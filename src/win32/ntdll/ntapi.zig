const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const platform = @import("../../platform.zig");
const mem_alloc = @import("../kernel32/mem.zig");

/// NTDLL stub implementations — NT Native API and CRT intrinsics.
/// Contains: NtQuerySystemInformation, RtlInitUnicodeString, SID functions,
/// _chkstk/_allmul/_alldiv (x86 inline asm), string helpers, RtlUnwind.
/// =============================================================================
/// Simple stubs
/// =============================================================================
/// Implementation status: Stub
pub fn stub_RtlFreeAnsiString(ansiString: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("NTDLL: RtlFreeAnsiString({x})\n", .{ansiString});
}

/// stub_RtlUnicodeStringToAnsiString
/// Implementation status: Stub
pub fn stub_RtlUnicodeStringToAnsiString(destinationString: usize, sourceString: usize, allocateDestinationString: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("NTDLL: RtlUnicodeStringToAnsiString({x}, {x}, {d})\n", .{ destinationString, sourceString, allocateDestinationString });
    return 0; // STATUS_SUCCESS
}

/// stub_RtlTimeToElapsedTimeFields
/// Implementation status: Stub
pub fn stub_RtlTimeToElapsedTimeFields(time: usize, timeFields: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("NTDLL: RtlTimeToElapsedTimeFields({x}, {x})\n", .{ time, timeFields });
}

/// stub_NtClose
/// Implementation status: Stub
pub fn stub_NtClose(handle: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("NTDLL: NtClose({x})\n", .{handle});
    return 0; // STATUS_SUCCESS
}

/// stub_RtlFreeSid
/// Implementation status: Stub
pub fn stub_RtlFreeSid(sid: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("NTDLL: RtlFreeSid({x})\n", .{sid});
    return 0;
}

/// stub_RtlUnwind
/// Implementation status: No-op fallback
pub fn stub_RtlUnwind(targetFrame: usize, targetIp: usize, exceptionRecord: usize, returnValue: usize) callconv(w32cc.WINAPI) void {
    _ = targetFrame;
    _ = targetIp;
    _ = exceptionRecord;
    _ = returnValue;
    if (trace.enable_tracing) trace.print("NTDLL: RtlUnwind (no-op)\n", .{});
}

/// =============================================================================
/// NtQuerySystemInformation
/// =============================================================================
/// Implementation status: Partially implemented
pub fn NtQuerySystemInformation(systemInformationClass: u32, systemInformation: usize, systemInformationLength: u32, returnLength: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("NTDLL: NtQuerySystemInformation(class={d}, info={x}, len={d}, ret_len={x})\n", .{ systemInformationClass, systemInformation, systemInformationLength, returnLength });
    if (systemInformationClass == 0) { // SystemBasicInformation
        if (systemInformationLength >= 44) {
            const info = @as(*w32.SYSTEM_BASIC_INFORMATION, @ptrFromInt(systemInformation));
            info.* = .{
                .PageSize = 4096,
                .NumberOfPhysicalPages = 1024 * 1024,
                .AllocationGranularity = 65536,
                .MinimumUserModeAddress = 0x10000,
                .MaximumUserModeAddress = 0x7FFEFFFF,
                .ActiveProcessorsAffinityMask = 1,
                .NumberOfProcessors = 1,
            };
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 44;
            }
            return 0;
        }
    } else if (systemInformationClass == 2) { // SystemPerformanceInformation
        if (systemInformationLength >= 312) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..312], 0);
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 312;
            }
            return 0;
        }
    } else if (systemInformationClass == 3) { // SystemTimeOfDayInformation
        if (systemInformationLength >= 32) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..32], 0);
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 32;
            }
            return 0;
        }
    } else if (systemInformationClass == 5) { // SystemProcessInformation
        if (systemInformationLength >= 136) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..136], 0);
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 136;
            }
            return 0;
        }
    } else if (systemInformationClass == 8) { // SystemProcessorPerformanceInformation
        const entry_size: u32 = 48;
        const num_cpus: u32 = 1;
        const total = entry_size * num_cpus;
        if (systemInformationLength >= total) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..total], 0);
            const qwords = @as([*]align(1) u64, @ptrCast(info));
            qwords[0] = 100000000; // IdleTime
            qwords[1] = 200000000; // KernelTime
            qwords[2] = 150000000; // UserTime
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = total;
            }
            return 0;
        }
    } else if (systemInformationClass == 11) { // SystemModuleInformation
        if (systemInformationLength >= 4) {
            const info = @as([*]u32, @ptrFromInt(systemInformation));
            info[0] = 0;
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 4;
            }
            return 0;
        }
    } else if (systemInformationClass == 18) { // SystemPageFileInformation
        if (systemInformationLength >= 32) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..32], 0);
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 32;
            }
            return 0;
        }
    } else if (systemInformationClass == 21) { // SystemFileCacheInformation
        if (systemInformationLength >= 36) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..36], 0);
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 36;
            }
            return 0;
        }
    }
    return 0xC0000002; // STATUS_NOT_IMPLEMENTED
}

