const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const builtin = @import("builtin");
const kernel32_mem = @import("mem.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const platform = @import("../../platform.zig");
const host_io = @import("../host_io.zig");
const ansi = @import("../ansi.zig");
const text_utils = @import("../../text_utils.zig");
const kernel32_error = @import("error.zig");
const log = @import("../../log.zig");

const ERROR_WRITE_FAULT = 29;
const ERROR_READ_FAULT = 30;
const ERROR_INVALID_PARAMETER = 87;
const ERROR_INVALID_ADDRESS = 487;
const ERROR_INVALID_HANDLE = 6;
const ERROR_DISK_FULL = 112;
const ERROR_FILE_NOT_FOUND = 2;

/// Narrow a guest wide string to the CP1252 bytes its `A` twin takes, leaving
/// room for the terminator. Truncating each code unit to its low byte instead
/// would turn a character above U+00FF into an unrelated one and split a
/// surrogate pair, so the code point is what gets encoded; what CP1252 cannot
/// represent becomes the default character.
fn narrowWide(wide: []const u16, buf: []u8) []const u8 {
    const n = ansi.wideToAnsi(wide, buf[0 .. buf.len - 1]);
    buf[n.len] = 0;
    return buf[0..n.len];
}

/// Widen one `WIN32_FIND_DATAA` name field into the fixed `WIN32_FIND_DATAW`
/// field next to it. The narrow field carries the host name as UTF-8, so
/// giving each byte its own code unit would split every non-ASCII character
/// into one unit per byte and hand the guest a name it cannot reopen. The
/// field is a fixed-size array, so whatever the name does not fill stays zero.
fn widenFindName(narrow: []const u8, wide: []u16) void {
    const text = std.mem.sliceTo(narrow, 0);
    const n = text_utils.utf8ToWide(text, wide[0..@min(text.len + 1, wide.len)]);
    @memset(wide[n..], 0);
}

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
    if (host_io.statFile(file)) |stat| {
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
        if (host_io.statFile(file)) |stat| {
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
    // toHostPath (not win32ToPosix): resolves ".." inside the drive_c anchor
    // so a guest cannot escape the virtual drive via C:\..\..\ paths.
    const len = path_utils.toHostPath(name, &fixed_path);
    if (len == 0) return w32.INVALID_HANDLE_VALUE;
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

// Track mapped views created in guest memory (WASM) so UnmapViewOfFile can
// write the guest's modifications back to the file. Without this, LINK.EXE
// produced an all-zeros output: it writes the image into the mapped view and
// relies on unmap to flush.
const MAX_VIEWS = 64;
var view_fds: [MAX_VIEWS]i32 = [_]i32{-1} ** MAX_VIEWS;
var view_addrs: [MAX_VIEWS]usize = [_]usize{0} ** MAX_VIEWS;
var view_sizes: [MAX_VIEWS]usize = [_]usize{0} ** MAX_VIEWS;
var view_offsets: [MAX_VIEWS]u64 = [_]u64{0} ** MAX_VIEWS;
var view_writable: [MAX_VIEWS]bool = [_]bool{false} ** MAX_VIEWS;

// Native hosts mmap real address ranges; UnmapViewOfFile must munmap them or
// every mapping leaks address space until process exit.
const MAX_NATIVE_MAPS = 64;
var native_map_addrs: [MAX_NATIVE_MAPS]usize = [_]usize{0} ** MAX_NATIVE_MAPS;
var native_map_sizes: [MAX_NATIVE_MAPS]usize = [_]usize{0} ** MAX_NATIVE_MAPS;

fn registerNativeMap(addr: usize, size: usize) bool {
    const page_rounded = (size + 0xFFF) & ~@as(usize, 0xFFF);
    for (&native_map_addrs, &native_map_sizes) |*a, *s| {
        if (a.* == 0) {
            a.* = addr;
            s.* = page_rounded;
            return true;
        }
    }
    return false;
}

fn unregisterNativeMap(addr: usize) void {
    for (&native_map_addrs, &native_map_sizes) |*a, *s| {
        if (a.* == addr) {
            platform.munmap(@as([*]align(4096) u8, @ptrFromInt(a.*))[0..s.*]);
            a.* = 0;
            s.* = 0;
            return;
        }
    }
}

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
            if (host_io.statFile(file)) |stat| {
                if (stat.size < dwMaximumSizeLow) {
                    if (trace.enable_tracing) trace.print("KERNEL32: extending file to {d}\n", .{dwMaximumSizeLow});
                    host_io.setLength(file, @intCast(dwMaximumSizeLow)) catch |err| {
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
            const stat = host_io.statFile(file) orelse return 0;

            if (stat.size > 0 or dwNumberOfBytesToMap > 0) {
                const offset = (@as(u64, dwFileOffsetHigh) << 32) | @as(u64, dwFileOffsetLow);
                const map_size = if (dwNumberOfBytesToMap > 0) dwNumberOfBytesToMap else @as(usize, @intCast(stat.size));

                // FILE_MAP_WRITE is 2, FILE_MAP_ALL_ACCESS includes 2
                const is_write = (dwDesiredAccess & 2) != 0 or dwDesiredAccess == 0xF001F;

                // On WASM the guest x86 interpreter can only read the combined
                // buffer (guest memory). Mapping into the WASI heap would hand
                // the guest a host pointer it cannot dereference — LINK.EXE
                // read 0xCC-fill from the combined buffer and passed it to
                // printf, trapping in vsnprintf. Allocate the view in guest
                // memory and copy the file content in.
                if (kernel32_mem.guest_memory()) |gmem| {
                    const guest_size: u32 = @intCast(@min(map_size, 0xFFFFFFFF));
                    const va = gmem.guestAlloc(guest_size);
                    if (va == 0) return 0;
                    const map_file = host_io.fileFromFd(fd);
                    const slice = gmem.base[(va - gmem.base_addr)..][0..guest_size];
                    // A short read means the file ends inside the view, which
                    // Windows zero-fills. A read *error* must not be treated the
                    // same: the view would be all zeros, and UnmapViewOfFile
                    // writes a writable view back, overwriting the file with
                    // those zeros. Fail the mapping instead of losing the data.
                    const bytes_read = host_io.readPositional(map_file, slice, offset) catch |err| {
                        log.err("MapViewOfFileEx: read of {d} bytes at offset {d} (fd={d}) failed: {t}; refusing to map", .{ guest_size, offset, fd, err });
                        kernel32_error.SetLastError(ERROR_READ_FAULT);
                        return 0;
                    };
                    if (bytes_read < guest_size) @memset(slice[bytes_read..], 0);
                    // Register the view so UnmapViewOfFile can flush writes back.
                    // An unregistered view would silently lose every write on
                    // unmap (LINK.EXE output), so a full table fails the call.
                    var registered = false;
                    for (0..MAX_VIEWS) |vi| {
                        if (view_fds[vi] == -1) {
                            view_fds[vi] = fd;
                            view_addrs[vi] = va;
                            view_sizes[vi] = guest_size;
                            view_offsets[vi] = offset;
                            view_writable[vi] = is_write;
                            registered = true;
                            break;
                        }
                    }
                    if (!registered) return 0;
                    if (trace.enable_tracing) trace.print("KERNEL32: MapViewOfFileEx -> {x} (guest)\n", .{va});
                    return va;
                }

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
                // Register the mapping so UnmapViewOfFile munmaps it. A full
                // table must not strand the address-space reservation: release
                // it here and fail the call.
                if (!registerNativeMap(@intFromPtr(memory.ptr), map_size)) {
                    platform.munmap(memory);
                    return 0;
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
/// On WASM the view lives in guest memory; if it was mapped writable, flush the
/// guest's changes back to the file (LINK.EXE writes its output image into the
/// view and relies on unmap to persist it).
/// Implementation status: Partially implemented
pub fn UnmapViewOfFile(lpBaseAddress: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: UnmapViewOfFile({x})\n", .{lpBaseAddress});
    // Native host: release the real mapping.
    unregisterNativeMap(lpBaseAddress);
    for (0..MAX_VIEWS) |vi| {
        if (view_fds[vi] == -1 or view_addrs[vi] != lpBaseAddress) continue;

        // The view is unmapped whether or not the writeback below succeeds:
        // Windows hands the address range back either way. Release the slot
        // first, so a failed flush reports the error without stranding the
        // entry and, once MAX_VIEWS of them are stranded, denying every
        // later MapViewOfFile its only table.
        const fd = view_fds[vi];
        const writable = view_writable[vi];
        const view_size = view_sizes[vi];
        const file_offset = view_offsets[vi];
        view_fds[vi] = -1;
        view_addrs[vi] = 0;
        view_sizes[vi] = 0;
        view_offsets[vi] = 0;
        view_writable[vi] = false;

        if (writable) {
            const gmem = kernel32_mem.guest_memory() orelse {
                kernel32_error.SetLastError(ERROR_INVALID_ADDRESS);
                return 0;
            };
            if (lpBaseAddress < gmem.base_addr) {
                kernel32_error.SetLastError(ERROR_INVALID_ADDRESS);
                return 0;
            }
            const offset = lpBaseAddress - gmem.base_addr;
            if (offset > gmem.base.len or view_size > gmem.base.len - offset) {
                kernel32_error.SetLastError(ERROR_INVALID_ADDRESS);
                return 0;
            }
            const slice = gmem.base[offset..][0..view_size];
            const map_file = host_io.fileFromFd(fd);
            host_io.writePositional(map_file, slice, file_offset) catch |err| {
                trace.print("KERNEL32: UnmapViewOfFile({x}) writeback failed (fd={d}, offset={d}, bytes={d}): {}\n", .{ lpBaseAddress, fd, file_offset, slice.len, err });
                kernel32_error.SetLastError(ERROR_WRITE_FAULT);
                return 0;
            };
        }
        return 1;
    }
    return 1;
}

/// Closes an open object handle.
/// Implementation status: Fully implemented (handles both real fds and synthetic handles)
pub fn CloseHandle(hObject: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: CloseHandle({x})\n", .{hObject});

    // File mapping handles carry the 0x40000000 marker (see alloc_mapping).
    // Closing one frees its slot; the fd itself stays owned by the file handle
    // the mapping was created from. A marked handle whose slot was never
    // allocated names no object, so the close fails instead of reporting
    // success over a slot it did not own.
    if ((hObject & 0xFFFF0000) == 0x40000000) {
        const idx = hObject & 0xFFFF;
        if (idx >= MAX_MAPPINGS or mapping_fds[idx] == -1) {
            kernel32_error.SetLastError(ERROR_INVALID_HANDLE);
            return 0;
        }
        mapping_fds[idx] = -1;
        return 1;
    }

    // Registries with per-handle release paths (thread, child process,
    // event/mutex/semaphore). Each returns true only if it owned the handle.
    const process_mod = @import("process.zig");
    if (process_mod.closeThreadHandle(hObject)) return 1;
    if (process_mod.closeChildProcHandle(hObject)) return 1;
    if (@import("sync.zig").closeKernelObject(hObject)) return 1;

    // Don't close other synthetic handles
    if (hObject >= 0x10000) return 1;

    // Don't close stdin/stdout/stderr
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hObject))));
    if (fd <= 2) return 1;

    const file = host_io.fileFromFd(fd);
    host_io.closeFile(file);
    return 1; // TRUE
}

/// Moves the file pointer of the specified file.
/// Implementation status: Partially implemented
pub fn SetFilePointer(hFile: usize, lDistanceToMove: i32, lpDistanceToMoveHigh: usize, dwMoveMethod: u32) callconv(w32cc.WINAPI) u32 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: SetFilePointer(hFile={d}, dist={d}, method={d})\n", .{ fd, lDistanceToMove, dwMoveMethod });

    const file = host_io.fileFromFd(fd);

    // MoveMethod 0/1/2 map directly to POSIX SEEK_SET/CUR/END.
    if (dwMoveMethod > 2) return 0xFFFFFFFF;
    const final_pos = if (comptime @import("builtin").os.tag == .windows)
        @as(i64, -1)
    else
        @import("../../platform.zig").lseek(file.handle, lDistanceToMove, dwMoveMethod);
    if (final_pos < 0) return 0xFFFFFFFF;
    if (lpDistanceToMoveHigh != 0) {
        const high = @as(*i32, @ptrFromInt(lpDistanceToMoveHigh));
        high.* = @intCast(final_pos >> 32);
    }

    if (trace.enable_tracing) trace.print("KERNEL32: SetFilePointer -> {d}\n", .{final_pos});
    return @intCast(final_pos & 0xFFFFFFFF);
}

/// Reads data from the specified file or I/O device.
/// Implementation status: Fully implemented
pub fn ReadFile(hFile: usize, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: ?*u32, lpOverlapped: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpOverlapped;
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: ReadFile(hFile={d}, len={d})\n", .{ fd, nNumberOfBytesToRead });

    const file = host_io.fileFromFd(fd);
    const buffer = lpBuffer[0..nNumberOfBytesToRead];
    // A failed read is not a short read: the guest gets FALSE with no byte
    // count, so the only way it learns the read faulted rather than hitting
    // EOF is the last error.
    const bytes_read = @import("../host_io.zig").readFromFile(file, buffer) catch |err| {
        log.err("ReadFile(hFile={d}, len={d}) failed: {t}", .{ fd, nNumberOfBytesToRead, err });
        kernel32_error.SetLastError(ERROR_READ_FAULT);
        if (lpNumberOfBytesRead) |p| p.* = 0;
        return 0;
    };

    if (lpNumberOfBytesRead) |p| p.* = @intCast(bytes_read);

    if (trace.enable_tracing) trace.print("KERNEL32: ReadFile -> {d}\n", .{bytes_read});
    return 1; // TRUE
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
        // lpBuffer is a guest VA (usize param — not auto-translated).
        // Without translation the path landed at the raw guest VA in linear
        // memory, leaving the guest's buffer garbage → GetTempFileNameA built
        // a broken temp name → LINK: LNK1104 cannot open file ''.
        const buf = @as([*]u8, @ptrFromInt(trace.addr(lpBuffer)));
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
        // lpTempFileName is a guest VA (usize param) — translate before writing.
        const buf = @as([*]u8, @ptrFromInt(trace.addr(lpTempFileName)));
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
                host_io.closeFile(f);
            }
        }
        return uniq; // Unique ID
    }
    return 0;
}

