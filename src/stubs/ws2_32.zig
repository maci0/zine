const env = @import("../loader/env.zig");
const stubs = @import("ws2_32/stubs.zig");

// Re-export symbols used by wsock32.zig
pub const stub_WSAStartup = stubs.stub_WSAStartup;
pub const stub_WSACleanup = stubs.stub_WSACleanup;
pub const stub_WSAGetLastError = stubs.stub_WSAGetLastError;
pub const stub_WSASetLastError = stubs.stub_WSASetLastError;
pub const stub_accept = stubs.stub_accept;
pub const stub_bind = stubs.stub_bind;
pub const stub_closesocket = stubs.stub_closesocket;
pub const stub_connect = stubs.stub_connect;
pub const stub_getpeername = stubs.stub_getpeername;
pub const stub_getsockname = stubs.stub_getsockname;
pub const stub_getsockopt = stubs.stub_getsockopt;
pub const stub_htonl = stubs.stub_htonl;
pub const stub_htons = stubs.stub_htons;
pub const stub_ioctlsocket = stubs.stub_ioctlsocket;
pub const stub_inet_addr = stubs.stub_inet_addr;
pub const stub_inet_ntoa = stubs.stub_inet_ntoa;
pub const stub_listen = stubs.stub_listen;
pub const stub_ntohl = stubs.stub_ntohl;
pub const stub_ntohs = stubs.stub_ntohs;
pub const stub_recv = stubs.stub_recv;
pub const stub_recvfrom = stubs.stub_recvfrom;
pub const stub_select = stubs.stub_select;
pub const stub_send = stubs.stub_send;
pub const stub_sendto = stubs.stub_sendto;
pub const stub_setsockopt = stubs.stub_setsockopt;
pub const stub_shutdown = stubs.stub_shutdown;
pub const stub_socket = stubs.stub_socket;
pub const stub_gethostbyaddr = stubs.stub_gethostbyaddr;
pub const stub_gethostbyname = stubs.stub_gethostbyname;
pub const stub_gethostname = stubs.stub_gethostname;

