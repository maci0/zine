const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const platform = @import("../../platform.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const civil_time = @import("../civil_time.zig");
const kernel32_error = @import("error.zig");
const ERROR_INVALID_PARAMETER: u32 = 87;

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
        // Windows guarantees QPC never steps backwards (NTP, manual clock
        // changes), so it must read the monotonic clock, not the wall clock.
        ptr.* = @intCast(@as(u64, @truncate(@as(u128, @bitCast(runtime.monoNanoTimestamp())))));
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
    // Zine presents the guest with a UTC system clock: GetTimeZoneInformation
    // reports bias 0, FileTimeToLocalFileTime is the identity, and both
    // GetLocalTime and GetSystemTime return UTC fields. Keep all of these in
    // agreement; converting only one side would corrupt every conversion
    // built on top of them.
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
    // Guests compute elapsed durations from tick deltas; a wall-clock step
    // would make those negative or huge. Monotonic keeps deltas sane.
    return @intCast(runtime.monoMilliTimestamp() & 0xFFFFFFFF);
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
    // GetLocalTime returns UTC fields (see comment there), so the two
    // implementations coincide by design.
    GetLocalTime(lpSystemTime);
}

/// --- Time conversion stubs ---
/// Implementation status: Partially implemented
pub fn SystemTimeToFileTime(lpSystemTime: usize, lpFileTime: usize) callconv(w32cc.WINAPI) i32 {
    if (lpSystemTime == 0 or lpFileTime == 0) return 0;
    const st = @as(*const w32.SYSTEMTIME, @ptrFromInt(lpSystemTime));
    const ft = @as(*w32.FILETIME, @ptrFromInt(lpFileTime));

    if (st.wYear < 1601 or st.wYear > 30827 or
        st.wMonth < 1 or st.wMonth > 12 or
        st.wDay < 1 or st.wDay > std.time.epoch.getDaysInMonth(st.wYear, @enumFromInt(st.wMonth)) or
        st.wHour > 23 or st.wMinute > 59 or st.wSecond > 59 or st.wMilliseconds > 999)
    {
        kernel32_error.SetLastError(ERROR_INVALID_PARAMETER);
        return 0;
    }
    // Days from 1601-01-01 to the given date, exact Gregorian calendar.
    // Leap-year-correct day counts come from daysFromCivil; the FILETIME
    // epoch 1601 is the lower validity bound checked above.
    const days = civil_time.daysFromCivil(st.wYear, st.wMonth, st.wDay) - civil_time.daysFromCivil(1601, 1, 1);

    const total_100ns_i64: i64 = days * 24 * 60 * 60 * 10_000_000 +
        @as(i64, st.wHour) * 60 * 60 * 10_000_000 +
        @as(i64, st.wMinute) * 60 * 10_000_000 +
        @as(i64, st.wSecond) * 10_000_000 +
        @as(i64, st.wMilliseconds) * 10_000;

    const total_100ns: u64 = @intCast(total_100ns_i64);

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
    if (total_100ns > std.math.maxInt(i64)) {
        kernel32_error.SetLastError(ERROR_INVALID_PARAMETER);
        return 0;
    }
    const total_secs: i64 = @intCast(total_100ns / 10_000_000);
    const remaining_100ns = total_100ns % 10_000_000;

    // Seconds since the Unix epoch; FILETIMEs between 1601 and 1970 are
    // valid and must not be clamped to 1970.
    const unix_secs: i64 = total_secs - 11644473600;
    // std.time.epoch only handles post-1970 days, so convert via civil date.
    const cd = civil_time.civilFromDays(@divFloor(unix_secs, 86400));
    const secs_into_day: u17 = @intCast(@mod(unix_secs, 86400));

    st.wYear = @intCast(cd.year);
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
    // The guest clock is UTC (see GetLocalTime), so local == UTC and the
    // conversion is the identity by policy.
    const src = @as(*const w32.FILETIME, @ptrFromInt(lpFileTime));
    const dst = @as(*w32.FILETIME, @ptrFromInt(lpLocalFileTime));
    dst.* = src.*;
    return 1; // TRUE
}

