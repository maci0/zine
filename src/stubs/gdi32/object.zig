const std = @import("std");
const trace = @import("../../trace.zig");
const gdi32 = @import("../gdi32.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn stub_GetStockObject(fnObject: i32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("GDI32: GetStockObject({d})\n", .{fnObject});
    return 0x0B0B0000 | @as(usize, @intCast(@as(u32, @bitCast(fnObject)) & 0xFF));
}

pub fn stub_SelectObject(hdc: usize, h: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("GDI32: SelectObject(dc=0x{x}, obj=0x{x})\n", .{ hdc, h });
    // Track DC → bitmap binding for known DIB sections
    if (gdi32.findDib(h) != null) {
        gdi32.bindDcBitmap(hdc, h);
    }
    return h; // Return "previous" object
}

pub fn stub_DeleteObject(h: usize) callconv(w32cc.WINAPI) i32 {
    _ = h;
    return 1;
}

pub fn stub_CreateSolidBrush(crColor: u32) callconv(w32cc.WINAPI) usize {
    _ = crColor;
    return gdi32.nextHandle();
}

pub fn stub_CreatePen(iStyle: i32, cWidth: i32, crColor: u32) callconv(w32cc.WINAPI) usize {
    _ = iStyle;
    _ = cWidth;
    _ = crColor;
    return gdi32.nextHandle();
}

pub fn stub_CreateFontIndirectA(lplf: usize) callconv(w32cc.WINAPI) usize {
    _ = lplf;
    if (trace.enable_tracing) trace.print("GDI32: CreateFontIndirectA\n", .{});
    return gdi32.nextHandle();
}

pub fn stub_CreateCompatibleBitmap(hdc: usize, cx: i32, cy: i32) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    if (trace.enable_tracing) trace.print("GDI32: CreateCompatibleBitmap({d}x{d})\n", .{ cx, cy });
    return gdi32.nextHandle();
}

pub fn stub_CreateBitmap(nWidth: i32, nHeight: i32, nPlanes: u32, nBitCount: u32, lpBits: usize) callconv(w32cc.WINAPI) usize {
    _ = nWidth;
    _ = nHeight;
    _ = nPlanes;
    _ = nBitCount;
    _ = lpBits;
    return gdi32.nextHandle();
}

pub fn stub_CreateDIBSection(hdc: usize, pbmi: usize, usage: u32, ppvBits: usize, hSection: usize, offset: u32) callconv(w32cc.WINAPI) usize {
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

pub fn stub_GetObjectA(h: usize, c: i32, pv: usize) callconv(w32cc.WINAPI) i32 {
    _ = h;
    if (pv != 0 and c > 0) {
        @memset(@as([*]u8, @ptrFromInt(pv))[0..@intCast(@as(u32, @bitCast(c)))], 0);
    }
    return 0;
}

pub fn stub_GetCurrentObject(hdc: usize, tp: u32) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    _ = tp;
    return 0;
}

pub fn stub_LoadImageA(hInst: usize, name: usize, tp: u32, cx: i32, cy: i32, fuLoad: u32) callconv(w32cc.WINAPI) usize {
    _ = hInst;
    _ = name;
    _ = cx;
    _ = cy;
    _ = fuLoad;
    if (trace.enable_tracing) trace.print("GDI32: LoadImageA(type={d})\n", .{tp});
    return gdi32.nextHandle();
}

pub fn stub_CreatePalette(lplgpl: usize) callconv(w32cc.WINAPI) usize {
    _ = lplgpl;
    if (trace.enable_tracing) trace.print("GDI32: CreatePalette\n", .{});
    return gdi32.nextHandle();
}

pub fn stub_SelectPalette(hdc: usize, hPal: usize, bForceBackground: i32) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    _ = bForceBackground;
    if (trace.enable_tracing) trace.print("GDI32: SelectPalette\n", .{});
    return hPal;
}

pub fn stub_RealizePalette(hdc: usize) callconv(w32cc.WINAPI) u32 {
    _ = hdc;
    if (trace.enable_tracing) trace.print("GDI32: RealizePalette\n", .{});
    return 0;
}

pub fn stub_CreateRectRgn(x1: i32, y1: i32, x2: i32, y2: i32) callconv(w32cc.WINAPI) usize {
    _ = x1;
    _ = y1;
    _ = x2;
    _ = y2;
    return gdi32.nextHandle();
}

pub fn stub_CreateBrushIndirect(lplb: usize) callconv(w32cc.WINAPI) usize {
    _ = lplb;
    return gdi32.nextHandle();
}

pub fn stub_CreatePenIndirect(lplgpn: usize) callconv(w32cc.WINAPI) usize {
    _ = lplgpn;
    return gdi32.nextHandle();
}

pub fn stub_CreateFontA(nHeight: i32, nWidth: i32, nEscapement: i32, nOrientation: i32, fnWeight: i32, fdwItalic: u32, fdwUnderline: u32, fdwStrikeOut: u32, fdwCharSet: u32, fdwOutputPrecision: u32, fdwClipPrecision: u32, fdwQuality: u32, fdwPitchAndFamily: u32, lpszFace: usize) callconv(w32cc.WINAPI) usize {
    _ = nHeight;
    _ = nWidth;
    _ = nEscapement;
    _ = nOrientation;
    _ = fnWeight;
    _ = fdwItalic;
    _ = fdwUnderline;
    _ = fdwStrikeOut;
    _ = fdwCharSet;
    _ = fdwOutputPrecision;
    _ = fdwClipPrecision;
    _ = fdwQuality;
    _ = fdwPitchAndFamily;
    _ = lpszFace;
    return gdi32.nextHandle();
}

pub fn stub_SetPaletteEntries(hpal: usize, iStart: u32, cEntries: u32, pPalEntries: usize) callconv(w32cc.WINAPI) u32 {
    _ = hpal;
    _ = iStart;
    _ = pPalEntries;
    _ = cEntries;
    return 0;
}

pub fn stub_UnrealizeObject(h: usize) callconv(w32cc.WINAPI) i32 {
    _ = h;
    return 1;
}

// CreateHalftonePalette: creates a halftone palette for a DC
pub fn stub_CreateHalftonePalette(hdc: usize) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    const h = gdi32.nextHandle();
    if (trace.enable_tracing) trace.print("GDI32: CreateHalftonePalette -> 0x{x}\n", .{h});
    return h;
}

// CreatePatternBrush: creates a brush based on a bitmap pattern
pub fn stub_CreatePatternBrush(hBitmap: usize) callconv(w32cc.WINAPI) usize {
    _ = hBitmap;
    const h = gdi32.nextHandle();
    if (trace.enable_tracing) trace.print("GDI32: CreatePatternBrush -> 0x{x}\n", .{h});
    return h;
}
