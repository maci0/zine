//! Civil calendar <-> day-count conversions (Howard Hinnant's algorithms).
//!
//! Days are counted from the Unix epoch 1970-01-01. All arithmetic is exact
//! i64 and handles negative day values (dates before 1970) correctly.

/// Days since 1970-01-01 for a civil date (month in 1..12).
pub fn daysFromCivil(year_in: i64, month: i64, day: i64) i64 {
    var y = year_in;
    y -= @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = @mod(month - 3, 12); // March = 0
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

pub const CivilDate = struct { year: i64, month: i64, day: i64 };

/// Civil date (month in 1..12) for a count of days since 1970-01-01.
pub fn civilFromDays(z: i64) CivilDate {
    const z_adj = z + 719468;
    const era = @divFloor(z_adj, 146097);
    const doe = z_adj - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{ .year = y + @intFromBool(m <= 2), .month = m, .day = d };
}

const testing = std.testing;

test "daysFromCivil epoch anchors" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, -134774), daysFromCivil(1601, 1, 1));
}

test "civil round trip over leap years and negatives" {
    const samples = [_][3]i64{
        .{ 1970, 1, 1 },  .{ 1601, 1, 1 },   .{ 1969, 12, 31 },
        .{ 2000, 2, 29 }, .{ 1900, 3, 1 },   .{ 2024, 5, 15 },
        .{ 2038, 1, 19 }, .{ 2400, 12, 31 },
    };
    for (samples) |s| {
        const days = daysFromCivil(s[0], s[1], s[2]);
        const back = civilFromDays(days);
        try testing.expectEqual(s[0], back.year);
        try testing.expectEqual(s[1], back.month);
        try testing.expectEqual(s[2], back.day);
    }
}

test "known day counts" {
    // 2000-03-01 is 11017 days after 1970-01-01.
    try testing.expectEqual(@as(i64, 11017), daysFromCivil(2000, 3, 1));
    // Windows epoch offset: 11644473600 s / 86400 s/day = 134774 days.
    try testing.expectEqual(@as(i64, 134774), daysFromCivil(1970, 1, 1) - daysFromCivil(1601, 1, 1));
}

const std = @import("std");
