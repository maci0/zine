//! Instruction decode cache for the x86 interpreter.
//!
//! Inspired by Blink's OpCache: a hash-indexed cache that maps guest EIP
//! addresses to previously decoded instructions. This eliminates redundant
//! decoding in loops, where the same instructions execute thousands of times.
//!
//! Entries validate the EIP and the complete decode input, including its
//! length, so guest code writes and changed fetch bounds cannot reuse a
//! stale decode.

const decoder = @import("decoder.zig");
const std = @import("std");
const Instruction = decoder.Instruction;

const CACHE_SIZE = 1024;
const MAX_CODE_BYTES = 16;
const CACHE_MASK = CACHE_SIZE - 1;

/// A single cache entry keyed by EIP with the exact decoded bytes.
const CacheEntry = struct {
    eip: u32 = 0,
    code: [MAX_CODE_BYTES]u8 = @splat(0),
    code_len: u8 = 0,
    /// The decoded instruction.
    insn: Instruction = .{},
};

/// Hash-indexed instruction decode cache.
pub const DecodeCache = struct {
    entries: [CACHE_SIZE]CacheEntry = @as([CACHE_SIZE]CacheEntry, @splat(.{})),

    /// Hit counter for diagnostics.
    hits: u64 = 0,
    /// Miss counter for diagnostics.
    misses: u64 = 0,

    /// Look up a cached decode result for the given EIP.
    /// Returns the cached Instruction if EIP and content match, null otherwise.
    pub inline fn lookup(self: *DecodeCache, eip: u32, code: []const u8) ?Instruction {
        const idx = index(eip);
        const entry = &self.entries[idx];
        if (entry.code_len != 0 and entry.eip == eip and entry.code_len == code.len and
            std.mem.eql(u8, entry.code[0..entry.code_len], code))
        {
            self.hits +%= 1;
            return entry.insn;
        }
        self.misses +%= 1;
        return null;
    }

    /// Store a decoded instruction in the cache.
    pub inline fn store(self: *DecodeCache, eip: u32, code: []const u8, insn: Instruction) void {
        const idx = index(eip);
        self.entries[idx] = .{};
        if (code.len == 0 or code.len > MAX_CODE_BYTES or insn.length == 0) return;
        const entry = &self.entries[idx];
        entry.eip = eip;
        entry.code_len = @intCast(code.len);
        @memcpy(entry.code[0..code.len], code);
        entry.insn = insn;
    }

    /// Invalidate the entire cache (e.g. after detecting self-modifying code).
    pub fn invalidate(self: *DecodeCache) void {
        self.entries = @as([CACHE_SIZE]CacheEntry, @splat(.{}));
    }

    /// Invalidate a single entry by EIP.
    pub fn invalidateAddr(self: *DecodeCache, eip: u32) void {
        const idx = index(eip);
        self.entries[idx].code_len = 0;
    }

    /// Hash function: multiplicative hash with Knuth's golden ratio constant
    /// for better distribution of sequential addresses across buckets.
    inline fn index(eip: u32) usize {
        const h = eip *% 2654435761;
        return @as(usize, (h >> 22)) & CACHE_MASK;
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "decode_cache: miss on empty cache" {
    var cache = DecodeCache{};
    const code = [_]u8{ 0x90, 0x00, 0x00, 0x00 };
    try testing.expect(cache.lookup(0x401000, &code) == null);
    try testing.expectEqual(@as(u64, 0), cache.hits);
    try testing.expectEqual(@as(u64, 1), cache.misses);
}

test "decode_cache: hit after store" {
    var cache = DecodeCache{};
    const code = [_]u8{ 0xB8, 0x78, 0x56, 0x34, 0x12 };
    const insn = decoder.decode(&code);
    cache.store(0x401000, &code, insn);

    const result = cache.lookup(0x401000, &code);
    try testing.expect(result != null);
    try testing.expectEqual(insn.opcode, result.?.opcode);
    try testing.expectEqual(insn.length, result.?.length);
    // The decoded MOV EAX immediate, pinned so the entry cannot pass by
    // echoing back whatever store was handed.
    try testing.expectEqual(@as(u32, 0x1234_5678), result.?.imm);
    try testing.expectEqual(@as(u8, 5), result.?.length);
    try testing.expectEqual(@as(u64, 1), cache.hits);
}

test "decode_cache: miss on different code at same EIP" {
    var cache = DecodeCache{};
    const code1 = [_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00 };
    const code2 = [_]u8{ 0xB8, 0x02, 0x00, 0x00, 0x00 };

    const insn = decoder.decode(&code1);
    cache.store(0x401000, &code1, insn);

    // Same EIP but different code bytes → miss (detects SMC)
    try testing.expect(cache.lookup(0x401000, &code2) == null);
}

test "decode_cache: invalidate clears entries" {
    var cache = DecodeCache{};
    const code = [_]u8{ 0x90, 0x00, 0x00, 0x00 };
    const insn = decoder.decode(&code);
    cache.store(0x401000, &code, insn);

    cache.invalidate();
    try testing.expect(cache.lookup(0x401000, &code) == null);
}

test "decode_cache: invalidateAddr clears single entry" {
    var cache = DecodeCache{};
    const eip_a = 0x401000;
    const eip_b = 0x402000;
    // Different buckets is what lets the second lookup below prove that
    // invalidateAddr touched only its own slot.
    comptime std.debug.assert(DecodeCache.index(eip_a) != DecodeCache.index(eip_b));

    const code1 = [_]u8{ 0x90, 0x00, 0x00, 0x00 };
    const code2 = [_]u8{ 0xF4, 0x00, 0x00, 0x00 };
    cache.store(eip_a, &code1, decoder.decode(&code1));
    cache.store(eip_b, &code2, decoder.decode(&code2));

    cache.invalidateAddr(eip_a);
    try testing.expect(cache.lookup(eip_a, &code1) == null);
    try testing.expect(cache.lookup(eip_b, &code2) != null);
}

test "decode_cache: hit/miss counters" {
    var cache = DecodeCache{};
    const code = [_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00 };
    try testing.expectEqual(@as(u64, 0), cache.hits);
    try testing.expectEqual(@as(u64, 0), cache.misses);

    _ = cache.lookup(0x401000, &code); // miss
    try testing.expectEqual(@as(u64, 1), cache.misses);

    cache.store(0x401000, &code, decoder.decode(&code));
    _ = cache.lookup(0x401000, &code); // hit
    _ = cache.lookup(0x401000, &code); // hit
    try testing.expectEqual(@as(u64, 2), cache.hits);
    try testing.expectEqual(@as(u64, 1), cache.misses);
}

test "decode_cache: validates every fetched byte" {
    var cache = DecodeCache{};
    var code: [MAX_CODE_BYTES]u8 = @splat(0x90);
    const insn = decoder.decode(&code);
    cache.store(0x401000, &code, insn);

    for (&code) |*byte| {
        byte.* = 0xCC;
        try testing.expect(cache.lookup(0x401000, &code) == null);
        byte.* = 0x90;
    }
    try testing.expectEqualDeep(insn, cache.lookup(0x401000, &code).?);
}

test "decode_cache: changed fetch length misses even with zero bytes" {
    var cache = DecodeCache{};
    const code = [_]u8{ 0xB8, 0, 0, 0, 0 };
    cache.store(0x401000, &code, decoder.decode(&code));
    try testing.expect(cache.lookup(0x401000, code[0..4]) == null);
    cache.store(0x401000, code[0..4], decoder.decode(code[0..4]));
    try testing.expect(cache.lookup(0x401000, &code) == null);
}

test "decode_cache: maximum EIP is distinct from an empty entry" {
    var cache = DecodeCache{};
    const code = [_]u8{0};
    try testing.expect(cache.lookup(0xFFFFFFFF, &code) == null);
    const insn = decoder.decode(&code);
    cache.store(0xFFFFFFFF, &code, insn);
    try testing.expectEqualDeep(insn, cache.lookup(0xFFFFFFFF, &code).?);
    cache.invalidateAddr(0xFFFFFFFF);
    try testing.expect(cache.lookup(0xFFFFFFFF, &code) == null);
    cache.store(0xFFFFFFFF, &code, insn);
    cache.invalidate();
    try testing.expect(cache.lookup(0xFFFFFFFF, &code) == null);
}

test "decode_cache: unsupported fetch sizes are not cached" {
    var cache = DecodeCache{};
    const code: [MAX_CODE_BYTES + 1]u8 = @splat(0x90);
    cache.store(0x401000, &code, decoder.decode(&code));
    try testing.expect(cache.lookup(0x401000, &code) == null);
    cache.store(0x401000, &.{}, decoder.decode(&.{}));
    try testing.expect(cache.lookup(0x401000, &.{}) == null);
}

test "decode_cache: short code slice handled" {
    var cache = DecodeCache{};
    const short_code = [_]u8{0x90};
    const insn = decoder.decode(&short_code);
    cache.store(0x500000, &short_code, insn);
    const result = cache.lookup(0x500000, &short_code);
    try testing.expect(result != null);
    // Assert the NOP the one-byte slice decodes to, not the Instruction just
    // handed to store: an entry that came back with a stale or zeroed opcode
    // of the right length would pass a comparison against `insn`.
    try testing.expectEqual(@as(u16, 0x90), result.?.opcode);
    try testing.expectEqual(@as(u8, 1), result.?.length);

    // A different instruction at the same EIP must not answer with the
    // cached one, so the entry above came from this EIP's bytes.
    const other = [_]u8{0xCC};
    cache.store(0x500000, &other, decoder.decode(&other));
    const replaced = cache.lookup(0x500000, &other);
    try testing.expect(replaced != null);
    try testing.expectEqual(@as(u16, 0xCC), replaced.?.opcode);
}
