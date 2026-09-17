//! FLTK Backend
//!
//! This module bridges Zig to native FLTK via the C bridge in fltk_bridge.cpp.
//!
//! Threading model:
//!   - Main thread: renders the window + runs the guest (FLTK init + show
//!     happen here, before setupFS switches FS to the guest TEB — so FLTK and
//!     fontconfig see real host TLS).
//!   - FLTK thread: spawned in init(), runs Fl::check() + drains commands.
//!
//! The guest thread enqueues commands into a lock-free ring buffer. No
//! Fl::awake() is called: host TLS is corrupted in the guest-thread signal
//! dispatch context (compat mode leaves FS = guest TEB), which crashed Xlib;
//! the 1ms event-loop poll picks commands up anyway.

const std = @import("std");
const runtime = @import("../runtime.zig");
const renderer = @import("renderer.zig");
const build_options = @import("build_options");

/// Conditionally import the C bridge — only available when -Dfltk=true
const c = if (build_options.use_fltk) @cImport({
    @cInclude("fltk_bridge.h");
}) else struct {};

var g_allocator: std.mem.Allocator = undefined;

/// Set by the FLTK thread after the window is initialized and shown. The guest
/// thread waits for this before the app runs, so no enqueue/awake can race
/// window creation.
var init_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// --- Command queue (worker → FLTK thread) ---

const Command = union(enum) {
    set_title: []const u8,
    set_framebuf: struct { w: u32, h: u32 },
    resize_window: struct { x: i32, y: i32, w: i32, h: i32 },
    set_menu: []const u8,
    show_message_box: struct { title: []const u8, text: []const u8 },
    set_resolution: struct { w: u32, h: u32 },
    redraw,
    add_control: struct { class: []const u8, id: usize, x: i32, y: i32, w: i32, h: i32, style: u32, text: []const u8 },
    update_control_text: struct { id: i32, text: []const u8 },
    update_control_value: struct { id: i32, value: i32 },
    update_control_range: struct { id: i32, min: i32, max: i32 },
    update_control_checked: struct { id: i32, checked: bool },
    set_listbox_items: struct { id: i32, items: []const u8 },
    set_control_color: struct { id: i32, color: u32 },
    open_color_dialog: u32,
    show_context_menu: struct { x: i32, y: i32, json: []const u8 },
    show_dialog: []const u8,
    show_controls: []const u8,
    close_dialog,
    set_clipboard: []const u8,
    set_icon: []const u8,
    open_file_dialog: struct { filters: []const u8, is_save: bool },
    open_font_dialog: struct { face: []const u8, size: i32, bold: bool, italic: bool },
    open_print_dialog: struct { from_page: i32, to_page: i32, min_page: i32, max_page: i32, copies: i32 },
    open_find_dialog: struct { find_text: []const u8, replace_text: []const u8, is_replace: bool },
    open_page_setup_dialog: struct { left: i32, top: i32, right: i32, bottom: i32, paper_w: i32, paper_h: i32, orientation: i32, units: []const u8 },
    edit_show: struct { multiline: bool },
    edit_resize: struct { x: i32, y: i32, w: i32, h: i32 },
    edit_set_text: []const u8,
    edit_set_sel: struct { start: i32, end: i32 },
    edit_replace_sel: []const u8,
    edit_insert_char: u8,
    edit_undo,
    edit_scroll_caret,
};

const QUEUE_SIZE = 256;
var cmd_queue: [QUEUE_SIZE]Command = undefined;
var cmd_write: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var cmd_read: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var queue_mutex: runtime.Mutex = .{};

/// Frees the heap strings owned by a command's payload. Callers enqueue
/// `g_allocator.dupe`d slices; once the command has been delivered (or is
/// dropped because the queue is full) nobody references them again — the FLTK
/// bridge copies every string it keeps.
fn freeCommandPayload(cmd: *const Command) void {
    switch (cmd.*) {
        .set_title,
        .set_menu,
        .show_dialog,
        .show_controls,
        .set_icon,
        .set_clipboard,
        .edit_set_text,
        .edit_replace_sel,
        => |s| g_allocator.free(s),
        .update_control_text => |ut| g_allocator.free(ut.text),
        .set_listbox_items => |sl| g_allocator.free(sl.items),
        .show_message_box => |mb| {
            g_allocator.free(mb.title);
            g_allocator.free(mb.text);
        },
        .add_control => |ac| {
            g_allocator.free(ac.class);
            g_allocator.free(ac.text);
        },
        .open_file_dialog => |fd| g_allocator.free(fd.filters),
        .open_font_dialog => |ff| g_allocator.free(ff.face),
        .open_find_dialog => |fd| {
            g_allocator.free(fd.find_text);
            g_allocator.free(fd.replace_text);
        },
        .open_page_setup_dialog => |ps| g_allocator.free(ps.units),
        .show_context_menu => |cm| g_allocator.free(cm.json),
        else => {},
    }
}

