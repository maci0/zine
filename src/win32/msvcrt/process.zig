const std = @import("std");
const x86_memory = @import("../../x86/memory.zig");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const log = @import("../../log.zig");
const msvcrt = @import("../msvcrt.zig");
const builtin = @import("builtin");

const io = @import("io.zig");
const platform = @import("../../platform.zig");

// --- Guest-accessible MSVCRT globals (WASM) ---
// On WASM, the x86 interpreter can only read guest memory. The `__p_xxx`
// stubs return pointers to globals, which must be guest virtual addresses.
// We allocate a small block in guest memory and mirror the globals there.
const guest_globals_size: u32 = 2048;

// Offsets within the guest globals block
pub const g_argc: u32 = 0; // i32
pub const g_argv: u32 = 4; // u32 (pointer to argv array)
pub const g_envp: u32 = 8; // u32 (pointer to envp array)
pub const g_fmode: u32 = 12; // u32
pub const g_commode: u32 = 16; // u16 padded to u32
pub const g_initenv: u32 = 20; // u32
pub const g_pgmptr: u32 = 24; // u32
pub const g_acmdln: u32 = 28; // u32 (pointer to acmdln string)
// Phase 3 additions: static return values that x86 code dereferences
pub const g_errno: u32 = 32; // i32
pub const g_doserrno: u32 = 36; // u32
pub const g_setlocale: u32 = 40; // 2 bytes ("C\0") padded
// Phase 18 additions:
pub const g_timezone: u32 = 44; // i32
pub const g_daylight: u32 = 48; // i32
pub const g_tzname: u32 = 52; // [2]u32
pub const g_adjust_fdiv: u32 = 60; // i32
pub const g_mb_cur_max: u32 = 64; // i32
pub const g_nhandle: u32 = 68; // i32
pub const g_pctype_ptr: u32 = 72; // u32
pub const g_mbctype_ptr: u32 = 76; // u32
pub const g_wcmdln: u32 = 80; // u32 (pointer to wcmdln string)

pub const g_pctype_array: u32 = 84; // 257 * 2 = 514 bytes
pub const g_mbctype_array: u32 = 600; // 257 bytes

pub var guest_globals_addr: u32 = 0; // guest virtual address of globals block

pub fn ensureGuestGlobals() u32 {
    if (guest_globals_addr != 0) return guest_globals_addr;
    if (x86_memory.guest_memory) |gmem| {
        const addr = gmem.guestAlloc(guest_globals_size);
        if (addr == 0) return 0;
        guest_globals_addr = addr;

        // Initialize with current global values
        gmem.write32(addr + g_argc, @bitCast(msvcrt.global_argc));
        // argv/envp will be filled by ensureGuestArgs → getmainargs
        gmem.write32(addr + g_argv, guest_argv_addr);
        gmem.write32(addr + g_envp, guest_envp_addr);
        gmem.write32(addr + g_fmode, msvcrt.msvcrt_fmode);
        gmem.write32(addr + g_commode, msvcrt.msvcrt_commode);
        gmem.write32(addr + g_initenv, 0); // null
        gmem.write32(addr + g_pgmptr, 0); // null
        gmem.write32(addr + g_acmdln, @truncate(msvcrt.msvcrt_acmdln));
        // Static return value slots
        gmem.write32(addr + g_errno, 0); // errno = 0
        gmem.write32(addr + g_doserrno, 0); // doserrno = 0
        gmem.base[addr - gmem.base_addr + g_setlocale] = 'C';
        gmem.base[addr - gmem.base_addr + g_setlocale + 1] = 0;

        gmem.write32(addr + g_timezone, @bitCast(msvcrt.msvcrt_timezone));
        gmem.write32(addr + g_daylight, @bitCast(msvcrt.msvcrt_daylight));
        gmem.write32(addr + g_tzname, 0); // null ptrs for now
        gmem.write32(addr + g_tzname + 4, 0);

        gmem.write32(addr + g_adjust_fdiv, @bitCast(msvcrt.msvcrt_adjust_fdiv));
        gmem.write32(addr + g_mb_cur_max, @bitCast(msvcrt.msvcrt_mb_cur_max));
        gmem.write32(addr + g_nhandle, @bitCast(io.nhandle));
        gmem.write32(addr + g_pctype_ptr, addr + g_pctype_array + 2); // points to [1]
        gmem.write32(addr + g_mbctype_ptr, addr + g_mbctype_array + 1); // points to [1]

        // arrays
        const pct = gmem.base[addr - gmem.base_addr + g_pctype_array .. addr - gmem.base_addr + g_pctype_array + 514];
        @memcpy(pct, std.mem.sliceAsBytes(&msvcrt.msvcrt_pctype));
        const mbc = gmem.base[addr - gmem.base_addr + g_mbctype_array .. addr - gmem.base_addr + g_mbctype_array + 257];
        @memcpy(mbc, &msvcrt.msvcrt_mbctype);

        return addr;
    }
    // On x86_64 compat mode, __p_xxx stubs return pointers that 32-bit guest
    // code dereferences. Host globals are above 4GB, so allocate a low-4GB
    // block via platform.mmap (MAP_32BIT) and mirror the globals there.
    if (comptime platform.is_x86_64) {
        // Allocate a large low-4GB block for globals + copied strings
        const block_size: usize = 64 * 1024; // 64KB for globals + string copies
        const mem = platform.mmap(null, block_size, false, -1, 0, false, false) catch return 0;
        const addr: u32 = @intCast(@intFromPtr(mem.ptr));
        guest_globals_addr = addr;
        const ptr = mem.ptr;
        // String copy area starts after the globals header (256 bytes)
        var str_cursor: u32 = guest_globals_size;

        // Helper to copy a NUL-terminated string into the low-4GB block
        const copyStr = struct {
            fn f(base: [*]u8, cursor: *u32, src: usize, limit: u32) u32 {
                if (src == 0) return 0;
                const s = @as([*]const u8, @ptrFromInt(src));
                var len: u32 = 0;
                while (len < limit - cursor.* - 1 and s[len] != 0) : (len += 1) {}
                const dest = cursor.*;
                @memcpy(base[dest .. dest + len], s[0..len]);
                base[dest + len] = 0;
                cursor.* += len + 1;
                return dest;
            }
        }.f;

        // Copy _pgmptr string
        const pgmptr_off = if (msvcrt.msvcrt_pgmptr) |pgm|
            copyStr(ptr, &str_cursor, @intFromPtr(pgm), @intCast(block_size))
        else
            @as(u32, 0);

        // Copy _acmdln string
        const acmdln_off = if (msvcrt.msvcrt_acmdln != 0)
            copyStr(ptr, &str_cursor, msvcrt.msvcrt_acmdln, @intCast(block_size))
        else
            @as(u32, 0);

        writeU32(ptr, g_argc, @bitCast(msvcrt.global_argc));
        // argv/envp: these are arrays of pointers. The pointers themselves
        // may be in low 4GB (from arena+mmap), just truncate for now.
        writeU32(ptr, g_argv, @truncate(@intFromPtr(msvcrt.global_argv)));
        writeU32(ptr, g_envp, @truncate(@intFromPtr(msvcrt.global_envp)));
        writeU32(ptr, g_fmode, msvcrt.msvcrt_fmode);
        writeU32(ptr, g_commode, msvcrt.msvcrt_commode);
        writeU32(ptr, g_initenv, 0);
        // pgmptr: pointer TO the string, stored as addr + pgmptr_off
        writeU32(ptr, g_pgmptr, if (pgmptr_off != 0) addr + pgmptr_off else 0);
        writeU32(ptr, g_acmdln, if (acmdln_off != 0) addr + acmdln_off else 0);
        writeU32(ptr, g_wcmdln, 0); // wcmdln uninitialized strings not handled natively yet

        writeU32(ptr, g_errno, 0);
        writeU32(ptr, g_doserrno, 0);
        ptr[g_setlocale] = 'C';
        ptr[g_setlocale + 1] = 0;

        writeU32(ptr, g_timezone, @bitCast(msvcrt.msvcrt_timezone));
        writeU32(ptr, g_daylight, @bitCast(msvcrt.msvcrt_daylight));
        // TZ strings are not mirrored into guest memory yet; _tzname stays
        // null there (the host-side default is UTC, matching the zero bias).
        writeU32(ptr, g_tzname, 0);
        writeU32(ptr, g_tzname + 4, 0);

        writeU32(ptr, g_adjust_fdiv, @bitCast(msvcrt.msvcrt_adjust_fdiv));
        writeU32(ptr, g_mb_cur_max, @bitCast(msvcrt.msvcrt_mb_cur_max));
        writeU32(ptr, g_nhandle, @bitCast(io.nhandle));
        writeU32(ptr, g_pctype_ptr, addr + g_pctype_array + 2); // pointer to index 1
        writeU32(ptr, g_mbctype_ptr, addr + g_mbctype_array + 1); // pointer to index 1

        const pct = ptr[g_pctype_array .. g_pctype_array + 514];
        @memcpy(pct, std.mem.sliceAsBytes(&msvcrt.msvcrt_pctype));

        const mbc = ptr[g_mbctype_array .. g_mbctype_array + 257];
        @memcpy(mbc, &msvcrt.msvcrt_mbctype);

        return addr;
    }
    return 0;
}

