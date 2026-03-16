// Platform backend: Native Linux (x86 / x86_64)
//
// Uses POSIX syscalls (mmap, sigaction, /proc/self/maps), inline asm for
// FS-segment setup, and std.Thread.  This file is only compiled when
// targeting a native CPU architecture.

const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");
const teb = @import("../win32/teb.zig");
const trace = @import("../trace.zig");
const kernel32_error = @import("../win32/kernel32/error.zig");

// -------------------------------------------------------------------------
// Architecture constants
// -------------------------------------------------------------------------

pub const is_wasm = false;
pub const is_native = true;
pub const is_x86 = builtin.target.cpu.arch == .x86;
pub const is_x86_64 = builtin.target.cpu.arch == .x86_64;

// -------------------------------------------------------------------------
// Threading
// -------------------------------------------------------------------------

/// Yields execution to the host environment.
pub fn yield() void {
    std.Thread.yield() catch {};
}

/// Suspends execution for the specified number of nanoseconds.
pub fn sleep(ns: u64) void {
    std.Thread.sleep(ns);
}

pub const Mutex = std.Thread.Mutex;

/// Spawns a new thread. Returns true on success.
pub fn spawnThread(func: anytype, args: anytype) bool {
    _ = std.Thread.spawn(.{}, func, args) catch return false;
    return true;
}

/// Read the SEH exception list head. On x86 this is FS:0.
/// On other native architectures, SEH is not supported.
pub fn readExceptionList() u32 {
    if (comptime is_x86) {
        return asm volatile ("movl %%fs:0, %[out]" : [out] "=r" (-> u32));
    } else {
        return 0xFFFFFFFF; // No SEH on this architecture
    }
}

// -------------------------------------------------------------------------
// Memory Mapping
// -------------------------------------------------------------------------

/// Allocates or maps a memory region.
pub fn mmap(
    hint: ?*anyopaque,
    size: usize,
    executable: bool,
    file_fd: i32,
    file_offset: u64,
    shared: bool,
    fixed: bool,
) ![]align(4096) u8 {
    if (comptime builtin.os.tag == .windows) {
        const os = std.os.windows;
        var prot: u32 = os.PAGE_READWRITE;
        if (executable) prot = os.PAGE_EXECUTE_READWRITE;
        const flags: u32 = os.MEM_COMMIT | os.MEM_RESERVE;
        const ptr = os.VirtualAlloc(hint, size, flags, prot) catch return error.OutOfMemory;
        return @as([*]align(4096) u8, @ptrCast(@alignCast(ptr)))[0..size];
    } else {
        var prot: u32 = std.posix.PROT.READ | std.posix.PROT.WRITE;
        if (executable) prot |= std.posix.PROT.EXEC;

        var flags: std.posix.MAP = if (shared) .{ .TYPE = .SHARED } else .{ .TYPE = .PRIVATE };
        if (comptime is_x86_64 and builtin.os.tag == .linux) {
            flags.@"32BIT" = true;
        }
        if (file_fd == -1) {
            flags.ANONYMOUS = true;
        }
        if (fixed) {
            // Use MAP_FIXED_NOREPLACE to avoid silently destroying existing
            // mappings (including the Zig host process itself).  If the
            // requested address is already occupied, the kernel returns
            // EEXIST and we fall back to a non-fixed mapping.
            flags.FIXED_NOREPLACE = true;
        }

        const ptr_hint: ?[*]align(4096) u8 = @ptrCast(@alignCast(hint));
        const result = std.posix.mmap(ptr_hint, size, prot, flags, file_fd, file_offset);

        if (result) |slice| {
            return slice;
        } else |err| {
            if (fixed and (err == error.MappingAlreadyExists or err == error.OutOfMemory)) {
                // The fixed address is occupied (by the host process). Fall back
                // to a non-fixed mapping — the PE will need relocations applied.
                log.warn("MAP_FIXED_NOREPLACE failed at 0x{X}, falling back to any address", .{@intFromPtr(hint)});
                var fallback_flags = flags;
                fallback_flags.FIXED_NOREPLACE = false;
                return std.posix.mmap(null, size, prot, fallback_flags, file_fd, file_offset);
            }
            return err;
        }
    }
}

