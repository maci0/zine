const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const path_utils = @import("../../path_utils.zig");
const w32cc = @import("../calling_convention.zig");

// The guest's virtual current directory is canonically stored in
// path_utils so path translation and these stubs share one source of truth.

/// Retrieves the current directory for the current process.
/// Implementation status: Partially implemented (returns C:\ by default)
pub fn GetCurrentDirectoryA(nBufferLength: u32, lpBuffer: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCurrentDirectoryA(len={d})\n", .{nBufferLength});
    if (path_utils.current_directory_len == 0) {
        // Initialize from actual host CWD in Win32 format
        const host_io = @import("../host_io.zig");
        const len = host_io.getCwd(&path_utils.current_directory);
        if (trace.enable_tracing) trace.print("KERNEL32: getCwd retrieved '{s}'\n", .{path_utils.current_directory[0..len]});
        path_utils.current_directory_len = if (len > 0) len else blk: {
            const cwd = "C:\\";
            @memcpy(path_utils.current_directory[0..cwd.len], cwd);
            break :blk cwd.len;
        };
    }

    if (lpBuffer != 0 and nBufferLength > path_utils.current_directory_len) {
        const host_buf = trace.addr(lpBuffer);
        const buf = @as([*]u8, @ptrFromInt(host_buf));
        @memcpy(buf[0..path_utils.current_directory_len], path_utils.current_directory[0..path_utils.current_directory_len]);
        buf[path_utils.current_directory_len] = 0;
        return @intCast(path_utils.current_directory_len);
    }
    return @intCast(path_utils.current_directory_len + 1);
}

/// Retrieves the current directory for the current process (Unicode version).
/// Implementation status: Partially implemented (returns C:\ by default)
pub fn GetCurrentDirectoryW(nBufferLength: u32, lpBuffer: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCurrentDirectoryW(len={d})\n", .{nBufferLength});
    if (path_utils.current_directory_len == 0) {
        const cwd = "C:\\";
        @memcpy(path_utils.current_directory[0..cwd.len], cwd);
        path_utils.current_directory_len = cwd.len;
    }
    if (lpBuffer != 0 and nBufferLength > path_utils.current_directory_len) {
        const host_buf = trace.addr(lpBuffer);
        const buf = @as([*]u16, @ptrFromInt(host_buf));
        for (0..path_utils.current_directory_len) |i| {
            buf[i] = path_utils.current_directory[i];
        }
        buf[path_utils.current_directory_len] = 0;
        return @intCast(path_utils.current_directory_len);
    }
    return @intCast(path_utils.current_directory_len + 1);
}

/// Changes the current directory for the current process.
/// Implementation status: Partially implemented
pub fn SetCurrentDirectoryA(lpPathName: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPathName == 0) return 0;
    const path = trace.c_span(lpPathName);
    if (trace.enable_tracing) trace.print("KERNEL32: SetCurrentDirectoryA('{s}')\n", .{path});

    const copy_len = @min(path.len, 1023);
    @memcpy(path_utils.current_directory[0..copy_len], path[0..copy_len]);
    path_utils.current_directory_len = copy_len;
    path_utils.current_directory[path_utils.current_directory_len] = 0;
    return 1;
}

/// Changes the current directory for the current process (Unicode version).
/// Implementation status: Partially implemented (handles basic path conversion)
pub fn SetCurrentDirectoryW(lpPathName: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPathName == 0) return 0;
    const wstr = @as([*]const u16, @ptrFromInt(lpPathName));
    var narrow: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < 1023 and wstr[i] != 0) : (i += 1) {
        narrow[i] = @intCast(wstr[i] & 0xFF);
    }
    narrow[i] = 0;
    if (trace.enable_tracing) trace.print("KERNEL32: SetCurrentDirectoryW('{s}')\n", .{narrow[0..i]});
    @memcpy(path_utils.current_directory[0..i], narrow[0..i]);
    path_utils.current_directory_len = i;
    path_utils.current_directory[i] = 0;
    return 1;
}

