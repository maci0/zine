//! CARDS.dll registration.

const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

/// Registers CARDS.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "CARDS.dll";
    try environment.addBuiltinExportComptime(m, "cdtInit", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "cdtTerm", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(m, "cdtDraw", kernel32.stub_args6);
    try environment.addBuiltinExportComptime(m, "cdtDrawExt", kernel32.stub_args8);
    try environment.addBuiltinExportComptime(m, "cdtAnimate", kernel32.stub_args4);
}
