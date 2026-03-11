const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");

pub fn register(environment: *env.Environment) !void {
    const builtin_module = "RPCRT4.dll";
    try environment.addBuiltinExport(builtin_module, "UuidCreate", @intFromPtr(&stub_UuidCreate));
    try environment.addBuiltinExport(builtin_module, "UuidToStringA", @intFromPtr(&stub_UuidToStringA));
    try environment.addBuiltinExport(builtin_module, "RpcStringFreeA", @intFromPtr(&stub_RpcStringFreeA));
}

fn stub_UuidCreate(uuid_ptr: usize) callconv(.winapi) i32 {
    if (trace.enable_tracing) trace.print("RPCRT4: UuidCreate({x})\n", .{uuid_ptr});
    if (uuid_ptr != 0) {
        // Just fill with a dummy UUID for now
        const out = @as([*]u8, @ptrFromInt(uuid_ptr));
        @memset(out[0..16], 0x42);
    }
    return 0; // RPC_S_OK
}

fn stub_UuidToStringA(uuid_ptr: usize, string_ptr: usize) callconv(.winapi) i32 {
    if (trace.enable_tracing) trace.print("RPCRT4: UuidToStringA({x}, {x})\n", .{ uuid_ptr, string_ptr });
    if (string_ptr != 0) {
        // Allocate a string. UUID is 36 chars + null.
        const ptr = std.heap.page_allocator.alloc(u8, 37) catch return 14; // RPC_S_OUT_OF_MEMORY
        const dummy_uuid = "42424242-4242-4242-4242-424242424242";
        @memcpy(ptr[0..dummy_uuid.len], dummy_uuid);
        ptr[dummy_uuid.len] = 0;

        const out = @as(*usize, @ptrFromInt(string_ptr));
        out.* = @intFromPtr(ptr.ptr);
    }
    return 0; // RPC_S_OK
}

fn stub_RpcStringFreeA(string_ptr: usize) callconv(.winapi) i32 {
    if (trace.enable_tracing) trace.print("RPCRT4: RpcStringFreeA({x})\n", .{string_ptr});
    // Let it leak or free it if we know the size. Page allocator can't free without size.
    // For a CLI tool, leaking a few UUID strings is fine.
    if (string_ptr != 0) {
        const out = @as(*usize, @ptrFromInt(string_ptr));
        out.* = 0;
    }
    return 0; // RPC_S_OK
}