/// =============================================================================
/// VerSetConditionMask
/// =============================================================================
/// Implementation status: Partially implemented
pub fn VerSetConditionMask(mask_lo: u32, mask_hi: u32, typeMask: u32, condition: u8) callconv(w32cc.WINAPI) u64 {
    _ = mask_hi;
    if (trace.enable_tracing) trace.print("NTDLL: VerSetConditionMask(mask=0x{x}, type=0x{x}, cond={d})\n", .{ mask_lo, typeMask, condition });
    if (typeMask == 0 or condition == 0) return mask_lo;

    var mask: u64 = mask_lo;
    const cond3: u64 = @as(u64, condition & 0x07);

    if (typeMask & 0x0000002 != 0) mask |= cond3 << 0; // VER_MINORVERSION
    if (typeMask & 0x0000001 != 0) mask |= cond3 << 3; // VER_MAJORVERSION
    if (typeMask & 0x0000004 != 0) mask |= cond3 << 6; // VER_BUILDNUMBER
    if (typeMask & 0x0000008 != 0) mask |= cond3 << 9; // VER_PLATFORMID
    if (typeMask & 0x0000010 != 0) mask |= cond3 << 12; // VER_SERVICEPACKMINOR
    if (typeMask & 0x0000020 != 0) mask |= cond3 << 15; // VER_SERVICEPACKMAJOR
    if (typeMask & 0x0000040 != 0) mask |= cond3 << 18; // VER_SUITENAME
    if (typeMask & 0x0000080 != 0) mask |= cond3 << 21; // VER_PRODUCT_TYPE

    return mask;
}

/// =============================================================================
/// Unicode strings
/// =============================================================================
/// Implementation status: Partially implemented
pub fn RtlInitUnicodeString(dest: usize, source: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("NTDLL: RtlInitUnicodeString(dest={x}, source={x})\n", .{ dest, source });
    if (dest == 0) return;

    const us = @as(*w32.UNICODE_STRING, @ptrFromInt(dest));

    if (source == 0) {
        us.* = .{};
        return;
    }

    const wstr = @as([*]const u16, @ptrFromInt(source));
    var len: u16 = 0;
    while (wstr[len] != 0 and len < 32767) : (len += 1) {}

    const byte_len = len * 2;
    us.Length = byte_len;
    us.MaximumLength = byte_len + 2;
    us.Buffer = @intCast(source);
}

/// =============================================================================
/// SID functions
/// =============================================================================
/// Implementation status: Partially implemented
pub fn RtlAllocateAndInitializeSid(
    identAuth: usize,
    subAuthCount: u8,
    sa0: u32,
    sa1: u32,
    sa2: u32,
    sa3: u32,
    sa4: u32,
    sa5: u32,
    sa6: u32,
    sa7: u32,
) callconv(w32cc.WINAPI) u32 {
    _ = sa4;
    _ = sa5;
    _ = sa6;
    _ = sa7;
    if (trace.enable_tracing) trace.print("NTDLL: RtlAllocateAndInitializeSid(count={d})\n", .{subAuthCount});

    const count = @min(subAuthCount, 8);
    const sid_size: usize = 8 + @as(usize, count) * 4;
    const sid_ptr = mem_alloc.raw_alloc(sid_size) orelse return 0xC0000017;

    const sid = @as([*]u8, @ptrCast(sid_ptr));
    sid[0] = 1; // Revision
    sid[1] = count;

    if (identAuth != 0) {
        const auth = @as([*]const u8, @ptrFromInt(identAuth));
        @memcpy(sid[2..8], auth[0..6]);
    } else {
        @memset(sid[2..8], 0);
    }

    const sub_auths = @as([*]align(1) u32, @ptrCast(@alignCast(sid + 8)));
    if (count > 0) sub_auths[0] = sa0;
    if (count > 1) sub_auths[1] = sa1;
    if (count > 2) sub_auths[2] = sa2;
    if (count > 3) sub_auths[3] = sa3;

    return 0; // STATUS_SUCCESS
}

/// Implementation status: Partially implemented
pub fn RtlEqualSid(sid1: usize, sid2: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("NTDLL: RtlEqualSid({x}, {x})\n", .{ sid1, sid2 });
    if (sid1 == 0 or sid2 == 0) return 0;

    const s1 = @as([*]const u8, @ptrFromInt(sid1));
    const s2 = @as([*]const u8, @ptrFromInt(sid2));
    const count1 = s1[1];
    const count2 = s2[1];
    if (count1 != count2) return 0;

    const size: usize = 8 + @as(usize, count1) * 4;
    const equal = std.mem.eql(u8, s1[0..size], s2[0..size]);
    return if (equal) 1 else 0;
}

