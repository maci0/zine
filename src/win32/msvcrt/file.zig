/// Low-level fd-based file I/O — corresponds to <io.h> / <fcntl.h>.
/// This module handles _sopen, _read, _write, _lseek, _close, _stat,
/// _fstat, _findfirst, etc. — everything that operates on integer fds
/// rather than FILE* streams (which live in io.zig).
const std = @import("std");
const trace = @import("../../trace.zig");
const io = @import("io.zig");

const max_fds = 64;
var fd_handles: [max_fds]?std.fs.File = [_]?std.fs.File{null} ** max_fds;

pub fn alloc_fd() ?i32 {
    for (3..max_fds) |i| if (fd_handles[i] == null) return @intCast(i);
    return null;
}

pub fn get_fd_file(fd: i32) ?std.fs.File {
    if (fd == 0) return std.fs.File{ .handle = 0 };
    if (fd == 1) return std.fs.File{ .handle = 1 };
    if (fd == 2) return std.fs.File{ .handle = 2 };
    return if (fd >= 3 and fd < max_fds) fd_handles[@intCast(fd)] else null;
}

const FILE = io.MSVCRT_FILE;

pub fn access(path_ptr: usize, mode: i32) callconv(.c) i32 {
    if (path_ptr == 0) return -1;
    const path = trace.c_span(path_ptr);
    const posix_fs = @import("posix_fs.zig");
    const result = posix_fs.access(@as([*:0]const u8, @ptrFromInt(path_ptr)), mode);
    if (trace.enable_tracing) trace.print("MSVCRT: _access('{s}', {d}) -> {d}\n", .{ path, mode, result });
    return result;
}

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

    const pfs = @import("posix_fs.zig");
    var flags: u32 = 0;
    if ((oflag & o_creat) != 0) flags |= pfs.O_CREAT;
    if ((oflag & o_rdwr) != 0) {
        flags |= pfs.O_RDWR;
    } else if ((oflag & o_wronly) != 0) {
        flags |= pfs.O_WRONLY;
    }
    if ((oflag & o_trunc) != 0) flags |= pfs.O_TRUNC;
    if ((oflag & o_append) != 0) flags |= pfs.O_APPEND;

    const posix_fs = @import("posix_fs.zig");
    const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(@constCast(path.ptr))), flags, 0o666);
    if (rc < 0) {
        if (trace.enable_tracing) trace.print("  -> failed\n", .{});
        return -1;
    }
    if (trace.enable_tracing) trace.print("  -> fd {d}\n", .{rc});
    return rc;
}

pub fn read(fd: i32, buffer_ptr: usize, count: u32) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _read(fd={d}, count={d})\n", .{ fd, count });
    if (buffer_ptr == 0 or count == 0) return 0;
    const file = std.fs.File{ .handle = fd };
    const buf = @as([*]u8, @ptrFromInt(buffer_ptr));
    const read_bytes = file.read(buf[0..count]) catch return -1;
    if (trace.enable_tracing) {
        trace.print("  -> read {d} bytes\n", .{read_bytes});
        for (0..read_bytes) |i| {
            trace.print("{x:0>2} ", .{buf[i]});
        }
        trace.print("\n", .{});
    }
    return @intCast(read_bytes);
}

pub fn write(fd: i32, buffer_ptr: usize, count: u32) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _write(fd={d}, count={d})\n", .{ fd, count });
    if (buffer_ptr == 0 or count == 0) return 0;
    const slice = @as([*]const u8, @ptrFromInt(trace.addr(buffer_ptr)))[0..count];
    const out_file = std.fs.File{ .handle = fd };
    out_file.writeAll(slice) catch |err| {
        if (trace.enable_tracing) trace.print("  -> _write failed: {}\n", .{err});
        return -1;
    };
    return @intCast(count);
}

