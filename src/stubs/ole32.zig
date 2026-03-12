const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const mem = @import("kernel32/mem.zig");
const w32cc = @import("../calling_convention.zig");

pub fn register(environment: *env.Environment) !void {
    // ole32.dll
    const m = "ole32.dll";
    try environment.addBuiltinExportComptime(m, "CoInitialize", stub_CoInitialize);
    try environment.addBuiltinExportComptime(m, "CoInitializeEx", stub_CoInitializeEx);
    try environment.addBuiltinExportComptime(m, "CoUninitialize", stub_CoUninitialize);
    try environment.addBuiltinExportComptime(m, "CoCreateInstance", stub_CoCreateInstance);
    try environment.addBuiltinExportComptime(m, "CoTaskMemAlloc", stub_CoTaskMemAlloc);
    try environment.addBuiltinExportComptime(m, "CoTaskMemFree", stub_CoTaskMemFree);
    try environment.addBuiltinExportComptime(m, "DoDragDrop", stub_DoDragDrop);

    // oleaut32.dll
    const o = "oleaut32.dll";
    try environment.addBuiltinExportComptime(o, "SysFreeString", stub_SysFreeString);
    try environment.addBuiltinExportComptime(o, "SysAllocStringLen", stub_SysAllocStringLen);

    // --- Remaining OLE32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExportComptime(m, "StringFromCLSID", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "WriteFmtUserTypeStg", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WriteClassStg", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "OleUninitialize", stub_CoUninitialize);
    try environment.addBuiltinExportComptime(m, "StgOpenStorage", kernel32.stub_args6);
    try environment.addBuiltinExportComptime(m, "OleRegGetUserType", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ReadClassStg", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "StgCreateDocfileOnILockBytes", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "CreateILockBytesOnHGlobal", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ReleaseStgMedium", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "OleInitialize", stub_CoInitialize);
}

fn stub_CoInitialize(pvReserved: usize) callconv(w32cc.WINAPI) i32 {
    _ = pvReserved;
    if (trace.enable_tracing) trace.print("OLE32: CoInitialize\n", .{});
    return 0; // S_OK
}

fn stub_CoInitializeEx(pvReserved: usize, dwCoInit: u32) callconv(w32cc.WINAPI) i32 {
    _ = pvReserved;
    _ = dwCoInit;
    if (trace.enable_tracing) trace.print("OLE32: CoInitializeEx\n", .{});
    return 0; // S_OK
}

fn stub_CoUninitialize() callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("OLE32: CoUninitialize\n", .{});
}

fn stub_CoCreateInstance(rclsid: usize, pUnkOuter: usize, dwClsContext: u32, riid: usize, ppv: usize) callconv(w32cc.WINAPI) i32 {
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

fn stub_CoTaskMemAlloc(cb: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("OLE32: CoTaskMemAlloc({d})\n", .{cb});
    if (mem.raw_alloc(cb)) |ptr| {
        return @intFromPtr(ptr);
    }
    return 0;
}

fn stub_CoTaskMemFree(pv: usize) callconv(w32cc.WINAPI) void {
    _ = pv;
    if (trace.enable_tracing) trace.print("OLE32: CoTaskMemFree\n", .{});
}

fn stub_DoDragDrop(pDataObj: usize, pDropSource: usize, dwOKEffects: u32, pdwEffect: usize) callconv(w32cc.WINAPI) i32 {
    _ = pDataObj;
    _ = pDropSource;
    _ = dwOKEffects;
    _ = pdwEffect;
    if (trace.enable_tracing) trace.print("OLE32: DoDragDrop -> E_NOTIMPL\n", .{});
    return @as(i32, @bitCast(@as(u32, 0x80004001))); // E_NOTIMPL
}

fn stub_SysFreeString(bstrString: usize) callconv(w32cc.WINAPI) void {
    _ = bstrString;
    if (trace.enable_tracing) trace.print("OLEAUT32: SysFreeString\n", .{});
}

fn stub_SysAllocStringLen(strIn: usize, ui: u32) callconv(w32cc.WINAPI) usize {
    _ = strIn;
    _ = ui;
    if (trace.enable_tracing) trace.print("OLEAUT32: SysAllocStringLen\n", .{});
    return 0;
}
