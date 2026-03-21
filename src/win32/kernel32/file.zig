
const std = @import("std");
const trace = @import("../../trace.zig");
const kernel32_mem = @import("mem.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const platform = @import("../../platform.zig");
const host_io = @import("../host_io.zig");

// KERNEL32.dll file I/O functions.
/// Retrieves file system attributes for a specified file or directory.
/// Implementation status: Partially implemented (supports basic attributes and directory detection)
pub fn GetFileAttributesA(lpFileName_ptr: usize) callconv(w32cc.WINAPI) u32 {
    if (lpFileName_ptr == 0) return w32.INVALID_FILE_ATTRIBUTES;
    const filename = trace.c_span(lpFileName_ptr);

    if (trace.enable_tracing) trace.print("KERNEL32: GetFileAttributesA('{s}')\n", .{filename});

    const path_utils = @import("../../path_utils.zig");
    var host_buf: [1024]u8 = undefined;
    const host_len = path_utils.toHostPath(filename, &host_buf);
    if (host_len == 0) return w32.INVALID_FILE_ATTRIBUTES;

    const posix_fs = @import("../msvcrt/posix_fs.zig");
    // fsStat is now private, use stat which handles everything
    if (posix_fs.stat(@as([*:0]const u8, @ptrCast(@constCast(filename.ptr))))) |stat_buf| {
        if (stat_buf.kind == .directory) return w32.FILE_ATTRIBUTE_DIRECTORY;
        return w32.FILE_ATTRIBUTE_NORMAL;
    }

    return w32.INVALID_FILE_ATTRIBUTES;
}

/// Retrieves the size of the specified file.
/// Implementation status: Partially implemented
pub fn GetFileSize(hFile: usize, lpFileSizeHigh: usize) callconv(w32cc.WINAPI) u32 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: GetFileSize(hFile={d})\n", .{fd});

    const file = host_io.fileFromFd(fd);
    if (file.stat() catch null) |stat| {
        if (lpFileSizeHigh != 0) {
            const high = @as(*u32, @ptrFromInt(lpFileSizeHigh));
            high.* = @intCast(stat.size >> 32);
        }
        if (trace.enable_tracing) trace.print("KERNEL32: GetFileSize -> {d}\n", .{stat.size});
        return @as(u32, @intCast(stat.size & 0xFFFFFFFF));
    }
    if (trace.enable_tracing) trace.print("KERNEL32: GetFileSize -> FAILED\n", .{});
    return w32.INVALID_FILE_SIZE;
}

/// Retrieves the type of the specified file.
/// Implementation status: Partially implemented
pub fn GetFileType(hFile: usize) callconv(w32cc.WINAPI) u32 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: GetFileType(hFile={d})\n", .{fd});
    if (fd == 0 or fd == 1 or fd == 2) return w32.FILE_TYPE_CHAR;
    return w32.FILE_TYPE_DISK;
}

/// Retrieves file information for the specified file.
/// Implementation status: Partially implemented
pub fn GetFileInformationByHandle(hFile: usize, file_info: *w32.BY_HANDLE_FILE_INFORMATION) callconv(w32cc.WINAPI) i32 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: GetFileInformationByHandle(hFile={d})\n", .{fd});

    {
        const file = host_io.fileFromFd(fd);
        if (file.stat() catch null) |stat| {
            file_info.* = .{};
            file_info.dwFileAttributes = w32.FILE_ATTRIBUTE_NORMAL;
            file_info.nFileSizeHigh = @intCast(stat.size >> 32);
            file_info.nFileSizeLow = @intCast(stat.size & 0xFFFFFFFF);
            file_info.nNumberOfLinks = 1;
            file_info.nFileIndexLow = @as(u32, @bitCast(@as(i32, @intCast(stat.inode))));

            return 1;
        }
    }
    return 0;
}

/// Creates or opens a file or I/O device.
/// Implementation status: Partially implemented (supports basic file creation and opening)
pub fn CreateFileA(lpFileName_ptr: usize, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: usize, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: usize) callconv(w32cc.WINAPI) usize {
    _ = dwDesiredAccess;
    _ = dwShareMode;
    _ = lpSecurityAttributes;
    _ = dwFlagsAndAttributes;
    _ = hTemplateFile;
    if (lpFileName_ptr == 0) return w32.INVALID_HANDLE_VALUE;

    const name = trace.c_span(lpFileName_ptr);

    const path_utils = @import("../../path_utils.zig");
    var fixed_path: [1024]u8 = undefined;
    const len = path_utils.win32ToPosix(name, &fixed_path);
    const fixed_slice = fixed_path[0..len];
    fixed_path[len] = 0;

    if (trace.enable_tracing) trace.print("KERNEL32: CreateFileA('{s}', disp={d})\n", .{ fixed_slice, dwCreationDisposition });

    // Device paths (\\.\DeviceName) — return fake handles for known devices
    if (name.len > 4 and name[0] == '\\' and name[1] == '\\' and name[2] == '.' and name[3] == '\\') {
        if (trace.enable_tracing) trace.print("KERNEL32: CreateFileA device: '{s}'\n", .{name[4..]});
        // cpuidsdk driver device — return a fake handle
        if (std.ascii.eqlIgnoreCase(name[4..], "CpuidSDK") or
            std.ascii.eqlIgnoreCase(name[4..], "cpuz135"))
        {
            if (trace.enable_tracing) trace.print("KERNEL32: CreateFileA -> fake device handle 0xFE000100\n", .{});
            return 0xFE000100; // Fake device handle
        }
        return w32.INVALID_HANDLE_VALUE;
    }

    // 1=CREATE_NEW, 2=CREATE_ALWAYS, 3=OPEN_EXISTING, 4=OPEN_ALWAYS, 5=TRUNCATE_EXISTING
    const posix_fs = @import("../msvcrt/posix_fs.zig");
    const O_CREAT = posix_fs.O_CREAT;
    const O_RDWR = posix_fs.O_RDWR;
    const O_TRUNC = posix_fs.O_TRUNC;

    if (dwCreationDisposition == w32.CREATE_NEW or dwCreationDisposition == w32.CREATE_ALWAYS or dwCreationDisposition == w32.OPEN_ALWAYS or dwCreationDisposition == w32.TRUNCATE_EXISTING) {
        var flags: u32 = O_CREAT | O_RDWR;
        if (dwCreationDisposition == w32.CREATE_ALWAYS or dwCreationDisposition == w32.TRUNCATE_EXISTING) flags |= O_TRUNC;

        var rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed_path)), flags, 0o666);
        if (rc < 0) {
            var last_slash: usize = 0;
            for (0..len) |i| {
                if (fixed_path[i] == '/') last_slash = i + 1;
            }
            for (last_slash..len) |i| {
                fixed_path[i] = std.ascii.toLower(fixed_path[i]);
            }
            rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed_path)), flags, 0o666);
        }
        if (rc >= 0) return @as(usize, @intCast(rc));

        if (trace.enable_tracing) trace.print("  -> createFile failed\n", .{});
    } else {
        // Try original name RDWR
        var rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed_path)), O_RDWR, 0);
        if (rc >= 0) return @as(usize, @intCast(rc));

        // Try original name RDONLY
        rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed_path)), 0, 0);
        if (rc >= 0) return @as(usize, @intCast(rc));

        // Try lowercase name RDWR
        var last_slash: usize = 0;
        for (0..len) |i| {
            if (fixed_path[i] == '/') last_slash = i + 1;
        }
        for (last_slash..len) |i| {
            fixed_path[i] = std.ascii.toLower(fixed_path[i]);
        }

        rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed_path)), O_RDWR, 0);
        if (rc >= 0) return @as(usize, @intCast(rc));

        // Try lowercase name RDONLY
        rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed_path)), 0, 0);
        if (rc >= 0) return @as(usize, @intCast(rc));

        if (trace.enable_tracing) trace.print("  -> openFile failed\n", .{});
    }
    return w32.INVALID_HANDLE_VALUE;
}