pub fn lseek(fd: i32, offset: i32, origin: i32) callconv(.c) i32 {
    const file = std.fs.File{ .handle = fd };
    switch (origin) {
        0 => file.seekTo(@intCast(offset)) catch return -1,
        1 => {
            const p = file.getPos() catch return -1;
            file.seekTo(@intCast(@as(i64, @intCast(p)) + offset)) catch return -1;
        },
        2 => {
            const e = file.getEndPos() catch return -1;
            file.seekTo(@intCast(@as(i64, @intCast(e)) + offset)) catch return -1;
        },
        else => return -1,
    }
    return @intCast(file.getPos() catch return -1);
}

pub fn close(fd: i32) callconv(.c) i32 {
    if (fd >= 3) {
        const file = std.fs.File{ .handle = fd };
        file.close();
        return 0;
    }
    return -1;
}

pub fn fileno(file_ptr: usize) callconv(.c) i32 {
    if (file_ptr != 0) {
        const ms_file = @as(*FILE, @ptrFromInt(file_ptr));
        return ms_file._file;
    }
    return -1;
}

pub fn stub_isatty(fd: i32) callconv(.c) i32 {
    if (fd == 0 or fd == 1 or fd == 2) return 1;
    return 0;
}

pub fn tell(fd: i32) callconv(.c) i32 {
    const file = std.fs.File{ .handle = fd };
    return @intCast(file.getPos() catch return -1);
}

pub fn chsize(fd: i32, size: i32) callconv(.c) i32 {
    const file = std.fs.File{ .handle = fd };
    file.setEndPos(@intCast(size)) catch return -1;
    return 0;
}

pub fn filelength(fd: i32) callconv(.c) i32 {
    const file = std.fs.File{ .handle = fd };
    if (file.getEndPos()) |pos| {
        if (trace.enable_tracing) trace.print("MSVCRT: _filelength(fd={d}) -> {d}\n", .{ fd, pos });
        return @intCast(pos);
    } else |_| {
        if (trace.enable_tracing) trace.print("MSVCRT: _filelength(fd={d}) -> failed\n", .{fd});
        return -1;
    }
}

pub fn stat(path_ptr: usize, stat_ptr: usize) callconv(.c) i32 {
    if (path_ptr < 0x10000 or stat_ptr == 0) return -1;
    const path = std.mem.span(@as([*:0]const u8, @ptrFromInt(path_ptr)));

    const posix_fs = @import("posix_fs.zig");
    if (posix_fs.stat(@as([*:0]const u8, @ptrFromInt(path_ptr)))) |stat_buf| {
        const out_buf = @as([*]u8, @ptrFromInt(stat_ptr));
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

pub fn fstat(fd: i32, stat_ptr: usize) callconv(.c) i32 {
    if (stat_ptr != 0) {
        const file = std.fs.File{ .handle = fd };
        if (file.stat() catch null) |st| {
            const stat_buf = @as([*]u8, @ptrFromInt(stat_ptr));
            @memset(stat_buf[0..36], 0);
            stat_buf[4] = 0x00;
            stat_buf[5] = 0x80; // _S_IFREG
            const size = @as(u32, @intCast(st.size));
            stat_buf[20] = @intCast(size & 0xFF);
            stat_buf[21] = @intCast((size >> 8) & 0xFF);
            stat_buf[22] = @intCast((size >> 16) & 0xFF);
            stat_buf[23] = @intCast((size >> 24) & 0xFF);

            if (trace.enable_tracing) trace.print("MSVCRT: _fstat(fd={d}) -> size {d}\n", .{ fd, st.size });
            return 0;
        }
    }
    return -1;
}

pub fn stub_findfirst(path_ptr: usize, find_data: usize) callconv(.c) isize {
    _ = path_ptr;
    _ = find_data;
    if (trace.enable_tracing) trace.print("MSVCRT: _findfirst returning -1\n", .{});
    return -1;
}

pub fn stub_findnext(handle: isize, find_data: usize) callconv(.c) i32 {
    _ = handle;
    _ = find_data;
    return -1;
}

pub fn get_osfhandle(fd: i32) callconv(.c) isize {
    return @as(isize, @intCast(fd));
}

pub fn open_osfhandle(osfhandle: isize, flags: i32) callconv(.c) i32 {
    _ = flags;
    return @intCast(osfhandle);
}
