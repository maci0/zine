const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "VERSION.dll";
    try environment.addBuiltinExport(m, "GetFileVersionInfoSizeA", @intFromPtr(&stub_GetFileVersionInfoSizeA));
    try environment.addBuiltinExport(m, "GetFileVersionInfoA", @intFromPtr(&stub_GetFileVersionInfoA));
    try environment.addBuiltinExport(m, "VerQueryValueA", @intFromPtr(&stub_VerQueryValueA));
    try environment.addBuiltinExport(m, "GetFileVersionInfoSizeW", @intFromPtr(&stub_GetFileVersionInfoSizeW));
    try environment.addBuiltinExport(m, "GetFileVersionInfoW", @intFromPtr(&stub_GetFileVersionInfoW));
    try environment.addBuiltinExport(m, "VerQueryValueW", @intFromPtr(&stub_VerQueryValueW));
}

fn stub_GetFileVersionInfoSizeA(lptstrFilename: usize, lpdwHandle: usize) callconv(.winapi) u32 {
    _ = lptstrFilename;
    if (lpdwHandle != 0) {
        @as(*u32, @ptrFromInt(lpdwHandle)).* = 0;
    }
    if (trace.enable_tracing) trace.print("VERSION: GetFileVersionInfoSizeA -> 0\n", .{});
    return 0;
}

fn stub_GetFileVersionInfoA(lptstrFilename: usize, dwHandle: u32, dwLen: u32, lpData: usize) callconv(.winapi) i32 {
    _ = lptstrFilename;
    _ = dwHandle;
    _ = dwLen;
    _ = lpData;
    if (trace.enable_tracing) trace.print("VERSION: GetFileVersionInfoA -> 0\n", .{});
    return 0;
}

fn stub_VerQueryValueA(pBlock: usize, lpSubBlock: usize, lplpBuffer: usize, puLen: usize) callconv(.winapi) i32 {
    _ = pBlock;
    _ = lpSubBlock;
    _ = lplpBuffer;
    if (puLen != 0) {
        @as(*u32, @ptrFromInt(puLen)).* = 0;
    }
    if (trace.enable_tracing) trace.print("VERSION: VerQueryValueA -> 0\n", .{});
    return 0;
}

fn stub_GetFileVersionInfoSizeW(lptstrFilename: usize, lpdwHandle: usize) callconv(.winapi) u32 {
    _ = lptstrFilename;
    if (lpdwHandle != 0) {
        @as(*u32, @ptrFromInt(lpdwHandle)).* = 0;
    }
    if (trace.enable_tracing) trace.print("VERSION: GetFileVersionInfoSizeW -> 0\n", .{});
    return 0;
}

fn stub_GetFileVersionInfoW(lptstrFilename: usize, dwHandle: u32, dwLen: u32, lpData: usize) callconv(.winapi) i32 {
    _ = lptstrFilename;
    _ = dwHandle;
    _ = dwLen;
    _ = lpData;
    if (trace.enable_tracing) trace.print("VERSION: GetFileVersionInfoW -> 0\n", .{});
    return 0;
}

fn stub_VerQueryValueW(pBlock: usize, lpSubBlock: usize, lplpBuffer: usize, puLen: usize) callconv(.winapi) i32 {
    _ = pBlock;
    _ = lpSubBlock;
    _ = lplpBuffer;
    if (puLen != 0) {
        @as(*u32, @ptrFromInt(puLen)).* = 0;
    }
    if (trace.enable_tracing) trace.print("VERSION: VerQueryValueW -> 0\n", .{});
    return 0;
}
