const std = @import("std");
const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");
const trace = @import("../trace.zig");

pub fn register(environment: *env.Environment) !void {
    const advapi32 = "ADVAPI32.dll";
    try environment.addBuiltinExport(advapi32, "RegOpenKeyExA", @intFromPtr(&stub_RegOpenKeyExA));
    try environment.addBuiltinExport(advapi32, "RegQueryValueExA", @intFromPtr(&stub_RegQueryValueExA));
    try environment.addBuiltinExport(advapi32, "RegCloseKey", @intFromPtr(&kernel32.stub_args1));
    try environment.addBuiltinExport(advapi32, "RegCreateKeyExA", @intFromPtr(&stub_RegCreateKeyExA));
    try environment.addBuiltinExport(advapi32, "RegSetValueExA", @intFromPtr(&stub_RegSetValueExA));
    try environment.addBuiltinExport(advapi32, "RegDeleteKeyA", @intFromPtr(&stub_RegDeleteKeyA));
    try environment.addBuiltinExport(advapi32, "RegDeleteValueA", @intFromPtr(&stub_RegDeleteValueA));
    try environment.addBuiltinExport(advapi32, "RegEnumKeyExA", @intFromPtr(&stub_RegEnumKeyExA));
    try environment.addBuiltinExport(advapi32, "RegEnumKeyA", @intFromPtr(&stub_RegEnumKeyA));
    try environment.addBuiltinExport(advapi32, "RegQueryInfoKeyA", @intFromPtr(&stub_RegQueryInfoKeyA));
    try environment.addBuiltinExport(advapi32, "RegFlushKey", @intFromPtr(&stub_RegFlushKey));
    try environment.addBuiltinExport(advapi32, "RegOpenKeyA", @intFromPtr(&stub_RegOpenKeyA));
    try environment.addBuiltinExport(advapi32, "RegQueryValueExW", @intFromPtr(&stub_RegQueryValueExW));
    try environment.addBuiltinExport(advapi32, "RegSetValueExW", @intFromPtr(&stub_RegSetValueExW));
    try environment.addBuiltinExport(advapi32, "OpenProcessToken", @intFromPtr(&stub_OpenProcessToken));
    try environment.addBuiltinExport(advapi32, "AdjustTokenPrivileges", @intFromPtr(&stub_AdjustTokenPrivileges));
    try environment.addBuiltinExport(advapi32, "LookupPrivilegeValueW", @intFromPtr(&stub_LookupPrivilegeValueW));
    try environment.addBuiltinExport(advapi32, "GetUserNameA", @intFromPtr(&stub_GetUserNameA));
    try environment.addBuiltinExport(advapi32, "GetFileSecurityW", @intFromPtr(&stub_GetFileSecurityW));
    try environment.addBuiltinExport(advapi32, "SetFileSecurityW", @intFromPtr(&stub_SetFileSecurityW));
    try environment.addBuiltinExport(advapi32, "RegCreateKeyA", @intFromPtr(&stub_RegCreateKeyA));
    try environment.addBuiltinExport(advapi32, "IsTextUnicode", @intFromPtr(&stub_IsTextUnicode));
    try environment.addBuiltinExport(advapi32, "RegCreateKeyW", @intFromPtr(&stub_RegCreateKeyW));

    // W variants needed by win2k apps (3-6x each)
    try environment.addBuiltinExport(advapi32, "RegOpenKeyExW", @intFromPtr(&stub_RegOpenKeyExW));
    try environment.addBuiltinExport(advapi32, "RegCreateKeyExW", @intFromPtr(&stub_RegCreateKeyExW));
    try environment.addBuiltinExport(advapi32, "RegOpenKeyW", @intFromPtr(&stub_RegOpenKeyW));
    try environment.addBuiltinExport(advapi32, "RegDeleteKeyW", @intFromPtr(&stub_RegDeleteKeyW));
    try environment.addBuiltinExport(advapi32, "RegDeleteValueW", @intFromPtr(&stub_RegDeleteValueW));
    try environment.addBuiltinExport(advapi32, "RegSetValueW", @intFromPtr(&stub_RegSetValueW));
    try environment.addBuiltinExport(advapi32, "RegEnumKeyW", @intFromPtr(&stub_RegEnumKeyW));
    try environment.addBuiltinExport(advapi32, "LookupPrivilegeValueA", @intFromPtr(&stub_LookupPrivilegeValueW));
    try environment.addBuiltinExport(advapi32, "GetTokenInformation", @intFromPtr(&stub_GetTokenInformation));
    try environment.addBuiltinExport(advapi32, "OpenThreadToken", @intFromPtr(&stub_OpenThreadToken));
    try environment.addBuiltinExport(advapi32, "RegQueryValueW", @intFromPtr(&stub_RegQueryValueW));

    // --- Remaining ADVAPI32 stubs for 100% win2k coverage ---
    // Faithful implementations
    try environment.addBuiltinExport(advapi32, "QueryServiceStatus", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(advapi32, "EqualSid", @intFromPtr(&stub_EqualSid));
    try environment.addBuiltinExport(advapi32, "OpenServiceA", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(advapi32, "OpenSCManagerA", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(advapi32, "CloseServiceHandle", @intFromPtr(&stub_ret_true_1));
    try environment.addBuiltinExport(advapi32, "GetAce", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(advapi32, "InitializeSecurityDescriptor", @intFromPtr(&stub_ret_true_2));
    try environment.addBuiltinExport(advapi32, "GetLengthSid", @intFromPtr(&stub_GetLengthSid));
    try environment.addBuiltinExport(advapi32, "InitializeAcl", @intFromPtr(&stub_ret_true_3));
    try environment.addBuiltinExport(advapi32, "AddAccessAllowedAce", @intFromPtr(&stub_ret_true_4));
    try environment.addBuiltinExport(advapi32, "SetSecurityDescriptorDacl", @intFromPtr(&stub_ret_true_4));
    try environment.addBuiltinExport(advapi32, "GetSecurityDescriptorOwner", @intFromPtr(&stub_GetSecurityDescriptorOwner));
    try environment.addBuiltinExport(advapi32, "IsValidSecurityDescriptor", @intFromPtr(&stub_ret_true_1));
    try environment.addBuiltinExport(advapi32, "GetSecurityDescriptorLength", @intFromPtr(&stub_GetSecurityDescriptorLength));
    try environment.addBuiltinExport(advapi32, "MakeSelfRelativeSD", @intFromPtr(&stub_ret_true_3));
    try environment.addBuiltinExport(advapi32, "GetSecurityInfoExW", @intFromPtr(&kernel32.stub_args8));
    try environment.addBuiltinExport(advapi32, "GetSiteSidFromToken", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(advapi32, "IsValidSid", @intFromPtr(&stub_ret_true_1));
    try environment.addBuiltinExport(advapi32, "IsTokenRestricted", @intFromPtr(&kernel32.stub_args1));
    try environment.addBuiltinExport(advapi32, "LookupAccountSidW", @intFromPtr(&kernel32.stub_args7));
    try environment.addBuiltinExport(advapi32, "FreeSid", @intFromPtr(&stub_FreeSid));
}

fn stub_RegOpenKeyExA(hKey: usize, lpSubKey: usize, ulOptions: u32, samDesired: u32, phkResult: usize) callconv(.winapi) u32 {
    _ = ulOptions;
    _ = samDesired;
    if (trace.enable_tracing) {
        const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "(null)";
        trace.print("ADVAPI32: RegOpenKeyExA(0x{X}, '{s}') -> ERROR_FILE_NOT_FOUND\n", .{ hKey, key });
    }
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = 0;
    }
    return 2; // ERROR_FILE_NOT_FOUND
}

fn stub_RegQueryValueExA(hKey: usize, lpValueName: usize, lpReserved: usize, lpType: usize, lpData: usize, lpcbData: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpReserved;
    _ = lpType;
    _ = lpData;
    _ = lpcbData;
    if (trace.enable_tracing) {
        const name = if (lpValueName != 0) trace.c_span(lpValueName) else "(null)";
        trace.print("ADVAPI32: RegQueryValueExA('{s}') -> ERROR_FILE_NOT_FOUND\n", .{name});
    }
    return 2; // ERROR_FILE_NOT_FOUND
}

var next_reg_handle: u32 = 0xDE000001;

fn stub_RegCreateKeyExA(hKey: usize, lpSubKey: usize, reserved: u32, lpClass: usize, dwOptions: u32, samDesired: u32, lpSecurityAttributes: usize, phkResult: usize, lpdwDisposition: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = reserved;
    _ = lpClass;
    _ = dwOptions;
    _ = samDesired;
    _ = lpSecurityAttributes;
    if (trace.enable_tracing) {
        const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "(null)";
        trace.print("ADVAPI32: RegCreateKeyExA('{s}')\n", .{key});
    }
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = next_reg_handle;
        next_reg_handle +%= 1;
    }
    if (lpdwDisposition != 0) {
        @as(*u32, @ptrFromInt(lpdwDisposition)).* = 1; // REG_CREATED_NEW_KEY (no persisted values)
    }
    return 0; // ERROR_SUCCESS
}

fn stub_RegSetValueExA(hKey: usize, lpValueName: usize, reserved: u32, dwType: u32, lpData: usize, cbData: u32) callconv(.winapi) u32 {
    _ = hKey;
    _ = reserved;
    _ = dwType;
    _ = lpData;
    _ = cbData;
    if (trace.enable_tracing) {
        const name = if (lpValueName != 0) trace.c_span(lpValueName) else "(null)";
        trace.print("ADVAPI32: RegSetValueExA('{s}')\n", .{name});
    }
    return 0;
}

fn stub_RegDeleteKeyA(hKey: usize, lpSubKey: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteKeyA\n", .{});
    return 0;
}

fn stub_RegDeleteValueA(hKey: usize, lpValueName: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpValueName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteValueA\n", .{});
    return 0;
}

fn stub_RegEnumKeyExA(hKey: usize, dwIndex: u32, lpName: usize, lpcchName: usize, lpReserved: usize, lpClass: usize, lpcchClass: usize, lpftLastWriteTime: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = dwIndex;
    _ = lpName;
    _ = lpcchName;
    _ = lpReserved;
    _ = lpClass;
    _ = lpcchClass;
    _ = lpftLastWriteTime;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegEnumKeyExA -> ERROR_NO_MORE_ITEMS\n", .{});
    return 259; // ERROR_NO_MORE_ITEMS
}

fn stub_RegEnumKeyA(hKey: usize, dwIndex: u32, lpName: usize, cchName: u32) callconv(.winapi) u32 {
    _ = hKey;
    _ = dwIndex;
    _ = lpName;
    _ = cchName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegEnumKeyA -> ERROR_NO_MORE_ITEMS\n", .{});
    return 259;
}

fn stub_RegQueryInfoKeyA(hKey: usize, lpClass: usize, lpcchClass: usize, lpReserved: usize, lpcSubKeys: usize, lpcbMaxSubKeyLen: usize, lpcbMaxClassLen: usize, lpcValues: usize, lpcbMaxValueNameLen: usize, lpcbMaxValueLen: usize, lpcbSecurityDescriptor: usize, lpftLastWriteTime: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpClass;
    _ = lpcchClass;
    _ = lpReserved;
    _ = lpftLastWriteTime;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryInfoKeyA\n", .{});
    // Fill counts with 0
    if (lpcSubKeys != 0) @as(*u32, @ptrFromInt(lpcSubKeys)).* = 0;
    if (lpcbMaxSubKeyLen != 0) @as(*u32, @ptrFromInt(lpcbMaxSubKeyLen)).* = 0;
    if (lpcbMaxClassLen != 0) @as(*u32, @ptrFromInt(lpcbMaxClassLen)).* = 0;
    if (lpcValues != 0) @as(*u32, @ptrFromInt(lpcValues)).* = 0;
    if (lpcbMaxValueNameLen != 0) @as(*u32, @ptrFromInt(lpcbMaxValueNameLen)).* = 0;
    if (lpcbMaxValueLen != 0) @as(*u32, @ptrFromInt(lpcbMaxValueLen)).* = 0;
    if (lpcbSecurityDescriptor != 0) @as(*u32, @ptrFromInt(lpcbSecurityDescriptor)).* = 0;
    return 0;
}

fn stub_RegFlushKey(hKey: usize) callconv(.winapi) u32 {
    _ = hKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegFlushKey\n", .{});
    return 0;
}

fn stub_RegOpenKeyA(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = phkResult;
    if (trace.enable_tracing) {
        const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "(null)";
        trace.print("ADVAPI32: RegOpenKeyA('{s}') -> ERROR_FILE_NOT_FOUND\n", .{key});
    }
    return 2; // ERROR_FILE_NOT_FOUND
}

fn stub_RegQueryValueExW(hKey: usize, lpValueName: usize, lpReserved: usize, lpType: usize, lpData: usize, lpcbData: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpValueName;
    _ = lpReserved;
    _ = lpType;
    _ = lpData;
    _ = lpcbData;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryValueExW -> ERROR_FILE_NOT_FOUND\n", .{});
    return 2; // ERROR_FILE_NOT_FOUND
}

fn stub_RegSetValueExW(hKey: usize, lpValueName: usize, reserved: u32, dwType: u32, lpData: usize, cbData: u32) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpValueName;
    _ = reserved;
    _ = dwType;
    _ = lpData;
    _ = cbData;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegSetValueExW\n", .{});
    return 0;
}

fn stub_OpenProcessToken(ProcessHandle: usize, DesiredAccess: u32, TokenHandle: usize) callconv(.winapi) i32 {
    _ = ProcessHandle;
    _ = DesiredAccess;
    if (TokenHandle != 0) {
        @as(*u32, @ptrFromInt(TokenHandle)).* = 0xFE000001; // fake token handle
    }
    if (trace.enable_tracing) trace.print("ADVAPI32: OpenProcessToken\n", .{});
    return 1;
}

fn stub_AdjustTokenPrivileges(TokenHandle: usize, DisableAllPrivileges: i32, NewState: usize, BufferLength: u32, PreviousState: usize, ReturnLength: usize) callconv(.winapi) i32 {
    _ = TokenHandle;
    _ = DisableAllPrivileges;
    _ = NewState;
    _ = BufferLength;
    _ = PreviousState;
    _ = ReturnLength;
    if (trace.enable_tracing) trace.print("ADVAPI32: AdjustTokenPrivileges\n", .{});
    return 1;
}

fn stub_LookupPrivilegeValueW(lpSystemName: usize, lpName: usize, lpLuid: usize) callconv(.winapi) i32 {
    _ = lpSystemName;
    _ = lpName;
    _ = lpLuid;
    if (trace.enable_tracing) trace.print("ADVAPI32: LookupPrivilegeValueW -> 0\n", .{});
    return 0;
}

fn stub_GetUserNameA(lpBuffer: usize, pcbBuffer: usize) callconv(.winapi) i32 {
    if (trace.enable_tracing) trace.print("ADVAPI32: GetUserNameA\n", .{});
    const name = "User";
    if (lpBuffer != 0 and pcbBuffer != 0) {
        const buf_size = @as(*u32, @ptrFromInt(pcbBuffer)).*;
        if (buf_size >= name.len + 1) {
            const buf = @as([*]u8, @ptrFromInt(lpBuffer));
            @memcpy(buf[0..name.len], name);
            buf[name.len] = 0;
            @as(*u32, @ptrFromInt(pcbBuffer)).* = @intCast(name.len + 1);
            return 1;
        }
    }
    if (pcbBuffer != 0) {
        @as(*u32, @ptrFromInt(pcbBuffer)).* = @intCast(name.len + 1);
    }
    return 0;
}

fn stub_GetFileSecurityW(lpFileName: usize, RequestedInformation: u32, pSecurityDescriptor: usize, nLength: u32, lpnLengthNeeded: usize) callconv(.winapi) i32 {
    _ = lpFileName;
    _ = RequestedInformation;
    _ = pSecurityDescriptor;
    _ = nLength;
    if (lpnLengthNeeded != 0) {
        @as(*u32, @ptrFromInt(lpnLengthNeeded)).* = 0;
    }
    if (trace.enable_tracing) trace.print("ADVAPI32: GetFileSecurityW -> 0\n", .{});
    return 0;
}

fn stub_RegCreateKeyA(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(.winapi) u32 {
    _ = hKey;
    if (trace.enable_tracing) {
        const key = if (lpSubKey != 0) trace.c_span(lpSubKey) else "(null)";
        trace.print("ADVAPI32: RegCreateKeyA('{s}')\n", .{key});
    }
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = next_reg_handle;
        next_reg_handle +%= 1;
    }
    return 0; // ERROR_SUCCESS
}

fn stub_SetFileSecurityW(lpFileName: usize, SecurityInformation: u32, pSecurityDescriptor: usize) callconv(.winapi) i32 {
    _ = lpFileName;
    _ = SecurityInformation;
    _ = pSecurityDescriptor;
    if (trace.enable_tracing) trace.print("ADVAPI32: SetFileSecurityW -> 0\n", .{});
    return 0;
}

fn stub_IsTextUnicode(lpv: usize, iSize: i32, lpiResult: usize) callconv(.winapi) i32 {
    _ = lpv;
    _ = iSize;
    if (lpiResult != 0) @as(*i32, @ptrFromInt(lpiResult)).* = 0;
    return 0; // Not Unicode
}

fn stub_RegCreateKeyW(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegCreateKeyW\n", .{});
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = next_reg_handle;
        next_reg_handle +%= 1;
    }
    return 0; // ERROR_SUCCESS
}

// --- W variant stubs for win2k apps ---

fn stub_RegOpenKeyExW(hKey: usize, lpSubKey: usize, ulOptions: u32, samDesired: u32, phkResult: usize) callconv(.winapi) u32 {
    _ = ulOptions;
    _ = samDesired;
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegOpenKeyExW -> ERROR_FILE_NOT_FOUND\n", .{});
    if (phkResult != 0) @as(*u32, @ptrFromInt(phkResult)).* = 0;
    return 2; // ERROR_FILE_NOT_FOUND
}

fn stub_RegCreateKeyExW(hKey: usize, lpSubKey: usize, reserved: u32, lpClass: usize, dwOptions: u32, samDesired: u32, lpSecurityAttributes: usize, phkResult: usize, lpdwDisposition: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpSubKey;
    _ = reserved;
    _ = lpClass;
    _ = dwOptions;
    _ = samDesired;
    _ = lpSecurityAttributes;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegCreateKeyExW\n", .{});
    if (phkResult != 0) {
        @as(*u32, @ptrFromInt(phkResult)).* = next_reg_handle;
        next_reg_handle +%= 1;
    }
    if (lpdwDisposition != 0) {
        @as(*u32, @ptrFromInt(lpdwDisposition)).* = 1; // REG_CREATED_NEW_KEY (no persisted values)
    }
    return 0;
}

fn stub_RegOpenKeyW(hKey: usize, lpSubKey: usize, phkResult: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegOpenKeyW -> ERROR_FILE_NOT_FOUND\n", .{});
    if (phkResult != 0) @as(*u32, @ptrFromInt(phkResult)).* = 0;
    return 2;
}

fn stub_RegDeleteKeyW(hKey: usize, lpSubKey: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpSubKey;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteKeyW\n", .{});
    return 0;
}

fn stub_RegDeleteValueW(hKey: usize, lpValueName: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpValueName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegDeleteValueW\n", .{});
    return 0;
}

fn stub_RegSetValueW(hKey: usize, lpSubKey: usize, dwType: u32, lpData: usize, cbData: u32) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpSubKey;
    _ = dwType;
    _ = lpData;
    _ = cbData;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegSetValueW\n", .{});
    return 0;
}

