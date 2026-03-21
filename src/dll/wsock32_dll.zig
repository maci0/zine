//! WSOCK32.dll export definitions
//! WSOCK32 is a thin wrapper around WS2_32 — identical stubs.

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&WSAStartup, .{ .name = "WSAStartup" });
    @export(&WSACleanup, .{ .name = "WSACleanup" });
    @export(&stub0, .{ .name = "WSAGetLastError" });
    @export(&stub1_void, .{ .name = "WSASetLastError" });
    @export(&stub3_socket, .{ .name = "socket" });
    @export(&stub3_ret, .{ .name = "bind" });
    @export(&stub2_ret, .{ .name = "listen" });
    @export(&stub3_usize, .{ .name = "accept" });
    @export(&stub3_ret, .{ .name = "connect" });
    @export(&stub4_ret, .{ .name = "send" });
    @export(&stub6_ret, .{ .name = "sendto" });
    @export(&stub4_ret, .{ .name = "recv" });
    @export(&stub6_usize, .{ .name = "recvfrom" });
    @export(&stub1_ret, .{ .name = "closesocket" });
    @export(&stub2_ret, .{ .name = "shutdown" });
    @export(&stub5_ret, .{ .name = "select" });
    @export(&stub5_ret, .{ .name = "setsockopt" });
    @export(&stub5_ret, .{ .name = "getsockopt" });
    @export(&stub3_ret, .{ .name = "ioctlsocket" });
    @export(&stub3_ret, .{ .name = "getpeername" });
    @export(&stub3_ret, .{ .name = "getsockname" });
    @export(&htonl, .{ .name = "htonl" });
    @export(&htons, .{ .name = "htons" });
    @export(&ntohl, .{ .name = "ntohl" });
    @export(&ntohs, .{ .name = "ntohs" });
    @export(&stub1_usize, .{ .name = "inet_addr" });
    @export(&stub1_usize, .{ .name = "inet_ntoa" });
    @export(&stub1_usize, .{ .name = "gethostbyname" });
    @export(&stub3_usize, .{ .name = "gethostbyaddr" });
    @export(&stub2_ret, .{ .name = "gethostname" });
}

fn WSAStartup(wVersionRequired: u16, lpWSAData: usize) callconv(w32cc.WINAPI) i32 {
    _ = wVersionRequired;
    if (lpWSAData != 0) {
        const data = @as([*]u8, @ptrFromInt(lpWSAData));
        @memset(data[0..400], 0);
        data[0] = 2; data[1] = 2;
        data[2] = 2; data[3] = 2;
    }
    return 0;
}
fn WSACleanup() callconv(w32cc.WINAPI) i32 { return 0; }
fn stub0() callconv(w32cc.WINAPI) i32 { return 0; }
fn stub1_void(a: usize) callconv(w32cc.WINAPI) void { _ = a; }
fn stub1_ret(a: usize) callconv(w32cc.WINAPI) i32 { _ = a; return -1; }
fn stub1_usize(a: usize) callconv(w32cc.WINAPI) usize { _ = a; return 0; }
fn stub2_ret(a: usize, b: usize) callconv(w32cc.WINAPI) i32 { _ = .{ a, b }; return -1; }
fn stub3_ret(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 { _ = .{ a, b, c }; return -1; }
fn stub3_usize(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize { _ = .{ a, b, c }; return ~@as(usize, 0); }
fn stub3_socket(af: i32, sock_type: i32, protocol: i32) callconv(w32cc.WINAPI) usize { _ = .{ af, sock_type, protocol }; return ~@as(usize, 0); }
fn stub4_ret(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) i32 { _ = .{ a, b, c, d }; return -1; }
fn stub5_ret(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) i32 { _ = .{ a, b, c, d, e }; return -1; }
fn stub6_ret(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) i32 { _ = .{ a, b, c, d, e, f }; return -1; }
fn stub6_usize(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize { _ = .{ a, b, c, d, e, f }; return 0; }
fn htonl(hostlong: u32) callconv(w32cc.WINAPI) u32 { return @byteSwap(hostlong); }
fn htons(hostshort: u16) callconv(w32cc.WINAPI) u16 { return @byteSwap(hostshort); }
fn ntohl(netlong: u32) callconv(w32cc.WINAPI) u32 { return @byteSwap(netlong); }
fn ntohs(netshort: u16) callconv(w32cc.WINAPI) u16 { return @byteSwap(netshort); }
