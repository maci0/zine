const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32 = @import("win32_constants.zig");

/// WS2_32.dll — Winsock 2 (primary implementation on Win2K)
pub fn register(environment: *env.Environment) !void {
    const dll = "WS2_32.dll";

    // Named exports
    try environment.addBuiltinExport(dll, "accept", @intFromPtr(&stub_accept));
    try environment.addBuiltinExport(dll, "bind", @intFromPtr(&stub_bind));
    try environment.addBuiltinExport(dll, "closesocket", @intFromPtr(&stub_closesocket));
    try environment.addBuiltinExport(dll, "connect", @intFromPtr(&stub_connect));
    try environment.addBuiltinExport(dll, "getpeername", @intFromPtr(&stub_getpeername));
    try environment.addBuiltinExport(dll, "getsockname", @intFromPtr(&stub_getsockname));
    try environment.addBuiltinExport(dll, "getsockopt", @intFromPtr(&stub_getsockopt));
    try environment.addBuiltinExport(dll, "htonl", @intFromPtr(&stub_htonl));
    try environment.addBuiltinExport(dll, "htons", @intFromPtr(&stub_htons));
    try environment.addBuiltinExport(dll, "ioctlsocket", @intFromPtr(&stub_ioctlsocket));
    try environment.addBuiltinExport(dll, "inet_addr", @intFromPtr(&stub_inet_addr));
    try environment.addBuiltinExport(dll, "inet_ntoa", @intFromPtr(&stub_inet_ntoa));
    try environment.addBuiltinExport(dll, "listen", @intFromPtr(&stub_listen));
    try environment.addBuiltinExport(dll, "ntohl", @intFromPtr(&stub_ntohl));
    try environment.addBuiltinExport(dll, "ntohs", @intFromPtr(&stub_ntohs));
    try environment.addBuiltinExport(dll, "recv", @intFromPtr(&stub_recv));
    try environment.addBuiltinExport(dll, "recvfrom", @intFromPtr(&stub_recvfrom));
    try environment.addBuiltinExport(dll, "select", @intFromPtr(&stub_select));
    try environment.addBuiltinExport(dll, "send", @intFromPtr(&stub_send));
    try environment.addBuiltinExport(dll, "sendto", @intFromPtr(&stub_sendto));
    try environment.addBuiltinExport(dll, "setsockopt", @intFromPtr(&stub_setsockopt));
    try environment.addBuiltinExport(dll, "shutdown", @intFromPtr(&stub_shutdown));
    try environment.addBuiltinExport(dll, "socket", @intFromPtr(&stub_socket));
    try environment.addBuiltinExport(dll, "gethostbyaddr", @intFromPtr(&stub_gethostbyaddr));
    try environment.addBuiltinExport(dll, "gethostbyname", @intFromPtr(&stub_gethostbyname));
    try environment.addBuiltinExport(dll, "gethostname", @intFromPtr(&stub_gethostname));
    try environment.addBuiltinExport(dll, "WSAStartup", @intFromPtr(&stub_WSAStartup));
    try environment.addBuiltinExport(dll, "WSACleanup", @intFromPtr(&stub_WSACleanup));
    try environment.addBuiltinExport(dll, "WSAGetLastError", @intFromPtr(&stub_WSAGetLastError));
    try environment.addBuiltinExport(dll, "WSASetLastError", @intFromPtr(&stub_WSASetLastError));

    // Ordinal exports (canonical Winsock ordinal table)
    try environment.addBuiltinExport(dll, "ordinal_1", @intFromPtr(&stub_accept));
    try environment.addBuiltinExport(dll, "ordinal_2", @intFromPtr(&stub_bind));
    try environment.addBuiltinExport(dll, "ordinal_3", @intFromPtr(&stub_closesocket));
    try environment.addBuiltinExport(dll, "ordinal_4", @intFromPtr(&stub_connect));
    try environment.addBuiltinExport(dll, "ordinal_5", @intFromPtr(&stub_getpeername));
    try environment.addBuiltinExport(dll, "ordinal_6", @intFromPtr(&stub_getsockname));
    try environment.addBuiltinExport(dll, "ordinal_7", @intFromPtr(&stub_getsockopt));
    try environment.addBuiltinExport(dll, "ordinal_8", @intFromPtr(&stub_htonl));
    try environment.addBuiltinExport(dll, "ordinal_9", @intFromPtr(&stub_htons));
    try environment.addBuiltinExport(dll, "ordinal_10", @intFromPtr(&stub_ioctlsocket));
    try environment.addBuiltinExport(dll, "ordinal_11", @intFromPtr(&stub_inet_addr));
    try environment.addBuiltinExport(dll, "ordinal_12", @intFromPtr(&stub_inet_ntoa));
    try environment.addBuiltinExport(dll, "ordinal_13", @intFromPtr(&stub_listen));
    try environment.addBuiltinExport(dll, "ordinal_14", @intFromPtr(&stub_ntohl));
    try environment.addBuiltinExport(dll, "ordinal_15", @intFromPtr(&stub_ntohs));
    try environment.addBuiltinExport(dll, "ordinal_16", @intFromPtr(&stub_recv));
    try environment.addBuiltinExport(dll, "ordinal_17", @intFromPtr(&stub_recvfrom));
    try environment.addBuiltinExport(dll, "ordinal_18", @intFromPtr(&stub_select));
    try environment.addBuiltinExport(dll, "ordinal_19", @intFromPtr(&stub_send));
    try environment.addBuiltinExport(dll, "ordinal_20", @intFromPtr(&stub_sendto));
    try environment.addBuiltinExport(dll, "ordinal_21", @intFromPtr(&stub_setsockopt));
    try environment.addBuiltinExport(dll, "ordinal_22", @intFromPtr(&stub_shutdown));
    try environment.addBuiltinExport(dll, "ordinal_23", @intFromPtr(&stub_socket));
    try environment.addBuiltinExport(dll, "ordinal_51", @intFromPtr(&stub_gethostbyaddr));
    try environment.addBuiltinExport(dll, "ordinal_52", @intFromPtr(&stub_gethostbyname));
    try environment.addBuiltinExport(dll, "ordinal_57", @intFromPtr(&stub_gethostname));
    try environment.addBuiltinExport(dll, "ordinal_115", @intFromPtr(&stub_WSAStartup));
    try environment.addBuiltinExport(dll, "ordinal_116", @intFromPtr(&stub_WSACleanup));
}

