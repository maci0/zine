const env = @import("../loader/env.zig");
const stubs = @import("ole32/com.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "oleaut32.dll";
    const stub = @import("stub_common.zig");
    try environment.addBuiltinExportComptime(m, "SysFreeString", stubs.stub_SysFreeString);
    try environment.addBuiltinExportComptime(m, "SysAllocStringLen", stubs.stub_SysAllocStringLen);

    // --- hgb.exe oleaut32 stubs ---
    try environment.addBuiltinExportComptime(m, "VariantChangeTypeEx", stub.stub_args5);
    try environment.addBuiltinExportComptime(m, "VariantCopyInd", stub.stub_args2);
    try environment.addBuiltinExportComptime(m, "VariantClear", stub.stub_args1);
    try environment.addBuiltinExportComptime(m, "SysStringLen", stub.stub_args1);
}
