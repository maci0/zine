//! PE menu resource parser.
//!
//! This module handles parsing binary Win32 menu resources into a hierarchical
//! JSON structure suitable for the GUI backend.

const std = @import("std");
const json_utils = @import("json_utils.zig");

/// The item is a popup submenu; a command item carries an id word instead.
const MF_POPUP: u16 = 0x0010;
/// The item is the last of its list.
const MF_END: u16 = 0x0080;

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
        var item = try parseItem(allocator, data, &offset, 0);
        errdefer freeMenuItem(allocator, &item);
        try root_items.append(allocator, item);
        if ((item.flags & MF_END) != 0) {
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
    errdefer list.deinit(allocator);
    return list.toOwnedSlice(allocator);
}

/// Maximum popup nesting accepted. Each level costs one stack frame, and a
/// crafted resource adds a level every four bytes (flags, empty name), so an
/// unbounded walk overflows the stack well before the input is exhausted.
pub const max_popup_depth = 32;

fn parseItem(allocator: std.mem.Allocator, data: []const u8, offset: *usize, depth: u32) !MenuItem {
    if (depth > max_popup_depth) return error.MenuNestingTooDeep;
    if (offset.* + 2 > data.len) return error.InvalidMenuResource;
    const flags = std.mem.readInt(u16, data[offset.*..][0..2], .little);
    offset.* += 2;

    const is_popup = (flags & MF_POPUP) != 0;

    var id: u16 = 0;
    if (!is_popup) {
        if (offset.* + 2 > data.len) return error.InvalidMenuResource;
        id = std.mem.readInt(u16, data[offset.*..][0..2], .little);
        offset.* += 2;
    }

    var name_u16: std.ArrayListUnmanaged(u16) = .empty;
    defer name_u16.deinit(allocator);

    while (true) {
        if (data.len - offset.* < 2) return error.InvalidMenuResource;
        const c = std.mem.readInt(u16, data[offset.*..][0..2], .little);
        offset.* += 2;
        if (c == 0) break;
        if (c == '\t') {
            try name_u16.appendNTimes(allocator, std.mem.nativeToLittle(u16, ' '), 3);
        } else {
            try name_u16.append(allocator, std.mem.nativeToLittle(u16, c));
        }
    }

    var item = MenuItem{
        .id = id,
        .name = try std.unicode.utf16LeToUtf8Alloc(allocator, name_u16.items),
        .flags = flags,
        .popup = null,
    };
    errdefer freeMenuItem(allocator, &item);

    if (is_popup) {
        var children: std.ArrayListUnmanaged(MenuItem) = .empty;
        errdefer {
            for (children.items) |*child| freeMenuItem(allocator, child);
            children.deinit(allocator);
        }

        while (offset.* < data.len) {
            var child = try parseItem(allocator, data, offset, depth + 1);
            errdefer freeMenuItem(allocator, &child);
            try children.append(allocator, child);
            if ((child.flags & MF_END) != 0) {
                break;
            }
        }
        item.popup = try children.toOwnedSlice(allocator);
    }

    return item;
}

fn writeMenuItemJson(writer: anytype, item: MenuItem) !void {
    try writer.print("{{\"id\":{d},\"name\":\"", .{item.id});
    try json_utils.writeJsonString(writer, item.name);
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
    try appendItem(&data, testing.allocator, MF_END, 7, &name);

    const json = try parseMenuResource(testing.allocator, data.items);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"type\":\"menu\",\"menu\":[{\"id\":7,\"name\":\"O   \\\"q\\\\\",\"flags\":128}]}",
        json,
    );
}

test "parseMenuResource: UTF-16 astral text survives as UTF-8" {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 });
    try appendItem(&data, testing.allocator, MF_END, 9, &.{ 0xE9, 0xD801, 0xDC00, 'e', 0x301 });

    const json = try parseMenuResource(testing.allocator, data.items);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"type\":\"menu\",\"menu\":[{\"id\":9,\"name\":\"\u{00e9}\u{10400}e\u{301}\",\"flags\":128}]}",
        json,
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("\u{00e9}\u{10400}e\u{301}", parsed.value.object.get("menu").?.array.items[0].object.get("name").?.string);
}

test "parseMenuResource: malformed UTF-16 is rejected without leaking popup names" {
    const cases = .{
        .{ &[_]u16{0xD801}, error.DanglingSurrogateHalf },
        .{ &[_]u16{ 0xD801, 'a' }, error.ExpectedSecondSurrogateHalf },
        .{ &[_]u16{0xDC00}, error.UnexpectedSecondSurrogateHalf },
    };
    inline for (cases) |case| {
        var data: std.ArrayListUnmanaged(u8) = .empty;
        defer data.deinit(testing.allocator);
        try data.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 });
        try appendItem(&data, testing.allocator, MF_POPUP | MF_END, null, &.{0xE9});
        try appendItem(&data, testing.allocator, 0, 1, &.{'a'});
        try appendItem(&data, testing.allocator, MF_END, 2, case[0]);
        try testing.expectError(case[1], parseMenuResource(testing.allocator, data.items));
    }
}

fn checkMenuAllocationFailures(allocator: std.mem.Allocator) !void {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(allocator);
    try data.appendSlice(allocator, &.{ 0, 0, 0, 0 });
    try appendItem(&data, allocator, MF_POPUP | MF_END, null, &.{ 0xE9, '\t' });
    try appendItem(&data, allocator, MF_END, 1, &.{ 0xD801, 0xDC00 });
    const json = parseMenuResource(allocator, data.items) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(json);
}

test "parseMenuResource: Unicode menus release every allocation on failure" {
    try testing.checkAllAllocationFailures(testing.allocator, checkMenuAllocationFailures, .{});
}

test "parseMenuResource: truncated input is rejected" {
    // Shorter than the 4-byte template header.
    try testing.expectError(error.InvalidMenuResource, parseMenuResource(testing.allocator, &.{ 0, 0 }));
    // Header present but first item's flags are cut off.
    try testing.expectError(error.InvalidMenuResource, parseMenuResource(testing.allocator, &.{ 0, 0, 0, 0, 0x80 }));
    for ([_][]const u8{ &.{}, &.{0xE9}, &.{ 0xE9, 0 }, &.{ 0xE9, 0, 0 } }) |name| {
        var data: std.ArrayListUnmanaged(u8) = .empty;
        defer data.deinit(testing.allocator);
        try data.appendSlice(testing.allocator, &.{ 0, 0, 0, 0, 0x80, 0, 1, 0 });
        try data.appendSlice(testing.allocator, name);
        try testing.expectError(error.InvalidMenuResource, parseMenuResource(testing.allocator, data.items));
    }
}

test "parseMenuResource: popup nesting past max_popup_depth is rejected" {
    // A crafted resource nests one popup every four bytes (MF_POPUP, an
    // empty name). Left unbounded this recurses until the stack is gone.
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 });
    const levels = max_popup_depth + 8;
    for (0..levels) |_| {
        try data.appendSlice(testing.allocator, &u16le(MF_POPUP) ++ &u16le(0));
    }
    try testing.expectError(error.MenuNestingTooDeep, parseMenuResource(testing.allocator, data.items));
}

test "parseMenuResource: control characters are escaped as \\uXXXX" {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 });
    // Name containing raw ESC (0x1B) and BEL (0x07) from a crafted resource.
    try appendItem(&data, testing.allocator, MF_END, 5, &.{ 'A', 0x1B, 'B', 0x07 });

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
