const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn stub_CharNextA(lpsz: [*:0]const u8) callconv(w32cc.WINAPI) [*:0]const u8 {
    if (lpsz[0] == 0) return lpsz;
    return lpsz + 1;
}

pub fn stub_CharPrevA(lpszStart: usize, lpszCurrent: usize) callconv(w32cc.WINAPI) usize {
    _ = lpszStart;
    if (lpszCurrent > 0) return lpszCurrent - 1;
    return 0;
}

pub fn stub_CharToOemA(lpszSrc: usize, lpszDst: usize) callconv(w32cc.WINAPI) i32 {
    if (lpszSrc == 0 or lpszDst == 0) return 0;
    if (lpszSrc != lpszDst) {
        const src = trace.c_span(lpszSrc);
        const dst = @as([*]u8, @ptrFromInt(lpszDst));
        @memcpy(dst[0..src.len], src);
        dst[src.len] = 0;
    }
    return 1;
}

// Identity copy — we don't distinguish ANSI and OEM codepages.
pub fn stub_OemToCharA(lpszSrc: usize, lpszDst: usize) callconv(w32cc.WINAPI) i32 {
    return stub_CharToOemA(lpszSrc, lpszDst);
}

pub fn stub_ChangeDisplaySettingsA(lpDevMode: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: ChangeDisplaySettingsA(lpDevMode=0x{X}, flags=0x{X})\n", .{ lpDevMode, dwFlags });
    // 0 = DISP_CHANGE_SUCCESSFUL
    return 0;
}

pub fn stub_EnumDisplaySettingsA(lpszDeviceName: usize, iModeNum: u32, lpDevMode: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn stub_ShowCursor(bShow: i32) callconv(w32cc.WINAPI) i32 {
    if (bShow != 0) {
        cursor_count += 1;
    } else {
        cursor_count -= 1;
    }
    if (trace.enable_tracing) trace.print("USER32: ShowCursor({d}) -> {d}\n", .{ bShow, cursor_count });
    return cursor_count;
}

pub fn stub_wsprintfA(lpOut: [*:0]u8, lpFmt: [*:0]const u8, a1: usize, a2: usize, a3: usize, a4: usize) callconv(w32cc.WINAPI) i32 {
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;

    if (trace.enable_tracing) {
        const fmt_span = trace.c_span(@intFromPtr(lpFmt));
        trace.print("USER32: wsprintfA fmt='{s}'\n", .{fmt_span});
    }

    lpOut[0] = 0;
    return 0;
}

pub fn stub_MessageBeep(uType: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: MessageBeep(type=0x{X})\n", .{uType});
    return 1;
}

pub fn stub_SetActiveWindow(hWnd: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("USER32: SetActiveWindow(0x{X})\n", .{hWnd});
    return hWnd;
}

pub fn stub_GetSysColor(nIndex: i32) callconv(w32cc.WINAPI) u32 {
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

pub fn stub_GetSysColorBrush(nIndex: i32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("USER32: GetSysColorBrush({d})\n", .{nIndex});
    return 0xB0000000 | @as(usize, @intCast(@as(u32, @bitCast(nIndex))));
}

pub fn stub_GetParent(hWnd: usize) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    return 0;
}

pub fn stub_FindWindowA(lpClassName: usize, lpWindowName: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        const cls = if (lpClassName != 0 and lpClassName > 0xFFFF) trace.c_span(lpClassName) else "(null)";
        const name = if (lpWindowName != 0) trace.c_span(lpWindowName) else "(null)";
        trace.print("USER32: FindWindowA(class='{s}', name='{s}') -> 0\n", .{ cls, name });
    }
    return 0;
}

pub fn stub_GetWindowTextA(hWnd: usize, lpString: usize, nMaxCount: i32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    if (lpString != 0 and nMaxCount > 0) {
        @as([*]u8, @ptrFromInt(lpString))[0] = 0;
    }
    return 0;
}

pub fn stub_GetWindowTextLengthA(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 0;
}

pub fn stub_IsZoomed(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 0;
}

var next_registered_msg: u32 = 0xC000;

