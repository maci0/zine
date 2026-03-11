const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "imm32.dll";
    try environment.addBuiltinExport(m, "ImmGetContext", @intFromPtr(&stub_ImmGetContext));
    try environment.addBuiltinExport(m, "ImmReleaseContext", @intFromPtr(&stub_ImmReleaseContext));
    try environment.addBuiltinExport(m, "ImmGetCompositionStringW", @intFromPtr(&stub_ImmGetCompositionStringW));
    try environment.addBuiltinExport(m, "ImmSetCompositionWindow", @intFromPtr(&stub_ImmSetCompositionWindow));
    try environment.addBuiltinExport(m, "ImmSetCompositionFontA", @intFromPtr(&stub_ImmSetCompositionFontA));
    try environment.addBuiltinExport(m, "ImmGetVirtualKey", @intFromPtr(&stub_ImmGetVirtualKey));

    // --- Remaining IMM32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExport(m, "ImmNotifyIME", @intFromPtr(&kernel32.stub_args4));
    try environment.addBuiltinExport(m, "ImmGetCompositionWindow", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "ImmAssociateContext", @intFromPtr(&kernel32.stub_args2));
}

fn stub_ImmGetContext(hWnd: usize) callconv(.winapi) usize {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("IMM32: ImmGetContext\n", .{});
    return 0;
}

fn stub_ImmReleaseContext(hWnd: usize, hIMC: usize) callconv(.winapi) i32 {
    _ = hWnd;
    _ = hIMC;
    if (trace.enable_tracing) trace.print("IMM32: ImmReleaseContext\n", .{});
    return 1;
}

fn stub_ImmGetCompositionStringW(hIMC: usize, dwIndex: u32, lpBuf: usize, dwBufLen: u32) callconv(.winapi) i32 {
    _ = hIMC;
    _ = dwIndex;
    _ = lpBuf;
    _ = dwBufLen;
    if (trace.enable_tracing) trace.print("IMM32: ImmGetCompositionStringW\n", .{});
    return 0;
}

fn stub_ImmSetCompositionWindow(hIMC: usize, lpCompForm: usize) callconv(.winapi) i32 {
    _ = hIMC;
    _ = lpCompForm;
    if (trace.enable_tracing) trace.print("IMM32: ImmSetCompositionWindow\n", .{});
    return 0;
}

fn stub_ImmSetCompositionFontA(hIMC: usize, lplf: usize) callconv(.winapi) i32 {
    _ = hIMC;
    _ = lplf;
    if (trace.enable_tracing) trace.print("IMM32: ImmSetCompositionFontA\n", .{});
    return 0;
}

fn stub_ImmGetVirtualKey(hWnd: usize) callconv(.winapi) u32 {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("IMM32: ImmGetVirtualKey\n", .{});
    return 0;
}
