//! Windows ANSI code page (CP1252, the value GetACP reports) conversion.
//!
//! Guest strings that cross an `*A` API boundary are CP1252 bytes, not UTF-8.
//! Everything downstream of such a boundary (renderer text, control text
//! stores, JSON payloads to the web UI) is UTF-8, so the conversion happens
//! once, here, rather than at each call site.

const std = @import("std");

/// The ANSI code page Zine reports and converts for, matching kernel32.GetACP.
pub const code_page: u32 = 1252;

/// Unmappable substitution for WideCharToMultiByte without WC_NO_BEST_FIT_CHARS.
pub const default_char: u8 = '?';

/// CP1252 mappings for bytes 0x80..0x9F. Outside that range the code page is
/// identical to Latin-1, so 0x00..0x7F and 0xA0..0xFF map to their byte value.
const upper_table = [32]u16{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

/// Decode one CP1252 byte to a Unicode code point. Undefined bytes (0x81,
/// 0x8D, 0x8F, 0x90, 0x9D) have no CP1252 character and decode to the
/// matching C1 control, as the Windows API does.
pub fn byteToCodepoint(b: u8) u21 {
    if (b >= 0x80 and b < 0xA0) return upper_table[b - 0x80];
    return b;
}

/// Encode one code point to CP1252, or null when the code page has no
/// character for it (callers substitute default_char).
pub fn codepointToByte(cp: u21) ?u8 {
    if (cp < 0x80 or (cp >= 0xA0 and cp <= 0xFF)) return @intCast(cp);
    for (upper_table, 0..) |u, i| {
        if (u == cp and cp >= 0xA0) return @intCast(0x80 + i);
    }
    return null;
}

/// Decode a CP1252 string into `out` as UTF-8, stopping on a character
/// boundary if `out` runs out of room. Returns the written prefix of `out`.
pub fn toUtf8(ansi: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (ansi) |b| {
        const cp = byteToCodepoint(b);
        const width = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
        if (n + width > out.len) break;
        n += std.unicode.utf8Encode(cp, out[n..]) catch continue;
    }
    return out[0..n];
}

/// Encode a UTF-8 string into `out` as CP1252, substituting default_char for
/// code points the code page cannot represent. A multi-byte character that
/// does not fit in the remaining room ends the output rather than being
/// split. Returns the written prefix of `out`.
pub fn fromUtf8(utf8: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(utf8) catch {
        // Not valid UTF-8: pass the bytes through unchanged rather than
        // dropping the text, matching what the guest handed us.
        const copied = @min(utf8.len, out.len);
        @memcpy(out[0..copied], utf8[0..copied]);
        return out[0..copied];
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (n >= out.len) break;
        out[n] = codepointToByte(cp) orelse default_char;
        n += 1;
    }
    return out[0..n];
}

/// The longest prefix of `text` that fits in `max` bytes without splitting a
/// UTF-8 sequence. Used to truncate text into fixed-size stores.
pub fn truncateUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// Encode a UTF-16 string into `out` as CP1252, the width a wide `W` API
/// string would have in its narrow form. Surrogate pairs are combined first,
/// so a character outside the BMP encodes as the default character per code
/// point rather than as two broken halves; a surrogate pair the code page
/// cannot represent likewise becomes one default character. Returns the
/// written prefix of `out`.
pub fn wideToAnsi(wide: []const u16, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < wide.len) {
        var cp: u21 = wide[i];
        i += 1;
        if (cp >= 0xD800 and cp < 0xDC00) {
            if (i < wide.len and wide[i] >= 0xDC00 and wide[i] < 0xE000) {
                cp = 0x10000 + ((@as(u21, cp) - 0xD800) << 10) + (@as(u21, wide[i]) - 0xDC00);
                i += 1;
            } else {
                cp = 0xFFFD;
            }
        } else if (cp >= 0xDC00 and cp < 0xE000) {
            cp = 0xFFFD;
        }
        if (n >= out.len) break;
        out[n] = codepointToByte(cp) orelse default_char;
        n += 1;
    }
    return out[0..n];
}

