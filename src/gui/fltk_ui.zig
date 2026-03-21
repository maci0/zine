//! FLTK Backend
//!
//! This module bridges Zig to native FLTK via the C bridge in fltk_bridge.cpp.
//!
//! Threading model:
//!   - Worker thread: x86 execution calls renderer functions (setTitle, pushFrame, etc.)
//!   - FLTK thread: spawned in init(), runs Fl::check() in a loop
//!
//! All FLTK widget mutations happen from the FLTK thread. Worker thread
//! enqueues commands into a lock-free ring buffer and calls fltk_awake().

const std = @import("std");
const renderer = @import("renderer.zig");
const build_options = @import("build_options");

/// Conditionally import the C bridge — only available when -Dfltk=true
const c = if (build_options.use_fltk) @cImport({
    @cInclude("fltk_bridge.h");
}) else struct {};

var g_allocator: std.mem.Allocator = undefined;

// --- Command queue (worker → FLTK thread) ---

const Command = union(enum) {
    set_title: []const u8,
    set_framebuf: struct { w: u32, h: u32 },
    resize_window: struct { x: i32, y: i32, w: i32, h: i32 },
    set_menu: []const u8,
    show_message_box: struct { title: []const u8, text: []const u8 },
    set_resolution: struct { w: u32, h: u32 },
    redraw,
};

const QUEUE_SIZE = 256;
var cmd_queue: [QUEUE_SIZE]Command = undefined;
var cmd_write: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var cmd_read: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var queue_mutex: std.Thread.Mutex = .{};

fn enqueue(cmd: Command) void {
    queue_mutex.lock();
    defer queue_mutex.unlock();
    const w = cmd_write.load(.acquire);
    const next = (w + 1) % QUEUE_SIZE;
    if (next == cmd_read.load(.acquire)) {
        // Queue full — drop command
        return;
    }
    cmd_queue[w] = cmd;
    cmd_write.store(next, .release);

    if (build_options.use_fltk) {
        c.fltk_awake();
    }
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
    }
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
        c.FLTK_EVT_MENU_CMD => {
            if (renderer.on_command) |cb| cb(@intCast(param1));
        },
        else => {},
    }
}

// --- FLTK event loop thread ---

fn fltkEventLoop() void {
    if (!build_options.use_fltk) return;

    c.fltk_show_window();

    // Main event loop
    while (true) {
        // Process FLTK events (non-blocking would spin CPU, so use a brief wait)
        c.fltk_run_check();

        // Drain enqueued commands from worker thread
        drainQueue();

        // Brief sleep to avoid burning CPU (FLTK check() returns immediately)
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

/// Initializes the FLTK backend, creates the window, and spawns the event loop thread.
pub fn init(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;

    if (!build_options.use_fltk) {
        std.debug.print("\n>>> FLTK backend initialized (stub — not compiled with -Dfltk) <<<\n\n", .{});
        return;
    }

    // Initialize FLTK window
    c.fltk_init(640, 480, "Zine");
    c.fltk_set_event_callback(&eventCallback);

    // Spawn FLTK event loop on a dedicated thread
    const thread = try std.Thread.spawn(.{}, fltkEventLoop, .{});
    thread.detach();

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
pub fn setIcon(_: []const u8) void {
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
pub fn showEditControl(_: bool) void {
}

/// Resizes the native edit control.
pub fn resizeEditControl(_: i32, _: i32, _: i32, _: i32) void {
}

/// Sets the font for the native edit control.
pub fn setEditFont(_: usize, _: []const u8, _: i32, _: bool, _: bool) void {
}

/// Sets the text selection in the native edit control.
pub fn setEditSelection(_: i32, _: i32) void {
}

/// Replaces the current selection in the native edit control.
pub fn replaceEditSelection(_: []const u8) void {
}

/// Undoes the last operation in the native edit control.
pub fn editUndo() void {
}

/// Scrolls the native edit control to the caret position.
pub fn editScrollCaret() void {
}

/// Sets the complete text content of the native edit control.
pub fn setEditText(_: []const u8) void {
}

// --- Status Bar ---

/// Configures the number of parts in the status bar.
pub fn setStatusBarParts(_: usize) void {
}

/// Sets the text for a specific part of the status bar.
pub fn setStatusBarText(_: usize, _: []const u8) void {
}

// --- Clipboard ---

/// Copies text to the system clipboard.
pub fn setClipboard(_: []const u8) void {
}

// --- Context Menu ---

/// Displays a context menu at the specified coordinates.
pub fn showContextMenu(_: i32, _: i32, _: []const u8) void {
}

// --- Dialogs ---

/// Displays a standard message box.
pub fn showMessageBox(title: []const u8, text: []const u8) void {
    const owned_title = g_allocator.dupe(u8, title) catch return;
    const owned_text = g_allocator.dupe(u8, text) catch return;
    enqueue(.{ .show_message_box = .{ .title = owned_title, .text = owned_text } });
}

/// Shows a modal dialog with the given JSON definition.
pub fn showDialog(_: []const u8) void {
}

/// Displays a collection of controls in a dialog.
pub fn showControls(_: []const u8) void {
}

/// Adds a control to the current dialog.
pub fn addControl(_: []const u8, _: usize, _: i32, _: i32, _: i32, _: i32, _: u32, _: []const u8) void {
}

/// Updates the text of a specific control in a dialog.
pub fn updateControlText(_: i32, _: []const u8) void {
}

/// Opens a standard file selection dialog.
pub fn openFileDialog(_: ?[]const u8, _: bool) void {
}

/// Opens a standard font selection dialog.
pub fn openFontDialog(_: []const u8, _: i32, _: bool, _: bool) void {
}

/// Closes the currently active modal dialog.
pub fn closeDialog() void {
}

// --- Audio ---

/// Sets the global audio playback volume.
pub fn setVolume(_: f32) void {
}

/// Sets the audio format for subsequent PCM playback.
pub fn setAudioFormat(_: u32, _: u16, _: u16) void {
}

/// Pushes PCM audio data to the output buffer.
pub fn pushAudio(_: []const u8) void {
}
