const std = @import("std");
const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const gdi32 = @import("../gdi32.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");

/// Performs a bit-block transfer of the color data corresponding to a rectangle of pixels
/// from the specified source device context into a destination device context.
/// Implementation status: Partially implemented (supports basic raster operations: SRCCOPY, SRCPAINT, SRCAND, SRCINVERT)
pub fn BitBlt(hdcDest: usize, x: i32, y: i32, cx: i32, cy: i32, hdcSrc: usize, x1: i32, y1: i32, rop: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("GDI32: BitBlt({d}x{d} @ {d},{d} -> {d},{d} srcDC={x} dstDC={x} rop={x})\n", .{ cx, cy, x1, y1, x, y, hdcSrc, hdcDest, rop });

    const src_dib = gdi32.getDcDib(hdcSrc);
    if (src_dib == null) return 1;
    const src = src_dib.?;

    const dest_dib = gdi32.getDcDib(hdcDest);
    const dest_buf = if (dest_dib) |dib|
        @as([*]u8, @ptrFromInt(dib.buffer))[0 .. dib.width * dib.height * 4]
    else
        renderer.global_framebuf;

    const dest_w = if (dest_dib) |dib| dib.width else renderer.global_width;
    const dest_h = if (dest_dib) |dib| dib.height else renderer.global_height;

    const src_ptr = @as([*]const u8, @ptrFromInt(src.buffer));
    const src_w = src.width;
    const src_h = src.height;

    const blit_w: i32 = if (cx > 0) cx else 0;
    const blit_h: i32 = if (cy > 0) cy else 0;

    // Clip the blit rectangle to both surfaces up front (i64 math so guest
    // coordinates cannot overflow) so the inner loops run without per-pixel
    // bounds checks. Source pixel (x1+d, y1+d') maps to dest (x+d, y+d').
    const dw: i64 = @intCast(dest_w);
    const dh: i64 = @intCast(dest_h);
    const sw: i64 = @intCast(src_w);
    const sh: i64 = @intCast(src_h);
    const lo_dy: i64 = @max(0, @max(-@as(i64, y), -@as(i64, y1)));
    const hi_dy: i64 = @min(@as(i64, blit_h), @min(dh - @as(i64, y), sh - @as(i64, y1)));
    const lo_dx: i64 = @max(0, @max(-@as(i64, x), -@as(i64, x1)));
    const hi_dx: i64 = @min(@as(i64, blit_w), @min(dw - @as(i64, x), sw - @as(i64, x1)));
    if (hi_dy <= lo_dy or hi_dx <= lo_dx) return 1;

    const src_bpp: u32 = @as(u32, src.bpp) / 8;
    const src_stride = @as(u64, src_w) * src_bpp;
    // The old per-pixel guards skipped pixels whose read crossed the declared
    // w*h*bpp source bound or dest_buf.len. Reads advance monotonically within
    // a row, so one span limit per row reproduces that truncation exactly.
    // u64 math: the product overflows u32 on 32-bit hosts.
    const src_size: u64 = @as(u64, src_w) * src_h * src_bpp;
    const dest_size: u64 = dest_buf.len;
    // A declared source larger than the address space cannot exist; bail
    // instead of wrapping offsets on 32-bit hosts.
    if (src_size > std.math.maxInt(usize)) return 1;

    const op: enum { or_, and_, xor_, copy_ } = switch (rop) {
        0x00EE0086 => .or_, // SRCPAINT
        0x008800C6 => .and_, // SRCAND
        0x00660046 => .xor_, // SRCINVERT
        else => .copy_, // SRCCOPY
    };

    const span: usize = @intCast(hi_dx - lo_dx);
    const first_sx: u64 = @intCast(@as(i64, x1) + lo_dx);
    const first_dx: u64 = @intCast(@as(i64, x) + lo_dx);
    var dy: i64 = lo_dy;
    while (dy < hi_dy) : (dy += 1) {
        const sy_i: i32 = @intCast(@as(i64, y1) + dy);
        const dy_i: i32 = @intCast(@as(i64, y) + dy);
        const sbase: u64 = @as(u64, @intCast(sy_i)) * src_stride + first_sx * src_bpp;
        const dbase: u64 = (@as(u64, @intCast(dy_i)) * dest_w + first_dx) * 4;
        const src_row = src_ptr + @as(usize, @intCast(sbase));
        const dst_row = dest_buf.ptr + @as(usize, @intCast(dbase));

        // Draw pixel k iff sbase + k*bpp + 3 < src_size (ceil division), and
        // iff dbase + k*4 + 3 < dest_size.
        var row_span = span;
        if (sbase + @as(u64, span - 1) * src_bpp + 3 >= src_size) {
            const room: u64 = if (src_size > sbase + 3) src_size - 3 - sbase else 0;
            row_span = @min(row_span, @as(usize, @intCast((room + src_bpp - 1) / src_bpp)));
        }
        if (dbase + @as(u64, span - 1) * 4 + 3 >= dest_size) {
            const room: u64 = if (dest_size > dbase + 3) dest_size - 3 - dbase else 0;
            row_span = @min(row_span, @as(usize, @intCast((room + 3) / 4)));
        }

        if (op == .copy_ and src_bpp == 4) {
            // Fast path: 32bpp SRCCOPY moves one word per pixel.
            for (0..row_span) |k| {
                const word = @as(*align(1) const u32, @ptrCast(src_row + k * 4)).*;
                @as(*align(1) u32, @ptrCast(dst_row + k * 4)).* = word;
            }
            continue;
        }

        for (0..row_span) |k| {
            const si_px = k * src_bpp;
            const di_px = k * 4;
            const r = src_row[si_px + 0];
            const g = src_row[si_px + 1];
            const b = src_row[si_px + 2];
            const a = if (src_bpp == 4) src_row[si_px + 3] else 255;

            switch (op) {
                .or_ => {
                    dst_row[di_px + 0] |= r;
                    dst_row[di_px + 1] |= g;
                    dst_row[di_px + 2] |= b;
                    dst_row[di_px + 3] = 255;
                },
                .and_ => {
                    dst_row[di_px + 0] &= r;
                    dst_row[di_px + 1] &= g;
                    dst_row[di_px + 2] &= b;
                    dst_row[di_px + 3] = 255;
                },
                .xor_ => {
                    dst_row[di_px + 0] ^= r;
                    dst_row[di_px + 1] ^= g;
                    dst_row[di_px + 2] ^= b;
                    dst_row[di_px + 3] = 255;
                },
                .copy_ => {
                    dst_row[di_px + 0] = r;
                    dst_row[di_px + 1] = g;
                    dst_row[di_px + 2] = b;
                    dst_row[di_px + 3] = a;
                },
            }
        }
    }

    if (dest_dib == null) {
        renderer.markScreenDirty();
    }

    return 1;
}

