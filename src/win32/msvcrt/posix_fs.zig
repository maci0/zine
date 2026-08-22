//! POSIX filesystem primitives for Win32 stubs.
//!
//! This module provides a minimal POSIX-like filesystem layer that performs
//! Win32-to-POSIX path translation and handles case-insensitive file access
//! on platforms that don't support it natively (like Linux).

const std = @import("std");
const runtime = @import("../../runtime.zig");
const path_utils = @import("../../path_utils.zig");
const builtin = @import("builtin");

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

fn fileFromFd(fd: std.posix.fd_t) std.Io.File {
    return std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
}

// statx mask matching std's Io/Threaded.zig constants, so the conversion
// produces a std.Io.File.Stat with identical semantics.
const linux_statx_request: std.os.linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .ATIME = true,
    .MTIME = true,
    .CTIME = true,
    .INO = true,
    .SIZE = true,
    .NLINK = true,
    .BLOCKS = true,
};
const linux_statx_check: std.os.linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .ATIME = false,
    .MTIME = true,
    .CTIME = true,
    .INO = true,
    .SIZE = true,
    .NLINK = true,
    .BLOCKS = false,
};

fn statFromLinuxStatx(stx: *const std.os.linux.Statx) ?std.Io.File.Stat {
    const actual_mask_int: u32 = @bitCast(stx.mask);
    const wanted_mask_int: u32 = @bitCast(linux_statx_check);
    if ((actual_mask_int | wanted_mask_int) != actual_mask_int) return null;
    return .{
        .inode = stx.ino,
        .nlink = stx.nlink,
        .size = stx.size,
        .permissions = .fromMode(stx.mode),
        .kind = switch (stx.mode & std.os.linux.S.IFMT) {
            std.os.linux.S.IFDIR => .directory,
            std.os.linux.S.IFCHR => .character_device,
            std.os.linux.S.IFBLK => .block_device,
            std.os.linux.S.IFREG => .file,
            std.os.linux.S.IFIFO => .named_pipe,
            std.os.linux.S.IFLNK => .sym_link,
            std.os.linux.S.IFSOCK => .unix_domain_socket,
            else => .unknown,
        },
        .atime = if (!stx.mask.ATIME) null else .{
            .nanoseconds = @intCast(@as(i128, stx.atime.sec) * std.time.ns_per_s + stx.atime.nsec),
        },
        .mtime = .{ .nanoseconds = @intCast(@as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec) },
        .ctime = .{ .nanoseconds = @intCast(@as(i128, stx.ctime.sec) * std.time.ns_per_s + stx.ctime.nsec) },
        .block_size = if (stx.mask.BLOCKS) stx.blksize else 1,
    };
}

/// Null-terminate a slice in a stack buffer (statx/open/faccessat need
/// [*:0]const u8 paths). Returns null if the path is too long.
fn nullTermBuf(path: []const u8, buf: *[std.posix.PATH_MAX]u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

/// Raw fstat on Linux (see fsStatLinux for why std.Io is avoided). Public so
/// host_io.statFile can share the same TLS-safe implementation.
pub fn fstatFdLinux(fd: i32) ?std.Io.File.Stat {
    const linux = std.os.linux;
    var stx = std.mem.zeroes(linux.Statx);
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, linux_statx_request, &stx);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    return statFromLinuxStatx(&stx);
}

/// fsStat on native Linux: raw syscalls only. std.Io.Dir goes through
/// Io.Threaded (futex/TLS), which faults when invoked from a stub running
/// inside the compat-mode SIGSEGV dispatch handler (FS points at the guest
/// TEB, so per-thread TLS reads land in guest memory).
fn fsStatLinux(path: []const u8) ?std.Io.File.Stat {
    const linux = std.os.linux;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const path_nt = nullTermBuf(path, &buf) orelse return null;
    var stx = std.mem.zeroes(linux.Statx);
    const rc = linux.statx(linux.AT.FDCWD, path_nt, linux.AT.NO_AUTOMOUNT, linux_statx_request, &stx);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    return statFromLinuxStatx(&stx);
}

/// fsAccess on native Linux: faccessat directly (see fsStatLinux for why).
fn fsAccessLinux(path: []const u8) bool {
    const linux = std.os.linux;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const path_nt = nullTermBuf(path, &buf) orelse return false;
    const rc = linux.faccessat(linux.AT.FDCWD, path_nt, 4, 0); // R_OK
    return @as(isize, @bitCast(rc)) == 0;
}

fn fsCreateFileLinux(path: []const u8, flags: std.Io.File.CreateFlags) !std.Io.File {
    const linux = std.os.linux;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const path_nt = nullTermBuf(path, &buf) orelse return error.FileNotFound;
    var oflags: linux.O = .{ .CREAT = true, .CLOEXEC = true };
    oflags.ACCMODE = if (flags.read) .RDWR else .WRONLY;
    if (flags.truncate) oflags.TRUNC = true;
    if (flags.exclusive) oflags.EXCL = true;
    const rc = linux.open(path_nt, oflags, 0o666);
    const fd: isize = @bitCast(rc);
    if (fd < 0) return error.FileNotFound;
    return fileFromFd(@intCast(fd));
}

