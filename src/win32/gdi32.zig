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

// --- Object Tracking ---

pub const ObjectType = enum {
    Bitmap,
    Brush,
    Pen,
    Font,
    Palette,
    Region,
};

pub const BrushData = struct {
    color: u32,
    style: i32, // 0 = solid
};

pub const PenData = struct {
    color: u32,
    width: i32,
    style: i32,
};

pub const GdiObject = struct {
    handle: usize,
    obj_type: ObjectType,
    data: union {
        bitmap: DibInfo,
        brush: BrushData,
        pen: PenData,
        none: void,
    },
};

pub var gdi_objects: [512]GdiObject = [_]GdiObject{.{ .handle = 0, .obj_type = .Bitmap, .data = .{ .none = {} } }} ** 512;
pub var gdi_object_count: usize = 0;

pub fn registerObject(obj: GdiObject) void {
    if (gdi_object_count < gdi_objects.len) {
        gdi_objects[gdi_object_count] = obj;
        gdi_object_count += 1;
    }
}

pub fn findObject(handle: usize) ?*const GdiObject {
    for (gdi_objects[0..gdi_object_count]) |*obj| {
        if (obj.handle == handle) return obj;
    }
    return null;
}

pub fn registerDib(handle: usize, buffer: usize, width: u32, height: u32, bpp: u16) void {
    registerObject(.{
        .handle = handle,
        .obj_type = .Bitmap,
        .data = .{ .bitmap = .{
            .handle = handle,
            .buffer = buffer,
            .width = width,
            .height = height,
            .bpp = bpp,
        } },
    });
}

pub fn findDib(handle: usize) ?*const DibInfo {
    if (findObject(handle)) |obj| {
        if (obj.obj_type == .Bitmap) {
            return &obj.data.bitmap;
        }
    }
    return null;
}

// --- Device Context Tracking ---

pub const DeviceContext = struct {
    handle: usize,
    bitmap: usize, // Selected bitmap handle
    brush: usize,  // Selected brush handle
    pen: usize,    // Selected pen handle
    font: usize,   // Selected font handle
    bk_mode: i32,  // 1 = TRANSPARENT, 2 = OPAQUE
    bk_color: u32,
    text_color: u32,
    rop2: i32,     // R2_COPYPEN = 13 (default)
    stretch_mode: i32, // BLACKONWHITE = 1 (default)
    text_align: u32,   // TA_LEFT | TA_TOP = 0 (default)
    map_mode: i32,     // MM_TEXT = 1 (default)
};

pub var dc_entries: [128]DeviceContext = [_]DeviceContext{.{
    .handle = 0,
    .bitmap = 0,
    .brush = 0,
    .pen = 0,
    .font = 0,
    .bk_mode = 2,
    .bk_color = 0x00FFFFFF,
    .text_color = 0x00000000,
    .rop2 = 13,
    .stretch_mode = 1,
    .text_align = 0,
    .map_mode = 1,
}} ** 128;
pub var dc_count: usize = 0;

pub fn getDc(handle: usize) ?*DeviceContext {
    for (dc_entries[0..dc_count]) |*dc_entry| {
        if (dc_entry.handle == handle) return dc_entry;
    }
    return null;
}

pub fn registerDc(handle: usize) void {
    if (dc_count < dc_entries.len) {
        dc_entries[dc_count] = .{
            .handle = handle,
            .bitmap = 0,
            .brush = 0,
            .pen = 0,
            .font = 0,
            .bk_mode = 2,
            .bk_color = 0x00FFFFFF,
            .text_color = 0x00000000,
            .rop2 = 13,
            .stretch_mode = 1,
            .text_align = 0,
            .map_mode = 1,
        };
        dc_count += 1;
    }
}

pub fn bindDcBitmap(dc_handle: usize, bmp_handle: usize) void {
    if (getDc(dc_handle)) |dc_entry| {
        dc_entry.bitmap = bmp_handle;
    }
}

pub fn getDcDib(dc_handle: usize) ?*const DibInfo {
    if (getDc(dc_handle)) |dc_entry| {
        return findDib(dc_entry.bitmap);
    }
    return null;
}

