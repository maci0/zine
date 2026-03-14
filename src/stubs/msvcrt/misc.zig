/// Miscellaneous MSVCRT stubs that don't fit neatly into a single
/// C library header category: rand/srand, qsort, bsearch, path utilities
/// (_splitpath/_makepath/_fullpath), _searchenv, _getcwd, _errno,
/// _tempnam, setlocale, setjmp/longjmp, SEH, and no-op stubs.
const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const io = @import("io.zig");

pub fn log_call(comptime name: []const u8) void {
    if (trace.enable_tracing) trace.print("MSVCRT: {s}\n", .{name});
}

// --- rand / srand (MSVC LCG) ---
var rand_seed: u32 = 1;

pub fn stub_srand(seed: u32) callconv(.c) void {
    rand_seed = seed;
    if (trace.enable_tracing) trace.print("MSVCRT: srand({d})\n", .{seed});
}

pub fn stub_rand() callconv(.c) i32 {
    rand_seed = rand_seed *% 214013 +% 2531011;
    const result = @as(i32, @intCast((rand_seed >> 16) & 0x7fff));
    if (trace.enable_tracing) trace.print("MSVCRT: rand() -> {d}\n", .{result});
    return result;
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

// --- setjmp / longjmp / EH_prolog ---

const platform = @import("../../platform.zig");

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
    const env = @as([*]u64, @ptrFromInt(env_ptr));
    env[0] = asm volatile ("movq %%rbp, %[out]" : [out] "=r" (-> u64));
    env[1] = asm volatile ("movq %%rbx, %[out]" : [out] "=r" (-> u64));
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
    _ = env_ptr;
    _ = value;
    if (trace.enable_tracing) trace.print("MSVCRT: WARNING: longjmp called on x86_64 (not fully implemented)\n", .{});
}

fn stub_longjmp_generic(_: usize, _: i32) callconv(.c) void {
    // On WASM, longjmp is handled by the interpreter
}

// --- qsort / bsearch ---

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

// --- Path utilities ---

pub fn stub_mktemp(template: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (template) |t| {
        const slice = @as([*]u8, @ptrCast(t));
        var i: usize = 0;
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
        const stub_common = @import("../stub_common.zig");
        const p = stub_common.raw_alloc(alloc_size) orelse return 0;
        dp = @intFromPtr(p);
    }
    const buf_size = if (max > 0) max else 4096;
    const cl = @min(s.len, buf_size - 1);
    @memcpy(@as([*]u8, @ptrFromInt(dp))[0..cl], s[0..cl]);
    @as([*]u8, @ptrFromInt(dp))[cl] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _fullpath(abs={x}, rel='{s}', max={d}) -> {x}\n", .{ abs, s, max, dp });
    return dp;
}

// --- errno ---

pub fn stub_errno() callconv(.c) *i32 {
    return &msvcrt.msvcrt_errno_val;
}

// --- _searchenv / _getcwd ---

pub fn stub_searchenv(filename_ptr: usize, varname_ptr: usize, result_ptr: usize) callconv(.c) void {
    const filename = if (filename_ptr != 0) trace.c_span(filename_ptr) else "";
    const varname = if (varname_ptr != 0) trace.c_span(varname_ptr) else "";

    if (trace.enable_tracing) trace.print("MSVCRT: _searchenv('{s}', '{s}')\n", .{ filename, varname });

    if (result_ptr == 0) return;
    const result_buf = @as([*]u8, @ptrFromInt(result_ptr));
    result_buf[0] = 0; // default to empty

    const env_val_ptr = @import("process.zig").stub_getenv(varname_ptr);
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

        const file_mod = @import("file.zig");
        if (file_mod.stub_access(@intFromPtr(&full_path), 0) == 0) {
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
        const stub_common = @import("../stub_common.zig");
        const raw = stub_common.raw_alloc(path.len + 1) orelse return null;
        const ptr = @as([*]u8, @ptrCast(raw));
        @memcpy(ptr[0..path.len], path);
        std.mem.replaceScalar(u8, ptr[0..path.len], '/', '\\');
        ptr[path.len] = 0;
        return raw;
    }
}

// --- tempnam ---

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
/// that handles the exception.
pub fn stub_except_handler3(
    exception_record_ptr: usize,
    establisher_frame: usize,
    context_record_ptr: usize,
    dispatcher_context: usize,
) callconv(.c) u32 {
    _ = dispatcher_context;

    const try_level_ptr = @as(*align(1) i32, @ptrFromInt(establisher_frame + 12));
    const scope_table_addr = @as(*align(1) usize, @ptrFromInt(establisher_frame + 8)).*;

    var try_level = try_level_ptr.*;
    const frame_ebp = establisher_frame + 16;

    if (trace.enable_tracing) {
        trace.print("SEH _except_handler3: frame=0x{X} try_level={d} scope_table=0x{X} ebp=0x{X}\n", .{ establisher_frame, try_level, scope_table_addr, frame_ebp });
    }

    if (scope_table_addr < 0x10000 or try_level < 0) {
        if (trace.enable_tracing) trace.print("SEH _except_handler3: invalid scope table or try_level, returning ContinueSearch\n", .{});
        return 1; // ExceptionContinueSearch
    }

    if (frame_ebp >= 0x14) {
        const excptrs_slot = @as(*align(1) [2]usize, @ptrFromInt(frame_ebp -% 0x14));
        excptrs_slot.*[0] = exception_record_ptr;
        excptrs_slot.*[1] = context_record_ptr;
    }

    while (try_level >= 0) {
        const entry_base = scope_table_addr + @as(usize, @intCast(try_level)) * 12;

        const enclosing_level = @as(*align(1) i32, @ptrFromInt(entry_base)).*;
        const filter_func_addr = @as(*align(1) usize, @ptrFromInt(entry_base + 4)).*;
        const handler_func_addr = @as(*align(1) usize, @ptrFromInt(entry_base + 8)).*;

        if (trace.enable_tracing) {
            trace.print("SEH _except_handler3: level={d} enclosing={d} filter=0x{X} handler=0x{X}\n", .{ try_level, enclosing_level, filter_func_addr, handler_func_addr });
        }

        if (filter_func_addr != 0) {
            const filter_result = call_seh_filter(filter_func_addr, frame_ebp);

            if (trace.enable_tracing) {
                trace.print("SEH _except_handler3: filter returned {d}\n", .{filter_result});
            }

            if (filter_result == 1) { // EXCEPTION_EXECUTE_HANDLER
                try_level_ptr.* = enclosing_level;
                jump_to_seh_handler(handler_func_addr, frame_ebp);
                unreachable;
            } else if (filter_result == -1) { // EXCEPTION_CONTINUE_EXECUTION
                return 0; // ExceptionContinueExecution
            }
        }

        try_level = enclosing_level;
    }

    return 1; // ExceptionContinueSearch
}

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

// --- Locale ---

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

// --- Simple stubs ---

pub fn stub_abs(n: i32) callconv(.c) i32 {
    return if (n < 0) -n else n;
}

pub fn stub_noop0() callconv(.c) void {}
pub fn stub_noop1(_: usize) callconv(.c) void {}
pub fn stub_noop3(_: usize, _: usize, _: usize) callconv(.c) void {}