fn enqueue(cmd: Command) void {
    queue_mutex.lock();
    defer queue_mutex.unlock();
    const w = cmd_write.load(.acquire);
    const next = (w + 1) % QUEUE_SIZE;
    if (next == cmd_read.load(.acquire)) {
        // Queue full — drop command (and its payload, or it would leak).
        freeCommandPayload(&cmd);
        return;
    }
    cmd_queue[w] = cmd;
    cmd_write.store(next, .release);

    // NOTE: no Fl::awake() here — it crashes when called from the guest thread
    // (host TLS is corrupted there because compat mode leaves FS pointing at
    // the guest TEB, and Fl::awake -> fl_open_display -> Xlib reads TLS).
    // The FLTK event loop polls every 1ms, so commands are picked up within
    // a millisecond anyway.
}

fn drainQueue() void {
    while (true) {
        const r = cmd_read.load(.acquire);
        const w = cmd_write.load(.acquire);
        if (r == w) break;

        const cmd = cmd_queue[r];
        cmd_read.store((r + 1) % QUEUE_SIZE, .release);

        if (build_options.use_fltk) {
            processCommand(cmd);
        }
        freeCommandPayload(&cmd);
    }
}

fn processCommand(cmd: Command) void {
    if (!build_options.use_fltk) return;

    switch (cmd) {
        .set_title => |title| {
            // Need null-terminated string for C
            var buf: [512]u8 = undefined;
            const len = @min(title.len, buf.len - 1);
            @memcpy(buf[0..len], title[0..len]);
            buf[len] = 0;
            c.fltk_set_title(&buf);
        },
        .set_framebuf => |fb| {
            const total = fb.w * fb.h * 4;
            if (total > 0 and total <= renderer.global_framebuf.len) {
                c.fltk_set_framebuf(
                    renderer.global_framebuf.ptr,
                    @intCast(fb.w),
                    @intCast(fb.h),
                );
            }
        },
        .resize_window => |r| {
            c.fltk_resize_window(r.x, r.y, r.w, r.h);
        },
        .set_menu => |json| {
            c.fltk_set_menu_json(json.ptr, @intCast(json.len));
        },
        .show_message_box => |mb| {
            // Need null-terminated strings
            var title_buf: [256]u8 = undefined;
            var text_buf: [2048]u8 = undefined;
            const tlen = @min(mb.title.len, title_buf.len - 1);
            const xlen = @min(mb.text.len, text_buf.len - 1);
            @memcpy(title_buf[0..tlen], mb.title[0..tlen]);
            title_buf[tlen] = 0;
            @memcpy(text_buf[0..xlen], mb.text[0..xlen]);
            text_buf[xlen] = 0;
            c.fltk_alert(&title_buf, &text_buf);
        },
        .set_resolution => |res| {
            // Resolution change — update canvas size
            c.fltk_resize_window(0, 0, @intCast(res.w), @intCast(res.h));
        },
        .redraw => {
            c.fltk_redraw();
        },
        .add_control => |ac| {
            var cls: [64]u8 = undefined;
            const clen = @min(ac.class.len, cls.len - 1);
            @memcpy(cls[0..clen], ac.class[0..clen]);
            cls[clen] = 0;
            var text: [512]u8 = undefined;
            const tlen = @min(ac.text.len, text.len - 1);
            @memcpy(text[0..tlen], ac.text[0..tlen]);
            text[tlen] = 0;
            c.fltk_add_control(&cls, @intCast(ac.id), ac.x, ac.y, ac.w, ac.h, ac.style, &text);
        },
        .update_control_text => |ut| {
            var text: [512]u8 = undefined;
            const tlen = @min(ut.text.len, text.len - 1);
            @memcpy(text[0..tlen], ut.text[0..tlen]);
            text[tlen] = 0;
            c.fltk_update_control_text(ut.id, &text);
        },
        .update_control_value => |uv| {
            c.fltk_update_control_value(uv.id, uv.value);
        },
        .update_control_range => |ur| {
            c.fltk_update_control_range(ur.id, ur.min, ur.max);
        },
        .update_control_checked => |uc| {
            c.fltk_set_control_checked(uc.id, if (uc.checked) 1 else 0);
        },
        .set_listbox_items => |sl| {
            c.fltk_set_listbox_items(sl.id, @ptrCast(sl.items.ptr));
        },
        .set_control_color => |sc| {
            c.fltk_set_control_color(sc.id, sc.color);
        },
        .open_color_dialog => |oc| {
            c.fltk_open_color_dialog(oc);
        },
        .show_context_menu => |cm| {
            var buf: [4096]u8 = undefined;
            const n = @min(cm.json.len, buf.len - 1);
            @memcpy(buf[0..n], cm.json[0..n]);
            buf[n] = 0;
            c.fltk_show_context_menu(cm.x, cm.y, &buf, @intCast(n));
        },
        .show_dialog => |json| processDialogJson(json),
        .show_controls => |json| processControlsJson(json),
        .close_dialog => c.fltk_close_dialog(),
        .set_clipboard => |text| {
            var buf: [4096]u8 = undefined;
            const n = @min(text.len, buf.len - 1);
            @memcpy(buf[0..n], text[0..n]);
            buf[n] = 0;
            c.fltk_set_clipboard(&buf);
        },
        .set_icon => |json| processIconJson(json),
        .open_file_dialog => |fd| {
            var buf: [512]u8 = undefined;
            const n = @min(fd.filters.len, buf.len - 1);
            @memcpy(buf[0..n], fd.filters[0..n]);
            buf[n] = 0;
            c.fltk_open_file_dialog(&buf, if (fd.is_save) 1 else 0);
        },
        .open_font_dialog => |ff| {
            var buf: [64]u8 = undefined;
            const n = @min(ff.face.len, buf.len - 1);
            @memcpy(buf[0..n], ff.face[0..n]);
            buf[n] = 0;
            c.fltk_open_font_dialog(&buf, ff.size, if (ff.bold) 1 else 0, if (ff.italic) 1 else 0);
        },
        .open_print_dialog => |pd| c.fltk_open_print_dialog(pd.from_page, pd.to_page, pd.min_page, pd.max_page, pd.copies),
        .open_find_dialog => |fd| {
            var fbuf: [512]u8 = undefined;
            const fn2 = @min(fd.find_text.len, fbuf.len - 1);
            @memcpy(fbuf[0..fn2], fd.find_text[0..fn2]);
            fbuf[fn2] = 0;
            var rbuf: [512]u8 = undefined;
            const rn = @min(fd.replace_text.len, rbuf.len - 1);
            @memcpy(rbuf[0..rn], fd.replace_text[0..rn]);
            rbuf[rn] = 0;
            c.fltk_open_find_dialog(&fbuf, &rbuf, if (fd.is_replace) 1 else 0);
        },
        .open_page_setup_dialog => |ps| c.fltk_open_page_setup_dialog(ps.left, ps.top, ps.right, ps.bottom, ps.paper_w, ps.paper_h, ps.orientation),
        .edit_show => |es| c.fltk_edit_show(if (es.multiline) 1 else 0),
        .edit_resize => |er| c.fltk_edit_resize(er.x, er.y, er.w, er.h),
        .edit_set_text => |t| {
            var buf: [4096]u8 = undefined;
            const n = @min(t.len, buf.len - 1);
            @memcpy(buf[0..n], t[0..n]);
            buf[n] = 0;
            c.fltk_edit_set_text(&buf);
        },
        .edit_set_sel => |es| c.fltk_edit_set_sel(es.start, es.end),
        .edit_replace_sel => |t| {
            var buf: [4096]u8 = undefined;
            const n = @min(t.len, buf.len - 1);
            @memcpy(buf[0..n], t[0..n]);
            buf[n] = 0;
            c.fltk_edit_replace_sel(&buf);
        },
        .edit_insert_char => |ch| c.fltk_edit_insert_char(ch),
        .edit_undo => c.fltk_edit_undo(),
        .edit_scroll_caret => c.fltk_edit_scroll_caret(),
    }
}

