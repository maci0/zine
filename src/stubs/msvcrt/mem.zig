const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const io = @import("io.zig");

const string = @import("string.zig");
const process = @import("process.zig");
const mem = @import("mem.zig");
const math = @import("math.zig");
const misc = @import("misc.zig");

pub var fba_state: ?std.heap.FixedBufferAllocator = null;
pub var custom_allocator: ?std.mem.Allocator = null;

fn getAllocator() std.mem.Allocator {
    if (custom_allocator == null) {
        // Allocate a large chunk in the lower 2GB to avoid signed pointer issues in legacy 32-bit apps
        const heap_size = 256 * 1024 * 1024; // 256MB should be enough
        const platform = @import("../../platform.zig");
        const ptr = platform.mmap(
            @ptrFromInt(0x20000000), 
            heap_size, 
            false, 
            -1, 
            0,
            false,
            false
        ) catch @panic("Failed to mmap 32-bit heap");
        
        fba_state = std.heap.FixedBufferAllocator.init(ptr[0..heap_size]);
        custom_allocator = fba_state.?.allocator();
    }
    return custom_allocator.?;
}

pub fn stub_malloc(size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) return null;
    if (size > 0x0FFFFFFF) {
        if (trace.enable_tracing) trace.print("MSVCRT: malloc({x}) -> failed (too large) from {x}\n", .{size, @returnAddress()});
        return null;
    }
    const alloc = getAllocator();
    // We need an 8-byte header. Allocating u64 guarantees 8-byte alignment.
    const num_u64s = (size + 15) / 8;
    const ptr_u64 = alloc.alloc(u64, num_u64s) catch {
        if (trace.enable_tracing) trace.print("MSVCRT: malloc({x}) -> failed (allocator out of memory) from {x}\n", .{size, @returnAddress()});
        return null;
    };
    const ptr = std.mem.sliceAsBytes(ptr_u64);
    @memset(ptr, 0); // Windows programs often assume memory is 0-initialized
    const header = @as(*usize, @ptrCast(@alignCast(ptr.ptr)));
    header.* = size;
    const ret_ptr = @as([*]u8, @ptrCast(ptr.ptr)) + 8;
    if (trace.enable_tracing) trace.print("MSVCRT: malloc({x}) -> {x} from {x}\n", .{ size, @intFromPtr(ret_ptr), @returnAddress() });
    return @ptrCast(ret_ptr);
}

pub fn stub_calloc(num: usize, size: usize) callconv(.c) ?*anyopaque {
    var total: usize = 0;
    if (@mulWithOverflow(num, size)[1] != 0) return null;
    total = num * size;
    if (total == 0 or total > 0x0FFFFFFF) return null;
    const alloc = getAllocator();
    const num_u64s = (total + 15) / 8;
    const ptr_u64 = alloc.alloc(u64, num_u64s) catch return null;
    const ptr = std.mem.sliceAsBytes(ptr_u64);
    @memset(ptr, 0);
    const header = @as(*usize, @ptrCast(@alignCast(ptr.ptr)));
    header.* = total;
    const ret_ptr = @as([*]u8, @ptrCast(ptr.ptr)) + 8;
    if (trace.enable_tracing) trace.print("MSVCRT: calloc({d}, {d}) -> {x}\n", .{ num, size, @intFromPtr(ret_ptr) });
    return @ptrCast(ret_ptr);
}

pub fn stub_free(ptr: ?*anyopaque) callconv(.c) void {
    _ = ptr;
    // We intentionally leak memory since this is a short-lived process,
    // and FixedBufferAllocator doesn't do much with free anyway.
}

pub fn stub_realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (trace.enable_tracing) trace.print("MSVCRT: realloc({x}, {x})\n", .{ @intFromPtr(ptr), size });
    if (size == 0) {
        mem.stub_free(ptr);
        return null;
    }
    if (ptr == null) return mem.stub_malloc(size);
    // Simple leak-based realloc
    const new_ptr = mem.stub_malloc(size);
    if (new_ptr != null) {
        const start_ptr = @as([*]u8, @ptrCast(ptr.?)) - 8;
        const old_size = @as(*usize, @ptrCast(@alignCast(start_ptr))).*;
        const copy_size = @min(old_size, size);
        @memcpy(@as([*]u8, @ptrCast(new_ptr.?))[0..copy_size], @as([*]u8, @ptrCast(ptr.?))[0..copy_size]);
        mem.stub_free(ptr);
    }
    return new_ptr;
}

// --- ANSI String & Memory ---

pub fn stub_memset(dest_ptr: usize, c: i32, count: usize) callconv(.c) usize {
    if (dest_ptr != 0 and count > 0) @memset(@as([*]u8, @ptrFromInt(dest_ptr))[0..count], @as(u8, @intCast(c & 0xFF)));
    return dest_ptr;
}

pub fn stub_memcpy(dest_ptr: usize, src_ptr: usize, count: usize) callconv(.c) usize {
    if (dest_ptr != 0 and src_ptr != 0 and count > 0) @memcpy(@as([*]u8, @ptrFromInt(dest_ptr))[0..count], @as([*]const u8, @ptrFromInt(src_ptr))[0..count]);
    return dest_ptr;
}

pub fn stub_memmove(dest_ptr: usize, src_ptr: usize, count: usize) callconv(.c) usize {
    if (dest_ptr == 0 or src_ptr == 0 or count == 0) return dest_ptr;
    const dest = @as([*]u8, @ptrFromInt(dest_ptr))[0..count];
    const src = @as([*]const u8, @ptrFromInt(src_ptr))[0..count];
    if (dest_ptr < src_ptr) {
        std.mem.copyForwards(u8, dest, src);
    } else if (dest_ptr > src_ptr) {
        std.mem.copyBackwards(u8, dest, src);
    }
    return dest_ptr;
}
