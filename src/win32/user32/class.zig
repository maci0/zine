const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const user32 = @import("../user32.zig");

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

/// Registered window message names → ids. Win32 guarantees identical strings
/// map to a single id within a session (e.g. FINDMSGSTRING registered by both
/// the app and the comdlg stub must match), so dedup by name.
const RegMsg = struct { name: [64]u8, len: u8, id: u32 };
var reg_msgs: [64]RegMsg = undefined;
var reg_msg_count: usize = 0;

pub fn RegisterWindowMessageA(lpString: usize) callconv(w32cc.WINAPI) u32 {
    if (lpString != 0 and lpString > 0xFFFF) {
        const name = trace.c_span(lpString);
        for (reg_msgs[0..reg_msg_count]) |*e| {
            if (e.len == name.len and std.mem.eql(u8, e.name[0..e.len], name)) {
                if (trace.enable_tracing) trace.print("USER32: RegisterWindowMessageA('{s}') -> 0x{X} (cached)\n", .{ name, e.id });
                return e.id;
            }
        }
        if (reg_msg_count < reg_msgs.len) {
            const e = &reg_msgs[reg_msg_count];
            reg_msg_count += 1;
            const n = @min(name.len, e.name.len);
            @memcpy(e.name[0..n], name[0..n]);
            e.len = @intCast(n);
            e.id = next_registered_msg;
            next_registered_msg += 1;
            if (trace.enable_tracing) trace.print("USER32: RegisterWindowMessageA('{s}') -> 0x{X}\n", .{ name, e.id });
            return e.id;
        }
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

/// GetClassNameA — returns the class name for a window handle.
/// Implementation status: Stub (returns empty string)
pub fn GetClassNameA(hWnd: usize, lpClassName: usize, nMaxCount: i32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: GetClassNameA -> 0\n", .{});
    if (lpClassName != 0 and nMaxCount > 0) {
        @as(*u8, @ptrFromInt(lpClassName)).* = 0;
    }
    return 0;
}

/// GetClassLongA — returns a value from the WNDCLASS structure.
/// Implementation status: Stub (returns 0)
pub fn GetClassLongA(hWnd: usize, nIndex: i32) callconv(w32cc.WINAPI) u32 {
    _ = hWnd;
    _ = nIndex;
    if (trace.enable_tracing) trace.print("USER32: GetClassLongA -> 0\n", .{});
    return 0;
}

/// GetClassInfoA — retrieves information about a window class.
/// Fills the WNDCLASSA struct with default values.
/// Returns 1 (found) for string class names, 0 for atoms.
pub fn GetClassInfoA(hInstance: usize, lpClassName: usize, lpWndClass: usize) callconv(w32cc.WINAPI) i32 {
    const is_string = lpClassName > 0xFFFF;

    if (trace.enable_tracing) {
        if (is_string) {
            const name = trace.c_span(lpClassName);
            trace.print("USER32: GetClassInfoA(hInst={x}, class='{s}', lpWndClass={x})\n", .{ hInstance, name, lpWndClass });
        } else {
            trace.print("USER32: GetClassInfoA(hInst={x}, atom={x}, lpWndClass={x})\n", .{ hInstance, lpClassName, lpWndClass });
        }
    }

    if (lpWndClass != 0) {
        // Zero out the WNDCLASSA struct (40 bytes)
        const wc_ptr = @as([*]u8, @ptrFromInt(lpWndClass));
        @memset(wc_ptr[0..40], 0);

        // Set lpfnWndProc at offset 8
        const wndproc_val: usize = if (user32.global_wndproc) |proc| @intFromPtr(proc) else 0;
        @as(*align(1) u32, @ptrFromInt(lpWndClass + 8)).* = @truncate(wndproc_val);

        // Set hInstance at offset 20
        @as(*align(1) u32, @ptrFromInt(lpWndClass + 20)).* = @truncate(hInstance);

        // Set hCursor at offset 24
        @as(*align(1) u32, @ptrFromInt(lpWndClass + 24)).* = 0x10001; // fake cursor
    }

    return if (is_string) 1 else 0;
}