/// Parse a custom_dialog JSON and build the FLTK modal dialog.
fn processDialogJson(json: []const u8) void {
    var title_buf: [256]u8 = undefined;
    var title_len: usize = 0;
    var cx: i32 = 200;
    var cy: i32 = 120;
    var items: [64]struct { id: i32, x: i32, y: i32, cx: i32, cy: i32, class: [32]u8, text: [256]u8 } = undefined;
    var item_count: usize = 0;

    const parsed = std.json.parseFromSlice(std.json.Value, g_allocator, json, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    if (root.object.get("title")) |t| {
        if (t == .string) {
            const n = @min(t.string.len, title_buf.len - 1);
            @memcpy(title_buf[0..n], t.string[0..n]);
            title_len = n;
        }
    }
    if (root.object.get("cx")) |v| {
        if (v == .integer) cx = @intCast(v.integer);
    }
    if (root.object.get("cy")) |v| {
        if (v == .integer) cy = @intCast(v.integer);
    }

    if (root.object.get("items")) |arr| {
        if (arr == .array) {
            for (arr.array.items) |it| {
                if (item_count >= items.len or it != .object) continue;
                const itm = &items[item_count];
                itm.* = .{ .id = 0, .x = 0, .y = 0, .cx = 10, .cy = 10, .class = undefined, .text = undefined };
                if (it.object.get("id")) |v| {
                    if (v == .integer) itm.id = @intCast(v.integer);
                }
                if (it.object.get("x")) |v| {
                    if (v == .integer) itm.x = @intCast(v.integer);
                }
                if (it.object.get("y")) |v| {
                    if (v == .integer) itm.y = @intCast(v.integer);
                }
                if (it.object.get("cx")) |v| {
                    if (v == .integer) itm.cx = @intCast(v.integer);
                }
                if (it.object.get("cy")) |v| {
                    if (v == .integer) itm.cy = @intCast(v.integer);
                }
                if (it.object.get("class")) |v| {
                    if (v == .string) {
                        const n = @min(v.string.len, itm.class.len - 1);
                        @memcpy(itm.class[0..n], v.string[0..n]);
                        itm.class[n] = 0;
                    }
                }
                if (it.object.get("text")) |v| {
                    if (v == .string) {
                        const n = @min(v.string.len, itm.text.len - 1);
                        @memcpy(itm.text[0..n], v.string[0..n]);
                        itm.text[n] = 0;
                    }
                }
                item_count += 1;
            }
        }
    }

    title_buf[title_len] = 0;
    c.fltk_show_dialog(&title_buf, cx, cy);
    for (items[0..item_count]) |itm| {
        var cls_buf: [64]u8 = undefined;
        var text_buf: [512]u8 = undefined;
        const clen = @min(std.mem.len(@as([*:0]const u8, @ptrCast(&itm.class))), cls_buf.len - 1);
        @memcpy(cls_buf[0..clen], itm.class[0..clen]);
        cls_buf[clen] = 0;
        const tlen = @min(std.mem.len(@as([*:0]const u8, @ptrCast(&itm.text))), text_buf.len - 1);
        @memcpy(text_buf[0..tlen], itm.text[0..tlen]);
        text_buf[tlen] = 0;
        c.fltk_add_dialog_item(&cls_buf, itm.id, itm.x, itm.y, itm.cx, itm.cy, &text_buf);
    }
    c.fltk_finish_dialog();
}

/// Parse a show_controls JSON and place the controls into the main window.
fn processControlsJson(json: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, g_allocator, json, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;
    if (root.object.get("items")) |arr| {
        if (arr == .array) {
            for (arr.array.items) |it| {
                if (it != .object) continue;
                var id: i32 = 0;
                var x: i32 = 0;
                var y: i32 = 0;
                var cx: i32 = 40;
                var cy: i32 = 14;
                var style: u32 = 0;
                var cls: [64]u8 = undefined;
                var text: [512]u8 = undefined;
                var clen: usize = 0;
                var tlen: usize = 0;
                if (it.object.get("id")) |v| {
                    if (v == .integer) id = @intCast(v.integer);
                }
                if (it.object.get("x")) |v| {
                    if (v == .integer) x = @intCast(v.integer);
                }
                if (it.object.get("y")) |v| {
                    if (v == .integer) y = @intCast(v.integer);
                }
                if (it.object.get("cx")) |v| {
                    if (v == .integer) cx = @intCast(v.integer);
                }
                if (it.object.get("cy")) |v| {
                    if (v == .integer) cy = @intCast(v.integer);
                }
                if (it.object.get("style")) |v| {
                    if (v == .integer) style = @intCast(v.integer);
                }
                if (it.object.get("class")) |v| {
                    if (v == .string) {
                        clen = @min(v.string.len, cls.len - 1);
                        @memcpy(cls[0..clen], v.string[0..clen]);
                    }
                }
                if (it.object.get("text")) |v| {
                    if (v == .string) {
                        tlen = @min(v.string.len, text.len - 1);
                        @memcpy(text[0..tlen], v.string[0..tlen]);
                    }
                }
                cls[clen] = 0;
                text[tlen] = 0;
                c.fltk_add_control(&cls, @intCast(id), x, y, cx, cy, style, &text);
            }
        }
    }
}

/// Parse a set_icon JSON {"type":"set_icon","base64":"..."} and apply it.
fn processIconJson(json: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, g_allocator, json, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;
    const b64 = root.object.get("base64") orelse return;
    if (b64 != .string) return;

    const dec_len = std.base64.standard.Decoder.calcSizeForSlice(b64.string) catch return;
    if (dec_len > 64 * 1024) return;
    var dec_buf: [64 * 1024]u8 = undefined;
    std.base64.standard.Decoder.decode(dec_buf[0..dec_len], b64.string) catch return;
    c.fltk_set_icon(&dec_buf, @intCast(dec_len));
}

// --- Event callback from FLTK → renderer ---

fn eventCallback(event_type: c_int, param1: c_int, param2: c_int) callconv(.c) void {
    if (!build_options.use_fltk) return;

    switch (event_type) {
        c.FLTK_EVT_KEY_DOWN => {
            if (renderer.on_key_event) |cb| cb(@intCast(param1), true);
            // Update keyboard state table
            const vk: usize = @intCast(param1);
            if (vk < 256) renderer.keyboard_state[vk] = 0x80;
        },
        c.FLTK_EVT_KEY_UP => {
            if (renderer.on_key_event) |cb| cb(@intCast(param1), false);
            const vk: usize = @intCast(param1);
            if (vk < 256) renderer.keyboard_state[vk] = 0;
        },
        c.FLTK_EVT_CLOSE => {
            if (renderer.on_close) |cb| cb();
        },
        c.FLTK_EVT_RESIZE => {
            if (renderer.on_resize) |cb| cb(param1, param2, 0); // SIZE_RESTORED = 0
        },
        c.FLTK_EVT_LDOWN => {
            if (renderer.on_mouse_event) |cb| cb(0x0201, param1, param2); // WM_LBUTTONDOWN
        },
        c.FLTK_EVT_LUP => {
            if (renderer.on_mouse_event) |cb| cb(0x0202, param1, param2); // WM_LBUTTONUP
        },
        c.FLTK_EVT_RDOWN => {
            if (renderer.on_mouse_event) |cb| cb(0x0204, param1, param2); // WM_RBUTTONDOWN
        },
        c.FLTK_EVT_RUP => {
            if (renderer.on_mouse_event) |cb| cb(0x0205, param1, param2); // WM_RBUTTONUP
        },
        c.FLTK_EVT_MOVE => {
            if (renderer.on_mouse_event) |cb| cb(0x0200, param1, param2); // WM_MOUSEMOVE
        },
        c.FLTK_EVT_WHEEL => {
            if (renderer.on_wheel_event) |cb| cb(param1, 0, 0);
        },
        c.FLTK_EVT_COLOR_SEL => {
            if (renderer.on_color_selected) |cb| cb(@as(u32, @bitCast(param1)));
        },
        c.FLTK_EVT_MENU_CMD => {
            if (context_menu_open.load(.acquire)) {
                // A popup (TrackPopupMenu) is waiting — deliver the selection
                // the same way the web backend's context_menu_select does.
                // Result first: the guest only reads it after it observes
                // chosen==true via acquire.
                renderer.context_menu_result.store(@intCast(param1), .release);
                renderer.context_menu_chosen.store(true, .release);
                context_menu_open.store(false, .release);
            } else if (renderer.on_command) |cb| {
                cb(@intCast(param1));
            }
        },
        else => {},
    }
}

/// Called on the FLTK thread when the native file chooser closes.
fn fileCallback(path: [*c]const u8, cancelled: c_int) callconv(.c) void {
    if (cancelled != 0) {
        if (renderer.on_cancel_dialog) |cb| cb();
        return;
    }
    const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(path)));
    if (renderer.on_file_uploaded) |cb| {
        cb(path_slice);
    }
}