fn writeU32(base: [*]u8, offset: u32, value: u32) void {
    @as(*align(1) u32, @ptrCast(base + offset)).* = value;
}

/// Update guest globals after argv/envp are built
/// Implementation status: Partially implemented
pub fn updateGuestGlobals() void {
    if (guest_globals_addr == 0) return;
    if (x86_memory.guest_memory) |gmem| {
        gmem.write32(guest_globals_addr + g_argc, @bitCast(msvcrt.global_argc));
        gmem.write32(guest_globals_addr + g_argv, guest_argv_addr);
        gmem.write32(guest_globals_addr + g_envp, guest_envp_addr);
        gmem.write32(guest_globals_addr + g_pgmptr, guest_pgmptr_addr);
    } else if (comptime platform.is_x86_64) {
        const ptr = @as([*]u8, @ptrFromInt(guest_globals_addr));
        writeU32(ptr, g_argc, @bitCast(msvcrt.global_argc));
        writeU32(ptr, g_argv, guest_argv_addr);
        writeU32(ptr, g_envp, guest_envp_addr);
        writeU32(ptr, g_pgmptr, guest_pgmptr_addr);
    }
}

/// Implementation status: Partially implemented
pub fn p_argc() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) return g + g_argc;
    return @intFromPtr(&msvcrt.global_argc);
}

/// Implementation status: Partially implemented
pub fn p_argv() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) {
        // Make sure guest args are built first
        ensureGuestArgs();
        updateGuestGlobals();
        return g + g_argv;
    }
    return @intFromPtr(&msvcrt.global_argv);
}

/// Implementation status: Partially implemented
pub fn p_environ() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) {
        ensureGuestArgs();
        updateGuestGlobals();
        return g + g_envp;
    }
    const static_p = struct {
        var p: [*]const ?[*:0]const u8 = undefined;
    };
    static_p.p = msvcrt.global_envp;
    return @intFromPtr(@as(*const anyopaque, @ptrCast(@constCast(&static_p.p))));
}

// Guest-accessible buffer for interpreter mode argv/envp data.
// Allocated once at low address via platform.mmap so x86 guest code
// can read the 32-bit pointers.  Lazily initialized.
var guest_args_buf: ?[]u8 = null;
pub var guest_argv_addr: u32 = 0;
pub var guest_envp_addr: u32 = 0;
pub var guest_pgmptr_addr: u32 = 0;