pub fn StretchBlt(hdcDest: usize, xDest: i32, yDest: i32, wDest: i32, hDest: i32, hdcSrc: usize, xSrc: i32, ySrc: i32, wSrc: i32, hSrc: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("GDI32: StretchBlt({d}x{d} -> {d}x{d})\n", .{ wSrc, hSrc, wDest, hDest });
    if (wSrc <= 0 or hSrc <= 0 or wDest <= 0 or hDest <= 0) return 1;

    const src_dib = gdi32.getDcDib(hdcSrc) orelse return 1;
    const src_ptr = @as([*]const u8, @ptrFromInt(src_dib.buffer));
    const src_w = src_dib.width;
    const src_h = src_dib.height;
    const src_bpp: u32 = @as(u32, src_dib.bpp) / 8;

    const dest_dib = gdi32.getDcDib(hdcDest);
    const dest_buf = if (dest_dib) |dib|
        @as([*]u8, @ptrFromInt(dib.buffer))[0 .. dib.width * dib.height * 4]
    else
        renderer.global_framebuf;
    const dest_w = if (dest_dib) |dib| dib.width else renderer.global_width;
    const dest_h = if (dest_dib) |dib| dib.height else renderer.global_height;

    // Nearest-neighbor scaling. The source coordinate sx(dx) = xSrc +
    // dx*wSrc/wd is stepped incrementally (error accumulation) so the inner
    // loop needs no integer division; the stepping reproduces
    // floor(dx*wSrc/wd) exactly.
    const wd: u32 = @intCast(wDest);
    const hd: u32 = @intCast(hDest);
    if (xSrc < 0 or ySrc < 0) return 1;
    const xsrc: u32 = @intCast(xSrc);
    const ysrc: u32 = @intCast(ySrc);

    // sx(dx) = xsrc + floor(dx*wSrc/wd) is nondecreasing, so valid dx form a
    // contiguous range [lo_dx, min(hi_dx, cutoff)) where cutoff is the first
    // dx with sx >= src_w.
    const lo_dx: u64 = @min(@as(u64, wd), @max(0, -@as(i64, xDest)));
    const hi_dx: u64 = @min(@as(u64, wd), @max(0, @as(i64, dest_w) - xDest));
    const eff_hi_dx: u64 = blk: {
        if (xsrc >= src_w or wSrc <= 0) break :blk 0;
        // smallest dx with xsrc + dx*wSrc/wd >= src_w (ceil division)
        const ws: u64 = @intCast(wSrc);
        const room: u64 = @as(u64, src_w - xsrc) * wd;
        break :blk @min(hi_dx, (room + ws - 1) / ws);
    };
    const span_x: u64 = if (eff_hi_dx > lo_dx) eff_hi_dx - lo_dx else 0;

    const lo_dy: u64 = @min(@as(u64, hd), @max(0, -@as(i64, yDest)));
    const hi_dy: u64 = @min(@as(u64, hd), @max(0, @as(i64, dest_h) - yDest));
    const eff_hi_dy: u64 = blk: {
        if (ysrc >= src_h or hSrc <= 0) break :blk 0;
        const hs: u64 = @intCast(hSrc);
        const room: u64 = @as(u64, src_h - ysrc) * hd;
        break :blk @min(hi_dy, (room + hs - 1) / hs);
    };
    const span_y: u64 = if (eff_hi_dy > lo_dy) eff_hi_dy - lo_dy else 0;

    if (span_x == 0 or span_y == 0) {
        if (dest_dib == null) renderer.markScreenDirty();
        return 1;
    }

    // Per-row truncation mirroring the old per-pixel guards (monotonic reads).
    const src_stride: u64 = @as(u64, src_w) * src_bpp;
    const src_size: u64 = @as(u64, src_w) * src_h * src_bpp;
    const dest_size: u64 = dest_buf.len;
    if (src_size > std.math.maxInt(usize)) {
        if (dest_dib == null) renderer.markScreenDirty();
        return 1;
    }

    var dy: u64 = 0;
    const step_x: u64 = @intCast(wSrc);
    const step_y: u64 = @intCast(hSrc);
    var err_y: u64 = 0;
    var sy: u64 = ysrc;
    while (dy < lo_dy) : (dy += 1) {
        err_y += step_y;
        while (err_y >= hd) : (err_y -= hd) sy += 1;
    }
    dy = lo_dy;
    while (dy < eff_hi_dy) : (dy += 1) {
        const dpy: usize = @intCast(yDest + @as(i64, @intCast(dy)));
        const dbase: u64 = (@as(u64, dpy) * dest_w + @as(u64, @intCast(xDest))) * 4;
        const dst_row = dest_buf.ptr + @as(usize, @intCast(dbase));

        var row_span = span_x;
        if (dbase + (row_span - 1) * 4 + 3 >= dest_size) {
            const room: u64 = if (dest_size > dbase + 3) dest_size - 3 - dbase else 0;
            row_span = @as(usize, @intCast((room + 3) / 4));
        }
        // Source bound: sx stays < src_w by construction, so reads can only
        // cross the declared end on the DIB's final row when bpp < 4 (the
        // old guard skipped those pixels). Gate that rare case explicitly;
        // scaled sx repeats mean a linear span clamp would be wrong here.
        const risky_row = (sy == src_h - 1);

        var err_x: u64 = 0;
        var sx: u64 = xsrc;
        for (0..@as(usize, @intCast(lo_dx))) |_| {
            err_x += step_x;
            while (err_x >= wd) : (err_x -= wd) sx += 1;
        }
        var k: usize = 0;
        while (k < row_span) : (k += 1) {
            const si: usize = @intCast(sy * src_stride + sx * src_bpp);
            if (risky_row and si + 2 >= src_size) break;
            const di = k * 4;
            dst_row[di + 0] = src_ptr[si + 0];
            dst_row[di + 1] = src_ptr[si + 1];
            dst_row[di + 2] = src_ptr[si + 2];
            dst_row[di + 3] = if (src_bpp == 4) src_ptr[si + 3] else 255;

            err_x += step_x;
            while (err_x >= wd) : (err_x -= wd) sx += 1;
        }

        err_y += step_y;
        while (err_y >= hd) : (err_y -= hd) sy += 1;
    }

    if (dest_dib == null) renderer.markScreenDirty();
    return 1;
}

