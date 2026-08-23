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
};

/// Represents the metadata for an entire dialog.
pub const DialogData = struct {
    /// The message type for the GUI backend.
    type: []const u8 = "custom_dialog",
    /// Title of the dialog window.
    title: []const u8,
    /// Preferred X coordinate.
    x: u16,
    /// Preferred Y coordinate.
    y: u16,
    /// Width in dialog units.
    cx: u16,
    /// Height in dialog units.
    cy: u16,
    /// List of controls in the dialog.
    items: []DialogItem,
};

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

    var title_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer title_buf.deinit(allocator);
    while (true) {
        c = try reader.takeInt(u16, .little);
        if (c == 0) break;
        try title_buf.append(allocator, @intCast(c & 0xFF));
    }

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
            var class_buf: std.ArrayListUnmanaged(u8) = .empty;
            if (c != 0) {
                class_buf.append(allocator, if (c < 128) @intCast(c) else '?') catch {};
            }
            while (c != 0) {
                c = try reader.takeInt(u16, .little);
                if (c != 0) {
                    class_buf.append(allocator, if (c < 128) @intCast(c) else '?') catch {};
                }
            }
            if (class_buf.items.len > 0) {
                class_name_owned = class_buf.toOwnedSlice(allocator) catch null;
                if (class_name_owned) |owned| class_name = owned;
            } else {
                class_buf.deinit(allocator);
            }
        }

        // Title array
        var text_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer text_buf.deinit(allocator);
        c = try reader.takeInt(u16, .little);
        if (c == 0xFFFF) {
            _ = try reader.takeInt(u16, .little);
        } else {
            while (c != 0) {
                if (c == '\r') {
                    // ignore
                } else if (c == '\n') {
                    try text_buf.append(allocator, '\n');
                } else {
                    try text_buf.append(allocator, @intCast(c & 0xFF));
                }
                c = try reader.takeInt(u16, .little);
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
        });
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"type\": \"custom_dialog\", \"title\": \"");
    for (title_buf.items) |char| {
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
        try w.print("{{\"id\": {d}, \"x\": {d}, \"y\": {d}, \"cx\": {d}, \"cy\": {d}, \"style\": {d}, \"class\": \"{s}\", \"text\": \"", .{ item.id, item.x, item.y, item.cx, item.cy, item.style, item.class });
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
