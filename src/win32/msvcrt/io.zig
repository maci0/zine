//! MSVCRT stream-based I/O implementation.
//!
//! This module implements the C standard library's FILE* stream functions and
//! the underlying MSVC CRT internal file descriptor table structures required
//! for formatted I/O and low-level descriptor validation.

const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const log = @import("../../log.zig");
const platform_mod = @import("../../platform.zig");

fn log_call(comptime name: []const u8) void {
    trace.print("MSVCRT_IO: {s}\n", .{name});
}

/// MSVCRT FILE._flag bits for stream error indicators. The guest reads these
/// through ferror/feof, so a host read or write failure has to set _IOERR
/// rather than look like a clean end of file.
const FLAG_IOEOF: i32 = 0x0010;
const FLAG_IOERR: i32 = 0x0020;

/// Sets an error indicator on a guest FILE and reports the failure to the log.
fn setStreamError(f: ?*anyopaque, comptime op: []const u8, err: anyerror) void {
    if (f) |ptr| {
        const ms_file = @as(*MSVCRT_FILE, @ptrCast(@alignCast(ptr)));
        ms_file._flag |= FLAG_IOERR;
    }
    log.err("MSVCRT_IO: {s} failed, stream error indicator set: {t}", .{ op, err });
}

/// MSVC CRT FILE structure (32-bit).
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

comptime {
    std.debug.assert(@sizeOf(MSVCRT_FILE) == 32);
}

/// Standard I/O stream table (stdin, stdout, stderr).
pub var msvcrt_iob: [3]MSVCRT_FILE = [_]MSVCRT_FILE{
    // stdin:  _IOREAD, bufsiz=512
    MSVCRT_FILE{ ._ptr = 0, ._cnt = 0, ._base = 0, ._flag = 0x0001, ._file = 0, ._charbuf = 0, ._bufsiz = 512, ._tmpfname = 0 },
    // stdout: _IOWRT, bufsiz=512
    MSVCRT_FILE{ ._ptr = 0, ._cnt = 0, ._base = 0, ._flag = 0x0002, ._file = 1, ._charbuf = 0, ._bufsiz = 512, ._tmpfname = 0 },
    // stderr: _IOWRT | _IONBF, bufsiz=2 (unbuffered, per MSVC CRT convention)
    MSVCRT_FILE{ ._ptr = 0, ._cnt = 0, ._base = 0, ._flag = 0x0006, ._file = 2, ._charbuf = 0, ._bufsiz = 2, ._tmpfname = 0 },
};

/// On WASM, _iob is allocated in guest memory at this virtual address.
pub var iob_guest_addr: usize = 0;

pub fn get_iob_guest_addr() usize {
    if (iob_guest_addr == 0) {
        if (comptime platform_mod.is_native) {
            const shared = @import("../shared.zig");
            if (shared.raw_alloc(@sizeOf([3]MSVCRT_FILE))) |addr_ptr| {
                const addr = @intFromPtr(addr_ptr);
                iob_guest_addr = addr;
                // copy static contents
                const ptr = @as(*[3]MSVCRT_FILE, @ptrCast(@alignCast(addr_ptr)));
                ptr.* = msvcrt_iob;
            }
        } else if (comptime platform_mod.is_x86_64) {
            const compat = @import("../../x86/compat_thunks.zig");
            if (compat.allocData(@ptrCast(&msvcrt_iob), @sizeOf([3]MSVCRT_FILE))) |addr32| {
                iob_guest_addr = addr32;
            }
        }
    }
    return if (iob_guest_addr != 0) iob_guest_addr else @intFromPtr(&msvcrt_iob);
}

const IOINFO_SIZE = 8; // sizeof(ioinfo) on x86
const IOINFO_TABLE_SIZE = 32; // entries per __pioinfo slot

// _osfile flag bits
const FOPEN: u8 = 0x01;
const FTEXT: u8 = 0x80;
const FDEV: u8 = 0x40;

