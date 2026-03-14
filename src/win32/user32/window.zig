const std = @import("std");
const trace = @import("../../trace.zig");
const user32 = @import("../user32.zig");
const kernel32 = @import("../kernel32.zig");
const renderer = @import("../../gui/renderer.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn stub_SetRect(lprc: *user32.RECT, xLeft: i32, yTop: i32, xRight: i32, yBottom: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: SetRect\n", .{});
    lprc.left = xLeft;
    lprc.top = yTop;
    lprc.right = xRight;
    lprc.bottom = yBottom;
    return 1;
}

pub fn stub_AdjustWindowRectEx(lpRect: *user32.RECT, dwStyle: u32, bMenu: i32, dwExStyle: u32) callconv(w32cc.WINAPI) i32 {
    const adj = user32.calcFrameAdjustments(dwStyle, bMenu != 0, dwExStyle);
    if (trace.enable_tracing) trace.print("USER32: AdjustWindowRectEx(style={x}, menu={d}, exstyle={x}) -> l={d} t={d} r={d} b={d}\n", .{ dwStyle, bMenu, dwExStyle, adj.left, adj.top, adj.right, adj.bottom });
    lpRect.left -= adj.left;
    lpRect.top -= adj.top;
    lpRect.right += adj.right;
    lpRect.bottom += adj.bottom;
    return 1;
}

pub fn stub_AdjustWindowRect(lpRect: *user32.RECT, dwStyle: u32, bMenu: i32) callconv(w32cc.WINAPI) i32 {
    return stub_AdjustWindowRectEx(lpRect, dwStyle, bMenu, 0);
}

pub fn stub_SystemParametersInfoA(uiAction: u32, uiParam: u32, pvParam: usize, fWinIni: u32) callconv(w32cc.WINAPI) i32 {
    _ = uiParam;
    _ = fWinIni;
    if (trace.enable_tracing) trace.print("USER32: SystemParametersInfoA(action={x})\n", .{uiAction});
    if (uiAction == w32.SPI_GETWORKAREA and pvParam != 0) {
        const rect = @as(*user32.RECT, @ptrFromInt(pvParam));
        rect.left = 0;
        rect.top = 0;
        rect.right = 1024;  // matches SM_CXSCREEN
        rect.bottom = 738;  // screen height minus taskbar (768 - 30)
    }
    if (uiAction == w32.SPI_GETNONCLIENTMETRICS and pvParam != 0) {
        const ncm = @as(*w32.NONCLIENTMETRICSA, @ptrFromInt(pvParam));
        ncm.* = .{}; // zero all fields, cbSize defaults to 340
        ncm.iBorderWidth = 1;
        ncm.iScrollWidth = 16;
        ncm.iScrollHeight = 16;
        ncm.iCaptionWidth = 18;
        ncm.iCaptionHeight = 18;
        ncm.lfCaptionFont.lfHeight = -11;  // 8pt @ 96dpi
        ncm.lfCaptionFont.lfWeight = 700;  // FW_BOLD
    }
    return 1;
}

pub fn stub_GetSystemMetrics(nIndex: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: GetSystemMetrics({d})\n", .{nIndex});
    // Windows 2000 "Windows Standard" at 96 DPI
    return switch (nIndex) {
        0 => 1024,  // SM_CXSCREEN
        1 => 768,   // SM_CYSCREEN
        2 => 16,    // SM_CXVSCROLL
        3 => 16,    // SM_CYHSCROLL
        4 => 19,    // SM_CYCAPTION
        5 => 1,     // SM_CXBORDER
        6 => 1,     // SM_CYBORDER
        7 => 3,     // SM_CXDLGFRAME / SM_CXFIXEDFRAME
        8 => 3,     // SM_CYDLGFRAME / SM_CYFIXEDFRAME
        9 => 0,     // SM_CXHTHUMB (same as CXHSCROLL = 16, but index 9 is unused)
        10 => 0,    // SM_CYVTHUMB (index 10 unused)
        11 => 16,   // SM_CXHTHUMB
        12 => 16,   // SM_CYVTHUMB
        13 => 32,   // SM_CXICON
        14 => 32,   // SM_CYICON
        15 => 19,   // SM_CYMENU
        16 => 1024, // SM_CXFULLSCREEN
        17 => 741,  // SM_CYFULLSCREEN (768 - caption - menu)
        20 => 112,  // SM_CXMINTRACK (min tracking width)
        21 => 27,   // SM_CYMINTRACK (caption + frame top + frame bottom)
        22 => 200,  // SM_CXDOUBLECLK
        23 => 200,  // SM_CYDOUBLECLK
        24 => 0,    // SM_CXICONSPACING (not relevant)
        25 => 0,    // SM_CYICONSPACING
        28 => 112,  // SM_CXMIN (minimum window width)
        29 => 27,   // SM_CYMIN (minimum window height)
        30 => 18,   // SM_CXSIZE (caption button width)
        31 => 18,   // SM_CYSIZE (caption button height)
        32 => 4,    // SM_CXFRAME / SM_CXSIZEFRAME
        33 => 4,    // SM_CYFRAME / SM_CYSIZEFRAME
        34 => 0,    // SM_CXMINTRACK (alias)
        36 => 1032, // SM_CXMAXIMIZED (screen + 2*frame)
        37 => 776,  // SM_CYMAXIMIZED (screen + 2*frame)
        43 => 0,    // SM_NETWORK
        45 => 2,    // SM_CXEDGE
        46 => 2,    // SM_CYEDGE
        49 => 16,   // SM_CXSMICON
        50 => 16,   // SM_CYSMICON
        51 => 15,   // SM_CYSMCAPTION
        52 => 12,   // SM_CXSMSIZE
        53 => 14,   // SM_CYSMSIZE
        54 => 18,   // SM_CXMENUSIZE
        55 => 18,   // SM_CYMENUSIZE
        57 => 0,    // SM_ARRANGE
        58 => 0,    // SM_CXMINIMIZED
        59 => 0,    // SM_CYMINIMIZED
        61 => 1024, // SM_CXMAXTRACK
        62 => 768,  // SM_CYMAXTRACK
        67 => 1,    // SM_IMMENABLED
        75 => 0,    // SM_CXFOCUSBORDER
        76 => 0,    // SM_CYFOCUSBORDER
        78 => 1024, // SM_CXVIRTUALSCREEN (same as screen for single monitor)
        79 => 768,  // SM_CYVIRTUALSCREEN
        80 => 1,    // SM_CMONITORS (number of monitors)
        else => 0,
    };
}

