//! GDI Device Context (DC) management.
const std = @import("std");
const trace = @import("../../trace.zig");
const gdi32 = @import("../gdi32.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");

/// Retrieves device-specific information for the specified device.
/// Implementation status: Partially implemented (returns fixed values for a 1024x768 32bpp display)
pub fn GetDeviceCaps(hdc: usize, nIndex: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    if (trace.enable_tracing) trace.print("GDI32: GetDeviceCaps({d})\n", .{nIndex});
    return switch (nIndex) {
        w32.TECHNOLOGY => 1, // DT_RASDISPLAY
        w32.HORZRES => 1024,
        w32.VERTRES => 768,
        w32.BITSPIXEL => 32,
        w32.PLANES => 1,
        w32.NUMCOLORS => 256,
        w32.LOGPIXELSX => 96,
        w32.LOGPIXELSY => 96,
        w32.SIZEPALETTE => 256,
        w32.DESKTOPVERTRES => 768,
        w32.DESKTOPHORZRES => 1024,
        else => 1,
    };
}

/// Creates a memory device context (DC) compatible with the specified device.
/// Implementation status: Fully implemented (registers a new DC in the global GDI object table)
pub fn CreateCompatibleDC(hdc: usize) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    const handle = gdi32.nextHandle();
    gdi32.registerDc(handle);
    if (trace.enable_tracing) trace.print("GDI32: CreateCompatibleDC -> 0x{x}\n", .{handle});
    return handle;
}

/// Deletes the specified device context (DC).
/// Implementation status: Fully implemented (removes the DC from the global table)
pub fn stub_DeleteDC(hdc: usize) callconv(w32cc.WINAPI) i32 {
    _ = gdi32.unregisterDc(hdc);
    return 1;
}

// --- SaveDC / RestoreDC ---
// Simple DC save stack (max 32 saved states per DC)
var saved_dc_stack: [32]gdi32.DeviceContext = undefined;
var saved_dc_count: usize = 0;

/// Saves the current state of the specified device context (DC) by copying
/// its attributes to a stack.
/// Implementation status: Partially implemented (uses a fixed-size global stack of 32 states)
pub fn SaveDC(hdc: usize) callconv(w32cc.WINAPI) i32 {
    if (gdi32.getDc(hdc)) |dc| {
        if (saved_dc_count < saved_dc_stack.len) {
            saved_dc_stack[saved_dc_count] = dc.*;
            saved_dc_count += 1;
            return @intCast(saved_dc_count); // 1-based save ID
        }
    }
    return 0; // failure
}

/// Restores a device context (DC) to the specified state.
/// Implementation status: Partially implemented (restores attributes from the global save stack)
pub fn RestoreDC(hdc: usize, nSavedDC: i32) callconv(w32cc.WINAPI) i32 {
    if (gdi32.getDc(hdc)) |dc| {
        if (nSavedDC == -1 and saved_dc_count > 0) {
            // Restore most recently saved
            saved_dc_count -= 1;
            dc.* = saved_dc_stack[saved_dc_count];
            return 1;
        } else if (nSavedDC > 0 and @as(usize, @intCast(nSavedDC)) <= saved_dc_count) {
            const idx: usize = @intCast(nSavedDC - 1);
            dc.* = saved_dc_stack[idx];
            saved_dc_count = idx;
            return 1;
        }
    }
    return 0;
}

/// Sets the background mix mode of the specified device context.
/// Implementation status: Fully implemented (updates the DC's bk_mode attribute)
pub fn SetBkMode(hdc: usize, mode: i32) callconv(w32cc.WINAPI) i32 {
    var old_mode: i32 = 1; // OPAQUE previous
    if (gdi32.getDc(hdc)) |dc_entry| {
        old_mode = dc_entry.bk_mode;
        dc_entry.bk_mode = mode;
    }
    return old_mode;
}

/// Sets the background color of the specified device context to the specified color.
/// Implementation status: Fully implemented
pub fn SetBkColor(hdc: usize, crColor: u32) callconv(w32cc.WINAPI) u32 {
    var old_color: u32 = 0x00FFFFFF;
    if (gdi32.getDc(hdc)) |dc_entry| {
        old_color = dc_entry.bk_color;
        dc_entry.bk_color = crColor;
    }
    return old_color;
}

