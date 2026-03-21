//! DDRAW.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub_DirectDrawCreate, .{ .name = "DirectDrawCreate" });
    @export(&stub_DirectDrawCreateEx, .{ .name = "DirectDrawCreateEx" });
    @export(&stub_DirectDrawEnumerateExA, .{ .name = "DirectDrawEnumerateExA" });
}

const DDERR_GENERIC: i32 = @bitCast(@as(u32, 0x80004005)); // E_FAIL

fn stub_DirectDrawCreate(lpGUID: usize, lplpDD: usize, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ lpGUID, lplpDD, pUnkOuter };
    return DDERR_GENERIC;
}

fn stub_DirectDrawCreateEx(lpGUID: usize, lplpDD: usize, iid: usize, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ lpGUID, lplpDD, iid, pUnkOuter };
    return DDERR_GENERIC;
}

fn stub_DirectDrawEnumerateExA(lpCallback: usize, lpContext: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = .{ lpCallback, lpContext, dwFlags };
    return 0; // DD_OK — no devices enumerated
}
