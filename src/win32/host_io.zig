//! Unified host I/O abstraction for Win32 stub functions.
//!
//! All file I/O from stub functions goes through this module. It accepts
//! Win32-style paths (C:\foo\bar) and handles:
//!   - Win32→POSIX path conversion (on non-Windows hosts)
//!   - Case-insensitive filename resolution (on case-sensitive filesystems)
//!   - WASI preopened directory handling (on WebAssembly)
//!
//! On real Windows, these functions are trivial pass-throughs to the OS.
//! On Linux/WASM, they convert paths and delegate to POSIX operations.
//!
//! Stub functions should use this module instead of calling std.fs,
//! path_utils, or posix_fs directly.

const std = @import("std");
const builtin = @import("builtin");
const path_utils = @import("../path_utils.zig");
const posix_fs = @import("msvcrt/posix_fs.zig");

// Re-export POSIX flag constants so stubs don't need to import posix_fs
pub const O_RDONLY = posix_fs.O_RDONLY;
pub const O_WRONLY = posix_fs.O_WRONLY;
pub const O_RDWR = posix_fs.O_RDWR;
pub const O_CREAT = posix_fs.O_CREAT;
pub const O_TRUNC = posix_fs.O_TRUNC;
pub const O_APPEND = posix_fs.O_APPEND;

/// Open a file given a Win32 path. Returns a file descriptor or -1.
/// Handles Win32→POSIX conversion and case-insensitive fallback.
pub fn open(win32_path: []const u8, flags: u32, mode: u32) i32 {
    var ntz_buf: [1025]u8 = undefined;
    const ntz = nullTerminate(win32_path, &ntz_buf) orelse return -1;
    return posix_fs.open(ntz, flags, mode);
}

const runtime = @import("../runtime.zig");

/// Raw write wrapper: std.Io.File has no writeAll in 0.16. Bypasses the
/// streaming Writer vtable on native targets because this is hot-path for
/// MSVCRT stdio stubs (fputc/putchar/_write).
pub fn writeAllToFile(file: std.Io.File, bytes: []const u8) error{WriteFailed}!void {
    if (comptime builtin.target.os.tag == .linux) {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.os.linux.write(file.handle, bytes.ptr + off, bytes.len - off);
            const signed: isize = @bitCast(rc);
            if (signed <= 0) return error.WriteFailed;
            off += rc;
        }
        return;
    }
    file.writeStreamingAll(runtime.io(), bytes) catch return error.WriteFailed;
}

/// Raw sequential read. Mirrors writeAllToFile: uses a direct syscall on
/// Linux because MSVCRT fread/fgetc/read hit this per byte or per record.
/// Returns bytes read (0 == EOF, < len == partial).
pub fn readFromFile(file: std.Io.File, buf: []u8) error{ReadFailed}!usize {
    if (comptime builtin.target.os.tag == .linux) {
        const rc = std.os.linux.read(file.handle, buf.ptr, buf.len);
        const signed: isize = @bitCast(rc);
        if (signed < 0) return error.ReadFailed;
        return rc;
    }
    // Sequential read at the CURRENT file position. readPositionalAll(..., 0)
    // reads offset 0 on every call, so repeated fread/fgetc calls would keep
    // returning the same leading bytes (breaking P2's intermediate-file parse
    // into "compiler limit: out of keys").
    const result = file.readStreaming(runtime.io(), &.{buf}) catch return error.ReadFailed;
    return result;
}

pub fn closeFile(file: std.Io.File) void {
    if (comptime builtin.target.os.tag == .linux) {
        _ = std.os.linux.close(file.handle);
        return;
    }
    file.close(runtime.io());
}

pub fn statFile(file: std.Io.File) ?std.Io.File.Stat {
    if (comptime builtin.target.os.tag == .linux) {
        return posix_fs.fstatFdLinux(file.handle);
    }
    return file.stat(runtime.io()) catch null;
}

