const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const ansi = @import("../ansi.zig");
const text_utils = @import("../../text_utils.zig");
const user32 = @import("../user32.zig");
const w32 = @import("../constants.zig");
const civil_time = @import("../civil_time.zig");
const w32cc = @import("../calling_convention.zig");
const kernel32_time = @import("../kernel32/time.zig");

pub fn PeekMessageA(lpMsg: *user32.MSG, hWnd: usize, wMsgFilterMin: u32, wMsgFilterMax: u32, wRemoveMsg: u32) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = wMsgFilterMin;
    _ = wMsgFilterMax;

    // Scope the mutex to just the message queue checks
    {
        user32.pending_command_mutex.lock();
        defer user32.pending_command_mutex.unlock();

        if (!user32.has_activated) {
            {
                const msg = lpMsg;
                msg.hwnd = @intCast(user32.global_hwnd);
                msg.message = w32.WM_ACTIVATE;
                msg.wParam = w32.WA_ACTIVE;
                msg.lParam = 0;
                msg.time = user32.msgTime();
                msg.pt_x = 0;
                msg.pt_y = 0;
            }

            if ((wRemoveMsg & w32.PM_REMOVE) != 0) {
                if (trace.enable_tracing) trace.print("USER32: PeekMessageA -> Returning WM_ACTIVATE\n", .{});
                user32.has_activated = true;
            }
            return 1;
        }

        // WM_ACTIVATEAPP tells the app it's now the foreground application.
        // Many fullscreen games (esp. DirectX) skip rendering without this.
        const AA = struct {
            var sent: bool = false;
        };
        if (!AA.sent) {
            {
                const msg = lpMsg;
                msg.hwnd = @intCast(user32.global_hwnd);
                msg.message = w32.WM_ACTIVATEAPP;
                msg.wParam = 1; // TRUE = app is being activated
                msg.lParam = 0;
                msg.time = user32.msgTime();
                msg.pt_x = 0;
                msg.pt_y = 0;
            }
            if ((wRemoveMsg & w32.PM_REMOVE) != 0) {
                if (trace.enable_tracing) trace.print("USER32: PeekMessageA -> Returning WM_ACTIVATEAPP\n", .{});
                AA.sent = true;
            }
            return 1;
        }

        if (user32.pending_command) |cmd_id| {
            {
                const msg = lpMsg;
                msg.hwnd = @intCast(user32.global_hwnd);
                msg.message = w32.WM_COMMAND;
                msg.wParam = cmd_id;
                msg.lParam = 0;
                msg.time = user32.msgTime();
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
            {
                const msg = lpMsg;
                msg.* = user32.pending_messages[user32.pending_messages_tail];
            }
            if ((wRemoveMsg & w32.PM_REMOVE) != 0) {
                user32.pending_messages_tail = (user32.pending_messages_tail + 1) % user32.pending_messages.len;
            }
            return 1;
        }

        if (user32.needs_paint) {
            if ((wRemoveMsg & w32.PM_REMOVE) != 0) {
                if (trace.enable_tracing) trace.print("USER32: PeekMessageA -> Dispatching WM_PAINT to all windows\n", .{});
                user32.needs_paint = false;

                // Dispatch WM_PAINT to child windows (they inherit the class WndProc)
                if (user32.global_wndproc) |wndproc| {
                    const proc = @intFromPtr(wndproc);
                    for (user32.window_info_table[0..user32.window_info_count]) |*info| {
                        if (info.hwnd != 0 and info.hwnd != user32.global_hwnd) {
                            // Use per-window WndProc if set, else class WndProc
                            const wp = if (info.proc != 0) info.proc else proc;
                            if (trace.enable_tracing) trace.print("USER32: WM_PAINT dispatch child hwnd={x} proc={x}\n", .{ info.hwnd, wp });
                            var err: u32 = 0;
                            _ = user32.callWndProcSafe(wp, info.hwnd, w32.WM_PAINT, 0, 0, &err);
                            if (trace.enable_tracing and err != 0) trace.print("USER32: WM_PAINT dispatch child hwnd={x} FAILED (err={d})\n", .{ info.hwnd, err });
                        }
                    }
                }
            }
            // Return WM_PAINT for the main form
            {
                const msg = lpMsg;
                msg.hwnd = @intCast(user32.global_hwnd);
                msg.message = w32.WM_PAINT;
                msg.wParam = 0;
                msg.lParam = 0;
                msg.time = user32.msgTime();
                msg.pt_x = 0;
                msg.pt_y = 0;
            }
            return 1;
        }
    } // mutex released here

    // Check for expired SetTimer-based timers — WM_TIMER has lowest priority (after WM_PAINT)
    const input = @import("../user32/input.zig");
    // Must pair with input.safeMilliTs(): same (monotonic) clock on both
    // sides of the elapsed-time comparison, or a wall-clock step would make
    // timers fire never or continuously.
    const now = runtime.monoMilliTimestamp();
    for (&input.timers) |*t| {
        if (t.active) {
            const elapsed = now - t.last_fire;
            if (elapsed >= @as(i64, t.elapse_ms)) {
                {
                    const msg = lpMsg;
                    msg.hwnd = @intCast(t.hwnd);
                    msg.message = w32.WM_TIMER;
                    msg.wParam = @intCast(t.id);
                    msg.lParam = 0;
                    msg.time = user32.msgTime();
                    msg.pt_x = 0;
                    msg.pt_y = 0;
                }
                if ((wRemoveMsg & w32.PM_REMOVE) != 0) {
                    t.last_fire = now;
                }
                return 1;
            }
        }
    }

    // Multimedia timer callbacks fire directly from the timer thread
    // (with FS base save/restore for TEB access), so no dispatch here.

    // No messages — flush any pending screen updates
    const rend = @import("../../gui/renderer.zig");
    rend.flushScreenIfDirty();

    // Disable AV suppression once the message loop is idle (init complete)
    const k32_err = @import("../kernel32/error.zig");
    if (k32_err.suppress_access_violations) {
        k32_err.suppress_access_violations = false;
        // Trigger a repaint now that initialization is complete
        user32.needs_paint = true;
    }

    return 0; // No messages
}

/// Posts a message to the queue targeting a specific hwnd.
pub fn postMessageTo(hwnd: usize, msg_id: u32, wParam: usize, lParam: isize) void {
    user32.pending_command_mutex.lock();
    defer user32.pending_command_mutex.unlock();
    const next_head = (user32.pending_messages_head + 1) % user32.pending_messages.len;
    if (next_head != user32.pending_messages_tail) {
        user32.pending_messages[user32.pending_messages_head] = .{
            .hwnd = @intCast(hwnd),
            .message = msg_id,
            .wParam = @intCast(wParam),
            .lParam = @intCast(lParam),
            .time = user32.msgTime(),
            .pt_x = 0,
            .pt_y = 0,
        };
        user32.pending_messages_head = next_head;
    }
}

/// TranslateMessage: converts WM_KEYDOWN/WM_SYSKEYDOWN into WM_CHAR/
/// WM_SYSCHAR using the current keyboard state (US layout).
pub fn TranslateMessage(lpMsg: ?*user32.MSG) callconv(w32cc.WINAPI) i32 {
    const msg = lpMsg orelse return 0;
    if (msg.message == w32.WM_KEYDOWN or msg.message == w32.WM_SYSKEYDOWN) {
        if (charFromVk(@intCast(msg.wParam & 0xFF))) |ch| {
            const char_msg = if (msg.message == w32.WM_SYSKEYDOWN) w32.WM_SYSCHAR else w32.WM_CHAR;
            postMessageTo(@as(usize, msg.hwnd), char_msg, ch, @as(isize, @intCast(msg.lParam)));
            return 1;
        }
    }
    return 0;
}

/// Map a virtual key code to the character it produces (US layout), honoring
/// the Shift state tracked in renderer.keyboard_state.
fn charFromVk(vk: u8) ?usize {
    const renderer = @import("../../gui/renderer.zig");
    // The FLTK thread updates the shift byte from its own event callback, so
    // the read takes the lock the table's contract names.
    renderer.input_mutex.lock();
    const shift = (renderer.keyboard_state[0x10] & 0x80) != 0; // VK_SHIFT
    renderer.input_mutex.unlock();

    if (vk >= 0x30 and vk <= 0x39) {
        // Digits: unshifted '0'-'9', shifted ")!@#$%^&*("
        const shifted = ")!@#$%^&*(";
        return if (shift) shifted[vk - 0x30] else vk;
    }
    if (vk >= 0x41 and vk <= 0x5A) {
        // A-Z: unshifted lowercase, shifted uppercase
        return if (shift) vk else vk + 32;
    }
    if (vk == 0x20) return ' ';
    const oem_pairs = [_]struct { vk: u8, plain: u8, shifted: u8 }{
        .{ .vk = 0xBA, .plain = ';', .shifted = ':' },
        .{ .vk = 0xBB, .plain = '=', .shifted = '+' },
        .{ .vk = 0xBC, .plain = ',', .shifted = '<' },
        .{ .vk = 0xBD, .plain = '-', .shifted = '_' },
        .{ .vk = 0xBE, .plain = '.', .shifted = '>' },
        .{ .vk = 0xBF, .plain = '/', .shifted = '?' },
        .{ .vk = 0xC0, .plain = '`', .shifted = '~' },
        .{ .vk = 0xDB, .plain = '[', .shifted = '{' },
        .{ .vk = 0xDC, .plain = '\\', .shifted = '|' },
        .{ .vk = 0xDD, .plain = ']', .shifted = '}' },
        .{ .vk = 0xDE, .plain = '\'', .shifted = '"' },
    };
    for (oem_pairs) |p| {
        if (p.vk == vk) return if (shift) p.shifted else p.plain;
    }
    return null;
}

