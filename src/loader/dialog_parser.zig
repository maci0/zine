//! PE dialog resource parser.
//!
//! This module handles parsing binary Win32 dialog (and DIALOGEX) resources
//! into a JSON structure for rendering on the GUI backend.

const std = @import("std");
const runtime = @import("../runtime.zig");
const Module = @import("module.zig").Module;

/// Represents a single control within a dialog.
pub const DialogItem = struct {
    /// Control identifier (ID).
    id: u16,
    /// X coordinate in dialog units.
    x: u16,
    /// Y coordinate in dialog units.
    y: u16,
    /// Width in dialog units.
    cx: u16,
    /// Height in dialog units.
    cy: u16,
    /// Win32 window style flags.
    style: u32,
    /// Text content (e.g., button label).
    text: []const u8,
    /// Window class name (e.g., "Button", "Static").
    class: []const u8,
    /// Backing allocation when `class` came from a string class name rather
    /// than an atom; freed with the item.
    class_owned: ?[]const u8 = null,
};

/// Reads a NUL-terminated UTF-16 string from a PE resource and returns it as
/// UTF-8. Surrogate pairs are combined, so characters outside the BMP survive
/// the trip into the JSON the frontend parses; an unpaired half has no UTF-8
/// form and becomes U+FFFD. `first` is the leading code unit when the caller
/// has already read it.
fn readUtf16String(allocator: std.mem.Allocator, reader: *std.Io.Reader, first: ?u16) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);

    var unit = first orelse try reader.takeInt(u16, .little);
    while (unit != 0) {
        var cp: u21 = unit;
        if (unit >= 0xD800 and unit < 0xDC00) {
            cp = 0xFFFD;
            if (reader.buffered().len >= 2) {
                const next = try reader.takeInt(u16, .little);
                if (next >= 0xDC00 and next < 0xE000) {
                    cp = @as(u21, 0x10000) + ((@as(u21, unit) - 0xD800) << 10) + (@as(u21, next) - 0xDC00);
                } else {
                    try appendCodepoint(allocator, &list, 0xFFFD);
                }
            }
        } else if (unit >= 0xDC00 and unit < 0xE000) {
            cp = 0xFFFD;
        }
        try appendCodepoint(allocator, &list, cp);
        unit = try reader.takeInt(u16, .little);
    }
    return list.toOwnedSlice(allocator);
}

fn appendCodepoint(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try list.appendSlice(allocator, buf[0..n]);
}

