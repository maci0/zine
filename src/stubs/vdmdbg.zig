const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "VDMDBG.dll";
    try environment.addBuiltinExport(m, "VDMTerminateTaskWOW", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "VDMEnumTaskWOWEx", @intFromPtr(&kernel32.stub_args3));
}
