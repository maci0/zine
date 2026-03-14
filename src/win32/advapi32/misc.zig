const trace = @import("../../trace.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn GetUserNameA(lpBuffer: usize, pcbBuffer: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("ADVAPI32: GetUserNameA\n", .{});
    const name = "User";
    if (lpBuffer != 0 and pcbBuffer != 0) {
        const buf_size = @as(*u32, @ptrFromInt(pcbBuffer)).*;
        if (buf_size >= name.len + 1) {
            const buf = @as([*]u8, @ptrFromInt(lpBuffer));
            @memcpy(buf[0..name.len], name);
            buf[name.len] = 0;
            @as(*u32, @ptrFromInt(pcbBuffer)).* = @intCast(name.len + 1);
            return 1;
        }
    }
    if (pcbBuffer != 0) {
        @as(*u32, @ptrFromInt(pcbBuffer)).* = @intCast(name.len + 1);
    }
    return 0;
}

// --- Return TRUE helpers (for functions that must succeed) ---
pub fn stub_ret_true_1(a: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    return 1; // TRUE
}

pub fn stub_ret_true_2(a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = a; _ = b;
    return 1;
}

pub fn stub_ret_true_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = a; _ = b; _ = c;
    return 1;
}

pub fn stub_ret_true_4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) i32 {
    _ = a; _ = b; _ = c; _ = d;
    return 1;
}

// =============================================================================
// Tests
// =============================================================================

test "InitializeSecurityDescriptor returns TRUE" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 1), stub_ret_true_2(0x1234, 1));
}
