const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

/// OpenProcessToken
/// Implementation status: Partially implemented
pub fn OpenProcessToken(ProcessHandle: usize, DesiredAccess: u32, TokenHandle: usize) callconv(w32cc.WINAPI) i32 {
    _ = ProcessHandle;
    _ = DesiredAccess;
    if (TokenHandle != 0) {
        @as(*u32, @ptrFromInt(TokenHandle)).* = 0xFE000001; // fake token handle
    }
    if (trace.enable_tracing) trace.print("ADVAPI32: OpenProcessToken\n", .{});
    return 1;
}

/// AdjustTokenPrivileges
/// Implementation status: Partially implemented
pub fn AdjustTokenPrivileges(TokenHandle: usize, DisableAllPrivileges: i32, NewState: usize, BufferLength: u32, PreviousState: usize, ReturnLength: usize) callconv(w32cc.WINAPI) i32 {
    _ = TokenHandle;
    _ = DisableAllPrivileges;
    _ = NewState;
    _ = BufferLength;
    _ = PreviousState;
    _ = ReturnLength;
    if (trace.enable_tracing) trace.print("ADVAPI32: AdjustTokenPrivileges\n", .{});
    return 1;
}

/// stub_LookupPrivilegeValueW
/// Implementation status: Stub
pub fn stub_LookupPrivilegeValueW(lpSystemName: usize, lpName: usize, lpLuid: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpSystemName;
    _ = lpName;
    _ = lpLuid;
    if (trace.enable_tracing) trace.print("ADVAPI32: LookupPrivilegeValueW -> 0\n", .{});
    return 0;
}

/// stub_GetTokenInformation
/// Implementation status: Stub
pub fn stub_GetTokenInformation(TokenHandle: usize, TokenInformationClass: u32, TokenInformation: usize, TokenInformationLength: u32, ReturnLength: usize) callconv(w32cc.WINAPI) i32 {
    _ = TokenHandle;
    _ = TokenInformationClass;
    _ = TokenInformation;
    _ = TokenInformationLength;
    if (ReturnLength != 0) @as(*u32, @ptrFromInt(ReturnLength)).* = 0;
    if (trace.enable_tracing) trace.print("ADVAPI32: GetTokenInformation -> 0\n", .{});
    return 0;
}

/// stub_OpenThreadToken
/// Implementation status: No-op fallback
pub fn stub_OpenThreadToken(ThreadHandle: usize, DesiredAccess: u32, OpenAsSelf: i32, TokenHandle: usize) callconv(w32cc.WINAPI) i32 {
    _ = ThreadHandle;
    _ = DesiredAccess;
    _ = OpenAsSelf;
    if (TokenHandle != 0) @as(*u32, @ptrFromInt(TokenHandle)).* = 0xFE000002;
    if (trace.enable_tracing) trace.print("ADVAPI32: OpenThreadToken\n", .{});
    return 1;
}

