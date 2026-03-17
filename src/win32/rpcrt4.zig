//! RPCRT4.dll registration.

const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const platform = @import("../platform.zig");
const w32cc = @import("calling_convention.zig");

/// Registers RPCRT4.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const builtin_module = "RPCRT4.dll";
    try environment.addBuiltinExportComptime(builtin_module, "UuidCreate", stub_UuidCreate);
    try environment.addBuiltinExportComptime(builtin_module, "UuidToStringA", stub_UuidToStringA);
    try environment.addBuiltinExportComptime(builtin_module, "RpcStringFreeA", stub_RpcStringFreeA);
}

fn stub_UuidCreate(uuid_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("RPCRT4: UuidCreate({x})\n", .{uuid_ptr});
    if (uuid_ptr != 0) {
        const out = @as([*]u8, @ptrFromInt(uuid_ptr));
        @memset(out[0..16], 0x42);
    }
    return 0; // RPC_S_OK
}

fn stub_UuidToStringA(uuid_ptr: usize, string_ptr: usize) callconv(w32cc.WINAPI) i32 {
    _ = uuid_ptr;
    if (trace.enable_tracing) trace.print("RPCRT4: UuidToStringA(string_ptr={x})\n", .{string_ptr});
    if (string_ptr == 0) return 0;

    const dummy_uuid = "42424242-4242-4242-4242-424242424242";
    const stub_common = @import("shared.zig");

    // On WASM, allocate from guest heap so the x86 code can read the string.
    // On native, allocate from page_allocator (host addresses work directly).
    if (comptime !platform.is_native) {
        if (stub_common.guest_memory) |gmem| {
            const guest_va = gmem.guestAlloc(dummy_uuid.len + 1);
            if (guest_va != 0) {
                const offset = guest_va - gmem.base_addr;
                @memcpy(gmem.base[offset..][0..dummy_uuid.len], dummy_uuid);
                gmem.base[offset + dummy_uuid.len] = 0;
                // Write 32-bit guest VA to the output pointer
                @as(*u32, @ptrFromInt(string_ptr)).* = guest_va;
                return 0;
            }
        }
    }

    // Native path: allocate string in low 4GB (needed for x86_64 compat mode)
    const stub_alloc = @import("shared.zig").raw_alloc;
    const raw = stub_alloc(37) orelse return 14;
    const ptr = @as([*]u8, @ptrCast(raw));
    @memcpy(ptr[0..dummy_uuid.len], dummy_uuid);
    ptr[dummy_uuid.len] = 0;
    // Write 32-bit pointer to the output location (guest expects u32)
    @as(*u32, @ptrFromInt(string_ptr)).* = @truncate(@intFromPtr(ptr));
    return 0; // RPC_S_OK
}

fn stub_RpcStringFreeA(string_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("RPCRT4: RpcStringFreeA({x})\n", .{string_ptr});
    if (string_ptr != 0) {
        @as(*u32, @ptrFromInt(string_ptr)).* = 0;
    }
    return 0; // RPC_S_OK
}
