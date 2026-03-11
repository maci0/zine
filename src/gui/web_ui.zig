const std = @import("std");
const platform = @import("../platform.zig");
const renderer = @import("renderer.zig");

var clients: std.ArrayListUnmanaged(std.net.Stream) = .{};
var clients_mutex: if (platform.is_native) std.Thread.Mutex else struct {
    pub fn lock(_: *@This()) void {}
    pub fn unlock(_: *@This()) void {}
} = .{};
var g_allocator: std.mem.Allocator = undefined;
var selected_file_path: [1024]u8 = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    g_allocator = allocator;
    clients = .{};

    // Clear buffer to black
    for (0..(1024 * 1024)) |i| {
        renderer.global_framebuf[i * 4 + 0] = 0; // R
        renderer.global_framebuf[i * 4 + 1] = 0; // G
        renderer.global_framebuf[i * 4 + 2] = 0; // B
        renderer.global_framebuf[i * 4 + 3] = 255; // A
    }

    if (comptime platform.is_native) {
        const thread = try std.Thread.spawn(.{}, serverLoop, .{allocator});
        thread.detach();
    }
}

pub fn pushFrame() void {
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
            _ = clients.orderedRemove(i);
        }
    }
}

pub fn pushMessage(json: []const u8) void {
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

        if (ws.writeMessage(json, .text)) {
            i += 1;
        } else |_| {
            _ = clients.orderedRemove(i);
        }
    }
}

pub fn pushAudio(data: []const u8) void {
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
            _ = clients.orderedRemove(i);
        }
    }
}

fn serverLoop(allocator: std.mem.Allocator) void {
    const address = std.net.Address.parseIp4("0.0.0.0", 1995) catch |err| {
        std.debug.print("WebUI: failed to parse address: {}\n", .{err});
        return;
    };
    var server = address.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("WebUI: failed to listen on port 1995: {}\n", .{err});
        return;
    };
    defer server.deinit();

    std.debug.print("\n>>> Winloader Web UI running on http://127.0.0.1:1995 <<<\n\n", .{});

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
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, msg.data, .{}) catch continue;
                defer parsed.deinit();
                const root = parsed.value;

                if (root == .object) {
                    const type_val = root.object.get("type");
                    if (type_val != null and type_val.? == .string) {
                        if (std.mem.eql(u8, type_val.?.string, "command")) {
                            if (root.object.get("id")) |id_val| {
                                if (id_val == .integer) {
                                    if (renderer.on_command) |cb| cb(@intCast(id_val.integer));
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "open_file")) {
                            if (root.object.get("filename")) |file_val| {
                                if (file_val == .string) {
                                    var found_dir: []const u8 = "Desktop";
                                    var d = std.fs.cwd().openDir("Desktop", .{}) catch blk: {
                                        found_dir = "../Desktop";
                                        break :blk std.fs.cwd().openDir("../Desktop", .{}) catch null;
                                    };
                                    if (d) |*dir| {
                                        dir.close();
                                    }
                                    const path = std.fmt.bufPrint(&selected_file_path, "{s}/{s}", .{found_dir, file_val.string}) catch null;
                                    if (path) |p| {
                                        if (renderer.on_file_uploaded) |cb| cb(p);
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "resize")) {
                            const cw = root.object.get("clientW");
                            const ch = root.object.get("clientH");
                            if (cw != null and ch != null and cw.? == .integer and ch.? == .integer) {
                                const new_cw: i32 = @intCast(@as(i64, cw.?.integer));
                                const new_ch: i32 = @intCast(@as(i64, ch.?.integer));
                                const size_type_val = root.object.get("sizeType");
                                const size_type: usize = if (size_type_val != null and size_type_val.? == .integer)
                                    @intCast(@as(i64, size_type_val.?.integer))
                                else
                                    0;
                                if (renderer.on_resize) |cb| cb(new_cw, new_ch, size_type);
                            }
                        } else if (std.mem.eql(u8, type_val.?.string, "close")) {
                            if (renderer.on_close) |cb| cb();
                        } else if (std.mem.eql(u8, type_val.?.string, "cancel_dialog")) {
                            if (renderer.on_cancel_dialog) |cb| cb();
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
                        }
                    }
                }
            }
        }
        conn.stream.close();
        
        clients_mutex.lock();
        for (clients.items, 0..) |stream, i| {
            if (stream.handle == conn.stream.handle) {
                _ = clients.orderedRemove(i);
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

        if (std.mem.indexOf(u8, req_path, "..") != null) {
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
        try req.respond(content[0..bytes_read], .{ .extra_headers = &.{ .{ .name = "content-type", .value = content_type } } });
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
