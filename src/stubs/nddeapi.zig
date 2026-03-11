const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "NDDEAPI.dll";
    // DDE Network APIs — all by ordinal
    try environment.addBuiltinExport(m, "ordinal_500", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "ordinal_501", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "ordinal_503", @intFromPtr(&kernel32.stub_args5));
    try environment.addBuiltinExport(m, "ordinal_504", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(m, "ordinal_505", @intFromPtr(&kernel32.stub_args5));
    try environment.addBuiltinExport(m, "ordinal_506", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(m, "ordinal_509", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "ordinal_511", @intFromPtr(&kernel32.stub_args6));
    try environment.addBuiltinExport(m, "ordinal_512", @intFromPtr(&kernel32.stub_args6));
    try environment.addBuiltinExport(m, "ordinal_609", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "ordinal_610", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "ordinal_611", @intFromPtr(&kernel32.stub_args5));
    try environment.addBuiltinExport(m, "ordinal_612", @intFromPtr(&kernel32.stub_args6));
}
