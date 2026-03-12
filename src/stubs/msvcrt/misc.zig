const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const io = @import("io.zig");

const string = @import("string.zig");
const process = @import("process.zig");
const mem = @import("mem.zig");
const math = @import("math.zig");
const misc = @import("misc.zig");

const MAX_FDS = 64;
var fd_handles: [MAX_FDS]?std.fs.File = [_]?std.fs.File{null} ** MAX_FDS;

pub fn log_call(comptime name: []const u8) void {
    if (trace.enable_tracing) trace.print("MSVCRT: {s}\n", .{name});
}

pub fn stub_time(time_ptr: usize) callconv(.c) i32 {
    const t = @as(i32, @intCast(std.time.timestamp()));
    if (time_ptr != 0) {
        @as(*i32, @ptrFromInt(time_ptr)).* = t;
    }
    return t;
}

// struct tm for localtime
const TM = extern struct {
    tm_sec: i32 = 0,
    tm_min: i32 = 0,
    tm_hour: i32 = 0,
    tm_mday: i32 = 0,
    tm_mon: i32 = 0,
    tm_year: i32 = 0,
    tm_wday: i32 = 0,
    tm_yday: i32 = 0,
    tm_isdst: i32 = 0,
};
var localtime_result: TM = .{};

pub fn stub_localtime(time_ptr: usize) callconv(.c) *TM {
    if (time_ptr != 0) {
        const ts: u64 = @intCast(@as(*const i32, @ptrFromInt(time_ptr)).*);
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = ts };
        const epoch_day = epoch_secs.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch_secs.getDaySeconds();
        localtime_result = .{
            .tm_sec = @intCast(day_secs.getSecondsIntoMinute()),
            .tm_min = @intCast(day_secs.getMinutesIntoHour()),
            .tm_hour = @intCast(day_secs.getHoursIntoDay()),
            .tm_mday = @intCast(month_day.day_index + 1),
            .tm_mon = @intCast(@intFromEnum(month_day.month) - 1),
            .tm_year = @as(i32, @intCast(year_day.year)) - 1900,
            .tm_wday = @intCast((epoch_day.day + 4) % 7),
            .tm_yday = @intCast(year_day.day),
            .tm_isdst = 0,
        };
    }
    return &localtime_result;
}

pub fn stub_ignore_i32() callconv(.c) i32 {
    if (trace.enable_tracing) {
        trace.print("MSVCRT: ignored call (i32) from 0x{X}\n", .{@returnAddress()});
    }
    return 0;
}

pub fn stub_ignore_ptr() callconv(.c) ?*anyopaque {
    const ra = @returnAddress();
    if (trace.enable_tracing) trace.print("MSVCRT: ignored call (ptr) from 0x{X}\n", .{ra});
    return null;
}

const platform = @import("../../platform.zig");
const native_arch = @import("builtin").target.cpu.arch;

pub const stub_setjmp3 = if (platform.is_x86) &stub_setjmp3_x86 else if (platform.is_x86_64) &stub_setjmp3_x64 else &stub_setjmp3_generic;

fn stub_setjmp3_x86() callconv(.naked) i32 {
    asm volatile (
        \\mov 4(%esp), %eax   # env
        \\mov %ebp, 0(%eax)
        \\mov %ebx, 4(%eax)
        \\mov %edi, 8(%eax)
        \\mov %esi, 12(%eax)
        \\mov %esp, 16(%eax)
        \\mov (%esp), %edx   # return address
        \\mov %edx, 20(%eax)
        \\xor %eax, %eax
        \\ret
    );
}

fn stub_setjmp3_x64(env_ptr: usize) callconv(.c) i32 {
    // x86_64 setjmp: save callee-saved registers into jmp_buf
    const env = @as([*]u64, @ptrFromInt(env_ptr));
    env[0] = asm volatile ("movq %%rbp, %[out]" : [out] "=r" (-> u64));
    env[1] = asm volatile ("movq %%rbx, %[out]" : [out] "=r" (-> u64));
    // Return address is at [rsp] at call site, but we're in a regular function now
    // This is a simplified stub; full impl would need naked
    return 0;
}

fn stub_setjmp3_generic(_: usize) callconv(.c) i32 {
    return 0; // On WASM, setjmp is handled by the interpreter
}

pub const stub_EH_prolog = if (platform.is_x86) &stub_EH_prolog_x86 else if (platform.is_x86_64) &stub_EH_prolog_x64 else &stub_EH_prolog_generic;

fn stub_EH_prolog_x86() callconv(.naked) void {
    asm volatile (
        \\ pushl $-1
        \\ pushl %eax
        \\ pushl %fs:0
        \\ movl  %esp, %fs:0
        \\ movl  12(%esp), %eax
        \\ movl  %ebp, 12(%esp)
        \\ leal  12(%esp), %ebp
        \\ pushl %eax
        \\ ret
    );
}

fn stub_EH_prolog_x64() callconv(.c) void {
    // 32-bit SEH prolog N/A on x86_64
}

fn stub_EH_prolog_generic() callconv(.c) void {}

pub const stub_longjmp = if (platform.is_x86) &stub_longjmp_x86 else if (platform.is_x86_64) &stub_longjmp_x64 else &stub_longjmp_generic;

