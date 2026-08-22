//! CARDS.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub0, .{ .name = "cdtTerm" });
    @export(&stub2, .{ .name = "cdtInit" });
    @export(&stub4, .{ .name = "cdtAnimate" });
    @export(&stub6, .{ .name = "cdtDraw" });
    @export(&stub8, .{ .name = "cdtDrawExt" });
}

fn stub0() callconv(w32cc.WINAPI) usize {
    return 0;
}
fn stub2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b };
    return 0;
}
fn stub4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d };
    return 0;
}
fn stub6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f };
    return 0;
}
fn stub8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f, g, h };
    return 0;
}
