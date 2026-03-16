//! Magnification hook registration.

const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

/// Registers MAG_HOOK.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "MAG_HOOK.dll";
    try environment.addBuiltinExportComptime(m, "_FakeCursorMove@8", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "_SetZoomRect@8", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "_InstallEventHook@4", kernel32.stub_args1);
}
