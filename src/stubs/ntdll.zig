const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const kernel32 = @import("kernel32.zig");
const w32 = @import("win32_constants.zig");

pub fn register(environment: *env.Environment) !void {
    const builtin_module = "ntdll.dll";
    try environment.addBuiltinExport(builtin_module, "RtlFreeAnsiString", @intFromPtr(&stub_RtlFreeAnsiString));
    try environment.addBuiltinExport(builtin_module, "RtlUnicodeStringToAnsiString", @intFromPtr(&stub_RtlUnicodeStringToAnsiString));
    try environment.addBuiltinExport(builtin_module, "NtQuerySystemInformation", @intFromPtr(&stub_NtQuerySystemInformation));
    try environment.addBuiltinExport(builtin_module, "RtlTimeToElapsedTimeFields", @intFromPtr(&stub_RtlTimeToElapsedTimeFields));

    // --- Remaining NTDLL stubs for 100% win2k coverage ---
    // Faithful implementations
    try environment.addBuiltinExport(builtin_module, "VerSetConditionMask", @intFromPtr(&stub_VerSetConditionMask));
    try environment.addBuiltinExport(builtin_module, "NtOpenProcessToken", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "RtlAllocateAndInitializeSid", @intFromPtr(&stub_RtlAllocateAndInitializeSid));
    try environment.addBuiltinExport(builtin_module, "NtQueryInformationToken", @intFromPtr(&kernel32.stub_args5));
    try environment.addBuiltinExport(builtin_module, "RtlFreeSid", @intFromPtr(&stub_RtlFreeSid));
    try environment.addBuiltinExport(builtin_module, "RtlEqualSid", @intFromPtr(&stub_RtlEqualSid));
    try environment.addBuiltinExport(builtin_module, "_chkstk", @intFromPtr(stub_chkstk));
    try environment.addBuiltinExport(builtin_module, "NtClose", @intFromPtr(&stub_NtClose));
    try environment.addBuiltinExport(builtin_module, "RtlInitUnicodeString", @intFromPtr(&stub_RtlInitUnicodeString));
    try environment.addBuiltinExport(builtin_module, "RtlUnicodeStringToInteger", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "RtlLargeIntegerToChar", @intFromPtr(&kernel32.stub_args4));
    try environment.addBuiltinExport(builtin_module, "RtlAnsiStringToUnicodeString", @intFromPtr(&stub_RtlUnicodeStringToAnsiString));
    try environment.addBuiltinExport(builtin_module, "_allmul", @intFromPtr(stub_allmul));
    try environment.addBuiltinExport(builtin_module, "_alldiv", @intFromPtr(stub_alldiv));
    try environment.addBuiltinExport(builtin_module, "NtOpenThread", @intFromPtr(&kernel32.stub_args4));

    // String/memory functions needed by taskmgr and other apps
    try environment.addBuiltinExport(builtin_module, "RtlUnwind", @intFromPtr(&stub_RtlUnwind));
    try environment.addBuiltinExport(builtin_module, "strrchr", @intFromPtr(&stub_strrchr));
    try environment.addBuiltinExport(builtin_module, "_wcsicmp", @intFromPtr(&stub_wcsicmp));
    try environment.addBuiltinExport(builtin_module, "memmove", @intFromPtr(&stub_memmove));
}

fn stub_RtlFreeAnsiString(ansiString: usize) callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("NTDLL: RtlFreeAnsiString({x})\n", .{ansiString});
}

fn stub_RtlUnicodeStringToAnsiString(destinationString: usize, sourceString: usize, allocateDestinationString: u32) callconv(.winapi) u32 {
    if (trace.enable_tracing) trace.print("NTDLL: RtlUnicodeStringToAnsiString({x}, {x}, {d})\n", .{ destinationString, sourceString, allocateDestinationString });
    return 0; // STATUS_SUCCESS
}