/// Sets the text color of the specified device context to the specified color.
/// Implementation status: Fully implemented
pub fn SetTextColor(hdc: usize, crColor: u32) callconv(w32cc.WINAPI) u32 {
    var old_color: u32 = 0;
    if (gdi32.getDc(hdc)) |dc_entry| {
        old_color = dc_entry.text_color;
        dc_entry.text_color = crColor;
    }
    return old_color;
}

/// Retrieves the text color of the specified device context.
/// Implementation status: Fully implemented
pub fn GetTextColor(hdc: usize) callconv(w32cc.WINAPI) u32 {
    if (gdi32.getDc(hdc)) |dc_entry| {
        return dc_entry.text_color;
    }
    return 0; // Black
}

/// Sets the stretching mode for bitmaps in the specified device context.
/// Implementation status: Fully implemented
pub fn SetStretchBltMode(hdc: usize, mode: i32) callconv(w32cc.WINAPI) i32 {
    var old_mode: i32 = 1; // BLACKONWHITE
    if (gdi32.getDc(hdc)) |dc| {
        old_mode = dc.stretch_mode;
        dc.stretch_mode = mode;
    }
    return old_mode;
}

/// Sets the mapping mode of the specified device context.
/// Implementation status: Fully implemented
pub fn SetMapMode(hdc: usize, iMode: i32) callconv(w32cc.WINAPI) i32 {
    var old_mode: i32 = 1; // MM_TEXT
    if (gdi32.getDc(hdc)) |dc| {
        old_mode = dc.map_mode;
        dc.map_mode = iMode;
    }
    return old_mode;
}

/// Sets the current foreground mix mode of the specified device context.
/// Implementation status: Fully implemented
pub fn SetROP2(hdc: usize, rop2: i32) callconv(w32cc.WINAPI) i32 {
    var old_rop: i32 = 13; // R2_COPYPEN
    if (gdi32.getDc(hdc)) |dc| {
        old_rop = dc.rop2;
        dc.rop2 = rop2;
    }
    return old_rop;
}

/// Helper: get the FontData for the font currently selected into a DC.
fn getSelectedFont(hdc: usize) gdi32.FontData {
    if (gdi32.getDc(hdc)) |dc_entry| {
        if (dc_entry.font != 0) {
            if (gdi32.findObject(dc_entry.font)) |obj| {
                if (obj.obj_type == .Font) return obj.data.font;
            }
        }
    }
    return gdi32.FontData{}; // Default: MS Sans Serif 13px
}

/// Retrieves the metrics for the currently selected font.
/// Implementation status: Partially implemented (derives metrics from stored font height)
pub fn GetTextMetricsA(hdc: usize, lptm: usize) callconv(w32cc.WINAPI) i32 {
    if (lptm != 0) {
        const fd = getSelectedFont(hdc);
        const h = fd.tmHeight();
        const aw = fd.aveCharWidth();
        const tm = @as(*w32.TEXTMETRICA, @ptrFromInt(lptm));
        tm.* = .{}; // zero all fields
        tm.tmHeight = h;
        tm.tmAscent = @divTrunc(h * 85, 100); // ~85% ascent
        tm.tmDescent = h - tm.tmAscent;
        tm.tmInternalLeading = @max(@divTrunc(h, 6), 1);
        tm.tmExternalLeading = 0;
        tm.tmAveCharWidth = aw;
        tm.tmMaxCharWidth = aw * 2;
    }
    return 1;
}

/// Retrieves the metrics for the currently selected font (Unicode).
/// Implementation status: Partially implemented (alias to ANSI)
pub fn GetTextMetricsW(hdc: usize, lptm: usize) callconv(w32cc.WINAPI) i32 {
    return GetTextMetricsA(hdc, lptm);
}

/// Computes the width and height of the specified string of text.
/// Implementation status: Partially implemented (derives from selected font height)
pub fn GetTextExtentPoint32A(hdc: usize, lpString: usize, c: i32, lpSize: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpString;
    if (lpSize != 0) {
        const fd = getSelectedFont(hdc);
        const size = @as(*w32.SIZE, @ptrFromInt(lpSize));
        size.cx = fd.aveCharWidth() * @as(i32, if (c > 0) c else 0);
        size.cy = fd.tmHeight();
    }
    return 1;
}

/// Computes the width and height of the specified string of text (Unicode).
/// Implementation status: Partially implemented (alias to ANSI)
pub fn GetTextExtentPoint32W(hdc: usize, lpString: usize, c: i32, lpSize: usize) callconv(w32cc.WINAPI) i32 {
    return GetTextExtentPoint32A(hdc, lpString, c, lpSize);
}

