//! IMM32.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub_ImmGetContext, .{ .name = "ImmGetContext" });
    @export(&stub_ImmReleaseContext, .{ .name = "ImmReleaseContext" });
    @export(&stub_ImmGetCompositionStringW, .{ .name = "ImmGetCompositionStringW" });
    @export(&stub_ImmSetCompositionWindow, .{ .name = "ImmSetCompositionWindow" });
    @export(&stub_ImmSetCompositionFontA, .{ .name = "ImmSetCompositionFontA" });
    @export(&stub_ImmGetVirtualKey, .{ .name = "ImmGetVirtualKey" });
    @export(&stub_ret0_2, .{ .name = "ImmGetCompositionWindow" });
    @export(&stub_ret0_2, .{ .name = "ImmAssociateContext" });
    @export(&stub_ret0_3, .{ .name = "ImmNotifyIME" });
}

fn stub_ImmGetContext(hWnd: usize) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    return 0;
}
fn stub_ImmReleaseContext(hWnd: usize, hIMC: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ hWnd, hIMC };
    return 1;
}
fn stub_ImmGetCompositionStringW(hIMC: usize, dwIndex: u32, lpBuf: usize, dwBufLen: u32) callconv(w32cc.WINAPI) i32 {
    _ = .{ hIMC, dwIndex, lpBuf, dwBufLen };
    return 0;
}
fn stub_ImmSetCompositionWindow(hIMC: usize, lpCompForm: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ hIMC, lpCompForm };
    return 0;
}
fn stub_ImmSetCompositionFontA(hIMC: usize, lplf: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ hIMC, lplf };
    return 0;
}
fn stub_ImmGetVirtualKey(hWnd: usize) callconv(w32cc.WINAPI) u32 {
    _ = hWnd;
    return 0;
}
fn stub_ret0_2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b };
    return 0;
}
fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c };
    return 0;
}