/// Parse a BITMAPINFOHEADER at lpbmi and blit pixel data from lpBits into a
/// destination buffer at position (dstX, dstY).
/// Handles 4-bit, 8-bit, 24-bit and 32-bit sources, and bottom-up/top-down.
pub fn blitDIBToBufferAt(lpBits: usize, lpbmi: usize, dest_buf: []u8, dest_w: u32, dest_h: u32, dstX: i32, dstY: i32, srcX: i32, srcY: i32, blitW: u32, blitH: u32, cLines: ?u32, rop: u32) void {
    if (lpBits == 0 or lpbmi == 0) return;

    const hdr = @as(*const w32.BITMAPINFOHEADER, @ptrFromInt(lpbmi));
    const bi_width = hdr.biWidth;
    const bi_height_raw = hdr.biHeight;
    const bi_bitcount = hdr.biBitCount;

    if (bi_width <= 0) return;
    const w: u32 = @intCast(bi_width);
    const bottom_up = bi_height_raw > 0;

    // If cLines is provided, the buffer only contains that many scan lines.
    const h: u32 = if (cLines) |cl| cl else @intCast(if (bottom_up) bi_height_raw else -bi_height_raw);

    if (w == 0 or h == 0 or blitW == 0 or blitH == 0) return;

    const src = @as([*]const u8, @ptrFromInt(lpBits));
    if (dest_w == 0 or dest_h == 0) return;

    // Read palette for indexed color modes (4bpp, 8bpp)
    // Palette follows immediately after BITMAPINFOHEADER (each entry is 4 bytes: B,G,R,reserved)
    const palette_ptr = @as([*]const u8, @ptrFromInt(lpbmi + hdr.biSize));

    // Calculate row stride (rows padded to 4-byte boundaries)
    const row_stride: u32 = switch (bi_bitcount) {
        4 => ((w + 7) / 8 * 4 + 3) / 4 * 4, // 4bpp: (w/2) rounded up, padded to 4
        8 => ((w + 3) / 4) * 4,
        24 => ((w * 3 + 3) / 4) * 4,
        32 => w * 4,
        else => {
            if (trace.enable_tracing) trace.print("GDI32: blitDIB unsupported bpp={d}\n", .{bi_bitcount});
            return;
        },
    };

    // For 4bpp, row stride is actually: ((w * 4 + 31) / 32) * 4 = ((w+7)/2) & ~3
    const actual_row_stride: u32 = if (bi_bitcount == 4)
        (((w * 4 + 31) / 32) * 4)
    else
        row_stride;

    if (bi_bitcount == 4 and trace.enable_tracing) {
        trace.print("GDI32: 4bpp blit, first 4 colors: [{X:0>2}{X:0>2}{X:0>2}, {X:0>2}{X:0>2}{X:0>2}, {X:0>2}{X:0>2}{X:0>2}, {X:0>2}{X:0>2}{X:0>2}]\n", .{ palette_ptr[2], palette_ptr[1], palette_ptr[0], palette_ptr[6], palette_ptr[5], palette_ptr[4], palette_ptr[10], palette_ptr[9], palette_ptr[8], palette_ptr[14], palette_ptr[13], palette_ptr[12] });
    }

    // Clip the blit rectangle to both surfaces up front so the inner loop
    // runs without per-pixel bounds checks. Logical source column
    // (srcX + d) maps to dest column (dstX + d).
    const lo_dy: i64 = @max(0, @max(-@as(i64, srcY), -@as(i64, dstY)));
    const hi_dy: i64 = @min(@as(i64, blitH), @min(@as(i64, h) - srcY, @as(i64, dest_h) - dstY));
    const lo_dx: i64 = @max(0, @max(-@as(i64, srcX), -@as(i64, dstX)));
    const hi_dx: i64 = @min(@as(i64, blitW), @min(@as(i64, w) - srcX, @as(i64, dest_w) - dstX));

    var dy: i64 = lo_dy;
    while (dy < hi_dy) : (dy += 1) {
        // True physical row in the DIB bits (handles bottom-up vs top-down)
        const src_y_physical: u32 = if (bottom_up)
            h - 1 - @as(u32, @intCast(srcY + dy))
        else
            @as(u32, @intCast(srcY + dy));

        const src_row = src + @as(usize, src_y_physical) * actual_row_stride;

        const screen_y: u32 = @intCast(dstY + dy);
        var row_span: usize = @intCast(hi_dx - lo_dx);
        // Clamp the span where a 4-byte dest write would cross the buffer
        // (dest writes are monotonic within the row).
        const dbase: usize = (@as(usize, screen_y) * dest_w + @as(usize, @intCast(dstX + lo_dx))) * 4;
        if (dbase + (row_span - 1) * 4 + 3 >= dest_buf.len) {
            const room: u64 = if (dest_buf.len > dbase + 3) dest_buf.len - 3 - dbase else 0;
            row_span = @intCast((room + 3) / 4);
        }
        const dst_row = dest_buf.ptr + dbase;

        for (0..row_span) |k| {
            const src_x_logical: i32 = @intCast(srcX + lo_dx + @as(i64, @intCast(k)));
            const di = k * 4;

            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;

            switch (bi_bitcount) {
                4 => {
                    // 4bpp: each byte has 2 pixels, high nibble = left
                    const byte_idx = @as(u32, @intCast(src_x_logical)) / 2;
                    const byte_val = src_row[byte_idx];
                    const color_idx: u8 = if (@rem(src_x_logical, 2) == 0) (byte_val >> 4) else (byte_val & 0x0F);
                    const pe = color_idx * 4; // palette entry (B, G, R, reserved)
                    b = palette_ptr[pe + 0];
                    g = palette_ptr[pe + 1];
                    r = palette_ptr[pe + 2];
                },
                8 => {
                    const color_idx = src_row[@intCast(src_x_logical)];
                    const pe = @as(u32, color_idx) * 4;
                    b = palette_ptr[pe + 0];
                    g = palette_ptr[pe + 1];
                    r = palette_ptr[pe + 2];
                },
                24 => {
                    const si = @as(u32, @intCast(src_x_logical)) * 3;
                    b = src_row[si + 0];
                    g = src_row[si + 1];
                    r = src_row[si + 2];
                },
                32 => {
                    const si = @as(u32, @intCast(src_x_logical)) * 4;
                    b = src_row[si + 0];
                    g = src_row[si + 1];
                    r = src_row[si + 2];
                },
                else => {},
            }

            switch (rop) {
                0x00EE0086 => { // SRCPAINT (OR)
                    dst_row[di + 0] |= r;
                    dst_row[di + 1] |= g;
                    dst_row[di + 2] |= b;
                    dst_row[di + 3] = 255;
                },
                0x008800C6 => { // SRCAND (AND)
                    dst_row[di + 0] &= r;
                    dst_row[di + 1] &= g;
                    dst_row[di + 2] &= b;
                    dst_row[di + 3] = 255;
                },
                0x00660046 => { // SRCINVERT (XOR)
                    dst_row[di + 0] ^= r;
                    dst_row[di + 1] ^= g;
                    dst_row[di + 2] ^= b;
                    dst_row[di + 3] = 255;
                },
                else => { // SRCCOPY
                    dst_row[di + 0] = r;
                    dst_row[di + 1] = g;
                    dst_row[di + 2] = b;
                    dst_row[di + 3] = 255;
                },
            }
        }
    }
}