// ============================================================
// Winsock stub implementations (all pub, shared with wsock32)
// ============================================================

pub fn stub_WSAStartup(wVersionRequired: u16, lpWSAData: usize) callconv(.winapi) i32 {
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

pub fn stub_WSACleanup() callconv(.winapi) i32 {
    return 0;
}

pub fn stub_WSAGetLastError() callconv(.winapi) i32 {
    return 0;
}

pub fn stub_WSASetLastError(iError: i32) callconv(.winapi) void {
    _ = iError;
}

pub fn stub_accept(s: usize, addr: usize, addrlen: usize) callconv(.winapi) usize {
    _ = s; _ = addr; _ = addrlen;
    if (trace.enable_tracing) trace.print("WS2_32: accept\n", .{});
    return @as(usize, @bitCast(@as(isize, -1))); // INVALID_SOCKET
}

pub fn stub_bind(s: usize, name: usize, namelen: i32) callconv(.winapi) i32 {
    _ = s; _ = name; _ = namelen;
    if (trace.enable_tracing) trace.print("WS2_32: bind\n", .{});
    return -1; // SOCKET_ERROR
}

pub fn stub_closesocket(s: usize) callconv(.winapi) i32 {
    _ = s;
    return 0;
}

pub fn stub_connect(s: usize, name: usize, namelen: i32) callconv(.winapi) i32 {
    _ = s; _ = name; _ = namelen;
    if (trace.enable_tracing) trace.print("WS2_32: connect\n", .{});
    return -1;
}

pub fn stub_getpeername(s: usize, name: usize, namelen: usize) callconv(.winapi) i32 {
    _ = s; _ = name; _ = namelen;
    return -1;
}

pub fn stub_getsockname(s: usize, name: usize, namelen: usize) callconv(.winapi) i32 {
    _ = s; _ = name; _ = namelen;
    return -1;
}

pub fn stub_getsockopt(s: usize, level: i32, optname: i32, optval: usize, optlen: usize) callconv(.winapi) i32 {
    _ = s; _ = level; _ = optname; _ = optval; _ = optlen;
    return -1;
}

pub fn stub_htonl(hostlong: u32) callconv(.winapi) u32 {
    return @byteSwap(hostlong);
}

pub fn stub_htons(hostshort: u16) callconv(.winapi) u16 {
    return @byteSwap(hostshort);
}

pub fn stub_ioctlsocket(s: usize, cmd: i32, argp: usize) callconv(.winapi) i32 {
    _ = s; _ = cmd; _ = argp;
    return 0;
}

pub fn stub_inet_addr(cp: usize) callconv(.winapi) u32 {
    _ = cp;
    return 0xFFFFFFFF; // INADDR_NONE
}

var inet_ntoa_buf: [16]u8 = undefined;
pub fn stub_inet_ntoa(in_addr: u32) callconv(.winapi) usize {
    _ = in_addr;
    const result = "0.0.0.0";
    @memcpy(inet_ntoa_buf[0..result.len], result);
    inet_ntoa_buf[result.len] = 0;
    return @intFromPtr(&inet_ntoa_buf);
}

pub fn stub_listen(s: usize, backlog: i32) callconv(.winapi) i32 {
    _ = s; _ = backlog;
    return -1;
}

pub fn stub_ntohl(netlong: u32) callconv(.winapi) u32 {
    return @byteSwap(netlong);
}

pub fn stub_ntohs(netshort: u16) callconv(.winapi) u16 {
    return @byteSwap(netshort);
}

pub fn stub_recv(s: usize, buf: usize, len: i32, flags: i32) callconv(.winapi) i32 {
    _ = s; _ = buf; _ = len; _ = flags;
    return -1;
}

pub fn stub_recvfrom(s: usize, buf: usize, len: i32, flags: i32, from: usize, fromlen: usize) callconv(.winapi) i32 {
    _ = s; _ = buf; _ = len; _ = flags; _ = from; _ = fromlen;
    return -1;
}

pub fn stub_select(nfds: i32, readfds: usize, writefds: usize, exceptfds: usize, timeout: usize) callconv(.winapi) i32 {
    _ = nfds; _ = readfds; _ = writefds; _ = exceptfds; _ = timeout;
    return 0; // No sockets ready
}

pub fn stub_send(s: usize, buf: usize, len: i32, flags: i32) callconv(.winapi) i32 {
    _ = s; _ = buf; _ = flags;
    return len; // Pretend we sent everything
}

pub fn stub_sendto(s: usize, buf: usize, len: i32, flags: i32, to: usize, tolen: i32) callconv(.winapi) i32 {
    _ = s; _ = buf; _ = flags; _ = to; _ = tolen;
    return len;
}

pub fn stub_setsockopt(s: usize, level: i32, optname: i32, optval: usize, optlen: i32) callconv(.winapi) i32 {
    _ = s; _ = level; _ = optname; _ = optval; _ = optlen;
    return 0;
}

pub fn stub_shutdown(s: usize, how: i32) callconv(.winapi) i32 {
    _ = s; _ = how;
    return 0;
}

pub fn stub_socket(af: i32, sock_type: i32, protocol: i32) callconv(.winapi) usize {
    _ = af; _ = sock_type; _ = protocol;
    if (trace.enable_tracing) trace.print("WS2_32: socket\n", .{});
    return @as(usize, @bitCast(@as(isize, -1))); // INVALID_SOCKET
}

pub fn stub_gethostbyname(name: usize) callconv(.winapi) usize {
    _ = name;
    if (trace.enable_tracing) trace.print("WS2_32: gethostbyname\n", .{});
    return 0; // NULL = failure
}

pub fn stub_gethostbyaddr(addr: usize, len: i32, atype: i32) callconv(.winapi) usize {
    _ = addr; _ = len; _ = atype;
    if (trace.enable_tracing) trace.print("WS2_32: gethostbyaddr\n", .{});
    return 0; // NULL = failure
}

pub fn stub_gethostname(name: usize, namelen: i32) callconv(.winapi) i32 {
    if (name != 0 and namelen > 0) {
        const hostname = "localhost";
        const buf = @as([*]u8, @ptrFromInt(name));
        const copy_len = @min(hostname.len, @as(usize, @intCast(namelen)) - 1);
        @memcpy(buf[0..copy_len], hostname[0..copy_len]);
        buf[copy_len] = 0;
    }
    return 0;
}
