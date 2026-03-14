const env = @import("../loader/env.zig");

/// WSOCK32.dll — Winsock 1.1 (thin forwarder to WS2_32.dll on Win2K)
pub fn register(environment: *env.Environment) !void {
    const dll = "WSOCK32.dll";

    // Import all implementations from WS2_32 (the real implementation)
    const ws2 = @import("ws2_32.zig");

    // Named exports — WSOCK32.dll exports the full BSD socket API by name
    try environment.addBuiltinExportComptime(dll, "accept", ws2.accept);
    try environment.addBuiltinExportComptime(dll, "bind", ws2.bind);
    try environment.addBuiltinExportComptime(dll, "closesocket", ws2.closesocket);
    try environment.addBuiltinExportComptime(dll, "connect", ws2.connect);
    try environment.addBuiltinExportComptime(dll, "getpeername", ws2.getpeername);
    try environment.addBuiltinExportComptime(dll, "getsockname", ws2.getsockname);
    try environment.addBuiltinExportComptime(dll, "getsockopt", ws2.getsockopt);
    try environment.addBuiltinExportComptime(dll, "htonl", ws2.htonl);
    try environment.addBuiltinExportComptime(dll, "htons", ws2.htons);
    try environment.addBuiltinExportComptime(dll, "ioctlsocket", ws2.ioctlsocket);
    try environment.addBuiltinExportComptime(dll, "inet_addr", ws2.inet_addr);
    try environment.addBuiltinExportComptime(dll, "inet_ntoa", ws2.inet_ntoa);
    try environment.addBuiltinExportComptime(dll, "listen", ws2.listen);
    try environment.addBuiltinExportComptime(dll, "ntohl", ws2.ntohl);
    try environment.addBuiltinExportComptime(dll, "ntohs", ws2.ntohs);
    try environment.addBuiltinExportComptime(dll, "recv", ws2.recv);
    try environment.addBuiltinExportComptime(dll, "recvfrom", ws2.recvfrom);
    try environment.addBuiltinExportComptime(dll, "select", ws2.select);
    try environment.addBuiltinExportComptime(dll, "send", ws2.send);
    try environment.addBuiltinExportComptime(dll, "sendto", ws2.sendto);
    try environment.addBuiltinExportComptime(dll, "setsockopt", ws2.setsockopt);
    try environment.addBuiltinExportComptime(dll, "shutdown", ws2.stub_shutdown);
    try environment.addBuiltinExportComptime(dll, "socket", ws2.socket);
    try environment.addBuiltinExportComptime(dll, "gethostbyaddr", ws2.gethostbyaddr);
    try environment.addBuiltinExportComptime(dll, "gethostbyname", ws2.gethostbyname);
    try environment.addBuiltinExportComptime(dll, "gethostname", ws2.gethostname);
    try environment.addBuiltinExportComptime(dll, "WSAStartup", ws2.WSAStartup);
    try environment.addBuiltinExportComptime(dll, "WSACleanup", ws2.WSACleanup);
    try environment.addBuiltinExportComptime(dll, "WSAGetLastError", ws2.stub_WSAGetLastError);
    try environment.addBuiltinExportComptime(dll, "WSASetLastError", ws2.stub_WSASetLastError);

    // WSOCK32 ordinals (same canonical table as WS2_32)
    try environment.addBuiltinExportComptime(dll, "ordinal_1", ws2.accept);
    try environment.addBuiltinExportComptime(dll, "ordinal_2", ws2.bind);
    try environment.addBuiltinExportComptime(dll, "ordinal_3", ws2.closesocket);
    try environment.addBuiltinExportComptime(dll, "ordinal_4", ws2.connect);
    try environment.addBuiltinExportComptime(dll, "ordinal_5", ws2.getpeername);
    try environment.addBuiltinExportComptime(dll, "ordinal_6", ws2.getsockname);
    try environment.addBuiltinExportComptime(dll, "ordinal_7", ws2.getsockopt);
    try environment.addBuiltinExportComptime(dll, "ordinal_8", ws2.htonl);
    try environment.addBuiltinExportComptime(dll, "ordinal_9", ws2.htons);
    try environment.addBuiltinExportComptime(dll, "ordinal_10", ws2.ioctlsocket);
    try environment.addBuiltinExportComptime(dll, "ordinal_11", ws2.inet_addr);
    try environment.addBuiltinExportComptime(dll, "ordinal_12", ws2.inet_ntoa);
    try environment.addBuiltinExportComptime(dll, "ordinal_13", ws2.listen);
    try environment.addBuiltinExportComptime(dll, "ordinal_14", ws2.ntohl);
    try environment.addBuiltinExportComptime(dll, "ordinal_15", ws2.ntohs);
    try environment.addBuiltinExportComptime(dll, "ordinal_16", ws2.recv);
    try environment.addBuiltinExportComptime(dll, "ordinal_17", ws2.recvfrom);
    try environment.addBuiltinExportComptime(dll, "ordinal_18", ws2.select);
    try environment.addBuiltinExportComptime(dll, "ordinal_19", ws2.send);
    try environment.addBuiltinExportComptime(dll, "ordinal_20", ws2.sendto);
    try environment.addBuiltinExportComptime(dll, "ordinal_21", ws2.setsockopt);
    try environment.addBuiltinExportComptime(dll, "ordinal_22", ws2.stub_shutdown);
    try environment.addBuiltinExportComptime(dll, "ordinal_23", ws2.socket);
    try environment.addBuiltinExportComptime(dll, "ordinal_51", ws2.gethostbyaddr);
    try environment.addBuiltinExportComptime(dll, "ordinal_52", ws2.gethostbyname);
    try environment.addBuiltinExportComptime(dll, "ordinal_57", ws2.gethostname);
    try environment.addBuiltinExportComptime(dll, "ordinal_115", ws2.WSAStartup);
    try environment.addBuiltinExportComptime(dll, "ordinal_116", ws2.WSACleanup);
}