pub fn DispatchMessageA(lpMsg: *user32.MSG) callconv(w32cc.WINAPI) isize {
    {
        const msg = lpMsg;
        if (trace.enable_tracing) trace.print("USER32: DispatchMessageA(hwnd={x} Msg={x}, wParam={x}) edit_hwnd={x}\n", .{ msg.hwnd, msg.message, msg.wParam, user32.edit_hwnd });

        // Delphi CM_ACTIVATE (0xB000): skip if the main form doesn't exist yet.
        // Dispatching CM_ACTIVATE before Application.CreateForm completes
        // causes a nil reference crash in the WndProc that prevents form creation.
        if (msg.message == 0xB000 and !user32.main_form_created) {
            return 0;
        }

        // EDIT/RichEdit class: WM_CHAR posted directly to the control hwnd
        // (e.g. PostMessageA(edit, WM_CHAR, ...)). Handled before any
        // WndProc dispatch, mirroring the real edit class wndproc.
        if ((@as(usize, msg.hwnd) == user32.edit_hwnd or @as(usize, msg.hwnd) == user32.rich_edit_hwnd) and msg.message == 0x0102) {
            const renderer = @import("../../gui/renderer.zig");
            renderer.editInsertChar(ansi.byteToCodepoint(@intCast(msg.wParam & 0xFF)));
            return 1;
        }

        // BUTTON class: VK_SPACE / VK_RETURN on a focused button activates it
        // (sends WM_COMMAND(BN_CLICKED) to the parent), like the real button
        // class wndproc.
        if (msg.message == 0x0100 or msg.message == 0x0104) { // WM_KEYDOWN / WM_SYSKEYDOWN
            const hwnd = @as(usize, msg.hwnd);
            const vk = msg.wParam & 0xFF;
            if ((vk == 0x20 or vk == 0x0D) and hwnd != user32.edit_hwnd) {
                if (controlClassOf(hwnd)) |cls| {
                    if (std.ascii.eqlIgnoreCase(cls, "Button")) {
                        if (user32.getWindowInfo(hwnd)) |info| {
                            const parent = info.parent;
                            const ctrl_id: u32 = @intCast(info.id);
                            const parent_proc = user32.getWndProc(parent) orelse
                                (if (user32.global_wndproc) |p| @intFromPtr(p) else 0);
                            if (trace.enable_tracing) trace.print("USER32: Button hwnd={x} activated via key {x} -> WM_COMMAND({d}) to parent {x}\n", .{ hwnd, vk, ctrl_id, parent });
                            if (parent_proc != 0) {
                                var err_flag: u32 = 0;
                                _ = user32.callWndProcSafe(parent_proc, parent, w32.WM_COMMAND, ctrl_id, @as(isize, @bitCast(hwnd)), &err_flag);
                            }
                            return 1;
                        }
                    }
                }
            }
        }

        // Look up per-hwnd WndProc first (for dialogs), then fall back to global
        const wndproc_addr: usize = if (user32.getWndProc(msg.hwnd)) |proc_addr|
            proc_addr
        else if (user32.global_wndproc) |proc|
            @intFromPtr(proc)
        else
            0;

        if (wndproc_addr != 0) {
            var err_flag: u32 = 0;
            return user32.callWndProcSafe(wndproc_addr, @as(usize, msg.hwnd), msg.message, msg.wParam, @as(isize, @intCast(@as(i32, @bitCast(msg.lParam)))), &err_flag);
        }
    }
    return 0;
}

/// How long GetMessageA waits between empty queue polls. Charged to the
/// virtual clock under simulation, so the loop's cost is simulated time.
const idle_poll_ns: u64 = std.time.ns_per_ms;
/// Idle time after which an empty GetMessageA returns a synthetic WM_PAINT.
const paint_interval_ns: u64 = 16 * idle_poll_ns;

pub fn GetMessageA(lpMsg: *user32.MSG, hWnd: usize, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: GetMessageA called\n", .{});
    var waited_ns: u64 = 0;
    while (true) {
        const result = PeekMessageA(lpMsg, hWnd, wMsgFilterMin, wMsgFilterMax, w32.PM_REMOVE);
        if (result != 0) {
            // GetMessage returns 0 when it retrieves WM_QUIT — this is how the
            // app's `while (GetMessage(...) > 0)` loop terminates. Without it,
            // WM_QUIT was dispatched like any other message and the loop spun
            // forever on synthesized WM_PAINT messages.
            if (lpMsg.message == w32.WM_QUIT) {
                if (trace.enable_tracing) trace.print("USER32: GetMessageA -> WM_QUIT, returning 0\n", .{});
                return 0;
            }
            if (trace.enable_tracing) {
                const msg = lpMsg;
                trace.print("USER32: GetMessageA returning msg={x}\n", .{msg.message});
            }
            return result;
        }

        // After an idle period of paint_interval_ns, generate a synthetic
        // WM_PAINT to keep the game's main message loop alive. Many games
        // expect GetMessage to return periodically even when no real messages
        // are pending. The wait is charged to the virtual clock when one is
        // installed, so a replay reaches the synthetic paint after the same
        // guest time and not after the same number of host iterations.
        if (waited_ns >= paint_interval_ns) {
            waited_ns = 0;
            {
                const msg = lpMsg;
                msg.hwnd = @intCast(user32.global_hwnd);
                msg.message = w32.WM_PAINT;
                msg.wParam = 0;
                msg.lParam = 0;
                msg.time = user32.msgTime();
                msg.pt_x = 0;
                msg.pt_y = 0;
            }
            return 1;
        }

        // Flush any pending screen updates while idle
        const rend = @import("../../gui/renderer.zig");
        rend.flushScreenIfDirty();
        runtime.pauseOrAdvance(idle_poll_ns);
        waited_ns += idle_poll_ns;
    }
}

pub fn PostMessageA(hWnd: usize, Msg: u32, wParam: usize, lParam: isize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("USER32: PostMessageA(hwnd={x}, Msg={x})\n", .{ hWnd, Msg });

    // Queue the message in the pending messages ring buffer
    user32.pending_command_mutex.lock();
    defer user32.pending_command_mutex.unlock();
    const next_head = (user32.pending_messages_head + 1) % user32.pending_messages.len;
    if (next_head != user32.pending_messages_tail) {
        user32.pending_messages[user32.pending_messages_head] = .{
            .hwnd = @intCast(if (hWnd == 0) user32.global_hwnd else hWnd),
            .message = Msg,
            .wParam = @intCast(wParam),
            .lParam = @truncate(@as(u64, @bitCast(@as(i64, @intCast(lParam))))),
            .time = user32.msgTime(),
            .pt_x = 0,
            .pt_y = 0,
        };
        user32.pending_messages_head = next_head;
    }
    return 1;
}

pub fn PostQuitMessage(nExitCode: i32) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("USER32: PostQuitMessage({d})\n", .{nExitCode});
    // Queue WM_QUIT in the message queue to allow cleanup
    user32.pending_command_mutex.lock();
    defer user32.pending_command_mutex.unlock();
    const next_head = (user32.pending_messages_head + 1) % user32.pending_messages.len;
    if (next_head != user32.pending_messages_tail) {
        user32.pending_messages[user32.pending_messages_head] = .{
            .hwnd = @intCast(user32.global_hwnd),
            .message = w32.WM_QUIT,
            .wParam = @intCast(@as(u32, @bitCast(nExitCode))),
            .lParam = 0,
            .time = user32.msgTime(),
            .pt_x = 0,
            .pt_y = 0,
        };
        user32.pending_messages_head = next_head;
    }
}

pub fn SendMessageA(hWnd: usize, Msg: u32, wParam: usize, lParam: isize) callconv(w32cc.WINAPI) isize {
    if (trace.enable_tracing) trace.print("USER32: SendMessageA(hwnd={x}, Msg={x}, wParam={x})\n", .{ hWnd, Msg, wParam });

    const renderer = @import("../../gui/renderer.zig");

    // WM_SETTEXT = 0x000C — update the text of a control
    if (Msg == 0x000C and lParam != 0) {
        // EDIT/RichEdit controls take the text into their buffer.
        if (hWnd == user32.edit_hwnd or hWnd == user32.rich_edit_hwnd) {
            if (handleEditMsg(Msg, wParam, lParam)) |r| return r;
        }
        // WM_SETTEXT hands over CP1252 ANSI bytes; the stores and the renderer
        // take UTF-8.
        var text_buf: [1024]u8 = undefined;
        const text = ansi.toUtf8(trace.c_span(@as(usize, @bitCast(lParam))), &text_buf);
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
        } else {
            // Other child controls: store per-hwnd so WM_GETTEXT /
            // GetWindowText read it back.
            user32.setHwndText(hWnd, text);
        }
        return 1;
    }

    // WM_GETTEXT = 0x000D for non-edit controls: uniform control text
    // read-back (dialog children, ListBox/ComboBox selection, per-hwnd text).
    if (Msg == 0x000D and lParam != 0 and wParam > 0) {
        if (hWnd != user32.edit_hwnd and hWnd != user32.rich_edit_hwnd) {
            const text = getControlText(hWnd);
            if (text.len > 0) {
                return user32.copyAnsiToGuest(text, @as(usize, @bitCast(lParam)), @intCast(wParam));
            }
            return 0;
        }
    }

    // EDIT / RichEdit control class behavior (built-in, like the real edit
    // wndproc). RichEdit is an EDIT superset — same text machinery, plus the
    // RichEdit 2.0 EM_* messages (WM_USER + n, per the MSVC6 richedit.h).
    if (hWnd == user32.edit_hwnd or hWnd == user32.rich_edit_hwnd) {
        if (handleEditMsg(Msg, wParam, lParam)) |r| return r;
    }

    // BUTTON class: checkbox/radio state (BM_*) and simulated clicks.
    if (controlClassOf(hWnd)) |cls| {
        if (std.ascii.eqlIgnoreCase(cls, "Button")) {
            const bs = buttonStateOf(hWnd) orelse (buttonStateAlloc(hWnd) orelse return 0);
            switch (Msg) {
                0x00F0 => return @intCast(bs.checked), // BM_GETCHECK
                0x00F1 => { // BM_SETCHECK
                    bs.checked = if (wParam != 0) 1 else 0;
                    bs.state = (bs.state & ~@as(u32, 3)) | (bs.checked & 3);
                    const id = controlIdOf(hWnd);
                    renderer.updateControlChecked(id, bs.checked != 0);
                    return 1;
                },
                0x00F2 => return @intCast(bs.state), // BM_GETSTATE
                0x00F3 => { // BM_SETSTATE (BST_PUSHED = 4)
                    bs.state = (bs.state & ~@as(u32, 4)) | (if (wParam != 0) @as(u32, 4) else 0);
                    return 1;
                },
                0x00F5 => { // BM_CLICK: toggle auto checkboxes/radios, notify parent
                    if (applyAutoButtonClick(bs, hWnd)) {
                        renderer.updateControlChecked(controlIdOf(hWnd), bs.checked != 0);
                    }
                    notifyButtonParent(hWnd, controlIdOf(hWnd));
                    return 1;
                },
                else => {},
            }
        }
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

    // ListBox messages (LB_*)
    if (handleListBoxMsg(hWnd, Msg, wParam, lParam)) |lb_result| {
        return lb_result;
    }

    // Common control messages — return sensible defaults
    return handleCommonControlMsg(hWnd, Msg, wParam, lParam);
}

