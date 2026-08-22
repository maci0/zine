//! VDMDBG.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub2, .{ .name = "VDMTerminateTaskWOW" });
    @export(&stub3, .{ .name = "VDMEnumTaskWOWEx" });
}

fn stub2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b };
    return 0;
}
fn stub3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c };
    return 0;
}
