//! x86 CPU register state and control flags.
//!
//! This module defines the state of the 32-bit x86 virtual processor,
//! including general-purpose registers, EIP, EFLAGS, and segment bases.
//! It also provides helper functions for register access and stack
//! operations.

const flags_mod = @import("flags.zig");
const fpu_mod = @import("fpu.zig");
const mem_mod = @import("memory.zig");
const cache_mod = @import("decode_cache.zig");

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
pub const Segment = @import("decoder.zig").Segment;

pub const Cpu = struct {
    /// General purpose register EAX (accumulator).
    eax: u32 = 0,
    /// General purpose register ECX (counter).
    ecx: u32 = 0,
    /// General purpose register EDX (data).
    edx: u32 = 0,
    /// General purpose register EBX (base).
    ebx: u32 = 0,
    /// Stack pointer register ESP.
    esp: u32 = 0,
    /// Base pointer register EBP.
    ebp: u32 = 0,
    /// Source index register ESI.
    esi: u32 = 0,
    /// Destination index register EDI.
    edi: u32 = 0,

    /// Instruction pointer register EIP.
    eip: u32 = 0,

    /// Segment registers (flat model, but need FS for TEB).
    cs: u16 = 0x001B,
    ds: u16 = 0x0023,
    es: u16 = 0x0023,
    fs: u16 = 0x003B,
    gs: u16 = 0x0000,
    ss: u16 = 0x0023,

    /// Base address of the FS segment (used for TEB/PEB access).
    fs_base: u32 = 0,

    /// Lazy EFLAGS state (computation deferred until needed).
    flags: LazyFlags = .{},

    /// x87 FPU state (registers and control words).
    fpu: FpuState = .{},

    /// SSE/SSE2 XMM registers (XMM0-XMM7), 128 bits each.
    xmm: [8]u128 = .{0} ** 8,

    /// MXCSR — SSE control/status register.
    /// Default: all exceptions masked (bits 7-12), round to nearest (bits 13-14 = 00).
    mxcsr: u32 = 0x1F80,

    /// Guest memory reference (maps virtual guest addresses to host memory).
    memory: GuestMemory = .{ .base = &.{} },

    /// Instruction decode cache — avoids re-decoding instructions in loops.
    decode_cache: cache_mod.DecodeCache = .{},

    /// If true, the CPU has encountered a HLT instruction or fatal error.
    halted: bool = false,
    /// Pending interrupt number to be handled on the next step.
    pending_interrupt: ?u8 = null,

    // --- Register access by index ---

    /// Gets the value of a general-purpose register by its 3-bit index.
    pub inline fn getReg(self: *const Cpu, idx: RegIndex) u32 {
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

    /// Sets the value of a general-purpose register by its 3-bit index.
    pub inline fn setReg(self: *Cpu, idx: RegIndex, val: u32) void {
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

    /// 0-3 = AL, CL, DL, BL (low byte), 4-7 = AH, CH, DH, BH (high byte).
    pub inline fn getReg8(self: *const Cpu, idx: u3) u8 {
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

    pub inline fn setReg8(self: *Cpu, idx: u3, val: u8) void {
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

    pub inline fn getReg16(self: *const Cpu, idx: u3) u16 {
        return @truncate(self.getReg(@enumFromInt(idx)));
    }

    /// Preserves upper 16 bits.
    pub inline fn setReg16(self: *Cpu, idx: u3, val: u16) void {
        const ri: RegIndex = @enumFromInt(idx);
        const old = self.getReg(ri);
        self.setReg(ri, (old & 0xFFFF0000) | @as(u32, val));
    }

    // --- Stack operations ---

    /// Pushes a 32-bit value onto the guest stack and decrements ESP.
    pub fn push32(self: *Cpu, val: u32) void {
        self.esp -%= 4;
        self.memory.write32(self.esp, val);
    }

    /// Pops a 32-bit value from the guest stack and increments ESP.
    pub fn pop32(self: *Cpu) u32 {
        const val = self.memory.read32(self.esp);
        self.esp +%= 4;
        return val;
    }

    /// Pushes a 16-bit value onto the guest stack and decrements ESP by 2.
    pub fn push16(self: *Cpu, val: u16) void {
        self.esp -%= 2;
        self.memory.write16(self.esp, val);
    }

    /// Pops a 16-bit value from the guest stack and increments ESP by 2.
    pub fn pop16(self: *Cpu) u16 {
        const val = self.memory.read16(self.esp);
        self.esp +%= 2;
        return val;
    }

    // --- XMM register access ---

    pub fn getXmmBytes(self: *const Cpu, idx: u3) [16]u8 {
        return @bitCast(self.xmm[idx]);
    }

    pub fn setXmmBytes(self: *Cpu, idx: u3, val: [16]u8) void {
        self.xmm[idx] = @bitCast(val);
    }

    pub fn getXmmF32(self: *const Cpu, idx: u3) [4]f32 {
        return @bitCast(self.xmm[idx]);
    }

    pub fn setXmmF32(self: *Cpu, idx: u3, val: [4]f32) void {
        self.xmm[idx] = @bitCast(val);
    }

    pub fn getXmmF64(self: *const Cpu, idx: u3) [2]f64 {
        return @bitCast(self.xmm[idx]);
    }

    pub fn setXmmF64(self: *Cpu, idx: u3, val: [2]f64) void {
        self.xmm[idx] = @bitCast(val);
    }

    pub fn getXmmU32(self: *const Cpu, idx: u3) [4]u32 {
        return @bitCast(self.xmm[idx]);
    }

    pub fn setXmmU32(self: *Cpu, idx: u3, val: [4]u32) void {
        self.xmm[idx] = @bitCast(val);
    }

    pub fn getXmmU64(self: *const Cpu, idx: u3) [2]u64 {
        return @bitCast(self.xmm[idx]);
    }

    pub fn setXmmU64(self: *Cpu, idx: u3, val: [2]u64) void {
        self.xmm[idx] = @bitCast(val);
    }

    // --- MMX register access (aliased to x87 FPU stack physical slots) ---

    /// MMX registers alias x87 FPU physical register slots.
    pub fn getMmx(self: *const Cpu, idx: u3) u64 {
        return @bitCast(self.fpu.stack[idx]);
    }

    pub fn setMmx(self: *Cpu, idx: u3, val: u64) void {
        self.fpu.stack[idx] = @bitCast(val);
    }

    // --- Segment address resolution ---

    /// Resolves a segment-relative offset to a flat 32-bit virtual address.
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

test "cpu: push32 and pop32" {
    var buf: [256]u8 = .{0} ** 256;
    var cpu = Cpu{};
    cpu.memory = GuestMemory{ .base = &buf };
    cpu.esp = 200;

    cpu.push32(0xDEADBEEF);
    try testing.expectEqual(@as(u32, 196), cpu.esp); // ESP decremented by 4
    try testing.expectEqual(@as(u32, 0xDEADBEEF), cpu.memory.read32(196));

    const val = cpu.pop32();
    try testing.expectEqual(@as(u32, 0xDEADBEEF), val);
    try testing.expectEqual(@as(u32, 200), cpu.esp); // ESP restored
}

test "cpu: sign extension edge cases" {
    // 0x00 → 0x00000000 (positive zero)
    try testing.expectEqual(@as(u32, 0x00000000), signExtend8to32(0x00));
    // 0xFF → 0xFFFFFFFF (-1)
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), signExtend8to32(0xFF));
    // 0x0000 → 0x00000000
    try testing.expectEqual(@as(u32, 0x00000000), signExtend16to32(0x0000));
    // 0xFFFF → 0xFFFFFFFF (-1)
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), signExtend16to32(0xFFFF));
}
