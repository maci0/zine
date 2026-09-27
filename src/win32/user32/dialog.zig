const std = @import("std");
const trace = @import("../../trace.zig");
const ansi = @import("../ansi.zig");
const text_utils = @import("../../text_utils.zig");
const user32 = @import("../user32.zig");
const renderer = @import("../../gui/renderer.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");

const DIALOG_HWND: usize = 0x00000456;

// --- Modal dialog state ---
pub var modal_dialog_active: bool = false;
var modal_dialog_result: isize = 0;
var modal_dialog_dismissed: bool = false;
var modal_dlgproc: usize = 0;

pub fn MessageBoxA(hWnd: usize, lpText: usize, lpCaption: usize, uType: u32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = uType;
    // The guest hands over CP1252 bytes; the renderer and the web UI take UTF-8.
    var caption_buf: [256]u8 = undefined;
    var text_buf: [2048]u8 = undefined;
    const caption = if (lpCaption != 0) ansi.toUtf8(trace.c_span(lpCaption), &caption_buf) else "(null)";
    const text = if (lpText != 0) ansi.toUtf8(trace.c_span(lpText), &text_buf) else "(null)";

    if (trace.enable_tracing) trace.print("USER32: MessageBoxA(caption='{s}', text='{s}')\n", .{ caption, text });

    renderer.showMessageBox(caption, text);

    return 1; // IDOK
}

pub fn DialogBoxParamA(hInstance: usize, lpTemplateName: usize, hWndParent: usize, lpDialogFunc: usize, dwInitParam: isize) callconv(w32cc.WINAPI) isize {
    _ = hWndParent;
    if (trace.enable_tracing) trace.print("USER32: DialogBoxParamA(template={x}, dlgproc={x})\n", .{ lpTemplateName, lpDialogFunc });

    var hInst = hInstance;
    if (hInst == 0) hInst = @import("../kernel32.zig").main_module_handle;

    var mod: ?*@import("../../loader/module.zig").Module = null;
    if (@import("../kernel32.zig").global_env) |genv| {
        var it = genv.registry.modules.valueIterator();
        while (it.next()) |m| {
            if (@intFromPtr(m.*.mapped_memory.ptr) == hInst) {
                mod = m.*;
                break;
            }
        }
    }

    if (lpTemplateName < 0x10000) {
        var pushed = false;

        if (mod) |m| {
            const dialog_parser = @import("../../loader/dialog_parser.zig");
            if (dialog_parser.parseDialogResource(m.allocator, m, @as(u32, @intCast(lpTemplateName))) catch null) |json_str| {
                renderer.showDialog(json_str);
                m.allocator.free(json_str);
                pushed = true;
            }
        }

        if (!pushed) {
            renderer.showMessageBox("About", "Windows application running via Zine\n\n(DialogBoxParamA stub)");
        }

        // Set up modal state BEFORE calling DlgProc (EndDialog may be called from within)
        modal_dialog_active = true;
        modal_dialog_dismissed = false;
        modal_dialog_result = 0;
        modal_dlgproc = lpDialogFunc;

        // Install cancel_dialog handler for browser close button
        const prev_cancel = renderer.on_cancel_dialog;
        renderer.on_cancel_dialog = &handleModalCancel;
        defer renderer.on_cancel_dialog = prev_cancel;

        if (lpDialogFunc != 0) {
            if (trace.enable_tracing) trace.print("USER32: Calling DlgProc with WM_INITDIALOG\n", .{});
            var err_flag: u32 = 0;
            _ = user32.callWndProcSafe(lpDialogFunc, DIALOG_HWND, 0x0110, DIALOG_HWND, dwInitParam, &err_flag);
            if (err_flag != 0 and trace.enable_tracing) {
                trace.print("USER32: DlgProc WM_INITDIALOG threw exception\n", .{});
            }
        }

        // Modal message loop — block until EndDialog is called
        modalMessageLoop(lpDialogFunc);

        const result = modal_dialog_result;
        modal_dialog_active = false;
        modal_dlgproc = 0;

        // Close the dialog on the frontend
        renderer.closeDialog();

        if (trace.enable_tracing) trace.print("USER32: DialogBoxParamA returning {d}\n", .{result});
        return result;
    }

    return 1; // IDOK
}

