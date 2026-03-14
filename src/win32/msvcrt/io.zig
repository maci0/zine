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

/// On WASM, _iob is allocated in guest memory at this virtual address.
/// Set by wasm_main.zig during startup.
pub var iob_guest_addr: usize = 0;

// We need a way to map MSVCRT_FILE pointers to Zig File handles.
// Since we don't want to use malloc/free for everything, we can keep a simple array of open files.
const max_files = 64;
var file_handles: [max_files]?std.fs.File = [_]?std.fs.File{null} ** max_files;
var file_structs: [max_files]MSVCRT_FILE = [_]MSVCRT_FILE{std.mem.zeroes(MSVCRT_FILE)} ** max_files;

pub fn getFile(ptr: ?*anyopaque) ?std.fs.File {
    if (ptr) |p| {
        const ptr_val = @intFromPtr(p);

        // Check standard streams: on WASM iob_guest_addr is set and we
        // translate via trace.addr(); on native it's 0 so we use the
        // host-address msvcrt_iob directly.  Single code path, no
        // comptime platform branch.
        if (iob_guest_addr != 0) {
            // Guest-memory _iob (WASM): translate both pointer and
            // iob base to host addresses, then compare.
            const translated = trace.addr(ptr_val);
            const iob_host = trace.addr(iob_guest_addr);
            const iob_end = iob_host + @sizeOf(@TypeOf(msvcrt_iob));
            if (translated >= iob_host and translated < iob_end) {
                return stdFileFromIobIndex((translated - iob_host) / @sizeOf(MSVCRT_FILE));
            }
        } else {
            // Host-address _iob (native / interpret)
            const iob_start = @intFromPtr(&msvcrt_iob);
            if (ptr_val >= iob_start and ptr_val < iob_start + @sizeOf(@TypeOf(msvcrt_iob))) {
                return stdFileFromIobIndex((ptr_val - iob_start) / @sizeOf(MSVCRT_FILE));
            }
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

/// Map _iob index (0=stdin, 1=stdout, 2=stderr) to a std.fs.File.
fn stdFileFromIobIndex(idx: usize) ?std.fs.File {
    return switch (idx) {
        0 => std.fs.File{ .handle = 0 },
        1 => std.fs.File{ .handle = 1 },
        2 => std.fs.File{ .handle = 2 },
        else => null,
    };
}

fn allocateFileSlot() ?usize {
    for (0..max_files) |i| {
        if (file_handles[i] == null) {
            return i;
        }
    }
    return null;
}

pub fn p_iob() callconv(.c) *anyopaque {
    return &msvcrt_iob;
}

/// Initialize guest-memory _iob with pre-allocated stdout/stderr buffers.
/// Called by wasm_main.zig after relocateDataExports() has placed _iob in
/// guest memory.  Allocates CRT-style I/O buffers and sets FILE flags so
/// that the CRT's _flsbuf / _write path works without running _ioinit.
pub fn initGuestIob(gmem: anytype, combined_buf: []u8, base_addr: u32, guest_va: u32) void {
    iob_guest_addr = guest_va;
    const iob_offset = guest_va - base_addr;

    // MSVC6 CRT BUFSIZ
    const BUFSIZ: u32 = 4096;
    const stdout_buf_va = gmem.guestAlloc(BUFSIZ);
    const stderr_buf_va = gmem.guestAlloc(BUFSIZ);

    // _iob[1] = stdout: buffered write
    if (stdout_buf_va != 0) {
        const stdout_iob = @as(*MSVCRT_FILE, @ptrCast(@alignCast(
            combined_buf[iob_offset + @sizeOf(MSVCRT_FILE) ..].ptr,
        )));
        stdout_iob._base = stdout_buf_va;
        stdout_iob._ptr = stdout_buf_va;
        stdout_iob._cnt = @intCast(BUFSIZ);
        stdout_iob._bufsiz = @intCast(BUFSIZ);
        stdout_iob._flag = 0x0082; // _IOWRT | _IOFLRTN
    }

    // _iob[2] = stderr: unbuffered write
    if (stderr_buf_va != 0) {
        const stderr_iob = @as(*MSVCRT_FILE, @ptrCast(@alignCast(
            combined_buf[iob_offset + 2 * @sizeOf(MSVCRT_FILE) ..].ptr,
        )));
        stderr_iob._base = stderr_buf_va;
        stderr_iob._ptr = stderr_buf_va;
        stderr_iob._cnt = @intCast(BUFSIZ);
        stderr_iob._bufsiz = @intCast(BUFSIZ);
        stderr_iob._flag = 0x0006; // _IOWRT | _IONBF
    }
}

pub fn stub_setmode(fd: i32, mode: i32) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _setmode(fd={d}, mode={x})\n", .{fd, mode});
    // Stub: always returns 0 (previous mode). Does not change translation mode.
    return 0;
}

var global_filename_buf: [4096]u8 align(16) = undefined;
var global_mode_buf: [32]u8 align(16) = undefined;

pub fn fsopen(filename_ptr: usize, mode_ptr: usize, shflag: i32) callconv(.c) ?*anyopaque {
    _ = shflag;
    return fopen(filename_ptr, mode_ptr);
}

pub fn fopen(filename_ptr: usize, mode_ptr: usize) callconv(.c) ?*anyopaque {
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
        const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed)), posix_fs.O_CREAT | posix_fs.O_RDWR | posix_fs.O_TRUNC, 0o666);
        if (rc < 0) {
            trace.print("MSVCRT_IO: fopen createFile failed\n", .{});
            return null;
        }
        file = std.fs.File{ .handle = @intCast(rc) };
    } else if (a_idx != null) {
        const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed)), posix_fs.O_CREAT | posix_fs.O_RDWR | posix_fs.O_APPEND, 0o666);
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

