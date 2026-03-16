//! NDDEAPI.dll registration.

const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");
const ord = @import("ordinals.zig").NDDEAPI;

/// Registers NDDEAPI.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "NDDEAPI.dll";
    // DDE Network APIs — all by ordinal (W = Unicode variants)
    try environment.addBuiltinExportComptime(m, ord.NDdeShareAddW, kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, ord.NDdeShareDelW, kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, ord.NDdeShareGetInfoW, kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, ord.NDdeShareSetInfoW, kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, ord.NDdeShareEnumW, kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, ord.NDdeGetShareSecurityW, kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, ord.NDdeSetShareSecurityW, kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, ord.NDdeSetTrustedShareW, kernel32.stub_args6);
    try environment.addBuiltinExportComptime(m, ord.NDdeGetTrustedShareW, kernel32.stub_args6);
    try environment.addBuiltinExportComptime(m, ord.NDdeGetErrorStringW, kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, ord.NDdeIsValidShareNameW, kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, ord.NDdeIsValidAppTopicListW, kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, ord.NDdeTrustedShareEnumW, kernel32.stub_args6);
}
