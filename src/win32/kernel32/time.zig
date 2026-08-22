const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const platform = @import("../../platform.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const civil_time = @import("../civil_time.zig");

/// Implementation status: Partially implemented
pub fn GetTimeZoneInformation(lpTimeZoneInformation: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetTimeZoneInformation({x})\n", .{lpTimeZoneInformation});
    if (lpTimeZoneInformation != 0) {
        const tzi = @as([*]u8, @ptrFromInt(lpTimeZoneInformation));
        @memset(tzi[0..172], 0); // TIME_ZONE_INFORMATION is 172 bytes
    }
    return 0; // TIME_ZONE_ID_UNKNOWN
}

/// Implementation status: Partially implemented
pub fn QueryPerformanceCounter(lpPerformanceCount: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPerformanceCount != 0) {
        const ptr = @as(*u64, @ptrFromInt(lpPerformanceCount));
        ptr.* = @intCast(@as(u64, @truncate(@as(u128, @bitCast(runtime.nanoTimestamp())))));
    }
    if (trace.enable_tracing) trace.print("KERNEL32: QueryPerformanceCounter({x})\n", .{lpPerformanceCount});
    return 1;
}

/// Implementation status: Partially implemented
pub fn QueryPerformanceFrequency(lpFrequency: usize) callconv(w32cc.WINAPI) i32 {
    if (lpFrequency != 0) {
        const ptr = @as(*u64, @ptrFromInt(lpFrequency));
        ptr.* = 1000000000; // 1 GHz
    }
    if (trace.enable_tracing) trace.print("KERNEL32: QueryPerformanceFrequency({x})\n", .{lpFrequency});
    return 1;
}

/// Implementation status: Partially implemented
pub fn GetVersionExA(lpVersionInfo: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetVersionExA({x})\n", .{lpVersionInfo});
    if (lpVersionInfo != 0) {
        const info = @as(*w32.OSVERSIONINFOA, @ptrFromInt(lpVersionInfo));
        info.dwMajorVersion = 5;
        info.dwMinorVersion = 1;
        info.dwBuildNumber = 2600;
        info.dwPlatformId = w32.VER_PLATFORM_WIN32_NT;
        info.szCSDVersion = [_]u8{0} ** 128;
    }
    return 1;
}

/// Implementation status: Partially implemented
pub fn GetVersionExW(lpVersionInfo: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetVersionExW({x})\n", .{lpVersionInfo});
    if (lpVersionInfo != 0) {
        const info = @as(*w32.OSVERSIONINFOW, @ptrFromInt(lpVersionInfo));
        info.dwMajorVersion = 5;
        info.dwMinorVersion = 1;
        info.dwBuildNumber = 2600;
        info.dwPlatformId = w32.VER_PLATFORM_WIN32_NT;
        info.szCSDVersion = [_]u8{0} ** 256;
    }
    return 1;
}

/// Implementation status: Partially implemented
pub fn GetLocalTime(lpSystemTime: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: GetLocalTime({x})\n", .{lpSystemTime});
    if (lpSystemTime == 0) return;
    const st = @as(*w32.SYSTEMTIME, @ptrFromInt(lpSystemTime));
    const ms = runtime.milliTimestamp();
    const ts: u64 = @intCast(@divTrunc(ms, 1000));
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
    st.wMilliseconds = @intCast(@mod(@as(u64, @intCast(ms)), 1000));
}

/// Implementation status: Partially implemented
pub fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: GetSystemTimeAsFileTime({x})\n", .{lpSystemTimeAsFileTime});
    if (lpSystemTimeAsFileTime == 0) return;
    const unix_ns: u128 = @bitCast(runtime.nanoTimestamp());
    const win_offset: u128 = 11644473600 * 10_000_000;
    const filetime: u64 = @intCast(unix_ns / 100 + win_offset);
    const ft = @as(*w32.FILETIME, @ptrFromInt(lpSystemTimeAsFileTime));
    ft.dwLowDateTime = @intCast(filetime & 0xFFFFFFFF);
    ft.dwHighDateTime = @intCast(filetime >> 32);
}

/// Implementation status: Partially implemented
pub fn GetSystemTimeAdjustment(lpTimeAdjustment: usize, lpTimeIncrement: usize, lpTimeAdjustmentDisabled: usize) callconv(w32cc.WINAPI) i32 {
    if (lpTimeAdjustment != 0) @as(*u32, @ptrFromInt(lpTimeAdjustment)).* = 0;
    if (lpTimeIncrement != 0) @as(*u32, @ptrFromInt(lpTimeIncrement)).* = 156250;
    if (lpTimeAdjustmentDisabled != 0) @as(*i32, @ptrFromInt(lpTimeAdjustmentDisabled)).* = 1; // TRUE
    return 1;
}

/// Implementation status: Partially implemented
pub fn GetTickCount() callconv(w32cc.WINAPI) u32 {
    const ts = runtime.milliTimestamp();
    return @intCast(ts & 0xFFFFFFFF);
}

/// Implementation status: Partially implemented
pub fn Sleep(dwMilliseconds: u32) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: Sleep({d})\n", .{dwMilliseconds});
    if (dwMilliseconds > 0) {
        @import("../../platform.zig").sleep(@as(u64, dwMilliseconds) * std.time.ns_per_ms);
    } else {
        platform.yield();
    }
}