/// Called on the FLTK thread when the font chooser closes (OK or Cancel).
fn fontCallback(face: [*c]const u8, size: c_int, bold: c_int, italic: c_int, cancelled: c_int) callconv(.c) void {
    if (cancelled != 0) {
        if (renderer.on_cancel_dialog) |cb| cb();
        return;
    }
    const face_slice = std.mem.span(@as([*:0]const u8, @ptrCast(face)));
    if (renderer.on_font_chosen) |cb| {
        // Copy immediately — the comdlg stub stores the face in its own buffer.
        const owned = g_allocator.dupe(u8, face_slice) catch return;
        cb(owned, size, bold != 0, italic != 0);
    }
}

/// Called on the FLTK thread when the print dialog closes (Print or Cancel).
fn printCallback(from_page: c_int, to_page: c_int, copies: c_int, cancelled: c_int) callconv(.c) void {
    if (cancelled != 0) {
        if (renderer.on_cancel_dialog) |cb| cb();
        return;
    }
    if (renderer.on_print_chosen) |cb| cb(from_page, to_page, copies);
}

/// Called on the FLTK thread when the find/replace dialog acts.
fn findCallback(action: [*c]const u8, find_text: [*c]const u8, replace_text: [*c]const u8, match_case: c_int, search_down: c_int) callconv(.c) void {
    if (renderer.on_find_action) |cb| {
        const a = std.mem.span(@as([*:0]const u8, @ptrCast(action)));
        const f = std.mem.span(@as([*:0]const u8, @ptrCast(find_text)));
        const r = std.mem.span(@as([*:0]const u8, @ptrCast(replace_text)));
        const owned_a = g_allocator.dupe(u8, a) catch return;
        const owned_f = g_allocator.dupe(u8, f) catch return;
        const owned_r = g_allocator.dupe(u8, r) catch return;
        cb(owned_a, owned_f, owned_r, match_case != 0, search_down != 0);
    }
}