pub fn stub_RegisterWindowMessageA(lpString: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const name = if (lpString != 0) trace.c_span(lpString) else "(null)";
        trace.print("USER32: RegisterWindowMessageA('{s}') -> 0x{X}\n", .{ name, next_registered_msg });
    }
    const id = next_registered_msg;
    next_registered_msg += 1;
    return id;
}

pub fn stub_RegisterWindowMessageW(lpString: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const window = @import("window.zig");
        const name = if (lpString != 0) window.wideToUtf8(lpString) else "(null)";
        trace.print("USER32: RegisterWindowMessageW('{s}') -> 0x{X}\n", .{ name, next_registered_msg });
    }
    const id = next_registered_msg;
    next_registered_msg += 1;
    return id;
}

pub fn stub_GetSystemMenu(hWnd: usize, bRevert: i32) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    _ = bRevert;
    if (trace.enable_tracing) trace.print("USER32: GetSystemMenu\n", .{});
    return 0x00000BBB;
}

pub fn stub_GetMessageTime() callconv(w32cc.WINAPI) i32 {
    const ts = std.time.milliTimestamp();
    return @truncate(ts);
}

pub fn stub_IsDialogMessageA(hDlg: usize, lpMsg: usize) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    _ = lpMsg;
    return 0;
}

pub fn stub_MsgWaitForMultipleObjects(nCount: u32, pHandles: usize, fWaitAll: i32, dwMilliseconds: u32, dwWakeMask: u32) callconv(w32cc.WINAPI) u32 {
    _ = pHandles;
    _ = fWaitAll;
    _ = dwMilliseconds;
    _ = dwWakeMask;
    return nCount; // WAIT_OBJECT_0 + nCount = message queue signaled
}

pub fn stub_GetWindowPlacement(hWnd: usize, lpwndpl: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    if (lpwndpl != 0) {
        const wp = @as(*w32.WINDOWPLACEMENT, @ptrFromInt(lpwndpl));
        wp.* = .{}; // zero all, length defaults to 44
    }
    return 1;
}

pub fn stub_SetWindowPlacement(hWnd: usize, lpwndpl: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = lpwndpl;
    return 1;
}

pub fn stub_WinHelpA(hWndMain: usize, lpszHelp: usize, uCommand: u32, dwData: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWndMain;
    _ = lpszHelp;
    _ = uCommand;
    _ = dwData;
    if (trace.enable_tracing) trace.print("USER32: WinHelpA\n", .{});
    return 1;
}

pub fn stub_DrawTextA(hdc: usize, lpchText: usize, cchText: i32, lprc: usize, format: u32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = lpchText;
    _ = cchText;
    _ = lprc;
    _ = format;
    return 0;
}

pub fn stub_DrawTextW(hdc: usize, lpchText: usize, cchText: i32, lprc: usize, format: u32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = lpchText;
    _ = cchText;
    _ = lprc;
    _ = format;
    return 0;
}

pub fn stub_CharLowerA(lpsz: usize) callconv(w32cc.WINAPI) usize {
    if (lpsz > 0xFFFF) {
        const span = trace.c_span(lpsz);
        const buf = @as([*]u8, @ptrFromInt(lpsz));
        for (0..span.len) |i| {
            if (buf[i] >= 'A' and buf[i] <= 'Z') {
                buf[i] = buf[i] + 32;
            }
        }
    }
    return lpsz;
}

pub fn stub_CharUpperW(lpsz: usize) callconv(w32cc.WINAPI) usize {
    return lpsz;
}

pub fn stub_CharLowerW(lpsz: usize) callconv(w32cc.WINAPI) usize {
    return lpsz;
}

pub fn stub_GetKeyboardLayout(idThread: u32) callconv(w32cc.WINAPI) usize {
    _ = idThread;
    return 0x04090409; // English US
}

pub fn stub_GetDoubleClickTime() callconv(w32cc.WINAPI) u32 {
    return 500;
}

pub fn stub_GetCaretBlinkTime() callconv(w32cc.WINAPI) u32 {
    return 530;
}