/// Parses a binary dialog resource from a PE module and returns its JSON representation.
pub fn parseDialogResource(allocator: std.mem.Allocator, module: *Module, dialog_id: u32) !?[]const u8 {
    const data = module.getResource(5, dialog_id) orelse return null; // RT_DIALOG = 5

    if (data.len < 18) return null;

    var reader = std.Io.Reader.fixed(data);

    // Detect DIALOGEX vs DIALOG
    // DIALOGEX starts with: dlgVer(u16)=1, signature(u16)=0xFFFF
    // DIALOG starts with: style(u32) which does NOT start with 0x0001FFFF
    const first_word = try reader.takeInt(u16, .little);
    const second_word = try reader.takeInt(u16, .little);
    const is_dialogex = (first_word == 1 and second_word == 0xFFFF);

    var style: u32 = undefined;
    var cdit: u16 = undefined;
    var dlg_x: u16 = undefined;
    var dlg_y: u16 = undefined;
    var dlg_cx: u16 = undefined;
    var dlg_cy: u16 = undefined;

    if (is_dialogex) {
        // DIALOGEX header:
        //   dlgVer(2) + signature(2) [already read]
        //   helpID(4), exStyle(4), style(4), cDlgItems(2), x(2), y(2), cx(2), cy(2)
        _ = try reader.takeInt(u32, .little); // helpID
        _ = try reader.takeInt(u32, .little); // exStyle
        style = try reader.takeInt(u32, .little);
        cdit = try reader.takeInt(u16, .little);
        dlg_x = try reader.takeInt(u16, .little);
        dlg_y = try reader.takeInt(u16, .little);
        dlg_cx = try reader.takeInt(u16, .little);
        dlg_cy = try reader.takeInt(u16, .little);
    } else {
        // DIALOG header — first 4 bytes we already read are the style
        style = @as(u32, second_word) << 16 | @as(u32, first_word);
        _ = try reader.takeInt(u32, .little); // exstyle
        cdit = try reader.takeInt(u16, .little);
        dlg_x = try reader.takeInt(u16, .little);
        dlg_y = try reader.takeInt(u16, .little);
        dlg_cx = try reader.takeInt(u16, .little);
        dlg_cy = try reader.takeInt(u16, .little);
    }

    var c = try reader.takeInt(u16, .little);
    if (c == 0xFFFF) {
        _ = try reader.takeInt(u16, .little);
    } else {
        while (c != 0) {
            c = try reader.takeInt(u16, .little);
        }
    }

    c = try reader.takeInt(u16, .little);
    if (c == 0xFFFF) {
        _ = try reader.takeInt(u16, .little);
    } else {
        while (c != 0) {
            c = try reader.takeInt(u16, .little);
        }
    }

    const title = try readUtf16String(allocator, &reader, null);
    defer allocator.free(title);

    // DS_SETFONT = 0x40
    if ((style & 0x40) != 0) {
        _ = try reader.takeInt(u16, .little); // pointsize
        if (is_dialogex) {
            _ = try reader.takeInt(u16, .little); // weight
            _ = try reader.takeInt(u16, .little); // italic + charset
        }
        // Read typeface name
        while (true) {
            c = try reader.takeInt(u16, .little);
            if (c == 0) break;
        }
    }

    // Parse items
    var items = std.ArrayListUnmanaged(DialogItem).empty;
    defer {
        for (items.items) |item| {
            allocator.free(item.text);
            if (item.class_owned) |owned| allocator.free(owned);
        }
        items.deinit(allocator);
    }

    var i: usize = 0;
    while (i < cdit) : (i += 1) {
        // align to DWORD
        const pos = reader.seek;
        if ((pos % 4) != 0) {
            try reader.discardAll(4 - (pos % 4));
        }

        var item_style: u32 = undefined;
        var item_x: u16 = undefined;
        var item_y: u16 = undefined;
        var item_cx: u16 = undefined;
        var item_cy: u16 = undefined;
        var id: u16 = undefined;

        if (is_dialogex) {
            // DLGITEMTEMPLATEEX: helpID(4), exStyle(4), style(4), x(2), y(2), cx(2), cy(2), id(4)
            _ = try reader.takeInt(u32, .little); // helpID
            _ = try reader.takeInt(u32, .little); // exStyle
            item_style = try reader.takeInt(u32, .little);
            item_x = try reader.takeInt(u16, .little);
            item_y = try reader.takeInt(u16, .little);
            item_cx = try reader.takeInt(u16, .little);
            item_cy = try reader.takeInt(u16, .little);
            const id32 = try reader.takeInt(u32, .little);
            id = @truncate(id32);
        } else {
            // DLGITEMTEMPLATE: style(4), exStyle(4), x(2), y(2), cx(2), cy(2), id(2)
            item_style = try reader.takeInt(u32, .little);
            _ = try reader.takeInt(u32, .little); // exStyle
            item_x = try reader.takeInt(u16, .little);
            item_y = try reader.takeInt(u16, .little);
            item_cx = try reader.takeInt(u16, .little);
            item_cy = try reader.takeInt(u16, .little);
            id = try reader.takeInt(u16, .little);
        }

        // Window Class array - capture the class name
        var class_name: []const u8 = "Unknown";
        var class_name_owned: ?[]const u8 = null;
        c = try reader.takeInt(u16, .little);
        if (c == 0xFFFF) {
            const class_atom = try reader.takeInt(u16, .little);
            class_name = switch (class_atom) {
                0x0080 => "Button",
                0x0081 => "Edit",
                0x0082 => "Static",
                0x0083 => "ListBox",
                0x0084 => "ScrollBar",
                0x0085 => "ComboBox",
                else => "Unknown",
            };
        } else {
            // String class name — capture it (e.g. SysTabControl32, SysListView32)
            const class_buf = try readUtf16String(allocator, &reader, null);
            if (class_buf.len > 0) {
                class_name = class_buf;
                class_name_owned = class_buf;
            } else {
                allocator.free(class_buf);
            }
        }

        // Title array
        var text_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer text_buf.deinit(allocator);
        c = try reader.takeInt(u16, .little);
        if (c == 0xFFFF) {
            _ = try reader.takeInt(u16, .little);
        } else {
            // The first unit was already consumed; CR/LF pairs become a single
            // LF, as the resource compiler stores multi-line text that way.
            const text = try readUtf16String(allocator, &reader, c);
            defer allocator.free(text);
            for (text) |unit| {
                if (unit != '\r') try text_buf.append(allocator, unit);
            }
        }

        const creation_data_len = try reader.takeInt(u16, .little);
        if (creation_data_len > 0) {
            try reader.discardAll(creation_data_len);
        }

        try items.append(allocator, .{
            .id = id,
            .x = item_x,
            .y = item_y,
            .cx = item_cx,
            .cy = item_cy,
            .style = item_style,
            .text = try text_buf.toOwnedSlice(allocator),
            .class = class_name,
            .class_owned = class_name_owned,
        });
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"type\": \"custom_dialog\", \"title\": \"");
    for (title) |char| {
        // JSON string escape incl. control chars: dialog strings come from PE
        // resources and must not be able to break the frontend's JSON.parse.
        if (char == '"') {
            try w.writeAll("\\\"");
        } else if (char == '\\') {
            try w.writeAll("\\\\");
        } else if (char < 0x20) {
            try w.print("\\u{x:0>4}", .{char});
        } else {
            try w.writeByte(char);
        }
    }
    try w.print("\", \"x\": {d}, \"y\": {d}, \"cx\": {d}, \"cy\": {d}, \"items\": [", .{ dlg_x, dlg_y, dlg_cx, dlg_cy });

    for (items.items, 0..) |item, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.print("{{\"id\": {d}, \"x\": {d}, \"y\": {d}, \"cx\": {d}, \"cy\": {d}, \"style\": {d}, \"class\": \"", .{ item.id, item.x, item.y, item.cx, item.cy, item.style });
        for (item.class) |char| {
            if (char == '"') {
                try w.writeAll("\\\"");
            } else if (char == '\\') {
                try w.writeAll("\\\\");
            } else if (char < 0x20) {
                try w.print("\\u{x:0>4}", .{char});
            } else {
                try w.writeByte(char);
            }
        }
        try w.writeAll("\", \"text\": \"");
        for (item.text) |char| {
            if (char == '\n') {
                try w.writeAll("\\n");
            } else if (char == '"') {
                try w.writeAll("\\\"");
            } else if (char == '\\') {
                try w.writeAll("\\\\");
            } else if (char < 0x20) {
                try w.print("\\u{x:0>4}", .{char});
            } else {
                try w.writeByte(char);
            }
        }
        try w.writeAll("\"}");
    }

    try w.writeAll("]}");

    var list = aw.toArrayList();
    const slice = try list.toOwnedSlice(allocator);
    return slice;
}
