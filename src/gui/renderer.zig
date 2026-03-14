const std = @import("std");
const web_ui = @import("web_ui.zig");
const fltk_ui = @import("fltk_ui.zig");

pub const Backend = enum {
    web_ui,
    fltk,
    none,
};

pub var active_backend: Backend = .web_ui;

// --- Framebuffer (shared rendering surface) ---
pub var global_framebuf: []u8 = &[_]u8{};
pub var global_width: u32 = 1;
pub var global_height: u32 = 1;
pub var resolution_set: bool = false; // True once setResolution is called with real dimensions

// --- Input State (written by backend, read by stubs) ---
pub var keyboard_state: [256]u8 = [_]u8{0} ** 256;
pub var last_mouse_x: i32 = 0;
pub var last_mouse_y: i32 = 0;
pub var mouse_buttons: [4]u8 = [_]u8{0} ** 4; // 0=left, 1=right, 2=middle, 3=x1
pub var mouse_dx: i32 = 0; // Accumulated X delta for DirectInput
pub var mouse_dy: i32 = 0; // Accumulated Y delta for DirectInput
pub var mouse_dz: i32 = 0; // Accumulated Z (wheel) delta for DirectInput

// --- Cached state for reconnecting clients (web_ui internal) ---
pub var dynamic_menu_json: ?[]const u8 = null;
pub var icon_json: ?[]const u8 = null;
pub var active_dialog: ?[]const u8 = null;
pub var last_window_pos_json: ?[]const u8 = null;
pub var last_title_json: ?[]const u8 = null;
pub var last_resolution_json: ?[]const u8 = null;
pub var last_edit_control_json: ?[]const u8 = null;
pub var last_audio_format_json: ?[]const u8 = null;
pub var last_controls_json: ?[]const u8 = null;
pub var cached_control_text_updates: std.ArrayListUnmanaged([]const u8) = .{};

var g_allocator: std.mem.Allocator = undefined;
var last_frame_time: ?i64 = null;

// --- Frame Batching ---
// Drawing operations set this flag instead of pushing frames immediately.
// Frames are flushed at EndPaint / message loop idle to avoid partial-draw artifacts.
pub var screen_dirty: bool = false;

pub fn markScreenDirty() void {
    screen_dirty = true;
}

pub fn flushScreenIfDirty() void {
    if (screen_dirty) {
        screen_dirty = false;
        pushFrame();
    }
}

// --- Input Callbacks (set by Win32 stubs, called by backend) ---
pub var on_command: ?*const fn (u32) void = null;
pub var on_resize: ?*const fn (i32, i32, usize) void = null;
pub var on_key_event: ?*const fn (usize, bool) void = null;
pub var on_mouse_event: ?*const fn (u32, i32, i32) void = null; // (msg_id, x, y)
pub var on_close: ?*const fn () void = null;
pub var on_cancel_dialog: ?*const fn () void = null;
pub var on_file_uploaded: ?*const fn ([]const u8) void = null;
pub var on_find_action: ?*const fn ([]const u8, []const u8, []const u8, bool, bool) void = null;
pub var on_context_menu_select: ?*const fn (u32) void = null;

// --- Edit text cache (synced from frontend textarea) ---
// Dynamically allocated — grows to fit any file size
pub var edit_text_data: []u8 = &[_]u8{};
pub var edit_text_data_cap: usize = 0;

pub fn editTextSlice() []const u8 {
    return edit_text_data;
}

pub fn editTextLen() usize {
    return edit_text_data.len;
}

pub fn editTextPtr() [*]const u8 {
    return edit_text_data.ptr;
}

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

// --- Clipboard buffer ---
pub var clipboard_data: []u8 = &[_]u8{};
pub var clipboard_data_cap: usize = 0;

pub fn clipboardSlice() []const u8 {
    return clipboard_data;
}

pub fn clipboardLen() usize {
    return clipboard_data.len;
}

pub fn clipboardPtr() [*]const u8 {
    return clipboard_data.ptr;
}

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

pub fn clearClipboard() void {
    clipboard_data.len = 0;
}

// --- Context menu blocking ---
pub var context_menu_chosen: bool = false;
pub var context_menu_result: u32 = 0;

// --- Lifecycle ---

pub fn init(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;
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
        .web_ui => try web_ui.init(allocator),
        .fltk => try fltk_ui.init(allocator),
        .none => {},
    }
    // Send desktop icons to the web UI
    sendDesktopIcons();
}

// --- Output: Framebuffer ---