const testing = std.testing;

test "QueryPerformanceCounter never steps backwards" {
    var first: u64 = 0;
    var second: u64 = 0;
    try testing.expectEqual(@as(i32, 1), QueryPerformanceCounter(@intFromPtr(&first)));
    try testing.expectEqual(@as(i32, 1), QueryPerformanceCounter(@intFromPtr(&second)));
    try testing.expect(second >= first);
}

test "GetTickCount never steps backwards" {
    const first = GetTickCount();
    const second = GetTickCount();
    try testing.expect(second >= first);
}

fn fileTimeOf(st: w32.SYSTEMTIME) w32.FILETIME {
    var ft: w32.FILETIME = .{};
    _ = SystemTimeToFileTime(@intFromPtr(&st), @intFromPtr(&ft));
    return ft;
}

fn systemTimeOf(ft: w32.FILETIME) w32.SYSTEMTIME {
    var st: w32.SYSTEMTIME = .{};
    _ = FileTimeToSystemTime(@intFromPtr(&ft), @intFromPtr(&st));
    return st;
}

test "SYSTEMTIME/FILETIME round trip across year, leap-day and DST boundaries" {
    // The guest clock is UTC with no DST, so every wall-time field must
    // survive the conversion exactly, including Feb 29 and New Year's Eve.
    const samples = [_]w32.SYSTEMTIME{
        .{ .wYear = 1601, .wMonth = 1, .wDay = 1 },
        .{ .wYear = 1999, .wMonth = 12, .wDay = 31, .wHour = 23, .wMinute = 59, .wSecond = 59 },
        .{ .wYear = 2000, .wMonth = 2, .wDay = 29 },
        .{ .wYear = 2024, .wMonth = 2, .wDay = 29, .wHour = 23, .wMinute = 59, .wSecond = 59, .wMilliseconds = 999 },
        .{ .wYear = 2100, .wMonth = 3, .wDay = 1 }, // non-leap century year
        .{ .wYear = 2400, .wMonth = 2, .wDay = 29, .wDayOfWeek = 65535 },
        .{ .wYear = 30827, .wMonth = 12, .wDay = 31, .wHour = 23, .wMinute = 59, .wSecond = 59, .wMilliseconds = 999 },
    };
    for (samples) |st| {
        const back = systemTimeOf(fileTimeOf(st));
        try testing.expectEqual(st.wYear, back.wYear);
        try testing.expectEqual(st.wMonth, back.wMonth);
        try testing.expectEqual(st.wDay, back.wDay);
        try testing.expectEqual(st.wHour, back.wHour);
        try testing.expectEqual(st.wMinute, back.wMinute);
        try testing.expectEqual(st.wSecond, back.wSecond);
        try testing.expectEqual(st.wMilliseconds, back.wMilliseconds);
    }
}

