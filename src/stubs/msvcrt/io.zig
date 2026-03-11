const std = @import("std");
const trace = @import("../../trace.zig");

fn log_call(comptime name: []const u8) void {
    trace.print("MSVCRT_IO: {s}\n", .{name});
}

pub const MSVCRT_FILE = extern struct {
    _ptr: u32,
    _cnt: i32,
    _base: u32,
    _flag: i32,
    _file: i32,
    _charbuf: i32,
    _bufsiz: i32,
    _tmpfname: u32,
};

// Ensure our size matches what MSVCRT expects (32 bytes on x86)
comptime {
    std.debug.assert(@sizeOf(MSVCRT_FILE) == 32);
}

pub var msvcrt_iob: [3]MSVCRT_FILE = [_]MSVCRT_FILE{
    // stdin
    MSVCRT_FILE{ ._ptr = 0, ._cnt = 0, ._base = 0, ._flag = 0x0001, ._file = 0, ._charbuf = 0, ._bufsiz = 0, ._tmpfname = 0 },
    // stdout
    MSVCRT_FILE{ ._ptr = 0, ._cnt = 0, ._base = 0, ._flag = 0x0002, ._file = 1, ._charbuf = 0, ._bufsiz = 0, ._tmpfname = 0 },
    // stderr
    MSVCRT_FILE{ ._ptr = 0, ._cnt = 0, ._base = 0, ._flag = 0x0004, ._file = 2, ._charbuf = 0, ._bufsiz = 0, ._tmpfname = 0 },
};

// We need a way to map MSVCRT_FILE pointers to Zig File handles.
// Since we don't want to use malloc/free for everything, we can keep a simple array of open files.
const MAX_FILES = 64;
var file_handles: [MAX_FILES]?std.fs.File = [_]?std.fs.File{null} ** MAX_FILES;
var file_structs: [MAX_FILES]MSVCRT_FILE = [_]MSVCRT_FILE{std.mem.zeroes(MSVCRT_FILE)} ** MAX_FILES;

pub fn getFile(ptr: ?*anyopaque) ?std.fs.File {
    if (ptr) |p| {
        const ptr_val = @intFromPtr(p);

        // Check if it's one of the standard streams
        const iob_start = @intFromPtr(&msvcrt_iob);
        if (ptr_val >= iob_start and ptr_val < iob_start + @sizeOf(@TypeOf(msvcrt_iob))) {
            const idx = (ptr_val - iob_start) / @sizeOf(MSVCRT_FILE);
            if (idx == 0) return std.fs.File{ .handle = 0 }; // stdin
            if (idx == 1) return std.fs.File{ .handle = 1 }; // stdout
            if (idx == 2) return std.fs.File{ .handle = 2 }; // stderr
        }

        // Check if it's one of our dynamically opened files
        const files_start = @intFromPtr(&file_structs);
        if (ptr_val >= files_start and ptr_val < files_start + @sizeOf(@TypeOf(file_structs))) {
            const idx = (ptr_val - files_start) / @sizeOf(MSVCRT_FILE);
            return file_handles[idx];
        }
    }
    return null;
}

fn allocateFileSlot() ?usize {
    for (0..MAX_FILES) |i| {
        if (file_handles[i] == null) {
            return i;
        }
    }
    return null;
}

pub fn stub_p_iob() callconv(.c) *anyopaque {
    return &msvcrt_iob;
}

pub fn stub_setmode(fd: i32, mode: i32) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _setmode(fd={d}, mode={x})\n", .{fd, mode});
    // Stub: always returns 0 (previous mode). Does not change translation mode.
    return 0;
}

var global_filename_buf: [4096]u8 align(16) = undefined;
var global_mode_buf: [32]u8 align(16) = undefined;

pub fn stub_fsopen(filename_ptr: usize, mode_ptr: usize, shflag: i32) callconv(.c) ?*anyopaque {
    _ = shflag;
    return stub_fopen(filename_ptr, mode_ptr);
}

