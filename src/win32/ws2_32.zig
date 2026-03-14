const env = @import("../loader/env.zig");
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
    try environment.addBuiltinExportComptime(m, "ordinal_1", stubs.accept);         // accept
    try environment.addBuiltinExportComptime(m, "ordinal_2", stubs.bind);           // bind
    try environment.addBuiltinExportComptime(m, "ordinal_3", stubs.closesocket);    // closesocket
    try environment.addBuiltinExportComptime(m, "ordinal_4", stubs.connect);        // connect
    try environment.addBuiltinExportComptime(m, "ordinal_5", stubs.getpeername);    // getpeername
    try environment.addBuiltinExportComptime(m, "ordinal_6", stubs.getsockname);    // getsockname
    try environment.addBuiltinExportComptime(m, "ordinal_7", stubs.getsockopt);     // getsockopt
    try environment.addBuiltinExportComptime(m, "ordinal_8", stubs.htonl);          // htonl
    try environment.addBuiltinExportComptime(m, "ordinal_9", stubs.htons);          // htons
    try environment.addBuiltinExportComptime(m, "ordinal_10", stubs.ioctlsocket);   // ioctlsocket
    try environment.addBuiltinExportComptime(m, "ordinal_11", stubs.inet_addr);     // inet_addr
    try environment.addBuiltinExportComptime(m, "ordinal_12", stubs.inet_ntoa);     // inet_ntoa
    try environment.addBuiltinExportComptime(m, "ordinal_13", stubs.listen);        // listen
    try environment.addBuiltinExportComptime(m, "ordinal_14", stubs.ntohl);         // ntohl
    try environment.addBuiltinExportComptime(m, "ordinal_15", stubs.ntohs);         // ntohs
    try environment.addBuiltinExportComptime(m, "ordinal_16", stubs.recv);          // recv
    try environment.addBuiltinExportComptime(m, "ordinal_17", stubs.recvfrom);      // recvfrom
    try environment.addBuiltinExportComptime(m, "ordinal_18", stubs.select);        // select
    try environment.addBuiltinExportComptime(m, "ordinal_19", stubs.send);          // send
    try environment.addBuiltinExportComptime(m, "ordinal_20", stubs.sendto);        // sendto
    try environment.addBuiltinExportComptime(m, "ordinal_21", stubs.setsockopt);    // setsockopt
    try environment.addBuiltinExportComptime(m, "ordinal_22", stubs.stub_shutdown);      // shutdown
    try environment.addBuiltinExportComptime(m, "ordinal_23", stubs.socket);        // socket
    try environment.addBuiltinExportComptime(m, "ordinal_51", stubs.gethostbyaddr); // gethostbyaddr
    try environment.addBuiltinExportComptime(m, "ordinal_52", stubs.gethostbyname); // gethostbyname
    try environment.addBuiltinExportComptime(m, "ordinal_57", stubs.gethostname);   // gethostname
    try environment.addBuiltinExportComptime(m, "ordinal_111", kernel32.stub_args3);     // WSAEnumNetworkEvents
    try environment.addBuiltinExportComptime(m, "ordinal_115", stubs.WSAStartup);   // WSAStartup
    try environment.addBuiltinExportComptime(m, "ordinal_116", stubs.WSACleanup);   // WSACleanup
}