/// Reset cached guest argv/envp state. Called by the WASM spawn handler
/// so the child PE's CRT rebuilds argv from the new global_argv.
pub fn resetGuestArgs() void {
    guest_args_buf = null;
    guest_argv_addr = 0;
    guest_envp_addr = 0;
    guest_pgmptr_addr = 0;
    guest_globals_addr = 0;
}
const guest_args_base: u32 = 0x04000000;

/// Upper bounds on the entries copied into the guest argv/envp block. The
/// block is a fixed 256 KB, so both the pointer tables and the strings they
/// point at have to stop somewhere the block cannot overrun.
const MAX_GUEST_ARGV: usize = 128;
const MAX_GUEST_ENVP: usize = 4096;

pub fn ensureGuestArgs() void {
    if (guest_args_buf != null) return;

    const plt = @import("../../platform.zig");

    var base_addr: u32 = guest_args_base;
    const buf_size: usize = 256 * 1024; // 256KB

    // On WASM, allocate from the guest heap so addresses are within GuestMemory range
    if (x86_memory.guest_memory) |gmem| {
        const alloc_addr = gmem.guestAlloc(@intCast(buf_size));
        if (alloc_addr == 0) return;
        base_addr = alloc_addr;
        const offset = alloc_addr - gmem.base_addr;
        guest_args_buf = gmem.base[offset .. offset + buf_size];
    } else {
        const block = plt.mmap(
            @ptrFromInt(guest_args_base),
            buf_size,
            false,
            -1,
            0,
            false,
            false,
        ) catch return;
        guest_args_buf = block;
    }

    var gpos: usize = 0;
    const block = guest_args_buf.?;

    // Copy a null-terminated string into the block, return guest address.
    // Null when the block is full: the strings come from the host
    // environment and the command line, so their total size is not bounded by
    // anything this function controls, and writing past the block would
    // corrupt whatever the guest heap placed after it.
    const putStr = struct {
        fn f(buf: []u8, pos: *usize, src: []const u8, base: u32) ?u32 {
            const end = (pos.* + src.len + 1 + 3) & ~@as(usize, 3); // align 4
            if (end > buf.len) return null;
            const guest_addr: u32 = base +% @as(u32, @intCast(pos.*));
            @memcpy(buf[pos.* .. pos.* + src.len], src);
            buf[pos.* + src.len] = 0;
            pos.* = end;
            return guest_addr;
        }
    }.f;

    // Append one guest pointer to the block, if it still fits.
    const putPtr = struct {
        fn f(buf: []u8, pos: *usize, value: u32) bool {
            if (pos.* + 4 > buf.len) return false;
            @memcpy(buf[pos.* .. pos.* + 4], std.mem.asBytes(&value));
            pos.* += 4;
            return true;
        }
    }.f;

    // 1) Copy argv strings, record 32-bit addresses
    const argc_val: usize = @intCast(msvcrt.global_argc);
    var argv_str_addrs: [MAX_GUEST_ARGV]u32 = [_]u32{0} ** MAX_GUEST_ARGV;
    var argv_str_count: usize = 0;
    var dropped_argv: usize = 0;
    for (0..@min(argc_val, MAX_GUEST_ARGV)) |i| {
        const arg_ptr = msvcrt.global_argv[i] orelse continue;
        if (putStr(block, &gpos, std.mem.span(arg_ptr), base_addr)) |addr| {
            argv_str_addrs[argv_str_count] = addr;
            argv_str_count += 1;
        } else {
            // Stop at the first one that does not fit: a later string would
            // only be reachable through a hole in the argv array.
            dropped_argv = argc_val - argv_str_count;
            break;
        }
    }
    if (dropped_argv > 0) {
        log.err("MSVCRT: guest argv block holds {d} of {d} arguments", .{ argv_str_count, argc_val });
    }
    guest_pgmptr_addr = if (argv_str_count > 0) argv_str_addrs[0] else 0;

    // 2) Build argv array of u32 pointers, null-terminated
    guest_argv_addr = base_addr +% @as(u32, @intCast(gpos));
    for (argv_str_addrs[0..argv_str_count]) |ptr| {
        if (!putPtr(block, &gpos, ptr)) break;
    }
    _ = putPtr(block, &gpos, 0);

    // 3) Copy envp strings and build envp array
    var envp_str_addrs: [MAX_GUEST_ENVP]u32 = undefined;
    var envp_str_count: usize = 0;
    {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            if (envp_str_count >= MAX_GUEST_ENVP) break;
            const src = std.mem.span(env_ptr);
            if (putStr(block, &gpos, src, base_addr)) |addr| {
                envp_str_addrs[envp_str_count] = addr;
                envp_str_count += 1;
            } else {
                // A truncated environment ends where the block ends; the
                // array below is null-terminated, so the guest reads a shorter
                // environment rather than a hole.
                log.err("MSVCRT: guest argv block is full, environment truncated after {d} entries", .{envp_str_count});
                break;
            }
        }
    }
    guest_envp_addr = base_addr +% @as(u32, @intCast(gpos));
    for (envp_str_addrs[0..envp_str_count]) |ptr| {
        if (!putPtr(block, &gpos, ptr)) break;
    }
    // null terminator
    _ = putPtr(block, &gpos, 0);

    if (trace.enable_tracing) trace.print("MSVCRT: built guest args at 0x{X} ({d} bytes)\n", .{ base_addr, gpos });
}