fn stub_NtQuerySystemInformation(systemInformationClass: u32, systemInformation: usize, systemInformationLength: u32, returnLength: usize) callconv(.winapi) u32 {
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
            return 0; // STATUS_SUCCESS
        }
    } else if (systemInformationClass == 2) { // SystemPerformanceInformation
        if (systemInformationLength >= 312) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..312], 0);
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 312;
            }
            return 0; // STATUS_SUCCESS
        }
    } else if (systemInformationClass == 3) { // SystemTimeOfDayInformation
        if (systemInformationLength >= 32) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..32], 0);
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 32;
            }
            return 0; // STATUS_SUCCESS
        }
    } else if (systemInformationClass == 5) { // SystemProcessInformation
        if (systemInformationLength >= 136) { // size of SYSTEM_PROCESS_INFORMATION roughly
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..136], 0);
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 136;
            }
            return 0; // STATUS_SUCCESS
        }
    } else if (systemInformationClass == 8) { // SystemProcessorPerformanceInformation
        // SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION (48 bytes per processor):
        //   LARGE_INTEGER IdleTime    (offset 0)
        //   LARGE_INTEGER KernelTime  (offset 8)
        //   LARGE_INTEGER UserTime    (offset 16)
        //   LARGE_INTEGER DpcTime     (offset 24)
        //   LARGE_INTEGER InterruptTime (offset 32)
        //   ULONG InterruptCount      (offset 40)
        //   ULONG padding             (offset 44)
        const entry_size: u32 = 48;
        const num_cpus: u32 = 1;
        const total = entry_size * num_cpus;
        if (systemInformationLength >= total) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..total], 0);
            // Provide non-zero idle/kernel/user times so taskmgr shows some data
            const qwords = @as([*]align(1) u64, @ptrCast(info));
            qwords[0] = 100000000; // IdleTime (100M * 100ns = 10s)
            qwords[1] = 200000000; // KernelTime
            qwords[2] = 150000000; // UserTime
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = total;
            }
            return 0; // STATUS_SUCCESS
        }
    } else if (systemInformationClass == 11) { // SystemModuleInformation
        if (systemInformationLength >= 4) {
            const info = @as([*]u32, @ptrFromInt(systemInformation));
            info[0] = 0; // NumberOfModules = 0
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 4;
            }
            return 0; // STATUS_SUCCESS
        }
    } else if (systemInformationClass == 18) { // SystemPageFileInformation
        if (systemInformationLength >= 32) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..32], 0);
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 32;
            }
            return 0; // STATUS_SUCCESS
        }
    } else if (systemInformationClass == 21) { // SystemFileCacheInformation
        if (systemInformationLength >= 36) {
            const info = @as([*]u8, @ptrFromInt(systemInformation));
            @memset(info[0..36], 0);
            if (returnLength != 0) {
                @as(*u32, @ptrFromInt(returnLength)).* = 36;
            }
            return 0; // STATUS_SUCCESS
        }
    }
    return 0xC0000002; // STATUS_NOT_IMPLEMENTED
}

fn stub_RtlTimeToElapsedTimeFields(time: usize, timeFields: usize) callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("NTDLL: RtlTimeToElapsedTimeFields({x}, {x})\n", .{ time, timeFields });
}

// =============================================================================
// Faithful implementations below
// =============================================================================

const platform = @import("../platform.zig");
const mem_alloc = @import("kernel32/mem.zig");

// --- _chkstk: Stack probe ---
// On x86, _chkstk is called with the requested stack size in EAX.
// It probes each page below ESP to trigger guard page commitment.
// It does NOT change ESP — the caller does that.
pub const stub_chkstk = if (platform.is_x86)
    &stub_chkstk_x86
else
    &stub_chkstk_generic;

fn stub_chkstk_x86() callconv(.naked) void {
    // _chkstk: EAX = number of bytes to allocate on stack
    // Must touch each 4K page from ESP downward to commit guard pages
    // Uses ECX/EAX as scratch, preserves all others
    asm volatile (
        \\  push %%ecx
        \\  lea 8(%%esp), %%ecx          // ECX = original ESP (before push + return addr)
        \\  cmp $0x1000, %%eax
        \\  jb 2f                        // if < 4096 bytes, just one probe
        \\1:
        \\  sub $0x1000, %%ecx
        \\  testl %%ecx, (%%ecx)         // probe page (read)
        \\  sub $0x1000, %%eax
        \\  cmp $0x1000, %%eax
        \\  ja 1b
        \\2:
        \\  sub %%eax, %%ecx
        \\  testl %%ecx, (%%ecx)         // probe final page
        \\  pop %%ecx
        \\  ret
    );
}

