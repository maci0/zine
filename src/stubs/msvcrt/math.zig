const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const io = @import("io.zig");

const string = @import("string.zig");
const process = @import("process.zig");
const mem = @import("mem.zig");
const math = @import("math.zig");
const misc = @import("misc.zig");

pub fn stub_controlfp(new: u32, mask: u32) callconv(.c) u32 {
    _ = new;
    _ = mask;
    return 0x9001f;
}

pub fn stub_setusermatherr(handler: *anyopaque) callconv(.c) void {
    _ = handler;
}

const platform = @import("../../platform.zig");
const native_arch = @import("builtin").target.cpu.arch;

pub const stub_ftol = if (platform.is_x86)
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

fn stub_ftol_x64() callconv(.naked) void {
    asm volatile (
        \\  cvttsd2si %%xmm0, %%rax
        \\  ret
    );
}

fn stub_ftol_generic() callconv(.c) i64 {
    // On WASM, _ftol is never called directly by native code.
    // The x86 interpreter handles it via the thunk mechanism.
    return 0;
}

// --- Memory Management ---