/// Implementation status: Partially implemented
pub fn getmainargs(
    argc_ptr: usize,
    argv_ptr: usize,
    envp_ptr: usize,
    dowildcard: i32,
    startinfo: usize,
) callconv(.c) i32 {
    _ = dowildcard;
    _ = startinfo;

    // Build guest-accessible argv/envp (rebuilds after resetGuestArgs)
    ensureGuestArgs();
    // Write argc (4 bytes — same width on both 32/64-bit)
    if (argc_ptr != 0) {
        @as(*i32, @ptrFromInt(trace.addr(argc_ptr))).* = msvcrt.global_argc;
    }

    // Write argv/envp as 32-bit pointers into guest memory
    if (argv_ptr != 0) {
        @as(*u32, @ptrFromInt(trace.addr(argv_ptr))).* = guest_argv_addr;
    }
    if (envp_ptr != 0) {
        @as(*u32, @ptrFromInt(trace.addr(envp_ptr))).* = guest_envp_addr;
    }

    updateGuestGlobals();

    if (trace.enable_tracing) {
        trace.print("MSVCRT: __getmainargs argc={d} argv=0x{X} envp=0x{X}\n", .{
            msvcrt.global_argc, guest_argv_addr, guest_envp_addr,
        });
        const argc_val: usize = @intCast(msvcrt.global_argc);
        for (0..argc_val) |i| {
            if (msvcrt.global_argv[i]) |arg| {
                trace.print("  argv[{d}] = '{s}'\n", .{ i, std.mem.span(arg) });
            }
        }
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn exit(status: i32) callconv(.c) void {
    if (trace.enable_tracing) trace.print("MSVCRT: exit({d}) called from 0x{X}\n", .{ status, @returnAddress() });
    // In child-process mode, store exit code and halt the child CPU.
    // exit() returns to the thunk handler → interpreter step() → run() loop
    // which checks cpu.halted and breaks.
    const shared = @import("../shared.zig");
    if (shared.child_exit_code) |ptr| {
        ptr.* = status;
        if (shared.child_cpu) |cpu| {
            cpu.halted = true;
        }
        return;
    }
    platform.exitProcess(@intCast(@as(u32, @bitCast(status)) & 0xFF));
}

/// _beginthreadex: MSVC CRT thread creation (wraps CreateThread)
/// Implementation status: Partially implemented
pub fn beginthreadex(
    security: usize,
    stack_size: u32,
    start_address: usize,
    arglist: usize,
    initflag: u32,
    thrdaddr: usize,
) callconv(.c) usize {
    _ = security;
    _ = initflag;
    if (trace.enable_tracing) trace.print("MSVCRT: _beginthreadex(start={x}, arg={x})\n", .{ start_address, arglist });

    const kernel32_process = @import("../kernel32/process.zig");
    return kernel32_process.CreateThread(0, stack_size, start_address, arglist, 0, thrdaddr);
}

/// Implementation status: Partially implemented
pub fn spawnvp(mode: i32, cmdname_ptr: usize, argv_ptr: usize) callconv(.c) i32 {
    if (comptime !platform.is_native) {
        // WASM mode: use the spawn handler to load and run the child PE in-process
        const shared = @import("../shared.zig");
        if (shared.spawn_handler) |handler| {
            if (cmdname_ptr == 0) return -1;
            const cmdname = trace.c_span(cmdname_ptr);
            if (trace.enable_tracing) trace.print("MSVCRT: _spawnvp(mode={d}, cmd='{s}') [WASM in-process]\n", .{ mode, cmdname });
            return handler(cmdname, argv_ptr);
        }
        _ = .{ mode, cmdname_ptr, argv_ptr };
        if (trace.enable_tracing) trace.print("MSVCRT: _spawnvp not supported on this platform\n", .{});
        return -1;
    }
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(std.heap.page_allocator);

    if (cmdname_ptr == 0) return -1;
    const cmdname = trace.c_span(cmdname_ptr);
    if (trace.enable_tracing) trace.print("spawnvp cmd: {s}\n", .{cmdname});

    if (comptime builtin.os.tag == .linux) {
        // Raw readlink: std.process.executablePathAlloc goes through std.Io
        // (TLS), which faults inside the compat-mode SIGSEGV dispatch handler.
        var exe_buf: [4096]u8 = undefined;
        const rl = std.os.linux.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
        const rl_signed: isize = @bitCast(rl);
        if (rl_signed > 0) {
            const loader_exe2 = std.fmt.allocPrint(std.heap.page_allocator, "{s}\x00", .{exe_buf[0..@intCast(rl_signed)]}) catch return -1;
            args.append(std.heap.page_allocator, loader_exe2[0 .. loader_exe2.len - 1]) catch return -1;
        } else {
            args.append(std.heap.page_allocator, "zine") catch return -1;
        }
    } else {
        const raw_loader_exe = std.process.executablePathAlloc(runtime.io(), std.heap.page_allocator) catch "zine";
        const loader_exe = std.fmt.allocPrint(std.heap.page_allocator, "{s}\x00", .{raw_loader_exe}) catch return -1;
        args.append(std.heap.page_allocator, loader_exe[0 .. loader_exe.len - 1]) catch return -1;
    }
    if (trace.enable_tracing) {
        args.append(std.heap.page_allocator, "--trace") catch return -1;
    }

    if (argv_ptr != 0) {
        // A 64-bit host (x86_64 or wasm64) holds guest argv entries as u32.
        const ArgPtrType = if (comptime platform.wide_host) u32 else usize;
        const argv = @as([*]const ArgPtrType, @ptrFromInt(argv_ptr));
        if (argv[0] != 0) {
            const arg0 = trace.c_span(@as(usize, argv[0]));
            var clean_arg0 = std.heap.page_allocator.dupe(u8, arg0) catch return -1;
            std.mem.replaceScalar(u8, clean_arg0, '/', '\\');
            // Strip surrounding quotes (the CRT/tool may pass argv[0] quoted).
            if (clean_arg0.len >= 2 and clean_arg0[0] == '"' and clean_arg0[clean_arg0.len - 1] == '"') {
                clean_arg0 = clean_arg0[1 .. clean_arg0.len - 1];
            }
            if (std.mem.lastIndexOfScalar(u8, clean_arg0, '\\')) |idx| {
                clean_arg0 = clean_arg0[idx + 1 ..];
            }
            _ = std.ascii.lowerString(clean_arg0, clean_arg0);
            if (std.ascii.endsWithIgnoreCase(clean_arg0, ".exe")) {
                clean_arg0 = clean_arg0[0 .. clean_arg0.len - 4];
            }

            args.append(std.heap.page_allocator, "--argv0") catch return -1;
            args.append(std.heap.page_allocator, clean_arg0) catch return -1;
        }
    }

    var resolved = false;
    var has_sep = false;
    for (cmdname) |c| {
        if (c == '/' or c == '\\') has_sep = true;
    }

    if (!has_sep and msvcrt.global_argc > 0 and msvcrt.global_argv[0] != null) {
        const exe_path = trace.c_span(@intFromPtr(msvcrt.global_argv[0].?));
        if (std.fs.path.dirname(exe_path)) |dir| {
            const full_cmd = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir, cmdname }) catch null;
            if (full_cmd) |fc| {
                args.append(std.heap.page_allocator, fc) catch return -1;
                resolved = true;
            }
        }
    }

    // Let standard PATH resolution handle it if it wasn't a relative sibling
    if (!resolved) {
        // Sanitize Windows paths for the host OS: strip drive letter (C:) and convert backslashes
        var clean_cmd = std.heap.page_allocator.dupe(u8, cmdname) catch return -1;
        std.mem.replaceScalar(u8, clean_cmd, '\\', '/');
        // Strip Windows drive prefix (e.g. "C:/./path" -> "./path")
        if (clean_cmd.len >= 2 and clean_cmd[1] == ':' and std.ascii.isAlphabetic(clean_cmd[0])) {
            clean_cmd = clean_cmd[2..];
            // If path is now "/./..." strip the leading "/" to make it relative
            if (clean_cmd.len >= 2 and clean_cmd[0] == '/' and clean_cmd[1] == '.') {
                clean_cmd = clean_cmd[1..];
            }
        }
        if (trace.enable_tracing) trace.print("spawnvp resolved: {s}\n", .{clean_cmd});
        args.append(std.heap.page_allocator, clean_cmd) catch return -1;
    }

    if (argv_ptr != 0) {
        const ArgPtrType2 = if (comptime platform.wide_host) u32 else usize;
        const argv2 = @as([*]const ArgPtrType2, @ptrFromInt(argv_ptr));
        var i: usize = 0;
        while (argv2[i] != 0) : (i += 1) {
            if (i > 0) {
                const arg = trace.c_span(@as(usize, argv2[i]));
                var clean_arg: []const u8 = arg;
                if (clean_arg.len >= 2 and clean_arg[0] == '"' and clean_arg[clean_arg.len - 1] == '"') {
                    clean_arg = clean_arg[1 .. clean_arg.len - 1];
                }
                // Copy to host-owned memory: the slice points into guest memory
                // (the parent's heap), which is not stable across the fork/exec
                // used to launch the child.
                const owned = std.heap.page_allocator.dupe(u8, clean_arg) catch return -1;
                args.append(std.heap.page_allocator, owned) catch return -1;
            }
        }
    }

    // Prepare argv array for execvpe
    var c_args: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    for (args.items) |arg| {
        c_args.append(std.heap.page_allocator, @as([*:0]const u8, @ptrCast(arg.ptr))) catch return -1;

        if (arg.len > 1 and arg[0] == '@') {
            const rsp_file = arg[1 .. arg.len - 1]; // remove null char? arg is [*:0] but arg.len doesn't include null
            if (comptime builtin.os.tag == .linux) {
                // Raw open/read/close (std.Io touches TLS in the signal context).
                var nt: [1025]u8 = undefined;
                if (rsp_file.len < nt.len) {
                    @memcpy(nt[0..rsp_file.len], rsp_file);
                    nt[rsp_file.len] = 0;
                    const orc = std.os.linux.open(@ptrCast(&nt), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
                    const ofd: isize = @bitCast(orc);
                    if (ofd >= 0) {
                        var buf: [4096]u8 = undefined;
                        const rr = std.os.linux.read(@intCast(ofd), &buf, buf.len);
                        const rrs: isize = @bitCast(rr);
                        if (rrs > 0) {
                            if (trace.enable_tracing) trace.responseFile(rsp_file, @intCast(rrs));
                        }
                        _ = std.os.linux.close(@intCast(ofd));
                    }
                }
            } else if (std.Io.Dir.cwd().openFile(runtime.io(), rsp_file, .{})) |file| {
                var buf: [4096]u8 = undefined;
                const rb = file.readPositionalAll(runtime.io(), &buf, 0) catch 0;
                if (trace.enable_tracing) trace.responseFile(rsp_file, rb);
                file.close(runtime.io());
            } else |_| {}
        }
    }

    const rt_io = runtime.io();
    var new_env_map = std.process.Environ.Map.init(std.heap.page_allocator);
    defer new_env_map.deinit();

    // An override with different letter-case than the inherited entry must
    // replace it for children: env lookup in the child is first-match, so
    // keeping both entries would hand the child the stale inherited value.
    const overrideShadows = struct {
        fn f(vars: anytype, key: []const u8) bool {
            for (vars.items) |v| {
                if (std.ascii.eqlIgnoreCase(v.key, key)) return true;
            }
            return false;
        }
    }.f;

    var env_i: usize = 0;
    while (msvcrt.global_envp[env_i]) |e_ptr| : (env_i += 1) {
        const e_str = trace.c_span(@intFromPtr(e_ptr));
        if (std.mem.indexOfScalar(u8, e_str, '=')) |eq_idx| {
            const key = e_str[0..eq_idx];
            const val = e_str[eq_idx + 1 ..];
            if (overrideShadows(msvcrt.msvcrt_env_vars, key)) continue;
            new_env_map.put(key, val) catch {};
        }
    }

    for (msvcrt.msvcrt_env_vars.items) |v| {
        // Deleted variables must not reach spawned children.
        if (v.deleted) continue;
        new_env_map.put(v.key, v.val) catch {};
    }

    if (comptime builtin.os.tag == .linux) {
        // Raw fork/execve/waitpid: std.process.spawn goes through std.Io
        // (TLS), which faults inside the compat-mode SIGSEGV dispatch handler.
        // All allocations happen before fork; the child only calls execve.
        var envp_items: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        defer envp_items.deinit(std.heap.page_allocator);
        var env_it = new_env_map.iterator();
        while (env_it.next()) |entry| {
            const kv = std.fmt.allocPrint(std.heap.page_allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
            envp_items.append(std.heap.page_allocator, @as([*:0]const u8, @ptrCast(kv.ptr))) catch {};
        }
        envp_items.append(std.heap.page_allocator, null) catch return -1;
        c_args.append(std.heap.page_allocator, null) catch return -1;

        const pid = std.os.linux.fork();
        const pid_signed: isize = @bitCast(pid);
        if (pid_signed < 0) return -1;
        if (pid_signed == 0) {
            // Child: exec the loader (no allocation, no locks).
            const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(c_args.items.ptr);
            const envp_z: [*:null]const ?[*:0]const u8 = @ptrCast(envp_items.items.ptr);
            _ = std.os.linux.execve(@as([*:0]const u8, @ptrCast(args.items[0].ptr)), argv_z, envp_z);
            _ = std.os.linux.exit(127);
        }
        var status: u32 = 0;
        _ = std.os.linux.waitpid(@intCast(pid), &status, 0);
        if (std.posix.W.IFEXITED(status)) return std.posix.W.EXITSTATUS(status);
        return -1;
    }

    var child = std.process.spawn(rt_io, .{ .argv = args.items }) catch return -1;
    const term = child.wait(rt_io) catch return -1;
    switch (term) {
        .exited => |code| return @intCast(code),
        else => return -1,
    }
}

/// Implementation status: Partially implemented
pub fn getenv(name_ptr: usize) callconv(.c) ?*anyopaque {
    if (name_ptr == 0) return null;
    const name = trace.c_span(name_ptr);

    if (trace.enable_tracing) trace.print("MSVCRT: getenv('{s}')\n", .{name});

    var deleted_shadow = false;
    for (msvcrt.msvcrt_env_vars.items) |v| {
        // Tombstones shadow the inherited value too: a deleted name reads
        // as absent, not as the pre-delete inherited string.
        if (!std.ascii.eqlIgnoreCase(v.key, name)) continue;
        if (v.deleted) {
            deleted_shadow = true;
            break;
        }
        if (trace.enable_tracing) trace.print("MSVCRT: getenv '{s}' -> '{s}'\n", .{ name, log.redactEnvValue(name, v.val) });
        const stub_common = @import("../shared.zig");
        const ptr = @as([*]u8, @ptrCast(stub_common.raw_alloc(v.val.len + 1) orelse return null));
        @memcpy(ptr[0..v.val.len], v.val);
        ptr[v.val.len] = 0;
        return @ptrCast(ptr);
    }

    if (deleted_shadow) {
        if (trace.enable_tracing) trace.print("MSVCRT: getenv '{s}' -> null (deleted)\n", .{name});
        return null;
    }

    // Fallback to global_envp for inherited environment variables
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const env_str = trace.c_span(@intFromPtr(env_ptr));
            if (std.ascii.startsWithIgnoreCase(env_str, name) and env_str.len > name.len and env_str[name.len] == '=') {
                const val = env_str[name.len + 1 ..];
                if (trace.enable_tracing) trace.print("MSVCRT: getenv '{s}' -> '{s}' (inherited)\n", .{ name, log.redactEnvValue(name, val) });
                const stub_common = @import("../shared.zig");
                const ptr = @as([*]u8, @ptrCast(stub_common.raw_alloc(val.len + 1) orelse return null));
                @memcpy(ptr[0..val.len], val);
                ptr[val.len] = 0;
                return @ptrCast(ptr);
            }
        }
    }

    if (trace.enable_tracing) trace.print("MSVCRT: getenv '{s}' -> null\n", .{name});

    // Windows usually expects TMP or TEMP to exist, but if it's missing in the native
    // environment, we'll provide a generic fallback since CLI tools frequently require it.
    if (std.ascii.eqlIgnoreCase(name, "TMP") or std.ascii.eqlIgnoreCase(name, "TEMP")) {
        const tmp_str = ".\x00";
        const stub_common = @import("../shared.zig");
        const ptr = @as([*]u8, @ptrCast(stub_common.raw_alloc(4096) orelse return null));
        @memset(ptr[0..4096], 0);
        @memcpy(ptr[0..tmp_str.len], tmp_str);
        return @ptrCast(ptr);
    }

    return null;
}

