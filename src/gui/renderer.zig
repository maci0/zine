//! Unified GUI rendering and input abstraction layer.
//!
//! This module provides a common interface for different rendering backends
//! (Web UI via WebSocket or native FLTK) and manages the shared framebuffer,
//! input state, and UI component synchronization.

const std = @import("std");
const runtime = @import("../runtime.zig");
const web_ui = @import("web_ui.zig");
const fltk_ui = @import("fltk_ui.zig");

/// Available rendering backends.
pub const Backend = enum {
    /// Web-based UI using a WebSocket server and HTML5 Canvas frontend.
    web_ui,
    /// Native UI using the Fast Light Tool Kit (FLTK).
    fltk,
    /// No GUI backend (headless mode).
    none,
};

/// The currently active rendering backend.
pub var active_backend: Backend = .web_ui;

/// Escapes a string for safe embedding in a JSON string value.
/// Handles quotes, backslashes, newlines, tabs, and control characters.
/// Returns the number of bytes written to `out`.
fn jsonEscape(text: []const u8, out: []u8) usize {
    var pos: usize = 0;
    for (text) |c| {
        if (pos + 6 > out.len) break; // worst case: \u00XX = 6 chars
        switch (c) {
            '"' => {
                out[pos] = '\\';
                out[pos + 1] = '"';
                pos += 2;
            },
            '\\' => {
                out[pos] = '\\';
                out[pos + 1] = '\\';
                pos += 2;
            },
            '\n' => {
                out[pos] = '\\';
                out[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {}, // skip CR (Windows CRLF → LF)
            '\t' => {
                out[pos] = '\\';
                out[pos + 1] = 't';
                pos += 2;
            },
            0x08 => { // backspace
                out[pos] = '\\';
                out[pos + 1] = 'b';
                pos += 2;
            },
            0x0C => { // form feed
                out[pos] = '\\';
                out[pos + 1] = 'f';
                pos += 2;
            },
            else => |byte| {
                if (byte < 0x20) {
                    // Other control characters: emit \u00XX
                    const hex = "0123456789abcdef";
                    out[pos] = '\\';
                    out[pos + 1] = 'u';
                    out[pos + 2] = '0';
                    out[pos + 3] = '0';
                    out[pos + 4] = hex[byte >> 4];
                    out[pos + 5] = hex[byte & 0x0F];
                    pos += 6;
                } else {
                    out[pos] = byte;
                    pos += 1;
                }
            },
        }
    }
    return pos;
}

// --- Framebuffer (shared rendering surface) ---

/// Shared BGRA framebuffer surface.
pub var global_framebuf: []u8 = &[_]u8{};
/// Current width of the framebuffer in pixels.
pub var global_width: u32 = 1;
/// Current height of the framebuffer in pixels.
pub var global_height: u32 = 1;
/// Whether the resolution has been explicitly set by the guest.
pub var resolution_set: bool = false; // True once setResolution is called with real dimensions

// --- Input State (written by backend, read by stubs) ---

/// Current state of the keyboard (256 keys).
pub var keyboard_state: [256]u8 = [_]u8{0} ** 256;
/// Last recorded X coordinate of the mouse.
pub var last_mouse_x: i32 = 0;
/// Last recorded Y coordinate of the mouse.
pub var last_mouse_y: i32 = 0;
/// State of mouse buttons (0=left, 1=right, 2=middle, 3=x1).
pub var mouse_buttons: [4]u8 = [_]u8{0} ** 4; // 0=left, 1=right, 2=middle, 3=x1
/// Accumulated mouse X delta (for DirectInput).
pub var mouse_dx: i32 = 0; // Accumulated X delta for DirectInput
/// Accumulated mouse Y delta (for DirectInput).
pub var mouse_dy: i32 = 0; // Accumulated Y delta for DirectInput
/// Accumulated mouse Z (wheel) delta (for DirectInput).
pub var mouse_dz: i32 = 0; // Accumulated Z (wheel) delta for DirectInput

// --- Cached state for reconnecting clients (web_ui internal) ---

/// Cached JSON representation of the current dynamic menu.
pub var dynamic_menu_json: ?[]const u8 = null;
/// Cached JSON representation of the current icon.
pub var icon_json: ?[]const u8 = null;
/// Cached JSON representation of the currently active dialog.
pub var active_dialog: ?[]const u8 = null;
/// Cached JSON representation of the last window position.
pub var last_window_pos_json: ?[]const u8 = null;
/// Cached JSON representation of the last window title.
pub var last_title_json: ?[]const u8 = null;
/// Cached JSON representation of the last set resolution.
pub var last_resolution_json: ?[]const u8 = null;
/// Cached JSON representation of the last edit control state.
pub var last_edit_control_json: ?[]const u8 = null;
/// Cached JSON representation of the last audio format.
pub var last_audio_format_json: ?[]const u8 = null;
/// Cached JSON for the color dialog, replayed to reconnecting clients.
pub var last_color_dialog_json: ?[]const u8 = null;
/// Cached JSON representation of the last controls state.
pub var last_controls_json: ?[]const u8 = null;
/// List of cached control text updates for replay.
pub var cached_control_text_updates: std.ArrayListUnmanaged([]const u8) = .empty;

var g_allocator: std.mem.Allocator = undefined;
/// True once renderer.init() ran. Console apps keep the .none backend and never
/// call init(), so g_allocator stays undefined — cache paths must skip it.
var g_allocator_ready: bool = false;
var last_frame_time: ?i64 = null;

// --- Frame Batching ---

/// Whether the screen contents have changed and need to be flushed to the backend.
pub var screen_dirty: bool = false;

/// Marks the screen as dirty, indicating a frame update is needed.
pub fn markScreenDirty() void {
    screen_dirty = true;
}

/// Flushes the framebuffer to the backend if it has been marked as dirty.
pub fn flushScreenIfDirty() void {
    if (screen_dirty) {
        screen_dirty = false;
        pushFrame();
    }
}

// --- Input Callbacks (set by Win32 stubs, called by backend) ---

/// Callback for menu or control commands (WM_COMMAND).
pub var on_command: ?*const fn (u32) void = null;
/// Callback for window resize events (WM_SIZE).
pub var on_resize: ?*const fn (i32, i32, usize) void = null;
/// Callback for keyboard events (WM_KEYDOWN/UP).
pub var on_key_event: ?*const fn (usize, bool) void = null;
/// Callback for mouse events (WM_MOUSEMOVE/LBUTTONDOWN/etc).
pub var on_mouse_event: ?*const fn (u32, i32, i32) void = null; // (msg_id, x, y)
/// Mouse wheel: (delta, x, y). Called by backends when the wheel turns.
pub var on_wheel_event: ?*const fn (i32, i32, i32) void = null;
/// Callback for window close events (WM_CLOSE).
pub var on_close: ?*const fn () void = null;
/// Callback for dialog cancellation.
pub var on_cancel_dialog: ?*const fn () void = null;
/// Callback for file upload events.
pub var on_file_uploaded: ?*const fn ([]const u8) void = null;
/// Callback for text find/replace actions.
pub var on_find_action: ?*const fn ([]const u8, []const u8, []const u8, bool, bool) void = null;
/// Callback for context menu selection.
pub var on_context_menu_select: ?*const fn (u32) void = null;
/// Callback for the color dialog result (0x00RRGGBB).
pub var on_color_selected: ?*const fn (u32) void = null;

/// Callback for listbox item selection (web/FLTK click).
pub var on_listbox_select: ?*const fn (u32, i32) void = null;

// --- Edit text cache (synced from frontend textarea) ---

/// Shared buffer for edit control text data.
pub var edit_text_data: []u8 = &[_]u8{};
/// Capacity of the edit text data buffer.
pub var edit_text_data_cap: usize = 0;

/// Returns a slice of the current edit text data.
pub fn editTextSlice() []const u8 {
    return edit_text_data;
}

/// Returns the length of the current edit text data.
pub fn editTextLen() usize {
    return edit_text_data.len;
}

/// Returns a pointer to the current edit text data.
pub fn editTextPtr() [*]const u8 {
    return edit_text_data.ptr;
}

/// Sets the edit text data from a slice, growing the buffer if necessary.
pub fn setEditTextFromSlice(text: []const u8) void {
    const needed = text.len + 1; // +1 for null terminator
    if (needed > edit_text_data_cap) {
        // Grow buffer
        const new_cap = @max(needed, edit_text_data_cap * 2);
        const new_buf = g_allocator.alloc(u8, new_cap) catch return;
        if (edit_text_data_cap > 0) g_allocator.free(edit_text_data.ptr[0..edit_text_data_cap]);
        edit_text_data.ptr = new_buf.ptr;
        edit_text_data_cap = new_cap;
    }
    @memcpy(edit_text_data.ptr[0..text.len], text);
    edit_text_data.ptr[text.len] = 0; // null terminate for C compat
    edit_text_data.len = text.len;
}

/// Handles WM_CHAR for the EDIT control: appends a character to the shared
/// edit buffer (or deletes the last code point on backspace) and pushes the
/// new text to the frontend so the native textarea stays in sync with
/// guest-driven input (SendMessage/PostMessage WM_CHAR).
pub fn editInsertChar(ch: u8) void {
    const text = editTextSlice();

    if (ch == 0x08) {
        // Backspace: drop the last UTF-8 code point. Shrink in place —
        // setEditTextFromSlice(trimmed) would alias the same buffer.
        var end = text.len;
        while (end > 0 and (text[end - 1] & 0xC0) == 0x80) end -= 1;
        if (end > 0) end -= 1;
        edit_text_data.len = end;
        edit_text_data.ptr[end] = 0;
        setEditText(edit_text_data[0..end]);
        return;
    }

    if (ch < 0x20 and ch != '\t') return; // other control chars are ignored

    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(ch, &buf) catch return;

    const old_len = edit_text_data.len;
    const needed = old_len + n + 1; // +1 null terminator
    if (needed > edit_text_data_cap) {
        const new_cap = @max(needed, edit_text_data_cap * 2);
        const new_buf = g_allocator.alloc(u8, new_cap) catch return;
        if (edit_text_data_cap > 0) {
            // Preserve existing content across the realloc.
            @memcpy(new_buf[0..old_len], edit_text_data.ptr[0..old_len]);
            g_allocator.free(edit_text_data.ptr[0..edit_text_data_cap]);
        }
        edit_text_data.ptr = new_buf.ptr;
        edit_text_data_cap = new_cap;
    }
    @memcpy(edit_text_data.ptr[old_len .. old_len + n], buf[0..n]);
    edit_text_data.ptr[old_len + n] = 0;
    edit_text_data.len = old_len + n;
    setEditText(edit_text_data[0..edit_text_data.len]);
}

// --- Clipboard buffer ---

/// Shared buffer for clipboard data.
pub var clipboard_data: []u8 = &[_]u8{};
/// Capacity of the clipboard data buffer.
pub var clipboard_data_cap: usize = 0;

/// Returns a slice of the current clipboard data.
pub fn clipboardSlice() []const u8 {
    return clipboard_data;
}

/// Returns the length of the current clipboard data.
pub fn clipboardLen() usize {
    return clipboard_data.len;
}

/// Returns a pointer to the current clipboard data.
pub fn clipboardPtr() [*]const u8 {
    return clipboard_data.ptr;
}

/// Sets the clipboard data from a slice, growing the buffer if necessary.
pub fn setClipboardFromSlice(text: []const u8) void {
    const needed = text.len + 1;
    if (needed > clipboard_data_cap) {
        const new_cap = @max(needed, clipboard_data_cap * 2);
        const new_buf = g_allocator.alloc(u8, new_cap) catch return;
        if (clipboard_data_cap > 0) g_allocator.free(clipboard_data.ptr[0..clipboard_data_cap]);
        clipboard_data.ptr = new_buf.ptr;
        clipboard_data_cap = new_cap;
    }
    @memcpy(clipboard_data.ptr[0..text.len], text);
    clipboard_data.ptr[text.len] = 0;
    clipboard_data.len = text.len;
}

/// Clears the current clipboard data.
pub fn clearClipboard() void {
    clipboard_data.len = 0;
}

// --- Context menu blocking ---

/// Whether a context menu selection has been made. Atomic: the guest thread
/// polls this while FLTK/web backend threads store the selection.
pub var context_menu_chosen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// The ID of the item chosen from the context menu.
pub var context_menu_result: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// --- Cached JSON replay state (written by guest thread, read by web clients) ---

/// Guards the cached_*_json fields and cached_control_text_updates below:
/// writers free-and-replace under this lock, web_ui's reconnect burst reads
/// under it, so a client can never observe a freed buffer.
pub var cache_mutex: runtime.Mutex = .{};

/// Replaces a cached JSON string under `cache_mutex`, freeing the old value.
/// Takes ownership of nothing; duplicates `json` first so callers keep theirs.
fn cacheReplace(field: *?[]const u8, json: []const u8) void {
    const owned = g_allocator.dupe(u8, json) catch return;
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (field.*) |old| g_allocator.free(old);
    field.* = owned;
}

/// Cap on the control-update replay cache. Control updates arrive
/// continuously (progress bars, status text, window titles); each entry is a
/// heap string kept forever, and every web-client reconnect replays the whole
/// list, so without a cap both memory and reconnect cost grow without bound.
const MAX_CACHED_CONTROL_UPDATES = 256;

/// Caches a control-update JSON for replay to (re)connecting web clients,
/// dropping the oldest entries once over the cap. Duplicates `json`; takes
/// ownership of nothing.
fn cacheControlUpdate(json: []const u8) void {
    if (!g_allocator_ready) return;
    const owned = g_allocator.dupe(u8, json) catch return;
    cache_mutex.lock();
    defer cache_mutex.unlock();
    while (cached_control_text_updates.items.len >= MAX_CACHED_CONTROL_UPDATES) {
        g_allocator.free(cached_control_text_updates.orderedRemove(0));
    }
    cached_control_text_updates.append(g_allocator, owned) catch {
        g_allocator.free(owned);
    };
}

// --- Lifecycle ---

/// Initializes the renderer and the active backend.
pub fn init(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;
    g_allocator_ready = true;
    global_framebuf = try allocator.alloc(u8, 1024 * 1024 * 4);
    // Initialize to COLOR_BTNFACE gray (0xC0C0C0) with full alpha (BGRA pixel order).
    // This ensures any unpainted areas default to the correct Win32
    // button face background color instead of black.
    var i: usize = 0;
    while (i + 3 < global_framebuf.len) : (i += 4) {
        global_framebuf[i + 0] = 0xC0; // B
        global_framebuf[i + 1] = 0xC0; // G
        global_framebuf[i + 2] = 0xC0; // R
        global_framebuf[i + 3] = 0xFF; // A
    }
    switch (active_backend) {
        .web_ui => try web_ui.init(),
        .fltk => try fltk_ui.init(allocator),
        .none => {},
    }
    // Send desktop icons to the web UI
    sendDesktopIcons();
}

// --- Output: Framebuffer ---

/// Pushes the current framebuffer to the active backend for display.
pub fn pushFrame() void {
    // Don't push frames before the app has set real window dimensions
    if (!resolution_set) return;

    // Frame pacing measures a duration: use the monotonic clock so a
    // wall-clock step cannot produce a negative or huge frame delta.
    const current_time = runtime.monoMilliTimestamp();
    if (last_frame_time) |last_time| {
        const diff = current_time - last_time;
        if (diff < 16) {
            @import("../platform.zig").sleep(@as(u64, @intCast(16 - diff)) * 1000 * 1000);
        }
    }
    last_frame_time = runtime.monoMilliTimestamp();

    switch (active_backend) {
        .web_ui => web_ui.pushFrame(),
        .fltk => fltk_ui.pushFrame(),
        .none => {},
    }
}

/// Sets the window resolution and re-initializes the framebuffer.
pub fn setResolution(w: u32, h: u32) void {
    global_width = w;
    global_height = h;
    resolution_set = true;

    // Re-initialize visible framebuffer area to gray (BGRA) when resolution
    // changes to prevent stale pixels from a previous stride causing stagger artifacts.
    const area = w * h * 4;
    if (area <= global_framebuf.len) {
        var i: usize = 0;
        while (i + 3 < area) : (i += 4) {
            global_framebuf[i + 0] = 0xC0; // B
            global_framebuf[i + 1] = 0xC0; // G
            global_framebuf[i + 2] = 0xC0; // R
            global_framebuf[i + 3] = 0xFF; // A
        }
    }

    switch (active_backend) {
        .web_ui => {
            var buf: [128]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_resolution\",\"width\":{d},\"height\":{d}}}", .{ w, h }) catch return;
            cacheReplace(&last_resolution_json, json);
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setResolution(w, h),
        .none => {},
    }
}

// --- Output: Window Chrome ---

/// Sets the title of the application window.
pub fn setTitle(title: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var escaped: [512]u8 = undefined;
            const esc_len = jsonEscape(title, &escaped);
            var buf: [1024]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_title\",\"title\":\"{s}\"}}", .{escaped[0..esc_len]}) catch return;
            cacheReplace(&last_title_json, json);
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setTitle(title),
        .none => {},
    }
}

