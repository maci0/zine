//! GDI32.dll export definitions

const w32 = @import("win32");
const drawing = w32.gdi32.drawing;
const object = w32.gdi32.object;
const dc = w32.gdi32.dc;

comptime {
    _ = @import("dll_common.zig");

    // Drawing
    @export(&drawing.BitBlt, .{ .name = "BitBlt" });
    @export(&drawing.StretchBlt, .{ .name = "StretchBlt" });
    @export(&drawing.StretchDIBits, .{ .name = "StretchDIBits" });
    @export(&drawing.SetDIBitsToDevice, .{ .name = "SetDIBitsToDevice" });
    @export(&drawing.TextOutA, .{ .name = "TextOutA" });
    @export(&drawing.TextOutW, .{ .name = "TextOutW" });
    @export(&drawing.SetPixel, .{ .name = "SetPixel" });
    @export(&drawing.GetPixel, .{ .name = "GetPixel" });
    @export(&drawing.MoveToEx, .{ .name = "MoveToEx" });
    @export(&drawing.LineTo, .{ .name = "LineTo" });
    @export(&drawing.Rectangle, .{ .name = "Rectangle" });
    @export(&drawing.PatBlt, .{ .name = "PatBlt" });
    @export(&drawing.Ellipse, .{ .name = "Ellipse" });
    @export(&drawing.RoundRect, .{ .name = "RoundRect" });
    @export(&drawing.Polygon, .{ .name = "Polygon" });
    @export(&drawing.Polyline, .{ .name = "Polyline" });

    // Objects
    @export(&object.GetStockObject, .{ .name = "GetStockObject" });
    @export(&object.SelectObject, .{ .name = "SelectObject" });
    @export(&object.CreateSolidBrush, .{ .name = "CreateSolidBrush" });
    @export(&object.CreatePen, .{ .name = "CreatePen" });
    @export(&object.CreateFontIndirectA, .{ .name = "CreateFontIndirectA" });
    @export(&object.CreateCompatibleBitmap, .{ .name = "CreateCompatibleBitmap" });
    @export(&object.CreateDIBSection, .{ .name = "CreateDIBSection" });
    @export(&object.GetObjectA, .{ .name = "GetObjectA" });
    @export(&object.GetCurrentObject, .{ .name = "GetCurrentObject" });
    @export(&object.CreateBrushIndirect, .{ .name = "CreateBrushIndirect" });
    @export(&object.CreatePenIndirect, .{ .name = "CreatePenIndirect" });
    @export(&object.CreateFontA, .{ .name = "CreateFontA" });
    @export(&object.CreateHalftonePalette, .{ .name = "CreateHalftonePalette" });
    @export(&object.CreatePatternBrush, .{ .name = "CreatePatternBrush" });

    // Device Context
    @export(&dc.GetDeviceCaps, .{ .name = "GetDeviceCaps" });
    @export(&dc.CreateCompatibleDC, .{ .name = "CreateCompatibleDC" });
    @export(&dc.SaveDC, .{ .name = "SaveDC" });
    @export(&dc.RestoreDC, .{ .name = "RestoreDC" });
    @export(&dc.SetBkMode, .{ .name = "SetBkMode" });
    @export(&dc.SetBkColor, .{ .name = "SetBkColor" });
    @export(&dc.SetTextColor, .{ .name = "SetTextColor" });
    @export(&dc.GetTextColor, .{ .name = "GetTextColor" });
    @export(&dc.SetStretchBltMode, .{ .name = "SetStretchBltMode" });
    @export(&dc.SetMapMode, .{ .name = "SetMapMode" });
    @export(&dc.SetROP2, .{ .name = "SetROP2" });
    @export(&dc.GetTextMetricsA, .{ .name = "GetTextMetricsA" });
    @export(&dc.GetTextExtentPoint32A, .{ .name = "GetTextExtentPoint32A" });
    @export(&dc.SetTextAlign, .{ .name = "SetTextAlign" });
    @export(&dc.CreateDCA, .{ .name = "CreateDCA" });
    @export(&dc.GetTextExtentExPointA, .{ .name = "GetTextExtentExPointA" });
    @export(&dc.GetCharWidthA, .{ .name = "GetCharWidthA" });
    @export(&dc.SetWindowExtEx, .{ .name = "SetWindowExtEx" });
    @export(&dc.SetViewportExtEx, .{ .name = "SetViewportExtEx" });
    @export(&dc.GetBkMode, .{ .name = "GetBkMode" });
    @export(&dc.GetBkColor, .{ .name = "GetBkColor" });
}
