//! DSOUND.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub_DirectSoundCreate, .{ .name = "DirectSoundCreate" });
    @export(&stub_DirectSoundEnumerateA, .{ .name = "DirectSoundEnumerateA" });
}

const DSERR_GENERIC: i32 = @bitCast(@as(u32, 0x80004005)); // E_FAIL

fn stub_DirectSoundCreate(pcGuidDevice: usize, ppDS: usize, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ pcGuidDevice, ppDS, pUnkOuter };
    return DSERR_GENERIC;
}

fn stub_DirectSoundEnumerateA(lpDSEnumCallback: usize, lpContext: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ lpDSEnumCallback, lpContext };
    return 0; // DS_OK — no devices enumerated
}
