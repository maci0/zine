//! x86 guest memory abstraction.
//!
//! This module provides the `GuestMemory` struct, which maps 32-bit virtual
//! guest addresses to the host's address space (WASM linear memory or native
//! buffer). It handles bounds-checked reading, writing, and guest heap
//! allocation.

const builtin = @import("builtin");

/// Process-wide guest memory instance. Set at startup by wasm_main; null on
/// native builds (guest addresses are then host addresses). Lives here with
/// the GuestMemory type it points to, so low-level utilities such as trace
/// can translate addresses without reaching up into the win32 layer.
pub var guest_memory: ?*GuestMemory = null;

/// Capacity of the PE section write-protection table. Two entries cover the
/// only production shape (the `.rsrc` carve-out splits the image into
/// before-rsrc and after-rsrc); the rest is headroom for tests.
pub const MAX_WRITABLE_SECTIONS = 8;

/// Translate a guest virtual address to a host pointer through the
/// process-wide instance. Identity when no instance is registered or the
/// address falls outside the mapping.
pub fn guestToHost(guest_addr: usize) usize {
    if (guest_addr == 0) return 0;
    const gmem = guest_memory orelse return guest_addr;
    const base_addr: usize = gmem.base_addr;
    // 64-bit window: on wasm32 the sum of an ImageBase near the top of the
    // address space and a half-gigabyte mapping would wrap a 32-bit usize.
    const base_end = @as(u64, base_addr) + gmem.base.len;
    if (@as(u64, guest_addr) >= base_addr and @as(u64, guest_addr) < base_end) {
        return @intFromPtr(gmem.base.ptr) + (guest_addr - base_addr);
    }
    return guest_addr;
}

