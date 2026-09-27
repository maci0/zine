const std = @import("std");
const trace = @import("../../trace.zig");
const shared = @import("../shared.zig");
const w32cc = @import("../calling_convention.zig");

/// Implementation status: Stub
pub fn stub_CoInitialize(pvReserved: usize) callconv(w32cc.WINAPI) i32 {
    _ = pvReserved;
    if (trace.enable_tracing) trace.print("OLE32: CoInitialize\n", .{});
    return 0; // S_OK
}

/// Implementation status: Stub
pub fn stub_CoInitializeEx(pvReserved: usize, dwCoInit: u32) callconv(w32cc.WINAPI) i32 {
    _ = pvReserved;
    _ = dwCoInit;
    if (trace.enable_tracing) trace.print("OLE32: CoInitializeEx\n", .{});
    return 0; // S_OK
}

/// Implementation status: No-op fallback
pub fn stub_CoUninitialize() callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("OLE32: CoUninitialize\n", .{});
}

/// Implementation status: No-op fallback
pub fn stub_CoCreateInstance(rclsid: usize, pUnkOuter: usize, dwClsContext: u32, riid: usize, ppv: usize) callconv(w32cc.WINAPI) i32 {
    _ = pUnkOuter;
    _ = dwClsContext;
    _ = riid;

    // Try WMI (WbemLocator) — needed by cpuidsdk.dll for CPU detection
    const wmi = @import("wmi.zig");
    if (wmi.tryCreateWbemLocator(rclsid, ppv)) {
        return 0; // S_OK
    }

    if (ppv != 0) @as(*usize, @ptrFromInt(ppv)).* = 0;
    if (trace.enable_tracing) {
        if (rclsid != 0) {
            const clsid = @as([*]const u8, @ptrFromInt(rclsid));
            trace.print("OLE32: CoCreateInstance({x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}) -> E_NOINTERFACE\n", .{
                clsid[3],  clsid[2],  clsid[1],  clsid[0],
                clsid[5],  clsid[4],  clsid[7],  clsid[6],
                clsid[8],  clsid[9],  clsid[10], clsid[11],
                clsid[12], clsid[13], clsid[14], clsid[15],
            });
        } else {
            trace.print("OLE32: CoCreateInstance(null) -> E_NOINTERFACE\n", .{});
        }
    }
    return @as(i32, @bitCast(@as(u32, 0x80004002))); // E_NOINTERFACE
}

/// Implementation status: Partially implemented
pub fn CoTaskMemAlloc(cb: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("OLE32: CoTaskMemAlloc({d})\n", .{cb});
    if (shared.raw_alloc(cb)) |ptr| {
        // usize return — hand back a guest VA, not the raw host pointer.
        return shared.hostToGuest(@intFromPtr(ptr));
    }
    return 0;
}

/// Implementation status: Stub
pub fn stub_CoTaskMemFree(pv: usize) callconv(w32cc.WINAPI) void {
    _ = pv;
    if (trace.enable_tracing) trace.print("OLE32: CoTaskMemFree\n", .{});
}

/// Implementation status: No-op fallback
pub fn stub_DoDragDrop(pDataObj: usize, pDropSource: usize, dwOKEffects: u32, pdwEffect: usize) callconv(w32cc.WINAPI) i32 {
    _ = pDataObj;
    _ = pDropSource;
    _ = dwOKEffects;
    _ = pdwEffect;
    if (trace.enable_tracing) trace.print("OLE32: DoDragDrop -> E_NOTIMPL\n", .{});
    return @as(i32, @bitCast(@as(u32, 0x80004001))); // E_NOTIMPL
}

/// Implementation status: Partially implemented
pub fn SysFreeString(bstrString: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("OLEAUT32: SysFreeString(0x{X})\n", .{bstrString});
    // Bump allocator doesn't support freeing; memory is reclaimed at exit
}

/// SysAllocStringLen — allocate a BSTR (length-prefixed wide string)
/// Layout: [u32 byte_length][wide chars...][u16 null]
/// Implementation status: Partially implemented
pub fn SysAllocStringLen(strIn: usize, ui: u32) callconv(w32cc.WINAPI) usize {
    const byte_len: usize = @as(usize, ui) * 2;
    const alloc_size = 4 + byte_len + 2;
    const ptr = shared.raw_alloc(alloc_size) orelse return 0;
    const base = @intFromPtr(ptr);
    @as(*align(1) u32, @ptrFromInt(base)).* = @intCast(byte_len);
    const data_ptr = base + 4;
    if (strIn != 0 and byte_len > 0) {
        // strIn is a guest VA (usize param — not auto-translated).
        const src = @as([*]const u8, @ptrFromInt(trace.addr(strIn)));
        @memcpy(@as([*]u8, @ptrFromInt(data_ptr))[0..byte_len], src[0..byte_len]);
    } else if (byte_len > 0) {
        @memset(@as([*]u8, @ptrFromInt(data_ptr))[0..byte_len], 0);
    }
    @as(*align(1) u16, @ptrFromInt(data_ptr + byte_len)).* = 0;
    // usize return — hand back a guest VA, not the raw host pointer.
    const guest_va = shared.hostToGuest(data_ptr);
    if (trace.enable_tracing) trace.print("OLEAUT32: SysAllocStringLen(len={d}) -> 0x{X}\n", .{ ui, guest_va });
    return guest_va;
}

/// VariantClear — release any resources in a VARIANT and zero it
/// Implementation status: Partially implemented
pub fn VariantClear(pvariant: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("OLEAUT32: VariantClear({x})\n", .{pvariant});
    if (pvariant != 0) {
        // VARIANT is 16 bytes: vt(2), padding(6), data(8)
        // If it's a BSTR (vt=8), free the BSTR
        const vt = @as(*const u16, @ptrFromInt(pvariant)).*;
        if (vt == 8) { // VT_BSTR
            const bstr = @as(*const u32, @ptrFromInt(pvariant + 8)).*;
            if (bstr != 0) SysFreeString(bstr);
        }
        // Zero the whole VARIANT
        @memset(@as([*]u8, @ptrFromInt(pvariant))[0..16], 0);
    }
    return 0; // S_OK
}

/// VariantInit — initialize a VARIANT to VT_EMPTY
/// Implementation status: Fully implemented
pub fn VariantInit(pvariant: usize) callconv(w32cc.WINAPI) void {
    if (pvariant != 0) {
        @memset(@as([*]u8, @ptrFromInt(pvariant))[0..16], 0);
    }
}

/// SysStringLen — return length of BSTR in wide characters
/// Implementation status: Fully implemented
pub fn SysStringLen(bstr: usize) callconv(w32cc.WINAPI) u32 {
    if (bstr == 0) return 0;
    // BSTR layout: [u32 byte_length at bstr-4][wide chars at bstr]
    const byte_len = @as(*align(1) const u32, @ptrFromInt(bstr - 4)).*;
    return byte_len / 2;
}

/// SysStringByteLen — return length of BSTR in bytes
/// Implementation status: Fully implemented
pub fn SysStringByteLen(bstr: usize) callconv(w32cc.WINAPI) u32 {
    if (bstr == 0) return 0;
    return @as(*align(1) const u32, @ptrFromInt(bstr - 4)).*;
}

/// Implementation status: Partially implemented
pub fn SysAllocString(strIn: usize) callconv(w32cc.WINAPI) usize {
    if (strIn == 0) return 0;
    // Count wide chars until null terminator
    var len: u32 = 0;
    const src = @as([*]const u16, @ptrFromInt(strIn));
    while (src[len] != 0) : (len += 1) {}
    return SysAllocStringLen(strIn, len);
}
