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
    raw_flags: u32 = EFLAGS_DEFAULT, // IF set, reserved bit 1 set

    /// Direction Flag stored separately — DF is orthogonal to ALU flag
    /// computations and is only changed by CLD/STD. Storing it separately
    /// avoids materializing all flags just to read DF in string operations.
    df: bool = false,

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

    /// Return the Direction Flag (DF) — O(1), no flag materialization needed.
    pub inline fn getDF(self: *const LazyFlags) bool {
        return self.df;
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
        if (self.op == .none) {
            // DF is stored separately — merge it into the raw flags.
            // setFlag(FLAG_DF) only updates self.df without touching raw_flags,
            // so we must reconcile here to avoid returning stale DF state.
            var flags = self.raw_flags;
            if (self.df) {
                flags |= FLAG_DF;
            } else {
                flags &= ~FLAG_DF;
            }
            return flags;
        }

        var flags: u32 = EFLAGS_DEFAULT; // Reserved bit 1 + IF always set
        if (self.getCF()) flags |= FLAG_CF;
        if (self.getPF()) flags |= FLAG_PF;
        if (self.getAF()) flags |= FLAG_AF;
        if (self.getZF()) flags |= FLAG_ZF;
        if (self.getSF()) flags |= FLAG_SF;
        if (self.getOF()) flags |= FLAG_OF;
        if (self.df) flags |= FLAG_DF;
        return flags;
    }

    /// Restore flags from a raw EFLAGS value (for POPFD, SAHF, etc.).
    pub fn fromEflags(self: *LazyFlags, eflags: u32) void {
        self.op = .none;
        self.raw_flags = eflags | FLAG_RESERVED; // Ensure reserved bit 1 is always set
        self.df = (eflags & FLAG_DF) != 0;
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
        // DF is stored separately — avoid full materialization for CLD.
        if (comptime flag == FLAG_DF) {
            self.df = false;
            return;
        }
        var ef = self.toEflags();
        ef &= ~flag;
        self.fromEflags(ef);
    }

    /// Set a single flag bit.
    pub inline fn setFlag(self: *LazyFlags, comptime flag: u32) void {
        // DF is stored separately — avoid full materialization for STD.
        if (comptime flag == FLAG_DF) {
            self.df = true;
            return;
        }
        var ef = self.toEflags();
        ef |= flag;
        self.fromEflags(ef);
    }

    /// Toggle a single flag bit.
    pub inline fn toggleFlag(self: *LazyFlags, comptime flag: u32) void {
        // DF is stored separately — avoid full materialization.
        if (comptime flag == FLAG_DF) {
            self.df = !self.df;
            return;
        }
        var ef = self.toEflags();
        ef ^= flag;
        self.fromEflags(ef);
    }
};

/// Reserved bit 1 (always set in EFLAGS).
pub const FLAG_RESERVED: u32 = 1 << 1;
/// Default EFLAGS value: reserved bit 1 + IF (interrupt enable).
pub const EFLAGS_DEFAULT: u32 = FLAG_RESERVED | (1 << 9);

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

