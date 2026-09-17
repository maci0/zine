//! MSVCRT time functions implementation.

const std = @import("std");
const x86_memory = @import("../../x86/memory.zig");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const civil_time = @import("../civil_time.zig");

/// struct tm for localtime
const Tm = extern struct {
    tm_sec: i32 = 0,
    tm_min: i32 = 0,
    tm_hour: i32 = 0,
    tm_mday: i32 = 0,
    tm_mon: i32 = 0,
    tm_year: i32 = 0,
    tm_wday: i32 = 0,
    tm_yday: i32 = 0,
    tm_isdst: i32 = 0,
};
var localtime_result: Tm = .{};

fn fillTm(tm: *Tm, ts: u64) void {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    tm.* = .{
        .tm_sec = @intCast(day_secs.getSecondsIntoMinute()),
        .tm_min = @intCast(day_secs.getMinutesIntoHour()),
        .tm_hour = @intCast(day_secs.getHoursIntoDay()),
        .tm_mday = @intCast(month_day.day_index + 1),
        .tm_mon = @intCast(@intFromEnum(month_day.month) - 1),
        .tm_year = @as(i32, @intCast(year_day.year)) - 1900,
        .tm_wday = @intCast((epoch_day.day + 4) % 7),
        .tm_yday = @intCast(year_day.day),
        .tm_isdst = 0,
    };
}

/// Get current system time.
/// Implementation status: Partially implemented
pub fn time(time_out: ?*i32) callconv(.c) i32 {
    const t = @as(i32, @intCast(@divTrunc(runtime.nanoTimestamp(), std.time.ns_per_s)));
    if (time_out) |p| p.* = t;
    return t;
}

/// Convert time_t to struct tm as local time.
pub fn localtime(time_in: *const i32) callconv(.c) *Tm {
    const raw = time_in.*;
    // Negative times (pre-1970, or the -1 error sentinel) clamp to the epoch
    // like ctime() below; a plain @intCast to u64 would panic on safe builds.
    const ts: u64 = if (raw >= 0) @intCast(raw) else 0;
    fillTm(&localtime_result, ts);
    return &localtime_result;
}

var ctime_buf: [26]u8 = undefined;
const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const mon_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Convert time_t to a string. Returns a static buffer: "Day Mon DD HH:MM:SS YYYY\n\0"
/// Implementation status: Partially implemented
pub fn ctime(time_in: ?*const i32) callconv(.c) [*]const u8 {
    var tm: Tm = .{};
    if (time_in) |p| {
        const raw = p.*;
        const ts: u64 = if (raw >= 0) @intCast(raw) else 0;
        fillTm(&tm, ts);
    }
    const wday: usize = @intCast(@mod(tm.tm_wday, 7));
    const mon: usize = @intCast(@mod(tm.tm_mon, 12));
    const result = std.fmt.bufPrint(&ctime_buf, "{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d}\n", .{
        day_names[wday],
        mon_names[mon],
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        @as(i32, tm.tm_year + 1900),
    }) catch {
        @memcpy(ctime_buf[0..25], "Thu Jan 01 00:00:00 1970\n");
        ctime_buf[25] = 0;
        return &ctime_buf;
    };
    if (result.len < ctime_buf.len) ctime_buf[result.len] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: ctime -> '{s}'\n", .{result});
    return &ctime_buf;
}

/// Set time zone environment variables.
/// Implementation status: Partially implemented
pub fn tzset() callconv(.c) void {
    msvcrt.msvcrt_timezone = 0;
    msvcrt.msvcrt_daylight = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _tzset()\n", .{});
}

/// Get current time into a _timeb structure.
/// Implementation status: Partially implemented
pub fn ftime(timeb_buf: [*]u8) callconv(.c) void {
    const ms = runtime.milliTimestamp();
    const secs: i32 = @intCast(@divTrunc(ms, 1000));
    const millitm: u16 = @intCast(@mod(@as(u64, @intCast(ms)), 1000));
    @as(*align(1) i32, @ptrCast(timeb_buf[0..4])).* = secs; // time
    @as(*align(1) u16, @ptrCast(timeb_buf[4..6])).* = millitm; // millitm
    @as(*align(1) i16, @ptrCast(timeb_buf[6..8])).* = 0; // timezone
    @as(*align(1) i16, @ptrCast(timeb_buf[8..10])).* = 0; // dstflag
    if (trace.enable_tracing) trace.print("MSVCRT: _ftime(time={d}, ms={d})\n", .{ secs, millitm });
}

/// Set file modification time.
/// Implementation status: Stub
pub fn stub_utime(path_ptr: usize, times_ptr: usize) callconv(.c) i32 {
    _ = times_ptr;
    if (trace.enable_tracing) {
        const path = if (path_ptr != 0) trace.c_span(path_ptr) else "<null>";
        trace.print("MSVCRT: _utime('{s}') -> 0\n", .{path});
    }
    return 0;
}

