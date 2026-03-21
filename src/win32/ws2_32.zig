//! Winsock 2.2 (WS2_32.dll) implementation.
const env = @import("../loader/env.zig");
const ordinals = @import("ordinals.zig");
const stubs = @import("ws2_32/winsock.zig");

// Re-export symbols used by wsock32.zig
pub const WSAStartup = stubs.WSAStartup;
pub const WSACleanup = stubs.WSACleanup;
pub const stub_WSAGetLastError = stubs.stub_WSAGetLastError;
pub const stub_WSASetLastError = stubs.stub_WSASetLastError;
pub const accept = stubs.accept;
pub const bind = stubs.bind;
pub const closesocket = stubs.closesocket;
pub const connect = stubs.connect;
pub const getpeername = stubs.getpeername;
pub const getsockname = stubs.getsockname;
pub const getsockopt = stubs.getsockopt;
pub const htonl = stubs.htonl;
pub const htons = stubs.htons;
pub const ioctlsocket = stubs.ioctlsocket;
pub const inet_addr = stubs.inet_addr;
pub const inet_ntoa = stubs.inet_ntoa;
pub const listen = stubs.listen;
pub const ntohl = stubs.ntohl;
pub const ntohs = stubs.ntohs;
pub const recv = stubs.recv;
pub const recvfrom = stubs.recvfrom;
pub const select = stubs.select;
pub const send = stubs.send;
pub const sendto = stubs.sendto;
pub const setsockopt = stubs.setsockopt;
pub const stub_shutdown = stubs.stub_shutdown;
pub const socket = stubs.socket;
pub const gethostbyaddr = stubs.gethostbyaddr;
pub const gethostbyname = stubs.gethostbyname;
pub const gethostname = stubs.gethostname;

/// Registers WS2_32.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "WS2_32.dll";
    try environment.addBuiltinExportComptime(m, "WSAStartup", stubs.WSAStartup);
    try environment.addBuiltinExportComptime(m, "WSACleanup", stubs.WSACleanup);
    try environment.addBuiltinExportComptime(m, "WSAGetLastError", stubs.stub_WSAGetLastError);
    try environment.addBuiltinExportComptime(m, "WSASetLastError", stubs.stub_WSASetLastError);
    try environment.addBuiltinExportComptime(m, "accept", stubs.accept);
    try environment.addBuiltinExportComptime(m, "bind", stubs.bind);
    try environment.addBuiltinExportComptime(m, "closesocket", stubs.closesocket);
    try environment.addBuiltinExportComptime(m, "connect", stubs.connect);
    try environment.addBuiltinExportComptime(m, "getpeername", stubs.getpeername);
    try environment.addBuiltinExportComptime(m, "getsockname", stubs.getsockname);
    try environment.addBuiltinExportComptime(m, "getsockopt", stubs.getsockopt);
    try environment.addBuiltinExportComptime(m, "htonl", stubs.htonl);
    try environment.addBuiltinExportComptime(m, "htons", stubs.htons);
    try environment.addBuiltinExportComptime(m, "ioctlsocket", stubs.ioctlsocket);
    try environment.addBuiltinExportComptime(m, "inet_addr", stubs.inet_addr);
    try environment.addBuiltinExportComptime(m, "inet_ntoa", stubs.inet_ntoa);
    try environment.addBuiltinExportComptime(m, "listen", stubs.listen);
    try environment.addBuiltinExportComptime(m, "ntohl", stubs.ntohl);
    try environment.addBuiltinExportComptime(m, "ntohs", stubs.ntohs);
    try environment.addBuiltinExportComptime(m, "recv", stubs.recv);
    try environment.addBuiltinExportComptime(m, "recvfrom", stubs.recvfrom);
    try environment.addBuiltinExportComptime(m, "select", stubs.select);
    try environment.addBuiltinExportComptime(m, "send", stubs.send);
    try environment.addBuiltinExportComptime(m, "sendto", stubs.sendto);
    try environment.addBuiltinExportComptime(m, "setsockopt", stubs.setsockopt);
    try environment.addBuiltinExportComptime(m, "shutdown", stubs.stub_shutdown);
    try environment.addBuiltinExportComptime(m, "socket", stubs.socket);
    try environment.addBuiltinExportComptime(m, "gethostbyname", stubs.gethostbyname);
    try environment.addBuiltinExportComptime(m, "gethostbyaddr", stubs.gethostbyaddr);
    try environment.addBuiltinExportComptime(m, "gethostname", stubs.gethostname);

    // --- Remaining WS2_32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExportComptime(m, "WSARecv", kernel32.stub_args7);
    try environment.addBuiltinExportComptime(m, "WSASend", kernel32.stub_args7);
    try environment.addBuiltinExportComptime(m, "WSASocketA", kernel32.stub_args6);
    try environment.addBuiltinExportComptime(m, "WSAIoctl", kernel32.stub_args9);
    try environment.addBuiltinExportComptime(m, "WSAEventSelect", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WSACreateEvent", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(m, "WSAWaitForMultipleEvents", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "WSAEnumNetworkEvents", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WSACloseEvent", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "getaddrinfo", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "freeaddrinfo", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "getnameinfo", kernel32.stub_args7);
    try environment.addBuiltinExportComptime(m, "WSAStringToAddressA", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "__WSAFDIsSet", kernel32.stub_args2);

    // --- Ordinal-based exports (WS2_32 exports by ordinal) ---
    // Games often import WS2_32 functions by ordinal number.
    // Standard ordinal map from Windows SDK:
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.accept, stubs.accept); // accept
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.bind, stubs.bind); // bind
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.closesocket, stubs.closesocket); // closesocket
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.connect, stubs.connect); // connect
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.getpeername, stubs.getpeername); // getpeername
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.getsockname, stubs.getsockname); // getsockname
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.getsockopt, stubs.getsockopt); // getsockopt
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.htonl, stubs.htonl); // htonl
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.htons, stubs.htons); // htons
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.ioctlsocket, stubs.ioctlsocket); // ioctlsocket
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.inet_addr, stubs.inet_addr); // inet_addr
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.inet_ntoa, stubs.inet_ntoa); // inet_ntoa
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.listen, stubs.listen); // listen
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.ntohl, stubs.ntohl); // ntohl
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.ntohs, stubs.ntohs); // ntohs
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.recv, stubs.recv); // recv
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.recvfrom, stubs.recvfrom); // recvfrom
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.select, stubs.select); // select
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.send, stubs.send); // send
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.sendto, stubs.sendto); // sendto
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.setsockopt, stubs.setsockopt); // setsockopt
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.shutdown, stubs.stub_shutdown); // shutdown
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.socket, stubs.socket); // socket
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.gethostbyaddr, stubs.gethostbyaddr); // gethostbyaddr
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.gethostbyname, stubs.gethostbyname); // gethostbyname
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.gethostname, stubs.gethostname); // gethostname
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.WSAEnumNetworkEvents, kernel32.stub_args3); // WSAEnumNetworkEvents
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.WSAStartup, stubs.WSAStartup); // WSAStartup
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.WSACleanup, stubs.WSACleanup); // WSACleanup

    // --- Additional WinSock ordinal imports ---
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.__WSAFDIsSet, kernel32.stub_args3); // __WSAFDIsSet
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.WSAGetOverlappedResult, kernel32.stub_args4); // WSAGetOverlappedResult
    try environment.addBuiltinExportComptime(m, ordinals.WS2_32.WSASocketW, kernel32.stub_args6); // WSASocketW
}
