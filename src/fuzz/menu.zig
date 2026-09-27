//! Fuzz harness for the PE menu resource parser.
//!
//! One input is one raw MENUITEMTEMPLATE blob, exactly as a PE resource
//! directory hands it to `parseMenuResource`.

const std = @import("std");
const menu = @import("../loader/menu_parser.zig");

/// Seed corpus: a flat menu, a popup menu, a menu whose name needs escaping.
pub const seeds = [_][]const u8{
    // Header, then one MF_END command item "Exit" (id 0x1001).
    &.{ 0, 0, 0, 0, 0x80, 0, 0x01, 0x10, 0x45, 0, 0x78, 0, 0x69, 0, 0x74, 0, 0, 0 },
    // Header, MF_POPUP "&File" holding "Open", then MF_END "Help".
    &.{
        0, 0, 0, 0, //
        0x10, 0, '&', 0, 'F', 0, 'i', 0, 'l', 0, 'e', 0, 0, 0, //
        0,    0, 0x01, 0, 'O', 0, 'p', 0, 'e', 0, 'n', 0, 0, 0, //
        0x80, 0, 0x03, 0, 'H', 0, 'e', 0, 'l', 0, 'p', 0, 0, 0,
    },
    // Tab, quote, backslash and a control character in the item name.
    &.{ 0, 0, 0, 0, 0x80, 0, 0x07, 0, 0x4F, 0, 0x09, 0, 0x22, 0, 0x5c, 0, 0x1b, 0, 0, 0 },
    // Header only: no items at all.
    &.{ 0, 0, 0, 0 },
};

/// Errors that mean the parser misbehaved rather than rejected the input.
pub const Failure = error{
    MenuOutputNotValidJson,
    MenuOutputNotAnObject,
    MenuOutputMissingType,
    MenuOutputTypeMismatch,
    MenuOutputMissingItems,
    MenuOutputItemsNotAnArray,
    /// Reported by the allocator, not by a parser contract violation.
    OutOfMemory,
};

/// Runs one input through the parser and checks the parser/JSON contract:
/// anything the parser accepts must render as a menu object. Without this the
/// fuzzer only proves absence of crashes, not of bad output.
pub fn harness(allocator: std.mem.Allocator, data: []const u8) Failure!void {
    const json = menu.parseMenuResource(allocator, data) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        // InvalidMenuResource, MenuNestingTooDeep and the invalid-UTF-16
        // errors are the documented rejections of malformed input.
        else => return,
    };
    defer allocator.free(json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return error.MenuOutputNotValidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MenuOutputNotAnObject;

    const type_value = parsed.value.object.get("type") orelse return error.MenuOutputMissingType;
    if (type_value != .string) return error.MenuOutputTypeMismatch;
    if (!std.mem.eql(u8, type_value.string, "menu")) return error.MenuOutputTypeMismatch;

    const items = parsed.value.object.get("menu") orelse return error.MenuOutputMissingItems;
    if (items != .array) return error.MenuOutputItemsNotAnArray;
}