const MAX_MAPPINGS = 64;
var mapping_fds: [MAX_MAPPINGS]i32 = [_]i32{-1} ** MAX_MAPPINGS;

fn alloc_mapping(fd: i32) ?usize {
    for (0..MAX_MAPPINGS) |i| {
        if (mapping_fds[i] == -1) {
            mapping_fds[i] = fd;
            return 0x40000000 | @as(usize, @intCast(i));
        }
    }
    return null;
}

/// Creates or opens a named or unnamed file mapping object for a specified file.
/// Implementation status: Partially implemented
pub fn CreateFileMappingA(hFile: usize, lpFileMappingAttributes: usize, flProtect: u32, dwMaximumSizeHigh: u32, dwMaximumSizeLow: u32, lpName_ptr: usize) callconv(w32cc.WINAPI) usize {
    _ = lpFileMappingAttributes;
    _ = flProtect;
    _ = dwMaximumSizeHigh;
    _ = lpName_ptr;
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: CreateFileMappingA(hFile={d}, max_size={d})\n", .{ fd, dwMaximumSizeLow });

    if (hFile != 0xFFFFFFFF) {
        if (dwMaximumSizeLow > 0) {
            const file = host_io.fileFromFd(fd);
            if (file.stat() catch null) |stat| {
                if (stat.size < dwMaximumSizeLow) {
                    if (trace.enable_tracing) trace.print("KERNEL32: extending file to {d}\n", .{dwMaximumSizeLow});
                    file.setEndPos(@intCast(dwMaximumSizeLow)) catch |err| {
                        if (trace.enable_tracing) trace.print("KERNEL32: setEndPos failed: {}\n", .{err});
                    };
                }
            }
        }
        if (alloc_mapping(fd)) |mapping_handle| {
            return mapping_handle;
        }
    }
    return 0; // NULL
}

/// Maps a view of a file mapping into the address space of a calling process.
/// Implementation status: Partially implemented
pub fn MapViewOfFileEx(hFileMappingObject: usize, dwDesiredAccess: u32, dwFileOffsetHigh: u32, dwFileOffsetLow: u32, dwNumberOfBytesToMap: usize, lpBaseAddress: usize) callconv(w32cc.WINAPI) usize {
    if ((hFileMappingObject & 0xFFFF0000) == 0x40000000) {
        const idx = hFileMappingObject & 0xFFFF;
        if (idx < MAX_MAPPINGS and mapping_fds[idx] != -1) {
            const fd = mapping_fds[idx];
            if (trace.enable_tracing) trace.print("KERNEL32: MapViewOfFileEx(mapping={x}, fd={d}, offsetHigh={d}, offsetLow={d}, bytes={d}, base={x})\n", .{ hFileMappingObject, fd, dwFileOffsetHigh, dwFileOffsetLow, dwNumberOfBytesToMap, lpBaseAddress });

            const file = host_io.fileFromFd(fd);
            const stat = file.stat() catch return 0;

            if (stat.size > 0 or dwNumberOfBytesToMap > 0) {
                const offset = (@as(u64, dwFileOffsetHigh) << 32) | @as(u64, dwFileOffsetLow);
                const map_size = if (dwNumberOfBytesToMap > 0) dwNumberOfBytesToMap else @as(usize, @intCast(stat.size));

                // FILE_MAP_WRITE is 2, FILE_MAP_ALL_ACCESS includes 2
                const is_write = (dwDesiredAccess & 2) != 0 or dwDesiredAccess == 0xF001F;

                var memory: []align(4096) u8 = undefined;
                if (lpBaseAddress != 0) {
                    memory = platform.mmap(@ptrFromInt(lpBaseAddress), map_size, false, fd, offset, is_write, true) catch |err| {
                        if (trace.enable_tracing) trace.print("KERNEL32: MapViewOfFileEx FIXED mmap failed: {}\n", .{err});
                        return 0;
                    };
                } else {
                    const hint = kernel32_mem.get_aligned_hint(@intCast(map_size));
                    memory = platform.mmap(@ptrFromInt(hint), map_size, false, fd, offset, is_write, false) catch |err| {
                        if (trace.enable_tracing) trace.print("KERNEL32: MapViewOfFileEx HINT mmap failed: {}\n", .{err});
                        return 0;
                    };
                }

                if (trace.enable_tracing) {
                    trace.print("KERNEL32: MapViewOfFileEx -> {x} [", .{@intFromPtr(memory.ptr)});
                    if (stat.size >= 4) {
                        trace.print("{x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{ memory[0], memory[1], memory[2], memory[3] });
                    }
                    trace.print("]\n", .{});
                }
                return @intFromPtr(memory.ptr);
            }
        }
    }
    return 0;
}

/// DeviceIoControl — send a control code to a device driver.
/// Implementation status: Partially implemented (cpuidsdk device stub)
pub fn DeviceIoControl(hDevice: usize, dwIoControlCode: u32, lpInBuffer: usize, nInBufferSize: u32, lpOutBuffer: usize, nOutBufferSize: u32, lpBytesReturned: usize, lpOverlapped: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpOverlapped;
    if (trace.enable_tracing) trace.print("KERNEL32: DeviceIoControl(dev={x}, ioctl={x}, inSz={d}, outSz={d})\n", .{ hDevice, dwIoControlCode, nInBufferSize, nOutBufferSize });

    // cpuidsdk device handle
    if (hDevice == 0xFE000100) {
        // Log input buffer for analysis
        if (lpInBuffer != 0 and nInBufferSize >= 4) {
            const inp = @as([*]const u32, @ptrFromInt(lpInBuffer));
            const n = @min(nInBufferSize / 4, 8);
            trace.print("  DeviceIoControl input:", .{});
            for (0..n) |i| trace.print(" {x}", .{inp[i]});
            trace.print("\n", .{});
        }

        // Return success with 0 bytes returned — cpuidsdk will check the output
        if (lpBytesReturned != 0) @as(*u32, @ptrFromInt(lpBytesReturned)).* = 0;
        // Zero the output buffer
        if (lpOutBuffer != 0 and nOutBufferSize > 0) {
            @memset(@as([*]u8, @ptrFromInt(lpOutBuffer))[0..nOutBufferSize], 0);
        }
        return 1; // TRUE = success
    }

    // Generic stub: return FALSE
    return 0;
}

/// Unmaps a mapped view of a file from the calling process's address space.
/// Implementation status: Stub
pub fn UnmapViewOfFile(lpBaseAddress: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: UnmapViewOfFile({x})\n", .{lpBaseAddress});
    return 1;
}

/// Closes an open object handle.
/// Implementation status: Fully implemented (handles both real fds and synthetic handles)
pub fn CloseHandle(hObject: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: CloseHandle({x})\n", .{hObject});

    // Don't close synthetic handles (events, mutexes, process handles, etc.)
    // Real file descriptors are small integers; synthetic handles use high ranges.
    if (hObject >= 0x10000) return 1; // synthetic handle, no-op

    // Don't close stdin/stdout/stderr
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hObject))));
    if (fd <= 2) return 1;

    const file = host_io.fileFromFd(fd);
    file.close();
    return 1; // TRUE
}