/// Shared EDIT / RichEdit wndproc. RichEdit is an EDIT superset: the classic
/// EM_* (0x00B0+) work identically, plus the RichEdit 2.0 messages at
/// WM_USER + n (per the MSVC6 richedit.h). The text itself lives in the
/// renderer's shared edit buffer, synced to the frontend textarea.
fn handleEditMsg(Msg: u32, wParam: usize, lParam: isize) ?isize {
    const renderer = @import("../../gui/renderer.zig");
    const text_len: i32 = @intCast(renderer.editTextLen());
    const WM_USER: u32 = 0x0400;

    switch (Msg) {
        0x0102 => { // WM_CHAR: insert character at the caret
            renderer.editInsertChar(ansi.byteToCodepoint(@intCast(wParam & 0xFF)));
            const new_len: i32 = @intCast(renderer.editTextLen());
            user32.edit_sel_start = new_len;
            user32.edit_sel_end = new_len;
            return 1;
        },
        0x000C => { // WM_SETTEXT
            var buf: [1024]u8 = undefined;
            const str = if (lParam != 0) ansi.toUtf8(trace.c_span(@as(usize, @bitCast(lParam))), &buf) else "";
            renderer.setEditTextFromSlice(str);
            renderer.setEditText(str);
            return 1;
        },
        0x000D => { // WM_GETTEXT
            return user32.copyAnsiToGuest(renderer.editTextSlice(), @as(usize, @bitCast(lParam)), @intCast(wParam));
        },
        0x000E => return user32.ansiLen(renderer.editTextSlice()), // WM_GETTEXTLENGTH
        0x00B0 => { // EM_GETSEL: write (start, end) — wParam=start*, lParam=end*
            if (wParam != 0) {
                @as(*align(1) u32, @ptrFromInt(trace.addr(wParam))).* =
                    @bitCast(@as(u32, @intCast(user32.edit_sel_start)));
            }
            if (lParam != 0) {
                @as(*align(1) u32, @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))))).* =
                    @bitCast(@as(u32, @intCast(user32.edit_sel_end)));
            }
            return 0;
        },
        0x00B1 => { // EM_SETSEL: wParam=start, lParam=end (-1 = end of text)
            editSetSel(editClampSel(@as(i32, @bitCast(@as(u32, @intCast(wParam)))), text_len), editClampSel(@as(i32, @bitCast(@as(u32, @intCast(lParam)))), text_len));
            return 1;
        },
        0x00C2 => { // EM_REPLACESEL: replace [sel_start, sel_end) with lParam string
            const str = if (lParam != 0) trace.c_span(@as(usize, @bitCast(lParam))) else "";
            const s = @max(user32.edit_sel_start, 0);
            const e = @min(@max(user32.edit_sel_end, s), text_len);
            const text = renderer.editTextSlice();
            var buf: [16384]u8 = undefined;
            const head_len = @min(@as(usize, @intCast(s)), text.len);
            const tail_len = if (e <= @as(i32, @intCast(text.len))) text.len - @as(usize, @intCast(e)) else 0;
            const total = head_len + str.len + tail_len;
            if (total < buf.len) {
                @memcpy(buf[0..head_len], text[0..head_len]);
                @memcpy(buf[head_len .. head_len + str.len], str);
                @memcpy(buf[head_len + str.len .. total], text[text.len - tail_len ..]);
                renderer.setEditTextFromSlice(buf[0..total]);
            }
            renderer.replaceEditSelection(str);
            const new_sel: i32 = @intCast(s + @as(i32, @intCast(str.len)));
            user32.edit_sel_start = new_sel;
            user32.edit_sel_end = new_sel;
            return 1;
        },
        0x00C5 => return 1, // EM_LIMITTEXT: accepted (limit not enforced)
        0x00C6 => return 0, // EM_CANUNDO
        0x00CF => return 1, // EM_SETREADONLY: accepted
        0x00D5 => return 0x7FFFFFFE, // EM_GETLIMITTEXT
        0x0301 => { // WM_COPY: selection → clipboard (CF_TEXT)
            const s = @max(user32.edit_sel_start, 0);
            const e = @min(@max(user32.edit_sel_end, s), text_len);
            if (e > s) {
                const text = renderer.editTextSlice();
                renderer.setClipboard(text[@intCast(s)..@intCast(e)]);
            }
            return 1;
        },
        WM_USER + 52 => { // EM_EXGETSEL: lParam = CHARRANGE* {cpMin, cpMax}
            if (lParam != 0) {
                const cr: [*]u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                @as(*align(1) i32, @ptrCast(cr + 0)).* = user32.edit_sel_start;
                @as(*align(1) i32, @ptrCast(cr + 4)).* = user32.edit_sel_end;
            }
            return 0;
        },
        WM_USER + 55 => { // EM_EXSETSEL: lParam = CHARRANGE*
            if (lParam != 0) {
                const cr: [*]const u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                const cp_min = @as(*align(1) const i32, @ptrCast(cr + 0)).*;
                const cp_max = @as(*align(1) const i32, @ptrCast(cr + 4)).*;
                const start = editClampSel(cp_min, text_len);
                const end = editClampSel(cp_max, text_len);
                editSetSel(start, end);
                return start;
            }
            return 0;
        },
        WM_USER + 58 => { // EM_GETCHARFORMAT: fill CHARFORMAT at lParam
            if (lParam != 0) {
                const cf: [*]u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                @as(*align(1) u32, @ptrCast(cf + 0)).* = 58; // cbSize
                // dwMask: CFM_FACE|CFM_SIZE|CFM_COLOR|CFM_BOLD|CFM_ITALIC
                @as(*align(1) u32, @ptrCast(cf + 4)).* = 0xE0000003;
                @as(*align(1) u32, @ptrCast(cf + 8)).* = 0; // dwEffects
                @as(*align(1) i32, @ptrCast(cf + 12)).* = 200; // yHeight (10pt * 20)
                @as(*align(1) i32, @ptrCast(cf + 16)).* = 0; // yOffset
                @as(*align(1) u32, @ptrCast(cf + 20)).* = 0; // crTextColor (black)
                @as(*align(1) u8, @ptrCast(cf + 24)).* = 0; // bCharSet (ANSI)
                @as(*align(1) u8, @ptrCast(cf + 25)).* = 0x31; // bPitchAndFamily (FF_SWISS | VARIABLE_PITCH)
                const face = cf + 26;
                @memcpy(face[0.."MS Sans Serif".len], "MS Sans Serif");
                face["MS Sans Serif".len] = 0;
            }
            return 1;
        },
        WM_USER + 62 => { // EM_GETSELTEXT: copy selected text to lParam
            const s = @max(user32.edit_sel_start, 0);
            const e = @min(@max(user32.edit_sel_end, s), text_len);
            if (lParam != 0 and e > s) {
                const text = renderer.editTextSlice();
                const dst: [*]u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                const n = @as(usize, @intCast(e - s));
                @memcpy(dst[0..n], text[@intCast(s)..][0..n]);
                dst[n] = 0;
                return @intCast(n);
            }
            return 0;
        },
        WM_USER + 67 => return 1, // EM_SETBKGNDCOLOR: accepted
        WM_USER + 68 => return 1, // EM_SETCHARFORMAT: accepted
        WM_USER + 75 => { // EM_GETTEXTRANGE: lParam = TEXTRANGEA* {CHARRANGE chrg; LPSTR lpstrText}
            if (lParam != 0) {
                const tr: [*]const u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                const cp_min = @as(*align(1) const i32, @ptrCast(tr + 0)).*;
                const cp_max = @as(*align(1) const i32, @ptrCast(tr + 4)).*;
                const dst_ptr = @as(*align(1) const u32, @ptrCast(tr + 8)).*;
                const s = @max(cp_min, 0);
                const e = @min(@max(cp_max, s), text_len);
                if (dst_ptr != 0 and e > s) {
                    const text = renderer.editTextSlice();
                    const dst: [*]u8 = @ptrFromInt(trace.addr(dst_ptr));
                    const n = @as(usize, @intCast(e - s));
                    @memcpy(dst[0..n], text[@intCast(s)..][0..n]);
                    dst[n] = 0;
                    return @intCast(n);
                }
                return 0;
            }
            return 0;
        },
        WM_USER + 89 => return 1, // EM_SETTEXTMODE: accepted
        WM_USER + 90 => return 1, // EM_GETTEXTMODE: TM_PLAINTEXT
        WM_USER + 94 => { // EM_GETTEXTEX: wParam=buffer, lParam=GETTEXTEX* {cb, flags, codepage, ...}
            if (wParam != 0 and lParam != 0) {
                const gt: [*]const u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                const cb = @as(*align(1) const u32, @ptrCast(gt + 0)).*;
                const text = renderer.editTextSlice();
                const n = @min(text.len, @as(usize, cb) -% 1);
                const dst: [*]u8 = @ptrFromInt(trace.addr(wParam));
                @memcpy(dst[0..n], text[0..n]);
                dst[n] = 0;
                return @intCast(n);
            }
            return 0;
        },
        WM_USER + 95 => { // EM_GETTEXTLENGTHEX: lParam = GETTEXTLENGTHEX* {flags, codepage}
            if (lParam != 0) {
                const gl: [*]const u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                const flags = @as(*align(1) const u32, @ptrCast(gl + 0)).*;
                // GTL_NUMCHARS (8) / GTL_NUMBYTES (16): plain count; otherwise
                // includes the NUL terminator (like WM_GETTEXTLENGTH).
                if ((flags & 0x18) != 0) return @intCast(renderer.editTextLen());
                return @intCast(renderer.editTextLen() + 1);
            }
            return @intCast(renderer.editTextLen() + 1);
        },
        else => return null,
    }
}

/// Clamp an EM_SETSEL position: -1 (or huge) means end of text.
fn editClampSel(pos: i32, text_len: i32) i32 {
    if (pos < 0) return text_len;
    return @min(pos, text_len);
}

/// Apply a guest-side selection change: update state + sync to the frontend.
fn editSetSel(start: i32, end: i32) void {
    const renderer = @import("../../gui/renderer.zig");
    user32.edit_sel_start = start;
    user32.edit_sel_end = end;
    renderer.setEditSelection(start, end);
}

// --- Common control class registry (hwnd -> class) ---
// SB_* (status bar) and PBM_* (progress bar) share the same WM_USER message
// numbers, so dispatch must know the control's class. Recorded at creation
// time by CreateWindowExA / CreateStatusWindowA.
const ControlClass = struct { hwnd: usize, class: [32]u8, len: u8 };
/// Width of a recorded class name, terminator included.
const max_control_class_len = @sizeOf(@TypeOf(ControlClass.class));
var control_classes: [64]ControlClass = undefined;
var control_class_count: usize = 0;

pub fn setControlClass(hwnd: usize, class: []const u8) void {
    if (hwnd == 0 or control_class_count >= control_classes.len) return;
    // A name that does not fit is dropped, not cut: a cut name is a different
    // name, and dispatch would then answer for whichever control shares the
    // truncated prefix.
    if (class.len + 1 > max_control_class_len) return;
    var entry = ControlClass{ .hwnd = hwnd, .class = undefined, .len = 0 };
    entry.len = @intCast(text_utils.copyCString(&entry.class, class));
    control_classes[control_class_count] = entry;
    control_class_count += 1;
}

fn controlClassOf(hwnd: usize) ?[]const u8 {
    var i: usize = control_class_count;
    while (i > 0) {
        i -= 1;
        const e = &control_classes[i];
        if (e.hwnd == hwnd) return e.class[0..e.len];
    }
    return null;
}

// --- Button state (checkboxes / radio buttons) ---

const ButtonState = struct { hwnd: usize, checked: u32, state: u32 };
var button_states: [64]ButtonState = [_]ButtonState{.{ .hwnd = 0, .checked = 0, .state = 0 }} ** 64;

fn buttonStateOf(hwnd: usize) ?*ButtonState {
    for (&button_states) |*bs| {
        if (bs.hwnd == hwnd) return bs;
    }
    return null;
}

fn buttonStateAlloc(hwnd: usize) ?*ButtonState {
    for (&button_states) |*bs| {
        if (bs.hwnd == 0) {
            bs.hwnd = hwnd;
            bs.checked = 0;
            bs.state = 0;
            return bs;
        }
    }
    return null;
}

