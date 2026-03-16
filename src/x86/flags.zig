//! Lazy EFLAGS implementation for the x86 interpreter.
//!
//! x86 sets FLAGS on almost every ALU instruction but they're rarely read.
//! Computing all 6 status flags on every instruction is ~30% overhead.
//! Instead, we store the operation context and compute flags on demand.

/// What operation produced the current flag state.
pub const FlagOp = enum {
    add,
    sub,
    adc,
    sbb,
    logic, // AND, OR, XOR, TEST — CF=0, OF=0
    inc,
    dec,
    shl,
    shr,
    sar,
    neg,
    none, // flags explicitly set (e.g. POPFD, SAHF)
};

/// Operand size — determines which bits are significant.
pub const OpSize = enum {
    byte,
    word,
    dword,

    /// Return the number of bits for this operand size.
    pub fn bits(self: OpSize) u6 {
        return switch (self) {
            .byte => 8,
            .word => 16,
            .dword => 32,
        };
    }

    /// Return a bitmask for this operand size.
    pub fn mask(self: OpSize) u32 {
        return switch (self) {
            .byte => 0xFF,
            .word => 0xFFFF,
            .dword => 0xFFFFFFFF,
        };
    }

    /// Return the sign bit for this operand size.
    pub fn signBit(self: OpSize) u32 {
        return switch (self) {
            .byte => 0x80,
            .word => 0x8000,
            .dword => 0x80000000,
        };
    }
};