/// Set file modification time using file descriptor.
/// Implementation status: Stub
pub fn stub_futime(fd: i32, times_ptr: usize) callconv(.c) i32 {
    _ = times_ptr;
    if (trace.enable_tracing) trace.print("MSVCRT: _futime(fd={d}) -> 0\n", .{fd});
    return 0;
}

/// Convert struct tm to time_t.
/// Implementation status: Partially implemented
pub fn mktime(tm: *Tm) callconv(.c) i32 {
    // Normalize the month into [1, 12], carrying overflow into the year.
    // tm_mon is 0-based; @divFloor/@mod handle out-of-range and negative values.
    const y: i64 = @as(i64, tm.tm_year) + 1900 + @divFloor(tm.tm_mon, 12);
    const m: i64 = @mod(tm.tm_mon, 12) + 1;

    // Days from epoch (1970-01-01), exact Gregorian calendar.
    const total_days = civil_time.daysFromCivil(y, m, tm.tm_mday);

    const total_secs = total_days * 86400 + @as(i64, tm.tm_hour) * 3600 + @as(i64, tm.tm_min) * 60 + @as(i64, tm.tm_sec);

    if (total_secs < 0 or total_secs > 0x7FFFFFFF) return -1;
    fillTm(tm, @intCast(total_secs));
    return @intCast(total_secs);
}

var clock_start: ?i64 = null;

/// Get elapsed processor time.
/// Implementation status: Partially implemented
pub fn clock() callconv(.c) i32 {
    // CLOCKS_PER_SEC is 1000 on MSVC. Measures elapsed time, so it must use
    // the monotonic clock: a wall-clock step would corrupt the delta.
    const now = runtime.monoMilliTimestamp();
    if (clock_start == null) clock_start = now;
    const elapsed = now - clock_start.?;
    return @intCast(@min(elapsed, 0x7FFFFFFF));
}

var asctime_buf: [48]u8 = undefined;

/// Convert struct tm to string. Returns a static buffer formatted like C
/// asctime: "Www Mmm dd hh:mm:ss yyyy\n" with dd right-aligned in 3 columns.
/// Reads the caller's tm through the guest->host translation; out-of-range
/// field values are folded into range instead of indexing out of bounds.
/// Implementation status: Partially implemented
pub fn asctime(tm_ptr: usize) callconv(.c) [*]const u8 {
    var tm: Tm = .{ .tm_mday = 1, .tm_year = 70, .tm_wday = 4 }; // Unix epoch
    if (tm_ptr >= 0x10000) {
        const src: *align(1) const Tm = @ptrFromInt(trace.addr(tm_ptr));
        tm = src.*;
    } else if (trace.enable_tracing) {
        trace.print("MSVCRT: asctime(NULL tm) -> epoch\n", .{});
    }
    const wday: usize = @intCast(@mod(tm.tm_wday, 7));
    const mon: usize = @intCast(@mod(tm.tm_mon, 12));
    const result = std.fmt.bufPrint(&asctime_buf, "{s} {s}{d:>3} {d:0>2}:{d:0>2}:{d:0>2} {d}\n", .{
        day_names[wday],
        mon_names[mon],
        @as(u32, @intCast(@max(tm.tm_mday, 0))),
        @as(u32, @intCast(@max(tm.tm_hour, 0))),
        @as(u32, @intCast(@max(tm.tm_min, 0))),
        @as(u32, @intCast(@max(tm.tm_sec, 0))),
        @as(i64, tm.tm_year) + 1900,
    }) catch {
        const fallback = "Thu Jan  1 00:00:00 1970\n";
        @memcpy(asctime_buf[0..fallback.len], fallback);
        asctime_buf[fallback.len] = 0;
        return &asctime_buf;
    };
    asctime_buf[result.len] = 0;
    // On WASM, allocate in guest memory so x86 code can read it
    const stub_common = @import("../shared.zig");
    if (x86_memory.guest_memory != null) {
        if (stub_common.raw_alloc(result.len + 1)) |raw| {
            const ptr = @as([*]u8, @ptrCast(raw));
            @memcpy(ptr[0..result.len], result);
            ptr[result.len] = 0;
            return ptr;
        }
    }
    return &asctime_buf;
}

/// 64-bit version of time().
/// Implementation status: Partially implemented
pub fn time64(t: ?*align(1) i64) callconv(.c) i64 {
    const ts: i64 = @intCast(@divTrunc(runtime.nanoTimestamp(), std.time.ns_per_s));
    if (t) |p| p.* = ts;
    return ts;
}

var tm_buf: [64]u8 = [_]u8{0} ** 64;