pub fn StretchDIBits(hdc: usize, xDest: i32, yDest: i32, DestWidth: i32, DestHeight: i32, xSrc: i32, ySrc: i32, SrcWidth: i32, SrcHeight: i32, lpBits: usize, lpbmi: usize, iUsage: u32, rop: u32) callconv(w32cc.WINAPI) i32 {
    _ = iUsage;
    if (trace.enable_tracing) trace.print("GDI32: StretchDIBits({d}x{d} -> {d}x{d})\n", .{ SrcWidth, SrcHeight, DestWidth, DestHeight });

    const dest_dib = gdi32.getDcDib(hdc);
    const dest_buf = if (dest_dib) |dib|
        @as([*]u8, @ptrFromInt(dib.buffer))[0 .. dib.width * dib.height * 4]
    else
        renderer.global_framebuf;

    const dest_w = if (dest_dib) |dib| dib.width else renderer.global_width;
    const dest_h = if (dest_dib) |dib| dib.height else renderer.global_height;

    blitDIBToBufferAt(lpBits, lpbmi, dest_buf, dest_w, dest_h, xDest, yDest, xSrc, ySrc, @intCast(SrcWidth), @intCast(SrcHeight), null, rop);

    if (dest_dib == null) {
        renderer.markScreenDirty();
    }

    return if (DestHeight > 0) DestHeight else -DestHeight;
}

pub const FramebufferInfo = struct {
    buf: []u8,
    w: u32,
    h: u32,
    is_screen: bool,

    pub fn setPixel(self: *const FramebufferInfo, x: i32, y: i32, color: u32) void {
        if (self.buf.len == 0) return; // headless (.none backend): no framebuffer
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.w)) or y >= @as(i32, @intCast(self.h))) return;
        const di: u32 = (@as(u32, @intCast(y)) * self.w + @as(u32, @intCast(x))) * 4;
        // color is a Win32 COLORREF (0x00BBGGRR). The framebuffer is BGRA, so
        // the byte order must be swapped: COLORREF's R (low byte) goes into the
        // framebuffer's R slot (buf+2), B (high byte) into buf+0. The previous
        // code wrote R into the B slot, so every non-gray color rendered
        // red<->blue swapped on screen.
        self.buf[di + 0] = @as(u8, @intCast((color >> 16) & 0xFF)); // B
        self.buf[di + 1] = @as(u8, @intCast((color >> 8) & 0xFF)); // G
        self.buf[di + 2] = @as(u8, @intCast(color & 0xFF)); // R
        self.buf[di + 3] = 255;
    }

    pub fn getPixel(self: *const FramebufferInfo, x: i32, y: i32) u32 {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.w)) or y >= @as(i32, @intCast(self.h))) return 0;
        const di: u32 = (@as(u32, @intCast(y)) * self.w + @as(u32, @intCast(x))) * 4;
        // Invert of setPixel: framebuffer is BGRA, COLORREF is 0x00BBGGRR.
        const b = @as(u32, self.buf[di + 0]);
        const g = @as(u32, self.buf[di + 1]);
        const r = @as(u32, self.buf[di + 2]);
        return (b << 16) | (g << 8) | r;
    }

    pub fn drawLine(self: *const FramebufferInfo, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) void {
        var cx = x0;
        var cy = y0;
        const dx: i32 = @intCast(@abs(x1 - x0));
        // Bresenham requires dy NEGATIVE (the error term accumulates toward
        // zero). With a positive dy both branches fired each step and the walk
        // filled the entire bounding box instead of drawing a line.
        const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx + dy;

        while (true) {
            self.setPixel(cx, cy, color);
            if (cx == x1 and cy == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                cx += sx;
            }
            if (e2 <= dx) {
                err += dx;
                cy += sy;
            }
        }
    }

    pub fn fillRect(self: *const FramebufferInfo, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        if (self.buf.len == 0) return; // headless (.none backend): no framebuffer
        // Clip once so the row fills below need no per-pixel bounds checks.
        const x0: u64 = @intCast(@max(0, x));
        const y0: u64 = @intCast(@max(0, y));
        const x1: u64 = @min(@as(u64, self.w), @as(u64, @intCast(@max(x0, @as(i64, x) + w))));
        const y1: u64 = @min(@as(u64, self.h), @as(u64, @intCast(@max(y0, @as(i64, y) + h))));
        if (x1 <= x0 or y1 <= y0) return;

        // COLORREF 0x00BBGGRR -> BGRA word (little-endian byte order B,G,R,A).
        const px: u32 = ((color >> 16) & 0xFF) | (((color >> 8) & 0xFF) << 8) | ((color & 0xFF) << 16) | 0xFF000000;
        var cy: u64 = y0;
        while (cy < y1) : (cy += 1) {
            const row = self.buf.ptr + @as(usize, @intCast(cy * self.w + x0)) * 4;
            var k: usize = 0;
            while (k < x1 - x0) : (k += 1) {
                @as(*align(1) u32, @ptrCast(row + k * 4)).* = px;
            }
        }
    }
};

pub fn getFramebufferForDc(hdc: usize) ?FramebufferInfo {
    if (gdi32.getDcDib(hdc)) |dib| {
        return FramebufferInfo{
            .buf = @as([*]u8, @ptrFromInt(dib.buffer))[0 .. dib.width * dib.height * 4],
            .w = dib.width,
            .h = dib.height,
            .is_screen = false,
        };
    } else {
        return FramebufferInfo{
            .buf = renderer.global_framebuf,
            .w = renderer.global_width,
            .h = renderer.global_height,
            .is_screen = true,
        };
    }
}

