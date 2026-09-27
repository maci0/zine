const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");

/// MSVCRT path utilities: _splitpath, _makepath, _fullpath,
/// _searchenv, _getcwd, _tempnam, _mktemp.
/// --- Path utilities ---
/// _mktemp: Replace trailing 'X' characters in template with unique alphanumeric chars.
/// On Windows, the last 6 positions XXXXXX are replaced with digit+alpha combinations.
/// Implementation status: Partially implemented (counter-based, not checking file existence)
var mktemp_counter: u32 = 0;
pub fn mktemp(template: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (template) |t| {
        const slice = @as([*]u8, @ptrCast(t));

        // Find length and convert tmp\ prefix to tmp_ for posix compatibility
        var len: usize = 0;
        while (slice[len] != 0 and len < 4096) : (len += 1) {}

        // Convert backslash-based tmp path prefix to underscore for POSIX
        if (len >= 4 and slice[0] == 't' and slice[1] == 'm' and slice[2] == 'p' and slice[3] == '\\') {
            slice[3] = '_';
        }

        // Find the rightmost run of 'X' characters
        var x_start: usize = len;
        while (x_start > 0 and slice[x_start - 1] == 'X') : (x_start -= 1) {}
        const x_count = len - x_start;

        if (x_count > 0) {
            // Generate unique suffix from counter
            const count = @atomicRmw(u32, &mktemp_counter, .Add, 1, .monotonic);
            const chars = "0123456789abcdefghijklmnopqrstuvwxyz";
            var val = count;
            var i: usize = 0;
            while (i < x_count) : (i += 1) {
                // Fill from right to left
                const pos = len - 1 - i;
                slice[pos] = chars[val % chars.len];
                val /= @intCast(chars.len);
            }
        }

        // Also replace backslashes with forward slashes for posix file operations
        for (0..len) |i| {
            if (slice[i] == '\\') slice[i] = '/';
        }

        if (trace.enable_tracing) trace.print("MSVCRT: _mktemp -> '{s}'\n", .{slice[0..len]});
        return t;
    }
    return null;
}

/// Implementation status: Partially implemented
pub fn splitpath(path: [*:0]const u8, drv_out: ?[*]u8, dir_out: ?[*]u8, fname_out: ?[*]u8, ext_out: ?[*]u8) callconv(.c) void {
    const s = std.mem.span(path);
    if (trace.enable_tracing) trace.print("MSVCRT: _splitpath('{s}')\n", .{s});
    var drive_len: usize = 0;
    if (s.len >= 2 and s[1] == ':') drive_len = 2;

    var de: usize = drive_len;
    var es: usize = s.len;
    for (drive_len..s.len) |i| {
        if (s[i] == '/' or s[i] == '\\') de = i + 1;
        if (s[i] == '.') es = i;
    }
    if (es < de) es = s.len;

    if (drv_out) |d| {
        if (drive_len > 0) @memcpy(d[0..drive_len], s[0..drive_len]);
        d[drive_len] = 0;
        if (trace.enable_tracing) trace.print("MSVCRT: _splitpath drv='{s}'\n", .{d[0..drive_len]});
    }
    if (dir_out) |d| {
        const dir_len = de - drive_len;
        if (dir_len > 0) @memcpy(d[0..dir_len], s[drive_len..de]);
        d[dir_len] = 0;
        if (trace.enable_tracing) trace.print("MSVCRT: _splitpath dir='{s}'\n", .{d[0..dir_len]});
    }
    if (fname_out) |d| {
        const fname_len = es - de;
        if (fname_len > 0) @memcpy(d[0..fname_len], s[de..es]);
        d[fname_len] = 0;
        if (trace.enable_tracing) trace.print("MSVCRT: _splitpath fname='{s}'\n", .{d[0..fname_len]});
    }
    if (ext_out) |d| {
        const ext_len = s.len - es;
        if (ext_len > 0) @memcpy(d[0..ext_len], s[es..s.len]);
        d[ext_len] = 0;
        if (trace.enable_tracing) trace.print("MSVCRT: _splitpath ext='{s}'\n", .{d[0..ext_len]});
    }
}

