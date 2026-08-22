//! x86 FPU emulation.

// x87 FPU state for the x86 interpreter.
//
// Supports a broad set of x87 instructions including arithmetic (FADD,
// FMUL, FSUB, FDIV), loads/stores (FLD, FST, FILD, FISTP), comparisons
// (FCOM, FUCOM), and control (FNINIT, FNSTCW, FLDCW, FXCH, FCHS, FABS).

const std = @import("std");

pub const FpuState = struct {
    /// 8-entry register stack (ST(0)..ST(7)) stored as f64.
    stack: [8]f64 = .{0} ** 8,

    /// Top of stack pointer (0-7).  ST(0) = stack[top].
    top: u3 = 0,

    /// FPU status word.
    status_word: u16 = 0,

    /// FPU control word.  Default: round to nearest, all exceptions masked.
    control_word: u16 = 0x037F,

    /// FPU tag word.  All entries initially empty (0xFFFF).
    tag_word: u16 = 0xFFFF,

    /// Reset FPU to initial state (FNINIT).
    pub fn init(self: *FpuState) void {
        self.top = 0;
        self.status_word = 0;
        self.control_word = 0x037F;
        self.tag_word = 0xFFFF;
        self.stack = .{0} ** 8;
    }

    /// Push a value onto the FPU stack.
    pub fn push(self: *FpuState, val: f64) void {
        self.top -%= 1;
        self.stack[self.top] = val;
    }

    /// Pop the top of the FPU stack.
    pub fn pop(self: *FpuState) f64 {
        const val = self.stack[self.top];
        self.stack[self.top] = 0;
        self.top +%= 1;
        return val;
    }

    pub fn st(self: *const FpuState, i: u3) f64 {
        return self.stack[self.top +% i];
    }

    pub fn setSt(self: *FpuState, i: u3, val: f64) void {
        self.stack[self.top +% i] = val;
    }

    /// Get the status word with TOP field embedded.
    pub fn getStatusWord(self: *const FpuState) u16 {
        return (self.status_word & 0xC7FF) | (@as(u16, self.top) << 11);
    }
};

/// Round to integer per an x87/SSE rounding-control field: 00 nearest-even
/// (the default), 01 down, 10 up, 11 toward zero.
pub fn roundPerRc(rc: u2, val: f64) f64 {
    return switch (rc) {
        0b00 => roundHalfEven(val),
        0b01 => @floor(val),
        0b10 => @ceil(val),
        0b11 => @trunc(val),
    };
}

fn roundHalfEven(x: f64) f64 {
    const t = @trunc(x);
    const diff = x - t;
    const adiff = @abs(diff);
    if (adiff < 0.5) return t;
    if (adiff > 0.5) return t + std.math.sign(diff);
    // Exact tie: choose the even neighbor.
    if (@mod(t, 2.0) == 0) return t;
    return t + std.math.sign(diff);
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "fpu: init resets state" {
    var fpu = FpuState{};
    fpu.push(3.14);
    fpu.init();
    try testing.expectEqual(@as(u3, 0), fpu.top);
    try testing.expectEqual(@as(u16, 0x037F), fpu.control_word);
}

test "fpu: push and pop" {
    var fpu = FpuState{};
    fpu.push(1.0);
    fpu.push(2.0);
    try testing.expectEqual(@as(f64, 2.0), fpu.st(0));
    try testing.expectEqual(@as(f64, 1.0), fpu.st(1));
    try testing.expectEqual(@as(f64, 2.0), fpu.pop());
    try testing.expectEqual(@as(f64, 1.0), fpu.st(0));
}

test "fpu: getStatusWord embeds TOP field" {
    var fpu = FpuState{};
    // Initial TOP = 0, status_word = 0 → bits 11-13 should be 000
    try testing.expectEqual(@as(u16, 0), fpu.getStatusWord());

    fpu.push(1.0); // TOP decrements to 7
    const sw = fpu.getStatusWord();
    // TOP field is bits 11-13
    const top_bits = (sw >> 11) & 0x7;
    try testing.expectEqual(@as(u16, 7), top_bits);
}

test "fpu: setSt modifies specific register" {
    var fpu = FpuState{};
    fpu.push(0.0);
    fpu.push(0.0);
    fpu.setSt(1, 42.0);
    try testing.expectEqual(@as(f64, 42.0), fpu.st(1));
    try testing.expectEqual(@as(f64, 0.0), fpu.st(0));
}

test "fpu: stack wraps around" {
    var fpu = FpuState{};
    // Push 8 values (fills the stack)
    var i: u3 = 0;
    while (true) {
        fpu.push(@floatFromInt(i));
        if (i == 7) break;
        i += 1;
    }
    // ST(0) should be the last pushed value (7)
    try testing.expectEqual(@as(f64, 7.0), fpu.st(0));
    // Pop all 8
    var j: u3 = 0;
    while (true) {
        _ = fpu.pop();
        if (j == 7) break;
        j += 1;
    }
    try testing.expectEqual(@as(u3, 0), fpu.top);
}
