//! MSVCRT low-level file descriptor I/O.

const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const io = @import("io.zig");

const max_fds = 64;
var fd_handles: [max_fds]?std.Io.File = [_]?std.Io.File{null} ** max_fds;

/// Internal helper to allocate a new file descriptor.
/// Implementation status: Partially implemented
pub fn alloc_fd() ?i32 {
    for (3..max_fds) |i| if (fd_handles[i] == null) return @intCast(i);
    return null;
}

/// Internal helper to get a std.Io.File from a file descriptor.
/// Implementation status: Partially implemented
pub fn get_fd_file(fd: i32) ?std.Io.File {
    if (fd == 0) return @import("../host_io.zig").fileFromFd(0);
    if (fd == 1) return @import("../host_io.zig").fileFromFd(1);
    if (fd == 2) return @import("../host_io.zig").fileFromFd(2);
    return if (fd >= 3 and fd < max_fds) fd_handles[@intCast(fd)] else null;
}

const FILE = io.MSVCRT_FILE;

/// Determines if a file has the specified access permissions.
/// Implementation status: Fully implemented
pub fn access(path_ptr: usize, mode: i32) callconv(.c) i32 {
    if (path_ptr == 0) return -1;
    const path = trace.c_span(path_ptr);
    const host_io = @import("../host_io.zig");
    const result = host_io.access(path, mode);
    if (trace.enable_tracing) trace.print("MSVCRT: _access('{s}', {d}) -> {d}\n", .{ path, mode, result });
    return result;
}

/// Opens a file with shared access.
/// Implementation status: Partially implemented
pub fn sopen(path_ptr: usize, oflag: i32, shflag: i32, pmode: i32) callconv(.c) i32 {
    _ = shflag;
    _ = pmode;
    if (path_ptr == 0) return -1;
    const path = trace.c_span(path_ptr);

    if (trace.enable_tracing) trace.print("MSVCRT: _sopen('{s}', {x})\n", .{ path, oflag });

    // Translate Windows oflags to POSIX flags
    // Windows CRT flag values (from MSVC headers)
    const o_wronly = 0x0001;
    const o_rdwr = 0x0002;
    const o_append = 0x0008;
    const o_creat = 0x0100;
    const o_trunc = 0x0200;

    const host_io = @import("../host_io.zig");
    var flags: u32 = 0;
    if ((oflag & o_creat) != 0) flags |= host_io.O_CREAT;
    if ((oflag & o_rdwr) != 0) {
        flags |= host_io.O_RDWR;
    } else if ((oflag & o_wronly) != 0) {
        flags |= host_io.O_WRONLY;
    }
    if ((oflag & o_trunc) != 0) flags |= host_io.O_TRUNC;
    if ((oflag & o_append) != 0) flags |= host_io.O_APPEND;

    const rc = host_io.open(path, flags, 0o666);
    if (rc < 0) {
        if (trace.enable_tracing) trace.print("  -> failed\n", .{});
        return -1;
    }
    if (trace.enable_tracing) trace.print("  -> fd {d}\n", .{rc});
    return rc;
}

/// Reads data from a file.
/// Implementation status: Fully implemented
pub fn read(fd: i32, buffer: [*]u8, count: u32) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _read(fd={d}, count={d})\n", .{ fd, count });
    if (count == 0) return 0;
    const file = @import("../host_io.zig").fileFromFd(fd);
    const buf = buffer;
    const read_bytes = @import("../host_io.zig").readFromFile(file, buf[0..count]) catch return -1;
    if (trace.enable_tracing) {
        trace.print("  -> read {d} bytes\n", .{read_bytes});
        for (0..read_bytes) |i| {
            trace.print("{x:0>2} ", .{buf[i]});
        }
        trace.print("\n", .{});
    }
    return @intCast(read_bytes);
}

