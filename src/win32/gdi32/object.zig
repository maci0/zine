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
            10...17 => gdi32.registerObject(.{ .handle = handle, .obj_type = .Font, .data = .{ .font = gdi32.FontData{} } }),
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
    // Win32 returns the object that was previously selected, and NULL when
    // nothing was selected (or the object could not be selected). Returning
    // the requested handle on failure would make a guest's
    // `SelectObject(hdc, bad)` check pass and its `DeleteObject(old)` free a
    // live object.
    return old_obj;
}

/// Deletes a GDI object, releasing its pixel buffer when zine allocated one.
/// Without this, every CreateCompatibleBitmap/CreateDIBSection cycle leaked
/// the full bitmap (up to megabytes) until process exit — a per-frame leak
/// in any app that redraws through memory bitmaps.
pub fn stub_DeleteObject(h: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("GDI32: DeleteObject(0x{x})\n", .{h});
    // Copy out the buffer info BEFORE unregistering: unregisterObject
    // swap-removes entries, invalidating pointers into the table.
    if (gdi32.findObject(h)) |obj| {
        if (obj.obj_type == .Bitmap and obj.data.bitmap.owned) {
            const dib = obj.data.bitmap;
            const buf: [*]u8 = @ptrFromInt(dib.buffer);
            std.heap.page_allocator.free(buf[0..dib.alloc_len]);
        }
    }
    // Stock objects may be "deleted" legally; GetStockObject re-registers
    // them lazily on next use.
    _ = gdi32.unregisterObject(h);
    return 1;
}

/// Create a logical brush that has the specified solid color.
/// Implementation status: Partially implemented
pub fn CreateSolidBrush(crColor: u32) callconv(w32cc.WINAPI) usize {
    const handle = gdi32.nextHandle();
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Brush, .data = .{ .brush = .{ .color = crColor, .style = 0 } } });
    return handle;
}

test "DeleteObject removes entries so create/delete cycles stay bounded" {
    // Snapshot and restore the shared table around the test.
    const saved_objects = gdi32.gdi_objects;
    const saved_count = gdi32.gdi_object_count;
    defer {
        gdi32.gdi_objects = saved_objects;
        gdi32.gdi_object_count = saved_count;
    }

    gdi32.gdi_object_count = 0;

    for (0..gdi32.gdi_objects.len) |i| {
        _ = CreateSolidBrush(@intCast(i));
    }
    try std.testing.expectEqual(gdi32.gdi_objects.len, gdi32.gdi_object_count);

    // Delete every object; each delete must free a slot.
    while (gdi32.gdi_object_count > 0) {
        const h = gdi32.gdi_objects[0].handle;
        _ = stub_DeleteObject(h);
    }
    try std.testing.expectEqual(@as(usize, 0), gdi32.gdi_object_count);
}

test "DeleteObject frees owned DIB buffers but not caller-owned ones" {
    const saved_objects = gdi32.gdi_objects;
    const saved_count = gdi32.gdi_object_count;
    defer {
        gdi32.gdi_objects = saved_objects;
        gdi32.gdi_object_count = saved_count;
    }
    gdi32.gdi_object_count = 0;

    // Owned registration: DeleteObject must release the allocation.
    const bytes = 64 * 64 * 4;
    const buf = try std.heap.page_allocator.alloc(u8, bytes);
    const h = gdi32.nextHandle();
    try std.testing.expect(gdi32.registerDib(h, @intFromPtr(buf.ptr), 64, 64, 32, bytes, true));
    try std.testing.expectEqual(@as(i32, 1), stub_DeleteObject(h));
    // findObject must no longer return the deleted handle.
    try std.testing.expect(gdi32.findObject(h) == null);

    // Caller-owned (stack/static) registrations must never be freed.
    var stack_px = [_]u32{0} ** 4;
    const h2 = gdi32.nextHandle();
    _ = gdi32.registerDib(h2, @intFromPtr(&stack_px), 2, 2, 32, 0, false);
    try std.testing.expectEqual(@as(i32, 1), stub_DeleteObject(h2));
    stack_px[0] = 0xDEADBEEF; // still writable, not dangling
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), stack_px[0]);
}

/// Create a logical pen with the specified style, width, and color.
/// Implementation status: Partially implemented
pub fn CreatePen(iStyle: i32, cWidth: i32, crColor: u32) callconv(w32cc.WINAPI) usize {
    const handle = gdi32.nextHandle();
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Pen, .data = .{ .pen = .{ .color = crColor, .width = cWidth, .style = iStyle } } });
    return handle;
}

