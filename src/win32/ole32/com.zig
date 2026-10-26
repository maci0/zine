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
    const result = allocateBstr(if (strIn == 0) null else @ptrFromInt(trace.addr(strIn)), ui) orelse return 0;
    return shared.hostToGuest(@intFromPtr(result));
}

fn allocateBstr(source: ?[*]const u16, len: u32) ?[*]u16 {
    const byte_len = std.math.mul(u32, len, 2) catch return null;
    const allocation = std.math.add(u32, byte_len, 6) catch return null;
    _ = std.math.add(u32, allocation, 8) catch return null; // Shared allocator header.
    const memory = shared.raw_alloc(allocation) orelse return null;
    const bytes: [*]u8 = @ptrCast(memory);
    std.mem.writeInt(u32, bytes[0..4], byte_len, .little);
    const result: [*]u16 = @ptrCast(@alignCast(bytes + 4));
    if (source) |src| @memcpy(result[0..len], src[0..len]) else @memset(result[0..len], 0);
    result[len] = 0;
    return result;
}

/// Implementation status: Partially implemented (replaces the string; bump storage is reclaimed at exit).
pub fn SysReAllocStringLen(destination: *?[*]u16, source: ?[*]const u16, len: u32) callconv(w32cc.WINAPI) i32 {
    trace.print("OLEAUT32: SysReAllocStringLen(len={d})\n", .{len});
    const replacement = allocateBstr(source, len) orelse return 0;
    destination.* = replacement;
    return 1;
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

test "BSTR reallocation supports aliases and embedded NULs and preserves the old string on failure" {
    const input = [_]u16{ 'a', 0, 'b' };
    var string: ?[*]u16 = null;
    try std.testing.expectEqual(@as(i32, 1), SysReAllocStringLen(&string, &input, input.len));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0, 'b', 0 }, string.?[0..4]);
    try std.testing.expectEqual(@as(u32, 6), @as(*align(1) const u32, @ptrFromInt(@intFromPtr(string.?) - 4)).*);
    try std.testing.expectEqual(@as(i32, 1), SysReAllocStringLen(&string, string.? + 2, 1));
    try std.testing.expectEqualSlices(u16, &.{ 'b', 0 }, string.?[0..2]);
    const previous = string;
    try std.testing.expectEqual(@as(i32, 0), SysReAllocStringLen(&string, null, std.math.maxInt(u32)));
    try std.testing.expectEqual(previous, string);
    try std.testing.expectEqual(@as(i32, 1), SysReAllocStringLen(&string, null, 0));
    try std.testing.expectEqual(@as(u16, 0), string.?[0]);
}