pub fn stub_fopen(filename_ptr: usize, mode_ptr: usize) callconv(.c) ?*anyopaque {
    if (filename_ptr == 0 or mode_ptr == 0) return null;

    const filename = trace.c_span(filename_ptr);
    const mode = trace.c_span(mode_ptr);

    const len = @min(filename.len, 4095);
    const name_slice = global_filename_buf[0..len];
    @memcpy(name_slice, filename[0..len]);
    
    // Convert backslashes to forward slashes for Linux
    std.mem.replaceScalar(u8, name_slice, '\\', '/');

    const mode_len = @min(mode.len, 31);
    const mode_slice = global_mode_buf[0..mode_len];
    @memcpy(mode_slice, mode[0..mode_len]);
    
    trace.print("MSVCRT_IO: fopen {s} (mode: {s})\n", .{ name_slice, mode_slice });
    trace.print("  raw hex: ", .{});
    for (name_slice) |b| trace.print("{x:0>2} ", .{b});
    trace.print("\n", .{});

    var fixed: [1024]u8 = undefined;
    const name_len = @min(name_slice.len, 1023);
    @memcpy(fixed[0..name_len], name_slice[0..name_len]);
    fixed[name_len] = 0;
    const posix_fs = @import("posix_fs.zig");

    var file: std.fs.File = undefined;
    var w_idx: ?usize = null;
    var a_idx: ?usize = null;
    for (0..mode_slice.len) |i| {
        if (mode_slice[i] == 'w') w_idx = i;
        if (mode_slice[i] == 'a') a_idx = i;
    }

    if (w_idx != null) {
        const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed)), 0o100 | 0o2 | 0o1000, 0o666);
        if (rc < 0) {
            trace.print("MSVCRT_IO: fopen createFile failed\n", .{});
            return null;
        }
        file = std.fs.File{ .handle = @intCast(rc) };
    } else if (a_idx != null) {
        const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed)), 0o100 | 0o2 | 0o2000, 0o666);
        if (rc < 0) {
            trace.print("MSVCRT_IO: fopen openFile (append) failed\n", .{});
            return null;
        }
        file = std.fs.File{ .handle = @intCast(rc) };
    } else {
        const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed)), 0, 0);
        if (rc < 0) {
            trace.print("MSVCRT_IO: fopen openFile failed\n", .{});
            return null;
        }
        file = std.fs.File{ .handle = @intCast(rc) };
    }

    if (allocateFileSlot()) |idx| {
        file_handles[idx] = file;
        var ms_file = &file_structs[idx];

        ms_file._ptr = 0;
        ms_file._cnt = 0;
        ms_file._base = 0;
        ms_file._charbuf = 0;
        ms_file._bufsiz = 0;
        ms_file._tmpfname = 0;

        // _flag = 1 (read), 2 (write), 3 (read/write) roughly
        if (std.mem.indexOfScalar(u8, mode_slice, 'r') != null) {
            ms_file._flag = 0x0001; // _IOREAD
        } else {
            ms_file._flag = 0x0002; // _IOWRT
        }

        ms_file._file = @intCast(file.handle); // Store raw fd just in case
        return ms_file;
    } else {
        file.close();
        return null;
    }
}

pub fn stub_fclose(f: ?*anyopaque) callconv(.c) i32 {
    trace.print("MSVCRT_IO: fclose\n", .{});
    if (getFile(f)) |file| {
        const ptr_val = @intFromPtr(f.?);
        const files_start = @intFromPtr(&file_structs);
        if (ptr_val >= files_start and ptr_val < files_start + @sizeOf(@TypeOf(file_structs))) {
            const idx = (ptr_val - files_start) / @sizeOf(MSVCRT_FILE);
            file.close();
            file_handles[idx] = null;
            return 0;
        }
        return 0;
    }
    return -1;
}

pub fn stub_fread(buffer: [*]u8, size: usize, count: usize, f: ?*anyopaque) callconv(.c) usize {
    if (getFile(f)) |file| {
        const bytes_to_read = size * count;
        if (bytes_to_read == 0) return 0;
        const read_bytes = file.read(buffer[0..bytes_to_read]) catch return 0;
        const ret_count = read_bytes / size;
        if (read_bytes < bytes_to_read) {
            if (f) |ptr| {
                var ms_file = @as(*MSVCRT_FILE, @ptrCast(@alignCast(ptr)));
                ms_file._flag |= 0x0010; // _IOEOF
            }
        }
        trace.print("MSVCRT_IO: fread (size: {d}, count: {d}) -> returned {d}\n", .{ size, count, ret_count });
        if (read_bytes > 0 and read_bytes < 100) {
            trace.print("  Read bytes: {s} (ptr=0x{x})\n", .{ buffer[0..read_bytes], @intFromPtr(buffer) });
        }
        return ret_count;
    }
    trace.print("MSVCRT_IO: fread (size: {d}, count: {d}) -> failed (null file)\n", .{ size, count });
    return 0;
}

pub fn stub_fwrite(buffer: [*]const u8, size: usize, count: usize, f: ?*anyopaque) callconv(.c) usize {
    trace.print("MSVCRT_IO: fwrite (size: {d}, count: {d})\n", .{ size, count });
    if (getFile(f)) |file| {
        const bytes_to_write = size * count;
        if (bytes_to_write == 0) return 0;
        file.writeAll(buffer[0..bytes_to_write]) catch return 0;
        return count;
    }
    return 0;
}

