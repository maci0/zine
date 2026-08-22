//! MSVCRT time functions implementation.

const std = @import("std");
const x86_memory = @import("../../x86/memory.zig");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");

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
    const ts: u64 = @intCast(time_in.*);
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
pub fn mktime(tm: *const Tm) callconv(.c) i32 {

    // Convert struct tm to Unix timestamp
    const year: i64 = @as(i64, tm.tm_year) + 1900;
    var month: i64 = @as(i64, tm.tm_mon) + 1;
    var y = year;

    // Adjust for months out of range
    if (month <= 0) {
        y -= 1;
        month += 12;
    } else if (month > 12) {
        y += @divTrunc(month - 1, 12);
        month = @mod(month - 1, 12) + 1;
    }

    // Days from epoch (1970-01-01) using a simplified algorithm
    if (month <= 2) {
        y -= 1;
        month += 12;
    }
    const era_days = 365 * (y - 1970) + @divFloor(y - 1969, 4) - @divFloor(y - 1901, 100) + @divFloor(y - 1601, 400);
    const month_days = @divTrunc(153 * (month - 3) + 2, 5);
    const total_days = era_days + month_days + @as(i64, tm.tm_mday) - 1 - 306;

    const total_secs = total_days * 86400 + @as(i64, tm.tm_hour) * 3600 + @as(i64, tm.tm_min) * 60 + @as(i64, tm.tm_sec);

    if (total_secs < 0 or total_secs > 0x7FFFFFFF) return -1;
    return @intCast(total_secs);
}

var clock_start: ?i64 = null;

/// Get elapsed processor time.
/// Implementation status: Partially implemented
pub fn clock() callconv(.c) i32 {
    // CLOCKS_PER_SEC is 1000 on MSVC
    const now = runtime.milliTimestamp();
    if (clock_start == null) clock_start = now;
    const elapsed = now - clock_start.?;
    return @intCast(@min(elapsed, 0x7FFFFFFF));
}

var asctime_buf: [32]u8 = undefined;

/// Convert struct tm to string. Returns a static buffer.
/// Implementation status: Stub
pub fn asctime(tm_ptr: usize) callconv(.c) [*]const u8 {
    _ = tm_ptr;
    const s = "Sat Jan  1 00:00:00 2000\n";
    @memcpy(asctime_buf[0..s.len], s);
    asctime_buf[s.len] = 0;
    // On WASM, allocate in guest memory so x86 code can read it
    const stub_common = @import("../shared.zig");
    if (x86_memory.guest_memory != null) {
        const raw = stub_common.raw_alloc(s.len + 1) orelse return &asctime_buf;
        const ptr = @as([*]u8, @ptrCast(raw));
        @memcpy(ptr[0..s.len], s);
        ptr[s.len] = 0;
        return ptr;
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
