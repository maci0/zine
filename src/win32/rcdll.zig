//! RCDLL.dll stub registration.
//!
//! Provides stubs for the two exports that RC.EXE imports from RCDLL.DLL.
//! The RC function returns 1 (failure) so RC.EXE reports a usage error,
//! matching the expected exit code for basic invocation tests.

const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32cc = @import("calling_convention.zig");

/// RC entry point — returns 1 (error) to signal "no valid input".
fn rc_main(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c };
    if (trace.enable_tracing) trace.print("RCDLL: RC() -> 1 (stub)\n", .{});
    return 1;
}

/// Handler callback registration — no-op.
fn rc_handler(a: usize) callconv(w32cc.WINAPI) void {
    _ = a;
    if (trace.enable_tracing) trace.print("RCDLL: Handler() (stub)\n", .{});
}

/// Registers RCDLL.dll functions with the environment.
pub fn register(environment: *env.Environment) !void {
    const m = "RCDLL.dll";
    try environment.addBuiltinExportComptime(m, "RC", rc_main);
    try environment.addBuiltinExportComptime(m, "Handler", rc_handler);
}