/// Moves the file pointer of the specified file.
/// Implementation status: Partially implemented
pub fn SetFilePointer(hFile: usize, lDistanceToMove: i32, lpDistanceToMoveHigh: usize, dwMoveMethod: u32) callconv(w32cc.WINAPI) u32 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: SetFilePointer(hFile={d}, dist={d}, method={d})\n", .{ fd, lDistanceToMove, dwMoveMethod });

    const file = host_io.fileFromFd(fd);

    switch (dwMoveMethod) {
        0 => { // FILE_BEGIN
            if (lDistanceToMove < 0) return 0xFFFFFFFF;
            file.seekTo(@intCast(lDistanceToMove)) catch return 0xFFFFFFFF;
        },
        1 => { // FILE_CURRENT
            const pos = file.getPos() catch return 0xFFFFFFFF;
            const new_pos = @as(i64, @intCast(pos)) + @as(i64, lDistanceToMove);
            if (new_pos < 0) return 0xFFFFFFFF;
            file.seekTo(@intCast(new_pos)) catch return 0xFFFFFFFF;
        },
        2 => { // FILE_END
            const end = file.getEndPos() catch return 0xFFFFFFFF;
            const new_pos = @as(i64, @intCast(end)) + @as(i64, lDistanceToMove);
            if (new_pos < 0) return 0xFFFFFFFF;
            file.seekTo(@intCast(new_pos)) catch return 0xFFFFFFFF;
        },
        else => return 0xFFFFFFFF,
    }

    const final_pos = file.getPos() catch return 0xFFFFFFFF;
    if (lpDistanceToMoveHigh != 0) {
        const high = @as(*i32, @ptrFromInt(lpDistanceToMoveHigh));
        high.* = @intCast(final_pos >> 32);
    }

    if (trace.enable_tracing) trace.print("KERNEL32: SetFilePointer -> {d}\n", .{final_pos});
    return @intCast(final_pos & 0xFFFFFFFF);
}

/// Reads data from the specified file or I/O device.
/// Implementation status: Fully implemented
pub fn ReadFile(hFile: usize, lpBuffer: usize, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: usize, lpOverlapped: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpOverlapped;
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: ReadFile(hFile={d}, len={d})\n", .{ fd, nNumberOfBytesToRead });

    const file = host_io.fileFromFd(fd);
    if (lpBuffer != 0) {
        const buffer = @as([*]u8, @ptrFromInt(lpBuffer));
        const bytes_read = file.read(buffer[0..nNumberOfBytesToRead]) catch return 0; // FALSE

        if (lpNumberOfBytesRead != 0) {
            const read_ptr = @as(*u32, @ptrFromInt(lpNumberOfBytesRead));
            read_ptr.* = @intCast(bytes_read);
        }

        if (trace.enable_tracing) trace.print("KERNEL32: ReadFile -> {d}\n", .{bytes_read});
        return 1; // TRUE
    }
    return 0; // FALSE
}

/// Retrieves a handle for the specified standard device (standard input, standard output, or standard error).
/// Implementation status: Fully implemented
pub fn GetStdHandle(nStdHandle: u32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GetStdHandle({d})\n", .{nStdHandle});
    const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
    const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
    return switch (nStdHandle) {
        STD_INPUT_HANDLE => 0,
        STD_OUTPUT_HANDLE => 1,
        STD_ERROR_HANDLE => 2,
        else => 0,
    };
}

/// Retrieves the path of the directory designated for temporary files.
/// Implementation status: Partially implemented (returns hardcoded path)
pub fn GetTempPathA(nBufferLength: u32, lpBuffer: usize) callconv(w32cc.WINAPI) u32 {
    const temp_path = ".\\\x00";
    if (trace.enable_tracing) trace.print("KERNEL32: GetTempPathA(len={d})\n", .{nBufferLength});
    if (lpBuffer != 0 and nBufferLength > temp_path.len) {
        const buf = @as([*]u8, @ptrFromInt(lpBuffer));
        @memcpy(buf[0..temp_path.len], temp_path);
        return temp_path.len - 1;
    }
    return temp_path.len;
}

var temp_counter: u32 = 0;

/// Creates a name for a temporary file.
/// Implementation status: Partially implemented
pub fn GetTempFileNameA(lpPathName: usize, lpPrefixString: usize, uUnique: u32, lpTempFileName: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const path = if (lpPathName != 0) trace.c_span(lpPathName) else "null";
        const prefix = if (lpPrefixString != 0) trace.c_span(lpPrefixString) else "null";
        trace.print("KERNEL32: GetTempFileNameA(path='{s}', prefix='{s}', unique={d})\n", .{ path, prefix, uUnique });
    }
    if (lpTempFileName != 0) {
        const buf = @as([*]u8, @ptrFromInt(lpTempFileName));
        temp_counter += 1;
        const uniq = if (uUnique == 0) temp_counter else uUnique;

        var name_buf: [256]u8 = undefined;
        const name_slice = std.fmt.bufPrintZ(&name_buf, ".\\t_{d}.tmp", .{uniq}) catch ".\\t_999.tmp\x00";

        @memcpy(buf[0 .. name_slice.len + 1], name_slice.ptr[0 .. name_slice.len + 1]);

        if (uUnique == 0) {
            const posix_fs = @import("../msvcrt/posix_fs.zig");
            var fixed_buf: [256]u8 = undefined;
            const fixed_slice = std.fmt.bufPrintZ(&fixed_buf, "./t_{d}.tmp", .{uniq}) catch "./t_999.tmp\x00";
            const rc = posix_fs.open(fixed_slice.ptr, 64 | 2, 0o666);
            if (rc >= 0) {
                const f = host_io.fileFromFd(@intCast(rc));
                f.close();
            }
        }
        return uniq; // Unique ID
    }
    return 0;
}