/// Pre-initialized ioinfo table for fd 0-31.
/// Layout: [osfhnd: i32, osfile: u8, pipech: u8, pad: u16] × 32
pub var ioinfo_table0: [IOINFO_TABLE_SIZE * IOINFO_SIZE]u8 = init_ioinfo: {
    var buf: [IOINFO_TABLE_SIZE * IOINFO_SIZE]u8 = [_]u8{0} ** (IOINFO_TABLE_SIZE * IOINFO_SIZE);
    // fd 0 (stdin):  osfhnd=0, osfile=FOPEN|FTEXT|FDEV
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 0; // osfhnd = 0
    buf[4] = FOPEN | FTEXT | FDEV; // osfile
    // fd 1 (stdout): osfhnd=1, osfile=FOPEN|FTEXT|FDEV
    buf[8] = 1;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 0; // osfhnd = 1
    buf[12] = FOPEN | FTEXT | FDEV; // osfile
    // fd 2 (stderr): osfhnd=2, osfile=FOPEN|FTEXT|FDEV
    buf[16] = 2;
    buf[17] = 0;
    buf[18] = 0;
    buf[19] = 0; // osfhnd = 2
    buf[20] = FOPEN | FTEXT | FDEV; // osfile
    break :init_ioinfo buf;
};

/// __pioinfo: array of 64 pointers to ioinfo tables.
pub var pioinfo: [64]usize = [_]usize{0} ** 64;
pub var pioinfo_guest_addr: usize = 0;

pub fn get_pioinfo_guest_addr() usize {
    if (pioinfo_guest_addr == 0) {
        if (comptime platform_mod.is_native) {
            const shared = @import("../shared.zig");
            if (shared.raw_alloc(@sizeOf([64]usize))) |addr_ptr| {
                const addr = @intFromPtr(addr_ptr);
                pioinfo_guest_addr = addr;
                // setup table0
                if (pioinfo[0] == 0) initPioinfo();
                // Map table0 to guest memory too!
                if (shared.raw_alloc(@sizeOf(@TypeOf(ioinfo_table0)))) |table0_ptr| {
                    const table0_addr = @intFromPtr(table0_ptr);
                    const t0_ptr = @as(*@TypeOf(ioinfo_table0), @ptrCast(@alignCast(table0_ptr)));
                    t0_ptr.* = ioinfo_table0;

                    const ptr = @as(*[64]usize, @ptrCast(@alignCast(addr_ptr)));
                    ptr.* = [_]usize{0} ** 64;
                    ptr[0] = table0_addr;
                }
            }
        }
    }
    return if (pioinfo_guest_addr != 0) pioinfo_guest_addr else @intFromPtr(&pioinfo);
}

/// Initialize __pioinfo[0] to point to ioinfo_table0.
/// Implementation status: Partially implemented
pub fn initPioinfo() void {
    pioinfo[0] = @intFromPtr(&ioinfo_table0);
}

/// Total available file handles.
pub var nhandle: i32 = 256;

const max_files = 64;
var file_handles: [max_files]?std.Io.File = [_]?std.Io.File{null} ** max_files;
var file_ptrs: [max_files]usize = [_]usize{0} ** max_files;

/// Recycled FILE structs. raw_alloc never frees, and a guest that
/// fopen/fclose-cycles (logs, temp files, response files) would otherwise
/// grow the heap by @sizeOf(MSVCRT_FILE) per cycle forever. fopen pops from
/// here before allocating; the struct is fully reinitialized on reuse.
var file_ptr_free_list: [max_files]usize = [_]usize{0} ** max_files;
var file_ptr_free_count: usize = 0;

fn takeFileSlotPtr() usize {
    if (file_ptr_free_count > 0) {
        file_ptr_free_count -= 1;
        return file_ptr_free_list[file_ptr_free_count];
    }
    const ptr_opaque = @import("../shared.zig").raw_alloc(@sizeOf(MSVCRT_FILE)) orelse return 0;
    return @intFromPtr(ptr_opaque);
}

fn recycleFileSlotPtr(ptr: usize) void {
    if (ptr == 0 or file_ptr_free_count >= file_ptr_free_list.len) return;
    file_ptr_free_list[file_ptr_free_count] = ptr;
    file_ptr_free_count += 1;
}