/// Modal message loop: processes messages and routes WM_COMMAND to the DlgProc.
/// Blocks until EndDialog sets modal_dialog_dismissed.
fn modalMessageLoop(dlgproc: usize) void {
    while (!modal_dialog_dismissed) {
        var got_message = false;

        // Check for pending command (WM_COMMAND from WebSocket/menu)
        var cmd_to_dispatch: ?u32 = null;
        {
            user32.pending_command_mutex.lock();
            defer user32.pending_command_mutex.unlock();

            if (user32.pending_command) |cmd_id| {
                user32.pending_command = null;
                cmd_to_dispatch = cmd_id;
                got_message = true;
            }
        }

        // Dispatch WM_COMMAND outside the mutex (DlgProc may re-enter message APIs)
        if (cmd_to_dispatch) |cmd_id| {
            if (trace.enable_tracing) trace.print("USER32: Modal dialog dispatching WM_COMMAND({d}) to DlgProc\n", .{cmd_id});
            if (dlgproc != 0) {
                var err_flag: u32 = 0;
                _ = user32.callWndProcSafe(dlgproc, DIALOG_HWND, w32.WM_COMMAND, cmd_id, 0, &err_flag);
            }
        }

        // Check for queued messages (keyboard, WM_CLOSE, etc.)
        var queued_msg: ?user32.MSG = null;
        {
            user32.pending_command_mutex.lock();
            defer user32.pending_command_mutex.unlock();

            if (user32.pending_messages_tail != user32.pending_messages_head) {
                queued_msg = user32.pending_messages[user32.pending_messages_tail];
                user32.pending_messages_tail = (user32.pending_messages_tail + 1) % user32.pending_messages.len;
                got_message = true;
            }
        }

        // Dispatch queued message outside the mutex
        if (queued_msg) |msg| {
            // WM_QUIT should break the modal loop
            if (msg.message == w32.WM_QUIT) {
                modal_dialog_dismissed = true;
                modal_dialog_result = 0;
                break;
            }

            // Dialog-manager keyboard: Tab/Enter/Escape handled like
            // IsDialogMessage does for modeless dialogs.
            if (msg.message == 0x0100 or msg.message == 0x0104) { // WM_KEYDOWN / WM_SYSKEYDOWN
                const vk = msg.wParam & 0xFF;
                const handled = switch (vk) {
                    0x09 => blk: { // VK_TAB
                        const shift = (renderer.keyboard_state[0x10] & 0x80) != 0;
                        const next = nextTabStop(DIALOG_HWND, user32.focused_hwnd, shift);
                        if (next != user32.focused_hwnd) {
                            _ = @import("window.zig").stub_SetFocus(next);
                        }
                        break :blk true;
                    },
                    0x0D => blk: { // VK_RETURN
                        const def_btn = findDefaultButton(DIALOG_HWND);
                        if (def_btn != 0) {
                            const id = if (user32.getWindowInfo(def_btn)) |info| @as(u32, @intCast(info.id)) else 1;
                            sendDialogCommand(DIALOG_HWND, id);
                        }
                        break :blk true;
                    },
                    0x1B => blk: { // VK_ESCAPE
                        sendDialogCommand(DIALOG_HWND, DLGKB_IDCANCEL);
                        break :blk true;
                    },
                    else => false,
                };
                if (handled) continue;
            }

            if (dlgproc != 0) {
                var err_flag: u32 = 0;
                _ = user32.callWndProcSafe(dlgproc, DIALOG_HWND, msg.message, msg.wParam, @as(isize, @intCast(msg.lParam)), &err_flag);
            }
        }

        if (!got_message) {
            // Sleep briefly to avoid busy-waiting
            @import("../../platform.zig").sleep(1 * std.time.ns_per_ms);
        }
    }
}

/// Handler for browser dialog close button during modal dialog
fn handleModalCancel() void {
    if (modal_dialog_active) {
        modal_dialog_dismissed = true;
        modal_dialog_result = 0; // IDCANCEL equivalent
    }
}

pub fn EndDialog(hDlg: usize, nResult: isize) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    if (trace.enable_tracing) trace.print("USER32: EndDialog(result={d})\n", .{nResult});

    if (modal_dialog_active) {
        modal_dialog_result = nResult;
        modal_dialog_dismissed = true;
    }
    return 1;
}

pub fn GetDlgItem(hDlg: usize, nIDDlgItem: i32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("USER32: GetDlgItem(id={d})\n", .{nIDDlgItem});
    // Return a deterministic HWND for the child control based on the parent dialog and child ID
    // This allows subclassing child controls without subclassing the main dialog!
    return (hDlg << 8) ^ @as(usize, @bitCast(@as(isize, nIDDlgItem)));
}

