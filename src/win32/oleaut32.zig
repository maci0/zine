//! OLEAUT32.dll registration.

const env = @import("../loader/env.zig");
const ordinals = @import("ordinals.zig");
const stubs = @import("ole32/com.zig");

/// Registers OLEAUT32.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "oleaut32.dll";
    const stub = @import("shared.zig");
    try environment.addBuiltinExportComptime(m, "SysFreeString", stubs.SysFreeString);
    try environment.addBuiltinExportComptime(m, "SysAllocStringLen", stubs.SysAllocStringLen);
    try environment.addBuiltinExportComptime(m, "SysAllocString", stubs.SysAllocString);
    try environment.addBuiltinExportComptime(m, "SysStringLen", stubs.SysStringLen);
    try environment.addBuiltinExportComptime(m, "SysStringByteLen", stubs.SysStringByteLen);
    try environment.addBuiltinExportComptime(m, "VariantClear", stubs.VariantClear);
    try environment.addBuiltinExportComptime(m, "VariantInit", stubs.VariantInit);

    // --- hgb.exe oleaut32 stubs ---
    try environment.addBuiltinExportComptime(m, "VariantChangeTypeEx", stub.stub_args5);
    try environment.addBuiltinExportComptime(m, "VariantCopyInd", stub.stub_args2);

    // Ordinal exports
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.SysAllocString, stubs.SysAllocString);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.SysFreeString, stubs.SysFreeString);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.SysAllocStringByteLen, stub.stub_args1);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.SysAllocStringLen, stubs.SysAllocStringLen);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.SysStringLen, stubs.SysStringLen);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.SysStringByteLen, stubs.SysStringByteLen);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.VariantInit, stubs.VariantInit);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.VariantClear, stubs.VariantClear);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.VariantChangeType, stub.stub_args2);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.VariantCopy, stub.stub_args3);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.VariantCopyInd, stub.stub_args2);
    try environment.addBuiltinExportComptime(m, ordinals.OLEAUT32.SafeArrayGetElement, stub.stub_args3);
}
