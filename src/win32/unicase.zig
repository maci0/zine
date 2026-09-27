//! Simple (single code point) Unicode case mapping for the case-folding the
//! Win32 and MSVCRT string APIs need: LCMapString, CompareString, lstrcmpi,
//! wcsicmp, towupper/towlower.
//!
//! Covers ASCII, Latin-1 Supplement, Latin Extended-A, Greek and Cyrillic.
//! Characters whose case mapping changes length (German sharp s uppercasing to
//! "SS", final sigma to sigma) have no simple mapping and are returned
//! unchanged, which is what a one-code-point mapping can express.

const std = @import("std");
const ansi = @import("ansi.zig");

/// A contiguous block where the code points alternate upper, lower, upper,
/// lower, ... starting at `start` with the case named by `upper_first`.
const PairBlock = struct {
    start: u16,
    end: u16,
    upper_first: bool,
};

const pair_blocks = [_]PairBlock{
    // Latin Extended-A: uppercase, lowercase, uppercase, ... from each block
    // start. 0x0138 and 0x0149 are lone lowercase forms, and 0x014A pairs with
    // 0x0149 rather than with its own block, so all three are handled apart
    // from the table.
    .{ .start = 0x0100, .end = 0x0137, .upper_first = true },
    .{ .start = 0x0139, .end = 0x0148, .upper_first = true },
    .{ .start = 0x014A, .end = 0x0177, .upper_first = true },
    .{ .start = 0x0179, .end = 0x017E, .upper_first = true },
    // Cyrillic, from 0x0460 up: adjacent pairs, even=upper except
    // 0x04C1-0x04CE (Yo and the letters derived from it), which is odd=upper.
    // The 0x0400-0x045F block is two parallel halves, handled by fixed offsets
    // rather than by this table, and 0x048A-0x04BF, 0x04C0/0x04CF do not
    // alternate cleanly and stay unmapped.
    .{ .start = 0x0460, .end = 0x0481, .upper_first = true },
    .{ .start = 0x04C2, .end = 0x04CE, .upper_first = false },
    .{ .start = 0x04D0, .end = 0x052F, .upper_first = true },
};

/// Code points whose case partner sits outside their block, so pairedCase
/// must leave them alone: y diaeresis (0x0178, whose partner 0x00FF is handled
/// in toUpper/toLower), Eng (0x014A) and yo (0x04C1/0x04C2).
const unpaired = [_]u16{ 0x014A, 0x0178, 0x04C1, 0x04C2 };

fn pairedCase(c: u16) ?u16 {
    for (unpaired) |u| {
        if (c == u) return null;
    }
    for (pair_blocks) |b| {
        if (c < b.start or c > b.end) continue;
        const is_upper = ((c - b.start) % 2 == 0) == b.upper_first;
        return if (is_upper) c +% 1 else c -% 1;
    }
    return null;
}

/// Simple uppercase mapping: the single code point `c` maps to, or `c` when
/// no single code point maps to it.
pub fn toUpper(c: u16) u16 {
    if (c >= 'a' and c <= 'z') return c - 0x20;
    if (c < 0x80) return c;

    // Latin-1 Supplement, excluding the signs (0xD7, 0xF7) and sharp s (0xDF),
    // which has no single code point uppercase mapping.
    if (c >= 0xE0 and c <= 0xFE and c != 0xF7) return c - 0x20;
    if (c == 0xFF) return 0x178;

    if (c == 0x04C2) return 0x04C1; // yo
    if (c >= 0x0100 and c <= 0x017E) {
        if (c == 0x0130 or c == 0x0131 or c == 0x0138 or c == 0x0149) return c;
        return pairedCase(c) orelse c;
    }

    // Greek, with 0x03C2 (final sigma) mapping to 0x03A3 outside the
    // final-letter pair and 0x03D8/0x03D9 handled with their block.
    if (c == 0x03C2) return 0x03A3;
    if (c >= 0x03B1 and c <= 0x03C1) return c - 0x20;
    if (c >= 0x03C3 and c <= 0x03CB) return c - 0x20;
    if (c == 0x03AC) return 0x0386;
    if (c >= 0x03AD and c <= 0x03AF) return c - 0x25; // to 0x0388-0x038A
    if (c == 0x03CC) return 0x038C;
    if (c == 0x03CD) return 0x038E;
    if (c == 0x03CE) return 0x038F;

    // Cyrillic: 0x0430-0x044F are the lowercase of 0x0410-0x042F, and
    // 0x0450-0x045F the lowercase of 0x0400-0x040F.
    if (c >= 0x0430 and c <= 0x044F) return c - 0x20;
    if (c >= 0x0450 and c <= 0x045F) return c - 0x50;
    if (c >= 0x0460 and c <= 0x052F) return pairedCase(c) orelse c;

    return c;
}

