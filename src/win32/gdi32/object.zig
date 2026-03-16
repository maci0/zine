//! GDI object management (brushes, pens, fonts, bitmaps).
const std = @import("std");
const trace = @import("../../trace.zig");
const gdi32 = @import("../gdi32.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");

/// Retrieve a handle to one of the stock GDI objects.
/// Implementation status: Partially implemented
pub fn GetStockObject(fnObject: i32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("GDI32: GetStockObject({d})\n", .{fnObject});
    const handle = 0x0B0B0000 | @as(usize, @intCast(@as(u32, @bitCast(fnObject)) & 0xFF));
    
    // Lazy registration of stock objects
    if (gdi32.findObject(handle) == null) {
        switch (fnObject) {
            0 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Brush, .data = .{ .brush = .{ .color = 0x00FFFFFF, .style = 0 } } }), // WHITE_BRUSH
            1 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Brush, .data = .{ .brush = .{ .color = 0x00C0C0C0, .style = 0 } } }), // LTGRAY_BRUSH
            2 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Brush, .data = .{ .brush = .{ .color = 0x00808080, .style = 0 } } }), // GRAY_BRUSH
            3 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Brush, .data = .{ .brush = .{ .color = 0x00404040, .style = 0 } } }), // DKGRAY_BRUSH
            4 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Brush, .data = .{ .brush = .{ .color = 0x00000000, .style = 0 } } }), // BLACK_BRUSH
            5 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Brush, .data = .{ .brush = .{ .color = 0, .style = 1 } } }), // NULL_BRUSH
            6 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Pen, .data = .{ .pen = .{ .color = 0x00FFFFFF, .width = 1, .style = 0 } } }), // WHITE_PEN
            7 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Pen, .data = .{ .pen = .{ .color = 0x00000000, .width = 1, .style = 0 } } }), // BLACK_PEN
            8 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Pen, .data = .{ .pen = .{ .color = 0, .width = 0, .style = 5 } } }), // NULL_PEN
            10...17 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Font, .data = .{ .none = {} } }),
            else => return 0,
        }
    }
    return handle;
}

/// Select an object into the specified device context (DC).
/// Implementation status: Partially implemented
pub fn SelectObject(hdc: usize, h: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("GDI32: SelectObject(dc=0x{x}, obj=0x{x})\n", .{ hdc, h });
    var old_obj: usize = 0;
    
    if (gdi32.findObject(h)) |obj| {
        if (gdi32.getDc(hdc)) |dc_entry| {
            switch (obj.obj_type) {
                .Bitmap => {
                    old_obj = dc_entry.bitmap;
                    dc_entry.bitmap = h;
                },
                .Brush => {
                    old_obj = dc_entry.brush;
                    dc_entry.brush = h;
                },
                .Pen => {
                    old_obj = dc_entry.pen;
                    dc_entry.pen = h;
                },
                .Font => {
                    old_obj = dc_entry.font;
                    dc_entry.font = h;
                },
                else => {},
            }
        }
    } else if (gdi32.findDib(h) != null) {
        // Handle is a bitmap registered in the DIB registry (e.g. from CreateCompatibleBitmap)
        if (gdi32.getDc(hdc)) |dc_entry| {
            old_obj = dc_entry.bitmap;
            dc_entry.bitmap = h;
        }
    }
    return if (old_obj != 0) old_obj else h; // Return previous object, or requested if failed
}

/// Delete a logical pen, brush, font, bitmap, region, or palette.
/// Implementation status: Stub
pub fn stub_DeleteObject(h: usize) callconv(w32cc.WINAPI) i32 {
    _ = h;
    return 1;
}

/// Create a logical brush that has the specified solid color.
/// Implementation status: Partially implemented
pub fn CreateSolidBrush(crColor: u32) callconv(w32cc.WINAPI) usize {
    const handle = gdi32.nextHandle();
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Brush, .data = .{ .brush = .{ .color = crColor, .style = 0 } } });
    return handle;
}

/// Create a logical pen with the specified style, width, and color.
/// Implementation status: Partially implemented
pub fn CreatePen(iStyle: i32, cWidth: i32, crColor: u32) callconv(w32cc.WINAPI) usize {
    const handle = gdi32.nextHandle();
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Pen, .data = .{ .pen = .{ .color = crColor, .width = cWidth, .style = iStyle } } });
    return handle;
}