pub fn stub_EqualRect(lprc1: usize, lprc2: usize) callconv(w32cc.WINAPI) i32 {
    if (lprc1 == 0 or lprc2 == 0) return 0;
    const r1 = @as(*const w32.RECT, @ptrFromInt(lprc1));
    const r2 = @as(*const w32.RECT, @ptrFromInt(lprc2));
    if (r1.left == r2.left and r1.top == r2.top and r1.right == r2.right and r1.bottom == r2.bottom) return 1;
    return 0;
}

pub fn stub_InflateRect(lprc: usize, dx: i32, dy: i32) callconv(w32cc.WINAPI) i32 {
    if (lprc == 0) return 0;
    const r = @as(*w32.RECT, @ptrFromInt(lprc));
    r.left -= dx;
    r.top -= dy;
    r.right += dx;
    r.bottom += dy;
    return 1;
}

pub fn stub_IntersectRect(lprcDst: usize, lprcSrc1: usize, lprcSrc2: usize) callconv(w32cc.WINAPI) i32 {
    if (lprcDst == 0 or lprcSrc1 == 0 or lprcSrc2 == 0) return 0;
    const src1 = @as(*const w32.RECT, @ptrFromInt(lprcSrc1));
    const src2 = @as(*const w32.RECT, @ptrFromInt(lprcSrc2));
    const dst = @as(*w32.RECT, @ptrFromInt(lprcDst));
    const left = @max(src1.left, src2.left);
    const top = @max(src1.top, src2.top);
    const right = @min(src1.right, src2.right);
    const bottom = @min(src1.bottom, src2.bottom);
    if (left < right and top < bottom) {
        dst.left = left;
        dst.top = top;
        dst.right = right;
        dst.bottom = bottom;
        return 1;
    }
    dst.* = .{};
    return 0;
}

pub fn stub_MessageBoxIndirectA(lpmbp: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpmbp;
    return 1; // IDOK
}

pub fn stub_SetKeyboardState(lpKeyState: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpKeyState;
    return 1;
}

pub fn stub_ToAsciiEx(uVirtKey: u32, uScanCode: u32, lpKeyState: usize, lpChar: usize, uFlags: u32, dwhkl: usize) callconv(w32cc.WINAPI) i32 {
    _ = uVirtKey;
    _ = uScanCode;
    _ = lpKeyState;
    _ = lpChar;
    _ = uFlags;
    _ = dwhkl;
    return 0;
}

pub fn stub_FlashWindow(hWnd: usize, bInvert: i32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = bInvert;
    return 0;
}

pub fn stub_SetClassLongA(hWnd: usize, nIndex: i32, dwNewLong: i32) callconv(w32cc.WINAPI) u32 {
    _ = hWnd;
    _ = nIndex;
    _ = dwNewLong;
    return 0;
}

pub fn stub_DefDlgProcA(hDlg: usize, Msg: u32, wParam: usize, lParam: usize) callconv(w32cc.WINAPI) usize {
    _ = hDlg;
    _ = Msg;
    _ = wParam;
    _ = lParam;
    return 0;
}

pub fn stub_MapDialogRect(hDlg: usize, lpRect: usize) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    _ = lpRect;
    return 1;
}

var next_clipboard_format: u32 = 0xC100;

pub fn stub_RegisterClipboardFormatA(lpszFormat: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const name = if (lpszFormat != 0) trace.c_span(lpszFormat) else "(null)";
        trace.print("USER32: RegisterClipboardFormatA('{s}') -> 0x{X}\n", .{ name, next_clipboard_format });
    }
    const id = next_clipboard_format;
    next_clipboard_format += 1;
    return id;
}

// --- Europa 1400 compatibility ---

pub fn stub_ValidateRect(hWnd: usize, lpRect: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = lpRect;
    return 1;
}

pub fn stub_UnregisterClassA(lpClassName: usize, hInstance: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpClassName;
    _ = hInstance;
    return 1;
}

pub fn stub_IsWindowVisible(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 1;
}

