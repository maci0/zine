const std = @import("std");
const trace = @import("../../trace.zig");
const platform = @import("../../platform.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn stub_GetTimeZoneInformation(lpTimeZoneInformation: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetTimeZoneInformation({x})\n", .{lpTimeZoneInformation});
    if (lpTimeZoneInformation != 0) {
        const tzi = @as([*]u8, @ptrFromInt(lpTimeZoneInformation));
        @memset(tzi[0..172], 0); // TIME_ZONE_INFORMATION is 172 bytes
    }
    return 0; // TIME_ZONE_ID_UNKNOWN
}

pub fn stub_QueryPerformanceCounter(lpPerformanceCount: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPerformanceCount != 0) {
        const ptr = @as(*u64, @ptrFromInt(lpPerformanceCount));
        ptr.* = @intCast(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))));
    }
    if (trace.enable_tracing) trace.print("KERNEL32: QueryPerformanceCounter({x})\n", .{lpPerformanceCount});
    return 1;
}

pub fn stub_QueryPerformanceFrequency(lpFrequency: usize) callconv(w32cc.WINAPI) i32 {
    if (lpFrequency != 0) {
        const ptr = @as(*u64, @ptrFromInt(lpFrequency));
        ptr.* = 1000000000; // 1 GHz
    }
    if (trace.enable_tracing) trace.print("KERNEL32: QueryPerformanceFrequency({x})\n", .{lpFrequency});
    return 1;
}

pub fn stub_GetVersionExA(lpVersionInfo: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetVersionExA({x})\n", .{lpVersionInfo});
    if (lpVersionInfo != 0) {
        const info = @as(*w32.OSVERSIONINFOA, @ptrFromInt(lpVersionInfo));
        info.dwMajorVersion = 5;
        info.dwMinorVersion = 0;
        info.dwBuildNumber = 2195;
        info.dwPlatformId = w32.VER_PLATFORM_WIN32_NT;
        info.szCSDVersion = [_]u8{0} ** 128;
    }
    return 1;
}

pub fn stub_GetLocalTime(lpSystemTime: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: GetLocalTime({x})\n", .{lpSystemTime});
    if (lpSystemTime == 0) return;
    const st = @as(*w32.SYSTEMTIME, @ptrFromInt(lpSystemTime));
    const ts: u64 = @intCast(std.time.timestamp());
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    st.wYear = @intCast(year_day.year);
    st.wMonth = @intFromEnum(month_day.month);
    st.wDayOfWeek = @intCast((epoch_day.day + 4) % 7);
    st.wDay = month_day.day_index + 1;
    st.wHour = @intCast(day_secs.getHoursIntoDay());
    st.wMinute = @intCast(day_secs.getMinutesIntoHour());
    st.wSecond = @intCast(day_secs.getSecondsIntoMinute());
    st.wMilliseconds = 0;
}

pub fn stub_GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: GetSystemTimeAsFileTime({x})\n", .{lpSystemTimeAsFileTime});
    if (lpSystemTimeAsFileTime == 0) return;
    const unix_ns: u128 = @bitCast(std.time.nanoTimestamp());
    const win_offset: u128 = 11644473600 * 10_000_000;
    const filetime: u64 = @intCast(unix_ns / 100 + win_offset);
    const ft = @as(*w32.FILETIME, @ptrFromInt(lpSystemTimeAsFileTime));
    ft.dwLowDateTime = @intCast(filetime & 0xFFFFFFFF);
    ft.dwHighDateTime = @intCast(filetime >> 32);
}

pub fn stub_GetSystemTimeAdjustment(lpTimeAdjustment: usize, lpTimeIncrement: usize, lpTimeAdjustmentDisabled: usize) callconv(w32cc.WINAPI) i32 {
    if (lpTimeAdjustment != 0) @as(*u32, @ptrFromInt(lpTimeAdjustment)).* = 0;
    if (lpTimeIncrement != 0) @as(*u32, @ptrFromInt(lpTimeIncrement)).* = 156250;
    if (lpTimeAdjustmentDisabled != 0) @as(*i32, @ptrFromInt(lpTimeAdjustmentDisabled)).* = 1; // TRUE
    return 1;
}

pub fn stub_GetTickCount() callconv(w32cc.WINAPI) u32 {
    const ts = std.time.milliTimestamp();
    return @intCast(ts & 0xFFFFFFFF);
}

pub fn stub_Sleep(dwMilliseconds: u32) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: Sleep({d})\n", .{dwMilliseconds});
    if (dwMilliseconds > 0) {
        std.Thread.sleep(dwMilliseconds * std.time.ns_per_ms);
    } else {
        platform.yield();
    }
}

pub fn stub_GetVersion() callconv(w32cc.WINAPI) u32 {
    // Return Windows 2000 (5.0) to match GetVersionExA
    // Low word: major version in low byte, minor in high byte = 0x0005
    // High word: build number (set high bit 0 for NT) = 0x0893 (2195)
    if (trace.enable_tracing) trace.print("KERNEL32: GetVersion()\n", .{});
    return 0x08930005;
}

// CompareFileTime: compares two FILETIMEs
// Returns: -1 if ft1 < ft2, 0 if equal, 1 if ft1 > ft2
pub fn stub_CompareFileTime(lpft1: usize, lpft2: usize) callconv(w32cc.WINAPI) i32 {
    if (lpft1 == 0 or lpft2 == 0) return 0;
    const ft1 = @as(*const w32.FILETIME, @ptrFromInt(lpft1));
    const ft2 = @as(*const w32.FILETIME, @ptrFromInt(lpft2));

    const t1: u64 = (@as(u64, ft1.dwHighDateTime) << 32) | ft1.dwLowDateTime;
    const t2: u64 = (@as(u64, ft2.dwHighDateTime) << 32) | ft2.dwLowDateTime;

    if (t1 < t2) return -1;
    if (t1 > t2) return 1;
    return 0;
}
