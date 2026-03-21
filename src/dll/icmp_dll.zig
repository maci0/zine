//! ICMP.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub0, .{ .name = "IcmpCreateFile" });
    @export(&stub1, .{ .name = "IcmpCloseHandle" });
    @export(&stub8, .{ .name = "IcmpSendEcho2" });
}

fn stub0() callconv(w32cc.WINAPI) usize { return 0; }
fn stub1(a: usize) callconv(w32cc.WINAPI) usize { _ = a; return 0; }
fn stub8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize { _ = .{ a, b, c, d, e, f, g, h }; return 0; }
