//! SETUPAPI.dll registration.

const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

/// Registers SETUPAPI.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "setupapi.dll";
    // SetupDiGetClassDevsA(ClassGuid, Enumerator, hwndParent, Flags) → HDEVINFO
    // Return INVALID_HANDLE_VALUE (-1) = no devices found
    try environment.addBuiltinExportComptime(m, "SetupDiGetClassDevsA", &stubInvalidHandle4);
    try environment.addBuiltinExportComptime(m, "SetupDiGetClassDevsW", &stubInvalidHandle4);
    try environment.addBuiltinExportComptime(m, "SetupDiEnumDeviceInfo", &kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "SetupDiGetDeviceRegistryPropertyA", &kernel32.stub_args7);
    try environment.addBuiltinExportComptime(m, "SetupDiGetDeviceRegistryPropertyW", &kernel32.stub_args7);
    try environment.addBuiltinExportComptime(m, "SetupDiDestroyDeviceInfoList", &kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "SetupDiEnumDeviceInterfaces", &kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "SetupDiGetDeviceInterfaceDetailA", &kernel32.stub_args6);
}

const w32cc = @import("calling_convention.zig");
fn stubInvalidHandle4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d };
    return 0xFFFFFFFF; // INVALID_HANDLE_VALUE
}
