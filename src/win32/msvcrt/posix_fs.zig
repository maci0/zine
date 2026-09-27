//! POSIX filesystem primitives for Win32 stubs.
//!
//! This module provides a minimal POSIX-like filesystem layer that performs
//! Win32-to-POSIX path translation and handles case-insensitive file access
//! on platforms that don't support it natively (like Linux).

const std = @import("std");
const log = @import("../../log.zig");
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
    return fsFile(true, path, flags);
}

fn fsOpenFile(path: []const u8, flags: std.Io.File.OpenFlags) !std.Io.File {
    return fsFile(false, path, flags);
}

/// `create` selects the create or the open half of the std.Io.Dir API; path
/// resolution is identical for both.
fn fsFile(
    comptime create: bool,
    path: []const u8,
    flags: if (create) std.Io.File.CreateFlags else std.Io.File.OpenFlags,
) !std.Io.File {
    const io = runtime.io();
    if (comptime builtin.target.os.tag == .linux) {
        if (create) return fsCreateFileLinux(path, flags);
        return fsOpenFileLinux(path, flags);
    }
    if (std.fs.path.isAbsolute(path)) {
        if (comptime builtin.target.os.tag != .wasi) {
            if (create) return std.Io.Dir.createFileAbsolute(io, path, flags);
            return std.Io.Dir.openFileAbsolute(io, path, flags);
        }
        if (path_utils.resolveWasiPath(path)) |resolved| {
            if (create) return resolved.dir.createFile(io, resolved.rel_path, flags);
            return resolved.dir.openFile(io, resolved.rel_path, flags);
        }
        return error.FileNotFound;
    }

    // Relative path: the WASI cwd (fd 3) may be "/" rather than the real cwd
    // (zine-host preopens "/" first), so try every preopened dir.
    if (comptime builtin.target.os.tag == .wasi) {
        var fd2: std.os.wasi.fd_t = 3;
        while (true) : (fd2 += 1) {
            var prestat: std.os.wasi.prestat_t = undefined;
            switch (std.os.wasi.fd_prestat_get(fd2, &prestat)) {
                .SUCCESS => {},
                else => break,
            }
            const dir = std.Io.Dir{ .handle = fd2 };
            const result = if (create) dir.createFile(io, path, flags) else dir.openFile(io, path, flags);
            if (result) |f| return f else |_| {}
        }
        return error.FileNotFound;
    }

    const result = if (create) std.Io.Dir.cwd().createFile(io, path, flags) else std.Io.Dir.cwd().openFile(io, path, flags);
    return result catch return error.FileNotFound;
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
                        // O_TRUNC must actually truncate. If it fails (read-only
                        // mount, quota, permissions) the caller would otherwise
                        // get a valid fd on a file whose old contents survive, so
                        // a shorter write would leave stale trailing bytes in a
                        // file the guest believes is empty. Fail the open instead.
                        if (comptime builtin.target.os.tag == .linux) {
                            const rc = std.os.linux.ftruncate(f.handle, 0);
                            if (std.os.linux.errno(rc) != .SUCCESS) {
                                log.err("_open('{s}'): O_TRUNC ftruncate failed, errno {t}", .{ p, std.os.linux.errno(rc) });
                                _ = std.os.linux.close(f.handle);
                                return -1;
                            }
                        } else {
                            f.setLength(runtime.io(), 0) catch |err| {
                                log.err("_open('{s}'): O_TRUNC failed: {t}", .{ p, err });
                                f.close(runtime.io());
                                return -1;
                            };
                        }
                        if (@import("../../platform.zig").lseek(f.handle, 0, 0) < 0) {
                            log.err("_open('{s}'): rewind after O_TRUNC failed", .{p});
                            if (comptime builtin.target.os.tag == .linux) {
                                _ = std.os.linux.close(f.handle);
                            } else {
                                f.close(runtime.io());
                            }
                            return -1;
                        }
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

/// Outcome of a raw rename attempt.
pub const RenameOutcome = enum {
    /// The rename completed.
    ok,
    /// Failed because old and new paths live on different filesystems
    /// (Linux EXDEV / Zig error.CrossDevice).
    cross_device,
    /// Failed for any other reason.
    failed,
};

/// Raw rename (see fsStat for why std.Io is avoided on Linux). Distinguishes
/// the cross-filesystem case so Win32 MoveFile can fall back to copy+delete,
/// matching Windows where moving across volumes succeeds.
fn fsRename(old_path: []const u8, new_path: []const u8) RenameOutcome {
    if (comptime builtin.target.os.tag == .linux) {
        var old_buf: [std.posix.PATH_MAX]u8 = undefined;
        var new_buf: [std.posix.PATH_MAX]u8 = undefined;
        const old_nt = nullTermBuf(old_path, &old_buf) orelse return .failed;
        const new_nt = nullTermBuf(new_path, &new_buf) orelse return .failed;
        const rc = std.os.linux.rename(old_nt, new_nt);
        if (@as(isize, @bitCast(rc)) == 0) return .ok;
        if (rc == @intFromEnum(std.os.linux.E.XDEV)) return .cross_device;
        return .failed;
    }
    const cwd = std.Io.Dir.cwd();
    cwd.rename(old_path, cwd, new_path, runtime.io()) catch |err| switch (err) {
        error.CrossDevice => return .cross_device,
        else => return .failed,
    };
    return .ok;
}

/// Cross-filesystem move fallback: copy contents, then delete the source.
/// Regular files only (directory trees are not recursed). On Linux this uses
/// raw syscalls only, so it stays safe inside the compat-mode SIGSEGV
/// dispatch context (see fsStat for why std.Io is avoided there).
fn copyDeleteMove(old_p: []const u8, new_p: []const u8) bool {
    if (comptime builtin.target.os.tag == .linux) return copyDeleteMoveLinux(old_p, new_p);

    // Only regular files are copied.
    const st = fsStat(old_p) orelse return false;
    if (st.kind != .file) return false;

    const src = fsOpenFile(old_p, .{ .mode = .read_only }) catch return false;
    defer src.close(runtime.io());
    const dst = fsCreateFile(new_p, .{ .read = false, .truncate = true, .exclusive = false }) catch return false;

    var buf: [8192]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = src.readPositionalAll(runtime.io(), &buf, off) catch {
            dst.close(runtime.io());
            _ = fsDelete(new_p);
            return false;
        };
        if (n == 0) break;
        dst.writePositionalAll(runtime.io(), buf[0..n], off) catch {
            dst.close(runtime.io());
            _ = fsDelete(new_p);
            return false;
        };
        off += n;
    }
    dst.close(runtime.io());
    _ = fsDelete(old_p);
    return true;
}