/// Raw setLength (ftruncate) on Linux; std.Io elsewhere.
pub fn setLength(file: std.Io.File, len: u64) error{TruncFailed}!void {
    if (comptime builtin.target.os.tag == .linux) {
        const rc = std.os.linux.ftruncate(file.handle, @intCast(len));
        if (@as(isize, @bitCast(rc)) < 0) return error.TruncFailed;
        return;
    }
    file.setLength(runtime.io(), len) catch return error.TruncFailed;
}

/// Sequential positional read at the CURRENT file position; raw pread on
/// Linux (std.Io.File.readPositionalAll touches TLS, which faults inside
/// the compat-mode SIGSEGV dispatch handler).
pub fn readPositional(file: std.Io.File, buf: []u8, offset: u64) error{ReadFailed}!usize {
    if (comptime builtin.target.os.tag == .linux) {
        var off: usize = 0;
        while (off < buf.len) {
            const rc = std.os.linux.pread(file.handle, buf.ptr + off, buf.len - off, @as(i64, @intCast(offset + off)));
            if (std.os.linux.errno(rc) == .INTR) continue;
            const signed: isize = @bitCast(rc);
            if (signed < 0) return error.ReadFailed;
            if (rc == 0) break;
            off += rc;
        }
        return off;
    }
    return file.readPositionalAll(runtime.io(), buf, offset) catch return error.ReadFailed;
}

test "readPositional returns partial data and EOF without moving the file position" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(runtime.io(), .{ .sub_path = "input.bin", .data = "abcdef" });
    const file = try tmp.dir.openFile(runtime.io(), "input.bin", .{});
    defer closeFile(file);

    var buf: [8]u8 = @splat(0xCC);
    try std.testing.expectEqual(@as(usize, 4), try readPositional(file, &buf, 2));
    try std.testing.expectEqualStrings("cdef", buf[0..4]);
    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0xCC)), buf[4..]);
    try std.testing.expectEqual(@as(usize, 0), try readPositional(file, &buf, 6));
    try std.testing.expectEqual(@as(usize, 0), try readPositional(file, &buf, 20));
    try std.testing.expectEqual(@as(usize, 0), try readPositional(file, buf[0..0], 0));
    try std.testing.expectEqual(@as(usize, 3), try readPositional(file, buf[0..3], 1));
    try std.testing.expectEqualStrings("bcd", buf[0..3]);
    try std.testing.expectEqual(@as(usize, 6), try readFromFile(file, &buf));
    try std.testing.expectEqualStrings("abcdef", buf[0..6]);
}

test "readPositional reports read errors" {
    var buf: [1]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, readPositional(fileFromFd(-1), &buf, 0));
}

/// Raw pwrite on Linux; std.Io elsewhere (see readPositional).
pub fn writePositional(file: std.Io.File, bytes: []const u8, offset: u64) error{WriteFailed}!void {
    if (comptime builtin.target.os.tag == .linux) {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.os.linux.pwrite(file.handle, bytes.ptr + off, bytes.len - off, @as(i64, @intCast(offset + off)));
            const signed: isize = @bitCast(rc);
            if (signed <= 0) return error.WriteFailed;
            off += rc;
        }
        return;
    }
    file.writePositionalAll(runtime.io(), bytes, offset) catch return error.WriteFailed;
}

/// Raw Dir close on Linux (see closeFile).
pub fn closeDir(dir: std.Io.Dir) void {
    if (comptime builtin.target.os.tag == .linux) {
        _ = std.os.linux.close(dir.handle);
        return;
    }
    dir.close(runtime.io());
}

/// Raw unlink on Linux; std.Io elsewhere.
pub fn deleteFilePosix(path: []const u8) bool {
    if (comptime builtin.target.os.tag == .linux) {
        var nt: [std.posix.PATH_MAX]u8 = undefined;
        if (path.len >= nt.len) return false;
        @memcpy(nt[0..path.len], path);
        nt[path.len] = 0;
        const rc = std.os.linux.unlink(@ptrCast(&nt));
        return @as(isize, @bitCast(rc)) == 0;
    }
    std.Io.Dir.cwd().deleteFile(runtime.io(), path) catch return false;
    return true;
}