/// Implementation status: Partially implemented
pub fn makepath(out: [*]u8, drv: ?[*:0]const u8, dir: ?[*:0]const u8, fname: ?[*:0]const u8, ext: ?[*:0]const u8) callconv(.c) void {
    if (trace.enable_tracing) {
        const d_str = if (drv) |d| std.mem.span(d) else "null";
        const dir_str = if (dir) |d| std.mem.span(d) else "null";
        const f_str = if (fname) |d| std.mem.span(d) else "null";
        const e_str = if (ext) |d| std.mem.span(d) else "null";
        trace.print("MSVCRT: _makepath(drv='{s}', dir='{s}', fname='{s}', ext='{s}')\n", .{ d_str, dir_str, f_str, e_str });
    }
    var len: usize = 0;
    if (drv) |d| {
        const s = std.mem.span(d);
        if (s.len > 0) {
            @memcpy(out[len..][0..s.len], s);
            len += s.len;
            if (s[s.len - 1] != ':') {
                out[len] = ':';
                len += 1;
            }
        }
    }
    if (dir) |d| {
        const s = std.mem.span(d);
        if (s.len > 0) {
            @memcpy(out[len..][0..s.len], s);
            len += s.len;
            if (s[s.len - 1] != '/' and s[s.len - 1] != '\\') {
                out[len] = '\\';
                len += 1;
            }
        }
    }
    if (fname) |d| {
        const s = std.mem.span(d);
        @memcpy(out[len..][0..s.len], s);
        len += s.len;
    }
    if (ext) |d| {
        const s = std.mem.span(d);
        if (s.len > 0) {
            if (s[0] != '.') {
                out[len] = '.';
                len += 1;
            }
            @memcpy(out[len..][0..s.len], s);
            len += s.len;
        }
    }
    out[len] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _makepath -> {s}\n", .{out[0..len]});
}

/// Implementation status: Partially implemented
pub fn fullpath(abs_buf: usize, rel: usize, max: usize) callconv(.c) usize {
    if (rel == 0) return 0;
    const s = trace.c_span(rel);
    var dp = abs_buf;
    var dp_host: usize = 0;
    if (dp == 0) {
        const alloc_size = if (max > 0) max else 4096;
        const stub_common = @import("../shared.zig");
        const p = stub_common.raw_alloc(alloc_size) orelse return 0;
        dp = @intFromPtr(p);
        dp_host = dp; // raw_alloc returns a host pointer already
    } else {
        // abs_buf is a GUEST virtual address (usize param — the comptime
        // thunk does not auto-translate). Without this, the result was
        // written to the raw guest VA in linear memory and the caller read
        // back an empty name → "fatal error C1074: 'IDB' is illegal
        // extension for PDB file".
        dp_host = trace.addr(dp);
    }
    const buf_size = if (max > 0) max else 4096;
    const cl = @min(s.len, buf_size - 1);
    @memcpy(@as([*]u8, @ptrFromInt(dp_host))[0..cl], s[0..cl]);
    @as([*]u8, @ptrFromInt(dp_host))[cl] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _fullpath(abs={x}, rel='{s}', max={d}) -> {x}\n", .{ abs_buf, s, max, dp });
    return dp;
}

