//! Instruction decode cache for the x86 interpreter.
//!
//! Inspired by Blink's OpCache: a hash-indexed cache that maps guest EIP
//! addresses to previously decoded instructions. This eliminates redundant
//! decoding in loops, where the same instructions execute thousands of times.
//!
//! Each entry is validated by both the EIP tag and the first 4 bytes of the
//! instruction stream, which catches both hash collisions and self-modifying
//! code (though we don't currently support SMC).

const decoder = @import("decoder.zig");
const Instruction = decoder.Instruction;

/// Number of cache entries — must be a power of 2.
/// With the compact Instruction struct (~28 bytes), 1024 entries ≈ 36KB,
/// fitting well within L1 cache on most CPUs.
const CACHE_SIZE = 1024;
const CACHE_MASK = CACHE_SIZE - 1;

/// A single cache entry: EIP tag + content tag + decoded instruction.
const CacheEntry = struct {
    /// Guest EIP that produced this entry (0xFFFFFFFF = empty).
    eip: u32 = 0xFFFFFFFF,
    /// First 4 bytes of the instruction stream at this EIP.
    /// Used to detect stale entries (e.g. self-modifying code).
    tag_bytes: u32 = 0,
    /// The decoded instruction.
    insn: Instruction = .{},
};

/// Hash-indexed instruction decode cache.
pub const DecodeCache = struct {
    entries: [CACHE_SIZE]CacheEntry = [_]CacheEntry{.{}} ** CACHE_SIZE,

    /// Hit counter for diagnostics.
    hits: u64 = 0,
    /// Miss counter for diagnostics.
    misses: u64 = 0,

    /// Look up a cached decode result for the given EIP.
    /// Returns the cached Instruction if EIP and content match, null otherwise.
    pub inline fn lookup(self: *DecodeCache, eip: u32, code: []const u8) ?Instruction {
        const idx = index(eip);
        const entry = &self.entries[idx];
        if (entry.eip == eip and entry.tag_bytes == readTag(code)) {
            self.hits +%= 1;
            return entry.insn;
        }
        self.misses +%= 1;
        return null;
    }

    /// Store a decoded instruction in the cache.
    pub inline fn store(self: *DecodeCache, eip: u32, code: []const u8, insn: Instruction) void {
        const idx = index(eip);
        self.entries[idx] = .{
            .eip = eip,
            .tag_bytes = readTag(code),
            .insn = insn,
        };
    }

    /// Invalidate the entire cache (e.g. after detecting self-modifying code).
    pub fn invalidate(self: *DecodeCache) void {
        self.entries = [_]CacheEntry{.{}} ** CACHE_SIZE;
    }

    /// Invalidate a single entry by EIP.
    pub fn invalidateAddr(self: *DecodeCache, eip: u32) void {
        const idx = index(eip);
        self.entries[idx].eip = 0xFFFFFFFF;
    }

    /// Hash function: multiplicative hash with Knuth's golden ratio constant
    /// for better distribution of sequential addresses across buckets.
    inline fn index(eip: u32) usize {
        const h = eip *% 2654435761;
        return @as(usize, (h >> 22)) & CACHE_MASK;
    }
};

/// Read the first 4 bytes of a code slice as a u32 tag for validation.
/// If the slice is shorter than 4 bytes, pads with zeros.
inline fn readTag(code: []const u8) u32 {
    if (code.len >= 4) {
        return @as(u32, code[0]) |
            (@as(u32, code[1]) << 8) |
            (@as(u32, code[2]) << 16) |
            (@as(u32, code[3]) << 24);
    }
    var tag: u32 = 0;
    for (code, 0..) |byte, i| {
        tag |= @as(u32, byte) << @intCast(i * 8);
    }
    return tag;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const std = @import("std");
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
    try testing.expectEqual(insn.imm, result.?.imm);
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

test "decode_cache: short code slice handled" {
    var cache = DecodeCache{};
    // Code shorter than 4 bytes — readTag should pad with zeros
    const short_code = [_]u8{0x90};
    const insn = decoder.decode(&short_code);
    cache.store(0x500000, &short_code, insn);
    const result = cache.lookup(0x500000, &short_code);
    try testing.expect(result != null);
    try testing.expectEqual(insn.opcode, result.?.opcode);
}