/// Check if a file exists / is accessible given a Win32 path.
/// Returns 0 if accessible, -1 if not.
pub fn access(win32_path: []const u8, mode: i32) i32 {
    var ntz_buf: [1025]u8 = undefined;
    const ntz = nullTerminate(win32_path, &ntz_buf) orelse return -1;
    return posix_fs.access(ntz, mode);
}

/// Get file status given a Win32 path. Returns null if not found.
pub fn stat(win32_path: []const u8) ?std.Io.File.Stat {
    var ntz_buf: [1025]u8 = undefined;
    const ntz = nullTerminate(win32_path, &ntz_buf) orelse return null;
    return posix_fs.stat(ntz);
}

/// Delete a file given a Win32 path. Returns true on success.
pub fn deleteFile(win32_path: []const u8) bool {
    var host_buf: [1024]u8 = undefined;
    const len = path_utils.toHostPath(win32_path, &host_buf);
    if (len == 0) return false;
    if (comptime builtin.target.os.tag == .linux) {
        const rc = std.os.linux.unlink(host_buf[0..len]);
        return @as(isize, @bitCast(rc)) == 0;
    }
    std.Io.Dir.cwd().deleteFile(runtime.io(), host_buf[0..len]) catch return false;
    return true;
}

/// Get the current working directory in Win32 format (C:\...).
/// Returns the number of bytes written, or 0 on failure.
pub fn getCwd(buf: []u8) usize {
    if (comptime builtin.target.os.tag == .linux) {
        // Raw getcwd syscall: std.process.currentPathAlloc goes through
        // std.Io (TLS), which faults inside the compat signal dispatch.
        const n = std.os.linux.getcwd(buf.ptr, buf.len);
        if (std.os.linux.errno(n) != .SUCCESS or n == 0) return 0;
        var win_buf: [1024]u8 = undefined;
        const win_len = path_utils.posixToWin32(buf[0 .. n - 1], &win_buf) catch return 0;
        if (win_len == 0 or win_len >= buf.len) return 0;
        @memcpy(buf[0..win_len], win_buf[0..win_len]);
        buf[win_len] = 0;
        return win_len;
    }
    const cwd = std.process.currentPathAlloc(runtime.io(), std.heap.page_allocator) catch return 0;
    defer std.heap.page_allocator.free(cwd);

    var win_buf: [1024]u8 = undefined;
    const win_len = path_utils.posixToWin32(cwd, &win_buf) catch return 0;
    if (win_len == 0 or win_len >= buf.len) return 0;

    @memcpy(buf[0..win_len], win_buf[0..win_len]);
    buf[win_len] = 0;
    return win_len;
}

test "getCwd excludes the terminator and resolves relative paths" {
    const cwd = try std.process.currentPathAlloc(runtime.io(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    var expected: [1024]u8 = undefined;
    const expected_len = try path_utils.posixToWin32(cwd, &expected);
    var actual: [1024]u8 = undefined;
    const actual_len = getCwd(&actual);
    try std.testing.expectEqual(expected_len, actual_len);
    try std.testing.expectEqualStrings(expected[0..expected_len], actual[0..actual_len]);
    try std.testing.expectEqual(@as(u8, 0), actual[actual_len]);

    const full_len = getFullPath("child.txt", &actual);
    const separator: []const u8 = if (expected[expected_len - 1] == '\\') "" else "\\";
    const full = try std.testing.allocator.print("{s}{s}child.txt", .{ expected[0..expected_len], separator });
    defer std.testing.allocator.free(full);
    try std.testing.expectEqualStrings(full, actual[0..full_len]);
}

test "getCwd rejects undersized buffers" {
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), getCwd(&buf));
    try std.testing.expectEqual(@as(usize, 0), getCwd(buf[0..0]));
}

