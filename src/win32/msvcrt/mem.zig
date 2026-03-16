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
/// Implementation status: Partially implemented
pub fn memset(dest_ptr: usize, c: i32, count: usize) callconv(.c) usize {
    if (dest_ptr != 0 and count > 0) @memset(@as([*]u8, @ptrFromInt(trace.addr(dest_ptr)))[0..count], @as(u8, @intCast(c & 0xFF)));
    return dest_ptr;
}

/// memcpy
/// Implementation status: Partially implemented
pub fn memcpy(dest_ptr: usize, src_ptr: usize, count: usize) callconv(.c) usize {
    if (dest_ptr != 0 and src_ptr != 0 and count > 0) @memcpy(@as([*]u8, @ptrFromInt(trace.addr(dest_ptr)))[0..count], @as([*]const u8, @ptrFromInt(trace.addr(src_ptr)))[0..count]);
    return dest_ptr;
}

/// memmove
/// Implementation status: Partially implemented
pub fn memmove(dest_ptr: usize, src_ptr: usize, count: usize) callconv(.c) usize {
    if (dest_ptr == 0 or src_ptr == 0 or count == 0) return dest_ptr;
    const dest = @as([*]u8, @ptrFromInt(trace.addr(dest_ptr)))[0..count];
    const src = @as([*]const u8, @ptrFromInt(trace.addr(src_ptr)))[0..count];
    if (dest_ptr < src_ptr) {
        std.mem.copyForwards(u8, dest, src);
    } else if (dest_ptr > src_ptr) {
        std.mem.copyBackwards(u8, dest, src);
    }
    return dest_ptr;
}
