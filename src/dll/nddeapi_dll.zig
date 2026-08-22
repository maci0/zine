//! NDDEAPI.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub3, .{ .name = "NDdeShareAddW" });
    @export(&stub2, .{ .name = "NDdeShareDelW" });
    @export(&stub5, .{ .name = "NDdeShareGetInfoW" });
    @export(&stub4, .{ .name = "NDdeShareSetInfoW" });
    @export(&stub4, .{ .name = "NDdeShareEnumW" });
    @export(&stub4, .{ .name = "NDdeGetShareSecurityW" });
    @export(&stub4, .{ .name = "NDdeSetShareSecurityW" });
    @export(&stub3, .{ .name = "NDdeSetTrustedShareW" });
    @export(&stub4, .{ .name = "NDdeGetTrustedShareW" });
    @export(&stub3, .{ .name = "NDdeGetErrorStringW" });
    @export(&stub1, .{ .name = "NDdeIsValidShareNameW" });
    @export(&stub1, .{ .name = "NDdeIsValidAppTopicListW" });
    @export(&stub4, .{ .name = "NDdeTrustedShareEnumW" });
}

fn stub1(a: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    return 0;
}
fn stub2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b };
    return 0;
}
fn stub3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c };
    return 0;
}
fn stub4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d };
    return 0;
}
fn stub5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e };
    return 0;
}
