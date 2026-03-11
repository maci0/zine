const env = @import("../loader/env.zig");

const object = @import("gdi32/object.zig");
const dc = @import("gdi32/dc.zig");
const drawing = @import("gdi32/drawing.zig");

// Shared handle counter
var next_gdi_handle: u32 = 0xA0000001;

pub fn nextHandle() usize {
    const h = next_gdi_handle;
    next_gdi_handle +%= 1;
    return h;
}

// --- DIB Section Tracking ---
// Tracks pixel buffers returned by CreateDIBSection so that BitBlt can
// look up the source bitmap's pixel data.

pub const DibInfo = struct {
    handle: usize,    // GDI bitmap handle
    buffer: usize,    // ppvBits pointer (pixel data)
    width: u32,
    height: u32,
    bpp: u16,         // bits per pixel
};

pub var dib_entries: [16]DibInfo = [_]DibInfo{.{ .handle = 0, .buffer = 0, .width = 0, .height = 0, .bpp = 0 }} ** 16;
pub var dib_count: usize = 0;

pub fn registerDib(handle: usize, buffer: usize, width: u32, height: u32, bpp: u16) void {
    if (dib_count < dib_entries.len) {
        dib_entries[dib_count] = .{ .handle = handle, .buffer = buffer, .width = width, .height = height, .bpp = bpp };
        dib_count += 1;
    }
}

pub fn findDib(handle: usize) ?*const DibInfo {
    for (dib_entries[0..dib_count]) |*entry| {
        if (entry.handle == handle) return entry;
    }
    return null;
}

// --- DC → Bitmap binding ---
// Tracks SelectObject(dc, bitmap) so BitBlt can resolve source DC to pixel data.

const DcBinding = struct {
    dc_handle: usize,
    bmp_handle: usize,
};

var dc_bindings: [16]DcBinding = [_]DcBinding{.{ .dc_handle = 0, .bmp_handle = 0 }} ** 16;
var dc_binding_count: usize = 0;

pub fn bindDcBitmap(dc_handle: usize, bmp_handle: usize) void {
    // Update existing binding or add new one
    for (dc_bindings[0..dc_binding_count]) |*b| {
        if (b.dc_handle == dc_handle) {
            b.bmp_handle = bmp_handle;
            return;
        }
    }
    if (dc_binding_count < dc_bindings.len) {
        dc_bindings[dc_binding_count] = .{ .dc_handle = dc_handle, .bmp_handle = bmp_handle };
        dc_binding_count += 1;
    }
}

pub fn getDcDib(dc_handle: usize) ?*const DibInfo {
    for (dc_bindings[0..dc_binding_count]) |*b| {
        if (b.dc_handle == dc_handle) {
            return findDib(b.bmp_handle);
        }
    }
    return null;
}