/// Retrieves the path of the Windows directory.
/// Implementation status: Partially implemented (returns C:\WINDOWS)
pub fn GetWindowsDirectoryA(lpBuffer: usize, uSize: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetWindowsDirectoryA(buffer={x}, size={d})\n", .{ lpBuffer, uSize });
    const win_dir = "C:\\WINDOWS";
    if (lpBuffer != 0 and uSize > win_dir.len) {
        const host_buf = trace.addr(lpBuffer);
        const buf = @as([*]u8, @ptrFromInt(host_buf));
        @memcpy(buf[0..win_dir.len], win_dir);
        buf[win_dir.len] = 0;
        return @intCast(win_dir.len);
    }
    return @intCast(win_dir.len + 1);
}

pub fn GetWindowsDirectoryW(lpBuffer: usize, uSize: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetWindowsDirectoryW(buffer={x}, size={d})\n", .{ lpBuffer, uSize });
    const win_dir = "C:\\WINDOWS";
    if (lpBuffer != 0 and uSize > win_dir.len) {
        const host_buf = trace.addr(lpBuffer);
        const buf = @as([*]u16, @ptrFromInt(host_buf));
        for (0..win_dir.len) |i| buf[i] = win_dir[i];
        buf[win_dir.len] = 0;
        return @intCast(win_dir.len);
    }
    return @intCast(win_dir.len + 1);
}

/// Retrieves the full path and file name of the specified file.
/// Implementation status: Partially implemented
pub fn GetFullPathNameA(lpFileName: usize, nBufferLength: u32, lpBuffer: usize, lpFilePart: usize) callconv(w32cc.WINAPI) u32 {
    if (lpFileName == 0) return 0;
    const name = trace.c_span(lpFileName);
    if (trace.enable_tracing) trace.print("KERNEL32: GetFullPathNameA('{s}')\n", .{name});
    if (lpBuffer == 0 or nBufferLength == 0) return @intCast(name.len + 1);

    const host_buf = trace.addr(lpBuffer);
    const buf = @as([*]u8, @ptrFromInt(host_buf));
    const host_io = @import("../host_io.zig");
    const resolved_len = host_io.getFullPath(name, buf[0..nBufferLength]);

    const result_len = if (resolved_len > 0) resolved_len else blk: {
        // Fallback: copy as-is
        if (nBufferLength <= name.len) break :blk @as(usize, 0);
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        break :blk name.len;
    };

    if (result_len > 0 and lpFilePart != 0) {
        var last_sep: usize = 0;
        for (0..result_len) |i| {
            if (buf[i] == '\\' or buf[i] == '/') last_sep = i + 1;
        }
        const host_fp = trace.addr(lpFilePart);
        @as(*u32, @ptrFromInt(host_fp)).* = @truncate(lpBuffer + last_sep);
    }
    return @intCast(result_len);
}

/// Retrieves the full path and file name of the specified file (Unicode version).
/// Implementation status: Partially implemented
pub fn GetFullPathNameW(lpFileName: usize, nBufferLength: u32, lpBuffer: usize, lpFilePart: usize) callconv(w32cc.WINAPI) u32 {
    if (lpFileName == 0) return 0;
    const src = @as([*]const u16, @ptrFromInt(lpFileName));
    var len: u32 = 0;
    while (src[len] != 0) : (len += 1) {
        if (len >= 1024) break;
    }
    if (trace.enable_tracing) trace.print("KERNEL32: GetFullPathNameW(len={d})\n", .{len});
    if (lpBuffer != 0 and nBufferLength > len) {
        const host_buf = trace.addr(lpBuffer);
        const buf = @as([*]u16, @ptrFromInt(host_buf));
        for (0..len) |i| buf[i] = src[i];
        buf[len] = 0;
        if (lpFilePart != 0) {
            var last_sep: u32 = 0;
            for (0..len) |i| {
                if (src[i] == '\\' or src[i] == '/') last_sep = @intCast(i + 1);
            }
            const host_fp = trace.addr(lpFilePart);
            @as(*align(1) u32, @ptrFromInt(host_fp)).* = @intCast(lpBuffer + last_sep * 2);
        }
        return len;
    }
    return len + 1;
}

