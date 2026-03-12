const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32 = @import("../win32_constants.zig");
const w32cc = @import("../calling_convention.zig");

/// WS2_32.dll — Winsock 2 (primary implementation on Win2K)
pub fn register(environment: *env.Environment) !void {
    const dll = "WS2_32.dll";

    // Named exports
    try environment.addBuiltinExportComptime(dll, "accept", stub_accept);
    try environment.addBuiltinExportComptime(dll, "bind", stub_bind);
    try environment.addBuiltinExportComptime(dll, "closesocket", stub_closesocket);
    try environment.addBuiltinExportComptime(dll, "connect", stub_connect);
    try environment.addBuiltinExportComptime(dll, "getpeername", stub_getpeername);
    try environment.addBuiltinExportComptime(dll, "getsockname", stub_getsockname);
    try environment.addBuiltinExportComptime(dll, "getsockopt", stub_getsockopt);
    try environment.addBuiltinExportComptime(dll, "htonl", stub_htonl);
    try environment.addBuiltinExportComptime(dll, "htons", stub_htons);
    try environment.addBuiltinExportComptime(dll, "ioctlsocket", stub_ioctlsocket);
    try environment.addBuiltinExportComptime(dll, "inet_addr", stub_inet_addr);
    try environment.addBuiltinExportComptime(dll, "inet_ntoa", stub_inet_ntoa);
    try environment.addBuiltinExportComptime(dll, "listen", stub_listen);
    try environment.addBuiltinExportComptime(dll, "ntohl", stub_ntohl);
    try environment.addBuiltinExportComptime(dll, "ntohs", stub_ntohs);
    try environment.addBuiltinExportComptime(dll, "recv", stub_recv);
    try environment.addBuiltinExportComptime(dll, "recvfrom", stub_recvfrom);
    try environment.addBuiltinExportComptime(dll, "select", stub_select);
    try environment.addBuiltinExportComptime(dll, "send", stub_send);
    try environment.addBuiltinExportComptime(dll, "sendto", stub_sendto);
    try environment.addBuiltinExportComptime(dll, "setsockopt", stub_setsockopt);
    try environment.addBuiltinExportComptime(dll, "shutdown", stub_shutdown);
    try environment.addBuiltinExportComptime(dll, "socket", stub_socket);
    try environment.addBuiltinExportComptime(dll, "gethostbyaddr", stub_gethostbyaddr);
    try environment.addBuiltinExportComptime(dll, "gethostbyname", stub_gethostbyname);
    try environment.addBuiltinExportComptime(dll, "gethostname", stub_gethostname);
    try environment.addBuiltinExportComptime(dll, "WSAStartup", stub_WSAStartup);
    try environment.addBuiltinExportComptime(dll, "WSACleanup", stub_WSACleanup);
    try environment.addBuiltinExportComptime(dll, "WSAGetLastError", stub_WSAGetLastError);
    try environment.addBuiltinExportComptime(dll, "WSASetLastError", stub_WSASetLastError);

    // Ordinal exports (canonical Winsock ordinal table)
    try environment.addBuiltinExportComptime(dll, "ordinal_1", stub_accept);
    try environment.addBuiltinExportComptime(dll, "ordinal_2", stub_bind);
    try environment.addBuiltinExportComptime(dll, "ordinal_3", stub_closesocket);
    try environment.addBuiltinExportComptime(dll, "ordinal_4", stub_connect);
    try environment.addBuiltinExportComptime(dll, "ordinal_5", stub_getpeername);
    try environment.addBuiltinExportComptime(dll, "ordinal_6", stub_getsockname);
    try environment.addBuiltinExportComptime(dll, "ordinal_7", stub_getsockopt);
    try environment.addBuiltinExportComptime(dll, "ordinal_8", stub_htonl);
    try environment.addBuiltinExportComptime(dll, "ordinal_9", stub_htons);
    try environment.addBuiltinExportComptime(dll, "ordinal_10", stub_ioctlsocket);
    try environment.addBuiltinExportComptime(dll, "ordinal_11", stub_inet_addr);
    try environment.addBuiltinExportComptime(dll, "ordinal_12", stub_inet_ntoa);
    try environment.addBuiltinExportComptime(dll, "ordinal_13", stub_listen);
    try environment.addBuiltinExportComptime(dll, "ordinal_14", stub_ntohl);
    try environment.addBuiltinExportComptime(dll, "ordinal_15", stub_ntohs);
    try environment.addBuiltinExportComptime(dll, "ordinal_16", stub_recv);
    try environment.addBuiltinExportComptime(dll, "ordinal_17", stub_recvfrom);
    try environment.addBuiltinExportComptime(dll, "ordinal_18", stub_select);
    try environment.addBuiltinExportComptime(dll, "ordinal_19", stub_send);
    try environment.addBuiltinExportComptime(dll, "ordinal_20", stub_sendto);
    try environment.addBuiltinExportComptime(dll, "ordinal_21", stub_setsockopt);
    try environment.addBuiltinExportComptime(dll, "ordinal_22", stub_shutdown);
    try environment.addBuiltinExportComptime(dll, "ordinal_23", stub_socket);
    try environment.addBuiltinExportComptime(dll, "ordinal_51", stub_gethostbyaddr);
    try environment.addBuiltinExportComptime(dll, "ordinal_52", stub_gethostbyname);
    try environment.addBuiltinExportComptime(dll, "ordinal_57", stub_gethostname);
    try environment.addBuiltinExportComptime(dll, "ordinal_115", stub_WSAStartup);
    try environment.addBuiltinExportComptime(dll, "ordinal_116", stub_WSACleanup);
}

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