/// Control id of a child window (window_info.id, stored at creation).
fn controlIdOf(hwnd: usize) i32 {
    if (user32.getWindowInfo(hwnd)) |info| return info.id;
    return @intCast(hwnd);
}

/// Apply an auto-button click: BS_AUTOCHECKBOX (3) toggles, BS_AUTORADIOBUTTON
/// (9) becomes checked (radios can't be un-checked by clicking). Returns true
/// if the state changed.
fn applyAutoButtonClick(bs: *ButtonState, hwnd: usize) bool {
    const bs_type = if (user32.getWindowInfo(hwnd)) |info|
        @as(u32, @bitCast(info.style)) & 0xF
    else
        0;
    if (bs_type != 3 and bs_type != 9) return false;
    if (bs_type == 3) {
        bs.checked ^= 1;
    } else {
        bs.checked = 1;
        // BS_AUTORADIOBUTTON: uncheck the other radios in the same group
        // (same parent, bounded by WS_GROUP controls), like real Win32.
        uncheckRadioGroup(hwnd);
    }
    bs.state = (bs.state & ~@as(u32, 3)) | (bs.checked & 3);
    return true;
}

const DLG_WS_GROUP: u32 = 0x00020000;

/// Uncheck every BS_AUTORADIOBUTTON in the same radio group as `hwnd` (except
/// `hwnd` itself). The group spans the parent's children from just after the
/// previous WS_GROUP control to just before the next one.
fn uncheckRadioGroup(hwnd: usize) void {
    const info = user32.getWindowInfo(hwnd) orelse return;
    const parent = info.parent;

    // Collect sibling auto-radio hwnds + their styles in creation order.
    var radios: [64]usize = undefined;
    var styles: [64]u32 = undefined;
    var n: usize = 0;
    var self_idx: ?usize = null;
    for (user32.window_info_table[0..user32.window_info_count]) |*entry| {
        if (entry.parent != parent) continue;
        const st: u32 = @bitCast(entry.style);
        if ((st & 0xF) != 9) continue; // not an auto radio
        if (n < radios.len) {
            radios[n] = entry.hwnd;
            styles[n] = st;
            if (entry.hwnd == hwnd) self_idx = n;
            n += 1;
        }
    }
    if (n == 0 or self_idx == null) return;
    const self_i = self_idx.?;

    // Group range: [start, end] of creation-order indices bounded by WS_GROUP.
    // The control carrying WS_GROUP starts its own group.
    var start: usize = 0;
    var i: usize = self_i;
    while (true) {
        if ((styles[i] & DLG_WS_GROUP) != 0) {
            start = i;
            break;
        }
        if (i == 0) break;
        i -= 1;
    }
    var end: usize = n - 1;
    i = self_i;
    while (i + 1 < n) {
        i += 1;
        if ((styles[i] & DLG_WS_GROUP) != 0) {
            end = i - 1;
            break;
        }
    }

    const renderer = @import("../../gui/renderer.zig");
    for (start..end + 1) |idx| {
        if (idx == self_i) continue;
        const rb = buttonStateOf(radios[idx]) orelse (buttonStateAlloc(radios[idx]) orelse continue);
        if (rb.checked != 0) {
            rb.checked = 0;
            rb.state = (rb.state & ~@as(u32, 3));
            renderer.updateControlChecked(controlIdOf(radios[idx]), false);
        }
    }
}

/// Sends WM_COMMAND(BN_CLICKED) to a button's parent (per-hwnd WndProc, else
/// the global WndProc) — used by BM_CLICK and the renderer click path.
fn notifyButtonParent(hwnd: usize, ctrl_id: i32) void {
    const parent = if (user32.getWindowInfo(hwnd)) |info| info.parent else 0;
    const parent_proc = user32.getWndProc(parent) orelse
        (if (user32.global_wndproc) |p| @intFromPtr(p) else 0);
    if (parent_proc != 0) {
        var err_flag: u32 = 0;
        _ = user32.callWndProcSafe(parent_proc, parent, w32.WM_COMMAND, @as(usize, @intCast(ctrl_id)), @as(isize, @bitCast(hwnd)), &err_flag);
    }
}

/// Toggle the checked state of an auto checkbox/radio with the given control
/// id and notify the renderer. Called from the renderer click path before the
/// WM_COMMAND is delivered, so the app sees the updated BM_GETCHECK state.
pub fn toggleAutoButton(ctrl_id: u32) void {
    for (user32.window_info_table[0..user32.window_info_count]) |*entry| {
        if (entry.id != @as(i32, @intCast(ctrl_id))) continue;
        const hwnd = entry.hwnd;
        const cls = controlClassOf(hwnd) orelse continue;
        if (!std.ascii.eqlIgnoreCase(cls, "Button")) continue;
        const bs = buttonStateOf(hwnd) orelse (buttonStateAlloc(hwnd) orelse return);
        if (applyAutoButtonClick(bs, hwnd)) {
            const renderer = @import("../../gui/renderer.zig");
            renderer.updateControlChecked(@intCast(ctrl_id), bs.checked != 0);
        }
        return;
    }
}

// ListBox state per hwnd (items + cursor) so LB_* messages round-trip.
const MAX_LB_ITEMS = 128;
const MAX_LB_ITEM_LEN = 64;
const ListBoxState = struct {
    hwnd: usize,
    items: [MAX_LB_ITEMS][MAX_LB_ITEM_LEN]u8 = undefined,
    item_lens: [MAX_LB_ITEMS]u8 = undefined,
    count: u16 = 0,
    cursor: i32 = -1,
    used: bool = false,
};
var listbox_states: [16]ListBoxState = undefined;
var listbox_state_count: usize = 0;
/// ListView column counter (shared, per-process).
var col_count: u32 = 0;

fn listBoxStateOf(hwnd: usize) *ListBoxState {
    for (listbox_states[0..listbox_state_count]) |*st| {
        if (st.hwnd == hwnd) return st;
    }
    if (listbox_state_count >= listbox_states.len) return &listbox_states[0];
    const st = &listbox_states[listbox_state_count];
    listbox_state_count += 1;
    st.* = .{ .hwnd = hwnd, .used = true };
    return st;
}

/// Find an existing listbox state without allocating (for read-only queries).
fn listBoxStateFind(hwnd: usize) ?*ListBoxState {
    for (listbox_states[0..listbox_state_count]) |*st| {
        if (st.hwnd == hwnd) return st;
    }
    return null;
}

/// Text of the currently selected ListBox/ComboBox item, if any.
pub fn listBoxSelectedText(hwnd: usize) []const u8 {
    const st = listBoxStateFind(hwnd) orelse return "";
    if (st.cursor < 0 or st.cursor >= @as(i32, @intCast(st.count))) return "";
    const idx: usize = @intCast(st.cursor);
    return st.items[idx][0..st.item_lens[idx]];
}

/// Uniform control text lookup for GetWindowTextA / WM_GETTEXT: dialog child
/// texts (by control id), ListBox/ComboBox selection text, and per-hwnd texts
/// set via SetWindowTextA / CreateWindowEx.
pub fn getControlText(hWnd: usize) []const u8 {
    const DIALOG_HWND: usize = 0x00000456;
    const dialog_base = DIALOG_HWND << 8;
    if (hWnd >= dialog_base and hWnd < dialog_base + 0x10000) {
        const ctrl_id: i32 = @intCast(hWnd ^ dialog_base);
        const dialog = @import("dialog.zig");
        return dialog.getCtrlText(ctrl_id);
    }
    if (controlClassOf(hWnd)) |cls| {
        if (std.ascii.eqlIgnoreCase(cls, "ListBox") or std.ascii.eqlIgnoreCase(cls, "ComboBox")) {
            return listBoxSelectedText(hWnd);
        }
    }
    return user32.getHwndText(hWnd);
}

/// Push the current items of a listbox to the renderer (web/FLTK display).
fn notifyListboxItems(st: *const ListBoxState) void {
    const renderer = @import("../../gui/renderer.zig");
    const id = controlIdOf(st.hwnd);
    var joined: [MAX_LB_ITEMS * MAX_LB_ITEM_LEN]u8 = undefined;
    var pos: usize = 0;
    for (0..st.count) |i| {
        if (i > 0 and pos < joined.len) {
            joined[pos] = '\n';
            pos += 1;
        }
        const n = @min(@as(usize, st.item_lens[i]), joined.len - pos);
        @memcpy(joined[pos .. pos + n], st.items[i][0..n]);
        pos += n;
    }
    renderer.setControlItems(id, joined[0..pos]);
}

/// LB_ADDSTRING/INSERTSTRING core: adds `text` at `idx` (-1 = append).
fn listBoxAddString(st: *ListBoxState, idx: i32, text: []const u8) i32 {
    if (st.count >= MAX_LB_ITEMS) return -1;
    const insert_idx: usize = if (idx < 0 or @as(usize, @intCast(idx)) > st.count) st.count else @intCast(idx);
    // Shift existing items right.
    var i: usize = st.count;
    while (i > insert_idx) : (i -= 1) {
        st.items[i] = st.items[i - 1];
        st.item_lens[i] = st.item_lens[i - 1];
    }
    const n = text_utils.copyCString(&st.items[insert_idx], text);
    st.item_lens[insert_idx] = @intCast(n);
    st.count += 1;
    notifyListboxItems(st);
    return @intCast(insert_idx);
}