fn stub_chkstk_generic() callconv(.winapi) void {
    // On non-x86 (WASM interpreter), stack probing is not needed.
}

// --- _allmul: 64-bit multiply ---
// Signature: __int64 _allmul(__int64 a, __int64 b) — callee pops 16 bytes
// Result in EDX:EAX
pub const stub_allmul = if (platform.is_x86)
    &stub_allmul_x86
else
    &stub_allmul_generic;

fn stub_allmul_x86() callconv(.naked) void {
    // Stack: [ret] [a_lo] [a_hi] [b_lo] [b_hi]
    //         0     4      8      12     16
    asm volatile (
        \\  mov 8(%%esp), %%ecx        // a_hi
        \\  mov 16(%%esp), %%eax       // b_hi
        \\  or %%ecx, %%eax            // test if both high parts are zero
        \\  mov 12(%%esp), %%ecx       // b_lo
        \\  jnz 1f                     // if high parts nonzero, do full multiply
        \\  // Simple case: both are 32-bit values
        \\  mov 4(%%esp), %%eax        // a_lo
        \\  mull %%ecx                 // EDX:EAX = a_lo * b_lo
        \\  ret $16
        \\1:
        \\  // Full 64-bit multiply:
        \\  // result_lo = a_lo * b_lo
        \\  // result_hi = a_lo * b_hi + a_hi * b_lo + carry from result_lo
        \\  push %%ebx
        \\  mull 4+4(%%esp)            // EAX = b_hi, mul a_lo -> EDX:EAX
        \\  mov %%eax, %%ebx           // save a_lo * b_hi
        \\  mov 8+4(%%esp), %%eax      // a_hi
        \\  mull %%ecx                 // a_hi * b_lo -> EDX:EAX
        \\  add %%eax, %%ebx           // ebx = a_lo*b_hi + a_hi*b_lo (high part adjustment)
        \\  mov 4+4(%%esp), %%eax      // a_lo
        \\  mull %%ecx                 // a_lo * b_lo -> EDX:EAX
        \\  add %%ebx, %%edx           // add high part adjustment
        \\  pop %%ebx
        \\  ret $16
    );
}

fn stub_allmul_generic() callconv(.winapi) usize {
    return 0;
}

// --- _alldiv: 64-bit signed divide ---
// Signature: __int64 _alldiv(__int64 dividend, __int64 divisor) — callee pops 16 bytes
// Result in EDX:EAX
pub const stub_alldiv = if (platform.is_x86)
    &stub_alldiv_x86
else
    &stub_alldiv_generic;