/// Implementation status: Partially implemented
pub fn putenv(envstring_ptr: usize) callconv(.c) i32 {
    if (envstring_ptr == 0) return -1;
    const envstring = trace.c_span(envstring_ptr);

    var split_idx: ?usize = null;
    for (0..envstring.len) |i| {
        if (envstring[i] == '=') {
            split_idx = i;
            break;
        }
    }
    if (split_idx == null) {
        if (trace.enable_tracing) trace.print("MSVCRT: _putenv('{s}')\n", .{envstring});
        return -1;
    }
    const idx = split_idx.?;
    const key = envstring[0..idx];
    const val = envstring[idx + 1 ..];
    if (trace.enable_tracing) trace.print("MSVCRT: _putenv('{s}={s}')\n", .{ key, log.redactEnvValue(key, val) });

    const msvcrt_mod = msvcrt;

    // MSVC _putenv contract: "varname=" (empty value) removes varname from
    // the environment.
    if (val.len == 0) {
        for (msvcrt_mod.msvcrt_env_vars.items) |*v| {
            if (!v.deleted and std.ascii.eqlIgnoreCase(v.key, key)) {
                std.heap.page_allocator.free(v.val);
                std.heap.page_allocator.free(v.key);
                v.key = "";
                v.val = "";
                v.deleted = true;
                return 0;
            }
        }
        // Not overridden: tombstone it so inherited entries are shadowed.
        const key_dupe = std.heap.page_allocator.dupe(u8, key) catch return -1;
        msvcrt_mod.msvcrt_env_vars.append(std.heap.page_allocator, .{ .key = key_dupe, .val = "", .deleted = true }) catch return -1;
        return 0;
    }

    // Update any existing override in place; lookups are case-insensitive,
    // so an exact-case-only match would leave a stale duplicate behind.
    for (msvcrt_mod.msvcrt_env_vars.items) |*v| {
        if (std.ascii.eqlIgnoreCase(v.key, key)) {
            if (v.deleted) {
                v.deleted = false;
                const val_dupe = std.heap.page_allocator.dupe(u8, val) catch return -1;
                v.val = val_dupe;
            } else {
                const val_dupe = std.heap.page_allocator.dupe(u8, val) catch return -1;
                std.heap.page_allocator.free(v.val);
                v.val = val_dupe;
            }
            return 0;
        }
    }

    const key_dupe = std.heap.page_allocator.dupe(u8, key) catch return -1;
    const val_dupe = std.heap.page_allocator.dupe(u8, val) catch return -1;
    msvcrt_mod.msvcrt_env_vars.append(std.heap.page_allocator, .{ .key = key_dupe, .val = val_dupe }) catch return -1;
    return 0;
}

