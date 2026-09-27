//! Fuzz harness for the PE dialog (and DIALOGEX) resource parser.
//!
//! One input is one raw RT_DIALOG blob, exactly as a PE resource directory
//! hands it to `parseDialogData`.

const std = @import("std");
const dialog = @import("../loader/dialog_parser.zig");

/// Seed corpus: a plain DIALOG, a DIALOGEX with a font and one control, a
/// title whose characters must be escaped into the JSON, and a truncated blob.
pub const seeds = [_][]const u8{
    // DIALOG, no items, Edit class, title "Hi".
    &.{
        0, 0, 0, 0x80, // style WS_POPUP
        0, 0, 0, 0, // exstyle
        0, 0, // cdit 0
        10, 0, 20, 0, // x, y
        100, 0, 50, 0, // cx, cy
        0xFF, 0xFF, 0x81, 0, // class atom 0x0081 (Edit)
        'H', 0, 'i', 0, 0, 0, // title "Hi"
    },
    // DIALOGEX, DS_SETFONT, one Button control titled by class atom.
    &.{
        1, 0, 0xFF, 0xFF, // dlgVer 1 + signature
        0, 0, 0, 0, // helpID
        0, 0, 0, 0, // exStyle
        0x40, 0, 0, 0, // style DS_SETFONT
        1,   0, // cdit 1
        10,  0,
        20,  0,
        100, 0,
        50,  0,
        0xFF, 0xFF, 0x80, 0, // class atom 0x0080 (Button)
        'O', 0, 'K', 0, 0, 0, // title "OK"
        8,   0, 0x90, 0x01, 0,   0, // point size 8, weight 400, charset
        'S', 0, 'e',  0,    'g', 0,
        'o', 0, 'e',  0,    ' ', 0,
        'U', 0, 'I',  0,    0,   0,
        0, 0, 0, 0, // item helpID
        0, 0, 0, 0, // item exStyle
        0x50, 0, 0, 0, // item style WS_CHILD | WS_VISIBLE
        10, 0, 10, 0, 60, 0, 20, 0, // x, y, cx, cy
        0x01, 0, 0, 0, 0, 0, // id 1
        'B', 0, 'u', 0, 't', 0, 't', 0, 'o', 0, 'n', 0, 0, 0, // class "Button"
        0, 0, // title: no text
        0, 0, // creation data length 0
    },
    // A quote, a backslash and a control character in the title, which the
    // JSON writer has to escape for the frontend's JSON.parse.
    &.{
        0, 0, 0, 0, // style
        0, 0, 0, 0, // exstyle
        0, 0, // cdit 0
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        0,    0, // class: empty string
        '"',  0,
        '\\', 0,
        0x01, 0,
        0,    0,
    },
    // Truncated inside the header: shorter than any fixed layout.
    &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0x01 },
    // A string class name holding a quote, a backslash and a control
    // character, which the JSON writer has to escape alongside the title.
    &.{
        0, 0, 0, 0, // style
        0, 0, 0, 0, // exstyle
        1, 0, // cdit 1
        0, 0, 0, 0, 0, 0, 0, 0, // x, y, cx, cy
        0, 0, // class: empty string
        0, 0, // title: empty string
        0, 0, // padding to the DWORD boundary the item starts on
        0x50, 0, 0, 0, // item style
        0, 0, 0, 0, // item exStyle
        10, 0, 10, 0, 60, 0, 20, 0, // x, y, cx, cy
        1, 0, // id 1
        'O', 0, 'K', 0, '"', 0, '\\', 0, 0x01, 0, 0, 0, // class "OK\"\\x01"
        0, 0, // title: no text
        0, 0, // creation data length 0
    },
};

/// Errors that mean the parser produced something impossible.
pub const Failure = error{
    DialogOutputNotValidJson,
    DialogOutputNotAnObject,
    DialogOutputBadType,
    DialogOutputMissingTitle,
    DialogOutputTitleNotAString,
    DialogOutputItemsNotAnArray,
    DialogItemFieldsNotNumbers,
    DialogItemFieldsOutOfRange,
    DialogItemClassNotAString,
    DialogItemTextNotAString,
    /// Reported by the allocator, not by a parser contract violation.
    OutOfMemory,
};

/// Runs one resource through the parser and checks the JSON contract: the
/// output is embedded verbatim in a message the frontend parses, so anything
/// the parser accepts must be a well-formed `custom_dialog` object. The
/// geometry comes from u16 resource fields, so each must fit back in a u16.
pub fn harness(allocator: std.mem.Allocator, data: []const u8) Failure!void {
    const json = dialog.parseDialogData(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A truncated resource is the documented rejection.
        else => return,
    } orelse return;
    defer allocator.free(json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return error.DialogOutputNotValidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.DialogOutputNotAnObject;

    const type_value = parsed.value.object.get("type") orelse return error.DialogOutputBadType;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "custom_dialog"))
        return error.DialogOutputBadType;

    const title = parsed.value.object.get("title") orelse return error.DialogOutputMissingTitle;
    if (title != .string) return error.DialogOutputTitleNotAString;

    const items = parsed.value.object.get("items") orelse return error.DialogOutputItemsNotAnArray;
    if (items != .array) return error.DialogOutputItemsNotAnArray;

    for (items.array.items) |item| {
        if (item != .object) return error.DialogOutputItemsNotAnArray;
        const object = item.object;
        inline for (.{ "id", "x", "y", "cx", "cy" }) |field| {
            const value = object.get(field) orelse return error.DialogItemFieldsNotNumbers;
            if (value != .integer) return error.DialogItemFieldsNotNumbers;
            if (value.integer < 0 or value.integer > 0xFFFF) return error.DialogItemFieldsOutOfRange;
        }
        const style = object.get("style") orelse return error.DialogItemFieldsNotNumbers;
        if (style != .integer or style.integer < 0) return error.DialogItemFieldsNotNumbers;
        const class_value = object.get("class") orelse return error.DialogItemClassNotAString;
        if (class_value != .string) return error.DialogItemClassNotAString;
        const text_value = object.get("text") orelse return error.DialogItemTextNotAString;
        if (text_value != .string) return error.DialogItemTextNotAString;
    }
}