/// Convert a host address back to the guest address space.
pub fn hostToGuest(host_addr: usize) usize {
    if (guest_memory) |gmem| {
        const base_ptr = @intFromPtr(gmem.base.ptr);
        const base_end = base_ptr + gmem.base.len;
        if (host_addr >= base_ptr and host_addr < base_end) {
            return gmem.base_addr +% @as(u32, @intCast(host_addr - base_ptr));
        }
    }
    return host_addr;
}

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
    writable_sections: [MAX_WRITABLE_SECTIONS][2]u32 = @splat(.{ 0, 0 }),
    writable_section_count: u8 = 0,

    /// Guest heap bump allocator (used in WASM mode).
    /// heap_start is the buffer offset where the heap area begins.
    /// heap_cursor is the current allocation offset (grows upward).
    heap_start: u32 = 0,
    heap_cursor: u32 = 0,

    /// Translate a virtual address to a buffer index, or null when the
    /// address is below the mapping. The subtraction must not wrap: a PE
    /// whose ImageBase sits near the top of the 32-bit space would otherwise
    /// alias low guest addresses (every null-pointer dereference) onto the
    /// front of the image.
    inline fn translate(self: *const GuestMemory, addr: u32) ?usize {
        if (addr < self.base_addr) return null;
        return addr - self.base_addr;
    }

    /// Allocate memory from the guest heap. Returns a guest virtual address
    /// or 0 on failure. The allocated region is zeroed.
    pub fn guestAlloc(self: *GuestMemory, size: u32) u32 {
        if (self.heap_start == 0) return 0; // heap not configured

        // 64-bit math so a guest-supplied size near u32 max fails the
        // bounds check instead of overflowing into a bogus allocation.
        const aligned_size = (@as(u64, size) + 15) & ~@as(u64, 15);
        const alloc_offset = self.heap_cursor;
        const end = @as(u64, alloc_offset) + aligned_size;

        if (end > self.base.len) return 0; // out of memory

        // Zero the allocated area
        @memset(self.base[alloc_offset..@intCast(end)], 0);

        self.heap_cursor = @intCast(end);
        return self.base_addr +% @as(u32, @intCast(alloc_offset));
    }

    // --- Read operations ---

    /// Reads an 8-bit value from guest memory at `addr`.
    pub inline fn read8(self: *const GuestMemory, addr: u32) u8 {
        if (self.native_linear) {
            if (addr < 4096) return 0;
            return @as(*const u8, @ptrFromInt(addr)).*;
        }
        const a = self.translate(addr) orelse return 0;
        if (a >= self.base.len) return 0;
        return self.base[a];
    }

    /// True when the host is little-endian, so an unaligned multi-byte load
    /// from the guest buffer already holds the little-endian value. Guest
    /// memory is always little-endian regardless of the host.
    const host_is_little = builtin.target.cpu.arch.endian() == .little;

    /// Reads a 16-bit little-endian value from guest memory at `addr`.
    pub inline fn read16(self: *const GuestMemory, addr: u32) u16 {
        if (self.native_linear) {
            if (addr < 4096) return 0;
            return @as(*align(1) const u16, @ptrFromInt(addr)).*;
        }
        const a = self.translate(addr) orelse return 0;
        if (self.base.len < 2 or a > self.base.len - 2) return 0;
        if (comptime host_is_little) {
            return @as(*align(1) const u16, @ptrCast(self.base.ptr + a)).*;
        }
        return @as(u16, self.base[a]) | (@as(u16, self.base[a + 1]) << 8);
    }

    /// Reads a 32-bit little-endian value from guest memory at `addr`.
    pub inline fn read32(self: *const GuestMemory, addr: u32) u32 {
        if (self.native_linear) {
            if (addr < 4096) return 0;
            return @as(*align(1) const u32, @ptrFromInt(addr)).*;
        }
        const a = self.translate(addr) orelse return 0;
        if (self.base.len < 4 or a > self.base.len - 4) return 0;
        if (comptime host_is_little) {
            return @as(*align(1) const u32, @ptrCast(self.base.ptr + a)).*;
        }
        return @as(u32, self.base[a]) |
            (@as(u32, self.base[a + 1]) << 8) |
            (@as(u32, self.base[a + 2]) << 16) |
            (@as(u32, self.base[a + 3]) << 24);
    }

    // --- Write operations ---

    /// Writes an 8-bit value to guest memory at `addr`.
    pub inline fn write8(self: *GuestMemory, addr: u32, val: u8) void {
        if (self.native_linear) {
            if (addr >= 4096) @as(*u8, @ptrFromInt(addr)).* = val;
            return;
        }
        if (self.isWriteProtected(addr)) return;
        const a = self.translate(addr) orelse return;
        if (a >= self.base.len) return;
        self.base[a] = val;
    }

    /// Writes a 16-bit little-endian value to guest memory at `addr`.
    pub inline fn write16(self: *GuestMemory, addr: u32, val: u16) void {
        if (self.native_linear) {
            if (addr >= 4096) @as(*align(1) u16, @ptrFromInt(addr)).* = val;
            return;
        }
        if (self.isWriteProtected(addr)) return;
        const a = self.translate(addr) orelse return;
        if (self.base.len < 2 or a > self.base.len - 2) return;
        if (comptime host_is_little) {
            @as(*align(1) u16, @ptrCast(self.base.ptr + a)).* = val;
            return;
        }
        self.base[a] = @truncate(val);
        self.base[a + 1] = @truncate(val >> 8);
    }

    /// Writes a 32-bit little-endian value to guest memory at `addr`.
    pub inline fn write32(self: *GuestMemory, addr: u32, val: u32) void {
        if (self.native_linear) {
            if (addr >= 4096) @as(*align(1) u32, @ptrFromInt(addr)).* = val;
            return;
        }
        if (self.isWriteProtected(addr)) return;
        const a = self.translate(addr) orelse return;
        if (self.base.len < 4 or a > self.base.len - 4) return;
        if (comptime host_is_little) {
            @as(*align(1) u32, @ptrCast(self.base.ptr + a)).* = val;
            return;
        }
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
    ///
    /// All-or-nothing: returns null unless the whole `[addr, addr+len)` range
    /// is in bounds, so a caller that indexes `len` bytes can never read past
    /// the returned slice. A short read would be silently mistaken for guest
    /// data. Use readRangeInBounds for the cheaper predicate.
    pub fn readSlice(self: *const GuestMemory, addr: u32, len: u32) ?[]const u8 {
        if (self.native_linear) return @as([*]const u8, @ptrFromInt(addr))[0..len];
        if (!self.readRangeInBounds(addr, len)) return null;
        const a = self.translate(addr) orelse return null;
        return self.base[a..][0..len];
    }

    /// Get a mutable slice of guest memory. All-or-nothing, as readSlice, and
    /// additionally refused when any byte of the range falls in a
    /// write-protected PE section, matching the write8/write16/write32 paths.
    pub fn writeSlice(self: *GuestMemory, addr: u32, len: u32) ?[]u8 {
        if (self.native_linear) return @as([*]u8, @ptrFromInt(addr))[0..len];
        if (!self.writeRangeAllowed(addr, len)) return null;
        const a = self.translate(addr) orelse return null;
        return self.base[a..][0..len];
    }

    /// Register a writable address range (PE section with IMAGE_SCN_MEM_WRITE).
    /// Returns false when the range was dropped for lack of capacity; the
    /// caller must treat that as fatal, because a dropped section stays
    /// write-protected and the guest's writes to it are silently discarded.
    pub fn addWritableSection(self: *GuestMemory, start: u32, end: u32) bool {
        if (self.writable_section_count >= self.writable_sections.len) return false;
        self.writable_sections[self.writable_section_count] = .{ start, end };
        self.writable_section_count += 1;
        return true;
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

    /// True when every byte in [addr, addr+len) reads as in-bounds guest
    /// memory. Used to gate bulk copies; a false result means element-wise
    /// handling is required (partial ranges no-op per byte).
    pub fn readRangeInBounds(self: *const GuestMemory, addr: u32, len: u64) bool {
        if (len == 0) return true;
        // Reject ranges that wrap the 32-bit address space.
        if (@as(u64, addr) + len > 0x100000000) return false;
        if (self.native_linear) return addr >= 4096;
        if (addr < self.base_addr) return false;
        const a = addr - self.base_addr;
        return a < self.base.len and len <= @as(u64, self.base.len) - a;
    }

    /// True when every byte in [addr, addr+len) can be written: in bounds and
    /// not inside a write-protected PE region. Walks the writable-section
    /// intervals to cover the range exactly.
    pub fn writeRangeAllowed(self: *const GuestMemory, addr: u32, len: u64) bool {
        if (len == 0) return true;
        if (@as(u64, addr) + len > 0x100000000) return false;
        if (self.native_linear) return addr >= 4096;
        if (addr < self.base_addr) return false;
        const start = addr - self.base_addr;
        if (start >= self.base.len) return false;
        if (len > self.base.len - start) return false;
        // Outside the protected image window everything is writable.
        if (self.pe_image_end == 0) return true;
        const win_start = self.base_addr;
        const win_end = self.pe_image_end;
        if (addr >= win_end or addr + len <= win_start) return true;
        // Range intersects the image: require full coverage by writable
        // sections. Greedy interval walk over at most 8 sections.
        var cur: u64 = if (addr < win_start) win_start else addr;
        const end: u64 = @min(@as(u64, addr) + len, win_end);
        var covered = true;
        while (cur < end) {
            var next: ?u64 = null;
            for (self.writable_sections[0..self.writable_section_count]) |r| {
                if (r[0] <= cur and cur < r[1]) {
                    next = @max(next orelse 0, r[1]);
                }
            }
            if (next) |n| {
                cur = n;
            } else {
                covered = false;
                break;
            }
        }
        return covered;
    }

    /// Mutable slice over an already-validated in-bounds guest range
    /// (see readRangeInBounds/writeRangeAllowed).
    pub fn mutRange(self: *GuestMemory, addr: u32, len: usize) []u8 {
        if (self.native_linear) return @as([*]u8, @ptrFromInt(addr))[0..len];
        const a = addr -% self.base_addr;
        return self.base[a..][0..len];
    }

    /// Read-only slice over an already-validated in-bounds guest range.
    pub fn range(self: *const GuestMemory, addr: u32, len: usize) []const u8 {
        if (self.native_linear) return @as([*]const u8, @ptrFromInt(addr))[0..len];
        const a = addr -% self.base_addr;
        return self.base[a..][0..len];
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;

test "guest memory: read/write 8-bit" {
    var buf: [16]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf };
    mem.write8(0, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), mem.read8(0));
}

test "guest memory: read/write 16-bit little-endian" {
    var buf: [16]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf };
    mem.write16(2, 0xBEEF);
    try testing.expectEqual(@as(u16, 0xBEEF), mem.read16(2));
    try testing.expectEqual(@as(u8, 0xEF), buf[2]);
    try testing.expectEqual(@as(u8, 0xBE), buf[3]);
}