// --- Dialog control text store (guest-visible state) ---
// SetDlgItemTextA/W and SetDlgItemInt write here; GetDlgItemTextA/W and
// GetDlgItemInt read it back, matching real Win32 where the control owns its
// text. Keyed by control id (the same id renderer.updateControlText uses).
const CtrlText = struct { id: i32, text: [512]u8, len: u16 };
var ctrl_texts: [64]CtrlText = undefined;
var ctrl_text_count: usize = 0;

fn setCtrlText(id: i32, text: []const u8) void {
    for (ctrl_texts[0..ctrl_text_count]) |*e| {
        if (e.id == id) {
            const n = ansi.truncateUtf8(text, e.text.len);
            @memcpy(e.text[0..n.len], n);
            e.len = @intCast(n.len);
            return;
        }
    }
    if (ctrl_text_count < ctrl_texts.len) {
        const e = &ctrl_texts[ctrl_text_count];
        ctrl_text_count += 1;
        e.id = id;
        const n = ansi.truncateUtf8(text, e.text.len);
        @memcpy(e.text[0..n.len], n);
        e.len = @intCast(n.len);
    }
}

pub fn getCtrlText(id: i32) []const u8 {
    var i: usize = ctrl_text_count;
    while (i > 0) {
        i -= 1;
        const e = &ctrl_texts[i];
        if (e.id == id) return e.text[0..e.len];
    }
    return "";
}

pub fn SetDlgItemTextA(hDlg: usize, nIDDlgItem: i32, lpString: usize) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    var buf: [512]u8 = undefined;
    const text = if (lpString != 0) ansi.toUtf8(trace.c_span(lpString), &buf) else "";
    if (trace.enable_tracing) {
        trace.print("USER32: SetDlgItemTextA(id={d}, text='{s}')\n", .{ nIDDlgItem, text });
    }
    setCtrlText(nIDDlgItem, text);
    renderer.updateControlText(nIDDlgItem, text);
    return 1;
}

pub fn SetDlgItemTextW(hDlg: usize, nIDDlgItem: i32, lpString: usize) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    const text = if (lpString != 0) trace.c_span_w(lpString) else &[_]u16{};
    var buf: [512]u8 = undefined;
    const converted = text_utils.wideToUtf8(text, &buf);
    if (trace.enable_tracing) {
        trace.print("USER32: SetDlgItemTextW(id={d}, text='{s}')\n", .{ nIDDlgItem, converted });
    }
    setCtrlText(nIDDlgItem, converted);
    renderer.updateControlText(nIDDlgItem, converted);
    return 1;
}

pub fn GetDlgItemTextA(hDlg: usize, nIDDlgItem: i32, lpString: usize, cchMax: i32) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    // The store holds UTF-8 (either the CP1252 text SetDlgItemTextA decoded, or
    // the UTF-16 of SetDlgItemTextW); the caller asked for ANSI bytes.
    const text = getCtrlText(nIDDlgItem);
    var buf: [512]u8 = undefined;
    const converted = ansi.fromUtf8(text, &buf);
    if (lpString != 0 and cchMax > 0) {
        const dst: [*]u8 = @ptrFromInt(trace.addr(lpString));
        const n = @min(converted.len, @as(usize, @intCast(cchMax)) - 1);
        @memcpy(dst[0..n], converted[0..n]);
        dst[n] = 0;
        return @intCast(n);
    }
    return 0;
}

pub fn GetDlgItemTextW(hDlg: usize, nIDDlgItem: i32, lpString: usize, cchMax: i32) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    const text = getCtrlText(nIDDlgItem);
    if (lpString != 0 and cchMax > 0) {
        const dst: [*]u16 = @ptrFromInt(trace.addr(lpString));
        // One code unit is reserved for the terminator.
        const pos = text_utils.utf8ToWide(text, dst[0 .. @as(usize, @intCast(cchMax)) - 1]);
        dst[pos] = 0;
        return @intCast(pos);
    }
    return 0;
}

pub fn stub_SendDlgItemMessageA(hDlg: usize, nIDDlgItem: i32, Msg: u32, wParam: usize, lParam: isize) callconv(w32cc.WINAPI) isize {
    _ = hDlg;
    _ = wParam;
    _ = lParam;
    if (trace.enable_tracing) trace.print("USER32: SendDlgItemMessageA(id={d}, msg={x})\n", .{ nIDDlgItem, Msg });
    if (Msg == 0x0172) {
        if (trace.enable_tracing) trace.print("  -> STM_SETIMAGE (bitmap handle)\n", .{});
    }
    return 0;
}