/// Implementation status: Partially implemented
pub fn p_pgmptr() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) {
        // Make sure argv[0] is available in guest memory for pgmptr
        ensureGuestArgs();
        // pgmptr = argv[0]
        if (x86_memory.guest_memory) |gmem| {
            if (guest_argv_addr != 0) {
                const first_arg = gmem.read32(guest_argv_addr);
                gmem.write32(g + g_pgmptr, first_arg);
                if (trace.enable_tracing) trace.print("MSVCRT: __p__pgmptr -> 0x{X} (points to string: '{s}')\n", .{ g + g_pgmptr, trace.c_span(first_arg) });
            }
        } else if (guest_argv_addr != 0) {
            // Native x86_64: guest_argv_addr points to the low-4GB argv array.
            // Read argv[0] directly from it.
            const first_arg = @as(*const u32, @ptrFromInt(@as(usize, guest_argv_addr))).*;
            @as(*align(1) u32, @ptrFromInt(@as(usize, g + g_pgmptr))).* = first_arg;
        }
        return g + g_pgmptr;
    }
    if (msvcrt.msvcrt_pgmptr == null and msvcrt.global_argc > 0) {
        if (msvcrt.global_argv[0]) |first| {
            msvcrt.msvcrt_pgmptr = @ptrCast(@constCast(first));
        }
    }
    return @intFromPtr(&msvcrt.msvcrt_pgmptr);
}