/// Writes data to a file.
/// Implementation status: Fully implemented
pub fn write(fd: i32, buffer_ptr: usize, count: u32) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _write(fd={d}, buf={x}, count={d})\n", .{ fd, buffer_ptr, count });
    if (buffer_ptr == 0 or count == 0) return 0;
    // On WASM, read from guest memory buffer directly instead of trace.addr
    // (which may return a stale host pointer if WASM memory grew)
    const sc = @import("../shared.zig");
    const slice = if (sc.guest_memory) |gmem| blk: {
        const offset = @as(u32, @truncate(buffer_ptr)) -% gmem.base_addr;
        if (offset + count <= gmem.base.len) {
            break :blk gmem.base[offset..][0..count];
        }
        break :blk @as([*]const u8, @ptrFromInt(trace.addr(buffer_ptr)))[0..count];
    } else @as([*]const u8, @ptrFromInt(trace.addr(buffer_ptr)))[0..count];
    const out_file = @import("../host_io.zig").fileFromFd(fd);
    @import("../host_io.zig").writeAllToFile(out_file, slice) catch {
        if (trace.enable_tracing) trace.print("  -> _write failed\n", .{});
        return -1;
    };
    return @intCast(count);
}

/// Moves the file pointer to the specified location.
/// Implementation status: Fully implemented
pub fn lseek(fd: i32, offset: i32, origin: i32) callconv(.c) i32 {
    if (origin < 0 or origin > 2) return -1;
    const file = @import("../host_io.zig").fileFromFd(fd);
    const pos = @import("../../platform.zig").lseek(file.handle, offset, @intCast(origin));
    if (pos < 0) return -1;
    return @intCast(pos);
}

/// Closes the specified file.
/// Implementation status: Fully implemented
pub fn close(fd: i32) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _close(fd={d})\n", .{fd});
    if (comptime @import("../../platform.zig").is_wasm) {
        if (fd == 3) {
            if (trace.enable_tracing) trace.print("  -> ignored (WASI root dir)\n", .{});
            return 0;
        }
    }
    if (fd >= 3) {
        const file = @import("../host_io.zig").fileFromFd(fd);
        if (comptime @import("builtin").os.tag == .linux) {
            // Raw close: std.Io.File.close goes through Io.Threaded (TLS),
            // which faults inside the compat-mode SIGSEGV dispatch handler.
            _ = std.os.linux.close(file.handle);
        } else {
            file.close(runtime.io());
        }
        return 0;
    }
    return -1;
}

/// Retrieves the file descriptor associated with a stream.
/// Implementation status: Fully implemented
pub fn fileno(file_ptr: ?*FILE) callconv(.c) i32 {
    if (file_ptr) |ms_file| {
        return ms_file._file;
    }
    return -1;
}

/// Determines whether a file descriptor is associated with a character device.
/// Implementation status: Fully implemented
pub fn stub_isatty(fd: i32) callconv(.c) i32 {
    if (fd == 0 or fd == 1 or fd == 2) return 1;
    return 0;
}

/// Gets the current position of the file pointer.
/// Implementation status: Fully implemented
pub fn tell(fd: i32) callconv(.c) i32 {
    const file = @import("../host_io.zig").fileFromFd(fd);
    const pos = @import("../../platform.zig").lseek(file.handle, 0, 1);
    if (pos < 0) return -1;
    return @intCast(pos);
}

/// Changes the size of a file.
/// Implementation status: Fully implemented
pub fn chsize(fd: i32, size: i32) callconv(.c) i32 {
    const file = @import("../host_io.zig").fileFromFd(fd);
    if (comptime @import("builtin").os.tag == .linux) {
        // Raw ftruncate: std.Io.File.setLength touches TLS (see _close).
        const rc = std.os.linux.ftruncate(file.handle, size);
        if (@as(isize, @bitCast(rc)) < 0) return -1;
        return 0;
    }
    file.setLength(runtime.io(), @intCast(size)) catch return -1;
    return 0;
}

/// Gets the length of a file.
/// Implementation status: Fully implemented
pub fn filelength(fd: i32) callconv(.c) i32 {
    const file = @import("../host_io.zig").fileFromFd(fd);
    if (comptime @import("builtin").os.tag == .linux) {
        const posix_fs = @import("posix_fs.zig");
        const st = posix_fs.fstatFdLinux(file.handle) orelse return -1;
        if (trace.enable_tracing) trace.print("MSVCRT: _filelength(fd={d}) -> {d}\n", .{ fd, st.size });
        return @intCast(st.size);
    }
    if (file.length(runtime.io())) |pos| {
        if (trace.enable_tracing) trace.print("MSVCRT: _filelength(fd={d}) -> {d}\n", .{ fd, pos });
        return @intCast(pos);
    } else |_| {
        if (trace.enable_tracing) trace.print("MSVCRT: _filelength(fd={d}) -> failed\n", .{fd});
        return -1;
    }
}

