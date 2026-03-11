const std = @import("std");
const web_ui = @import("web_ui.zig");

pub const Backend = enum {
    web_ui,
    none,
};

pub var active_backend: Backend = .web_ui;

// --- Framebuffer (shared rendering surface) ---
pub var global_framebuf: []u8 = &[_]u8{};
pub var global_width: u32 = 1;
pub var global_height: u32 = 1;

// --- Input State (written by backend, read by stubs) ---
pub var keyboard_state: [256]u8 = [_]u8{0} ** 256;

// --- Cached state for reconnecting clients (internal) ---
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

// --- Lifecycle ---

pub fn init(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;
    global_framebuf = try allocator.alloc(u8, 1024 * 1024 * 4);
    switch (active_backend) {
        .web_ui => try web_ui.init(allocator),
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
        .none => {},
    }
}

pub fn setResolution(w: u32, h: u32) void {
    global_width = w;
    global_height = h;
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_resolution\",\"width\":{d},\"height\":{d}}}", .{ w, h }) catch return;
    
    if (last_resolution_json) |old| {
        g_allocator.free(old);
    }
    last_resolution_json = g_allocator.dupe(u8, json) catch null;
    
    pushMessage(json);
}

// --- Output: Window Chrome ---

pub fn setTitle(title: []const u8) void {
    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_title\",\"title\":\"{s}\"}}", .{title}) catch return;

    if (last_title_json) |old| {
        g_allocator.free(old);
    }
    last_title_json = g_allocator.dupe(u8, json) catch null;

    pushMessage(json);
}

pub fn setWindowPos(cx: i32, cy: i32, clientW: i32, clientH: i32) void {
    var buf: [192]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_window_pos\",\"cx\":{d},\"cy\":{d},\"clientW\":{d},\"clientH\":{d}}}", .{ cx, cy, clientW, clientH }) catch return;

    if (last_window_pos_json) |old| {
        g_allocator.free(old);
    }
    last_window_pos_json = g_allocator.dupe(u8, json) catch null;

    pushMessage(json);
}

pub fn showEditControl(multiline: bool) void {
    const msg = if (multiline) "{\"type\":\"show_edit_control\",\"multiline\":true}" else "{\"type\":\"show_edit_control\",\"multiline\":false}";
    last_edit_control_json = msg;
    pushMessage(msg);
}

pub fn resizeEditControl(x: i32, y: i32, width: i32, height: i32) void {
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"resize_edit_control\",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ x, y, width, height }) catch return;
    pushMessage(json);
}

pub fn setIcon(json: []const u8) void {
    icon_json = json;
    pushMessage(json);
}

pub fn setMenu(json: []const u8) void {
    dynamic_menu_json = json;
    pushMessage(json);
}

// --- Output: Dialogs ---

pub fn showMessageBox(title: []const u8, text: []const u8) void {
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
    pushMessage(json);
}

pub fn showDialog(json: []const u8) void {
    active_dialog = g_allocator.dupe(u8, json) catch null;
    pushMessage(json);
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

    pushMessage(buf.items);
    buf.deinit(g_allocator);
}

/// Add a single child control to the in-place controls container.
pub fn addControl(class: []const u8, hwnd_id: usize, x: i32, y: i32, w: i32, h: i32, style: u32, text: []const u8) void {
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        "{{\"type\":\"add_control\",\"class\":\"{s}\",\"id\":{d},\"x\":{d},\"y\":{d},\"cx\":{d},\"cy\":{d},\"style\":{d},\"text\":\"{s}\"}}",
        .{ class, hwnd_id, x, y, w, h, style, text },
    ) catch return;
    pushMessage(json);
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
    pushMessage(json);
}

pub fn openFileDialog(filters: ?[]const u8, is_save: bool) void {
    var files_json: std.ArrayListUnmanaged(u8) = .{};
    defer files_json.deinit(g_allocator);

    files_json.appendSlice(g_allocator, "{\"type\":\"open_file_dialog\"") catch {};
    if (is_save) {
        files_json.appendSlice(g_allocator, ",\"mode\":\"save\"") catch {};
    }
    files_json.appendSlice(g_allocator, ",\"files\":[") catch {};

    var first = true;
    var dir = std.fs.cwd().openDir("Desktop", .{ .iterate = true }) catch blk: {
        break :blk std.fs.cwd().openDir("../Desktop", .{ .iterate = true }) catch null;
    };
    
    if (dir) |*d| {
        defer d.close();
        var it = d.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind == .file) {
                if (!first) files_json.appendSlice(g_allocator, ",") catch {};
                first = false;
                files_json.appendSlice(g_allocator, "\"") catch {};
                files_json.appendSlice(g_allocator, entry.name) catch {};
                files_json.appendSlice(g_allocator, "\"") catch {};
            }
        }
    }

    files_json.appendSlice(g_allocator, "]") catch {};

    // Append filter list if provided (pre-formatted JSON array string)
    if (filters) |f| {
        files_json.appendSlice(g_allocator, ",\"filters\":") catch {};
        files_json.appendSlice(g_allocator, f) catch {};
    }

    files_json.appendSlice(g_allocator, "}") catch {};

    if (active_dialog) |old| {
        g_allocator.free(old);
    }
    active_dialog = g_allocator.dupe(u8, files_json.items) catch null;
    pushMessage(files_json.items);
}

pub fn closeDialog() void {
    active_dialog = null;
    pushMessage("{\"type\":\"close_dialog\"}");
}

// --- Input: Volume changed from UI ---
pub var on_volume_change: ?*const fn (f32) void = null;

// --- Output: Audio ---

pub fn setVolume(linear: f32) void {
    // linear: 0.0 (silence) to 1.0 (full)
    const clamped = std.math.clamp(linear, 0.0, 1.0);
    const vol_int: u32 = @intFromFloat(clamped * 100.0);
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"set_volume\",\"volume\":{d}}}", .{vol_int}) catch return;
    pushMessage(json);
}

pub fn setAudioFormat(sample_rate: u32, channels: u16, bits_per_sample: u16) void {
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"audio_format\",\"sampleRate\":{d},\"channels\":{d},\"bitsPerSample\":{d}}}", .{ sample_rate, channels, bits_per_sample }) catch return;

    if (last_audio_format_json) |old| {
        g_allocator.free(old);
    }
    last_audio_format_json = g_allocator.dupe(u8, json) catch null;

    pushMessage(json);
}

pub fn pushAudio(data: []const u8) void {
    switch (active_backend) {
        .web_ui => web_ui.pushAudio(data),
        .none => {},
    }
}

// --- Internal: raw message push (used by typed functions above) ---

pub fn pushMessage(json: []const u8) void {
    switch (active_backend) {
        .web_ui => web_ui.pushMessage(json),
        .none => {},
    }
}
