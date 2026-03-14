const env = @import("../loader/env.zig");
const stubs = @import("dinput/dinput.zig");

pub fn register(environment: *env.Environment) !void {
    stubs.initVtables();

    try environment.addBuiltinExportComptime("DINPUT8.dll", "DirectInput8Create", stubs.stub_DirectInput8Create);

    environment.addBuiltinVtableComptime(stubs.IDirectInputVtbl, &stubs.dinput_vtbl);
    environment.addBuiltinVtableComptime(stubs.IDirectInputDeviceVtbl, &stubs.device_vtbl);
}