pub fn TextOutA(hdc: usize, x: i32, y: i32, lpString: usize, c: i32) callconv(w32cc.WINAPI) i32 {
    if (lpString == 0 or c <= 0) return 1;
    if (getFramebufferForDc(hdc)) |fb| {
        const font = @import("font5x7.zig");
        const dc_entry = gdi32.getDc(hdc);
        const bg_color = if (dc_entry) |dc| dc.bk_color else 0x00FFFFFF;
        const fg_color = if (dc_entry) |dc| dc.text_color else 0x00000000;
        const bk_mode = if (dc_entry) |dc| dc.bk_mode else 2;

        // lpString is a guest VA (usize param — not auto-translated).
        const src = @as([*]const u8, @ptrFromInt(trace.addr(lpString)));
        const count: usize = @intCast(@min(c, 4096));

        // Draw opaque background over the whole text run first.
        if (bk_mode == 2) {
            const width = @as(i32, @intCast(count)) * font.glyph_width;
            fb.fillRect(x, y, width, font.glyph_height, bg_color);
        }

        // Render each glyph with the 5x7 bitmap font.
        var gx: i32 = x;
        for (0..count) |i| {
            const ch = src[i];
            if (ch == '\n' or ch == '\r') continue;
            const rows = font.glyphForChar(ch);
            var row: i32 = 0;
            while (row < font.glyph_height) : (row += 1) {
                const bits = rows[@intCast(row)];
                var col: i32 = 0;
                while (col < 5) : (col += 1) {
                    if ((bits >> @intCast(col)) & 1 != 0) {
                        fb.setPixel(gx + col, y + row, fg_color);
                    }
                }
            }
            gx += font.glyph_width;
        }
        if (fb.is_screen) renderer.markScreenDirty();
    }
    return 1;
}

pub fn TextOutW(hdc: usize, x: i32, y: i32, lpString: usize, c: i32) callconv(w32cc.WINAPI) i32 {
    // Widen ASCII-compatible wide strings by narrowing each wchar to its
    // low byte, then reuse the A renderer. Non-ASCII wchars render as '?'.
    if (lpString == 0 or c <= 0) return 1;
    var narrow_buf: [4096]u8 = undefined;
    const count: usize = @intCast(@min(c, 4096));
    const wsrc = @as([*]const u16, @ptrFromInt(trace.addr(lpString)));
    for (0..count) |i| {
        narrow_buf[i] = @intCast(wsrc[i] & 0xFF);
    }
    return TextOutA(hdc, x, y, @intFromPtr(&narrow_buf), @intCast(count));
}

pub fn SetPixel(hdc: usize, x: i32, y: i32, color: u32) callconv(w32cc.WINAPI) u32 {
    if (getFramebufferForDc(hdc)) |fb| {
        fb.setPixel(x, y, color);
        if (fb.is_screen) renderer.markScreenDirty();
    }
    return color;
}

pub fn GetPixel(hdc: usize, x: i32, y: i32) callconv(w32cc.WINAPI) u32 {
    if (getFramebufferForDc(hdc)) |fb| {
        return fb.getPixel(x, y);
    }
    return 0;
}

// Map DC handle to its current path position
var current_pos_x: i32 = 0;
var current_pos_y: i32 = 0;

pub fn MoveToEx(hdc: usize, x: i32, y: i32, lppt: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    if (lppt != 0) {
        const pt = @as(*w32.POINT, @ptrFromInt(lppt));
        pt.x = current_pos_x;
        pt.y = current_pos_y;
    }
    current_pos_x = x;
    current_pos_y = y;
    return 1;
}

pub fn LineTo(hdc: usize, x: i32, y: i32) callconv(w32cc.WINAPI) i32 {
    if (getFramebufferForDc(hdc)) |fb| {
        var pen_color: u32 = 0; // Black
        if (gdi32.getDc(hdc)) |dc| {
            if (gdi32.findObject(dc.pen)) |obj| {
                if (obj.obj_type == .Pen) pen_color = obj.data.pen.color;
            }
        }
        fb.drawLine(current_pos_x, current_pos_y, x, y, pen_color);
        if (fb.is_screen) renderer.markScreenDirty();
    }
    current_pos_x = x;
    current_pos_y = y;
    return 1;
}

pub fn Rectangle(hdc: usize, left: i32, top: i32, right: i32, bottom: i32) callconv(w32cc.WINAPI) i32 {
    if (getFramebufferForDc(hdc)) |fb| {
        var pen_color: u32 = 0; // Black
        var pen_style: i32 = 0; // Solid
        var brush_color: u32 = 0x00FFFFFF; // White
        var brush_style: i32 = 0; // Solid

        if (gdi32.getDc(hdc)) |dc| {
            if (gdi32.findObject(dc.pen)) |obj| {
                if (obj.obj_type == .Pen) {
                    pen_color = obj.data.pen.color;
                    pen_style = obj.data.pen.style;
                }
            }
            if (gdi32.findObject(dc.brush)) |obj| {
                if (obj.obj_type == .Brush) {
                    brush_color = obj.data.brush.color;
                    brush_style = obj.data.brush.style;
                }
            }
        }

        const w = if (right > left) right - left else 0;
        const h = if (bottom > top) bottom - top else 0;

        // Fill rect (if brush not NULL (5))
        if (brush_style != 5) { // Assuming 5 is NULL/HOLLOW_BRUSH or 1 (some systems use 1)
            // Need to correctly map NULL_BRUSH. I registered it with style=1 earlier.
            if (brush_style != 1) {
                fb.fillRect(left + 1, top + 1, w - 2, h - 2, brush_color);
            }
        }

        // Draw Outline (if pen not NULL)
        if (pen_style != 5) {
            fb.drawLine(left, top, right - 1, top, pen_color); // Top
            fb.drawLine(right - 1, top, right - 1, bottom - 1, pen_color); // Right
            fb.drawLine(right - 1, bottom - 1, left, bottom - 1, pen_color); // Bottom
            fb.drawLine(left, bottom - 1, left, top, pen_color); // Left
        }

        if (fb.is_screen) renderer.markScreenDirty();
    }
    return 1;
}