fn fsOpenFileLinux(path: []const u8, mode: std.Io.File.OpenFlags) !std.Io.File {
    const linux = std.os.linux;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const path_nt = nullTermBuf(path, &buf) orelse return error.FileNotFound;
    var oflags: linux.O = .{ .CLOEXEC = true };
    oflags.ACCMODE = switch (mode.mode) {
        .read_only => .RDONLY,
        .write_only => .WRONLY,
        .read_write => .RDWR,
    };
    const rc = linux.open(path_nt, oflags, 0);
    const fd: isize = @bitCast(rc);
    if (fd < 0) return error.FileNotFound;
    return fileFromFd(@intCast(fd));
}

fn fsStat(path: []const u8) ?std.Io.File.Stat {
    if (comptime builtin.target.os.tag == .linux) return fsStatLinux(path);
    if (std.fs.path.isAbsolute(path)) {
        if (comptime @import("builtin").os.tag != .wasi) {
            return std.Io.Dir.cwd().statFile(runtime.io(), path, .{}) catch null;
        }
        if (path_utils.resolveWasiPath(path)) |resolved| {
            return resolved.dir.statFile(runtime.io(), resolved.rel_path, .{}) catch null;
        }
        return null;
    } else {
        return std.Io.Dir.cwd().statFile(runtime.io(), path, .{}) catch null;
    }
}

fn fsAccess(path: []const u8) bool {
    const trace = @import("../../trace.zig");
    if (trace.enable_tracing) trace.print("POSIX_FS ACCESS: '{s}'\n", .{path});
    if (comptime builtin.target.os.tag == .linux) return fsAccessLinux(path);
    if (std.fs.path.isAbsolute(path)) {
        if (comptime @import("builtin").os.tag != .wasi) {
            if (std.Io.Dir.openFileAbsolute(runtime.io(), path, .{})) |file| {
                file.close(runtime.io());
                return true;
            } else |_| {}
            return false;
        }
        if (path_utils.resolveWasiPath(path)) |resolved| {
            if (resolved.dir.openFile(runtime.io(), resolved.rel_path, .{})) |file| {
                file.close(runtime.io());
                return true;
            } else |_| {}
        }
        return false;
    }

    // Use openFile+close instead of access/accessAbsolute — faccessat panics on WASI.
    if (std.Io.Dir.cwd().openFile(runtime.io(), path, .{})) |file| {
        file.close(runtime.io());
        return true;
    } else |_| {}
    return false;
}

fn fsCreateFile(path: []const u8, flags: std.Io.File.CreateFlags) !std.Io.File {
    if (comptime builtin.target.os.tag == .linux) return fsCreateFileLinux(path, flags);
    if (std.fs.path.isAbsolute(path)) {
        if (comptime @import("builtin").os.tag != .wasi) {
            return std.Io.Dir.createFileAbsolute(runtime.io(), path, flags);
        }
        if (path_utils.resolveWasiPath(path)) |resolved| {
            return resolved.dir.createFile(runtime.io(), resolved.rel_path, flags);
        }
        return error.FileNotFound;
    }

    // Relative path: the WASI cwd (fd 3) may be "/" rather than the real cwd
    // (zine-host preopens "/" first), so try every preopened dir.
    if (comptime @import("builtin").os.tag == .wasi) {
        var fd2: std.os.wasi.fd_t = 3;
        while (true) : (fd2 += 1) {
            var prestat: std.os.wasi.prestat_t = undefined;
            switch (std.os.wasi.fd_prestat_get(fd2, &prestat)) {
                .SUCCESS => {},
                else => break,
            }
            const dir = std.Io.Dir{ .handle = fd2 };
            if (dir.createFile(runtime.io(), path, flags)) |f| return f else |_| {}
        }
        return error.FileNotFound;
    }

    return std.Io.Dir.cwd().createFile(runtime.io(), path, flags) catch {
        return error.FileNotFound;
    };
}

