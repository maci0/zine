//! JSON emission shared by the PE resource parsers.
//!
//! Resource names, class names and control text come from the PE image and are
//! untrusted. Escaping them once here keeps a byte that JSON.parse rejects out
//! of every message the parsers build, instead of leaving each parser to
//! reimplement the rules and drift.

const std = @import("std");

/// Writes `text` as the body of a JSON string, escaping quotes, backslashes
/// and control characters. The caller writes the surrounding quotes.
pub fn writeJsonString(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |char| {
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
}

const testing = std.testing;

fn escaped(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeJsonString(&aw.writer, text);
    var list = aw.toArrayList();
    return list.toOwnedSlice(allocator);
}

test "writeJsonString escapes quotes, backslashes and control bytes" {
    const out = try escaped(testing.allocator, "a\"b\\c\x01\x1b");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\\\"b\\\\c\\u0001\\u001b", out);
}

test "writeJsonString leaves UTF-8 text alone" {
    const out = try escaped(testing.allocator, "héllo \u{4f60}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("héllo \u{4f60}", out);
}

test "writeJsonString output parses back to the original string" {
    const out = try escaped(testing.allocator, "quote\" back\\slash \x07 \u{10400}");
    defer testing.allocator.free(out);
    const json = try testing.allocator.print("\"{s}\"", .{out});
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice([]const u8, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("quote\" back\\slash \x07 \u{10400}", parsed.value);
}