pub fn SetDIBitsToDevice(hdc: usize, xDest: i32, yDest: i32, w: u32, h: u32, xSrc: i32, ySrc: i32, StartScan: u32, cLines: u32, lpvBits: usize, lpbmi: usize, ColorUse: u32) callconv(w32cc.WINAPI) i32 {
    _ = ColorUse;
    const hdr = @as(*const w32.BITMAPINFOHEADER, @ptrFromInt(lpbmi));
    if (trace.enable_tracing) trace.print("GDI32: SetDIBitsToDevice(dst={d},{d} slice={d}x{d} @ {d},{d} start={d} lines={d} bits={x} biW={d} biH={d})\n", .{ xDest, yDest, w, h, xSrc, ySrc, StartScan, cLines, lpvBits, hdr.biWidth, hdr.biHeight });

    const dest_dib = gdi32.getDcDib(hdc);
    const dest_buf = if (dest_dib) |dib|
        @as([*]u8, @ptrFromInt(dib.buffer))[0 .. dib.width * dib.height * 4]
    else
        renderer.global_framebuf;

    const dest_w = if (dest_dib) |dib| dib.width else renderer.global_width;
    const dest_h = if (dest_dib) |dib| dib.height else renderer.global_height;

    blitDIBToBufferAt(lpvBits, lpbmi, dest_buf, dest_w, dest_h, xDest, yDest, xSrc, ySrc, w, h, cLines, 0x00CC0020); // SRCCOPY

    if (dest_dib == null) {
        renderer.markScreenDirty();
    }

    return @intCast(cLines);
}

pub fn stub_GetDIBits(hdc: usize, hbm: usize, start: u32, cLines: u32, lpvBits: usize, lpbmi: usize, usage: u32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = hbm;
    _ = start;
    _ = cLines;
    _ = lpvBits;
    _ = lpbmi;
    _ = usage;
    return 0;
}

pub fn PatBlt(hdc: usize, x: i32, y: i32, w: i32, h: i32, rop: u32) callconv(w32cc.WINAPI) i32 {
    if (getFramebufferForDc(hdc)) |fb| {
        var color: u32 = 0x00FFFFFF; // Default white

        // BLACKNESS = 0x00000042, WHITENESS = 0x00FF0062
        if (rop == 0x00000042) {
            color = 0x00000000; // Black
        } else if (rop == 0x00FF0062) {
            color = 0x00FFFFFF; // White
        } else {
            // PATCOPY (0x00F00021) or default: use the DC's selected brush color
            if (gdi32.getDc(hdc)) |dc| {
                if (gdi32.findObject(dc.brush)) |obj| {
                    if (obj.obj_type == .Brush) color = obj.data.brush.color;
                }
            }
        }

        fb.fillRect(x, y, w, h, color);
        if (fb.is_screen) renderer.markScreenDirty();
    }
    return 1;
}

/// ExtTextOutA: extended text output with opaque rectangle and character positioning.
/// Implementation status: Partially implemented (delegates to TextOutA after optional opaque rect)
pub fn ExtTextOutA(hdc: usize, x: i32, y: i32, options: u32, lprect: usize, lpString: usize, c: u32, lpDx: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpDx;
    // ETO_OPAQUE = 0x0002
    if (options & 0x0002 != 0 and lprect != 0) {
        // Fill opaque background rectangle
        if (getFramebufferForDc(hdc)) |fb| {
            const bg_color = if (gdi32.getDc(hdc)) |dc_e| dc_e.bk_color else 0x00FFFFFF;
            const left = @as(*const i32, @ptrFromInt(lprect)).*;
            const top = @as(*const i32, @ptrFromInt(lprect + 4)).*;
            const right = @as(*const i32, @ptrFromInt(lprect + 8)).*;
            const bot = @as(*const i32, @ptrFromInt(lprect + 12)).*;
            fb.fillRect(left, top, right - left, bot - top, bg_color);
            if (fb.is_screen) renderer.markScreenDirty();
        }
    }
    return TextOutA(hdc, x, y, lpString, @intCast(c));
}

/// ExtTextOutW: Unicode variant delegates to ExtTextOutA.
pub fn ExtTextOutW(hdc: usize, x: i32, y: i32, options: u32, lprect: usize, lpString: usize, c: u32, lpDx: usize) callconv(w32cc.WINAPI) i32 {
    return ExtTextOutA(hdc, x, y, options, lprect, lpString, c, lpDx);
}

pub fn stub_IntersectClipRect(hdc: usize, left: i32, top: i32, right: i32, bottom: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = left;
    _ = top;
    _ = right;
    _ = bottom;
    return 1; // SIMPLEREGION
}

pub fn stub_ExcludeClipRect(hdc: usize, left: i32, top: i32, right: i32, bottom: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = left;
    _ = top;
    _ = right;
    _ = bottom;
    return 1;
}

pub fn stub_CombineRgn(hrgnDst: usize, hrgnSrc1: usize, hrgnSrc2: usize, iMode: i32) callconv(w32cc.WINAPI) i32 {
    _ = hrgnDst;
    _ = hrgnSrc1;
    _ = hrgnSrc2;
    _ = iMode;
    return 1;
}

pub fn Ellipse(hdc: usize, left: i32, top: i32, right: i32, bottom: i32) callconv(w32cc.WINAPI) i32 {
    const fb = getFramebufferForDc(hdc) orelse return 1;

    var brush_color: u32 = 0x00FFFFFF;
    var brush_null = false;
    var pen_color: u32 = 0x00000000;

    if (gdi32.getDc(hdc)) |dc| {
        if (gdi32.findObject(dc.brush)) |obj| {
            if (obj.obj_type == .Brush) {
                brush_color = obj.data.brush.color;
                if (obj.data.brush.style == 1 or obj.data.brush.style == 5) brush_null = true;
            }
        }
        if (gdi32.findObject(dc.pen)) |obj| {
            if (obj.obj_type == .Pen) pen_color = obj.data.pen.color;
        }
    }

    const cx = @divTrunc(left + right, 2);
    const cy = @divTrunc(top + bottom, 2);
    const rx = @divTrunc(right - left, 2);
    const ry = @divTrunc(bottom - top, 2);

    if (rx <= 0 or ry <= 0) return 1;

    // Fill using scanlines
    if (!brush_null) {
        var y_off: i32 = -ry;
        while (y_off <= ry) : (y_off += 1) {
            // x^2/rx^2 + y^2/ry^2 = 1 → x = rx * sqrt(1 - y^2/ry^2)
            const yf: f64 = @floatFromInt(y_off);
            const ryf: f64 = @floatFromInt(ry);
            const rxf: f64 = @floatFromInt(rx);
            const ratio = 1.0 - (yf * yf) / (ryf * ryf);
            if (ratio < 0) continue;
            const x_span: i32 = @intFromFloat(rxf * @sqrt(ratio));
            fb.fillRect(cx - x_span, cy + y_off, x_span * 2, 1, brush_color);
        }
    }

    // Draw outline using midpoint algorithm (simplified: draw 4 border pixels per step)
    var y_off: i32 = -ry;
    while (y_off <= ry) : (y_off += 1) {
        const yf: f64 = @floatFromInt(y_off);
        const ryf: f64 = @floatFromInt(ry);
        const rxf: f64 = @floatFromInt(rx);
        const ratio = 1.0 - (yf * yf) / (ryf * ryf);
        if (ratio < 0) continue;
        const x_span: i32 = @intFromFloat(rxf * @sqrt(ratio));
        fb.setPixel(cx + x_span, cy + y_off, pen_color);
        fb.setPixel(cx - x_span, cy + y_off, pen_color);
    }

    if (fb.is_screen) renderer.markScreenDirty();
    return 1;
}

