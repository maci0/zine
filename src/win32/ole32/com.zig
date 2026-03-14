const std = @import("std");
const trace = @import("../../trace.zig");
const mem = @import("../kernel32/mem.zig");
const w32cc = @import("../../calling_convention.zig");


pub fn stub_CoInitialize(pvReserved: usize) callconv(w32cc.WINAPI) i32 {
    _ = pvReserved;
    if (trace.enable_tracing) trace.print("OLE32: CoInitialize\n", .{});
    return 0; // S_OK
}

pub fn stub_CoInitializeEx(pvReserved: usize, dwCoInit: u32) callconv(w32cc.WINAPI) i32 {
    _ = pvReserved;
    _ = dwCoInit;
    if (trace.enable_tracing) trace.print("OLE32: CoInitializeEx\n", .{});
    return 0; // S_OK
}

pub fn stub_CoUninitialize() callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("OLE32: CoUninitialize\n", .{});
}

pub fn stub_CoCreateInstance(rclsid: usize, pUnkOuter: usize, dwClsContext: u32, riid: usize, ppv: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn CoTaskMemAlloc(cb: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("OLE32: CoTaskMemAlloc({d})\n", .{cb});
    if (mem.raw_alloc(cb)) |ptr| {
        return @intFromPtr(ptr);
    }
    return 0;
}

pub fn stub_CoTaskMemFree(pv: usize) callconv(w32cc.WINAPI) void {
    _ = pv;
    if (trace.enable_tracing) trace.print("OLE32: CoTaskMemFree\n", .{});
}

pub fn stub_DoDragDrop(pDataObj: usize, pDropSource: usize, dwOKEffects: u32, pdwEffect: usize) callconv(w32cc.WINAPI) i32 {
    _ = pDataObj;
    _ = pDropSource;
    _ = dwOKEffects;
    _ = pdwEffect;
    if (trace.enable_tracing) trace.print("OLE32: DoDragDrop -> E_NOTIMPL\n", .{});
    return @as(i32, @bitCast(@as(u32, 0x80004001))); // E_NOTIMPL
}

pub fn stub_SysFreeString(bstrString: usize) callconv(w32cc.WINAPI) void {
    _ = bstrString;
    if (trace.enable_tracing) trace.print("OLEAUT32: SysFreeString\n", .{});
}

pub fn stub_SysAllocStringLen(strIn: usize, ui: u32) callconv(w32cc.WINAPI) usize {
    _ = strIn;
    _ = ui;
    if (trace.enable_tracing) trace.print("OLEAUT32: SysAllocStringLen\n", .{});
    return 0;
}
