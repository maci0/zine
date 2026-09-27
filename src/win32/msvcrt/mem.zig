const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const io = @import("io.zig");

const stub_common = @import("../shared.zig");

/// Implementation status: Partially implemented
pub fn malloc(size: usize) callconv(.c) ?*anyopaque {
    const alloc_size = if (size == 0) 1 else size;
    if (alloc_size > 0x0FFFFFFF) {
        if (trace.enable_tracing) trace.print("MSVCRT: malloc({x}) -> failed (too large) from {x}\n", .{ alloc_size, @returnAddress() });
        return null;
    }
    const ptr = stub_common.raw_alloc(alloc_size) orelse {
        if (trace.enable_tracing) trace.print("MSVCRT: malloc({x}) -> failed (out of memory) from {x}\n", .{ alloc_size, @returnAddress() });
        return null;
    };
    if (trace.enable_tracing) trace.print("MSVCRT: malloc({x}) -> {x} from {x}\n", .{ size, @intFromPtr(ptr), @returnAddress() });
    return ptr;
}

/// Implementation status: Partially implemented
pub fn calloc(num: usize, size: usize) callconv(.c) ?*anyopaque {
    if (@mulWithOverflow(num, size)[1] != 0) return null;
    const total = num * size;
    if (total == 0 or total > 0x0FFFFFFF) return null;
    const ptr = stub_common.raw_alloc(total) orelse return null;
    // raw_alloc zero-initializes on guest (via guestAlloc) and native (heapAlloc memsets)
    if (trace.enable_tracing) trace.print("MSVCRT: calloc({d}, {d}) -> {x}\n", .{ num, size, @intFromPtr(ptr) });
    return ptr;
}

/// Implementation status: Stub
pub fn stub_free(ptr: ?*anyopaque) callconv(.c) void {
    _ = ptr;
    // Bump allocator doesn't support individual frees.
    // Memory is reclaimed when the process exits.
}

/// Implementation status: Partially implemented
pub fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (trace.enable_tracing) trace.print("MSVCRT: realloc({x}, {x})\n", .{ @intFromPtr(ptr), size });
    if (size == 0) {
        stub_free(ptr);
        return null;
    }
    return stub_common.raw_realloc(ptr, size);
}

/// --- ANSI String & Memory ---
pub fn memset(dest: [*]u8, c: i32, count: usize) callconv(.c) [*]u8 {
    if (count > 0) @memset(dest[0..count], @as(u8, @intCast(c & 0xFF)));
    return dest;
}

pub fn memcpy(dest: [*]u8, src: [*]const u8, count: usize) callconv(.c) [*]u8 {
    if (count > 0) @memcpy(dest[0..count], src[0..count]);
    return dest;
}

pub fn memmove(dest: [*]u8, src: [*]const u8, count: usize) callconv(.c) [*]u8 {
    if (count == 0) return dest;
    const d = dest[0..count];
    const s = src[0..count];
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        std.mem.copyForwards(u8, d, s);
    } else if (@intFromPtr(dest) > @intFromPtr(src)) {
        std.mem.copyBackwards(u8, d, s);
    }
    return dest;
}

/// memcmp — byte-wise comparison, no NUL termination semantics
pub fn memcmp(s1: [*]const u8, s2: [*]const u8, count: usize) callconv(.c) i32 {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (s1[i] != s2[i]) return @as(i32, s1[i]) - @as(i32, s2[i]);
    }
    return 0;
}

/// _memicmp — case-insensitive memcmp
pub fn memicmp(s1: [*]const u8, s2: [*]const u8, count: usize) callconv(.c) i32 {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const c1 = std.ascii.toLower(s1[i]);
        const c2 = std.ascii.toLower(s2[i]);
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    return 0;
}
