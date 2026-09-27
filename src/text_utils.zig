//! UTF-16 ↔ UTF-8 conversion for the Win32 `W` API boundary.
//!
//! Guest wide strings are UTF-16LE; everything downstream (control text
//! stores, renderer text, JSON payloads to the web UI, host paths) is UTF-8,
//! so the conversion happens once, here, rather than at each call site.
//!
//! Two rules apply to every direction:
//!   * An unpaired surrogate has no UTF-8 form and decodes to U+FFFD instead
//!     of failing. A guest is free to pass a lone half, and dropping the
//!     whole string over one bad unit loses every other character in it.
//!   * A fixed-size destination stops on a code point boundary. Cutting a
//!     sequence mid-way would hand the next layer invalid UTF-8.
//!
//! The host filesystem is UTF-8, so `W` path APIs convert straight to UTF-8
//! rather than to CP1252; see `src/win32/ansi.zig` for the ANSI side.

const std = @import("std");
const unicase = @import("win32/unicase.zig");

/// U+FFFD REPLACEMENT CHARACTER, the substitution for an unpaired surrogate.
const replacement: u21 = 0xFFFD;

/// Decode one UTF-16 sequence starting at `i`, returning the code point and
/// the index of the last code unit it consumed. An unpaired surrogate
/// decodes to U+FFFD and consumes one unit.
fn nextCodepoint(wide: []const u16, i: usize) struct { cp: u21, next: usize } {
    const unit = wide[i];
    if (unit >= 0xD800 and unit < 0xDC00) {
        if (i + 1 < wide.len and wide[i + 1] >= 0xDC00 and wide[i + 1] < 0xE000) {
            const cp: u21 = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (@as(u21, wide[i + 1]) - 0xDC00);
            return .{ .cp = cp, .next = i + 2 };
        }
        return .{ .cp = replacement, .next = i + 1 };
    }
    if (unit >= 0xDC00 and unit < 0xE000) return .{ .cp = replacement, .next = i + 1 };
    return .{ .cp = unit, .next = i + 1 };
}

/// Convert UTF-16 to UTF-8 in `out`, stopping on a code point boundary when
/// `out` runs out of room. Returns the written prefix.
pub fn wideToUtf8(wide: []const u16, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < wide.len) {
        const step = nextCodepoint(wide, i);
        i = step.next;
        const width = std.unicode.utf8CodepointSequenceLength(step.cp) catch break;
        if (n + width > out.len) break;
        n += std.unicode.utf8Encode(step.cp, out[n..]) catch break;
    }
    return out[0..n];
}

/// Encode one code point as UTF-16 (1 or 2 code units, surrogate pair).
/// Surrogate code points never reach here: `nextCodepoint` replaces them.
fn encodeUtf16(cp: u21, out: *[2]u16) usize {
    if (cp < 0x10000) {
        out[0] = @intCast(cp);
        return 1;
    }
    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

/// Convert UTF-8 to UTF-16 in `out`, stopping before a code unit that does
/// not fit. Invalid UTF-8 decodes to U+FFFD one byte at a time, so a store
/// that was corrupted upstream still yields displayable text. Returns the
/// number of code units written.
pub fn utf8ToWide(utf8: []const u8, out: []u16) usize {
    var pos: usize = 0;
    const view = std.unicode.Utf8View.init(utf8) catch {
        for (utf8) |b| {
            var pair: [2]u16 = undefined;
            const n = encodeUtf16(if (b < 0x80) b else replacement, &pair);
            if (pos + n > out.len) break;
            for (pair[0..n]) |u| {
                out[pos] = u;
                pos += 1;
            }
        }
        return pos;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        var pair: [2]u16 = undefined;
        const n = encodeUtf16(cp, &pair);
        if (pos + n > out.len) break;
        for (pair[0..n]) |u| {
            out[pos] = u;
            pos += 1;
        }
    }
    return pos;
}

/// The longest prefix of `text` that fits in `max` bytes without splitting a
/// UTF-8 sequence. Used to truncate text into fixed-size stores.
pub fn truncateUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// Copy `src` into `dst` as a NUL-terminated string, cutting on a UTF-8 code
/// point boundary so the C side never sees half a character. `dst` must be
/// non-empty: one byte is always reserved for the terminator. Returns the
/// number of bytes copied, excluding the terminator.
pub fn copyCString(dst: []u8, src: []const u8) usize {
    const cut = truncateUtf8(src, dst.len - 1);
    @memcpy(dst[0..cut.len], cut);
    dst[cut.len] = 0;
    return cut.len;
}

/// Case-insensitive UTF-8 comparison, case-folding per code point. Win32
/// names files case-insensitively, so a guest opening "CAFÉ.TXT" must find
/// "café.txt" on disk; byte-wise ASCII folding alone misses the accent and
/// every non-ASCII letter.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    const a_view = std.unicode.Utf8View.init(a) catch return false;
    const b_view = std.unicode.Utf8View.init(b) catch return false;
    var a_it = a_view.iterator();
    var b_it = b_view.iterator();
    while (true) {
        const lhs = a_it.nextCodepoint();
        const rhs = b_it.nextCodepoint();
        if (lhs == null and rhs == null) return true;
        const l = lhs orelse return false;
        const r = rhs orelse return false;
        if (foldCodepoint(l) != foldCodepoint(r)) return false;
    }
}