/// Create a logical font from a LOGFONT structure.
/// Implementation status: Stub
pub fn CreateFontIndirectA(lplf: usize) callconv(w32cc.WINAPI) usize {
    _ = lplf;
    if (trace.enable_tracing) trace.print("GDI32: CreateFontIndirectA\n", .{});
    const handle = gdi32.nextHandle();
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Font, .data = .{ .none = {} } });
    return handle;
}

/// Create a bitmap compatible with the device that is associated with the specified DC.
/// Implementation status: Partially implemented
pub fn CreateCompatibleBitmap(hdc: usize, cx: i32, cy: i32) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    const w: u32 = if (cx > 0) @intCast(cx) else 1;
    const h: u32 = if (cy > 0) @intCast(cy) else 1;
    if (trace.enable_tracing) trace.print("GDI32: CreateCompatibleBitmap({d}x{d})\n", .{ w, h });

    const handle = gdi32.nextHandle();
    const bitcount = 32;
    const bytes = w * h * 4;
    const buf = std.heap.page_allocator.alloc(u8, bytes) catch return 0;
    @memset(buf, 0);

    gdi32.registerDib(handle, @intFromPtr(buf.ptr), w, h, bitcount);
    return handle;
}

/// Create a bitmap with the specified width, height, and color format.
/// Implementation status: Stub
pub fn stub_CreateBitmap(nWidth: i32, nHeight: i32, nPlanes: u32, nBitCount: u32, lpBits: usize) callconv(w32cc.WINAPI) usize {
    _ = nWidth;
    _ = nHeight;
    _ = nPlanes;
    _ = nBitCount;
    _ = lpBits;
    return gdi32.nextHandle();
}

/// Create a DIB that applications can write to directly.
/// Implementation status: Partially implemented
pub fn CreateDIBSection(hdc: usize, pbmi: usize, usage: u32, ppvBits: usize, hSection: usize, offset: u32) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    _ = usage;
    _ = hSection;
    _ = offset;

    // Parse BITMAPINFOHEADER to determine buffer size
    var w: u32 = 256;
    var h: u32 = 256;
    var bitcount: u16 = 32;
    var buf_size: usize = 1024 * 1024 * 4; // Default fallback
    if (pbmi != 0) {
        const bmi = @as(*const w32.BITMAPINFOHEADER, @ptrFromInt(pbmi));
        const bi_width = bmi.biWidth;
        const bi_height_raw = bmi.biHeight;
        bitcount = bmi.biBitCount;
        w = if (bi_width > 0) @intCast(bi_width) else 1;
        h = @intCast(if (bi_height_raw > 0) bi_height_raw else -bi_height_raw);
        const bpp: u32 = if (bitcount > 0) @as(u32, bitcount) / 8 else 4;
        const row_stride = ((w * bpp + 3) / 4) * 4;
        buf_size = row_stride * h;
        if (trace.enable_tracing) trace.print("GDI32: CreateDIBSection({d}x{d} @ {d}bpp, {d} bytes)\n", .{ w, h, bitcount, buf_size });
    } else {
        if (trace.enable_tracing) trace.print("GDI32: CreateDIBSection(no BITMAPINFO)\n", .{});
    }

    const handle = gdi32.nextHandle();

    if (ppvBits != 0) {
        // Allocate the pixel buffer the app will render into
        const buf = std.heap.page_allocator.alloc(u8, buf_size) catch {
            @as(*usize, @ptrFromInt(ppvBits)).* = 0;
            return 0; // GDI_ERROR
        };
        @memset(buf, 0);
        @as(*usize, @ptrFromInt(ppvBits)).* = @intFromPtr(buf.ptr);
        // Register so BitBlt can find the pixel data via DC → bitmap lookup
        gdi32.registerDib(handle, @intFromPtr(buf.ptr), w, h, bitcount);
    }
    return handle;
}