pub fn RoundRect(hdc: usize, left: i32, top: i32, right: i32, bottom: i32, width: i32, height: i32) callconv(w32cc.WINAPI) i32 {
    // Simplified: draw as a plain rectangle (corner rounding is cosmetic)
    _ = width;
    _ = height;
    return Rectangle(hdc, left, top, right, bottom);
}

pub fn Polygon(hdc: usize, apt: usize, cpt: i32) callconv(w32cc.WINAPI) i32 {
    if (apt == 0 or cpt < 3) return 1;
    const fb = getFramebufferForDc(hdc) orelse return 1;

    var pen_color: u32 = 0x00000000;
    var brush_color: u32 = 0x00FFFFFF;
    var brush_null = false;

    if (gdi32.getDc(hdc)) |dc| {
        if (gdi32.findObject(dc.pen)) |obj| {
            if (obj.obj_type == .Pen) pen_color = obj.data.pen.color;
        }
        if (gdi32.findObject(dc.brush)) |obj| {
            if (obj.obj_type == .Brush) {
                brush_color = obj.data.brush.color;
                if (obj.data.brush.style == 1 or obj.data.brush.style == 5) brush_null = true;
            }
        }
    }

    const pts = @as([*]const w32.POINT, @ptrFromInt(apt));
    const count: usize = @intCast(cpt);

    // Simple fill: find bounding box and use scanline with even-odd rule
    if (!brush_null) {
        var min_y: i32 = pts[0].y;
        var max_y: i32 = pts[0].y;
        for (0..count) |i| {
            if (pts[i].y < min_y) min_y = pts[i].y;
            if (pts[i].y > max_y) max_y = pts[i].y;
        }
        var scan_y = min_y;
        while (scan_y <= max_y) : (scan_y += 1) {
            // Count intersections with each edge
            var min_x: i32 = 10000;
            var max_x: i32 = -10000;
            var crossings: u32 = 0;
            for (0..count) |i| {
                const j = (i + 1) % count;
                const y0 = pts[i].y;
                const y1 = pts[j].y;
                if ((y0 <= scan_y and y1 > scan_y) or (y1 <= scan_y and y0 > scan_y)) {
                    crossings += 1;
                    const x0 = pts[i].x;
                    const x1 = pts[j].x;
                    const ix = x0 + @divTrunc((scan_y - y0) * (x1 - x0), (y1 - y0));
                    if (ix < min_x) min_x = ix;
                    if (ix > max_x) max_x = ix;
                }
            }
            if (crossings >= 2) {
                fb.fillRect(min_x, scan_y, max_x - min_x, 1, brush_color);
            }
        }
    }

    // Draw outline
    for (0..count) |i| {
        const j = (i + 1) % count;
        fb.drawLine(pts[i].x, pts[i].y, pts[j].x, pts[j].y, pen_color);
    }

    if (fb.is_screen) renderer.markScreenDirty();
    return 1;
}

pub fn Polyline(hdc: usize, apt: usize, cpt: i32) callconv(w32cc.WINAPI) i32 {
    if (apt == 0 or cpt < 2) return 1;
    const fb = getFramebufferForDc(hdc) orelse return 1;

    var pen_color: u32 = 0x00000000;
    if (gdi32.getDc(hdc)) |dc| {
        if (gdi32.findObject(dc.pen)) |obj| {
            if (obj.obj_type == .Pen) pen_color = obj.data.pen.color;
        }
    }

    const pts = @as([*]const w32.POINT, @ptrFromInt(apt));
    const count: usize = @intCast(cpt);
    for (1..count) |i| {
        fb.drawLine(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y, pen_color);
    }

    if (fb.is_screen) renderer.markScreenDirty();
    return 1;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;

fn makeDibHeader(w: i32, h: i32, bpp: u16) w32.BITMAPINFOHEADER {
    var hdr = std.mem.zeroes(w32.BITMAPINFOHEADER);
    hdr.biSize = @sizeOf(w32.BITMAPINFOHEADER);
    hdr.biWidth = w;
    hdr.biHeight = h;
    hdr.biBitCount = bpp;
    return hdr;
}

test "fillRect: fills clamped intersection with BGRA bytes" {
    var buf: [8 * 4 * 4]u8 = .{0} ** (8 * 4 * 4);
    const fb = FramebufferInfo{ .buf = &buf, .w = 8, .h = 4, .is_screen = false };

    // COLORREF 0x00102030: B=0x10 G=0x20 R=0x30 -> bytes B,G,R,A = 10 20 30 FF
    fb.fillRect(-2, -1, 5, 3, 0x00102030);

    // Row 0: columns 0..2 filled (x from -2..2 clipped to >=0)
    for (0..3) |x| {
        const di = x * 4;
        try testing.expectEqual(@as(u8, 0x10), buf[di + 0]);
        try testing.expectEqual(@as(u8, 0x20), buf[di + 1]);
        try testing.expectEqual(@as(u8, 0x30), buf[di + 2]);
        try testing.expectEqual(@as(u8, 0xFF), buf[di + 3]);
    }
    // Column 3 on row 0 untouched
    try testing.expectEqual(@as(u8, 0), buf[12]);
    // Rows 1..2 fully filled
    try testing.expectEqual(@as(u8, 0x10), buf[4 * 8]);
    // Row 3 untouched
    try testing.expectEqual(@as(u8, 0), buf[4 * 24]);

    // Rect entirely outside the buffer is a no-op
    fb.fillRect(100, 100, 10, 10, 0x00FFFFFF);
    try testing.expectEqual(@as(u8, 0), buf[4 * 24]);
}

test "blitDIBToBufferAt: 32bpp top-down copy with clipping" {
    // 4x2 top-down source. Source pixels are byte triplets (b,g,r); the blit
    // writes dest in its long-standing r,g,b order and forces alpha 255.
    var src_bytes: [8 * 4]u8 = undefined;
    for (0..8) |i| {
        src_bytes[i * 4 + 0] = @intCast(i); // B
        src_bytes[i * 4 + 1] = @intCast(i * 2); // G
        src_bytes[i * 4 + 2] = @intCast(i * 3); // R
        src_bytes[i * 4 + 3] = 0xAA; // A (dropped by the blit)
    }
    const expectWord = struct {
        // Dest byte order is r,g,b,255 (long-standing behavior pinned here).
        fn f(idx: usize) u32 {
            const b: u32 = @intCast(idx);
            const g: u32 = @intCast(idx * 2);
            const r: u32 = @intCast(idx * 3);
            return 0xFF000000 | (b << 16) | (g << 8) | r;
        }
    }.f;

    const header = makeDibHeader(4, -2, 32); // negative height = top-down
    var dest: [4 * 2 * 4]u8 = .{0} ** (4 * 2 * 4);

    // Full copy at offset 0
    blitDIBToBufferAt(@intFromPtr(&src_bytes), @intFromPtr(&header), &dest, 4, 2, 0, 0, 0, 0, 4, 2, null, 0x00CC0020);
    for (0..8) |i| {
        try testing.expectEqual(expectWord(i), std.mem.readInt(u32, dest[i * 4 ..][0..4], .little));
    }

    // Clip: shift right by 2 and down by 1 — only source cols 0..1 land in dest
    @memset(&dest, 0);
    blitDIBToBufferAt(@intFromPtr(&src_bytes), @intFromPtr(&header), &dest, 4, 2, 2, 1, 0, 0, 4, 2, null, 0x00CC0020);
    // dest row 1, col 2 = src row 0 col 0
    try testing.expectEqual(expectWord(0), std.mem.readInt(u32, dest[(4 + 2) * 4 ..][0..4], .little));
    try testing.expectEqual(expectWord(1), std.mem.readInt(u32, dest[(4 + 3) * 4 ..][0..4], .little));
    // dest row 0 untouched
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, dest[0..4], .little));
}