test "SystemTimeToFileTime rejects invalid dates without changing output" {
    const invalid = [_]w32.SYSTEMTIME{
        .{ .wYear = 2023, .wMonth = 2, .wDay = 29 },
        .{ .wYear = 1900, .wMonth = 2, .wDay = 29 },
        .{ .wYear = 2100, .wMonth = 2, .wDay = 29 },
        .{ .wYear = 2024, .wMonth = 2, .wDay = 30 },
        .{ .wYear = 2024, .wMonth = 4, .wDay = 31 },
        .{ .wYear = 2024, .wMonth = 0, .wDay = 1 },
        .{ .wYear = 2023, .wMonth = 13, .wDay = 1 },
        .{ .wYear = 2024, .wMonth = 1, .wDay = 0 },
        .{ .wYear = 2024, .wMonth = 1, .wDay = 32 },
        .{ .wYear = 1600, .wMonth = 12, .wDay = 31 },
        .{ .wYear = 30828, .wMonth = 1, .wDay = 1 },
        .{ .wYear = 65535, .wMonth = 1, .wDay = 1 },
        .{ .wYear = 2024, .wMonth = 1, .wDay = 1, .wHour = 24 },
        .{ .wYear = 2024, .wMonth = 1, .wDay = 1, .wMinute = 60 },
        .{ .wYear = 2024, .wMonth = 1, .wDay = 1, .wSecond = 60 },
        .{ .wYear = 2024, .wMonth = 1, .wDay = 1, .wMilliseconds = 1000 },
    };
    const sentinel: w32.FILETIME = .{ .dwLowDateTime = 123, .dwHighDateTime = 456 };
    for (invalid) |st| {
        var ft = sentinel;
        kernel32_error.SetLastError(0);
        try testing.expectEqual(@as(i32, 0), SystemTimeToFileTime(@intFromPtr(&st), @intFromPtr(&ft)));
        try testing.expectEqual(ERROR_INVALID_PARAMETER, kernel32_error.GetLastError());
        try testing.expectEqual(sentinel, ft);
    }
}

test "FileTimeToSystemTime preserves the last valid FILETIME date" {
    const ft: w32.FILETIME = .{ .dwLowDateTime = 0xFFFFFFFF, .dwHighDateTime = 0x7FFFFFFF };
    var st: w32.SYSTEMTIME = .{};
    try testing.expectEqual(@as(i32, 1), FileTimeToSystemTime(@intFromPtr(&ft), @intFromPtr(&st)));
    try testing.expectEqualDeep(w32.SYSTEMTIME{
        .wYear = 30828,
        .wMonth = 9,
        .wDay = 14,
        .wDayOfWeek = 4,
        .wHour = 2,
        .wMinute = 48,
        .wSecond = 5,
        .wMilliseconds = 477,
    }, st);
}

test "FileTimeToSystemTime rejects high-bit timestamps without changing output" {
    const invalid = [_]w32.FILETIME{
        .{ .dwLowDateTime = 0, .dwHighDateTime = 0x80000000 },
        .{ .dwLowDateTime = 0xFFFFFFFF, .dwHighDateTime = 0xFFFFFFFF },
    };
    const sentinel: w32.SYSTEMTIME = .{ .wYear = 2024, .wMonth = 2, .wDay = 29 };
    for (invalid) |ft| {
        var st = sentinel;
        kernel32_error.SetLastError(0);
        try testing.expectEqual(@as(i32, 0), FileTimeToSystemTime(@intFromPtr(&ft), @intFromPtr(&st)));
        try testing.expectEqual(ERROR_INVALID_PARAMETER, kernel32_error.GetLastError());
        try testing.expectEqualDeep(sentinel, st);
    }
}

test "GetLocalTime and GetSystemTime agree (UTC guest clock policy)" {
    var local: w32.SYSTEMTIME = .{};
    var system: w32.SYSTEMTIME = .{};
    GetLocalTime(@intFromPtr(&local));
    GetSystemTime(@intFromPtr(&system));
    // The two calls sample the clock separately, so comparing broken-down
    // fields directly flakes when a sample straddles an hour/year boundary.
    // Convert both to FILETIME and require agreement within 2s instead:
    // real skew here would be whole time-zone offsets (>= 30 minutes).
    const local_ft = fileTimeOf(local);
    const system_ft = fileTimeOf(system);
    const as_u64 = struct {
        fn f(ft: w32.FILETIME) u64 {
            return @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime;
        }
    }.f;
    const lu = as_u64(local_ft);
    const su = as_u64(system_ft);
    const diff = if (lu > su) lu - su else su - lu;
    try testing.expect(diff <= 2 * 10_000_000);
    try testing.expect(local.wMilliseconds < 1000);
}
