//! x86 guest memory abstraction.
//!
//! This module provides the `GuestMemory` struct, which maps 32-bit virtual
//! guest addresses to the host's address space (WASM linear memory or native
//! buffer). It handles bounds-checked reading, writing, and guest heap
//! allocation.

/// Bounds-checked guest memory accessor.
pub const GuestMemory = struct {
    /// The backing memory buffer.  On WASM this is a slice of the linear
    /// memory starting at GUEST_BASE; on native (for testing) it can be
    /// any allocated buffer.
    base: []u8,

    /// The virtual address that maps to base[0].
    /// For WASM: the PE's preferred ImageBase (e.g. 0x00400000).
    /// For native --interpret: the mmap'd address (image_base).
    /// For unit tests: 0 (addresses are buffer indices directly).
    base_addr: u32 = 0,
    native_linear: bool = false,

    /// PE section write protection (offsets 0 = start VA, 1 = end VA).
    pe_image_end: u32 = 0,
    writable_sections: [8][2]u32 = .{.{ 0, 0 }} ** 8,
    writable_section_count: u8 = 0,

    /// Guest heap bump allocator (used in WASM mode).
    /// heap_start is the buffer offset where the heap area begins.
    /// heap_cursor is the current allocation offset (grows upward).
    heap_start: u32 = 0,
    heap_cursor: u32 = 0,

    /// Translate a virtual address to a buffer index.
    inline fn translate(self: *const GuestMemory, addr: u32) usize {
        return addr -% self.base_addr;
    }

    /// Allocate memory from the guest heap. Returns a guest virtual address
    /// or 0 on failure. The allocated region is zeroed.
    pub fn guestAlloc(self: *GuestMemory, size: u32) u32 {
        if (self.heap_start == 0) return 0; // heap not configured

        // Align to 16 bytes
        const aligned_size = (size + 15) & ~@as(u32, 15);
        const alloc_offset = self.heap_cursor;
        const end = alloc_offset + aligned_size;

        if (end > self.base.len) return 0; // out of memory

        // Zero the allocated area
        @memset(self.base[alloc_offset..end], 0);

        self.heap_cursor = end;
        return self.base_addr +% @as(u32, @intCast(alloc_offset));
    }

    // --- Read operations ---

    /// Reads an 8-bit value from guest memory at `addr`.
    pub inline fn read8(self: *const GuestMemory, addr: u32) u8 {
        if (self.native_linear) { if (addr < 4096) return 0; return @as(*const u8, @ptrFromInt(addr)).*; }
        const a = self.translate(addr);
        if (a >= self.base.len) return 0;
        return self.base[a];
    }

    /// Reads a 16-bit little-endian value from guest memory at `addr`.
    pub inline fn read16(self: *const GuestMemory, addr: u32) u16 {
        if (self.native_linear) { if (addr < 4096) return 0; return @as(*align(1) const u16, @ptrFromInt(addr)).*; }
        const a = self.translate(addr);
        if (self.base.len < 2 or a > self.base.len - 2) return 0;
        return @as(u16, self.base[a]) | (@as(u16, self.base[a + 1]) << 8);
    }

    /// Reads a 32-bit little-endian value from guest memory at `addr`.
    pub inline fn read32(self: *const GuestMemory, addr: u32) u32 {
        if (self.native_linear) { if (addr < 4096) return 0; return @as(*align(1) const u32, @ptrFromInt(addr)).*; }
        const a = self.translate(addr);
        if (self.base.len < 4 or a > self.base.len - 4) return 0;
        return @as(u32, self.base[a]) |
            (@as(u32, self.base[a + 1]) << 8) |
            (@as(u32, self.base[a + 2]) << 16) |
            (@as(u32, self.base[a + 3]) << 24);
    }

    // --- Write operations ---

    /// Writes an 8-bit value to guest memory at `addr`.
    pub inline fn write8(self: *GuestMemory, addr: u32, val: u8) void {
        if (self.native_linear) { if (addr >= 4096) @as(*u8, @ptrFromInt(addr)).* = val; return; }
        if (self.isWriteProtected(addr)) return;
        const a = self.translate(addr);
        if (a >= self.base.len) return;
        self.base[a] = val;
    }

    /// Writes a 16-bit little-endian value to guest memory at `addr`.
    pub inline fn write16(self: *GuestMemory, addr: u32, val: u16) void {
        if (self.native_linear) { if (addr >= 4096) @as(*align(1) u16, @ptrFromInt(addr)).* = val; return; }
        if (self.isWriteProtected(addr)) return;
        const a = self.translate(addr);
        if (self.base.len < 2 or a > self.base.len - 2) return;
        self.base[a] = @truncate(val);
        self.base[a + 1] = @truncate(val >> 8);
    }

    /// Writes a 32-bit little-endian value to guest memory at `addr`.
    pub inline fn write32(self: *GuestMemory, addr: u32, val: u32) void {
        if (self.native_linear) { if (addr >= 4096) @as(*align(1) u32, @ptrFromInt(addr)).* = val; return; }
        if (self.isWriteProtected(addr)) return;
        const a = self.translate(addr);
        if (self.base.len < 4 or a > self.base.len - 4) return;
        self.base[a] = @truncate(val);
        self.base[a + 1] = @truncate(val >> 8);
        self.base[a + 2] = @truncate(val >> 16);
        self.base[a + 3] = @truncate(val >> 24);
    }

    /// Reads a 64-bit little-endian value from guest memory at `addr`.
    pub fn read64(self: *const GuestMemory, addr: u32) u64 {
        return @as(u64, self.read32(addr)) | (@as(u64, self.read32(addr +% 4)) << 32);
    }

    /// Writes a 64-bit little-endian value to guest memory at `addr`.
    pub fn write64(self: *GuestMemory, addr: u32, val: u64) void {
        self.write32(addr, @truncate(val));
        self.write32(addr +% 4, @truncate(val >> 32));
    }

    /// Reads a 128-bit little-endian value from guest memory at `addr`.
    pub fn read128(self: *const GuestMemory, addr: u32) u128 {
        return @as(u128, self.read64(addr)) | (@as(u128, self.read64(addr +% 8)) << 64);
    }

    /// Writes a 128-bit little-endian value to guest memory at `addr`.
    pub fn write128(self: *GuestMemory, addr: u32, val: u128) void {
        self.write64(addr, @truncate(val));
        self.write64(addr +% 8, @truncate(val >> 64));
    }

    /// Get a read-only slice of guest memory.
    pub fn readSlice(self: *const GuestMemory, addr: u32, len: u32) ?[]const u8 {
        if (self.native_linear) return @as([*]const u8, @ptrFromInt(addr))[0..len];
        const a = self.translate(addr);
        if (a >= self.base.len) return null;
        const end = @min(a + len, self.base.len);
        return self.base[a..end];
    }

    /// Get a mutable slice of guest memory.
    pub fn writeSlice(self: *GuestMemory, addr: u32, len: u32) ?[]u8 {
        if (self.native_linear) return @as([*]u8, @ptrFromInt(addr))[0..len];
        const a = self.translate(addr);
        if (a >= self.base.len) return null;
        const end = @min(a + len, self.base.len);
        return self.base[a..end];
    }

    /// Register a writable address range (PE section with IMAGE_SCN_MEM_WRITE).
    pub fn addWritableSection(self: *GuestMemory, start: u32, end: u32) void {
        if (self.writable_section_count < self.writable_sections.len) {
            self.writable_sections[self.writable_section_count] = .{ start, end };
            self.writable_section_count += 1;
        }
    }

    /// Check if a guest address is write-protected. Addresses outside the PE
    /// image (stack, heap, thunks) are always writable.
    inline fn isWriteProtected(self: *const GuestMemory, addr: u32) bool {
        if (self.pe_image_end == 0) return false;
        if (addr < self.base_addr or addr >= self.pe_image_end) return false;
        for (self.writable_sections[0..self.writable_section_count]) |r| {
            if (addr >= r[0] and addr < r[1]) return false;
        }
        return true;
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

test "guest memory: non-zero base_addr translation" {
    var buf: [16]u8 = .{0} ** 16;
    var mem = GuestMemory{ .base = &buf, .base_addr = 0x00400000 };
    mem.write32(0x00400004, 0xCAFEBABE);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), mem.read32(0x00400004));
    // Verify raw buffer position (offset 4 from base)
    try testing.expectEqual(@as(u8, 0xBE), buf[4]);
    try testing.expectEqual(@as(u8, 0xBA), buf[5]);
}