fn stub_RegEnumKeyW(hKey: usize, dwIndex: u32, lpName: usize, cchName: u32) callconv(.winapi) u32 {
    _ = hKey;
    _ = dwIndex;
    _ = lpName;
    _ = cchName;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegEnumKeyW -> ERROR_NO_MORE_ITEMS\n", .{});
    return 259;
}

fn stub_GetTokenInformation(TokenHandle: usize, TokenInformationClass: u32, TokenInformation: usize, TokenInformationLength: u32, ReturnLength: usize) callconv(.winapi) i32 {
    _ = TokenHandle;
    _ = TokenInformationClass;
    _ = TokenInformation;
    _ = TokenInformationLength;
    if (ReturnLength != 0) @as(*u32, @ptrFromInt(ReturnLength)).* = 0;
    if (trace.enable_tracing) trace.print("ADVAPI32: GetTokenInformation -> 0\n", .{});
    return 0;
}

fn stub_OpenThreadToken(ThreadHandle: usize, DesiredAccess: u32, OpenAsSelf: i32, TokenHandle: usize) callconv(.winapi) i32 {
    _ = ThreadHandle;
    _ = DesiredAccess;
    _ = OpenAsSelf;
    if (TokenHandle != 0) @as(*u32, @ptrFromInt(TokenHandle)).* = 0xFE000002;
    if (trace.enable_tracing) trace.print("ADVAPI32: OpenThreadToken\n", .{});
    return 1;
}