pub fn stub_CheckDlgButton(hDlg: usize, nIDButton: i32, uCheck: u32) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    _ = nIDButton;
    _ = uCheck;
    return 1;
}

pub fn stub_CheckRadioButton(hDlg: usize, nIDFirstButton: i32, nIDLastButton: i32, nIDCheckButton: i32) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    _ = nIDFirstButton;
    _ = nIDLastButton;
    _ = nIDCheckButton;
    return 1;
}

pub fn stub_IsDlgButtonChecked(hDlg: usize, nIDButton: i32) callconv(w32cc.WINAPI) u32 {
    _ = hDlg;
    _ = nIDButton;
    return 0;
}

pub fn GetDlgItemInt(hDlg: usize, nIDDlgItem: i32, lpTranslated: usize, bSigned: i32) callconv(w32cc.WINAPI) u32 {
    _ = hDlg;
    const text = getCtrlText(nIDDlgItem);
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    var neg = false;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) {
        neg = (text[i] == '-');
        i += 1;
    }
    var value: u32 = 0;
    const start = i;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') {
        value = value *% 10 +% (text[i] - '0');
        i += 1;
    }
    const ok = i > start;
    if (lpTranslated != 0) {
        @as(*i32, @ptrFromInt(trace.addr(lpTranslated))).* = if (ok) 1 else 0;
    }
    if (!ok) return 0;
    if (bSigned != 0 and neg) return 0 -% value;
    return value;
}

var next_dialog_hwnd: usize = DIALOG_HWND;

pub fn CreateDialogParamA(hInstance: usize, lpTemplateName: usize, hWndParent: usize, lpDialogFunc: usize, dwInitParam: usize) callconv(w32cc.WINAPI) usize {
    _ = hWndParent;

    const dialog_hwnd = next_dialog_hwnd;
    next_dialog_hwnd += 1;

    if (trace.enable_tracing) trace.print("USER32: CreateDialogParamA(dlgproc={x}, template={x}) -> hwnd={x}\n", .{ lpDialogFunc, lpTemplateName, dialog_hwnd });

    // Store the DlgProc for this dialog hwnd so DispatchMessage can find it
    user32.setWndProc(dialog_hwnd, lpDialogFunc);

    // Set as the global hwnd only for the first (main) dialog
    if (dialog_hwnd == DIALOG_HWND) {
        user32.global_hwnd = DIALOG_HWND;
    }

    // Try to parse the dialog template and render controls in-place
    if (lpTemplateName < 0x10000) {
        var hInst = hInstance;
        if (hInst == 0) hInst = @import("../kernel32.zig").main_module_handle;

        if (trace.enable_tracing) trace.print("  dialog: hInst={x}, looking for module...\n", .{hInst});

        var mod: ?*@import("../../loader/module.zig").Module = null;
        if (@import("../kernel32.zig").global_env) |genv| {
            var it = genv.registry.modules.valueIterator();
            while (it.next()) |m| {
                if (@intFromPtr(m.*.mapped_memory.ptr) == hInst) {
                    mod = m.*;
                    break;
                }
            }
        }

        if (mod) |m| {
            if (trace.enable_tracing) trace.print("  dialog: found module, parsing resource {d}...\n", .{@as(u32, @intCast(lpTemplateName))});
            const dialog_parser = @import("../../loader/dialog_parser.zig");
            if (dialog_parser.parseDialogResource(m.allocator, m, @as(u32, @intCast(lpTemplateName))) catch null) |json_str| {
                if (trace.enable_tracing) trace.print("  dialog: parsed {d} bytes JSON\n", .{json_str.len});
                // Only send show_controls for the main dialog; child dialogs are ignored for now
                if (dialog_hwnd == DIALOG_HWND) {
                    renderer.showControls(json_str);
                }
                m.allocator.free(json_str);
            } else {
                if (trace.enable_tracing) trace.print("  dialog: parseDialogResource returned null\n", .{});
            }
        } else {
            if (trace.enable_tracing) trace.print("  dialog: module NOT found for hInst={x}\n", .{hInst});
        }
    }

    // Call WM_INITDIALOG
    if (lpDialogFunc != 0) {
        var err_flag: u32 = 0;
        _ = user32.callWndProcSafe(lpDialogFunc, dialog_hwnd, 0x0110, 0, @bitCast(dwInitParam), &err_flag);
    }

    // Real dialogs focus the first WS_TABSTOP control. This gives
    // IsDialogMessage a starting point for Tab navigation.
    {
        const first = nextTabStop(dialog_hwnd, 0, false);
        if (first != 0) {
            user32.focused_hwnd = first;
            if (trace.enable_tracing) trace.print("USER32: CreateDialogParamA initial focus={x}\n", .{first});
        }
    }

    return dialog_hwnd;
}

