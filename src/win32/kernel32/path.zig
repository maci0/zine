const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../../calling_convention.zig");

pub var current_directory: [1024]u8 = undefined;
pub var current_directory_len: usize = 0;

pub fn GetCurrentDirectoryA(nBufferLength: u32, lpBuffer: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCurrentDirectoryA(len={d})\n", .{nBufferLength});
    if (current_directory_len == 0) {
        const cwd = "C:\\";
        @memcpy(current_directory[0..cwd.len], cwd);
        current_directory_len = cwd.len;
    }

    if (lpBuffer != 0 and nBufferLength > current_directory_len) {
        const buf = @as([*]u8, @ptrFromInt(lpBuffer));
        @memcpy(buf[0..current_directory_len], current_directory[0..current_directory_len]);
        buf[current_directory_len] = 0;
        return @intCast(current_directory_len);
    }
    return @intCast(current_directory_len + 1);
}

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

// SetCurrentDirectoryW: properly handle wide string paths
pub fn SetCurrentDirectoryW(lpPathName: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPathName == 0) return 0;
    const wstr = @as([*]const u16, @ptrFromInt(lpPathName));
    // Convert wide to narrow
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

pub fn GetFullPathNameA(lpFileName: usize, nBufferLength: u32, lpBuffer: usize, lpFilePart: usize) callconv(w32cc.WINAPI) u32 {
    if (lpFileName == 0) return 0;
    const name = trace.c_span(lpFileName);
    if (trace.enable_tracing) trace.print("KERNEL32: GetFullPathNameA('{s}')\n", .{name});
    if (lpBuffer != 0 and nBufferLength > name.len) {
        const buf = @as([*]u8, @ptrFromInt(lpBuffer));
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        if (lpFilePart != 0) {
            var last_sep: usize = 0;
            for (0..name.len) |i| {
                if (name[i] == '\\' or name[i] == '/') last_sep = i + 1;
            }
            @as(*usize, @ptrFromInt(lpFilePart)).* = lpBuffer + last_sep;
        }
        return @intCast(name.len);
    }
    return @intCast(name.len + 1);
}

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

pub fn stub_GetDriveTypeA(lpRootPathName: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpRootPathName;
    return 3; // DRIVE_FIXED
}

// GetDriveTypeW: returns drive type for a root path
// DRIVE_FIXED = 3 (typical for hard drives)
pub fn stub_GetDriveTypeW(lpRootPathName: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpRootPathName;
    return 3; // DRIVE_FIXED
}

// GetLongPathNameW: just copies the input to the output (identity mapping)
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