/// Unmaps a memory region.
pub fn munmap(slice: []align(4096) u8) void {
    if (comptime builtin.os.tag == .windows) {
        const os = std.os.windows;
        os.VirtualFree(slice.ptr, 0, os.MEM_RELEASE) catch {};
    } else {
        std.posix.munmap(slice);
    }
}

// -------------------------------------------------------------------------
// Process
// -------------------------------------------------------------------------

/// Returns the process ID of the current process.
pub fn getProcessId() u32 {
    // Linux-specific — no cross-platform Zig std equivalent
    return @intCast(std.os.linux.getpid());
}

/// Terminates the current process with the given exit code.
pub fn exitProcess(code: u8) noreturn {
    std.process.exit(code);
}

/// Returns a high-resolution timestamp in nanoseconds.
pub fn timestamp() i64 {
    return std.time.timestamp();
}

// -------------------------------------------------------------------------
// Stack bounds (from /proc/self/maps)
// -------------------------------------------------------------------------

pub const StackBounds = struct {
    stack_base: u32,
    stack_limit: u32,
};

/// Returns the bounds of the current thread's stack.
pub fn getStackBounds(frame_addr: usize) StackBounds {
    // Defaults based on frame address
    var result = StackBounds{
        .stack_base = @truncate((frame_addr +% 0x100000) & 0xFFFFF000),
        .stack_limit = @truncate((frame_addr -% 0x700000) & 0xFFFFF000),
    };

    if (std.fs.openFileAbsolute("/proc/self/maps", .{})) |file| {
        defer file.close();
        var maps_buf: [8192]u8 = undefined;
        const bytes_read = file.readAll(&maps_buf) catch 0;
        const content = maps_buf[0..bytes_read];

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "[stack]")) |_| {
                var it = std.mem.splitScalar(u8, line, ' ');
                const range = it.next() orelse break;
                var range_it = std.mem.splitScalar(u8, range, '-');
                const start_str = range_it.next() orelse break;
                const end_str = range_it.next() orelse break;

                const stack_limit = std.fmt.parseInt(usize, start_str, 16) catch break;
                const stack_base = std.fmt.parseInt(usize, end_str, 16) catch break;

                result.stack_base = @truncate(stack_base);
                const eight_mb: usize = 8 * 1024 * 1024;
                if (stack_base > eight_mb) {
                    result.stack_limit = @truncate(stack_base - eight_mb);
                } else {
                    result.stack_limit = @truncate(stack_limit);
                }

                log.info("Detected stack: 0x{X} - 0x{X} (limit set to 0x{X})", .{ stack_limit, stack_base, result.stack_limit });
                break;
            }
        }
    } else |_| {}

    return result;
}

// -------------------------------------------------------------------------
// FS Segment Setup (TEB)
// -------------------------------------------------------------------------

/// Configures the FS segment for the current thread.
pub fn setupFS(teb_ptr: *anyopaque) !void {
    const arch = builtin.target.cpu.arch;

    if (arch == .x86) {
        // x86: use set_thread_area syscall via int $0x80
        // No Zig std equivalent — this is a Linux-specific syscall for
        // configuring x86 segment descriptors (needed for Win32 FS: TEB access).
        const SYS_set_thread_area: usize = 243;

        var desc: [4]u32 = [_]u32{
            0xFFFFFFFF, // entry_number = -1
            @truncate(@intFromPtr(teb_ptr)), // base_addr
            0xfffff, // limit
            0 | (1 << 0) | (0 << 1) | (0 << 3) | (1 << 4) | (0 << 5) | (1 << 6),
        };

        var rc: usize = undefined;
        asm volatile ("int $0x80"
            : [ret] "={eax}" (rc),
            : [num] "{eax}" (SYS_set_thread_area),
              [arg1] "{ebx}" (@intFromPtr(&desc)),
            : .{ .memory = true, .cc = true }
        );

        if (rc > 0xfffff000) {
            log.err("set_thread_area failed: {d}", .{rc});
            return error.SetThreadAreaFailed;
        }

        const entry_number = desc[0];
        const selector: u16 = @intCast((entry_number << 3) | 3); // RPL 3

        asm volatile ("mov %[sel], %%fs"
            :
            : [sel] "r" (selector),
        );

        // Save selector globally for timer threads that need to set FS for game callbacks
        teb.teb_fs_selector = selector;

        log.info("FS segment initialized with selector 0x{X}, TEB at 0x{X}", .{ selector, @intFromPtr(teb_ptr) });
    } else if (arch == .x86_64) {
        // x86_64: use arch_prctl(ARCH_SET_FS, base) syscall
        // No Zig std equivalent — arch_prctl is Linux-specific for setting
        // the FS segment base on x86_64 (needed for Win32 TEB access).
        const SYS_arch_prctl: usize = 158;
        const ARCH_SET_FS: usize = 0x1002;
        var rc: usize = undefined;
        asm volatile ("syscall"
            : [ret] "={rax}" (rc),
            : [num] "{rax}" (SYS_arch_prctl),
              [arg1] "{rdi}" (ARCH_SET_FS),
              [arg2] "{rsi}" (@intFromPtr(teb_ptr)),
            : .{ .rcx = true, .r11 = true, .memory = true }
        );

        if (rc > 0xfffffffffffff000) {
            log.err("arch_prctl(ARCH_SET_FS) failed: {d}", .{rc});
            return error.SetThreadAreaFailed;
        }
        log.info("FS base set via arch_prctl, TEB at 0x{X}", .{@intFromPtr(teb_ptr)});
    } else {
        return; // Unsupported architecture
    }
}