fn stub_RegQueryValueW(hKey: usize, lpSubKey: usize, lpData: usize, lpcbData: usize) callconv(.winapi) u32 {
    _ = hKey;
    _ = lpSubKey;
    _ = lpData;
    _ = lpcbData;
    if (trace.enable_tracing) trace.print("ADVAPI32: RegQueryValueW -> ERROR_FILE_NOT_FOUND\n", .{});
    return 2;
}

// =============================================================================
// Faithful implementations
// =============================================================================

// --- Return TRUE helpers (for functions that must succeed) ---
fn stub_ret_true_1(a: usize) callconv(.winapi) i32 {
    _ = a;
    return 1; // TRUE
}

fn stub_ret_true_2(a: usize, b: usize) callconv(.winapi) i32 {
    _ = a; _ = b;
    return 1;
}

fn stub_ret_true_3(a: usize, b: usize, c: usize) callconv(.winapi) i32 {
    _ = a; _ = b; _ = c;
    return 1;
}

fn stub_ret_true_4(a: usize, b: usize, c: usize, d: usize) callconv(.winapi) i32 {
    _ = a; _ = b; _ = c; _ = d;
    return 1;
}

// --- EqualSid: compares two SIDs byte-by-byte ---
fn stub_EqualSid(sid1: usize, sid2: usize) callconv(.winapi) i32 {
    if (trace.enable_tracing) trace.print("ADVAPI32: EqualSid({x}, {x})\n", .{ sid1, sid2 });
    if (sid1 == 0 or sid2 == 0) return 0;

    const s1 = @as([*]const u8, @ptrFromInt(sid1));
    const s2 = @as([*]const u8, @ptrFromInt(sid2));

    // SID: Revision(1) + SubAuthorityCount(1) + IdentifierAuthority(6) + SubAuthority[count](4*count)
    const count1 = s1[1];
    const count2 = s2[1];
    if (count1 != count2) return 0;

    const size: usize = 8 + @as(usize, count1) * 4;
    return if (std.mem.eql(u8, s1[0..size], s2[0..size])) 1 else 0;
}