/// --- _searchenv / _getcwd ---
/// Implementation status: Partially implemented
pub fn searchenv(filename_ptr: usize, varname_ptr: usize, result_ptr: usize) callconv(.c) void {
    const filename = if (filename_ptr != 0) trace.c_span(filename_ptr) else "";
    const varname = if (varname_ptr != 0) trace.c_span(varname_ptr) else "";

    if (trace.enable_tracing) trace.print("MSVCRT: _searchenv('{s}', '{s}')\n", .{ filename, varname });

    if (result_ptr == 0) return;
    const result_buf = @as([*]u8, @ptrFromInt(trace.addr(result_ptr)));
    result_buf[0] = 0; // default to empty

    const env_val_ptr = @import("process.zig").getenv(varname_ptr);
    if (env_val_ptr == null) return;
    // getenv is called directly (not through the thunk layer), so it returns
    // a HOST pointer — do NOT run it through trace.c_span, which expects a
    // guest VA and would re-translate the host pointer into garbage.
    const env_val = std.mem.span(@as([*:0]const u8, @ptrCast(env_val_ptr.?)));

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

        // full_path is a HOST buffer on the stub stack — its address can
        // numerically fall inside the guest VA range, so passing it through
        // the guest-facing access() stub (which c_spans/translates its arg)
        // would re-translate it into garbage. Call the POSIX-level access
        // directly: it takes a host path and does its own toHostPath.
        const posix_fs = @import("posix_fs.zig");
        if (posix_fs.access(@as([*:0]const u8, @ptrCast(&full_path)), 0) == 0) {
            @memcpy(result_buf[0..full_len], full_path[0..full_len]);
            result_buf[full_len] = 0;
            if (trace.enable_tracing) trace.print("  -> found at '{s}'\n", .{full_path[0..full_len]});
            return;
        }
    }
    if (trace.enable_tracing) trace.print("MSVCRT: _searchenv -> NOT FOUND\n", .{});
}

/// Implementation status: Partially implemented
pub fn getcwd(buffer_ptr: usize, maxlen: i32) callconv(.c) ?*anyopaque {
    const host_io = @import("../host_io.zig");
    var cwd_buf: [1024]u8 = undefined;
    const cwd_len = host_io.getCwd(&cwd_buf); // raw syscall on Linux (TLS-safe)
    if (cwd_len == 0) return null;
    const path = cwd_buf[0..cwd_len];

    if (buffer_ptr != 0) {
        if (path.len >= maxlen) return null;
        const host_ptr = trace.addr(buffer_ptr);
        const buf = @as([*]u8, @ptrFromInt(host_ptr));
        @memcpy(buf[0..path.len], path);
        std.mem.replaceScalar(u8, buf[0..path.len], '/', '\\');
        buf[path.len] = 0;
        return @ptrFromInt(host_ptr);
    } else {
        const stub_common = @import("../shared.zig");
        const raw = stub_common.raw_alloc(path.len + 1) orelse return null;
        const ptr = @as([*]u8, @ptrCast(raw));
        @memcpy(ptr[0..path.len], path);
        std.mem.replaceScalar(u8, ptr[0..path.len], '/', '\\');
        ptr[path.len] = 0;
        return raw;
    }
}

var tempnam_counter: u32 = 0;

/// --- tempnam ---
/// Implementation status: Partially implemented
pub fn tempnam(dir_ptr: usize, prefix_ptr: usize) callconv(.c) usize {
    const prefix = if (prefix_ptr != 0) trace.c_span(prefix_ptr) else "tmp";
    _ = dir_ptr;

    const count = @atomicRmw(u32, &tempnam_counter, .Add, 1, .monotonic);

    var name_buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}_{d}.tmp\x00", .{ prefix, count }) catch "zine_tmp.tmp\x00";

    const alloc_ptr = std.heap.page_allocator.alloc(u8, name.len) catch return 0;
    @memcpy(alloc_ptr[0..name.len], name[0..name.len]);
    if (trace.enable_tracing) trace.print("MSVCRT: _tempnam -> '{s}'\n", .{alloc_ptr[0 .. name.len - 1]});

    if (comptime @import("builtin").os.tag == .linux) {
        // Raw create: std.Io.Dir.createFile touches TLS (see _close).
        var nt_buf: [512]u8 = undefined;
        const name_slice = alloc_ptr[0 .. name.len - 1];
        if (name_slice.len < nt_buf.len) {
            @memcpy(nt_buf[0..name_slice.len], name_slice);
            nt_buf[name_slice.len] = 0;
            const rc = std.os.linux.open(@ptrCast(&nt_buf), .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o666);
            const fd: isize = @bitCast(rc);
            if (fd >= 0) _ = std.os.linux.close(@intCast(fd));
        }
    } else if (std.Io.Dir.cwd().createFile(runtime.io(), alloc_ptr[0 .. name.len - 1], .{})) |file| {
        file.close(runtime.io());
    } else |_| {}

    return @intFromPtr(alloc_ptr.ptr);
}
