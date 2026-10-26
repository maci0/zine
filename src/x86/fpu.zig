//! x86 FPU emulation.

// x87 FPU state for the x86 interpreter.
//
// Supports a broad set of x87 instructions including arithmetic (FADD,
// FMUL, FSUB, FDIV), loads/stores (FLD, FST, FILD, FISTP), comparisons
// (FCOM, FUCOM), and control (FNINIT, FNSTCW, FLDCW, FXCH, FCHS, FABS).

const std = @import("std");

pub const FpuState = struct {
    /// 8-entry register stack (ST(0)..ST(7)) stored as f64.
    stack: [8]f64 = @splat(0),

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
        self.stack = @splat(0);
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

/// Safe float-to-int conversion with masked-x87 semantics: truncate toward
/// zero; NaN and out-of-range inputs produce the integer indefinite value
/// (most-negative), matching real FISTP/_ftol instead of saturating.
pub fn safeFloatToInt(comptime T: type, val: f64) T {
    comptime std.debug.assert(@typeInfo(T).int.signedness == .signed);
    if (!std.math.isFinite(val)) return std.math.minInt(T);
    const t = @trunc(val);
    const min_f: f64 = @floatFromInt(std.math.minInt(T));
    // Exact power-of-two upper bound above maxInt avoids f64 rounding
    // ambiguity near maxInt for wide types.
    const max_excl: f64 = @floatFromInt(@as(u64, 1) << (@bitSizeOf(T) - 1));
    if (t < min_f or t >= max_excl) return std.math.minInt(T);
    return @intFromFloat(t);
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

test "fpu: float-to-int truncates and returns integer indefinite" {
    inline for (.{ i16, i32, i64 }) |T| {
        const min = std.math.minInt(T);
        const min_f: f64 = @floatFromInt(min);
        const max_excl = -min_f;
        try testing.expectEqual(@as(T, 0), safeFloatToInt(T, 0.0));
        try testing.expectEqual(@as(T, 0), safeFloatToInt(T, -0.0));
        try testing.expectEqual(@as(T, 1), safeFloatToInt(T, 1.9));
        try testing.expectEqual(@as(T, -1), safeFloatToInt(T, -1.9));
        try testing.expectEqual(@as(T, min), safeFloatToInt(T, min_f));
        try testing.expectEqual(@as(T, min), safeFloatToInt(T, min_f * 2));
        try testing.expectEqual(@as(T, min), safeFloatToInt(T, max_excl));
        try testing.expectEqual(@as(T, min), safeFloatToInt(T, std.math.nan(f64)));
        try testing.expectEqual(@as(T, min), safeFloatToInt(T, std.math.inf(f64)));
        try testing.expectEqual(@as(T, min), safeFloatToInt(T, -std.math.inf(f64)));
    }
    try testing.expectEqual(@as(i16, 32767), safeFloatToInt(i16, 32767.9));
    try testing.expectEqual(@as(i32, 2147483647), safeFloatToInt(i32, 2147483647.9));
    try testing.expectEqual(@as(i64, 9223372036854774784), safeFloatToInt(i64, 9223372036854774784.0));
}

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
