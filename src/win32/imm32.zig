//! IMM32.dll registration.

const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32cc = @import("calling_convention.zig");

/// Registers IMM32.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "imm32.dll";
    try environment.addBuiltinExportComptime(m, "ImmGetContext", stub_ImmGetContext);
    try environment.addBuiltinExportComptime(m, "ImmReleaseContext", stub_ImmReleaseContext);
    try environment.addBuiltinExportComptime(m, "ImmGetCompositionStringW", stub_ImmGetCompositionStringW);
    try environment.addBuiltinExportComptime(m, "ImmSetCompositionWindow", stub_ImmSetCompositionWindow);
    try environment.addBuiltinExportComptime(m, "ImmSetCompositionFontA", stub_ImmSetCompositionFontA);
    try environment.addBuiltinExportComptime(m, "ImmGetVirtualKey", stub_ImmGetVirtualKey);

    // --- Remaining IMM32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExportComptime(m, "ImmNotifyIME", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "ImmGetCompositionWindow", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "ImmAssociateContext", kernel32.stub_args2);
}

fn stub_ImmGetContext(hWnd: usize) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("IMM32: ImmGetContext\n", .{});
    return 0;
}

fn stub_ImmReleaseContext(hWnd: usize, hIMC: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = hIMC;
    if (trace.enable_tracing) trace.print("IMM32: ImmReleaseContext\n", .{});
    return 1;
}

fn stub_ImmGetCompositionStringW(hIMC: usize, dwIndex: u32, lpBuf: usize, dwBufLen: u32) callconv(w32cc.WINAPI) i32 {
    _ = hIMC;
    _ = dwIndex;
    _ = lpBuf;
    _ = dwBufLen;
    if (trace.enable_tracing) trace.print("IMM32: ImmGetCompositionStringW\n", .{});
    return 0;
}

fn stub_ImmSetCompositionWindow(hIMC: usize, lpCompForm: usize) callconv(w32cc.WINAPI) i32 {
    _ = hIMC;
    _ = lpCompForm;
    if (trace.enable_tracing) trace.print("IMM32: ImmSetCompositionWindow\n", .{});
    return 0;
}

fn stub_ImmSetCompositionFontA(hIMC: usize, lplf: usize) callconv(w32cc.WINAPI) i32 {
    _ = hIMC;
    _ = lplf;
    if (trace.enable_tracing) trace.print("IMM32: ImmSetCompositionFontA\n", .{});
    return 0;
}

fn stub_ImmGetVirtualKey(hWnd: usize) callconv(w32cc.WINAPI) u32 {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("IMM32: ImmGetVirtualKey\n", .{});
    return 0;
}