/// Map MSVCRT_FILE pointers to Zig File handles.
/// Implementation status: Partially implemented
pub fn getFile(ptr: ?*anyopaque) ?std.Io.File {
    if (ptr) |p| {
        // The thunk layer hands us a HOST pointer for the guest FILE*.
        const ptr_val = @intFromPtr(p);

        // Check standard streams
        if (trace.enable_tracing) trace.print("MSVCRT: getFile(ptr_val={X}, iob_guest_addr={X})\n", .{ ptr_val, iob_guest_addr });
        if (iob_guest_addr != 0) {
            // iob_guest_addr is a GUEST address; translate to a host address
            // for the comparison (trace.addr is a no-op where guest==host).
            // On WASM, failing to translate made stdio FILE* lookups miss and
            // silently dropped every fwrite/fputs to stdout/stderr.
            const iob_host = trace.addr(iob_guest_addr);
            const iob_end = iob_host + @sizeOf([3]MSVCRT_FILE);
            if (ptr_val >= iob_host and ptr_val < iob_end) {
                if (trace.enable_tracing) trace.print("MSVCRT: got std idx {d}\n", .{(ptr_val - iob_host) / @sizeOf(MSVCRT_FILE)});
                return stdFileFromIobIndex((ptr_val - iob_host) / @sizeOf(MSVCRT_FILE));
            }
        } else {
            // Host-address _iob (pure native fallback)
            const iob_start = @intFromPtr(&msvcrt_iob);
            if (ptr_val >= iob_start and ptr_val < iob_start + @sizeOf(@TypeOf(msvcrt_iob))) {
                return stdFileFromIobIndex((ptr_val - iob_start) / @sizeOf(MSVCRT_FILE));
            }
        }

        // Check dynamically opened files
        for (0..max_files) |idx| {
            if (file_ptrs[idx] == ptr_val and file_handles[idx] != null) {
                return file_handles[idx];
            }
        }
    }
    return null;
}

/// Map _iob index (0=stdin, 1=stdout, 2=stderr) to a std.Io.File.
fn stdFileFromIobIndex(idx: usize) ?std.Io.File {
    const hio = @import("../host_io.zig");
    return switch (idx) {
        0 => hio.fileFromFd(0),
        1 => hio.fileFromFd(1),
        2 => hio.fileFromFd(2),
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

/// Retrieves the base address of the standard I/O stream table.
/// Implementation status: Partially implemented
pub fn p_iob() callconv(.c) usize {
    // On WASM, return the guest VA so the x86 interpreter can correctly
    // access the FILE structs through its guest memory translation.
    // On native, return the host address (interpreter uses native_linear mode).
    if (iob_guest_addr != 0) return iob_guest_addr;
    return @intFromPtr(&msvcrt_iob);
}

/// Initialize guest-memory _iob with pre-allocated stdout/stderr buffers.
/// Implementation status: Partially implemented
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

    // Also update the host msvcrt_iob so that __p__iob() returns correct flags.
    // On WASM the CRT may access _iob via either the data export (guest copy)
    // or via __p__iob() (host copy) — both must agree.
    msvcrt_iob[1]._flag = 0x0082; // _IOWRT | _IORW
    msvcrt_iob[1]._bufsiz = @intCast(BUFSIZ);
    msvcrt_iob[2]._flag = 0x0006; // _IOWRT | _IONBF
    msvcrt_iob[2]._bufsiz = 2;
}

/// Set file translation mode.
/// Implementation status: Stub
pub fn stub_setmode(fd: i32, mode: i32) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _setmode(fd={d}, mode={x})\n", .{ fd, mode });
    // Stub: always returns 0 (previous mode). Does not change translation mode.
    return 0;
}

var global_filename_buf: [4096]u8 align(16) = undefined;
var global_mode_buf: [32]u8 align(16) = undefined;

/// Opens a file with shared access.
/// Implementation status: Partially implemented
pub fn fsopen(filename_ptr: usize, mode_ptr: usize, shflag: i32) callconv(.c) ?*anyopaque {
    _ = shflag;
    return fopen(filename_ptr, mode_ptr);
}