/// Resolve a relative Win32 path to an absolute Win32 path.
/// Returns the number of bytes written, or 0 on failure.
pub fn getFullPath(rel_path: []const u8, buf: []u8) usize {
    // If already absolute (has drive letter), just normalize slashes
    if (rel_path.len >= 2 and rel_path[1] == ':' and std.ascii.isAlphabetic(rel_path[0])) {
        if (rel_path.len >= buf.len) return 0;
        @memcpy(buf[0..rel_path.len], rel_path);
        // Normalize forward slashes to backslashes
        std.mem.replaceScalar(u8, buf[0..rel_path.len], '/', '\\');
        buf[rel_path.len] = 0;
        return rel_path.len;
    }

    // Relative: combine with CWD
    var cwd_buf: [1024]u8 = undefined;
    const cwd_len = getCwd(&cwd_buf);
    if (cwd_len == 0) return 0;

    // cwd_buf has "C:\some\dir", rel_path has "subdir\file.txt"
    // Result: "C:\some\dir\subdir\file.txt"
    var pos: usize = cwd_len;
    if (pos > 0 and cwd_buf[pos - 1] != '\\') {
        if (pos >= buf.len) return 0;
        cwd_buf[pos] = '\\';
        pos += 1;
    }
    if (pos >= buf.len or rel_path.len >= buf.len - pos) return 0;
    const dest = buf[pos..][0..rel_path.len];
    if (@intFromPtr(dest.ptr) > @intFromPtr(rel_path.ptr)) {
        std.mem.copyBackwards(u8, dest, rel_path);
    } else {
        std.mem.copyForwards(u8, dest, rel_path);
    }
    @memcpy(buf[0..pos], cwd_buf[0..pos]);
    pos += rel_path.len;

    std.mem.replaceScalar(u8, buf[0..pos], '/', '\\');
    buf[pos] = 0;
    return pos;
}

test "getFullPath builds long relative paths in the caller buffer" {
    var cwd: [1024]u8 = undefined;
    const cwd_len = getCwd(&cwd);
    try std.testing.expect(cwd_len > 0);
    const separator: []const u8 = if (cwd[cwd_len - 1] == '\\') "" else "\\";
    const relative = @as([1120]u8, @bitCast(@as([160][7]u8, @splat(.{ 102, 111, 108, 100, 101, 114, 47 })))) ++ "file.txt";
    const expected = try std.testing.allocator.print("{s}{s}{s}", .{ cwd[0..cwd_len], separator, relative });
    defer std.testing.allocator.free(expected);
    std.mem.replaceScalar(u8, expected, '/', '\\');

    var buf: [4096]u8 = @splat(0xaa);
    try std.testing.expectEqual(@as(usize, 0), getFullPath(relative, buf[0..expected.len]));
    const len = getFullPath(relative, buf[0 .. expected.len + 1]);
    try std.testing.expectEqualStrings(expected, buf[0..len]);
    try std.testing.expectEqual(@as(u8, 0), buf[len]);
    try std.testing.expectEqual(@as(u8, 0xaa), buf[len + 1]);

    @memcpy(buf[0..relative.len], relative);
    const aliased_len = getFullPath(buf[0..relative.len], &buf);
    try std.testing.expectEqualStrings(expected, buf[0..aliased_len]);
    try std.testing.expectEqual(@as(u8, 0), buf[aliased_len]);

    const source_offset = cwd_len + 16;
    @memcpy(buf[source_offset..][0..relative.len], relative);
    const overlapping_len = getFullPath(buf[source_offset..][0..relative.len], &buf);
    try std.testing.expectEqualStrings(expected, buf[0..overlapping_len]);
    try std.testing.expectEqual(@as(u8, 0), buf[overlapping_len]);
}

/// Create a std.Io.File from an integer file descriptor.
/// On POSIX, fd is used directly. On Windows, fd is cast to HANDLE.
/// This abstracts the platform difference so stubs can use integer fds everywhere.
pub fn fileFromFd(fd: i32) std.Io.File {
    const builtin_os = @import("builtin").target.os.tag;
    if (comptime builtin_os == .windows) {
        // For DLL builds: defer handle lookup to kernel32 stubs at runtime.
        // std.os.windows.GetStdHandle was removed in Zig 0.16.
        return std.Io.File{ .handle = @ptrFromInt(@as(usize, @intCast(fd))), .flags = .{ .nonblocking = false } };
    } else {
        return std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    }
}

// --- Internal helpers ---

/// Null-terminate a slice for passing to posix_fs functions.
fn nullTerminate(s: []const u8, buf: *[1025]u8) ?[*:0]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf);
}