/// Handle ListBox (LB_*) messages. Returns null if the message isn't LB_*.
fn handleListBoxMsg(hWnd: usize, Msg: u32, wParam: usize, lParam: isize) ?isize {
    const class = controlClassOf(hWnd) orelse return null;
    const is_lb = std.ascii.eqlIgnoreCase(class, "ListBox");
    const is_cb = std.ascii.eqlIgnoreCase(class, "ComboBox");
    const is_tab = std.ascii.eqlIgnoreCase(class, "SysTabControl32");
    const is_lv = std.ascii.eqlIgnoreCase(class, "SysListView32") or std.ascii.eqlIgnoreCase(class, "SysListView");
    const is_tv = std.ascii.eqlIgnoreCase(class, "SysTreeView32");
    const is_hdr = std.ascii.eqlIgnoreCase(class, "SysHeader32");
    if (!is_lb and !is_cb and !is_tab and !is_lv and !is_tv and !is_hdr) return null;
    const st = listBoxStateOf(hWnd);

    // Normalize ComboBox (CB_*) / TabControl (TCM_*) / ListView (LVM_*) /
    // TreeView (TVM_*) / Header (HDM_*) message numbers onto the shared
    // item-list ops.
    var op: u32 = Msg;
    if (is_hdr) {
        op = switch (Msg) {
            0x1200 => 0x018B, // HDM_GETITEMCOUNT
            0x1201 => 0x01A5, // HDM_INSERTITEMA (HDITEM* in lParam)
            0x1202 => 0x0182, // HDM_DELETEITEM (returns TRUE)
            0x1203 => 0x0189, // HDM_GETITEMA (HDITEM* in lParam)
            0x1204 => return 1, // HDM_SETITEMA
            0x120F => return 0, // HDM_ORDERTOINDEX
            else => return 0,
        };
    } else if (is_tv) {
        op = switch (Msg) {
            0x1100 => 0x01A4, // TVM_INSERTITEMA (TVINSERTSTRUCT* in lParam)
            0x1101 => 0x0182, // TVM_DELETEITEM (returns TRUE)
            0x1102 => return 1, // TVM_EXPAND
            0x1104 => return 0, // TVM_GETITEMRECT
            0x1105 => 0x018B, // TVM_GETCOUNT
            0x110A => return 0, // TVM_GETNEXTITEM
            0x110B => return 1, // TVM_SELECTITEM
            0x110C => 0x0189, // TVM_GETITEMA (TVITEM* in lParam)
            else => return null,
        };
    } else if (is_lv) {
        op = switch (Msg) {
            0x1004 => 0x018B, // LVM_GETITEMCOUNT
            0x1005 => 0x0189, // LVM_GETITEMA (LVITEM* in lParam)
            0x1007 => 0x01A1, // LVM_INSERTITEMA (special: LVITEM* in lParam)
            0x1008 => 0x0182, // LVM_DELETEITEM (returns TRUE)
            0x1009 => 0x0184, // LVM_DELETEALLITEMS
            0x101B => 0x01A2, // LVM_INSERTCOLUMNA (count columns)
            0x102B => { // LVM_SETITEMSTATE: select item (wParam = index)
                const idx: usize = @intCast(wParam);
                if (idx < st.count) st.cursor = @intCast(idx);
                return 1;
            },
            0x102C => return if (st.cursor >= 0) @as(isize, 1) else 0, // LVM_GETITEMSTATE (selected)
            0x102D => 0x0189, // LVM_GETITEMTEXTA (LVITEM* in lParam)
            0x102E => 0x01A3, // LVM_SETITEMTEXTA (LVITEM* in lParam)
            0x1032 => return if (st.cursor >= 0) @as(isize, 1) else 0, // LVM_GETSELECTEDCOUNT
            else => return null,
        };
    } else if (is_tab) {
        op = switch (Msg) {
            0x130C => 0x0186, // TCM_SETCURSEL (MSVC6: FIRST+12)
            0x130B => 0x0188, // TCM_GETCURSEL
            0x1304 => 0x018B, // TCM_GETITEMCOUNT
            0x1308 => 0x0182, // TCM_DELETEITEM
            0x1309 => 0x0184, // TCM_DELETEALLITEMS
            0x1305 => 0x0189, // TCM_GETITEMA (text out via TCITEM*)
            0x1307 => 0x01A0, // TCM_INSERTITEMA (special: TCITEM* in lParam)
            0x1301, 0x1302, 0x1303, 0x1306, 0x130A, 0x130D, 0x130E, 0x130F, 0x1310, 0x1311, 0x1312, 0x1313 => return 0,
            else => return null,
        };
    } else if (is_cb) {
        op = switch (Msg) {
            0x0143 => 0x0180, // CB_ADDSTRING
            0x014A => 0x0181, // CB_INSERTSTRING
            0x0144 => 0x0182, // CB_DELETESTRING
            0x014B => 0x0184, // CB_RESETCONTENT
            0x0146 => 0x018B, // CB_GETCOUNT
            0x0147 => 0x0188, // CB_GETCURSEL
            0x014E => 0x0186, // CB_SETCURSEL
            0x0148 => 0x0189, // CB_GETLBTEXT
            0x0149 => 0x018A, // CB_GETLBTEXTLEN
            0x014D => 0x018C, // CB_SELECTSTRING
            0x014C => 0x018F, // CB_FINDSTRING
            0x014F => return 1, // CB_SHOWDROPDOWN
            0x0157 => return 0, // CB_GETDROPPEDSTATE
            0x0159, 0x015A => return 0, // CB_GETITEMDATA / CB_SETITEMDATA
            else => return null,
        };
    }
    switch (op) {
        0x0180 => return listBoxAddString(st, -1, trace.c_span(@as(usize, @bitCast(lParam)))), // LB_ADDSTRING
        0x0181 => return listBoxAddString(st, @intCast(@as(i32, @bitCast(@as(u32, @truncate(wParam))))), trace.c_span(@as(usize, @bitCast(lParam)))), // LB_INSERTSTRING
        0x01A5 => { // HDM_INSERTITEMA: lParam = HDITEM* (pszText at +8)
            if (lParam == 0) return 0;
            const item = @as([*]const u8, @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam)))));
            const mask = std.mem.readInt(u32, item[0..4], .little);
            const psz = @as(*align(1) const u32, @ptrCast(item + 8)).*;
            const text = if ((mask & 0x2) != 0 and psz != 0) trace.c_span(psz) else "";
            return @intCast(listBoxAddString(st, -1, text));
        },
        0x01A4 => { // TVM_INSERTITEMA: lParam = TVINSERTSTRUCT* (item.pszText at +24)
            if (lParam == 0) return 0;
            const item = @as([*]const u8, @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam)))));
            const mask = std.mem.readInt(u32, item[8..12], .little);
            const psz = @as(*align(1) const u32, @ptrCast(item + 24)).*;
            const text = if ((mask & 0x1) != 0 and psz != 0) trace.c_span(psz) else "";
            return @intCast(listBoxAddString(st, -1, text));
        },
        0x01A1 => { // LVM_INSERTITEMA: lParam = LVITEM* (pszText at +20)
            if (lParam == 0) return -1;
            const item = @as([*]const u8, @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam)))));
            const mask = std.mem.readInt(u32, item[0..4], .little);
            const psz = std.mem.readInt(u32, item[20..24], .little);
            const text = if ((mask & 0x1) != 0 and psz != 0) trace.c_span(psz) else "";
            return listBoxAddString(st, @intCast(@as(i32, @bitCast(@as(u32, @truncate(wParam))))), text);
        },
        0x01A2 => { // LVM_INSERTCOLUMNA: bump a column counter
            col_count +%= 1;
            return @intCast(col_count - 1);
        },
        0x01A3 => { // LVM_SETITEMTEXTA: replace item text (LVITEM* pszText at +20)
            const idx: usize = @intCast(wParam);
            if (idx >= st.count or lParam == 0) return 1;
            const item = @as([*]const u8, @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam)))));
            const psz = std.mem.readInt(u32, item[20..24], .little);
            if (psz != 0) {
                const text = trace.c_span(psz);
                st.item_lens[idx] = @intCast(text_utils.copyCString(&st.items[idx], text));
                notifyListboxItems(st);
            }
            return 1;
        },
        0x01A0 => { // TCM_INSERTITEM: lParam = TCITEM* (pszText at +12)
            if (lParam == 0) return -1;
            const item = @as([*]const u8, @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam)))));
            const mask = std.mem.readInt(u32, item[0..4], .little);
            const psz = std.mem.readInt(u32, item[12..16], .little);
            const text = if ((mask & 0x1) != 0 and psz != 0) trace.c_span(psz) else "";
            return listBoxAddString(st, @intCast(@as(i32, @bitCast(@as(u32, @truncate(wParam))))), text);
        },
        0x0182 => { // LB_DELETESTRING
            const idx: usize = @intCast(wParam);
            if (idx >= st.count) return @intCast(st.count -| 1);
            var i = idx;
            while (i + 1 < st.count) : (i += 1) {
                st.items[i] = st.items[i + 1];
                st.item_lens[i] = st.item_lens[i + 1];
            }
            st.count -= 1;
            if (st.cursor >= @as(i32, @intCast(st.count))) st.cursor = @intCast(st.count -| 1);
            notifyListboxItems(st);
            // TCM_DELETEITEM / LVM_DELETEITEM return TRUE (LB_DELETESTRING
            // returns the count).
            return if (is_tab or is_lv or is_tv or is_hdr) @as(isize, 1) else @as(isize, st.count);
        },
        0x0184 => { // LB_RESETCONTENT
            st.count = 0;
            st.cursor = -1;
            notifyListboxItems(st);
            return 1;
        },
        0x0186 => { // LB_SETCURSEL
            const prev = st.cursor;
            st.cursor = if (wParam == 0xFFFFFFFF) -1 else @intCast(@as(i32, @bitCast(@as(u32, @truncate(wParam)))));
            return prev;
        },
        0x0188 => return st.cursor, // LB_GETCURSEL
        0x0189 => { // LB_GETTEXT / TCM_GETITEM / LVM_GETITEMTEXTA / TVM_GETITEMA
            var idx: usize = @intCast(wParam);
            var dst_addr: usize = @as(usize, @bitCast(lParam));
            if (is_tab or is_lv or is_tv or is_hdr) {
                // TCITEM*: pszText at +12; LVITEM*: +20; TVITEM*: +16; HDITEM*: +8.
                // the output buffer (32-bit guest ptr). TVM_GETITEMA's index is
                // in the struct's hItem field (+4), not wParam.
                const psz_off: usize = if (is_tab) 12 else if (is_lv) 20 else if (is_tv) 16 else 8;
                const item = @as([*]const u8, @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam)))));
                if (is_tv) {
                    const hitem = @as(*align(1) const u32, @ptrCast(item + 4)).*;
                    idx = @intCast(hitem);
                }
                const psz = @as(*align(1) const u32, @ptrCast(item + psz_off)).*;
                if (psz == 0) return 0;
                dst_addr = @as(usize, psz);
            }
            if (idx >= st.count or lParam == 0) return @intCast(st.count -| 1);
            const dst: [*]u8 = @ptrFromInt(trace.addr(dst_addr));
            const n = st.item_lens[idx];
            @memcpy(dst[0..n], st.items[idx][0..n]);
            dst[n] = 0;
            // TCM_GETITEM / LVM_GETITEMTEXT return 1 on success (LB_GETTEXT
            // returns the length).
            return if (is_tab or is_lv or is_tv or is_hdr) @as(isize, 1) else @as(isize, n);
        },
        0x018A => { // LB_GETTEXTLEN
            const idx: usize = @intCast(wParam);
            if (idx >= st.count) return @intCast(st.count -| 1);
            return st.item_lens[idx];
        },
        0x018B => return @intCast(st.count), // LB_GETCOUNT
        0x018C => { // LB_SELECTSTRING: find item starting with lParam, select it
            const prefix = trace.c_span(@as(usize, @bitCast(lParam)));
            var start: usize = if (wParam == 0xFFFFFFFF) 0 else @intCast(wParam);
            while (start < st.count) : (start += 1) {
                if (std.mem.startsWith(u8, st.items[start][0..st.item_lens[start]], prefix)) {
                    st.cursor = @intCast(start);
                    return @intCast(start);
                }
            }
            return st.count -| 1;
        },
        0x018F => { // LB_FINDSTRING: like SELECTSTRING but no selection
            const prefix = trace.c_span(@as(usize, @bitCast(lParam)));
            var start: usize = if (wParam == 0xFFFFFFFF) 0 else @intCast(wParam);
            while (start < st.count) : (start += 1) {
                if (std.mem.startsWith(u8, st.items[start][0..st.item_lens[start]], prefix)) {
                    return @intCast(start);
                }
            }
            return st.count -| 1;
        },
        0x0199, 0x019A => return 0, // LB_GETITEMDATA / LB_SETITEMDATA
        else => return null,
    }
}