pub fn stub_RegisterClassA(lpWndClass: usize) callconv(w32cc.WINAPI) u16 {
    if (lpWndClass != 0) {
        const wc = @as(*const w32.WNDCLASSA, @ptrFromInt(lpWndClass));
        if (wc.lpfnWndProc != 0) {
            user32.global_wndproc = @as(*const fn (usize, u32, usize, isize) callconv(w32cc.WINAPI) isize, @ptrFromInt(wc.lpfnWndProc));
        }

        // Store background brush for WM_ERASEBKGND
        user32.wndclass_bg_brush = wc.hbrBackground;

        const menu_name = if (wc.lpszMenuName != 0) trace.c_span(wc.lpszMenuName) else "(null)";
        const class_name = if (wc.lpszClassName != 0) trace.c_span(wc.lpszClassName) else "(null)";

        if (wc.lpszMenuName != 0 and menu_name.len > 0) {
            user32.window_has_menu = true;
        }

        if (trace.enable_tracing) trace.print("USER32: RegisterClassA(class='{s}', menu='{s}', hbrBg={x})\n", .{ class_name, menu_name, wc.hbrBackground });
    } else {
        if (trace.enable_tracing) trace.print("USER32: RegisterClassA(NULL)\n", .{});
    }
    return 0x1234; // Dummy ATOM
}

// Convert a null-terminated UTF-16 (wide) string pointer to a UTF-8 slice in a static buffer.
var wide_conv_buf: [1024]u8 = undefined;

pub fn wideToUtf8(ptr: usize) []const u8 {
    if (ptr == 0) return "";
    const wide = @as([*]const u16, @ptrFromInt(ptr));
    var i: usize = 0;
    while (i < wide_conv_buf.len - 1 and wide[i] != 0) : (i += 1) {
        wide_conv_buf[i] = if (wide[i] < 128) @intCast(wide[i]) else '?';
    }
    return wide_conv_buf[0..i];
}

fn applyWindowSize(dwStyle: u32, dwExStyle: u32, nWidth: i32, nHeight: i32) void {
    var w = nWidth;
    var h = nHeight;

    // CW_USEDEFAULT: Windows uses ~3/4 of the work area (1024x738)
    // This matches what real Win2K does for the first cascaded window
    if (w == w32.CW_USEDEFAULT or w <= 0) w = 768;  // ~75% of 1024
    if (h == w32.CW_USEDEFAULT or h <= 0) h = 554;  // ~75% of 738

    user32.window_width = w;
    user32.window_height = h;

    const adj = user32.calcFrameAdjustments(dwStyle, user32.window_has_menu, dwExStyle);
    user32.current_client_width = w - adj.left - adj.right;
    if (user32.current_client_width < 1) user32.current_client_width = 1;
    user32.current_client_height = h - adj.top - adj.bottom;
    if (user32.current_client_height < 1) user32.current_client_height = 1;

    renderer.setResolution(@intCast(user32.current_client_width), @intCast(user32.current_client_height));
}

// Check if an ANSI class name matches a target (case-insensitive)
fn ansiClassEql(class_ptr: usize, target: []const u8) bool {
    if (class_ptr == 0 or class_ptr <= 0xFFFF) return false;
    const name = trace.c_span(class_ptr);
    if (name.len != target.len) return false;
    for (0..name.len) |i| {
        if (std.ascii.toLower(name[i]) != std.ascii.toLower(target[i])) return false;
    }
    return true;
}

pub fn stub_CreateWindowExA(
    dwExStyle: u32, lpClassName: usize, lpWindowName: usize, dwStyle: u32,
    x: i32, y: i32, nWidth: i32, nHeight: i32,
    hWndParent: usize, hMenu: usize, hInstance: usize, lpParam: usize,
) callconv(w32cc.WINAPI) usize {
    _ = hInstance;
    _ = lpParam;

    const is_child = (dwStyle & w32.WS_CHILD) != 0;
    const is_edit = ansiClassEql(lpClassName, "Edit");

    if (!is_child) {
        user32.window_style = dwStyle;
        user32.window_exstyle = dwExStyle;
        user32.window_x = x;
        user32.window_y = y;
        if (hMenu != 0) user32.window_has_menu = true;

        applyWindowSize(dwStyle, dwExStyle, nWidth, nHeight);

        if (trace.enable_tracing) trace.print("USER32: CreateWindowExA(style={x}, exstyle={x}, {d}x{d}, menu={x}) -> client {d}x{d}\n", .{ dwStyle, dwExStyle, nWidth, nHeight, hMenu, user32.current_client_width, user32.current_client_height });

        if (lpWindowName != 0) {
            const title = trace.c_span(lpWindowName);
            renderer.setTitle(title);
        }

        if (user32.window_width > 0 and user32.window_height > 0) {
            renderer.setWindowPos(user32.window_width, user32.window_height, user32.current_client_width, user32.current_client_height);
        }

        fillFramebufWhite();

        user32.global_hwnd = 0x00000123;

        // Dispatch WM_NCCREATE and WM_CREATE to WndProc (with SEH protection)
        if (user32.global_wndproc) |wndproc| {
            var cs: [12]u32 = std.mem.zeroes([12]u32);
            cs[1] = @truncate(kernel32.main_module_handle); // hInstance
            cs[2] = @truncate(hMenu); // hMenu
            cs[4] = @bitCast(nHeight); // cy
            cs[5] = @bitCast(nWidth);  // cx
            cs[6] = @bitCast(y);       // y
            cs[7] = @bitCast(x);       // x
            cs[8] = dwStyle;           // style
            cs[11] = dwExStyle;        // dwExStyle
            const lp: isize = @bitCast(@intFromPtr(&cs));
            const proc = @intFromPtr(wndproc);
            var err_flag: u32 = 0;
            _ = user32.callWndProcSafe(proc, user32.global_hwnd, 0x0081, 0, lp, &err_flag); // WM_NCCREATE
            if (err_flag == 0) {
                const create_result = user32.callWndProcSafe(proc, user32.global_hwnd, 0x0001, 0, lp, &err_flag); // WM_CREATE
                if (err_flag == 0 and create_result == -1) {
                    if (trace.enable_tracing) trace.print("USER32: WM_CREATE returned -1, window creation failed\n", .{});
                    return 0;
                }
            }
        }

        return user32.global_hwnd;
    }

    // Child window
    const child_hwnd = next_child_hwnd;
    next_child_hwnd += 1;

    const class_name = if (lpClassName > 0xFFFF) trace.c_span(lpClassName) else "?";
    if (trace.enable_tracing) trace.print("USER32: CreateWindowExA child(class={s}, style={x}, parent={x}) -> {x}\n", .{ class_name, dwStyle, hWndParent, child_hwnd });

    if (is_edit) {
        const is_multiline = (dwStyle & w32.ES_MULTILINE) != 0;
        user32.edit_hwnd = child_hwnd;
        renderer.showEditControl(is_multiline);
    }

    return child_hwnd;
}

