//! MAG_HOOK.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub1, .{ .name = "_InstallEventHook@4" });
    @export(&stub2, .{ .name = "_FakeCursorMove@8" });
    @export(&stub2, .{ .name = "_SetZoomRect@8" });
}

fn stub1(a: usize) callconv(w32cc.WINAPI) usize { _ = a; return 0; }
fn stub2(a: usize, b: usize) callconv(w32cc.WINAPI) usize { _ = .{ a, b }; return 0; }
