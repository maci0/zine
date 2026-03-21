//! MFC42.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    // MFC42 uses ordinal-only exports. Export a generic stub for common ordinals.
    @export(&stub_mfc_dummy, .{ .name = "MFC42_stub" });
}

fn stub_mfc_dummy() callconv(w32cc.WINAPI) usize {
    return 0;
}
