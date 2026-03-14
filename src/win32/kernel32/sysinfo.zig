const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn GetSystemInfo(lpSystemInfo_ptr: usize) callconv(w32cc.WINAPI) void {
    if (lpSystemInfo_ptr != 0) {
        const lpSystemInfo = @as(*[9]u32, @ptrFromInt(lpSystemInfo_ptr));
        lpSystemInfo[0] = 0; // wProcessorArchitecture
        lpSystemInfo[1] = 4096; // dwPageSize
        lpSystemInfo[2] = 0x10000; // lpMinimumApplicationAddress
        lpSystemInfo[3] = 0x7FFEFFFF; // lpMaximumApplicationAddress
        lpSystemInfo[4] = 1; // dwActiveProcessorMask
        lpSystemInfo[5] = 1; // dwNumberOfProcessors
        lpSystemInfo[6] = 0; // dwProcessorType
        lpSystemInfo[7] = 65536; // dwAllocationGranularity
        lpSystemInfo[8] = 0; // wProcessorLevel
    }
}

pub fn GetNativeSystemInfo(lpSystemInfo_ptr: usize) callconv(w32cc.WINAPI) void {
    // On x86, GetNativeSystemInfo returns the same as GetSystemInfo
    GetSystemInfo(lpSystemInfo_ptr);
}

pub fn IsProcessorFeaturePresent(ProcessorFeature: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: IsProcessorFeaturePresent({d})\n", .{ProcessorFeature});
    // PF_FLOATING_POINT_EMULATED=1 -> FALSE (we have real FP)
    // PF_MMX_INSTRUCTIONS_AVAILABLE=3 -> TRUE
    // PF_XMMI_INSTRUCTIONS_AVAILABLE=6 (SSE) -> TRUE
    return switch (ProcessorFeature) {
        1 => 0, // Not emulated
        3 => 1, // MMX available
        6 => 1, // SSE available
        else => 0,
    };
}

pub fn IsBadReadPtr(lp: usize, ucb: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucb;
    return if (lp == 0) 1 else 0; // Only NULL is "bad"
}

pub fn IsBadWritePtr(lp: usize, ucb: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucb;
    return if (lp == 0) 1 else 0;
}

pub fn IsBadCodePtr(lpfn: usize) callconv(w32cc.WINAPI) i32 {
    return if (lpfn == 0) 1 else 0;
}

pub fn IsBadStringPtrA(lpsz: usize, ucchMax: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucchMax;
    return if (lpsz == 0) 1 else 0;
}

pub fn IsBadStringPtrW(lpsz: usize, ucchMax: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucchMax;
    return if (lpsz == 0) 1 else 0;
}

pub fn MulDiv(nNumber: i32, nNumerator: i32, nDenominator: i32) callconv(w32cc.WINAPI) i32 {
    if (nDenominator == 0) return -1;
    const result = @divTrunc(@as(i64, nNumber) * @as(i64, nNumerator), @as(i64, nDenominator));
    if (result > 0x7FFFFFFF or result < -0x80000000) return -1;
    return @intCast(result);
}

pub fn HeapSize(hHeap: usize, dwFlags: u32, lpMem: usize) callconv(w32cc.WINAPI) usize {
    _ = hHeap;
    _ = dwFlags;
    if (lpMem == 0) return 0;
    // raw_alloc layout: [usize size header][user data] -- header is at ptr-8
    const header = @as(*const usize, @ptrFromInt(lpMem - 8));
    return header.*;
}

pub fn stub_HeapValidate(hHeap: usize, dwFlags: u32, lpMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    _ = dwFlags;
    _ = lpMem;
    return 1; // TRUE = valid
}

pub fn stub_Beep(dwFreq: u32, dwDuration: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwFreq;
    _ = dwDuration;
    return 1;
}

pub fn stub_SetFileApisToOEM() callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: SetFileApisToOEM()\n", .{});
}

pub fn GlobalMemoryStatusEx(lpBuffer: usize) callconv(w32cc.WINAPI) i32 {
    if (lpBuffer == 0) return 0;
    // MEMORYSTATUSEX: first field is dwLength (u32), then various 64-bit fields
    // dwLength, dwMemoryLoad, ullTotalPhys, ullAvailPhys, ullTotalPageFile,
    // ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual
    const buf = @as([*]u8, @ptrFromInt(lpBuffer));
    // Zero out the structure (64 bytes)
    @memset(buf[0..64], 0);
    // dwLength = 64
    @as(*align(1) u32, @ptrFromInt(lpBuffer)).* = 64;
    // dwMemoryLoad = 50 (50% used)
    @as(*align(1) u32, @ptrFromInt(lpBuffer + 4)).* = 50;
    // ullTotalPhys = 2GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 8)).* = 2 * 1024 * 1024 * 1024;
    // ullAvailPhys = 1GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 16)).* = 1 * 1024 * 1024 * 1024;
    // ullTotalPageFile = 4GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 24)).* = 4 * 1024 * 1024 * 1024;
    // ullAvailPageFile = 3GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 32)).* = 3 * 1024 * 1024 * 1024;
    // ullTotalVirtual = 2GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 40)).* = 2 * 1024 * 1024 * 1024;
    // ullAvailVirtual = 1.5GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 48)).* = 1536 * 1024 * 1024;
    return 1; // TRUE
}

pub fn SleepEx(dwMilliseconds: u32, bAlertable: i32) callconv(w32cc.WINAPI) u32 {
    _ = bAlertable;
    if (dwMilliseconds > 0) {
        const sleep_ns: u64 = @min(@as(u64, dwMilliseconds) * 1_000_000, 100_000_000); // Cap at 100ms
        std.Thread.sleep(sleep_ns);
    }
    return 0; // The return value is 0 if the specified time interval expired.
}
