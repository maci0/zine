/// MSVCRT path utilities: _splitpath, _makepath, _fullpath,
/// _searchenv, _getcwd, _tempnam, _mktemp.
const std = @import("std");
const trace = @import("../../trace.zig");

// --- Path utilities ---

pub fn mktemp(template: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (template) |t| {
        const slice = @as([*]u8, @ptrCast(t));
        var i: usize = 0;
        if (slice[0] == 't' and slice[1] == 'm' and slice[2] == 'p' and slice[3] == '\\') {
            slice[0] = 't';
            slice[1] = 'm';
            slice[2] = 'p';
            slice[3] = '_';
        }

        while (slice[i] != 0 and i < 4096) {
            if (slice[i] == 'X') slice[i] = '1';
            i += 1;
        }
        if (trace.enable_tracing) trace.print("MSVCRT: _mktemp -> '{s}'\n", .{slice[0..i]});
        return t;
    }
    return null;
}

pub fn splitpath(path_ptr: usize, drive: usize, dir: usize, fname: usize, ext: usize) callconv(.c) void {
    if (path_ptr < 0x10000) return;
    const path = trace.c_span(path_ptr);

    var drive_len: usize = 0;
    if (path.len >= 2 and path[1] == ':') {
        drive_len = 2;
    }

    var de: usize = drive_len;
    var es: usize = path.len;
    for (drive_len..path.len) |i| {
        if (path[i] == '/' or path[i] == '\\') de = i + 1;
        if (path[i] == '.') es = i;
    }
    if (es < de) es = path.len;

    if (drive != 0) {
        if (drive_len > 0) {
            @memcpy(@as([*]u8, @ptrFromInt(drive))[0..drive_len], path[0..drive_len]);
        }
        @as([*]u8, @ptrFromInt(drive))[drive_len] = 0;
    }
    if (dir != 0) {
        const dir_len = de - drive_len;
        if (dir_len > 0) {
            @memcpy(@as([*]u8, @ptrFromInt(dir))[0..dir_len], path[drive_len..de]);
        }
        @as([*]u8, @ptrFromInt(dir))[dir_len] = 0;
    }
    if (fname != 0) {
        const fname_len = es - de;
        if (fname_len > 0) {
            @memcpy(@as([*]u8, @ptrFromInt(fname))[0..fname_len], path[de..es]);
        }
        @as([*]u8, @ptrFromInt(fname))[fname_len] = 0;
    }
    if (ext != 0) {
        const ext_len = path.len - es;
        if (ext_len > 0) {
            @memcpy(@as([*]u8, @ptrFromInt(ext))[0..ext_len], path[es..path.len]);
        }
        @as([*]u8, @ptrFromInt(ext))[ext_len] = 0;
    }
}

pub fn makepath(path_ptr: usize, drive: usize, dir: usize, fname: usize, ext: usize) callconv(.c) void {
    if (path_ptr == 0) return;
    const path = @as([*]u8, @ptrFromInt(path_ptr));
    var len: usize = 0;
    if (drive != 0) {
        const s = trace.c_span(drive);
        if (s.len > 0) {
            @memcpy(path[len .. len + s.len], s);
            len += s.len;
            if (s[s.len - 1] != ':') {
                path[len] = ':';
                len += 1;
            }
        }
    }
    if (dir != 0) {
        const s = trace.c_span(dir);
        if (s.len > 0) {
            @memcpy(path[len .. len + s.len], s);
            len += s.len;
            if (s[s.len - 1] != '/' and s[s.len - 1] != '\\') {
                path[len] = '\\';
                len += 1;
            }
        }
    }
    if (fname != 0) {
        const s = trace.c_span(fname);
        @memcpy(path[len .. len + s.len], s);
        len += s.len;
    }
    if (ext != 0) {
        const s = trace.c_span(ext);
        if (s.len > 0) {
            if (s[0] != '.') {
                path[len] = '.';
                len += 1;
            }
            @memcpy(path[len .. len + s.len], s);
            len += s.len;
        }
    }
    path[len] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _makepath -> {s}\n", .{path[0..len]});
}

