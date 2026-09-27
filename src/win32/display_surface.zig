//! Primary display surface shared by the DirectDraw and Direct3D 7 DLLs.
//!
//! Both DDRAW and D3D7 present through the same guest-visible primary
//! surface: one pixel buffer plus the current display mode. It lives here
//! rather than in either DLL so the two stub modules do not import each
//! other.

const renderer = @import("../gui/renderer.zig");

/// Primary surface pixel buffer. Owned by whichever DLL allocated it.
pub var buffer: []u8 = &[_]u8{};

/// Current display mode width.
pub var width: u32 = 640;
/// Current display mode height.
pub var height: u32 = 480;
/// Current display mode bits per pixel.
pub var bpp: u32 = 32;

/// Bytes per pixel for the current display mode.
pub fn bytesPerPixel() u32 {
    return if (bpp == 16) 2 else 4;
}

pub inline fn unpack16To32(src: [*]const u8, si: usize, di: usize) void {
    const lo: u16 = src[si * 2];
    const hi: u16 = src[si * 2 + 1];
    const rgb565 = lo | (hi << 8);
    renderer.global_framebuf[di * 4 + 0] = @truncate((rgb565 >> 11) << 3);
    renderer.global_framebuf[di * 4 + 1] = @truncate(((rgb565 >> 5) & 0x3F) << 2);
    renderer.global_framebuf[di * 4 + 2] = @truncate((rgb565 & 0x1F) << 3);
    renderer.global_framebuf[di * 4 + 3] = 255;
}

pub inline fn unpack32To32(src: [*]const u8, si: usize, di: usize) void {
    renderer.global_framebuf[di * 4 + 0] = src[si * 4 + 2]; // R <- B
    renderer.global_framebuf[di * 4 + 1] = src[si * 4 + 1]; // G
    renderer.global_framebuf[di * 4 + 2] = src[si * 4 + 0]; // B <- R
    renderer.global_framebuf[di * 4 + 3] = 255; // A
}

/// Convert the module-level `buffer` to BGRA in global_framebuf and push frame.
/// Handles both 16bpp RGB565 and 32bpp BGRA based on current display mode. Both
/// paths unpack per pixel; there is no direct-copy fast path.
/// Implementation status: Fully implemented
pub fn pushFrame() void {
    const vw = renderer.global_width;
    const vh = renderer.global_height;
    const pixels = vw * vh;
    const src_bpp = bytesPerPixel();

    if (buffer.len < pixels * src_bpp) return;

    if (bpp == 16) {
        for (0..pixels) |i| {
            unpack16To32(buffer.ptr, i, i);
        }
    } else {
        for (0..pixels) |i| {
            unpack32To32(buffer.ptr, i, i);
        }
    }
    renderer.pushFrame();
}
