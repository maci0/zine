//! Web-based graphical user interface.

const std = @import("std");
const config = @import("../config.zig");
const runtime = @import("../runtime.zig");
const platform = @import("../platform.zig");
const path_utils = @import("../path_utils.zig");
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

        const len: u64 = @min(
            @as(u64, renderer.global_width) * @as(u64, renderer.global_height) * 4,
            renderer.global_framebuf.len,
        );
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
    const web = config.web_server;
    const address: std.Io.net.IpAddress = std.Io.net.IpAddress.parse(web.host(), web.port) catch |err| {
        std.debug.print("WebUI: failed to parse address: {}\n", .{err});
        return;
    };
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        var url_buf: [config.max_url_len]u8 = undefined;
        std.debug.print("WebUI: failed to listen on {s}: {}\n", .{ web.url(&url_buf), err });
        return;
    };
    defer server.deinit(io);

    var url_buf: [config.max_url_len]u8 = undefined;
    std.debug.print("\n>>> Zine Web UI running on {s} <<<\n\n", .{web.url(&url_buf)});

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

/// Methods the static branch serves. Anything else is a client mistake, not
/// a missing resource, so it gets 405 with `Allow` rather than a body.
const static_allowed_methods = "GET, HEAD";
/// The WebSocket endpoint exists only as a GET upgrade.
const websocket_allowed_methods = "GET";

/// True when `method` is named in a comma-separated `Allow` list. The same
/// list drives the 405 and its `Allow` header, so the two cannot drift.
fn methodAllowed(method: std.http.Method, allowed: []const u8) bool {
    var rest = allowed;
    while (std.mem.indexOfScalar(u8, rest, ',')) |i| {
        if (std.mem.eql(u8, std.mem.trim(u8, rest[0..i], " \t"), @tagName(method))) return true;
        rest = rest[i + 1 ..];
    }
    return std.mem.eql(u8, std.mem.trim(u8, rest, " \t"), @tagName(method));
}

/// Single body for every non-file response: a plain-text reason carrying the
/// `Content-Type` a client needs to read it. `Allow` is set on 405.
fn respondStatus(
    req: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    allow: ?[]const u8,
) !void {
    var headers: [2]std.http.Header = undefined;
    var count: usize = 1;
    headers[0] = .{ .name = "content-type", .value = "text/plain; charset=utf-8" };
    if (allow) |methods| {
        headers[1] = .{ .name = "allow", .value = methods };
        count = 2;
    }
    try req.respond(body, .{ .status = status, .extra_headers = headers[0..count] });
}

/// Content type for a static asset, or null when the extension is unknown and
/// the caller should fall back to `application/octet-stream`.
fn contentTypeForPath(req_path: []const u8) ?[]const u8 {
    const table = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "application/javascript; charset=utf-8" },
        .{ ".json", "application/json; charset=utf-8" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".ico", "image/vnd.microsoft.icon" },
        .{ ".wav", "audio/wav" },
    };
    inline for (table) |entry| {
        if (std.mem.endsWith(u8, req_path, entry[0])) return entry[1];
    }
    return null;
}

/// Upper bound on one text_sync or clipboard_sync payload. The guest edit
/// control and the clipboard are both page-sized; anything larger is a client
/// bug and is rejected before it reaches the cached strings.
const max_sync_text_len = 65536;

// A message field is either present with the right JSON type or it is not:
// `null` covers a missing key and a wrong-typed value alike, so every handler
// reports the same rejection for both.
fn jsonInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn jsonIntOr(object: std.json.ObjectMap, key: []const u8, default: i32) i32 {
    return std.math.cast(i32, jsonInt(object, key) orelse return default) orelse default;
}