/// Sets the text-alignment flags for the specified device context.
/// Implementation status: Fully implemented
pub fn SetTextAlign(hdc: usize, fMode: u32) callconv(w32cc.WINAPI) u32 {
    var old_align: u32 = 0;
    if (gdi32.getDc(hdc)) |dc| {
        old_align = dc.text_align;
        dc.text_align = fMode;
    }
    return old_align;
}

pub fn GetTextAlign(hdc: usize) callconv(w32cc.WINAPI) u32 {
    if (gdi32.getDc(hdc)) |dc| return dc.text_align;
    return 0;
}

/// Creates a device context (DC) for a device using the specified name.
/// Implementation status: Partially implemented (registers a generic DC)
pub fn CreateDCA(lpszDriver: usize, lpszDevice: usize, lpszOutput: usize, lpInitData: usize) callconv(w32cc.WINAPI) usize {
    _ = lpszDriver;
    _ = lpszDevice;
    _ = lpszOutput;
    _ = lpInitData;
    if (trace.enable_tracing) trace.print("GDI32: CreateDCA\n", .{});
    const handle = gdi32.nextHandle();
    gdi32.registerDc(handle);
    return handle;
}

/// Retrieves the color that most closely matches the specified color.
/// Implementation status: Stub
pub fn stub_GetNearestColor(hdc: usize, color: u32) callconv(w32cc.WINAPI) u32 {
    _ = hdc;
    return color;
}

/// Updates the colors in the client area of the specified DC.
/// Implementation status: Stub
pub fn stub_UpdateColors(hdc: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    return 0;
}

/// Retrieves the number of characters in a string that will fit within a specified space.
/// Implementation status: Partially implemented (derives from selected font)
pub fn GetTextExtentExPointA(hdc: usize, lpszString: usize, cchString: i32, nMaxExtent: i32, lpnFit: usize, lpnDx: usize, lpSize: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpszString;
    _ = nMaxExtent;
    const fd = getSelectedFont(hdc);
    const aw = fd.aveCharWidth();
    if (lpnFit != 0) @as(*i32, @ptrFromInt(lpnFit)).* = cchString;
    if (lpSize != 0) {
        const size = @as(*w32.SIZE, @ptrFromInt(lpSize));
        size.cx = @as(i32, cchString) * aw;
        size.cy = fd.tmHeight();
    }
    if (lpnDx != 0) {
        const dx = @as([*]i32, @ptrFromInt(lpnDx));
        const count: usize = @intCast(@max(cchString, 0));
        for (0..@min(count, 1024)) |i| {
            dx[i] = @intCast(@as(i32, @intCast(i + 1)) * aw);
        }
    }
    return 1;
}

/// Retrieves character placement information (Unicode).
/// Implementation status: Stub
pub fn stub_GetCharacterPlacementW(hdc: usize, lpString: usize, nCount: i32, nMexExtent: i32, lpResults: usize, dwFlags: u32, extra: usize) callconv(w32cc.WINAPI) u32 {
    _ = hdc;
    _ = lpString;
    _ = nCount;
    _ = nMexExtent;
    _ = lpResults;
    _ = dwFlags;
    _ = extra;
    return 0;
}

/// Translates charset information.
/// Implementation status: Stub
pub fn stub_TranslateCharsetInfo(lpSrc: usize, lpCs: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = lpSrc;
    _ = lpCs;
    _ = dwFlags;
    return 0;
}

/// Retrieves the widths of consecutive characters in a specified range.
/// Implementation status: Partially implemented (uses selected font's aveCharWidth)
pub fn GetCharWidthA(hdc: usize, iFirst: u32, iLast: u32, lpBuffer: usize) callconv(w32cc.WINAPI) i32 {
    const fd = getSelectedFont(hdc);
    const aw = fd.aveCharWidth();
    if (lpBuffer != 0 and iLast >= iFirst) {
        const count = iLast - iFirst + 1;
        const buf = @as([*]i32, @ptrFromInt(lpBuffer));
        for (0..@min(count, 256)) |i| {
            buf[i] = aw;
        }
    }
    return 1;
}

/// Sets the window extent for the specified DC.
/// Implementation status: Partially implemented
pub fn SetWindowExtEx(hdc: usize, x: i32, y: i32, lpSize: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = x;
    _ = y;
    if (lpSize != 0) {
        const size = @as(*w32.SIZE, @ptrFromInt(lpSize));
        size.cx = 1;
        size.cy = 1;
    }
    return 1;
}

