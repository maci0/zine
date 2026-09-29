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

/// Registered message and clipboard format names → ids. Win32 guarantees an
/// identical string maps to a single id for the life of the process, and both
/// kinds share one id space, so a guest comparing two results of
/// `RegisterWindowMessage` (or one result against a clipboard format) gets the
/// same answer every time. The name is compared at full length: a name too long
/// for the entry keeps its id only for the call that made it, rather than
/// aliasing every other name with the same prefix onto one id.
const RegMsg = struct { name: [64]u8, len: u8, id: u32 };
var reg_msgs: [64]RegMsg = undefined;
var reg_msg_count: usize = 0;

/// Return the id for `name`, minting one on first use. `label` names the calling
/// API for the trace record.
fn registerMessageName(label: []const u8, name: []const u8) u32 {
    for (reg_msgs[0..reg_msg_count]) |*e| {
        if (e.len == name.len and std.mem.eql(u8, e.name[0..e.len], name)) {
            if (trace.enable_tracing) trace.print("USER32: {s}('{s}') -> 0x{X} (cached)\n", .{ label, name, e.id });
            return e.id;
        }
    }
    const id = next_registered_msg;
    next_registered_msg += 1;
    if (name.len <= reg_msgs[0].name.len and reg_msg_count < reg_msgs.len) {
        const e = &reg_msgs[reg_msg_count];
        reg_msg_count += 1;
        @memcpy(e.name[0..name.len], name);
        e.len = @intCast(name.len);
        e.id = id;
    }
    if (trace.enable_tracing) trace.print("USER32: {s}('{s}') -> 0x{X}\n", .{ label, name, id });
    return id;
}

pub fn RegisterWindowMessageA(lpString: usize) callconv(w32cc.WINAPI) u32 {
    if (lpString != 0 and lpString > 0xFFFF) {
        return registerMessageName("RegisterWindowMessageA", trace.c_span(lpString));
    }
    const id = next_registered_msg;
    next_registered_msg += 1;
    return id;
}

pub fn RegisterWindowMessageW(lpString: usize) callconv(w32cc.WINAPI) u32 {
    if (lpString == 0) {
        const id = next_registered_msg;
        next_registered_msg += 1;
        return id;
    }
    const window = @import("window.zig");
    return registerMessageName("RegisterWindowMessageW", window.wideToUtf8(lpString));
}

pub fn RegisterClipboardFormatA(lpszFormat: usize) callconv(w32cc.WINAPI) u32 {
    if (lpszFormat != 0 and lpszFormat > 0xFFFF) {
        return registerMessageName("RegisterClipboardFormatA", trace.c_span(lpszFormat));
    }
    const id = next_registered_msg;
    next_registered_msg += 1;
    return id;
}

pub fn RegisterClipboardFormatW(lpszFormat: usize) callconv(w32cc.WINAPI) u32 {
    if (lpszFormat == 0) {
        const id = next_registered_msg;
        next_registered_msg += 1;
        return id;
    }
    const window = @import("window.zig");
    return registerMessageName("RegisterClipboardFormatW", window.wideToUtf8(lpszFormat));
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
        @as(*u8, @ptrFromInt(trace.addr(lpClassName))).* = 0;
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

test "a registered message name keeps one id across calls" {
    const first = RegisterWindowMessageA(@intFromPtr("ZINE_REG_MSG_TEST"));
    const again = RegisterWindowMessageA(@intFromPtr("ZINE_REG_MSG_TEST"));
    try std.testing.expectEqual(first, again);

    const other = RegisterClipboardFormatA(@intFromPtr("ZINE_REG_MSG_TEST"));
    try std.testing.expectEqual(first, other);
    try std.testing.expect(RegisterWindowMessageA(@intFromPtr("ZINE_REG_MSG_OTHER")) != first);
}

test "menu item state is keyed by menu and id together" {
    const menu = @import("menu.zig");
    const first = menu.CreateMenu();
    const second = menu.CreateMenu();
    _ = menu.CheckMenuItem(first, 7, 0x0008);
    _ = menu.CheckMenuItem(second, 8, 0x0008);
    try std.testing.expectEqual(@as(u32, 0x0008), menu.GetMenuState(first, 7, 0));
    try std.testing.expectEqual(@as(u32, 0), menu.GetMenuState(first, 8, 0));
    try std.testing.expectEqual(@as(u32, 0x0008), menu.GetMenuState(second, 8, 0));
}
