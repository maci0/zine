const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

/// The current working directory stored in narrow form.
pub var current_directory: [1024]u8 = undefined;
/// The length of the current working directory string.
pub var current_directory_len: usize = 0;

/// Retrieves the current directory for the current process.
/// Implementation status: Partially implemented (returns C:\ by default).
pub fn GetCurrentDirectoryA(nBufferLength: u32, lpBuffer: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCurrentDirectoryA(len={d})\n", .{nBufferLength});
    if (current_directory_len == 0) {
        // Initialize from actual host CWD in Win32 format
        const host_io = @import("../host_io.zig");
        const len = host_io.getCwd(&current_directory);
        current_directory_len = if (len > 0) len else blk: {
            const cwd = "C:\\";
            @memcpy(current_directory[0..cwd.len], cwd);
            break :blk cwd.len;
        };
    }

    if (lpBuffer != 0 and nBufferLength > current_directory_len) {
        const buf = @as([*]u8, @ptrFromInt(lpBuffer));
        @memcpy(buf[0..current_directory_len], current_directory[0..current_directory_len]);
        buf[current_directory_len] = 0;
        return @intCast(current_directory_len);
    }
    return @intCast(current_directory_len + 1);
}

/// Retrieves the current directory for the current process (Unicode version).
/// Implementation status: Partially implemented (returns C:\ by default).
pub fn GetCurrentDirectoryW(nBufferLength: u32, lpBuffer: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCurrentDirectoryW(len={d})\n", .{nBufferLength});
    if (current_directory_len == 0) {
        const cwd = "C:\\";
        @memcpy(current_directory[0..cwd.len], cwd);
        current_directory_len = cwd.len;
    }
    if (lpBuffer != 0 and nBufferLength > current_directory_len) {
        const buf = @as([*]u16, @ptrFromInt(lpBuffer));
        for (0..current_directory_len) |i| {
            buf[i] = current_directory[i];
        }
        buf[current_directory_len] = 0;
        return @intCast(current_directory_len);
    }
    return @intCast(current_directory_len + 1);
}

/// Changes the current directory for the current process.
/// Implementation status: Partially implemented.
pub fn SetCurrentDirectoryA(lpPathName: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPathName == 0) return 0;
    const path = trace.c_span(lpPathName);
    if (trace.enable_tracing) trace.print("KERNEL32: SetCurrentDirectoryA('{s}')\n", .{path});

    const copy_len = @min(path.len, 1023);
    @memcpy(current_directory[0..copy_len], path[0..copy_len]);
    current_directory_len = copy_len;
    current_directory[current_directory_len] = 0;
    return 1;
}

/// Changes the current directory for the current process (Unicode version).
/// Implementation status: Partially implemented (handles basic path conversion).
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
    @memcpy(current_directory[0..i], narrow[0..i]);
    current_directory_len = i;
    current_directory[i] = 0;
    return 1;
}

/// Retrieves the path of the Windows directory.
/// Implementation status: Partially implemented (returns C:\WINDOWS).
pub fn GetWindowsDirectoryA(lpBuffer: usize, uSize: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetWindowsDirectoryA(buffer={x}, size={d})\n", .{ lpBuffer, uSize });
    const win_dir = "C:\\WINDOWS";
    if (lpBuffer != 0 and uSize > win_dir.len) {
        const buf = @as([*]u8, @ptrFromInt(lpBuffer));
        @memcpy(buf[0..win_dir.len], win_dir);
        buf[win_dir.len] = 0;
        return @intCast(win_dir.len);
    }
    return @intCast(win_dir.len + 1);
}