test "guest memory: read/write 32-bit little-endian" {
    var buf: [16]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf };
    mem.write32(4, 0xDEADBEEF);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), mem.read32(4));
    try testing.expectEqual(@as(u8, 0xEF), buf[4]);
    try testing.expectEqual(@as(u8, 0xBE), buf[5]);
    try testing.expectEqual(@as(u8, 0xAD), buf[6]);
    try testing.expectEqual(@as(u8, 0xDE), buf[7]);
}

test "guest memory: out of bounds returns zero/no-ops" {
    var buf: [4]u8 = @splat(0xA5);
    var mem = GuestMemory{ .base = &buf };
    try testing.expectEqual(@as(u8, 0), mem.read8(100));
    try testing.expectEqual(@as(u32, 0), mem.read32(100));
    // The write must not land anywhere, not even clamped into the buffer.
    mem.write32(100, 0xDEAD);
    for (buf) |byte| try testing.expectEqual(@as(u8, 0xA5), byte);
}

test "guest memory: unaligned multi-byte access matches little-endian layout" {
    // Guest operands are unaligned freely; the fast path loads them natively,
    // so every offset in the range must still produce the same bytes.
    var buf: [16]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf };
    // 0..8 so the widest access (8 bytes) stays inside the buffer at every
    // offset, aligned and unaligned alike.
    for (0..9) |i| {
        const off: u32 = @intCast(i);
        mem.write32(off, 0xDEADBEEF);
        try testing.expectEqual(@as(u8, 0xEF), buf[off]);
        try testing.expectEqual(@as(u8, 0xBE), buf[off + 1]);
        try testing.expectEqual(@as(u8, 0xAD), buf[off + 2]);
        try testing.expectEqual(@as(u8, 0xDE), buf[off + 3]);
        try testing.expectEqual(@as(u32, 0xDEADBEEF), mem.read32(off));

        mem.write16(off, 0xBEEF);
        try testing.expectEqual(@as(u8, 0xEF), buf[off]);
        try testing.expectEqual(@as(u8, 0xBE), buf[off + 1]);
        try testing.expectEqual(@as(u16, 0xBEEF), mem.read16(off));

        mem.write64(off, 0xDEADBEEFCAFEBABE);
        try testing.expectEqual(@as(u64, 0xDEADBEEFCAFEBABE), mem.read64(off));
        try testing.expectEqual(@as(u32, 0xCAFEBABE), mem.read32(off));
        try testing.expectEqual(@as(u32, 0xDEADBEEF), mem.read32(off + 4));
    }
}