/// Retrieve information for the specified graphics object.
/// Implementation status: Partially implemented
pub fn GetObjectA(h: usize, c: i32, pv: usize) callconv(w32cc.WINAPI) i32 {
    if (c <= 0) return 0;

    // Check if it's a DIB/bitmap
    if (gdi32.findDib(h)) |dib| {
        // BITMAP struct: { LONG bmType; LONG bmWidth; LONG bmHeight; LONG bmWidthBytes; WORD bmPlanes; WORD bmBitsPixel; LPVOID bmBits; }
        const BITMAP_SIZE: i32 = 24; // sizeof(BITMAP) on 32-bit
        if (pv == 0) return BITMAP_SIZE;
        if (c >= BITMAP_SIZE) {
            const ptr = @as([*]u8, @ptrFromInt(pv));
            @memset(ptr[0..@intCast(@as(u32, @bitCast(c)))], 0);
            @as(*i32, @ptrFromInt(pv + 0)).* = 0; // bmType
            @as(*i32, @ptrFromInt(pv + 4)).* = @intCast(dib.width); // bmWidth
            @as(*i32, @ptrFromInt(pv + 8)).* = @intCast(dib.height); // bmHeight
            @as(*i32, @ptrFromInt(pv + 12)).* = @intCast(dib.width * (@as(u32, dib.bpp) / 8)); // bmWidthBytes
            @as(*u16, @ptrFromInt(pv + 16)).* = 1; // bmPlanes
            @as(*u16, @ptrFromInt(pv + 18)).* = dib.bpp; // bmBitsPixel
            @as(*u32, @ptrFromInt(pv + 20)).* = @truncate(dib.buffer); // bmBits
        }
        return BITMAP_SIZE;
    }

    // Check registered GDI objects
    if (gdi32.findObject(h)) |obj| {
        if (pv != 0) {
            @memset(@as([*]u8, @ptrFromInt(pv))[0..@intCast(@as(u32, @bitCast(c)))], 0);
        }
        return switch (obj.obj_type) {
            .Brush => 12, // sizeof(LOGBRUSH)
            .Pen => 16,   // sizeof(LOGPEN)
            .Font => 60,  // sizeof(LOGFONT)
            else => 0,
        };
    }

    if (pv != 0) {
        @memset(@as([*]u8, @ptrFromInt(pv))[0..@intCast(@as(u32, @bitCast(c)))], 0);
    }
    return 0;
}

/// Retrieve a handle to an object of the specified type that is currently selected into the specified DC.
/// Implementation status: Partially implemented
pub fn GetCurrentObject(hdc: usize, tp: u32) callconv(w32cc.WINAPI) usize {
    if (gdi32.getDc(hdc)) |dc| {
        return switch (tp) {
            1 => dc.pen,       // OBJ_PEN
            2 => dc.brush,     // OBJ_BRUSH
            6 => dc.font,      // OBJ_FONT
            7 => dc.bitmap,    // OBJ_BITMAP
            else => 0,
        };
    }
    return 0;
}

/// Load an icon, cursor, animated cursor, or bitmap.
/// Implementation status: Stub
pub fn stub_LoadImageA(hInst: usize, name: usize, tp: u32, cx: i32, cy: i32, fuLoad: u32) callconv(w32cc.WINAPI) usize {
    _ = hInst;
    _ = name;
    _ = cx;
    _ = cy;
    _ = fuLoad;
    if (trace.enable_tracing) trace.print("GDI32: LoadImageA(type={d})\n", .{tp});
    return gdi32.nextHandle();
}

/// Create a logical palette.
/// Implementation status: Stub
pub fn stub_CreatePalette(lplgpl: usize) callconv(w32cc.WINAPI) usize {
    _ = lplgpl;
    if (trace.enable_tracing) trace.print("GDI32: CreatePalette\n", .{});
    return gdi32.nextHandle();
}

/// Select the specified logical palette into the specified device context.
/// Implementation status: Stub
pub fn stub_SelectPalette(hdc: usize, hPal: usize, bForceBackground: i32) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    _ = bForceBackground;
    if (trace.enable_tracing) trace.print("GDI32: SelectPalette\n", .{});
    return hPal;
}

/// Map palette entries from the current logical palette to the system palette.
/// Implementation status: Stub
pub fn stub_RealizePalette(hdc: usize) callconv(w32cc.WINAPI) u32 {
    _ = hdc;
    if (trace.enable_tracing) trace.print("GDI32: RealizePalette\n", .{});
    return 0;
}

/// Create a rectangular region.
/// Implementation status: Stub
pub fn stub_CreateRectRgn(x1: i32, y1: i32, x2: i32, y2: i32) callconv(w32cc.WINAPI) usize {
    _ = x1;
    _ = y1;
    _ = x2;
    _ = y2;
    return gdi32.nextHandle();
}