test "guest memory: read64/write64" {
    var buf: [16]u8 = .{0} ** 16;
    var mem = GuestMemory{ .base = &buf };
    mem.write64(0, 0xDEADBEEFCAFEBABE);
    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFEBABE), mem.read64(0));
    // Low 32 bits at offset 0, high 32 bits at offset 4
    try testing.expectEqual(@as(u32, 0xCAFEBABE), mem.read32(0));
    try testing.expectEqual(@as(u32, 0xDEADBEEF), mem.read32(4));
}

test "guest memory: readSlice returns correct view" {
    var buf = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 };
    var mem = GuestMemory{ .base = &buf };
    const slice = mem.readSlice(2, 4).?;
    try testing.expectEqual(@as(usize, 4), slice.len);
    try testing.expectEqual(@as(u8, 0xCC), slice[0]);
    try testing.expectEqual(@as(u8, 0xDD), slice[1]);
    // Out of bounds returns null
    try testing.expect(mem.readSlice(100, 4) == null);
}

test "guest memory: guestAlloc bump allocator" {
    var buf: [256]u8 = .{0xAA} ** 256;
    var mem = GuestMemory{ .base = &buf, .base_addr = 0x1000, .heap_start = 64, .heap_cursor = 64 };
    const addr1 = mem.guestAlloc(8);
    try testing.expect(addr1 != 0);
    try testing.expectEqual(@as(u32, 0x1000 + 64), addr1);
    // Allocated area should be zeroed
    try testing.expectEqual(@as(u8, 0), buf[64]);
    // Second allocation should be after the first (16-byte aligned)
    const addr2 = mem.guestAlloc(4);
    try testing.expectEqual(@as(u32, 0x1000 + 80), addr2); // 8 rounded up to 16
    // Allocation beyond buffer should return 0
    try testing.expectEqual(@as(u32, 0), mem.guestAlloc(1024));
}