fn stub_longjmp_x86() callconv(.naked) void {
    asm volatile (
        \\mov 4(%esp), %edx   # env
        \\mov 8(%esp), %eax   # value
        \\test %eax, %eax
        \\jnz 1f
        \\inc %eax            # longjmp(0) returns 1
        \\1:
        \\mov 0(%edx), %ebp
        \\mov 4(%edx), %ebx
        \\mov 8(%edx), %edi
        \\mov 12(%edx), %esi
        \\mov 16(%edx), %esp
        \\add $4, %esp        # pop return address of setjmp
        \\jmp *20(%edx)       # jump back to setjmp caller
    );
}

fn stub_longjmp_x64(env_ptr: usize, value: i32) callconv(.c) void {
    // x86_64 longjmp stub — simplified, full impl needs naked
    _ = env_ptr;
    _ = value;
    // Log a warning instead of panicking — some apps use setjmp/longjmp
    // in non-critical paths and can survive this being a no-op
    if (trace.enable_tracing) trace.print("MSVCRT: WARNING: longjmp called on x86_64 (not fully implemented)\n", .{});
}

fn stub_longjmp_generic(_: usize, _: i32) callconv(.c) void {
    // On WASM, longjmp is handled by the interpreter
}

// --- Miscellaneous ---

pub fn stub_qsort(base: usize, num: usize, width: usize, compare_ptr: usize) callconv(.c) void {
    if (base == 0 or num == 0 or width == 0 or compare_ptr == 0) return;
    const compare = @as(*const fn (usize, usize) callconv(.c) i32, @ptrFromInt(compare_ptr));
    var i: usize = 0;
    while (i < num) : (i += 1) {
        var j: usize = i + 1;
        while (j < num) : (j += 1) {
            const ap = base + i * width;
            const bp = base + j * width;
            if (compare(ap, bp) > 0) {
                var k: usize = 0;
                while (k < width) : (k += 1) {
                    const a = @as(*u8, @ptrFromInt(ap + k));
                    const b = @as(*u8, @ptrFromInt(bp + k));
                    const t = a.*;
                    a.* = b.*;
                    b.* = t;
                }
            }
        }
    }
}

pub fn stub_bsearch(key: usize, base: usize, num: usize, width: usize, compare_ptr: usize) callconv(.c) usize {
    if (key == 0 or base == 0 or num == 0 or width == 0 or compare_ptr == 0) return 0;
    const compare = @as(*const fn (usize, usize) callconv(.c) i32, @ptrFromInt(compare_ptr));
    // Binary search (array must be pre-sorted)
    var lo: usize = 0;
    var hi: usize = num;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const item = base + mid * width;
        const cmp = compare(key, item);
        if (cmp == 0) return item;
        if (cmp < 0) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return 0;
}

pub fn stub_mktemp(template: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (template) |t| {
        const slice = @as([*]u8, @ptrCast(t));
        var i: usize = 0;
        // Replace tmp\ with tmp_ to drop files locally instead of requiring a tmp folder
        if (slice[0] == 't' and slice[1] == 'm' and slice[2] == 'p' and slice[3] == '\\') {
            slice[0] = 't';
            slice[1] = 'm';
            slice[2] = 'p';
            slice[3] = '_';
        }
        
        while (slice[i] != 0 and i < 4096) {
            if (slice[i] == 'X') slice[i] = '1';
            i += 1;
        }
        if (trace.enable_tracing) trace.print("MSVCRT: _mktemp -> '{s}'\n", .{slice[0..i]});
        return t;
    }
    return null;
}

pub fn stub_splitpath(path_ptr: usize, drive: usize, dir: usize, fname: usize, ext: usize) callconv(.c) void {
    if (path_ptr < 0x10000) return;
    const path = trace.c_span(path_ptr);
    
    var drive_len: usize = 0;
    if (path.len >= 2 and path[1] == ':') {
        drive_len = 2;
    }

    var de: usize = drive_len;
    var es: usize = path.len;
    for (drive_len..path.len) |i| {
        if (path[i] == '/' or path[i] == '\\') de = i + 1;
        if (path[i] == '.') es = i;
    }
    if (es < de) es = path.len;

    if (drive != 0) {
        if (drive_len > 0) {
            @memcpy(@as([*]u8, @ptrFromInt(drive))[0..drive_len], path[0..drive_len]);
        }
        @as([*]u8, @ptrFromInt(drive))[drive_len] = 0;
    }
    if (dir != 0) {
        const dir_len = de - drive_len;
        if (dir_len > 0) {
            @memcpy(@as([*]u8, @ptrFromInt(dir))[0..dir_len], path[drive_len..de]);
        }
        @as([*]u8, @ptrFromInt(dir))[dir_len] = 0;
    }
    if (fname != 0) {
        const fname_len = es - de;
        if (fname_len > 0) {
            @memcpy(@as([*]u8, @ptrFromInt(fname))[0..fname_len], path[de..es]);
        }
        @as([*]u8, @ptrFromInt(fname))[fname_len] = 0;
    }
    if (ext != 0) {
        const ext_len = path.len - es;
        if (ext_len > 0) {
            @memcpy(@as([*]u8, @ptrFromInt(ext))[0..ext_len], path[es..path.len]);
        }
        @as([*]u8, @ptrFromInt(ext))[ext_len] = 0;
    }
}

