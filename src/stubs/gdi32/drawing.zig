const std = @import("std");
const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const gdi32 = @import("../gdi32.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn stub_BitBlt(hdcDest: usize, x: i32, y: i32, cx: i32, cy: i32, hdcSrc: usize, x1: i32, y1: i32, rop: u32) callconv(w32cc.WINAPI) i32 {
    _ = hdcDest; _ = x; _ = y; _ = x1; _ = y1; _ = rop;
    // Look up source DC's DIB section
    if (gdi32.getDcDib(hdcSrc)) |dib| {
        if (trace.enable_tracing) trace.print("GDI32: BitBlt({d}x{d}) from DIB {d}x{d}\n", .{ cx, cy, dib.width, dib.height });
        blitDibInfoToFramebuf(dib);
    }
    return 1;
}

pub fn stub_StretchBlt(hdcDest: usize, xDest: i32, yDest: i32, wDest: i32, hDest: i32, hdcSrc: usize, xSrc: i32, ySrc: i32, wSrc: i32, hSrc: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdcDest; _ = xDest; _ = yDest; _ = xSrc; _ = ySrc;
    // Look up source DC's DIB section
    if (gdi32.getDcDib(hdcSrc)) |dib| {
        if (trace.enable_tracing) trace.print("GDI32: StretchBlt({d}x{d} -> {d}x{d}) from DIB\n", .{ wSrc, hSrc, wDest, hDest });
        blitDibInfoToFramebuf(dib);
    }
    return 1;
}

/// Blit a tracked DIB section's pixel buffer into the renderer framebuffer.
fn blitDibInfoToFramebuf(dib: *const gdi32.DibInfo) void {
    const w = dib.width;
    const h = dib.height;
    if (w == 0 or h == 0 or dib.buffer == 0) return;

    if (w != renderer.global_width or h != renderer.global_height) {
        renderer.setResolution(w, h);
    }

    const src = @as([*]const u8, @ptrFromInt(dib.buffer));
    const fb = renderer.global_framebuf;
    const pixels = w * h;
    if (fb.len < pixels * 4) return;

    const bytes_per_pixel: u32 = @as(u32, dib.bpp) / 8;
    // DIB rows are padded to 4-byte boundaries
    const row_stride = ((w * bytes_per_pixel + 3) / 4) * 4;

    // DIB sections created with CreateDIBSection use the biHeight sign:
    // We always treat the buffer as-is (top-down) since the app writes
    // directly to it and usually uses negative biHeight (top-down).
    // If the image appears flipped, we may need to revisit this.
    for (0..h) |y_idx| {
        const src_row = src + @as(u32, @intCast(y_idx)) * row_stride;
        const dest_row_offset: u32 = @as(u32, @intCast(y_idx)) * w;

        for (0..w) |x_idx| {
            const si = @as(u32, @intCast(x_idx)) * bytes_per_pixel;
            const di = (dest_row_offset + @as(u32, @intCast(x_idx))) * 4;
            fb[di + 0] = src_row[si + 2]; // R (from BGR)
            fb[di + 1] = src_row[si + 1]; // G
            fb[di + 2] = src_row[si + 0]; // B
            fb[di + 3] = 255;             // A
        }
    }

    renderer.pushFrame();
}

/// Parse a BITMAPINFOHEADER at lpbmi and blit pixel data from lpBits into the
/// renderer framebuffer, converting BGR(A) → RGBA.  Handles 24-bit and 32-bit
/// sources, and bottom-up (positive biHeight) vs top-down (negative biHeight).
fn blitDIBToFramebuf(lpBits: usize, lpbmi: usize) void {
    if (lpBits == 0 or lpbmi == 0) return;

    // BITMAPINFOHEADER layout (all i32/u32 little-endian):
    //   offset 0:  biSize       (u32)
    //   offset 4:  biWidth      (i32)
    //   offset 8:  biHeight     (i32)  — positive = bottom-up, negative = top-down
    //   offset 12: biPlanes     (u16)
    //   offset 14: biBitCount   (u16)
    const hdr = @as(*const w32.BITMAPINFOHEADER, @ptrFromInt(lpbmi));
    const bi_width = hdr.biWidth;
    const bi_height_raw = hdr.biHeight;
    const bi_bitcount = hdr.biBitCount;

    if (bi_width <= 0) return;
    const w: u32 = @intCast(bi_width);
    const bottom_up = bi_height_raw > 0;
    const h: u32 = @intCast(if (bottom_up) bi_height_raw else -bi_height_raw);

    if (w == 0 or h == 0) return;
    if (bi_bitcount != 24 and bi_bitcount != 32) {
        if (trace.enable_tracing) trace.print("GDI32: blitDIB unsupported bpp={d}\n", .{bi_bitcount});
        return;
    }

    // Update renderer resolution if needed
    if (w != renderer.global_width or h != renderer.global_height) {
        renderer.setResolution(w, h);
    }

    const src = @as([*]const u8, @ptrFromInt(lpBits));
    const fb = renderer.global_framebuf;
    const pixels: u32 = w * h;
    if (fb.len < pixels * 4) return;

    const bytes_per_pixel: u32 = @as(u32, bi_bitcount) / 8;
    // DIB rows are padded to 4-byte boundaries
    const row_stride: u32 = ((w * bytes_per_pixel + 3) / 4) * 4;

    for (0..h) |dest_y| {
        // For bottom-up DIBs, row 0 in the file is the bottom scanline
        const src_y: u32 = if (bottom_up) h - 1 - @as(u32, @intCast(dest_y)) else @as(u32, @intCast(dest_y));
        const src_row = src + src_y * row_stride;
        const dest_row_offset: u32 = @as(u32, @intCast(dest_y)) * w;

        for (0..w) |x| {
            const si = @as(u32, @intCast(x)) * bytes_per_pixel;
            const di = (dest_row_offset + @as(u32, @intCast(x))) * 4;
            fb[di + 0] = src_row[si + 2]; // R (from BGR)
            fb[di + 1] = src_row[si + 1]; // G
            fb[di + 2] = src_row[si + 0]; // B
            fb[di + 3] = 255;             // A
        }
    }

    renderer.pushFrame();
}