pub fn fclose(f: ?*anyopaque) callconv(.c) i32 {
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

pub fn fread(buffer: [*]u8, size: usize, count: usize, f: ?*anyopaque) callconv(.c) usize {
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

pub fn fwrite(buffer: [*]const u8, size: usize, count: usize, f: ?*anyopaque) callconv(.c) usize {
    const bytes_to_write = size *% count;
    trace.print("MSVCRT_IO: fwrite (size: {d}, count: {d}, total: {d})\n", .{ size, count, bytes_to_write });
    // Defensive: a size > 256MB is almost certainly a sign-extension bug.
    if (bytes_to_write > 256 * 1024 * 1024 or bytes_to_write == 0) {
        if (bytes_to_write > 0) {
            // Try to read up to 256 bytes from the buffer to see what was being written
            const preview_len: usize = @min(256, @as(usize, @intFromPtr(buffer)) + 256);
            _ = preview_len;
            const preview = buffer[0..@min(256, bytes_to_write)];
            trace.print("MSVCRT_IO: fwrite REJECTED (size {d}) preview: {s}\n", .{ bytes_to_write, preview });
        }
        return 0;
    }
    if (getFile(f)) |file| {
        file.writeAll(buffer[0..bytes_to_write]) catch return 0;
        return count;
    }
    return 0;
}

pub fn fseek(f: ?*anyopaque, offset: i32, origin: i32) callconv(.c) i32 {
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

pub fn ftell(f: ?*anyopaque) callconv(.c) i32 {
    if (getFile(f)) |file| {
        const pos = file.getPos() catch return -1;
        trace.print("MSVCRT_IO: ftell -> {d}\n", .{pos});
        return @intCast(pos);
    }
    trace.print("MSVCRT_IO: ftell -> failed\n", .{});
    return -1;
}

pub fn fgets(buf_ptr: usize, max_count: i32, f: ?*anyopaque) callconv(.c) usize {
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

pub fn fgetc(f: ?*anyopaque) callconv(.c) i32 {
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

pub fn fputc(c: i32, f: ?*anyopaque) callconv(.c) i32 {
    if (getFile(f)) |file| {
        var buf: [1]u8 = undefined;
        buf[0] = @intCast(c & 0xFF);
        file.writeAll(&buf) catch return -1;
        // Don't trace every single character to avoid spam, or maybe just trace it if needed
        return buf[0];
    }
    return -1;
}

pub fn putchar(c: i32) callconv(.c) i32 {
    var buf: [1]u8 = undefined;
    buf[0] = @intCast(c & 0xFF);
    const out_file = std.fs.File{ .handle = 1 }; // stdout
    out_file.writeAll(&buf) catch return -1;
    return buf[0];
}

const fmt_mod = @import("fmt.zig");

const platform_mod = @import("../../platform.zig");

pub const fprintf = if (platform_mod.is_wasm) stub_fprintf_wasm else stub_fprintf_native;

fn stub_fprintf_wasm(f: ?*anyopaque, format_ptr: usize, ap: usize) callconv(.c) i32 {
    return fprintf_impl(f, format_ptr, ap);
}

fn stub_fprintf_native(f: ?*anyopaque, format_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return fprintf_impl(f, format_ptr, fmt_mod.va_list_to_usize(ap));
}

fn fprintf_impl(f: ?*anyopaque, format_ptr: usize, ap: usize) i32 {
    if (getFile(f)) |file| {
        if (format_ptr != 0) {
            const fmt = @as([*:0]const u8, @ptrFromInt(trace.addr(format_ptr)));
            var buf: [4096]u8 = undefined;
            const len = fmt_mod.x86_vsnprintf(&buf, 4096, fmt, ap);
            file.writeAll(buf[0..len]) catch return -1;
            return @intCast(len);
        }
        return -1;
    }
    return -1;
}

pub fn fwprintf(f: ?*anyopaque, format_ptr: usize) callconv(.c) i32 {
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
