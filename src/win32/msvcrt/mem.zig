const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const io = @import("io.zig");

const stub_common = @import("../shared.zig");

/// malloc
/// Implementation status: Partially implemented
pub fn malloc(size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) return null;
    if (size > 0x0FFFFFFF) {
        if (trace.enable_tracing) trace.print("MSVCRT: malloc({x}) -> failed (too large) from {x}\n", .{ size, @returnAddress() });
        return null;
    }
    const ptr = stub_common.raw_alloc(size) orelse {
        if (trace.enable_tracing) trace.print("MSVCRT: malloc({x}) -> failed (out of memory) from {x}\n", .{ size, @returnAddress() });
        return null;
    };
    if (trace.enable_tracing) trace.print("MSVCRT: malloc({x}) -> {x} from {x}\n", .{ size, @intFromPtr(ptr), @returnAddress() });
    return ptr;
}

/// calloc
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

/// stub_free
/// Implementation status: Stub
pub fn stub_free(ptr: ?*anyopaque) callconv(.c) void {
    _ = ptr;
    // Bump allocator doesn't support individual frees.
    // Memory is reclaimed when the process exits.
}

/// realloc
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

/// memcpy
pub fn memcpy(dest: [*]u8, src: [*]const u8, count: usize) callconv(.c) [*]u8 {
    if (count > 0) @memcpy(dest[0..count], src[0..count]);
    return dest;
}

/// memmove
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
