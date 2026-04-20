const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");

/// Miscellaneous MSVCRT stubs: rand/srand, qsort, bsearch, errno,
/// setlocale, _strupr, abs, and generic no-op/ignore stubs.
/// Implementation status: Partially implemented
pub fn log_call(comptime name: []const u8) void {
    if (trace.enable_tracing) trace.print("MSVCRT: {s}\n", .{name});
}

var rand_seed: u32 = 1;

/// --- rand / srand (MSVC LCG) ---
/// Implementation status: Partially implemented
pub fn srand(seed: u32) callconv(.c) void {
    rand_seed = seed;
    if (trace.enable_tracing) trace.print("MSVCRT: srand({d})\n", .{seed});
}

/// rand
/// Implementation status: Partially implemented
pub fn rand() callconv(.c) i32 {
    rand_seed = rand_seed *% 214013 +% 2531011;
    const result = @as(i32, @intCast((rand_seed >> 16) & 0x7fff));
    if (trace.enable_tracing) trace.print("MSVCRT: rand() -> {d}\n", .{result});
    return result;
}

/// stub_ignore_i32
/// Implementation status: Stub
pub fn stub_ignore_i32() callconv(.c) i32 {
    if (trace.enable_tracing) {
        trace.print("MSVCRT: ignored call (i32) from 0x{X}\n", .{@returnAddress()});
    }
    return 0;
}

/// stub_ignore_ptr
/// Implementation status: No-op fallback
pub fn stub_ignore_ptr() callconv(.c) ?*anyopaque {
    const ra = @returnAddress();
    if (trace.enable_tracing) trace.print("MSVCRT: ignored call (ptr) from 0x{X}\n", .{ra});
    return null;
}

/// --- qsort / bsearch ---
/// Implementation status: Partially implemented
pub fn qsort(base: usize, num: usize, width: usize, compare_ptr: usize) callconv(.c) void {
    if (base == 0 or num == 0 or width == 0 or compare_ptr == 0) return;
    const compare = @as(*const fn (usize, usize) callconv(.c) i32, @ptrFromInt(compare_ptr));
    var i: usize = 0;
    while (i < num) : (i += 1) {
        var j: usize = i + 1;
        while (j < num) : (j += 1) {
            const ap = base + i * width;
            const bp = base + j * width;
            const cmp = if (comptime @import("../../platform.zig").is_x86_64)
                @as(i32, @bitCast(@import("../../x86/compat_thunks.zig").callCompat32_4(@truncate(compare_ptr), @truncate(ap), @truncate(bp), 0, 0)))
            else
                compare(ap, bp);
            if (cmp > 0) {
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

/// bsearch
/// Implementation status: Partially implemented
pub fn bsearch(key: usize, base: usize, num: usize, width: usize, compare_ptr: usize) callconv(.c) usize {
    if (key == 0 or base == 0 or num == 0 or width == 0 or compare_ptr == 0) return 0;
    const compare = @as(*const fn (usize, usize) callconv(.c) i32, @ptrFromInt(compare_ptr));
    var lo: usize = 0;
    var hi: usize = num;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const item = base + mid * width;
        const cmp = if (comptime @import("../../platform.zig").is_x86_64)
            @as(i32, @bitCast(@import("../../x86/compat_thunks.zig").callCompat32_4(@truncate(compare_ptr), @truncate(key), @truncate(item), 0, 0)))
        else
            compare(key, item);
        if (cmp == 0) return item;
        if (cmp < 0) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return 0;
}

/// --- errno ---
/// Returns a pointer to the errno value. On WASM, returns a guest VA
/// so the x86 interpreter can dereference it.
pub fn errno() callconv(.c) *i32 {
    // On WASM, use guest globals slot so x86 code can dereference
    const process = @import("process.zig");
    const g = process.ensureGuestGlobals();
    if (g != 0) {
        const shared = @import("../shared.zig");
        if (shared.guest_memory) |gmem| {
            // Sync host errno into guest slot
            const off = g + process.g_errno - gmem.base_addr;
            @as(*align(1) i32, @ptrCast(gmem.base[off..][0..4].ptr)).* = msvcrt.msvcrt_errno_val;
            return @ptrCast(@alignCast(gmem.base[off..][0..4].ptr));
        }
    }
    return &msvcrt.msvcrt_errno_val;
}

var setlocale_buf: [2]u8 = .{ 'C', 0 };

/// --- Locale ---
/// Returns a pointer to the locale string. On WASM, returns a guest VA.
pub fn setlocale(category: i32, locale: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (trace.enable_tracing) {
        if (locale) |loc| {
            trace.print("MSVCRT: setlocale({d}, '{s}')\n", .{ category, std.mem.span(loc) });
        } else {
            trace.print("MSVCRT: setlocale({d}, NULL)\n", .{category});
        }
    }
    // On WASM, return from guest globals slot
    const process = @import("process.zig");
    const g = process.ensureGuestGlobals();
    if (g != 0) {
        const shared = @import("../shared.zig");
        if (shared.guest_memory) |gmem| {
            const off = g + process.g_setlocale - gmem.base_addr;
            return @ptrCast(gmem.base[off..].ptr);
        }
    }
    return @ptrCast(&setlocale_buf);
}

/// strupr
/// Implementation status: Partially implemented
pub fn strupr(s: [*]u8) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (s[i] != 0 and i < 0x100000) : (i += 1) {
        if (s[i] >= 'a' and s[i] <= 'z') s[i] -= 32;
    }
    return s;
}

/// --- Simple stubs ---
/// Implementation status: Partially implemented
pub fn abs(n: i32) callconv(.c) i32 {
    return if (n < 0) -n else n;
}

/// stub_noop0
/// Implementation status: Stub
pub fn stub_noop0() callconv(.c) void {}
/// stub_noop1
/// Implementation status: Stub
pub fn stub_noop1(_: usize) callconv(.c) void {}
/// stub_noop3
/// Implementation status: Stub
pub fn stub_noop3(_: usize, _: usize, _: usize) callconv(.c) void {}