pub fn stub_makepath(path_ptr: usize, drive: usize, dir: usize, fname: usize, ext: usize) callconv(.c) void {
    if (path_ptr == 0) return;
    const path = @as([*]u8, @ptrFromInt(path_ptr));
    var len: usize = 0;
    if (drive != 0) {
        const s = trace.c_span(drive);
        if (s.len > 0) {
            @memcpy(path[len .. len + s.len], s);
            len += s.len;
            if (s[s.len - 1] != ':') {
                path[len] = ':';
                len += 1;
            }
        }
    }
    if (dir != 0) {
        const s = trace.c_span(dir);
        if (s.len > 0) {
            @memcpy(path[len .. len + s.len], s);
            len += s.len;
            if (s[s.len - 1] != '/' and s[s.len - 1] != '\\') {
                path[len] = '\\';
                len += 1;
            }
        }
    }
    if (fname != 0) {
        const s = trace.c_span(fname);
        @memcpy(path[len .. len + s.len], s);
        len += s.len;
    }
    if (ext != 0) {
        const s = trace.c_span(ext);
        if (s.len > 0) {
            if (s[0] != '.') {
                path[len] = '.';
                len += 1;
            }
            @memcpy(path[len .. len + s.len], s);
            len += s.len;
        }
    }
    path[len] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _makepath -> {s}\n", .{path[0..len]});
}

pub fn stub_fullpath(abs: usize, rel: usize, max: usize) callconv(.c) usize {
    if (rel == 0) return 0;
    const s = trace.c_span(rel);
    var dp = abs;
    if (dp == 0) {
        const alloc_size = if (max > 0) max else 4096;
        const p = std.heap.page_allocator.alloc(u8, alloc_size) catch return 0;
        dp = @intFromPtr(p.ptr);
    }
    const buf_size = if (max > 0) max else 4096;
    const cl = @min(s.len, buf_size - 1);
    @memcpy(@as([*]u8, @ptrFromInt(dp))[0..cl], s[0..cl]);
    @as([*]u8, @ptrFromInt(dp))[cl] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _fullpath(abs={x}, rel='{s}', max={d}) -> {x}\n", .{ abs, s, max, dp });
    return dp;
}

pub fn stub_errno() callconv(.c) *i32 {
    return &msvcrt.msvcrt_errno_val;
}

// --- Formatted I/O Helpers ---

pub fn alloc_fd() ?i32 {
    for (3..MAX_FDS) |i| if (fd_handles[i] == null) return @intCast(i);
    return null;
}

pub fn get_fd_file(fd: i32) ?std.fs.File {
    if (fd == 0) return std.fs.File{ .handle = 0 };
    if (fd == 1) return std.fs.File{ .handle = 1 };
    if (fd == 2) return std.fs.File{ .handle = 2 };
    return if (fd >= 3 and fd < MAX_FDS) fd_handles[@intCast(fd)] else null;
}

pub fn stub_access(path_ptr: usize, mode: i32) callconv(.c) i32 {
    if (path_ptr == 0) return -1;
    const path = trace.c_span(path_ptr);
    const posix_fs = @import("posix_fs.zig");
    const result = posix_fs.access(@as([*:0]const u8, @ptrFromInt(path_ptr)), mode);
    if (trace.enable_tracing) trace.print("MSVCRT: _access('{s}', {d}) -> {d}\n", .{ path, mode, result });
    return result;
}

pub fn stub_searchenv(filename_ptr: usize, varname_ptr: usize, result_ptr: usize) callconv(.c) void {
    const filename = if (filename_ptr != 0) trace.c_span(filename_ptr) else "";
    const varname = if (varname_ptr != 0) trace.c_span(varname_ptr) else "";
    
    if (trace.enable_tracing) trace.print("MSVCRT: _searchenv('{s}', '{s}')\n", .{ filename, varname });
    
    if (result_ptr == 0) return;
    const result_buf = @as([*]u8, @ptrFromInt(result_ptr));
    result_buf[0] = 0; // default to empty

    const env_val_ptr = process.stub_getenv(varname_ptr);
    if (env_val_ptr == null) return;
    const env_val = trace.c_span(@intFromPtr(env_val_ptr.?));

    var it = std.mem.splitScalar(u8, env_val, ';');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        
        var full_path: [1024]u8 = undefined;
        var full_len: usize = 0;
        @memcpy(full_path[full_len .. full_len + dir.len], dir);
        full_len += dir.len;
        if (full_path[full_len - 1] != '\\' and full_path[full_len - 1] != '/') {
            full_path[full_len] = '\\';
            full_len += 1;
        }
        @memcpy(full_path[full_len .. full_len + filename.len], filename);
        full_len += filename.len;
        full_path[full_len] = 0;
        
        // Use our _access stub to handle lowercase fallback and forward slashes
        if (stub_access(@intFromPtr(&full_path), 0) == 0) {
            @memcpy(result_buf[0..full_len], full_path[0..full_len]);
            result_buf[full_len] = 0;
            if (trace.enable_tracing) trace.print("  -> found at '{s}'\n", .{full_path[0..full_len]});
            return;
        }
    }
    if (trace.enable_tracing) trace.print("MSVCRT: _searchenv -> NOT FOUND\n", .{});
}

