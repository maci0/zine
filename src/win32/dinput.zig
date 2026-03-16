//! DINPUT.dll registration.

const env = @import("../loader/env.zig");
const stubs = @import("dinput/dinput.zig");

/// Registers DINPUT.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    stubs.initVtables();

    const builtin_module = "DINPUT.dll";
    try environment.addBuiltinExportComptime(builtin_module, "DirectInputCreateA", stubs.stub_DirectInputCreateA);

    environment.addBuiltinVtableComptime(stubs.IDirectInputVtbl, &stubs.dinput_vtbl);
    environment.addBuiltinVtableComptime(stubs.IDirectInputDeviceVtbl, &stubs.device_vtbl);
}