/// System-color lookup for WM_CTLCOLOR brushes (handle N = COLOR_xxx + 1).
fn systemColor(index: usize) u32 {
    const colors = [_]u32{
        0x00C0C0C0, // 0  COLOR_SCROLLBAR
        0x00808080, // 1  COLOR_BACKGROUND
        0x00000080, // 2  COLOR_ACTIVECAPTION
        0x00808080, // 3  COLOR_INACTIVECAPTION
        0x00C0C0C0, // 4  COLOR_MENU
        0x00FFFFFF, // 5  COLOR_WINDOW
        0x00C0C0C0, // 6  COLOR_WINDOWFRAME
        0x00000000, // 7  COLOR_MENUTEXT
        0x00000000, // 8  COLOR_WINDOWTEXT
        0x00FFFFFF, // 9  COLOR_CAPTIONTEXT
        0x00C0C0C0, // 10 COLOR_ACTIVEBORDER
        0x00C0C0C0, // 11 COLOR_INACTIVEBORDER
        0x00808080, // 12 COLOR_APPWORKSPACE
        0x00000080, // 13 COLOR_HIGHLIGHT
        0x00FFFFFF, // 14 COLOR_HIGHLIGHTTEXT
        0x00C0C0C0, // 15 COLOR_BTNFACE
        0x00808080, // 16 COLOR_BTNSHADOW
        0x00808080, // 17 COLOR_GRAYTEXT
        0x00000000, // 18 COLOR_BTNTEXT
        0x00C0C0C0, // 19 COLOR_INACTIVECAPTIONTEXT
        0x00FFFFFF, // 20 COLOR_BTNHIGHLIGHT
        0x00000000, // 21 COLOR_3DDKSHADOW
    };
    if (index < colors.len) return colors[index];
    return 0x00C0C0C0;
}

/// Sends the WM_CTLCOLOR* message for a standard control to its parent,
/// maps the returned brush to an RGB color, caches it per control id, and
/// pushes it to the renderer so the web/FLTK widget uses the background.
/// Returns the color, or 0xFFFFFFFF if the parent returned 0 (default).
pub fn applyCtlColor(control_hwnd: usize, class_name: []const u8) u32 {
    const parent = if (user32.getWindowInfo(control_hwnd)) |info| info.parent else 0;
    const parent_proc = user32.getWndProc(parent) orelse
        (if (user32.global_wndproc) |p| @intFromPtr(p) else 0);
    if (parent_proc == 0) return 0xFFFFFFFF;

    // Pick the WM_CTLCOLOR* message for this class.
    const msg_id: u32 = if (std.ascii.eqlIgnoreCase(class_name, "Button"))
        0x0135 // WM_CTLCOLORBTN
    else if (std.ascii.eqlIgnoreCase(class_name, "Edit"))
        0x0133 // WM_CTLCOLOREDIT
    else if (std.ascii.eqlIgnoreCase(class_name, "ListBox") or std.ascii.eqlIgnoreCase(class_name, "ComboBox"))
        0x0134 // WM_CTLCOLORLISTBOX
    else if (std.ascii.eqlIgnoreCase(class_name, "Static"))
        0x0138 // WM_CTLCOLORSTATIC
    else
        0xFFFFFFFF;
    if (msg_id == 0xFFFFFFFF) return 0xFFFFFFFF;

    var err_flag: u32 = 0;
    const brush = user32.callWndProcSafe(parent_proc, parent, msg_id, 0, @as(isize, @bitCast(control_hwnd)), &err_flag);
    // GDI handles start at 0xA0000001 (high bit set), which is NEGATIVE as a
    // 32-bit isize — reinterpret as unsigned for the system-color / handle
    // ranges.
    const brush_u: u32 = @truncate(@as(usize, @bitCast(brush)));
    const color: u32 = if (brush_u == 0)
        0xFFFFFFFF // default
    else if (brush_u >= 1 and brush_u <= 21)
        systemColor(brush_u - 1)
    else blk: {
        const gdi32 = @import("../gdi32.zig");
        if (gdi32.findObject(@as(usize, brush_u))) |obj| {
            if (obj.obj_type == .Brush) break :blk obj.data.brush.color;
        }
        break :blk 0xFFFFFFFF;
    };

    if (color != 0xFFFFFFFF) {
        const id = controlIdOf(control_hwnd);
        const renderer = @import("../../gui/renderer.zig");
        renderer.updateControlColor(id, color);
    }
    return color;
}

/// Set the listbox cursor for a control id (used by the web/FLTK click path).
pub fn setListboxCursor(ctrl_id: u32, index: i32) void {
    for (user32.window_info_table[0..user32.window_info_count]) |*entry| {
        if (entry.id != @as(i32, @intCast(ctrl_id))) continue;
        const class = controlClassOf(entry.hwnd) orelse continue;
        if (!std.ascii.eqlIgnoreCase(class, "ListBox")) continue;
        const st = listBoxStateOf(entry.hwnd);
        if (index >= 0 and @as(usize, @intCast(index)) < st.count) {
            st.cursor = index;
        }
        return;
    }
}

const ProgressState = struct { hwnd: usize, min: i32, max: i32, pos: i32 };
var progress_states: [32]ProgressState = [_]ProgressState{.{ .hwnd = 0, .min = 0, .max = 100, .pos = 0 }} ** 32;
var progress_state_count: usize = 0;

fn progressStateOf(hwnd: usize) *ProgressState {
    for (progress_states[0..progress_state_count]) |*st| {
        if (st.hwnd == hwnd) return st;
    }
    if (progress_state_count >= progress_states.len) return &progress_states[0];
    const st = &progress_states[progress_state_count];
    progress_state_count += 1;
    st.* = .{ .hwnd = hwnd, .min = 0, .max = 100, .pos = 0 };
    return st;
}