/// Retrieves the full path and file name of the specified file.
/// Implementation status: Partially implemented.
pub fn GetFullPathNameA(lpFileName: usize, nBufferLength: u32, lpBuffer: usize, lpFilePart: usize) callconv(w32cc.WINAPI) u32 {
    if (lpFileName == 0) return 0;
    const name = trace.c_span(lpFileName);
    if (trace.enable_tracing) trace.print("KERNEL32: GetFullPathNameA('{s}')\n", .{name});
    if (lpBuffer == 0 or nBufferLength == 0) return @intCast(name.len + 1);

    const buf = @as([*]u8, @ptrFromInt(lpBuffer));
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
        @as(*u32, @ptrFromInt(lpFilePart)).* = @truncate(lpBuffer + last_sep);
    }
    return @intCast(result_len);
}

/// Retrieves the full path and file name of the specified file (Unicode version).
/// Implementation status: Partially implemented.
pub fn GetFullPathNameW(lpFileName: usize, nBufferLength: u32, lpBuffer: usize, lpFilePart: usize) callconv(w32cc.WINAPI) u32 {
    if (lpFileName == 0) return 0;
    const src = @as([*]const u16, @ptrFromInt(lpFileName));
    var len: u32 = 0;
    while (src[len] != 0) : (len += 1) {
        if (len >= 1024) break;
    }
    if (trace.enable_tracing) trace.print("KERNEL32: GetFullPathNameW(len={d})\n", .{len});
    if (lpBuffer != 0 and nBufferLength > len) {
        const buf = @as([*]u16, @ptrFromInt(lpBuffer));
        for (0..len) |i| buf[i] = src[i];
        buf[len] = 0;
        if (lpFilePart != 0) {
            var last_sep: u32 = 0;
            for (0..len) |i| {
                if (src[i] == '\\' or src[i] == '/') last_sep = @intCast(i + 1);
            }
            @as(*align(1) u32, @ptrFromInt(lpFilePart)).* = @intCast(lpBuffer + last_sep * 2);
        }
        return len;
    }
    return len + 1;
}

/// Creates a new directory.
/// Implementation status: Partially implemented (maps to Zig's makeDir).
pub fn CreateDirectoryA(lpPathName: usize, lpSecurityAttributes: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpSecurityAttributes;
    if (lpPathName == 0) return 0;
    const path = trace.c_span(lpPathName);
    if (trace.enable_tracing) trace.print("KERNEL32: CreateDirectoryA('{s}')\n", .{path});
    var fixed: [1024]u8 = undefined;
    const len = @min(path.len, 1023);
    @memcpy(fixed[0..len], path[0..len]);
    std.mem.replaceScalar(u8, fixed[0..len], '\\', '/');
    fixed[len] = 0;
    std.fs.cwd().makeDir(fixed[0..len]) catch return 0;
    return 1;
}

/// Determines whether a disk drive is a removable, fixed, CD-ROM, RAM disk, or network drive.
/// Implementation status: No-op fallback (returns DRIVE_FIXED).
pub fn stub_GetDriveTypeA(lpRootPathName: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpRootPathName;
    return 3; // DRIVE_FIXED
}

/// Determines whether a disk drive is a removable, fixed, CD-ROM, RAM disk, or network drive (Unicode version).
/// Implementation status: Stub (returns DRIVE_FIXED).
pub fn stub_GetDriveTypeW(lpRootPathName: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpRootPathName;
    return 3; // DRIVE_FIXED
}

/// Converts the specified path to its long form (Unicode version).
/// Implementation status: Partially implemented (currently performs identity mapping).
pub fn GetLongPathNameW(lpszShortPath: usize, lpszLongPath: usize, cchBuffer: u32) callconv(w32cc.WINAPI) u32 {
    if (lpszShortPath == 0) return 0;
    const src = @as([*]const u16, @ptrFromInt(lpszShortPath));
    var len: usize = 0;
    while (len < 4096 and src[len] != 0) len += 1;
    if (lpszLongPath != 0 and cchBuffer > len) {
        const dst = @as([*]u16, @ptrFromInt(lpszLongPath));
        for (0..len) |i| dst[i] = src[i];
        dst[len] = 0;
    }
    return @intCast(len);
}
