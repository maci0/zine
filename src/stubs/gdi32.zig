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
    const stub = @import("stub_common.zig");

    // Object Management (object.zig)
    try environment.addBuiltinExportComptime(m, "GetStockObject", object.stub_GetStockObject);
    try environment.addBuiltinExportComptime(m, "SelectObject", object.stub_SelectObject);
    try environment.addBuiltinExportComptime(m, "DeleteObject", object.stub_DeleteObject);
    try environment.addBuiltinExportComptime(m, "CreateSolidBrush", object.stub_CreateSolidBrush);
    try environment.addBuiltinExportComptime(m, "CreatePen", object.stub_CreatePen);
    try environment.addBuiltinExportComptime(m, "CreateFontIndirectA", object.stub_CreateFontIndirectA);
    try environment.addBuiltinExportComptime(m, "CreateCompatibleBitmap", object.stub_CreateCompatibleBitmap);
    try environment.addBuiltinExportComptime(m, "CreateBitmap", object.stub_CreateBitmap);
    try environment.addBuiltinExportComptime(m, "CreateDIBSection", object.stub_CreateDIBSection);
    try environment.addBuiltinExportComptime(m, "GetObjectA", object.stub_GetObjectA);
    try environment.addBuiltinExportComptime(m, "GetCurrentObject", object.stub_GetCurrentObject);
    try environment.addBuiltinExportComptime(m, "LoadImageA", object.stub_LoadImageA);
    try environment.addBuiltinExportComptime(m, "CreatePalette", object.stub_CreatePalette);
    try environment.addBuiltinExportComptime(m, "SelectPalette", object.stub_SelectPalette);
    try environment.addBuiltinExportComptime(m, "RealizePalette", object.stub_RealizePalette);
    try environment.addBuiltinExportComptime(m, "CreateRectRgn", object.stub_CreateRectRgn);
    try environment.addBuiltinExportComptime(m, "CreateBrushIndirect", object.stub_CreateBrushIndirect);
    try environment.addBuiltinExportComptime(m, "CreatePenIndirect", object.stub_CreatePenIndirect);
    try environment.addBuiltinExportComptime(m, "CreateFontA", object.stub_CreateFontA);
    try environment.addBuiltinExportComptime(m, "SetPaletteEntries", object.stub_SetPaletteEntries);
    try environment.addBuiltinExportComptime(m, "UnrealizeObject", object.stub_UnrealizeObject);
    try environment.addBuiltinExportComptime(m, "CreateHalftonePalette", object.stub_CreateHalftonePalette);
    try environment.addBuiltinExportComptime(m, "CreatePatternBrush", object.stub_CreatePatternBrush);
    try environment.addBuiltinExportComptime(m, "CreateFontIndirectW", object.stub_CreateFontIndirectA);
    try environment.addBuiltinExportComptime(m, "GetObjectW", object.stub_GetObjectA);

    // Device Context (dc.zig)
    try environment.addBuiltinExportComptime(m, "GetDeviceCaps", dc.stub_GetDeviceCaps);
    try environment.addBuiltinExportComptime(m, "CreateCompatibleDC", dc.stub_CreateCompatibleDC);
    try environment.addBuiltinExportComptime(m, "DeleteDC", dc.stub_DeleteDC);
    try environment.addBuiltinExportComptime(m, "SaveDC", dc.stub_SaveDC);
    try environment.addBuiltinExportComptime(m, "RestoreDC", dc.stub_RestoreDC);
    try environment.addBuiltinExportComptime(m, "SetBkMode", dc.stub_SetBkMode);
    try environment.addBuiltinExportComptime(m, "SetBkColor", dc.stub_SetBkColor);
    try environment.addBuiltinExportComptime(m, "SetTextColor", dc.stub_SetTextColor);
    try environment.addBuiltinExportComptime(m, "GetTextColor", dc.stub_GetTextColor);
    try environment.addBuiltinExportComptime(m, "SetStretchBltMode", dc.stub_SetStretchBltMode);
    try environment.addBuiltinExportComptime(m, "SetMapMode", dc.stub_SetMapMode);
    try environment.addBuiltinExportComptime(m, "SetROP2", dc.stub_SetROP2);
    try environment.addBuiltinExportComptime(m, "GetTextMetricsA", dc.stub_GetTextMetricsA);
    try environment.addBuiltinExportComptime(m, "GetTextMetricsW", dc.stub_GetTextMetricsW);
    try environment.addBuiltinExportComptime(m, "GetTextExtentPoint32A", dc.stub_GetTextExtentPoint32A);
    try environment.addBuiltinExportComptime(m, "GetTextExtentPoint32W", dc.stub_GetTextExtentPoint32W);
    try environment.addBuiltinExportComptime(m, "SetTextAlign", dc.stub_SetTextAlign);
    try environment.addBuiltinExportComptime(m, "CreateDCA", dc.stub_CreateDCA);
    try environment.addBuiltinExportComptime(m, "GetNearestColor", dc.stub_GetNearestColor);
    try environment.addBuiltinExportComptime(m, "UpdateColors", dc.stub_UpdateColors);
    try environment.addBuiltinExportComptime(m, "GetTextExtentExPointA", dc.stub_GetTextExtentExPointA);
    try environment.addBuiltinExportComptime(m, "GetCharacterPlacementW", dc.stub_GetCharacterPlacementW);
    try environment.addBuiltinExportComptime(m, "TranslateCharsetInfo", dc.stub_TranslateCharsetInfo);
    try environment.addBuiltinExportComptime(m, "GetCharWidthA", dc.stub_GetCharWidthA);
    try environment.addBuiltinExportComptime(m, "GetCharWidth32A", dc.stub_GetCharWidthA);
    try environment.addBuiltinExportComptime(m, "GetCharWidthW", dc.stub_GetCharWidthA);
    try environment.addBuiltinExportComptime(m, "GetCharWidth32W", dc.stub_GetCharWidthA);
    try environment.addBuiltinExportComptime(m, "SetWindowExtEx", dc.stub_SetWindowExtEx);
    try environment.addBuiltinExportComptime(m, "SetViewportExtEx", dc.stub_SetViewportExtEx);
    try environment.addBuiltinExportComptime(m, "RectVisible", dc.stub_RectVisible);
    try environment.addBuiltinExportComptime(m, "GetBkMode", dc.stub_GetBkMode);
    try environment.addBuiltinExportComptime(m, "GetBkColor", dc.stub_GetBkColor);
    try environment.addBuiltinExportComptime(m, "CreateDCW", dc.stub_CreateDCA);
    try environment.addBuiltinExportComptime(m, "CreateICW", dc.stub_CreateDCA);

    // Drawing & Blitting (drawing.zig)
    try environment.addBuiltinExportComptime(m, "BitBlt", drawing.stub_BitBlt);
    try environment.addBuiltinExportComptime(m, "StretchBlt", drawing.stub_StretchBlt);
    try environment.addBuiltinExportComptime(m, "StretchDIBits", drawing.stub_StretchDIBits);
    try environment.addBuiltinExportComptime(m, "TextOutA", drawing.stub_TextOutA);
    try environment.addBuiltinExportComptime(m, "TextOutW", drawing.stub_TextOutW);
    try environment.addBuiltinExportComptime(m, "SetPixel", drawing.stub_SetPixel);
    try environment.addBuiltinExportComptime(m, "GetPixel", drawing.stub_GetPixel);
    try environment.addBuiltinExportComptime(m, "MoveToEx", drawing.stub_MoveToEx);
    try environment.addBuiltinExportComptime(m, "LineTo", drawing.stub_LineTo);
    try environment.addBuiltinExportComptime(m, "Rectangle", drawing.stub_Rectangle);
    try environment.addBuiltinExportComptime(m, "SetDIBitsToDevice", drawing.stub_SetDIBitsToDevice);
    try environment.addBuiltinExportComptime(m, "GetDIBits", drawing.stub_GetDIBits);
    try environment.addBuiltinExportComptime(m, "PatBlt", drawing.stub_PatBlt);
    try environment.addBuiltinExportComptime(m, "ExtTextOutA", drawing.stub_ExtTextOutA);
    try environment.addBuiltinExportComptime(m, "ExtTextOutW", drawing.stub_ExtTextOutW);
    try environment.addBuiltinExportComptime(m, "IntersectClipRect", drawing.stub_IntersectClipRect);
    try environment.addBuiltinExportComptime(m, "ExcludeClipRect", drawing.stub_ExcludeClipRect);
    try environment.addBuiltinExportComptime(m, "CombineRgn", drawing.stub_CombineRgn);
    try environment.addBuiltinExportComptime(m, "Ellipse", drawing.stub_Ellipse);
    try environment.addBuiltinExportComptime(m, "RoundRect", drawing.stub_RoundRect);
    try environment.addBuiltinExportComptime(m, "Polygon", drawing.stub_Polygon);
    try environment.addBuiltinExportComptime(m, "Polyline", drawing.stub_Polyline);

    // Generic stubs for unimplemented GDI32 functions
    try environment.addBuiltinExportComptime(m, "StartDocW", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "SetAbortProc", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "StartPage", stub.stub_args1);
    try environment.addBuiltinExportComptime(m, "EndPage", stub.stub_args1);
    try environment.addBuiltinExportComptime(m, "EndDoc", stub.stub_args1);
    try environment.addBuiltinExportComptime(m, "LPtoDP", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "EnumFontsW", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "GetTextFaceW", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "SetBrushOrgEx", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "GetPaletteEntries", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "GetTextExtentPointW", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "PtVisible", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "CreateDIBitmap", stub.stub_args6);
    try environment.addBuiltinExportComptime(m, "PlayMetaFile", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "SetRectRgn", stub.stub_args5);
    try environment.addBuiltinExportComptime(m, "FillRgn", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "Escape", stub.stub_args5);
    try environment.addBuiltinExportComptime(m, "EnumFontFamiliesExW", stub.stub_args5);
    try environment.addBuiltinExportComptime(m, "EnumFontFamiliesW", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "SetWindowOrgEx", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "SetEnhMetaFileBits", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "EnumMetaFile", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "PlayMetaFileRecord", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "PlayEnhMetaFile", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "SetViewportOrgEx", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "GetEnhMetaFileHeader", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "GetBitmapBits", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "GetEnhMetaFileBits", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "GetMetaFileBitsEx", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "DeleteEnhMetaFile", stub.stub_args1);
    try environment.addBuiltinExportComptime(m, "GetTextExtentPointA", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "SetMetaFileBitsEx", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "CreateBitmapIndirect", stub.stub_args1);
    try environment.addBuiltinExportComptime(m, "SetBitmapDimensionEx", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "CreatePolygonRgn", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "ExtFloodFill", stub.stub_args5);
    try environment.addBuiltinExportComptime(m, "OffsetRgn", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "GetDIBColorTable", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "SetDIBColorTable", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "GetNearestPaletteIndex", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "ResizePalette", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "SetDIBits", stub.stub_args6);
    try environment.addBuiltinExportComptime(m, "CreateRectRgnIndirect", stub.stub_args1);
    try environment.addBuiltinExportComptime(m, "PolyBezier", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "LineDDA", stub.stub_args6);
    try environment.addBuiltinExportComptime(m, "GetLayout", stub.stub_args1);
    try environment.addBuiltinExportComptime(m, "SetLayout", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "DPtoLP", stub.stub_args3);
    try environment.addBuiltinExportComptime(m, "ScaleWindowExtEx", stub.stub_args6);
}
