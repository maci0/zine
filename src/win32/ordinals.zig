//! Win32 DLL ordinal mappings.
//! Standard ordinal numbers for DLLs that export by ordinal.
//! Usage: `ordinals.WS2_32.accept` returns `"ordinal_1"`.
//! Reference: Windows SDK import libraries / dumpbin /exports
const std = @import("std");

fn ordStr(comptime n: u16) []const u8 {
    return "ordinal_" ++ std.fmt.comptimePrint("{d}", .{n});
}

// -----------------------------------------------------------------------
/// WS2_32.dll — Winsock 2
// -----------------------------------------------------------------------
pub const WS2_32 = struct {
    pub const accept = ordStr(1);
    pub const bind = ordStr(2);
    pub const closesocket = ordStr(3);
    pub const connect = ordStr(4);
    pub const getpeername = ordStr(5);
    pub const getsockname = ordStr(6);
    pub const getsockopt = ordStr(7);
    pub const htonl = ordStr(8);
    pub const htons = ordStr(9);
    pub const ioctlsocket = ordStr(10);
    pub const inet_addr = ordStr(11);
    pub const inet_ntoa = ordStr(12);
    pub const listen = ordStr(13);
    pub const ntohl = ordStr(14);
    pub const ntohs = ordStr(15);
    pub const recv = ordStr(16);
    pub const recvfrom = ordStr(17);
    pub const select = ordStr(18);
    pub const send = ordStr(19);
    pub const sendto = ordStr(20);
    pub const setsockopt = ordStr(21);
    pub const shutdown = ordStr(22);
    pub const socket = ordStr(23);
    pub const gethostbyaddr = ordStr(51);
    pub const gethostbyname = ordStr(52);
    pub const __WSAFDIsSet = ordStr(53);
    pub const gethostname = ordStr(57);
    pub const WSAEnumNetworkEvents = ordStr(111);
    pub const WSAGetOverlappedResult = ordStr(112);
    pub const WSAStartup = ordStr(115);
    pub const WSACleanup = ordStr(116);
    pub const WSASocketW = ordStr(151);
};

// -----------------------------------------------------------------------
/// WSOCK32.dll — Winsock 1.1 (same ordinals as WS2_32 for 1-23)
// -----------------------------------------------------------------------
pub const WSOCK32 = struct {
    pub const accept = ordStr(1);
    pub const bind = ordStr(2);
    pub const closesocket = ordStr(3);
    pub const connect = ordStr(4);
    pub const getpeername = ordStr(5);
    pub const getsockname = ordStr(6);
    pub const getsockopt = ordStr(7);
    pub const htonl = ordStr(8);
    pub const htons = ordStr(9);
    pub const ioctlsocket = ordStr(10);
    pub const inet_addr = ordStr(11);
    pub const inet_ntoa = ordStr(12);
    pub const listen = ordStr(13);
    pub const ntohl = ordStr(14);
    pub const ntohs = ordStr(15);
    pub const recv = ordStr(16);
    pub const recvfrom = ordStr(17);
    pub const select = ordStr(18);
    pub const send = ordStr(19);
    pub const sendto = ordStr(20);
    pub const setsockopt = ordStr(21);
    pub const shutdown = ordStr(22);
    pub const socket = ordStr(23);
    pub const gethostbyaddr = ordStr(51);
    pub const gethostbyname = ordStr(52);
    pub const gethostname = ordStr(57);
    pub const WSAStartup = ordStr(115);
    pub const WSACleanup = ordStr(116);
};

// -----------------------------------------------------------------------
/// OLEAUT32.dll — OLE Automation
// -----------------------------------------------------------------------
pub const OLEAUT32 = struct {
    pub const SysAllocString = ordStr(2);
    pub const SysFreeString = ordStr(6);
    pub const SysAllocStringLen = ordStr(4);
    pub const SysAllocStringByteLen = ordStr(7);
    pub const VariantInit = ordStr(8);
    pub const VariantClear = ordStr(9);
    pub const VariantCopyInd = ordStr(10);
    pub const VariantChangeType = ordStr(18);
    pub const VariantCopy = ordStr(25);
    pub const SysStringLen = ordStr(149);
    pub const SafeArrayGetElement = ordStr(77);
    pub const SysStringByteLen = ordStr(150);
};

// -----------------------------------------------------------------------
/// COMCTL32.dll — Common Controls
// -----------------------------------------------------------------------
pub const COMCTL32 = struct {
    pub const CreateStatusWindowA = ordStr(6);
    pub const CreateMappedBitmap = ordStr(8);
    pub const TrackMouseEvent_13 = ordStr(13); // old ordinal
    pub const CreateUpDownControl_14 = ordStr(14);
    pub const CreateStatusWindowA_15 = ordStr(15);
    pub const InitCommonControls = ordStr(17);
};

// -----------------------------------------------------------------------
/// SHELL32.dll
// -----------------------------------------------------------------------
pub const SHELL32 = struct {
    pub const RunFileDlg = ordStr(61);
    pub const SHFreeNameMappings = ordStr(100);
    pub const SHBrowseForFolder = ordStr(180);
    pub const SHGetSpecialFolderPathA = ordStr(258);
};

// -----------------------------------------------------------------------
/// DSOUND.dll
// -----------------------------------------------------------------------
pub const DSOUND = struct {
    pub const DirectSoundCreate = ordStr(1);
};

// -----------------------------------------------------------------------
/// NDDEAPI.dll
// -----------------------------------------------------------------------
pub const NDDEAPI = struct {
    // W variants (Unicode); the A (ANSI) ordinals are not registered.
    pub const NDdeShareAddW = ordStr(500);
    pub const NDdeShareDelW = ordStr(501);
    pub const NDdeShareGetInfoW = ordStr(503);
    pub const NDdeShareSetInfoW = ordStr(504);
    pub const NDdeShareEnumW = ordStr(505);
    pub const NDdeGetShareSecurityW = ordStr(506);
    pub const NDdeSetShareSecurityW = ordStr(509);
    pub const NDdeSetTrustedShareW = ordStr(511);
    pub const NDdeGetTrustedShareW = ordStr(512);
    pub const NDdeGetErrorStringW = ordStr(609);
    pub const NDdeIsValidShareNameW = ordStr(610);
    pub const NDdeIsValidAppTopicListW = ordStr(611);
    pub const NDdeTrustedShareEnumW = ordStr(612);
};