/// Deletes an existing file.
/// Implementation status: Fully implemented
pub fn DeleteFileA(lpFileName: usize) callconv(w32cc.WINAPI) i32 {
    if (lpFileName == 0) return 0;
    const name = trace.c_span(lpFileName);
    if (trace.enable_tracing) trace.print("KERNEL32: DeleteFileA('{s}')\n", .{name});

    const path_utils = @import("../../path_utils.zig");
    var fixed_path: [1024]u8 = undefined;
    const len = path_utils.win32ToPosix(name, &fixed_path);

    const cwd = std.fs.cwd();
    cwd.deleteFile(fixed_path[0..len]) catch {
        // Try case-insensitive: lowercase the filename portion
        var last_slash: usize = 0;
        for (0..len) |i| {
            if (fixed_path[i] == '/') last_slash = i + 1;
        }
        for (last_slash..len) |i| {
            fixed_path[i] = std.ascii.toLower(fixed_path[i]);
        }
        cwd.deleteFile(fixed_path[0..len]) catch return 0;
    };
    return 1; // TRUE
}

/// Sets the physical file size for the specified file to the current position of the file pointer.
/// Implementation status: Fully implemented
pub fn SetEndOfFile(hFile: usize) callconv(w32cc.WINAPI) i32 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: SetEndOfFile(hFile={d})\n", .{fd});
    const file = host_io.fileFromFd(fd);
    const pos = file.getPos() catch return 0;
    file.setEndPos(pos) catch return 0;
    return 1; // TRUE
}

/// Searches for a specified file in a specified path.
/// Implementation status: Partially implemented
pub fn SearchPathA(lpPath_ptr: usize, lpFileName_ptr: usize, lpExtension_ptr: usize, nBufferLength: u32, lpBuffer_ptr: ?[*]u8, lpFilePart_ptr: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpPath_ptr;
    if (lpFileName_ptr == 0) return 0;
    const filename = trace.c_span(lpFileName_ptr);
    const extension = if (lpExtension_ptr != 0) trace.c_span(lpExtension_ptr) else "";

    if (trace.enable_tracing) trace.print("KERNEL32: SearchPathA('{s}')\n", .{filename});

    var fixed_path: [1024]u8 = undefined;

    // Helper to check if file exists
    const posix_fs = @import("../msvcrt/posix_fs.zig");
    const check_exists = struct {
        fn check(path: []const u8, buf: *[1024]u8) bool {
            const len = @min(path.len, 1023);
            @memcpy(buf[0..len], path[0..len]);
            std.mem.replaceScalar(u8, buf[0..len], '\\', '/');
            buf[len] = 0;
            return posix_fs.access(@as([*:0]const u8, @ptrCast(buf)), 0) == 0; // F_OK
        }
    }.check;

    var found_path: ?[]const u8 = null;

    // First try exactly as provided
    if (check_exists(filename, &fixed_path)) {
        found_path = filename;
    } else {
        // Try with extension if it doesn't have one and extension is provided
        var has_ext = false;
        for (filename) |c| {
            if (c == '.') has_ext = true;
        }
        if (!has_ext and extension.len > 0) {
            var ext_path: [1024]u8 = undefined;
            if (filename.len + extension.len < 1023) {
                @memcpy(ext_path[0..filename.len], filename);
                @memcpy(ext_path[filename.len .. filename.len + extension.len], extension);
                const full = ext_path[0 .. filename.len + extension.len];
                if (check_exists(full, &fixed_path)) {
                    found_path = full;
                }
            }
        }
    }

    // If not found, try PATH
    var resolved_path: [1024]u8 = undefined;
    if (found_path == null) {
        const msvcrt = @import("../msvcrt.zig");
        var env_i: usize = 0;
        while (msvcrt.global_envp[env_i]) |e_ptr| : (env_i += 1) {
            const e_str = trace.c_span(@intFromPtr(e_ptr));
            if (e_str.len > 5 and e_str[0] == 'P' and e_str[1] == 'A' and e_str[2] == 'T' and e_str[3] == 'H' and e_str[4] == '=') {
                const paths = e_str[5..];
                var path_start: usize = 0;
                while (path_start < paths.len) {
                    var path_end = path_start;
                    while (path_end < paths.len and paths[path_end] != ':' and paths[path_end] != ';') : (path_end += 1) {}
                    const p = paths[path_start..path_end];

                    if (p.len > 0 and p.len + 1 + filename.len < 1023) {
                        @memcpy(resolved_path[0..p.len], p);
                        resolved_path[p.len] = '/';
                        @memcpy(resolved_path[p.len + 1 .. p.len + 1 + filename.len], filename);
                        const p_full = resolved_path[0 .. p.len + 1 + filename.len];
                        if (check_exists(p_full, &fixed_path)) {
                            found_path = p_full;
                            break;
                        }
                    }
                    path_start = path_end + 1;
                }
                break;
            }
        }
    }

    if (found_path) |found| {
        const len = found.len;
        if (lpBuffer_ptr != null and nBufferLength > len) {
            const out_buf = lpBuffer_ptr orelse return 0;
            @memcpy(out_buf[0..len], found);
            // Replace forward slashes back to backslashes for Win32 callers
            std.mem.replaceScalar(u8, out_buf[0..len], '/', '\\');
            out_buf[len] = 0;
            if (lpFilePart_ptr != 0) {
                // Find last slash for file part
                var last_slash: usize = 0;
                for (0..len) |i| {
                    if (out_buf[i] == '\\') last_slash = i + 1;
                }
                @as(*u32, @ptrFromInt(lpFilePart_ptr)).* = @truncate(@intFromPtr(out_buf) + last_slash);
            }
            return @intCast(len);
        }
        return @intCast(len + 1);
    }

    return 0; // Not found
}

// Pool of find handles for concurrent FindFirstFileA/FindNextFileA
const MAX_FIND_HANDLES = 16;
const FIND_HANDLE_BASE = 0xF1AD0000;