/// Handle common control messages (ListView, TabControl, StatusBar, ProgressBar, etc.)
/// Returns sensible default values so apps don't loop or crash.
pub fn handleCommonControlMsg(hWnd: usize, Msg: u32, wParam: usize, lParam: isize) isize {
    const renderer = @import("../../gui/renderer.zig");

    const class = controlClassOf(hWnd);
    if (class != null and std.ascii.eqlIgnoreCase(class.?, "msctls_statusbar32")) {
        // Status bar: SB_* (WM_USER+0..15). Text updates are forwarded to the
        // renderer so the web/FLTK status bar actually shows the new string.
        return switch (Msg) {
            0x0401 => { // SB_SETTEXTA: lParam = LPCSTR text
                if (lParam != 0) {
                    var buf: [512]u8 = undefined;
                    renderer.updateControlText(@intCast(hWnd), ansi.toUtf8(trace.c_span(@as(usize, @bitCast(lParam))), &buf));
                }
                return 1;
            },
            0x040B => { // SB_SETTEXTW: lParam = LPCWSTR text
                if (lParam != 0) {
                    const w = trace.c_span_w(@intCast(lParam));
                    var buf: [512]u8 = undefined;
                    renderer.updateControlText(@intCast(hWnd), text_utils.wideToUtf8(w, &buf));
                }
                return 1;
            },
            0x0404 => 1, // SB_SETPARTS: TRUE
            0x0409 => 0, // SB_GETPARTS: 0 parts
            0x040D => 0, // SB_GETTEXTLENGTHW: 0
            else => 0,
        };
    }

    if (class != null and std.ascii.eqlIgnoreCase(class.?, "msctls_progress32")) {
        // Progress bar: PBM_* (WM_USER+1..15). Position/range updates are
        // forwarded to the renderer so the fill animates in the web/FLTK UI.
        const st = progressStateOf(hWnd);
        return switch (Msg) {
            0x0401 => { // PBM_SETRANGE: lParam = MAKELPARAM(min, max)
                if (lParam != 0) {
                    const bits: u32 = @truncate(@as(u64, @bitCast(@as(i64, lParam))));
                    st.min = @intCast(bits & 0xFFFF);
                    st.max = @intCast((bits >> 16) & 0xFFFF);
                    renderer.updateControlRange(@intCast(hWnd), st.min, st.max);
                }
                return 1;
            },
            0x0402 => { // PBM_SETPOS: wParam = new position
                st.pos = @intCast(wParam);
                renderer.updateControlValue(@intCast(hWnd), st.pos);
                return 1;
            },
            0x0403 => { // PBM_DELTAPOS: wParam = delta
                st.pos += @intCast(wParam);
                renderer.updateControlValue(@intCast(hWnd), st.pos);
                return 1;
            },
            0x0404 => 1, // PBM_SETSTEP
            0x0405 => 1, // PBM_STEPIT
            0x0406 => { // PBM_SETRANGE32: wParam = min, lParam = max
                st.min = @intCast(wParam);
                st.max = @intCast(lParam);
                renderer.updateControlRange(@intCast(hWnd), st.min, st.max);
                return 1;
            },
            0x0408 => st.pos, // PBM_GETPOS: current position
            0x0409 => 1, // PBM_SETBARCOLOR
            0x040D => 1, // PBM_SETBKCOLOR
            else => 0,
        };
    }

    // UpDown control (msctls_updown32): UDM_* = WM_USER+101..115.
    if (class != null and std.ascii.eqlIgnoreCase(class.?, "msctls_updown32")) {
        const st = upDownStateOf(hWnd);
        return switch (Msg) {
            0x0465 => { // UDM_SETRANGE: lParam = MAKELPARAM(lo, hi)
                const bits: u32 = @truncate(@as(u64, @bitCast(@as(i64, lParam))));
                st.min = @intCast(@as(i32, @bitCast(bits & 0xFFFF)));
                st.max = @intCast(@as(i32, @bitCast((bits >> 16) & 0xFFFF)));
                return 0;
            },
            0x0466 => 0, // UDM_GETRANGE (callers usually use GETRANGE32)
            0x0467 => { // UDM_SETPOS: lParam = new position
                const prev = st.pos;
                const bits: u32 = @truncate(@as(u64, @bitCast(@as(i64, lParam))));
                st.pos = @as(i32, @bitCast(bits));
                if (st.pos < st.min) st.pos = st.min;
                if (st.pos > st.max) st.pos = st.max;
                renderer.updateControlValue(@intCast(hWnd), st.pos);
                return prev;
            },
            0x0468 => st.pos, // UDM_GETPOS
            0x0469 => 0, // UDM_SETBUDDY
            0x046A => 0, // UDM_GETBUDDY
            0x046F => { // UDM_SETRANGE32: wParam = lo, lParam = hi
                st.min = w32val(wParam);
                st.max = l32val(lParam);
                return 0;
            },
            0x0470 => { // UDM_GETRANGE32: wParam = lo*, lParam = hi*
                if (wParam != 0) @as(*align(1) i32, @ptrFromInt(trace.addr(wParam))).* = st.min;
                if (lParam != 0) @as(*align(1) i32, @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))))).* = st.max;
                return 0;
            },
            else => 0,
        };
    }

    // Trackbar control (msctls_trackbar32): TBM_* = WM_USER+0..30.
    if (class != null and std.ascii.eqlIgnoreCase(class.?, "msctls_trackbar32")) {
        const st = upDownStateOf(hWnd); // same {pos,min,max} shape
        return switch (Msg) {
            0x0400 => st.pos, // TBM_GETPOS
            0x0401 => st.min, // TBM_GETRANGEMIN
            0x0402 => st.max, // TBM_GETRANGEMAX
            0x0404 => 1, // TBM_SETTIC
            0x0405 => { // TBM_SETPOS: lParam = position
                st.pos = @intCast(lParam);
                renderer.updateControlValue(@intCast(hWnd), st.pos);
                return 1;
            },
            0x0406 => { // TBM_SETRANGE: lParam = MAKELPARAM(min, max)
                const bits: u32 = @truncate(@as(u64, @bitCast(@as(i64, lParam))));
                st.min = @intCast(bits & 0xFFFF);
                st.max = @intCast((bits >> 16) & 0xFFFF);
                renderer.updateControlRange(@intCast(hWnd), st.min, st.max);
                return 1;
            },
            0x0414 => 1, // TBM_SETTICFREQ
            else => 0,
        };
    }

    // DateTimePicker control (SysDateTimePick32): DTM_FIRST = 0x1000.
    if (class != null and std.ascii.eqlIgnoreCase(class.?, "SysDateTimePick32")) {
        return switch (Msg) {
            0x1001 => { // DTM_GETSYSTEMTIME: fill SYSTEMTIME at lParam
                if (trace.enable_tracing) trace.print("USER32: DTM_GETSYSTEMTIME hwnd={x}\n", .{hWnd});
                if (lParam != 0) {
                    const st = dtpStateOf(hWnd);
                    const dst: [*]u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                    @memcpy(dst[0..16], @as(*const [16]u8, @ptrCast(st)));
                }
                // MSVC6 GDT_VALID = 0 (modern SDKs define it as 1).
                return 0;
            },
            0x1002 => { // DTM_SETSYSTEMTIME: lParam = SYSTEMTIME*, wParam = GDT_VALID (0)
                if (trace.enable_tracing) trace.print("USER32: DTM_SETSYSTEMTIME hwnd={x} wParam={x}\n", .{ hWnd, wParam });
                if (lParam != 0 and wParam == 0) {
                    const src: [*]const u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                    const st = dtpStateOf(hWnd);
                    if (!dtpSetSystemTime(st, src[0..16])) return 0;
                    // render a date string for the widget
                    var buf: [64]u8 = undefined;
                    const formatted = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ st.year, st.month, st.day }) catch &[_]u8{};
                    renderer.updateControlText(@intCast(hWnd), formatted);
                }
                return 1;
            },
            else => 0,
        };
    }

    // MonthCal control (SysMonthCal32): MCM_FIRST = 0x1000. Cursor/today use
    // SYSTEMTIME pointers like DTM; MSVC6 returns TRUE (1) for success.
    if (class != null and std.ascii.eqlIgnoreCase(class.?, "SysMonthCal32")) {
        return switch (Msg) {
            0x1001 => { // MCM_GETCURSEL: fill SYSTEMTIME at lParam
                if (lParam != 0) {
                    const st = dtpStateOf(hWnd);
                    const dst: [*]u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                    @memcpy(dst[0..16], @as(*const [16]u8, @ptrCast(st)));
                }
                return 1;
            },
            0x1002 => { // MCM_SETCURSEL: store SYSTEMTIME at lParam
                if (lParam != 0) {
                    const src: [*]const u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                    const st = dtpStateOf(hWnd);
                    if (!dtpSetSystemTime(st, src[0..16])) return 0;
                }
                return 1;
            },
            0x100C => { // MCM_SETTODAY
                if (lParam != 0) {
                    const src: [*]const u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                    const st = dtpStateOf(hWnd);
                    if (!dtpSetSystemTime(st, src[0..16])) return 0;
                }
                return 1;
            },
            0x100D => { // MCM_GETTODAY
                if (lParam != 0) {
                    const st = dtpStateOf(hWnd);
                    const dst: [*]u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                    @memcpy(dst[0..16], @as(*const [16]u8, @ptrCast(st)));
                }
                return 1;
            },
            else => 0,
        };
    }

    // Tooltip control (tooltips_class32): TTM_* = WM_USER+0..50.
    if (class != null and (std.ascii.eqlIgnoreCase(class.?, "tooltips_class32") or std.ascii.eqlIgnoreCase(class.?, "tooltips_class"))) {
        return switch (Msg) {
            0x0401 => 1, // TTM_ACTIVATE
            0x0404 => { // TTM_ADDTOOLA: lParam = TOOLINFOA* — remember the tip text
                if (lParam != 0) {
                    const ti: [*]const u8 = @ptrFromInt(trace.addr(@as(usize, @bitCast(lParam))));
                    const text_ptr = @as(*align(1) const u32, @ptrCast(ti + 36)).*; // lpszText
                    const text = if (text_ptr != 0 and text_ptr != 0xFFFFFFFF) trace.c_span(@as(usize, @intCast(text_ptr))) else "";
                    setTooltipText(hWnd, text);
                }
                return 1;
            },
            0x0405 => 1, // TTM_DELTOOLA
            0x0408 => 1, // TTM_GETTOOLINFOA (text already stored)
            0x0418 => 1, // TTM_SETMAXTIPWIDTH
            else => 0,
        };
    }

    // Animation control (SysAnimate32): ACM_* = WM_USER+100..103.
    if (class != null and std.ascii.eqlIgnoreCase(class.?, "SysAnimate32")) {
        return switch (Msg) {
            0x0464 => 1, // ACM_OPENA
            0x0465 => 1, // ACM_PLAY
            0x0466 => 1, // ACM_STOP
            0x0467 => 1, // ACM_ISPLAYING
            else => 0,
        };
    }

    // ListView messages: LVM_FIRST = 0x1000
    if (Msg >= 0x1000 and Msg < 0x1100) {
        return switch (Msg) {
            0x1004 => 0, // LVM_GETITEMCOUNT: 0 items
            0x1005 => 0, // LVM_GETITEMA: FALSE (not found)
            0x1006 => 1, // LVM_SETITEMA: TRUE (success)
            0x1007 => 0, // LVM_INSERTITEMA: index 0
            0x1008 => 1, // LVM_DELETEITEM: TRUE
            0x1009 => 1, // LVM_DELETEALLITEMS: TRUE
            0x101B => 0, // LVM_INSERTCOLUMNA: column index 0
            0x101C => 0, // LVM_DELETECOLUMN: FALSE (no columns to delete)
            0x101D => 60, // LVM_GETCOLUMNWIDTH: 60 pixels
            0x102F => 1, // LVM_SETITEMCOUNT: TRUE
            0x1036 => 0, // LVM_GETSELECTEDCOUNT: 0
            0x103F => 0, // LVM_GETEXTENDEDLISTVIEWSTYLE: 0
            0x1040 => 0, // LVM_GETSUBITEMRECT: FALSE
            0x1041 => 0, // LVM_SUBITEMHITTEST: -1 miss
            0x1042 => 0, // LVM_SETCOLUMNORDERARRAY
            0x104B => 0, // LVM_GETCOLUMNORDERARRAY
            0x104D => 0, // LVM_SETEXTENDEDLISTVIEWSTYLE
            0x104E => 0, // LVM_GETEXTENDEDLISTVIEWSTYLE (alias)
            0x1061 => 0, // LVM_INSERTCOLUMNW
            0x1019 => 0, // LVM_GETCOLUMNA: FALSE (prevents infinite loop deleting columns)
            0x105F => 0, // LVM_GETCOLUMNW: FALSE
            0x1013 => 1, // LVM_ENSUREVISIBLE: TRUE
            0x1015 => 1, // LVM_REDRAWITEMS: TRUE
            else => 0,
        };
    }

    // TabControl messages: TCM_FIRST = 0x1300
    if (Msg >= 0x1300 and Msg < 0x1400) {
        return switch (Msg) {
            0x1304 => 0, // TCM_GETITEMCOUNT: 0 items
            0x1307 => 0, // TCM_INSERTITEMA: index 0
            0x133E => 0, // TCM_INSERTITEMW: index 0
            0x130B => -1, // TCM_GETCURSEL: -1 (no selection)
            0x130C => -1, // TCM_SETCURSEL: -1
            else => 0,
        };
    }

    // StatusBar messages: SB_* use WM_USER range 0x0400+
    if (Msg >= 0x0400 and Msg < 0x0500) {
        return switch (Msg) {
            0x0404 => 1, // SB_SETPARTS: TRUE
            0x0401 => 1, // SB_SETTEXTA: TRUE
            0x0409 => 0, // SB_GETPARTS: 0 parts
            0x040B => 1, // SB_SETTEXTW: TRUE
            0x040D => 0, // SB_GETTEXTLENGTHW: 0
            else => 0,
        };
    }

    // Header control: HDM_FIRST = 0x1200
    if (Msg >= 0x1200 and Msg < 0x1300) {
        return switch (Msg) {
            0x1200 => 0, // HDM_GETITEMCOUNT: 0 items
            else => 0,
        };
    }

    return 0;
}

// --- UpDown / Trackbar shared {pos,min,max} state ---
/// Drop the per-HWND state a destroyed window owned. Without this the fixed
/// tables are append-only, so an app that creates controls in a loop
/// (listbox, progress bar, up-down, date-time picker) exhausts them.
pub fn releaseControlState(hwnd: usize) void {
    {
        var i: usize = 0;
        while (i < listbox_state_count) : (i += 1) {
            if (listbox_states[i].hwnd != hwnd) continue;
            listbox_state_count -= 1;
            if (i != listbox_state_count) listbox_states[i] = listbox_states[listbox_state_count];
            break;
        }
    }
    {
        var i: usize = 0;
        while (i < progress_state_count) : (i += 1) {
            if (progress_states[i].hwnd != hwnd) continue;
            progress_state_count -= 1;
            if (i != progress_state_count) progress_states[i] = progress_states[progress_state_count];
            break;
        }
    }
    {
        var i: usize = 0;
        while (i < updown_state_count) : (i += 1) {
            if (updown_states[i].hwnd != hwnd) continue;
            updown_state_count -= 1;
            if (i != updown_state_count) updown_states[i] = updown_states[updown_state_count];
            break;
        }
    }
    var d: usize = 0;
    while (d < dtp_state_count) : (d += 1) {
        if (dtp_hwnds[d] != hwnd) continue;
        dtp_state_count -= 1;
        if (d != dtp_state_count) {
            dtp_hwnds[d] = dtp_hwnds[dtp_state_count];
            dtp_states[d] = dtp_states[dtp_state_count];
        }
        break;
    }
}

const UpDownState = struct { hwnd: usize, pos: i32, min: i32, max: i32 };
var updown_states: [32]UpDownState = [_]UpDownState{.{ .hwnd = 0, .pos = 0, .min = 0, .max = 100 }} ** 32;
var updown_state_count: usize = 0;

/// Low 32 bits of a usize (wParam) reinterpreted as i32 — handles negative
/// 32-bit guest values sign-extended on the 64-bit host.
fn w32val(v: usize) i32 {
    return @bitCast(@as(u32, @truncate(@as(u64, @intCast(v)))));
}

/// Low 32 bits of an isize (lParam) reinterpreted as i32.
fn l32val(v: isize) i32 {
    return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @intCast(v)))))));
}

