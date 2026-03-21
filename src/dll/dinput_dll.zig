//! DINPUT.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub_DirectInputCreateA, .{ .name = "DirectInputCreateA" });
}

const DIERR_GENERIC: i32 = @bitCast(@as(u32, 0x80004005)); // E_FAIL

fn stub_DirectInputCreateA(hInst: usize, dwVersion: u32, ppDI: usize, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ hInst, dwVersion, ppDI, pUnkOuter };
    return DIERR_GENERIC;
}
