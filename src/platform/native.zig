// Platform backend: Native Linux (x86 / x86_64)
//
// Uses POSIX syscalls (mmap, sigaction, /proc/self/maps), inline asm for
// FS-segment setup, and std.Thread.  This file is only compiled when
// targeting a native CPU architecture.

const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");

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

pub fn yield() void {
    std.Thread.yield() catch {};
}

pub fn sleep(ns: u64) void {
    std.Thread.sleep(ns);
}

pub const Mutex = std.Thread.Mutex;

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

pub fn getProcessId() u32 {
    return @intCast(std.os.linux.getpid());
}

pub fn exitProcess(code: u8) noreturn {
    std.process.exit(code);
}

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

pub fn setupFS(teb_ptr: *anyopaque) !void {
    const arch = builtin.target.cpu.arch;

    if (arch == .x86) {
        // x86: use set_thread_area syscall via int $0x80
        var desc: [4]u32 = [_]u32{
            0xFFFFFFFF, // entry_number = -1
            @truncate(@intFromPtr(teb_ptr)), // base_addr
            0xfffff, // limit
            0 | (1 << 0) | (0 << 1) | (0 << 3) | (1 << 4) | (0 << 5) | (1 << 6),
        };

        var rc: usize = undefined;
        asm volatile ("int $0x80"
            : [ret] "={eax}" (rc),
            : [num] "{eax}" (@as(usize, 243)), // __NR_set_thread_area
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
        log.info("FS segment initialized with selector 0x{X}, TEB at 0x{X}", .{ selector, @intFromPtr(teb_ptr) });
    } else if (arch == .x86_64) {
        // x86_64: use arch_prctl(ARCH_SET_FS, base) syscall
        const ARCH_SET_FS: usize = 0x1002;
        var rc: usize = undefined;
        asm volatile ("syscall"
            : [ret] "={rax}" (rc),
            : [num] "{rax}" (@as(usize, 158)), // __NR_arch_prctl
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
// Signal Handler Setup
// -------------------------------------------------------------------------

/// Install a SIGSEGV handler. The caller provides the handler function.
pub fn installSegfaultHandler(
    handler: *const fn (i32, *const std.posix.siginfo_t, ?*const anyopaque) callconv(.c) void,
) void {
    var act = std.posix.Sigaction{
        .handler = .{ .sigaction = handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO,
    };
    std.posix.sigaction(std.posix.SIG.SEGV, &act, null);
    std.posix.sigaction(std.posix.SIG.FPE, &act, null);
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