/// Called on the FLTK thread when the page-setup dialog closes (OK or Cancel).
fn pagesetupCallback(left: c_int, top: c_int, right: c_int, bottom: c_int, paper_w: c_int, paper_h: c_int, orientation: c_int, cancelled: c_int) callconv(.c) void {
    if (cancelled != 0) {
        if (renderer.on_cancel_dialog) |cb| cb();
        return;
    }
    if (renderer.on_page_setup_chosen) |cb| cb(left, top, right, bottom, paper_w, paper_h, orientation);
}

fn fltkEventLoop() void {
    if (!build_options.use_fltk) return;

    // Window was created + shown by init() on the main thread (before setupFS
    // switches FS to the guest TEB, so host TLS is intact there). This thread
    // only pumps events and drains commands.
    init_ready.store(true, .release);

    // Main event loop
    while (true) {
        // Process FLTK events (non-blocking would spin CPU, so use a brief wait)
        c.fltk_run_check();

        // Drain enqueued commands from worker thread
        drainQueue();

        // Brief sleep to avoid burning CPU (FLTK check() returns immediately)
        @import("../platform.zig").sleep(1 * std.time.ns_per_ms);
    }
}

/// Initializes the FLTK backend and spawns the single FLTK thread (window
/// creation + event loop both live there; the guest thread only enqueues
/// commands and calls the thread-safe Fl::awake()).
pub fn init(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;

    if (!build_options.use_fltk) {
        std.debug.print("\n>>> FLTK backend initialized (stub — not compiled with -Dfltk) <<<\n\n", .{});
        return;
    }

    // Initialize and show the window on THIS (main) thread. renderer.init runs
    // BEFORE setupFS in main.zig, so the main thread's FS is still real host
    // TLS here — FLTK/fontconfig initialize correctly. The spawned thread
    // only pumps events and drains commands.
    c.fltk_init(640, 480, "Zine");
    c.fltk_set_event_callback(&eventCallback);
    c.fltk_set_file_callback(&fileCallback);
    c.fltk_set_font_callback(&fontCallback);
    c.fltk_set_print_callback(&printCallback);
    c.fltk_set_find_callback(&findCallback);
    c.fltk_set_pagesetup_callback(&pagesetupCallback);
    c.fltk_set_edit_text_callback(&editTextCallback);
    c.fltk_show_window();

    const thread = try std.Thread.spawn(.{}, fltkEventLoop, .{});
    thread.detach();

    // Wait until the window is up before the guest starts running, so the
    // guest's first enqueue/Fl::awake() cannot race window creation (which
    // crashed with a NULL deref in the X11 layer).
    const platform = @import("../platform.zig");
    var spins: usize = 0;
    while (!init_ready.load(.acquire)) {
        platform.yield();
        spins += 1;
        if (spins > 10_000_000) break; // safety: don't hang forever
    }

    std.debug.print("\n>>> FLTK native GUI backend initialized <<<\n\n", .{});
}