// -------------------------------------------------------------------------
// Memory Protection
// -------------------------------------------------------------------------

/// Changes the protection of a memory region.
pub fn mprotect(addr: usize, len: usize, readable: bool, writable: bool, executable: bool) void {
    var prot: u32 = 0;
    if (readable) prot |= std.posix.PROT.READ;
    if (writable) prot |= std.posix.PROT.WRITE;
    if (executable) prot |= std.posix.PROT.EXEC;
    _ = std.os.linux.mprotect(@ptrFromInt(addr), len, prot);
}

// -------------------------------------------------------------------------
// Pipe / Dup
// -------------------------------------------------------------------------

/// Creates a unidirectional data channel.
pub fn pipe() ![2]std.posix.fd_t {
    return std.posix.pipe();
}

/// Duplicates a file descriptor.
pub fn dup(fd: std.posix.fd_t) !std.posix.fd_t {
    return std.posix.dup(fd);
}

// -------------------------------------------------------------------------
// Signal Handler Setup
// -------------------------------------------------------------------------

const native_arch = builtin.target.cpu.arch;

// Architecture-dependent register access helpers
const REG = std.os.linux.REG;
const reg_ip = if (native_arch == .x86) REG.EIP else @as(usize, REG.RIP);
const reg_sp = if (native_arch == .x86) REG.ESP else @as(usize, REG.RSP);
const reg_ax = if (native_arch == .x86) REG.EAX else @as(usize, REG.RAX);
const reg_cx = if (native_arch == .x86) REG.ECX else @as(usize, REG.RCX);
const reg_dx = if (native_arch == .x86) REG.EDX else @as(usize, REG.RDX);
const reg_bx = if (native_arch == .x86) REG.EBX else @as(usize, REG.RBX);
const reg_si = if (native_arch == .x86) REG.ESI else @as(usize, REG.RSI);
const reg_di = if (native_arch == .x86) REG.EDI else @as(usize, REG.RDI);
const reg_bp = if (native_arch == .x86) REG.EBP else @as(usize, REG.RBP);
const reg_fl = if (native_arch == .x86) REG.EFL else @as(usize, REG.EFL);