/// Sets the window position and size.
pub fn setWindowPos(cx: i32, cy: i32, clientW: i32, clientH: i32) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [192]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_window_pos\",\"cx\":{d},\"cy\":{d},\"clientW\":{d},\"clientH\":{d}}}", .{ cx, cy, clientW, clientH }) catch return;
            cacheReplace(&last_window_pos_json, json);
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setWindowPos(cx, cy, clientW, clientH),
        .none => {},
    }
}

/// Shows the native edit control (textbox).
pub fn showEditControl(multiline: bool) void {
    switch (active_backend) {
        .web_ui => {
            const msg = if (multiline) "{\"type\":\"show_edit_control\",\"multiline\":true}" else "{\"type\":\"show_edit_control\",\"multiline\":false}";
            {
                cache_mutex.lock();
                defer cache_mutex.unlock();
                last_edit_control_json = msg;
            }
            web_ui.pushMessage(msg);
        },
        .fltk => fltk_ui.showEditControl(multiline),
        .none => {},
    }
}

/// Resizes the native edit control.
pub fn resizeEditControl(x: i32, y: i32, width: i32, height: i32) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [256]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"resize_edit_control\",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ x, y, width, height }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.resizeEditControl(x, y, width, height),
        .none => {},
    }
}

/// Sets the application icon from a JSON description.
pub fn setIcon(json: []const u8) void {
    cacheReplace(&icon_json, json);
    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.setIcon(json),
        .none => {},
    }
}

