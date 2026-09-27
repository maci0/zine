//! Regression tests for the fuzz harnesses.
//!
//! These replay the seed corpora and a deterministic mutation sweep under
//! `std.testing.allocator`, so a leak or a broken parser/JSON contract fails
//! `zig build test` rather than only surfacing under a coverage-guided fuzzer.
//! A minimized input from `zig-out/fuzz/` belongs in one of the seed arrays.

const std = @import("std");
const testing = std.testing;
const mutation = @import("mutation.zig");
const menu_fuzz = @import("menu.zig");
const pe_fuzz = @import("pe.zig");

/// Mutations replayed per target in CI. Small enough to keep the unit-test
/// gate fast, large enough to reach the truncation and boundary paths.
const replay_iterations = 5000;

fn replay(
    seeds: []const []const u8,
    comptime run: fn (std.mem.Allocator, []u8) anyerror!void,
) !void {
    var prng = std.Random.DefaultPrng.init(0x5EED_F0_0D);
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

test "fuzz: pe seeds and mutations hold the parser contract" {
    try replay(&pe_fuzz.seeds, pe_fuzz.harness);
}