test "guest memory: guestAlloc returns 0 when heap not configured" {
    var buf: [64]u8 = .{0} ** 64;
    var mem = GuestMemory{ .base = &buf };
    // heap_start == 0 means heap is not configured
    try testing.expectEqual(@as(u32, 0), mem.guestAlloc(16));
}

test "guest memory: write protection blocks writes to PE image" {
    var buf: [256]u8 = .{0} ** 256;
    var mem = GuestMemory{ .base = &buf, .base_addr = 0, .pe_image_end = 128 };
    // No writable sections registered — writes inside PE image should be blocked
    mem.write8(64, 0xFF);
    try testing.expectEqual(@as(u8, 0), buf[64]); // write was blocked

    // Writes outside PE image (>= pe_image_end) should succeed
    mem.write8(128, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), buf[128]);
}

test "guest memory: writable section allows writes" {
    var buf: [256]u8 = .{0} ** 256;
    var mem = GuestMemory{ .base = &buf, .base_addr = 0, .pe_image_end = 128 };
    mem.addWritableSection(32, 96); // allow writes to range [32, 96)

    // Write inside writable section — should succeed
    mem.write8(64, 0xCD);
    try testing.expectEqual(@as(u8, 0xCD), buf[64]);

    // Write outside writable section but inside PE image — blocked
    mem.write8(16, 0xEF);
    try testing.expectEqual(@as(u8, 0), buf[16]);
}

test "guest memory: read/write 128-bit" {
    var buf: [32]u8 = .{0} ** 32;
    var mem = GuestMemory{ .base = &buf };
    const val: u128 = 0xDEADBEEFCAFEBABE_1234567890ABCDEF;
    mem.write128(0, val);
    try testing.expectEqual(val, mem.read128(0));
}

test "guest memory: writeSlice returns mutable view" {
    var buf = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var mem = GuestMemory{ .base = &buf };
    const slice = mem.writeSlice(2, 3).?;
    try testing.expectEqual(@as(usize, 3), slice.len);
    slice[0] = 0xAA;
    slice[1] = 0xBB;
    try testing.expectEqual(@as(u8, 0xAA), buf[2]);
    try testing.expectEqual(@as(u8, 0xBB), buf[3]);
    // Out of bounds returns null
    try testing.expect(mem.writeSlice(100, 4) == null);
}
