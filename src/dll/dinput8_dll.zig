//! DINPUT8.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub_DirectInput8Create, .{ .name = "DirectInput8Create" });
}

const DIERR_GENERIC: i32 = @bitCast(@as(u32, 0x80004005)); // E_FAIL

fn stub_DirectInput8Create(hInst: usize, dwVersion: u32, riidltf: usize, ppvOut: usize, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ hInst, dwVersion, riidltf, ppvOut, pUnkOuter };
    return DIERR_GENERIC;
}