test "cp1252 round trip for the 0x80..0x9F range" {
    for (0x80..0xA0) |i| {
        const b: u8 = @intCast(i);
        const cp = byteToCodepoint(b);
        var utf8_buf: [4]u8 = undefined;
        const decoded = toUtf8(&[_]u8{b}, &utf8_buf);
        var expected: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &expected) catch unreachable;
        try std.testing.expectEqualSlices(u8, expected[0..n], decoded);

        var back: [4]u8 = undefined;
        // The five undefined CP1252 bytes have no reverse mapping and are
        // replaced by default_char, as Windows does.
        if (codepointToByte(cp) != null) {
            try std.testing.expectEqualSlices(u8, &[_]u8{b}, fromUtf8(decoded, &back));
        } else {
            try std.testing.expectEqualSlices(u8, &[_]u8{default_char}, fromUtf8(decoded, &back));
        }
    }
}

test "latin-1 range is identical to the byte value" {
    for (0xA0..0x100) |i| {
        const b: u8 = @intCast(i);
        try std.testing.expectEqual(@as(u21, b), byteToCodepoint(b));
        try std.testing.expectEqual(@as(?u8, b), codepointToByte(b));
    }
}

test "euro sign decodes to U+20AC and encodes back to 0x80" {
    try std.testing.expectEqual(@as(u21, 0x20AC), byteToCodepoint(0x80));
    try std.testing.expectEqual(@as(?u8, 0x80), codepointToByte(0x20AC));

    var out: [8]u8 = undefined;
    const decoded = toUtf8("\x80", &out);
    try std.testing.expectEqualStrings("\u{20AC}", decoded);

    var back: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\x80", fromUtf8(decoded, &back));
}

test "characters outside cp1252 become the default char" {
    var out: [8]u8 = undefined;
    // Japanese has no CP1252 representation: one default char per code point.
    try std.testing.expectEqualStrings("??", fromUtf8("\u{4f60}\u{597d}", &out));
    // The euro sign is representable, so it survives the round trip.
    try std.testing.expectEqualStrings("\x80", fromUtf8("\u{20AC}", &out));
}

test "truncateUtf8 never splits a code point" {
    // "ab" + U+00E9 (2 bytes) + U+4F60 (3 bytes)
    const s = "ab\u{00e9}\u{4f60}";
    try std.testing.expectEqualStrings("ab", truncateUtf8(s, 3));
    try std.testing.expectEqualStrings("ab\u{00e9}", truncateUtf8(s, 4));
    try std.testing.expectEqualStrings("ab\u{00e9}", truncateUtf8(s, 5));
    try std.testing.expectEqualStrings("ab\u{00e9}", truncateUtf8(s, 6));
    try std.testing.expectEqualStrings(s, truncateUtf8(s, 100));
}

test "wideToAnsi keeps Latin-1 characters and substitutes the rest" {
    var out: [16]u8 = undefined;
    const path = [_:0]u16{ 'C', ':', '\\', 'c', 'a', 'f', 0x00E9, '.', 't', 'x', 't' };
    // C:\café.txt survives, since CP1252 is Latin-1 above 0xA0.
    try std.testing.expectEqualStrings("C:\\caf\xE9.txt", wideToAnsi(&path, &out));
    // A CJK character is not the low byte of its code point.
    const cjk = [_:0]u16{0x4f60};
    try std.testing.expectEqualStrings("?", wideToAnsi(&cjk, &out));
    // A surrogate pair is one character, so it is one default character.
    const emoji = [_:0]u16{ 0xD83D, 0xDE00 };
    try std.testing.expectEqualStrings("?", wideToAnsi(&emoji, &out));
    // An unpaired half is not silently dropped.
    const lone = [_:0]u16{ 'a', 0xD800, 'b' };
    try std.testing.expectEqualStrings("a?b", wideToAnsi(&lone, &out));
}

test "wideToAnsi stops when out is full" {
    var out: [2]u8 = undefined;
    const text = [_:0]u16{ 'a', 'b', 'c' };
    try std.testing.expectEqualStrings("ab", wideToAnsi(&text, &out));
}
