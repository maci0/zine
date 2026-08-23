//! PE menu resource parser.
//!
//! This module handles parsing binary Win32 menu resources into a hierarchical
//! JSON structure suitable for the GUI backend.

const std = @import("std");

/// Represents a single item in a menu, which may be a command or a popup submenu.
pub const MenuItem = struct {
    /// Command identifier (0 for popups).
    id: u16,
    /// Display name of the menu item.
    name: []const u8,
    /// Menu item flags (e.g., MF_POPUP, MF_END).
    flags: u16,
    /// Optional list of children if this item is a popup submenu.
    popup: ?[]MenuItem,
};

/// Parses a binary menu resource and returns a JSON string representing the menu.
pub fn parseMenuResource(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var offset: usize = 0;

    // MENUITEMTEMPLATEHEADER
    if (offset + 4 > data.len) return error.InvalidMenuResource;
    _ = std.mem.readInt(u16, data[offset..][0..2], .little); // version
    _ = std.mem.readInt(u16, data[offset + 2 ..][0..2], .little); // cbHeader
    offset += 4;

    var root_items: std.ArrayListUnmanaged(MenuItem) = .empty;
    defer {
        for (root_items.items) |*item| freeMenuItem(allocator, item);
        root_items.deinit(allocator);
    }

    while (offset < data.len) {
        const item = try parseItem(allocator, data, &offset);
        try root_items.append(allocator, item);
        if ((item.flags & 0x0080) != 0) { // MF_END
            break;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;
    try writer.writeAll("{\"type\":\"menu\",\"menu\":[");
    for (root_items.items, 0..) |item, i| {
        if (i > 0) try writer.writeAll(",");
        try writeMenuItemJson(writer, item);
    }
    try writer.writeAll("]}");

    var list = aw.toArrayList();
    return list.toOwnedSlice(allocator);
}

fn parseItem(allocator: std.mem.Allocator, data: []const u8, offset: *usize) !MenuItem {
    if (offset.* + 2 > data.len) return error.InvalidMenuResource;
    const flags = std.mem.readInt(u16, data[offset.*..][0..2], .little);
    offset.* += 2;

    const is_popup = (flags & 0x0010) != 0;

    var id: u16 = 0;
    if (!is_popup) {
        if (offset.* + 2 > data.len) return error.InvalidMenuResource;
        id = std.mem.readInt(u16, data[offset.*..][0..2], .little);
        offset.* += 2;
    }

    // Read null-terminated UTF-16 string
    var name_bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer name_bytes.deinit(allocator);

    while (offset.* + 2 <= data.len) {
        const c = std.mem.readInt(u16, data[offset.*..][0..2], .little);
        offset.* += 2;
        if (c == 0) break;
        // Basic UTF-16 to UTF-8 (assuming mostly ascii/latin1 for older games, or simple 1-1 mapping for simplicity)
        if (c < 0x80) {
            try name_bytes.append(allocator, @intCast(c));
        } else {
            // Very simple fallback, just append '?'
            try name_bytes.append(allocator, '?');
        }
    }

    // Simplify tabs (like "\t" to "   ")
    var clean_name: std.ArrayListUnmanaged(u8) = .empty;
    for (name_bytes.items) |c| {
        if (c == '\t') {
            try clean_name.appendSlice(allocator, "   ");
        } else {
            try clean_name.append(allocator, c);
        }
    }
    name_bytes.deinit(allocator);

    var item = MenuItem{
        .id = id,
        .name = try clean_name.toOwnedSlice(allocator),
        .flags = flags,
        .popup = null,
    };

    if (is_popup) {
        var children: std.ArrayListUnmanaged(MenuItem) = .empty;
        errdefer {
            for (children.items) |*child| freeMenuItem(allocator, child);
            children.deinit(allocator);
        }

        while (offset.* < data.len) {
            const child = try parseItem(allocator, data, offset);
            try children.append(allocator, child);
            if ((child.flags & 0x0080) != 0) { // MF_END
                break;
            }
        }
        item.popup = try children.toOwnedSlice(allocator);
    }

    return item;
}

fn writeMenuItemJson(writer: anytype, item: MenuItem) !void {
    try writer.print("{{\"id\":{d},\"name\":\"", .{item.id});

    // JSON string escape, including control characters: menu names come from
    // PE resources, and an unescaped 0x00-0x1F byte produces JSON that
    // JSON.parse rejects, breaking menu rendering.
    for (item.name) |c| {
        if (c == '"') {
            try writer.writeAll("\\\"");
        } else if (c == '\\') {
            try writer.writeAll("\\\\");
        } else if (c < 0x20) {
            try writer.print("\\u{x:0>4}", .{c});
        } else {
            try writer.writeByte(c);
        }
    }

    try writer.print("\",\"flags\":{d}", .{item.flags});

    if (item.popup) |popup| {
        try writer.writeAll(",\"popup\":[");
        for (popup, 0..) |child, i| {
            if (i > 0) try writer.writeAll(",");
            try writeMenuItemJson(writer, child);
        }
        try writer.writeAll("]");
    }

    try writer.writeAll("}");
}

fn freeMenuItem(allocator: std.mem.Allocator, item: *MenuItem) void {
    allocator.free(item.name);
    if (item.popup) |popup| {
        for (popup) |*child| {
            freeMenuItem(allocator, child);
        }
        allocator.free(popup);
    }
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

fn u16le(value: u16) [2]u8 {
    return std.mem.toBytes(std.mem.nativeToLittle(u16, value));
}

/// Append one MENUITEMTEMPLATE entry: flags [+ id] + UTF-16LE name + NUL.
fn appendItem(items: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, flags: u16, id: ?u16, name: []const u16) !void {
    try items.appendSlice(allocator, &u16le(flags));
    if (id) |v| try items.appendSlice(allocator, &u16le(v));
    for (name) |c| try items.appendSlice(allocator, &u16le(c));
    try items.appendSlice(allocator, &u16le(0));
}

test "parseMenuResource: flat menu renders items in order" {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(testing.allocator);
    // MENUITEMTEMPLATEHEADER: version 0, cbHeader 0
    try data.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 });
    const MF_END: u16 = 0x0080;
    try appendItem(&data, testing.allocator, MF_END, 0x1001, &.{ 'E', 'x', 'i', 't' });

    const json = try parseMenuResource(testing.allocator, data.items);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"type\":\"menu\",\"menu\":[{\"id\":4097,\"name\":\"Exit\",\"flags\":128}]}",
        json,
    );
}

