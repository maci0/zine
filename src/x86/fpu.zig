//! x86 FPU emulation.

// Minimal x87 FPU state for the x86 interpreter.
//
// Most Win32 apps use only basic floating point.  This provides enough
// state to survive CRT initialisation (FNINIT, FNSTCW, FLDCW) without
// crashing.  Full FPU instruction implementation is deferred.

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

    /// Read ST(i).
    pub fn st(self: *const FpuState, i: u3) f64 {
        return self.stack[self.top +% i];
    }

    /// Write ST(i).
    pub fn setSt(self: *FpuState, i: u3, val: f64) void {
        self.stack[self.top +% i] = val;
    }

    /// Get the status word with TOP field embedded.
    pub fn getStatusWord(self: *const FpuState) u16 {
        return (self.status_word & 0xC7FF) | (@as(u16, self.top) << 11);
    }
};

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