/// Sets the application menu from a JSON description.
pub fn setMenu(json: []const u8) void {
    cacheReplace(&dynamic_menu_json, json);
    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.setMenu(json),
        .none => {},
    }
}

/// Sets the font for the native edit control.
pub fn setEditFont(hwnd: usize, face: []const u8, pt_size: i32, bold: bool, italic: bool) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [512]u8 = undefined;
            const json = std.fmt.bufPrint(
                &buf,
                "{{\"type\":\"set_edit_font\",\"hwnd\":{d},\"face\":\"{s}\",\"size\":{d},\"bold\":{},\"italic\":{}}}",
                .{ hwnd, face, pt_size, bold, italic },
            ) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setEditFont(hwnd, face, pt_size, bold, italic),
        .none => {},
    }
}

// --- Edit Control Operations (EM_* message support) ---

/// Sets the text selection in the native edit control.
pub fn setEditSelection(start: i32, end: i32) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [128]u8 = undefined;
            const json = std.fmt.bufPrint(
                &buf,
                "{{\"type\":\"edit_setsel\",\"start\":{d},\"end\":{d}}}",
                .{ start, end },
            ) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setEditSelection(start, end),
        .none => {},
    }
}

/// Replaces the current selection in the native edit control with new text.
pub fn replaceEditSelection(text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var escaped_buf: [4096]u8 = undefined;
            const esc_len = jsonEscape(text, &escaped_buf);
            const escaped = escaped_buf[0..esc_len];

            var buf: [8192]u8 = undefined;
            const json = std.fmt.bufPrint(
                &buf,
                "{{\"type\":\"edit_replacesel\",\"text\":\"{s}\"}}",
                .{escaped},
            ) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.replaceEditSelection(text),
        .none => {},
    }
}

