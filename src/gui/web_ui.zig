//! Web-based graphical user interface.

const std = @import("std");
const runtime = @import("../runtime.zig");
const platform = @import("../platform.zig");
const renderer = @import("renderer.zig");
const log = @import("../log.zig");

var clients: if (platform.is_native) std.ArrayListUnmanaged(std.Io.net.Stream) else struct {} = if (platform.is_native) .empty else .{};
var clients_mutex: if (platform.is_native) runtime.Mutex else struct {
    pub fn lock(_: *@This()) void {}
    pub fn unlock(_: *@This()) void {}
} = .{};
var g_allocator: std.mem.Allocator = undefined;

/// Initializes the Web UI backend.
pub fn init() !void {
    // Use page allocator for internal web UI data to avoid alignment issues
    // with the game's custom HeapAlloc-based allocator
    g_allocator = std.heap.page_allocator;
    clients = .empty;

    // Clear buffer to black (BGRA pixel order: B=0, G=0, R=0, A=255)
    @memset(renderer.global_framebuf[0 .. 1024 * 1024 * 4], 0);
    // Set alpha channel to 255 for all pixels
    {
        var i: usize = 3;
        while (i < 1024 * 1024 * 4) : (i += 4) {
            renderer.global_framebuf[i] = 255;
        }
    }

    if (comptime platform.is_native) {
        const thread = try std.Thread.spawn(.{}, serverLoop, .{});
        thread.detach();
    }
}

/// Pushes the current framebuffer to all connected Web UI clients.
pub fn pushFrame() void {
    if (comptime !platform.is_native) return;
    clients_mutex.lock();
    defer clients_mutex.unlock();

    var i: usize = 0;
    while (i < clients.items.len) {
        const stream = clients.items[i];
        var out_buf: [4096]u8 = undefined;
        var w = std.Io.net.Stream.writer(stream, runtime.io(), &out_buf);
        var ws: std.http.Server.WebSocket = .{
            .input = undefined,
            .output = &w.interface,
            .key = "",
        };

        const len: u64 = renderer.global_width * renderer.global_height * 4;
        const payload = renderer.global_framebuf[0..@intCast(len)];

        if (ws.writeMessage(payload, .binary)) {
            i += 1;
        } else |_| {
            _ = clients.swapRemove(i);
        }
    }
}

/// Sends a JSON-encoded message to all connected Web UI clients.
pub fn pushMessage(json: []const u8) void {
    if (comptime !platform.is_native) return;
    clients_mutex.lock();
    defer clients_mutex.unlock();

    var i: usize = 0;
    while (i < clients.items.len) {
        const stream = clients.items[i];

        // TODO(zig-0.16): reinstate socket liveness check via std.Io.net. std.posix.getsockopt removed.

        var out_buf: [4096]u8 = undefined;
        var w = std.Io.net.Stream.writer(stream, runtime.io(), &out_buf);
        var ws: std.http.Server.WebSocket = .{
            .input = undefined,
            .output = &w.interface,
            .key = "",
        };

        if (ws.writeMessage(json, .text)) {
            i += 1;
        } else |_| {
            _ = clients.swapRemove(i);
        }
    }
}

/// Sends PCM audio data to all connected Web UI clients.
pub fn pushAudio(data: []const u8) void {
    if (comptime !platform.is_native) return;
    clients_mutex.lock();
    defer clients_mutex.unlock();

    const prefix = [4]u8{ 'A', 'U', 'D', 0 };

    var i: usize = 0;
    while (i < clients.items.len) {
        const stream = clients.items[i];
        var out_buf: [4096]u8 = undefined;
        var w = std.Io.net.Stream.writer(stream, runtime.io(), &out_buf);
        var ws: std.http.Server.WebSocket = .{
            .input = undefined,
            .output = &w.interface,
            .key = "",
        };

        var bufs = [_][]const u8{ &prefix, data };
        if (ws.writeMessageVec(&bufs, .binary)) {
            i += 1;
        } else |_| {
            _ = clients.swapRemove(i);
        }
    }
}