// =============================================================================
// x86 CRT intrinsics (_chkstk, _allmul, _alldiv)
// =============================================================================

pub const stub_chkstk = if (platform.is_x86)
    &chkstk_x86
else
    &chkstk_generic;

fn chkstk_x86() callconv(.naked) void {
    asm volatile (
        \\  push %%ecx
        \\  lea 8(%%esp), %%ecx
        \\  cmp $0x1000, %%eax
        \\  jb 2f
        \\1:
        \\  sub $0x1000, %%ecx
        \\  testl %%ecx, (%%ecx)
        \\  sub $0x1000, %%eax
        \\  cmp $0x1000, %%eax
        \\  ja 1b
        \\2:
        \\  sub %%eax, %%ecx
        \\  testl %%ecx, (%%ecx)
        \\  pop %%ecx
        \\  ret
    );
}

fn chkstk_generic() callconv(w32cc.WINAPI) void {}

pub const stub_allmul = if (platform.is_x86)
    &allmul_x86
else
    &allmul_generic;

fn allmul_x86() callconv(.naked) void {
    asm volatile (
        \\  mov 8(%%esp), %%ecx
        \\  mov 16(%%esp), %%eax
        \\  or %%ecx, %%eax
        \\  mov 12(%%esp), %%ecx
        \\  jnz 1f
        \\  mov 4(%%esp), %%eax
        \\  mull %%ecx
        \\  ret $16
        \\1:
        \\  push %%ebx
        \\  mull 4+4(%%esp)
        \\  mov %%eax, %%ebx
        \\  mov 8+4(%%esp), %%eax
        \\  mull %%ecx
        \\  add %%eax, %%ebx
        \\  mov 4+4(%%esp), %%eax
        \\  mull %%ecx
        \\  add %%ebx, %%edx
        \\  pop %%ebx
        \\  ret $16
    );
}

fn allmul_generic() callconv(w32cc.WINAPI) usize {
    return 0;
}

pub const stub_alldiv = if (platform.is_x86)
    &alldiv_x86
else
    &alldiv_generic;

fn alldiv_x86() callconv(.naked) void {
    asm volatile (
        \\  push %%esi
        \\  push %%edi
        \\  mov 12(%%esp), %%eax
        \\  mov 16(%%esp), %%edx
        \\  mov %%edx, %%esi
        \\  test %%edx, %%edx
        \\  jns 1f
        \\  neg %%edx
        \\  neg %%eax
        \\  sbb $0, %%edx
        \\1:
        \\  push %%edx
        \\  push %%eax
        \\  mov 28(%%esp), %%eax
        \\  mov 32(%%esp), %%edx
        \\  xor %%edx, %%esi
        \\  mov %%esi, %%edi
        \\  test %%edx, %%edx
        \\  jns 2f
        \\  neg %%edx
        \\  neg %%eax
        \\  sbb $0, %%edx
        \\2:
        \\  mov %%edx, %%ecx
        \\  mov %%eax, %%esi
        \\  test %%ecx, %%ecx
        \\  jnz 3f
        \\  pop %%eax
        \\  pop %%edx
        \\  divl %%esi
        \\  mov %%eax, %%esi
        \\  xor %%edx, %%edx
        \\  mov %%esi, %%eax
        \\  jmp 4f
        \\3:
        \\  pop %%eax
        \\  pop %%eax
        \\  xor %%edx, %%edx
        \\  divl %%ecx
        \\  xor %%edx, %%edx
        \\4:
        \\  test %%edi, %%edi
        \\  jns 5f
        \\  neg %%edx
        \\  neg %%eax
        \\  sbb $0, %%edx
        \\5:
        \\  pop %%edi
        \\  pop %%esi
        \\  ret $16
    );
}

fn alldiv_generic() callconv(w32cc.WINAPI) usize {
    return 0;
}

/// =============================================================================
/// String/memory helpers (exported from NTDLL)
/// =============================================================================
/// Implementation status: Partially implemented
pub fn strrchr(str_ptr: usize, c: i32) callconv(w32cc.WINAPI) usize {
    if (str_ptr == 0) return 0;
    const s = @as([*]const u8, @ptrFromInt(str_ptr));
    const ch: u8 = @truncate(@as(u32, @bitCast(c)));
    var last: usize = 0;
    var i: usize = 0;
    while (true) {
        if (s[i] == ch) last = str_ptr + i;
        if (s[i] == 0) break;
        i += 1;
    }
    return last;
}