pub fn stub_StretchDIBits(hdc: usize, xDest: i32, yDest: i32, DestWidth: i32, DestHeight: i32, xSrc: i32, ySrc: i32, SrcWidth: i32, SrcHeight: i32, lpBits: usize, lpbmi: usize, iUsage: u32, rop: u32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = xDest; _ = yDest; _ = xSrc; _ = ySrc; _ = iUsage; _ = rop;
    if (trace.enable_tracing) trace.print("GDI32: StretchDIBits({d}x{d} -> {d}x{d})\n", .{ SrcWidth, SrcHeight, DestWidth, DestHeight });
    blitDIBToFramebuf(lpBits, lpbmi);
    return if (DestHeight > 0) DestHeight else -DestHeight;
}

pub fn stub_TextOutA(hdc: usize, x: i32, y: i32, lpString: usize, c: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = x; _ = y; _ = lpString; _ = c;
    return 1;
}

pub fn stub_TextOutW(hdc: usize, x: i32, y: i32, lpString: usize, c: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = x; _ = y; _ = lpString; _ = c;
    return 1;
}

pub fn stub_SetPixel(hdc: usize, x: i32, y: i32, color: u32) callconv(w32cc.WINAPI) u32 {
    _ = hdc; _ = x; _ = y;
    return color;
}

pub fn stub_GetPixel(hdc: usize, x: i32, y: i32) callconv(w32cc.WINAPI) u32 {
    _ = hdc; _ = x; _ = y;
    return 0;
}

pub fn stub_MoveToEx(hdc: usize, x: i32, y: i32, lppt: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = x; _ = y; _ = lppt;
    return 1;
}

pub fn stub_LineTo(hdc: usize, x: i32, y: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = x; _ = y;
    return 1;
}

pub fn stub_Rectangle(hdc: usize, left: i32, top: i32, right: i32, bottom: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = left; _ = top; _ = right; _ = bottom;
    return 1;
}

pub fn stub_SetDIBitsToDevice(hdc: usize, xDest: i32, yDest: i32, w: u32, h: u32, xSrc: i32, ySrc: i32, StartScan: u32, cLines: u32, lpvBits: usize, lpbmi: usize, ColorUse: u32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = xDest; _ = yDest; _ = xSrc; _ = ySrc; _ = StartScan; _ = ColorUse;
    if (trace.enable_tracing) trace.print("GDI32: SetDIBitsToDevice({d}x{d}, {d} lines)\n", .{ w, h, cLines });
    blitDIBToFramebuf(lpvBits, lpbmi);
    return @intCast(cLines);
}

pub fn stub_GetDIBits(hdc: usize, hbm: usize, start: u32, cLines: u32, lpvBits: usize, lpbmi: usize, usage: u32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = hbm; _ = start; _ = cLines; _ = lpvBits; _ = lpbmi; _ = usage;
    return 0;
}

pub fn stub_PatBlt(hdc: usize, x: i32, y: i32, w: i32, h: i32, rop: u32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = x; _ = y; _ = w; _ = h; _ = rop;
    return 1;
}

pub fn stub_ExtTextOutA(hdc: usize, x: i32, y: i32, options: u32, lprect: usize, lpString: usize, c: u32, lpDx: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = x; _ = y; _ = options; _ = lprect; _ = lpString; _ = c; _ = lpDx;
    return 1;
}

pub fn stub_ExtTextOutW(hdc: usize, x: i32, y: i32, options: u32, lprect: usize, lpString: usize, c: u32, lpDx: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = x; _ = y; _ = options; _ = lprect; _ = lpString; _ = c; _ = lpDx;
    return 1;
}

pub fn stub_IntersectClipRect(hdc: usize, left: i32, top: i32, right: i32, bottom: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = left; _ = top; _ = right; _ = bottom;
    return 1; // SIMPLEREGION
}

pub fn stub_ExcludeClipRect(hdc: usize, left: i32, top: i32, right: i32, bottom: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = left; _ = top; _ = right; _ = bottom;
    return 1;
}

pub fn stub_CombineRgn(hrgnDst: usize, hrgnSrc1: usize, hrgnSrc2: usize, iMode: i32) callconv(w32cc.WINAPI) i32 {
    _ = hrgnDst; _ = hrgnSrc1; _ = hrgnSrc2; _ = iMode;
    return 1;
}

pub fn stub_Ellipse(hdc: usize, left: i32, top: i32, right: i32, bottom: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = left; _ = top; _ = right; _ = bottom;
    return 1;
}

pub fn stub_RoundRect(hdc: usize, left: i32, top: i32, right: i32, bottom: i32, width: i32, height: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = left; _ = top; _ = right; _ = bottom; _ = width; _ = height;
    return 1;
}

pub fn stub_Polygon(hdc: usize, apt: usize, cpt: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = apt; _ = cpt;
    return 1;
}

pub fn stub_Polyline(hdc: usize, apt: usize, cpt: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = apt; _ = cpt;
    return 1;
}