pub fn stub_getcwd(buffer_ptr: usize, maxlen: i32) callconv(.c) ?*anyopaque {
    const path = std.process.getCwdAlloc(std.heap.page_allocator) catch return null;
    defer std.heap.page_allocator.free(path);

    if (buffer_ptr != 0) {
        if (path.len >= maxlen) return null;
        const buf = @as([*]u8, @ptrFromInt(buffer_ptr));
        @memcpy(buf[0..path.len], path);
        std.mem.replaceScalar(u8, buf[0..path.len], '/', '\\');
        buf[path.len] = 0;
        return @ptrFromInt(buffer_ptr);
    } else {
        const ptr = std.heap.page_allocator.alloc(u8, path.len + 1) catch return null;
        @memcpy(ptr[0..path.len], path);
        std.mem.replaceScalar(u8, ptr[0..path.len], '/', '\\');
        ptr[path.len] = 0;
        return ptr.ptr;
    }
}

pub fn stub_sopen(path_ptr: usize, oflag: i32, shflag: i32, pmode: i32) callconv(.c) i32 {
    _ = shflag;
    _ = pmode;
    if (path_ptr == 0) return -1;
    const path = trace.c_span(path_ptr);

    if (trace.enable_tracing) trace.print("MSVCRT: _sopen('{s}', {x})\n", .{ path, oflag });

    // Translate Windows oflags to POSIX flags
    const O_WRONLY = 0x0001;
    const O_RDWR = 0x0002;
    const O_APPEND = 0x0008;
    const O_CREAT = 0x0100;
    const O_TRUNC = 0x0200;

    var flags: u32 = 0;
    if ((oflag & O_CREAT) != 0) flags |= 64; // POSIX O_CREAT
    if ((oflag & O_RDWR) != 0) {
        flags |= 2; // POSIX O_RDWR
    } else if ((oflag & O_WRONLY) != 0) {
        flags |= 1; // POSIX O_WRONLY
    }
    if ((oflag & O_TRUNC) != 0) flags |= 512; // POSIX O_TRUNC
    if ((oflag & O_APPEND) != 0) flags |= 1024; // POSIX O_APPEND

    // posix_fs.open handles all path resolution via path_utils.toHostPath
    const posix_fs = @import("posix_fs.zig");
    const rc = posix_fs.open(@as([*:0]const u8, @ptrCast(@constCast(path.ptr))), flags, 0o666);
    if (rc < 0) {
        if (trace.enable_tracing) trace.print("  -> failed\n", .{});
        return -1;
    }
    if (trace.enable_tracing) trace.print("  -> fd {d}\n", .{rc});
    return rc;
}

pub fn stub_read(fd: i32, buffer_ptr: usize, count: u32) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _read(fd={d}, count={d})\n", .{fd, count});
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

pub fn stub_write(fd: i32, buffer_ptr: usize, count: u32) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _write(fd={d}, count={d})\n", .{fd, count});
    if (buffer_ptr == 0 or count == 0) return 0;
    const slice = @as([*]const u8, @ptrFromInt(buffer_ptr))[0..count];
    const out_file = std.fs.File{ .handle = fd };
    out_file.writeAll(slice) catch |err| {
        if (trace.enable_tracing) trace.print("  -> _write failed: {}\n", .{err});
        return -1;
    };
    return @intCast(count);
}