pub fn register(environment: *env.Environment) !void {
    const m = "GDI32.dll";

    // Object Management (object.zig)
    try environment.addBuiltinExport(m, "GetStockObject", @intFromPtr(&object.stub_GetStockObject));
    try environment.addBuiltinExport(m, "SelectObject", @intFromPtr(&object.stub_SelectObject));
    try environment.addBuiltinExport(m, "DeleteObject", @intFromPtr(&object.stub_DeleteObject));
    try environment.addBuiltinExport(m, "CreateSolidBrush", @intFromPtr(&object.stub_CreateSolidBrush));
    try environment.addBuiltinExport(m, "CreatePen", @intFromPtr(&object.stub_CreatePen));
    try environment.addBuiltinExport(m, "CreateFontIndirectA", @intFromPtr(&object.stub_CreateFontIndirectA));
    try environment.addBuiltinExport(m, "CreateCompatibleBitmap", @intFromPtr(&object.stub_CreateCompatibleBitmap));
    try environment.addBuiltinExport(m, "CreateBitmap", @intFromPtr(&object.stub_CreateBitmap));
    try environment.addBuiltinExport(m, "CreateDIBSection", @intFromPtr(&object.stub_CreateDIBSection));
    try environment.addBuiltinExport(m, "GetObjectA", @intFromPtr(&object.stub_GetObjectA));
    try environment.addBuiltinExport(m, "GetCurrentObject", @intFromPtr(&object.stub_GetCurrentObject));
    try environment.addBuiltinExport(m, "LoadImageA", @intFromPtr(&object.stub_LoadImageA));

    // Device Context (dc.zig)
    try environment.addBuiltinExport(m, "GetDeviceCaps", @intFromPtr(&dc.stub_GetDeviceCaps));
    try environment.addBuiltinExport(m, "CreateCompatibleDC", @intFromPtr(&dc.stub_CreateCompatibleDC));
    try environment.addBuiltinExport(m, "DeleteDC", @intFromPtr(&dc.stub_DeleteDC));
    try environment.addBuiltinExport(m, "SaveDC", @intFromPtr(&dc.stub_SaveDC));
    try environment.addBuiltinExport(m, "RestoreDC", @intFromPtr(&dc.stub_RestoreDC));
    try environment.addBuiltinExport(m, "SetBkMode", @intFromPtr(&dc.stub_SetBkMode));
    try environment.addBuiltinExport(m, "SetBkColor", @intFromPtr(&dc.stub_SetBkColor));
    try environment.addBuiltinExport(m, "SetTextColor", @intFromPtr(&dc.stub_SetTextColor));
    try environment.addBuiltinExport(m, "GetTextColor", @intFromPtr(&dc.stub_GetTextColor));
    try environment.addBuiltinExport(m, "SetStretchBltMode", @intFromPtr(&dc.stub_SetStretchBltMode));
    try environment.addBuiltinExport(m, "SetMapMode", @intFromPtr(&dc.stub_SetMapMode));
    try environment.addBuiltinExport(m, "SetROP2", @intFromPtr(&dc.stub_SetROP2));
    try environment.addBuiltinExport(m, "GetTextMetricsA", @intFromPtr(&dc.stub_GetTextMetricsA));
    try environment.addBuiltinExport(m, "GetTextMetricsW", @intFromPtr(&dc.stub_GetTextMetricsW));
    try environment.addBuiltinExport(m, "GetTextExtentPoint32A", @intFromPtr(&dc.stub_GetTextExtentPoint32A));
    try environment.addBuiltinExport(m, "GetTextExtentPoint32W", @intFromPtr(&dc.stub_GetTextExtentPoint32W));
    try environment.addBuiltinExport(m, "SetTextAlign", @intFromPtr(&dc.stub_SetTextAlign));
    try environment.addBuiltinExport(m, "CreateDCA", @intFromPtr(&dc.stub_CreateDCA));
    try environment.addBuiltinExport(m, "GetNearestColor", @intFromPtr(&dc.stub_GetNearestColor));

    // Drawing & Blitting (drawing.zig)
    try environment.addBuiltinExport(m, "BitBlt", @intFromPtr(&drawing.stub_BitBlt));
    try environment.addBuiltinExport(m, "StretchBlt", @intFromPtr(&drawing.stub_StretchBlt));
    try environment.addBuiltinExport(m, "StretchDIBits", @intFromPtr(&drawing.stub_StretchDIBits));
    try environment.addBuiltinExport(m, "TextOutA", @intFromPtr(&drawing.stub_TextOutA));
    try environment.addBuiltinExport(m, "SetPixel", @intFromPtr(&drawing.stub_SetPixel));
    try environment.addBuiltinExport(m, "GetPixel", @intFromPtr(&drawing.stub_GetPixel));
    try environment.addBuiltinExport(m, "MoveToEx", @intFromPtr(&drawing.stub_MoveToEx));
    try environment.addBuiltinExport(m, "LineTo", @intFromPtr(&drawing.stub_LineTo));
    try environment.addBuiltinExport(m, "Rectangle", @intFromPtr(&drawing.stub_Rectangle));
    try environment.addBuiltinExport(m, "SetDIBitsToDevice", @intFromPtr(&drawing.stub_SetDIBitsToDevice));
    try environment.addBuiltinExport(m, "GetDIBits", @intFromPtr(&drawing.stub_GetDIBits));
    try environment.addBuiltinExport(m, "PatBlt", @intFromPtr(&drawing.stub_PatBlt));
    try environment.addBuiltinExport(m, "ExtTextOutA", @intFromPtr(&drawing.stub_ExtTextOutA));
    try environment.addBuiltinExport(m, "ExtTextOutW", @intFromPtr(&drawing.stub_ExtTextOutW));
    try environment.addBuiltinExport(m, "IntersectClipRect", @intFromPtr(&drawing.stub_IntersectClipRect));
    try environment.addBuiltinExport(m, "ExcludeClipRect", @intFromPtr(&drawing.stub_ExcludeClipRect));
    try environment.addBuiltinExport(m, "CombineRgn", @intFromPtr(&drawing.stub_CombineRgn));
    try environment.addBuiltinExport(m, "Ellipse", @intFromPtr(&drawing.stub_Ellipse));
    try environment.addBuiltinExport(m, "RoundRect", @intFromPtr(&drawing.stub_RoundRect));
    try environment.addBuiltinExport(m, "Polygon", @intFromPtr(&drawing.stub_Polygon));
    try environment.addBuiltinExport(m, "Polyline", @intFromPtr(&drawing.stub_Polyline));

    // Object Management - additional (object.zig)
    try environment.addBuiltinExport(m, "CreatePalette", @intFromPtr(&object.stub_CreatePalette));
    try environment.addBuiltinExport(m, "SelectPalette", @intFromPtr(&object.stub_SelectPalette));
    try environment.addBuiltinExport(m, "RealizePalette", @intFromPtr(&object.stub_RealizePalette));
    try environment.addBuiltinExport(m, "CreateRectRgn", @intFromPtr(&object.stub_CreateRectRgn));
    try environment.addBuiltinExport(m, "CreateBrushIndirect", @intFromPtr(&object.stub_CreateBrushIndirect));
    try environment.addBuiltinExport(m, "CreatePenIndirect", @intFromPtr(&object.stub_CreatePenIndirect));
    try environment.addBuiltinExport(m, "CreateFontA", @intFromPtr(&object.stub_CreateFontA));
    try environment.addBuiltinExport(m, "SetPaletteEntries", @intFromPtr(&object.stub_SetPaletteEntries));
    try environment.addBuiltinExport(m, "UnrealizeObject", @intFromPtr(&object.stub_UnrealizeObject));

    // DC-related additions
    try environment.addBuiltinExport(m, "UpdateColors", @intFromPtr(&dc.stub_UpdateColors));
    try environment.addBuiltinExport(m, "GetTextExtentExPointA", @intFromPtr(&dc.stub_GetTextExtentExPointA));
    try environment.addBuiltinExport(m, "GetCharacterPlacementW", @intFromPtr(&dc.stub_GetCharacterPlacementW));
    try environment.addBuiltinExport(m, "TranslateCharsetInfo", @intFromPtr(&dc.stub_TranslateCharsetInfo));
    try environment.addBuiltinExport(m, "GetCharWidthA", @intFromPtr(&dc.stub_GetCharWidthA));
    try environment.addBuiltinExport(m, "GetCharWidth32A", @intFromPtr(&dc.stub_GetCharWidthA));
    try environment.addBuiltinExport(m, "GetCharWidthW", @intFromPtr(&dc.stub_GetCharWidthA));
    try environment.addBuiltinExport(m, "GetCharWidth32W", @intFromPtr(&dc.stub_GetCharWidthA));

    // Wide (W) variants for Unicode apps
    try environment.addBuiltinExport(m, "TextOutW", @intFromPtr(&drawing.stub_TextOutW));
    try environment.addBuiltinExport(m, "StartDocW", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "SetAbortProc", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "StartPage", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "EndPage", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "EndDoc", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "SetWindowExtEx", @intFromPtr(&dc.stub_SetWindowExtEx));
    try environment.addBuiltinExport(m, "SetViewportExtEx", @intFromPtr(&dc.stub_SetViewportExtEx));
    try environment.addBuiltinExport(m, "CreateFontIndirectW", @intFromPtr(&object.stub_CreateFontIndirectA));
    try environment.addBuiltinExport(m, "LPtoDP", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "CreateDCW", @intFromPtr(&dc.stub_CreateDCA));
    try environment.addBuiltinExport(m, "GetObjectW", @intFromPtr(&object.stub_GetObjectA));
    try environment.addBuiltinExport(m, "EnumFontsW", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "GetTextFaceW", @intFromPtr(&stub_ret0_3));

    // --- Remaining GDI32 stubs for 100% win2k coverage ---
    try environment.addBuiltinExport(m, "SetBrushOrgEx", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "RectVisible", @intFromPtr(&stub_RectVisible));
    try environment.addBuiltinExport(m, "GetPaletteEntries", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "GetTextExtentPointW", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "CreateICW", @intFromPtr(&dc.stub_CreateDCA));
    try environment.addBuiltinExport(m, "PtVisible", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "CreateDIBitmap", @intFromPtr(&stub_ret0_6));
    try environment.addBuiltinExport(m, "PlayMetaFile", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "SetRectRgn", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "FillRgn", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "Escape", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "EnumFontFamiliesExW", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "EnumFontFamiliesW", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "SetWindowOrgEx", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "SetEnhMetaFileBits", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "EnumMetaFile", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "PlayMetaFileRecord", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "PlayEnhMetaFile", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "SetViewportOrgEx", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "GetEnhMetaFileHeader", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "GetBitmapBits", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "GetEnhMetaFileBits", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "GetMetaFileBitsEx", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "DeleteEnhMetaFile", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "GetTextExtentPointA", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "SetMetaFileBitsEx", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "CreateBitmapIndirect", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "SetBitmapDimensionEx", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "CreatePolygonRgn", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "ExtFloodFill", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "OffsetRgn", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "CreateHalftonePalette", @intFromPtr(&stub_CreateHalfonePalette));
    try environment.addBuiltinExport(m, "GetDIBColorTable", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "SetDIBColorTable", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "CreatePatternBrush", @intFromPtr(&stub_CreateFakeBrush));
    try environment.addBuiltinExport(m, "GetNearestPaletteIndex", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "ResizePalette", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "SetDIBits", @intFromPtr(&stub_ret0_6));
    try environment.addBuiltinExport(m, "CreateRectRgnIndirect", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "GetBkMode", @intFromPtr(&stub_GetBkMode));
    try environment.addBuiltinExport(m, "PolyBezier", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "LineDDA", @intFromPtr(&stub_ret0_6));
    try environment.addBuiltinExport(m, "GetLayout", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "SetLayout", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "DPtoLP", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "ScaleWindowExtEx", @intFromPtr(&stub_ret0_6));
    try environment.addBuiltinExport(m, "GetBkColor", @intFromPtr(&stub_GetBkColor));
}