/// Opens a file.
/// Implementation status: Partially implemented
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

    var fixed: [1024]u8 = undefined;
    const name_len = @min(name_slice.len, 1023);
    @memcpy(fixed[0..name_len], name_slice[0..name_len]);
    fixed[name_len] = 0;
    const posix_fs = @import("posix_fs.zig");

    var file: std.Io.File = undefined;
    var w_idx: ?usize = null;
    var a_idx: ?usize = null;
    var plus_mode = false;
    for (0..mode_slice.len) |i| {
        if (mode_slice[i] == 'w') w_idx = i;
        if (mode_slice[i] == 'a') a_idx = i;
        if (mode_slice[i] == '+') plus_mode = true;
    }

    const host_io_mod = @import("../host_io.zig");

    if (w_idx != null) {
        const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed)), posix_fs.O_CREAT | posix_fs.O_RDWR | posix_fs.O_TRUNC, 0o666);
        if (rc < 0) {
            trace.print("MSVCRT_IO: fopen createFile failed\n", .{});
            return null;
        }
        file = @import("../host_io.zig").fileFromFd(@intCast(rc));
    } else if (a_idx != null) {
        const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed)), posix_fs.O_CREAT | posix_fs.O_RDWR | posix_fs.O_APPEND, 0o666);
        if (rc < 0) {
            trace.print("MSVCRT_IO: fopen openFile (append) failed\n", .{});
            return null;
        }
        file = @import("../host_io.zig").fileFromFd(@intCast(rc));
    } else if (plus_mode) {
        // "r+": existing file opened for update — no create, no truncate.
        // Opening O_RDONLY here made writes silently fail.
        const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed)), posix_fs.O_RDWR, 0);
        if (rc < 0) {
            trace.print("MSVCRT_IO: fopen openFile (r+) failed\n", .{});
            return null;
        }
        file = host_io_mod.fileFromFd(@intCast(rc));
    } else {
        const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(&fixed)), 0, 0);
        if (rc < 0) {
            trace.print("MSVCRT_IO: fopen openFile failed\n", .{});
            return null;
        }
        file = @import("../host_io.zig").fileFromFd(@intCast(rc));
    }

    if (allocateFileSlot()) |idx| {
        file_handles[idx] = file;

        const ptr = takeFileSlotPtr();
        if (ptr == 0) {
            @import("../host_io.zig").closeFile(file);
            file_handles[idx] = null;
            return null;
        }
        file_ptrs[idx] = ptr;

        // raw_alloc already returns a HOST pointer. Do NOT run it through
        // trace.addr again — on WASM a host pointer can numerically fall
        // inside the guest address range, and the second translation would
        // corrupt the address. The guest FILE* must translate back to this
        // exact host address in getFile() for fwrite/fread to match.
        var ms_file = @as(*MSVCRT_FILE, @ptrFromInt(ptr));
        ms_file._ptr = 0;
        ms_file._cnt = 0;
        ms_file._base = 0;
        ms_file._charbuf = 0;
        ms_file._bufsiz = 0;
        ms_file._tmpfname = 0;

        // _flag: 1 (read), 2 (write), 3 (read/write)
        if (plus_mode) {
            ms_file._flag = 0x0003; // _IOREAD | _IOWRT
        } else if (std.mem.indexOfScalar(u8, mode_slice, 'r') != null) {
            ms_file._flag = 0x0001; // _IOREAD
        } else {
            ms_file._flag = 0x0002; // _IOWRT
        }

        ms_file._file = @intCast(file.handle); // Store raw fd just in case
        return @ptrCast(ms_file); // Returns the guest pointer (from raw_alloc) mapped down by the thunks
    } else {
        @import("../host_io.zig").closeFile(file);
        return null;
    }
}

