// x86 CPU state for the software interpreter.
//
// Contains all register state, segment registers, EFLAGS (lazy), FPU state,
// and guest memory references needed to execute 32-bit x86 instructions.

const flags_mod = @import("flags.zig");
const fpu_mod = @import("fpu.zig");
const mem_mod = @import("memory.zig");

pub const LazyFlags = flags_mod.LazyFlags;
pub const FlagOp = flags_mod.FlagOp;
pub const OpSize = flags_mod.OpSize;
pub const FpuState = fpu_mod.FpuState;
pub const GuestMemory = mem_mod.GuestMemory;

/// x86 register index (matches ModR/M reg field encoding).
pub const RegIndex = enum(u3) {
    eax = 0,
    ecx = 1,
    edx = 2,
    ebx = 3,
    esp = 4,
    ebp = 5,
    esi = 6,
    edi = 7,
};

/// Segment register.
pub const Segment = enum(u3) {
    es = 0,
    cs = 1,
    ss = 2,
    ds = 3,
    fs = 4,
    gs = 5,
};

pub const Cpu = struct {
    // General purpose registers
    eax: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    ebx: u32 = 0,
    esp: u32 = 0,
    ebp: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,

    // Instruction pointer
    eip: u32 = 0,

    // Segment registers (flat model, but need FS for TEB)
    cs: u16 = 0x001B,
    ds: u16 = 0x0023,
    es: u16 = 0x0023,
    fs: u16 = 0x003B,
    gs: u16 = 0x0000,
    ss: u16 = 0x0023,

    // FS base — used for TEB access (FS:0, FS:0x18, etc.)
    fs_base: u32 = 0,

    // Lazy EFLAGS
    flags: LazyFlags = .{},

    // FPU state
    fpu: FpuState = .{},

    // Guest memory
    memory: GuestMemory = .{ .base = &.{} },

    // Execution state
    halted: bool = false,
    pending_interrupt: ?u8 = null,

    // --- Register access by index ---

    pub fn getReg(self: *const Cpu, idx: RegIndex) u32 {
        return switch (idx) {
            .eax => self.eax,
            .ecx => self.ecx,
            .edx => self.edx,
            .ebx => self.ebx,
            .esp => self.esp,
            .ebp => self.ebp,
            .esi => self.esi,
            .edi => self.edi,
        };
    }

    pub fn setReg(self: *Cpu, idx: RegIndex, val: u32) void {
        switch (idx) {
            .eax => self.eax = val,
            .ecx => self.ecx = val,
            .edx => self.edx = val,
            .ebx => self.ebx = val,
            .esp => self.esp = val,
            .ebp => self.ebp = val,
            .esi => self.esi = val,
            .edi => self.edi = val,
        }
    }

    /// Get 8-bit register by index.
    /// 0-3 = AL, CL, DL, BL (low byte)
    /// 4-7 = AH, CH, DH, BH (high byte)
    pub fn getReg8(self: *const Cpu, idx: u3) u8 {
        return switch (idx) {
            0 => @truncate(self.eax), // AL
            1 => @truncate(self.ecx), // CL
            2 => @truncate(self.edx), // DL
            3 => @truncate(self.ebx), // BL
            4 => @truncate(self.eax >> 8), // AH
            5 => @truncate(self.ecx >> 8), // CH
            6 => @truncate(self.edx >> 8), // DH
            7 => @truncate(self.ebx >> 8), // BH
        };
    }

    /// Set 8-bit register by index.
    pub fn setReg8(self: *Cpu, idx: u3, val: u8) void {
        const v32: u32 = val;
        switch (idx) {
            0 => self.eax = (self.eax & 0xFFFFFF00) | v32, // AL
            1 => self.ecx = (self.ecx & 0xFFFFFF00) | v32, // CL
            2 => self.edx = (self.edx & 0xFFFFFF00) | v32, // DL
            3 => self.ebx = (self.ebx & 0xFFFFFF00) | v32, // BL
            4 => self.eax = (self.eax & 0xFFFF00FF) | (v32 << 8), // AH
            5 => self.ecx = (self.ecx & 0xFFFF00FF) | (v32 << 8), // CH
            6 => self.edx = (self.edx & 0xFFFF00FF) | (v32 << 8), // DH
            7 => self.ebx = (self.ebx & 0xFFFF00FF) | (v32 << 8), // BH
        }
    }

    /// Get 16-bit register by index.
    pub fn getReg16(self: *const Cpu, idx: u3) u16 {
        return @truncate(self.getReg(@enumFromInt(idx)));
    }

    /// Set 16-bit register by index (preserves upper 16 bits).
    pub fn setReg16(self: *Cpu, idx: u3, val: u16) void {
        const ri: RegIndex = @enumFromInt(idx);
        const old = self.getReg(ri);
        self.setReg(ri, (old & 0xFFFF0000) | @as(u32, val));
    }

    // --- Stack operations ---

    pub fn push32(self: *Cpu, val: u32) void {
        self.esp -%= 4;
        self.memory.write32(self.esp, val);
    }

    pub fn pop32(self: *Cpu) u32 {
        const val = self.memory.read32(self.esp);
        self.esp +%= 4;
        return val;
    }

    pub fn push16(self: *Cpu, val: u16) void {
        self.esp -%= 2;
        self.memory.write16(self.esp, val);
    }

    pub fn pop16(self: *Cpu) u16 {
        const val = self.memory.read16(self.esp);
        self.esp +%= 2;
        return val;
    }

    // --- Segment address resolution ---

    pub fn resolveSegmentAddress(self: *const Cpu, seg: Segment, offset: u32) u32 {
        return switch (seg) {
            .fs => self.fs_base +% offset,
            else => offset, // flat model, base = 0
        };
    }
};