/// 64-bit version of localtime(). Returns a static buffer.
/// Implementation status: Stub
pub fn localtime64(t: usize) callconv(.c) *[64]u8 {
    _ = t;
    // On WASM, allocate in guest memory so x86 can dereference
    const stub_common = @import("../shared.zig");
    if (x86_memory.guest_memory != null) {
        const raw = stub_common.raw_alloc(64) orelse return &tm_buf;
        const ptr = @as(*[64]u8, @ptrCast(raw));
        @memset(ptr, 0);
        return ptr;
    }
    return &tm_buf;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn asctimeStr(tm: *const Tm) []const u8 {
    return std.mem.sliceTo(asctime(@intFromPtr(tm)), 0);
}

test "asctime formats the caller's tm per the C standard layout" {
    // Classic C standard example: 1973-09-16 (a Sunday), 01:03:52.
    const tm: Tm = .{
        .tm_sec = 52,
        .tm_min = 3,
        .tm_hour = 1,
        .tm_mday = 16,
        .tm_mon = 8, // September, 0-based
        .tm_year = 73,
        .tm_wday = 0,
        .tm_yday = 258,
        .tm_isdst = 0,
    };
    try testing.expectEqualStrings("Sun Sep 16 01:03:52 1973\n", asctimeStr(&tm));

    // Single-digit day is space-padded to width 3, not zero-padded.
    const first: Tm = .{ .tm_year = 70, .tm_mday = 1, .tm_wday = 4 };
    try testing.expectEqualStrings("Thu Jan  1 00:00:00 1970\n", asctimeStr(&first));
}

test "asctime tolerates null and garbage fields" {
    // Null/near-null pointer falls back to the epoch date instead of crashing.
    const null_result = std.mem.sliceTo(asctime(0), 0);
    try testing.expectEqualStrings("Thu Jan  1 00:00:00 1970\n", null_result);

    // Out-of-range wday/mon fold into range rather than indexing out of bounds.
    const weird: Tm = .{ .tm_mday = 4, .tm_mon = 25, .tm_wday = -7 };
    const s = asctimeStr(&weird);
    try testing.expect(s.len > 0);
}

test "mktime interprets tm as UTC and normalizes month overflow" {
    // 2024-02-29T00:00:00Z exists only on leap years; pin its exact value.
    var leap_day: Tm = .{ .tm_mday = 29, .tm_mon = 1, .tm_year = 124 };
    const expected = (civil_time.daysFromCivil(2024, 2, 29) - civil_time.daysFromCivil(1970, 1, 1)) * 86400;
    try testing.expectEqual(@as(i32, @intCast(expected)), mktime(&leap_day));

    var month13: Tm = .{ .tm_mday = 1, .tm_mon = 12, .tm_year = 123 };
    var jan: Tm = .{ .tm_mday = 1, .tm_mon = 0, .tm_year = 124 };
    try testing.expectEqual(mktime(&jan), mktime(&month13));
}

test "mktime updates normalized fields across leap days and year boundaries" {
    const cases = [_]struct { input: Tm, expected: Tm, timestamp: i32 }{
        .{
            .input = .{ .tm_year = 124, .tm_mon = 1, .tm_mday = 29, .tm_hour = 24, .tm_isdst = -1 },
            .expected = .{ .tm_year = 124, .tm_mon = 2, .tm_mday = 1, .tm_wday = 5, .tm_yday = 60 },
            .timestamp = 1709251200,
        },
        .{
            .input = .{ .tm_year = 123, .tm_mon = 11, .tm_mday = 31, .tm_hour = 23, .tm_min = 59, .tm_sec = 60 },
            .expected = .{ .tm_year = 124, .tm_mon = 0, .tm_mday = 1, .tm_wday = 1 },
            .timestamp = 1704067200,
        },
        .{
            .input = .{ .tm_year = 124, .tm_mon = -1, .tm_mday = 32, .tm_hour = -1 },
            .expected = .{ .tm_year = 123, .tm_mon = 11, .tm_mday = 31, .tm_hour = 23, .tm_wday = 0, .tm_yday = 364 },
            .timestamp = 1704063600,
        },
    };
    for (cases) |case| {
        var tm = case.input;
        try testing.expectEqual(case.timestamp, mktime(&tm));
        try testing.expectEqualDeep(case.expected, tm);
    }
}

test "localtime inverts mktime on the UTC guest clock" {
    var t: i32 = 1709164800; // 2024-02-29T00:00:00Z
    const tm = localtime(&t);
    try testing.expectEqual(@as(i32, 2024 - 1900), tm.tm_year);
    try testing.expectEqual(@as(i32, 1), tm.tm_mon); // February
    try testing.expectEqual(@as(i32, 29), tm.tm_mday);
    try testing.expect(mktime(tm) == t);
}
