const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");

pub fn stub_ChangeDisplaySettingsA(lpDevMode: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: ChangeDisplaySettingsA(lpDevMode=0x{X}, flags=0x{X})\n", .{ lpDevMode, dwFlags });
    // 0 = DISP_CHANGE_SUCCESSFUL
    return 0;
}

pub fn EnumDisplaySettingsA(lpszDeviceName: usize, iModeNum: u32, lpDevMode: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpszDeviceName;
    if (trace.enable_tracing) trace.print("USER32: EnumDisplaySettingsA(mode={d})\n", .{iModeNum});

    if (lpDevMode == 0) return 0;

    if (iModeNum > 0 and iModeNum != 0xFFFFFFFF) return 0; // no more modes

    const dm = @as(*w32.DEVMODEA, @ptrFromInt(lpDevMode));
    dm.dmFields = w32.DM_PELSWIDTH | w32.DM_PELSHEIGHT | w32.DM_BITSPERPEL | w32.DM_DISPLAYFREQUENCY;
    dm.dmBitsPerPel = 32;
    dm.dmPelsWidth = 1024;
    dm.dmPelsHeight = 768;
    dm.dmDisplayFrequency = 60;

    return 1; // TRUE = success
}

var cursor_count: i32 = 0;

pub fn ShowCursor(bShow: i32) callconv(w32cc.WINAPI) i32 {
    if (bShow != 0) {
        cursor_count += 1;
    } else {
        cursor_count -= 1;
    }
    if (trace.enable_tracing) trace.print("USER32: ShowCursor({d}) -> {d}\n", .{ bShow, cursor_count });
    return cursor_count;
}

pub fn GetSysColor(nIndex: i32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("USER32: GetSysColor({d})\n", .{nIndex});
    // Windows 2000 "Windows Standard" scheme — COLORREF is 0x00BBGGRR
    return switch (nIndex) {
        0 => 0x00C8D0D4,   // COLOR_SCROLLBAR          #D4D0C8
        1 => 0x00A56E3A,   // COLOR_BACKGROUND          #3A6EA5
        2 => 0x006A240A,   // COLOR_ACTIVECAPTION        #0A246A
        3 => 0x00808080,   // COLOR_INACTIVECAPTION      #808080
        4 => 0x00C8D0D4,   // COLOR_MENU                 #D4D0C8
        5 => 0x00FFFFFF,   // COLOR_WINDOW               #FFFFFF
        6 => 0x00000000,   // COLOR_WINDOWFRAME          #000000
        7 => 0x00000000,   // COLOR_MENUTEXT             #000000
        8 => 0x00000000,   // COLOR_WINDOWTEXT           #000000
        9 => 0x00FFFFFF,   // COLOR_CAPTIONTEXT          #FFFFFF
        10 => 0x00C8D0D4,  // COLOR_ACTIVEBORDER         #D4D0C8
        11 => 0x00C8D0D4,  // COLOR_INACTIVEBORDER       #D4D0C8
        12 => 0x00808080,  // COLOR_APPWORKSPACE          #808080
        13 => 0x006A240A,  // COLOR_HIGHLIGHT             #0A246A
        14 => 0x00FFFFFF,  // COLOR_HIGHLIGHTTEXT         #FFFFFF
        15 => 0x00C8D0D4,  // COLOR_BTNFACE               #D4D0C8
        16 => 0x00808080,  // COLOR_BTNSHADOW             #808080
        17 => 0x00808080,  // COLOR_GRAYTEXT              #808080
        18 => 0x00000000,  // COLOR_BTNTEXT               #000000
        19 => 0x00C8D0D4,  // COLOR_INACTIVECAPTIONTEXT   #D4D0C8
        20 => 0x00FFFFFF,  // COLOR_BTNHIGHLIGHT          #FFFFFF
        21 => 0x00404040,  // COLOR_3DDKSHADOW            #404040
        22 => 0x00C8D0D4,  // COLOR_3DLIGHT               #D4D0C8
        23 => 0x00000000,  // COLOR_INFOTEXT              #000000
        24 => 0x00E1FFFF,  // COLOR_INFOBK                #FFFFE1
        25 => 0x00000000,  // (unused)
        26 => 0x00800000,  // COLOR_HOTLIGHT              #000080
        27 => 0x00F0CAA6,  // COLOR_GRADIENTACTIVECAPTION #A6CAF0
        28 => 0x00C0C0C0,  // COLOR_GRADIENTINACTIVECAPTION #C0C0C0
        else => 0x00000000,
    };
}

pub fn GetSysColorBrush(nIndex: i32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("USER32: GetSysColorBrush({d})\n", .{nIndex});
    return 0xB0000000 | @as(usize, @intCast(@as(u32, @bitCast(nIndex))));
}

pub fn stub_FlashWindow(hWnd: usize, bInvert: i32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = bInvert;
    return 0;
}