const FindHandleState = struct {
    in_use: bool = false,
    dir: ?std.fs.Dir = null,
    iter: ?std.fs.Dir.Iterator = null,
    pattern: [256]u8 = undefined,
    pattern_len: usize = 0,
    dir_path: [1024]u8 = undefined,
    dir_path_len: usize = 0,

    fn close(self: *FindHandleState) void {
        if (self.dir) |*d| {
            d.close();
        }
        self.dir = null;
        self.iter = null;
        self.in_use = false;
    }
};

var find_handles: [MAX_FIND_HANDLES]FindHandleState = [_]FindHandleState{.{}} ** MAX_FIND_HANDLES;

fn allocFindHandle() ?usize {
    for (0..MAX_FIND_HANDLES) |i| {
        if (!find_handles[i].in_use) {
            find_handles[i].in_use = true;
            return FIND_HANDLE_BASE + i;
        }
    }
    return null;
}

fn getFindHandle(handle: usize) ?*FindHandleState {
    if (handle >= FIND_HANDLE_BASE and handle < FIND_HANDLE_BASE + MAX_FIND_HANDLES) {
        const idx = handle - FIND_HANDLE_BASE;
        if (find_handles[idx].in_use) return &find_handles[idx];
    }
    return null;
}

fn matchWildcard(name: []const u8, pattern: []const u8) bool {
    // Simple *.ext matching (case-insensitive)
    if (pattern.len >= 2 and pattern[0] == '*' and pattern[1] == '.') {
        const ext = pattern[1..]; // ".ext"
        if (name.len < ext.len) return false;
        return std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext);
    }
    // Simple * matches everything
    if (pattern.len == 1 and pattern[0] == '*') return true;
    // Literal comparison (case-insensitive)
    return std.ascii.eqlIgnoreCase(name, pattern);
}

/// Searches a directory for a file or subdirectory with a name that matches a specific name.
/// Implementation status: Partially implemented
pub fn FindFirstFileA(lpFileName_ptr: usize, lpFindFileData_ptr: *align(1) w32.WIN32_FIND_DATAA) callconv(w32cc.WINAPI) usize {
    if (lpFileName_ptr == 0) return w32.INVALID_HANDLE_VALUE;

    const filename = trace.c_span(lpFileName_ptr);
    if (trace.enable_tracing) trace.print("KERNEL32: FindFirstFileA('{s}')\n", .{filename});

    // Convert path using win32ToPosix
    const path_utils = @import("../../path_utils.zig");
    var fixed_buf: [1024]u8 = undefined;
    const len = path_utils.win32ToPosix(filename, &fixed_buf);
    const fixed_slice = fixed_buf[0..len];

    // Split into directory and file pattern at last slash
    var last_slash: usize = 0;
    var has_slash = false;
    for (0..len) |i| {
        if (fixed_buf[i] == '/') {
            last_slash = i;
            has_slash = true;
        }
    }

    const pattern = if (has_slash) fixed_buf[last_slash + 1 .. len] else fixed_slice;
    const dir_path = if (has_slash) fixed_buf[0..last_slash] else ".";

    // Check if pattern has wildcards
    var has_wildcard = false;
    for (pattern) |c| {
        if (c == '*' or c == '?') {
            has_wildcard = true;
            break;
        }
    }

    if (has_wildcard) {
        // Allocate a find handle from the pool
        const handle = allocFindHandle() orelse {
            if (trace.enable_tracing) trace.print("  -> FindFirstFileA: no free find handles\n", .{});
            return w32.INVALID_HANDLE_VALUE;
        };
        const state = getFindHandle(handle).?;

        // Store pattern for FindNextFileA
        @memcpy(state.pattern[0..pattern.len], pattern);
        state.pattern_len = pattern.len;

        // Try opening directory (with case-insensitive fallback)
        var resolved_dir = dir_path;
        var ci_buf: [1024]u8 = undefined;

        const d = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch blk: {
            // Try case-insensitive resolution
            resolved_dir = path_utils.tryCaseInsensitiveResolve(dir_path, &ci_buf) orelse {
                if (trace.enable_tracing) trace.print("  -> FindFirstFileA: dir not found\n", .{});
                state.close();
                return w32.INVALID_HANDLE_VALUE;
            };
            break :blk std.fs.cwd().openDir(resolved_dir, .{ .iterate = true }) catch {
                if (trace.enable_tracing) trace.print("  -> FindFirstFileA: resolved dir not found\n", .{});
                state.close();
                return w32.INVALID_HANDLE_VALUE;
            };
        };

        @memcpy(state.dir_path[0..resolved_dir.len], resolved_dir);
        state.dir_path_len = resolved_dir.len;
        state.dir = d;
        state.iter = d.iterate();

        // Find first matching entry
        const result = FindNextFileA(handle, lpFindFileData_ptr);
        if (result != 0) return handle;
        state.close();
        return w32.INVALID_HANDLE_VALUE;
    }

    // No wildcard — literal file lookup
    const posix_fs = @import("../msvcrt/posix_fs.zig");
    if (posix_fs.stat(@as([*:0]const u8, @ptrCast(&fixed_buf)))) |st| {
        const find_data = lpFindFileData_ptr;
        find_data.* = .{};

        find_data.dwFileAttributes = if (st.kind == .directory) w32.FILE_ATTRIBUTE_DIRECTORY else w32.FILE_ATTRIBUTE_NORMAL;
        find_data.nFileSizeLow = @intCast(st.size & 0xFFFFFFFF);

        // Copy just the filename, not the full path
        const fname = if (has_slash) fixed_buf[last_slash + 1 .. len] else fixed_slice;
        const copy_len = @min(fname.len, 259);
        @memcpy(find_data.cFileName[0..copy_len], fname[0..copy_len]);
        find_data.cFileName[copy_len] = 0;

        // Allocate a dummy handle for literal matches
        return allocFindHandle() orelse FIND_HANDLE_BASE;
    }

    if (trace.enable_tracing) trace.print("  -> FindFirstFileA: not found\n", .{});
    return w32.INVALID_HANDLE_VALUE;
}

/// Continues a file search from a previous call to the FindFirstFileA function.
/// Implementation status: Partially implemented
pub fn FindNextFileA(hFindFile: usize, lpFindFileData_ptr: *align(1) w32.WIN32_FIND_DATAA) callconv(w32cc.WINAPI) i32 {

    const state = getFindHandle(hFindFile) orelse return 0;

    if (state.iter) |*iter| {
        while (iter.next() catch null) |entry| {
            if (matchWildcard(entry.name, state.pattern[0..state.pattern_len])) {
                const find_data = lpFindFileData_ptr;
                find_data.* = .{};
                find_data.dwFileAttributes = if (entry.kind == .directory) w32.FILE_ATTRIBUTE_DIRECTORY else w32.FILE_ATTRIBUTE_NORMAL;
                const copy_len = @min(entry.name.len, 259);
                @memcpy(find_data.cFileName[0..copy_len], entry.name[0..copy_len]);
                find_data.cFileName[copy_len] = 0;

                if (trace.enable_tracing) trace.print("KERNEL32: FindNextFileA -> '{s}'\n", .{entry.name});
                return 1;
            }
        }
    }
    return 0; // No more files
}

