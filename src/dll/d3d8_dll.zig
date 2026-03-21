//! D3D8.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub_Direct3DCreate8, .{ .name = "Direct3DCreate8" });
}

fn stub_Direct3DCreate8(SDKVersion: u32) callconv(w32cc.WINAPI) usize {
    _ = SDKVersion;
    return 0; // NULL — no Direct3D device available
}