fn copyDeleteMoveLinux(old_p: []const u8, new_p: []const u8) bool {
    const linux = std.os.linux;
    var old_buf: [std.posix.PATH_MAX]u8 = undefined;
    var new_buf: [std.posix.PATH_MAX]u8 = undefined;
    const old_nt = nullTermBuf(old_p, &old_buf) orelse return false;
    const new_nt = nullTermBuf(new_p, &new_buf) orelse return false;

    const src_rc = linux.open(old_nt, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const src_fd: isize = @bitCast(src_rc);
    if (src_fd < 0) return false;
    const src: linux.fd_t = @intCast(src_fd);
    defer _ = linux.close(src);

    // Refuse anything but regular files.
    var stx = std.mem.zeroes(linux.Statx);
    const stx_rc = linux.statx(src, "", linux.AT.EMPTY_PATH, linux_statx_request, &stx);
    if (@as(isize, @bitCast(stx_rc)) < 0) return false;
    if ((stx.mode & linux.S.IFMT) != linux.S.IFREG) return false;

    const dst_rc = linux.open(new_nt, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o666);
    const dst_fd: isize = @bitCast(dst_rc);
    if (dst_fd < 0) return false;

    var buf: [8192]u8 align(16) = undefined;
    var failed = false;
    while (true) {
        const r_rc = linux.read(src, &buf, buf.len);
        const r: isize = @bitCast(r_rc);
        if (r <= 0) {
            failed = r < 0;
            break;
        }
        var written: usize = 0;
        const r_len: usize = @intCast(r);
        while (written < r_len) {
            const w_rc = linux.write(@intCast(dst_fd), buf[written..r_len].ptr, r_len - written);
            const w: isize = @bitCast(w_rc);
            if (w <= 0) {
                failed = true;
                break;
            }
            written += @intCast(w);
        }
        if (failed) break;
    }
    _ = linux.close(@intCast(dst_fd));
    if (failed) {
        // Remove the partial destination instead of leaving debris behind.
        _ = linux.unlink(new_nt);
        return false;
    }
    _ = linux.unlink(old_nt);
    return true;
}

/// Apply fsRename once, optionally falling back to copy+delete when the two
/// paths turn out to live on different filesystems.
fn renameOnce(old_p: []const u8, new_p: []const u8, allow_copy_move: bool) bool {
    switch (fsRename(old_p, new_p)) {
        .ok => return true,
        .cross_device => return allow_copy_move and copyDeleteMove(old_p, new_p),
        .failed => return false,
    }
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

    if (renameOnce(old_p, new_p, false)) return 0;

    // Lowercased filename fallback
    var old_lower: [1024]u8 = undefined;
    if (tryLower(old_p, &old_lower)) |old_l| {
        if (renameOnce(old_l, new_p, false)) return 0;
    }

    return -1;
}

/// Core of kernel32 MoveFile given Win32-format path slices. Unlike CRT
/// rename(), Win32 MoveFile works across volumes: when the host refuses the
/// rename because source and target sit on different filesystems, fall back
/// to copy + delete of the regular file.
pub fn moveFileWin32(old_win: []const u8, new_win: []const u8) i32 {
    var old_buf: [1024]u8 = undefined;
    var new_buf: [1024]u8 = undefined;
    const old_len = path_utils.toHostPath(old_win, &old_buf);
    if (old_len == 0) return -1;
    const new_len = path_utils.toHostPath(new_win, &new_buf);
    if (new_len == 0) return -1;
    const old_p = old_buf[0..old_len];
    const new_p = new_buf[0..new_len];

    if (renameOnce(old_p, new_p, true)) return 0;

    // Lowercased filename fallback
    var old_lower: [1024]u8 = undefined;
    if (tryLower(old_p, &old_lower)) |old_l| {
        if (renameOnce(old_l, new_p, true)) return 0;
    }

    return -1;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;

fn tmpFileRealPath(tmp_dir: *testing.TmpDir, name: []const u8, buf: []u8) ![]const u8 {
    const io = runtime.io();
    try tmp_dir.dir.writeFile(io, .{ .sub_path = name, .data = "move me" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp_dir.dir.realPath(io, &dir_buf);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir_buf[0..dir_len], name });
}

test "moveFileWin32: same-filesystem move renames and drops the source" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var src_buf: [512]u8 = undefined;
    var dst_buf: [512]u8 = undefined;
    const src = try tmpFileRealPath(&tmp_dir, "mv_src.txt", &src_buf);
    const dst = try tmpFileRealPath(&tmp_dir, "mv_dst.txt", &dst_buf);

    try testing.expectEqual(@as(i32, 0), moveFileWin32(src, dst));
    try testing.expect(fsStat(dst) != null);
    try testing.expect(fsStat(src) == null);
}

test "moveFileWin32: Z: drive paths resolve through translation" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var src_buf: [512]u8 = undefined;
    var dst_buf: [512]u8 = undefined;
    const src_posix = try tmpFileRealPath(&tmp_dir, "z_src.txt", &src_buf);
    const dst_posix = try tmpFileRealPath(&tmp_dir, "z_dst.txt", &dst_buf);

    var src_win: [516]u8 = undefined;
    var dst_win: [516]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_win, "Z:{s}", .{src_posix});
    const dst = try std.fmt.bufPrint(&dst_win, "Z:{s}", .{dst_posix});

    try testing.expectEqual(@as(i32, 0), moveFileWin32(src, dst));
    try testing.expect(fsStat(dst_posix) != null);
    try testing.expect(fsStat(src_posix) == null);
}

test "moveFileWin32: missing source fails without creating the target" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const io = runtime.io();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp_dir.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    var src_buf: [512]u8 = undefined;
    var dst_buf: [512]u8 = undefined;
    const missing = try std.fmt.bufPrint(&src_buf, "{s}/no_such_file.bin", .{dir});
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/should_not_exist.bin", .{dir});

    try testing.expectEqual(@as(i32, -1), moveFileWin32(missing, dst));
    try testing.expect(fsStat(dst) == null);
}

test "copyDeleteMove: copies content and removes the source" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var src_buf: [512]u8 = undefined;
    var dst_buf: [512]u8 = undefined;
    const src = try tmpFileRealPath(&tmp_dir, "cp_src.txt", &src_buf);
    const dst = try tmpFileRealPath(&tmp_dir, "cp_dst.txt", &dst_buf);

    try testing.expect(copyDeleteMove(src, dst));
    try testing.expect(fsStat(src) == null);
    const st = fsStat(dst) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, "move me".len), st.size);
}