// Detect if a wide class name matches an ASCII string (case-insensitive)
fn wideClassEql(class_ptr: usize, target: []const u8) bool {
    if (class_ptr == 0 or class_ptr <= 0xFFFF) return false; // ATOM, not a string
    const wide = @as([*]const u16, @ptrFromInt(class_ptr));
    for (0..target.len) |i| {
        const wc = wide[i];
        if (wc == 0) return false;
        const c: u8 = if (wc < 128) @intCast(wc) else return false;
        if (std.ascii.toLower(c) != std.ascii.toLower(target[i])) return false;
    }
    return wide[target.len] == 0;
}

var next_child_hwnd: usize = 0x00001000;

pub fn stub_CreateWindowExW(
    dwExStyle: u32, lpClassName: usize, lpWindowName: usize, dwStyle: u32,
    x: i32, y: i32, nWidth: i32, nHeight: i32,
    hWndParent: usize, hMenu: usize, hInstance: usize, lpParam: usize,
) callconv(w32cc.WINAPI) usize {
    _ = hInstance;
    _ = lpParam;

    const is_child = (dwStyle & w32.WS_CHILD) != 0;
    const is_edit = wideClassEql(lpClassName, "Edit");

    if (!is_child) {
        // Top-level window
        user32.window_style = dwStyle;
        user32.window_exstyle = dwExStyle;
        user32.window_x = x;
        user32.window_y = y;
        if (hMenu != 0) user32.window_has_menu = true;

        applyWindowSize(dwStyle, dwExStyle, nWidth, nHeight);

        if (trace.enable_tracing) trace.print("USER32: CreateWindowExW(style={x}, exstyle={x}, {d}x{d}, menu={x}) -> client {d}x{d}\n", .{ dwStyle, dwExStyle, nWidth, nHeight, hMenu, user32.current_client_width, user32.current_client_height });

        if (lpWindowName != 0) {
            const title = wideToUtf8(lpWindowName);
            if (title.len > 0) renderer.setTitle(title);
        }

        if (user32.window_width > 0 and user32.window_height > 0) {
            renderer.setWindowPos(user32.window_width, user32.window_height, user32.current_client_width, user32.current_client_height);
        }

        fillFramebufWhite();

        user32.global_hwnd = 0x00000123;

        // Dispatch WM_NCCREATE (0x0081) and WM_CREATE (0x0001) to WndProc
        // This is critical: apps initialize their state in WM_CREATE
        if (user32.global_wndproc) |wndproc| {
            // Provide a valid CREATESTRUCT on the stack
            var cs: [12]u32 = std.mem.zeroes([12]u32);
            cs[1] = @truncate(kernel32.main_module_handle); // hInstance
            cs[2] = @truncate(hMenu); // hMenu
            cs[4] = @bitCast(nHeight); // cy
            cs[5] = @bitCast(nWidth);  // cx
            cs[6] = @bitCast(y);       // y
            cs[7] = @bitCast(x);       // x
            cs[8] = dwStyle;           // style
            cs[11] = dwExStyle;        // dwExStyle
            const lp: isize = @bitCast(@intFromPtr(&cs));
            const proc = @intFromPtr(wndproc);
            var err_flag: u32 = 0;
            _ = user32.callWndProcSafe(proc, user32.global_hwnd, 0x0081, 0, lp, &err_flag); // WM_NCCREATE
            if (err_flag == 0) {
                const create_result = user32.callWndProcSafe(proc, user32.global_hwnd, 0x0001, 0, lp, &err_flag); // WM_CREATE
                if (err_flag == 0 and create_result == -1) {
                    if (trace.enable_tracing) trace.print("USER32: WM_CREATE returned -1, window creation failed\n", .{});
                    return 0; // CreateWindowEx returns NULL
                }
            }
        }

        return user32.global_hwnd;
    }

    // Child window
    const child_hwnd = next_child_hwnd;
    next_child_hwnd += 1;

    const class_name = if (lpClassName > 0xFFFF) wideToUtf8(lpClassName) else "?";
    if (trace.enable_tracing) trace.print("USER32: CreateWindowExW child(class={s}, style={x}, parent={x}, pos={d},{d},{d},{d}) -> {x}\n", .{ class_name, dwStyle, hWndParent, x, y, nWidth, nHeight, child_hwnd });

    if (is_edit) {
        // Multiline edit control → show native textarea in web UI
        const is_multiline = (dwStyle & w32.ES_MULTILINE) != 0;
        user32.edit_hwnd = child_hwnd;
        renderer.showEditControl(is_multiline);
    } else if (lpClassName > 0xFFFF) {
        // Check for common controls and render them
        const text = if (lpWindowName > 0xFFFF) wideToUtf8(lpWindowName) else "";
        if (wideClassEql(lpClassName, "SysTabControl32") or
            wideClassEql(lpClassName, "SysListView32") or
            wideClassEql(lpClassName, "msctls_statusbar32") or
            wideClassEql(lpClassName, "msctls_progress32") or
            wideClassEql(lpClassName, "SysTreeView32") or
            wideClassEql(lpClassName, "SysHeader32"))
        {
            renderer.addControl(class_name, child_hwnd, x, y, nWidth, nHeight, dwStyle, text);
        }
    }

    return child_hwnd;
}

fn fillFramebufWhite() void {
    const fb = renderer.global_framebuf;
    const total_pixels = renderer.global_width * renderer.global_height;
    var i: usize = 0;
    while (i < total_pixels and (i * 4 + 3) < fb.len) : (i += 1) {
        fb[i * 4 + 0] = 0xFF; // R
        fb[i * 4 + 1] = 0xFF; // G
        fb[i * 4 + 2] = 0xFF; // B
        fb[i * 4 + 3] = 0xFF; // A
    }
}

pub fn stub_SetWindowTextA(hWnd: usize, lpString: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: SetWindowTextA\n", .{});

    if (lpString != 0) {
        const title = trace.c_span(lpString);
        renderer.setTitle(title);
    }

    return 1;
}

pub fn stub_SetWindowTextW(hWnd: usize, lpString: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    if (lpString != 0) {
        const title = wideToUtf8(lpString);
        if (trace.enable_tracing) trace.print("USER32: SetWindowTextW('{s}')\n", .{title});
        if (title.len > 0) renderer.setTitle(title);
    }
    return 1;
}