/// Lazy flags — stores the operation context and computes individual flags
/// only when they are actually read.
pub const LazyFlags = struct {
    op: FlagOp = .none,
    result: u32 = 0,
    operand1: u32 = 0,
    operand2: u32 = 0,
    carry_in: u32 = 0,
    size: OpSize = .dword,

    // When op == .none, these hold the raw EFLAGS bits
    raw_flags: u32 = 0x202, // IF set, reserved bit 1 set

    /// Return the Zero Flag (ZF).
    pub fn getZF(self: *const LazyFlags) bool {
        if (self.op == .none) return (self.raw_flags & FLAG_ZF) != 0;
        return (self.result & self.size.mask()) == 0;
    }

    /// Return the Sign Flag (SF).
    pub fn getSF(self: *const LazyFlags) bool {
        if (self.op == .none) return (self.raw_flags & FLAG_SF) != 0;
        return (self.result & self.size.signBit()) != 0;
    }

    /// Return the Carry Flag (CF).
    pub fn getCF(self: *const LazyFlags) bool {
        if (self.op == .none) return (self.raw_flags & FLAG_CF) != 0;
        const m = self.size.mask();
        return switch (self.op) {
            .add => (@as(u64, self.operand1 & m) + @as(u64, self.operand2 & m)) > m,
            .sub => (@as(u64, self.operand1 & m)) < (@as(u64, self.operand2 & m)),
            .adc => (@as(u64, self.operand1 & m) + @as(u64, self.operand2 & m) + self.carry_in) > m,
            .sbb => (@as(u64, self.operand1 & m)) < (@as(u64, self.operand2 & m) + self.carry_in),
            .neg => (self.result & m) != 0,
            .shl => blk: {
                // Carry is the last bit shifted out
                const shift: u6 = @truncate(self.operand2);
                if (shift == 0) break :blk false;
                const bit_pos: u5 = @truncate(self.size.bits() -| shift);
                break :blk ((self.operand1 >> bit_pos) & 1) != 0;
            },
            .shr, .sar => blk: {
                const shift = @as(u5, @truncate(self.operand2));
                if (shift == 0) break :blk false;
                break :blk ((self.operand1 >> @as(u5, @truncate(shift -% 1))) & 1) != 0;
            },
            .logic => false,
            .inc, .dec => false, // INC/DEC don't affect CF
            .none => unreachable,
        };
    }

    /// Return the Overflow Flag (OF).
    pub fn getOF(self: *const LazyFlags) bool {
        if (self.op == .none) return (self.raw_flags & FLAG_OF) != 0;
        const sb = self.size.signBit();
        return switch (self.op) {
            .add, .adc => ((~(self.operand1 ^ self.operand2)) & (self.operand1 ^ self.result) & sb) != 0,
            .sub, .sbb => (((self.operand1 ^ self.operand2)) & (self.operand1 ^ self.result) & sb) != 0,
            .neg => (self.result & self.operand1 & sb) != 0,
            .inc => self.result == sb,
            .dec => (self.result & self.size.mask()) == (sb -% 1),
            .logic => false,
            .shl, .shr, .sar => false, // simplified — only defined for shift count 1
            .none => unreachable,
        };
    }

    /// Return the Parity Flag (PF) — set if low byte of result has even number of set bits.
    pub fn getPF(self: *const LazyFlags) bool {
        if (self.op == .none) return (self.raw_flags & FLAG_PF) != 0;
        const low_byte: u8 = @truncate(self.result);
        return (@popCount(low_byte) & 1) == 0;
    }

    /// Return the Auxiliary Carry Flag (AF) (BCD half-carry from bit 3 to bit 4).
    pub fn getAF(self: *const LazyFlags) bool {
        if (self.op == .none) return (self.raw_flags & FLAG_AF) != 0;
        return switch (self.op) {
            .add, .sub, .adc, .sbb, .inc, .dec, .neg => ((self.operand1 ^ self.operand2 ^ self.result) & 0x10) != 0,
            .logic => false,
            .shl, .shr, .sar => false,
            .none => unreachable,
        };
    }

    /// Evaluate a condition code (used by Jcc, SETcc, CMOVcc).
    /// `cc` is the low 4 bits of the opcode (0x0-0xF).
    pub fn evaluateCC(self: *const LazyFlags, cc: u4) bool {
        return switch (cc) {
            0x0 => self.getOF(), // O
            0x1 => !self.getOF(), // NO
            0x2 => self.getCF(), // B/NAE/C
            0x3 => !self.getCF(), // NB/AE/NC
            0x4 => self.getZF(), // E/Z
            0x5 => !self.getZF(), // NE/NZ
            0x6 => self.getCF() or self.getZF(), // BE/NA
            0x7 => !self.getCF() and !self.getZF(), // NBE/A
            0x8 => self.getSF(), // S
            0x9 => !self.getSF(), // NS
            0xA => self.getPF(), // P/PE
            0xB => !self.getPF(), // NP/PO
            0xC => self.getSF() != self.getOF(), // L/NGE
            0xD => self.getSF() == self.getOF(), // NL/GE
            0xE => self.getZF() or (self.getSF() != self.getOF()), // LE/NG
            0xF => !self.getZF() and (self.getSF() == self.getOF()), // NLE/G
        };
    }

    /// Materialize full EFLAGS value (for PUSHFD, LAHF, etc.).
    pub fn toEflags(self: *const LazyFlags) u32 {
        if (self.op == .none) return self.raw_flags;

        var flags: u32 = 0x202; // Reserved bit 1 + IF always set
        if (self.getCF()) flags |= FLAG_CF;
        if (self.getPF()) flags |= FLAG_PF;
        if (self.getAF()) flags |= FLAG_AF;
        if (self.getZF()) flags |= FLAG_ZF;
        if (self.getSF()) flags |= FLAG_SF;
        if (self.getOF()) flags |= FLAG_OF;
        return flags;
    }

    /// Restore flags from a raw EFLAGS value (for POPFD, SAHF, etc.).
    pub fn fromEflags(self: *LazyFlags, eflags: u32) void {
        self.op = .none;
        self.raw_flags = eflags | 0x2; // Ensure reserved bit 1 is always set
    }

    /// Set flags after an ALU operation.
    pub fn update(self: *LazyFlags, op: FlagOp, size: OpSize, result: u32, op1: u32, op2: u32) void {
        self.op = op;
        self.size = size;
        self.result = result;
        self.operand1 = op1;
        self.operand2 = op2;
        self.carry_in = 0;
    }

    /// Set flags after an ALU operation with carry/borrow input.
    pub fn updateCarry(self: *LazyFlags, op: FlagOp, size: OpSize, result: u32, op1: u32, op2: u32, carry_in: u32) void {
        self.op = op;
        self.size = size;
        self.result = result;
        self.operand1 = op1;
        self.operand2 = op2;
        self.carry_in = carry_in;
    }

    /// Clear a single flag bit.
    pub inline fn clearFlag(self: *LazyFlags, comptime flag: u32) void {
        var ef = self.toEflags();
        ef &= ~flag;
        self.fromEflags(ef);
    }

    /// Set a single flag bit.
    pub inline fn setFlag(self: *LazyFlags, comptime flag: u32) void {
        var ef = self.toEflags();
        ef |= flag;
        self.fromEflags(ef);
    }

    /// Toggle a single flag bit.
    pub inline fn toggleFlag(self: *LazyFlags, comptime flag: u32) void {
        var ef = self.toEflags();
        ef ^= flag;
        self.fromEflags(ef);
    }
};