fn serverLoop() void {
    const io = runtime.io();
    const address: std.Io.net.IpAddress = std.Io.net.IpAddress.parseLiteral("127.0.0.1:1995") catch |err| {
        std.debug.print("WebUI: failed to parse address: {}\n", .{err});
        return;
    };
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("WebUI: failed to listen on port 1995: {}\n", .{err});
        return;
    };
    defer server.deinit(io);

    std.debug.print("\n>>> Zine Web UI running on http://127.0.0.1:1995 <<<\n\n", .{});

    while (true) {
        const stream = server.accept(io) catch continue;
        const client_thread = std.Thread.spawn(.{}, handleClient, .{stream}) catch {
            stream.close(io);
            continue;
        };
        client_thread.detach();
    }
}

fn handleClient(stream: std.Io.net.Stream) void {
    // handleClientInner closes the stream on its success paths. On an error
    // return (failed respond, handshake, or file read) nothing else owns the
    // fd: close it here or every failed request leaks one until exit.
    handleClientInner(stream) catch |err| {
        std.debug.print("Error in handleClientInner: {}\n", .{err});
        stream.close(runtime.io());
    };
}

fn sendError(ws: *std.http.Server.WebSocket, msg: []const u8) void {
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"message\":\"{s}\"}}", .{msg}) catch return;
    _ = ws.writeMessage(json, .text) catch {};
}

/// True if the request may talk to this UI. Browsers always send an Origin
/// header on WebSocket handshakes and on cross-site fetches; without this
/// check any webpage the user visits could open ws://127.0.0.1:1995/ws,
/// receive the emulator's screen frames, and drive the guest with synthetic
/// input (cross-site WebSocket hijacking / DNS rebinding). Non-browser
/// clients (curl, tests) omit Origin and are allowed.
fn originAllowed(req: *const std.http.Server.Request) bool {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
            const allowed = [_][]const u8{
                "http://127.0.0.1:1995",
                "http://localhost:1995",
                "http://[::1]:1995",
            };
            for (allowed) |a| {
                if (std.mem.eql(u8, header.value, a)) return true;
            }
            return false;
        }
    }
    return true;
}

