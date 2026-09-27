//! GDI32.dll function stubs and graphics object management.
//!
//! This module provides the registration logic for GDI32 API stubs
//! and maintains global state for GDI objects (bitmaps, brushes, pens)
//! and device contexts.

const std = @import("std");
const env = @import("../loader/env.zig");

const object = @import("gdi32/object.zig");
const dc = @import("gdi32/dc.zig");
const drawing = @import("gdi32/drawing.zig");

/// Shared handle counter for GDI objects.
var next_gdi_handle: u32 = 0xA0000001;

/// Allocates a new unique GDI handle.
pub fn nextHandle() usize {
    const h = next_gdi_handle;
    next_gdi_handle +%= 1;
    return h;
}

/// Tracks pixel buffers returned by CreateDIBSection so that BitBlt can
/// look up the source bitmap's pixel data.
pub const DibInfo = struct {
    /// GDI bitmap handle.
    handle: usize,
    /// ppvBits pointer (pixel data) in host memory.
    buffer: usize,
    /// Width of the bitmap in pixels.
    width: u32,
    /// Height of the bitmap in pixels.
    height: u32,
    /// Bits per pixel (e.g., 24, 32).
    bpp: u16,
    /// Exact length of the allocation at `buffer`. Only meaningful together
    /// with `owned`; needed to free the right span.
    alloc_len: usize = 0,
    /// True when zine allocated the pixel buffer (CreateCompatibleBitmap /
    /// CreateDIBSection) and DeleteObject must release it. Registrations of
    /// caller-owned buffers (tests, stack scratch) leave this false.
    owned: bool = false,
};

/// Type identifiers for GDI objects.
pub const ObjectType = enum {
    Bitmap,
    Brush,
    Pen,
    Font,
    Palette,
    Region,
};

/// Data for solid or styled brushes.
pub const BrushData = struct {
    /// RGB color value.
    color: u32,
    /// Brush style (0 = solid).
    style: i32,
};

/// Data for solid or styled pens.
pub const PenData = struct {
    /// RGB color value.
    color: u32,
    /// Width of the pen in pixels.
    width: i32,
    /// Pen style (e.g., solid, dashed).
    style: i32,
};

/// Data for logical fonts (from LOGFONT / CreateFont parameters).
pub const FontData = struct {
    /// Font height in logical units (negative = character height, positive = cell height).
    height: i32 = 13,
    /// Average character width (0 = system default derived from height).
    width: i32 = 0,
    /// Font weight (400 = FW_NORMAL, 700 = FW_BOLD).
    weight: i32 = 400,
    /// Character set (0 = ANSI_CHARSET).
    charset: u32 = 0,
    /// Italic flag.
    italic: bool = false,
    /// Face name (up to 31 chars + null).
    face_name: [32]u8 = [_]u8{0} ** 32,
    face_len: u8 = 0,

    /// Derive tmHeight from the font height parameter.
    /// Win32 convention: negative = character height, positive = cell height.
    pub fn tmHeight(self: FontData) i32 {
        const h = if (self.height < 0) -self.height else if (self.height > 0) self.height else 13;
        return @max(h, 1);
    }

    /// Derive average character width proportional to height.
    /// MS Sans Serif at 13px height has aveCharWidth=6, roughly height * 0.46.
    pub fn aveCharWidth(self: FontData) i32 {
        if (self.width > 0) return self.width;
        const h = self.tmHeight();
        return @max(@divTrunc(h * 46, 100), 1);
    }
};

