const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const platform = @import("../../platform.zig");
const io = @import("io.zig");

const string = @import("string.zig");
const process = @import("process.zig");
const mem = @import("mem.zig");
const math = @import("math.zig");
const misc = @import("misc.zig");

pub fn stub_p_argc() callconv(.c) *i32 {
    return &msvcrt.global_argc;
}

pub fn stub_p_argv() callconv(.c) *[*]?[*:0]u8 {
    return &msvcrt.global_argv;
}

pub fn stub_p_environ() callconv(.c) *[*]const ?[*:0]const u8 {
    const static_p = struct {
        var p: [*]const ?[*:0]const u8 = undefined;
    };
    static_p.p = msvcrt.global_envp;
    return @ptrCast(@constCast(&static_p.p));
}

// --- Process & Environment ---

pub fn stub_getmainargs(
    argc: *i32,
    argv: *[*]?[*:0]u8,
    envp: *[*]?[*:0]u8,
    dowildcard: i32,
    startinfo: *anyopaque,
) callconv(.c) i32 {
    _ = dowildcard;
    _ = startinfo;
    argc.* = msvcrt.global_argc;
    argv.* = msvcrt.global_argv;
    envp.* = @ptrCast(@constCast(msvcrt.global_envp));

    if (trace.enable_tracing) {
        trace.print("MSVCRT: __getmainargs argc={d}\n", .{msvcrt.global_argc});
        var i: usize = 0;
        while (i < msvcrt.global_argc) : (i += 1) {
            if (msvcrt.global_argv[i]) |arg| {
                trace.print("  argv[{d}] = '{s}'\n", .{ i, trace.c_span(@intFromPtr(arg)) });
            }
        }
    }
    return 0;
}

pub fn stub_exit(status: i32) callconv(.c) noreturn {
    if (trace.enable_tracing) trace.print("MSVCRT: exit({d}) called from 0x{X}\n", .{ status, @returnAddress() });
    platform.exitProcess(@intCast(@as(u32, @bitCast(status)) & 0xFF));
}

pub fn stub_spawnvp(mode: i32, cmdname_ptr: usize, argv_ptr: usize) callconv(.c) i32 {
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
    
    args.append(std.heap.page_allocator, loader_exe[0..loader_exe.len - 1]) catch return -1;
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

    if (argv_ptr != 0) {        const argv = @as([*]const usize, @ptrFromInt(argv_ptr));
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
            const rsp_file = arg[1..arg.len - 1]; // remove null char? arg is [*:0] but arg.len doesn't include null
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

pub fn stub_getenv(name_ptr: usize) callconv(.c) ?*anyopaque {
    if (name_ptr == 0) return null;
    const name = trace.c_span(name_ptr);
    
    if (trace.enable_tracing) trace.print("MSVCRT: getenv('{s}')\n", .{name});

    for (msvcrt.msvcrt_env_vars.items) |v| {
        if (std.ascii.eqlIgnoreCase(v.key, name)) {
            if (trace.enable_tracing) trace.print("MSVCRT: getenv '{s}' -> '{s}'\n", .{name, v.val});
            const ptr = std.heap.page_allocator.alloc(u8, v.val.len + 1) catch return null;
            @memcpy(ptr[0..v.val.len], v.val);
            ptr[v.val.len] = 0;
            return ptr.ptr;
        }
    }

    // Fallback to global_envp for inherited environment variables
    if (msvcrt.global_env_initialized) {
        var i: usize = 0;
        while (msvcrt.global_envp[i]) |env_ptr| : (i += 1) {
            const env_str = trace.c_span(@intFromPtr(env_ptr));
            if (std.ascii.startsWithIgnoreCase(env_str, name) and env_str.len > name.len and env_str[name.len] == '=') {
                const val = env_str[name.len + 1 ..];
                if (trace.enable_tracing) trace.print("MSVCRT: getenv '{s}' -> '{s}' (inherited)\n", .{name, val});
                const ptr = std.heap.page_allocator.alloc(u8, val.len + 1) catch return null;
                @memcpy(ptr[0..val.len], val);
                ptr[val.len] = 0;
                return ptr.ptr;
            }
        }
    }

    if (trace.enable_tracing) trace.print("MSVCRT: getenv '{s}' -> null\n", .{name});

    // Windows usually expects TMP or TEMP to exist, but if it's missing in the native
    // environment, we'll provide a generic fallback since CLI tools frequently require it.
    if (std.ascii.eqlIgnoreCase(name, "TMP") or std.ascii.eqlIgnoreCase(name, "TEMP")) {
        const tmp_str = "tmp\x00";
        const ptr = std.heap.page_allocator.alloc(u8, 4096) catch return null;
        @memset(ptr, 0);
        @memcpy(ptr[0..tmp_str.len], tmp_str);
        return ptr.ptr;
    }

    return null;
}

pub fn stub_putenv(envstring_ptr: usize) callconv(.c) i32 {
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

pub fn stub_p_pgmptr() callconv(.c) *?*anyopaque {
    if (msvcrt.msvcrt_pgmptr == null and msvcrt.global_argc > 0) {
        if (msvcrt.global_argv[0]) |first| {
            msvcrt.msvcrt_pgmptr = @ptrCast(@constCast(first));
        }
    }
    return &msvcrt.msvcrt_pgmptr;
}

pub fn stub_XcptFilter(xcptnum: u32, pxcptinfoptrs: *anyopaque) callconv(.c) i32 {
    _ = xcptnum;
    _ = pxcptinfoptrs;
    return 0;
}

pub fn stub_initterm(pfbegin: [*]const ?*const fn () callconv(.c) void, pfend: [*]const ?*const fn () callconv(.c) void) callconv(.c) void {
    var p = pfbegin;
    while (@intFromPtr(p) < @intFromPtr(pfend)) : (p += 1) {
        if (p[0]) |func| func();
    }
}

pub fn stub_p_fmode() callconv(.c) *u32 {
    return &msvcrt.msvcrt_fmode;
}

pub fn stub_p_commode() callconv(.c) *u16 {
    return &msvcrt.msvcrt_commode;
}

pub fn stub_p_initenv() callconv(.c) *[*]const ?[*:0]const u8 {
    const static_p = struct {
        var p: [*]const ?[*:0]const u8 = undefined;
    };
    static_p.p = msvcrt.global_envp;
    return @ptrCast(@constCast(&static_p.p));
}

pub fn stub_p_timezone() callconv(.c) *i32 {
    return &msvcrt.msvcrt_timezone;
}

pub fn stub_p_daylight() callconv(.c) *i32 {
    return &msvcrt.msvcrt_daylight;
}

pub fn stub_p_tzname() callconv(.c) *[2]?*anyopaque {
    return &msvcrt.msvcrt_tzname;
}

pub fn stub_set_app_type(app_type: i32) callconv(.c) void {
    _ = app_type;
}

// Wide version of __getmainargs for Unicode CRT apps
var wargv_ptrs: [64]?[*:0]u16 = [_]?[*:0]u16{null} ** 64;
var wargv_bufs: [64][512]u16 = undefined;

pub fn stub_wgetmainargs(
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