pub fn register(environment: *env.Environment) !void {
    const m = "WS2_32.dll";
    try environment.addBuiltinExportComptime(m, "WSAStartup", stubs.stub_WSAStartup);
    try environment.addBuiltinExportComptime(m, "WSACleanup", stubs.stub_WSACleanup);
    try environment.addBuiltinExportComptime(m, "WSAGetLastError", stubs.stub_WSAGetLastError);
    try environment.addBuiltinExportComptime(m, "WSASetLastError", stubs.stub_WSASetLastError);
    try environment.addBuiltinExportComptime(m, "accept", stubs.stub_accept);
    try environment.addBuiltinExportComptime(m, "bind", stubs.stub_bind);
    try environment.addBuiltinExportComptime(m, "closesocket", stubs.stub_closesocket);
    try environment.addBuiltinExportComptime(m, "connect", stubs.stub_connect);
    try environment.addBuiltinExportComptime(m, "getpeername", stubs.stub_getpeername);
    try environment.addBuiltinExportComptime(m, "getsockname", stubs.stub_getsockname);
    try environment.addBuiltinExportComptime(m, "getsockopt", stubs.stub_getsockopt);
    try environment.addBuiltinExportComptime(m, "htonl", stubs.stub_htonl);
    try environment.addBuiltinExportComptime(m, "htons", stubs.stub_htons);
    try environment.addBuiltinExportComptime(m, "ioctlsocket", stubs.stub_ioctlsocket);
    try environment.addBuiltinExportComptime(m, "inet_addr", stubs.stub_inet_addr);
    try environment.addBuiltinExportComptime(m, "inet_ntoa", stubs.stub_inet_ntoa);
    try environment.addBuiltinExportComptime(m, "listen", stubs.stub_listen);
    try environment.addBuiltinExportComptime(m, "ntohl", stubs.stub_ntohl);
    try environment.addBuiltinExportComptime(m, "ntohs", stubs.stub_ntohs);
    try environment.addBuiltinExportComptime(m, "recv", stubs.stub_recv);
    try environment.addBuiltinExportComptime(m, "recvfrom", stubs.stub_recvfrom);
    try environment.addBuiltinExportComptime(m, "select", stubs.stub_select);
    try environment.addBuiltinExportComptime(m, "send", stubs.stub_send);
    try environment.addBuiltinExportComptime(m, "sendto", stubs.stub_sendto);
    try environment.addBuiltinExportComptime(m, "setsockopt", stubs.stub_setsockopt);
    try environment.addBuiltinExportComptime(m, "shutdown", stubs.stub_shutdown);
    try environment.addBuiltinExportComptime(m, "socket", stubs.stub_socket);
    try environment.addBuiltinExportComptime(m, "gethostbyname", stubs.stub_gethostbyname);
    try environment.addBuiltinExportComptime(m, "gethostbyaddr", stubs.stub_gethostbyaddr);
    try environment.addBuiltinExportComptime(m, "gethostname", stubs.stub_gethostname);

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
    try environment.addBuiltinExportComptime(m, "ordinal_1", stubs.stub_accept);         // accept
    try environment.addBuiltinExportComptime(m, "ordinal_2", stubs.stub_bind);           // bind
    try environment.addBuiltinExportComptime(m, "ordinal_3", stubs.stub_closesocket);    // closesocket
    try environment.addBuiltinExportComptime(m, "ordinal_4", stubs.stub_connect);        // connect
    try environment.addBuiltinExportComptime(m, "ordinal_5", stubs.stub_getpeername);    // getpeername
    try environment.addBuiltinExportComptime(m, "ordinal_6", stubs.stub_getsockname);    // getsockname
    try environment.addBuiltinExportComptime(m, "ordinal_7", stubs.stub_getsockopt);     // getsockopt
    try environment.addBuiltinExportComptime(m, "ordinal_8", stubs.stub_htonl);          // htonl
    try environment.addBuiltinExportComptime(m, "ordinal_9", stubs.stub_htons);          // htons
    try environment.addBuiltinExportComptime(m, "ordinal_10", stubs.stub_ioctlsocket);   // ioctlsocket
    try environment.addBuiltinExportComptime(m, "ordinal_11", stubs.stub_inet_addr);     // inet_addr
    try environment.addBuiltinExportComptime(m, "ordinal_12", stubs.stub_inet_ntoa);     // inet_ntoa
    try environment.addBuiltinExportComptime(m, "ordinal_13", stubs.stub_listen);        // listen
    try environment.addBuiltinExportComptime(m, "ordinal_14", stubs.stub_ntohl);         // ntohl
    try environment.addBuiltinExportComptime(m, "ordinal_15", stubs.stub_ntohs);         // ntohs
    try environment.addBuiltinExportComptime(m, "ordinal_16", stubs.stub_recv);          // recv
    try environment.addBuiltinExportComptime(m, "ordinal_17", stubs.stub_recvfrom);      // recvfrom
    try environment.addBuiltinExportComptime(m, "ordinal_18", stubs.stub_select);        // select
    try environment.addBuiltinExportComptime(m, "ordinal_19", stubs.stub_send);          // send
    try environment.addBuiltinExportComptime(m, "ordinal_20", stubs.stub_sendto);        // sendto
    try environment.addBuiltinExportComptime(m, "ordinal_21", stubs.stub_setsockopt);    // setsockopt
    try environment.addBuiltinExportComptime(m, "ordinal_22", stubs.stub_shutdown);      // shutdown
    try environment.addBuiltinExportComptime(m, "ordinal_23", stubs.stub_socket);        // socket
    try environment.addBuiltinExportComptime(m, "ordinal_51", stubs.stub_gethostbyaddr); // gethostbyaddr
    try environment.addBuiltinExportComptime(m, "ordinal_52", stubs.stub_gethostbyname); // gethostbyname
    try environment.addBuiltinExportComptime(m, "ordinal_57", stubs.stub_gethostname);   // gethostname
    try environment.addBuiltinExportComptime(m, "ordinal_111", kernel32.stub_args3);     // WSAEnumNetworkEvents
    try environment.addBuiltinExportComptime(m, "ordinal_115", stubs.stub_WSAStartup);   // WSAStartup
    try environment.addBuiltinExportComptime(m, "ordinal_116", stubs.stub_WSACleanup);   // WSACleanup
}