/// Simple lowercase mapping: the single code point `c` maps to, or `c` when
/// no single code point maps to it.
pub fn toLower(c: u16) u16 {
    if (c >= 'A' and c <= 'Z') return c + 0x20;
    if (c < 0x80) return c;

    if (c >= 0xC0 and c <= 0xDE and c != 0xD7) return c + 0x20;
    if (c == 0x0178) return 0x00FF; // y diaeresis
    if (c == 0x014A) return 0x0149; // Eng, whose partner has no uppercase
    if (c == 0x04C1) return 0x04C2; // yo

    if (c >= 0x0100 and c <= 0x17E) {
        if (c == 0x0130 or c == 0x0131 or c == 0x0138 or c == 0x0149) return c;
        return pairedCase(c) orelse c;
    }

    if (c >= 0x0391 and c <= 0x03A1) return c + 0x20;
    if (c >= 0x03A3 and c <= 0x03AB) return c + 0x20;
    if (c == 0x0386) return 0x03AC;
    if (c >= 0x0388 and c <= 0x038A) return c + 0x25;
    if (c == 0x038C) return 0x03CC;
    if (c == 0x038E) return 0x03CD;
    if (c == 0x038F) return 0x03CE;

    if (c >= 0x0410 and c <= 0x042F) return c + 0x20;
    if (c >= 0x0400 and c <= 0x040F) return c + 0x50;
    if (c >= 0x0460 and c <= 0x052F) return pairedCase(c) orelse c;

    return c;
}

/// Case-insensitive comparison key for one UTF-16 code unit. Case mapping is
/// not symmetric for every character (German sharp s uppercases to two code
/// points), so comparing the lowercase forms is the stable direction; an
/// unpaired uppercase code unit keeps its own value.
pub fn foldKey(c: u16) u16 {
    return toLower(c);
}

// --- Locale-sensitive case mapping ---
//
// The mappings above are the Unicode default ones, which Turkish and Azerbaijani
// override for the letter I: 'I' lowercases to dotless 0x131 rather than 'i', and
// 'i' uppercases to dotted 0x130 rather than 'I'. LCMapString and CompareString
// take a locale for exactly this reason, so the mapping is selected by the
// caller's locale rather than fixed.

// LANG_TR and LANG_AZ share the dotted/dotless I rules.
const LANG_TURKISH: u16 = 0x041F;
const LANG_AZERBAIJANI: u16 = 0x042C;

// The primary language ID of an LCID, with LOCALE_USER_DEFAULT (0x0400) and
// LOCALE_NAME_DEFAULT (0x1000) resolving to the emulated en-US locale.
pub const LANG_ENGLISH_US: u16 = 0x0409;
const LANG_NEUTRAL: u16 = 0x0400;
const LOCALE_NAME_DEFAULT: u32 = 0x1000;

fn usesDotlessI(lcid: u32) bool {
    const lang: u16 = switch (lcid) {
        LANG_NEUTRAL, LOCALE_NAME_DEFAULT => LANG_ENGLISH_US,
        else => @truncate(lcid),
    };
    return lang == LANG_TURKISH or lang == LANG_AZERBAIJANI;
}

/// Lowercase mapping as `locale` (an LCID) requires. A Turkish or Azerbaijani
/// locale maps 'I' to dotless 0x131 and 0x130 to 'i'; every other locale uses
/// the Unicode default mapping.
pub fn toLowerForLocale(c: u16, lcid: u32) u16 {
    if (!usesDotlessI(lcid)) return toLower(c);
    if (c == 'I') return 0x131;
    if (c == 0x130) return 'i';
    return toLower(c);
}

/// Uppercase mapping as `locale` (an LCID) requires. A Turkish or Azerbaijani
/// locale maps 'i' to dotted 0x130 and 0x131 to 'I'; every other locale uses
/// the Unicode default mapping.
pub fn toUpperForLocale(c: u16, lcid: u32) u16 {
    if (!usesDotlessI(lcid)) return toUpper(c);
    if (c == 'i') return 0x130;
    if (c == 0x131) return 'I';
    return toUpper(c);
}

/// Case-insensitive comparison key for one UTF-16 code unit under `locale`.
/// Comparing lowercase forms is the stable direction; see `foldKey`.
pub fn foldKeyForLocale(c: u16, lcid: u32) u16 {
    return toLowerForLocale(c, lcid);
}