pub fn stub_GetClientRect(hWnd: usize, lpRect: *user32.RECT) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    lpRect.left = 0;
    lpRect.top = 0;
    lpRect.right = user32.current_client_width;
    lpRect.bottom = user32.current_client_height;
    if (trace.enable_tracing) trace.print("USER32: GetClientRect -> {d}x{d}\n", .{ user32.current_client_width, user32.current_client_height });
    return 1;
}

pub fn stub_GetWindowRect(hWnd: usize, lpRect: *user32.RECT) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    lpRect.left = user32.window_x;
    lpRect.top = user32.window_y;
    lpRect.right = user32.window_x + user32.window_width;
    lpRect.bottom = user32.window_y + user32.window_height;
    if (trace.enable_tracing) trace.print("USER32: GetWindowRect -> {d},{d},{d},{d}\n", .{ lpRect.left, lpRect.top, lpRect.right, lpRect.bottom });
    return 1;
}

pub fn stub_DefWindowProcA(hWnd: usize, Msg: u32, wParam: usize, lParam: isize) callconv(w32cc.WINAPI) isize {
    _ = lParam;

    // WM_ERASEBKGND: actually fill the client area with class's hbrBackground
    if (Msg == 0x0014) { // WM_ERASEBKGND
        const hdc = wParam;
        const drawing = @import("../gdi32/drawing.zig");
        const gdi32 = @import("../gdi32.zig");
        const rend = @import("../../gui/renderer.zig");

        if (drawing.getFramebufferForDc(hdc)) |fb| {
            var color: u32 = 0x00C0C0C0; // Default: button face gray (COLOR_BTNFACE)
            const hbr: u32 = user32.wndclass_bg_brush;

            if (hbr != 0 and hbr <= 30) {
                // System color brush (COLOR_xxx + 1)
                color = switch (hbr) {
                    1 => 0x00C0C0C0,  // COLOR_SCROLLBAR
                    2 => 0x00C0C0C0,  // COLOR_BACKGROUND
                    5 => 0x00FFFFFF,   // COLOR_WINDOW
                    16 => 0x00C0C0C0, // COLOR_BTNFACE
                    else => 0x00C0C0C0,
                };
            } else if (hbr != 0) {
                if (gdi32.findObject(hbr)) |obj| {
                    if (obj.obj_type == .Brush) color = obj.data.brush.color;
                }
                // If brush not found in registry, keep default gray
            }

            fb.fillRect(0, 0, @intCast(fb.w), @intCast(fb.h), color);
            if (fb.is_screen) rend.markScreenDirty();
        }
        return 1;
    }

    _ = hWnd;
    return switch (Msg) {
        0x0081 => 1, // WM_NCCREATE: must return TRUE to continue creation
        0x0001 => 0, // WM_CREATE: 0 = continue, -1 = fail
        0x0082 => 0, // WM_NCDESTROY
        0x000D => 0, // WM_GETTEXT: 0 chars copied
        0x000E => 0, // WM_GETTEXTLENGTH: 0 length
        0x0084 => 1, // WM_NCHITTEST: HTCLIENT
        else => 0,
    };
}

pub fn stub_GetWindowLongA(hWnd: usize, nIndex: i32) callconv(w32cc.WINAPI) i32 {
    const is_main = (hWnd == user32.global_hwnd) or (hWnd == 0);
    var result: i32 = 0;

    if (user32.getWindowInfo(hWnd)) |info| {
        result = switch (nIndex) {
            w32.GWL_STYLE => if (is_main) @bitCast(user32.window_style) else info.style,
            w32.GWL_EXSTYLE => if (is_main) @bitCast(user32.window_exstyle) else info.exstyle,
            w32.GWL_WNDPROC => @bitCast(@as(u32, @truncate(info.proc))),
            w32.GWL_USERDATA => info.userdata,
            w32.GWL_ID => info.id,
            w32.GWL_HINSTANCE => @bitCast(@as(u32, @truncate(kernel32.main_module_handle))),
            else => 0,
        };
    } else {
        result = switch (nIndex) {
            w32.GWL_STYLE => if (is_main) @bitCast(user32.window_style) else 0,
            w32.GWL_EXSTYLE => if (is_main) @bitCast(user32.window_exstyle) else 0,
            w32.GWL_HINSTANCE => @bitCast(@as(u32, @truncate(kernel32.main_module_handle))),
            else => 0,
        };
    }

    // Fallback for main window WndProc if not in info table
    if (nIndex == w32.GWL_WNDPROC and result == 0 and is_main) {
        if (user32.global_wndproc) |wndproc| result = @bitCast(@as(u32, @truncate(@intFromPtr(wndproc))));
    }

    if (trace.enable_tracing) trace.print("USER32: GetWindowLongA(hwnd={x}, index={d}) -> {x}\n", .{ hWnd, nIndex, @as(u32, @bitCast(result)) });
    return result;
}

pub fn stub_SetWindowLongA(hWnd: usize, nIndex: i32, dwNewLong: i32) callconv(w32cc.WINAPI) i32 {
    const old = stub_GetWindowLongA(hWnd, nIndex);
    const is_main = (hWnd == user32.global_hwnd) or (hWnd == 0);

    if (user32.getWindowInfo(hWnd)) |info| {
        switch (nIndex) {
            w32.GWL_STYLE => {
                info.style = dwNewLong;
                if (is_main) user32.window_style = @bitCast(dwNewLong);
            },
            w32.GWL_EXSTYLE => {
                info.exstyle = dwNewLong;
                if (is_main) user32.window_exstyle = @bitCast(dwNewLong);
            },
            w32.GWL_USERDATA => info.userdata = dwNewLong,
            w32.GWL_ID => info.id = dwNewLong,
            w32.GWL_WNDPROC => {
                if (dwNewLong != 0) {
                    info.proc = @as(usize, @bitCast(@as(isize, dwNewLong)));
                    if (is_main) user32.global_wndproc = @ptrFromInt(info.proc);
                }
            },
            else => {},
        }
    }

    if (trace.enable_tracing) trace.print("USER32: SetWindowLongA(hwnd={x}, index={d}, val={x})\n", .{ hWnd, nIndex, @as(u32, @bitCast(dwNewLong)) });
    return old;
}

