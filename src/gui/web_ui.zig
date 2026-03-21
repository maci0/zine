//! Web-based graphical user interface.

const std = @import("std");
const platform = @import("../platform.zig");
const renderer = @import("renderer.zig");
const log = @import("../log.zig");

var clients: if (platform.is_native) std.ArrayListUnmanaged(std.net.Stream) else struct {} = if (platform.is_native) .{} else .{};
var clients_mutex: if (platform.is_native) std.Thread.Mutex else struct {
    pub fn lock(_: *@This()) void {}
    pub fn unlock(_: *@This()) void {}
} = .{};
var g_allocator: std.mem.Allocator = undefined;
var selected_file_path: [1024]u8 = undefined;

/// Initializes the Web UI backend.
pub fn init(allocator: std.mem.Allocator) !void {
    // Use page allocator for internal web UI data to avoid alignment issues
    // with the game's custom HeapAlloc-based allocator
    g_allocator = std.heap.page_allocator;
    clients = .{};

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
        const thread = try std.Thread.spawn(.{}, serverLoop, .{allocator});
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
        var w = std.net.Stream.writer(stream, &out_buf);
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

        // Validate socket is still alive before writing (prevent INVAL panic from stdlib)
        if (comptime platform.is_native) {
            var sock_err: c_int = 0;
            std.posix.getsockopt(
                stream.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.ERROR,
                std.mem.asBytes(&sock_err),
            ) catch {
                _ = clients.swapRemove(i);
                continue;
            };
            if (sock_err != 0) {
                _ = clients.swapRemove(i);
                continue;
            }
        }

        var out_buf: [4096]u8 = undefined;
        var w = std.net.Stream.writer(stream, &out_buf);
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
        var w = std.net.Stream.writer(stream, &out_buf);
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

fn serverLoop(allocator: std.mem.Allocator) void {
    const address = std.net.Address.parseIp4("127.0.0.1", 1995) catch |err| {
        std.debug.print("WebUI: failed to parse address: {}\n", .{err});
        return;
    };
    var server = address.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("WebUI: failed to listen on port 1995: {}\n", .{err});
        return;
    };
    defer server.deinit();

    std.debug.print("\n>>> Zine Web UI running on http://127.0.0.1:1995 <<<\n\n", .{});

    while (true) {
        const conn = server.accept() catch continue;
        const thread = std.Thread.spawn(.{}, handleClient, .{ conn, allocator }) catch {
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleClient(conn: std.net.Server.Connection, _: std.mem.Allocator) void {
    handleClientInner(conn) catch |err| {
        std.debug.print("Error in handleClientInner: {}\n", .{err});
    };
}

fn sendError(ws: *std.http.Server.WebSocket, msg: []const u8) void {
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"message\":\"{s}\"}}", .{msg}) catch return;
    _ = ws.writeMessage(json, .text) catch {};
}

fn handleClientInner(conn: std.net.Server.Connection) !void {
    // Each client handler gets its own arena to avoid thread-safety issues
    // with the shared ArenaAllocator from main.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var in_buf: [8192]u8 = undefined;
    var out_buf: [8192]u8 = undefined;
    var r = std.net.Stream.reader(conn.stream, &in_buf);
    var w = std.net.Stream.writer(conn.stream, &out_buf);

    var server = std.http.Server.init(r.interface(), &w.interface);

    var req = server.receiveHead() catch |err| {
        if (err != error.EndOfStream and err != error.ConnectionResetByPeer) {
            std.debug.print("HTTP receiveHead error: {}\n", .{err});
        }
        conn.stream.close();
        return;
    };

    const target = req.head.target;

    if (std.mem.startsWith(u8, target, "/ws")) {
        const upgrade = req.upgradeRequested();
        if (upgrade != .websocket) {
            try req.respond("Expected websocket upgrade", .{ .status = .bad_request });
            return conn.stream.close();
        }

        var ws = try req.respondWebSocket(.{ .key = upgrade.websocket.? });
        ws.flush() catch {};

        clients_mutex.lock();
        clients.append(g_allocator, conn.stream) catch {};
        clients_mutex.unlock();

        // Push initial state to reconnecting client
        if (renderer.last_resolution_json) |json| pushMessage(json);
        pushFrame();
        if (renderer.dynamic_menu_json) |json| pushMessage(json);
        if (renderer.icon_json) |json| pushMessage(json);
        if (renderer.desktop_icons_json) |json| pushMessage(json);
        if (renderer.active_dialog) |json| pushMessage(json);
        if (renderer.last_window_pos_json) |json| pushMessage(json);
        if (renderer.last_title_json) |json| pushMessage(json);
        if (renderer.last_edit_control_json) |json| pushMessage(json);
        if (renderer.last_audio_format_json) |json| pushMessage(json);
        if (renderer.last_controls_json) |json| pushMessage(json);
        for (renderer.cached_control_text_updates.items) |json| pushMessage(json);

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

                                    const path = std.fmt.bufPrint(&selected_file_path, "drive_c/{s}/{s}", .{ dir_path, file_val.string }) catch null;
                                    if (path) |p| {
                                        if (renderer.on_file_uploaded) |cb| cb(p);
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
                                    const path = std.fmt.bufPrint(&selected_file_path, "drive_c/{s}", .{req_path}) catch null;
                                    if (path) |p| {
                                        if (renderer.on_file_uploaded) |cb| cb(p);
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
                        } else if (std.mem.eql(u8, type_val.?.string, "context_menu_select")) {
                            // Context menu item selected
                            if (root.object.get("id")) |id_val| {
                                if (id_val == .integer) {
                                    renderer.context_menu_result = @intCast(@as(u32, @truncate(@as(u64, @bitCast(id_val.integer)))));
                                    renderer.context_menu_chosen = true;
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
                        } else if (std.mem.eql(u8, type_val.?.string, "mousedown") or
                                   std.mem.eql(u8, type_val.?.string, "mouseup") or
                                   std.mem.eql(u8, type_val.?.string, "mousemove")) {
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
        conn.stream.close();
        
        clients_mutex.lock();
        for (clients.items, 0..) |stream, i| {
            if (stream.handle == conn.stream.handle) {
                _ = clients.swapRemove(i);
                break;
            }
        }
        clients_mutex.unlock();
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
            return conn.stream.close();
        }

        // Only allow paths starting with / and containing only safe characters
        if (req_path.len == 0 or req_path[0] != '/') {
            try req.respond("Forbidden", .{ .status = .forbidden });
            return conn.stream.close();
        }

        const full_path = std.fmt.bufPrint(&file_path_buf, "src/gui{s}", .{req_path}) catch {
            return conn.stream.close();
        };

        var file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try req.respond("Not found", .{ .status = .not_found });
            } else {
                try req.respond("Internal server error", .{ .status = .internal_server_error });
            }
            std.debug.print("Closing FD {} (File error: {s})\n", .{conn.stream.handle, full_path});
            return conn.stream.close();
        };
        defer file.close();

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

        const file_size = try file.getEndPos();
        if (file_size > 10 * 1024 * 1024) {
             try req.respond("File too large", .{ .status = .internal_server_error });
             return conn.stream.close();
        }
        const content = allocator.alloc(u8, @intCast(file_size)) catch {
             try req.respond("Out of memory", .{ .status = .internal_server_error });
             return conn.stream.close();
        };
        const bytes_read = try file.readAll(content);
        try req.respond(content[0..bytes_read], .{ .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "x-content-type-options", .value = "nosniff" },
            .{ .name = "x-frame-options", .value = "DENY" },
            .{ .name = "content-security-policy", .value = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws://127.0.0.1:1995" },
        } });
        return conn.stream.close();
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