/// Gets status information on a file.
/// Implementation status: Partially implemented
pub fn stat(path_str: [*:0]const u8, stat_out: [*]u8) callconv(.c) i32 {
    const path = std.mem.span(path_str);

    const host_io = @import("../host_io.zig");
    if (host_io.stat(path)) |stat_buf| {
        const out_buf = stat_out;
        @memset(out_buf[0..36], 0);
        out_buf[4] = 0x00;
        out_buf[5] = if (stat_buf.kind == .directory) 0x40 else 0x80; // _S_IFDIR or _S_IFREG
        const size = @as(u32, @intCast(stat_buf.size));
        out_buf[20] = @intCast(size & 0xFF);
        out_buf[21] = @intCast((size >> 8) & 0xFF);
        out_buf[22] = @intCast((size >> 16) & 0xFF);
        out_buf[23] = @intCast((size >> 24) & 0xFF);
        if (trace.enable_tracing) trace.print("MSVCRT: _stat('{s}') -> 0 (size={d})\n", .{ path, stat_buf.size });
        return 0;
    }
    if (trace.enable_tracing) trace.print("MSVCRT: _stat('{s}') -> -1\n", .{path});
    return -1;
}

/// Gets status information on an open file.
/// Implementation status: Partially implemented
pub fn fstat(fd: i32, stat_out: [*]u8) callconv(.c) i32 {
    {
        const file = @import("../host_io.zig").fileFromFd(fd);
        const st = if (comptime @import("builtin").os.tag == .linux)
            @import("posix_fs.zig").fstatFdLinux(file.handle)
        else
            file.stat(runtime.io()) catch null;
        if (st) |st_| {
            const stat_buf = stat_out;
            @memset(stat_buf[0..36], 0);
            stat_buf[4] = 0x00;
            stat_buf[5] = 0x80; // _S_IFREG
            const size = @as(u32, @intCast(st_.size));
            stat_buf[20] = @intCast(size & 0xFF);
            stat_buf[21] = @intCast((size >> 8) & 0xFF);
            stat_buf[22] = @intCast((size >> 16) & 0xFF);
            stat_buf[23] = @intCast((size >> 24) & 0xFF);

            if (trace.enable_tracing) trace.print("MSVCRT: _fstat(fd={d}) -> size {d}\n", .{ fd, st_.size });
            return 0;
        }
    }
    return -1;
}

/// Finds the first instance of a filename that matches the file specified in the argument.
/// Implementation status: Stub
pub fn stub_findfirst(path_ptr: usize, find_data: usize) callconv(.c) isize {
    _ = path_ptr;
    _ = find_data;
    if (trace.enable_tracing) trace.print("MSVCRT: _findfirst returning -1\n", .{});
    return -1;
}

/// Finds the next name, if any, that matches the argument specified in a previous call to _findfirst.
/// Implementation status: Stub
pub fn stub_findnext(handle: isize, find_data: usize) callconv(.c) i32 {
    _ = handle;
    _ = find_data;
    return -1;
}

/// Retrieves the operating-system file handle that is associated with the specified file descriptor.
/// Implementation status: Fully implemented
pub fn get_osfhandle(fd: i32) callconv(.c) isize {
    return @as(isize, @intCast(fd));
}

/// Associates a C run-time file descriptor with an existing operating-system file handle.
/// Implementation status: Fully implemented
pub fn open_osfhandle(osfhandle: isize, flags: i32) callconv(.c) i32 {
    _ = flags;
    return @intCast(osfhandle);
}

/// UCRT replacement for _iob array access.
/// Implementation status: Fully implemented
pub fn acrt_iob_func(index: u32) callconv(.c) usize {
    if (index < 3) {
        // On WASM, _iob is relocated to guest memory — return guest VA
        if (io.iob_guest_addr != 0) {
            return io.iob_guest_addr + index * @sizeOf(io.MSVCRT_FILE);
        }
        return @intFromPtr(&io.msvcrt_iob[index]);
    }
    return 0;
}