/// Triggers an undo operation in the native edit control.
pub fn editUndo() void {
    switch (active_backend) {
        .web_ui => web_ui.pushMessage("{\"type\":\"edit_undo\"}"),
        .fltk => fltk_ui.editUndo(),
        .none => {},
    }
}

/// Scrolls the native edit control to the current caret position.
pub fn editScrollCaret() void {
    switch (active_backend) {
        .web_ui => web_ui.pushMessage("{\"type\":\"edit_scrollcaret\"}"),
        .fltk => fltk_ui.editScrollCaret(),
        .none => {},
    }
}

/// Enables or disables a menu item by ID.
pub fn enableMenuItem(id: u32, enabled: bool) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [128]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"enable_menu_item\",\"id\":{d},\"enabled\":{}}}", .{ id, enabled }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.enableMenuItem(id, enabled),
        .none => {},
    }
}

/// Sets the check state of a menu item by ID.
pub fn checkMenuItem(id: u32, checked: bool) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [128]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"check_menu_item\",\"id\":{d},\"checked\":{}}}", .{ id, checked }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.checkMenuItem(id, checked),
        .none => {},
    }
}

// --- Status Bar ---

/// Sets the number of parts in the status bar.
pub fn setStatusBarParts(count: usize) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [64]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_statusbar_parts\",\"count\":{d}}}", .{count}) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setStatusBarParts(count),
        .none => {},
    }
}

/// Sets the text for a specific part of the status bar.
pub fn setStatusBarText(part: usize, text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var escaped: [512]u8 = undefined;
            const esc_len = jsonEscape(text, &escaped);
            var buf: [1024]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_statusbar_text\",\"part\":{d},\"text\":\"{s}\"}}", .{ part, escaped[0..esc_len] }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setStatusBarText(part, text),
        .none => {},
    }
}

// --- Clipboard ---

/// Sets the system clipboard text.
pub fn setClipboard(text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var escaped: [4096]u8 = undefined;
            const esc_len = jsonEscape(text, &escaped);
            var buf: [8192]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_clipboard\",\"text\":\"{s}\"}}", .{escaped[0..esc_len]}) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setClipboard(text),
        .none => {},
    }
}

// --- Edit Text Push ---

/// Sets the full text content of the native edit control.
pub fn setEditText(text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var escaped_buf: [8192]u8 = undefined;
            const esc_len = jsonEscape(text, &escaped_buf);
            const escaped = escaped_buf[0..esc_len];

            var buf: [16384]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_edit_text\",\"len\":{d},\"text\":\"{s}\"}}", .{ text.len, escaped }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setEditText(text),
        .none => {},
    }
}

// --- Context Menu ---

/// Displays a context menu at the specified coordinates.
pub fn showContextMenu(x: i32, y: i32, items_json: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [4096]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"show_context_menu\",\"x\":{d},\"y\":{d},\"items\":{s}}}", .{ x, y, items_json }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.showContextMenu(x, y, items_json),
        .none => {},
    }
}

// --- Output: Dialogs ---

/// Displays a standard message box.
pub fn showMessageBox(title: []const u8, text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var escaped_buf: [4096]u8 = undefined;
            const esc_len = jsonEscape(text, &escaped_buf);
            const escaped = escaped_buf[0..esc_len];

            var title_escaped: [512]u8 = undefined;
            const title_esc_len = jsonEscape(title, &title_escaped);

            var buf: [8192]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"message_box\",\"title\":\"{s}\",\"text\":\"{s}\"}}", .{ title_escaped[0..title_esc_len], escaped }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.showMessageBox(title, text),
        .none => {},
    }
}

/// Displays a dialog from a JSON description.
pub fn showDialog(json: []const u8) void {
    cacheReplace(&active_dialog, json);
    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.showDialog(json),
        .none => {},
    }
}

/// Send dialog controls to be rendered in-place in the game container (not as a modal popup).
/// The JSON is a custom_dialog-format object but sent with type "show_controls".
pub fn showControls(json: []const u8) void {
    // Rewrite the type field from "custom_dialog" to "show_controls"
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(g_allocator, "{\"type\":\"show_controls\",") catch return;
    // Skip past the original type field: {"type": "custom_dialog",
    if (std.mem.indexOf(u8, json, ",")) |comma_pos| {
        buf.appendSlice(g_allocator, json[comma_pos + 1 ..]) catch return;
    } else {
        buf.appendSlice(g_allocator, json) catch return;
    }

    cacheReplace(&last_controls_json, buf.items);

    switch (active_backend) {
        .web_ui => web_ui.pushMessage(buf.items),
        .fltk => fltk_ui.showControls(buf.items),
        .none => {},
    }
    buf.deinit(g_allocator);
}

/// Add a single child control to the in-place controls container.
pub fn addControl(class: []const u8, hwnd_id: usize, x: i32, y: i32, w: i32, h: i32, style: u32, text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var escaped: [512]u8 = undefined;
            const esc_len = jsonEscape(text, &escaped);
            var buf: [2048]u8 = undefined;
            const json = std.fmt.bufPrint(
                &buf,
                "{{\"type\":\"add_control\",\"class\":\"{s}\",\"id\":{d},\"x\":{d},\"y\":{d},\"cx\":{d},\"cy\":{d},\"style\":{d},\"text\":\"{s}\"}}",
                .{ class, hwnd_id, x, y, w, h, style, escaped[0..esc_len] },
            ) catch return;
            web_ui.pushMessage(json);
            // Cache for reconnect: like resolution/title, controls created before
            // a client connects would otherwise never reach the browser.
            cacheControlUpdate(json);
        },
        .fltk => fltk_ui.addControl(class, hwnd_id, x, y, w, h, style, text),
        .none => {},
    }
}

