const env = @import("../loader/env.zig");
const stubs = @import("ole32/stubs.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "oleaut32.dll";
    try environment.addBuiltinExportComptime(m, "SysFreeString", stubs.stub_SysFreeString);
    try environment.addBuiltinExportComptime(m, "SysAllocStringLen", stubs.stub_SysAllocStringLen);
}
