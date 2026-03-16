const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");

const io = @import("io.zig");
const platform = @import("../../platform.zig");

// --- Guest-accessible MSVCRT globals (WASM) ---
// On WASM, the x86 interpreter can only read guest memory. The `__p_xxx`
// stubs return pointers to globals, which must be guest virtual addresses.
// We allocate a small block in guest memory and mirror the globals there.
const guest_globals_size: u32 = 256;

// Offsets within the guest globals block
const g_argc: u32 = 0; // i32
const g_argv: u32 = 4; // u32 (pointer to argv array)
const g_envp: u32 = 8; // u32 (pointer to envp array)
const g_fmode: u32 = 12; // u32
const g_commode: u32 = 16; // u16 padded to u32
const g_initenv: u32 = 20; // u32
const g_pgmptr: u32 = 24; // u32
const g_acmdln: u32 = 28; // u32 (pointer to acmdln string)

var guest_globals_addr: u32 = 0; // guest virtual address of globals block

fn ensureGuestGlobals() u32 {
    if (guest_globals_addr != 0) return guest_globals_addr;
    const stub_common = @import("../shared.zig");
    if (stub_common.guest_memory) |gmem| {
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
        return addr;
    }
    return 0;
}

/// Update guest globals after argv/envp are built
/// Implementation status: Partially implemented
pub fn updateGuestGlobals() void {
    if (guest_globals_addr == 0) return;
    const stub_common = @import("../shared.zig");
    if (stub_common.guest_memory) |gmem| {
        gmem.write32(guest_globals_addr + g_argc, @bitCast(msvcrt.global_argc));
        gmem.write32(guest_globals_addr + g_argv, guest_argv_addr);
        gmem.write32(guest_globals_addr + g_envp, guest_envp_addr);
    }
}

/// p_argc
/// Implementation status: Partially implemented
pub fn p_argc() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) return g + g_argc;
    return @intFromPtr(&msvcrt.global_argc);
}

/// p_argv
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

/// p_environ
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
var guest_argv_addr: u32 = 0;
var guest_envp_addr: u32 = 0;
const guest_args_base: u32 = 0x50000000;

fn ensureGuestArgs() void {
    if (guest_args_buf != null) return;

    const plt = @import("../../platform.zig");
    const stub_common = @import("../shared.zig");

    var base_addr: u32 = guest_args_base;
    const buf_size: usize = 256 * 1024; // 256KB

    // On WASM, allocate from the guest heap so addresses are within GuestMemory range
    if (stub_common.guest_memory) |gmem| {
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

    // Copy a null-terminated string into the block, return guest address
    const putStr = struct {
        fn f(buf: []u8, pos: *usize, src: []const u8, base: u32) u32 {
            const guest_addr: u32 = base +% @as(u32, @intCast(pos.*));
            @memcpy(buf[pos.* .. pos.* + src.len], src);
            buf[pos.* + src.len] = 0;
            pos.* += src.len + 1;
            pos.* = (pos.* + 3) & ~@as(usize, 3); // align 4
            return guest_addr;
        }
    }.f;

    // 1) Copy argv strings, record 32-bit addresses
    const argc_val: usize = @intCast(msvcrt.global_argc);
    var argv_str_addrs: [128]u32 = [_]u32{0} ** 128;
    for (0..@min(argc_val, 127)) |i| {
        if (msvcrt.global_argv[i]) |arg_ptr| {
            argv_str_addrs[i] = putStr(block, &gpos, std.mem.span(arg_ptr), base_addr);
        }
    }

    // 2) Build argv array of u32 pointers, null-terminated
    guest_argv_addr = base_addr +% @as(u32, @intCast(gpos));
    for (0..argc_val + 1) |i| {
        const val: u32 = if (i < argc_val) argv_str_addrs[i] else 0;
        @memcpy(block[gpos .. gpos + 4], std.mem.asBytes(&val));
        gpos += 4;
    }

    // 3) Copy envp strings and build envp array
    var envp_str_addrs: [4096]u32 = undefined;
    var envp_str_count: usize = 0;
    {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const src = std.mem.span(env_ptr);
            if (envp_str_count < 4096) {
                envp_str_addrs[envp_str_count] = putStr(block, &gpos, src, base_addr);
                envp_str_count += 1;
            }
        }
    }
    guest_envp_addr = base_addr +% @as(u32, @intCast(gpos));
    for (envp_str_addrs[0..envp_str_count]) |ptr| {
        @memcpy(block[gpos .. gpos + 4], std.mem.asBytes(&ptr));
        gpos += 4;
    }
    // null terminator
    @memset(block[gpos .. gpos + 4], 0);
    gpos += 4;

    if (trace.enable_tracing) trace.print("MSVCRT: built guest args at 0x{X} ({d} bytes)\n", .{ base_addr, gpos });
}