/// GetFileSecurityW
/// Implementation status: Partially implemented
pub fn GetFileSecurityW(lpFileName: usize, RequestedInformation: u32, pSecurityDescriptor: usize, nLength: u32, lpnLengthNeeded: usize) callconv(w32cc.WINAPI) i32 {
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

/// stub_SetFileSecurityW
/// Implementation status: Stub
pub fn stub_SetFileSecurityW(lpFileName: usize, SecurityInformation: u32, pSecurityDescriptor: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpFileName;
    _ = SecurityInformation;
    _ = pSecurityDescriptor;
    if (trace.enable_tracing) trace.print("ADVAPI32: SetFileSecurityW -> 0\n", .{});
    return 0;
}

/// stub_IsTextUnicode
/// Implementation status: Stub
pub fn stub_IsTextUnicode(lpv: usize, iSize: i32, lpiResult: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpv;
    _ = iSize;
    if (lpiResult != 0) @as(*i32, @ptrFromInt(lpiResult)).* = 0;
    return 0; // Not Unicode
}

/// --- EqualSid: compares two SIDs byte-by-byte ---
/// Implementation status: Partially implemented
pub fn EqualSid(sid1: usize, sid2: usize) callconv(w32cc.WINAPI) i32 {
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

/// --- GetLengthSid: returns byte length of a SID ---
/// Implementation status: Partially implemented
pub fn GetLengthSid(sid: usize) callconv(w32cc.WINAPI) u32 {
    if (sid == 0) return 0;
    const s = @as([*]const u8, @ptrFromInt(sid));
    const count = s[1];
    const result = 8 + @as(u32, count) * 4;
    if (trace.enable_tracing) trace.print("ADVAPI32: GetLengthSid({x}) -> {d}\n", .{ sid, result });
    return result;
}

/// --- GetSecurityDescriptorOwner ---
/// BOOL GetSecurityDescriptorOwner(PSECURITY_DESCRIPTOR pSD, PSID *pOwner, LPBOOL lpbOwnerDefaulted)
/// Implementation status: Partially implemented
pub fn GetSecurityDescriptorOwner(pSD: usize, pOwner: usize, lpbOwnerDefaulted: usize) callconv(w32cc.WINAPI) i32 {
    _ = pSD;
    // Set owner to NULL (no owner set)
    if (pOwner != 0) @as(*usize, @ptrFromInt(pOwner)).* = 0;
    if (lpbOwnerDefaulted != 0) @as(*i32, @ptrFromInt(lpbOwnerDefaulted)).* = 0;
    if (trace.enable_tracing) trace.print("ADVAPI32: GetSecurityDescriptorOwner -> TRUE (no owner)\n", .{});
    return 1; // TRUE
}

/// --- GetSecurityDescriptorLength ---
/// Implementation status: Partially implemented
pub fn GetSecurityDescriptorLength(pSD: usize) callconv(w32cc.WINAPI) u32 {
    _ = pSD;
    // Minimum SECURITY_DESCRIPTOR_RELATIVE size = 20 bytes
    return 20;
}

/// --- FreeSid ---
/// Implementation status: Partially implemented
pub fn FreeSid(sid: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("ADVAPI32: FreeSid({x})\n", .{sid});
    return 0; // Returns NULL on success
}

// =============================================================================
// Tests
// =============================================================================

test "EqualSid compares SIDs correctly" {
    var sid1 = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 }; // S-1-5-18 (LocalSystem)
    var sid2 = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 };

    try std.testing.expectEqual(@as(i32, 1), EqualSid(@intFromPtr(&sid1), @intFromPtr(&sid2)));

    sid2[8] = 19; // Change SubAuthority
    try std.testing.expectEqual(@as(i32, 0), EqualSid(@intFromPtr(&sid1), @intFromPtr(&sid2)));
}

test "GetLengthSid returns correct size" {
    var sid = [_]u8{ 1, 2, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0 }; // 2 SubAuthorities
    try std.testing.expectEqual(@as(u32, 16), GetLengthSid(@intFromPtr(&sid))); // 8 + 2*4 = 16
}

test "GetSecurityDescriptorOwner sets NULL owner" {
    var owner: usize = 0xDEAD;
    var defaulted: i32 = 99;
    const result = GetSecurityDescriptorOwner(0x1234, @intFromPtr(&owner), @intFromPtr(&defaulted));
    try std.testing.expectEqual(@as(i32, 1), result);
    try std.testing.expectEqual(@as(usize, 0), owner);
    try std.testing.expectEqual(@as(i32, 0), defaulted);
}

var sid_storage: [48]u8 align(4) = [_]u8{0} ** 48;

/// SID structure: revision(1) + subAuthorityCount(1) + identifierAuthority(6) + subAuthority[8](32)
/// Implementation status: Stub
pub fn stub_AllocateAndInitializeSid(
    pIdentifierAuthority: usize,
    nSubAuthorityCount: u8,
    sa0: u32,
    sa1: u32,
    sa2: u32,
    sa3: u32,
    sa4: u32,
    sa5: u32,
    sa6: u32,
    sa7: u32,
    pSid: usize,
) callconv(w32cc.WINAPI) i32 {
    // Build a real SID in static storage
    const count = @min(nSubAuthorityCount, 8);
    sid_storage[0] = 1; // Revision
    sid_storage[1] = count;
    // Copy identifier authority (6 bytes)
    if (pIdentifierAuthority != 0) {
        const auth = @as([*]const u8, @ptrFromInt(pIdentifierAuthority));
        @memcpy(sid_storage[2..8], auth[0..6]);
    }
    // Copy sub-authorities
    const subs = [_]u32{ sa0, sa1, sa2, sa3, sa4, sa5, sa6, sa7 };
    for (0..count) |i| {
        const off = 8 + i * 4;
        @as(*align(1) u32, @ptrCast(sid_storage[off..].ptr)).* = subs[i];
    }
    if (pSid != 0) {
        @as(*usize, @ptrFromInt(pSid)).* = @intFromPtr(&sid_storage);
    }
    return 1; // TRUE
}

test "FreeSid returns NULL" {
    try std.testing.expectEqual(@as(usize, 0), FreeSid(0x1234));
}