fn stub_ret0_1(a: usize) callconv(.winapi) i32 {
    _ = a;
    return 0;
}
fn stub_ret0_2(a: usize, b: usize) callconv(.winapi) i32 {
    _ = a; _ = b;
    return 0;
}
fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(.winapi) i32 {
    _ = a; _ = b; _ = c;
    return 0;
}
fn stub_ret0_4(a: usize, b: usize, c: usize, d: usize) callconv(.winapi) i32 {
    _ = a; _ = b; _ = c; _ = d;
    return 0;
}
fn stub_ret0_5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(.winapi) i32 {
    _ = a; _ = b; _ = c; _ = d; _ = e;
    return 0;
}
fn stub_ret0_6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(.winapi) i32 {
    _ = a; _ = b; _ = c; _ = d; _ = e; _ = f;
    return 0;
}

// =============================================================================
// Faithful implementations — Tier 4
// =============================================================================

const trace = @import("../trace.zig");

var next_fake_gdi_handle: usize = 0xBB000001;
fn alloc_fake_handle() usize {
    const h = next_fake_gdi_handle;
    next_fake_gdi_handle +%= 1;
    return h;
}

// RectVisible: is any part of the given rect visible in the clip region?
// Always return TRUE since we don't track clipping
fn stub_RectVisible(hdc: usize, lprc: usize) callconv(.winapi) i32 {
    _ = hdc; _ = lprc;
    return 1; // TRUE — rect is visible
}