/// Update the text of an existing control by its dialog item ID.
pub fn updateControlText(nIDDlgItem: i32, text: []const u8) void {
    var escaped: [512]u8 = undefined;
    const esc_len = jsonEscape(text, &escaped);
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"update_control_text\",\"id\":{d},\"text\":\"{s}\"}}", .{ nIDDlgItem, escaped[0..esc_len] }) catch return;
    // Cache for replay on reconnect (only when the renderer allocator is live —
    // console apps keep backend .none and never call init()).
    cacheControlUpdate(json);

    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.updateControlText(nIDDlgItem, text),
        .none => {},
    }
}

/// Update the value (position) of a control, e.g. progress-bar fill.
/// Sets the background color of a control (from WM_CTLCOLOR). Color is
/// 0x00RRGGBB; 0xFFFFFFFF means "use the default".
pub fn updateControlColor(nIDDlgItem: i32, color: u32) void {
    if (color == 0xFFFFFFFF) return;
    switch (active_backend) {
        .web_ui => {
            var buf: [256]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_control_color\",\"id\":{d},\"color\":{d}}}", .{ nIDDlgItem, color }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setControlColor(nIDDlgItem, color),
        .none => {},
    }
}

/// Opens the host color chooser dialog (ChooseColor).
pub fn openColorDialog(initial: u32) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [128]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"show_color_dialog\",\"initial\":{d}}}", .{initial}) catch return;
            cacheReplace(&last_color_dialog_json, json);
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.openColorDialog(initial),
        .none => {},
    }
}

/// Pushes the item list of a listbox control to the backend. `items` is a
/// newline-joined string (one item per line).
pub fn setControlItems(nIDDlgItem: i32, items: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            // JSON-escape and send as an array of strings.
            var esc: [8192]u8 = undefined;
            const esc_len = jsonEscape(items, &esc);
            var buf: [16384]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_listbox_items\",\"id\":{d},\"items\":\"{s}\"}}", .{ nIDDlgItem, esc[0..esc_len] }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setListboxItems(nIDDlgItem, items),
        .none => {},
    }
}

/// Updates the checked state of a checkbox/radio button control.
pub fn updateControlChecked(nIDDlgItem: i32, checked: bool) void {
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_control_checked\",\"id\":{d},\"checked\":{}}}", .{ nIDDlgItem, checked }) catch return;
    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.updateControlChecked(nIDDlgItem, checked),
        .none => {},
    }
}

pub fn updateControlValue(nIDDlgItem: i32, value: i32) void {
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"update_control_value\",\"id\":{d},\"value\":{d}}}", .{ nIDDlgItem, value }) catch return;
    cacheControlUpdate(json);

    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.updateControlValue(nIDDlgItem, value),
        .none => {},
    }
}

/// Update the range (min/max) of a control, e.g. progress-bar bounds.
pub fn updateControlRange(nIDDlgItem: i32, min: i32, max: i32) void {
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"update_control_range\",\"id\":{d},\"min\":{d},\"max\":{d}}}", .{ nIDDlgItem, min, max }) catch return;
    cacheControlUpdate(json);

    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.updateControlRange(nIDDlgItem, min, max),
        .none => {},
    }
}

/// Opens a file selection dialog.
pub fn openFileDialog(filters: ?[]const u8, is_save: bool) void {
    switch (active_backend) {
        .web_ui => {
            var files_json: std.ArrayListUnmanaged(u8) = .empty;
            defer files_json.deinit(g_allocator);

            files_json.appendSlice(g_allocator, "{\"type\":\"open_file_dialog\"") catch {};
            if (is_save) {
                files_json.appendSlice(g_allocator, ",\"mode\":\"save\"") catch {};
            }

            // List both files and folders in the Desktop directory
            appendDirectoryListing(&files_json, "Desktop");

            if (filters) |f| {
                files_json.appendSlice(g_allocator, ",\"filters\":") catch {};
                files_json.appendSlice(g_allocator, f) catch {};
            }

            files_json.appendSlice(g_allocator, ",\"path\":\"Desktop\"") catch {};
            files_json.appendSlice(g_allocator, "}") catch {};

            cacheReplace(&active_dialog, files_json.items);
            web_ui.pushMessage(files_json.items);
        },
        .fltk => fltk_ui.openFileDialog(filters, is_save),
        .none => {},
    }
}

/// List directory contents and send as a directory_listing message.
/// Called by web_ui when the client sends a browse_directory request.
pub fn listDirectory(path: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var json: std.ArrayListUnmanaged(u8) = .empty;
            defer json.deinit(g_allocator);

            json.appendSlice(g_allocator, "{\"type\":\"directory_listing\"") catch {};

            // Include the path in the response
            json.appendSlice(g_allocator, ",\"path\":\"") catch {};
            json.appendSlice(g_allocator, path) catch {};
            json.appendSlice(g_allocator, "\"") catch {};

            appendDirectoryListing(&json, path);

            json.appendSlice(g_allocator, "}") catch {};
            web_ui.pushMessage(json.items);
        },
        .fltk => {},
        .none => {},
    }
}

/// Helper: append ",\"folders\":[...],\"files\":[...]" to a JSON builder
/// by iterating the given path relative to cwd.
fn appendDirectoryListing(json: *std.ArrayListUnmanaged(u8), path: []const u8) void {
    // The path is a logical Win32 path (e.g. "Desktop", "Desktop/subfolder").
    // Map it to the host filesystem under drive_c/.
    var host_path_buf: [512]u8 = undefined;
    const host_path = std.fmt.bufPrint(&host_path_buf, "drive_c/{s}", .{path}) catch path;

    var dir = std.Io.Dir.cwd().openDir(runtime.io(), host_path, .{ .iterate = true }) catch blk: {
        // Fallback: try the path as-is (in case cwd is already inside drive_c)
        break :blk std.Io.Dir.cwd().openDir(runtime.io(), path, .{ .iterate = true }) catch null;
    };

    // Folders
    json.appendSlice(g_allocator, ",\"folders\":[") catch {};
    var first_folder = true;
    if (dir) |*d| {
        var it = d.iterate();
        while (it.next(runtime.io()) catch null) |entry| {
            if (entry.kind == .directory) {
                if (!first_folder) json.appendSlice(g_allocator, ",") catch {};
                first_folder = false;
                json.appendSlice(g_allocator, "\"") catch {};
                jsonEscapeAppend(json, entry.name);
                json.appendSlice(g_allocator, "\"") catch {};
            }
        }
        d.close(runtime.io());
    }
    json.appendSlice(g_allocator, "]") catch {};

    // Re-open for files (iterator is consumed)
    var dir2 = std.Io.Dir.cwd().openDir(runtime.io(), host_path, .{ .iterate = true }) catch blk: {
        break :blk std.Io.Dir.cwd().openDir(runtime.io(), path, .{ .iterate = true }) catch null;
    };

    // Files
    json.appendSlice(g_allocator, ",\"files\":[") catch {};
    var first_file = true;
    if (dir2) |*d2| {
        defer d2.close(runtime.io());
        var it2 = d2.iterate();
        while (it2.next(runtime.io()) catch null) |entry| {
            if (entry.kind == .file) {
                if (!first_file) json.appendSlice(g_allocator, ",") catch {};
                first_file = false;
                json.appendSlice(g_allocator, "\"") catch {};
                jsonEscapeAppend(json, entry.name);
                json.appendSlice(g_allocator, "\"") catch {};
            }
        }
    }
    json.appendSlice(g_allocator, "]") catch {};
}

