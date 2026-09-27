//! The one seed the fuzz driver and the unit-test replay both stream from.
//!
//! `zig build fuzz` prints this value when `ZINE_FUZZ_SEED` is unset, and
//! `zig build test` mutates with the same number, so a mutation that breaks a
//! parser contract breaks for the same reason under both gates. Two literals
//! would let the gates explore different streams, and the input a fuzzer run
//! blamed would not be the input the unit test re-derives.

const std = @import("std");
const testing = std.testing;

/// Seed used when `ZINE_FUZZ_SEED` is unset. A fixed value, not a hash of a
/// constant string: the printed seed is what a failing run is replayed from,
/// so it has to be readable and settable.
pub const default: u64 = 0x5eed_f022_1ab7_5c0d;

/// Resolves the mutation stream's only entropy source. An unparsable value is
/// rejected rather than silently falling back, which would replay a different
/// stream than the one that failed.
pub fn fromEnv(text: ?[]const u8) !u64 {
    const value = text orelse return default;
    return std.fmt.parseInt(u64, value, 0) catch error.InvalidFuzzSeed;
}

test "seed: ZINE_FUZZ_SEED selects the stream, unset uses the default" {
    try testing.expectEqual(default, try fromEnv(null));
    try testing.expectEqual(@as(u64, 1), try fromEnv("1"));
    try testing.expectEqual(@as(u64, 0x5eed), try fromEnv("0x5eed"));
    try testing.expectError(error.InvalidFuzzSeed, fromEnv("not a number"));
    try testing.expectError(error.InvalidFuzzSeed, fromEnv(""));
}