test "guest memory: non-zero base_addr translation" {
    var buf: [16]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf, .base_addr = 0x00400000 };
    mem.write32(0x00400004, 0xCAFEBABE);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), mem.read32(0x00400004));
    // Verify raw buffer position (offset 4 from base)
    try testing.expectEqual(@as(u8, 0xBE), buf[4]);
    try testing.expectEqual(@as(u8, 0xBA), buf[5]);
}

test "guest memory: read64/write64" {
    var buf: [16]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf };
    mem.write64(0, 0xDEADBEEFCAFEBABE);
    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFEBABE), mem.read64(0));
    // Low 32 bits at offset 0, high 32 bits at offset 4
    try testing.expectEqual(@as(u32, 0xCAFEBABE), mem.read32(0));
    try testing.expectEqual(@as(u32, 0xDEADBEEF), mem.read32(4));
}

test "guest memory: readSlice refuses a range that straddles the end" {
    var buf: [8]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf };
    // A short read would hand the caller fewer bytes than it asked for and
    // every index into it would be a host out-of-bounds access.
    try testing.expect(mem.readSlice(6, 4) == null);
    try testing.expect(mem.readSlice(8, 1) == null);
    try testing.expect(mem.readSlice(4, 4) != null);
    try testing.expectEqual(@as(usize, 4), mem.readSlice(4, 4).?.len);
}