/// Append a string to the JSON builder, escaping special JSON characters.
fn jsonEscapeAppend(json: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    for (s) |c| {
        if (c == '"') {
            json.appendSlice(g_allocator, "\\\"") catch {};
        } else if (c == '\\') {
            json.appendSlice(g_allocator, "\\\\") catch {};
        } else {
            json.append(g_allocator, c) catch {};
        }
    }
}

/// Callback for when a font is chosen in the font dialog.
pub var on_font_chosen: ?*const fn ([]const u8, i32, bool, bool) void = null;

/// Callback for when a print dialog is confirmed: (from_page, to_page, copies).
pub var on_print_chosen: ?*const fn (i32, i32, i32) void = null;

/// Callback for when a page-setup dialog is confirmed:
/// (left, top, right, bottom, paper_w, paper_h, orientation) — margins and
/// paper size in the dialog's units; orientation 0 = portrait, 1 = landscape.
pub var on_page_setup_chosen: ?*const fn (i32, i32, i32, i32, i32, i32, i32) void = null;

/// Opens a font selection dialog.
pub fn openFontDialog(face_name: []const u8, point_size: i32, bold: bool, italic: bool) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [512]u8 = undefined;
            const json = std.fmt.bufPrint(
                &buf,
                "{{\"type\":\"open_font_dialog\",\"face\":\"{s}\",\"size\":{d},\"bold\":{},\"italic\":{}}}",
                .{ face_name, point_size, bold, italic },
            ) catch return;
            cacheReplace(&active_dialog, json);
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.openFontDialog(face_name, point_size, bold, italic),
        .none => {},
    }
}

/// Opens a host print dialog (PrintDlg) with the caller's page range + copies.
pub fn openPrintDialog(from_page: i32, to_page: i32, min_page: i32, max_page: i32, copies: i32) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [256]u8 = undefined;
            const json = std.fmt.bufPrint(
                &buf,
                "{{\"type\":\"show_print_dialog\",\"from\":{d},\"to\":{d},\"min\":{d},\"max\":{d},\"copies\":{d}}}",
                .{ from_page, to_page, min_page, max_page, copies },
            ) catch return;
            cacheReplace(&active_dialog, json);
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.openPrintDialog(from_page, to_page, min_page, max_page, copies),
        .none => {},
    }
}

/// Opens a modeless Find/Replace dialog (FindTextA / ReplaceTextA).
pub fn openFindDialog(find_text: []const u8, replace_text: []const u8, is_replace: bool) void {
    switch (active_backend) {
        .web_ui => {
            var esc_find: [512]u8 = undefined;
            const f_len = jsonEscape(find_text, &esc_find);
            var esc_repl: [512]u8 = undefined;
            const r_len = jsonEscape(replace_text, &esc_repl);
            var buf: [1536]u8 = undefined;
            const json = std.fmt.bufPrint(
                &buf,
                "{{\"type\":\"open_find_dialog\",\"mode\":\"{s}\",\"findText\":\"{s}\",\"replaceText\":\"{s}\"}}",
                .{ if (is_replace) "replace" else "find", esc_find[0..f_len], esc_repl[0..r_len] },
            ) catch return;
            cacheReplace(&active_dialog, json);
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.openFindDialog(find_text, replace_text, is_replace),
        .none => {},
    }
}

/// Opens a host page-setup dialog (PageSetupDlg). Margins/paper in the
/// caller's units (thousandths of an inch by default); orientation 0 =
/// portrait, 1 = landscape.
pub fn openPageSetupDialog(left: i32, top: i32, right: i32, bottom: i32, paper_w: i32, paper_h: i32, orientation: i32, units_label: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var esc_label: [64]u8 = undefined;
            const l_len = jsonEscape(units_label, &esc_label);
            var buf: [512]u8 = undefined;
            const json = std.fmt.bufPrint(
                &buf,
                "{{\"type\":\"show_page_setup_dialog\",\"left\":{d},\"top\":{d},\"right\":{d},\"bottom\":{d},\"paperW\":{d},\"paperH\":{d},\"orientation\":{d},\"units\":\"{s}\"}}",
                .{ left, top, right, bottom, paper_w, paper_h, orientation, esc_label[0..l_len] },
            ) catch return;
            cacheReplace(&active_dialog, json);
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.openPageSetupDialog(left, top, right, bottom, paper_w, paper_h, orientation, units_label),
        .none => {},
    }
}

/// Closes the currently active dialog.
pub fn closeDialog() void {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    active_dialog = null;
    switch (active_backend) {
        .web_ui => web_ui.pushMessage("{\"type\":\"close_dialog\"}"),
        .fltk => fltk_ui.closeDialog(),
        .none => {},
    }
}

// --- Input: Volume changed from UI ---

/// Callback for when the audio volume is changed via the UI.
pub var on_volume_change: ?*const fn (f32) void = null;

// --- Output: Audio ---

/// Sets the master audio volume (0.0 to 1.0).
pub fn setVolume(linear: f32) void {
    const clamped = std.math.clamp(linear, 0.0, 1.0);
    switch (active_backend) {
        .web_ui => {
            const vol_int: u32 = @intFromFloat(clamped * 100.0);
            var buf: [64]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_volume\",\"volume\":{d}}}", .{vol_int}) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setVolume(clamped),
        .none => {},
    }
}

/// Sets the output audio format.
pub fn setAudioFormat(sample_rate: u32, channels: u16, bits_per_sample: u16) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [128]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"audio_format\",\"sampleRate\":{d},\"channels\":{d},\"bitsPerSample\":{d}}}", .{ sample_rate, channels, bits_per_sample }) catch return;
            cacheReplace(&last_audio_format_json, json);
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setAudioFormat(sample_rate, channels, bits_per_sample),
        .none => {},
    }
}

/// Pushes raw PCM audio data to the active backend for playback.
pub fn pushAudio(data: []const u8) void {
    switch (active_backend) {
        .web_ui => web_ui.pushAudio(data),
        .fltk => fltk_ui.pushAudio(data),
        .none => {},
    }
}

