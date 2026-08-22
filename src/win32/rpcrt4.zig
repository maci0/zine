//! RPCRT4.dll registration.

const std = @import("std");
const x86_memory = @import("../x86/memory.zig");
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
        // uuid_ptr is a guest VA (usize param — not auto-translated).
        const out = @as([*]u8, @ptrFromInt(trace.addr(uuid_ptr)));
        @memset(out[0..16], 0x42); // Deterministic stand-in for a random GUID
    }
    return 0; // RPC_S_OK
}

fn stub_UuidToStringA(uuid_ptr: usize, string_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("RPCRT4: UuidToStringA(uuid={x}, string_ptr={x})\n", .{ uuid_ptr, string_ptr });
    if (string_ptr == 0) return 0;

    // Format the GUID bytes from the caller's buffer into canonical form.
    var uuid_buf: [37]u8 = undefined;
    if (uuid_ptr != 0) {
        const uuid = @as([*]const u8, @ptrFromInt(trace.addr(uuid_ptr)));
        _ = std.fmt.bufPrint(&uuid_buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        }) catch return 14; // RPC_S_OUT_OF_MEMORY-ish; treat as failure
    } else {
        const dummy = "42424242-4242-4242-4242-424242424242";
        @memcpy(uuid_buf[0..dummy.len], dummy);
    }
    const uuid_len = 36;

    // On WASM, allocate from guest heap so the x86 code can read the string.
    // On native, allocate from page_allocator (host addresses work directly).
    if (comptime !platform.is_native) {
        if (x86_memory.guest_memory) |gmem| {
            const guest_va = gmem.guestAlloc(uuid_len + 1);
            if (guest_va != 0) {
                const offset = guest_va - gmem.base_addr;
                @memcpy(gmem.base[offset..][0..uuid_len], uuid_buf[0..uuid_len]);
                gmem.base[offset + uuid_len] = 0;
                // string_ptr is a guest VA pointing to the caller's RPC_CSTR slot.
                @as(*u32, @ptrFromInt(trace.addr(string_ptr))).* = guest_va;
                return 0;
            }
        }
    }

    // Native path: allocate string in low 4GB (needed for x86_64 compat mode)
    const stub_alloc = @import("shared.zig").raw_alloc;
    const raw = stub_alloc(uuid_len + 1) orelse return 14;
    const ptr = @as([*]u8, @ptrCast(raw));
    @memcpy(ptr[0..uuid_len], uuid_buf[0..uuid_len]);
    ptr[uuid_len] = 0;
    // Write 32-bit pointer to the output location (guest expects u32)
    @as(*u32, @ptrFromInt(string_ptr)).* = @truncate(@intFromPtr(ptr));
    return 0; // RPC_S_OK
}

fn stub_RpcStringFreeA(string_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("RPCRT4: RpcStringFreeA({x})\n", .{string_ptr});
    if (string_ptr != 0) {
        // string_ptr is a guest VA pointing to the caller's RPC_CSTR slot.
        @as(*u32, @ptrFromInt(trace.addr(string_ptr))).* = 0;
    }
    return 0; // RPC_S_OK
}