test "guest memory: writeSlice honours PE section write protection" {
    var buf: [128]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf, .pe_image_end = 64 };
    try testing.expect(mem.addWritableSection(16, 48));

    const ok = mem.writeSlice(16, 32).?;
    ok[0] = 0xAB;
    try testing.expectEqual(@as(u8, 0xAB), buf[16]);

    // Same ranges the element-wise writers refuse.
    try testing.expect(mem.writeSlice(0, 16) == null);
    try testing.expect(mem.writeSlice(48, 16) == null);
    try testing.expect(mem.writeSlice(60, 8) == null);
    try testing.expect(mem.writeSlice(64, 8) != null);
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
    var buf: [256]u8 = @splat(0xAA);
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
    var buf: [64]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf };
    // heap_start == 0 means heap is not configured
    try testing.expectEqual(@as(u32, 0), mem.guestAlloc(16));
}

test "guest memory: guestAlloc rejects sizes that overflow u32" {
    var buf: [256]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf, .base_addr = 0x1000, .heap_start = 64, .heap_cursor = 64 };
    // A guest-supplied size near u32 max must fail cleanly (return 0),
    // not overflow the alignment computation into a bogus allocation.
    try testing.expectEqual(@as(u32, 0), mem.guestAlloc(0xFFFFFFF0));
    try testing.expectEqual(@as(u32, 0), mem.guestAlloc(0xFFFFFFFF));
    try testing.expectEqual(@as(u32, 64), mem.heap_cursor); // state unchanged
}

test "guest memory: write protection blocks writes to PE image" {
    var buf: [256]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf, .base_addr = 0, .pe_image_end = 128 };
    // No writable sections registered — writes inside PE image should be blocked
    mem.write8(64, 0xFF);
    try testing.expectEqual(@as(u8, 0), buf[64]); // write was blocked

    // Writes outside PE image (>= pe_image_end) should succeed
    mem.write8(128, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), buf[128]);
}

test "guest memory: writable section allows writes" {
    var buf: [256]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf, .base_addr = 0, .pe_image_end = 128 };
    try testing.expect(mem.addWritableSection(32, 96)); // allow writes to range [32, 96)

    // Write inside writable section — should succeed
    mem.write8(64, 0xCD);
    try testing.expectEqual(@as(u8, 0xCD), buf[64]);

    // Write outside writable section but inside PE image — blocked
    mem.write8(16, 0xEF);
    try testing.expectEqual(@as(u8, 0), buf[16]);
}

test "guest memory: read/write 128-bit" {
    var buf: [32]u8 = @splat(0);
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

test "guest memory: readRangeInBounds rejects OOB and wrapping ranges" {
    var buf: [256]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf, .base_addr = 0x0001_0000 };

    try testing.expect(mem.readRangeInBounds(0x0001_0000, 0)); // empty range
    try testing.expect(mem.readRangeInBounds(0x0001_0000, 256)); // exact fit
    try testing.expect(mem.readRangeInBounds(0x0001_00FF, 1)); // last byte
    try testing.expect(!mem.readRangeInBounds(0x0001_00FF, 2)); // straddles end
    try testing.expect(!mem.readRangeInBounds(0x0002_0000, 1)); // past end
    // Ranges wrapping the 32-bit address space must be rejected outright.
    try testing.expect(!mem.readRangeInBounds(0xFFFF_FFFC, 8));
}