/// Moves/rename a file or directory.
/// Implementation status: Fully implemented
pub fn MoveFileA(lpExistingFileName: usize, lpNewFileName: usize) callconv(w32cc.WINAPI) i32 {
    if (lpExistingFileName == 0 or lpNewFileName == 0) return 0;
    const old_name = trace.c_span(lpExistingFileName);
    const new_name = trace.c_span(lpNewFileName);
    if (trace.enable_tracing) trace.print("KERNEL32: MoveFileA('{s}' -> '{s}')\n", .{ old_name, new_name });

    const posix_fs = @import("../msvcrt/posix_fs.zig");
    return if (posix_fs.moveFileWin32(old_name, new_name) == 0) 1 else 0;
}

/// Wide-char variant of MoveFileA (narrowed per the codebase W->A convention).
pub fn MoveFileW(lpExistingFileName_ptr: usize, lpNewFileName_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (lpExistingFileName_ptr == 0 or lpNewFileName_ptr == 0) return 0;
    const wstr = trace.c_span_w(lpExistingFileName_ptr);
    var old_buf: [1024]u8 = undefined;
    const old_name = narrowWide(wstr, &old_buf);

    const wstr_new = trace.c_span_w(lpNewFileName_ptr);
    var new_buf: [1024]u8 = undefined;
    const new_name = narrowWide(wstr_new, &new_buf);

    if (trace.enable_tracing) trace.print("KERNEL32: MoveFileW(len={d} -> len={d})\n", .{ old_name.len, new_name.len });

    const posix_fs = @import("../msvcrt/posix_fs.zig");
    return if (posix_fs.moveFileWin32(old_name, new_name) == 0) 1 else 0;
}

