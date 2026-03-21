const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");

pub fn GetKeyboardState(lpKeyState: usize) callconv(w32cc.WINAPI) i32 {
    if (lpKeyState != 0) {
        @memcpy(@as([*]u8, @ptrFromInt(lpKeyState))[0..256], &renderer.keyboard_state);
    }
    return 1;
}

pub fn GetKeyState(nVirtKey: i32) callconv(w32cc.WINAPI) i16 {
    const vk: u8 = @intCast(@as(u32, @bitCast(nVirtKey)) & 0xFF);
    const state = renderer.keyboard_state[vk];
    if (state != 0) return @bitCast(@as(u16, 0x8000));
    return 0;
}

pub fn stub_SetCursor(hCursor: usize) callconv(w32cc.WINAPI) usize {
    _ = hCursor;
    return 0x87654321;
}

pub fn GetCursorPos(lpPoint: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPoint != 0) {
        const pt = @as(*w32.POINT, @ptrFromInt(lpPoint));
        pt.x = renderer.last_mouse_x;
        pt.y = renderer.last_mouse_y;
    }
    return 1;
}

var capture_hwnd: usize = 0;

pub fn GetCapture() callconv(w32cc.WINAPI) usize {
    return capture_hwnd;
}

pub fn SetCapture(hWnd: usize) callconv(w32cc.WINAPI) usize {
    const prev = capture_hwnd;
    capture_hwnd = hWnd;
    return prev;
}

pub fn ReleaseCapture() callconv(w32cc.WINAPI) i32 {
    capture_hwnd = 0;
    return 1;
}

const std = @import("std");

pub const TimerEntry = struct {
    hwnd: usize,
    id: usize,
    elapse_ms: u32,
    callback: usize, // lpTimerFunc (0 = post WM_TIMER)
    last_fire: i64,  // millisecond timestamp of last fire
    active: bool,
};

pub var timers: [16]TimerEntry = [_]TimerEntry{.{ .hwnd = 0, .id = 0, .elapse_ms = 0, .callback = 0, .last_fire = 0, .active = false }} ** 16;

pub fn SetTimer(hWnd: usize, nIDEvent: usize, uElapse: u32, lpTimerFunc: usize) callconv(w32cc.WINAPI) usize {
    _ = lpTimerFunc; // We don't call lpTimerFunc; we post WM_TIMER instead
    if (trace.enable_tracing) trace.print("USER32: SetTimer(hwnd={x}, id={d}, elapse={d}ms)\n", .{ hWnd, nIDEvent, uElapse });

    // Find existing timer with same id or a free slot
    var slot: ?usize = null;
    for (&timers, 0..) |*t, i| {
        if (t.active and t.id == nIDEvent and t.hwnd == hWnd) {
            slot = i;
            break;
        }
    }
    if (slot == null) {
        for (&timers, 0..) |*t, i| {
            if (!t.active) {
                slot = i;
                break;
            }
        }
    }

    if (slot) |s| {
        timers[s] = .{
            .hwnd = hWnd,
            .id = nIDEvent,
            .elapse_ms = if (uElapse < 10) 10 else uElapse, // Win32 minimum is 10ms
            .callback = 0,
            .last_fire = std.time.milliTimestamp(),
            .active = true,
        };
    }
    return nIDEvent;
}

pub fn KillTimer(hWnd: usize, uIDEvent: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: KillTimer(hwnd={x}, id={d})\n", .{ hWnd, uIDEvent });
    for (&timers) |*t| {
        if (t.active and t.id == uIDEvent and t.hwnd == hWnd) {
            t.active = false;
            return 1;
        }
    }
    return 0; // Timer not found
}

pub fn stub_GetQueueStatus(flags: u32) callconv(w32cc.WINAPI) u32 {
    _ = flags;
    return 0;
}

// -------------------------------------------------------------------------
// Keyboard / cursor / input stubs (moved from misc.zig)
// -------------------------------------------------------------------------

pub fn stub_MessageBeep(uType: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: MessageBeep(type=0x{X})\n", .{uType});
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

pub fn SetKeyboardState(lpKeyState: usize) callconv(w32cc.WINAPI) i32 {
    if (lpKeyState != 0) {
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

pub fn stub_MapVirtualKeyA(uCode: u32, uMapType: u32) callconv(w32cc.WINAPI) u32 {
    _ = uMapType;
    return uCode; // Identity mapping
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