test "blitDIBToBufferAt: 32bpp bottom-up row order" {
    // Positive biHeight = bottom-up: the first stored row is the BOTTOM
    // image row, so it lands in the last dest row.
    var src_bytes: [4 * 2 * 4]u8 = .{0} ** (4 * 2 * 4);
    const header_td = makeDibHeader(4, -2, 32);
    const header_bu = makeDibHeader(4, 2, 32);
    var dest: [4 * 2 * 4]u8 = .{0} ** (4 * 2 * 4);

    // Mark source row 0 (physical) with a recognizable R byte = 0x77.
    @memset(src_bytes[0..16], 0x11);
    @memset(src_bytes[16..32], 0x22);
    src_bytes[2] = 0x77;

    blitDIBToBufferAt(@intFromPtr(&src_bytes), @intFromPtr(&header_td), &dest, 4, 2, 0, 0, 0, 0, 4, 2, null, 0x00CC0020);
    try testing.expectEqual(@as(u32, 0xFF111177), std.mem.readInt(u32, dest[0..4], .little)); // top-down: row 0 first

    @memset(&dest, 0);
    blitDIBToBufferAt(@intFromPtr(&src_bytes), @intFromPtr(&header_bu), &dest, 4, 2, 0, 0, 0, 0, 4, 2, null, 0x00CC0020);
    try testing.expectEqual(@as(u32, 0xFF111177), std.mem.readInt(u32, dest[4 * 4 ..][0..4], .little)); // bottom-up: row 0 lands last
}

test "blitDIBToBufferAt: SRCPAINT ORs into destination" {
    var src_px = [_]u32{0xFF101010};
    const header = makeDibHeader(1, 1, 32);
    var dest: [4]u8 = .{ 0x00, 0x20, 0x40, 0x80 };
    blitDIBToBufferAt(@intFromPtr(&src_px), @intFromPtr(&header), &dest, 1, 1, 0, 0, 0, 0, 1, 1, null, 0x00EE0086);
    try testing.expectEqual(@as(u8, 0x10), dest[0]);
    try testing.expectEqual(@as(u8, 0x30), dest[1]);
    try testing.expectEqual(@as(u8, 0x50), dest[2]);
    try testing.expectEqual(@as(u8, 0xFF), dest[3]); // alpha forced opaque
}

test "StretchBlt: 2x upscale maps source by floor(dx*wSrc/wd)" {
    const gdi = @import("../gdi32.zig");

    // 2x1 source scaled to 4x2: sx(dx) = xSrc + floor(dx*2/4) -> 0,0,1,1.
    var src_px = [_]u32{ 0xFF111111, 0xFF222222 };
    var dest_px = [_]u32{0} ** (4 * 2);

    gdi.registerDib(0xBEEF0001, @intFromPtr(&src_px), 2, 1, 32);
    gdi.registerDib(0xBEEF0002, @intFromPtr(&dest_px), 4, 2, 32);
    gdi.registerDc(0xCAFE0001);
    gdi.bindDcBitmap(0xCAFE0001, 0xBEEF0001);
    gdi.registerDc(0xCAFE0002);
    gdi.bindDcBitmap(0xCAFE0002, 0xBEEF0002);

    const rc = StretchBlt(0xCAFE0002, 0, 0, 4, 2, 0xCAFE0001, 0, 0, 2, 1);
    try testing.expectEqual(@as(i32, 1), rc);
    for (0..4) |x| {
        const expect: u32 = if (x < 2) src_px[0] else src_px[1];
        for (0..2) |y| {
            try testing.expectEqual(expect, dest_px[y * 4 + x]);
        }
    }
}

test "StretchBlt: negative source origin is a no-op" {
    // The old per-pixel code would have panicked casting a negative xSrc to
    // u32; the incremental version must skip drawing instead.
    const gdi = @import("../gdi32.zig");
    var src_px = [_]u32{0xFF111111};
    var dest_px = [_]u32{0} ** (2 * 2);

    gdi.registerDib(0xBEEF0003, @intFromPtr(&src_px), 1, 1, 32);
    gdi.registerDib(0xBEEF0004, @intFromPtr(&dest_px), 2, 2, 32);
    gdi.registerDc(0xCAFE0003);
    gdi.bindDcBitmap(0xCAFE0003, 0xBEEF0003);
    gdi.registerDc(0xCAFE0004);
    gdi.bindDcBitmap(0xCAFE0004, 0xBEEF0004);

    const rc = StretchBlt(0xCAFE0004, 0, 0, 2, 2, 0xCAFE0003, -4, -4, 1, 1);
    try testing.expectEqual(@as(i32, 1), rc);
    for (dest_px) |px| try testing.expectEqual(@as(u32, 0), px);
}
