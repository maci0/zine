/// Miscellaneous MSVCRT stubs: rand/srand, qsort, bsearch, errno,
/// setlocale, _strupr, abs, and generic no-op/ignore stubs.
const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");

pub fn log_call(comptime name: []const u8) void {
    if (trace.enable_tracing) trace.print("MSVCRT: {s}\n", .{name});
}

// --- rand / srand (MSVC LCG) ---
var rand_seed: u32 = 1;

pub fn srand(seed: u32) callconv(.c) void {
    rand_seed = seed;
    if (trace.enable_tracing) trace.print("MSVCRT: srand({d})\n", .{seed});
}

pub fn rand() callconv(.c) i32 {
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

// --- qsort / bsearch ---

pub fn qsort(base: usize, num: usize, width: usize, compare_ptr: usize) callconv(.c) void {
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
                    const a = @as(*u8, @ptrFromInt(trace.addr(ap + k)));
                    const b = @as(*u8, @ptrFromInt(trace.addr(bp + k)));
                    const t = a.*;
                    a.* = b.*;
                    b.* = t;
                }
            }
        }
    }
}

pub fn bsearch(key: usize, base: usize, num: usize, width: usize, compare_ptr: usize) callconv(.c) usize {
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

// --- errno ---

pub fn errno() callconv(.c) *i32 {
    return &msvcrt.msvcrt_errno_val;
}

// --- Locale ---

var setlocale_buf: [2]u8 = .{ 'C', 0 };

pub fn setlocale(category: i32, locale_ptr: usize) callconv(.c) usize {
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

pub fn strupr(str_ptr: usize) callconv(.c) usize {
    if (str_ptr < 0x10000) return 0;
    const s = @as([*]u8, @ptrFromInt(trace.addr(str_ptr)));
    var i: usize = 0;
    while (s[i] != 0 and i < 0x100000) : (i += 1) {
        if (s[i] >= 'a' and s[i] <= 'z') s[i] -= 32;
    }
    return str_ptr;
}

// --- Simple stubs ---

pub fn abs(n: i32) callconv(.c) i32 {
    return if (n < 0) -n else n;
}

pub fn stub_noop0() callconv(.c) void {}
pub fn stub_noop1(_: usize) callconv(.c) void {}
pub fn stub_noop3(_: usize, _: usize, _: usize) callconv(.c) void {}