pub fn SetDlgItemInt(hDlg: usize, nIDDlgItem: i32, uValue: u32, bSigned: i32) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    if (trace.enable_tracing) trace.print("USER32: SetDlgItemInt(id={d}, val={d})\n", .{ nIDDlgItem, uValue });
    // Format as a decimal string (signed when bSigned, else unsigned) and push
    // it through the same text path so GetDlgItemInt round-trips and the UI
    // shows the value.
    var buf: [16]u8 = undefined;
    var text: []const u8 = undefined;
    if (bSigned != 0 and (@as(i32, @bitCast(uValue)) < 0)) {
        text = std.fmt.bufPrint(&buf, "{d}", .{@as(i32, @bitCast(uValue))}) catch buf[0..0];
    } else {
        text = std.fmt.bufPrint(&buf, "{d}", .{uValue}) catch buf[0..0];
    }
    setCtrlText(nIDDlgItem, text);
    renderer.updateControlText(nIDDlgItem, text);
    return 1;
}

pub fn MessageBoxW(hWnd: usize, lpText: usize, lpCaption: usize, uType: u32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = uType;
    if (trace.enable_tracing) trace.print("USER32: MessageBoxW\n", .{});
    // Convert wide (UTF-16LE) strings to UTF-8 for the renderer. The old
    // @truncate-per-wchar approach garbled any non-ASCII text.
    if (lpCaption != 0 and lpText != 0) {
        const caption_w = trace.c_span_w(lpCaption);
        const text_w = trace.c_span_w(lpText);
        var caption_buf: [256]u8 = undefined;
        var text_buf: [2048]u8 = undefined;
        const caption = text_utils.wideToUtf8(caption_w, &caption_buf);
        const body = text_utils.wideToUtf8(text_w, &text_buf);
        renderer.showMessageBox(caption, body);
    }
    return 1; // IDOK
}

// -------------------------------------------------------------------------
// Dialog utility stubs (moved from misc.zig)
// -------------------------------------------------------------------------

/// Sends WM_COMMAND to a dialog's DlgProc (the per-hwnd WndProc registered by
/// CreateDialogParamA/DialogBoxParamA). wParam = control id (low word), like
/// the existing modal-command dispatch path. Falls back to the modal DlgProc
/// (DialogBoxParamA doesn't register a per-hwnd WndProc).
fn sendDialogCommand(hDlg: usize, ctrl_id: u32) void {
    const proc_addr = user32.getWndProc(hDlg) orelse modal_dlgproc;
    if (proc_addr == 0) return;
    var err_flag: u32 = 0;
    if (trace.enable_tracing) trace.print("USER32: IsDialogMessage -> WM_COMMAND({d}) to dialog {x}\n", .{ ctrl_id, hDlg });
    _ = user32.callWndProcSafe(proc_addr, hDlg, w32.WM_COMMAND, ctrl_id, 0, &err_flag);
}

const DLGKB_WS_TABSTOP: u32 = 0x00010000;
const DLGKB_WS_VISIBLE: u32 = 0x10000000;
const DLGKB_BS_DEFPUSHBUTTON: u32 = 0x00000001;
const DLGKB_IDCANCEL: u32 = 2;
const DLGKB_VK_TAB: u32 = 0x09;
const DLGKB_VK_RETURN: u32 = 0x0D;
const DLGKB_VK_ESCAPE: u32 = 0x1B;
const DLGKB_WM_KEYDOWN: u32 = 0x0100;
const DLGKB_WM_SYSKEYDOWN: u32 = 0x0104;

/// Collect the dialog's child controls (hwnd + style + id) from the window
/// table. Returns the number found.
fn dialogChildren(hDlg: usize, out_hwnds: []usize, out_styles: []u32) usize {
    var n: usize = 0;
    for (user32.window_info_table[0..user32.window_info_count]) |*entry| {
        if (entry.parent != hDlg) continue;
        if (n < out_hwnds.len) {
            out_hwnds[n] = entry.hwnd;
            out_styles[n] = @bitCast(entry.style);
            n += 1;
        }
    }
    return n;
}

