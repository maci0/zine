const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "NDDEAPI.dll";
    // DDE Network APIs — all by ordinal
    try environment.addBuiltinExportComptime(m, "ordinal_500", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "ordinal_501", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "ordinal_503", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "ordinal_504", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ordinal_505", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "ordinal_506", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ordinal_509", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "ordinal_511", kernel32.stub_args6);
    try environment.addBuiltinExportComptime(m, "ordinal_512", kernel32.stub_args6);
    try environment.addBuiltinExportComptime(m, "ordinal_609", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "ordinal_610", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "ordinal_611", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "ordinal_612", kernel32.stub_args6);
}
