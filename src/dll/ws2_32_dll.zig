//! WS2_32.dll export definitions
//! Standalone stubs using Windows Winsock2 types directly.

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&WSAStartup, .{ .name = "WSAStartup" });
    @export(&WSACleanup, .{ .name = "WSACleanup" });
    @export(&stub_WSAGetLastError, .{ .name = "WSAGetLastError" });
    @export(&stub_WSASetLastError, .{ .name = "WSASetLastError" });
    @export(&stub3_socket, .{ .name = "socket" });
    @export(&stub3_ret, .{ .name = "bind" });
    @export(&stub2_ret, .{ .name = "listen" });
    @export(&stub3_ret_usize, .{ .name = "accept" });
    @export(&stub3_ret, .{ .name = "connect" });
    @export(&stub4_ret, .{ .name = "send" });
    @export(&stub6_ret, .{ .name = "sendto" });
    @export(&stub4_ret, .{ .name = "recv" });
    @export(&stub6_ret_usize, .{ .name = "recvfrom" });
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
    @export(&inet_addr, .{ .name = "inet_addr" });
    @export(&stub1_ret_usize, .{ .name = "inet_ntoa" });
    @export(&stub1_ret_usize, .{ .name = "gethostbyname" });
    @export(&stub3_ret_usize, .{ .name = "gethostbyaddr" });
    @export(&stub2_ret, .{ .name = "gethostname" });
}

const INVALID_SOCKET: usize = ~@as(usize, 0);
const SOCKET_ERROR: i32 = -1;

pub fn WSAStartup(wVersionRequired: u16, lpWSAData: usize) callconv(w32cc.WINAPI) i32 {
    _ = wVersionRequired;
    if (lpWSAData != 0) {
        const data = @as([*]u8, @ptrFromInt(lpWSAData));
        @memset(data[0..400], 0);
        data[0] = 2;
        data[1] = 2; // wVersion = 2.2
        data[2] = 2;
        data[3] = 2; // wHighVersion = 2.2
    }
    return 0;
}
pub fn WSACleanup() callconv(w32cc.WINAPI) i32 {
    return 0;
}
pub fn stub_WSAGetLastError() callconv(w32cc.WINAPI) i32 {
    return 0;
}
pub fn stub_WSASetLastError(iError: i32) callconv(w32cc.WINAPI) void {
    _ = iError;
}

pub fn stub1_ret(a: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    return SOCKET_ERROR;
}
pub fn stub1_ret_usize(a: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    return 0;
}
pub fn stub2_ret(a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b };
    return SOCKET_ERROR;
}
pub fn stub3_ret(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c };
    return SOCKET_ERROR;
}
pub fn stub3_ret_usize(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c };
    return INVALID_SOCKET;
}
pub fn stub3_socket(af: i32, sock_type: i32, protocol: i32) callconv(w32cc.WINAPI) usize {
    _ = .{ af, sock_type, protocol };
    return INVALID_SOCKET;
}
pub fn stub4_ret(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d };
    return SOCKET_ERROR;
}
pub fn stub5_ret(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d, e };
    return SOCKET_ERROR;
}
pub fn stub6_ret(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d, e, f };
    return SOCKET_ERROR;
}
pub fn stub6_ret_usize(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f };
    return 0;
}

pub fn htonl(hostlong: u32) callconv(w32cc.WINAPI) u32 {
    return @byteSwap(hostlong);
}
pub fn htons(hostshort: u16) callconv(w32cc.WINAPI) u16 {
    return @byteSwap(hostshort);
}
pub fn ntohl(netlong: u32) callconv(w32cc.WINAPI) u32 {
    return @byteSwap(netlong);
}
pub fn ntohs(netshort: u16) callconv(w32cc.WINAPI) u16 {
    return @byteSwap(netshort);
}

pub fn inet_addr(cp: usize) callconv(w32cc.WINAPI) u32 {
    if (cp == 0) return 0xFFFFFFFF; // INADDR_NONE
    const str = @as([*:0]const u8, @ptrFromInt(cp));
    var result: u32 = 0;
    var octet: u32 = 0;
    var dots: u32 = 0;
    var i: usize = 0;
    while (str[i] != 0) : (i += 1) {
        if (str[i] == '.') {
            if (dots >= 3 or octet > 255) return 0xFFFFFFFF;
            result |= octet << @intCast(dots * 8);
            octet = 0;
            dots += 1;
        } else if (str[i] >= '0' and str[i] <= '9') {
            octet = octet * 10 + (str[i] - '0');
        } else return 0xFFFFFFFF;
    }
    if (dots != 3 or octet > 255) return 0xFFFFFFFF;
    result |= octet << 24;
    return result;
}
