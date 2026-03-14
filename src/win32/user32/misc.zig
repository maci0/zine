const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn stub_MessageBeep(uType: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: MessageBeep(type=0x{X})\n", .{uType});
    return 1;
}

pub fn stub_SetActiveWindow(hWnd: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("USER32: SetActiveWindow(0x{X})\n", .{hWnd});
    return hWnd;
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

pub fn stub_GetSystemMenu(hWnd: usize, bRevert: i32) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    _ = bRevert;
    if (trace.enable_tracing) trace.print("USER32: GetSystemMenu\n", .{});
    return 0x00000BBB;
}

pub fn GetMessageTime() callconv(w32cc.WINAPI) i32 {
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

pub fn GetWindowPlacement(hWnd: usize, lpwndpl: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn EqualRect(lprc1: usize, lprc2: usize) callconv(w32cc.WINAPI) i32 {
    if (lprc1 == 0 or lprc2 == 0) return 0;
    const r1 = @as(*const w32.RECT, @ptrFromInt(lprc1));
    const r2 = @as(*const w32.RECT, @ptrFromInt(lprc2));
    if (r1.left == r2.left and r1.top == r2.top and r1.right == r2.right and r1.bottom == r2.bottom) return 1;
    return 0;
}

pub fn InflateRect(lprc: usize, dx: i32, dy: i32) callconv(w32cc.WINAPI) i32 {
    if (lprc == 0) return 0;
    const r = @as(*w32.RECT, @ptrFromInt(lprc));
    r.left -= dx;
    r.top -= dy;
    r.right += dx;
    r.bottom += dy;
    return 1;
}

pub fn IntersectRect(lprcDst: usize, lprcSrc1: usize, lprcSrc2: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn SetKeyboardState(lpKeyState: usize) callconv(w32cc.WINAPI) i32 {
    if (lpKeyState != 0) {
        const renderer = @import("../../gui/renderer.zig");
        @memcpy(&renderer.keyboard_state, @as([*]const u8, @ptrFromInt(lpKeyState))[0..256]);
    }
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

// --- Europa 1400 compatibility ---

pub fn stub_ValidateRect(hWnd: usize, lpRect: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = lpRect;
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

pub fn GetWindowThreadProcessId(hWnd: usize, lpdwProcessId: usize) callconv(w32cc.WINAPI) u32 {
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