pub fn register(environment: *env.Environment) !void {
    const m = "GDI32.dll";
    const stub = @import("stub_common.zig");

    // Object Management (object.zig)
    try environment.addBuiltinExportComptime(m, "GetStockObject", object.GetStockObject);
    try environment.addBuiltinExportComptime(m, "SelectObject", object.SelectObject);
    try environment.addBuiltinExportComptime(m, "DeleteObject", object.stub_DeleteObject);
    try environment.addBuiltinExportComptime(m, "CreateSolidBrush", object.CreateSolidBrush);
    try environment.addBuiltinExportComptime(m, "CreatePen", object.CreatePen);
    try environment.addBuiltinExportComptime(m, "CreateFontIndirectA", object.CreateFontIndirectA);
    try environment.addBuiltinExportComptime(m, "CreateCompatibleBitmap", object.CreateCompatibleBitmap);
    try environment.addBuiltinExportComptime(m, "CreateBitmap", object.stub_CreateBitmap);
    try environment.addBuiltinExportComptime(m, "CreateDIBSection", object.CreateDIBSection);
    try environment.addBuiltinExportComptime(m, "GetObjectA", object.GetObjectA);
    try environment.addBuiltinExportComptime(m, "GetCurrentObject", object.GetCurrentObject);
    try environment.addBuiltinExportComptime(m, "LoadImageA", object.stub_LoadImageA);
    try environment.addBuiltinExportComptime(m, "CreatePalette", object.stub_CreatePalette);
    try environment.addBuiltinExportComptime(m, "SelectPalette", object.stub_SelectPalette);
    try environment.addBuiltinExportComptime(m, "RealizePalette", object.stub_RealizePalette);
    try environment.addBuiltinExportComptime(m, "CreateRectRgn", object.stub_CreateRectRgn);
    try environment.addBuiltinExportComptime(m, "CreateBrushIndirect", object.CreateBrushIndirect);
    try environment.addBuiltinExportComptime(m, "CreatePenIndirect", object.CreatePenIndirect);
    try environment.addBuiltinExportComptime(m, "CreateFontA", object.CreateFontA);
    try environment.addBuiltinExportComptime(m, "SetPaletteEntries", object.stub_SetPaletteEntries);
    try environment.addBuiltinExportComptime(m, "UnrealizeObject", object.stub_UnrealizeObject);
    try environment.addBuiltinExportComptime(m, "CreateHalftonePalette", object.CreateHalftonePalette);
    try environment.addBuiltinExportComptime(m, "CreatePatternBrush", object.CreatePatternBrush);
    try environment.addBuiltinExportComptime(m, "CreateFontIndirectW", object.CreateFontIndirectA);
    try environment.addBuiltinExportComptime(m, "GetObjectW", object.GetObjectA);

    // Device Context (dc.zig)
    try environment.addBuiltinExportComptime(m, "GetDeviceCaps", dc.GetDeviceCaps);
    try environment.addBuiltinExportComptime(m, "CreateCompatibleDC", dc.CreateCompatibleDC);
    try environment.addBuiltinExportComptime(m, "DeleteDC", dc.stub_DeleteDC);
    try environment.addBuiltinExportComptime(m, "SaveDC", dc.SaveDC);
    try environment.addBuiltinExportComptime(m, "RestoreDC", dc.RestoreDC);
    try environment.addBuiltinExportComptime(m, "SetBkMode", dc.SetBkMode);
    try environment.addBuiltinExportComptime(m, "SetBkColor", dc.SetBkColor);
    try environment.addBuiltinExportComptime(m, "SetTextColor", dc.SetTextColor);
    try environment.addBuiltinExportComptime(m, "GetTextColor", dc.GetTextColor);
    try environment.addBuiltinExportComptime(m, "SetStretchBltMode", dc.SetStretchBltMode);
    try environment.addBuiltinExportComptime(m, "SetMapMode", dc.SetMapMode);
    try environment.addBuiltinExportComptime(m, "SetROP2", dc.SetROP2);
    try environment.addBuiltinExportComptime(m, "GetTextMetricsA", dc.GetTextMetricsA);
    try environment.addBuiltinExportComptime(m, "GetTextMetricsW", dc.GetTextMetricsW);
    try environment.addBuiltinExportComptime(m, "GetTextExtentPoint32A", dc.GetTextExtentPoint32A);
    try environment.addBuiltinExportComptime(m, "GetTextExtentPoint32W", dc.GetTextExtentPoint32W);
    try environment.addBuiltinExportComptime(m, "SetTextAlign", dc.SetTextAlign);
    try environment.addBuiltinExportComptime(m, "CreateDCA", dc.CreateDCA);
    try environment.addBuiltinExportComptime(m, "GetNearestColor", dc.stub_GetNearestColor);
    try environment.addBuiltinExportComptime(m, "UpdateColors", dc.stub_UpdateColors);
    try environment.addBuiltinExportComptime(m, "GetTextExtentExPointA", dc.GetTextExtentExPointA);
    try environment.addBuiltinExportComptime(m, "GetCharacterPlacementW", dc.stub_GetCharacterPlacementW);
    try environment.addBuiltinExportComptime(m, "TranslateCharsetInfo", dc.stub_TranslateCharsetInfo);
    try environment.addBuiltinExportComptime(m, "GetCharWidthA", dc.GetCharWidthA);
    try environment.addBuiltinExportComptime(m, "GetCharWidth32A", dc.GetCharWidthA);
    try environment.addBuiltinExportComptime(m, "GetCharWidthW", dc.GetCharWidthA);
    try environment.addBuiltinExportComptime(m, "GetCharWidth32W", dc.GetCharWidthA);
    try environment.addBuiltinExportComptime(m, "SetWindowExtEx", dc.SetWindowExtEx);
    try environment.addBuiltinExportComptime(m, "SetViewportExtEx", dc.SetViewportExtEx);
    try environment.addBuiltinExportComptime(m, "RectVisible", dc.stub_RectVisible);
    try environment.addBuiltinExportComptime(m, "GetBkMode", dc.GetBkMode);
    try environment.addBuiltinExportComptime(m, "GetBkColor", dc.GetBkColor);
    try environment.addBuiltinExportComptime(m, "CreateDCW", dc.CreateDCA);
    try environment.addBuiltinExportComptime(m, "CreateICW", dc.CreateDCA);

    // Drawing & Blitting (drawing.zig)
    try environment.addBuiltinExportComptime(m, "BitBlt", drawing.BitBlt);
    try environment.addBuiltinExportComptime(m, "StretchBlt", drawing.StretchBlt);
    try environment.addBuiltinExportComptime(m, "StretchDIBits", drawing.StretchDIBits);
    try environment.addBuiltinExportComptime(m, "TextOutA", drawing.TextOutA);
    try environment.addBuiltinExportComptime(m, "TextOutW", drawing.TextOutW);
    try environment.addBuiltinExportComptime(m, "SetPixel", drawing.SetPixel);
    try environment.addBuiltinExportComptime(m, "GetPixel", drawing.GetPixel);
    try environment.addBuiltinExportComptime(m, "MoveToEx", drawing.MoveToEx);
    try environment.addBuiltinExportComptime(m, "LineTo", drawing.LineTo);
    try environment.addBuiltinExportComptime(m, "Rectangle", drawing.Rectangle);
    try environment.addBuiltinExportComptime(m, "SetDIBitsToDevice", drawing.SetDIBitsToDevice);
    try environment.addBuiltinExportComptime(m, "GetDIBits", drawing.stub_GetDIBits);
    try environment.addBuiltinExportComptime(m, "PatBlt", drawing.PatBlt);
    try environment.addBuiltinExportComptime(m, "ExtTextOutA", drawing.stub_ExtTextOutA);
    try environment.addBuiltinExportComptime(m, "ExtTextOutW", drawing.stub_ExtTextOutW);
    try environment.addBuiltinExportComptime(m, "IntersectClipRect", drawing.stub_IntersectClipRect);
    try environment.addBuiltinExportComptime(m, "ExcludeClipRect", drawing.stub_ExcludeClipRect);
    try environment.addBuiltinExportComptime(m, "CombineRgn", drawing.stub_CombineRgn);
    try environment.addBuiltinExportComptime(m, "Ellipse", drawing.Ellipse);
    try environment.addBuiltinExportComptime(m, "RoundRect", drawing.RoundRect);
    try environment.addBuiltinExportComptime(m, "Polygon", drawing.Polygon);
    try environment.addBuiltinExportComptime(m, "Polyline", drawing.Polyline);

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

    // --- Notepad2 GDI32 stubs ---
    try environment.addBuiltinExportComptime(m, "GetTextExtentExPointW", dc.GetTextExtentExPointA);
    try environment.addBuiltinExportComptime(m, "CreateFontW", object.CreateFontA);

    // --- hgb.exe GDI32 stubs ---
    try environment.addBuiltinExportComptime(m, "GetWindowOrgEx", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "GetSystemPaletteEntries", stub.stub_args4);
    try environment.addBuiltinExportComptime(m, "GetCurrentPositionEx", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "EnumFontsA", stub.stub_args4);
}