// GetBkMode: returns background mix mode
// OPAQUE = 2, TRANSPARENT = 1
fn stub_GetBkMode(hdc: usize) callconv(.winapi) i32 {
    _ = hdc;
    return 2; // OPAQUE
}

// GetBkColor: returns background color as COLORREF
// Default is white
fn stub_GetBkColor(hdc: usize) callconv(.winapi) u32 {
    _ = hdc;
    return 0x00FFFFFF; // RGB(255, 255, 255) = white
}

// CreateHalftonePalette: creates a halftone palette for a DC
fn stub_CreateHalfonePalette(hdc: usize) callconv(.winapi) usize {
    _ = hdc;
    const h = alloc_fake_handle();
    if (trace.enable_tracing) trace.print("GDI32: CreateHalftonePalette -> 0x{x}\n", .{h});
    return h;
}

// CreatePatternBrush: creates a brush based on a bitmap pattern
fn stub_CreateFakeBrush(hBitmap: usize) callconv(.winapi) usize {
    _ = hBitmap;
    const h = alloc_fake_handle();
    if (trace.enable_tracing) trace.print("GDI32: CreatePatternBrush -> 0x{x}\n", .{h});
    return h;
}

// =============================================================================
// Tests
// =============================================================================

test "GetBkMode returns OPAQUE" {
    try @import("std").testing.expectEqual(@as(i32, 2), stub_GetBkMode(0));
}

test "GetBkColor returns white" {
    try @import("std").testing.expectEqual(@as(u32, 0x00FFFFFF), stub_GetBkColor(0));
}

test "RectVisible returns TRUE" {
    try @import("std").testing.expectEqual(@as(i32, 1), stub_RectVisible(0, 0));
}

test "CreateHalftonePalette returns non-zero" {
    try @import("std").testing.expect(stub_CreateHalfonePalette(0) != 0);
}