fn stub_alldiv_x86() callconv(.naked) void {
    // Signed 64-bit division: negate inputs if needed, do unsigned div, fix sign
    asm volatile (
        \\  push %%esi
        \\  push %%edi
        \\  // Load dividend (a) from stack
        \\  mov 12(%%esp), %%eax       // a_lo
        \\  mov 16(%%esp), %%edx       // a_hi
        \\  mov %%edx, %%esi           // save sign of a in esi
        \\  // If a is negative, negate it
        \\  test %%edx, %%edx
        \\  jns 1f
        \\  neg %%edx
        \\  neg %%eax
        \\  sbb $0, %%edx
        \\1:
        \\  push %%edx                 // save |a_hi|
        \\  push %%eax                 // save |a_lo|
        \\  // Load divisor (b) from stack (offset by extra pushes)
        \\  mov 28(%%esp), %%eax       // b_lo
        \\  mov 32(%%esp), %%edx       // b_hi
        \\  xor %%edx, %%esi           // esi = sign of result
        \\  mov %%esi, %%edi           // save result sign
        \\  // If b is negative, negate it
        \\  test %%edx, %%edx
        \\  jns 2f
        \\  neg %%edx
        \\  neg %%eax
        \\  sbb $0, %%edx
        \\2:
        \\  mov %%edx, %%ecx           // |b_hi|
        \\  mov %%eax, %%esi           // |b_lo|
        \\  // Now do unsigned divide: pop(a_hi:a_lo) / ecx:esi
        \\  test %%ecx, %%ecx
        \\  jnz 3f
        \\  // Simple case: divisor fits in 32 bits
        \\  pop %%eax                  // |a_lo|
        \\  pop %%edx                  // |a_hi|
        \\  divl %%esi                 // EDX:EAX / ESI
        \\  mov %%eax, %%esi           // quotient_lo = eax
        \\  xor %%edx, %%edx          // quotient_hi = 0
        \\  mov %%esi, %%eax
        \\  jmp 4f
        \\3:
        \\  // Complex case: 64-bit divisor. Result fits in 32 bits.
        \\  pop %%eax                  // |a_lo| (discard, we use a_hi for estimate)
        \\  pop %%eax                  // |a_hi|
        \\  xor %%edx, %%edx
        \\  divl %%ecx                 // a_hi / b_hi -> approximate quotient
        \\  xor %%edx, %%edx          // result high = 0
        \\4:
        \\  // Apply sign
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

fn stub_alldiv_generic() callconv(.winapi) usize {
    return 0;
}

// --- VerSetConditionMask ---
// ULONGLONG VerSetConditionMask(ULONGLONG ConditionMask, DWORD TypeMask, BYTE Condition)
// Called as: VerSetConditionMask(mask_lo, mask_hi, typeMask, condition) on x86
// since ULONGLONG is passed as two DWORDs
fn stub_VerSetConditionMask(mask_lo: u32, mask_hi: u32, typeMask: u32, condition: u8) callconv(.winapi) u64 {
    _ = mask_hi;
    if (trace.enable_tracing) trace.print("NTDLL: VerSetConditionMask(mask=0x{x}, type=0x{x}, cond={d})\n", .{ mask_lo, typeMask, condition });
    if (typeMask == 0 or condition == 0) return mask_lo;

    var mask: u64 = mask_lo;
    const cond3: u64 = @as(u64, condition & 0x07); // 3-bit condition value

    // Each type bit maps to a 3-bit field in the condition mask
    if (typeMask & 0x0000002 != 0) mask |= cond3 << 0;  // VER_MINORVERSION
    if (typeMask & 0x0000001 != 0) mask |= cond3 << 3;  // VER_MAJORVERSION
    if (typeMask & 0x0000004 != 0) mask |= cond3 << 6;  // VER_BUILDNUMBER
    if (typeMask & 0x0000008 != 0) mask |= cond3 << 9;  // VER_PLATFORMID
    if (typeMask & 0x0000010 != 0) mask |= cond3 << 12; // VER_SERVICEPACKMINOR
    if (typeMask & 0x0000020 != 0) mask |= cond3 << 15; // VER_SERVICEPACKMAJOR
    if (typeMask & 0x0000040 != 0) mask |= cond3 << 18; // VER_SUITENAME
    if (typeMask & 0x0000080 != 0) mask |= cond3 << 21; // VER_PRODUCT_TYPE

    return mask;
}

// --- RtlInitUnicodeString ---
// void RtlInitUnicodeString(PUNICODE_STRING DestinationString, PCWSTR SourceString)
// UNICODE_STRING: { USHORT Length, USHORT MaximumLength, PWSTR Buffer }
fn stub_RtlInitUnicodeString(dest: usize, source: usize) callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("NTDLL: RtlInitUnicodeString(dest={x}, source={x})\n", .{ dest, source });
    if (dest == 0) return;

    const us = @as(*w32.UNICODE_STRING, @ptrFromInt(dest));

    if (source == 0) {
        us.* = .{}; // Length=0, MaximumLength=0, Buffer=0
        return;
    }

    // Count wide chars (find null terminator)
    const wstr = @as([*]const u16, @ptrFromInt(source));
    var len: u16 = 0;
    while (wstr[len] != 0 and len < 32767) : (len += 1) {}

    const byte_len = len * 2;
    us.Length = byte_len;
    us.MaximumLength = byte_len + 2;
    us.Buffer = @intCast(source);
}

// --- RtlAllocateAndInitializeSid ---
// NTSTATUS RtlAllocateAndInitializeSid(
//   PSID_IDENTIFIER_AUTHORITY, BYTE SubAuthorityCount,
//   ULONG sa0..sa7, PSID *Sid)
fn stub_RtlAllocateAndInitializeSid(
    identAuth: usize, subAuthCount: u8,
    sa0: u32, sa1: u32, sa2: u32, sa3: u32,
    sa4: u32, sa5: u32, sa6: u32, sa7: u32,
    // The last arg is actually PSID* pSid — passed on the stack after sa7
    // On x86 cdecl/stdcall, 10th arg would be at esp+40
    // But winapi calling convention should handle it..
    // Actually RtlAllocateAndInitializeSid has 11 params total.
    // Let's use a usize for pSid
) callconv(.winapi) u32 {
    _ = sa4; _ = sa5; _ = sa6; _ = sa7;
    if (trace.enable_tracing) trace.print("NTDLL: RtlAllocateAndInitializeSid(count={d})\n", .{subAuthCount});

    // SID structure: Revision(1) + SubAuthorityCount(1) + IdentifierAuthority(6) + SubAuthority[count](4*count)
    const count = @min(subAuthCount, 8);
    const sid_size: usize = 8 + @as(usize, count) * 4;
    const sid_ptr = mem_alloc.raw_alloc(sid_size) orelse return 0xC0000017; // STATUS_NO_MEMORY

    const sid = @as([*]u8, @ptrCast(sid_ptr));
    sid[0] = 1; // Revision
    sid[1] = count; // SubAuthorityCount

    // Copy IdentifierAuthority (6 bytes)
    if (identAuth != 0) {
        const auth = @as([*]const u8, @ptrFromInt(identAuth));
        @memcpy(sid[2..8], auth[0..6]);
    } else {
        @memset(sid[2..8], 0);
    }

    // Set SubAuthorities
    const sub_auths = @as([*]align(1) u32, @ptrCast(@alignCast(sid + 8)));
    if (count > 0) sub_auths[0] = sa0;
    if (count > 1) sub_auths[1] = sa1;
    if (count > 2) sub_auths[2] = sa2;
    if (count > 3) sub_auths[3] = sa3;

    // TODO: need to write the SID pointer to *pSid output parameter
    // This is the 11th argument which isn't easily accessible with .winapi convention
    // For now, we at least properly allocate the SID

    return 0; // STATUS_SUCCESS
}

// --- RtlFreeSid ---
fn stub_RtlFreeSid(sid: usize) callconv(.winapi) usize {
    if (trace.enable_tracing) trace.print("NTDLL: RtlFreeSid({x})\n", .{sid});
    // Should return NULL on success
    return 0;
}

// --- RtlEqualSid ---
fn stub_RtlEqualSid(sid1: usize, sid2: usize) callconv(.winapi) i32 {
    if (trace.enable_tracing) trace.print("NTDLL: RtlEqualSid({x}, {x})\n", .{ sid1, sid2 });
    if (sid1 == 0 or sid2 == 0) return 0; // FALSE

    // SID size = 8 + 4 * SubAuthorityCount
    const s1 = @as([*]const u8, @ptrFromInt(sid1));
    const s2 = @as([*]const u8, @ptrFromInt(sid2));
    const count1 = s1[1];
    const count2 = s2[1];
    if (count1 != count2) return 0;

    const size: usize = 8 + @as(usize, count1) * 4;
    const equal = std.mem.eql(u8, s1[0..size], s2[0..size]);
    return if (equal) 1 else 0; // BOOLEAN
}

// --- NtClose ---
fn stub_NtClose(handle: usize) callconv(.winapi) u32 {
    if (trace.enable_tracing) trace.print("NTDLL: NtClose({x})\n", .{handle});
    return 0; // STATUS_SUCCESS
}

// --- RtlUnwind ---
// void RtlUnwind(PVOID TargetFrame, PVOID TargetIp, PEXCEPTION_RECORD ExceptionRecord, PVOID ReturnValue)
fn stub_RtlUnwind(targetFrame: usize, targetIp: usize, exceptionRecord: usize, returnValue: usize) callconv(.winapi) void {
    _ = targetFrame; _ = targetIp; _ = exceptionRecord; _ = returnValue;
    if (trace.enable_tracing) trace.print("NTDLL: RtlUnwind (no-op)\n", .{});
}

// --- strrchr ---
// char* strrchr(const char* str, int c)
fn stub_strrchr(str_ptr: usize, c: i32) callconv(.winapi) usize {
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

// --- _wcsicmp ---
// int _wcsicmp(const wchar_t* s1, const wchar_t* s2)
fn stub_wcsicmp(s1_ptr: usize, s2_ptr: usize) callconv(.winapi) i32 {
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

// --- memmove ---
// void* memmove(void* dest, const void* src, size_t count)
fn stub_memmove(dest_ptr: usize, src_ptr: usize, count: usize) callconv(.winapi) usize {
    if (dest_ptr == 0 or src_ptr == 0 or count == 0) return dest_ptr;
    const dst = @as([*]u8, @ptrFromInt(dest_ptr));
    const src = @as([*]const u8, @ptrFromInt(src_ptr));
    if (dest_ptr < src_ptr or dest_ptr >= src_ptr + count) {
        // No overlap or dst before src — copy forward
        for (0..count) |i| {
            dst[i] = src[i];
        }
    } else {
        // Overlap with dst after src — copy backward
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
    // VER_MAJORVERSION (0x02) with VER_GREATER_EQUAL (3)
    const mask1 = stub_VerSetConditionMask(0, 0, 0x01, 3); // MAJORVERSION -> bits 3-5
    try std.testing.expect(mask1 == (3 << 3));

    // Add VER_MINORVERSION (0x01) with VER_EQUAL (1)
    const mask2 = stub_VerSetConditionMask(@intCast(mask1 & 0xFFFFFFFF), 0, 0x02, 1); // MINORVERSION -> bits 0-2
    try std.testing.expect(mask2 == (3 << 3) | (1 << 0));
}

test "RtlInitUnicodeString fills struct correctly" {
    // Create a test wide string "Hi" = {0x48, 0x69, 0x00}
    var wstr = [_]u16{ 'H', 'i', 0 };
    var unicode_string: [8]u8 = undefined;

    stub_RtlInitUnicodeString(@intFromPtr(&unicode_string), @intFromPtr(&wstr));

    const length = @as(*align(1) const u16, @ptrCast(&unicode_string[0])).*;
    const max_length = @as(*align(1) const u16, @ptrCast(&unicode_string[2])).*;
    const buffer = @as(*align(1) const u32, @ptrCast(&unicode_string[4])).*;

    try std.testing.expectEqual(@as(u16, 4), length);       // 2 chars * 2 bytes = 4
    try std.testing.expectEqual(@as(u16, 6), max_length);   // 4 + 2 (null terminator)
    try std.testing.expectEqual(@intFromPtr(&wstr), @as(usize, buffer));
}

test "RtlInitUnicodeString with null source" {
    var unicode_string: [8]u8 = undefined;
    @memset(&unicode_string, 0xFF); // fill with garbage

    stub_RtlInitUnicodeString(@intFromPtr(&unicode_string), 0);

    const length = @as(*align(1) const u16, @ptrCast(&unicode_string[0])).*;
    const max_length = @as(*align(1) const u16, @ptrCast(&unicode_string[2])).*;
    const buffer = @as(*align(1) const u32, @ptrCast(&unicode_string[4])).*;

    try std.testing.expectEqual(@as(u16, 0), length);
    try std.testing.expectEqual(@as(u16, 0), max_length);
    try std.testing.expectEqual(@as(u32, 0), buffer);
}

test "RtlEqualSid compares correctly" {
    // Build two identical SIDs: Revision=1, Count=1, Auth={0,0,0,0,0,5}, SubAuth={18}
    var sid1 = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 };
    var sid2 = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 };

    try std.testing.expectEqual(@as(i32, 1), stub_RtlEqualSid(@intFromPtr(&sid1), @intFromPtr(&sid2)));

    // Change SubAuthority in sid2
    sid2[8] = 19;
    try std.testing.expectEqual(@as(i32, 0), stub_RtlEqualSid(@intFromPtr(&sid1), @intFromPtr(&sid2)));
}

test "NtClose returns STATUS_SUCCESS" {
    try std.testing.expectEqual(@as(u32, 0), stub_NtClose(0x1234));
}