// --- Framebuffer ---

/// Notifies the FLTK thread to redraw the framebuffer.
pub fn pushFrame() void {
    enqueue(.{ .set_framebuf = .{
        .w = renderer.global_width,
        .h = renderer.global_height,
    } });
}

// --- Window Chrome ---

/// Sets the window title.
pub fn setTitle(title: []const u8) void {
    // We need to copy the title since the caller's buffer may be reused
    const owned = g_allocator.dupe(u8, title) catch return;
    enqueue(.{ .set_title = owned });
}

/// Sets the window position and size.
pub fn setWindowPos(cx: i32, cy: i32, clientW: i32, clientH: i32) void {
    _ = cx;
    _ = cy;
    enqueue(.{ .resize_window = .{ .x = 0, .y = 0, .w = clientW, .h = clientH } });
}

/// Sets the internal rendering resolution.
pub fn setResolution(w: u32, h: u32) void {
    enqueue(.{ .set_resolution = .{ .w = w, .h = h } });
}

/// Updates the window icon from a base64-encoded string.
pub fn setIcon(json: []const u8) void {
    const owned = g_allocator.dupe(u8, json) catch return;
    enqueue(.{ .set_icon = owned });
}

// --- Menu ---

/// Configures the window menu using a JSON definition.
pub fn setMenu(json: []const u8) void {
    const owned = g_allocator.dupe(u8, json) catch return;
    enqueue(.{ .set_menu = owned });
}

