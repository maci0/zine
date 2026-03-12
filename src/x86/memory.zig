// Guest memory access for the x86 interpreter.
//
// The guest x86 address space lives inside WASM linear memory (or a
// host-allocated buffer on native).  All memory reads/writes go through
// this module for bounds checking and segment resolution.

/// Bounds-checked guest memory accessor.
pub const GuestMemory = struct {
    /// The backing memory buffer.  On WASM this is a slice of the linear
    /// memory starting at GUEST_BASE; on native (for testing) it can be
    /// any allocated buffer.
    base: []u8,

    /// The virtual address that maps to base[0].
    /// For WASM/testing: 0 (addresses are buffer indices directly).
    /// For native --interpret: the mmap'd address (image_base), so that
    /// absolute x86 addresses (e.g. 0x01006420) translate correctly.
    base_addr: u32 = 0,

    /// Translate a virtual address to a buffer index.
    inline fn translate(self: *const GuestMemory, addr: u32) usize {
        return addr -% self.base_addr;
    }

    // --- Read operations ---

    pub fn read8(self: *const GuestMemory, addr: u32) u8 {
        const a = self.translate(addr);
        if (a >= self.base.len) return 0;
        return self.base[a];
    }

    pub fn read16(self: *const GuestMemory, addr: u32) u16 {
        const a = self.translate(addr);
        if (self.base.len < 2 or a > self.base.len - 2) return 0;
        return @as(u16, self.base[a]) | (@as(u16, self.base[a + 1]) << 8);
    }

    pub fn read32(self: *const GuestMemory, addr: u32) u32 {
        const a = self.translate(addr);
        if (self.base.len < 4 or a > self.base.len - 4) return 0;
        return @as(u32, self.base[a]) |
            (@as(u32, self.base[a + 1]) << 8) |
            (@as(u32, self.base[a + 2]) << 16) |
            (@as(u32, self.base[a + 3]) << 24);
    }

    // --- Write operations ---

    pub fn write8(self: *GuestMemory, addr: u32, val: u8) void {
        const a = self.translate(addr);
        if (a >= self.base.len) return;
        self.base[a] = val;
    }

    pub fn write16(self: *GuestMemory, addr: u32, val: u16) void {
        const a = self.translate(addr);
        if (self.base.len < 2 or a > self.base.len - 2) return;
        self.base[a] = @truncate(val);
        self.base[a + 1] = @truncate(val >> 8);
    }

    pub fn write32(self: *GuestMemory, addr: u32, val: u32) void {
        const a = self.translate(addr);
        if (self.base.len < 4 or a > self.base.len - 4) return;
        self.base[a] = @truncate(val);
        self.base[a + 1] = @truncate(val >> 8);
        self.base[a + 2] = @truncate(val >> 16);
        self.base[a + 3] = @truncate(val >> 24);
    }

    /// Get a read-only slice of guest memory.
    pub fn readSlice(self: *const GuestMemory, addr: u32, len: u32) ?[]const u8 {
        const a = self.translate(addr);
        if (a >= self.base.len) return null;
        const end = @min(a + len, self.base.len);
        return self.base[a..end];
    }

    /// Get a mutable slice of guest memory.
    pub fn writeSlice(self: *GuestMemory, addr: u32, len: u32) ?[]u8 {
        const a = self.translate(addr);
        if (a >= self.base.len) return null;
        const end = @min(a + len, self.base.len);
        return self.base[a..end];
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;

test "guest memory: read/write 8-bit" {
    var buf: [16]u8 = .{0} ** 16;
    var mem = GuestMemory{ .base = &buf };
    mem.write8(0, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), mem.read8(0));
}

test "guest memory: read/write 16-bit little-endian" {
    var buf: [16]u8 = .{0} ** 16;
    var mem = GuestMemory{ .base = &buf };
    mem.write16(2, 0xBEEF);
    try testing.expectEqual(@as(u16, 0xBEEF), mem.read16(2));
    try testing.expectEqual(@as(u8, 0xEF), buf[2]);
    try testing.expectEqual(@as(u8, 0xBE), buf[3]);
}

test "guest memory: read/write 32-bit little-endian" {
    var buf: [16]u8 = .{0} ** 16;
    var mem = GuestMemory{ .base = &buf };
    mem.write32(4, 0xDEADBEEF);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), mem.read32(4));
    try testing.expectEqual(@as(u8, 0xEF), buf[4]);
    try testing.expectEqual(@as(u8, 0xBE), buf[5]);
    try testing.expectEqual(@as(u8, 0xAD), buf[6]);
    try testing.expectEqual(@as(u8, 0xDE), buf[7]);
}

test "guest memory: out of bounds returns zero/no-ops" {
    var buf: [4]u8 = .{0} ** 4;
    var mem = GuestMemory{ .base = &buf };
    try testing.expectEqual(@as(u8, 0), mem.read8(100));
    try testing.expectEqual(@as(u32, 0), mem.read32(100));
    mem.write32(100, 0xDEAD); // should not crash
}