/// Closes a file.
/// Implementation status: Partially implemented
pub fn fclose(f: ?*anyopaque) callconv(.c) i32 {
    trace.print("MSVCRT_IO: fclose\n", .{});
    if (getFile(f)) |file| {
        const ptr_val = @intFromPtr(f.?);
        for (0..max_files) |idx| {
            if (file_ptrs[idx] == ptr_val) {
                if (comptime @import("builtin").os.tag == .linux) {
                    // Raw close: std.Io.File.close touches TLS, which faults
                    // inside the compat-mode SIGSEGV dispatch handler.
                    _ = std.os.linux.close(file.handle);
                } else {
                    file.close(runtime.io());
                }
                file_handles[idx] = null;
                recycleFileSlotPtr(file_ptrs[idx]);
                file_ptrs[idx] = 0;
                return 0;
            }
        }
        return 0;
    }
    return -1;
}

/// Flushes a stream (or all streams when stream is null).
/// Writes are unbuffered (direct fd), so this is a no-op that reports success.
pub fn fflush(f: ?*anyopaque) callconv(.c) i32 {
    if (f == null) {
        _ = _flushall();
        return 0;
    }
    if (getFile(f)) |_| return 0;
    return -1; // EOF
}

/// Flushes all streams; returns the number of streams open.
pub fn _flushall() callconv(.c) i32 {
    var n: i32 = 3; // stdin/stdout/stderr always open
    for (0..max_files) |idx| {
        if (file_handles[idx] != null) n += 1;
    }
    return n;
}

/// Sets the buffering mode/size of a stream. Buffering is a no-op here
/// (writes go straight to the fd); accept and return 0.
pub fn setvbuf(stream: ?*anyopaque, buffer: ?*anyopaque, mode: i32, size: usize) callconv(.c) i32 {
    _ = .{ stream, buffer, mode, size };
    return 0;
}

/// Closes all open streams (except the standard streams); returns the count.
pub fn _fcloseall() callconv(.c) i32 {
    var closed: i32 = 0;
    for (0..max_files) |idx| {
        if (file_handles[idx]) |file| {
            if (comptime @import("builtin").os.tag == .linux) {
                _ = std.os.linux.close(file.handle);
            } else {
                file.close(runtime.io());
            }
            file_handles[idx] = null;
            recycleFileSlotPtr(file_ptrs[idx]);
            file_ptrs[idx] = 0;
            closed += 1;
        }
    }
    return closed;
}

/// Closes a stream and reopens it with a new path/mode. Returns the new
/// stream pointer (or null on failure).
pub fn freopen(filename_ptr: usize, mode_ptr: usize, f: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = fclose(f);
    return fopen(filename_ptr, mode_ptr);
}