/// Enables or disables a menu item by ID.
pub fn enableMenuItem(id: u32, enabled: bool) void {
    if (build_options.use_fltk) {
        c.fltk_enable_menu_item(@intCast(id), if (enabled) 1 else 0);
    }
}

/// Checks or unchecks a menu item by ID.
pub fn checkMenuItem(id: u32, checked: bool) void {
    if (build_options.use_fltk) {
        c.fltk_check_menu_item(@intCast(id), if (checked) 1 else 0);
    }
}

// --- Edit Control ---

/// Shows or hides the native edit control.
pub fn showEditControl(multiline: bool) void {
    if (build_options.use_fltk) enqueue(.{ .edit_show = .{ .multiline = multiline } });
}

/// Resizes the native edit control.
pub fn resizeEditControl(x: i32, y: i32, w: i32, h: i32) void {
    if (build_options.use_fltk) enqueue(.{ .edit_resize = .{ .x = x, .y = y, .w = w, .h = h } });
}

/// Sets the font for the native edit control.
pub fn setEditFont(_: usize, _: []const u8, _: i32, _: bool, _: bool) void {}

/// Sets the text selection in the native edit control.
pub fn setEditSelection(start: i32, end: i32) void {
    if (build_options.use_fltk) enqueue(.{ .edit_set_sel = .{ .start = start, .end = end } });
}

/// Replaces the current selection in the native edit control.
pub fn replaceEditSelection(text: []const u8) void {
    if (!build_options.use_fltk) return;
    const owned = g_allocator.dupe(u8, text) catch return;
    enqueue(.{ .edit_replace_sel = owned });
}

/// Undoes the last operation in the native edit control.
pub fn editUndo() void {
    if (build_options.use_fltk) enqueue(.edit_undo);
}

/// Scrolls the native edit control to the caret position.
pub fn editScrollCaret() void {
    if (build_options.use_fltk) enqueue(.edit_scroll_caret);
}

/// Sets the complete text content of the native edit control.
pub fn setEditText(text: []const u8) void {
    if (!build_options.use_fltk) return;
    const owned = g_allocator.dupe(u8, text) catch return;
    enqueue(.{ .edit_set_text = owned });
}

/// Called on the FLTK thread when the user types in the edit control; syncs
/// the text back into the renderer's shared buffer (the bridge suppresses
/// this for guest-driven updates).
fn editTextCallback(text: [*c]const u8) callconv(.c) void {
    if (text == null) return;
    const text_slice = std.mem.span(@as([*:0]const u8, @ptrCast(text)));
    renderer.setEditTextFromSlice(text_slice);
}

// --- Status Bar ---

/// Configures the number of parts in the status bar.
pub fn setStatusBarParts(_: usize) void {}

/// Sets the text for a specific part of the status bar.
pub fn setStatusBarText(_: usize, _: []const u8) void {}

// --- Clipboard ---

/// Copies text to the system clipboard.
pub fn setClipboard(text: []const u8) void {
    const owned = g_allocator.dupe(u8, text) catch return;
    enqueue(.{ .set_clipboard = owned });
}

// --- Context Menu ---
/// Written by the guest thread (showContextMenu), cleared by the FLTK thread
/// (eventCallback), so it must be atomic.
var context_menu_open: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Displays a context menu at the specified coordinates.
pub fn showContextMenu(x: i32, y: i32, items_json: []const u8) void {
    const owned = g_allocator.dupe(u8, items_json) catch return;
    context_menu_open.store(true, .release);
    enqueue(.{ .show_context_menu = .{ .x = x, .y = y, .json = owned } });
}

// --- Dialogs ---

/// Displays a standard message box.
pub fn showMessageBox(title: []const u8, text: []const u8) void {
    const owned_title = g_allocator.dupe(u8, title) catch return;
    const owned_text = g_allocator.dupe(u8, text) catch return;
    enqueue(.{ .show_message_box = .{ .title = owned_title, .text = owned_text } });
}

/// Shows a modal dialog with the given JSON definition.
pub fn showDialog(json: []const u8) void {
    const owned = g_allocator.dupe(u8, json) catch return;
    enqueue(.{ .show_dialog = owned });
}

/// Displays a collection of controls in the main window.
pub fn showControls(json: []const u8) void {
    const owned = g_allocator.dupe(u8, json) catch return;
    enqueue(.{ .show_controls = owned });
}