/// Sets the viewport extent for the specified DC.
/// Implementation status: Partially implemented
pub fn SetViewportExtEx(hdc: usize, x: i32, y: i32, lpSize: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = x;
    _ = y;
    if (lpSize != 0) {
        const size = @as(*w32.SIZE, @ptrFromInt(lpSize));
        size.cx = 1;
        size.cy = 1;
    }
    return 1;
}

/// Determines whether any part of the specified rectangle is within the clipping region of a DC.
/// Implementation status: Stub (always returns 1)
pub fn stub_RectVisible(hdc: usize, lprc: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = lprc;
    return 1; // TRUE — rect is visible
}

/// Retrieves the background mix mode of the specified DC.
/// Implementation status: Fully implemented
pub fn GetBkMode(hdc: usize) callconv(w32cc.WINAPI) i32 {
    if (gdi32.getDc(hdc)) |dc_entry| {
        return dc_entry.bk_mode;
    }
    return 2; // OPAQUE
}

/// Retrieves the background color of the specified DC.
/// Implementation status: Fully implemented
pub fn GetBkColor(hdc: usize) callconv(w32cc.WINAPI) u32 {
    if (gdi32.getDc(hdc)) |dc_entry| {
        return dc_entry.bk_color;
    }
    return 0x00FFFFFF; // RGB(255, 255, 255) = white
}

/// Retrieves the current position in logical coordinates for the specified DC.
/// Implementation status: Stub (always returns 0,0)
pub fn GetCurrentPositionEx(hdc: usize, lppt: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    if (trace.enable_tracing) trace.print("GDI32: GetCurrentPositionEx\n", .{});
    if (lppt != 0) {
        @as(*align(1) i32, @ptrFromInt(lppt)).* = 0; // x
        @as(*align(1) i32, @ptrFromInt(lppt + 4)).* = 0; // y
    }
    return 1;
}

/// Sets the viewport origin of the specified DC.
/// Implementation status: Stub (stores no state, returns previous origin as 0,0)
pub fn SetViewportOrgEx(hdc: usize, x: i32, y: i32, lppt: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    if (trace.enable_tracing) trace.print("GDI32: SetViewportOrgEx(x={d}, y={d})\n", .{ x, y });
    if (lppt != 0) {
        @as(*align(1) i32, @ptrFromInt(lppt)).* = 0; // previous x
        @as(*align(1) i32, @ptrFromInt(lppt + 4)).* = 0; // previous y
    }
    return 1;
}

/// Retrieves the face name of the font selected into the DC.
pub fn GetTextFaceA(hdc: usize, c: i32, lpName: usize) callconv(w32cc.WINAPI) i32 {
    const fd = getSelectedFont(hdc);
    const face = if (fd.face_len > 0) fd.face_name[0..fd.face_len] else "MS Sans Serif";
    if (lpName != 0 and c > 0) {
        const buf = @as([*]u8, @ptrFromInt(lpName));
        const copy_len = @min(face.len, @as(usize, @intCast(c)) -| 1);
        @memcpy(buf[0..copy_len], face[0..copy_len]);
        buf[copy_len] = 0;
        return @intCast(copy_len);
    }
    return @intCast(face.len);
}

test "DeleteDC removes DC entries so create/delete cycles stay bounded" {
    const saved_dcs = gdi32.dc_entries;
    const saved_count = gdi32.dc_count;
    defer {
        gdi32.dc_entries = saved_dcs;
        gdi32.dc_count = saved_count;
    }

    gdi32.dc_entries = [_]gdi32.DeviceContext{.{
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
    }} ** gdi32.dc_entries.len;
    gdi32.dc_count = 0;

    var first_hdc: usize = 0;
    for (0..gdi32.dc_entries.len) |i| {
        _ = CreateCompatibleDC(0);
        if (i == 0) first_hdc = gdi32.dc_entries[0].handle;
    }
    try std.testing.expectEqual(gdi32.dc_entries.len, gdi32.dc_count);

    // Delete the DCs; each delete must free a slot.
    while (gdi32.dc_count > 0) {
        const h = gdi32.dc_entries[0].handle;
        _ = stub_DeleteDC(h);
    }
    try std.testing.expectEqual(@as(usize, 0), gdi32.dc_count);
}