pub fn stub_lseek(fd: i32, offset: i32, origin: i32) callconv(.c) i32 {
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

pub fn stub_close(fd: i32) callconv(.c) i32 {
    if (fd >= 3) {
        const file = std.fs.File{ .handle = fd };
        file.close();
        return 0;
    }
    return -1;
}

pub fn stub_fileno(file_ptr: usize) callconv(.c) i32 {
    if (file_ptr != 0) {
        const ms_file = @as(*io.FILE, @ptrFromInt(file_ptr));
        return ms_file._file;
    }
    return -1;
}

pub fn stub_isatty(fd: i32) callconv(.c) i32 {
    if (fd == 0 or fd == 1 or fd == 2) return 1;
    return 0;
}
pub fn stub_initterm(pfbegin: usize, pfend: usize) callconv(.c) void {
    if (trace.enable_tracing) trace.print("MSVCRT: _initterm({x}, {x})\n", .{ pfbegin, pfend });
    if (pfbegin == 0 or pfend == 0 or pfbegin > pfend) return;

    var current = pfbegin;
    while (current < pfend) : (current += 4) {
        const func_ptr = @as(*usize, @ptrFromInt(current)).*;
        if (func_ptr != 0) {
            if (trace.enable_tracing) trace.print("  -> calling init func at {x}\n", .{func_ptr});
            const InitFunc = *const fn () callconv(.c) void;
            const init_func = @as(InitFunc, @ptrFromInt(func_ptr));
            init_func();
        }
    }
}
pub fn stub_tell(fd: i32) callconv(.c) i32 {
    const file = std.fs.File{ .handle = fd };
    return @intCast(file.getPos() catch return -1);
}

pub fn stub_chsize(fd: i32, size: i32) callconv(.c) i32 {
    const file = std.fs.File{ .handle = fd };
    file.setEndPos(@intCast(size)) catch return -1;
    return 0;
}

pub fn stub_filelength(fd: i32) callconv(.c) i32 {
    const file = std.fs.File{ .handle = fd };
    if (file.getEndPos()) |pos| {
        if (trace.enable_tracing) trace.print("MSVCRT: _filelength(fd={d}) -> {d}\n", .{fd, pos});
        return @intCast(pos);
    } else |_| {
        if (trace.enable_tracing) trace.print("MSVCRT: _filelength(fd={d}) -> failed\n", .{fd});
        return -1;
    }
}

pub fn stub_stat(path_ptr: usize, stat_ptr: usize) callconv(.c) i32 {
    if (path_ptr < 0x10000 or stat_ptr == 0) return -1;
    const path = std.mem.span(@as([*:0]const u8, @ptrFromInt(path_ptr)));

    // posix_fs.stat handles all path resolution via path_utils.toHostPath
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
pub fn stub_fstat(fd: i32, stat_ptr: usize) callconv(.c) i32 {
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
            
            if (trace.enable_tracing) trace.print("MSVCRT: _fstat(fd={d}) -> size {d}\n", .{fd, st.size});
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

pub fn stub_get_osfhandle(fd: i32) callconv(.c) isize {
    return @as(isize, @intCast(fd));
}

pub fn stub_open_osfhandle(osfhandle: isize, flags: i32) callconv(.c) i32 {
    _ = flags;
    return @intCast(osfhandle);
}

// --- Char Type & Locale ---

pub fn x86_vsnprintf(buf: [*]u8, max: usize, format: [*:0]const u8, args_ptr: usize) usize {
    if (max == 0) return 0;
    const args = @as([*]const usize, @ptrFromInt(args_ptr));
    var ai: usize = 0;
    var oi: usize = 0;
    var ii: usize = 0;
    while (format[ii] != 0 and oi < max - 1) : (ii += 1) {
        if (format[ii] == '%') {
            ii += 1;
            if (format[ii] == 0) break;
            
            var pad_char: u8 = ' ';
            if (format[ii] == '0') {
                pad_char = '0';
                ii += 1;
            }
            var width: usize = 0;
            while (format[ii] >= '0' and format[ii] <= '9') {
                width = width * 10 + (format[ii] - '0');
                ii += 1;
            }
            if (format[ii] == 'w' or format[ii] == 'l') ii += 1;
            const c = format[ii];
            if (c == 's') {
                if (args[ai] >= 0x10000) {
                    const s = @as([*:0]const u8, @ptrFromInt(args[ai]));
                    const len = std.mem.indexOfScalar(u8, s[0..4096], 0) orelse 0;
                    
                    while (len < width and oi < max - 1) : (width -= 1) {
                        buf[oi] = pad_char;
                        oi += 1;
                    }

                    var si: usize = 0;
                    while (s[si] != 0 and oi < max - 1) {
                        buf[oi] = s[si];
                        oi += 1;
                        si += 1;
                    }
                }
                ai += 1;
            } else if (c == 'd' or c == 'i') {
                const v = @as(i32, @bitCast(@as(u32, @truncate(args[ai]))));
                ai += 1;
                var nb: [32]u8 = undefined;
                const ns = std.fmt.bufPrint(&nb, "{d}", .{v}) catch "";
                
                const len = ns.len;
                while (len < width and oi < max - 1) : (width -= 1) {
                    buf[oi] = pad_char;
                    oi += 1;
                }

                const copy_len = @min(ns.len, max - 1 - oi);
                @memcpy(buf[oi .. oi + copy_len], ns[0..copy_len]);
                oi += copy_len;
            } else if (c == 'x' or c == 'X') {
                const v = args[ai];
                ai += 1;
                var nb: [32]u8 = undefined;
                var ns: []u8 = "";
                if (c == 'x') {
                    ns = std.fmt.bufPrint(&nb, "{x}", .{v}) catch "";
                } else {
                    ns = std.fmt.bufPrint(&nb, "{X}", .{v}) catch "";
                }
                
                const len = ns.len;
                while (len < width and oi < max - 1) : (width -= 1) {
                    buf[oi] = pad_char;
                    oi += 1;
                }

                const copy_len = @min(ns.len, max - 1 - oi);
                @memcpy(buf[oi .. oi + copy_len], ns[0..copy_len]);
                oi += copy_len;
            } else if (c == 'u') {
                const v = @as(u32, @truncate(args[ai]));
                ai += 1;
                var nb: [32]u8 = undefined;
                const ns = std.fmt.bufPrint(&nb, "{d}", .{v}) catch "";
                
                const len = ns.len;
                while (len < width and oi < max - 1) : (width -= 1) {
                    buf[oi] = pad_char;
                    oi += 1;
                }

                const copy_len = @min(ns.len, max - 1 - oi);
                @memcpy(buf[oi .. oi + copy_len], ns[0..copy_len]);
                oi += copy_len;
            } else if (c == 'c') {
                if (oi < max - 1) {
                    buf[oi] = @as(u8, @truncate(args[ai]));
                    oi += 1;
                }
                ai += 1;
            } else if (c == '%') {
                if (oi < max - 1) {
                    buf[oi] = '%';
                    oi += 1;
                }
            }
        } else {
            buf[oi] = format[ii];
            oi += 1;
        }
    }
    buf[oi] = 0;
    return oi;
}

pub fn stub_printf(fmt_ptr: usize, a1: usize, a2: usize, a3: usize, a4: usize) callconv(.c) i32 {
    if (fmt_ptr == 0) return 0;
    const fmt = @as([*:0]const u8, @ptrFromInt(fmt_ptr));
    var args = [_]usize{ a1, a2, a3, a4 };
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, @intFromPtr(&args));
    if (trace.enable_tracing) trace.print("MSVCRT: printf '{s}'\n", .{buf[0..len]});
    const out_file = std.fs.File{ .handle = 1 }; // stdout
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

pub fn stub_vprintf(fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    if (fmt_ptr == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, @ptrFromInt(fmt_ptr), ap);
    if (trace.enable_tracing) trace.print("MSVCRT: vprintf '{s}'\n", .{buf[0..len]});
    const out_file = std.fs.File{ .handle = 1 }; // stdout
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

pub fn stub_vfprintf(stream: usize, fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    if (fmt_ptr == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, @ptrFromInt(fmt_ptr), ap);
    if (trace.enable_tracing) trace.print("MSVCRT: vfprintf '{s}'\n", .{buf[0..len]});

    const out_file = if (stream != 0) io.getFile(@ptrFromInt(stream)) orelse std.fs.File{ .handle = 1 } else std.fs.File{ .handle = 1 };
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

pub fn stub_vsnprintf(buf_ptr: usize, max: usize, fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    if (buf_ptr == 0 or max == 0 or fmt_ptr == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, @ptrFromInt(fmt_ptr), ap);
    if (trace.enable_tracing) trace.print("MSVCRT: _vsnprintf '{s}'\n", .{buf[0..len]});
    const copy_len = @min(len, max - 1);
    const out_buf = @as([*]u8, @ptrFromInt(buf_ptr));
    @memcpy(out_buf[0..copy_len], buf[0..copy_len]);
    out_buf[copy_len] = 0;
    return @intCast(copy_len);
}

pub fn stub_snprintf(buf_ptr: usize, max: usize, fmt_ptr: usize, a1: usize, a2: usize, a3: usize) callconv(.c) i32 {
    if (buf_ptr == 0 or max == 0 or fmt_ptr == 0) return 0;
    var args = [_]usize{ a1, a2, a3 };
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, @ptrFromInt(fmt_ptr), @intFromPtr(&args));
    if (trace.enable_tracing) trace.print("MSVCRT: _snprintf '{s}'\n", .{buf[0..len]});
    const copy_len = @min(len, max - 1);
    const out_buf = @as([*]u8, @ptrFromInt(buf_ptr));
    @memcpy(out_buf[0..copy_len], buf[0..copy_len]);
    out_buf[copy_len] = 0;
    return @intCast(copy_len);
}
pub fn stub_swprintf(buf_ptr: usize, fmt_ptr: usize, a1: usize, a2: usize, a3: usize) callconv(.c) i32 {
    if (buf_ptr == 0 or fmt_ptr == 0) return 0;
    var args = [_]usize{ a1, a2, a3 };

    // Convert wide format string to narrow
    var fmt_buf: [4096]u8 = undefined;
    const fmt_w_len = trace.c_span_w(fmt_ptr).len;
    const fmt_w = @as([*]const u16, @ptrFromInt(fmt_ptr));
    const copy_len = @min(fmt_w_len, 4095);
    for (0..copy_len) |i| {
        fmt_buf[i] = @intCast(fmt_w[i] & 0xFF);
    }
    fmt_buf[copy_len] = 0;
    const fmt_narrow = @as([*:0]const u8, @ptrCast(&fmt_buf));

    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt_narrow, @intFromPtr(&args));
    if (trace.enable_tracing) trace.print("MSVCRT: swprintf '{s}' -> '{s}'\n", .{fmt_narrow, buf[0..len]});

    // Convert output back to wide
    const out_buf = @as([*]u16, @ptrFromInt(buf_ptr));
    for (0..len) |i| {
        out_buf[i] = buf[i];
    }
    out_buf[len] = 0;
    return @intCast(len);
}
pub fn stub_sprintf(buf_ptr: usize, fmt_ptr: usize, a1: usize, a2: usize, a3: usize) callconv(.c) i32 {
    if (buf_ptr == 0 or fmt_ptr == 0) return 0;
    var args = [_]usize{ a1, a2, a3 };
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, @ptrFromInt(fmt_ptr), @intFromPtr(&args));
    if (trace.enable_tracing) trace.print("MSVCRT: sprintf '{s}'\n", .{buf[0..len]});
    const out_buf = @as([*]u8, @ptrFromInt(buf_ptr));
    @memcpy(out_buf[0..len], buf[0..len]);
    out_buf[len] = 0;
    return @intCast(len);
}

pub fn stub_puts(str_ptr: usize) callconv(.c) i32 {
    if (str_ptr >= 0x10000) {
        const s = std.mem.span(@as([*:0]const u8, @ptrFromInt(str_ptr)));
        const f = std.fs.File{ .handle = 1 };
        _ = f.writeAll(s) catch {};
        _ = f.writeAll("\n") catch {};
        return 0;
    }
    return -1;
}

pub fn stub_fputs(str_ptr: usize, file_ptr: usize) callconv(.c) i32 {
    if (str_ptr >= 0x10000) {
        const s = std.mem.span(@as([*:0]const u8, @ptrFromInt(str_ptr)));
        if (trace.enable_tracing) trace.print("MSVCRT: fputs '{s}'\n", .{s});
        if (io.getFile(@ptrFromInt(file_ptr))) |file| {
            file.writeAll(s) catch return -1;
            return 0;
        }
        return -1;
    }
    return -1;
}

pub fn stub_sscanf(buf_ptr: usize, fmt_ptr: usize, a1: usize, a2: usize) callconv(.c) i32 {
    _ = a2;
    if (buf_ptr < 0x10000 or fmt_ptr < 0x10000) return 0;
    const buf = std.mem.span(@as([*:0]const u8, @ptrFromInt(buf_ptr)));
    const fmt = std.mem.span(@as([*:0]const u8, @ptrFromInt(fmt_ptr)));
    if (trace.enable_tracing) trace.print("MSVCRT: sscanf('{s}', '{s}')\n", .{buf, fmt});

    // Super hacky sscanf for single %d/%i/%x
    if (std.mem.eql(u8, fmt, "%d") or std.mem.eql(u8, fmt, "%i") or std.mem.eql(u8, fmt, "%ld")) {
        // use strtol
        if (a1 != 0) {
            const val = string.stub_strtol(buf_ptr, 0, 10);
            @as(*i32, @ptrFromInt(a1)).* = val;
            return 1; // 1 item matched
        }
    } else if (std.mem.eql(u8, fmt, "%x") or std.mem.eql(u8, fmt, "%X")) {
        if (a1 != 0) {
            const val = string.stub_strtoul(buf_ptr, 0, 16);
            @as(*u32, @ptrFromInt(a1)).* = val;
            return 1;
        }
    } else {
        if (trace.enable_tracing) trace.print("  -> unhandled format!\n", .{});
    }

    return 0;
}

var tempnam_counter: u32 = 0;

pub fn stub_tempnam(dir_ptr: usize, prefix_ptr: usize) callconv(.c) usize {
    const prefix = if (prefix_ptr != 0) trace.c_span(prefix_ptr) else "tmp";
    _ = dir_ptr;

    const count = @atomicRmw(u32, &tempnam_counter, .Add, 1, .monotonic);

    var name_buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}_{d}.tmp\x00", .{ prefix, count }) catch "winloader_tmp.tmp\x00";

    const alloc_ptr = std.heap.page_allocator.alloc(u8, name.len) catch return 0;
    @memcpy(alloc_ptr[0..name.len], name[0..name.len]);
    if (trace.enable_tracing) trace.print("MSVCRT: _tempnam -> '{s}'\n", .{alloc_ptr[0 .. name.len - 1]});

    if (std.fs.cwd().createFile(alloc_ptr[0 .. name.len - 1], .{})) |file| {
        file.close();
    } else |_| {}

    return @intFromPtr(alloc_ptr.ptr);
}

// --- SEH Exception Handlers ---

const teb = @import("../../teb.zig");

/// MSVC _except_handler3: walks the scope table to find an __except filter
/// that handles the exception. If a filter returns EXCEPTION_EXECUTE_HANDLER (1),
/// we unwind and jump to the handler. If EXCEPTION_CONTINUE_EXECUTION (-1),
/// we resume. Otherwise we continue searching.
///
/// Registration record layout (at establisher_frame):
///   +0:  Next SEH handler
///   +4:  Handler function pointer (_except_handler3)
///   +8:  ScopeTable pointer
///   +12: TryLevel
///
/// Frame EBP = establisher_frame + 16
///
/// ScopeTable entries (12 bytes each):
///   +0: EnclosingLevel (i32, -1 = none)
///   +4: FilterFunc pointer (0 = __finally, not __except)
///   +8: HandlerFunc pointer
pub fn stub_except_handler3(
    exception_record_ptr: usize,
    establisher_frame: usize,
    context_record_ptr: usize,
    dispatcher_context: usize,
) callconv(.c) u32 {
    _ = dispatcher_context;

    // Read TryLevel and ScopeTable from the registration record
    const try_level_ptr = @as(*align(1) i32, @ptrFromInt(establisher_frame + 12));
    const scope_table_addr = @as(*align(1) usize, @ptrFromInt(establisher_frame + 8)).*;

    var try_level = try_level_ptr.*;
    const frame_ebp = establisher_frame + 16;

    if (trace.enable_tracing) {
        trace.print("SEH _except_handler3: frame=0x{X} try_level={d} scope_table=0x{X} ebp=0x{X}\n", .{ establisher_frame, try_level, scope_table_addr, frame_ebp });
    }

    // Validate scope_table_addr
    if (scope_table_addr < 0x10000 or try_level < 0) {
        if (trace.enable_tracing) trace.print("SEH _except_handler3: invalid scope table or try_level, returning ContinueSearch\n", .{});
        return 1; // ExceptionContinueSearch
    }

    // Set up EXCEPTION_POINTERS at [frame_ebp - 0x14]
    // This is where GetExceptionInformation() reads from in __except filters
    if (frame_ebp >= 0x14) {
        const excptrs_slot = @as(*align(1) [2]usize, @ptrFromInt(frame_ebp -% 0x14));
        excptrs_slot.*[0] = exception_record_ptr;
        excptrs_slot.*[1] = context_record_ptr;
    }

    while (try_level >= 0) {
        const entry_base = scope_table_addr + @as(usize, @intCast(try_level)) * 12;

        // Read scope table entry
        const enclosing_level = @as(*align(1) i32, @ptrFromInt(entry_base)).*;
        const filter_func_addr = @as(*align(1) usize, @ptrFromInt(entry_base + 4)).*;
        const handler_func_addr = @as(*align(1) usize, @ptrFromInt(entry_base + 8)).*;

        if (trace.enable_tracing) {
            trace.print("SEH _except_handler3: level={d} enclosing={d} filter=0x{X} handler=0x{X}\n", .{ try_level, enclosing_level, filter_func_addr, handler_func_addr });
        }

        if (filter_func_addr != 0) {
            // Call the filter function with EBP set to the frame's EBP
            const filter_result = call_seh_filter(filter_func_addr, frame_ebp);

            if (trace.enable_tracing) {
                trace.print("SEH _except_handler3: filter returned {d}\n", .{filter_result});
            }

            if (filter_result == 1) { // EXCEPTION_EXECUTE_HANDLER
                // Update TryLevel to enclosing level (unwind)
                try_level_ptr.* = enclosing_level;
                // Jump to the __except handler block
                jump_to_seh_handler(handler_func_addr, frame_ebp);
                unreachable;
            } else if (filter_result == -1) { // EXCEPTION_CONTINUE_EXECUTION
                return 0; // ExceptionContinueExecution
            }
            // filter_result == 0: EXCEPTION_CONTINUE_SEARCH, try enclosing level
        }

        try_level = enclosing_level;
    }

    return 1; // ExceptionContinueSearch
}

/// Call a SEH filter function with EBP set to the __try frame's EBP.
/// The filter may call GetExceptionInformation() which reads [EBP-0x14].
const call_seh_filter = if (platform.is_x86) call_seh_filter_x86 else call_seh_filter_x64;

fn call_seh_filter_x86(filter_addr: usize, frame_ebp: usize) i32 {
    return asm volatile (
        \\push %%ebp
        \\push %%ebx
        \\push %%esi
        \\push %%edi
        \\push %%ecx
        \\push %%edx
        \\mov %[ebp_val], %%ebp
        \\call *%[filter]
        \\pop %%edx
        \\pop %%ecx
        \\pop %%edi
        \\pop %%esi
        \\pop %%ebx
        \\pop %%ebp
        : [result] "={eax}" (-> i32),
        : [filter] "r" (filter_addr),
          [ebp_val] "r" (frame_ebp),
    );
}

fn call_seh_filter_x64(filter_addr: usize, frame_ebp: usize) i32 {
    _ = frame_ebp;
    const filter_fn = @as(*const fn () callconv(.c) i32, @ptrFromInt(filter_addr));
    return filter_fn();
}

/// Jump to a SEH handler (__except block), restoring EBP to the frame.
/// This never returns - execution continues in the handler.
const jump_to_seh_handler = if (platform.is_x86) jump_to_seh_handler_x86 else jump_to_seh_handler_x64;

fn jump_to_seh_handler_x86(handler_addr: usize, frame_ebp: usize) noreturn {
    asm volatile (
        \\mov %[ebp_val], %%ebp
        \\jmp *%[handler]
        :
        : [handler] "r" (handler_addr),
          [ebp_val] "r" (frame_ebp),
    );
    unreachable;
}

fn jump_to_seh_handler_x64(handler_addr: usize, frame_ebp: usize) noreturn {
    _ = frame_ebp;
    const handler_fn = @as(*const fn () callconv(.c) noreturn, @ptrFromInt(handler_addr));
    handler_fn();
}

var setlocale_buf: [2]u8 = .{ 'C', 0 };

pub fn stub_setlocale(category: i32, locale_ptr: usize) callconv(.c) usize {
    if (trace.enable_tracing) {
        if (locale_ptr >= 0x10000) {
            const loc = trace.c_span(locale_ptr);
            trace.print("MSVCRT: setlocale({d}, '{s}')\n", .{ category, loc });
        } else {
            trace.print("MSVCRT: setlocale({d}, NULL)\n", .{category});
        }
    }
    return @intFromPtr(&setlocale_buf);
}

pub fn stub_strupr(str_ptr: usize) callconv(.c) usize {
    if (str_ptr < 0x10000) return 0;
    const s = @as([*]u8, @ptrFromInt(str_ptr));
    var i: usize = 0;
    while (s[i] != 0 and i < 0x100000) : (i += 1) {
        if (s[i] >= 'a' and s[i] <= 'z') s[i] -= 32;
    }
    return str_ptr;
}

// --- Registration ---
