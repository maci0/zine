const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");

pub fn RegisterClassExA(lpwcx: usize) callconv(w32cc.WINAPI) u16 {
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

pub fn RegisterClassExW(lpwcx: usize) callconv(w32cc.WINAPI) u16 {
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

var next_registered_msg: u32 = 0xC000;

pub fn RegisterWindowMessageA(lpString: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const name = if (lpString != 0) trace.c_span(lpString) else "(null)";
        trace.print("USER32: RegisterWindowMessageA('{s}') -> 0x{X}\n", .{ name, next_registered_msg });
    }
    const id = next_registered_msg;
    next_registered_msg += 1;
    return id;
}

pub fn RegisterWindowMessageW(lpString: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const window = @import("window.zig");
        const name = if (lpString != 0) window.wideToUtf8(lpString) else "(null)";
        trace.print("USER32: RegisterWindowMessageW('{s}') -> 0x{X}\n", .{ name, next_registered_msg });
    }
    const id = next_registered_msg;
    next_registered_msg += 1;
    return id;
}

var next_clipboard_format: u32 = 0xC100;

pub fn RegisterClipboardFormatA(lpszFormat: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const name = if (lpszFormat != 0) trace.c_span(lpszFormat) else "(null)";
        trace.print("USER32: RegisterClipboardFormatA('{s}') -> 0x{X}\n", .{ name, next_clipboard_format });
    }
    const id = next_clipboard_format;
    next_clipboard_format += 1;
    return id;
}

pub fn stub_UnregisterClassA(lpClassName: usize, hInstance: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpClassName;
    _ = hInstance;
    return 1;
}

pub fn stub_SetClassLongA(hWnd: usize, nIndex: i32, dwNewLong: i32) callconv(w32cc.WINAPI) u32 {
    _ = hWnd;
    _ = nIndex;
    _ = dwNewLong;
    return 0;
}
