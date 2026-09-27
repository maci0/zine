//! Regression tests for the fuzz harnesses.
//!
//! These replay the seed corpora and a deterministic mutation sweep under
//! `std.testing.allocator`, so a leak or a broken parser/JSON contract fails
//! `zig build test` rather than only surfacing under a coverage-guided fuzzer.
//! A minimized input from `zig-out/fuzz/` belongs in one of the seed arrays.

const std = @import("std");
const testing = std.testing;
const mutation = @import("mutation.zig");
const seed_source = @import("seed.zig");
const bat_fuzz = @import("bat.zig");
const dialog_fuzz = @import("dialog.zig");
const icon_fuzz = @import("icon.zig");
const loadstring_fuzz = @import("loadstring.zig");
const menu_fuzz = @import("menu.zig");
const pe_fuzz = @import("pe.zig");

/// Mutations replayed per target in CI. Small enough to keep the unit-test
/// gate fast, large enough to reach the truncation and boundary paths.
const replay_iterations = 5000;

fn replay(
    seeds: []const []const u8,
    comptime run: fn (std.mem.Allocator, []u8) anyerror!void,
) !void {
    // The same seed `zig build fuzz` streams from (seed.default), so an input
    // the driver blamed is one of the inputs this sweep derives.
    var prng = std.Random.DefaultPrng.init(seed_source.default);
    const rand = prng.random();
    var buffer: [mutation.max_input_len]u8 = undefined;

    for (seeds) |seed| {
        try run(testing.allocator, mutation.loadSeed(&buffer, seed));
    }
    for (0..replay_iterations) |i| {
        const input = mutation.loadSeed(&buffer, seeds[i % seeds.len]);
        const len = mutation.apply(rand, input);
        try run(testing.allocator, input[0..len]);
    }
}

test "fuzz: menu seeds and mutations hold the parser contract" {
    try replay(&menu_fuzz.seeds, menu_fuzz.harness);
}

test "fuzz: dialog seeds and mutations hold the parser contract" {
    try replay(&dialog_fuzz.seeds, dialog_fuzz.harness);
}

test "fuzz: icon seeds and mutations hold the parser contract" {
    try replay(&icon_fuzz.seeds, icon_fuzz.harness);
}

test "fuzz: pe seeds and mutations hold the parser contract" {
    try replay(&pe_fuzz.seeds, pe_fuzz.harness);
}

test "fuzz: loadstring seeds and mutations hold the parser contract" {
    try replay(&loadstring_fuzz.seeds, loadstring_fuzz.harness);
}

test "fuzz: bat seeds and mutations hold the interpreter contract" {
    try replay(&bat_fuzz.seeds, bat_fuzz.harness);
}

test "loadstring: a well-formed string table yields its strings" {
    const resource = @import("../win32/user32/resource.zig");
    const image = loadstring_fuzz.seeds[0];

    for (loadstring_fuzz.seed_strings, 0..) |expected, uID| {
        var narrow: [64]u8 = undefined;
        const len = resource.loadStringFromImage(image, @intCast(uID), &narrow, narrow.len);
        var want: [64]u8 = undefined;
        for (expected, 0..) |wc, i| want[i] = @intCast(wc & 0xFF);
        try testing.expectEqualStrings(want[0..expected.len], narrow[0..len]);
        try testing.expectEqual(@as(u8, 0), narrow[len]);

        var wide: [64]u16 = undefined;
        const wide_len = resource.loadStringFromImageW(image, @intCast(uID), &wide, wide.len);
        try testing.expectEqualSlices(u16, expected, wide[0..wide_len]);
    }

    // A block the image does not hold must resolve to nothing, not to a
    // neighbouring string.
    var narrow: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), resource.loadStringFromImage(image, 0x20, &narrow, narrow.len));
}
