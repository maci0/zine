const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "VDMDBG.dll";
    try environment.addBuiltinExportComptime(m, "VDMTerminateTaskWOW", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "VDMEnumTaskWOWEx", kernel32.stub_args3);
}
