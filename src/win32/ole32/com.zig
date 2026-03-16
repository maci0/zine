const std = @import("std");
const trace = @import("../../trace.zig");
const shared = @import("../shared.zig");
const w32cc = @import("../calling_convention.zig");

/// stub_CoInitialize
/// Implementation status: Stub
pub fn stub_CoInitialize(pvReserved: usize) callconv(w32cc.WINAPI) i32 {
    _ = pvReserved;
    if (trace.enable_tracing) trace.print("OLE32: CoInitialize\n", .{});
    return 0; // S_OK
}

/// stub_CoInitializeEx
/// Implementation status: Stub
pub fn stub_CoInitializeEx(pvReserved: usize, dwCoInit: u32) callconv(w32cc.WINAPI) i32 {
    _ = pvReserved;
    _ = dwCoInit;
    if (trace.enable_tracing) trace.print("OLE32: CoInitializeEx\n", .{});
    return 0; // S_OK
}

/// stub_CoUninitialize
/// Implementation status: No-op fallback
pub fn stub_CoUninitialize() callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("OLE32: CoUninitialize\n", .{});
}

/// Dummy COM vtable — all methods return E_NOTIMPL (0x80004001).
/// This provides a non-NULL interface so callers can check HRESULT returns
/// instead of crashing on NULL dereference.
const E_NOTIMPL = @as(i32, @bitCast(@as(u32, 0x80004001)));

fn dummyComMethod0(this: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    return 0; // S_OK
}
fn dummyComMethod1(this: usize, a: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    // Zero output parameter if it looks like a valid pointer
    if (a > 0x10000 and a < 0xF0000000) @as(*align(1) u32, @ptrFromInt(a)).* = 0;
    return 0; // S_OK
}
fn dummyComMethod2(this: usize, a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (a > 0x10000 and a < 0xF0000000) @as(*align(1) u32, @ptrFromInt(a)).* = 0;
    if (b > 0x10000 and b < 0xF0000000) @as(*align(1) u32, @ptrFromInt(b)).* = 0;
    return 0; // S_OK
}
fn dummyComMethod3(this: usize, a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (a > 0x10000 and a < 0xF0000000) @as(*align(1) u32, @ptrFromInt(a)).* = 0;
    if (b > 0x10000 and b < 0xF0000000) @as(*align(1) u32, @ptrFromInt(b)).* = 0;
    if (c > 0x10000 and c < 0xF0000000) @as(*align(1) u32, @ptrFromInt(c)).* = 0;
    return 0; // S_OK
}
fn dummyQueryInterface(this: usize, riid: usize, ppvObject: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ this, riid };
    if (ppvObject != 0) @as(*usize, @ptrFromInt(ppvObject)).* = @intFromPtr(&dummy_com_object);
    return 0; // S_OK - return self for any interface query
}
fn dummyAddRef(this: usize) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 1;
}
fn dummyRelease(this: usize) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 1;
}

// 64-slot vtable of dummy methods. Slot 0=QueryInterface, 1=AddRef, 2=Release,
// rest return E_NOTIMPL with varying arg counts (cycling to handle different sigs).
var dummy_vtable: [64]usize = undefined;
var dummy_vtable_initialized: bool = false;
pub var dummy_com_object: [1]usize = undefined;

pub fn ensureDummyVtable() void {
    if (dummy_vtable_initialized) return;
    dummy_vtable[0] = @intFromPtr(&dummyQueryInterface);
    dummy_vtable[1] = @intFromPtr(&dummyAddRef);
    dummy_vtable[2] = @intFromPtr(&dummyRelease);
    for (3..64) |i| {
        dummy_vtable[i] = switch (i % 3) {
            0 => @intFromPtr(&dummyComMethod1),
            1 => @intFromPtr(&dummyComMethod2),
            2 => @intFromPtr(&dummyComMethod3),
            else => unreachable,
        };
    }
    dummy_com_object[0] = @intFromPtr(&dummy_vtable);
    dummy_vtable_initialized = true;
}

/// stub_CoCreateInstance
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
                clsid[3], clsid[2], clsid[1], clsid[0],
                clsid[5], clsid[4], clsid[7], clsid[6],
                clsid[8], clsid[9], clsid[10], clsid[11],
                clsid[12], clsid[13], clsid[14], clsid[15],
            });
        } else {
            trace.print("OLE32: CoCreateInstance(null) -> E_NOINTERFACE\n", .{});
        }
    }
    return @as(i32, @bitCast(@as(u32, 0x80004002))); // E_NOINTERFACE
}

/// CoTaskMemAlloc
/// Implementation status: Partially implemented
pub fn CoTaskMemAlloc(cb: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("OLE32: CoTaskMemAlloc({d})\n", .{cb});
    if (shared.raw_alloc(cb)) |ptr| {
        return @intFromPtr(ptr);
    }
    return 0;
}

/// stub_CoTaskMemFree
/// Implementation status: Stub
pub fn stub_CoTaskMemFree(pv: usize) callconv(w32cc.WINAPI) void {
    _ = pv;
    if (trace.enable_tracing) trace.print("OLE32: CoTaskMemFree\n", .{});
}

/// stub_DoDragDrop
/// Implementation status: No-op fallback
pub fn stub_DoDragDrop(pDataObj: usize, pDropSource: usize, dwOKEffects: u32, pdwEffect: usize) callconv(w32cc.WINAPI) i32 {
    _ = pDataObj;
    _ = pDropSource;
    _ = dwOKEffects;
    _ = pdwEffect;
    if (trace.enable_tracing) trace.print("OLE32: DoDragDrop -> E_NOTIMPL\n", .{});
    return @as(i32, @bitCast(@as(u32, 0x80004001))); // E_NOTIMPL
}

/// SysFreeString
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
        const src = @as([*]const u8, @ptrFromInt(strIn));
        @memcpy(@as([*]u8, @ptrFromInt(data_ptr))[0..byte_len], src[0..byte_len]);
    } else if (byte_len > 0) {
        @memset(@as([*]u8, @ptrFromInt(data_ptr))[0..byte_len], 0);
    }
    @as(*align(1) u16, @ptrFromInt(data_ptr + byte_len)).* = 0;
    if (trace.enable_tracing) trace.print("OLEAUT32: SysAllocStringLen(len={d}) -> 0x{X}\n", .{ ui, data_ptr });
    return data_ptr;
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

/// SysAllocString
/// Implementation status: Partially implemented
pub fn SysAllocString(strIn: usize) callconv(w32cc.WINAPI) usize {
    if (strIn == 0) return 0;
    // Count wide chars until null terminator
    var len: u32 = 0;
    const src = @as([*]const u16, @ptrFromInt(strIn));
    while (src[len] != 0) : (len += 1) {}
    return SysAllocStringLen(strIn, len);
}