// --- Internal: raw message push (web_ui only, kept for web_ui.zig internal use) ---

/// Pushes a raw JSON message to the web UI backend.
pub fn pushMessage(json: []const u8) void {
    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => {}, // FLTK uses typed dispatch, not JSON messages
        .none => {},
    }
}

// --- Desktop Icons ---

/// Cached JSON representation of desktop icons.
pub var desktop_icons_json: ?[]const u8 = null;

/// Scans the Desktop directory and sends icon metadata to the web UI.
pub fn sendDesktopIcons() void {
    if (active_backend != .web_ui) return;

    var json: std.ArrayListUnmanaged(u8) = .empty;
    json.appendSlice(g_allocator, "{\"type\":\"desktop_icons\",\"items\":[") catch return;

    var dir = std.Io.Dir.cwd().openDir(runtime.io(), "drive_c/Desktop", .{ .iterate = true }) catch return;
    defer dir.close(runtime.io());

    var first = true;
    var it = dir.iterate();
    while (it.next(runtime.io()) catch null) |entry| {
        // Skip hidden files
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        if (!first) json.appendSlice(g_allocator, ",") catch {};
        first = false;

        json.appendSlice(g_allocator, "{\"name\":\"") catch {};
        jsonEscapeAppend(&json, entry.name);
        json.appendSlice(g_allocator, "\",\"is_dir\":") catch {};
        json.appendSlice(g_allocator, if (entry.kind == .directory) "true" else "false") catch {};

        // Extract extension
        const ext = blk: {
            var i = entry.name.len;
            while (i > 0) {
                i -= 1;
                if (entry.name[i] == '.') break :blk entry.name[i + 1 ..];
            }
            break :blk "";
        };
        json.appendSlice(g_allocator, ",\"ext\":\"") catch {};
        jsonEscapeAppend(&json, ext);
        json.appendSlice(g_allocator, "\"") catch {};

        // For .exe files, try to extract icon from PE resources
        if (entry.kind == .file and ext.len >= 3 and
            (ext[0] == 'e' or ext[0] == 'E') and
            (ext[1] == 'x' or ext[1] == 'X') and
            (ext[2] == 'e' or ext[2] == 'E'))
        {
            if (extractExeIconBase64(entry.name)) |icon_b64| {
                json.appendSlice(g_allocator, ",\"icon\":\"") catch {};
                json.appendSlice(g_allocator, icon_b64) catch {};
                json.appendSlice(g_allocator, "\"") catch {};
                g_allocator.free(icon_b64);
            }
        }

        json.appendSlice(g_allocator, "}") catch {};
    }

    json.appendSlice(g_allocator, "]}") catch {};

    // Cache for reconnecting clients
    cacheReplace(&desktop_icons_json, json.items);

    web_ui.pushMessage(json.items);
    json.deinit(g_allocator);
}

/// Extract icon from a .exe file in drive_c/Desktop/ and return base64-encoded ICO data.
fn extractExeIconBase64(filename: []const u8) ?[]const u8 {
    // Build path to the exe
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "drive_c/Desktop/{s}", .{filename}) catch return null;

    // Read the file into memory
    const file = std.Io.Dir.cwd().openFile(runtime.io(), path, .{}) catch return null;
    defer file.close(runtime.io());

    const file_size = file.length(runtime.io()) catch return null;
    if (file_size < 64 or file_size > 50 * 1024 * 1024) return null; // sanity check

    const file_data = g_allocator.alloc(u8, @intCast(file_size)) catch return null;
    defer g_allocator.free(file_data);
    const bytes_read = file.readPositionalAll(runtime.io(), file_data, 0) catch return null;
    if (bytes_read < 64) return null;

    // Parse PE to find icon resources
    return extractIconFromPEData(file_data[0..bytes_read]);
}

/// Parse PE data in memory and extract the first icon group as a base64-encoded .ICO file.
fn extractIconFromPEData(data: []const u8) ?[]const u8 {
    if (data.len < 64) return null;

    // Check MZ signature
    if (data[0] != 'M' or data[1] != 'Z') return null;

    // Get PE offset
    const pe_offset = std.mem.readInt(u32, data[0x3C..0x40], .little);
    if (pe_offset + 4 > data.len) return null;

    // Check PE signature
    if (data[pe_offset] != 'P' or data[pe_offset + 1] != 'E' or data[pe_offset + 2] != 0 or data[pe_offset + 3] != 0) return null;

    // COFF header
    const coff_start = pe_offset + 4;
    if (coff_start + 20 > data.len) return null;
    const num_sections = std.mem.readInt(u16, data[coff_start + 2 ..][0..2], .little);
    const optional_header_size = std.mem.readInt(u16, data[coff_start + 16 ..][0..2], .little);

    // Optional header
    const opt_start = coff_start + 20;
    if (opt_start + optional_header_size > data.len) return null;

    // Data directories start at offset 96 in PE32 optional header
    const data_dir_start = opt_start + 96;
    // Resource table is data directory index 2
    const rsrc_rva_offset = data_dir_start + 2 * 8;
    if (rsrc_rva_offset + 8 > data.len) return null;
    const rsrc_rva = std.mem.readInt(u32, data[rsrc_rva_offset..][0..4], .little);
    const rsrc_size = std.mem.readInt(u32, data[rsrc_rva_offset + 4 ..][0..4], .little);
    if (rsrc_rva == 0 or rsrc_size == 0) return null;

    // Find the section containing the resource RVA
    const section_start = opt_start + optional_header_size;
    var rsrc_file_offset: u32 = 0;

    for (0..num_sections) |i| {
        const s = section_start + i * 40;
        if (s + 40 > data.len) break;
        const s_rva = std.mem.readInt(u32, data[s + 12 ..][0..4], .little);
        const s_size = std.mem.readInt(u32, data[s + 8 ..][0..4], .little);
        const s_raw = std.mem.readInt(u32, data[s + 20 ..][0..4], .little);
        if (rsrc_rva >= s_rva and rsrc_rva < s_rva + s_size) {
            rsrc_file_offset = s_raw + (rsrc_rva - s_rva);
            break;
        }
    }
    if (rsrc_file_offset == 0) return null;

    // Now parse the resource directory tree to find RT_GROUP_ICON (type 14)
    return parseResourceDirForIcon(data, rsrc_file_offset, rsrc_rva);
}