/// Reads data from a stream.
/// Implementation status: Partially implemented
pub fn fread(buffer: [*]u8, size: usize, count: usize, f: ?*anyopaque) callconv(.c) usize {
    if (getFile(f)) |file| {
        const bytes_to_read = size * count;
        if (bytes_to_read == 0) return 0;
        const read_bytes = @import("../host_io.zig").readFromFile(file, buffer[0..bytes_to_read]) catch |err| {
            // A failed read is not EOF: report it through _IOERR so the guest's
            // ferror() sees it. Returning 0 alone makes the guest stop reading
            // a stream that still has data.
            setStreamError(f, "read", err);
            return 0;
        };
        const ret_count = read_bytes / size;
        if (read_bytes < bytes_to_read) {
            if (f) |ptr| {
                var ms_file = @as(*MSVCRT_FILE, @ptrCast(@alignCast(ptr)));
                ms_file._flag |= FLAG_IOEOF;
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

/// Writes data to a stream.
/// Implementation status: Partially implemented
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
        @import("../host_io.zig").writeAllToFile(file, buffer[0..bytes_to_write]) catch |err| {
            // 0 items is the correct failure return, but without _IOERR the
            // guest cannot tell a full disk from a valid short write.
            setStreamError(f, "write", err);
            return 0;
        };
        return count;
    }
    return 0;
}

/// Moves the file pointer to a specified location.
/// Implementation status: Partially implemented
pub fn fseek(f: ?*anyopaque, offset: i32, origin: i32) callconv(.c) i32 {
    trace.print("MSVCRT_IO: fseek(offset={d}, origin={d})\n", .{ offset, origin });
    if (origin < 0 or origin > 2) return -1;
    if (getFile(f)) |file| {
        const pos = @import("../../platform.zig").lseek(file.handle, offset, @intCast(origin));
        if (pos < 0) return -1;
        return 0;
    }
    return -1;
}

/// Repositions the file pointer to the beginning of a stream and clears its
/// error indicators. Equivalent to fseek(f, 0, SEEK_SET) plus clearing
/// _IOEOF/_IOERR. MSVC c1/c2 use this to re-read their intermediate files;
/// a no-op here left the file position past the written data, so re-reads
/// came back empty/truncated ("compiler limit: out of keys" in P2).
pub fn rewind(f: ?*anyopaque) callconv(.c) void {
    trace.print("MSVCRT_IO: rewind\n", .{});
    if (f == null) return;
    _ = fseek(f, 0, 0);
    // Clear the _IOEOF and _IOERR flags in the guest FILE struct.
    // f is a host pointer (translated by the thunk layer).
    const ms_file = @as(*MSVCRT_FILE, @ptrCast(@alignCast(f.?)));
    ms_file._flag &= ~(FLAG_IOEOF | FLAG_IOERR);
}

/// Tests the error indicator on a stream. Returns nonzero when a host read or
/// write has failed, so the guest can tell a real I/O fault from a clean EOF.
/// Implementation status: Fully implemented
pub fn ferror(f: ?*anyopaque) callconv(.c) i32 {
    if (f == null) return 1;
    const ms_file = @as(*MSVCRT_FILE, @ptrCast(@alignCast(f.?)));
    return @intFromBool(ms_file._flag & FLAG_IOERR != 0);
}

/// Tests the end-of-file indicator on a stream. Returns nonzero only for a
/// genuine end of file, never for a failed read.
/// Implementation status: Fully implemented
pub fn feof(f: ?*anyopaque) callconv(.c) i32 {
    if (f == null) return 1;
    const ms_file = @as(*MSVCRT_FILE, @ptrCast(@alignCast(f.?)));
    return @intFromBool(ms_file._flag & FLAG_IOEOF != 0);
}

/// Gets the current position of a file pointer.
/// Implementation status: Partially implemented
pub fn ftell(f: ?*anyopaque) callconv(.c) i32 {
    if (getFile(f)) |file| {
        const pos = @import("../../platform.zig").lseek(file.handle, 0, 1);
        if (pos < 0) return -1;
        trace.print("MSVCRT_IO: ftell -> {d}\n", .{pos});
        return @intCast(pos);
    }
    trace.print("MSVCRT_IO: ftell -> failed\n", .{});
    return -1;
}

/// Gets a string from a stream.
/// Implementation status: Partially implemented
pub fn fgets(buf_ptr: usize, max_count: i32, f: ?*anyopaque) callconv(.c) usize {
    if (buf_ptr == 0 or max_count <= 1) return 0;
    if (getFile(f)) |file| {
        // buf_ptr is a guest VA (usize param — not auto-translated). Without
        // translation the line was written to the raw guest VA in linear
        // memory, leaving the guest's buffer empty — LINK's response-file
        // (@file) expansion then saw no arguments → LNK4001/LNK1561.
        const buf = @as([*]u8, @ptrFromInt(trace.addr(buf_ptr)));
        const limit = @as(usize, @intCast(max_count - 1));
        var i: usize = 0;
        while (i < limit) {
            var char_buf: [1]u8 = undefined;
            const read_bytes = @import("../host_io.zig").readFromFile(file, &char_buf) catch |err| {
                // Do not hand back a half-read line as if it were complete.
                setStreamError(f, "read", err);
                return 0;
            };
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

/// Gets a character from a stream.
/// Implementation status: Partially implemented
pub fn fgetc(f: ?*anyopaque) callconv(.c) i32 {
    if (getFile(f)) |file| {
        var buf: [1]u8 = undefined;
        const bytes_read = @import("../host_io.zig").readFromFile(file, &buf) catch |err| {
            // -1 is also the EOF result, so the only way the guest can see a
            // failed read is the _IOERR indicator.
            setStreamError(f, "read", err);
            return -1;
        };
        if (bytes_read == 0) {
            if (f) |ptr| {
                var ms_file = @as(*MSVCRT_FILE, @ptrCast(@alignCast(ptr)));
                ms_file._flag |= FLAG_IOEOF;
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

/// Writes a character to a stream.
/// Implementation status: Partially implemented
pub fn fputc(c: i32, f: ?*anyopaque) callconv(.c) i32 {
    if (getFile(f)) |file| {
        var buf: [1]u8 = undefined;
        buf[0] = @intCast(c & 0xFF);
        @import("../host_io.zig").writeAllToFile(file, &buf) catch return -1;
        // Don't trace every single character to avoid spam, or maybe just trace it if needed
        return buf[0];
    }
    return -1;
}

/// Writes a character to stdout.
/// Implementation status: Partially implemented
pub fn putchar(c: i32) callconv(.c) i32 {
    var buf: [1]u8 = undefined;
    buf[0] = @intCast(c & 0xFF);
    const out_file = @import("../host_io.zig").fileFromFd(1);
    @import("../../win32/host_io.zig").writeAllToFile(out_file, &buf) catch return -1;
    return buf[0];
}

const fmt_mod = @import("fmt.zig");

/// Prints formatted data to a stream.
/// Implementation status: Partially implemented
pub const fprintf = if (platform_mod.is_wasm or platform_mod.is_x86_64) stub_fprintf_wasm else stub_fprintf_native;

fn stub_fprintf_wasm(f: ?*anyopaque, format_ptr: usize, ap: usize) callconv(.c) i32 {
    return fprintf_impl(f, format_ptr, ap);
}

fn stub_fprintf_native(f: ?*anyopaque, format_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return fprintf_impl(f, format_ptr, fmt_mod.va_list_to_usize(ap));
}

fn fprintf_impl(f: ?*anyopaque, format_ptr: usize, ap: usize) i32 {
    // Fall back to stdout when the FILE* can't be resolved (e.g. a child
    // process's _iob FILE* that doesn't match the recorded iob range) — the
    // vfprintf stub does the same. Without this, DUMPBIN/LIB diagnostics were
    // silently dropped (exit 0, no output).
    const file = getFile(f) orelse @import("../host_io.zig").fileFromFd(1);
    if (format_ptr != 0) {
        const fmt = @as([*:0]const u8, @ptrFromInt(trace.addr(format_ptr)));
        var buf: [4096]u8 = undefined;
        const len = fmt_mod.x86_vsnprintf(&buf, 4096, fmt, ap);
        @import("../host_io.zig").writeAllToFile(file, buf[0..len]) catch return -1;
        return @intCast(len);
    }
    return -1;
}

/// Writes formatted data to a stream.
/// Implementation status: Partially implemented
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
            @import("../host_io.zig").writeAllToFile(file, buf[0..len]) catch return -1;
            return @intCast(len);
        }
        return -1;
    }
    return -1;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "fclose recycles FILE structs across fopen cycles" {
    file_handles = [_]?std.Io.File{null} ** max_files;
    file_ptrs = [_]usize{0} ** max_files;
    file_ptr_free_count = 0;

    var name_buf: [16]u8 = undefined;
    @memcpy(name_buf[0..9], "/dev/null");
    name_buf[9] = 0;
    var mode_buf: [4]u8 = undefined;
    @memcpy(mode_buf[0..2], "r\x00");

    const f1 = fopen(@intFromPtr(&name_buf), @intFromPtr(&mode_buf));
    try std.testing.expect(f1 != null);
    const p1 = @intFromPtr(f1.?);

    try std.testing.expectEqual(@as(i32, 0), fclose(f1));
    try std.testing.expectEqual(@as(usize, 0), file_ptrs[0]);

    // The second open must reuse the recycled struct instead of allocating.
    const f2 = fopen(@intFromPtr(&name_buf), @intFromPtr(&mode_buf));
    try std.testing.expect(f2 != null);
    try std.testing.expectEqual(p1, @intFromPtr(f2.?));
    _ = fclose(f2);
}