pub fn stub_fseek(f: ?*anyopaque, offset: i32, origin: i32) callconv(.c) i32 {
    trace.print("MSVCRT_IO: fseek(offset={d}, origin={d})\n", .{ offset, origin });
    if (getFile(f)) |file| {
        switch (origin) {
            0 => file.seekTo(@intCast(offset)) catch return -1,
            1 => {
                const pos = file.getPos() catch return -1;
                const new_pos = @as(i64, @intCast(pos)) + @as(i64, offset);
                file.seekTo(@intCast(new_pos)) catch return -1;
            },
            2 => {
                const end = file.getEndPos() catch return -1;
                const new_pos = @as(i64, @intCast(end)) + @as(i64, offset);
                file.seekTo(@intCast(new_pos)) catch return -1;
            },
            else => return -1,
        }
        return 0;
    }
    return -1;
}

pub fn stub_ftell(f: ?*anyopaque) callconv(.c) i32 {
    if (getFile(f)) |file| {
        const pos = file.getPos() catch return -1;
        trace.print("MSVCRT_IO: ftell -> {d}\n", .{pos});
        return @intCast(pos);
    }
    trace.print("MSVCRT_IO: ftell -> failed\n", .{});
    return -1;
}

pub fn stub_fgets(buf_ptr: usize, max_count: i32, f: ?*anyopaque) callconv(.c) usize {
    if (buf_ptr == 0 or max_count <= 1) return 0;
    if (getFile(f)) |file| {
        const buf = @as([*]u8, @ptrFromInt(buf_ptr));
        const limit = @as(usize, @intCast(max_count - 1));
        var i: usize = 0;
        while (i < limit) {
            var char_buf: [1]u8 = undefined;
            const read_bytes = file.read(&char_buf) catch break;
            if (read_bytes == 0) break;
            if (char_buf[0] == '\r') continue; // strip carriage return for now
            buf[i] = char_buf[0];
            i += 1;
            if (char_buf[0] == '\n') break;
        }
        if (i == 0) return 0; // EOF
        buf[i] = 0;
        if (trace.enable_tracing) trace.print("MSVCRT_IO: fgets -> '{s}'\n", .{buf[0..i]});
        return buf_ptr;
    }
    return 0;
}

pub fn stub_fgetc(f: ?*anyopaque) callconv(.c) i32 {
    if (getFile(f)) |file| {
        var buf: [1]u8 = undefined;
        const bytes_read = file.read(&buf) catch return -1;
        if (bytes_read == 0) {
            if (f) |ptr| {
                var ms_file = @as(*MSVCRT_FILE, @ptrCast(@alignCast(ptr)));
                ms_file._flag |= 0x0010; // _IOEOF
            }
            trace.print("MSVCRT_IO: fgetc -> EOF\n", .{});
            return -1; // EOF
        }
        trace.print("MSVCRT_IO: fgetc -> {x:0>2}\n", .{buf[0]});
        return buf[0];
    }
    trace.print("MSVCRT_IO: fgetc -> failed (null file)\n", .{});
    return -1;
}

pub fn stub_fputc(c: i32, f: ?*anyopaque) callconv(.c) i32 {
    if (getFile(f)) |file| {
        var buf: [1]u8 = undefined;
        buf[0] = @intCast(c & 0xFF);
        file.writeAll(&buf) catch return -1;
        // Don't trace every single character to avoid spam, or maybe just trace it if needed
        return buf[0];
    }
    return -1;
}

pub fn stub_putchar(c: i32) callconv(.c) i32 {
    var buf: [1]u8 = undefined;
    buf[0] = @intCast(c & 0xFF);
    const out_file = std.fs.File{ .handle = 1 }; // stdout
    out_file.writeAll(&buf) catch return -1;
    return buf[0];
}

const misc = @import("misc.zig");

// Just prints the format string. We ignore varargs natively since x86 stack deals with it on return.
pub fn stub_fprintf(f: ?*anyopaque, format_ptr: usize, a1: usize, a2: usize, a3: usize, a4: usize) callconv(.c) i32 {
    if (getFile(f)) |file| {
        if (format_ptr != 0) {
            const fmt = @as([*:0]const u8, @ptrFromInt(format_ptr));
            var args = [_]usize{ a1, a2, a3, a4 };
            var buf: [4096]u8 = undefined;
            const len = misc.x86_vsnprintf(&buf, 4096, fmt, @intFromPtr(&args));
            file.writeAll(buf[0..len]) catch return -1;
            return @intCast(len);
        }
        return -1;
    }
    return -1;
}

pub fn stub_fwprintf(f: ?*anyopaque, format_ptr: usize) callconv(.c) i32 {
    if (getFile(f)) |file| {
        if (format_ptr != 0) {
            const fmt = @as([*]const u16, @ptrFromInt(format_ptr));
            const max_len = 4096;
            const len = std.mem.indexOfScalar(u16, fmt[0..max_len], 0) orelse max_len;
            
            var buf: [4096]u8 = undefined;
            for (0..len) |i| {
                buf[i] = @intCast(fmt[i] & 0xFF);
            }
            file.writeAll(buf[0..len]) catch return -1;
            return @intCast(len);
        }
        return -1;
    }
    return -1;
}