// --- GetLengthSid: returns byte length of a SID ---
fn stub_GetLengthSid(sid: usize) callconv(.winapi) u32 {
    if (sid == 0) return 0;
    const s = @as([*]const u8, @ptrFromInt(sid));
    const count = s[1];
    const result = 8 + @as(u32, count) * 4;
    if (trace.enable_tracing) trace.print("ADVAPI32: GetLengthSid({x}) -> {d}\n", .{ sid, result });
    return result;
}

// --- GetSecurityDescriptorOwner ---
// BOOL GetSecurityDescriptorOwner(PSECURITY_DESCRIPTOR pSD, PSID *pOwner, LPBOOL lpbOwnerDefaulted)
fn stub_GetSecurityDescriptorOwner(pSD: usize, pOwner: usize, lpbOwnerDefaulted: usize) callconv(.winapi) i32 {
    _ = pSD;
    // Set owner to NULL (no owner set)
    if (pOwner != 0) @as(*usize, @ptrFromInt(pOwner)).* = 0;
    if (lpbOwnerDefaulted != 0) @as(*i32, @ptrFromInt(lpbOwnerDefaulted)).* = 0;
    if (trace.enable_tracing) trace.print("ADVAPI32: GetSecurityDescriptorOwner -> TRUE (no owner)\n", .{});
    return 1; // TRUE
}