test "guest memory: writeRangeAllowed without image protection" {
    var buf: [256]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf, .base_addr = 0x0001_0000 };

    // No PE image window configured: every in-bounds byte is writable.
    try testing.expect(mem.writeRangeAllowed(0x0001_0000, 0));
    try testing.expect(mem.writeRangeAllowed(0x0001_0000, 256));
    try testing.expect(!mem.writeRangeAllowed(0x0001_0100, 1));
    try testing.expect(!mem.writeRangeAllowed(0xFFFF_FFFC, 8));
}

test "guest memory: writeRangeAllowed requires full writable-section cover in image" {
    var buf: [256]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf, .base_addr = 0x0001_0000, .pe_image_end = 0x0001_0080 };
    // Image window is [0x10000, 0x10080); only [0x10020, 0x10060) is writable.
    try testing.expect(mem.addWritableSection(0x0001_0020, 0x0001_0060));

    try testing.expect(mem.writeRangeAllowed(0x0001_0030, 8)); // inside section
    try testing.expect(mem.writeRangeAllowed(0x0001_0020, 64)); // exact section span
    try testing.expect(mem.writeRangeAllowed(0x0001_0080, 16)); // fully past image end
    try testing.expect(!mem.writeRangeAllowed(0x0001_0010, 4)); // protected head
    try testing.expect(!mem.writeRangeAllowed(0x0001_0060, 4)); // protected tail gap
    try testing.expect(!mem.writeRangeAllowed(0x0001_0050, 32)); // straddles section edge
    try testing.expect(!mem.writeRangeAllowed(0x0001_0078, 16)); // crosses image end uncovered
}

test "guest memory: writeRangeAllowed chains adjacent writable sections" {
    var buf: [256]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf, .base_addr = 0x0001_0000, .pe_image_end = 0x0001_0080 };
    try testing.expect(mem.addWritableSection(0x0001_0020, 0x0001_0040));
    try testing.expect(mem.addWritableSection(0x0001_0040, 0x0001_0060));

    try testing.expect(mem.writeRangeAllowed(0x0001_0020, 64)); // both sections chained
    try testing.expect(!mem.writeRangeAllowed(0x0001_0020, 65)); // one byte past the chain
}

test "guest memory: writable section table reports overflow instead of dropping" {
    var buf: [256]u8 = @splat(0);
    var mem = GuestMemory{ .base = &buf, .base_addr = 0x0001_0000, .pe_image_end = 0x0001_0100 };
    for (0..MAX_WRITABLE_SECTIONS) |i| {
        const start: u32 = 0x0001_0000 + @as(u32, @intCast(i)) * 4;
        try testing.expect(mem.addWritableSection(start, start + 4));
    }
    try testing.expectEqual(@as(u8, MAX_WRITABLE_SECTIONS), mem.writable_section_count);
    try testing.expect(!mem.addWritableSection(0x0001_00F0, 0x0001_0100));
    try testing.expectEqual(@as(u8, MAX_WRITABLE_SECTIONS), mem.writable_section_count);
}

test "guest memory: an address below the base does not alias into the image" {
    // A PE whose ImageBase sits near the top of the 32-bit space would fold
    // a low guest address (a null-pointer dereference) onto a small offset
    // inside the image if the subtraction wrapped.
    var buf: [256]u8 = @splat(0xAB);
    var gmem = GuestMemory{ .base = &buf, .base_addr = 0xFFFF0000 };
    try testing.expectEqual(@as(u8, 0xAB), gmem.read8(0xFFFF0000));
    try testing.expectEqual(@as(u32, 0), gmem.read32(0x00001000));
    try testing.expectEqual(@as(u32, 0), gmem.read32(0));
    gmem.write8(0x00001000, 0x11);
    try testing.expectEqual(@as(u8, 0xAB), gmem.base[0]);
    try testing.expect(!gmem.readRangeInBounds(0x00001000, 4));
    try testing.expect(!gmem.writeRangeAllowed(0x00001000, 4));
    try testing.expect(gmem.readSlice(0x00001000, 4) == null);
    try testing.expect(gmem.writeSlice(0x00001000, 4) == null);
}
