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

/// Check if a file exists / is accessible given a Win32 path.
/// Returns 0 if accessible, -1 if not.
pub fn access(win32_path: []const u8, mode: i32) i32 {
    var ntz_buf: [1025]u8 = undefined;
    const ntz = nullTerminate(win32_path, &ntz_buf) orelse return -1;
    return posix_fs.access(ntz, mode);
}

/// Get file status given a Win32 path. Returns null if not found.
pub fn stat(win32_path: []const u8) ?std.fs.File.Stat {
    var ntz_buf: [1025]u8 = undefined;
    const ntz = nullTerminate(win32_path, &ntz_buf) orelse return null;
    return posix_fs.stat(ntz);
}

/// Delete a file given a Win32 path. Returns true on success.
pub fn deleteFile(win32_path: []const u8) bool {
    var host_buf: [1024]u8 = undefined;
    const len = path_utils.toHostPath(win32_path, &host_buf);
    if (len == 0) return false;
    std.fs.cwd().deleteFile(host_buf[0..len]) catch return false;
    return true;
}

/// Get the current working directory in Win32 format (C:\...).
/// Returns the number of bytes written, or 0 on failure.
pub fn getCwd(buf: []u8) usize {
    const cwd = std.process.getCwdAlloc(std.heap.page_allocator) catch return 0;
    defer std.heap.page_allocator.free(cwd);

    var win_buf: [1024]u8 = undefined;
    const win_len = path_utils.posixToWin32(cwd, &win_buf) catch return 0;
    if (win_len == 0 or win_len >= buf.len) return 0;

    @memcpy(buf[0..win_len], win_buf[0..win_len]);
    buf[win_len] = 0;
    return win_len;
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
    if (pos + rel_path.len >= buf.len) return 0;
    @memcpy(cwd_buf[pos..][0..rel_path.len], rel_path);
    pos += rel_path.len;

    @memcpy(buf[0..pos], cwd_buf[0..pos]);
    std.mem.replaceScalar(u8, buf[0..pos], '/', '\\');
    buf[pos] = 0;
    return pos;
}

/// Search for a file in a set of directories (semicolon-separated Win32 paths).
/// Also searches the main EXE directory. Returns the full Win32 path or empty.
pub fn searchPath(filename: []const u8, search_dirs: ?[]const u8, result: []u8) usize {
    const kernel32 = @import("kernel32.zig");

    // First: check the main EXE's directory
    if (kernel32.main_exe_dir_len > 0 and filename.len > 0) {
        const dir = kernel32.main_exe_dir[0..kernel32.main_exe_dir_len];
        if (dir.len + filename.len < result.len) {
            @memcpy(result[0..dir.len], dir);
            @memcpy(result[dir.len..][0..filename.len], filename);
            const total = dir.len + filename.len;
            result[total] = 0;
            // Check if this file exists
            if (access(result[0..total], 0) == 0) {
                return total;
            }
        }
    }

    // Then: search the provided directories
    if (search_dirs) |dirs| {
        var it = std.mem.splitScalar(u8, dirs, ';');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            if (dir.len + 1 + filename.len >= result.len) continue;

            @memcpy(result[0..dir.len], dir);
            var pos = dir.len;
            if (result[pos - 1] != '\\' and result[pos - 1] != '/') {
                result[pos] = '\\';
                pos += 1;
            }
            @memcpy(result[pos..][0..filename.len], filename);
            pos += filename.len;
            result[pos] = 0;

            if (access(result[0..pos], 0) == 0) {
                return pos;
            }
        }
    }

    return 0; // Not found
}

/// Create a std.fs.File from an integer file descriptor.
/// On POSIX, fd is used directly. On Windows, fd is cast to HANDLE.
/// This abstracts the platform difference so stubs can use integer fds everywhere.
pub fn fileFromFd(fd: i32) std.fs.File {
    const builtin_os = @import("builtin").os.tag;
    if (comptime builtin_os == .windows) {
        // On Windows, small integers 0-2 are stdin/stdout/stderr
        // Use GetStdHandle for those, otherwise treat as raw HANDLE
        const windows = std.os.windows;
        const handle: windows.HANDLE = switch (fd) {
            0 => windows.GetStdHandle(windows.STD_INPUT_HANDLE) catch windows.INVALID_HANDLE_VALUE,
            1 => windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch windows.INVALID_HANDLE_VALUE,
            2 => windows.GetStdHandle(windows.STD_ERROR_HANDLE) catch windows.INVALID_HANDLE_VALUE,
            else => @ptrFromInt(@as(usize, @intCast(fd))),
        };
        return std.fs.File{ .handle = handle };
    } else {
        return std.fs.File{ .handle = fd };
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
