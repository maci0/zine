const std = @import("std");
const trace = @import("../../trace.zig");
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
    const text = if (lpText != 0) trace.c_span(lpText) else "(null)";
    const caption = if (lpCaption != 0) trace.c_span(lpCaption) else "(null)";

    if (trace.enable_tracing) trace.print("USER32: MessageBoxA(caption='{s}', text='{s}')\n", .{caption, text});

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

            if (dlgproc != 0) {
                var err_flag: u32 = 0;
                _ = user32.callWndProcSafe(dlgproc, DIALOG_HWND, msg.message, msg.wParam, msg.lParam, &err_flag);
            }
        }

        if (!got_message) {
            // Sleep briefly to avoid busy-waiting
            std.Thread.sleep(1 * std.time.ns_per_ms);
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

pub fn SetDlgItemTextA(hDlg: usize, nIDDlgItem: i32, lpString: usize) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    const text = if (lpString != 0) trace.c_span(lpString) else "";
    if (trace.enable_tracing) {
        trace.print("USER32: SetDlgItemTextA(id={d}, text='{s}')\n", .{ nIDDlgItem, text });
    }
    renderer.updateControlText(nIDDlgItem, text);
    return 1;
}

pub fn stub_GetDlgItemTextA(hDlg: usize, nIDDlgItem: i32, lpString: usize, cchMax: i32) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    _ = nIDDlgItem;
    if (lpString != 0 and cchMax > 0) {
        @as([*]u8, @ptrFromInt(lpString))[0] = 0;
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

pub fn stub_GetDlgItemInt(hDlg: usize, nIDDlgItem: i32, lpTranslated: usize, bSigned: i32) callconv(w32cc.WINAPI) u32 {
    _ = hDlg;
    _ = nIDDlgItem;
    _ = bSigned;
    if (lpTranslated != 0) {
        @as(*i32, @ptrFromInt(lpTranslated)).* = 0; // FALSE = translation failed
    }
    return 0;
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

    return dialog_hwnd;
}

pub fn stub_SetDlgItemInt(hDlg: usize, nIDDlgItem: i32, uValue: u32, bSigned: i32) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    _ = bSigned;
    if (trace.enable_tracing) trace.print("USER32: SetDlgItemInt(id={d}, val={d})\n", .{ nIDDlgItem, uValue });
    return 1;
}

pub fn MessageBoxW(hWnd: usize, lpText: usize, lpCaption: usize, uType: u32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = uType;
    if (trace.enable_tracing) trace.print("USER32: MessageBoxW\n", .{});
    // Convert wide strings for display
    if (lpCaption != 0 and lpText != 0) {
        const caption_w = trace.c_span_w(lpCaption);
        const text_w = trace.c_span_w(lpText);
        var caption_buf: [256]u8 = undefined;
        var text_buf: [1024]u8 = undefined;
        const cap_len = @min(caption_w.len, caption_buf.len);
        const txt_len = @min(text_w.len, text_buf.len);
        for (0..cap_len) |i| caption_buf[i] = @truncate(caption_w[i]);
        for (0..txt_len) |i| text_buf[i] = @truncate(text_w[i]);
        renderer.showMessageBox(caption_buf[0..cap_len], text_buf[0..txt_len]);
    }
    return 1; // IDOK
}

// -------------------------------------------------------------------------
// Dialog utility stubs (moved from misc.zig)
// -------------------------------------------------------------------------

pub fn stub_IsDialogMessageA(hDlg: usize, lpMsg: usize) callconv(w32cc.WINAPI) i32 {
    _ = hDlg;
    _ = lpMsg;
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