/// wcsicmp
/// Implementation status: Partially implemented
pub fn wcsicmp(s1_ptr: usize, s2_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (s1_ptr == 0 or s2_ptr == 0) return 0;
    const s1 = @as([*]const u16, @ptrFromInt(s1_ptr));
    const s2 = @as([*]const u16, @ptrFromInt(s2_ptr));
    var i: usize = 0;
    while (true) {
        const c1 = toLowerW(s1[i]);
        const c2 = toLowerW(s2[i]);
        if (c1 != c2) return @as(i32, @intCast(c1)) - @as(i32, @intCast(c2));
        if (c1 == 0) return 0;
        i += 1;
    }
}

fn toLowerW(c: u16) u16 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// memmove
/// Implementation status: Partially implemented
pub fn memmove(dest_ptr: usize, src_ptr: usize, count: usize) callconv(w32cc.WINAPI) usize {
    if (dest_ptr == 0 or src_ptr == 0 or count == 0) return dest_ptr;
    const dst = @as([*]u8, @ptrFromInt(dest_ptr));
    const src = @as([*]const u8, @ptrFromInt(src_ptr));
    if (dest_ptr < src_ptr or dest_ptr >= src_ptr + count) {
        for (0..count) |i| {
            dst[i] = src[i];
        }
    } else {
        var i = count;
        while (i > 0) {
            i -= 1;
            dst[i] = src[i];
        }
    }
    return dest_ptr;
}

// =============================================================================
// Tests
// =============================================================================

test "VerSetConditionMask builds correct mask" {
    const mask1 = VerSetConditionMask(0, 0, 0x01, 3);
    try std.testing.expect(mask1 == (3 << 3));

    const mask2 = VerSetConditionMask(@intCast(mask1 & 0xFFFFFFFF), 0, 0x02, 1);
    try std.testing.expect(mask2 == (3 << 3) | (1 << 0));
}

// UNICODE_STRING is 8 bytes with a 32-bit Buffer on every host, so the
// destination is decoded by offset rather than through the struct type.
fn usLength(buf: *const [8]u8) u16 {
    return @as(*align(1) const u16, @ptrCast(&buf[0])).*;
}
fn usMaxLength(buf: *const [8]u8) u16 {
    return @as(*align(1) const u16, @ptrCast(&buf[2])).*;
}
fn usBuffer(buf: *const [8]u8) u32 {
    return @as(*align(1) const u32, @ptrCast(&buf[4])).*;
}

// RtlInitUnicodeString stores `source` into a 32-bit Buffer field, so a test
// can only supply a source whose address fits 32 bits. A stack address on a
// 64-bit host does not, and guest-low memory cannot be mapped from a test.
const needs_32bit_address = @import("builtin").target.cpu.arch != .x86;

test "RtlInitUnicodeString fills struct correctly" {
    if (needs_32bit_address) return error.SkipZigTest;

    var wstr = [_]u16{ 'H', 'i', 0 };
    var buf: [8]u8 align(4) = undefined;
    @memset(&buf, 0xFF);

    RtlInitUnicodeString(@intFromPtr(&buf), @intFromPtr(&wstr));

    try std.testing.expectEqual(@as(u16, 4), usLength(&buf)); // 2 chars * 2 bytes
    try std.testing.expectEqual(@as(u16, 6), usMaxLength(&buf)); // length + null terminator
    try std.testing.expectEqual(@as(u32, @intCast(@intFromPtr(&wstr))), usBuffer(&buf));
}

test "RtlInitUnicodeString with null source" {
    if (needs_32bit_address) return error.SkipZigTest;

    var buf: [8]u8 align(4) = undefined;
    @memset(&buf, 0xFF);

    RtlInitUnicodeString(@intFromPtr(&buf), 0);

    try std.testing.expectEqual(@as(u16, 0), usLength(&buf));
    try std.testing.expectEqual(@as(u16, 0), usMaxLength(&buf));
    try std.testing.expectEqual(@as(u32, 0), usBuffer(&buf));
}

test "RtlInitUnicodeString with null destination writes nothing" {
    // Guest code can pass a null PUNICODE_STRING. The stub must return
    // before touching either pointer, so this holds on every host.
    var wstr = [_]u16{ 'H', 'i', 0 };

    RtlInitUnicodeString(0, @intFromPtr(&wstr));

    try std.testing.expectEqualSlices(u16, &.{ 'H', 'i', 0 }, &wstr);
}

test "RtlEqualSid compares correctly" {
    var sid1 = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 };
    var sid2 = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 };

    try std.testing.expectEqual(@as(i32, 1), RtlEqualSid(@intFromPtr(&sid1), @intFromPtr(&sid2)));

    sid2[8] = 19;
    try std.testing.expectEqual(@as(i32, 0), RtlEqualSid(@intFromPtr(&sid1), @intFromPtr(&sid2)));
}

test "NtClose returns STATUS_SUCCESS" {
    try std.testing.expectEqual(@as(u32, 0), stub_NtClose(0x1234));
}