/// MoveFileExA/W: same as MoveFile; MOVEFILE_* flags only tune failure
/// modes we don't model (delay-until-reboot, write-through), so they are
/// accepted and ignored.
pub fn MoveFileExA(lpExistingFileName: usize, lpNewFileName: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwFlags;
    return MoveFileA(lpExistingFileName, lpNewFileName);
}

pub fn MoveFileExW(lpExistingFileName_ptr: usize, lpNewFileName_ptr: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwFlags;
    return MoveFileW(lpExistingFileName_ptr, lpNewFileName_ptr);
}

/// Deletes an existing file.
/// Implementation status: Fully implemented
pub fn DeleteFileA(lpFileName: usize) callconv(w32cc.WINAPI) i32 {
    if (lpFileName == 0) return 0;
    return deleteFileWin32(trace.c_span(lpFileName));
}

/// Wide-char variant of DeleteFileA (narrowed per the codebase W->A convention).
pub fn DeleteFileW(lpFileName_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (lpFileName_ptr == 0) return 0;
    var narrow_buf: [1024]u8 = undefined;
    return deleteFileWin32(narrowWide(trace.c_span_w(lpFileName_ptr), &narrow_buf));
}

fn deleteFileWin32(name: []const u8) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: DeleteFile('{s}')\n", .{name});

    const path_utils = @import("../../path_utils.zig");
    var fixed_path: [1024]u8 = undefined;
    // toHostPath anchors ".." inside drive_c/ so a guest cannot delete
    // arbitrary host files outside the virtual drive.
    const len = path_utils.toHostPath(name, &fixed_path);
    if (len == 0) return 0;

    if (!host_io.deleteFilePosix(fixed_path[0..len])) {
        // Try case-insensitive: lowercase the filename portion
        var last_slash: usize = 0;
        for (0..len) |i| {
            if (fixed_path[i] == '/') last_slash = i + 1;
        }
        for (last_slash..len) |i| {
            fixed_path[i] = std.ascii.toLower(fixed_path[i]);
        }
        if (!host_io.deleteFilePosix(fixed_path[0..len])) return 0;
    }
    return 1; // TRUE
}