/// Closes a file search handle.
/// Implementation status: Fully implemented
pub fn FindClose(hFindFile: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: FindClose({x})\n", .{hFindFile});
    if (getFindHandle(hFindFile)) |state| {
        state.close();
        return 1; // TRUE
    }
    return 1; // Still return TRUE even if not found
}

/// Retrieves the full path of the system directory.
/// Implementation status: Stub (returns hardcoded path)
pub fn GetSystemDirectoryA(lpBuffer: usize, uSize: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetSystemDirectoryA(buffer={x}, size={d})\n", .{ lpBuffer, uSize });
    const sys_dir = "C:\\WINDOWS\\SYSTEM32";
    if (lpBuffer != 0 and uSize > sys_dir.len) {
        const buf = @as([*]u8, @ptrFromInt(lpBuffer));
        @memcpy(buf[0..sys_dir.len], sys_dir);
        buf[sys_dir.len] = 0;
        return @intCast(sys_dir.len);
    }
    return @intCast(sys_dir.len + 1);
}

pub fn GetSystemDirectoryW(lpBuffer: usize, uSize: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetSystemDirectoryW(buffer={x}, size={d})\n", .{ lpBuffer, uSize });
    const sys_dir = "C:\\WINDOWS\\SYSTEM32";
    if (lpBuffer != 0 and uSize > sys_dir.len) {
        const buf = @as([*]u16, @ptrFromInt(lpBuffer));
        for (0..sys_dir.len) |i| buf[i] = sys_dir[i];
        buf[sys_dir.len] = 0;
        return @intCast(sys_dir.len);
    }
    return @intCast(sys_dir.len + 1);
}

/// Writes data to the specified file or I/O device.
/// Implementation status: Fully implemented
pub fn WriteFile(hFile: usize, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: ?*u32, lpOverlapped: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpOverlapped;
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: WriteFile(hFile={d}, size={d})\n", .{ fd, nNumberOfBytesToWrite });

    const buf = lpBuffer[0..nNumberOfBytesToWrite];
    const file = host_io.fileFromFd(fd);
    const written = file.write(buf) catch return 0;

    if (lpNumberOfBytesWritten) |p| p.* = @intCast(written);
    return 1;
}

/// Creates or opens a file or I/O device (wide-string version).
/// Implementation status: Partially implemented (delegates to CreateFileA)
pub fn CreateFileW(lpFileName_ptr: usize, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: usize, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: usize) callconv(w32cc.WINAPI) usize {
    if (lpFileName_ptr == 0) return w32.INVALID_HANDLE_VALUE;
    // Convert wide string to narrow
    const wstr = trace.c_span_w(lpFileName_ptr);
    var narrow_buf: [1024]u8 = undefined;
    const copy_len = @min(wstr.len, 1023);
    for (0..copy_len) |i| {
        narrow_buf[i] = @intCast(wstr[i] & 0xFF);
    }
    narrow_buf[copy_len] = 0;
    if (trace.enable_tracing) trace.print("KERNEL32: CreateFileW -> delegating to CreateFileA('{s}')\n", .{narrow_buf[0..copy_len]});
    // Delegate to CreateFileA
    return CreateFileA(@intFromPtr(&narrow_buf), dwDesiredAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);
}

/// Maps a view of a file mapping into the address space of a calling process.
/// Implementation status: Partially implemented (delegates to MapViewOfFileEx)
pub fn MapViewOfFile(hFileMappingObject: usize, dwDesiredAccess: u32, dwFileOffsetHigh: u32, dwFileOffsetLow: u32, dwNumberOfBytesToMap: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: MapViewOfFile -> delegating to MapViewOfFileEx\n", .{});
    return MapViewOfFileEx(hFileMappingObject, dwDesiredAccess, dwFileOffsetHigh, dwFileOffsetLow, dwNumberOfBytesToMap, 0);
}

/// Opens a named file mapping object.
/// Implementation status: Stub
pub fn stub_OpenFileMappingA(dwDesiredAccess: u32, bInheritHandle: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = dwDesiredAccess;
    _ = bInheritHandle;
    _ = lpName;
    if (trace.enable_tracing) trace.print("KERNEL32: OpenFileMappingA -> 0 (fail)\n", .{});
    return 0;
}

/// Retrieves file system attributes for a specified file or directory (wide-string version).
/// Implementation status: Partially implemented (delegates to GetFileAttributesA)
pub fn GetFileAttributesW(lpFileName_ptr: usize) callconv(w32cc.WINAPI) u32 {
    if (lpFileName_ptr == 0) return w32.INVALID_FILE_ATTRIBUTES;
    // Convert wide to narrow
    const wstr = trace.c_span_w(lpFileName_ptr);
    var narrow_buf: [1024]u8 = undefined;
    const copy_len = @min(wstr.len, 1023);
    for (0..copy_len) |i| {
        narrow_buf[i] = @intCast(wstr[i] & 0xFF);
    }
    narrow_buf[copy_len] = 0;
    if (trace.enable_tracing) trace.print("KERNEL32: GetFileAttributesW('{s}')\n", .{narrow_buf[0..copy_len]});
    // Delegate to GetFileAttributesA logic
    return GetFileAttributesA(@intFromPtr(&narrow_buf));
}

/// Retrieves information about the amount of space that is available on a disk volume.
/// Implementation status: Partially implemented (returns fixed values)
pub fn GetDiskFreeSpaceA(
    lpRootPathName: usize,
    lpSectorsPerCluster: usize,
    lpBytesPerSector: usize,
    lpNumberOfFreeClusters: usize,
    lpTotalNumberOfClusters: usize,
) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) {
        const path = if (lpRootPathName >= 0x10000) trace.c_span(lpRootPathName) else "NULL";
        trace.print("KERNEL32: GetDiskFreeSpaceA('{s}')\n", .{path});
    }
    if (lpSectorsPerCluster != 0) @as(*u32, @ptrFromInt(lpSectorsPerCluster)).* = 8;
    if (lpBytesPerSector != 0) @as(*u32, @ptrFromInt(lpBytesPerSector)).* = 512;
    if (lpNumberOfFreeClusters != 0) @as(*u32, @ptrFromInt(lpNumberOfFreeClusters)).* = 1024 * 1024;
    if (lpTotalNumberOfClusters != 0) @as(*u32, @ptrFromInt(lpTotalNumberOfClusters)).* = 2 * 1024 * 1024;
    return 1; // TRUE = success
}