/// Primary language IDs reachable by locale name, for the languages whose
/// case mapping differs from the Unicode default. Every other locale name
/// resolves to the emulated default, whose mapping is the default one.
const NamedLanguage = struct { name: []const u8, lcid: u16 };
const named_languages = [_]NamedLanguage{
    .{ .name = "tr", .lcid = LANG_TURKISH },
    .{ .name = "az", .lcid = LANG_AZERBAIJANI },
};

/// The LCID for a BCP-47 or POSIX locale name ("tr-TR", "tr_TR", "tr"),
/// comparing language subtags case-insensitively as BCP-47 requires. Names
/// whose language has no special case mapping return the emulated default.
pub fn lcidFromLocaleName(name: []const u8) u32 {
    const lang = name[0..@min(name.len, langSubtagLen(name))];
    for (named_languages) |entry| {
        if (std.ascii.eqlIgnoreCase(lang, entry.name)) return entry.lcid;
    }
    return LANG_ENGLISH_US;
}

/// Length of the language subtag: everything before the first "-" or "_".
fn langSubtagLen(name: []const u8) usize {
    for (name, 0..) |c, i| {
        if (c == '-' or c == '_') return i;
    }
    return name.len;
}

/// Lowercase one CP1252 byte, mapping the byte through the ANSI code page so
/// accented Latin characters fold the way the wide comparison folds them.
/// CP1252 has no 0x130 or 0x131, so this mapping is the same in every locale.
pub fn toLowerAnsiByte(b: u8) u8 {
    const folded = toLower(@as(u16, @intCast(ansi.byteToCodepoint(b))));
    return ansi.codepointToByte(folded) orelse b;
}

/// Uppercase one CP1252 byte. Bytes with no encoding in the code page (the
/// 0x80-0x9F range) are returned unchanged.
pub fn toUpperAnsiByte(b: u8) u8 {
    const mapped = toUpper(@as(u16, @intCast(ansi.byteToCodepoint(b))));
    return ansi.codepointToByte(mapped) orelse b;
}

const testing = std.testing;

test "ASCII mapping is unchanged" {
    try testing.expectEqual(@as(u16, 'A'), toUpper('a'));
    try testing.expectEqual(@as(u16, 'z'), toLower('Z'));
    try testing.expectEqual(@as(u16, '0'), toUpper('0'));
    try testing.expectEqual(@as(u16, '~'), toLower('~'));
}

test "Latin-1 and Latin Extended-A mapping" {
    try testing.expectEqual(@as(u16, 0xC9), toUpper(0xE9)); // e acute
    try testing.expectEqual(@as(u16, 0xE9), toLower(0xC9));
    try testing.expectEqual(@as(u16, 0xC4), toUpper(0xE4)); // a diaeresis
    try testing.expectEqual(@as(u16, 0x100), toUpper(0x101)); // A with macron
    try testing.expectEqual(@as(u16, 0x101), toLower(0x100));
    try testing.expectEqual(@as(u16, 0x149), toLower(0x14A)); // Eng
    try testing.expectEqual(@as(u16, 0x149), toUpper(0x149)); // no simple uppercase
    try testing.expectEqual(@as(u16, 0x149), toLower(0x14A));
    try testing.expectEqual(@as(u16, 0x178), toUpper(0xFF)); // y diaeresis
    try testing.expectEqual(@as(u16, 0xFF), toLower(0x178));
    // Sharp s, dotted capital I and dotless i have no one-to-one swap here.
    try testing.expectEqual(@as(u16, 0xDF), toUpper(0xDF));
    try testing.expectEqual(@as(u16, 0x130), toLower(0x130));
}

test "Greek mapping, including final sigma" {
    try testing.expectEqual(@as(u16, 0x391), toUpper(0x3B1)); // alpha
    try testing.expectEqual(@as(u16, 0x3B1), toLower(0x391));
    try testing.expectEqual(@as(u16, 0x3A3), toUpper(0x3C2)); // final sigma
    try testing.expectEqual(@as(u16, 0x3C3), toLower(0x3A3)); // sigma
    try testing.expectEqual(@as(u16, 0x386), toUpper(0x3AC));
    try testing.expectEqual(@as(u16, 0x3AC), toLower(0x386));
    try testing.expectEqual(@as(u16, 0x38C), toUpper(0x3CC));
    try testing.expectEqual(@as(u16, 0x3CC), toLower(0x38C));
}

