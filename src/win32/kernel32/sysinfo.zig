const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

/// Retrieves the process affinity mask for the specified process and the system affinity mask for the system.
/// Implementation status: Partially implemented (reports 1 CPU)
pub fn GetProcessAffinityMask(hProcess: usize, lpProcessAffinityMask: ?*u32, lpSystemAffinityMask: ?*u32) callconv(w32cc.WINAPI) i32 {
    _ = hProcess;
    if (lpProcessAffinityMask) |p| p.* = 1;
    if (lpSystemAffinityMask) |p| p.* = 1;
    return 1;
}

/// Retrieves information about the current system.
pub fn GetSystemInfo(si: *[9]u32) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: GetSystemInfo() (caller: {X})\n", .{@returnAddress()});
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
/// Implementation status: Partially implemented
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
/// Implementation status: Partially implemented (only checks for NULL)
pub fn IsBadReadPtr(lp: usize, ucb: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucb;
    return if (lp == 0) 1 else 0;
}

/// Verifies that the calling process has write access to the specified range of memory.
/// Implementation status: Partially implemented (only checks for NULL)
pub fn IsBadWritePtr(lp: usize, ucb: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucb;
    return if (lp == 0) 1 else 0;
}

/// Determines whether the calling process has read access to the memory at the specified address.
/// Implementation status: Partially implemented (only checks for NULL)
pub fn IsBadCodePtr(lpfn: usize) callconv(w32cc.WINAPI) i32 {
    return if (lpfn == 0) 1 else 0;
}

/// Verifies that the calling process has read access to a range of memory containing a string.
/// Implementation status: Partially implemented (only checks for NULL)
pub fn IsBadStringPtrA(lpsz: usize, ucchMax: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucchMax;
    return if (lpsz == 0) 1 else 0;
}

/// Verifies that the calling process has read access to a range of memory containing a string (Unicode version).
/// Implementation status: Partially implemented (only checks for NULL)
pub fn IsBadStringPtrW(lpsz: usize, ucchMax: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucchMax;
    return if (lpsz == 0) 1 else 0;
}

/// Multiplies two 32-bit values and then divides the 64-bit result by a third 32-bit value.
/// Rounds to nearest (ties away from zero) and returns -1 on overflow or a
/// zero denominator, matching Win32.
/// Implementation status: Fully implemented
pub fn MulDiv(nNumber: i32, nNumerator: i32, nDenominator: i32) callconv(w32cc.WINAPI) i32 {
    if (nDenominator == 0) return -1;
    const numerator = @as(i64, nNumber) * @as(i64, nNumerator);
    const denominator = @as(i64, nDenominator);
    // Half-up on magnitudes keeps the quotient sign intact; a plain
    // @divFloor((2*n + d) / 2d) formulation would overflow at i64 extremes.
    const half_denominator = @divTrunc(if (denominator < 0) -denominator else denominator, 2);
    const rounded = @divTrunc(numerator + (if (numerator < 0) -half_denominator else half_denominator), denominator);
    if (rounded > 0x7FFFFFFF or rounded < -0x80000000) return -1;
    return @intCast(rounded);
}

test "MulDiv rounds with negative denominators" {
    try std.testing.expectEqual(@as(i32, -2), MulDiv(3, 1, -2));
    try std.testing.expectEqual(@as(i32, 2), MulDiv(-3, 1, -2));
    try std.testing.expectEqual(@as(i32, -2), MulDiv(5, 1, -3));
    try std.testing.expectEqual(@as(i32, 2), MulDiv(5, -1, -3));
    try std.testing.expectEqual(@as(i32, -3), MulDiv(6, 1, -2));
    try std.testing.expectEqual(@as(i32, 0), MulDiv(0, 1, -2));
    try std.testing.expectEqual(@as(i32, 1), MulDiv(std.math.minInt(i32), 1, std.math.minInt(i32)));
    try std.testing.expectEqual(@as(i32, -1), MulDiv(std.math.minInt(i32), 1, -1));
}