test "parseMenuResource: popup submenu nests children" {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 });
    const MF_POPUP: u16 = 0x0010;
    const MF_END: u16 = 0x0080;
    // "&File" popup containing Open then Exit; root list ends after the
    // following Help item carries MF_END.
    try appendItem(&data, testing.allocator, MF_POPUP, null, &.{ '&', 'F', 'i', 'l', 'e' });
    try appendItem(&data, testing.allocator, 0, 1, &.{ 'O', 'p', 'e', 'n' });
    try appendItem(&data, testing.allocator, MF_END, 2, &.{ 'E', 'x', 'i', 't' });
    try appendItem(&data, testing.allocator, MF_END, 3, &.{ 'H', 'e', 'l', 'p' });

    const json = try parseMenuResource(testing.allocator, data.items);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"type\":\"menu\",\"menu\":[" ++
            "{\"id\":0,\"name\":\"&File\",\"flags\":16,\"popup\":[" ++
            "{\"id\":1,\"name\":\"Open\",\"flags\":0}," ++
            "{\"id\":2,\"name\":\"Exit\",\"flags\":128}]}," ++
            "{\"id\":3,\"name\":\"Help\",\"flags\":128}" ++
            "]}",
        json,
    );
}

test "parseMenuResource: tabs widen and JSON metacharacters escape" {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 });
    const name = [_]u16{ 'O', '\t', '"', 'q', '\\', 0 };
    try appendItem(&data, testing.allocator, 0x0080, 7, &name);

    const json = try parseMenuResource(testing.allocator, data.items);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"type\":\"menu\",\"menu\":[{\"id\":7,\"name\":\"O   \\\"q\\\\\",\"flags\":128}]}",
        json,
    );
}

test "parseMenuResource: non-ASCII UTF-16 becomes question mark" {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 });
    try appendItem(&data, testing.allocator, 0x0080, 9, &.{0xE9}); // é

    const json = try parseMenuResource(testing.allocator, data.items);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"type\":\"menu\",\"menu\":[{\"id\":9,\"name\":\"?\",\"flags\":128}]}",
        json,
    );
}

test "parseMenuResource: truncated input is rejected" {
    // Shorter than the 4-byte template header.
    try testing.expectError(error.InvalidMenuResource, parseMenuResource(testing.allocator, &.{ 0, 0 }));
    // Header present but first item's flags are cut off.
    try testing.expectError(error.InvalidMenuResource, parseMenuResource(testing.allocator, &.{ 0, 0, 0, 0, 0x80 }));
}

test "parseMenuResource: control characters are escaped as \\uXXXX" {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 });
    // Name containing raw ESC (0x1B) and BEL (0x07) from a crafted resource.
    try appendItem(&data, testing.allocator, 0x0080, 5, &.{ 'A', 0x1B, 'B', 0x07 });

    const json = try parseMenuResource(testing.allocator, data.items);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"type\":\"menu\",\"menu\":[{\"id\":5,\"name\":\"A\\u001bB\\u0007\",\"flags\":128}]}",
        json,
    );
    // The output must remain valid JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
}
