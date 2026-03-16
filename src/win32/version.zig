//! VERSION.dll registration.

const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32cc = @import("calling_convention.zig");

/// Registers VERSION.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "VERSION.dll";
    try environment.addBuiltinExportComptime(m, "GetFileVersionInfoSizeA", stub_GetFileVersionInfoSizeA);
    try environment.addBuiltinExportComptime(m, "GetFileVersionInfoA", stub_GetFileVersionInfoA);
    try environment.addBuiltinExportComptime(m, "VerQueryValueA", stub_VerQueryValueA);
    try environment.addBuiltinExportComptime(m, "GetFileVersionInfoSizeW", stub_GetFileVersionInfoSizeW);
    try environment.addBuiltinExportComptime(m, "GetFileVersionInfoW", stub_GetFileVersionInfoW);
    try environment.addBuiltinExportComptime(m, "VerQueryValueW", stub_VerQueryValueW);
}

fn stub_GetFileVersionInfoSizeA(lptstrFilename: usize, lpdwHandle: usize) callconv(w32cc.WINAPI) u32 {
    _ = lptstrFilename;
    if (lpdwHandle != 0) {
        @as(*u32, @ptrFromInt(lpdwHandle)).* = 0;
    }
    if (trace.enable_tracing) trace.print("VERSION: GetFileVersionInfoSizeA -> 0\n", .{});
    return 0;
}

fn stub_GetFileVersionInfoA(lptstrFilename: usize, dwHandle: u32, dwLen: u32, lpData: usize) callconv(w32cc.WINAPI) i32 {
    _ = lptstrFilename;
    _ = dwHandle;
    _ = dwLen;
    _ = lpData;
    if (trace.enable_tracing) trace.print("VERSION: GetFileVersionInfoA -> 0\n", .{});
    return 0;
}

fn stub_VerQueryValueA(pBlock: usize, lpSubBlock: usize, lplpBuffer: usize, puLen: usize) callconv(w32cc.WINAPI) i32 {
    _ = pBlock;
    _ = lpSubBlock;
    _ = lplpBuffer;
    if (puLen != 0) {
        @as(*u32, @ptrFromInt(puLen)).* = 0;
    }
    if (trace.enable_tracing) trace.print("VERSION: VerQueryValueA -> 0\n", .{});
    return 0;
}

fn stub_GetFileVersionInfoSizeW(lptstrFilename: usize, lpdwHandle: usize) callconv(w32cc.WINAPI) u32 {
    _ = lptstrFilename;
    if (lpdwHandle != 0) {
        @as(*u32, @ptrFromInt(lpdwHandle)).* = 0;
    }
    if (trace.enable_tracing) trace.print("VERSION: GetFileVersionInfoSizeW -> 0\n", .{});
    return 0;
}

fn stub_GetFileVersionInfoW(lptstrFilename: usize, dwHandle: u32, dwLen: u32, lpData: usize) callconv(w32cc.WINAPI) i32 {
    _ = lptstrFilename;
    _ = dwHandle;
    _ = dwLen;
    _ = lpData;
    if (trace.enable_tracing) trace.print("VERSION: GetFileVersionInfoW -> 0\n", .{});
    return 0;
}

fn stub_VerQueryValueW(pBlock: usize, lpSubBlock: usize, lplpBuffer: usize, puLen: usize) callconv(w32cc.WINAPI) i32 {
    _ = pBlock;
    _ = lpSubBlock;
    _ = lplpBuffer;
    if (puLen != 0) {
        @as(*u32, @ptrFromInt(puLen)).* = 0;
    }
    if (trace.enable_tracing) trace.print("VERSION: VerQueryValueW -> 0\n", .{});
    return 0;
}
