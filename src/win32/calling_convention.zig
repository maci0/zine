//! Win32 calling convention aliases.

// Calling convention alias for Win32 API stubs.
//
// On native x86/x86_64 targets, this resolves to `std.lang.CallingConvention.winapi`
// (stdcall on x86, Win64 on x86_64).  On all other targets (WASM, ARM,
// RISC-V, etc.) where there is no stdcall convention, we fall back to `.c`.
//
// All Win32 API stubs should use `callconv(WINAPI)` instead of
// `callconv(.winapi)` to ensure cross-target compilation.

const std = @import("std");

const arch = @import("builtin").target.cpu.arch;

pub const WINAPI: std.lang.CallingConvention = if (arch == .x86 or arch == .x86_64)
    .winapi
else
    .c;

/// Fully implemented: USER32's variadic formatters use cdecl like the CRT.
pub fn isCdeclExport(dll: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(dll, "MSVCRT.dll") or std.ascii.startsWithIgnoreCase(dll, "MSVCP") or
        (std.ascii.eqlIgnoreCase(dll, "USER32.dll") and
            (std.mem.eql(u8, name, "wsprintfA") or std.mem.eql(u8, name, "wsprintfW")));
}

test "only USER32 variadic formatters use caller stack cleanup" {
    try std.testing.expect(isCdeclExport("user32.dll", "wsprintfW"));
    try std.testing.expect(isCdeclExport("USER32.dll", "wsprintfA"));
    try std.testing.expect(!isCdeclExport("user32.dll", "wvsprintfW"));
    try std.testing.expect(!isCdeclExport("other.dll", "wsprintfA"));
    try std.testing.expect(isCdeclExport("msvcrt.dll", "sprintf"));
}