test "Cyrillic mapping" {
    try testing.expectEqual(@as(u16, 0x410), toUpper(0x430)); // a -> A
    try testing.expectEqual(@as(u16, 0x430), toLower(0x410));
    try testing.expectEqual(@as(u16, 0x401), toUpper(0x451)); // yo
    try testing.expectEqual(@as(u16, 0x451), toLower(0x401));
    try testing.expectEqual(@as(u16, 0x42F), toUpper(0x44F)); // ya
    try testing.expectEqual(@as(u16, 0x4C1), toUpper(0x4C2)); // Yo keeps odd=upper
    try testing.expectEqual(@as(u16, 0x4C2), toLower(0x4C1));
    try testing.expectEqual(@as(u16, 0x4D0), toUpper(0x4D1)); // A
}

test "every mapped code point round-trips through its inverse" {
    const ranges = [_][2]u16{ .{ 0x41, 0x5A }, .{ 0x61, 0x7A }, .{ 0xC0, 0xFF }, .{ 0x100, 0x17E }, .{ 0x386, 0x3FF }, .{ 0x400, 0x52F } };
    for (ranges) |r| {
        var c: u32 = r[0];
        while (c <= r[1]) : (c += 1) {
            const cp: u16 = @intCast(c);
            // These map to a partner that is itself unmapped, so the mapping
            // is one-way by construction.
            if (cp == 0x130 or cp == 0x131 or cp == 0x138 or cp == 0x139 or
                cp == 0x148 or cp == 0x149 or cp == 0x14A or cp == 0x14B or cp == 0x3C2) continue;
            const lower = toLower(cp);
            const upper = toUpper(cp);
            if (lower != cp) try testing.expectEqual(cp, toUpper(lower));
            if (upper != cp) try testing.expectEqual(cp, toLower(upper));
        }
    }
}

test "CP1252 byte mapping matches the wide mapping" {
    try testing.expectEqual(@as(u8, 0xC9), toUpperAnsiByte(0xE9));
    try testing.expectEqual(@as(u8, 0xE9), toLowerAnsiByte(0xC9));
    try testing.expectEqual(@as(u8, 'A'), toUpperAnsiByte('a'));
    // 0x81 has no CP1252 character, so it must survive the round trip.
    try testing.expectEqual(@as(u8, 0x81), toLowerAnsiByte(0x81));
}

test "non-Turkish locales keep the Unicode default I mapping" {
    for ([_]u32{ LANG_ENGLISH_US, 0x0407, 0x040C, LANG_NEUTRAL, LOCALE_NAME_DEFAULT }) |lcid| {
        try testing.expectEqual(@as(u16, 'i'), toLowerForLocale('I', lcid));
        try testing.expectEqual(@as(u16, 'I'), toUpperForLocale('i', lcid));
        try testing.expectEqual(@as(u16, 'i'), foldKeyForLocale('I', lcid));
    }
}

test "Turkish and Azerbaijani locales map I to dotless and i to dotted" {
    for ([_]u32{ 0x041F, 0x042C }) |lcid| {
        try testing.expectEqual(@as(u16, 0x131), toLowerForLocale('I', lcid));
        try testing.expectEqual(@as(u16, 'i'), toLowerForLocale(0x130, lcid));
        try testing.expectEqual(@as(u16, 0x130), toUpperForLocale('i', lcid));
        try testing.expectEqual(@as(u16, 'I'), toUpperForLocale(0x131, lcid));
    }
    // Folding 'I' to 0x131 and 0x131 to 0x131 makes a dotted and an undotted I
    // compare equal in a Turkish locale, as NORM_IGNORECASE requires.
    try testing.expectEqual(foldKeyForLocale('I', 0x041F), foldKeyForLocale(0x131, 0x041F));
    // Under the default mapping they do not, which is the bug this fixes.
    try testing.expect(foldKey('I') != foldKey(0x131));
}

test "the Turkish mapping leaves every other letter alone" {
    for ([_]u32{ 0x041F, 0x042C }) |lcid| {
        const ranges = [_][2]u16{ .{ 0x41, 0x5A }, .{ 0x61, 0x7A }, .{ 0xC0, 0xFF }, .{ 0x100, 0x17E }, .{ 0x400, 0x52F } };
        for (ranges) |r| {
            var c: u32 = r[0];
            while (c <= r[1]) : (c += 1) {
                const cp: u16 = @intCast(c);
                if (cp == 'I' or cp == 'i' or cp == 0x130 or cp == 0x131) continue;
                try testing.expectEqual(toLower(cp), toLowerForLocale(cp, lcid));
                try testing.expectEqual(toUpper(cp), toUpperForLocale(cp, lcid));
            }
        }
    }
}
