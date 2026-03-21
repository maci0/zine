//! VERSION.dll export definitions
//! Stubs written directly since the original file mixes registration code with implementations.

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub_GetFileVersionInfoSizeA, .{ .name = "GetFileVersionInfoSizeA" });
    @export(&stub_GetFileVersionInfoA, .{ .name = "GetFileVersionInfoA" });
    @export(&stub_VerQueryValueA, .{ .name = "VerQueryValueA" });
    @export(&stub_GetFileVersionInfoSizeW, .{ .name = "GetFileVersionInfoSizeW" });
    @export(&stub_GetFileVersionInfoW, .{ .name = "GetFileVersionInfoW" });
    @export(&stub_VerQueryValueW, .{ .name = "VerQueryValueW" });
}

fn stub_GetFileVersionInfoSizeA(lptstrFilename: usize, lpdwHandle: usize) callconv(w32cc.WINAPI) u32 {
    _ = lptstrFilename;
    if (lpdwHandle != 0) @as(*u32, @ptrFromInt(lpdwHandle)).* = 0;
    return 0;
}
fn stub_GetFileVersionInfoA(a: usize, b: u32, c: u32, d: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d };
    return 0;
}
fn stub_VerQueryValueA(pBlock: usize, lpSubBlock: usize, lplpBuffer: usize, puLen: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ pBlock, lpSubBlock, lplpBuffer };
    if (puLen != 0) @as(*u32, @ptrFromInt(puLen)).* = 0;
    return 0;
}
fn stub_GetFileVersionInfoSizeW(lptstrFilename: usize, lpdwHandle: usize) callconv(w32cc.WINAPI) u32 {
    _ = lptstrFilename;
    if (lpdwHandle != 0) @as(*u32, @ptrFromInt(lpdwHandle)).* = 0;
    return 0;
}
fn stub_GetFileVersionInfoW(a: usize, b: u32, c: u32, d: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d };
    return 0;
}
fn stub_VerQueryValueW(pBlock: usize, lpSubBlock: usize, lplpBuffer: usize, puLen: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ pBlock, lpSubBlock, lplpBuffer };
    if (puLen != 0) @as(*u32, @ptrFromInt(puLen)).* = 0;
    return 0;
}