/// Retrieves the size of the specified file.
/// Implementation status: Partially implemented
pub fn GetFileSizeEx(hFile: usize, lpFileSize: usize) callconv(w32cc.WINAPI) i32 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: GetFileSizeEx(hFile={d})\n", .{fd});

    if (lpFileSize == 0) return 0;
    const file = host_io.fileFromFd(fd);
    if (file.stat() catch null) |stat_result| {
        // LARGE_INTEGER: 64-bit signed int
        @as(*i64, @ptrFromInt(lpFileSize)).* = @intCast(stat_result.size);
        return 1; // TRUE
    }
    return 0; // FALSE
}

/// Moves the file pointer of the specified file.
/// Implementation status: Partially implemented
pub fn SetFilePointerEx(hFile: usize, liDistanceToMove_lo: u32, liDistanceToMove_hi: u32, lpNewFilePointer: usize, dwMoveMethod: u32) callconv(w32cc.WINAPI) i32 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    const distance = @as(i64, @bitCast((@as(u64, liDistanceToMove_hi) << 32) | @as(u64, liDistanceToMove_lo)));
    if (trace.enable_tracing) trace.print("KERNEL32: SetFilePointerEx(hFile={d}, dist={d}, method={d})\n", .{ fd, distance, dwMoveMethod });

    const file = host_io.fileFromFd(fd);

    switch (dwMoveMethod) {
        0 => { // FILE_BEGIN
            if (distance < 0) return 0;
            file.seekTo(@intCast(distance)) catch return 0;
        },
        1 => { // FILE_CURRENT
            const pos = file.getPos() catch return 0;
            const new_pos = @as(i64, @intCast(pos)) + distance;
            if (new_pos < 0) return 0;
            file.seekTo(@intCast(new_pos)) catch return 0;
        },
        2 => { // FILE_END
            const end = file.getEndPos() catch return 0;
            const new_pos = @as(i64, @intCast(end)) + distance;
            if (new_pos < 0) return 0;
            file.seekTo(@intCast(new_pos)) catch return 0;
        },
        else => return 0,
    }

    if (lpNewFilePointer != 0) {
        const final_pos = file.getPos() catch return 0;
        @as(*i64, @ptrFromInt(lpNewFilePointer)).* = @intCast(final_pos);
    }
    return 1; // TRUE
}

/// Searches a directory for a file or subdirectory with a name that matches a specific name and additional attributes (wide-string version).
/// Implementation status: Partially implemented (delegates to FindFirstFileW)
pub fn FindFirstFileExW(lpFileName: usize, fInfoLevelId: u32, lpFindFileData: usize, fSearchOp: u32, lpSearchFilter: usize, dwAdditionalFlags: u32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: FindFirstFileExW(level={d}, op={d}, filter={X}, flags={X})\n", .{ fInfoLevelId, fSearchOp, lpSearchFilter, dwAdditionalFlags });
    // Delegate to FindFirstFileW (ignoring extended parameters)
    return FindFirstFileW(lpFileName, lpFindFileData);
}

/// Searches a directory for a file or subdirectory with a name that matches a specific name and additional attributes.
/// Implementation status: Partially implemented (delegates to FindFirstFileA)
pub fn FindFirstFileExA(lpFileName: usize, fInfoLevelId: u32, lpFindFileData: *align(1) w32.WIN32_FIND_DATAA, fSearchOp: u32, lpSearchFilter: usize, dwAdditionalFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = fInfoLevelId;
    _ = fSearchOp;
    _ = lpSearchFilter;
    _ = dwAdditionalFlags;
    return FindFirstFileA(lpFileName, lpFindFileData);
}

/// Sets the attributes for a file or directory.
/// Implementation status: Stub
pub fn stub_SetFileAttributesA(lpFileName_ptr: usize, dwFileAttributes: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) {
        if (lpFileName_ptr != 0) {
            trace.print("KERNEL32: SetFileAttributesA('{s}', {x})\n", .{ trace.c_span(lpFileName_ptr), dwFileAttributes });
        }
    }
    return 1; // TRUE = success (no-op)
}

/// Flushes the buffers of a specified file and causes all buffered data to be written to a file.
/// Implementation status: Partially implemented (native sync, no-op otherwise)
pub fn FlushFileBuffers(hFile: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: FlushFileBuffers({x})\n", .{hFile});
    // Actually flush the fd if possible (not available on WASM/WASI)
    if (comptime platform.is_native) {
        const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
        const file = host_io.fileFromFd(fd);
        file.sync() catch {};
    }
    return 1; // TRUE
}

/// Retrieves the date and time that a file was created, last accessed, and last modified.
/// Implementation status: Partially implemented (uses mtime for all)
pub fn GetFileTime(hFile: usize, lpCreationTime: usize, lpLastAccessTime: usize, lpLastWriteTime: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetFileTime({x})\n", .{hFile});

    // Get current time as FILETIME
    const unix_ns: u128 = @bitCast(std.time.nanoTimestamp());
    const win_offset: u128 = 11644473600 * 10_000_000;
    const filetime: u64 = @intCast(unix_ns / 100 + win_offset);
    const low: u32 = @intCast(filetime & 0xFFFFFFFF);
    const high: u32 = @intCast(filetime >> 32);

    // Try to get actual file times from stat
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    const file = host_io.fileFromFd(fd);
    var actual_low = low;
    var actual_high = high;
    if (file.stat() catch null) |st| {
        const mtime_ns: u128 = @intCast(@as(u64, @bitCast(@as(i64, @intCast(st.mtime)))));
        const mtime_ft: u64 = @intCast(mtime_ns / 100 + win_offset);
        actual_low = @intCast(mtime_ft & 0xFFFFFFFF);
        actual_high = @intCast(mtime_ft >> 32);
    }

    if (lpCreationTime != 0) {
        const ft = @as(*w32.FILETIME, @ptrFromInt(lpCreationTime));
        ft.dwLowDateTime = actual_low;
        ft.dwHighDateTime = actual_high;
    }
    if (lpLastAccessTime != 0) {
        const ft = @as(*w32.FILETIME, @ptrFromInt(lpLastAccessTime));
        ft.dwLowDateTime = actual_low;
        ft.dwHighDateTime = actual_high;
    }
    if (lpLastWriteTime != 0) {
        const ft = @as(*w32.FILETIME, @ptrFromInt(lpLastWriteTime));
        ft.dwLowDateTime = actual_low;
        ft.dwHighDateTime = actual_high;
    }
    return 1; // TRUE
}