fn handleClientInner(stream: std.Io.net.Stream) !void {
    // Each client handler gets its own arena to avoid thread-safety issues
    // with the shared ArenaAllocator from main.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var in_buf: [8192]u8 = undefined;
    var out_buf: [8192]u8 = undefined;
    var r = std.Io.net.Stream.reader(stream, runtime.io(), &in_buf);
    var w = std.Io.net.Stream.writer(stream, runtime.io(), &out_buf);

    var server = std.http.Server.init(&r.interface, &w.interface);

    var req = server.receiveHead() catch |err| {
        if (err != error.EndOfStream and err != error.ConnectionResetByPeer) {
            std.debug.print("HTTP receiveHead error: {}\n", .{err});
        }
        stream.close(runtime.io());
        return;
    };

    const target = req.head.target;

    if (std.mem.startsWith(u8, target, "/ws")) {
        if (!originAllowed(&req)) {
            try req.respond("Forbidden", .{ .status = .forbidden });
            return stream.close(runtime.io());
        }
        const upgrade = req.upgradeRequested();
        if (upgrade != .websocket) {
            try req.respond("Expected websocket upgrade", .{ .status = .bad_request });
            return stream.close(runtime.io());
        }

        var ws = try req.respondWebSocket(.{ .key = upgrade.websocket.? });
        ws.flush() catch {};

        clients_mutex.lock();
        clients.append(g_allocator, stream) catch {};
        clients_mutex.unlock();

        // Push initial state to reconnecting client. Hold cache_mutex across
        // the burst: the guest thread frees-and-replaces these cached strings,
        // so reading them unlocked could observe freed memory. Scoped block so
        // the lock is released before this thread settles into its read loop.
        // Frame first: it can block on socket writes (up to 4 MiB), so keep
        // it outside the cache_mutex critical section below.
        pushFrame();
        {
            renderer.cache_mutex.lock();
            defer renderer.cache_mutex.unlock();
            if (renderer.last_resolution_json) |json| pushMessage(json);
            if (renderer.dynamic_menu_json) |json| pushMessage(json);
            if (renderer.icon_json) |json| pushMessage(json);
            if (renderer.desktop_icons_json) |json| pushMessage(json);
            if (renderer.active_dialog) |json| pushMessage(json);
            if (renderer.last_window_pos_json) |json| pushMessage(json);
            if (renderer.last_title_json) |json| pushMessage(json);
            if (renderer.last_edit_control_json) |json| pushMessage(json);
            if (renderer.last_audio_format_json) |json| pushMessage(json);
            if (renderer.last_controls_json) |json| pushMessage(json);
            if (renderer.last_color_dialog_json) |json| pushMessage(json);
            for (renderer.cached_control_text_updates.items) |json| pushMessage(json);
        }

        // Read loop for incoming messages
        while (true) {
            const msg = ws.readSmallMessage() catch |err| {
                if (err != error.ConnectionClose and err != error.EndOfStream and err != error.ConnectionResetByPeer) {
                    std.debug.print("WS read error: {}\n", .{err});
                }
                break;
            };

            if (msg.opcode == .text) {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, msg.data, .{}) catch {
                    log.warn("WebSocket: malformed JSON message (len={d})", .{msg.data.len});
                    continue;
                };
                defer parsed.deinit();
                const root = parsed.value;

                if (root == .object) {
                    const type_val = root.object.get("type");
                    if (type_val != null and type_val.? == .string) {
                        if (std.mem.eql(u8, type_val.?.string, "command")) {
                            if (root.object.get("id")) |id_val| {
                                if (id_val == .integer) {
                                    if (renderer.on_command) |cb| cb(std.math.cast(u32, id_val.integer) orelse continue);
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "open_file")) {
                            if (root.object.get("filename")) |file_val| {
                                if (file_val == .string) {
                                    // Use the dir path provided by the client (defaults to Desktop)
                                    const dir_path = if (root.object.get("dir")) |dir_val|
                                        (if (dir_val == .string) dir_val.string else "Desktop")
                                    else
                                        "Desktop";

                                    // Security: reject path traversal in both dir and filename
                                    if (std.mem.indexOf(u8, dir_path, "..") != null or
                                        std.mem.indexOf(u8, file_val.string, "..") != null or
                                        std.mem.indexOfScalar(u8, dir_path, 0) != null or
                                        std.mem.indexOfScalar(u8, file_val.string, 0) != null)
                                    {
                                        sendError(&ws, "Invalid path traversal attempt");
                                        continue;
                                    }

                                    var path_buf: [1024]u8 = undefined;
                                    const path = std.fmt.bufPrint(&path_buf, "drive_c/{s}/{s}", .{ dir_path, file_val.string }) catch null;
                                    if (path) |p| {
                                        if (renderer.on_file_uploaded) |cb| {
                                            cb(p);
                                        }
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "browse_directory")) {
                            // Client requests directory listing for navigation
                            if (root.object.get("path")) |path_val| {
                                if (path_val == .string) {
                                    const req_path = path_val.string;
                                    // Security: reject path traversal and null bytes
                                    if (std.mem.indexOf(u8, req_path, "..") != null or
                                        std.mem.indexOfScalar(u8, req_path, 0) != null)
                                    {
                                        sendError(&ws, "Invalid path traversal attempt");
                                        continue;
                                    }
                                    renderer.listDirectory(req_path);
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "launch")) {
                            // Desktop icon double-click: launch a file from drive_c/
                            if (root.object.get("path")) |path_val| {
                                if (path_val == .string) {
                                    const req_path = path_val.string;
                                    // Security: reject path traversal and null bytes
                                    if (std.mem.indexOf(u8, req_path, "..") != null or
                                        std.mem.indexOfScalar(u8, req_path, 0) != null)
                                    {
                                        sendError(&ws, "Invalid path traversal attempt");
                                        continue;
                                    }
                                    var path_buf: [1024]u8 = undefined;
                                    const path = std.fmt.bufPrint(&path_buf, "drive_c/{s}", .{req_path}) catch null;
                                    if (path) |p| {
                                        if (renderer.on_file_uploaded) |cb| {
                                            cb(p);
                                        }
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "resize")) {
                            const cw = root.object.get("clientW");
                            const ch = root.object.get("clientH");
                            if (cw != null and ch != null and cw.? == .integer and ch.? == .integer) {
                                const new_cw = std.math.cast(i32, cw.?.integer) orelse continue;
                                const new_ch = std.math.cast(i32, ch.?.integer) orelse continue;
                                const size_type_val = root.object.get("sizeType");
                                const size_type: usize = if (size_type_val != null and size_type_val.? == .integer)
                                    std.math.cast(usize, size_type_val.?.integer) orelse 0
                                else
                                    0;
                                if (renderer.on_resize) |cb| cb(new_cw, new_ch, size_type);
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "close")) {
                            if (renderer.on_close) |cb| cb();
                        } else if (std.mem.eql(u8, type_val.?.string, "font_chosen")) {
                            // Parse font selection: { face: "...", size: N, bold: bool, italic: bool }
                            const face_val = root.object.get("face");
                            const size_val = root.object.get("size");
                            const bold_val = root.object.get("bold");
                            const italic_val = root.object.get("italic");
                            if (face_val != null and face_val.? == .string and
                                size_val != null and size_val.? == .integer)
                            {
                                const pt_size = std.math.cast(i32, size_val.?.integer) orelse continue;
                                const is_bold = if (bold_val != null and bold_val.? == .bool) bold_val.?.bool else false;
                                const is_italic = if (italic_val != null and italic_val.? == .bool) italic_val.?.bool else false;
                                if (renderer.on_font_chosen) |cb| cb(face_val.?.string, pt_size, is_bold, is_italic);
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "print_chosen")) {
                            // Parse print confirmation: { from, to, copies }
                            const from_val = root.object.get("from");
                            const to_val = root.object.get("to");
                            const copies_val = root.object.get("copies");
                            if (from_val != null and from_val.? == .integer and
                                to_val != null and to_val.? == .integer)
                            {
                                const from_page = std.math.cast(i32, from_val.?.integer) orelse continue;
                                const to_page = std.math.cast(i32, to_val.?.integer) orelse continue;
                                const copies: i32 = if (copies_val != null and copies_val.? == .integer)
                                    std.math.cast(i32, copies_val.?.integer) orelse 1
                                else
                                    1;
                                if (renderer.on_print_chosen) |cb| cb(from_page, to_page, copies);
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "page_setup_chosen")) {
                            // Parse page-setup confirmation:
                            // { left, top, right, bottom, paperW, paperH, orientation }
                            const left_val = root.object.get("left");
                            const top_val = root.object.get("top");
                            if (left_val != null and left_val.? == .integer and top_val != null and top_val.? == .integer) {
                                const gv = struct {
                                    fn get(o: std.json.ObjectMap, k: []const u8, dflt: i32) i32 {
                                        const v = o.get(k);
                                        if (v != null and v.? == .integer) return std.math.cast(i32, v.?.integer) orelse dflt;
                                        return dflt;
                                    }
                                }.get;
                                if (renderer.on_page_setup_chosen) |cb| {
                                    const left = std.math.cast(i32, left_val.?.integer) orelse 0;
                                    const top = std.math.cast(i32, top_val.?.integer) orelse 0;
                                    cb(left, top, gv(root.object, "right", 0), gv(root.object, "bottom", 0), gv(root.object, "paperW", 8500), gv(root.object, "paperH", 11000), gv(root.object, "orientation", 0));
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "cancel_dialog")) {
                            if (renderer.on_cancel_dialog) |cb| cb();
                        } else if (std.mem.eql(u8, type_val.?.string, "find_action")) {
                            // Parse: { action: "find_next"|"replace"|"replace_all"|"close",
                            //          findText: "...", replaceText: "...",
                            //          matchCase: bool, searchDown: bool }
                            const action_val = root.object.get("action");
                            const find_val = root.object.get("findText");
                            if (action_val != null and action_val.? == .string and
                                find_val != null and find_val.? == .string)
                            {
                                const replace_val = root.object.get("replaceText");
                                const replace_str = if (replace_val != null and replace_val.? == .string) replace_val.?.string else "";
                                const mc_val = root.object.get("matchCase");
                                const sd_val = root.object.get("searchDown");
                                const match_case = if (mc_val != null and mc_val.? == .bool) mc_val.?.bool else false;
                                const search_down = if (sd_val != null and sd_val.? == .bool) sd_val.?.bool else true;
                                if (renderer.on_find_action) |cb| cb(action_val.?.string, find_val.?.string, replace_str, match_case, search_down);
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "text_sync")) {
                            // Frontend syncs textarea content to backend cache
                            if (root.object.get("text")) |text_val| {
                                if (text_val == .string) {
                                    if (text_val.string.len > 65536) {
                                        sendError(&ws, "Text payload exceeds maximum size");
                                        continue;
                                    }
                                    renderer.setEditTextFromSlice(text_val.string);
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "clipboard_sync")) {
                            // Browser clipboard → backend clipboard buffer
                            if (root.object.get("text")) |text_val| {
                                if (text_val == .string) {
                                    if (text_val.string.len > 65536) {
                                        sendError(&ws, "Clipboard payload exceeds maximum size");
                                        continue;
                                    }
                                    renderer.setClipboardFromSlice(text_val.string);
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "color_selected")) {
                            // Color dialog result: { color: 0xRRGGBB } (-1 = cancel)
                            if (root.object.get("color")) |color_val| {
                                if (color_val == .integer) {
                                    if (color_val.integer < 0) {
                                        if (renderer.on_cancel_dialog) |cb| cb();
                                    } else if (renderer.on_color_selected) |cb| {
                                        cb(@intCast(@as(u64, @bitCast(color_val.integer)) & 0xFFFFFF));
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "listbox_select")) {
                            // Listbox item clicked: (id, index)
                            const id_val = root.object.get("id");
                            const idx_val = root.object.get("index");
                            if (id_val != null and id_val.? == .integer and idx_val != null and idx_val.? == .integer) {
                                if (renderer.on_listbox_select) |cb| {
                                    cb(@intCast(@as(u64, @bitCast(id_val.?.integer))), @intCast(@as(i64, idx_val.?.integer)));
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "context_menu_select")) {
                            // Context menu item selected
                            if (root.object.get("id")) |id_val| {
                                if (id_val == .integer) {
                                    // Result first so a guest that observes
                                    // chosen==true also observes the result.
                                    renderer.context_menu_result.store(@intCast(@as(u32, @truncate(@as(u64, @bitCast(id_val.integer))))), .release);
                                    renderer.context_menu_chosen.store(true, .release);
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "set_volume")) {
                            if (root.object.get("volume")) |vol_val| {
                                if (vol_val == .integer) {
                                    const pct: f32 = @floatFromInt(@as(i64, vol_val.integer));
                                    const linear = std.math.clamp(pct / 100.0, 0.0, 1.0);
                                    if (renderer.on_volume_change) |cb| cb(linear);
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "keydown") or std.mem.eql(u8, type_val.?.string, "keyup")) {
                            const is_down = std.mem.eql(u8, type_val.?.string, "keydown");
                            if (root.object.get("key")) |key_val| {
                                if (key_val == .string) {
                                    const vk_code = mapBrowserKey(key_val.string);
                                    if (vk_code != 0) {
                                        if (renderer.on_key_event) |cb| cb(vk_code, is_down);
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "wheel")) {
                            if (root.object.get("delta")) |d_val| {
                                if (d_val == .integer) {
                                    if (renderer.on_wheel_event) |cb| {
                                        const delta = std.math.cast(i32, d_val.integer) orelse 0;
                                        cb(delta, 0, 0);
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "mousedown") or
                            std.mem.eql(u8, type_val.?.string, "mouseup") or
                            std.mem.eql(u8, type_val.?.string, "mousemove"))
                        {
                            const x_val = root.object.get("x");
                            const y_val = root.object.get("y");
                            const btn_val = root.object.get("button");
                            if (x_val != null and y_val != null and x_val.? == .integer and y_val.? == .integer) {
                                const x = std.math.cast(i32, x_val.?.integer) orelse continue;
                                const y = std.math.cast(i32, y_val.?.integer) orelse continue;
                                const button: i32 = if (btn_val != null and btn_val.? == .integer) std.math.cast(i32, btn_val.?.integer) orelse 0 else 0;
                                const w32 = @import("../win32/constants.zig");
                                var msg_id: u32 = w32.WM_MOUSEMOVE;
                                if (std.mem.eql(u8, type_val.?.string, "mousedown")) {
                                    msg_id = if (button == 2) w32.WM_RBUTTONDOWN else w32.WM_LBUTTONDOWN;
                                } else if (std.mem.eql(u8, type_val.?.string, "mouseup")) {
                                    msg_id = if (button == 2) w32.WM_RBUTTONUP else w32.WM_LBUTTONUP;
                                }
                                if (renderer.on_mouse_event) |cb| cb(msg_id, x, y);
                            }
                        }
                    }
                }
            }
        }
        // Deregister BEFORE closing the socket: pushFrame/pushMessage run on
        // other threads and must never touch this fd again. After close() the
        // OS can recycle the descriptor for a freshly accepted connection (or
        // a file opened by the guest), and frames would be written into that
        // unrelated stream.
        clients_mutex.lock();
        for (clients.items, 0..) |client_stream, i| {
            if (client_stream.socket.handle == stream.socket.handle) {
                _ = clients.swapRemove(i);
                break;
            }
        }
        clients_mutex.unlock();
        stream.close(runtime.io());
    } else {
        var file_path_buf: [256]u8 = undefined;
        var req_path = target;
        if (std.mem.indexOfScalar(u8, req_path, '?')) |idx| {
            req_path = req_path[0..idx];
        }
        if (std.mem.eql(u8, req_path, "/")) req_path = "/index.html";

        // Security: reject path traversal sequences, encoded variants, and null bytes.
        // Check for ".." (literal), "%2e" / "%2E" (percent-encoded dot), and null bytes.
        if (std.mem.indexOf(u8, req_path, "..") != null or
            std.mem.indexOf(u8, req_path, "%2e") != null or
            std.mem.indexOf(u8, req_path, "%2E") != null or
            std.mem.indexOf(u8, req_path, "%00") != null or
            std.mem.indexOfScalar(u8, req_path, 0) != null)
        {
            try req.respond("Forbidden", .{ .status = .forbidden });
            return stream.close(runtime.io());
        }

        // Only allow paths starting with / and containing only safe characters
        if (req_path.len == 0 or req_path[0] != '/') {
            try req.respond("Forbidden", .{ .status = .forbidden });
            return stream.close(runtime.io());
        }

        const full_path = std.fmt.bufPrint(&file_path_buf, "src/gui{s}", .{req_path}) catch {
            return stream.close(runtime.io());
        };

        var file = std.Io.Dir.cwd().openFile(runtime.io(), full_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try req.respond("Not found", .{ .status = .not_found });
            } else {
                try req.respond("Internal server error", .{ .status = .internal_server_error });
            }
            std.debug.print("Closing FD {} (File error: {s})\n", .{ stream.socket.handle, full_path });
            return stream.close(runtime.io());
        };
        defer file.close(runtime.io());

        var content_type: []const u8 = "application/octet-stream";
        if (std.mem.endsWith(u8, req_path, ".html")) {
            content_type = "text/html";
        } else if (std.mem.endsWith(u8, req_path, ".css")) {
            content_type = "text/css";
        } else if (std.mem.endsWith(u8, req_path, ".js")) {
            content_type = "application/javascript";
        } else if (std.mem.endsWith(u8, req_path, ".svg")) {
            content_type = "image/svg+xml";
        }

        const file_size = try file.length(runtime.io());
        if (file_size > 10 * 1024 * 1024) {
            try req.respond("File too large", .{ .status = .internal_server_error });
            return stream.close(runtime.io());
        }
        const content = allocator.alloc(u8, @intCast(file_size)) catch {
            try req.respond("Out of memory", .{ .status = .internal_server_error });
            return stream.close(runtime.io());
        };
        const bytes_read = try file.readPositionalAll(runtime.io(), content, 0);
        try respondStaticContent(&req, content[0..bytes_read], content_type);
        return stream.close(runtime.io());
    }
}

fn staticContentNotModified(req: *const std.http.Server.Request, etag: []const u8) bool {
    if (req.head.method != .GET and req.head.method != .HEAD) return false;
    var headers = req.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "if-none-match")) continue;
        var tags = std.mem.splitScalar(u8, header.value, ',');
        while (tags.next()) |value| {
            var tag = std.mem.trim(u8, value, " \t");
            if (std.mem.eql(u8, tag, "*")) return true;
            if (std.mem.startsWith(u8, tag, "W/")) tag = tag[2..];
            if (std.mem.eql(u8, tag, etag)) return true;
        }
    }
    return false;
}

fn respondStaticContent(req: *std.http.Server.Request, content: []const u8, content_type: []const u8) !void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    var etag_buf: [digest.len * 2 + 2]u8 = undefined;
    const etag = try std.fmt.bufPrint(&etag_buf, "\"{s}\"", .{std.fmt.bytesToHex(digest, .lower)});

    if (staticContentNotModified(req, etag)) {
        try req.respond("", .{
            .status = .not_modified,
            .keep_alive = false,
            .transfer_encoding = .none,
            .extra_headers = &.{
                .{ .name = "etag", .value = etag },
                .{ .name = "cache-control", .value = "private, no-cache" },
            },
        });
        return;
    }

    try req.respond(content, .{ .keep_alive = false, .extra_headers = &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "etag", .value = etag },
        .{ .name = "cache-control", .value = "private, no-cache" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "x-frame-options", .value = "DENY" },
        .{ .name = "content-security-policy", .value = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws://127.0.0.1:1995" },
    } });
}

test "static asset responses carry an etag and 304 on a matching If-None-Match" {
    const content = @embedFile("app.js");
    const content_type = "application/javascript";
    var input = std.Io.Reader.fixed("GET /app.js HTTP/1.1\r\nHost: localhost\r\n\r\n");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var server = std.http.Server.init(&input, &output.writer);
    var req = try server.receiveHead();
    try respondStaticContent(&req, content, content_type);
    const response = output.written();
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    const initial_body_start = (std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.TestUnexpectedResult) + 4;
    try std.testing.expectEqualStrings(content, response[initial_body_start..]);
    try std.testing.expect(std.mem.indexOf(u8, response, "\r\netag: \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\r\ncache-control: private, no-cache\r\n") != null);

    const etag_start = (std.mem.indexOf(u8, response, "\r\netag: ") orelse return error.TestUnexpectedResult) + "\r\netag: ".len;
    const etag_end = std.mem.indexOfPos(u8, response, etag_start, "\r\n") orelse return error.TestUnexpectedResult;
    const etag = response[etag_start..etag_end];
    const conditional = try std.fmt.allocPrint(std.testing.allocator, "GET /app.js HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: {s}\r\n\r\n", .{etag});
    defer std.testing.allocator.free(conditional);
    var conditional_input = std.Io.Reader.fixed(conditional);
    var conditional_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer conditional_output.deinit();
    var conditional_server = std.http.Server.init(&conditional_input, &conditional_output.writer);
    var conditional_req = try conditional_server.receiveHead();
    try respondStaticContent(&conditional_req, content, content_type);
    const revalidated = conditional_output.written();
    try std.testing.expect(std.mem.startsWith(u8, revalidated, "HTTP/1.1 304 Not Modified\r\n"));
    const body_start = (std.mem.indexOf(u8, revalidated, "\r\n\r\n") orelse return error.TestUnexpectedResult) + 4;
    try std.testing.expectEqual(@as(usize, 0), revalidated[body_start..].len);
    try std.testing.expect(std.mem.indexOf(u8, revalidated, etag) != null);
    try std.testing.expect(std.mem.indexOf(u8, revalidated, "\r\ncache-control: private, no-cache\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, revalidated, "\r\ncontent-length:") == null);
    var changed_input = std.Io.Reader.fixed(conditional);
    var changed_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer changed_output.deinit();
    var changed_server = std.http.Server.init(&changed_input, &changed_output.writer);
    var changed_req = try changed_server.receiveHead();
    try respondStaticContent(&changed_req, "updated asset", content_type);
    const changed = changed_output.written();
    try std.testing.expect(std.mem.startsWith(u8, changed, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, changed, "\r\n\r\nupdated asset"));
    try std.testing.expect(std.mem.indexOf(u8, changed, etag) == null);
}

test "static asset revalidation accepts weak tags and the * matcher" {
    const cases = [_]struct { header: []const u8, expect_304: bool }{
        .{ .header = "W/\"abcd\"", .expect_304 = true },
        .{ .header = "\"abcd\", \"ffff\"", .expect_304 = true },
        .{ .header = "*", .expect_304 = true },
        .{ .header = "\"beef\"", .expect_304 = false },
    };
    for (cases) |case| {
        var input_buf: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(&input_buf, "GET /app.js HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: {s}\r\n\r\n", .{case.header});
        var input = std.Io.Reader.fixed(request);
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        var server = std.http.Server.init(&input, &output.writer);
        const req = try server.receiveHead();
        try std.testing.expectEqual(case.expect_304, staticContentNotModified(&req, "\"abcd\""));
    }
}

fn mapBrowserKey(key_str: []const u8) usize {
    if (std.mem.eql(u8, key_str, "ArrowUp")) return 0x26;
    if (std.mem.eql(u8, key_str, "ArrowDown")) return 0x28;
    if (std.mem.eql(u8, key_str, "ArrowLeft")) return 0x25;
    if (std.mem.eql(u8, key_str, "ArrowRight")) return 0x27;
    if (std.mem.eql(u8, key_str, "KeyZ")) return 0x5A;
    if (std.mem.eql(u8, key_str, "KeyX")) return 0x58;
    if (std.mem.eql(u8, key_str, "KeyA")) return 0x41;
    if (std.mem.eql(u8, key_str, "KeyS")) return 0x53;
    if (std.mem.eql(u8, key_str, "Enter")) return 0x0D;
    if (std.mem.eql(u8, key_str, "Space")) return 0x20;
    if (std.mem.eql(u8, key_str, "ShiftRight") or std.mem.eql(u8, key_str, "ShiftLeft")) return 0x10;
    if (std.mem.eql(u8, key_str, "AltLeft") or std.mem.eql(u8, key_str, "AltRight")) return 0x12; // VK_MENU
    if (std.mem.eql(u8, key_str, "ControlLeft") or std.mem.eql(u8, key_str, "ControlRight")) return 0x11; // VK_CONTROL
    if (std.mem.eql(u8, key_str, "Escape")) return 0x1B;
    if (std.mem.eql(u8, key_str, "Tab")) return 0x09;
    if (std.mem.eql(u8, key_str, "Backspace")) return 0x08;
    if (std.mem.eql(u8, key_str, "Delete")) return 0x2E;
    if (std.mem.eql(u8, key_str, "F1")) return 0x70;
    if (std.mem.eql(u8, key_str, "F2")) return 0x71;
    if (std.mem.eql(u8, key_str, "F3")) return 0x72;
    if (std.mem.eql(u8, key_str, "F4")) return 0x73;
    if (std.mem.eql(u8, key_str, "F5")) return 0x74;
    if (std.mem.eql(u8, key_str, "F6")) return 0x75;
    if (std.mem.eql(u8, key_str, "F7")) return 0x76;
    if (std.mem.eql(u8, key_str, "F8")) return 0x77;
    if (std.mem.eql(u8, key_str, "F9")) return 0x78;
    if (std.mem.eql(u8, key_str, "F10")) return 0x79;
    if (std.mem.eql(u8, key_str, "F11")) return 0x7A;
    if (std.mem.eql(u8, key_str, "F12")) return 0x7B;
    if (std.mem.eql(u8, key_str, "Digit1")) return 0x31;
    if (std.mem.eql(u8, key_str, "Digit2")) return 0x32;
    if (std.mem.eql(u8, key_str, "Digit3")) return 0x33;
    if (std.mem.eql(u8, key_str, "Digit4")) return 0x34;
    return 0;
}
