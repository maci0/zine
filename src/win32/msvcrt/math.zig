const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const io = @import("io.zig");

/// Implementation status: Partially implemented
pub fn controlfp(new: u32, mask: u32) callconv(.c) u32 {
    _ = new;
    _ = mask;
    return 0x9001f;
}

/// Implementation status: Stub
pub fn stub_setusermatherr(handler: *anyopaque) callconv(.c) void {
    _ = handler;
}

const platform = @import("../../platform.zig");
const native_arch = @import("builtin").target.cpu.arch;

pub const ftol = if (platform.is_x86)
    &stub_ftol_x86
else if (platform.is_x86_64)
    &stub_ftol_x64
else
    &stub_ftol_generic;

fn stub_ftol_x86() callconv(.naked) void {
    asm volatile (
        \\  push %%ebp
        \\  mov %%esp, %%ebp
        \\  sub $8, %%esp
        \\  fistpll -8(%%ebp)
        \\  mov -8(%%ebp), %%eax
        \\  mov -4(%%ebp), %%edx
        \\  mov %%ebp, %%esp
        \\  pop %%ebp
        \\  ret
    );
}

fn stub_ftol_x64() callconv(.c) i64 {
    // On x86_64 the _ftol thunk is called from the interpreter which
    // passes the f64 value as a regular C argument.
    // Native x87-calling-convention path only applies to 32-bit.
    return 0;
}

fn stub_ftol_generic() callconv(.c) i64 {
    // On WASM, _ftol is never called directly by native code.
    // The x86 interpreter handles it via the thunk mechanism.
    return 0;
}

/// Implementation status: Partially implemented
pub fn ceil(x: f64) callconv(.c) f64 {
    return @ceil(x);
}

/// Implementation status: Partially implemented
pub fn floor(x: f64) callconv(.c) f64 {
    return @floor(x);
}

// --- Memory Management ---

/// Calculates the value of base raised to the power of exp.
/// Implementation status: Fully implemented (wraps std.math.pow)
pub fn pow(base: f64, exp: f64) callconv(.c) f64 {
    return std.math.pow(f64, base, exp);
}
