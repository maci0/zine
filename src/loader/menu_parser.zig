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
    _ = std.mem.readInt(u16, data[offset+2..][0..2], .little); // cbHeader
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
    
    // simple json string escape
    for (item.name) |c| {
        if (c == '"') {
            try writer.writeAll("\\\"");
        } else if (c == '\\') {
            try writer.writeAll("\\\\");
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