fn sigsegvHandler(sig: i32, info: *const std.posix.siginfo_t, ctx_ptr: ?*const anyopaque) callconv(.c) void {
    const uctx = @as(*std.posix.ucontext_t, @ptrCast(@constCast(@alignCast(ctx_ptr.?))));
    const fault_addr = @intFromPtr(info.fields.sigfault.addr);
    const ip: usize = @bitCast(uctx.mcontext.gregs[reg_ip]);


    // Handle SIGILL — dispatch through SEH like Wine does.
    // cpuidsdk's SEH handler catches EXCEPTION_ILLEGAL_INSTRUCTION and sets
    // EIP/registers appropriately. Only skip directly if no SEH handler exists.
    if (sig == std.posix.SIG.ILL) {
        const teb_mod = @import("../win32/teb.zig");
        var has_seh = false;
        if (teb_mod.teb_base_addr != 0) {
            const seh_head = @as(*const u32, @ptrFromInt(teb_mod.teb_base_addr)).*;
            if (seh_head != 0 and seh_head != 0xFFFFFFFF) has_seh = true;
        }
        if (!has_seh) {
            const seh_fs = readExceptionList();
            if (seh_fs != 0 and seh_fs != 0xFFFFFFFF) has_seh = true;
        }
        if (has_seh) {
            // Fall through to SEH dispatch below with EXCEPTION_ILLEGAL_INSTRUCTION
            log.info("AppCompat: SIGILL at 0x{X}, dispatching to SEH", .{ip});
        } else {
            // No SEH handler — skip the instruction directly
            const code = @as([*]const u8, @ptrFromInt(ip));
            var inst_len: usize = 2;
            if (code[0] == 0x0F) {
                if (code[1] == 0x3F) inst_len = 4
                else if (code[1] == 0x37) inst_len = 2
                else if (code[1] == 0x01) inst_len = 3;
            }
            log.info("AppCompat: SIGILL at 0x{X}, no SEH, skipping {d} bytes", .{ ip, inst_len });
            uctx.mcontext.gregs[reg_ip] = @bitCast(ip + inst_len);
            uctx.mcontext.gregs[reg_ax] = 0;
            uctx.mcontext.gregs[reg_dx] = 0;
            return;
        }
    }

    // Handle SIGFPE (divide by zero) in game or native DLL code — skip the instruction
    if (sig == std.posix.SIG.FPE) {
        const code = @as([*]const u8, @ptrFromInt(ip));
        // Determine instruction length: div/idiv are 2 bytes (F7 /6 or F7 /7 with modrm)
        var inst_len: usize = 2;
        if (code[0] == 0xF7) {
            const modrm = code[1];
            const mod = (modrm >> 6) & 3;
            const rm = modrm & 7;
            if (mod == 0 and rm == 5) inst_len += 4  // [disp32]
            else if (mod == 1) inst_len += 1         // [reg+disp8]
            else if (mod == 2) inst_len += 4;        // [reg+disp32]
            if (rm == 4 and mod != 3) inst_len += 1; // SIB byte
        }
        log.info("AppCompat: SIGFPE at 0x{X}, skipping {d} bytes", .{ ip, inst_len });
        uctx.mcontext.gregs[reg_ip] = @bitCast(ip + inst_len);
        uctx.mcontext.gregs[reg_ax] = 0;
        uctx.mcontext.gregs[reg_dx] = 0;
        return;
    }

    // Handle privileged I/O port instructions (IN/OUT) — skip directly.
    // These cause #GP on Linux (SIGSEGV). cpuidsdk.dll uses VMware's backdoor
    // I/O port for detection. Skipping with EAX=0 indicates "not VMware".
    if (sig == std.posix.SIG.SEGV and ip != 0 and ip < 0xF0000000) {
        const code = @as([*]const u8, @ptrFromInt(ip));
        const is_io = switch (code[0]) {
            0xEC, 0xED, 0xEE, 0xEF => true,
            0xE4, 0xE5, 0xE6, 0xE7 => true,
            else => false,
        };
        if (is_io) {
            const ilen: usize = switch (code[0]) {
                0xE4, 0xE5, 0xE6, 0xE7 => 2,
                else => 1,
            };
            log.info("AppCompat: I/O port at 0x{X}, skipping {d} bytes", .{ ip, ilen });
            uctx.mcontext.gregs[reg_ip] = @bitCast(ip + ilen);
            uctx.mcontext.gregs[reg_ax] = 0;
            return;
        }
    }
    const is_priv_instruction = false;

    // Guard: If IP is outside game code range AND outside loaded native DLL ranges,
    // check if it's a near-null jump (bad function pointer call from game code).
    // Native DLLs like MSS32 may legally crash (e.g., null pointer deref) and should
    // fall through to the SEH handler dispatch below.
    const k32 = @import("../win32/kernel32.zig");
    const is_app_code = (ip >= k32.app_code_start and ip < k32.app_code_end);
    const is_native_dll = (ip >= 0x10000000 and ip < 0x30000000) or
        (ip >= 0xF0000000); // loaded DLLs (may be relocated)
    // Check if IP is within the zine binary's code segment. We use the address
    // of this handler function as a reference point — all Zig-compiled stubs
    // (COM vtable methods, Win32 API stubs) are in the same binary and within
    // a ±64MB window. We can't use isNativeImport() because that only matches
    // exact function entry points, not instructions within functions.
    const zine_code_ref = @intFromPtr(&sigsegvHandler);
    const is_zine_code = (ip >= zine_code_ref -| (64 * 1024 * 1024)) and
        (ip < zine_code_ref + (64 * 1024 * 1024));
    if (ip != 0 and !is_app_code and !is_native_dll and !is_zine_code and sig != std.posix.SIG.ILL) {
        // Bad function pointer call from game code — try to recover
        // This handles both near-null (0x40) and garbage (0xF0EB1210) addresses
        const esp: usize = @bitCast(uctx.mcontext.gregs[reg_sp]);
        if (esp > 0x1000) {
            const stack = @as([*]const u32, @ptrFromInt(esp & ~@as(usize, 3)));
            log.warn("AppCompat: Bad IP=0x{X} jump. Stack walk:", .{ip});
            var found_ret: ?u32 = null;
            var found_idx: usize = 0;
            for (0..200) |si| {
                const val = stack[si];
                if (val >= k32.app_code_start and val < k32.app_code_end) {
                    if (found_ret == null) {
                        found_ret = val;
                        found_idx = si;
                    }
                    if (si < 10 or found_ret != null) {
                        log.warn("  stack[{d}] = 0x{X} <app>", .{ si, val });
                    }
                } else if (si < 10) {
                    log.warn("  stack[{d}] = 0x{X}", .{ si, val });
                }
            }
            if (found_ret) |ret| {
                log.info("AppCompat: Recovering from bad IP=0x{X} to 0x{X} (stack[{d}])", .{ ip, ret, found_idx });
                uctx.mcontext.gregs[reg_ip] = ret;
                uctx.mcontext.gregs[reg_sp] = @bitCast(esp + (found_idx + 1) * 4);
                uctx.mcontext.gregs[reg_ax] = 0;
                return;
            }
        }
        // True emulator crash — print diagnostics and exit
        log.fatal("Segfault in emulator code at IP=0x{X}, fault_addr=0x{X}", .{ ip, fault_addr });
        log.fatal("  EAX=0x{X} ECX=0x{X} EDX=0x{X} EBX=0x{X}", .{
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_ax])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_cx])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_dx])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_bx])),
        });
        log.fatal("  ESP=0x{X} EBP=0x{X} ESI=0x{X} EDI=0x{X}", .{
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_sp])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_bp])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_si])),
            @as(usize, @bitCast(uctx.mcontext.gregs[reg_di])),
        });
        const fatal_esp: usize = @bitCast(uctx.mcontext.gregs[reg_sp]);
        if (fatal_esp > 0x1000) {
            const stack = @as([*]const u32, @ptrFromInt(fatal_esp));
            log.fatal("  Stack (first 16):", .{});
            for (0..16) |si| {
                log.fatal("    [{d}] = 0x{X}", .{ si, stack[si] });
            }
        }
        std.process.exit(1);
    }

    // AppCompat: Handle EIP=0 (null function pointer call or corrupted ret)
    if (ip == 0) {
        const esp: usize = @bitCast(uctx.mcontext.gregs[reg_sp]);
        if (esp > 0x1000) {
            // Walk the stack to find the first valid code address
            // App code is in 0x401000-0x6B0000, zine code is in 0x100000-0x300000
            // App code is in .text section (bounds from PE loader)
            // (.rdata starts at 0x662000 — must NOT jump there, it's data)
            const stack = @as([*]const u32, @ptrFromInt(esp & ~@as(usize, 3)));
            log.warn("AppCompat: EIP=0 fault. Stack walk:", .{});
            var found_ret: ?u32 = null;
            var found_idx: usize = 0;
            for (0..200) |si| {
                const val = stack[si];
                if (val >= k32.app_code_start and val < k32.app_code_end) {
                    if (found_ret == null) {
                        found_ret = val;
                        found_idx = si;
                    }
                    if (si < 10 or found_ret != null) {
                        log.warn("  stack[{d}] = 0x{X} <app>", .{si, val});
                    }
                } else if (si < 10) {
                    log.warn("  stack[{d}] = 0x{X}", .{si, val});
                }
            }
            if (found_ret) |ret| {
                log.info("AppCompat: Recovering to app code 0x{X} (stack[{d}])", .{ret, found_idx});
                uctx.mcontext.gregs[reg_ip] = ret;
                uctx.mcontext.gregs[reg_sp] = @bitCast(esp + (found_idx + 1) * 4);
                uctx.mcontext.gregs[reg_ax] = 0;
                return;
            }
        }
    }

    // Application Compatibility Shim for NULL pointer dereferences
    if (fault_addr < 0x1000 and ip != 0) {
        const ptr = @as([*]u8, @ptrFromInt(ip));

        // F2 AE = repnz scasb (strlen pattern: ecx=-1, al=0, scan es:[edi])
        // When EDI is in the NULL page, simulate scanning an empty string:
        // one iteration finds the null terminator, so ecx goes -1 → -2.
        if (ptr[0] == 0xF2 and ptr[1] == 0xAE) {
            log.info("AppCompat: Skipped NULL repnz scasb at 0x{X} (edi=0x{X})", .{ ip, @as(usize, @bitCast(uctx.mcontext.gregs[reg_di])) });
            uctx.mcontext.gregs[reg_cx] = @bitCast(@as(isize, -2)); // as if one byte scanned
            uctx.mcontext.gregs[reg_di] = 1; // edi advanced past the "null terminator"
            uctx.mcontext.gregs[reg_ip] += 2; // skip F2 AE
            return;
        }

        // ff 51 XX (call [ecx+disp8]) or ff 52 XX (call [edx+disp8])
        if ((ptr[0] == 0xFF and (ptr[1] & 0xF8) == 0x50)) {
            log.info("AppCompat: Skipped NULL pointer call at 0x{X} ({X} {X} {X})", .{ip, ptr[0], ptr[1], ptr[2]});
            uctx.mcontext.gregs[reg_ip] += 3;
            uctx.mcontext.gregs[reg_sp] += if (native_arch == .x86) 4 else 8;
            return;
        }

        // Generic x86 NULL-pointer read/write skip.  We decode the ModR/M
        // (and optional SIB) byte to figure out how many bytes to skip.
        //
        // Reads:  8A (mov r8, [r/m])   8B (mov r32, [r/m])
        //         3B (cmp r32, [r/m])
        // Writes: 88/89 (mov [r/m], reg)  C6/C7 (mov [r/m], imm)
        //         01/09/21/29/31 (alu [r/m], reg)
        const maybe_opcode = ptr[0];

        const is_read = switch (maybe_opcode) {
            0x8A, 0x8B => true, // mov reg, [r/m] (8/32 bit)
            0x3B => true,       // cmp reg, [r/m]
            else => false,
        };
        const is_store = switch (maybe_opcode) {
            0x88, 0x89 => true, // mov [r/m], reg8/32
            0xC6, 0xC7 => true, // mov [r/m], imm8/imm32
            0x01 => true,       // add [r/m], reg
            0x29 => true,       // sub [r/m], reg
            0x09 => true,       // or  [r/m], reg
            0x21 => true,       // and [r/m], reg
            0x31 => true,       // xor [r/m], reg
            else => false,
        };

        if ((is_read or is_store) and ptr[1] & 0xC0 != 0xC0) { // Not reg-to-reg (mod != 11)
            const modrm = ptr[1];
            const mod_field = (modrm >> 6) & 3;
            const rm_field = modrm & 7;
            const reg_field = (modrm >> 3) & 7;
            // Base instruction length: opcode(1) + modrm(1)
            var skip: usize = 2;
            // SIB byte present when rm == 4 and mod != 3
            if (rm_field == 4 and mod_field != 3) skip += 1;
            // Displacement
            if (mod_field == 0 and rm_field == 5) {
                skip += 4; // [disp32]
            } else if (mod_field == 1) {
                skip += 1; // [reg+disp8]
            } else if (mod_field == 2) {
                skip += 4; // [reg+disp32]
            }
            // Immediate (for C6/C7)
            if (maybe_opcode == 0xC6) skip += 1;
            if (maybe_opcode == 0xC7) skip += 4;

            if (is_read) {
                // Zero the destination register (from reg field of ModR/M)
                const dest_reg_idx: usize = switch (reg_field) {
                    0 => reg_ax,
                    1 => reg_cx,
                    2 => reg_dx,
                    3 => reg_bx,
                    4 => reg_sp,
                    5 => reg_bp,
                    6 => reg_si,
                    7 => reg_di,
                    else => unreachable,
                };
                uctx.mcontext.gregs[dest_reg_idx] = 0;
                log.info("AppCompat: Skipped NULL pointer read at 0x{X} (reg={d})", .{ip, reg_field});
            } else {
                log.info("AppCompat: Skipped NULL pointer write at 0x{X}", .{ip});
            }
            uctx.mcontext.gregs[reg_ip] += @intCast(skip);
            return;
        }
    }

    // Instead of calling SEH handlers directly (which corrupts the stack when
    // they do RtlUnwind/longjmp), redirect execution to RaiseException.
    // This sets up the exception dispatch in normal context, not signal context.
    //
    // Write RaiseException args on the guest stack and set EIP to RaiseException.
    const exc_code: u32 = if (sig == std.posix.SIG.ILL)
        0xC000001D // EXCEPTION_ILLEGAL_INSTRUCTION
    else if (is_priv_instruction)
        0xC0000096 // EXCEPTION_PRIV_INSTRUCTION
    else
        0xC0000005; // EXCEPTION_ACCESS_VIOLATION

    // Save hardware context for RaiseException's SEH dispatch
    const k32_error = @import("../win32/kernel32/error.zig");
    const raise_addr = @intFromPtr(&k32_error.RaiseException);

    // Fill a static CONTEXT with the faulting register state
    const hw_ctx = &(struct { var ctx: teb.CONTEXT = undefined; }).ctx;
    @memset(std.mem.asBytes(hw_ctx), 0);
    hw_ctx.ContextFlags = 0x10007;
    hw_ctx.Eax = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_ax])));
    hw_ctx.Ecx = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_cx])));
    hw_ctx.Edx = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_dx])));
    hw_ctx.Ebx = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_bx])));
    hw_ctx.Esi = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_si])));
    hw_ctx.Edi = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_di])));
    hw_ctx.Ebp = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_bp])));
    hw_ctx.Esp = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_sp])));
    hw_ctx.Eip = @truncate(ip);
    hw_ctx.EFlags = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_fl])));
    k32_error.saved_hw_context = hw_ctx;

    // Push RaiseException args on the guest stack (stdcall: right-to-left)
    var esp: u32 = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[reg_sp])));
    esp -= 4; @as(*u32, @ptrFromInt(esp)).* = 0; // lpArguments = NULL
    esp -= 4; @as(*u32, @ptrFromInt(esp)).* = 0; // nNumberOfArguments = 0
    esp -= 4; @as(*u32, @ptrFromInt(esp)).* = 0; // dwExceptionFlags = 0
    esp -= 4; @as(*u32, @ptrFromInt(esp)).* = exc_code; // dwExceptionCode
    esp -= 4; @as(*u32, @ptrFromInt(esp)).* = @truncate(ip); // fake return address

    // Set signal context to call RaiseException when signal handler returns
    uctx.mcontext.gregs[reg_sp] = esp;
    uctx.mcontext.gregs[reg_ip] = @truncate(raise_addr);

    if (trace.enable_tracing) trace.print("SEH: Redirecting to RaiseException(code={x}) for exception at 0x{X}\n", .{ exc_code, ip });
    return;

}

/// Install the SIGSEGV/SIGFPE handler.
pub fn installSegfaultHandler() void {
    var act = std.posix.Sigaction{
        .handler = .{ .sigaction = &sigsegvHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO,
    };
    std.posix.sigaction(std.posix.SIG.SEGV, &act, null);
    std.posix.sigaction(std.posix.SIG.FPE, &act, null);
    std.posix.sigaction(std.posix.SIG.ILL, &act, null);
}

/// Map the null page for compatibility (may fail due to mmap_min_addr).
pub fn mapNullPage() void {
    _ = std.posix.mmap(
        @ptrFromInt(0),
        4096,
        std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
        -1,
        0,
    ) catch {};
}

/// Increase the stack rlimit to avoid C1063.
pub fn raiseStackLimit() void {
    if (@hasDecl(std.posix, "getrlimit")) {
        if (std.posix.getrlimit(.STACK)) |rlim| {
            var new_rlim = rlim;
            new_rlim.cur = rlim.max;
            _ = std.posix.setrlimit(.STACK, new_rlim) catch {};
        } else |_| {}
    }
}
