//! POSIX filesystem primitives for Win32 stubs.
//!
//! This module provides a minimal POSIX-like filesystem layer that performs
//! Win32-to-POSIX path translation and handles case-insensitive file access
//! on platforms that don't support it natively (like Linux).

const std = @import("std");
const path_utils = @import("../../path_utils.zig");

/// Read-only access.
pub const O_RDONLY: u32 = 0;
/// Write-only access.
pub const O_WRONLY: u32 = 1;
/// Read-write access.
pub const O_RDWR: u32 = 2;
/// Create file if it does not exist.
pub const O_CREAT: u32 = 0x40;
/// Truncate file to zero length.
pub const O_TRUNC: u32 = 0x200;
/// Append data to the end of the file.
pub const O_APPEND: u32 = 0x400;

fn fsStat(path: []const u8) ?std.fs.File.Stat {
    if (std.fs.path.isAbsolute(path)) {
        var dir = std.fs.openDirAbsolute("/", .{}) catch return null;
        defer dir.close();
        const rel_path = if (path.len > 0 and path[0] == '/') path[1..] else path;
        return dir.statFile(rel_path) catch null;
    } else {
        return std.fs.cwd().statFile(path) catch null;
    }
}

fn fsAccess(path: []const u8) bool {
    // Use openFile+close instead of access/accessAbsolute — faccessat panics on WASI.
    // Try all preopened directories on WASI (fd 3, 4, 5...).
    // wasmtime --dir=/ --dir=. gives fd 3=/, fd 4=.
    if (std.fs.cwd().openFile(path, .{})) |file| {
        file.close();
        return true;
    } else |_| {}
    // Try the second WASI preopened fd (typically fd 4 = "." from --dir=.)
    {
        const dir = std.fs.Dir{ .fd = 4 };
        if (dir.openFile(path, .{})) |file| {
            file.close();
            return true;
        } else |_| {}
    }
    if (std.fs.path.isAbsolute(path)) {
        if (std.fs.openFileAbsolute(path, .{})) |file| {
            file.close();
            return true;
        } else |_| {}
    }
    return false;
}

fn fsCreateFile(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
    return std.fs.cwd().createFile(path, flags) catch {
        const cwd_dir = std.fs.Dir{ .fd = 4 }; // WASI preopen for "."
        if (cwd_dir.createFile(path, flags)) |f| return f else |_| {}
        if (std.fs.path.isAbsolute(path))
            return std.fs.createFileAbsolute(path, flags);
        return error.FileNotFound;
    };
}

fn fsOpenFile(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    return std.fs.cwd().openFile(path, flags) catch {
        const cwd_dir = std.fs.Dir{ .fd = 4 };
        if (cwd_dir.openFile(path, flags)) |f| return f else |_| {}
        if (std.fs.path.isAbsolute(path))
            return std.fs.openFileAbsolute(path, flags);
        return error.FileNotFound;
    };
}

fn tryLower(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    var last_slash: usize = 0;
    for (0..path.len) |i| {
        if (buf[i] == '/') last_slash = i + 1;
    }
    for (last_slash..path.len) |i| {
        buf[i] = std.ascii.toLower(buf[i]);
    }
    return buf[0..path.len];
}

/// Get status information on a file.
/// Implementation status: Partially implemented
pub fn stat(path: [*:0]const u8) ?std.fs.File.Stat {
    const span = std.mem.span(path);
    var host_buf: [1024]u8 = undefined;
    const host_len = path_utils.toHostPath(span, &host_buf);
    if (host_len == 0) return null;
    const p = host_buf[0..host_len];

    // Try exact path
    if (fsStat(p)) |s| return s;

    // Try lowercased filename
    var lower_buf: [1024]u8 = undefined;
    if (tryLower(p, &lower_buf)) |lower_p| {
        if (fsStat(lower_p)) |s| return s;
    }

    // Try case-insensitive dir scan
    var ci_buf: [1024]u8 = undefined;
    if (path_utils.tryCaseInsensitiveResolve(p, &ci_buf)) |ci_path| {
        if (fsStat(ci_path)) |s| return s;
    }

    return null;
}

/// Determine file-access permissions.
/// Implementation status: Partially implemented
pub fn access(path: [*:0]const u8, mode: i32) i32 {
    _ = mode;
    const span = std.mem.span(path);
    var host_buf: [1024]u8 = undefined;
    const host_len = path_utils.toHostPath(span, &host_buf);
    if (host_len == 0) return -1;
    const p = host_buf[0..host_len];

    // Try exact path
    if (fsAccess(p)) return 0;

    // Try lowercased filename
    var lower_buf: [1024]u8 = undefined;
    if (tryLower(p, &lower_buf)) |lower_p| {
        if (fsAccess(lower_p)) return 0;
    }

    // Try case-insensitive dir scan
    var ci_buf: [1024]u8 = undefined;
    if (path_utils.tryCaseInsensitiveResolve(p, &ci_buf)) |ci_path| {
        if (fsAccess(ci_path)) return 0;
    }

    return -1;
}

/// Opens a file.
/// Implementation status: Partially implemented
pub fn open(path: [*:0]const u8, flags: u32, mode: u32) i32 {
    _ = mode;
    const span = std.mem.span(path);
    var host_buf: [1024]u8 = undefined;
    const host_len = path_utils.toHostPath(span, &host_buf);
    if (host_len == 0) return -1;

    const trace = @import("../../trace.zig");
    if (trace.enable_tracing) trace.print("POSIX_FS OPEN: {s} (flags {d})\n", .{ host_buf[0..host_len], flags });

    const is_write = (flags & O_WRONLY) != 0 or (flags & O_RDWR) != 0;
    const is_create = (flags & O_CREAT) != 0;
    const is_trunc = (flags & O_TRUNC) != 0;
    const is_append = (flags & O_APPEND) != 0;

    var lower_buf: [1024]u8 = undefined;
    var ci_buf: [1024]u8 = undefined;

    const p0 = host_buf[0..host_len];
    const p1 = tryLower(p0, &lower_buf);
    const p2 = path_utils.tryCaseInsensitiveResolve(p0, &ci_buf);

    const candidates = [_]?[]const u8{ p0, p1, p2 };

    for (candidates) |maybe_path| {
        const p = maybe_path orelse continue;

        if (is_write) {
            if (is_create) {
                if (fsCreateFile(p, .{
                    .read = (flags & O_RDWR) != 0,
                    .truncate = is_trunc,
                    .exclusive = false,
                })) |f| {
                    if (is_append) f.seekFromEnd(0) catch {};
                    return @intCast(f.handle);
                } else |_| {}
            } else {
                if (fsOpenFile(p, .{
                    .mode = if ((flags & O_RDWR) != 0) .read_write else .write_only,
                })) |f| {
                    if (is_trunc) {
                        f.setEndPos(0) catch {};
                        f.seekTo(0) catch {};
                    }
                    if (is_append) f.seekFromEnd(0) catch {};
                    return @intCast(f.handle);
                } else |_| {}
            }
        } else {
            if (fsOpenFile(p, .{ .mode = .read_only })) |f| {
                return @intCast(f.handle);
            } else |_| {}
        }
    }

    return -1;
}