/// Create a logical brush that has the style, color, and pattern specified in a LOGBRUSH structure.
/// Implementation status: Partially implemented
pub fn CreateBrushIndirect(lplb: usize) callconv(w32cc.WINAPI) usize {
    const handle = gdi32.nextHandle();
    var color: u32 = 0;
    var style: i32 = 0;
    if (lplb != 0) {
        // LOGBRUSH: { UINT lbStyle; COLORREF lbColor; ULONG_PTR lbHatch; }
        const lb_style = @as(*const u32, @ptrFromInt(lplb)).*;
        const lb_color = @as(*const u32, @ptrFromInt(lplb + 4)).*;
        style = @bitCast(lb_style);
        color = lb_color;
    }
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Brush, .data = .{ .brush = .{ .color = color, .style = style } } });
    return handle;
}

/// Create a logical pen that has the style, width, and color specified in a structure.
/// Implementation status: Partially implemented
pub fn CreatePenIndirect(lplgpn: usize) callconv(w32cc.WINAPI) usize {
    const handle = gdi32.nextHandle();
    var color: u32 = 0;
    var width: i32 = 1;
    var style: i32 = 0;
    if (lplgpn != 0) {
        // LOGPEN: { UINT lopnStyle; POINT lopnWidth; COLORREF lopnColor; }
        const pen_style = @as(*const u32, @ptrFromInt(lplgpn)).*;
        const pen_width = @as(*const i32, @ptrFromInt(lplgpn + 4)).*;
        const pen_color = @as(*const u32, @ptrFromInt(lplgpn + 12)).*;
        style = @bitCast(pen_style);
        width = pen_width;
        color = pen_color;
    }
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Pen, .data = .{ .pen = .{ .color = color, .width = width, .style = style } } });
    return handle;
}

/// Create a logical font with the specified characteristics.
/// Implementation status: Stub
pub fn CreateFontA(nHeight: i32, nWidth: i32, nEscapement: i32, nOrientation: i32, fnWeight: i32, fdwItalic: u32, fdwUnderline: u32, fdwStrikeOut: u32, fdwCharSet: u32, fdwOutputPrecision: u32, fdwClipPrecision: u32, fdwQuality: u32, fdwPitchAndFamily: u32, lpszFace: usize) callconv(w32cc.WINAPI) usize {
    _ = nHeight; _ = nWidth; _ = nEscapement; _ = nOrientation; _ = fnWeight;
    _ = fdwItalic; _ = fdwUnderline; _ = fdwStrikeOut; _ = fdwCharSet;
    _ = fdwOutputPrecision; _ = fdwClipPrecision; _ = fdwQuality;
    _ = fdwPitchAndFamily; _ = lpszFace;
    const handle = gdi32.nextHandle();
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Font, .data = .{ .none = {} } });
    return handle;
}

/// Set RGB (red, green, blue) color values and flags in a range of entries in a logical palette.
/// Implementation status: Stub
pub fn stub_SetPaletteEntries(hpal: usize, iStart: u32, cEntries: u32, pPalEntries: usize) callconv(w32cc.WINAPI) u32 {
    _ = hpal;
    _ = iStart;
    _ = pPalEntries;
    _ = cEntries;
    return 0;
}

/// Reset the origin of the specified brush or reset the specified palette.
/// Implementation status: Stub
pub fn stub_UnrealizeObject(h: usize) callconv(w32cc.WINAPI) i32 {
    _ = h;
    return 1;
}

/// Create a halftone palette for the specified device context.
/// Implementation status: Partially implemented
pub fn CreateHalftonePalette(hdc: usize) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    const handle = gdi32.nextHandle();
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Palette, .data = .{ .none = {} } });
    if (trace.enable_tracing) trace.print("GDI32: CreateHalftonePalette -> 0x{x}\n", .{handle});
    return handle;
}

/// Create a logical brush with the specified bitmap pattern.
/// Implementation status: Partially implemented
pub fn CreatePatternBrush(hBitmap: usize) callconv(w32cc.WINAPI) usize {
    _ = hBitmap;
    const handle = gdi32.nextHandle();
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Brush, .data = .{ .brush = .{ .color = 0, .style = 3 } } }); // style 3 = pattern
    if (trace.enable_tracing) trace.print("GDI32: CreatePatternBrush -> 0x{x}\n", .{handle});
    return handle;
}