pub fn fullpath(abs_buf: usize, rel: usize, max: usize) callconv(.c) usize {
    if (rel == 0) return 0;
    const s = trace.c_span(rel);
    var dp = abs_buf;
    if (dp == 0) {
        const alloc_size = if (max > 0) max else 4096;
        const stub_common = @import("../stub_common.zig");
        const p = stub_common.raw_alloc(alloc_size) orelse return 0;
        dp = @intFromPtr(p);
    }
    const buf_size = if (max > 0) max else 4096;
    const cl = @min(s.len, buf_size - 1);
    @memcpy(@as([*]u8, @ptrFromInt(dp))[0..cl], s[0..cl]);
    @as([*]u8, @ptrFromInt(dp))[cl] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _fullpath(abs={x}, rel='{s}', max={d}) -> {x}\n", .{ abs_buf, s, max, dp });
    return dp;
}

// --- _searchenv / _getcwd ---

pub fn searchenv(filename_ptr: usize, varname_ptr: usize, result_ptr: usize) callconv(.c) void {
    const filename = if (filename_ptr != 0) trace.c_span(filename_ptr) else "";
    const varname = if (varname_ptr != 0) trace.c_span(varname_ptr) else "";

    if (trace.enable_tracing) trace.print("MSVCRT: _searchenv('{s}', '{s}')\n", .{ filename, varname });

    if (result_ptr == 0) return;
    const result_buf = @as([*]u8, @ptrFromInt(result_ptr));
    result_buf[0] = 0; // default to empty

    const env_val_ptr = @import("process.zig").getenv(varname_ptr);
    if (env_val_ptr == null) return;
    const env_val = trace.c_span(@intFromPtr(env_val_ptr.?));

    var it = std.mem.splitScalar(u8, env_val, ';');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;

        var full_path: [1024]u8 = undefined;
        var full_len: usize = 0;
        @memcpy(full_path[full_len .. full_len + dir.len], dir);
        full_len += dir.len;
        if (full_path[full_len - 1] != '\\' and full_path[full_len - 1] != '/') {
            full_path[full_len] = '\\';
            full_len += 1;
        }
        @memcpy(full_path[full_len .. full_len + filename.len], filename);
        full_len += filename.len;
        full_path[full_len] = 0;

        const file_mod = @import("file.zig");
        if (file_mod.access(@intFromPtr(&full_path), 0) == 0) {
            @memcpy(result_buf[0..full_len], full_path[0..full_len]);
            result_buf[full_len] = 0;
            if (trace.enable_tracing) trace.print("  -> found at '{s}'\n", .{full_path[0..full_len]});
            return;
        }
    }
    if (trace.enable_tracing) trace.print("MSVCRT: _searchenv -> NOT FOUND\n", .{});
}

pub fn getcwd(buffer_ptr: usize, maxlen: i32) callconv(.c) ?*anyopaque {
    const path = std.process.getCwdAlloc(std.heap.page_allocator) catch return null;
    defer std.heap.page_allocator.free(path);

    if (buffer_ptr != 0) {
        if (path.len >= maxlen) return null;
        const buf = @as([*]u8, @ptrFromInt(buffer_ptr));
        @memcpy(buf[0..path.len], path);
        std.mem.replaceScalar(u8, buf[0..path.len], '/', '\\');
        buf[path.len] = 0;
        return @ptrFromInt(buffer_ptr);
    } else {
        const stub_common = @import("../stub_common.zig");
        const raw = stub_common.raw_alloc(path.len + 1) orelse return null;
        const ptr = @as([*]u8, @ptrCast(raw));
        @memcpy(ptr[0..path.len], path);
        std.mem.replaceScalar(u8, ptr[0..path.len], '/', '\\');
        ptr[path.len] = 0;
        return raw;
    }
}

// --- tempnam ---

var tempnam_counter: u32 = 0;

pub fn tempnam(dir_ptr: usize, prefix_ptr: usize) callconv(.c) usize {
    const prefix = if (prefix_ptr != 0) trace.c_span(prefix_ptr) else "tmp";
    _ = dir_ptr;

    const count = @atomicRmw(u32, &tempnam_counter, .Add, 1, .monotonic);

    var name_buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}_{d}.tmp\x00", .{ prefix, count }) catch "winloader_tmp.tmp\x00";

    const alloc_ptr = std.heap.page_allocator.alloc(u8, name.len) catch return 0;
    @memcpy(alloc_ptr[0..name.len], name[0..name.len]);
    if (trace.enable_tracing) trace.print("MSVCRT: _tempnam -> '{s}'\n", .{alloc_ptr[0 .. name.len - 1]});

    if (std.fs.cwd().createFile(alloc_ptr[0 .. name.len - 1], .{})) |file| {
        file.close();
    } else |_| {}

    return @intFromPtr(alloc_ptr.ptr);
}