pub fn stub_SetWindowPos(hWnd: usize, hWndInsertAfter: usize, X: i32, Y: i32, cx: i32, cy: i32, uFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = hWndInsertAfter;
    if (trace.enable_tracing) trace.print("USER32: SetWindowPos(hwnd={x}, cx={d}, cy={d}, flags={x})\n", .{ hWnd, cx, cy, uFlags });

    // Only update global window dimensions for the main window, not child windows
    const is_main_window = (hWnd == user32.global_hwnd) or (hWnd == 0);

    if (is_main_window and (uFlags & w32.SWP_NOSIZE) == 0 and cx > 0 and cy > 0) {
        user32.window_width = cx;
        user32.window_height = cy;

        const adj = user32.calcFrameAdjustments(user32.window_style, user32.window_has_menu, user32.window_exstyle);
        user32.current_client_width = cx - adj.left - adj.right;
        if (user32.current_client_width < 1) user32.current_client_width = 1;
        user32.current_client_height = cy - adj.top - adj.bottom;
        if (user32.current_client_height < 1) user32.current_client_height = 1;

        if (trace.enable_tracing) trace.print("  -> client {d}x{d}\n", .{ user32.current_client_width, user32.current_client_height });

        renderer.setResolution(@intCast(user32.current_client_width), @intCast(user32.current_client_height));
        renderer.setWindowPos(cx, cy, user32.current_client_width, user32.current_client_height);

        // Post WM_SIZE so the app knows the client area changed
        const cw: u32 = @intCast(@as(u16, @truncate(@as(u32, @bitCast(user32.current_client_width)))));
        const ch: u32 = @intCast(@as(u16, @truncate(@as(u32, @bitCast(user32.current_client_height)))));
        user32.postGenericMessage(w32.WM_SIZE, w32.SIZE_RESTORED, @as(isize, @intCast((ch << 16) | cw)));
    } else if (!is_main_window) {
        // Child window — if it's the edit control, resize the edit control in the renderer
        if (hWnd == user32.edit_hwnd and cx > 0 and cy > 0) {
            if (trace.enable_tracing) trace.print("  -> edit control resize to {d}x{d} at ({d},{d})\n", .{ cx, cy, X, Y });
            renderer.resizeEditControl(X, Y, cx, cy);
        }
    }

    return 1;
}

pub fn stub_MoveWindow(hWnd: usize, X: i32, Y: i32, nWidth: i32, nHeight: i32, bRepaint: i32) callconv(w32cc.WINAPI) i32 {
    _ = bRepaint;
    return stub_SetWindowPos(hWnd, 0, X, Y, nWidth, nHeight, 0);
}


pub fn stub_ShowWindow(hWnd: usize, nCmdShow: i32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: ShowWindow(nCmdShow={d})\n", .{nCmdShow});
    return 1;
}

pub fn stub_DestroyWindow(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: DestroyWindow(0x{X})\n", .{hWnd});
    // Send WM_DESTROY to WndProc so the app calls PostQuitMessage
    if (user32.global_wndproc) |wndproc| {
        var err: u32 = 0;
        _ = user32.callWndProcSafe(@intFromPtr(wndproc), hWnd, w32.WM_DESTROY, 0, 0, &err);
    }
    return 1;
}

pub fn stub_EnableWindow(hWnd: usize, bEnable: i32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = bEnable;
    return 0;
}

pub fn stub_IsWindow(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 1;
}

pub fn stub_GetForegroundWindow() callconv(w32cc.WINAPI) usize {
    return user32.global_hwnd;
}

pub fn stub_SetForegroundWindow(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 1;
}

pub fn stub_GetActiveWindow() callconv(w32cc.WINAPI) usize {
    return user32.global_hwnd;
}

pub fn stub_GetDesktopWindow() callconv(w32cc.WINAPI) usize {
    return 0x00010010;
}

pub fn stub_SetFocus(hWnd: usize) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: SetFocus\n", .{});
    return 0;
}

pub fn stub_GetFocus() callconv(w32cc.WINAPI) usize {
    return user32.global_hwnd;
}

pub fn stub_IsIconic(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 0;
}

pub fn stub_UpdateWindow(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: UpdateWindow\n", .{});
    // In real Windows, UpdateWindow always sends WM_PAINT if the window has an
    // invalid region. After CreateWindow, the entire client area is invalid.
    // Always dispatch WM_PAINT to the WndProc.
    if (user32.global_wndproc) |wndproc| {
        if (trace.enable_tracing) trace.print("USER32: UpdateWindow -> dispatching WM_PAINT to WndProc\n", .{});
        var err: u32 = 0;
        _ = user32.callWndProcSafe(@intFromPtr(wndproc), hWnd, w32.WM_PAINT, 0, 0, &err);
    }
    user32.needs_paint = false;
    return 1;
}

pub fn stub_RedrawWindow(hWnd: usize, lprcUpdate: usize, hrgnUpdate: usize, flags: u32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd; _ = lprcUpdate; _ = hrgnUpdate;
    if (trace.enable_tracing) trace.print("USER32: RedrawWindow(flags={x})\n", .{flags});
    const RDW_INVALIDATE: u32 = 0x0001;
    const RDW_ERASE: u32 = 0x0004;
    if ((flags & RDW_INVALIDATE) != 0) user32.needs_paint = true;
    if ((flags & RDW_ERASE) != 0) user32.bg_needs_erase = true;
    return 1;
}

pub fn stub_InvalidateRect(hWnd: usize, lpRect: usize, bErase: i32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = lpRect;
    _ = bErase;
    user32.needs_paint = true;
    return 1;
}

pub fn stub_ClientToScreen(hWnd: usize, lpPoint: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    if (lpPoint == 0) return 0;
    const pt = @as(*w32.POINT, @ptrFromInt(lpPoint));
    // Add frame offsets to convert from client to screen coordinates
    const adj = user32.calcFrameAdjustments(user32.window_style, user32.window_has_menu, user32.window_exstyle);
    pt.x += user32.window_x + adj.left;
    pt.y += user32.window_y + adj.top;
    return 1;
}

pub fn stub_ScreenToClient(hWnd: usize, lpPoint: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    if (lpPoint == 0) return 0;
    const pt = @as(*w32.POINT, @ptrFromInt(lpPoint));
    // Subtract frame offsets to convert from screen to client coordinates
    const adj = user32.calcFrameAdjustments(user32.window_style, user32.window_has_menu, user32.window_exstyle);
    pt.x -= user32.window_x + adj.left;
    pt.y -= user32.window_y + adj.top;
    return 1;
}

pub fn stub_MapWindowPoints(hWndFrom: usize, hWndTo: usize, lpPoints: usize, cPoints: u32) callconv(w32cc.WINAPI) i32 {
    _ = hWndFrom;
    _ = hWndTo;
    _ = lpPoints;
    _ = cPoints;
    return 0;
}

