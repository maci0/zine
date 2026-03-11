const std = @import("std");
const trace = @import("../../trace.zig");
const user32 = @import("../user32.zig");
const w32 = @import("../win32_constants.zig");

pub fn stub_PeekMessageA(lpMsg: usize, hWnd: usize, wMsgFilterMin: u32, wMsgFilterMax: u32, wRemoveMsg: u32) callconv(.winapi) i32 {
    _ = hWnd; _ = wMsgFilterMin; _ = wMsgFilterMax;

    user32.pending_command_mutex.lock();
    defer user32.pending_command_mutex.unlock();

    if (!user32.has_activated) {
        if (lpMsg != 0) {
            const msg = @as(*user32.MSG, @ptrFromInt(lpMsg));
            msg.hwnd = user32.global_hwnd;
            msg.message = w32.WM_ACTIVATE;
            msg.wParam = w32.WA_ACTIVE;
            msg.lParam = 0;
            msg.time = 0;
            msg.pt_x = 0;
            msg.pt_y = 0;
        }

        if ((wRemoveMsg & w32.PM_REMOVE) != 0) {
            if (trace.enable_tracing) trace.print("USER32: PeekMessageA -> Returning WM_ACTIVATE\n", .{});
            user32.has_activated = true;
        }
        return 1;
    }

    if (user32.pending_command) |cmd_id| {
        if (lpMsg != 0) {
            const msg = @as(*user32.MSG, @ptrFromInt(lpMsg));
            msg.hwnd = user32.global_hwnd;
            msg.message = w32.WM_COMMAND;
            msg.wParam = cmd_id;
            msg.lParam = 0;
            msg.time = 0;
            msg.pt_x = 0;
            msg.pt_y = 0;
        }

        if ((wRemoveMsg & w32.PM_REMOVE) != 0) {
            if (trace.enable_tracing) trace.print("USER32: PeekMessageA -> Returning WM_COMMAND({d})\n", .{cmd_id});
            user32.pending_command = null;
        }
        return 1;
    }

    if (user32.pending_messages_tail != user32.pending_messages_head) {
        if (lpMsg != 0) {
            const msg = @as(*user32.MSG, @ptrFromInt(lpMsg));
            msg.* = user32.pending_messages[user32.pending_messages_tail];
        }
        if ((wRemoveMsg & w32.PM_REMOVE) != 0) {
            user32.pending_messages_tail = (user32.pending_messages_tail + 1) % user32.pending_messages.len;
        }
        return 1;
    }

    return 0; // No messages
}

pub fn stub_TranslateMessage(lpMsg: usize) callconv(.winapi) i32 {
    _ = lpMsg;
    return 0;
}

pub fn stub_DispatchMessageA(lpMsg: usize) callconv(.winapi) isize {
    if (lpMsg != 0) {
        const msg = @as(*user32.MSG, @ptrFromInt(lpMsg));
        if (trace.enable_tracing) trace.print("USER32: DispatchMessageA(Msg={x}, wParam={x})\n", .{msg.message, msg.wParam});

        // Look up per-hwnd WndProc first (for dialogs), then fall back to global
        const wndproc_addr: usize = if (user32.getWndProc(msg.hwnd)) |proc_addr|
            proc_addr
        else if (user32.global_wndproc) |proc|
            @intFromPtr(proc)
        else
            0;

        if (wndproc_addr != 0) {
            var err_flag: u32 = 0;
            return user32.callWndProcSafe(wndproc_addr, msg.hwnd, msg.message, msg.wParam, msg.lParam, &err_flag);
        }
    }
    return 0;
}

pub fn stub_GetMessageA(lpMsg: usize, hWnd: usize, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.winapi) i32 {
    while (true) {
        const result = stub_PeekMessageA(lpMsg, hWnd, wMsgFilterMin, wMsgFilterMax, w32.PM_REMOVE);
        if (result != 0) return result;
        std.Thread.sleep(1 * 1000 * 1000); // 1ms
    }
}

pub fn stub_PostMessageA(hWnd: usize, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) i32 {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: PostMessageA(Msg={x})\n", .{Msg});
    if (Msg == w32.WM_QUIT) {
        if (trace.enable_tracing) trace.print("USER32: WM_QUIT posted, queuing quit message.\n", .{});
        // Queue WM_QUIT in the message queue instead of immediately exiting
        user32.pending_command_mutex.lock();
        defer user32.pending_command_mutex.unlock();
        const next_head = (user32.pending_messages_head + 1) % user32.pending_messages.len;
        if (next_head != user32.pending_messages_tail) {
            user32.pending_messages[user32.pending_messages_head] = .{
                .hwnd = user32.global_hwnd,
                .message = w32.WM_QUIT,
                .wParam = wParam,
                .lParam = lParam,
                .time = 0,
                .pt_x = 0,
                .pt_y = 0,
            };
            user32.pending_messages_head = next_head;
        }
        return 1;
    }
    return 1;
}

pub fn stub_PostQuitMessage(nExitCode: i32) callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("USER32: PostQuitMessage({d})\n", .{nExitCode});
    // Queue WM_QUIT in the message queue to allow cleanup
    user32.pending_command_mutex.lock();
    defer user32.pending_command_mutex.unlock();
    const next_head = (user32.pending_messages_head + 1) % user32.pending_messages.len;
    if (next_head != user32.pending_messages_tail) {
        user32.pending_messages[user32.pending_messages_head] = .{
            .hwnd = user32.global_hwnd,
            .message = w32.WM_QUIT,
            .wParam = @intCast(@as(u32, @bitCast(nExitCode))),
            .lParam = 0,
            .time = 0,
            .pt_x = 0,
            .pt_y = 0,
        };
        user32.pending_messages_head = next_head;
    }
}