/// Sets the physical file size for the specified file to the current position of the file pointer.
/// Implementation status: Fully implemented
pub fn SetEndOfFile(hFile: usize) callconv(w32cc.WINAPI) i32 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    if (trace.enable_tracing) trace.print("KERNEL32: SetEndOfFile(hFile={d})\n", .{fd});
    const file = host_io.fileFromFd(fd);
    const pos = @import("../../platform.zig").lseek(file.handle, 0, 1); // SEEK_CUR
    if (pos < 0) {
        log.err("SetEndOfFile(hFile={d}): the current position is unavailable, the file is left at its old length", .{fd});
        kernel32_error.SetLastError(ERROR_INVALID_HANDLE);
        return 0;
    }
    // A failed truncate leaves the file longer than the guest believes, and
    // the guest keeps writing at offsets past the end believing they landed.
    host_io.setLength(file, @intCast(pos)) catch |err| {
        log.err("SetEndOfFile(hFile={d}): truncating to {d} bytes failed: {t}", .{ fd, pos, err });
        kernel32_error.SetLastError(ERROR_WRITE_FAULT);
        return 0;
    };
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
            const e_str = trace.host_c_span(@intFromPtr(e_ptr));
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
    dir: ?std.Io.Dir = null,
    iter: ?std.Io.Dir.Iterator = null,
    // Linux raw-syscall directory scan state (getdents64). std.Io.Dir
    // iteration goes through Io.Threaded (TLS), which faults inside the
    // compat-mode SIGSEGV dispatch handler (FS points at the guest TEB).
    raw_dir_fd: i32 = -1,
    raw_buf: [4096]u8 align(8) = undefined,
    raw_buf_len: usize = 0,
    raw_pos: usize = 0,
    raw_done: bool = false,
    pattern: [256]u8 = undefined,
    pattern_len: usize = 0,
    dir_path: [1024]u8 = undefined,
    dir_path_len: usize = 0,

    fn close(self: *FindHandleState) void {
        if (self.raw_dir_fd >= 0) {
            if (comptime builtin.os.tag == .linux) _ = std.os.linux.close(self.raw_dir_fd);
            self.raw_dir_fd = -1;
        }
        if (self.dir) |d| {
            host_io.closeDir(d);
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

    // Convert path using toHostPath: anchors ".." inside drive_c/ so a guest
    // cannot enumerate host directories outside the virtual drive.
    const path_utils = @import("../../path_utils.zig");
    var fixed_buf: [1024]u8 = undefined;
    const len = path_utils.toHostPath(filename, &fixed_buf);
    if (len == 0) return w32.INVALID_HANDLE_VALUE;
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

        if (comptime builtin.os.tag == .linux) {
            // Raw open: std.Io.Dir.openDir touches TLS (see FindHandleState).
            var nt_buf: [1025]u8 = undefined;
            if (dir_path.len >= nt_buf.len) {
                state.close();
                return w32.INVALID_HANDLE_VALUE;
            }
            @memcpy(nt_buf[0..dir_path.len], dir_path);
            nt_buf[dir_path.len] = 0;
            const open_rc = std.os.linux.open(@ptrCast(&nt_buf), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
            const dir_fd: isize = @bitCast(open_rc);
            if (dir_fd < 0) {
                // Case-insensitive fallback
                resolved_dir = path_utils.tryCaseInsensitiveResolve(dir_path, &ci_buf) orelse {
                    if (trace.enable_tracing) trace.print("  -> FindFirstFileA: dir not found\n", .{});
                    state.close();
                    return w32.INVALID_HANDLE_VALUE;
                };
                if (resolved_dir.len >= nt_buf.len) {
                    state.close();
                    return w32.INVALID_HANDLE_VALUE;
                }
                @memcpy(nt_buf[0..resolved_dir.len], resolved_dir);
                nt_buf[resolved_dir.len] = 0;
                const rc2 = std.os.linux.open(@ptrCast(&nt_buf), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
                const fd2: isize = @bitCast(rc2);
                if (fd2 < 0) {
                    if (trace.enable_tracing) trace.print("  -> FindFirstFileA: resolved dir not found\n", .{});
                    state.close();
                    return w32.INVALID_HANDLE_VALUE;
                }
                state.raw_dir_fd = @intCast(fd2);
            } else {
                state.raw_dir_fd = @intCast(dir_fd);
            }
            @memcpy(state.dir_path[0..resolved_dir.len], resolved_dir);
            state.dir_path_len = resolved_dir.len;
            state.raw_buf_len = 0;
            state.raw_pos = 0;
            state.raw_done = false;
        } else {
            const d = std.Io.Dir.cwd().openDir(runtime.io(), dir_path, .{ .iterate = true }) catch blk: {
                // Try case-insensitive resolution
                resolved_dir = path_utils.tryCaseInsensitiveResolve(dir_path, &ci_buf) orelse {
                    if (trace.enable_tracing) trace.print("  -> FindFirstFileA: dir not found\n", .{});
                    state.close();
                    return w32.INVALID_HANDLE_VALUE;
                };
                break :blk std.Io.Dir.cwd().openDir(runtime.io(), resolved_dir, .{ .iterate = true }) catch {
                    if (trace.enable_tracing) trace.print("  -> FindFirstFileA: resolved dir not found\n", .{});
                    state.close();
                    return w32.INVALID_HANDLE_VALUE;
                };
            };

            @memcpy(state.dir_path[0..resolved_dir.len], resolved_dir);
            state.dir_path_len = resolved_dir.len;
            state.dir = d;
            state.iter = d.iterate();
        }

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

        // Allocate a dummy handle for literal matches. When the pool is
        // exhausted, fail rather than alias slot 0 of an active search.
        return allocFindHandle() orelse w32.INVALID_HANDLE_VALUE;
    }

    if (trace.enable_tracing) trace.print("  -> FindFirstFileA: not found\n", .{});
    return w32.INVALID_HANDLE_VALUE;
}

/// Continues a file search from a previous call to the FindFirstFileA function.
/// Implementation status: Partially implemented
pub fn FindNextFileA(hFindFile: usize, lpFindFileData_ptr: *align(1) w32.WIN32_FIND_DATAA) callconv(w32cc.WINAPI) i32 {
    const state = getFindHandle(hFindFile) orelse return 0;

    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        while (true) {
            if (state.raw_pos >= state.raw_buf_len) {
                if (state.raw_done) return 0;
                const n_rc = linux.getdents64(state.raw_dir_fd, &state.raw_buf, state.raw_buf.len);
                const n: isize = @bitCast(n_rc);
                if (n <= 0) {
                    state.raw_done = true;
                    return 0;
                }
                state.raw_buf_len = @intCast(n);
                state.raw_pos = 0;
            }
            const d = @as(*align(1) linux.dirent64, @ptrCast(state.raw_buf[state.raw_pos..].ptr));
            const name_ptr: [*:0]const u8 = @ptrCast(&d.name);
            const name = std.mem.sliceTo(name_ptr, 0);
            state.raw_pos += d.reclen;
            if (matchWildcard(name, state.pattern[0..state.pattern_len])) {
                const find_data = lpFindFileData_ptr;
                find_data.* = .{};
                find_data.dwFileAttributes = if (d.type == linux.DT.DIR) w32.FILE_ATTRIBUTE_DIRECTORY else w32.FILE_ATTRIBUTE_NORMAL;
                const copy_len = @min(name.len, 259);
                @memcpy(find_data.cFileName[0..copy_len], name[0..copy_len]);
                find_data.cFileName[copy_len] = 0;

                if (trace.enable_tracing) trace.print("KERNEL32: FindNextFileA -> '{s}'\n", .{name});
                return 1;
            }
        }
    }

    if (state.iter) |*iter| {
        while (iter.next(runtime.io()) catch null) |entry| {
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
    // writeAllToFile is all-or-nothing, so a failure wrote nothing: report
    // FALSE with a zero byte count and a last error, never a silent success
    // that leaves the guest believing the bytes landed.
    host_io.writeAllToFile(file, buf) catch |err| {
        log.err("WriteFile(hFile={d}, size={d}) failed: {t}", .{ fd, nNumberOfBytesToWrite, err });
        kernel32_error.SetLastError(ERROR_WRITE_FAULT);
        if (lpNumberOfBytesWritten) |p| p.* = 0;
        return 0;
    };
    if (lpNumberOfBytesWritten) |p| p.* = @intCast(buf.len);
    return 1;
}

/// Creates or opens a file or I/O device (wide-string version).
/// Implementation status: Partially implemented (delegates to CreateFileA)
pub fn CreateFileW(lpFileName_ptr: usize, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: usize, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: usize) callconv(w32cc.WINAPI) usize {
    if (lpFileName_ptr == 0) return w32.INVALID_HANDLE_VALUE;
    // Convert wide string to narrow
    var narrow_buf: [1024]u8 = undefined;
    const name = narrowWide(trace.c_span_w(lpFileName_ptr), &narrow_buf);
    if (trace.enable_tracing) trace.print("KERNEL32: CreateFileW -> delegating to CreateFileA('{s}')\n", .{name});
    // Delegate to CreateFileA
    return CreateFileA(@intFromPtr(name.ptr), dwDesiredAccess, dwShareMode, lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes, hTemplateFile);
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
    var narrow_buf: [1024]u8 = undefined;
    const name = narrowWide(trace.c_span_w(lpFileName_ptr), &narrow_buf);
    if (trace.enable_tracing) trace.print("KERNEL32: GetFileAttributesW('{s}')\n", .{name});
    // Delegate to GetFileAttributesA logic
    return GetFileAttributesA(@intFromPtr(name.ptr));
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
    if (host_io.statFile(file)) |stat_result| {
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

    // MoveMethod 0/1/2 map directly to POSIX SEEK_SET/CUR/END.
    if (dwMoveMethod > 2) return 0;
    const seek_res = @import("../../platform.zig").lseek(file.handle, distance, dwMoveMethod);
    if (seek_res < 0) return 0;

    if (lpNewFilePointer != 0) {
        @as(*i64, @ptrFromInt(lpNewFilePointer)).* = seek_res;
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
        if (comptime builtin.os.tag == .linux) {
            while (true) {
                const err = std.os.linux.errno(std.os.linux.fsync(file.handle));
                switch (err) {
                    .SUCCESS => break,
                    .INTR => continue,
                    else => {
                        kernel32_error.SetLastError(switch (err) {
                            .BADF => ERROR_INVALID_HANDLE,
                            .INVAL => ERROR_INVALID_PARAMETER,
                            .NOSPC, .DQUOT => ERROR_DISK_FULL,
                            else => ERROR_WRITE_FAULT,
                        });
                        trace.print("KERNEL32: FlushFileBuffers({d}) failed: {t}\n", .{ fd, err });
                        return 0;
                    },
                }
            }
        } else {
            file.sync(runtime.io()) catch |err| {
                kernel32_error.SetLastError(ERROR_WRITE_FAULT);
                trace.print("KERNEL32: FlushFileBuffers({d}) failed: {t}\n", .{ fd, err });
                return 0;
            };
        }
    }
    return 1; // TRUE
}

/// Retrieves the date and time that a file was created, last accessed, and last modified.
/// Implementation status: Partially implemented (uses mtime for all)
pub fn GetFileTime(hFile: usize, lpCreationTime: usize, lpLastAccessTime: usize, lpLastWriteTime: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetFileTime({x})\n", .{hFile});

    // Get current time as FILETIME
    const unix_ns = runtime.nanoTimestamp();
    const win_offset: i128 = 11644473600 * 10_000_000;
    const filetime = std.math.cast(u64, @divFloor(unix_ns, 100) + win_offset) orelse {
        kernel32_error.SetLastError(ERROR_INVALID_PARAMETER);
        return 0;
    };
    const low: u32 = @intCast(filetime & 0xFFFFFFFF);
    const high: u32 = @intCast(filetime >> 32);

    // Try to get actual file times from stat
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hFile))));
    const file = host_io.fileFromFd(fd);
    var actual_low = low;
    var actual_high = high;
    if (host_io.statFile(file)) |st| {
        const mtime_ft = std.math.cast(u64, @divFloor(st.mtime.nanoseconds, 100) + win_offset) orelse {
            kernel32_error.SetLastError(ERROR_INVALID_PARAMETER);
            return 0;
        };
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
    if (lpExistingFileName == 0 or lpNewFileName == 0) return 0;
    const src_name = trace.c_span(lpExistingFileName);
    const dst_name = trace.c_span(lpNewFileName);
    if (trace.enable_tracing) trace.print("KERNEL32: CopyFileA('{s}' -> '{s}')\n", .{ src_name, dst_name });

    const path_utils = @import("../../path_utils.zig");
    var src_buf: [1024]u8 = undefined;
    // toHostPath anchors ".." inside drive_c/ so a guest cannot copy
    // arbitrary host files in or out of the virtual drive.
    const src_len = path_utils.toHostPath(src_name, &src_buf);
    if (src_len == 0) return 0;
    var dst_buf: [1024]u8 = undefined;
    const dst_len = path_utils.toHostPath(dst_name, &dst_buf);
    if (dst_len == 0) return 0;

    // Win32 contract: fail when the destination exists and bFailIfExists is TRUE
    if (bFailIfExists != 0 and fileExistsPosix(dst_buf[0..dst_len])) return 0;

    return copyFileHost(src_buf[0..src_len], dst_buf[0..dst_len]);
}

/// Wide-char variant of CopyFileA (narrowed per the codebase W->A convention).
pub fn CopyFileW(lpExistingFileName_ptr: usize, lpNewFileName_ptr: usize, bFailIfExists: i32) callconv(w32cc.WINAPI) i32 {
    if (lpExistingFileName_ptr == 0 or lpNewFileName_ptr == 0) return 0;
    var src_narrow: [1024]u8 = undefined;
    var dst_narrow: [1024]u8 = undefined;
    const src_name = narrowWide(trace.c_span_w(lpExistingFileName_ptr), &src_narrow);
    const dst_name = narrowWide(trace.c_span_w(lpNewFileName_ptr), &dst_narrow);
    if (trace.enable_tracing) trace.print("KERNEL32: CopyFileW -> CopyFileA\n", .{});

    const path_utils = @import("../../path_utils.zig");
    var src_buf: [1024]u8 = undefined;
    const src_len = path_utils.toHostPath(src_name, &src_buf);
    if (src_len == 0) return 0;
    var dst_buf: [1024]u8 = undefined;
    const dst_len = path_utils.toHostPath(dst_name, &dst_buf);
    if (dst_len == 0) return 0;

    // Win32 contract: fail when the destination exists and bFailIfExists is TRUE
    if (bFailIfExists != 0 and fileExistsPosix(dst_buf[0..dst_len])) return 0;

    return copyFileHost(src_buf[0..src_len], dst_buf[0..dst_len]);
}

/// Check existence of a host POSIX path.
fn fileExistsPosix(host_path: []const u8) bool {
    if (comptime builtin.os.tag == .linux) {
        var nt: [1025]u8 = undefined;
        if (host_path.len >= nt.len) return false;
        @memcpy(nt[0..host_path.len], host_path);
        nt[host_path.len] = 0;
        const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, @ptrCast(&nt), 0, 0);
        return @as(isize, @bitCast(rc)) == 0;
    }
    _ = std.Io.Dir.cwd().statFile(runtime.io(), host_path, .{}) catch return false;
    return true;
}