test "lazy flags: signed condition codes L/NL/LE/NLE" {
    var f = LazyFlags{};
    // cmp 5, 10 -> result -5: SF=1 OF=0 ZF=0, so signed 5 < 10.
    f.update(.sub, .dword, 0xFFFFFFFB, 5, 10);
    try testing.expect(f.evaluateCC(0xC)); // JL
    try testing.expect(!f.evaluateCC(0xD)); // JNL
    try testing.expect(f.evaluateCC(0xE)); // JLE
    try testing.expect(!f.evaluateCC(0xF)); // JNLE/JG

    // cmp 10, 5 -> result +5: SF=0 OF=0 ZF=0, so signed 10 > 5.
    f.update(.sub, .dword, 5, 10, 5);
    try testing.expect(!f.evaluateCC(0xC));
    try testing.expect(f.evaluateCC(0xD));
    try testing.expect(!f.evaluateCC(0xE));
    try testing.expect(f.evaluateCC(0xF));

    // Equal operands: only LE and NL may fire (ZF=1).
    f.update(.sub, .dword, 0, 42, 42);
    try testing.expect(!f.evaluateCC(0xC));
    try testing.expect(f.evaluateCC(0xD));
    try testing.expect(f.evaluateCC(0xE));
    try testing.expect(!f.evaluateCC(0xF));

    // Signed overflow must drive JL even when SF=0:
    // cmp 0x80000000, 1 wraps to 0x7FFFFFFF with OF=1, and INT_MIN < 1.
    f.update(.sub, .dword, 0x7FFFFFFF, 0x80000000, 1);
    try testing.expect(f.getOF());
    try testing.expect(!f.getSF());
    try testing.expect(f.evaluateCC(0xC)); // JL — SF != OF
    try testing.expect(!f.evaluateCC(0xD));
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

test "lazy flags: overflow on signed add" {
    var f = LazyFlags{};
    // 0x7FFFFFFF + 1 = 0x80000000: positive + positive = negative → OF=1
    f.update(.add, .dword, 0x80000000, 0x7FFFFFFF, 0x00000001);
    try testing.expect(f.getOF());
    try testing.expect(f.getSF()); // result is negative
    try testing.expect(!f.getZF());
}

test "lazy flags: no overflow on unsigned add" {
    var f = LazyFlags{};
    // 1 + 2 = 3: no sign change → OF=0
    f.update(.add, .dword, 3, 1, 2);
    try testing.expect(!f.getOF());
    try testing.expect(!f.getCF());
}

test "lazy flags: overflow on signed sub" {
    var f = LazyFlags{};
    // 0x80000000 - 1 = 0x7FFFFFFF: negative - positive = positive → OF=1
    f.update(.sub, .dword, 0x7FFFFFFF, 0x80000000, 0x00000001);
    try testing.expect(f.getOF());
    try testing.expect(!f.getSF()); // result is positive
}

test "lazy flags: word-size operations" {
    var f = LazyFlags{};
    // 0xFFFF + 1 = 0x10000, but word-size mask → result = 0x0000
    f.update(.add, .word, 0x00000000, 0x0000FFFF, 0x00000001);
    try testing.expect(f.getCF()); // carry out of 16 bits
    try testing.expect(f.getZF()); // masked result is 0
    try testing.expect(!f.getSF()); // bit 15 of result is 0
}

test "lazy flags: inc overflow" {
    var f = LazyFlags{};
    // INC 0x7FFFFFFF → 0x80000000: OF should be set
    f.update(.inc, .dword, 0x80000000, 0x7FFFFFFF, 1);
    try testing.expect(f.getOF());
    try testing.expect(f.getSF());
    try testing.expect(!f.getCF()); // INC doesn't affect CF
}

test "lazy flags: dec overflow" {
    var f = LazyFlags{};
    // DEC 0x80000000 → 0x7FFFFFFF: OF should be set
    f.update(.dec, .dword, 0x7FFFFFFF, 0x80000000, 1);
    try testing.expect(f.getOF());
    try testing.expect(!f.getSF());
    try testing.expect(!f.getCF()); // DEC doesn't affect CF
}

test "lazy flags: neg sets CF when result non-zero" {
    var f = LazyFlags{};
    // NEG 5 → 0xFFFFFFFB: CF=1 (result != 0), SF=1, ZF=0
    f.update(.neg, .dword, 0xFFFFFFFB, 5, 5);
    try testing.expect(f.getCF());
    try testing.expect(f.getSF());
    try testing.expect(!f.getZF());
}

test "lazy flags: neg zero clears CF" {
    var f = LazyFlags{};
    // NEG 0 → 0: CF=0
    f.update(.neg, .dword, 0, 0, 0);
    try testing.expect(!f.getCF());
    try testing.expect(f.getZF());
}

test "lazy flags: AF on add with half-carry" {
    var f = LazyFlags{};
    // 0x0F + 0x01 = 0x10: carry from bit 3 to bit 4 → AF=1
    f.update(.add, .byte, 0x10, 0x0F, 0x01);
    try testing.expect(f.getAF());
}

test "lazy flags: AF clear when no half-carry" {
    var f = LazyFlags{};
    // 0x01 + 0x02 = 0x03: no carry from bit 3 → AF=0
    f.update(.add, .byte, 0x03, 0x01, 0x02);
    try testing.expect(!f.getAF());
}

test "lazy flags: DF set and clear" {
    var f = LazyFlags{};
    try testing.expect(!f.getDF());
    f.setFlag(FLAG_DF);
    try testing.expect(f.getDF());
    f.clearFlag(FLAG_DF);
    try testing.expect(!f.getDF());
}

test "lazy flags: shl carry flag" {
    var f = LazyFlags{};
    // SHL 0x80000000, 1 → 0x00000000: last bit shifted out is 1 → CF=1
    f.update(.shl, .dword, 0x00000000, 0x80000000, 1);
    try testing.expect(f.getCF());
    try testing.expect(f.getZF());
}

test "lazy flags: shr carry flag" {
    var f = LazyFlags{};
    // SHR 0x01, 1 → 0x00: last bit shifted out is 1 → CF=1
    f.update(.shr, .dword, 0x00000000, 0x01, 1);
    try testing.expect(f.getCF());
    try testing.expect(f.getZF());
}

test "lazy flags: toEflags includes DF" {
    var f = LazyFlags{};
    f.df = true;
    const eflags = f.toEflags();
    try testing.expect((eflags & FLAG_DF) != 0);

    f.df = false;
    const eflags2 = f.toEflags();
    try testing.expect((eflags2 & FLAG_DF) == 0);
}

test "lazy flags: fromEflags restores DF" {
    var f = LazyFlags{};
    f.fromEflags(FLAG_DF | EFLAGS_DEFAULT);
    try testing.expect(f.df);
    try testing.expect(f.getDF());

    f.fromEflags(EFLAGS_DEFAULT);
    try testing.expect(!f.df);
}

test "lazy flags: toggleFlag" {
    var f = LazyFlags{};
    f.fromEflags(EFLAGS_DEFAULT);
    try testing.expect(!f.getCF());
    f.toggleFlag(FLAG_CF);
    try testing.expect(f.getCF());
    f.toggleFlag(FLAG_CF);
    try testing.expect(!f.getCF());
}

test "lazy flags: toggleFlag DF" {
    var f = LazyFlags{};
    try testing.expect(!f.getDF());
    f.toggleFlag(FLAG_DF);
    try testing.expect(f.getDF());
    f.toggleFlag(FLAG_DF);
    try testing.expect(!f.getDF());
}