pub fn stub_SendMessageA(hWnd: usize, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize {
    if (trace.enable_tracing) trace.print("USER32: SendMessageA(hwnd={x}, Msg={x}, wParam={x})\n", .{ hWnd, Msg, wParam });

    const renderer = @import("../../gui/renderer.zig");

    // WM_SETTEXT = 0x000C — update the text of a control
    if (Msg == 0x000C and lParam != 0) {
        const text = trace.c_span(@intCast(lParam));
        // Try to extract control ID from the synthetic child hwnd
        // GetDlgItem returns (hDlg << 8) ^ nIDDlgItem, so reverse it
        const DIALOG_HWND: usize = 0x00000456;
        const dialog_base = DIALOG_HWND << 8;
        if (hWnd >= dialog_base and hWnd < dialog_base + 0x10000) {
            const ctrl_id: i32 = @intCast(hWnd ^ dialog_base);
            renderer.updateControlText(ctrl_id, text);
        } else if (hWnd == user32.global_hwnd or hWnd == DIALOG_HWND) {
            // Main window title update
            renderer.setTitle(text);
        }
        return 1;
    }

    // Try per-hwnd WndProc first (for dialogs, child controls)
    if (user32.getWndProc(hWnd)) |proc_addr| {
        var err_flag: u32 = 0;
        return user32.callWndProcSafe(proc_addr, hWnd, Msg, wParam, lParam, &err_flag);
    }

    // Fall back to global WndProc only for the main window / dialog hwnd
    if (hWnd == user32.global_hwnd or hWnd == 0) {
        if (user32.global_wndproc) |wndproc| {
            var err_flag: u32 = 0;
            return user32.callWndProcSafe(@intFromPtr(wndproc), hWnd, Msg, wParam, lParam, &err_flag);
        }
    }

    // Common control messages — return sensible defaults
    return handleCommonControlMsg(Msg, wParam);
}

/// Handle common control messages (ListView, TabControl, StatusBar, etc.)
/// Returns sensible default values so apps don't loop or crash.
pub fn handleCommonControlMsg(Msg: u32, wParam: usize) isize {
    _ = wParam;

    // ListView messages: LVM_FIRST = 0x1000
    if (Msg >= 0x1000 and Msg < 0x1100) {
        return switch (Msg) {
            0x1004 => 0,   // LVM_GETITEMCOUNT: 0 items
            0x1005 => 0,   // LVM_GETITEMA: FALSE (not found)
            0x1006 => 1,   // LVM_SETITEMA: TRUE (success)
            0x1007 => 0,   // LVM_INSERTITEMA: index 0
            0x1008 => 1,   // LVM_DELETEITEM: TRUE
            0x1009 => 1,   // LVM_DELETEALLITEMS: TRUE
            0x101B => 0,   // LVM_INSERTCOLUMNA: column index 0
            0x101C => 0,   // LVM_DELETECOLUMN: FALSE (no columns to delete)
            0x101D => 60,  // LVM_GETCOLUMNWIDTH: 60 pixels
            0x102F => 1,   // LVM_SETITEMCOUNT: TRUE
            0x1036 => 0,   // LVM_GETSELECTEDCOUNT: 0
            0x103F => 0,   // LVM_GETEXTENDEDLISTVIEWSTYLE: 0
            0x1040 => 0,   // LVM_GETSUBITEMRECT: FALSE
            0x1041 => 0,   // LVM_SUBITEMHITTEST: -1 miss
            0x1042 => 0,   // LVM_SETCOLUMNORDERARRAY
            0x104B => 0,   // LVM_GETCOLUMNORDERARRAY
            0x104D => 0,   // LVM_SETEXTENDEDLISTVIEWSTYLE
            0x104E => 0,   // LVM_GETEXTENDEDLISTVIEWSTYLE (alias)
            0x1061 => 0,   // LVM_INSERTCOLUMNW
            0x1019 => 0,   // LVM_GETCOLUMNA: FALSE (prevents infinite loop deleting columns)
            0x105F => 0,   // LVM_GETCOLUMNW: FALSE
            0x1013 => 1,   // LVM_ENSUREVISIBLE: TRUE
            0x1015 => 1,   // LVM_REDRAWITEMS: TRUE
            else => 0,
        };
    }

    // TabControl messages: TCM_FIRST = 0x1300
    if (Msg >= 0x1300 and Msg < 0x1400) {
        return switch (Msg) {
            0x1304 => 0,   // TCM_GETITEMCOUNT: 0 items
            0x1307 => 0,   // TCM_INSERTITEMA: index 0
            0x133E => 0,   // TCM_INSERTITEMW: index 0
            0x130B => -1,  // TCM_GETCURSEL: -1 (no selection)
            0x130C => -1,  // TCM_SETCURSEL: -1
            else => 0,
        };
    }

    // StatusBar messages: SB_* use WM_USER range 0x0400+
    if (Msg >= 0x0400 and Msg < 0x0500) {
        return switch (Msg) {
            0x0404 => 1,   // SB_SETPARTS: TRUE
            0x0401 => 1,   // SB_SETTEXTA: TRUE
            0x0409 => 0,   // SB_GETPARTS: 0 parts
            0x040B => 1,   // SB_SETTEXTW: TRUE
            0x040D => 0,   // SB_GETTEXTLENGTHW: 0
            else => 0,
        };
    }

    // Header control: HDM_FIRST = 0x1200
    if (Msg >= 0x1200 and Msg < 0x1300) {
        return switch (Msg) {
            0x1200 => 0,   // HDM_GETITEMCOUNT: 0 items
            else => 0,
        };
    }

    return 0;
}
