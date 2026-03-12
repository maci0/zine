const trace = @import("../../trace.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

/// WS2_32.dll — Winsock 2 (primary implementation on Win2K)

// ============================================================
// Winsock stub implementations (all pub, shared with wsock32)
// ============================================================

pub fn stub_WSAStartup(wVersionRequired: u16, lpWSAData: usize) callconv(w32cc.WINAPI) i32 {
    _ = wVersionRequired;
    if (trace.enable_tracing) trace.print("WS2_32: WSAStartup\n", .{});
    if (lpWSAData != 0) {
        const wsa = @as(*w32.WSADATA, @ptrFromInt(lpWSAData));
        wsa.* = .{};
        wsa.wVersion = 0x0202;
        wsa.wHighVersion = 0x0202;
    }
    return 0; // Success
}

pub fn stub_WSACleanup() callconv(w32cc.WINAPI) i32 {
    return 0;
}

pub fn stub_WSAGetLastError() callconv(w32cc.WINAPI) i32 {
    return 0;
}

pub fn stub_WSASetLastError(iError: i32) callconv(w32cc.WINAPI) void {
    _ = iError;
}

pub fn stub_accept(s: usize, addr: usize, addrlen: usize) callconv(w32cc.WINAPI) usize {
    _ = s; _ = addr; _ = addrlen;
    if (trace.enable_tracing) trace.print("WS2_32: accept\n", .{});
    return @as(usize, @bitCast(@as(isize, -1))); // INVALID_SOCKET
}

pub fn stub_bind(s: usize, name: usize, namelen: i32) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = name; _ = namelen;
    if (trace.enable_tracing) trace.print("WS2_32: bind\n", .{});
    return -1; // SOCKET_ERROR
}

pub fn stub_closesocket(s: usize) callconv(w32cc.WINAPI) i32 {
    _ = s;
    return 0;
}

pub fn stub_connect(s: usize, name: usize, namelen: i32) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = name; _ = namelen;
    if (trace.enable_tracing) trace.print("WS2_32: connect\n", .{});
    return -1;
}

pub fn stub_getpeername(s: usize, name: usize, namelen: usize) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = name; _ = namelen;
    return -1;
}

pub fn stub_getsockname(s: usize, name: usize, namelen: usize) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = name; _ = namelen;
    return -1;
}

pub fn stub_getsockopt(s: usize, level: i32, optname: i32, optval: usize, optlen: usize) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = level; _ = optname; _ = optval; _ = optlen;
    return -1;
}

pub fn stub_htonl(hostlong: u32) callconv(w32cc.WINAPI) u32 {
    return @byteSwap(hostlong);
}

pub fn stub_htons(hostshort: u16) callconv(w32cc.WINAPI) u16 {
    return @byteSwap(hostshort);
}

pub fn stub_ioctlsocket(s: usize, cmd: i32, argp: usize) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = cmd; _ = argp;
    return 0;
}

pub fn stub_inet_addr(cp: usize) callconv(w32cc.WINAPI) u32 {
    _ = cp;
    return 0xFFFFFFFF; // INADDR_NONE
}

var inet_ntoa_buf: [16]u8 = undefined;
pub fn stub_inet_ntoa(in_addr: u32) callconv(w32cc.WINAPI) usize {
    _ = in_addr;
    const result = "0.0.0.0";
    @memcpy(inet_ntoa_buf[0..result.len], result);
    inet_ntoa_buf[result.len] = 0;
    return @intFromPtr(&inet_ntoa_buf);
}

pub fn stub_listen(s: usize, backlog: i32) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = backlog;
    return -1;
}

pub fn stub_ntohl(netlong: u32) callconv(w32cc.WINAPI) u32 {
    return @byteSwap(netlong);
}

pub fn stub_ntohs(netshort: u16) callconv(w32cc.WINAPI) u16 {
    return @byteSwap(netshort);
}

pub fn stub_recv(s: usize, buf: usize, len: i32, flags: i32) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = buf; _ = len; _ = flags;
    return -1;
}

pub fn stub_recvfrom(s: usize, buf: usize, len: i32, flags: i32, from: usize, fromlen: usize) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = buf; _ = len; _ = flags; _ = from; _ = fromlen;
    return -1;
}

pub fn stub_select(nfds: i32, readfds: usize, writefds: usize, exceptfds: usize, timeout: usize) callconv(w32cc.WINAPI) i32 {
    _ = nfds; _ = readfds; _ = writefds; _ = exceptfds; _ = timeout;
    return 0; // No sockets ready
}

pub fn stub_send(s: usize, buf: usize, len: i32, flags: i32) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = buf; _ = flags;
    return len; // Pretend we sent everything
}

pub fn stub_sendto(s: usize, buf: usize, len: i32, flags: i32, to: usize, tolen: i32) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = buf; _ = flags; _ = to; _ = tolen;
    return len;
}

pub fn stub_setsockopt(s: usize, level: i32, optname: i32, optval: usize, optlen: i32) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = level; _ = optname; _ = optval; _ = optlen;
    return 0;
}

pub fn stub_shutdown(s: usize, how: i32) callconv(w32cc.WINAPI) i32 {
    _ = s; _ = how;
    return 0;
}

pub fn stub_socket(af: i32, sock_type: i32, protocol: i32) callconv(w32cc.WINAPI) usize {
    _ = af; _ = sock_type; _ = protocol;
    if (trace.enable_tracing) trace.print("WS2_32: socket\n", .{});
    return @as(usize, @bitCast(@as(isize, -1))); // INVALID_SOCKET
}

pub fn stub_gethostbyname(name: usize) callconv(w32cc.WINAPI) usize {
    _ = name;
    if (trace.enable_tracing) trace.print("WS2_32: gethostbyname\n", .{});
    return 0; // NULL = failure
}

pub fn stub_gethostbyaddr(addr: usize, len: i32, atype: i32) callconv(w32cc.WINAPI) usize {
    _ = addr; _ = len; _ = atype;
    if (trace.enable_tracing) trace.print("WS2_32: gethostbyaddr\n", .{});
    return 0; // NULL = failure
}

pub fn stub_gethostname(name: usize, namelen: i32) callconv(w32cc.WINAPI) i32 {
    if (name != 0 and namelen > 0) {
        const hostname = "localhost";
        const buf = @as([*]u8, @ptrFromInt(name));
        const copy_len = @min(hostname.len, @as(usize, @intCast(namelen)) - 1);
        @memcpy(buf[0..copy_len], hostname[0..copy_len]);
        buf[copy_len] = 0;
    }
    return 0;
}