/// A generic GDI object container.
pub const GdiObject = struct {
    /// Unique handle.
    handle: usize,
    /// Type of the object.
    obj_type: ObjectType,
    /// Object-specific data.
    data: union {
        bitmap: DibInfo,
        brush: BrushData,
        pen: PenData,
        font: FontData,
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

/// Removes an object from the table (DeleteObject). Swap-remove keeps the
/// array compact so create/delete cycles don't exhaust the 512 slots.
pub fn unregisterObject(handle: usize) bool {
    for (gdi_objects[0..gdi_object_count], 0..) |*obj, i| {
        if (obj.handle == handle) {
            gdi_objects[i] = gdi_objects[gdi_object_count - 1];
            gdi_objects[gdi_object_count - 1] = .{ .handle = 0, .obj_type = .Bitmap, .data = .{ .none = {} } };
            gdi_object_count -= 1;
            return true;
        }
    }
    return false;
}

/// Registers a bitmap in the object table. `owned` marks pixel buffers that
/// DeleteObject must free (see DibInfo.owned). Returns false when the table
/// is full so callers can release their buffer instead of leaking it.
pub fn registerDib(handle: usize, buffer: usize, width: u32, height: u32, bpp: u16, alloc_len: usize, owned: bool) bool {
    if (gdi_object_count >= gdi_objects.len) return false;
    registerObject(.{
        .handle = handle,
        .obj_type = .Bitmap,
        .data = .{ .bitmap = .{
            .handle = handle,
            .buffer = buffer,
            .width = width,
            .height = height,
            .bpp = bpp,
            .alloc_len = alloc_len,
            .owned = owned,
        } },
    });
    return true;
}

pub fn findDib(handle: usize) ?*const DibInfo {
    if (findObject(handle)) |obj| {
        if (obj.obj_type == .Bitmap) {
            return &obj.data.bitmap;
        }
    }
    return null;
}

/// Bytes a blit may touch in this DIB's pixel buffer. A registered bitmap
/// allocated by zine carries its exact length, and a DIB narrower than 32 bits
/// per pixel stores fewer bytes than `width * height * 4` claims, so the
/// allocation is the bound. A caller-registered buffer (no recorded length) is
/// a 32bpp scratch of the declared size.
pub fn dibPixelLen(dib: *const DibInfo) usize {
    // u128 for the product: guest dimensions close to u32 max would wrap u64.
    const declared: u128 = @as(u128, dib.width) * dib.height * 4;
    const ceiling: u128 = std.math.maxInt(usize);
    const by_allocation: u128 = if (dib.alloc_len == 0) declared else @min(declared, @as(u128, dib.alloc_len));
    return @intCast(@min(by_allocation, ceiling));
}

/// Tracks active GDI Device Contexts (DCs).
pub const DeviceContext = struct {
    /// Unique DC handle.
    handle: usize,
    /// Selected bitmap handle.
    bitmap: usize,
    /// Selected brush handle.
    brush: usize,
    /// Selected pen handle.
    pen: usize,
    /// Selected font handle.
    font: usize,
    /// Background mode (1 = TRANSPARENT, 2 = OPAQUE).
    bk_mode: i32,
    /// Background color (RGB).
    bk_color: u32,
    /// Text color (RGB).
    text_color: u32,
    /// Raster operation mode (R2_COPYPEN = 13 default).
    rop2: i32,
    /// Bitmap stretching mode (BLACKONWHITE = 1 default).
    stretch_mode: i32,
    /// Text alignment flags (TA_LEFT | TA_TOP = 0 default).
    text_align: u32,
    /// Mapping mode (MM_TEXT = 1 default).
    map_mode: i32,
};

/// Global table of active Device Contexts.
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
/// Current number of registered DCs.
pub var dc_count: usize = 0;

/// Retrieves a pointer to the DeviceContext for the given handle.
pub fn getDc(handle: usize) ?*DeviceContext {
    for (dc_entries[0..dc_count]) |*dc_entry| {
        if (dc_entry.handle == handle) return dc_entry;
    }
    return null;
}

/// Removes a DC from the table (DeleteDC). Returns true when found.
pub fn unregisterDc(handle: usize) bool {
    for (dc_entries[0..dc_count], 0..) |*dc_entry, i| {
        if (dc_entry.handle == handle) {
            dc_entries[i] = dc_entries[dc_count - 1];
            dc_entries[dc_count - 1] = .{
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
            };
            dc_count -= 1;
            return true;
        }
    }
    return false;
}

/// Registers a new DeviceContext handle in the global table.
pub fn registerDc(handle: usize) void {
    if (dc_count < dc_entries.len) {
        // A new DC starts with the BLACK_PEN and WHITE_BRUSH selected (like
        // real Windows). These stock handles must be registered objects so
        // SelectObject can restore them: with 0 here, `SelectObject(dc, old)`
        // with old==0 silently no-oped and the DC kept leaking the previously
        // selected object (e.g. a blue pen across paint calls).
        const stock_black_pen = object.GetStockObject(7); // BLACK_PEN
        const stock_white_brush = object.GetStockObject(0); // WHITE_BRUSH
        const stock_gui_font = object.GetStockObject(17); // DEFAULT_GUI_FONT
        dc_entries[dc_count] = .{
            .handle = handle,
            .bitmap = 0,
            .brush = stock_white_brush,
            .pen = stock_black_pen,
            .font = stock_gui_font,
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

/// Binds a bitmap to a device context.
pub fn bindDcBitmap(dc_handle: usize, bmp_handle: usize) void {
    if (getDc(dc_handle)) |dc_entry| {
        dc_entry.bitmap = bmp_handle;
    }
}

/// Retrieves the DIB information for the bitmap currently selected into a DC.
pub fn getDcDib(dc_handle: usize) ?*const DibInfo {
    if (getDc(dc_handle)) |dc_entry| {
        return findDib(dc_entry.bitmap);
    }
    return null;
}

/// Registers GDI32.dll built-in exports in the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "GDI32.dll";
    const stub = @import("shared.zig");

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
    try environment.addBuiltinExportComptime(m, "ExtTextOutA", drawing.ExtTextOutA);
    try environment.addBuiltinExportComptime(m, "ExtTextOutW", drawing.ExtTextOutW);
    try environment.addBuiltinExportComptime(m, "IntersectClipRect", drawing.stub_IntersectClipRect);
    try environment.addBuiltinExportComptime(m, "ExcludeClipRect", drawing.stub_ExcludeClipRect);
    try environment.addBuiltinExportComptime(m, "CombineRgn", drawing.stub_CombineRgn);
    try environment.addBuiltinExportComptime(m, "Ellipse", drawing.Ellipse);
    try environment.addBuiltinExportComptime(m, "RoundRect", drawing.RoundRect);
    try environment.addBuiltinExportComptime(m, "Polygon", drawing.Polygon);
    try environment.addBuiltinExportComptime(m, "Polyline", drawing.Polyline);

    // Generic stubs for unimplemented GDI32 functions
    try environment.addBuiltinExportComptime(m, "StartDocW", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "SetAbortProc", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "StartPage", stub.stub_args(1));
    try environment.addBuiltinExportComptime(m, "EndPage", stub.stub_args(1));
    try environment.addBuiltinExportComptime(m, "EndDoc", stub.stub_args(1));
    try environment.addBuiltinExportComptime(m, "LPtoDP", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "EnumFontsW", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "GetTextFaceA", dc.GetTextFaceA);
    try environment.addBuiltinExportComptime(m, "GetTextFaceW", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "SetBrushOrgEx", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "GetPaletteEntries", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "GetTextExtentPointW", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "PtVisible", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "CreateDIBitmap", stub.stub_args(6));
    try environment.addBuiltinExportComptime(m, "PlayMetaFile", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "SetRectRgn", stub.stub_args(5));
    try environment.addBuiltinExportComptime(m, "FillRgn", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "Escape", stub.stub_args(5));
    try environment.addBuiltinExportComptime(m, "EnumFontFamiliesExW", stub.stub_args(5));
    try environment.addBuiltinExportComptime(m, "EnumFontFamiliesW", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "SetWindowOrgEx", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "SetEnhMetaFileBits", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "EnumMetaFile", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "PlayMetaFileRecord", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "PlayEnhMetaFile", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "SetViewportOrgEx", dc.SetViewportOrgEx);
    try environment.addBuiltinExportComptime(m, "GetEnhMetaFileHeader", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "GetBitmapBits", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "GetEnhMetaFileBits", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "GetMetaFileBitsEx", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "DeleteEnhMetaFile", stub.stub_args(1));
    try environment.addBuiltinExportComptime(m, "GetTextExtentPointA", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "SetMetaFileBitsEx", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "CreateBitmapIndirect", stub.stub_args(1));
    try environment.addBuiltinExportComptime(m, "SetBitmapDimensionEx", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "CreatePolygonRgn", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "ExtFloodFill", stub.stub_args(5));
    try environment.addBuiltinExportComptime(m, "OffsetRgn", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "GetDIBColorTable", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "SetDIBColorTable", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "GetNearestPaletteIndex", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "ResizePalette", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "SetDIBits", stub.stub_args(6));
    try environment.addBuiltinExportComptime(m, "CreateRectRgnIndirect", stub.stub_args(1));
    try environment.addBuiltinExportComptime(m, "PolyBezier", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "LineDDA", stub.stub_args(6));
    try environment.addBuiltinExportComptime(m, "GetLayout", stub.stub_args(1));
    try environment.addBuiltinExportComptime(m, "SetLayout", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "DPtoLP", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "ScaleWindowExtEx", stub.stub_args(6));

    // --- Unicode (W) GDI32 stubs ---
    try environment.addBuiltinExportComptime(m, "GetTextExtentExPointW", dc.GetTextExtentExPointA);
    try environment.addBuiltinExportComptime(m, "CreateFontW", object.CreateFontA);

    // --- hgb.exe GDI32 stubs ---
    try environment.addBuiltinExportComptime(m, "GetWindowOrgEx", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "GetSystemPaletteEntries", stub.stub_args(4));
    try environment.addBuiltinExportComptime(m, "GetCurrentPositionEx", dc.GetCurrentPositionEx);
    try environment.addBuiltinExportComptime(m, "EnumFontsA", object.EnumFontsA);

    // --- Additional GDI stubs ---
    try environment.addBuiltinExportComptime(m, "StartDocA", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "SelectClipRgn", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "PtInRegion", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "GetWinMetaFileBits", stub.stub_args(5));
    try environment.addBuiltinExportComptime(m, "GetTextAlign", dc.GetTextAlign);
    try environment.addBuiltinExportComptime(m, "GetEnhMetaFilePaletteEntries", stub.stub_args(3));
    try environment.addBuiltinExportComptime(m, "GetClipRgn", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "GetClipBox", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "GdiFlush", stub.stub_args(0));
    try environment.addBuiltinExportComptime(m, "ExtCreatePen", stub.stub_args(5));
    try environment.addBuiltinExportComptime(m, "CreateICA", dc.CreateDCA);
    try environment.addBuiltinExportComptime(m, "CopyEnhMetaFileA", stub.stub_args(2));
    try environment.addBuiltinExportComptime(m, "AbortDoc", stub.stub_args(1));
}

test "a blit is bounded by the DIB's allocation, not its declared 4bpp size" {
    // 24bpp 256x256: three bytes per pixel, so the allocation is 196608 while
    // width * height * 4 would claim 262144.
    try std.testing.expectEqual(@as(usize, 256 * 256 * 3), dibPixelLen(&.{
        .handle = 1,
        .buffer = 0,
        .width = 256,
        .height = 256,
        .bpp = 24,
        .alloc_len = 256 * 256 * 3,
        .owned = true,
    }));
    // A caller-registered buffer records no length and is 32bpp scratch.
    try std.testing.expectEqual(@as(usize, 2 * 2 * 4), dibPixelLen(&.{
        .handle = 1,
        .buffer = 0,
        .width = 2,
        .height = 2,
        .bpp = 32,
    }));
    // Dimensions whose product overflows the address space saturate instead
    // of wrapping to a small bound.
    try std.testing.expectEqual(std.math.maxInt(usize), dibPixelLen(&.{
        .handle = 1,
        .buffer = 0,
        .width = std.math.maxInt(u32),
        .height = std.math.maxInt(u32),
        .bpp = 32,
        .alloc_len = 0,
    }));
}
