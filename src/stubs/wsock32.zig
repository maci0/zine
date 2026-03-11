const env = @import("../loader/env.zig");

/// WSOCK32.dll — Winsock 1.1 (thin forwarder to WS2_32.dll on Win2K)
pub fn register(environment: *env.Environment) !void {
    const dll = "WSOCK32.dll";

    // Import all implementations from WS2_32 (the real implementation)
    const ws2 = @import("ws2_32.zig");

    // Named exports — WSOCK32.dll exports the full BSD socket API by name
    try environment.addBuiltinExport(dll, "accept", @intFromPtr(&ws2.stub_accept));
    try environment.addBuiltinExport(dll, "bind", @intFromPtr(&ws2.stub_bind));
    try environment.addBuiltinExport(dll, "closesocket", @intFromPtr(&ws2.stub_closesocket));
    try environment.addBuiltinExport(dll, "connect", @intFromPtr(&ws2.stub_connect));
    try environment.addBuiltinExport(dll, "getpeername", @intFromPtr(&ws2.stub_getpeername));
    try environment.addBuiltinExport(dll, "getsockname", @intFromPtr(&ws2.stub_getsockname));
    try environment.addBuiltinExport(dll, "getsockopt", @intFromPtr(&ws2.stub_getsockopt));
    try environment.addBuiltinExport(dll, "htonl", @intFromPtr(&ws2.stub_htonl));
    try environment.addBuiltinExport(dll, "htons", @intFromPtr(&ws2.stub_htons));
    try environment.addBuiltinExport(dll, "ioctlsocket", @intFromPtr(&ws2.stub_ioctlsocket));
    try environment.addBuiltinExport(dll, "inet_addr", @intFromPtr(&ws2.stub_inet_addr));
    try environment.addBuiltinExport(dll, "inet_ntoa", @intFromPtr(&ws2.stub_inet_ntoa));
    try environment.addBuiltinExport(dll, "listen", @intFromPtr(&ws2.stub_listen));
    try environment.addBuiltinExport(dll, "ntohl", @intFromPtr(&ws2.stub_ntohl));
    try environment.addBuiltinExport(dll, "ntohs", @intFromPtr(&ws2.stub_ntohs));
    try environment.addBuiltinExport(dll, "recv", @intFromPtr(&ws2.stub_recv));
    try environment.addBuiltinExport(dll, "recvfrom", @intFromPtr(&ws2.stub_recvfrom));
    try environment.addBuiltinExport(dll, "select", @intFromPtr(&ws2.stub_select));
    try environment.addBuiltinExport(dll, "send", @intFromPtr(&ws2.stub_send));
    try environment.addBuiltinExport(dll, "sendto", @intFromPtr(&ws2.stub_sendto));
    try environment.addBuiltinExport(dll, "setsockopt", @intFromPtr(&ws2.stub_setsockopt));
    try environment.addBuiltinExport(dll, "shutdown", @intFromPtr(&ws2.stub_shutdown));
    try environment.addBuiltinExport(dll, "socket", @intFromPtr(&ws2.stub_socket));
    try environment.addBuiltinExport(dll, "gethostbyaddr", @intFromPtr(&ws2.stub_gethostbyaddr));
    try environment.addBuiltinExport(dll, "gethostbyname", @intFromPtr(&ws2.stub_gethostbyname));
    try environment.addBuiltinExport(dll, "gethostname", @intFromPtr(&ws2.stub_gethostname));
    try environment.addBuiltinExport(dll, "WSAStartup", @intFromPtr(&ws2.stub_WSAStartup));
    try environment.addBuiltinExport(dll, "WSACleanup", @intFromPtr(&ws2.stub_WSACleanup));
    try environment.addBuiltinExport(dll, "WSAGetLastError", @intFromPtr(&ws2.stub_WSAGetLastError));
    try environment.addBuiltinExport(dll, "WSASetLastError", @intFromPtr(&ws2.stub_WSASetLastError));

    // WSOCK32 ordinals (same canonical table as WS2_32)
    try environment.addBuiltinExport(dll, "ordinal_1", @intFromPtr(&ws2.stub_accept));
    try environment.addBuiltinExport(dll, "ordinal_2", @intFromPtr(&ws2.stub_bind));
    try environment.addBuiltinExport(dll, "ordinal_3", @intFromPtr(&ws2.stub_closesocket));
    try environment.addBuiltinExport(dll, "ordinal_4", @intFromPtr(&ws2.stub_connect));
    try environment.addBuiltinExport(dll, "ordinal_5", @intFromPtr(&ws2.stub_getpeername));
    try environment.addBuiltinExport(dll, "ordinal_6", @intFromPtr(&ws2.stub_getsockname));
    try environment.addBuiltinExport(dll, "ordinal_7", @intFromPtr(&ws2.stub_getsockopt));
    try environment.addBuiltinExport(dll, "ordinal_8", @intFromPtr(&ws2.stub_htonl));
    try environment.addBuiltinExport(dll, "ordinal_9", @intFromPtr(&ws2.stub_htons));
    try environment.addBuiltinExport(dll, "ordinal_10", @intFromPtr(&ws2.stub_ioctlsocket));
    try environment.addBuiltinExport(dll, "ordinal_11", @intFromPtr(&ws2.stub_inet_addr));
    try environment.addBuiltinExport(dll, "ordinal_12", @intFromPtr(&ws2.stub_inet_ntoa));
    try environment.addBuiltinExport(dll, "ordinal_13", @intFromPtr(&ws2.stub_listen));
    try environment.addBuiltinExport(dll, "ordinal_14", @intFromPtr(&ws2.stub_ntohl));
    try environment.addBuiltinExport(dll, "ordinal_15", @intFromPtr(&ws2.stub_ntohs));
    try environment.addBuiltinExport(dll, "ordinal_16", @intFromPtr(&ws2.stub_recv));
    try environment.addBuiltinExport(dll, "ordinal_17", @intFromPtr(&ws2.stub_recvfrom));
    try environment.addBuiltinExport(dll, "ordinal_18", @intFromPtr(&ws2.stub_select));
    try environment.addBuiltinExport(dll, "ordinal_19", @intFromPtr(&ws2.stub_send));
    try environment.addBuiltinExport(dll, "ordinal_20", @intFromPtr(&ws2.stub_sendto));
    try environment.addBuiltinExport(dll, "ordinal_21", @intFromPtr(&ws2.stub_setsockopt));
    try environment.addBuiltinExport(dll, "ordinal_22", @intFromPtr(&ws2.stub_shutdown));
    try environment.addBuiltinExport(dll, "ordinal_23", @intFromPtr(&ws2.stub_socket));
    try environment.addBuiltinExport(dll, "ordinal_51", @intFromPtr(&ws2.stub_gethostbyaddr));
    try environment.addBuiltinExport(dll, "ordinal_52", @intFromPtr(&ws2.stub_gethostbyname));
    try environment.addBuiltinExport(dll, "ordinal_57", @intFromPtr(&ws2.stub_gethostname));
    try environment.addBuiltinExport(dll, "ordinal_115", @intFromPtr(&ws2.stub_WSAStartup));
    try environment.addBuiltinExport(dll, "ordinal_116", @intFromPtr(&ws2.stub_WSACleanup));
}
