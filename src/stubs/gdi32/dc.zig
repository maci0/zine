const trace = @import("../../trace.zig");
const gdi32 = @import("../gdi32.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn stub_GetDeviceCaps(hdc: usize, nIndex: i32) callconv(w32cc.WINAPI) i32 {
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

pub fn stub_CreateCompatibleDC(hdc: usize) callconv(w32cc.WINAPI) usize {
    _ = hdc;
    if (trace.enable_tracing) trace.print("GDI32: CreateCompatibleDC\n", .{});
    return gdi32.nextHandle();
}

pub fn stub_DeleteDC(hdc: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    return 1;
}

pub fn stub_SaveDC(hdc: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    return 1;
}

pub fn stub_RestoreDC(hdc: usize, nSavedDC: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = nSavedDC;
    return 1;
}

pub fn stub_SetBkMode(hdc: usize, mode: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = mode;
    return 1; // Previous mode (OPAQUE)
}

pub fn stub_SetBkColor(hdc: usize, crColor: u32) callconv(w32cc.WINAPI) u32 {
    _ = hdc;
    _ = crColor;
    return 0x00FFFFFF; // Previous color (white)
}

pub fn stub_SetTextColor(hdc: usize, crColor: u32) callconv(w32cc.WINAPI) u32 {
    _ = hdc;
    _ = crColor;
    return 0; // Previous color (black)
}

pub fn stub_GetTextColor(hdc: usize) callconv(w32cc.WINAPI) u32 {
    _ = hdc;
    return 0; // Black
}

pub fn stub_SetStretchBltMode(hdc: usize, mode: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = mode;
    return 1;
}

pub fn stub_SetMapMode(hdc: usize, iMode: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = iMode;
    return 1; // Previous mode (MM_TEXT)
}

pub fn stub_SetROP2(hdc: usize, rop2: i32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = rop2;
    return 1;
}

pub fn stub_GetTextMetricsA(hdc: usize, lptm: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn stub_GetTextMetricsW(hdc: usize, lptm: usize) callconv(w32cc.WINAPI) i32 {
    return stub_GetTextMetricsA(hdc, lptm);
}

pub fn stub_GetTextExtentPoint32A(hdc: usize, lpString: usize, c: i32, lpSize: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = lpString;
    if (lpSize != 0) {
        const size = @as(*w32.SIZE, @ptrFromInt(lpSize));
        size.cx = 6 * @as(i32, if (c > 0) c else 0); // avgCharWidth(6) * len
        size.cy = 13; // tmHeight
    }
    return 1;
}

pub fn stub_GetTextExtentPoint32W(hdc: usize, lpString: usize, c: i32, lpSize: usize) callconv(w32cc.WINAPI) i32 {
    return stub_GetTextExtentPoint32A(hdc, lpString, c, lpSize);
}

pub fn stub_SetTextAlign(hdc: usize, fMode: u32) callconv(w32cc.WINAPI) u32 {
    _ = hdc;
    _ = fMode;
    return 0; // old mode
}

pub fn stub_CreateDCA(lpszDriver: usize, lpszDevice: usize, lpszOutput: usize, lpInitData: usize) callconv(w32cc.WINAPI) usize {
    _ = lpszDriver;
    _ = lpszDevice;
    _ = lpszOutput;
    _ = lpInitData;
    if (trace.enable_tracing) trace.print("GDI32: CreateDCA\n", .{});
    return gdi32.nextHandle();
}

pub fn stub_GetNearestColor(hdc: usize, color: u32) callconv(w32cc.WINAPI) u32 {
    _ = hdc;
    return color;
}

pub fn stub_UpdateColors(hdc: usize) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    return 0;
}

pub fn stub_GetTextExtentExPointA(hdc: usize, lpszString: usize, cchString: i32, nMaxExtent: i32, lpnFit: usize, lpnDx: usize, lpSize: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn stub_GetCharWidthA(hdc: usize, iFirst: u32, iLast: u32, lpBuffer: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn stub_SetWindowExtEx(hdc: usize, x: i32, y: i32, lpSize: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn stub_SetViewportExtEx(hdc: usize, x: i32, y: i32, lpSize: usize) callconv(w32cc.WINAPI) i32 {
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
