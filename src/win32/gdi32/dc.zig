const trace = @import("../../trace.zig");
const gdi32 = @import("../gdi32.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn GetDeviceCaps(hdc: usize, nIndex: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    if (trace.enable_tracing) trace.print("GDI32: GetDeviceCaps({d})\n", .{nIndex});
    return switch (nIndex) {
        w32.TECHNOLOGY => 1,  // DT_RASDISPLAY
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

pub fn CreateCompatibleDC(hdc: usize) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    const handle = gdi32.nextHandle();
    gdi32.registerDc(handle);
    if (trace.enable_tracing) trace.print("GDI32: CreateCompatibleDC -> 0x{x}\n", .{handle});
    return handle;
}

pub fn stub_DeleteDC(hdc: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    return 1;
}

// --- SaveDC / RestoreDC ---
// Simple DC save stack (max 32 saved states per DC)
var saved_dc_stack: [32]gdi32.DeviceContext = undefined;
var saved_dc_count: usize = 0;

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

pub fn RestoreDC(hdc: usize, nSavedDC: i32) callconv(w32cc.WINAPI) i32 {
    if (gdi32.getDc(hdc)) |dc| {
        if (nSavedDC == -1 and saved_dc_count > 0) {
            // Restore most recently saved
            saved_dc_count -= 1;
            const saved = saved_dc_stack[saved_dc_count];
            dc.bitmap = saved.bitmap;
            dc.brush = saved.brush;
            dc.pen = saved.pen;
            dc.font = saved.font;
            dc.bk_mode = saved.bk_mode;
            dc.bk_color = saved.bk_color;
            dc.text_color = saved.text_color;
            dc.rop2 = saved.rop2;
            dc.stretch_mode = saved.stretch_mode;
            dc.text_align = saved.text_align;
            dc.map_mode = saved.map_mode;
            return 1;
        } else if (nSavedDC > 0 and @as(usize, @intCast(nSavedDC)) <= saved_dc_count) {
            const idx: usize = @intCast(nSavedDC - 1);
            const saved = saved_dc_stack[idx];
            dc.bitmap = saved.bitmap;
            dc.brush = saved.brush;
            dc.pen = saved.pen;
            dc.font = saved.font;
            dc.bk_mode = saved.bk_mode;
            dc.bk_color = saved.bk_color;
            dc.text_color = saved.text_color;
            dc.rop2 = saved.rop2;
            dc.stretch_mode = saved.stretch_mode;
            dc.text_align = saved.text_align;
            dc.map_mode = saved.map_mode;
            saved_dc_count = idx;
            return 1;
        }
    }
    return 0;
}

pub fn SetBkMode(hdc: usize, mode: i32) callconv(w32cc.WINAPI) i32 {
    var old_mode: i32 = 1; // OPAQUE previous
    if (gdi32.getDc(hdc)) |dc_entry| {
        old_mode = dc_entry.bk_mode;
        dc_entry.bk_mode = mode;
    }
    return old_mode;
}

pub fn SetBkColor(hdc: usize, crColor: u32) callconv(w32cc.WINAPI) u32 {
    var old_color: u32 = 0x00FFFFFF;
    if (gdi32.getDc(hdc)) |dc_entry| {
        old_color = dc_entry.bk_color;
        dc_entry.bk_color = crColor;
    }
    return old_color;
}

pub fn SetTextColor(hdc: usize, crColor: u32) callconv(w32cc.WINAPI) u32 {
    var old_color: u32 = 0;
    if (gdi32.getDc(hdc)) |dc_entry| {
        old_color = dc_entry.text_color;
        dc_entry.text_color = crColor;
    }
    return old_color;
}

pub fn GetTextColor(hdc: usize) callconv(w32cc.WINAPI) u32 {
    if (gdi32.getDc(hdc)) |dc_entry| {
        return dc_entry.text_color;
    }
    return 0; // Black
}

pub fn SetStretchBltMode(hdc: usize, mode: i32) callconv(w32cc.WINAPI) i32 {
    var old_mode: i32 = 1; // BLACKONWHITE
    if (gdi32.getDc(hdc)) |dc| {
        old_mode = dc.stretch_mode;
        dc.stretch_mode = mode;
    }
    return old_mode;
}

pub fn SetMapMode(hdc: usize, iMode: i32) callconv(w32cc.WINAPI) i32 {
    var old_mode: i32 = 1; // MM_TEXT
    if (gdi32.getDc(hdc)) |dc| {
        old_mode = dc.map_mode;
        dc.map_mode = iMode;
    }
    return old_mode;
}

pub fn SetROP2(hdc: usize, rop2: i32) callconv(w32cc.WINAPI) i32 {
    var old_rop: i32 = 13; // R2_COPYPEN
    if (gdi32.getDc(hdc)) |dc| {
        old_rop = dc.rop2;
        dc.rop2 = rop2;
    }
    return old_rop;
}

pub fn GetTextMetricsA(hdc: usize, lptm: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    if (lptm != 0) {
        const tm = @as(*w32.TEXTMETRICA, @ptrFromInt(lptm));
        tm.* = .{}; // zero all fields
        tm.tmHeight = 13;
        tm.tmAscent = 11;
        tm.tmDescent = 2;
        tm.tmInternalLeading = 2;
        tm.tmExternalLeading = 0;
        tm.tmAveCharWidth = 6;  // used for DLU: horiz DLU = tmAveCharWidth / 4
        tm.tmMaxCharWidth = 11;
    }
    return 1;
}

pub fn GetTextMetricsW(hdc: usize, lptm: usize) callconv(w32cc.WINAPI) i32 {
    return GetTextMetricsA(hdc, lptm);
}

pub fn GetTextExtentPoint32A(hdc: usize, lpString: usize, c: i32, lpSize: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = lpString;
    if (lpSize != 0) {
        const size = @as(*w32.SIZE, @ptrFromInt(lpSize));
        size.cx = 6 * @as(i32, if (c > 0) c else 0); // avgCharWidth(6) * len
        size.cy = 13; // tmHeight
    }
    return 1;
}

pub fn GetTextExtentPoint32W(hdc: usize, lpString: usize, c: i32, lpSize: usize) callconv(w32cc.WINAPI) i32 {
    return GetTextExtentPoint32A(hdc, lpString, c, lpSize);
}

pub fn SetTextAlign(hdc: usize, fMode: u32) callconv(w32cc.WINAPI) u32 {
    var old_align: u32 = 0;
    if (gdi32.getDc(hdc)) |dc| {
        old_align = dc.text_align;
        dc.text_align = fMode;
    }
    return old_align;
}

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

pub fn stub_GetNearestColor(hdc: usize, color: u32) callconv(w32cc.WINAPI) u32 {
    _ = hdc;
    return color;
}

pub fn stub_UpdateColors(hdc: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    return 0;
}

pub fn GetTextExtentExPointA(hdc: usize, lpszString: usize, cchString: i32, nMaxExtent: i32, lpnFit: usize, lpnDx: usize, lpSize: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = lpszString;
    _ = nMaxExtent;
    if (lpnFit != 0) @as(*i32, @ptrFromInt(lpnFit)).* = cchString;
    if (lpSize != 0) {
        const size = @as(*w32.SIZE, @ptrFromInt(lpSize));
        size.cx = @as(i32, cchString) * 6;
        size.cy = 13;
    }
    if (lpnDx != 0) {
        const dx = @as([*]i32, @ptrFromInt(lpnDx));
        const count: usize = @intCast(@max(cchString, 0));
        for (0..@min(count, 1024)) |i| {
            dx[i] = @intCast(@as(i32, @intCast(i + 1)) * 6);
        }
    }
    return 1;
}

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

pub fn stub_TranslateCharsetInfo(lpSrc: usize, lpCs: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = lpSrc;
    _ = lpCs;
    _ = dwFlags;
    return 0;
}

pub fn GetCharWidthA(hdc: usize, iFirst: u32, iLast: u32, lpBuffer: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    if (lpBuffer != 0 and iLast >= iFirst) {
        const count = iLast - iFirst + 1;
        const buf = @as([*]i32, @ptrFromInt(lpBuffer));
        for (0..@min(count, 256)) |i| {
            buf[i] = 6; // avgCharWidth for MS Sans Serif 8pt
        }
    }
    return 1;
}

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

// RectVisible: is any part of the given rect visible in the clip region?
// Always return TRUE since we don't track clipping
pub fn stub_RectVisible(hdc: usize, lprc: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc; _ = lprc;
    return 1; // TRUE — rect is visible
}

// GetBkMode: returns background mix mode
// OPAQUE = 2, TRANSPARENT = 1
pub fn GetBkMode(hdc: usize) callconv(w32cc.WINAPI) i32 {
    if (gdi32.getDc(hdc)) |dc_entry| {
        return dc_entry.bk_mode;
    }
    return 2; // OPAQUE
}

// GetBkColor: returns background color as COLORREF
// Default is white
pub fn GetBkColor(hdc: usize) callconv(w32cc.WINAPI) u32 {
    if (gdi32.getDc(hdc)) |dc_entry| {
        return dc_entry.bk_color;
    }
    return 0x00FFFFFF; // RGB(255, 255, 255) = white
}