pub fn pushFrame() void {
    // Don't push frames before the app has set real window dimensions
    if (!resolution_set) return;

    const current_time = std.time.milliTimestamp();
    if (last_frame_time) |last_time| {
        const diff = current_time - last_time;
        if (diff < 16) {
            std.Thread.sleep(@as(u64, @intCast(16 - diff)) * 1000 * 1000);
        }
    }
    last_frame_time = std.time.milliTimestamp();

    switch (active_backend) {
        .web_ui => web_ui.pushFrame(),
        .fltk => fltk_ui.pushFrame(),
        .none => {},
    }
}

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
            if (last_resolution_json) |old| g_allocator.free(old);
            last_resolution_json = g_allocator.dupe(u8, json) catch null;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setResolution(w, h),
        .none => {},
    }
}

// --- Output: Window Chrome ---

pub fn setTitle(title: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [512]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_title\",\"title\":\"{s}\"}}", .{title}) catch return;
            if (last_title_json) |old| g_allocator.free(old);
            last_title_json = g_allocator.dupe(u8, json) catch null;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setTitle(title),
        .none => {},
    }
}

pub fn setWindowPos(cx: i32, cy: i32, clientW: i32, clientH: i32) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [192]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_window_pos\",\"cx\":{d},\"cy\":{d},\"clientW\":{d},\"clientH\":{d}}}", .{ cx, cy, clientW, clientH }) catch return;
            if (last_window_pos_json) |old| g_allocator.free(old);
            last_window_pos_json = g_allocator.dupe(u8, json) catch null;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setWindowPos(cx, cy, clientW, clientH),
        .none => {},
    }
}

pub fn showEditControl(multiline: bool) void {
    switch (active_backend) {
        .web_ui => {
            const msg = if (multiline) "{\"type\":\"show_edit_control\",\"multiline\":true}" else "{\"type\":\"show_edit_control\",\"multiline\":false}";
            last_edit_control_json = msg;
            web_ui.pushMessage(msg);
        },
        .fltk => fltk_ui.showEditControl(multiline),
        .none => {},
    }
}

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

pub fn setIcon(json: []const u8) void {
    if (icon_json) |old| g_allocator.free(old);
    icon_json = g_allocator.dupe(u8, json) catch null;
    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.setIcon(json),
        .none => {},
    }
}

pub fn setMenu(json: []const u8) void {
    if (dynamic_menu_json) |old| g_allocator.free(old);
    dynamic_menu_json = g_allocator.dupe(u8, json) catch null;
    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.setMenu(json),
        .none => {},
    }
}

pub fn setEditFont(hwnd: usize, face: []const u8, pt_size: i32, bold: bool, italic: bool) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [512]u8 = undefined;
            const json = std.fmt.bufPrint(&buf,
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

pub fn setEditSelection(start: i32, end: i32) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [128]u8 = undefined;
            const json = std.fmt.bufPrint(&buf,
                "{{\"type\":\"edit_setsel\",\"start\":{d},\"end\":{d}}}",
                .{ start, end },
            ) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setEditSelection(start, end),
        .none => {},
    }
}

pub fn replaceEditSelection(text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            // Escape special chars for JSON
            var escaped_buf: [2048]u8 = undefined;
            var esc_len: usize = 0;
            for (text) |c| {
                if (esc_len + 2 > escaped_buf.len) break;
                if (c == '\n') {
                    escaped_buf[esc_len] = '\\';
                    esc_len += 1;
                    escaped_buf[esc_len] = 'n';
                    esc_len += 1;
                } else if (c == '\r') {
                    // skip CR (Windows CRLF → LF)
                } else if (c == '"') {
                    escaped_buf[esc_len] = '\\';
                    esc_len += 1;
                    escaped_buf[esc_len] = '"';
                    esc_len += 1;
                } else if (c == '\\') {
                    escaped_buf[esc_len] = '\\';
                    esc_len += 1;
                    escaped_buf[esc_len] = '\\';
                    esc_len += 1;
                } else {
                    escaped_buf[esc_len] = c;
                    esc_len += 1;
                }
            }
            const escaped = escaped_buf[0..esc_len];

            var buf: [4096]u8 = undefined;
            const json = std.fmt.bufPrint(&buf,
                "{{\"type\":\"edit_replacesel\",\"text\":\"{s}\"}}",
                .{escaped},
            ) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.replaceEditSelection(text),
        .none => {},
    }
}

pub fn editUndo() void {
    switch (active_backend) {
        .web_ui => web_ui.pushMessage("{\"type\":\"edit_undo\"}"),
        .fltk => fltk_ui.editUndo(),
        .none => {},
    }
}

pub fn editScrollCaret() void {
    switch (active_backend) {
        .web_ui => web_ui.pushMessage("{\"type\":\"edit_scrollcaret\"}"),
        .fltk => fltk_ui.editScrollCaret(),
        .none => {},
    }
}

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

pub fn setStatusBarText(part: usize, text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [512]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_statusbar_text\",\"part\":{d},\"text\":\"{s}\"}}", .{ part, text }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setStatusBarText(part, text),
        .none => {},
    }
}