pub fn stub_FillRect(hDC: usize, lprc: usize, hbr: usize) callconv(w32cc.WINAPI) i32 {
    const drawing = @import("../gdi32/drawing.zig");
    const gdi32 = @import("../gdi32.zig");
    const rend = @import("../../gui/renderer.zig");

    if (drawing.getFramebufferForDc(hDC)) |fb| {
        const rect = @as(*const w32.RECT, @ptrFromInt(lprc));
        var color: u32 = 0x00FFFFFF; // Default white

        // hbr can be a real brush handle or a system color index + 1
        if (hbr <= 30) {
            // System color brush (COLOR_xxx + 1)
            color = switch (hbr) {
                1 => 0x00C0C0C0,  // COLOR_SCROLLBAR (silver)
                2 => 0x00C0C0C0,  // COLOR_BACKGROUND (silver)
                4 => 0x00808080,  // COLOR_MENU
                5 => 0x00FFFFFF,  // COLOR_WINDOW
                6 => 0x00000000,  // COLOR_WINDOWFRAME
                7 => 0x00000000,  // COLOR_MENUTEXT
                8 => 0x00000000,  // COLOR_WINDOWTEXT
                9 => 0x00FFFFFF,  // COLOR_CAPTIONTEXT
                16 => 0x00C0C0C0, // COLOR_BTNFACE
                else => 0x00C0C0C0,
            };
        } else if (gdi32.findObject(hbr)) |obj| {
            if (obj.obj_type == .Brush) color = obj.data.brush.color;
        }

        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        fb.fillRect(rect.left, rect.top, w, h, color);
        if (fb.is_screen) rend.markScreenDirty();
    }
    return 1;
}

pub fn stub_GetDC(hWnd: usize) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    return 0xDC123;
}

pub fn stub_ReleaseDC(hWnd: usize, hDC: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd; _ = hDC;
    return 1;
}

pub fn stub_BeginPaint(hWnd: usize, lpPaint: usize) callconv(w32cc.WINAPI) usize {
    _ = lpPaint;
    const hdc: usize = 0xDC123;

    // In real Windows, BeginPaint sends WM_ERASEBKGND only if the background
    // hasn't been erased since the last InvalidateRect. Use the one-shot flag.
    if (user32.bg_needs_erase) {
        user32.bg_needs_erase = false;

        const wndproc_addr: usize = if (user32.getWndProc(hWnd)) |p| p
            else if (user32.global_wndproc) |p| @intFromPtr(p)
            else 0;

        if (wndproc_addr != 0) {
            var err_flag: u32 = 0;
            _ = user32.callWndProcSafe(wndproc_addr, hWnd, 0x0014, hdc, 0, &err_flag); // WM_ERASEBKGND
        }
    }

    return hdc;
}

pub fn stub_EndPaint(hWnd: usize, lpPaint: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd; _ = lpPaint;
    // Flush any batched screen updates accumulated during BeginPaint..EndPaint
    const rend = @import("../../gui/renderer.zig");
    rend.flushScreenIfDirty();
    return 1;
}

// --- Scroll ---

pub fn stub_SetScrollInfo(hwnd: usize, nBar: i32, lpsi: usize, redraw: i32) callconv(w32cc.WINAPI) i32 {
    _ = hwnd;
    _ = nBar;
    _ = lpsi;
    _ = redraw;
    return 0;
}

pub fn stub_GetScrollInfo(hwnd: usize, nBar: i32, lpsi: usize) callconv(w32cc.WINAPI) i32 {
    _ = hwnd;
    _ = nBar;
    _ = lpsi;
    return 0;
}

// --- Drawing ---

pub fn stub_CopyImage(h: usize, typ: u32, cx: i32, cy: i32, flags: u32) callconv(w32cc.WINAPI) usize {
    _ = typ;
    _ = cx;
    _ = cy;
    _ = flags;
    return h;
}

pub fn stub_DrawEdge(hdc: usize, qrc: usize, edge: u32, grfFlags: u32) callconv(w32cc.WINAPI) i32 {
    if (qrc == 0) return 0;
    const drawing = @import("../gdi32/drawing.zig");
    const rend = @import("../../gui/renderer.zig");
    const misc = @import("misc.zig");

    const fb = drawing.getFramebufferForDc(hdc) orelse return 0;
    const rc = @as(*w32.RECT, @ptrFromInt(qrc));

    if (trace.enable_tracing) trace.print("USER32: DrawEdge(edge={x}, flags={x}, rect={d},{d},{d},{d})\n", .{ edge, grfFlags, rc.left, rc.top, rc.right, rc.bottom });

    // Win32 edge flags
    const BDR_RAISEDOUTER: u32 = 0x0001;
    const BDR_SUNKENOUTER: u32 = 0x0002;
    const BDR_RAISEDINNER: u32 = 0x0004;
    const BDR_SUNKENINNER: u32 = 0x0008;
    // Edge types (combinations)
    // EDGE_RAISED = BDR_RAISEDOUTER | BDR_RAISEDINNER = 0x0005
    // EDGE_SUNKEN = BDR_SUNKENOUTER | BDR_SUNKENINNER = 0x000A
    // EDGE_ETCHED = BDR_SUNKENOUTER | BDR_RAISEDINNER = 0x0006
    // EDGE_BUMP   = BDR_RAISEDOUTER | BDR_SUNKENINNER = 0x0009

    // Border flags
    const BF_LEFT: u32 = 0x0001;
    const BF_TOP: u32 = 0x0002;
    const BF_RIGHT: u32 = 0x0004;
    const BF_BOTTOM: u32 = 0x0008;
    const BF_MIDDLE: u32 = 0x0800;
    const BF_ADJUST: u32 = 0x2000;

    // Win2k system colors for 3D effects (COLORREF = 0x00BBGGRR)
    const highlight = misc.stub_GetSysColor(20);     // COLOR_BTNHIGHLIGHT (#FFFFFF)
    const light = misc.stub_GetSysColor(22);           // COLOR_3DLIGHT (#D4D0C8)
    const shadow = misc.stub_GetSysColor(16);          // COLOR_BTNSHADOW (#808080)
    const dkshadow = misc.stub_GetSysColor(21);        // COLOR_3DDKSHADOW (#404040)
    const face = misc.stub_GetSysColor(15);            // COLOR_BTNFACE (#D4D0C8)

    // Determine outer and inner edge colors
    var outer_tl: u32 = face; // top-left color
    var outer_br: u32 = face; // bottom-right color
    var inner_tl: u32 = face;
    var inner_br: u32 = face;

    // Outer edge
    if ((edge & BDR_RAISEDOUTER) != 0) {
        outer_tl = light;
        outer_br = dkshadow;
    } else if ((edge & BDR_SUNKENOUTER) != 0) {
        outer_tl = shadow;
        outer_br = highlight;
    }

    // Inner edge
    if ((edge & BDR_RAISEDINNER) != 0) {
        inner_tl = highlight;
        inner_br = shadow;
    } else if ((edge & BDR_SUNKENINNER) != 0) {
        inner_tl = dkshadow;
        inner_br = light;
    }

    const has_outer = (edge & (BDR_RAISEDOUTER | BDR_SUNKENOUTER)) != 0;
    const has_inner = (edge & (BDR_RAISEDINNER | BDR_SUNKENINNER)) != 0;
    const sides = if (grfFlags & (BF_LEFT | BF_TOP | BF_RIGHT | BF_BOTTOM) != 0) grfFlags else (BF_LEFT | BF_TOP | BF_RIGHT | BF_BOTTOM);

    var left = rc.left;
    var top = rc.top;
    var right = rc.right;
    var bottom = rc.bottom;

    // Fill middle if requested
    if ((grfFlags & BF_MIDDLE) != 0) {
        fb.fillRect(left, top, right - left, bottom - top, face);
    }

    // Draw outer edge
    if (has_outer) {
        if ((sides & BF_TOP) != 0) fb.fillRect(left, top, right - left, 1, outer_tl);
        if ((sides & BF_LEFT) != 0) fb.fillRect(left, top, 1, bottom - top, outer_tl);
        if ((sides & BF_BOTTOM) != 0) fb.fillRect(left, bottom - 1, right - left, 1, outer_br);
        if ((sides & BF_RIGHT) != 0) fb.fillRect(right - 1, top, 1, bottom - top, outer_br);
        left += 1;
        top += 1;
        right -= 1;
        bottom -= 1;
    }

    // Draw inner edge
    if (has_inner) {
        if ((sides & BF_TOP) != 0) fb.fillRect(left, top, right - left, 1, inner_tl);
        if ((sides & BF_LEFT) != 0) fb.fillRect(left, top, 1, bottom - top, inner_tl);
        if ((sides & BF_BOTTOM) != 0) fb.fillRect(left, bottom - 1, right - left, 1, inner_br);
        if ((sides & BF_RIGHT) != 0) fb.fillRect(right - 1, top, 1, bottom - top, inner_br);
        left += 1;
        top += 1;
        right -= 1;
        bottom -= 1;
    }

    // BF_ADJUST: shrink the rect to the interior
    if ((grfFlags & BF_ADJUST) != 0) {
        rc.left = left;
        rc.top = top;
        rc.right = right;
        rc.bottom = bottom;
    }

    if (fb.is_screen) rend.markScreenDirty();
    return 1;
}