fn jsonStr(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn jsonBool(object: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = object.get(key) orelse return default;
    if (value != .bool) return default;
    return value.bool;
}

/// True if the request may talk to this UI. Browsers always send an Origin
/// header on WebSocket handshakes and on cross-site fetches; without this
/// check any webpage the user visits could open the UI's WebSocket, receive
/// the emulator's screen frames, and drive the guest with synthetic input
/// (cross-site WebSocket hijacking / DNS rebinding). Non-browser clients
/// (curl, tests) omit Origin and are allowed. The accepted origins follow
/// the configured bind address and port, not a hardcoded one.
fn originAllowed(req: *const std.http.Server.Request) bool {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
            return config.web_server.originAllowed(header.value);
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
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const req_path = target[0..query_start];

    if (std.mem.eql(u8, req_path, "/ws")) {
        if (!originAllowed(&req)) {
            try respondStatus(&req, .forbidden, "Forbidden", null);
            return stream.close(runtime.io());
        }
        if (!methodAllowed(req.head.method, websocket_allowed_methods)) {
            try respondStatus(&req, .method_not_allowed, "Method not allowed", websocket_allowed_methods);
            return stream.close(runtime.io());
        }
        const upgrade = req.upgradeRequested();
        if (upgrade != .websocket) {
            try respondStatus(&req, .bad_request, "Expected websocket upgrade", null);
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
                    sendError(&ws, "malformed JSON message");
                    continue;
                };
                defer parsed.deinit();
                const root = parsed.value;

                // A message the server cannot read is answered with the same
                // {"type":"error",...} envelope as a message whose fields fail
                // validation, so a client has one way to learn a send failed.
                if (root != .object) {
                    sendError(&ws, "message must be a JSON object");
                    continue;
                }
                const type_val = root.object.get("type") orelse {
                    sendError(&ws, "missing string field \"type\"");
                    continue;
                };
                if (type_val != .string) {
                    sendError(&ws, "field \"type\" must be a string");
                    continue;
                }
                if (std.mem.eql(u8, type_val.string, "command")) {
                    if (jsonInt(root.object, "id")) |id| {
                        if (std.math.cast(u32, id)) |cmd_id| {
                            if (renderer.on_command) |cb| cb(cmd_id);
                        } else {
                            sendError(&ws, "command field \"id\" is out of range");
                        }
                    } else {
                        sendError(&ws, "command requires an integer field \"id\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "open_file")) {
                    if (jsonStr(root.object, "filename")) |file_val| {
                        // Use the dir path provided by the client (defaults to Desktop)
                        const dir_path = jsonStr(root.object, "dir") orelse "Desktop";

                        var rel_buf: [1024]u8 = undefined;
                        const rel = std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ dir_path, file_val }) catch {
                            sendError(&ws, "Path too long");
                            continue;
                        };
                        // Reject anything that resolves outside drive_c/
                        // (absolute, drive-qualified, "..", NUL).
                        var path_buf: [1024]u8 = undefined;
                        const resolved = path_utils.virtualPathToDriveC(rel, &path_buf);
                        if (resolved == 0) {
                            sendError(&ws, "Invalid path");
                        } else if (renderer.on_file_uploaded) |cb| {
                            cb(path_buf[0..resolved]);
                        }
                    } else {
                        sendError(&ws, "open_file requires a string field \"filename\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "browse_directory")) {
                    // Client requests directory listing for navigation
                    if (jsonStr(root.object, "path")) |path_val| {
                        // Listing stays inside drive_c/; listDirectory
                        // resolves and rejects escaping paths itself.
                        renderer.listDirectory(path_val);
                    } else {
                        sendError(&ws, "browse_directory requires a string field \"path\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "launch")) {
                    // Desktop icon double-click: launch a file from drive_c/
                    if (jsonStr(root.object, "path")) |path_val| {
                        var path_buf: [1024]u8 = undefined;
                        const resolved = path_utils.virtualPathToDriveC(path_val, &path_buf);
                        if (resolved != 0) {
                            if (renderer.on_file_uploaded) |cb| {
                                cb(path_buf[0..resolved]);
                            }
                        } else {
                            sendError(&ws, "Invalid path");
                        }
                    } else {
                        sendError(&ws, "launch requires a string field \"path\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "resize")) {
                    const client_w = jsonInt(root.object, "clientW") orelse {
                        sendError(&ws, "resize requires integer fields \"clientW\" and \"clientH\"");
                        continue;
                    };
                    const client_h = jsonInt(root.object, "clientH") orelse {
                        sendError(&ws, "resize requires integer fields \"clientW\" and \"clientH\"");
                        continue;
                    };
                    const new_cw = std.math.cast(i32, client_w) orelse {
                        sendError(&ws, "resize field \"clientW\" is out of range");
                        continue;
                    };
                    const new_ch = std.math.cast(i32, client_h) orelse {
                        sendError(&ws, "resize field \"clientH\" is out of range");
                        continue;
                    };
                    const size_type: usize = @intCast(@max(jsonInt(root.object, "sizeType") orelse 0, 0));
                    if (renderer.on_resize) |cb| cb(new_cw, new_ch, size_type);
                } else if (std.mem.eql(u8, type_val.string, "close")) {
                    if (renderer.on_close) |cb| cb();
                } else if (std.mem.eql(u8, type_val.string, "font_chosen")) {
                    // Parse font selection: { face: "...", size: N, bold: bool, italic: bool }
                    const face = jsonStr(root.object, "face") orelse {
                        sendError(&ws, "font_chosen requires a string field \"face\" and an integer field \"size\"");
                        continue;
                    };
                    const pt_size = std.math.cast(i32, jsonInt(root.object, "size") orelse {
                        sendError(&ws, "font_chosen requires a string field \"face\" and an integer field \"size\"");
                        continue;
                    }) orelse {
                        sendError(&ws, "font_chosen field \"size\" is out of range");
                        continue;
                    };
                    const is_bold = jsonBool(root.object, "bold", false);
                    const is_italic = jsonBool(root.object, "italic", false);
                    if (renderer.on_font_chosen) |cb| cb(face, pt_size, is_bold, is_italic);
                } else if (std.mem.eql(u8, type_val.string, "print_chosen")) {
                    // Parse print confirmation: { from, to, copies }
                    const from_page = std.math.cast(i32, jsonInt(root.object, "from") orelse {
                        sendError(&ws, "print_chosen requires integer fields \"from\" and \"to\"");
                        continue;
                    }) orelse {
                        sendError(&ws, "print_chosen field \"from\" is out of range");
                        continue;
                    };
                    const to_page = std.math.cast(i32, jsonInt(root.object, "to") orelse {
                        sendError(&ws, "print_chosen requires integer fields \"from\" and \"to\"");
                        continue;
                    }) orelse {
                        sendError(&ws, "print_chosen field \"to\" is out of range");
                        continue;
                    };
                    const copies = jsonIntOr(root.object, "copies", 1);
                    if (renderer.on_print_chosen) |cb| cb(from_page, to_page, copies);
                } else if (std.mem.eql(u8, type_val.string, "page_setup_chosen")) {
                    // Parse page-setup confirmation:
                    // { left, top, right, bottom, paperW, paperH, orientation }
                    if (jsonInt(root.object, "left") == null or jsonInt(root.object, "top") == null) {
                        sendError(&ws, "page_setup_chosen requires integer fields \"left\" and \"top\"");
                        continue;
                    }
                    if (renderer.on_page_setup_chosen) |cb| {
                        cb(
                            jsonIntOr(root.object, "left", 0),
                            jsonIntOr(root.object, "top", 0),
                            jsonIntOr(root.object, "right", 0),
                            jsonIntOr(root.object, "bottom", 0),
                            jsonIntOr(root.object, "paperW", 8500),
                            jsonIntOr(root.object, "paperH", 11000),
                            jsonIntOr(root.object, "orientation", 0),
                        );
                    }
                } else if (std.mem.eql(u8, type_val.string, "cancel_dialog")) {
                    if (renderer.on_cancel_dialog) |cb| cb();
                } else if (std.mem.eql(u8, type_val.string, "find_action")) {
                    // Parse: { action: "find_next"|"replace"|"replace_all"|"close",
                    //          findText: "...", replaceText: "...",
                    //          matchCase: bool, searchDown: bool }
                    const action = jsonStr(root.object, "action") orelse {
                        sendError(&ws, "find_action requires string fields \"action\" and \"findText\"");
                        continue;
                    };
                    const find_text = jsonStr(root.object, "findText") orelse {
                        sendError(&ws, "find_action requires string fields \"action\" and \"findText\"");
                        continue;
                    };
                    const replace_str = jsonStr(root.object, "replaceText") orelse "";
                    const match_case = jsonBool(root.object, "matchCase", false);
                    const search_down = jsonBool(root.object, "searchDown", true);
                    if (renderer.on_find_action) |cb| cb(action, find_text, replace_str, match_case, search_down);
                } else if (std.mem.eql(u8, type_val.string, "text_sync")) {
                    // Frontend syncs textarea content to backend cache
                    if (jsonStr(root.object, "text")) |text| {
                        if (text.len > max_sync_text_len) {
                            sendError(&ws, "Text payload exceeds maximum size");
                            continue;
                        }
                        renderer.setEditTextFromSlice(text);
                    } else {
                        sendError(&ws, "text_sync requires a string field \"text\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "clipboard_sync")) {
                    // Browser clipboard → backend clipboard buffer
                    if (jsonStr(root.object, "text")) |text| {
                        if (text.len > max_sync_text_len) {
                            sendError(&ws, "Clipboard payload exceeds maximum size");
                            continue;
                        }
                        renderer.setClipboard(text);
                    } else {
                        sendError(&ws, "clipboard_sync requires a string field \"text\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "color_selected")) {
                    // Color dialog result: { color: 0xRRGGBB } (-1 = cancel)
                    if (jsonInt(root.object, "color")) |color| {
                        if (color < 0) {
                            if (renderer.on_cancel_dialog) |cb| cb();
                        } else if (renderer.on_color_selected) |cb| {
                            cb(@intCast(@as(u64, @bitCast(color)) & 0xFFFFFF));
                        }
                    } else {
                        sendError(&ws, "color_selected requires an integer field \"color\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "listbox_select")) {
                    // Listbox item clicked: (id, index)
                    if (jsonInt(root.object, "id")) |id| {
                        if (jsonInt(root.object, "index")) |index| {
                            if (renderer.on_listbox_select) |cb| {
                                cb(@intCast(@as(u64, @bitCast(id))), @intCast(index));
                            }
                        } else {
                            sendError(&ws, "listbox_select requires integer fields \"id\" and \"index\"");
                        }
                    } else {
                        sendError(&ws, "listbox_select requires integer fields \"id\" and \"index\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "context_menu_select")) {
                    // Context menu item selected
                    if (jsonInt(root.object, "id")) |id| {
                        // Result first so a guest that observes
                        // chosen==true also observes the result.
                        renderer.context_menu_result.store(@intCast(@as(u32, @truncate(@as(u64, @bitCast(id))))), .release);
                        renderer.context_menu_chosen.store(true, .release);
                    } else {
                        sendError(&ws, "context_menu_select requires an integer field \"id\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "set_volume")) {
                    if (jsonInt(root.object, "volume")) |pct| {
                        const linear = std.math.clamp(@as(f32, @floatFromInt(pct)) / 100.0, 0.0, 1.0);
                        if (renderer.on_volume_change) |cb| cb(linear);
                    } else {
                        sendError(&ws, "set_volume requires an integer field \"volume\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "keydown") or std.mem.eql(u8, type_val.string, "keyup")) {
                    const is_down = std.mem.eql(u8, type_val.string, "keydown");
                    if (jsonStr(root.object, "key")) |key| {
                        // A key with no Win32 equivalent is not an
                        // error: browsers report many more keys than
                        // the guest window can use.
                        const vk_code = mapBrowserKey(key);
                        if (vk_code != 0) {
                            if (renderer.on_key_event) |cb| cb(vk_code, is_down);
                        }
                    } else {
                        sendError(&ws, "key event requires a string field \"key\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "wheel")) {
                    if (jsonInt(root.object, "delta")) |raw_delta| {
                        const delta = std.math.cast(i32, raw_delta) orelse {
                            sendError(&ws, "wheel field \"delta\" is out of range");
                            continue;
                        };
                        if (renderer.on_wheel_event) |cb| cb(delta, 0, 0);
                    } else {
                        sendError(&ws, "wheel requires an integer field \"delta\"");
                    }
                } else if (std.mem.eql(u8, type_val.string, "mousedown") or
                    std.mem.eql(u8, type_val.string, "mouseup") or
                    std.mem.eql(u8, type_val.string, "mousemove"))
                {
                    const x = std.math.cast(i32, jsonInt(root.object, "x") orelse {
                        sendError(&ws, "mouse event requires integer fields \"x\" and \"y\"");
                        continue;
                    }) orelse {
                        sendError(&ws, "mouse event field \"x\" is out of range");
                        continue;
                    };
                    const y = std.math.cast(i32, jsonInt(root.object, "y") orelse {
                        sendError(&ws, "mouse event requires integer fields \"x\" and \"y\"");
                        continue;
                    }) orelse {
                        sendError(&ws, "mouse event field \"y\" is out of range");
                        continue;
                    };
                    const button = jsonIntOr(root.object, "button", 0);
                    const w32 = @import("../win32/constants.zig");
                    var msg_id: u32 = w32.WM_MOUSEMOVE;
                    if (std.mem.eql(u8, type_val.string, "mousedown")) {
                        msg_id = if (button == 2) w32.WM_RBUTTONDOWN else w32.WM_LBUTTONDOWN;
                    } else if (std.mem.eql(u8, type_val.string, "mouseup")) {
                        msg_id = if (button == 2) w32.WM_RBUTTONUP else w32.WM_LBUTTONUP;
                    }
                    if (renderer.on_mouse_event) |cb| cb(msg_id, x, y);
                } else {
                    sendError(&ws, "unknown message type");
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
        if (!methodAllowed(req.head.method, static_allowed_methods)) {
            try respondStatus(&req, .method_not_allowed, "Method not allowed", static_allowed_methods);
            return stream.close(runtime.io());
        }

        var file_path_buf: [256]u8 = undefined;
        var asset_path = req_path;
        if (std.mem.eql(u8, asset_path, "/")) asset_path = "/index.html";

        // Security: reject path traversal sequences, encoded variants, and null bytes.
        // Check for ".." (literal), "%2e" / "%2E" (percent-encoded dot), and null bytes.
        if (std.mem.indexOf(u8, asset_path, "..") != null or
            std.mem.indexOf(u8, asset_path, "%2e") != null or
            std.mem.indexOf(u8, asset_path, "%2E") != null or
            std.mem.indexOf(u8, asset_path, "%00") != null or
            std.mem.indexOfScalar(u8, asset_path, 0) != null)
        {
            try respondStatus(&req, .forbidden, "Forbidden", null);
            return stream.close(runtime.io());
        }

        // Only allow paths starting with / and containing only safe characters
        if (asset_path.len == 0 or asset_path[0] != '/') {
            try respondStatus(&req, .forbidden, "Forbidden", null);
            return stream.close(runtime.io());
        }

        const full_path = std.fmt.bufPrint(&file_path_buf, "src/gui{s}", .{asset_path}) catch {
            return stream.close(runtime.io());
        };

        var file = std.Io.Dir.cwd().openFile(runtime.io(), full_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try respondStatus(&req, .not_found, "Not found", null);
            } else {
                try respondStatus(&req, .internal_server_error, "Internal server error", null);
            }
            std.debug.print("Closing FD {} (File error: {s})\n", .{ stream.socket.handle, full_path });
            return stream.close(runtime.io());
        };
        defer file.close(runtime.io());

        const content_type = contentTypeForPath(asset_path) orelse "application/octet-stream";

        const file_size = try file.length(runtime.io());
        if (file_size > max_static_file_size) {
            try respondStatus(&req, .payload_too_large, "File too large", null);
            return stream.close(runtime.io());
        }
        const content = allocator.alloc(u8, @intCast(file_size)) catch {
            try respondStatus(&req, .internal_server_error, "Out of memory", null);
            return stream.close(runtime.io());
        };
        const bytes_read = try file.readPositionalAll(runtime.io(), content, 0);
        try respondStaticContent(&req, content[0..bytes_read], content_type);
        return stream.close(runtime.io());
    }
}

/// Largest asset the static branch reads into memory. Matches the
/// uncompressed size one desktop asset can plausibly reach.
const max_static_file_size = 10 * 1024 * 1024;

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

fn acceptsGzip(req: *const std.http.Server.Request) bool {
    var gzip_quality: ?f32 = null;
    var wildcard_quality: f32 = 0;
    var identity_quality: f32 = 0;
    var headers = req.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) continue;
        var codings = std.mem.splitScalar(u8, header.value, ',');
        while (codings.next()) |coding| {
            var parts = std.mem.splitScalar(u8, coding, ';');
            const name = std.mem.trim(u8, parts.next().?, " \t");
            var quality: f32 = 1;
            while (parts.next()) |parameter| {
                const param = std.mem.trim(u8, parameter, " \t");
                if (std.mem.startsWith(u8, param, "q=")) {
                    quality = std.fmt.parseFloat(f32, param[2..]) catch 0;
                    if (!std.math.isFinite(quality) or quality < 0 or quality > 1) quality = 0;
                }
            }
            if (std.ascii.eqlIgnoreCase(name, "gzip")) {
                gzip_quality = quality;
            } else if (std.mem.eql(u8, name, "*")) {
                wildcard_quality = quality;
            } else if (std.ascii.eqlIgnoreCase(name, "identity")) {
                identity_quality = quality;
            }
        }
    }
    const quality = gzip_quality orelse wildcard_quality;
    return quality > 0 and quality >= identity_quality;
}

fn precompressedContent(digest: [32]u8) ?[]const u8 {
    const assets = @import("web_assets");
    inline for (.{ "app.js", "win2k.css", "index.html", "van.min.js" }) |name| {
        if (std.mem.eql(u8, &digest, &@field(assets, name ++ "_digest"))) return @field(assets, name);
    }
    return null;
}

fn respondStaticContent(req: *std.http.Server.Request, content: []const u8, content_type: []const u8) !void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    const candidate = if (acceptsGzip(req)) precompressedContent(digest) else null;
    const compressed = if (candidate) |bytes| (if (bytes.len < content.len) bytes else null) else null;
    const body = compressed orelse content;
    if (compressed != null) std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    var etag_buf: [digest.len * 2 + 2]u8 = undefined;
    const etag = try std.fmt.bufPrint(&etag_buf, "\"{s}\"", .{std.fmt.bytesToHex(digest, .lower)});

    if (staticContentNotModified(req, etag)) {
        // A 304 has to describe the representation it revalidated, so a
        // client that negotiated gzip sees the same Content-Encoding it would
        // have seen on the 200.
        var not_modified_headers: [4]std.http.Header = undefined;
        not_modified_headers[0] = .{ .name = "etag", .value = etag };
        not_modified_headers[1] = .{ .name = "cache-control", .value = "private, no-cache" };
        not_modified_headers[2] = .{ .name = "vary", .value = "Accept-Encoding" };
        const not_modified_count: usize = 3 + @as(usize, @intFromBool(compressed != null));
        if (compressed != null) {
            not_modified_headers[3] = .{ .name = "content-encoding", .value = "gzip" };
        }
        try req.respond("", .{
            .status = .not_modified,
            .keep_alive = false,
            .transfer_encoding = .none,
            .extra_headers = not_modified_headers[0..not_modified_count],
        });
        return;
    }

    var ws_buf: [config.max_url_len]u8 = undefined;
    var csp_buf: [256]u8 = undefined;
    const csp = std.fmt.bufPrint(&csp_buf, "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' {s}", .{config.web_server.wsUrl(&ws_buf)}) catch "default-src 'self'";

    const response_headers = [_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "etag", .value = etag },
        .{ .name = "cache-control", .value = "private, no-cache" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "x-frame-options", .value = "DENY" },
        .{ .name = "content-security-policy", .value = csp },
        .{ .name = "vary", .value = "Accept-Encoding" },
        .{ .name = "content-encoding", .value = "gzip" },
    };
    try req.respond(body, .{ .keep_alive = false, .extra_headers = response_headers[0 .. response_headers.len - @intFromBool(compressed == null)] });
}

test "endpoints answer an unsupported method with 405 and their Allow list" {
    try std.testing.expect(methodAllowed(.GET, static_allowed_methods));
    try std.testing.expect(methodAllowed(.HEAD, static_allowed_methods));
    try std.testing.expect(!methodAllowed(.POST, static_allowed_methods));
    try std.testing.expect(!methodAllowed(.PUT, static_allowed_methods));
    try std.testing.expect(!methodAllowed(.DELETE, static_allowed_methods));
    try std.testing.expect(methodAllowed(.GET, websocket_allowed_methods));
    try std.testing.expect(!methodAllowed(.HEAD, websocket_allowed_methods));
    try std.testing.expect(!methodAllowed(.POST, websocket_allowed_methods));

    var input = std.Io.Reader.fixed("POST /app.js HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var server = std.http.Server.init(&input, &output.writer);
    var req = try server.receiveHead();
    try std.testing.expect(!methodAllowed(req.head.method, static_allowed_methods));
    try respondStatus(&req, .method_not_allowed, "Method not allowed", static_allowed_methods);
    const response = output.written();
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, response, "\r\nallow: GET, HEAD\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\r\ncontent-type: text/plain; charset=utf-8\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, response, "\r\n\r\nMethod not allowed"));
}

test "error responses share one plain-text envelope" {
    const cases = [_]struct { status: std.http.Status, body: []const u8 }{
        .{ .status = .forbidden, .body = "Forbidden" },
        .{ .status = .not_found, .body = "Not found" },
        .{ .status = .internal_server_error, .body = "Internal server error" },
        .{ .status = .payload_too_large, .body = "File too large" },
    };
    for (cases) |case| {
        var input = std.Io.Reader.fixed("GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n");
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        var server = std.http.Server.init(&input, &output.writer);
        var req = try server.receiveHead();
        try respondStatus(&req, case.status, case.body, null);
        const response = output.written();
        try std.testing.expect(std.mem.indexOf(u8, response, "\r\ncontent-type: text/plain; charset=utf-8\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\r\nallow:") == null);
        try std.testing.expect(std.mem.endsWith(u8, response, case.body));
    }
}

test "static assets map their extension to a content type" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", contentTypeForPath("/index.html").?);
    try std.testing.expectEqualStrings("text/css; charset=utf-8", contentTypeForPath("/win2k.css").?);
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", contentTypeForPath("/app.js").?);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", contentTypeForPath("/menu.json").?);
    try std.testing.expectEqualStrings("image/svg+xml", contentTypeForPath("/assets/back.svg").?);
    try std.testing.expectEqualStrings("image/png", contentTypeForPath("/assets/wall.png").?);
    try std.testing.expectEqualStrings("image/vnd.microsoft.icon", contentTypeForPath("/favicon.ico").?);
    try std.testing.expect(contentTypeForPath("/drive_c/game.exe") == null);
}

test "a 304 describes the gzip representation it revalidated" {
    const content = @embedFile("app.js");
    var input = std.Io.Reader.fixed("GET /app.js HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\n\r\n");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var server = std.http.Server.init(&input, &output.writer);
    var req = try server.receiveHead();
    try respondStaticContent(&req, content, "application/javascript; charset=utf-8");
    const response = output.written();
    const etag_start = (std.mem.indexOf(u8, response, "\r\netag: ") orelse return error.TestUnexpectedResult) + "\r\netag: ".len;
    const etag_end = std.mem.indexOfPos(u8, response, etag_start, "\r\n") orelse return error.TestUnexpectedResult;
    const etag = response[etag_start..etag_end];

    const conditional = try std.fmt.allocPrint(std.testing.allocator, "GET /app.js HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\nIf-None-Match: {s}\r\n\r\n", .{etag});
    defer std.testing.allocator.free(conditional);
    var conditional_input = std.Io.Reader.fixed(conditional);
    var conditional_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer conditional_output.deinit();
    var conditional_server = std.http.Server.init(&conditional_input, &conditional_output.writer);
    var conditional_req = try conditional_server.receiveHead();
    try respondStaticContent(&conditional_req, content, "application/javascript; charset=utf-8");
    const revalidated = conditional_output.written();
    try std.testing.expect(std.mem.startsWith(u8, revalidated, "HTTP/1.1 304 Not Modified\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, revalidated, "\r\ncontent-encoding: gzip\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, revalidated, "\r\nvary: Accept-Encoding\r\n") != null);

    // An identity client revalidates a different ETag and must not be told
    // the resource is gzip encoded.
    const identity = try std.fmt.allocPrint(std.testing.allocator, "GET /app.js HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: identity\r\nIf-None-Match: {s}\r\n\r\n", .{etag});
    defer std.testing.allocator.free(identity);
    var identity_input = std.Io.Reader.fixed(identity);
    var identity_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer identity_output.deinit();
    var identity_server = std.http.Server.init(&identity_input, &identity_output.writer);
    var identity_req = try identity_server.receiveHead();
    try respondStaticContent(&identity_req, content, "application/javascript; charset=utf-8");
    const identity_response = identity_output.written();
    try std.testing.expect(std.mem.startsWith(u8, identity_response, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, identity_response, "\r\ncontent-encoding: gzip\r\n") == null);
}

test "message fields are read by JSON type, missing and wrong-typed alike" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"id":7,"face":"Arial","size":"12","bold":true,"loud":"x","null_id":null}
    , .{});
    defer parsed.deinit();

    const object = parsed.value.object;
    try std.testing.expectEqual(@as(?i64, 7), jsonInt(object, "id"));
    try std.testing.expect(jsonInt(object, "size") == null);
    try std.testing.expect(jsonInt(object, "loud") == null);
    try std.testing.expect(jsonInt(object, "null_id") == null);
    try std.testing.expect(jsonInt(object, "absent") == null);
    try std.testing.expectEqualStrings("Arial", jsonStr(object, "face").?);
    try std.testing.expect(jsonStr(object, "id") == null);
    try std.testing.expect(jsonStr(object, "absent") == null);
    try std.testing.expect(jsonBool(object, "bold", false));
    try std.testing.expect(!jsonBool(object, "loud", false));
    try std.testing.expect(jsonBool(object, "absent", true));
    try std.testing.expectEqual(@as(i32, 1), jsonIntOr(object, "absent", 1));
    try std.testing.expectEqual(@as(i32, 0), jsonIntOr(object, "size", 0));
    try std.testing.expectEqual(@as(i32, 7), jsonIntOr(object, "id", 0));
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

test "static assets negotiate gzip without changing decoded content" {
    const assets = .{
        .{ @embedFile("app.js"), "application/javascript" },
        .{ @embedFile("win2k.css"), "text/css" },
        .{ @embedFile("index.html"), "text/html" },
        .{ @embedFile("van.min.js"), "application/javascript" },
    };
    inline for (assets) |asset| {
        var input = std.Io.Reader.fixed("GET /asset HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: br, gzip, zstd\r\n\r\n");
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        var server = std.http.Server.init(&input, &output.writer);
        var req = try server.receiveHead();
        try respondStaticContent(&req, asset[0], asset[1]);
        const response = output.written();
        try std.testing.expect(std.mem.indexOf(u8, response, "\r\ncontent-encoding: gzip\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\r\nvary: Accept-Encoding\r\n") != null);
        const body_start = (std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.TestUnexpectedResult) + 4;
        const body = response[body_start..];
        try std.testing.expect(body.len < asset[0].len);
        if (std.mem.eql(u8, asset[1], "text/css")) try std.testing.expect(body.len <= 14 * 1024);
        var compressed = std.Io.Reader.fixed(body);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor = std.compress.flate.Decompress.init(&compressed, .gzip, &window);
        const decoded = try std.testing.allocator.alloc(u8, asset[0].len);
        defer std.testing.allocator.free(decoded);
        try decompressor.reader.readSliceAll(decoded);
        try std.testing.expectError(error.EndOfStream, decompressor.reader.takeByte());
        try std.testing.expectEqualStrings(asset[0], decoded);
        const length_header = try std.fmt.allocPrint(std.testing.allocator, "\r\ncontent-length: {d}\r\n", .{body.len});
        defer std.testing.allocator.free(length_header);
        try std.testing.expect(std.mem.indexOf(u8, response, length_header) != null);
    }
}

test "static asset encoding negotiation preserves identity and edited files" {
    const cases = [_]struct { encoding: []const u8, gzip: bool }{
        .{ .encoding = "", .gzip = false },
        .{ .encoding = "br, zstd", .gzip = false },
        .{ .encoding = "gzip;q=0", .gzip = false },
        .{ .encoding = "gzip;q=0, *;q=1", .gzip = false },
        .{ .encoding = "*;q=0", .gzip = false },
        .{ .encoding = "gzip;q=0.5, identity;q=1", .gzip = false },
        .{ .encoding = "gzip;q=invalid", .gzip = false },
        .{ .encoding = "gzip;q=NaN", .gzip = false },
        .{ .encoding = "gzip;q=2", .gzip = false },
        .{ .encoding = "GZip", .gzip = true },
        .{ .encoding = "br, gzip;q=0.5", .gzip = true },
        .{ .encoding = "*;q=0.5", .gzip = true },
    };
    for (cases) |case| {
        const request = try std.fmt.allocPrint(std.testing.allocator, "GET /app.js HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: {s}\r\n\r\n", .{case.encoding});
        defer std.testing.allocator.free(request);
        for ([_][]const u8{ @embedFile("app.js"), "edited asset", "" }) |content| {
            var input = std.Io.Reader.fixed(request);
            var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer output.deinit();
            var server = std.http.Server.init(&input, &output.writer);
            var req = try server.receiveHead();
            try respondStaticContent(&req, content, "application/javascript");
            const response = output.written();
            const encoded = case.gzip and content.len == @embedFile("app.js").len;
            try std.testing.expectEqual(encoded, std.mem.indexOf(u8, response, "\r\ncontent-encoding: gzip\r\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, response, "\r\nvary: Accept-Encoding\r\n") != null);
            if (!encoded) {
                const body_start = (std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.TestUnexpectedResult) + 4;
                try std.testing.expectEqualStrings(content, response[body_start..]);
            }
        }
    }
}

test "gzip asset validators distinguish representations and HEAD omits the body" {
    const content = @embedFile("app.js");
    var input = std.Io.Reader.fixed("GET /app.js HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\n\r\n");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var server = std.http.Server.init(&input, &output.writer);
    var req = try server.receiveHead();
    try respondStaticContent(&req, content, "application/javascript");
    const response = output.written();
    const etag_start = (std.mem.indexOf(u8, response, "\r\netag: ") orelse return error.TestUnexpectedResult) + "\r\netag: ".len;
    const etag_end = std.mem.indexOfPos(u8, response, etag_start, "\r\n") orelse return error.TestUnexpectedResult;
    const etag = response[etag_start..etag_end];
    const cases = .{
        .{ "GET", "gzip", etag, true, false },
        .{ "GET", "identity", etag, false, true },
        .{ "HEAD", "gzip", etag, true, false },
        .{ "HEAD", "gzip", "\"outdated\"", false, false },
    };
    inline for (cases) |case| {
        const request = try std.fmt.allocPrint(std.testing.allocator, "{s} /app.js HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: {s}\r\nIf-None-Match: {s}\r\n\r\n", .{ case[0], case[1], case[2] });
        defer std.testing.allocator.free(request);
        var next_input = std.Io.Reader.fixed(request);
        var next_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer next_output.deinit();
        var next_server = std.http.Server.init(&next_input, &next_output.writer);
        var next_req = try next_server.receiveHead();
        try respondStaticContent(&next_req, content, "application/javascript");
        const next = next_output.written();
        try std.testing.expect(std.mem.startsWith(u8, next, if (case[3]) "HTTP/1.1 304" else "HTTP/1.1 200"));
        try std.testing.expect(std.mem.indexOf(u8, next, "\r\nvary: Accept-Encoding\r\n") != null);
        const body_start = (std.mem.indexOf(u8, next, "\r\n\r\n") orelse return error.TestUnexpectedResult) + 4;
        try std.testing.expectEqualStrings(if (case[4]) content else "", next[body_start..]);
        if (case[4]) try std.testing.expect(std.mem.indexOf(u8, next, etag) == null);
    }
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
