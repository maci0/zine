const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn stub_GetKeyboardState(lpKeyState: usize) callconv(w32cc.WINAPI) i32 {
    if (lpKeyState != 0) {
        @memcpy(@as([*]u8, @ptrFromInt(lpKeyState))[0..256], &renderer.keyboard_state);
    }
    return 1;
}

pub fn stub_GetKeyState(nVirtKey: i32) callconv(w32cc.WINAPI) i16 {
    const vk: u8 = @intCast(@as(u32, @bitCast(nVirtKey)) & 0xFF);
    const state = renderer.keyboard_state[vk];
    if (state != 0) return @bitCast(@as(u16, 0x8000));
    return 0;
}

pub fn stub_SetCursor(hCursor: usize) callconv(w32cc.WINAPI) usize {
    _ = hCursor;
    return 0x87654321;
}

pub fn stub_GetCursorPos(lpPoint: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPoint != 0) {
        const pt = @as(*w32.POINT, @ptrFromInt(lpPoint));
        pt.x = 0;
        pt.y = 0;
    }
    return 1;
}

pub fn stub_GetCapture() callconv(w32cc.WINAPI) usize {
    return 0;
}

pub fn stub_SetCapture(hWnd: usize) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    return 0;
}

pub fn stub_ReleaseCapture() callconv(w32cc.WINAPI) i32 {
    return 1;
}

pub fn stub_SetTimer(hWnd: usize, nIDEvent: usize, uElapse: u32, lpTimerFunc: usize) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    _ = uElapse;
    _ = lpTimerFunc;
    if (trace.enable_tracing) trace.print("USER32: SetTimer(id={d})\n", .{nIDEvent});
    return nIDEvent;
}

pub fn stub_KillTimer(hWnd: usize, uIDEvent: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = uIDEvent;
    return 1;
}

pub fn stub_GetQueueStatus(flags: u32) callconv(w32cc.WINAPI) u32 {
    _ = flags;
    return 0;
}