fn upDownStateOf(hwnd: usize) *UpDownState {
    for (updown_states[0..updown_state_count]) |*st| {
        if (st.hwnd == hwnd) return st;
    }
    if (updown_state_count >= updown_states.len) return &updown_states[0];
    const st = &updown_states[updown_state_count];
    updown_state_count += 1;
    st.* = .{ .hwnd = hwnd, .pos = 0, .min = 0, .max = 100 };
    return st;
}

// --- DateTimePicker SYSTEMTIME state (16 bytes, mirroring the Win32 struct) ---
const DtpState = extern struct {
    year: u16 = 2000,
    month: u16 = 1,
    day_of_week: u16 = 0,
    day: u16 = 1,
    hour: u16 = 0,
    minute: u16 = 0,
    second: u16 = 0,
    milliseconds: u16 = 0,
};
var dtp_states: [16]DtpState = [_]DtpState{.{}} ** 16;
var dtp_state_count: usize = 0;

/// Weekday (0 = Sunday) that the calendar gives a date. Exact for every date
/// the FILETIME epoch covers, so 2000-02-29 is a Tuesday and not a Sunday.
fn civilDayOfWeek(year: u16, month: u16, day: u16) u16 {
    // 1970-01-01, day 0, was a Thursday, hence the +4.
    return @intCast(@mod(civil_time.daysFromCivil(year, month, day) + 4, 7));
}

/// Store the guest's 16 SYSTEMTIME bytes in a date control's state.
///
/// The weekday is derived from the date, never copied: a guest that zeroes the
/// struct before the call (the usual Delphi idiom) would otherwise store a date
/// whose wDayOfWeek is always Sunday, and the control's own day arithmetic
/// would then be wrong for every date the program shows. An impossible date
/// (2001-02-29, month 13, day 0) is rejected and leaves the state untouched, so
/// a control never displays a day its calendar does not have. Returns false
/// for a rejected date.
fn dtpSetSystemTime(st: *DtpState, src: []const u8) bool {
    var in: DtpState = undefined;
    @memcpy(std.mem.asBytes(&in), src[0..@sizeOf(DtpState)]);
    if (in.year < 1601 or in.year > 30827) return false;
    if (in.month < 1 or in.month > 12) return false;
    if (in.day < 1 or in.day > std.time.epoch.getDaysInMonth(in.year, @enumFromInt(in.month))) return false;
    st.* = in;
    st.day_of_week = civilDayOfWeek(in.year, in.month, in.day);
    return true;
}

fn dtpStateOf(hwnd: usize) *DtpState {
    for (0..dtp_state_count) |i| {
        if (dtp_hwnds[i] == hwnd) return &dtp_states[i];
    }
    if (dtp_state_count < dtp_states.len) {
        dtp_hwnds[dtp_state_count] = hwnd;
        const st = &dtp_states[dtp_state_count];
        dtp_state_count += 1;
        // A freshly created control shows today's date on the UTC guest
        // clock, not a fixed 2000-01-01 epoch (see kernel32/time.zig).
        var now: w32.SYSTEMTIME = .{};
        kernel32_time.GetLocalTime(@intFromPtr(&now));
        st.* = .{
            .year = now.wYear,
            .month = now.wMonth,
            .day_of_week = now.wDayOfWeek,
            .day = now.wDay,
            .hour = now.wHour,
            .minute = now.wMinute,
            .second = now.wSecond,
            .milliseconds = now.wMilliseconds,
        };
        return st;
    }
    return &dtp_states[0];
}
var dtp_hwnds: [16]usize = [_]usize{0} ** 16;

// --- Tooltip text store (TTM_ADDTOOL captures the tip text per hwnd) ---
const TooltipState = struct { hwnd: usize, text: [256]u8, len: u16 };
var tooltip_states: [16]TooltipState = undefined;
var tooltip_state_count: usize = 0;

fn setTooltipText(hwnd: usize, text: []const u8) void {
    for (tooltip_states[0..tooltip_state_count]) |*e| {
        if (e.hwnd == hwnd) {
            e.len = @intCast(text_utils.copyCString(&e.text, text));
            return;
        }
    }
    if (tooltip_state_count < tooltip_states.len) {
        const e = &tooltip_states[tooltip_state_count];
        tooltip_state_count += 1;
        e.hwnd = hwnd;
        e.len = @intCast(text_utils.copyCString(&e.text, text));
    }
}

/// SendMessageTimeoutA — sends a message with a timeout.
/// Delegates to SendMessageA and returns its result.
pub fn SendMessageTimeoutA(hWnd: usize, Msg: u32, wParam: usize, lParam: isize, fuFlags: u32, uTimeout: u32) callconv(w32cc.WINAPI) isize {
    _ = fuFlags;
    _ = uTimeout;
    if (trace.enable_tracing) trace.print("USER32: SendMessageTimeoutA(hwnd={x}, Msg={x}, wParam={x})\n", .{ hWnd, Msg, wParam });
    return SendMessageA(hWnd, Msg, wParam, lParam);
}

/// WaitMessage — blocks until a message is available in the queue.
/// On real Windows this blocks the thread. We sleep briefly to avoid
/// burning 100% CPU in the Delphi message loop.
pub fn WaitMessage() callconv(w32cc.WINAPI) i32 {
    const ns: u64 = 10 * 1000000; // 10ms
    runtime.pauseOrAdvance(ns);
    return 1; // TRUE = success
}

// -------------------------------------------------------------------------
// Message / hook stubs (moved from misc.zig)
// -------------------------------------------------------------------------

pub fn GetMessageTime() callconv(w32cc.WINAPI) i32 {
    // Windows defines the message time as a GetTickCount-style value. It is
    // the same helper that stamps MSG.time, so a guest mixing the two never
    // compares a real reading against a zero.
    return @bitCast(user32.msgTime());
}

pub fn stub_MsgWaitForMultipleObjects(nCount: u32, pHandles: usize, fWaitAll: i32, dwMilliseconds: u32, dwWakeMask: u32) callconv(w32cc.WINAPI) u32 {
    _ = .{ pHandles, fWaitAll, dwWakeMask };
    // Sleep briefly to avoid burning CPU. Return nCount = message queue signaled.
    if (dwMilliseconds > 0 and dwMilliseconds != 0xFFFFFFFF) {
        const ms = @min(dwMilliseconds, 50);
        const ns = @as(u64, ms) * 1000000;
        runtime.pauseOrAdvance(ns);
    }
    return nCount;
}

pub fn stub_CallNextHookEx(hhk: usize, nCode: i32, wParam: usize, lParam: usize) callconv(w32cc.WINAPI) usize {
    _ = hhk;
    _ = nCode;
    _ = wParam;
    _ = lParam;
    return 0;
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

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "fresh DateTimePicker state shows today's date, not a fixed epoch" {
    var now: w32.SYSTEMTIME = .{};
    kernel32_time.GetLocalTime(@intFromPtr(&now));

    const first = dtpStateOf(0xd001);
    // Seeded from the live UTC guest clock rather than hardcoded 2000-01-01.
    // A year may roll over between sampling and seeding.
    try testing.expect(first.year == now.wYear or first.year == now.wYear + 1);
    try testing.expect(first.month >= 1 and first.month <= 12);
    try testing.expect(first.day >= 1 and first.day <= 31);
    try testing.expect(first.milliseconds < 1000);

    // The same hwnd maps back to the same state slot.
    const again = dtpStateOf(0xd001);
    try testing.expectEqual(first.year, again.year);

    // A different hwnd gets its own state.
    const other = dtpStateOf(0xd002);
    try testing.expect(other != first);
}

test "every dispatched MSG carries the tick count GetMessageTime reports" {
    // A zero time field makes the guest's age arithmetic read as "posted at
    // boot". The stamps come from one helper, so a message delivered now and
    // GetMessageTime() now differ by a sampling gap, not by the whole uptime.
    var msg: user32.MSG = .{};
    msg.hwnd = 1;
    msg.message = w32.WM_NULL;
    msg.time = user32.msgTime();
    const before = @as(u32, @bitCast(GetMessageTime()));
    try testing.expect(msg.time != 0);
    // The host clock is monotonic, so a later reading is never behind the
    // stamp, and both stay inside one 32-bit wrap window.
    const after = @as(u32, @bitCast(GetMessageTime()));
    try testing.expect(after - msg.time < 1000);
    try testing.expect(after - before < 1000);
}

test "a stored date keeps the weekday its calendar gives, not the caller's" {
    var st: DtpState = .{};
    // A zeroed wDayOfWeek (0 = Sunday) is what a Delphi caller sends with a
    // real date; 2000-02-29 was a Tuesday, and 2024-12-31 a Tuesday too.
    const zeroed: [16]u8 = blk: {
        var b = [_]u8{0} ** 16;
        std.mem.writeInt(u16, b[0..2], 2000, .little);
        std.mem.writeInt(u16, b[2..4], 2, .little);
        std.mem.writeInt(u16, b[6..8], 29, .little);
        break :blk b;
    };
    try testing.expect(dtpSetSystemTime(&st, &zeroed));
    try testing.expectEqual(@as(u16, 29), st.day);
    try testing.expectEqual(@as(u16, 2), st.day_of_week); // Tuesday

    const year_end: [16]u8 = blk: {
        var b = [_]u8{0} ** 16;
        std.mem.writeInt(u16, b[0..2], 2024, .little);
        std.mem.writeInt(u16, b[2..4], 12, .little);
        std.mem.writeInt(u16, b[6..8], 31, .little);
        break :blk b;
    };
    try testing.expect(dtpSetSystemTime(&st, &year_end));
    try testing.expectEqual(@as(u16, 2), st.day_of_week); // Tuesday
    // 2025-01-01 is a Wednesday: the weekday follows the year boundary.
    const new_year: [16]u8 = blk: {
        var b = [_]u8{0} ** 16;
        std.mem.writeInt(u16, b[0..2], 2025, .little);
        std.mem.writeInt(u16, b[2..4], 1, .little);
        std.mem.writeInt(u16, b[6..8], 1, .little);
        break :blk b;
    };
    try testing.expect(dtpSetSystemTime(&st, &new_year));
    try testing.expectEqual(@as(u16, 3), st.day_of_week); // Wednesday
}

test "a date the calendar does not have is rejected and leaves the state alone" {
    var st: DtpState = .{ .year = 1999, .month = 12, .day = 31, .day_of_week = 5 };
    const impossible = [_][3]u16{
        .{ 2001, 2, 29 }, // not a leap year
        .{ 1900, 2, 29 }, // century, not a leap year
        .{ 2024, 13, 1 }, // no month 13
        .{ 2024, 4, 31 }, // April has 30 days
        .{ 2024, 1, 0 },
    };
    for (impossible) |ymd| {
        var b = [_]u8{0} ** 16;
        std.mem.writeInt(u16, b[0..2], ymd[0], .little);
        std.mem.writeInt(u16, b[2..4], ymd[1], .little);
        std.mem.writeInt(u16, b[6..8], ymd[2], .little);
        try testing.expect(!dtpSetSystemTime(&st, &b));
    }
    try testing.expectEqual(DtpState{ .year = 1999, .month = 12, .day = 31, .day_of_week = 5 }, st);
}