/// Carry Flag (CF) bit position.
pub const FLAG_CF: u32 = 1 << 0;
/// Parity Flag (PF) bit position.
pub const FLAG_PF: u32 = 1 << 2;
/// Auxiliary Carry Flag (AF) bit position.
pub const FLAG_AF: u32 = 1 << 4;
/// Zero Flag (ZF) bit position.
pub const FLAG_ZF: u32 = 1 << 6;
/// Sign Flag (SF) bit position.
pub const FLAG_SF: u32 = 1 << 7;
/// Trap Flag (TF) bit position.
pub const FLAG_TF: u32 = 1 << 8;
/// Interrupt Enable Flag (IF) bit position.
pub const FLAG_IF: u32 = 1 << 9;
/// Direction Flag (DF) bit position.
pub const FLAG_DF: u32 = 1 << 10;
/// Overflow Flag (OF) bit position.
pub const FLAG_OF: u32 = 1 << 11;

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;

test "lazy flags: add with carry" {
    var f = LazyFlags{};
    f.update(.add, .dword, 0x00000000, 0xFFFFFFFF, 0x00000001);
    try testing.expect(f.getCF()); // 0xFFFFFFFF + 1 wraps
    try testing.expect(f.getZF()); // result is 0
    try testing.expect(!f.getSF()); // result is 0
}

test "lazy flags: sub no borrow" {
    var f = LazyFlags{};
    f.update(.sub, .dword, 5, 10, 5);
    try testing.expect(!f.getCF());
    try testing.expect(!f.getZF());
    try testing.expect(!f.getSF());
}

test "lazy flags: sub with borrow" {
    var f = LazyFlags{};
    f.update(.sub, .dword, 0xFFFFFFFB, 5, 10);
    try testing.expect(f.getCF()); // 5 < 10
    try testing.expect(!f.getZF());
    try testing.expect(f.getSF()); // result is negative
}

test "lazy flags: logic zeroes CF and OF" {
    var f = LazyFlags{};
    f.update(.logic, .dword, 0xFF, 0xFF, 0xFF);
    try testing.expect(!f.getCF());
    try testing.expect(!f.getOF());
    try testing.expect(!f.getZF());
}

test "lazy flags: evaluate condition codes" {
    var f = LazyFlags{};
    // ZF=1
    f.update(.sub, .dword, 0, 42, 42);
    try testing.expect(f.evaluateCC(0x4)); // JE — ZF=1
    try testing.expect(!f.evaluateCC(0x5)); // JNE — ZF=0
    try testing.expect(!f.getCF()); // 42 >= 42
    try testing.expect(f.evaluateCC(0x6)); // JBE — CF=1 or ZF=1 (ZF=1)
}

test "lazy flags: parity" {
    var f = LazyFlags{};
    f.update(.logic, .byte, 0x03, 0x03, 0x03); // 0x03 = 0b11, 2 bits set = even parity
    try testing.expect(f.getPF());
    f.update(.logic, .byte, 0x07, 0x07, 0x07); // 0x07 = 0b111, 3 bits = odd parity
    try testing.expect(!f.getPF());
}

test "lazy flags: toEflags roundtrip" {
    var f = LazyFlags{};
    f.update(.add, .dword, 0, 0xFFFFFFFF, 1);
    const eflags = f.toEflags();
    var f2 = LazyFlags{};
    f2.fromEflags(eflags);
    try testing.expectEqual(f.getZF(), f2.getZF());
    try testing.expectEqual(f.getCF(), f2.getCF());
    try testing.expectEqual(f.getSF(), f2.getSF());
}

test "lazy flags: byte-size SF" {
    var f = LazyFlags{};
    f.update(.sub, .byte, 0x80, 0x00, 0x80); // result = 0x80, sign bit set for byte
    try testing.expect(f.getSF());
}