pub fn stub_DrawFocusRect(hDC: usize, lprc: usize) callconv(w32cc.WINAPI) i32 {
    _ = hDC;
    _ = lprc;
    return 1;
}

pub fn stub_FrameRect(hDC: usize, lprc: usize, hbr: usize) callconv(w32cc.WINAPI) i32 {
    if (lprc == 0) return 0;
    const drawing = @import("../gdi32/drawing.zig");
    const gdi32 = @import("../gdi32.zig");
    const rend = @import("../../gui/renderer.zig");
    const misc = @import("misc.zig");

    const fb = drawing.getFramebufferForDc(hDC) orelse return 0;
    const rc = @as(*const w32.RECT, @ptrFromInt(lprc));

    // Resolve brush color
    var color: u32 = 0x00000000;
    if (hbr <= 30) {
        // System color brush (COLOR_xxx + 1)
        color = misc.stub_GetSysColor(@intCast(hbr -| 1));
    } else if (gdi32.findObject(hbr)) |obj| {
        if (obj.obj_type == .Brush) color = obj.data.brush.color;
    }

    const left = rc.left;
    const top = rc.top;
    const right = rc.right;
    const bottom = rc.bottom;

    // Draw 1-pixel border on each side
    fb.fillRect(left, top, right - left, 1, color);            // Top
    fb.fillRect(left, bottom - 1, right - left, 1, color);     // Bottom
    fb.fillRect(left, top, 1, bottom - top, color);            // Left
    fb.fillRect(right - 1, top, 1, bottom - top, color);       // Right

    if (fb.is_screen) rend.markScreenDirty();
    return 1;
}

// --- Window Enumeration & State ---

pub fn stub_EnumWindows(lpEnumFunc: usize, lParam: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpEnumFunc;
    _ = lParam;
    return 1;
}

pub fn stub_IsChild(hWndParent: usize, hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWndParent;
    _ = hWnd;
    return 0;
}

pub fn stub_IsWindowEnabled(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 1;
}

// --- Icons & Cursors ---

pub fn stub_GetIconInfo(hIcon: usize, piconinfo: usize) callconv(w32cc.WINAPI) i32 {
    _ = hIcon;
    _ = piconinfo;
    return 0;
}

pub fn stub_DestroyIcon(hIcon: usize) callconv(w32cc.WINAPI) i32 {
    _ = hIcon;
    return 1;
}

pub fn stub_DestroyCursor(hCursor: usize) callconv(w32cc.WINAPI) i32 {
    _ = hCursor;
    return 1;
}

// --- Clipboard ---

pub fn stub_OpenClipboard(hWndNewOwner: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWndNewOwner;
    return 1;
}

pub fn stub_CloseClipboard() callconv(w32cc.WINAPI) i32 {
    return 1;
}

pub fn stub_EmptyClipboard() callconv(w32cc.WINAPI) i32 {
    return 1;
}

pub fn stub_GetClipboardData(uFormat: u32) callconv(w32cc.WINAPI) usize {
    _ = uFormat;
    return 0;
}

pub fn stub_SetClipboardData(uFormat: u32, hMem: usize) callconv(w32cc.WINAPI) usize {
    _ = uFormat;
    return hMem;
}

pub fn stub_IsClipboardFormatAvailable(format: u32) callconv(w32cc.WINAPI) i32 {
    _ = format;
    return 0;
}

pub fn stub_GetClipboardOwner() callconv(w32cc.WINAPI) usize {
    return 0;
}

// --- Caret ---

pub fn stub_CreateCaret(hWnd: usize, hBitmap: usize, nWidth: i32, nHeight: i32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = hBitmap;
    _ = nWidth;
    _ = nHeight;
    return 1;
}

pub fn stub_DestroyCaret() callconv(w32cc.WINAPI) i32 {
    return 1;
}

pub fn stub_SetCaretPos(X: i32, Y: i32) callconv(w32cc.WINAPI) i32 {
    _ = X;
    _ = Y;
    return 1;
}

pub fn stub_ShowCaret(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 1;
}

pub fn stub_HideCaret(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 1;
}

// --- Rect Utilities (faithful Win32 implementations) ---

pub fn stub_CopyRect(lprcDst: *user32.RECT, lprcSrc: *const user32.RECT) callconv(w32cc.WINAPI) i32 {
    lprcDst.* = lprcSrc.*;
    return 1;
}