fn parseResourceDirForIcon(data: []const u8, rsrc_offset: u32, rsrc_rva: u32) ?[]const u8 {
    if (rsrc_offset + 16 > data.len) return null;

    const num_named = std.mem.readInt(u16, data[rsrc_offset + 12 ..][0..2], .little);
    const num_id = std.mem.readInt(u16, data[rsrc_offset + 14 ..][0..2], .little);

    var entry_offset = rsrc_offset + 16;

    // Skip named entries, then look for RT_GROUP_ICON (14) and RT_ICON (3)
    entry_offset += @as(u32, num_named) * 8;

    var group_icon_offset: u32 = 0;
    var icon_dir_offset: u32 = 0;

    for (0..num_id) |_| {
        if (entry_offset + 8 > data.len) break;
        const id = std.mem.readInt(u32, data[entry_offset..][0..4], .little);
        const offset_or_dir = std.mem.readInt(u32, data[entry_offset + 4 ..][0..4], .little);

        if (id == 14) { // RT_GROUP_ICON
            group_icon_offset = rsrc_offset + (offset_or_dir & 0x7FFFFFFF);
        } else if (id == 3) { // RT_ICON
            icon_dir_offset = rsrc_offset + (offset_or_dir & 0x7FFFFFFF);
        }
        entry_offset += 8;
    }

    if (group_icon_offset == 0) return null;

    // Navigate: type dir → first name/id → first language → data entry
    const group_data = getFirstResourceData(data, group_icon_offset, rsrc_offset, rsrc_rva) orelse return null;

    // Parse GROUP_ICON header
    if (group_data.len < 20) return null;
    const id_type = std.mem.readInt(u16, group_data[2..4], .little);
    if (id_type != 1) return null;

    // Get first icon entry
    const bWidth = group_data[6];
    const bHeight = group_data[7];
    const bColorCount = group_data[8];
    const bReserved = group_data[9];
    const wPlanes = std.mem.readInt(u16, group_data[10..12], .little);
    const wBitCount = std.mem.readInt(u16, group_data[12..14], .little);
    const dwBytesInRes = std.mem.readInt(u32, group_data[14..18], .little);
    const nId = std.mem.readInt(u16, group_data[18..20], .little);

    // Now find the RT_ICON data for this nId
    if (icon_dir_offset == 0) return null;
    const icon_data = getResourceDataById(data, icon_dir_offset, rsrc_offset, rsrc_rva, nId) orelse return null;
    _ = dwBytesInRes;

    // Build ICO file
    var aw: std.Io.Writer.Allocating = .init(g_allocator);
    defer aw.deinit();
    const writer = &aw.writer;
    writer.writeInt(u16, 0, .little) catch return null;
    writer.writeInt(u16, 1, .little) catch return null;
    writer.writeInt(u16, 1, .little) catch return null;
    writer.writeByte(bWidth) catch return null;
    writer.writeByte(bHeight) catch return null;
    writer.writeByte(bColorCount) catch return null;
    writer.writeByte(bReserved) catch return null;
    writer.writeInt(u16, wPlanes, .little) catch return null;
    writer.writeInt(u16, wBitCount, .little) catch return null;
    writer.writeInt(u32, @intCast(icon_data.len), .little) catch return null;
    writer.writeInt(u32, 22, .little) catch return null; // data offset
    writer.writeAll(icon_data) catch return null;

    const ico_bytes = writer.buffer[0..writer.end];

    // Base64 encode
    const b64_encoder = std.base64.standard.Encoder;
    const b64_len = b64_encoder.calcSize(ico_bytes.len);
    const b64_buf = g_allocator.alloc(u8, b64_len) catch return null;
    _ = b64_encoder.encode(b64_buf, ico_bytes);
    return b64_buf;
}

/// Navigate a resource directory (type → first ID → first language) to get data
fn getFirstResourceData(data: []const u8, dir_offset: u32, rsrc_base: u32, rsrc_rva: u32) ?[]const u8 {
    if (dir_offset + 16 > data.len) return null;
    const num_named = std.mem.readInt(u16, data[dir_offset + 12 ..][0..2], .little);
    const num_id = std.mem.readInt(u16, data[dir_offset + 14 ..][0..2], .little);
    const total = @as(u32, num_named) + @as(u32, num_id);
    if (total == 0) return null;

    // Take first entry
    const first_entry = dir_offset + 16;
    if (first_entry + 8 > data.len) return null;
    const sub_offset = std.mem.readInt(u32, data[first_entry + 4 ..][0..4], .little);

    if ((sub_offset & 0x80000000) != 0) {
        // It's a subdirectory — recurse one more level
        const sub_dir = rsrc_base + (sub_offset & 0x7FFFFFFF);
        return getFirstResourceData(data, sub_dir, rsrc_base, rsrc_rva);
    } else {
        // It's a data entry
        const data_entry = rsrc_base + sub_offset;
        if (data_entry + 16 > data.len) return null;
        const data_rva = std.mem.readInt(u32, data[data_entry..][0..4], .little);
        const data_size = std.mem.readInt(u32, data[data_entry + 4 ..][0..4], .little);
        const file_offset = data_rva - rsrc_rva + rsrc_base;
        if (file_offset + data_size > data.len) return null;
        return data[file_offset..][0..data_size];
    }
}

/// Find a specific resource ID in a resource directory and return its data
fn getResourceDataById(data: []const u8, dir_offset: u32, rsrc_base: u32, rsrc_rva: u32, target_id: u16) ?[]const u8 {
    if (dir_offset + 16 > data.len) return null;
    const num_named = std.mem.readInt(u16, data[dir_offset + 12 ..][0..2], .little);
    const num_id = std.mem.readInt(u16, data[dir_offset + 14 ..][0..2], .little);

    var entry = dir_offset + 16 + @as(u32, num_named) * 8;
    for (0..num_id) |_| {
        if (entry + 8 > data.len) break;
        const id = std.mem.readInt(u32, data[entry..][0..4], .little);
        const sub_offset = std.mem.readInt(u32, data[entry + 4 ..][0..4], .little);

        if (id == target_id) {
            if ((sub_offset & 0x80000000) != 0) {
                const sub_dir = rsrc_base + (sub_offset & 0x7FFFFFFF);
                return getFirstResourceData(data, sub_dir, rsrc_base, rsrc_rva);
            } else {
                const data_entry = rsrc_base + sub_offset;
                if (data_entry + 16 > data.len) return null;
                const data_rva = std.mem.readInt(u32, data[data_entry..][0..4], .little);
                const data_size = std.mem.readInt(u32, data[data_entry + 4 ..][0..4], .little);
                const file_offset = data_rva - rsrc_rva + rsrc_base;
                if (file_offset + data_size > data.len) return null;
                return data[file_offset..][0..data_size];
            }
        }
        entry += 8;
    }
    return null;
}