/// Find the next (or previous, for Shift+Tab) control with WS_TABSTOP after
/// `from_hwnd`. If `from_hwnd` isn't a child, starts from the first tabstop
/// (forward) or the last one (backward). Returns the control hwnd, or
/// `from_hwnd` if none.
fn nextTabStop(hDlg: usize, from_hwnd: usize, backward: bool) usize {
    var hwnds: [64]usize = undefined;
    var styles: [64]u32 = undefined;
    const n = dialogChildren(hDlg, &hwnds, &styles);
    if (n == 0) return from_hwnd;

    var from_idx: ?usize = null;
    for (0..n) |i| {
        if (hwnds[i] == from_hwnd) {
            from_idx = i;
            break;
        }
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = if (backward)
            (from_idx orelse 0) +% n -% (i + 1)
        else
            ((from_idx orelse n -% 1) +% 1 +% i) % n;
        if ((styles[idx] & DLGKB_WS_TABSTOP) != 0 and (styles[idx] & DLGKB_WS_VISIBLE) != 0) {
            return hwnds[idx];
        }
    }
    return from_hwnd;
}

/// Find the default push button (BS_DEFPUSHBUTTON) among the dialog's children.
fn findDefaultButton(hDlg: usize) usize {
    var hwnds: [64]usize = undefined;
    var styles: [64]u32 = undefined;
    const n = dialogChildren(hDlg, &hwnds, &styles);
    for (0..n) |i| {
        if ((styles[i] & DLGKB_BS_DEFPUSHBUTTON) != 0) return hwnds[i];
    }
    return 0;
}

/// IsDialogMessageA: dialog-manager keyboard handling. Returns 1 if the
/// message was consumed (Tab moves focus, Enter activates the default button,
/// Escape activates IDCANCEL), 0 otherwise.
pub fn IsDialogMessageA(hDlg: usize, lpMsg: usize) callconv(w32cc.WINAPI) i32 {
    if (lpMsg == 0) return 0;

    // Read the 32-bit guest MSG directly (message at +4, wParam at +8).
    const msg_ptr = @as([*]const u8, @ptrFromInt(trace.addr(lpMsg)));
    const message = std.mem.readInt(u32, msg_ptr[4..8], .little);
    const wparam = std.mem.readInt(u32, msg_ptr[8..12], .little);

    if (message == DLGKB_WM_KEYDOWN or message == DLGKB_WM_SYSKEYDOWN) {
        const vk = wparam & 0xFF;
        switch (vk) {
            DLGKB_VK_TAB => {
                const shift = (renderer.keyboard_state[0x10] & 0x80) != 0; // VK_SHIFT
                const next = nextTabStop(hDlg, user32.focused_hwnd, shift);
                if (next != user32.focused_hwnd) {
                    _ = @import("window.zig").stub_SetFocus(next);
                }
                if (trace.enable_tracing) trace.print("USER32: IsDialogMessage Tab -> focus={x}\n", .{next});
                return 1;
            },
            DLGKB_VK_RETURN => {
                const def_btn = findDefaultButton(hDlg);
                if (def_btn != 0) {
                    const id = if (user32.getWindowInfo(def_btn)) |info| @as(u32, @intCast(info.id)) else 1;
                    sendDialogCommand(hDlg, id);
                }
                return 1;
            },
            DLGKB_VK_ESCAPE => {
                sendDialogCommand(hDlg, DLGKB_IDCANCEL);
                return 1;
            },
            else => {},
        }
    }

    // WM_CHAR: if the focused control is the edit control (which wants
    // characters), let the message flow (return 0). Buttons and other
    // controls consume stray chars (real dialog manager behavior).
    if (message == 0x0102) { // WM_CHAR
        if (user32.focused_hwnd == user32.edit_hwnd) return 0;
        return 1;
    }

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

pub fn stub_MessageBoxIndirectA(lpmbp: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpmbp;
    return 1; // IDOK
}

pub fn stub_WinHelpA(hWndMain: usize, lpszHelp: usize, uCommand: u32, dwData: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWndMain;
    _ = lpszHelp;
    _ = uCommand;
    _ = dwData;
    if (trace.enable_tracing) trace.print("USER32: WinHelpA\n", .{});
    return 1;
}
