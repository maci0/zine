const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

/// Retrieves the process affinity mask for the specified process and the system affinity mask for the system.
/// Implementation status: Partially implemented (reports 1 CPU).
pub fn GetProcessAffinityMask(hProcess: usize, lpProcessAffinityMask: ?*u32, lpSystemAffinityMask: ?*u32) callconv(w32cc.WINAPI) i32 {
    _ = hProcess;
    if (lpProcessAffinityMask) |p| p.* = 1;
    if (lpSystemAffinityMask) |p| p.* = 1;
    return 1;
}

/// Retrieves information about the current system.
pub fn GetSystemInfo(si: *[9]u32) callconv(w32cc.WINAPI) void {
    si[0] = 0; // PROCESSOR_ARCHITECTURE_INTEL
    si[1] = 4096;
    si[2] = 0x10000;
    si[3] = 0x7FFEFFFF;
    si[4] = 1;
    si[5] = 1;
    si[6] = 0;
    si[7] = 65536;
    si[8] = 0;
}

/// Retrieves information about the current system to an application running under WOW64.
pub fn GetNativeSystemInfo(si: *[9]u32) callconv(w32cc.WINAPI) void {
    GetSystemInfo(si);
}

/// Determines whether the specified processor feature is supported by the current computer.
/// Implementation status: Partially implemented.
pub fn IsProcessorFeaturePresent(ProcessorFeature: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: IsProcessorFeaturePresent({d})\n", .{ProcessorFeature});
    return switch (ProcessorFeature) {
        0 => 0, // PF_FLOATING_POINT_PRECISION_ERRATA
        1 => 0, // PF_FLOATING_POINT_EMULATED
        3 => 1, // PF_MMX_INSTRUCTIONS_AVAILABLE
        6 => 1, // PF_XMMI_INSTRUCTIONS_AVAILABLE (SSE)
        // Note: SSE2+ features are NOT reported because the x86 interpreter
        // cannot handle SSE2 instructions. DLL code runs natively via
        // callDllNative and uses real CPUID for feature detection.
        else => 0,
    };
}

/// Verifies that the calling process has read access to the specified range of memory.
/// Implementation status: Partially implemented (only checks for NULL).
pub fn IsBadReadPtr(lp: usize, ucb: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucb;
    return if (lp == 0) 1 else 0;
}

/// Verifies that the calling process has write access to the specified range of memory.
/// Implementation status: Partially implemented (only checks for NULL).
pub fn IsBadWritePtr(lp: usize, ucb: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucb;
    return if (lp == 0) 1 else 0;
}

/// Determines whether the calling process has read access to the memory at the specified address.
/// Implementation status: Partially implemented (only checks for NULL).
pub fn IsBadCodePtr(lpfn: usize) callconv(w32cc.WINAPI) i32 {
    return if (lpfn == 0) 1 else 0;
}

/// Verifies that the calling process has read access to a range of memory containing a string.
/// Implementation status: Partially implemented (only checks for NULL).
pub fn IsBadStringPtrA(lpsz: usize, ucchMax: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucchMax;
    return if (lpsz == 0) 1 else 0;
}

/// Verifies that the calling process has read access to a range of memory containing a string (Unicode version).
/// Implementation status: Partially implemented (only checks for NULL).
pub fn IsBadStringPtrW(lpsz: usize, ucchMax: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucchMax;
    return if (lpsz == 0) 1 else 0;
}

/// Multiplies two 32-bit values and then divides the 64-bit result by a third 32-bit value.
/// Implementation status: Partially implemented.
pub fn MulDiv(nNumber: i32, nNumerator: i32, nDenominator: i32) callconv(w32cc.WINAPI) i32 {
    if (nDenominator == 0) return -1;
    const result = @divTrunc(@as(i64, nNumber) * @as(i64, nNumerator), @as(i64, nDenominator));
    if (result > 0x7FFFFFFF or result < -0x80000000) return -1;
    return @intCast(result);
}

/// Retrieves the size of a memory block allocated from a heap.
/// Implementation status: Partially implemented.
pub fn HeapSize(hHeap: usize, dwFlags: u32, lpMem: usize) callconv(w32cc.WINAPI) usize {
    _ = hHeap;
    _ = dwFlags;
    if (lpMem == 0) return 0;
    const header = @as(*const usize, @ptrFromInt(lpMem - 8));
    return header.*;
}

/// Validates the specified heap.
/// Implementation status: No-op fallback (returns TRUE).
pub fn stub_HeapValidate(hHeap: usize, dwFlags: u32, lpMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    _ = dwFlags;
    _ = lpMem;
    return 1;
}

/// Generates a simple tone on the speaker.
/// Implementation status: No-op fallback.
pub fn stub_Beep(dwFreq: u32, dwDuration: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwFreq;
    _ = dwDuration;
    return 1;
}

/// Causes the file I/O functions to use the OEM character set.
/// Implementation status: Stub.
pub fn stub_SetFileApisToOEM() callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: SetFileApisToOEM()\n", .{});
}

/// Retrieves information about the system's current usage of both physical and virtual memory.
/// Implementation status: Partially implemented (returns hardcoded values).
pub fn GlobalMemoryStatusEx(buf: [*]u8) callconv(w32cc.WINAPI) i32 {
    @memset(buf[0..64], 0);
    @as(*align(1) u32, @ptrCast(buf)).* = 64;
    @as(*align(1) u32, @ptrCast(buf + 4)).* = 50;
    @as(*align(1) u64, @ptrCast(buf + 8)).* = 2 * 1024 * 1024 * 1024;
    @as(*align(1) u64, @ptrCast(buf + 16)).* = 1 * 1024 * 1024 * 1024;
    @as(*align(1) u64, @ptrCast(buf + 24)).* = 4 * 1024 * 1024 * 1024;
    @as(*align(1) u64, @ptrCast(buf + 32)).* = 3 * 1024 * 1024 * 1024;
    @as(*align(1) u64, @ptrCast(buf + 40)).* = 2 * 1024 * 1024 * 1024;
    @as(*align(1) u64, @ptrCast(buf + 48)).* = 1536 * 1024 * 1024;
    return 1;
}

/// Enables features for a specified heap.
/// Implementation status: Partially implemented (always returns TRUE).
pub fn HeapSetInformation(hHeap: usize, HeapInformationClass: u32, HeapInformation: usize, HeapInformationLength: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ hHeap, HeapInformationClass, HeapInformation, HeapInformationLength };
    return 1;
}

/// Suspends the current thread until the specified condition is met or the time-out interval elapses.
/// Implementation status: Partially implemented.
pub fn SleepEx(dwMilliseconds: u32, bAlertable: i32) callconv(w32cc.WINAPI) u32 {
    _ = bAlertable;
    if (dwMilliseconds > 0) {
        const sleep_ns: u64 = @min(@as(u64, dwMilliseconds) * 1_000_000, 100_000_000); // Cap at 100ms
        std.Thread.sleep(sleep_ns);
    }
    return 0;
}