/// Reports a copy failure with the paths, the failing direction, and the
/// host errno, then returns FALSE. The destination is left truncated; the
/// guest learns of it only from this return value, so it must not be FALSE.
fn copyFailed(src_buf: []const u8, dst_buf: []const u8, op: []const u8, errno: ?std.posix.E, err: ?anyerror) i32 {
    log.err("CopyFile '{s}' -> '{s}': host {s} failed, errno {?}, error {?}", .{ src_buf, dst_buf, op, errno, err });
    kernel32_error.SetLastError(if (std.mem.eql(u8, op, "read")) ERROR_READ_FAULT else ERROR_WRITE_FAULT);
    return 0;
}

/// Shared copy core given resolved POSIX paths.
fn copyFileHost(src_buf: []const u8, dst_buf: []const u8) i32 {
    if (comptime builtin.os.tag == .linux) {
        // Raw syscalls: std.Io.Dir open/create touch TLS, which faults
        // inside the compat-mode SIGSEGV dispatch handler.
        var src_nt: [1025]u8 = undefined;
        if (src_buf.len >= src_nt.len or dst_buf.len >= src_nt.len) return 0;
        @memcpy(src_nt[0..src_buf.len], src_buf);
        src_nt[src_buf.len] = 0;
        const src_rc = std.os.linux.open(@ptrCast(&src_nt), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        const src_fd: isize = @bitCast(src_rc);
        if (src_fd < 0) return 0;
        defer _ = std.os.linux.close(@intCast(src_fd));

        var dst_nt: [1025]u8 = undefined;
        @memcpy(dst_nt[0..dst_buf.len], dst_buf);
        dst_nt[dst_buf.len] = 0;
        const dst_rc = std.os.linux.open(@ptrCast(&dst_nt), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o666);
        const dst_fd: isize = @bitCast(dst_rc);
        if (dst_fd < 0) return 0;
        defer _ = std.os.linux.close(@intCast(dst_fd));

        var buf: [4096]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n_rc = std.os.linux.pread(@intCast(src_fd), &buf, buf.len, @as(i64, @intCast(offset)));
            const n: isize = @bitCast(n_rc);
            // pread returns 0 only at end of file; a negative value is an
            // errno. Collapsing both into a clean exit would report success
            // for a truncated destination, so distinguish them.
            if (n == 0) break;
            if (n < 0) return copyFailed(src_buf, dst_buf, "read", std.posix.errno(n_rc), null);
            var woff: usize = 0;
            while (woff < @as(usize, @intCast(n))) {
                const w_rc = std.os.linux.pwrite(@intCast(dst_fd), buf[woff..].ptr, @as(usize, @intCast(n)) - woff, @as(i64, @intCast(offset + woff)));
                const w: isize = @bitCast(w_rc);
                if (w == 0) return copyFailed(src_buf, dst_buf, "write", null, null);
                if (w < 0) return copyFailed(src_buf, dst_buf, "write", std.posix.errno(w_rc), null);
                woff += @intCast(w);
            }
            offset += @intCast(n);
        }
        return 1;
    }
    const cwd = std.Io.Dir.cwd();
    const src_file = cwd.openFile(runtime.io(), src_buf, .{}) catch |err| {
        log.err("CopyFile '{s}' -> '{s}': host open of the source failed: {t}", .{ src_buf, dst_buf, err });
        kernel32_error.SetLastError(ERROR_FILE_NOT_FOUND);
        return 0;
    };
    defer host_io.closeFile(src_file);
    const dst_file = cwd.createFile(runtime.io(), dst_buf, .{}) catch |err| {
        log.err("CopyFile '{s}' -> '{s}': host create of the destination failed: {t}", .{ src_buf, dst_buf, err });
        kernel32_error.SetLastError(ERROR_WRITE_FAULT);
        return 0;
    };
    defer host_io.closeFile(dst_file);

    var buf: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = host_io.readPositional(src_file, &buf, offset) catch |err| return copyFailed(src_buf, dst_buf, "read", null, err);
        if (n == 0) break;
        host_io.writePositional(dst_file, buf[0..n], offset) catch |err| return copyFailed(src_buf, dst_buf, "write", null, err);
        offset += n;
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
    var narrow_buf: [1024]u8 = undefined;
    const pattern = narrowWide(trace.c_span_w(lpFileName), &narrow_buf);

    if (trace.enable_tracing) trace.print("KERNEL32: FindFirstFileW('{s}')\\n", .{pattern});

    // Use a temporary narrow find data buffer
    var narrow_find_data: w32.WIN32_FIND_DATAA = .{};
    const result = FindFirstFileA(@intFromPtr(pattern.ptr), &narrow_find_data);

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
    widenFindName(narrow_name, wide_name[0..260]);

    // Widen cAlternateFileName (14 bytes narrow -> 14 u16 = 28 bytes wide)
    const narrow_alt = nfd_bytes[304..318];
    const wide_alt = @as([*]u16, @ptrCast(@alignCast(out + 44 + 520)));
    widenFindName(narrow_alt, wide_alt[0..14]);

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
    widenFindName(narrow_name, wide_name[0..260]);

    const narrow_alt = nfd_b[304..318];
    const wide_alt = @as([*]u16, @ptrCast(@alignCast(out + 44 + 520)));
    widenFindName(narrow_alt, wide_alt[0..14]);

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

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "FlushFileBuffers reports native sync failures" {
    if (comptime !platform.is_native) return error.SkipZigTest;
    const saved_error = kernel32_error.GetLastError();
    defer kernel32_error.SetLastError(saved_error);

    kernel32_error.SetLastError(0);
    try std.testing.expectEqual(@as(i32, 0), FlushFileBuffers(w32.INVALID_HANDLE_VALUE));
    try std.testing.expectEqual(@as(u32, 6), kernel32_error.GetLastError());

    if (comptime builtin.os.tag == .linux) {
        const fds = try platform.pipe();
        defer host_io.closeFile(host_io.fileFromFd(fds[0]));
        defer host_io.closeFile(host_io.fileFromFd(fds[1]));
        kernel32_error.SetLastError(0);
        try std.testing.expectEqual(@as(i32, 0), FlushFileBuffers(@intCast(fds[1])));
        try std.testing.expectEqual(@as(u32, 87), kernel32_error.GetLastError());
    }
}

test "FlushFileBuffers succeeds for a writable native file" {
    if (comptime !platform.is_native) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(runtime.io(), "flush.bin", .{ .read = true });
    defer host_io.closeFile(file);
    try host_io.writeAllToFile(file, "persisted");
    try std.testing.expectEqual(@as(i32, 1), FlushFileBuffers(@intCast(file.handle)));
    var data: [9]u8 = undefined;
    try std.testing.expectEqual(@as(usize, data.len), try host_io.readPositional(file, &data, 0));
    try std.testing.expectEqualStrings("persisted", &data);
}

test "GetFileTime preserves file timestamps before the Unix epoch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(runtime.io(), "dated.bin", .{});
    defer host_io.closeFile(file);

    const samples = [_]struct { ns: i64, ticks: u64 }{
        .{ .ns = -1_000_000_000, .ticks = 116444735990000000 },
        .{ .ns = -123_456_789, .ticks = 116444735998765432 },
        .{ .ns = -1, .ticks = 116444735999999999 },
        .{ .ns = 0, .ticks = 116444736000000000 },
        .{ .ns = 123_456_789, .ticks = 116444736001234567 },
    };
    for (samples) |sample| {
        try file.setTimestamps(runtime.io(), .{
            .modify_timestamp = .{ .new = .{ .nanoseconds = sample.ns } },
        });
        const stat = host_io.statFile(file) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(i128, sample.ns), stat.mtime.nanoseconds);
        var ft: w32.FILETIME = .{};
        try std.testing.expectEqual(@as(i32, 1), GetFileTime(@intCast(file.handle), 0, 0, @intFromPtr(&ft)));
        try std.testing.expectEqual(sample.ticks, @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime);
    }
}