test "MulDiv rounds half away from zero like Win32" {
    try std.testing.expectEqual(@as(i32, 5), MulDiv(10, 50, 100)); // 5.0 stays 5
    try std.testing.expectEqual(@as(i32, 5), MulDiv(10, 49, 100));
    try std.testing.expectEqual(@as(i32, 5), MulDiv(10, 45, 100)); // 4.5 -> 5
    try std.testing.expectEqual(@as(i32, 16), MulDiv(10, 16, 10));
    try std.testing.expectEqual(@as(i32, -5), MulDiv(-10, 45, 100)); // -4.5 -> -5
    try std.testing.expectEqual(@as(i32, -1), MulDiv(std.math.maxInt(i32), 2, 1)); // overflow
    try std.testing.expectEqual(@as(i32, -1), MulDiv(1, 1, 0)); // divide by zero
}

test "MulDiv avoids intermediate overflow for huge inputs" {
    try std.testing.expectEqual(@as(i32, 1073741824), MulDiv(std.math.maxInt(i32), 1 << 15, 1 << 16));
    try std.testing.expectEqual(@as(i32, -1073741824), MulDiv(std.math.minInt(i32) + 1, 1 << 15, 1 << 16));
    try std.testing.expectEqual(std.math.maxInt(i32), MulDiv(std.math.maxInt(i32), 1 << 16, 1 << 16));
    try std.testing.expectEqual(std.math.maxInt(i32), MulDiv(std.math.maxInt(i32), std.math.maxInt(i32), std.math.maxInt(i32)));
    try std.testing.expectEqual(std.math.minInt(i32), MulDiv(std.math.minInt(i32), std.math.minInt(i32), std.math.minInt(i32)));
}

/// Retrieves the size of a memory block allocated from a heap.
/// Implementation status: Partially implemented
pub fn HeapSize(hHeap: usize, dwFlags: u32, lpMem: ?*const anyopaque) callconv(w32cc.WINAPI) usize {
    _ = hHeap;
    _ = dwFlags;
    const memory = lpMem orelse {
        @import("error.zig").SetLastError(87); // ERROR_INVALID_PARAMETER
        return std.math.maxInt(usize);
    };
    const header: *const usize = @ptrFromInt(@intFromPtr(memory) - 16);
    return header.*;
}

/// Validates the specified heap.
/// Implementation status: No-op fallback (returns TRUE)
pub fn stub_HeapValidate(hHeap: usize, dwFlags: u32, lpMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    _ = dwFlags;
    _ = lpMem;
    return 1;
}

/// Generates a simple tone on the speaker.
/// Implementation status: No-op fallback
pub fn stub_Beep(dwFreq: u32, dwDuration: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwFreq;
    _ = dwDuration;
    return 1;
}

/// Causes the file I/O functions to use the OEM character set.
/// Implementation status: Stub
pub fn stub_SetFileApisToOEM() callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: SetFileApisToOEM()\n", .{});
}

/// Retrieves information about the system's current usage of both physical and virtual memory.
/// Implementation status: Partially implemented (returns hardcoded values)
pub fn GlobalMemoryStatusEx(buf: [*]u8) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GlobalMemoryStatusEx()\n", .{});
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
/// Implementation status: Partially implemented (always returns TRUE)
pub fn HeapSetInformation(hHeap: usize, HeapInformationClass: u32, HeapInformation: usize, HeapInformationLength: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ hHeap, HeapInformationClass, HeapInformation, HeapInformationLength };
    return 1;
}

/// Suspends the current thread until the specified condition is met or the time-out interval elapses.
/// Implementation status: Partially implemented
pub fn SleepEx(dwMilliseconds: u32, bAlertable: i32) callconv(w32cc.WINAPI) u32 {
    _ = bAlertable;
    if (dwMilliseconds > 0) {
        const sleep_ns: u64 = @min(@as(u64, dwMilliseconds) * 1_000_000, 100_000_000); // Cap at 100ms
        @import("../../runtime.zig").pauseOrAdvance(sleep_ns);
    }
    return 0;
}

test "HeapSize reads the Win32 allocation header before and after reallocation" {
    const mem = @import("mem.zig");
    const old = mem.HeapAlloc(null, 0, 13) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 13), HeapSize(0, 0, old));
    const grown = mem.HeapReAlloc(null, 0, old, 37) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 37), HeapSize(0, 0, grown));
    try std.testing.expectEqual(std.math.maxInt(usize), HeapSize(0, 0, null));
}