/// The Win32 upper/lower APIs fold UTF-16 code units, so a code point outside
/// the BMP folds per its leading surrogate, which is enough for a case
/// decision.
fn foldCodepoint(cp: u21) u16 {
    const unit: u16 = if (cp < 0x10000) @intCast(cp) else @intCast(0xD800 + ((cp - 0x10000) >> 10));
    return unicase.foldKey(unit);
}

const testing = std.testing;

test "wideToUtf8 combines surrogate pairs" {
    const wide = [_]u16{ 0xD83D, 0xDE00, 'a' }; // U+1F600 then 'a'
    var out: [8]u8 = undefined;
    try testing.expectEqualStrings("\u{1F600}a", wideToUtf8(&wide, &out));
}

test "wideToUtf8 substitutes unpaired surrogates instead of failing" {
    // A lone high half and a lone low half each decode to U+FFFD, and the
    // characters around them survive.
    const wide = [_]u16{ 'a', 0xD800, 'b', 0xDC00, 'c' };
    var out: [16]u8 = undefined;
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c", wideToUtf8(&wide, &out));
}

test "wideToUtf8 stops on a code point boundary" {
    // 200 CJK characters need 600 UTF-8 bytes and do not fit in 512.
    var wide: [200]u16 = undefined;
    @memset(&wide, 0x4F60);
    var out: [512]u8 = undefined;
    const written = wideToUtf8(&wide, &out);
    try testing.expectEqual(@as(usize, 510), written.len);
    _ = try std.unicode.Utf8View.init(written);
}

test "truncateUtf8 never splits a code point" {
    // "ab" + U+00E9 (2 bytes) + U+4F60 (3 bytes)
    const s = "ab\u{00e9}\u{4f60}";
    try testing.expectEqualStrings("ab", truncateUtf8(s, 3));
    try testing.expectEqualStrings("ab\u{00e9}", truncateUtf8(s, 4));
    try testing.expectEqualStrings("ab\u{00e9}", truncateUtf8(s, 5));
    try testing.expectEqualStrings("ab\u{00e9}", truncateUtf8(s, 6));
    try testing.expectEqualStrings(s, truncateUtf8(s, 100));
}

test "copyCString terminates without splitting a character" {
    var buf: [4]u8 = undefined;
    // Three bytes of room: the two-byte é would not fit after "ab", so the
    // cut lands before it and leaves a decodable string behind.
    try testing.expectEqual(@as(usize, 2), copyCString(&buf, "ab\u{00e9}cd"));
    try testing.expectEqualStrings("ab", std.mem.span(@as([*:0]const u8, @ptrCast(&buf))));
    try testing.expectEqual(@as(usize, 3), copyCString(&buf, "abcde"));
    try testing.expectEqualStrings("abc", std.mem.span(@as([*:0]const u8, @ptrCast(&buf))));
    // A single-byte buffer holds nothing but the terminator.
    var one: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), copyCString(&one, "abc"));
    try testing.expectEqual(@as(u8, 0), one[0]);
}

test "utf8ToWide encodes astral characters as surrogate pairs" {
    var out: [4]u16 = undefined;
    const n = utf8ToWide("a\u{1F600}", &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u16, 'a'), out[0]);
    try testing.expectEqual(@as(u16, 0xD83D), out[1]);
    try testing.expectEqual(@as(u16, 0xDE00), out[2]);
}

test "utf8ToWide round-trips through wideToUtf8" {
    var wide: [8]u16 = undefined;
    const n = utf8ToWide("héllo \u{4f60}", &wide);
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("héllo \u{4f60}", wideToUtf8(wide[0..n], &out));
}

test "utf8ToWide stops before a code unit that does not fit" {
    var out: [1]u16 = undefined;
    // The emoji needs two units; only the 'a' fits.
    try testing.expectEqual(@as(usize, 1), utf8ToWide("a\u{1F600}", &out));
    try testing.expectEqual(@as(u16, 'a'), out[0]);
}

test "eqlIgnoreCase folds non-ASCII letters" {
    try testing.expect(eqlIgnoreCase("CAFÉ.TXT", "café.txt"));
    try testing.expect(eqlIgnoreCase("ReadMe.TXT", "readme.txt"));
    // Different lengths and different letters stay distinct.
    try testing.expect(!eqlIgnoreCase("café.txt", "cafe.txt"));
    try testing.expect(!eqlIgnoreCase("readme.txt", "readme.tx"));
}

test "eqlIgnoreCase rejects invalid UTF-8 rather than matching" {
    try testing.expect(!eqlIgnoreCase("\xC3", "\xC3"));
    try testing.expect(eqlIgnoreCase("\xC3\xA9", "\xC3\xA9"));
}