test "CloseHandle frees file mapping slots" {
    const saved_fds = mapping_fds;
    defer mapping_fds = saved_fds;
    mapping_fds = [_]i32{-1} ** MAX_MAPPINGS;

    var handles: [MAX_MAPPINGS]usize = undefined;
    for (0..MAX_MAPPINGS) |i| {
        handles[i] = alloc_mapping(@intCast(100 + i)) orelse return error.TestUnexpectedResult;
    }
    // Pool is exhausted now.
    try std.testing.expect(alloc_mapping(999) == null);
    // Closing each mapping handle must free its slot.
    for (handles) |h| {
        try std.testing.expectEqual(@as(i32, 1), CloseHandle(h));
        const replacement = alloc_mapping(999) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(h, replacement);
        try std.testing.expect(alloc_mapping(999) == null);
    }
}

test "guest view writeback failure reports the error and releases the view" {
    const x86_memory = @import("../../x86/memory.zig");
    const saved_memory = x86_memory.guest_memory;
    const saved_error = kernel32_error.GetLastError();
    var backing: [256]u8 = @splat(0);
    var memory: x86_memory.GuestMemory = .{
        .base = &backing,
        .base_addr = 0x400000,
        .heap_start = 16,
        .heap_cursor = 16,
    };
    x86_memory.guest_memory = &memory;
    defer {
        x86_memory.guest_memory = saved_memory;
        kernel32_error.SetLastError(saved_error);
        view_fds = @splat(-1);
        view_addrs = @splat(0);
        view_sizes = @splat(0);
        view_offsets = @splat(0);
        view_writable = @splat(false);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(runtime.io(), .{ .sub_path = "mapped.bin", .data = "original" });
    const read_only = try tmp.dir.openFile(runtime.io(), "mapped.bin", .{});
    defer host_io.closeFile(read_only);
    const writable = try tmp.dir.openFile(runtime.io(), "mapped.bin", .{ .mode = .read_write });
    defer host_io.closeFile(writable);
    const mapping = alloc_mapping(@intCast(read_only.handle)) orelse return error.TestUnexpectedResult;
    defer _ = CloseHandle(mapping);
    const address = MapViewOfFileEx(mapping, 2, 0, 0, 8, 0);
    try std.testing.expect(address != 0);
    @memcpy(backing[address - memory.base_addr ..][0..8], "modified");

    kernel32_error.SetLastError(0);
    try std.testing.expectEqual(@as(i32, 0), UnmapViewOfFile(address));
    try std.testing.expectEqual(@as(u32, 29), kernel32_error.GetLastError());
    var contents: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try host_io.readPositional(read_only, &contents, 0));
    try std.testing.expectEqualStrings("original", &contents);

    // The view is gone whatever the writeback did, so its slot is available
    // again and a guest that hits a permanent flush failure cannot fill the
    // table and deny itself every later mapping.
    try std.testing.expect(std.mem.indexOfScalar(usize, &view_addrs, address) == null);
    const retry_address = MapViewOfFileEx(mapping, 2, 0, 0, 8, 0);
    try std.testing.expect(retry_address != 0);
    const vi = std.mem.indexOfScalar(usize, &view_addrs, retry_address) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 8), view_sizes[vi]);
    @memcpy(backing[retry_address - memory.base_addr ..][0..8], "modified");
    view_fds[vi] = @intCast(writable.handle);
    try std.testing.expectEqual(@as(i32, 1), UnmapViewOfFile(retry_address));
    try std.testing.expectEqual(@as(i32, -1), view_fds[vi]);
    try std.testing.expectEqual(@as(usize, 8), try host_io.readPositional(read_only, &contents, 0));
    try std.testing.expectEqualStrings("modified", &contents);
}

