//! Input mutation shared by the fuzz driver and the CI replay tests.

const std = @import("std");

/// Largest input handed to a target. Menu resources and PE headers in the
/// wild stay well under this; the cap keeps mutation time bounded.
pub const max_input_len = 4096;

/// Values the parsers branch on: signature bytes, MF_POPUP, MF_END,
/// DS_SETFONT, and the u8/u16 boundaries.
const boundary_bytes = [_]u8{ 0x00, 0x01, 0x04, 0x08, 0x10, 0x40, 0x7F, 0x80, 0xFF };

/// Apply one structural mutation to `input` (mutated in place) and return the
/// new length. Mirrors what a coverage-guided fuzzer does to a seed: bit
/// flips, boundary values, insertions, deletions, and truncation.
pub fn apply(rand: std.Random, input: []u8) usize {
    var len = @max(input.len, 1);
    switch (rand.intRangeLessThan(u8, 0, 6)) {
        0 => { // flip one bit
            const at = rand.intRangeLessThan(usize, 0, len);
            input[at] ^= @as(u8, 1) << @intCast(rand.int(u3));
        },
        1 => { // overwrite one byte with a boundary value
            const at = rand.intRangeLessThan(usize, 0, len);
            input[at] = boundary_bytes[rand.intRangeLessThan(usize, 0, boundary_bytes.len)];
        },
        2 => { // insert random bytes
            if (len < input.len) {
                const at = rand.intRangeLessThan(usize, 0, len);
                const count = @min(rand.intRangeLessThan(usize, 1, 17), input.len - len);
                std.mem.copyForwards(u8, input[at + count .. len + count], input[at..len]);
                rand.bytes(input[at .. at + count]);
                len += count;
            }
        },
        3 => { // delete bytes
            if (len > 1) {
                const at = rand.intRangeLessThan(usize, 0, len);
                const count = @min(rand.intRangeLessThan(usize, 1, 17), len - at);
                std.mem.copyForwards(u8, input[at .. len - count], input[at + count .. len]);
                len -= count;
            }
        },
        4 => len = @max(1, len - rand.intRangeLessThan(usize, 1, len + 1)),
        else => { // copy a chunk from elsewhere in the same input
            if (len > 4) {
                const from = rand.intRangeLessThan(usize, 0, len - 4);
                const to = rand.intRangeLessThan(usize, 0, len - 4);
                const count = rand.intRangeLessThan(usize, 1, @min(5, len - @max(from, to)));
                std.mem.copyForwards(u8, input[to .. to + count], input[from .. from + count]);
            }
        },
    }
    return len;
}

/// Copy a seed (or a user-supplied file) into `buf`, truncating at max_input_len.
pub fn loadSeed(buf: []u8, seed: []const u8) []u8 {
    const len = @min(seed.len, buf.len);
    @memcpy(buf[0..len], seed[0..len]);
    return buf[0..len];
}
