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

// --- Input State (written by backend, read by stubs) ---
pub var keyboard_state: [256]u8 = [_]u8{0} ** 256;

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

// --- Input Callbacks (set by Win32 stubs, called by backend) ---
pub var on_command: ?*const fn (u32) void = null;
pub var on_resize: ?*const fn (i32, i32, usize) void = null;
pub var on_key_event: ?*const fn (usize, bool) void = null;
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
    switch (active_backend) {
        .web_ui => try web_ui.init(allocator),
        .fltk => try fltk_ui.init(allocator),
        .none => {},
    }
}

// --- Output: Framebuffer ---

pub fn pushFrame() void {
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
    icon_json = json;
    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .fltk => fltk_ui.setIcon(json),
        .none => {},
    }
}

pub fn setMenu(json: []const u8) void {
    dynamic_menu_json = json;
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
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch blk: {
        // Try with ../ prefix (for when cwd is inside drive_c)
        var fallback_buf: [512]u8 = undefined;
        const fallback = std.fmt.bufPrint(&fallback_buf, "../{s}", .{path}) catch break :blk null;
        break :blk std.fs.cwd().openDir(fallback, .{ .iterate = true }) catch null;
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
    var dir2 = std.fs.cwd().openDir(path, .{ .iterate = true }) catch blk: {
        var fallback_buf2: [512]u8 = undefined;
        const fallback2 = std.fmt.bufPrint(&fallback_buf2, "../{s}", .{path}) catch break :blk null;
        break :blk std.fs.cwd().openDir(fallback2, .{ .iterate = true }) catch null;
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