/// Create a logical font from a LOGFONT structure.
/// Implementation status: Partially implemented (stores height, weight, face name for metrics)
pub fn CreateFontIndirectA(lplf: usize) callconv(w32cc.WINAPI) usize {
    var fd = gdi32.FontData{};
    if (lplf != 0) {
        // LOGFONT layout: lfHeight(0), lfWidth(4), lfEscapement(8), lfOrientation(12),
        // lfWeight(16), lfItalic(20), lfUnderline(21), lfStrikeOut(22), lfCharSet(23),
        // ... lfFaceName(28, 32 bytes)
        fd.height = @as(*const i32, @ptrFromInt(lplf)).*;
        fd.width = @as(*const i32, @ptrFromInt(lplf + 4)).*;
        fd.weight = @as(*const i32, @ptrFromInt(lplf + 16)).*;
        fd.italic = @as(*const u8, @ptrFromInt(lplf + 20)).* != 0;
        fd.charset = @as(*const u8, @ptrFromInt(lplf + 23)).*;
        // Copy face name
        const face = @as([*]const u8, @ptrFromInt(lplf + 28));
        const len = std.mem.indexOfScalar(u8, face[0..32], 0) orelse 32;
        const copy_len = @min(len, 31);
        @memcpy(fd.face_name[0..copy_len], face[0..copy_len]);
        fd.face_len = @intCast(copy_len);
        if (trace.enable_tracing) trace.print("GDI32: CreateFontIndirectA(face='{s}', h={d})\n", .{ fd.face_name[0..fd.face_len], fd.height });
    } else {
        if (trace.enable_tracing) trace.print("GDI32: CreateFontIndirectA(NULL)\n", .{});
    }
    const handle = gdi32.nextHandle();
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Font, .data = .{ .font = fd } });
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

    // If the table is full the buffer would be unreachable forever, so
    // fail the call and release it instead of registering nothing.
    if (!gdi32.registerDib(handle, @intFromPtr(buf.ptr), w, h, bitcount, bytes, true)) {
        std.heap.page_allocator.free(buf);
        return 0;
    }
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
        // Negating INT32_MIN in i32 traps, and the geometry products wrap in
        // u32, so the whole computation runs in u64 and a height that does not
        // fit u32 is refused rather than wrapped.
        const height: u64 = if (bi_height_raw > 0) @intCast(bi_height_raw) else @intCast(-@as(i64, bi_height_raw));
        if (height > std.math.maxInt(u32)) {
            @as(*usize, @ptrFromInt(ppvBits)).* = 0;
            return 0; // GDI_ERROR
        }
        h = @intCast(height);
        const bpp: u32 = if (bitcount > 0) @as(u32, bitcount) / 8 else 4;
        const row_stride = (@as(u64, w) * bpp + 3) / 4 * 4;
        buf_size = @intCast(@min(row_stride * height, @as(u64, std.math.maxInt(usize))));
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
        // Register so BitBlt can find the pixel data via DC → bitmap lookup.
        // A full table must not strand the allocation: report failure and free.
        if (!gdi32.registerDib(handle, @intFromPtr(buf.ptr), w, h, bitcount, buf_size, true)) {
            std.heap.page_allocator.free(buf);
            @as(*usize, @ptrFromInt(ppvBits)).* = 0;
            return 0;
        }
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
            .Pen => 16, // sizeof(LOGPEN)
            .Font => 60, // sizeof(LOGFONT)
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
            1 => dc.pen, // OBJ_PEN
            2 => dc.brush, // OBJ_BRUSH
            6 => dc.font, // OBJ_FONT
            7 => dc.bitmap, // OBJ_BITMAP
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
/// Implementation status: Partially implemented (stores height, weight, face for metrics)
pub fn CreateFontA(nHeight: i32, nWidth: i32, nEscapement: i32, nOrientation: i32, fnWeight: i32, fdwItalic: u32, fdwUnderline: u32, fdwStrikeOut: u32, fdwCharSet: u32, fdwOutputPrecision: u32, fdwClipPrecision: u32, fdwQuality: u32, fdwPitchAndFamily: u32, lpszFace: usize) callconv(w32cc.WINAPI) usize {
    _ = nEscapement;
    _ = nOrientation;
    _ = fdwUnderline;
    _ = fdwStrikeOut;
    _ = fdwOutputPrecision;
    _ = fdwClipPrecision;
    _ = fdwQuality;
    _ = fdwPitchAndFamily;
    var fd = gdi32.FontData{};
    fd.height = nHeight;
    fd.width = nWidth;
    fd.weight = fnWeight;
    fd.italic = (fdwItalic != 0);
    fd.charset = fdwCharSet;
    if (lpszFace != 0) {
        const face = @as([*]const u8, @ptrFromInt(lpszFace));
        const len = std.mem.indexOfScalar(u8, face[0..32], 0) orelse 32;
        const copy_len = @min(len, 31);
        @memcpy(fd.face_name[0..copy_len], face[0..copy_len]);
        fd.face_len = @intCast(copy_len);
    }
    if (trace.enable_tracing) trace.print("GDI32: CreateFontA(h={d}, face='{s}')\n", .{ nHeight, fd.face_name[0..fd.face_len] });
    const handle = gdi32.nextHandle();
    gdi32.registerObject(.{ .handle = handle, .obj_type = .Font, .data = .{ .font = fd } });
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

/// EnumFontsA — enumerates the fonts available on a specified device.
/// Returns 1 (success, no fonts enumerated) without invoking the callback.
pub fn EnumFontsA(hdc: usize, lpLogfont: usize, lpProc: usize, lParam: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = lpLogfont;
    _ = lpProc;
    _ = lParam;
    if (trace.enable_tracing) trace.print("GDI32: EnumFontsA -> 1 (no fonts enumerated)\n", .{});
    return 1;
}