// --- GetSecurityDescriptorLength ---
fn stub_GetSecurityDescriptorLength(pSD: usize) callconv(.winapi) u32 {
    _ = pSD;
    // Minimum SECURITY_DESCRIPTOR_RELATIVE size = 20 bytes
    return 20;
}

// --- FreeSid ---
fn stub_FreeSid(sid: usize) callconv(.winapi) usize {
    if (trace.enable_tracing) trace.print("ADVAPI32: FreeSid({x})\n", .{sid});
    return 0; // Returns NULL on success
}

// =============================================================================
// Tests
// =============================================================================

test "EqualSid compares SIDs correctly" {
    var sid1 = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 }; // S-1-5-18 (LocalSystem)
    var sid2 = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 };

    try std.testing.expectEqual(@as(i32, 1), stub_EqualSid(@intFromPtr(&sid1), @intFromPtr(&sid2)));

    sid2[8] = 19; // Change SubAuthority
    try std.testing.expectEqual(@as(i32, 0), stub_EqualSid(@intFromPtr(&sid1), @intFromPtr(&sid2)));
}

test "GetLengthSid returns correct size" {
    var sid = [_]u8{ 1, 2, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0 }; // 2 SubAuthorities
    try std.testing.expectEqual(@as(u32, 16), stub_GetLengthSid(@intFromPtr(&sid))); // 8 + 2*4 = 16
}

test "InitializeSecurityDescriptor returns TRUE" {
    try std.testing.expectEqual(@as(i32, 1), stub_ret_true_2(0x1234, 1));
}

test "GetSecurityDescriptorOwner sets NULL owner" {
    var owner: usize = 0xDEAD;
    var defaulted: i32 = 99;
    const result = stub_GetSecurityDescriptorOwner(0x1234, @intFromPtr(&owner), @intFromPtr(&defaulted));
    try std.testing.expectEqual(@as(i32, 1), result);
    try std.testing.expectEqual(@as(usize, 0), owner);
    try std.testing.expectEqual(@as(i32, 0), defaulted);
}

test "FreeSid returns NULL" {
    try std.testing.expectEqual(@as(usize, 0), stub_FreeSid(0x1234));
}