pub fn stub_CallNextHookEx(hhk: usize, nCode: i32, wParam: usize, lParam: usize) callconv(w32cc.WINAPI) usize {
    _ = hhk;
    _ = nCode;
    _ = wParam;
    _ = lParam;
    return 0;
}

pub fn stub_MapVirtualKeyA(uCode: u32, uMapType: u32) callconv(w32cc.WINAPI) u32 {
    _ = uMapType;
    return uCode; // Identity mapping
}

pub fn stub_RegisterClassExA(lpwcx: usize) callconv(w32cc.WINAPI) u16 {
    if (lpwcx != 0) {
        const wc = @as(*const w32.WNDCLASSEXA, @ptrFromInt(lpwcx));
        _ = wc.lpfnWndProc;

        if (trace.enable_tracing) {
            if (wc.lpszClassName != 0 and wc.lpszClassName > 0xFFFF) {
                const name = trace.c_span(wc.lpszClassName);
                trace.print("USER32: RegisterClassExA('{s}')\n", .{name});
            }
        }
    }
    return 0xBEEF; // Fake atom
}

pub fn stub_RegisterClassExW(lpwcx: usize) callconv(w32cc.WINAPI) u16 {
    if (lpwcx != 0) {
        const wc = @as(*const w32.WNDCLASSEXA, @ptrFromInt(lpwcx));
        const user32 = @import("../user32.zig");
        if (wc.lpfnWndProc != 0) {
            user32.global_wndproc = @as(*const fn (usize, u32, usize, isize) callconv(w32cc.WINAPI) isize, @ptrFromInt(wc.lpfnWndProc));
        }

        if (wc.lpszMenuName != 0) {
            user32.window_has_menu = true;
        }

        if (trace.enable_tracing) {
            if (wc.lpszClassName != 0 and wc.lpszClassName > 0xFFFF) {
                const window = @import("window.zig");
                const name = window.wideToUtf8(wc.lpszClassName);
                trace.print("USER32: RegisterClassExW('{s}')\n", .{name});
            }
        }
    }
    return 0xBEEF; // Fake atom
}

pub fn stub_BringWindowToTop(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 1;
}

pub fn stub_VkKeyScanA(ch: u8) callconv(w32cc.WINAPI) i16 {
    // Return the VK code for basic ASCII
    return @as(i16, @intCast(ch));
}

pub fn stub_SetCursorPos(x: i32, y: i32) callconv(w32cc.WINAPI) i32 {
    _ = x;
    _ = y;
    return 1;
}

pub fn stub_SetWindowsHookExA(idHook: i32, lpfn: usize, hmod: usize, dwThreadId: u32) callconv(w32cc.WINAPI) usize {
    _ = idHook;
    _ = lpfn;
    _ = hmod;
    _ = dwThreadId;
    return 0xBEEF0010; // Fake hook handle
}

pub fn stub_UnhookWindowsHookEx(hhk: usize) callconv(w32cc.WINAPI) i32 {
    _ = hhk;
    return 1;
}

pub fn stub_GetWindowThreadProcessId(hWnd: usize, lpdwProcessId: usize) callconv(w32cc.WINAPI) u32 {
    _ = hWnd;
    if (lpdwProcessId != 0) {
        @as(*u32, @ptrFromInt(lpdwProcessId)).* = 1000; // fake PID
    }
    return 1000; // fake thread ID
}

pub fn stub_GetWindow(hWnd: usize, uCmd: u32) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    _ = uCmd;
    return 0; // No window found
}

pub fn stub_GetTopWindow(hWnd: usize) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    return 0;
}

pub fn stub_CharNextW(lpsz: usize) callconv(w32cc.WINAPI) usize {
    if (lpsz == 0) return 0;
    const ptr = @as([*]const u16, @ptrFromInt(lpsz));
    if (ptr[0] == 0) return lpsz;
    return lpsz + 2; // advance by one u16
}

pub fn stub_wsprintfW(lpOut: [*]u16, lpFmt: [*]const u16, a1: usize, a2: usize, a3: usize, a4: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpFmt;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    lpOut[0] = 0;
    return 0;
}