/// Creates a new directory.
/// Implementation status: Partially implemented (maps to Zig's makeDir)
pub fn CreateDirectoryA(lpPathName: usize, lpSecurityAttributes: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpSecurityAttributes;
    if (lpPathName == 0) return 0;
    const path = trace.c_span(lpPathName);
    if (trace.enable_tracing) trace.print("KERNEL32: CreateDirectoryA('{s}')\n", .{path});
    var host_buf: [1024]u8 = undefined;
    // toHostPath maps Win32 paths into drive_c/ and anchors ".." there, so a
    // guest cannot create directories outside the virtual drive.
    const len = path_utils.toHostPath(path, &host_buf);
    if (len == 0) return 0;
    std.Io.Dir.cwd().createDirPath(runtime.io(), host_buf[0..len]) catch return 0;
    return 1;
}

/// Deletes an existing empty directory. Returns TRUE on success.
/// Implementation status: Fully implemented
pub fn RemoveDirectoryA(lpPathName: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPathName == 0) return 0;
    const path = trace.c_span(lpPathName);
    if (trace.enable_tracing) trace.print("KERNEL32: RemoveDirectoryA('{s}')\n", .{path});
    var host_buf: [1024]u8 = undefined;
    const host_len = path_utils.toHostPath(path, &host_buf);
    if (host_len == 0) return 0;

    if (!deleteDirHost(host_buf[0..host_len])) {
        // Case-insensitive fallback: lowercase the final component
        var last_sep: usize = 0;
        for (0..host_len) |i| {
            if (host_buf[i] == '/') last_sep = i + 1;
        }
        for (last_sep..host_len) |i| {
            host_buf[i] = std.ascii.toLower(host_buf[i]);
        }
        if (!deleteDirHost(host_buf[0..host_len])) return 0;
    }
    return 1;
}

fn deleteDirHost(host_path: []const u8) bool {
    if (comptime @import("builtin").target.os.tag == .linux) {
        var nt: [std.posix.PATH_MAX]u8 = undefined;
        if (host_path.len >= nt.len) return false;
        @memcpy(nt[0..host_path.len], host_path);
        nt[host_path.len] = 0;
        const rc = std.os.linux.rmdir(@ptrCast(&nt));
        return @as(isize, @bitCast(rc)) == 0;
    }
    std.Io.Dir.cwd().deleteDir(runtime.io(), host_path) catch return false;
    return true;
}

/// Determines whether a disk drive is a removable, fixed, CD-ROM, RAM disk, or network drive.
/// Implementation status: No-op fallback (returns DRIVE_FIXED)
pub fn stub_GetDriveTypeA(lpRootPathName: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpRootPathName;
    return 3; // DRIVE_FIXED
}

/// Determines whether a disk drive is a removable, fixed, CD-ROM, RAM disk, or network drive (Unicode version).
/// Implementation status: Stub (returns DRIVE_FIXED)
pub fn stub_GetDriveTypeW(lpRootPathName: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpRootPathName;
    return 3; // DRIVE_FIXED
}

/// Converts the specified path to its long form (Unicode version).
/// Implementation status: Partially implemented (currently performs identity mapping)
pub fn GetLongPathNameW(lpszShortPath: usize, lpszLongPath: usize, cchBuffer: u32) callconv(w32cc.WINAPI) u32 {
    if (lpszShortPath == 0) return 0;
    const src = @as([*]const u16, @ptrFromInt(lpszShortPath));
    var len: usize = 0;
    while (len < 4096 and src[len] != 0) len += 1;
    if (lpszLongPath != 0 and cchBuffer > len) {
        const host_buf = trace.addr(lpszLongPath);
        const dst = @as([*]u16, @ptrFromInt(host_buf));
        for (0..len) |i| dst[i] = src[i];
        dst[len] = 0;
    }
    return @intCast(len);
}