// -----------------------------------------------------------------------
// Helpers for Zig integer casting (avoids @-litter in decoder/execute code)
// -----------------------------------------------------------------------

/// Sign-extend an 8-bit value to 32 bits.
pub inline fn signExtend8to32(val: u8) u32 {
    return @bitCast(@as(i32, @as(i8, @bitCast(val))));
}

/// Sign-extend a 16-bit value to 32 bits.
pub inline fn signExtend16to32(val: u16) u32 {
    return @bitCast(@as(i32, @as(i16, @bitCast(val))));
}

/// Sign-extend an 8-bit value to 16 bits.
pub inline fn signExtend8to16(val: u8) u16 {
    return @bitCast(@as(i16, @as(i8, @bitCast(val))));
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;

test "cpu: register access by index" {
    var cpu = Cpu{};
    cpu.setReg(.eax, 0xDEADBEEF);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), cpu.getReg(.eax));
    try testing.expectEqual(@as(u32, 0), cpu.getReg(.ebx));
}

test "cpu: 8-bit register access" {
    var cpu = Cpu{};
    cpu.eax = 0x12345678;
    try testing.expectEqual(@as(u8, 0x78), cpu.getReg8(0)); // AL
    try testing.expectEqual(@as(u8, 0x56), cpu.getReg8(4)); // AH

    cpu.setReg8(0, 0xAA); // AL
    try testing.expectEqual(@as(u32, 0x123456AA), cpu.eax);
    cpu.setReg8(4, 0xBB); // AH
    try testing.expectEqual(@as(u32, 0x1234BBAA), cpu.eax);
}

test "cpu: 16-bit register access" {
    var cpu = Cpu{};
    cpu.eax = 0xAABBCCDD;
    try testing.expectEqual(@as(u16, 0xCCDD), cpu.getReg16(0));
    cpu.setReg16(0, 0x1122);
    try testing.expectEqual(@as(u32, 0xAABB1122), cpu.eax);
}

test "cpu: sign extension helpers" {
    try testing.expectEqual(@as(u32, 0xFFFFFF80), signExtend8to32(0x80));
    try testing.expectEqual(@as(u32, 0x0000007F), signExtend8to32(0x7F));
    try testing.expectEqual(@as(u32, 0xFFFF8000), signExtend16to32(0x8000));
    try testing.expectEqual(@as(u32, 0x00007FFF), signExtend16to32(0x7FFF));
}

test "cpu: segment resolution" {
    var cpu = Cpu{};
    cpu.fs_base = 0x7FFE0000;
    try testing.expectEqual(@as(u32, 0x7FFE0000), cpu.resolveSegmentAddress(.fs, 0));
    try testing.expectEqual(@as(u32, 0x7FFE0018), cpu.resolveSegmentAddress(.fs, 0x18));
    try testing.expectEqual(@as(u32, 0x00401000), cpu.resolveSegmentAddress(.ds, 0x00401000));
}
