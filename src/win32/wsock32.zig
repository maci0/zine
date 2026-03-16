//! WSOCK32.dll registration.

const env = @import("../loader/env.zig");
const ordinals = @import("ordinals.zig");

/// Registers WSOCK32.dll functions with the environment.
/// Implementation status: Partially implemented
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
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.accept, ws2.accept);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.bind, ws2.bind);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.closesocket, ws2.closesocket);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.connect, ws2.connect);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.getpeername, ws2.getpeername);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.getsockname, ws2.getsockname);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.getsockopt, ws2.getsockopt);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.htonl, ws2.htonl);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.htons, ws2.htons);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.ioctlsocket, ws2.ioctlsocket);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.inet_addr, ws2.inet_addr);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.inet_ntoa, ws2.inet_ntoa);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.listen, ws2.listen);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.ntohl, ws2.ntohl);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.ntohs, ws2.ntohs);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.recv, ws2.recv);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.recvfrom, ws2.recvfrom);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.select, ws2.select);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.send, ws2.send);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.sendto, ws2.sendto);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.setsockopt, ws2.setsockopt);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.shutdown, ws2.stub_shutdown);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.socket, ws2.socket);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.gethostbyaddr, ws2.gethostbyaddr);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.gethostbyname, ws2.gethostbyname);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.gethostname, ws2.gethostname);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.WSAStartup, ws2.WSAStartup);
    try environment.addBuiltinExportComptime(dll, ordinals.WSOCK32.WSACleanup, ws2.WSACleanup);
}
