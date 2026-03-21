//! SETUPAPI.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stubInvalidHandle4, .{ .name = "SetupDiGetClassDevsA" });
    @export(&stubInvalidHandle4, .{ .name = "SetupDiGetClassDevsW" });
    @export(&stub_ret0_3, .{ .name = "SetupDiEnumDeviceInfo" });
    @export(&stub_ret0_6, .{ .name = "SetupDiGetDeviceRegistryPropertyA" });
    @export(&stub_ret0_6, .{ .name = "SetupDiGetDeviceRegistryPropertyW" });
    @export(&stub_ret0_1, .{ .name = "SetupDiDestroyDeviceInfoList" });
    @export(&stub_ret0_5, .{ .name = "SetupDiEnumDeviceInterfaces" });
    @export(&stub_ret0_6, .{ .name = "SetupDiGetDeviceInterfaceDetailA" });
}

fn stubInvalidHandle4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d };
    return 0xFFFFFFFF;
}
fn stub_ret0_1(a: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    return 0;
}
fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c };
    return 0;
}
fn stub_ret0_5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d, e };
    return 0;
}
fn stub_ret0_6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d, e, f };
    return 0;
}
