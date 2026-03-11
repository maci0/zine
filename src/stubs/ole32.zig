const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const mem = @import("kernel32/mem.zig");

pub fn register(environment: *env.Environment) !void {
    // ole32.dll
    const m = "ole32.dll";
    try environment.addBuiltinExport(m, "CoInitialize", @intFromPtr(&stub_CoInitialize));
    try environment.addBuiltinExport(m, "CoInitializeEx", @intFromPtr(&stub_CoInitializeEx));
    try environment.addBuiltinExport(m, "CoUninitialize", @intFromPtr(&stub_CoUninitialize));
    try environment.addBuiltinExport(m, "CoCreateInstance", @intFromPtr(&stub_CoCreateInstance));
    try environment.addBuiltinExport(m, "CoTaskMemAlloc", @intFromPtr(&stub_CoTaskMemAlloc));
    try environment.addBuiltinExport(m, "CoTaskMemFree", @intFromPtr(&stub_CoTaskMemFree));
    try environment.addBuiltinExport(m, "DoDragDrop", @intFromPtr(&stub_DoDragDrop));

    // oleaut32.dll
    const o = "oleaut32.dll";
    try environment.addBuiltinExport(o, "SysFreeString", @intFromPtr(&stub_SysFreeString));
    try environment.addBuiltinExport(o, "SysAllocStringLen", @intFromPtr(&stub_SysAllocStringLen));

    // --- Remaining OLE32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExport(m, "StringFromCLSID", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "WriteFmtUserTypeStg", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(m, "WriteClassStg", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "OleUninitialize", @intFromPtr(&stub_CoUninitialize));
    try environment.addBuiltinExport(m, "StgOpenStorage", @intFromPtr(&kernel32.stub_args6));
    try environment.addBuiltinExport(m, "OleRegGetUserType", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(m, "ReadClassStg", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "StgCreateDocfileOnILockBytes", @intFromPtr(&kernel32.stub_args4));
    try environment.addBuiltinExport(m, "CreateILockBytesOnHGlobal", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(m, "ReleaseStgMedium", @intFromPtr(&kernel32.stub_args1));
    try environment.addBuiltinExport(m, "OleInitialize", @intFromPtr(&stub_CoInitialize));
}

fn stub_CoInitialize(pvReserved: usize) callconv(.winapi) i32 {
    _ = pvReserved;
    if (trace.enable_tracing) trace.print("OLE32: CoInitialize\n", .{});
    return 0; // S_OK
}

fn stub_CoInitializeEx(pvReserved: usize, dwCoInit: u32) callconv(.winapi) i32 {
    _ = pvReserved;
    _ = dwCoInit;
    if (trace.enable_tracing) trace.print("OLE32: CoInitializeEx\n", .{});
    return 0; // S_OK
}

fn stub_CoUninitialize() callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("OLE32: CoUninitialize\n", .{});
}

fn stub_CoCreateInstance(rclsid: usize, pUnkOuter: usize, dwClsContext: u32, riid: usize, ppv: usize) callconv(.winapi) i32 {
    _ = rclsid;
    _ = pUnkOuter;
    _ = dwClsContext;
    _ = riid;
    if (ppv != 0) {
        @as(*usize, @ptrFromInt(ppv)).* = 0;
    }
    if (trace.enable_tracing) trace.print("OLE32: CoCreateInstance -> E_NOINTERFACE\n", .{});
    return @as(i32, @bitCast(@as(u32, 0x80004002))); // E_NOINTERFACE
}

fn stub_CoTaskMemAlloc(cb: usize) callconv(.winapi) usize {
    if (trace.enable_tracing) trace.print("OLE32: CoTaskMemAlloc({d})\n", .{cb});
    if (mem.raw_alloc(cb)) |ptr| {
        return @intFromPtr(ptr);
    }
    return 0;
}

fn stub_CoTaskMemFree(pv: usize) callconv(.winapi) void {
    _ = pv;
    if (trace.enable_tracing) trace.print("OLE32: CoTaskMemFree\n", .{});
}

fn stub_DoDragDrop(pDataObj: usize, pDropSource: usize, dwOKEffects: u32, pdwEffect: usize) callconv(.winapi) i32 {
    _ = pDataObj;
    _ = pDropSource;
    _ = dwOKEffects;
    _ = pdwEffect;
    if (trace.enable_tracing) trace.print("OLE32: DoDragDrop -> E_NOTIMPL\n", .{});
    return @as(i32, @bitCast(@as(u32, 0x80004001))); // E_NOTIMPL
}

fn stub_SysFreeString(bstrString: usize) callconv(.winapi) void {
    _ = bstrString;
    if (trace.enable_tracing) trace.print("OLEAUT32: SysFreeString\n", .{});
}

fn stub_SysAllocStringLen(strIn: usize, ui: u32) callconv(.winapi) usize {
    _ = strIn;
    _ = ui;
    if (trace.enable_tracing) trace.print("OLEAUT32: SysAllocStringLen\n", .{});
    return 0;
}