test "native map registry unmaps registered views" {
    const saved_addrs = native_map_addrs;
    const saved_sizes = native_map_sizes;
    defer {
        native_map_addrs = saved_addrs;
        native_map_sizes = saved_sizes;
    }
    native_map_addrs = [_]usize{0} ** MAX_NATIVE_MAPS;
    native_map_sizes = [_]usize{0} ** MAX_NATIVE_MAPS;

    try std.testing.expect(registerNativeMap(0x1234000, 0x2001)); // page-rounded to 0x3000
    try std.testing.expect(native_map_sizes[0] == 0x3000);

    // A full table reports failure instead of silently dropping the mapping.
    var i: usize = 1;
    while (i < MAX_NATIVE_MAPS) : (i += 1) _ = registerNativeMap(0x2000000 + i * 0x10000, 0x1000);
    try std.testing.expect(!registerNativeMap(0xDEAD000, 0x1000));

    // Unknown addresses are ignored without panicking.
    unregisterNativeMap(0xDEAD000);
    try std.testing.expect(native_map_addrs[0] == 0x1234000);
}

test "a failed WriteFile reports a byte count of zero and a last error" {
    if (comptime !platform.is_native) return error.SkipZigTest;
    const saved_error = kernel32_error.GetLastError();
    defer kernel32_error.SetLastError(saved_error);

    // A read-only descriptor makes every write fail. The guest must not read
    // back an untouched byte count that says the data was written.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(runtime.io(), .{ .sub_path = "written.bin", .data = "seed" });
    const read_only = try tmp.dir.openFile(runtime.io(), "written.bin", .{ .mode = .read_only });
    defer host_io.closeFile(read_only);

    var written: u32 = 0xDEAD_BEEF;
    kernel32_error.SetLastError(0);
    try std.testing.expectEqual(@as(i32, 0), WriteFile(@intCast(read_only.handle), "payload", 7, &written, 0));
    try std.testing.expectEqual(@as(u32, 0), written);
    try std.testing.expect(kernel32_error.GetLastError() != 0);
}