pub fn stub_PtInRect(lprc: *const user32.RECT, ptX: i32, ptY: i32) callconv(w32cc.WINAPI) i32 {
    // Win32: returns TRUE if point is inside rect (left <= x < right, top <= y < bottom)
    if (ptX >= lprc.left and ptX < lprc.right and ptY >= lprc.top and ptY < lprc.bottom) return 1;
    return 0;
}

pub fn stub_OffsetRect(lprc: *user32.RECT, dx: i32, dy: i32) callconv(w32cc.WINAPI) i32 {
    lprc.left += dx;
    lprc.top += dy;
    lprc.right += dx;
    lprc.bottom += dy;
    return 1;
}

pub fn stub_SetRectEmpty(lprc: *user32.RECT) callconv(w32cc.WINAPI) i32 {
    lprc.left = 0;
    lprc.top = 0;
    lprc.right = 0;
    lprc.bottom = 0;
    return 1;
}

pub fn stub_IsRectEmpty(lprc: *const user32.RECT) callconv(w32cc.WINAPI) i32 {
    // Win32: empty if width <= 0 or height <= 0
    if (lprc.right <= lprc.left or lprc.bottom <= lprc.top) return 1;
    return 0;
}

pub fn stub_EqualRect(lprc1: *const user32.RECT, lprc2: *const user32.RECT) callconv(w32cc.WINAPI) i32 {
    if (lprc1.left == lprc2.left and lprc1.top == lprc2.top and
        lprc1.right == lprc2.right and lprc1.bottom == lprc2.bottom) return 1;
    return 0;
}

pub fn stub_InflateRect(lprc: *user32.RECT, dx: i32, dy: i32) callconv(w32cc.WINAPI) i32 {
    lprc.left -= dx;
    lprc.top -= dy;
    lprc.right += dx;
    lprc.bottom += dy;
    return 1;
}

pub fn stub_IntersectRect(lprcDst: *user32.RECT, lprcSrc1: *const user32.RECT, lprcSrc2: *const user32.RECT) callconv(w32cc.WINAPI) i32 {
    const left = @max(lprcSrc1.left, lprcSrc2.left);
    const top = @max(lprcSrc1.top, lprcSrc2.top);
    const right = @min(lprcSrc1.right, lprcSrc2.right);
    const bottom = @min(lprcSrc1.bottom, lprcSrc2.bottom);
    if (left < right and top < bottom) {
        lprcDst.left = left;
        lprcDst.top = top;
        lprcDst.right = right;
        lprcDst.bottom = bottom;
        return 1;
    }
    lprcDst.left = 0;
    lprcDst.top = 0;
    lprcDst.right = 0;
    lprcDst.bottom = 0;
    return 0;
}

pub fn stub_UnionRect(lprcDst: *user32.RECT, lprcSrc1: *const user32.RECT, lprcSrc2: *const user32.RECT) callconv(w32cc.WINAPI) i32 {
    lprcDst.left = @min(lprcSrc1.left, lprcSrc2.left);
    lprcDst.top = @min(lprcSrc1.top, lprcSrc2.top);
    lprcDst.right = @max(lprcSrc1.right, lprcSrc2.right);
    lprcDst.bottom = @max(lprcSrc1.bottom, lprcSrc2.bottom);
    return 1;
}

pub fn stub_SubtractRect(lprcDst: *user32.RECT, lprcSrc1: *const user32.RECT, lprcSrc2: *const user32.RECT) callconv(w32cc.WINAPI) i32 {
    // Simplified: if src2 doesn't intersect src1, result is src1
    // Full implementation is complex; this handles the common case
    _ = lprcSrc2;
    lprcDst.* = lprcSrc1.*;
    return 1;
}

// --- Window/Class W variants ---

pub fn stub_FindWindowW(lpClassName: usize, lpWindowName: usize) callconv(w32cc.WINAPI) usize {
    _ = lpClassName;
    _ = lpWindowName;
    if (trace.enable_tracing) trace.print("USER32: FindWindowW -> 0\n", .{});
    return 0; // not found
}

pub fn stub_FindWindowExW(hWndParent: usize, hWndChildAfter: usize, lpszClass: usize, lpszWindow: usize) callconv(w32cc.WINAPI) usize {
    _ = hWndParent;
    _ = hWndChildAfter;
    _ = lpszClass;
    _ = lpszWindow;
    return 0;
}

pub fn stub_GetClassInfoW(hInstance: usize, lpClassName: usize, lpWndClass: usize) callconv(w32cc.WINAPI) i32 {
    _ = hInstance;
    _ = lpClassName;
    _ = lpWndClass;
    if (trace.enable_tracing) trace.print("USER32: GetClassInfoW -> 0\n", .{});
    return 0; // class not found
}

pub fn stub_GetClassInfoExW(hInstance: usize, lpszClass: usize, lpwcx: usize) callconv(w32cc.WINAPI) i32 {
    _ = hInstance;
    _ = lpszClass;
    _ = lpwcx;
    return 0;
}

pub fn stub_SystemParametersInfoW(uiAction: u32, uiParam: u32, pvParam: usize, fWinIni: u32) callconv(w32cc.WINAPI) i32 {
    _ = uiParam;
    _ = fWinIni;
    if (trace.enable_tracing) trace.print("USER32: SystemParametersInfoW(action=0x{x})\n", .{uiAction});
    // SPI_GETWORKAREA
    if (uiAction == w32.SPI_GETWORKAREA and pvParam != 0) {
        const rect = @as(*user32.RECT, @ptrFromInt(pvParam));
        rect.left = 0;
        rect.top = 0;
        rect.right = @intCast(user32.current_client_width);
        rect.bottom = @intCast(user32.current_client_height);
        return 1;
    }
    // SPI_GETNONCLIENTMETRICS
    if (uiAction == w32.SPI_GETNONCLIENTMETRICS and pvParam != 0) {
        const size_ptr = @as(*u32, @ptrFromInt(pvParam));
        const total = size_ptr.*;
        const bytes = @as([*]u8, @ptrFromInt(pvParam));
        @memset(bytes[0..total], 0);
        size_ptr.* = total;
        return 1;
    }
    return 1; // success for unhandled
}

pub fn stub_GetUpdateRect(hWnd: usize, lpRect: usize, bErase: i32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = bErase;
    if (lpRect != 0) {
        const rect = @as(*user32.RECT, @ptrFromInt(lpRect));
        rect.left = 0;
        rect.top = 0;
        rect.right = 0;
        rect.bottom = 0;
    }
    return 0; // no update region
}

pub fn stub_GetWindowDC(hWnd: usize) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    return 0xDC123; // same as GetDC
}

pub fn stub_DrawMenuBar(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    return 1;
}