/// getmainargs
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

    // Build guest-accessible argv/envp once (interpreter mode only needs this,
    // but it's harmless on native x86 too — the addresses are still valid).
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

/// exit
/// Implementation status: Partially implemented
pub fn exit(status: i32) callconv(.c) noreturn {
    if (trace.enable_tracing) trace.print("MSVCRT: exit({d}) called from 0x{X}\n", .{ status, @returnAddress() });
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

/// spawnvp
/// Implementation status: Partially implemented
pub fn spawnvp(mode: i32, cmdname_ptr: usize, argv_ptr: usize) callconv(.c) i32 {
    if (comptime !platform.is_native) {
        _ = .{ mode, cmdname_ptr, argv_ptr };
        if (trace.enable_tracing) trace.print("MSVCRT: _spawnvp not supported on this platform\n", .{});
        return -1;
    }
    var args: std.ArrayListUnmanaged([]const u8) = .{};
    defer args.deinit(std.heap.page_allocator);

    if (cmdname_ptr == 0) return -1;
    const cmdname = trace.c_span(cmdname_ptr);
    if (trace.enable_tracing) trace.print("spawnvp cmd: {s}\n", .{cmdname});

    const raw_loader_exe = std.fs.selfExePathAlloc(std.heap.page_allocator) catch "winloader";
    const loader_exe = std.fmt.allocPrint(std.heap.page_allocator, "{s}\x00", .{raw_loader_exe}) catch return -1;

    args.append(std.heap.page_allocator, loader_exe[0 .. loader_exe.len - 1]) catch return -1;
    if (trace.enable_tracing) {
        args.append(std.heap.page_allocator, "--trace") catch return -1;
    }

    if (argv_ptr != 0) {
        const argv = @as([*]const usize, @ptrFromInt(argv_ptr));
        if (argv[0] != 0) {
            const arg0 = trace.c_span(argv[0]);
            var clean_arg0 = std.heap.page_allocator.dupe(u8, arg0) catch return -1;
            std.mem.replaceScalar(u8, clean_arg0, '/', '\\');
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
        const argv = @as([*]const usize, @ptrFromInt(argv_ptr));
        var i: usize = 0;
        while (argv[i] != 0) : (i += 1) {
            if (i > 0) {
                const arg = trace.c_span(argv[i]);
                var clean_arg: []const u8 = arg;
                if (clean_arg.len >= 2 and clean_arg[0] == '"' and clean_arg[clean_arg.len - 1] == '"') {
                    clean_arg = clean_arg[1 .. clean_arg.len - 1];
                }
                args.append(std.heap.page_allocator, clean_arg) catch return -1;
            }
        }
    }

    // Prepare argv array for execvpe
    var c_args: std.ArrayListUnmanaged(?[*:0]const u8) = .{};
    for (args.items) |arg| {
        c_args.append(std.heap.page_allocator, @as([*:0]const u8, @ptrCast(arg.ptr))) catch return -1;

        if (arg.len > 1 and arg[0] == '@') {
            const rsp_file = arg[1 .. arg.len - 1]; // remove null char? arg is [*:0] but arg.len doesn't include null
            if (std.fs.cwd().openFile(rsp_file, .{})) |file| {
                var buf: [4096]u8 = undefined;
                const rb = file.readAll(&buf) catch 0;
                if (trace.enable_tracing) trace.print("RESPONSE FILE DUMP:\n{s}\n---END DUMP---\n", .{buf[0..rb]});
                file.close();
            } else |_| {}
        }
    }

    var new_env_map = std.process.EnvMap.init(std.heap.page_allocator);
    defer new_env_map.deinit();

    var env_i: usize = 0;
    while (msvcrt.global_envp[env_i]) |e_ptr| : (env_i += 1) {
        const e_str = trace.c_span(@intFromPtr(e_ptr));
        if (std.mem.indexOfScalar(u8, e_str, '=')) |eq_idx| {
            const key = e_str[0..eq_idx];
            const val = e_str[eq_idx + 1 ..];
            new_env_map.put(key, val) catch {};
        }
    }

    for (msvcrt.msvcrt_env_vars.items) |v| {
        new_env_map.put(v.key, v.val) catch {};
    }

    var child = std.process.Child.init(args.items, std.heap.page_allocator);
    child.env_map = &new_env_map;
    const term = child.spawnAndWait() catch return -1;
    switch (term) {
        .Exited => |code| return @intCast(code),
        else => return -1,
    }
}

/// getenv
/// Implementation status: Partially implemented
pub fn getenv(name_ptr: usize) callconv(.c) ?*anyopaque {
    if (name_ptr == 0) return null;
    const name = trace.c_span(name_ptr);

    if (trace.enable_tracing) trace.print("MSVCRT: getenv('{s}')\n", .{name});

    for (msvcrt.msvcrt_env_vars.items) |v| {
        if (std.ascii.eqlIgnoreCase(v.key, name)) {
            if (trace.enable_tracing) trace.print("MSVCRT: getenv '{s}' -> '{s}'\n", .{ name, v.val });
            const stub_common = @import("../shared.zig");
            const ptr = @as([*]u8, @ptrCast(stub_common.raw_alloc(v.val.len + 1) orelse return null));
            @memcpy(ptr[0..v.val.len], v.val);
            ptr[v.val.len] = 0;
            return @ptrCast(ptr);
        }
    }

    // Fallback to global_envp for inherited environment variables
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const env_str = trace.c_span(@intFromPtr(env_ptr));
            if (std.ascii.startsWithIgnoreCase(env_str, name) and env_str.len > name.len and env_str[name.len] == '=') {
                const val = env_str[name.len + 1 ..];
                if (trace.enable_tracing) trace.print("MSVCRT: getenv '{s}' -> '{s}' (inherited)\n", .{ name, val });
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
        const tmp_str = "tmp\x00";
        const stub_common = @import("../shared.zig");
        const ptr = @as([*]u8, @ptrCast(stub_common.raw_alloc(4096) orelse return null));
        @memset(ptr[0..4096], 0);
        @memcpy(ptr[0..tmp_str.len], tmp_str);
        return @ptrCast(ptr);
    }

    return null;
}

/// putenv
/// Implementation status: Partially implemented
pub fn putenv(envstring_ptr: usize) callconv(.c) i32 {
    if (envstring_ptr == 0) return -1;
    const envstring = trace.c_span(envstring_ptr);
    if (trace.enable_tracing) trace.print("MSVCRT: _putenv('{s}')\n", .{envstring});

    var split_idx: ?usize = null;
    for (0..envstring.len) |i| {
        if (envstring[i] == '=') {
            split_idx = i;
            break;
        }
    }
    if (split_idx == null) return -1;
    const idx = split_idx.?;
    const key = envstring[0..idx];
    const val = envstring[idx + 1 ..];

    const key_dupe = std.heap.page_allocator.dupe(u8, key) catch return -1;
    const val_dupe = std.heap.page_allocator.dupe(u8, val) catch return -1;

    for (msvcrt.msvcrt_env_vars.items) |*v| {
        if (std.mem.eql(u8, v.key, key_dupe)) {
            v.val = val_dupe;
            return 0;
        }
    }
    msvcrt.msvcrt_env_vars.append(std.heap.page_allocator, .{ .key = key_dupe, .val = val_dupe }) catch return -1;
    return 0;
}

/// p_pgmptr
/// Implementation status: Partially implemented
pub fn p_pgmptr() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) {
        // Make sure argv[0] is available in guest memory for pgmptr
        ensureGuestArgs();
        // pgmptr = argv[0]
        const stub_common = @import("../shared.zig");
        if (stub_common.guest_memory) |gmem| {
            if (guest_argv_addr != 0) {
                const first_arg = gmem.read32(guest_argv_addr);
                gmem.write32(g + g_pgmptr, first_arg);
            }
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

/// stub_XcptFilter
/// Implementation status: Stub
pub fn stub_XcptFilter(xcptnum: u32, pxcptinfoptrs: *anyopaque) callconv(.c) i32 {
    _ = xcptnum;
    _ = pxcptinfoptrs;
    return 0;
}

/// Pending init function callbacks for WASM — shared through stub_common
/// so x86/execute.zig can read them without importing msvcrt directly.
const initterm_state = struct {
    const sc = @import("../shared.zig");
    fn callbacks() *[64]u32 {
        return &sc.pending_initterm_callbacks;
    }
    fn count() *usize {
        return &sc.pending_initterm_count;
    }
};

/// initterm
/// Implementation status: Partially implemented
pub fn initterm(pfbegin: [*]const ?*const fn () callconv(.c) void, pfend: [*]const ?*const fn () callconv(.c) void) callconv(.c) void {
    if (comptime !platform.is_native) {
        // On WASM, the function pointers are guest x86 addresses stored as
        // u32 values in the PE's .CRT section. We read them and enqueue for
        // the interpreter to execute after this stub returns.
        const begin_addr = @intFromPtr(pfbegin);
        const end_addr = @intFromPtr(pfend);
        if (trace.enable_tracing) trace.print("MSVCRT: _initterm({x}, {x}) [WASM collect]\n", .{ begin_addr, end_addr });

        // Each entry is a 4-byte guest function pointer
        var current = begin_addr;
        while (current < end_addr) : (current += 4) {
            const func_ptr = @as(*const u32, @ptrFromInt(current)).*;
            if (func_ptr != 0) {
                if (trace.enable_tracing) trace.print("  -> enqueuing init func at guest {x}\n", .{func_ptr});
                if (initterm_state.count().* < 64) {
                    initterm_state.callbacks().*[initterm_state.count().*] = func_ptr;
                    initterm_state.count().* += 1;
                }
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
                if (initterm_state.count().* < 64) {
                    initterm_state.callbacks().*[initterm_state.count().*] = func_ptr;
                    initterm_state.count().* += 1;
                }
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

/// p_fmode
/// Implementation status: Partially implemented
pub fn p_fmode() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) return g + g_fmode;
    return @intFromPtr(&msvcrt.msvcrt_fmode);
}

/// p_commode
/// Implementation status: Partially implemented
pub fn p_commode() callconv(.c) usize {
    const g = ensureGuestGlobals();
    if (g != 0) return g + g_commode;
    return @intFromPtr(&msvcrt.msvcrt_commode);
}

/// p_initenv
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

/// p_timezone
/// Implementation status: Partially implemented
pub fn p_timezone() callconv(.c) *i32 {
    return &msvcrt.msvcrt_timezone;
}

/// p_daylight
/// Implementation status: Partially implemented
pub fn p_daylight() callconv(.c) *i32 {
    return &msvcrt.msvcrt_daylight;
}

/// p_tzname
/// Implementation status: Partially implemented
pub fn p_tzname() callconv(.c) *[2]?*anyopaque {
    return &msvcrt.msvcrt_tzname;
}

/// stub_set_app_type
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
