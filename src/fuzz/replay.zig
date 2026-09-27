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
const export_fuzz = @import("export.zig");
const resource_fuzz = @import("resource.zig");

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

test "fuzz: resource seeds and mutations hold the lookup contract" {
    try replay(&resource_fuzz.seeds, resource_fuzz.harness);
}

test "fuzz: export seeds and mutations hold the lookup contract" {
    try replay(&export_fuzz.seeds, export_fuzz.harness);
}

test "export: the seed directory resolves its names and rejects the rest" {
    // The mutations only reach the function table if the seeds do, so pin the
    // lookups the seed directory is built to satisfy.
    const module = @import("../loader/module.zig");
    const image = export_fuzz.seeds[0];
    const rva = std.mem.readInt(u32, image[0..4], .little);
    const size = std.mem.readInt(u32, image[4..8], .little);

    try testing.expectEqual(@as(u32, 0x800), module.findExportRvaInImage(image, rva, size, "ZineFirst").?);
    try testing.expectEqual(@as(u32, 0x900), module.findExportRvaInImage(image, rva, size, "ZineSecond").?);
    // The name compare is exact, so a different case is a different export.
    try testing.expectEqual(@as(?u32, null), module.findExportRvaInImage(image, rva, size, "zinethird2"));
    try testing.expectEqual(@as(?u32, null), module.findExportRvaInImage(image, rva, size, "Missing"));
    try testing.expectEqual(@as(?u32, null), module.findExportRvaInImage(image, 0, size, "ZineFirst"));
}

test "resource: the seed tree resolves by id and by name" {
    // The mutations only reach the data entry if the seeds do, so pin the
    // lookups the seed tree is built to satisfy.
    const module = @import("../loader/module.zig");
    const pe_resources = @import("../pe_resources.zig");
    const image = resource_fuzz.seeds[0];
    const res_rva = std.mem.readInt(u32, image[0..4], .little);

    try testing.expectEqualStrings("ICONDATA", module.findResourceInImage(image, res_rva, pe_resources.RT_ICON, 1).?);
    try testing.expectEqualStrings("ICONDATA", module.findFirstResourceInImage(image, res_rva, pe_resources.RT_ICON).?);
    try testing.expectEqualStrings("NAMEDATA", module.findResourceByNameInImage(image, res_rva, pe_resources.RT_DIALOG, "mainicon").?);
    // Nothing the tree does not hold resolves, and a directory RVA outside
    // the image walks nothing at all.
    try testing.expectEqual(@as(?[]const u8, null), module.findResourceInImage(image, res_rva, pe_resources.RT_ICON, 2));
    try testing.expectEqual(@as(?[]const u8, null), module.findResourceInImage(image, 0xFFFF_0000, pe_resources.RT_ICON, 1));
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