/// Implementation status: Stub
pub fn stub_XcptFilter(xcptnum: u32, pxcptinfoptrs: *anyopaque) callconv(.c) i32 {
    _ = xcptnum;
    _ = pxcptinfoptrs;
    return 0;
}

/// Implementation status: Partially implemented
pub fn initterm(pfbegin: [*]const ?*const fn () callconv(.c) void, pfend: [*]const ?*const fn () callconv(.c) void) callconv(.c) void {
    if (comptime !platform.is_native) {
        // On WASM, the function pointers are guest x86 addresses stored as
        // u32 values in the PE's .CRT section. We read them and enqueue for
        // the interpreter to execute after this stub returns.
        const begin_addr = @intFromPtr(pfbegin);
        const end_addr = @intFromPtr(pfend);
        if (trace.enable_tracing) trace.print("MSVCRT: _initterm({x}, {x}) [WASM collect]\n", .{ begin_addr, end_addr });

        const x86_thunks = @import("../../x86/thunks.zig");

        // Each entry is a 4-byte guest function pointer
        var current = begin_addr;
        while (current < end_addr) : (current += 4) {
            const func_ptr = @as(*const u32, @ptrFromInt(current)).*;
            if (func_ptr != 0) {
                if (trace.enable_tracing) trace.print("  -> enqueuing init func at guest {x}\n", .{func_ptr});
                x86_thunks.queueInittermCallback(func_ptr);
            }
        }
        return;
    }
    if (comptime platform.is_x86_64) {
        const compat_thunks = @import("../../x86/compat_thunks.zig");
        var current: usize = @intFromPtr(pfbegin);
        const end: usize = @intFromPtr(pfend);
        while (current < end) : (current += 4) {
            const func_addr = @as(*const u32, @ptrFromInt(current)).*;
            if (func_addr != 0) {
                _ = compat_thunks.callCompat32(func_addr, 0, 0, 0);
            }
        }
        return;
    }
    var p = pfbegin;
    while (@intFromPtr(p) < @intFromPtr(pfend)) : (p += 1) {
        if (p[0]) |func| func();
    }
}

/// _initterm_e — like _initterm but callbacks return int (0 = success)
/// Implementation status: Partially implemented
pub fn initterm_e(pfbegin: [*]const ?*const fn () callconv(.c) i32, pfend: [*]const ?*const fn () callconv(.c) i32) callconv(.c) i32 {
    if (comptime !platform.is_native) {
        // WASM path: collect like initterm
        const begin_addr = @intFromPtr(pfbegin);
        const end_addr = @intFromPtr(pfend);
        if (trace.enable_tracing) trace.print("MSVCRT: _initterm_e({x}, {x}) [WASM collect]\n", .{ begin_addr, end_addr });
        var current = begin_addr;
        while (current < end_addr) : (current += 4) {
            const func_ptr = @as(*const u32, @ptrFromInt(current)).*;
            if (func_ptr != 0) {
                const x86_thunks = @import("../../x86/thunks.zig");
                x86_thunks.queueInittermCallback(func_ptr);
            }
        }
        return 0;
    }
    var p = pfbegin;
    while (@intFromPtr(p) < @intFromPtr(pfend)) : (p += 1) {
        if (p[0]) |func| {
            const ret = func();
            if (ret != 0) return ret;
        }
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn p_fmode() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) return g + g_fmode;
    return @intFromPtr(&msvcrt.msvcrt_fmode);
}