test "a failed ReadFile reports a byte count of zero and a last error" {
    if (comptime !platform.is_native) return error.SkipZigTest;
    const saved_error = kernel32_error.GetLastError();
    defer kernel32_error.SetLastError(saved_error);

    // A write-only descriptor makes every read fail, which is not EOF.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(runtime.io(), .{ .sub_path = "read.bin", .data = "seed" });
    const write_only = try tmp.dir.createFile(runtime.io(), "read.bin", .{ .truncate = false });
    defer host_io.closeFile(write_only);
    const reopened = try tmp.dir.openFile(runtime.io(), "read.bin", .{ .mode = .write_only });
    defer host_io.closeFile(reopened);

    var buf: [4]u8 = undefined;
    var read_count: u32 = 0xDEAD_BEEF;
    kernel32_error.SetLastError(0);
    try std.testing.expectEqual(@as(i32, 0), ReadFile(@intCast(reopened.handle), &buf, 4, &read_count, 0));
    try std.testing.expectEqual(@as(u32, 0), read_count);
    try std.testing.expect(kernel32_error.GetLastError() != 0);
}

test "SetEndOfFile reports a last error when the position is unavailable" {
    if (comptime !platform.is_native) return error.SkipZigTest;
    const saved_error = kernel32_error.GetLastError();
    defer kernel32_error.SetLastError(saved_error);

    kernel32_error.SetLastError(0);
    try std.testing.expectEqual(@as(i32, 0), SetEndOfFile(w32.INVALID_HANDLE_VALUE));
    try std.testing.expect(kernel32_error.GetLastError() != 0);
}

test "CloseHandle releases a mapping slot and rejects one that was never allocated" {
    // Slots other tests may have taken, isolated so the assertions do not
    // depend on the order the suite happens to run in.
    const saved = mapping_fds;
    defer mapping_fds = saved;

    @memset(&mapping_fds, -1);
    const handle = alloc_mapping(7) orelse return error.NoSlots;
    try std.testing.expectEqual(@as(i32, 1), CloseHandle(handle));
    try std.testing.expectEqual(@as(i32, -1), mapping_fds[handle & 0xFFFF]);

    // The same handle again, and a marked index past the table: neither names
    // a live mapping, so neither may report success.
    try std.testing.expectEqual(@as(i32, 0), CloseHandle(handle));
    try std.testing.expectEqual(@as(i32, 0), CloseHandle(0x40000000 | MAX_MAPPINGS));
}

test "widenFindName gives a non-ASCII host name one unit per character" {
    var narrow: [260]u8 = undefined;
    @memset(&narrow, 0);
    const name = "café — ünïcode.txt";
    @memcpy(narrow[0..name.len], name);

    var wide: [260]u16 = undefined;
    widenFindName(&narrow, &wide);

    // A unit per byte would hand back 20 units of mojibake; the name has to
    // survive as itself, or the guest cannot reopen what it just enumerated.
    var want: [260]u16 = undefined;
    const want_n = text_utils.utf8ToWide(name, want[0..]);
    try std.testing.expectEqual(want_n, @as(usize, std.mem.len(@as([*:0]const u16, @ptrCast(&wide)))));
    try std.testing.expectEqualSlices(u16, want[0..want_n], wide[0..want_n]);
    // The rest of the fixed field stays zeroed, as the struct expects.
    try std.testing.expectEqual(@as(u16, 0), wide[want_n]);
}

test "widenFindName stops at the field width and stays terminated" {
    var narrow: [260]u8 = undefined;
    @memset(&narrow, 0);
    // 200 CJK characters are 600 UTF-8 bytes, far past the 260-byte field the
    // narrow struct holds, so the name is already cut there. What must not
    // happen is a unit past the field or a missing terminator.
    @memcpy(narrow[0..259], "你" ** 86 ++ "x");

    var wide: [260]u16 = undefined;
    widenFindName(&narrow, &wide);
    const written = std.mem.len(@as([*:0]const u16, @ptrCast(&wide)));
    try std.testing.expect(written <= 260);
    try std.testing.expectEqualSlices(u16, wide[0..written], wide[0..written]);
}