fn fsOpenFile(path: []const u8, flags: std.Io.File.OpenFlags) !std.Io.File {
    if (comptime builtin.target.os.tag == .linux) return fsOpenFileLinux(path, flags);
    if (std.fs.path.isAbsolute(path)) {
        if (comptime @import("builtin").os.tag != .wasi) {
            return std.Io.Dir.openFileAbsolute(runtime.io(), path, flags);
        }
        if (path_utils.resolveWasiPath(path)) |resolved| {
            return resolved.dir.openFile(runtime.io(), resolved.rel_path, flags);
        }
        return error.FileNotFound;
    }

    // Relative path: the WASI cwd (fd 3) may be "/" rather than the real cwd
    // (zine-host preopens "/" first), so try every preopened dir.
    if (comptime @import("builtin").os.tag == .wasi) {
        var fd2: std.os.wasi.fd_t = 3;
        while (true) : (fd2 += 1) {
            var prestat: std.os.wasi.prestat_t = undefined;
            switch (std.os.wasi.fd_prestat_get(fd2, &prestat)) {
                .SUCCESS => {},
                else => break,
            }
            const dir = std.Io.Dir{ .handle = fd2 };
            if (dir.openFile(runtime.io(), path, flags)) |f| return f else |_| {}
        }
        return error.FileNotFound;
    }

    return std.Io.Dir.cwd().openFile(runtime.io(), path, flags) catch {
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
pub fn stat(path: [*:0]const u8) ?std.Io.File.Stat {
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
                    if (is_append) _ = @import("../../platform.zig").lseek(f.handle, 0, 2);
                    return @intCast(f.handle);
                } else |_| {}
            } else {
                if (fsOpenFile(p, .{
                    .mode = if ((flags & O_RDWR) != 0) .read_write else .write_only,
                })) |f| {
                    if (is_trunc) {
                        if (comptime builtin.target.os.tag == .linux) {
                            _ = std.os.linux.ftruncate(f.handle, 0);
                        } else {
                            f.setLength(runtime.io(), 0) catch {};
                        }
                        _ = @import("../../platform.zig").lseek(f.handle, 0, 0);
                    }
                    if (is_append) _ = @import("../../platform.zig").lseek(f.handle, 0, 2);
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

/// Raw unlink (see fsStat for why std.Io is avoided on Linux).
fn fsDelete(path: []const u8) bool {
    if (comptime builtin.target.os.tag == .linux) {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const path_nt = nullTermBuf(path, &buf) orelse return false;
        const rc = std.os.linux.unlink(path_nt);
        return @as(isize, @bitCast(rc)) == 0;
    }
    std.Io.Dir.cwd().deleteFile(runtime.io(), path) catch return false;
    return true;
}

/// Raw rename (see fsStat for why std.Io is avoided on Linux).
fn fsRename(old_path: []const u8, new_path: []const u8) bool {
    if (comptime builtin.target.os.tag == .linux) {
        var old_buf: [std.posix.PATH_MAX]u8 = undefined;
        var new_buf: [std.posix.PATH_MAX]u8 = undefined;
        const old_nt = nullTermBuf(old_path, &old_buf) orelse return false;
        const new_nt = nullTermBuf(new_path, &new_buf) orelse return false;
        const rc = std.os.linux.rename(old_nt, new_nt);
        return @as(isize, @bitCast(rc)) == 0;
    }
    const cwd = std.Io.Dir.cwd();
    cwd.rename(cwd, old_path, cwd, new_path, runtime.io()) catch return false;
    return true;
}

fn toHostBuf(path: [*:0]const u8, host_buf: []u8) ?[]const u8 {
    const host_len = path_utils.toHostPath(std.mem.span(path), host_buf);
    if (host_len == 0) return null;
    return host_buf[0..host_len];
}

/// remove / _unlink — delete a file. Returns 0 on success, -1 on failure.
pub fn unlink(path: [*:0]const u8) i32 {
    var host_buf: [1024]u8 = undefined;
    const p = toHostBuf(path, &host_buf) orelse return -1;

    // Exact path
    if (fsDelete(p)) return 0;

    // Lowercased filename
    var lower_buf: [1024]u8 = undefined;
    if (tryLower(p, &lower_buf)) |lower_p| {
        if (fsDelete(lower_p)) return 0;
    }

    // Case-insensitive dir scan
    var ci_buf: [1024]u8 = undefined;
    if (path_utils.tryCaseInsensitiveResolve(p, &ci_buf)) |ci_path| {
        if (fsDelete(ci_path)) return 0;
    }

    return -1;
}

/// rename — move/rename a file. Returns 0 on success, -1 on failure.
pub fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) i32 {
    return renameWin32(std.mem.span(old_path), std.mem.span(new_path));
}

/// Core of rename given Win32-format path slices. Shared with
/// kernel32.MoveFileA so the CRT `rename()` (which forwards to MoveFileA)
/// and direct MoveFile callers take the same path.
pub fn renameWin32(old_win: []const u8, new_win: []const u8) i32 {
    var old_buf: [1024]u8 = undefined;
    var new_buf: [1024]u8 = undefined;
    const old_len = path_utils.toHostPath(old_win, &old_buf);
    if (old_len == 0) return -1;
    const new_len = path_utils.toHostPath(new_win, &new_buf);
    if (new_len == 0) return -1;
    const old_p = old_buf[0..old_len];
    const new_p = new_buf[0..new_len];

    if (fsRename(old_p, new_p)) return 0;

    // Lowercased filename fallback
    var old_lower: [1024]u8 = undefined;
    if (tryLower(old_p, &old_lower)) |old_l| {
        if (fsRename(old_l, new_p)) return 0;
    }

    return -1;
}