/// Implementation status: Partially implemented
pub fn p_commode() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) return g + g_commode;
    return @intFromPtr(&msvcrt.msvcrt_commode);
}

/// Implementation status: Partially implemented
pub fn p_initenv() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) return g + g_initenv;
    const static_p = struct {
        var p: [*]const ?[*:0]const u8 = undefined;
    };
    static_p.p = msvcrt.global_envp;
    return @intFromPtr(@as(*const anyopaque, @ptrCast(@constCast(&static_p.p))));
}

/// Implementation status: Partially implemented
pub fn p_timezone() callconv(.c) *i32 {
    const g = ensureGuestGlobals();
    if (g != 0) return @ptrFromInt(g + g_timezone);
    return &msvcrt.msvcrt_timezone;
}

/// Implementation status: Partially implemented
pub fn p_daylight() callconv(.c) *i32 {
    const g = ensureGuestGlobals();
    if (g != 0) return @ptrFromInt(g + g_daylight);
    return &msvcrt.msvcrt_daylight;
}

/// Implementation status: Partially implemented
pub fn p_tzname() callconv(.c) *[2]?*anyopaque {
    const g = ensureGuestGlobals();
    if (g != 0) return @ptrFromInt(g + g_tzname);
    return &msvcrt.msvcrt_tzname;
}

/// Implementation status: Stub
pub fn stub_set_app_type(app_type: i32) callconv(.c) void {
    _ = app_type;
}

var wargv_ptrs: [64]?[*:0]u16 = [_]?[*:0]u16{null} ** 64;
var wargv_bufs: [64][512]u16 = undefined;

/// Wide version of __getmainargs for Unicode CRT apps
/// Implementation status: Partially implemented
pub fn wgetmainargs(
    argc: *i32,
    argv: *[*]?[*:0]u16,
    envp: *[*]?[*:0]u8,
    dowildcard: i32,
    startinfo: *anyopaque,
) callconv(.c) i32 {
    _ = dowildcard;
    _ = startinfo;

    // Convert ANSI argv to wide argv
    const n: usize = @intCast(msvcrt.global_argc);
    var i: usize = 0;
    while (i < n and i < 63) : (i += 1) {
        if (msvcrt.global_argv[i]) |arg| {
            const src = trace.c_span(@intFromPtr(arg));
            var j: usize = 0;
            while (j < src.len and j < 511) : (j += 1) {
                wargv_bufs[i][j] = src[j];
            }
            wargv_bufs[i][j] = 0;
            wargv_ptrs[i] = @ptrCast(&wargv_bufs[i]);
        }
    }
    wargv_ptrs[i] = null;

    argc.* = msvcrt.global_argc;
    argv.* = @ptrCast(&wargv_ptrs);
    envp.* = @ptrCast(@constCast(msvcrt.global_envp));

    if (trace.enable_tracing) trace.print("MSVCRT: __wgetmainargs argc={d}\n", .{msvcrt.global_argc});
    return 0;
}

pub fn abort() callconv(.c) void {
    platform.exitProcess(3);
}

pub fn stub_crt_atexit(func: usize) callconv(.c) i32 {
    _ = func;
    return 0; // success
}

test "putenv empty value deletes; getenv sees deletion" {
    const msvcrt_mod = msvcrt;
    const saved_vars = msvcrt_mod.msvcrt_env_vars;
    const saved_env_init = msvcrt_mod.global_env_initialized;
    const saved_envp = msvcrt_mod.global_envp;
    msvcrt_mod.msvcrt_env_vars = .empty;
    msvcrt_mod.global_env_initialized = false;
    defer {
        for (msvcrt_mod.msvcrt_env_vars.items) |v| {
            if (!v.deleted) {
                std.heap.page_allocator.free(v.key);
                std.heap.page_allocator.free(v.val);
            } else if (v.key.len > 0) {
                std.heap.page_allocator.free(v.key);
            }
        }
        msvcrt_mod.msvcrt_env_vars.deinit(std.heap.page_allocator);
        msvcrt_mod.msvcrt_env_vars = saved_vars;
        msvcrt_mod.global_env_initialized = saved_env_init;
        msvcrt_mod.global_envp = saved_envp;
    }

    // Set, then delete via "NAME=" (MSVC _putenv contract).
    var set_buf: [16]u8 = undefined;
    @memcpy(set_buf[0..8], "MYVAR=1\x00");
    set_buf[8] = 0;
    try std.testing.expectEqual(@as(i32, 0), putenv(@intFromPtr(&set_buf)));

    var name_buf: [8]u8 = undefined;
    @memcpy(name_buf[0..5], "MYVAR");
    name_buf[5] = 0;
    // The insert has to be observable, or a putenv that drops the write
    // passes on the return code alone.
    const found = getenv(@intFromPtr(&name_buf)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", std.mem.span(@as([*:0]const u8, @ptrCast(@alignCast(found)))));

    var del_buf: [8]u8 = undefined;
    @memcpy(del_buf[0..6], "MYVAR=");
    del_buf[6] = 0;
    try std.testing.expectEqual(@as(i32, 0), putenv(@intFromPtr(&del_buf)));

    try std.testing.expect(getenv(@intFromPtr(&name_buf)) == null);
}