/// Adds a control (button/label/status bar/progress bar) to the window.
pub fn addControl(class: []const u8, hwnd_id: usize, x: i32, y: i32, w: i32, h: i32, style: u32, text: []const u8) void {
    const owned_class = g_allocator.dupe(u8, class) catch return;
    const owned_text = g_allocator.dupe(u8, text) catch return;
    enqueue(.{ .add_control = .{
        .class = owned_class,
        .id = hwnd_id,
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .style = style,
        .text = owned_text,
    } });
}

/// Updates the text of a specific control.
pub fn updateControlText(id: i32, text: []const u8) void {
    const owned = g_allocator.dupe(u8, text) catch return;
    enqueue(.{ .update_control_text = .{ .id = id, .text = owned } });
}

/// Updates the value (position) of a control, e.g. progress-bar fill.
pub fn updateControlValue(id: i32, value: i32) void {
    enqueue(.{ .update_control_value = .{ .id = id, .value = value } });
}

/// Updates the checked state of a checkbox/radio button control.
pub fn updateControlChecked(id: i32, checked: bool) void {
    enqueue(.{ .update_control_checked = .{ .id = id, .checked = checked } });
}

/// Opens the FLTK color chooser dialog.
pub fn openColorDialog(initial: u32) void {
    enqueue(.{ .open_color_dialog = initial });
}

/// Sets the background color of a control (0x00RRGGBB).
pub fn setControlColor(id: i32, color: u32) void {
    enqueue(.{ .set_control_color = .{ .id = id, .color = color } });
}

/// Sets the item list of a listbox control (newline-joined).
pub fn setListboxItems(id: i32, items: []const u8) void {
    const owned = g_allocator.dupe(u8, items) catch return;
    enqueue(.{ .set_listbox_items = .{ .id = id, .items = owned } });
}

/// Updates the range (min/max) of a control, e.g. progress-bar bounds.
pub fn updateControlRange(id: i32, min: i32, max: i32) void {
    enqueue(.{ .update_control_range = .{ .id = id, .min = min, .max = max } });
}

/// Opens a standard file selection dialog (FLTK native chooser).
pub fn openFileDialog(filters: ?[]const u8, is_save: bool) void {
    const owned = g_allocator.dupe(u8, filters orelse "") catch return;
    enqueue(.{ .open_file_dialog = .{ .filters = owned, .is_save = is_save } });
}

/// Opens a standard font selection dialog.
pub fn openFontDialog(face: []const u8, size: i32, bold: bool, italic: bool) void {
    const owned = g_allocator.dupe(u8, face) catch return;
    enqueue(.{ .open_font_dialog = .{ .face = owned, .size = size, .bold = bold, .italic = italic } });
}

/// Opens a host print dialog (PrintDlg).
pub fn openPrintDialog(from_page: i32, to_page: i32, min_page: i32, max_page: i32, copies: i32) void {
    if (build_options.use_fltk) {
        enqueue(.{ .open_print_dialog = .{ .from_page = from_page, .to_page = to_page, .min_page = min_page, .max_page = max_page, .copies = copies } });
    }
}

/// Opens a modeless Find/Replace dialog (FindTextA / ReplaceTextA).
pub fn openFindDialog(find_text: []const u8, replace_text: []const u8, is_replace: bool) void {
    if (!build_options.use_fltk) return;
    const owned_find = g_allocator.dupe(u8, find_text) catch return;
    const owned_repl = g_allocator.dupe(u8, replace_text) catch return;
    enqueue(.{ .open_find_dialog = .{ .find_text = owned_find, .replace_text = owned_repl, .is_replace = is_replace } });
}

/// Opens a host page-setup dialog (PageSetupDlg).
pub fn openPageSetupDialog(left: i32, top: i32, right: i32, bottom: i32, paper_w: i32, paper_h: i32, orientation: i32, units: []const u8) void {
    if (!build_options.use_fltk) return;
    const owned_units = g_allocator.dupe(u8, units) catch return;
    enqueue(.{ .open_page_setup_dialog = .{ .left = left, .top = top, .right = right, .bottom = bottom, .paper_w = paper_w, .paper_h = paper_h, .orientation = orientation, .units = owned_units } });
}

/// Closes the currently active modal dialog.
pub fn closeDialog() void {
    enqueue(.close_dialog);
}

// --- Audio ---

/// Sets the global audio playback volume.
pub fn setVolume(_: f32) void {}

/// Sets the audio format for subsequent PCM playback.
pub fn setAudioFormat(_: u32, _: u16, _: u16) void {}

/// Pushes PCM audio data to the output buffer.
pub fn pushAudio(_: []const u8) void {}