/// Sets the date and time that a file was created, last accessed, or last modified.
/// Implementation status: Stub
pub fn stub_SetFileTime(hFile: usize, lpCreationTime: usize, lpLastAccessTime: usize, lpLastWriteTime: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpCreationTime;
    _ = lpLastAccessTime;
    _ = lpLastWriteTime;
    if (trace.enable_tracing) trace.print("KERNEL32: SetFileTime({x}) - no-op\n", .{hFile});
    return 1; // TRUE = success (no-op)
}

/// Copies an existing file to a new file.
/// Implementation status: Fully implemented
pub fn CopyFileA(lpExistingFileName: usize, lpNewFileName: usize, bFailIfExists: i32) callconv(w32cc.WINAPI) i32 {
    _ = bFailIfExists;
    if (lpExistingFileName == 0 or lpNewFileName == 0) return 0;
    const src_name = trace.c_span(lpExistingFileName);
    const dst_name = trace.c_span(lpNewFileName);
    if (trace.enable_tracing) trace.print("KERNEL32: CopyFileA('{s}' -> '{s}')\n", .{ src_name, dst_name });

    const path_utils = @import("../../path_utils.zig");
    var src_buf: [1024]u8 = undefined;
    const src_len = path_utils.win32ToPosix(src_name, &src_buf);
    var dst_buf: [1024]u8 = undefined;
    const dst_len = path_utils.win32ToPosix(dst_name, &dst_buf);

    // Attempt actual copy via filesystem
    const cwd = std.fs.cwd();
    const src_file = cwd.openFile(src_buf[0..src_len], .{}) catch return 0;
    defer src_file.close();
    const dst_file = cwd.createFile(dst_buf[0..dst_len], .{}) catch return 0;
    defer dst_file.close();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = src_file.read(&buf) catch return 0;
        if (n == 0) break;
        dst_file.writeAll(buf[0..n]) catch return 0;
    }
    return 1; // TRUE
}

/// Sets the handle for the specified standard device.
/// Implementation status: Stub
pub fn stub_SetStdHandle(nStdHandle: u32, hHandle: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: SetStdHandle({d}, {x})\n", .{ nStdHandle, hHandle });
    return 1; // TRUE
}

/// Sets the number of handles that a process can use.
/// Implementation status: Stub (returns requested number)
pub fn SetHandleCount(uNumber: u32) callconv(w32cc.WINAPI) u32 {
    // Legacy API — just return the requested number
    return uNumber;
}

/// Searches a directory for a file or subdirectory with a name that matches a specific name (wide-string version).
/// Implementation status: Partially implemented
pub fn FindFirstFileW(lpFileName: usize, lpFindFileData: usize) callconv(w32cc.WINAPI) usize {
    if (lpFileName == 0 or lpFindFileData == 0) return 0xFFFFFFFF;

    // Convert wide filename to narrow
    const wstr = trace.c_span_w(lpFileName);
    var narrow_buf: [1024]u8 = undefined;
    const copy_len = @min(wstr.len, 1023);
    for (0..copy_len) |i| {
        narrow_buf[i] = @intCast(wstr[i] & 0xFF);
    }
    narrow_buf[copy_len] = 0;

    if (trace.enable_tracing) trace.print("KERNEL32: FindFirstFileW('{s}')\\n", .{narrow_buf[0..copy_len]});

    // Use a temporary narrow find data buffer
    var narrow_find_data: w32.WIN32_FIND_DATAA = .{};
    const result = FindFirstFileA(@intFromPtr(&narrow_buf), &narrow_find_data);

    if (result == 0xFFFFFFFF) {
        if (trace.enable_tracing) trace.print("KERNEL32: FindFirstFileW -> INVALID_HANDLE_VALUE\n", .{});
        return 0xFFFFFFFF;
    }

    // Copy narrow find data to wide find data
    // WIN32_FIND_DATAW: same layout but cFileName is [260]u16 and cAlternateFileName is [14]u16
    const out = @as([*]u8, @ptrFromInt(lpFindFileData));
    // Copy the fixed fields (dwFileAttributes through dwReserved1 = 44 bytes)
    const nfd_bytes = @as([*]const u8, @ptrCast(&narrow_find_data));
    @memcpy(out[0..44], nfd_bytes[0..44]);

    // Widen cFileName (260 bytes narrow -> 260 u16 = 520 bytes wide)
    const narrow_name = nfd_bytes[44..304]; // 260 bytes
    const wide_name = @as([*]u16, @ptrCast(@alignCast(out + 44)));
    for (0..260) |i| {
        wide_name[i] = narrow_name[i];
    }

    // Widen cAlternateFileName (14 bytes narrow -> 14 u16 = 28 bytes wide)
    const narrow_alt = nfd_bytes[304..318];
    const wide_alt = @as([*]u16, @ptrCast(@alignCast(out + 44 + 520)));
    for (0..14) |i| {
        wide_alt[i] = narrow_alt[i];
    }

    if (trace.enable_tracing) trace.print("KERNEL32: FindFirstFileW -> {d}\n", .{result});
    return result;
}

/// Continues a file search from a previous call to the FindFirstFileW function.
/// Implementation status: Partially implemented
pub fn FindNextFileW(hFindFile: usize, lpFindFileData: usize) callconv(w32cc.WINAPI) i32 {
    if (lpFindFileData == 0) return 0;

    // Get the next narrow result, then widen it
    var nfd: w32.WIN32_FIND_DATAA = .{};
    const result = FindNextFileA(hFindFile, &nfd);
    if (result == 0) return 0;

    const nfd_b = @as([*]const u8, @ptrCast(&nfd));
    const out = @as([*]u8, @ptrFromInt(lpFindFileData));
    @memcpy(out[0..44], nfd_b[0..44]);

    const narrow_name = nfd_b[44..304];
    const wide_name = @as([*]u16, @ptrCast(@alignCast(out + 44)));
    for (0..260) |i| {
        wide_name[i] = narrow_name[i];
    }

    const narrow_alt = nfd_b[304..318];
    const wide_alt = @as([*]u16, @ptrCast(@alignCast(out + 44 + 520)));
    for (0..14) |i| {
        wide_alt[i] = narrow_alt[i];
    }

    return 1;
}

/// Opens a file using the specified access and sharing modes.
/// Implementation status: Stub (returns HFILE_ERROR)
pub fn stub_OpenFile(lpFileName: usize, lpReOpenBuff: usize, uStyle: u32) callconv(w32cc.WINAPI) i32 {
    _ = lpReOpenBuff;
    _ = uStyle;
    if (trace.enable_tracing) {
        const name = if (lpFileName != 0) trace.c_span(lpFileName) else "(null)";
        trace.print("KERNEL32: OpenFile('{s}')\n", .{name});
    }
    return -1; // HFILE_ERROR
}