/// Implementation status: Partially implemented
pub fn GetVersion() callconv(w32cc.WINAPI) u32 {
    // Return Windows XP SP3 (5.1) to match GetVersionExA
    // Low word: major=5, minor=1 → 0x0105
    // High word: build 2600 = 0x0A28
    if (trace.enable_tracing) trace.print("KERNEL32: GetVersion()\n", .{});
    return 0x0A280105;
}

/// CompareFileTime: compares two FILETIMEs
/// Returns: -1 if ft1 < ft2, 0 if equal, 1 if ft1 > ft2
/// Implementation status: Partially implemented
pub fn CompareFileTime(lpft1: usize, lpft2: usize) callconv(w32cc.WINAPI) i32 {
    if (lpft1 == 0 or lpft2 == 0) return 0;
    const ft1 = @as(*const w32.FILETIME, @ptrFromInt(lpft1));
    const ft2 = @as(*const w32.FILETIME, @ptrFromInt(lpft2));

    const t1: u64 = (@as(u64, ft1.dwHighDateTime) << 32) | ft1.dwLowDateTime;
    const t2: u64 = (@as(u64, ft2.dwHighDateTime) << 32) | ft2.dwLowDateTime;

    if (t1 < t2) return -1;
    if (t1 > t2) return 1;
    return 0;
}

/// Implementation status: Partially implemented
pub fn GetSystemTime(lpSystemTime: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: GetSystemTime({x})\n", .{lpSystemTime});
    // Use GetLocalTime for simplicity (close enough for gaming)
    GetLocalTime(lpSystemTime);
}

/// --- Time conversion stubs ---
/// Implementation status: Partially implemented
pub fn SystemTimeToFileTime(lpSystemTime: usize, lpFileTime: usize) callconv(w32cc.WINAPI) i32 {
    if (lpSystemTime == 0 or lpFileTime == 0) return 0;
    const st = @as(*const w32.SYSTEMTIME, @ptrFromInt(lpSystemTime));
    const ft = @as(*w32.FILETIME, @ptrFromInt(lpFileTime));

    // Days from 1601-01-01 to the given date, exact Gregorian calendar.
    // SYSTEMTIME months outside [1, 12] are normalized like mktime does.
    const y: i64 = st.wYear + @divFloor(@as(i64, st.wMonth) - 1, 12);
    const m: i64 = @mod(@as(i64, st.wMonth) - 1, 12) + 1;
    const days: i64 = civil_time.daysFromCivil(y, m, st.wDay) - civil_time.daysFromCivil(1601, 1, 1);

    const total_100ns_i64: i64 = days * 24 * 60 * 60 * 10_000_000 +
        @as(i64, st.wHour) * 60 * 60 * 10_000_000 +
        @as(i64, st.wMinute) * 60 * 10_000_000 +
        @as(i64, st.wSecond) * 10_000_000 +
        @as(i64, st.wMilliseconds) * 10_000;

    // FILETIME is unsigned; dates before 1601 saturate at the epoch instead
    // of panicking on the cast.
    const total_100ns: u64 = if (total_100ns_i64 < 0) 0 else @intCast(total_100ns_i64);

    ft.dwLowDateTime = @intCast(total_100ns & 0xFFFFFFFF);
    ft.dwHighDateTime = @intCast(total_100ns >> 32);
    return 1; // TRUE
}

/// Implementation status: Partially implemented
pub fn FileTimeToSystemTime(lpFileTime: usize, lpSystemTime: usize) callconv(w32cc.WINAPI) i32 {
    if (lpFileTime == 0 or lpSystemTime == 0) return 0;
    const ft = @as(*const w32.FILETIME, @ptrFromInt(lpFileTime));
    const st = @as(*w32.SYSTEMTIME, @ptrFromInt(lpSystemTime));

    const total_100ns: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    const total_secs: i64 = @intCast(total_100ns / 10_000_000);
    const remaining_100ns = total_100ns % 10_000_000;

    // Seconds since the Unix epoch; FILETIMEs between 1601 and 1970 are
    // valid and must not be clamped to 1970.
    const unix_secs: i64 = total_secs - 11644473600;
    // std.time.epoch only handles post-1970 days, so convert via civil date.
    const cd = civil_time.civilFromDays(@divFloor(unix_secs, 86400));
    const secs_into_day: u17 = @intCast(@mod(unix_secs, 86400));

    st.wYear = @intCast(std.math.clamp(cd.year, 1601, 30827));
    st.wMonth = @intCast(cd.month);
    st.wDayOfWeek = @intCast(@mod(@divFloor(unix_secs, 86400) + 4, 7));
    st.wDay = @intCast(cd.day);
    st.wHour = @intCast(secs_into_day / 3600);
    st.wMinute = @intCast((secs_into_day / 60) % 60);
    st.wSecond = @intCast(secs_into_day % 60);
    st.wMilliseconds = @intCast(remaining_100ns / 10_000);
    return 1; // TRUE
}

/// Implementation status: Partially implemented
pub fn FileTimeToLocalFileTime(lpFileTime: usize, lpLocalFileTime: usize) callconv(w32cc.WINAPI) i32 {
    if (lpFileTime == 0 or lpLocalFileTime == 0) return 0;
    // We don't do timezone conversion — just copy
    const src = @as(*const w32.FILETIME, @ptrFromInt(lpFileTime));
    const dst = @as(*w32.FILETIME, @ptrFromInt(lpLocalFileTime));
    dst.* = src.*;
    return 1; // TRUE
}