// --- Clipboard ---

pub fn setClipboard(text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [4096]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_clipboard\",\"text\":\"{s}\"}}", .{text}) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setClipboard(text),
        .none => {},
    }
}

// --- Edit Text Push ---

pub fn setEditText(text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            // For large text, we can't fit in a JSON message. Send as a special binary-like message.
            var buf: [256]u8 = undefined;
            const len = text.len;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_edit_text\",\"len\":{d}}}", .{len}) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setEditText(text),
        .none => {},
    }
}

// --- Context Menu ---

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

pub fn showMessageBox(title: []const u8, text: []const u8) void {
    switch (active_backend) {
        .web_ui => {
            // Escape newlines for JSON
            var escaped_buf: [2048]u8 = undefined;
            var esc_len: usize = 0;
            for (text) |c| {
                if (esc_len + 2 > escaped_buf.len) break;
                if (c == '\n') {
                    escaped_buf[esc_len] = '\\';
                    esc_len += 1;
                    escaped_buf[esc_len] = 'n';
                    esc_len += 1;
                } else if (c == '"') {
                    escaped_buf[esc_len] = '\\';
                    esc_len += 1;
                    escaped_buf[esc_len] = '"';
                    esc_len += 1;
                } else if (c == '\\') {
                    escaped_buf[esc_len] = '\\';
                    esc_len += 1;
                    escaped_buf[esc_len] = '\\';
                    esc_len += 1;
                } else {
                    escaped_buf[esc_len] = c;
                    esc_len += 1;
                }
            }
            const escaped = escaped_buf[0..esc_len];

            var buf: [4096]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"message_box\",\"title\":\"{s}\",\"text\":\"{s}\"}}", .{ title, escaped }) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.showMessageBox(title, text),
        .none => {},
    }
}

pub fn showDialog(json: []const u8) void {
    active_dialog = g_allocator.dupe(u8, json) catch null;
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
    var buf: std.ArrayListUnmanaged(u8) = .{};
    buf.appendSlice(g_allocator, "{\"type\":\"show_controls\",") catch return;
    // Skip past the original type field: {"type": "custom_dialog",
    if (std.mem.indexOf(u8, json, ",")) |comma_pos| {
        buf.appendSlice(g_allocator, json[comma_pos + 1 ..]) catch return;
    } else {
        buf.appendSlice(g_allocator, json) catch return;
    }

    if (last_controls_json) |old| g_allocator.free(old);
    last_controls_json = g_allocator.dupe(u8, buf.items) catch null;

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
            var buf: [1024]u8 = undefined;
            const json = std.fmt.bufPrint(&buf,
                "{{\"type\":\"add_control\",\"class\":\"{s}\",\"id\":{d},\"x\":{d},\"y\":{d},\"cx\":{d},\"cy\":{d},\"style\":{d},\"text\":\"{s}\"}}",
                .{ class, hwnd_id, x, y, w, h, style, text },
            ) catch return;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.addControl(class, hwnd_id, x, y, w, h, style, text),
        .none => {},
    }
}

/// Update the text of an existing control by its dialog item ID.
pub fn updateControlText(nIDDlgItem: i32, text: []const u8) void {
    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"update_control_text\",\"id\":{d},\"text\":\"{s}\"}}", .{ nIDDlgItem, text }) catch return;
    // Cache for replay on reconnect
    const cached = g_allocator.dupe(u8, json) catch return;
    cached_control_text_updates.append(g_allocator, cached) catch {
        g_allocator.free(cached);
        return;
    };

    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.updateControlText(nIDDlgItem, text),
        .none => {},
    }
}

pub fn openFileDialog(filters: ?[]const u8, is_save: bool) void {
    switch (active_backend) {
        .web_ui => {
            var files_json: std.ArrayListUnmanaged(u8) = .{};
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

            if (active_dialog) |old| g_allocator.free(old);
            active_dialog = g_allocator.dupe(u8, files_json.items) catch null;
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
            var json: std.ArrayListUnmanaged(u8) = .{};
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

    var dir = std.fs.cwd().openDir(host_path, .{ .iterate = true }) catch blk: {
        // Fallback: try the path as-is (in case cwd is already inside drive_c)
        break :blk std.fs.cwd().openDir(path, .{ .iterate = true }) catch null;
    };

    // Folders
    json.appendSlice(g_allocator, ",\"folders\":[") catch {};
    var first_folder = true;
    if (dir) |*d| {
        var it = d.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind == .directory) {
                if (!first_folder) json.appendSlice(g_allocator, ",") catch {};
                first_folder = false;
                json.appendSlice(g_allocator, "\"") catch {};
                jsonEscapeAppend(json, entry.name);
                json.appendSlice(g_allocator, "\"") catch {};
            }
        }
        d.close();
    }
    json.appendSlice(g_allocator, "]") catch {};

    // Re-open for files (iterator is consumed)
    var dir2 = std.fs.cwd().openDir(host_path, .{ .iterate = true }) catch blk: {
        break :blk std.fs.cwd().openDir(path, .{ .iterate = true }) catch null;
    };

    // Files
    json.appendSlice(g_allocator, ",\"files\":[") catch {};
    var first_file = true;
    if (dir2) |*d2| {
        defer d2.close();
        var it2 = d2.iterate();
        while (it2.next() catch null) |entry| {
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

pub var on_font_chosen: ?*const fn ([]const u8, i32, bool, bool) void = null;

pub fn openFontDialog(face_name: []const u8, point_size: i32, bold: bool, italic: bool) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [512]u8 = undefined;
            const json = std.fmt.bufPrint(&buf,
                "{{\"type\":\"open_font_dialog\",\"face\":\"{s}\",\"size\":{d},\"bold\":{},\"italic\":{}}}",
                .{ face_name, point_size, bold, italic },
            ) catch return;
            if (active_dialog) |old| g_allocator.free(old);
            active_dialog = g_allocator.dupe(u8, json) catch null;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.openFontDialog(face_name, point_size, bold, italic),
        .none => {},
    }
}

pub fn closeDialog() void {
    active_dialog = null;
    switch (active_backend) {
        .web_ui => web_ui.pushMessage("{\"type\":\"close_dialog\"}"),
        .fltk => fltk_ui.closeDialog(),
        .none => {},
    }
}

// --- Input: Volume changed from UI ---
pub var on_volume_change: ?*const fn (f32) void = null;

// --- Output: Audio ---

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

pub fn setAudioFormat(sample_rate: u32, channels: u16, bits_per_sample: u16) void {
    switch (active_backend) {
        .web_ui => {
            var buf: [128]u8 = undefined;
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"audio_format\",\"sampleRate\":{d},\"channels\":{d},\"bitsPerSample\":{d}}}", .{ sample_rate, channels, bits_per_sample }) catch return;
            if (last_audio_format_json) |old| g_allocator.free(old);
            last_audio_format_json = g_allocator.dupe(u8, json) catch null;
            web_ui.pushMessage(json);
        },
        .fltk => fltk_ui.setAudioFormat(sample_rate, channels, bits_per_sample),
        .none => {},
    }
}

pub fn pushAudio(data: []const u8) void {
    switch (active_backend) {
        .web_ui => web_ui.pushAudio(data),
        .fltk => fltk_ui.pushAudio(data),
        .none => {},
    }
}

// --- Internal: raw message push (web_ui only, kept for web_ui.zig internal use) ---

pub fn pushMessage(json: []const u8) void {
    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => {}, // FLTK uses typed dispatch, not JSON messages
        .none => {},
    }
}

// --- Desktop Icons ---

pub var desktop_icons_json: ?[]const u8 = null;

pub fn sendDesktopIcons() void {
    if (active_backend != .web_ui) return;

    var json: std.ArrayListUnmanaged(u8) = .{};
    json.appendSlice(g_allocator, "{\"type\":\"desktop_icons\",\"items\":[") catch return;

    var dir = std.fs.cwd().openDir("drive_c/Desktop", .{ .iterate = true }) catch return;
    defer dir.close();

    var first = true;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
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
    if (desktop_icons_json) |old| g_allocator.free(old);
    desktop_icons_json = g_allocator.dupe(u8, json.items) catch null;

    web_ui.pushMessage(json.items);
    json.deinit(g_allocator);
}

/// Extract icon from a .exe file in drive_c/Desktop/ and return base64-encoded ICO data.
fn extractExeIconBase64(filename: []const u8) ?[]const u8 {
    // Build path to the exe
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "drive_c/Desktop/{s}", .{filename}) catch return null;

    // Read the file into memory
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const file_size = file.getEndPos() catch return null;
    if (file_size < 64 or file_size > 50 * 1024 * 1024) return null; // sanity check

    const file_data = g_allocator.alloc(u8, @intCast(file_size)) catch return null;
    defer g_allocator.free(file_data);
    const bytes_read = file.readAll(file_data) catch return null;
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
    var ico_buf: std.ArrayListUnmanaged(u8) = .{};
    var writer = ico_buf.writer(g_allocator);
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

    // Base64 encode
    const b64_encoder = std.base64.standard.Encoder;
    const b64_len = b64_encoder.calcSize(ico_buf.items.len);
    const b64_buf = g_allocator.alloc(u8, b64_len) catch { ico_buf.deinit(g_allocator); return null; };
    _ = b64_encoder.encode(b64_buf, ico_buf.items);
    ico_buf.deinit(g_allocator);
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
