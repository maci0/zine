const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const io = @import("io.zig");
const unicase = @import("../unicase.zig");

/// Implementation status: Partially implemented
pub fn strlen(str: [*:0]const u8) callconv(.c) usize {
    const len = std.mem.span(str).len;
    if (trace.enable_tracing) trace.print("MSVCRT: _strlen('{s}') -> {d}\n", .{ std.mem.span(str), len });
    return len;
}

/// Implementation status: Partially implemented
pub fn strcpy(dest: [*]u8, src: [*:0]const u8) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dest[i] = src[i];
    dest[i] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _strcpy('{s}', '{s}')\n", .{ std.mem.span(@as([*:0]const u8, @ptrCast(dest))), std.mem.span(src) });
    return dest;
}

/// Implementation status: Partially implemented
pub fn strncpy(dest: [*]u8, src: [*:0]const u8, count: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < count and src[i] != 0) : (i += 1) dest[i] = src[i];
    if (i < count) @memset(dest[i..count], 0);
    return dest;
}

pub fn strcat(dest: [*]u8, src: [*:0]const u8) callconv(.c) [*]u8 {
    var dest_len: usize = 0;
    while (dest[dest_len] != 0) : (dest_len += 1) {}
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dest[dest_len + i] = src[i];
    dest[dest_len + i] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _strcat('{s}', '{s}')\n", .{ std.mem.span(@as([*:0]const u8, @ptrCast(dest))), std.mem.span(src) });
    return dest;
}

pub fn strncat(dest: [*]u8, src: [*:0]const u8, count: usize) callconv(.c) [*]u8 {
    var dest_len: usize = 0;
    while (dest[dest_len] != 0) : (dest_len += 1) {}
    var i: usize = 0;
    while (i < count and src[i] != 0) : (i += 1) dest[dest_len + i] = src[i];
    dest[dest_len + i] = 0;
    return dest;
}

/// Implementation status: Partially implemented
pub fn strcmp(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) i32 {
    var i: usize = 0;
    while (s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn strncmp(s1: [*:0]const u8, s2: [*:0]const u8, count: usize) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _strncmp('{s}', '{s}', {d})\n", .{ std.mem.span(s1), std.mem.span(s2), count });
    if (count == 0) return 0;
    var i: usize = 0;
    while (i < count and s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    if (i == count) return 0;
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

/// Implementation status: Partially implemented
pub fn stricmp(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) i32 {
    const sp1 = std.mem.span(s1);
    const sp2 = std.mem.span(s2);
    var i: usize = 0;
    var ret: i32 = 0;
    while (i < sp1.len and i < sp2.len) : (i += 1) {
        const c1 = unicase.toLowerAnsiByte(sp1[i]);
        const c2 = unicase.toLowerAnsiByte(sp2[i]);
        if (c1 != c2) {
            ret = @as(i32, c1) - @as(i32, c2);
            break;
        }
    }
    if (ret == 0) {
        if (sp1.len < sp2.len) ret = -1 else if (sp1.len > sp2.len) ret = 1;
    }
    if (trace.enable_tracing) trace.print("MSVCRT: stricmp('{s}', '{s}') = {d}\n", .{ sp1, sp2, ret });
    return ret;
}

pub fn mbsicmp(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) i32 {
    const sp1 = std.mem.span(s1);
    const sp2 = std.mem.span(s2);
    var i: usize = 0;
    while (i < sp1.len and i < sp2.len) : (i += 1) {
        const c1 = unicase.toLowerAnsiByte(sp1[i]);
        const c2 = unicase.toLowerAnsiByte(sp2[i]);
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    const ret: i32 = if (sp1.len < sp2.len) -1 else if (sp1.len > sp2.len) @as(i32, 1) else 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _mbsicmp('{s}', '{s}') = {d}\n", .{ sp1, sp2, ret });
    return ret;
}

pub fn strnicmp(s1: [*:0]const u8, s2: [*:0]const u8, count: usize) callconv(.c) i32 {
    if (count == 0) return 0;
    const sp1 = std.mem.span(s1);
    const sp2 = std.mem.span(s2);
    var i: usize = 0;
    while (i < count and i < sp1.len and i < sp2.len) : (i += 1) {
        const c1 = unicase.toLowerAnsiByte(sp1[i]);
        const c2 = unicase.toLowerAnsiByte(sp2[i]);
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    if (i == count) return 0;
    if (i < sp1.len) return 1;
    if (i < sp2.len) return -1;
    return 0;
}

pub fn strchr(s: [*:0]const u8, c: i32) callconv(.c) ?[*:0]const u8 {
    const target = @as(u8, @intCast(c & 0xFF));
    const span = std.mem.span(s);
    if (target == 0) return @ptrCast(s + span.len);
    if (std.mem.indexOfScalar(u8, span, target)) |idx| return @ptrCast(s + idx);
    return null;
}

pub fn strrchr(s: [*:0]const u8, c: i32) callconv(.c) ?[*:0]const u8 {
    const target = @as(u8, @intCast(c & 0xFF));
    const span = std.mem.span(s);
    if (target == 0) return @ptrCast(s + span.len);
    if (std.mem.lastIndexOfScalar(u8, span, target)) |idx| return @ptrCast(s + idx);
    return null;
}

pub fn strstr(haystack: [*:0]const u8, needle: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const h = std.mem.span(haystack);
    const n = std.mem.span(needle);
    if (n.len == 0) return haystack;
    if (std.mem.indexOf(u8, h, n)) |idx| return @ptrCast(haystack + idx);
    return null;
}

pub fn strpbrk(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) ?[*]u8 {
    const sp1 = std.mem.span(s1);
    const sp2 = std.mem.span(s2);
    if (std.mem.indexOfAny(u8, sp1, sp2)) |idx| return @ptrFromInt(@intFromPtr(s1) + idx);
    return null;
}

pub fn strcspn(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) usize {
    return std.mem.indexOfAny(u8, std.mem.span(s1), std.mem.span(s2)) orelse std.mem.span(s1).len;
}

pub fn strdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const span = std.mem.span(s);
    const stub_common = @import("../shared.zig");
    const raw = stub_common.raw_alloc(span.len + 1) orelse return null;
    const ptr = @as([*]u8, @ptrCast(raw));
    @memcpy(ptr[0..span.len], span);
    ptr[span.len] = 0;
    return @ptrCast(ptr);
}

/// Implementation status: Partially implemented
pub fn wcsdup(str: [*]const u16) callconv(.c) ?[*]u16 {
    const len = std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
    const stub_common = @import("../shared.zig");
    const raw = stub_common.raw_alloc((len + 1) * 2) orelse return null;
    const ptr = @as([*]u16, @ptrCast(@alignCast(raw)));
    @memcpy(ptr[0..len], str[0..len]);
    ptr[len] = 0;
    return ptr;
}

/// Implementation status: Partially implemented
pub fn itoa(value: i32, buffer: [*]u8, radix: i32) callconv(.c) [*]u8 {
    if (trace.enable_tracing) trace.print("MSVCRT: _itoa(value={d}, radix={d})\n", .{ value, radix });
    const slice = buffer[0..33];
    // MSVCRT accepts any radix in 2..36; a value outside that has no digit
    // set, and the empty string is the only result the caller can use.
    if (radix < 2 or radix > 36) {
        buffer[0] = 0;
        return buffer;
    }
    const u: u32 = if (value < 0) ~@as(u32, @bitCast(value)) +% 1 else @as(u32, @bitCast(value));
    if (value < 0) {
        var digits: [32]u8 = undefined;
        const n = formatRadix(u, @intCast(radix), &digits).len;
        if (n + 2 > slice.len) return buffer;
        slice[0] = '-';
        @memcpy(slice[1 .. 1 + n], digits[0..n]);
        slice[1 + n] = 0;
    } else {
        _ = formatRadix(u, @intCast(radix), slice);
    }
    return buffer;
}

/// Writes `value` in `radix` digits with no terminator into `out`, which must
/// have room for all of them, and returns the written prefix.
fn formatRadix(value: u32, radix: u8, out: []u8) []const u8 {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var tmp: [32]u8 = undefined;
    var n: usize = 0;
    var v = value;
    while (true) {
        tmp[n] = digits[v % radix];
        n += 1;
        v /= radix;
        if (v == 0) break;
    }
    for (0..n) |i| out[i] = tmp[n - 1 - i];
    if (out.len > n) out[n] = 0;
    return out[0..n];
}

/// Implementation status: Partially implemented
pub fn strtoul(str_ptr: usize, end_ptr: usize, radix: i32) callconv(.c) u32 {
    if (str_ptr == 0) return 0;
    const str = @as([*:0]const u8, @ptrFromInt(trace.addr(str_ptr)));
    var i: usize = 0;
    while (std.ascii.isWhitespace(str[i])) i += 1;
    var sign: i32 = 1;
    if (str[i] == '-') {
        sign = -1;
        i += 1;
    } else if (str[i] == '+') i += 1;

    // A radix outside 2..36 has no digit set to convert with; C falls back to
    // base 10, and a value too large for u8 to hold must not trap the cast.
    var r: u8 = if (radix >= 2 and radix <= 36) @intCast(radix) else 10;
    // A "0x" prefix alone converts nothing; a leading "0" is a complete octal
    // digit, so "0" and "00" must count as parsed and advance end_ptr past it.
    var parsed = false;
    if (radix == 0) {
        if (str[i] == '0' and (str[i + 1] == 'x' or str[i + 1] == 'X')) {
            r = 16;
            i += 2;
        } else if (str[i] == '0') {
            r = 8;
            i += 1;
            parsed = true;
        } else r = 10;
    } else if (r == 16 and str[i] == '0' and (str[i + 1] == 'x' or str[i + 1] == 'X')) i += 2;

    var val: u32 = 0;
    while (str[i] != 0) : (i += 1) {
        const digit = std.fmt.charToDigit(str[i], r) catch break;
        // Saturate instead of overflowing: a long digit run keeps consuming
        // and pins the result at ULONG_MAX, which is what the C library
        // reports. Wrapping arithmetic would fold "99999999999" to a small
        // positive value.
        const scaled = std.math.mul(u32, val, r) catch std.math.maxInt(u32);
        val = std.math.add(u32, scaled, digit) catch std.math.maxInt(u32);
        parsed = true;
    }
    if (end_ptr != 0) {
        const end_val: u32 = @truncate(if (parsed) str_ptr + i else str_ptr);
        @as(*u32, @ptrFromInt(trace.addr(end_ptr))).* = end_val;
    }
    const final_val = if (sign == -1) ~val +% 1 else val;
    if (trace.enable_tracing) trace.print("MSVCRT: strtoul('{s}', {d}) -> {d}\n", .{ trace.c_span(str_ptr), radix, final_val });
    return final_val;
}

/// Implementation status: Partially implemented
pub fn strtol(str_ptr: usize, end_ptr: usize, radix: i32) callconv(.c) i32 {
    const val = @as(i32, @bitCast(strtoul(str_ptr, end_ptr, radix)));
    if (trace.enable_tracing) {
        trace.print("MSVCRT: strtol('{s}', {d}) -> {d}\n", .{ trace.c_span(str_ptr), radix, val });
    }
    return val;
}

/// Implementation status: Partially implemented
pub fn atoi(str_ptr: usize) callconv(.c) i32 {
    const val = @as(i32, @bitCast(strtoul(str_ptr, 0, 10)));
    if (trace.enable_tracing) {
        if (str_ptr != 0) {
            trace.print("MSVCRT: atoi('{s}') -> {d} from {x}\n", .{ trace.c_span(str_ptr), val, @returnAddress() });
        }
    }
    return val;
}

/// --- Wide String ---
pub fn wcslen(str: [*]const u16) callconv(.c) usize {
    return std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
}

/// _wcsupr. Case mapping is the same one towupper applies, so a string
/// uppercased here compares equal to one uppercased there.
pub fn wcsupr(str: [*]u16) callconv(.c) [*]u16 {
    const len = std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
    for (str[0..len]) |*ch| {
        ch.* = unicase.toUpper(ch.*);
    }
    return str;
}

/// _wcslwr
pub fn wcslwr(str: [*]u16) callconv(.c) [*]u16 {
    const len = std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
    for (str[0..len]) |*ch| {
        ch.* = unicase.toLower(ch.*);
    }
    return str;
}

pub fn wcscpy(dst: [*]u16, src: [*]const u16) callconv(.c) [*]u16 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dst[i] = src[i];
    dst[i] = 0;
    return dst;
}

pub fn wcsncpy(dst: [*]u16, src: [*]const u16, count: usize) callconv(.c) [*]u16 {
    var i: usize = 0;
    while (i < count and src[i] != 0) : (i += 1) dst[i] = src[i];
    while (i < count) : (i += 1) dst[i] = 0;
    return dst;
}

pub fn wcscat(dst: [*]u16, src: [*]const u16) callconv(.c) [*]u16 {
    var dst_len: usize = 0;
    while (dst[dst_len] != 0) : (dst_len += 1) {}
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dst[dst_len + i] = src[i];
    dst[dst_len + i] = 0;
    return dst;
}

pub fn wcscmp(s1: [*]const u16, s2: [*]const u16) callconv(.c) i32 {
    var i: usize = 0;
    while (s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn wcsncmp(s1: [*]const u16, s2: [*]const u16, count: usize) callconv(.c) i32 {
    if (count == 0) return 0;
    var i: usize = 0;
    while (i < count and s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    if (i == count) return 0;
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn wcsicmp(s1: [*]const u16, s2: [*]const u16) callconv(.c) i32 {
    var i: usize = 0;
    while (s1[i] != 0 and s2[i] != 0) : (i += 1) {
        const c1 = unicase.foldKey(s1[i]);
        const c2 = unicase.foldKey(s2[i]);
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn wcsnicmp(s1: [*]const u16, s2: [*]const u16, count: usize) callconv(.c) i32 {
    if (count == 0) return 0;
    var i: usize = 0;
    while (i < count and s1[i] != 0 and s2[i] != 0) : (i += 1) {
        const c1 = unicase.foldKey(s1[i]);
        const c2 = unicase.foldKey(s2[i]);
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    if (i == count) return 0;
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn wcschr(str: [*]const u16, c: i32) callconv(.c) ?[*]const u16 {
    const target = @as(u16, @intCast(c & 0xFFFF));
    const len = std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
    if (target == 0) return str + len;
    if (std.mem.indexOfScalar(u16, str[0..len], target)) |idx| return str + idx;
    return null;
}

pub fn wcsrchr(str: [*]const u16, c: i32) callconv(.c) ?[*]const u16 {
    const target = @as(u16, @intCast(c & 0xFFFF));
    const len = std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
    if (target == 0) return str + len;
    if (std.mem.lastIndexOfScalar(u16, str[0..len], target)) |idx| return str + idx;
    return null;
}

pub fn wcsstr(haystack: [*]const u16, needle: [*]const u16) callconv(.c) ?[*]const u16 {
    const h_len = std.mem.indexOfScalar(u16, haystack[0..65536], 0) orelse 0;
    const n_len = std.mem.indexOfScalar(u16, needle[0..65536], 0) orelse 0;
    if (n_len == 0) return haystack;
    if (h_len < n_len) return null;
    var i: usize = 0;
    while (i <= h_len - n_len) : (i += 1) {
        if (std.mem.eql(u16, haystack[i..][0..n_len], needle[0..n_len])) return haystack + i;
    }
    return null;
}

/// wcstol — keeps end_ptr as usize (writes guest VA back)
pub fn wcstol(str: [*]const u16, end_ptr: usize, radix: i32) callconv(.c) i32 {
    var i: usize = 0;
    while (str[i] != 0 and std.ascii.isWhitespace(@intCast(str[i] & 0xFF))) i += 1;
    var sign: i32 = 1;
    if (str[i] == '-') {
        sign = -1;
        i += 1;
    } else if (str[i] == '+') i += 1;
    // A radix outside 2..36 has no digit set to convert with; C falls back to
    // base 10 rather than trapping on the u8 cast.
    var r: u8 = if (radix >= 2 and radix <= 36) @intCast(radix) else 10;
    if (radix == 0) {
        if (str[i] == '0' and (str[i + 1] == 'x' or str[i + 1] == 'X')) {
            r = 16;
            i += 2;
        } else if (str[i] == '0') {
            r = 8;
            i += 1;
        } else r = 10;
    } else if (r == 16 and str[i] == '0' and (str[i + 1] == 'x' or str[i + 1] == 'X')) i += 2;
    var val: i32 = 0;
    var parsed = false;
    // Saturate on a long digit run, matching strtoul: wrapping arithmetic
    // would fold "99999999999" to a small value.
    var overflow = false;
    while (str[i] != 0) : (i += 1) {
        const digit = std.fmt.charToDigit(@intCast(str[i] & 0xFF), r) catch break;
        if (overflow) continue;
        const scaled = std.math.mul(i32, val, @intCast(r)) catch {
            overflow = true;
            continue;
        };
        val = std.math.add(i32, scaled, @intCast(digit)) catch {
            overflow = true;
            continue;
        };
        parsed = true;
    }
    // end_ptr stays usize — writes back a guest VA for x86 code
    if (end_ptr != 0) {
        const end_val: u32 = @truncate(if (parsed) @intFromPtr(str) + i * 2 else @intFromPtr(str));
        @as(*u32, @ptrFromInt(end_ptr)).* = end_val;
    }
    if (overflow) return if (sign == -1) std.math.minInt(i32) else std.math.maxInt(i32);
    return val *% sign;
}

pub fn wtoi(str: [*]const u16) callconv(.c) i32 {
    var i: usize = 0;
    while (str[i] != 0 and std.ascii.isWhitespace(@intCast(str[i] & 0xFF))) i += 1;
    var sign: i32 = 1;
    if (str[i] == '-') {
        sign = -1;
        i += 1;
    } else if (str[i] == '+') i += 1;
    var val: i32 = 0;
    var overflow = false;
    while (str[i] >= '0' and str[i] <= '9') {
        if (!overflow) {
            const scaled = std.math.mul(i32, val, 10) catch {
                overflow = true;
                i += 1;
                continue;
            };
            val = std.math.add(i32, scaled, @as(i32, str[i] - '0')) catch {
                overflow = true;
                i += 1;
                continue;
            };
        }
        i += 1;
    }
    if (overflow) return if (sign == -1) std.math.minInt(i32) else std.math.maxInt(i32);
    return val *% sign;
}

/// Implementation status: Partially implemented
pub fn init_pctype() void {
    const pctype_data = [_]u16{
        0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0028, 0x0028, 0x0028, 0x0028, 0x0028, 0x0020, 0x0020,
        0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020, 0x0020,
        0x0048, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010,
        0x0084, 0x0084, 0x0084, 0x0084, 0x0084, 0x0084, 0x0084, 0x0084, 0x0084, 0x0084, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010,
        0x0010, 0x0081, 0x0081, 0x0081, 0x0081, 0x0081, 0x0081, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001,
        0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001, 0x0010, 0x0010, 0x0010, 0x0010, 0x0010,
        0x0010, 0x0082, 0x0082, 0x0082, 0x0082, 0x0082, 0x0082, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002,
        0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0002, 0x0010, 0x0010, 0x0010, 0x0010, 0x0020,
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
    };
    msvcrt.msvcrt_pctype[0] = 0; // EOF
    @memcpy(msvcrt.msvcrt_pctype[1..257], pctype_data[0..256]);

    const mbctype_data = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
        0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
        0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x10,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x20, 0x00, 0x20,
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
        0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x00, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
        0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
        0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
    };
    msvcrt.msvcrt_mbctype[0] = 0; // EOF
    @memcpy(msvcrt.msvcrt_mbctype[1..257], mbctype_data[0..256]);
}

/// Implementation status: Partially implemented
pub fn p_pctype() callconv(.c) *?*u16 {
    const process = @import("process.zig");
    const g = process.ensureGuestGlobals();
    if (g != 0) return @ptrFromInt(g + process.g_pctype_ptr);

    const static = struct {
        var p: ?*u16 = null;
    };
    if (static.p == null) static.p = @ptrCast(@constCast(&msvcrt.msvcrt_pctype[1]));
    return @ptrCast(@constCast(&static.p));
}

/// Implementation status: Partially implemented
pub fn isalnum(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0107; // _ALPHA | _DIGIT
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn isalpha(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        const res = msvcrt.msvcrt_pctype[index] & 0x0103; // _ALPHA | _UPPER | _LOWER
        if (trace.enable_tracing) trace.print("MSVCRT: isalpha({d}) -> {x}\n", .{ c, res });
        return res;
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn isdigit(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0004; // _DIGIT
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn isupper(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0001; // _UPPER
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn islower(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0002; // _LOWER
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn isspace(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        const res = msvcrt.msvcrt_pctype[index] & 0x0008; // _SPACE
        if (trace.enable_tracing) trace.print("MSVCRT: isspace({d}) -> {x}\n", .{ c, res });
        return res;
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn isxdigit(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0080; // _HEX
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn isprint(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0157; // _BLANK | _PUNCT | _ALPHA | _DIGIT
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn ispunct(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0010; // _PUNCT
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn isctype(c: i32, mask: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return if ((msvcrt.msvcrt_pctype[index] & @as(u16, @intCast(mask & 0xFFFF))) != 0) 1 else 0;
    }
    return 0;
}

/// Implementation status: Partially implemented
pub fn tolower(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    if (v <= 255) return unicase.toLowerAnsiByte(@intCast(v));
    return v;
}

/// Implementation status: Partially implemented
pub fn toupper(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    if (v <= 255) return unicase.toUpperAnsiByte(@intCast(v));
    return v;
}

/// Implementation status: Partially implemented
pub fn iswctype(c: i32, desc: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        const res = if ((msvcrt.msvcrt_pctype[index] & @as(u16, @intCast(desc & 0xFFFF))) != 0) @as(i32, 1) else @as(i32, 0);
        if (trace.enable_tracing) trace.print("MSVCRT: iswctype({d}, {x}) -> {d}\n", .{ c, desc, res });
        return res;
    }
    if (trace.enable_tracing) trace.print("MSVCRT: iswctype({d}, {x}) -> 0 (out of bounds)\n", .{ c, desc });
    return 0;
}

/// Implementation status: Partially implemented
pub fn towupper(c: i32) callconv(.c) i32 {
    return unicase.toUpper(@as(u16, @intCast(c & 0xFFFF)));
}

/// Implementation status: Partially implemented
pub fn towlower(c: i32) callconv(.c) i32 {
    return unicase.toLower(@as(u16, @intCast(c & 0xFFFF)));
}

/// Implementation status: Partially implemented
pub fn ismbcspace(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    return if (v == ' ' or v == '\t' or v == '\n' or v == '\r' or v == 0x0B or v == 0x0C) 1 else 0;
}

/// Implementation status: Partially implemented
pub fn mbsinc(str: ?[*]const u8) callconv(.c) ?[*]const u8 {
    if (str) |s| {
        if (s[0] == 0) return null;
        return s + 1;
    }
    return null;
}

/// Implementation status: Partially implemented
pub fn mbccpy(dest: [*]u8, src: [*]const u8) callconv(.c) void {
    dest[0] = src[0];
}

/// Implementation status: Partially implemented
pub fn mbclen(c_ptr: usize) callconv(.c) usize {
    return if (c_ptr == 0) 0 else 1;
}

/// Implementation status: Partially implemented
pub fn mbsdec(start: ?[*]const u8, current: ?[*]const u8) callconv(.c) ?[*]const u8 {
    if (start == null or current == null or @intFromPtr(current.?) <= @intFromPtr(start.?)) return null;
    if (trace.enable_tracing) trace.print("MSVCRT: _mbsdec(start={x}, current={x}) -> {x}\n", .{ @intFromPtr(start.?), @intFromPtr(current.?), @intFromPtr(current.?) - 1 });
    return current.? - 1;
}

/// --- Generic Stubs ---
/// Implementation status: Partially implemented
pub fn iscntrl(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0020; // _CONTROL
    }
    return 0;
}

pub fn atof(str: [*:0]const u8) callconv(.c) f64 {
    return std.fmt.parseFloat(f64, std.mem.span(str)) catch 0.0;
}

/// _strlwr. Folds CP1252 bytes through the same mapping tolower applies, so
/// a string lowercased here matches the same string compared by stricmp.
pub fn strlwr(str: ?[*:0]u8) callconv(.c) ?[*:0]u8 {
    if (str) |s_ptr| {
        const s = std.mem.span(s_ptr);
        for (s) |*c| {
            c.* = unicase.toLowerAnsiByte(c.*);
        }
        return s_ptr;
    }
    return null;
}

/// _strupr
pub fn strupr(str: ?[*:0]u8) callconv(.c) ?[*:0]u8 {
    if (str) |s_ptr| {
        const s = std.mem.span(s_ptr);
        for (s) |*c| {
            c.* = unicase.toUpperAnsiByte(c.*);
        }
        return s_ptr;
    }
    return null;
}

var strtok_state: ?[*:0]u8 = null;

/// _strtok
pub fn strtok(str: ?[*:0]u8, delim: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const s_ptr = str orelse strtok_state orelse return null;
    const d_ptr = delim orelse return null;
    if (trace.enable_tracing) trace.print("MSVCRT: _strtok('{s}', '{s}')\n", .{ std.mem.span(s_ptr), std.mem.span(d_ptr) });

    var s = std.mem.span(s_ptr);
    const d = std.mem.span(d_ptr);

    // Skip leading delimiters
    var start: usize = 0;
    while (start < s.len and std.mem.indexOfScalar(u8, d, s[start]) != null) : (start += 1) {}

    if (start == s.len) {
        strtok_state = null;
        return null;
    }

    // Find next delimiter
    var end = start;
    while (end < s.len and std.mem.indexOfScalar(u8, d, s[end]) == null) : (end += 1) {}

    if (end < s.len) {
        s[end] = 0;
        strtok_state = @ptrCast(s.ptr + end + 1);
    } else {
        strtok_state = null;
    }

    return @ptrCast(s.ptr + start);
}

// --- narrow string copy/concat ---

test "strcpy and strcat keep the terminator and the return value" {
    var buf: [16]u8 = undefined;
    const dest: [*]u8 = @ptrCast(&buf);

    try std.testing.expectEqual(dest, strcpy(dest, "hello"));
    try std.testing.expectEqualStrings("hello", std.mem.span(@as([*:0]u8, @ptrCast(&buf))));

    try std.testing.expectEqual(dest, strcat(dest, " world"));
    try std.testing.expectEqualStrings("hello world", std.mem.span(@as([*:0]u8, @ptrCast(&buf))));
}

test "strncpy pads with NUL and truncates without one" {
    var buf: [8]u8 = @splat(0xAB);
    const dest: [*]u8 = @ptrCast(&buf);

    // Source shorter than count: the remainder is zero-filled.
    _ = strncpy(dest, "ab", 6);
    try std.testing.expectEqualSlices(u8, "ab\x00\x00\x00\x00", buf[0..6]);

    // Source longer than count: exactly count bytes land, no terminator.
    _ = strncpy(dest, "abcdef", 3);
    try std.testing.expectEqualSlices(u8, "abc\x00", buf[0..4]);

    // count == 0 touches nothing.
    const untouched: [8]u8 = @splat(0x5A);
    buf = untouched;
    _ = strncpy(dest, "xyz", 0);
    try std.testing.expectEqualSlices(u8, &untouched, &buf);
}

test "strncat appends at most count bytes" {
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..3], "ab\x00");
    _ = strncat(@ptrCast(&buf), "cdef", 2);
    try std.testing.expectEqualStrings("abcd", std.mem.span(@as([*:0]u8, @ptrCast(&buf))));

    // A count past the source end stops at the source's NUL, not at count.
    _ = strncat(@ptrCast(&buf), "gh", 9);
    try std.testing.expectEqualStrings("abcdgh", std.mem.span(@as([*:0]u8, @ptrCast(&buf))));
}

test "strlen measures the span up to the first NUL" {
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..4], "abc\x00");
    buf[4] = 'X'; // must not be counted
    try std.testing.expectEqual(@as(usize, 3), strlen(@ptrCast(&buf)));
    try std.testing.expectEqual(@as(usize, 0), strlen(""));
}

// --- narrow comparison ---

test "strcmp sign and magnitude follow the first differing byte" {
    try std.testing.expect(strcmp("abc", "abc") == 0);
    try std.testing.expect(strcmp("abc", "abd") < 0);
    try std.testing.expect(strcmp("abd", "abc") > 0);
    // A prefix sorts before the longer string.
    try std.testing.expect(strcmp("ab", "abc") < 0);
    try std.testing.expect(strcmp("abc", "ab") > 0);
    try std.testing.expectEqual(@as(i32, 'a' - 'A'), strcmp("a", "A"));
    try std.testing.expectEqual(@as(i32, 'a' - 'b'), strcmp("a", "b"));
}

test "strncmp stops at count and treats count 0 as equal" {
    try std.testing.expect(strncmp("abcdef", "abcxyz", 3) == 0);
    try std.testing.expect(strncmp("abcdef", "abcxyz", 4) < 0);
    try std.testing.expect(strncmp("abc", "ab", 2) == 0);
    // Comparing up to the shorter string's NUL still reports a difference.
    try std.testing.expect(strncmp("abc", "ab", 5) > 0);
    try std.testing.expect(strncmp("anything", "different", 0) == 0);
}

test "stricmp folds case and still orders by length" {
    try std.testing.expect(stricmp("Hello", "hELLO") == 0);
    try std.testing.expect(stricmp("abc", "abd") < 0);
    try std.testing.expect(stricmp("ab", "ABC") < 0);
    try std.testing.expect(stricmp("ABC", "ab") > 0);
    try std.testing.expectEqual(@as(i32, 'a' - 'b'), stricmp("A", "b"));
}

test "strnicmp folds case within count and orders by length past it" {
    try std.testing.expect(strnicmp("Hello", "hELLOxyz", 5) == 0);
    try std.testing.expect(strnicmp("Hello", "hELLOxyz", 6) < 0);
    try std.testing.expect(strnicmp("ab", "ABC", 5) < 0);
    try std.testing.expect(strnicmp("ABC", "ab", 5) > 0);
    try std.testing.expect(strnicmp("same", "diff", 0) == 0);
}

test "mbsicmp folds case like stricmp" {
    try std.testing.expect(mbsicmp("Hello", "hELLO") == 0);
    try std.testing.expect(mbsicmp("ab", "ABC") < 0);
    try std.testing.expect(mbsicmp("ABC", "ab") > 0);
    try std.testing.expectEqual(@as(i32, 'a' - 'b'), mbsicmp("A", "b"));
}

// --- narrow search ---

test "strchr finds the first and last occurrence and the terminator" {
    try std.testing.expectEqual(@as(usize, 1), @intFromPtr(strchr("abcabc", 'b').?) - @intFromPtr("abcabc"));
    const r = strrchr("abcabc", 'b');
    try std.testing.expectEqual(@as(usize, 4), @intFromPtr(r.?) - @intFromPtr("abcabc"));
    // Searching for NUL yields the terminator, not a null pointer.
    try std.testing.expectEqual(@as(usize, 6), @intFromPtr(strchr("abcdef", 0).?) - @intFromPtr("abcdef"));
    try std.testing.expectEqual(@as(usize, 6), @intFromPtr(strrchr("abcdef", 0).?) - @intFromPtr("abcdef"));
    try std.testing.expect(strchr("abcdef", 'z') == null);
    try std.testing.expect(strrchr("abcdef", 'z') == null);
}

test "strstr returns the haystack for an empty needle and null when absent" {
    var hay = "abcabc".*;
    try std.testing.expectEqual(@intFromPtr(&hay), @intFromPtr(strstr(&hay, "").?));
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(strstr(&hay, "abc").?) - @intFromPtr(&hay));
    try std.testing.expectEqual(@as(usize, 2), @intFromPtr(strstr(&hay, "cab").?) - @intFromPtr(&hay));
    try std.testing.expect(strstr("abcabc", "abd") == null);
    // A needle longer than the haystack cannot match.
    try std.testing.expect(strstr("ab", "abc") == null);
}

test "strpbrk and strcspn use the first byte present in the reject set" {
    const s = "hello world";
    try std.testing.expectEqual(@as(usize, 4), @intFromPtr(strpbrk(s, "ow").?) - @intFromPtr(s));
    try std.testing.expect(strpbrk(s, "xyz") == null);

    try std.testing.expectEqual(@as(usize, 4), strcspn(s, "ow"));
    try std.testing.expectEqual(@as(usize, 11), strcspn(s, "xyz"));
    try std.testing.expectEqual(@as(usize, 0), strcspn(s, "h"));
}

test "strdup copies the span and terminates it" {
    const dup = strdup("hello").?;
    try std.testing.expectEqualStrings("hello", std.mem.span(dup));
    // The copy is independent of the source buffer.
    var src: [5]u8 = "hello".*;
    try std.testing.expect(dup != @as([*]u8, @ptrCast(&src)));
}

test "strlwr and strupr return the same pointer and leave non-letters alone" {
    var buf: [8]u8 = "MiXeD9\x00\x00".*;
    const p: [*:0]u8 = @ptrCast(&buf);
    try std.testing.expectEqual(@intFromPtr(p), @intFromPtr(strlwr(p).?));
    try std.testing.expectEqualStrings("mixed9", std.mem.span(p));
    try std.testing.expectEqual(@intFromPtr(p), @intFromPtr(strupr(p).?));
    try std.testing.expectEqualStrings("MIXED9", std.mem.span(p));

    try std.testing.expect(strlwr(null) == null);
    try std.testing.expect(strupr(null) == null);
}

// --- numeric parsing ---

test "itoa formats any radix in 2..36 and rejects the rest" {
    var buf: [33]u8 = undefined;
    try std.testing.expectEqualStrings("-42", std.mem.span(@as([*:0]u8, @ptrCast(itoa(-42, @ptrCast(&buf), 10)))));
    try std.testing.expectEqualStrings("ff", std.mem.span(@as([*:0]u8, @ptrCast(itoa(255, @ptrCast(&buf), 16)))));
    try std.testing.expectEqualStrings("5", std.mem.span(@as([*:0]u8, @ptrCast(itoa(5, @ptrCast(&buf), 8)))));
    try std.testing.expectEqualStrings("377", std.mem.span(@as([*:0]u8, @ptrCast(itoa(255, @ptrCast(&buf), 8)))));
    try std.testing.expectEqualStrings("-1010", std.mem.span(@as([*:0]u8, @ptrCast(itoa(-10, @ptrCast(&buf), 2)))));
    try std.testing.expectEqualStrings("zz", std.mem.span(@as([*:0]u8, @ptrCast(itoa(1295, @ptrCast(&buf), 36)))));
    buf[1] = 'X';
    _ = itoa(5, @ptrCast(&buf), 1);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    _ = itoa(5, @ptrCast(&buf), 37);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
}

test "strtoul honours the radix, sign, and 0x prefix" {
    const check = struct {
        fn parse(text: [*:0]const u8, radix: i32) !struct { val: u32, end: u32 } {
            var end: u32 = 0xDEAD_BEEF;
            const val = strtoul(@intFromPtr(text), @intFromPtr(&end), radix);
            return .{ .val = val, .end = end };
        }
    }.parse;

    const dec = try check("  42xyz", 10);
    try std.testing.expectEqual(@as(u32, 42), dec.val);
    try std.testing.expectEqual(@as(u32, 4), dec.end - @intFromPtr("  42xyz"));

    const hex = try check("0x1F", 16);
    try std.testing.expectEqual(@as(u32, 0x1F), hex.val);
    try std.testing.expectEqual(@as(u32, 4), hex.end - @intFromPtr("0x1F"));

    // radix 16 also tolerates the prefix when asked explicitly.
    const hex2 = try check("0x10", 16);
    try std.testing.expectEqual(@as(u32, 0x10), hex2.val);

    // A leading '-' is folded into the two's complement result.
    const neg = try check("-1", 10);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), neg.val);

    const plus = try check("+7", 10);
    try std.testing.expectEqual(@as(u32, 7), plus.val);
}

test "strtoul infers the radix from the prefix when radix is 0" {
    const check = struct {
        fn parse(text: [*:0]const u8) !struct { val: u32, end: u32 } {
            var end: u32 = 0xDEAD_BEEF;
            const val = strtoul(@intFromPtr(text), @intFromPtr(&end), 0);
            return .{ .val = val, .end = end };
        }
    }.parse;

    const octal = try check("0755");
    try std.testing.expectEqual(@as(u32, 493), octal.val); // 0755 octal
    try std.testing.expectEqual(@as(u32, 4), octal.end - @intFromPtr("0755"));

    const auto_hex = try check("0x20");
    try std.testing.expectEqual(@as(u32, 0x20), auto_hex.val);
    try std.testing.expectEqual(@as(u32, 4), auto_hex.end - @intFromPtr("0x20"));

    const decimal = try check("12");
    try std.testing.expectEqual(@as(u32, 12), decimal.val);

    // A lone "0" is a complete conversion of one digit, not an empty one.
    const zero = try check("0");
    try std.testing.expectEqual(@as(u32, 0), zero.val);
    try std.testing.expectEqual(@as(u32, 1), zero.end - @intFromPtr("0"));
}

test "strtoul reports an unparsable string by leaving end at the start" {
    var end: u32 = 0xDEAD_BEEF;
    const text = "  nope";
    try std.testing.expectEqual(@as(u32, 0), strtoul(@intFromPtr(text), @intFromPtr(&end), 10));
    try std.testing.expectEqual(@intFromPtr(text), @as(usize, end));

    // Digits before a non-digit are still consumed.
    try std.testing.expectEqual(@as(u32, 12), strtoul(@intFromPtr("12!"), 0, 10));
    try std.testing.expectEqual(@as(u32, 0), strtoul(0, 0, 10));
}

test "strtol and atoi share strtoul's parsing with a signed result" {
    try std.testing.expectEqual(@as(i32, -42), strtol(@intFromPtr("-42"), 0, 10));
    try std.testing.expectEqual(@as(i32, 0x7FFFFFFF), strtol(@intFromPtr("2147483647"), 0, 10));
    try std.testing.expectEqual(@as(i32, 123), atoi(@intFromPtr("  123")));
    try std.testing.expectEqual(@as(i32, -7), atoi(@intFromPtr("-7")));
    try std.testing.expectEqual(@as(i32, 0), atoi(@intFromPtr("junk")));
    try std.testing.expectEqual(@as(i32, 0), atoi(0));
}

test "strtoul saturates a long digit run and rejects a bad radix" {
    var end: u32 = 0xDEAD_BEEF;
    // Ten digits of 9 overflows u32; the result pins at ULONG_MAX and every
    // digit is still consumed.
    try std.testing.expectEqual(
        @as(u32, std.math.maxInt(u32)),
        strtoul(@intFromPtr("99999999999"), @intFromPtr(&end), 10),
    );
    try std.testing.expectEqual(@as(u32, 11), end - @intFromPtr("99999999999"));
    // Hexadecimal overflow takes the same path.
    try std.testing.expectEqual(
        @as(u32, std.math.maxInt(u32)),
        strtoul(@intFromPtr("1FFFFFFFFF"), 0, 16),
    );
    // A radix with no digit set converts as base 10 instead of trapping.
    try std.testing.expectEqual(@as(u32, 42), strtoul(@intFromPtr("42"), 0, 300));
    try std.testing.expectEqual(@as(u32, 10), strtoul(@intFromPtr("10"), 0, 1));
    // Negation still applies to the saturated value, so the result is the
    // two's complement of ULONG_MAX rather than a clamp at LONG_MIN.
    try std.testing.expectEqual(@as(i32, 1), strtol(@intFromPtr("-99999999999"), 0, 10));
}

test "atof parses a float and yields zero for junk" {
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), atof("3.5"), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -0.25), atof("-0.25"), 1e-12);
    try std.testing.expectEqual(@as(f64, 0.0), atof("not a number"));
}

// --- wide strings ---

/// Widens an ASCII literal into a NUL-terminated u16 array for the wide stubs.
fn wide(comptime text: []const u8) [text.len + 1]u16 {
    comptime var out: [text.len + 1]u16 = undefined;
    inline for (text, 0..) |c, i| out[i] = c;
    out[text.len] = 0;
    return out;
}

test "wcslen, wcscpy, wcsncpy, and wcscat round trip wide text" {
    var buf: [16]u16 = undefined;
    const dst: [*]u16 = @ptrCast(&buf);

    var src = wide("wide");
    try std.testing.expectEqual(dst, wcscpy(dst, &src));
    try std.testing.expectEqual(@as(usize, 4), wcslen(dst));
    try std.testing.expectEqualSlices(u16, &src, buf[0..5]);

    // A source longer than count leaves the unit at count untouched, C style:
    // wcsncpy only guarantees a terminator when the source fits.
    var long_src = wide("abcdef");
    _ = wcsncpy(dst, &long_src, 3);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, buf[0..3]);
    try std.testing.expectEqual(@as(u16, 'e'), buf[3]);

    // A source shorter than count is NUL-padded out to count.
    var short_src = wide("ab");
    _ = wcsncpy(dst, &short_src, 5);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 0, 0, 0 }, buf[0..5]);
    try std.testing.expectEqual(@as(usize, 2), wcslen(dst));

    var tail = wide("cat");
    try std.testing.expectEqual(dst, wcscat(dst, &tail));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c', 'a', 't', 0 }, buf[0..6]);
    try std.testing.expectEqual(@as(usize, 5), wcslen(dst));
}

test "wcsupr uppercases ASCII in place" {
    var buf: [8]u16 = .{ 'M', 'i', 'X', 'e', 'D', '9', 0, 0 };
    const p: [*]u16 = @ptrCast(&buf);
    try std.testing.expectEqual(@intFromPtr(p), @intFromPtr(wcsupr(p)));
    try std.testing.expectEqualSlices(u16, &.{ 'M', 'I', 'X', 'E', 'D', '9', 0 }, buf[0..7]);
}

test "wcsupr and wcslwr fold the same characters towupper and towlower do" {
    // A guest that normalizes with the wide APIs must not be left with the
    // string unchanged: 0x00E9 (e acute) and 0x0430 (Cyrillic a) both fold.
    var buf: [8]u16 = .{ 0x00E9, 0x0430, 'a', '9', 0, 0, 0, 0 };
    const p: [*]u16 = @ptrCast(&buf);
    try std.testing.expectEqual(@intFromPtr(p), @intFromPtr(wcslwr(p)));
    try std.testing.expectEqualSlices(u16, &.{ 0x00E9, 0x0430, 'a', '9', 0 }, buf[0..5]);

    try std.testing.expectEqual(@intFromPtr(p), @intFromPtr(wcsupr(p)));
    try std.testing.expectEqualSlices(u16, &.{ 0x00C9, 0x0410, 'A', '9', 0 }, buf[0..5]);

    // A surrogate pair is outside the simple mapping and is left alone.
    var astral: [4]u16 = .{ 0xD83D, 0xDE00, 0, 0 };
    const ap: [*]u16 = @ptrCast(&astral);
    _ = wcsupr(ap);
    _ = wcslwr(ap);
    try std.testing.expectEqualSlices(u16, &.{ 0xD83D, 0xDE00, 0 }, astral[0..3]);
}

test "strlwr and strupr fold CP1252 the way tolower and toupper do" {
    // "É" is 0xC9 in CP1252. ASCII-only folding left it uppercase, so a
    // string normalized with _strlwr did not match under _stricmp.
    var buf: [5]u8 = "CAF\xC9\x00".*;
    const p: [*:0]u8 = @ptrCast(&buf);
    try std.testing.expectEqual(@intFromPtr(p), @intFromPtr(strlwr(p).?));
    try std.testing.expectEqualSlices(u8, &.{ 'c', 'a', 'f', 0xE9 }, buf[0..4]);
    try std.testing.expectEqual(@as(i32, 0), stricmp(@ptrCast(&buf), "caf\xE9"));

    try std.testing.expectEqual(@intFromPtr(p), @intFromPtr(strupr(p).?));
    try std.testing.expectEqualSlices(u8, &.{ 'C', 'A', 'F', 0xC9 }, buf[0..4]);
    try std.testing.expectEqual(@as(i32, 0), stricmp(@ptrCast(&buf), "CAF\xC9"));

    // The euro sign has no simple case mapping and survives both directions.
    var euro: [4]u8 = .{ 0x80, 0, 0, 0 };
    const ep: [*:0]u8 = @ptrCast(&euro);
    _ = strlwr(ep);
    _ = strupr(ep);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0 }, euro[0..2]);
}

test "wcs family comparisons fold case only below 256" {
    var a = wide("abc");
    var a2 = wide("abc");
    var abd = wide("abd");
    var prefix = wide("ab");
    var mixed = wide("Hello");
    var folded = wide("hELLO");
    var longer = wide("hELLOxyz");

    try std.testing.expect(wcscmp(&a, &a2) == 0);
    try std.testing.expect(wcscmp(&a, &abd) < 0);
    try std.testing.expect(wcscmp(&prefix, &a) < 0);
    try std.testing.expectEqual(@as(i32, 'a' - 'A'), wcscmp(&.{ 'a', 0 }, &.{ 'A', 0 }));

    try std.testing.expect(wcsncmp(&a, &abd, 2) == 0);
    try std.testing.expect(wcsncmp(&a, &abd, 3) < 0);
    try std.testing.expect(wcsncmp(&a, &abd, 0) == 0);

    try std.testing.expect(wcsicmp(&mixed, &folded) == 0);
    try std.testing.expect(wcsicmp(&prefix, &folded) < 0);
    try std.testing.expectEqual(@as(i32, 'a' - 'b'), wcsicmp(&.{ 'A', 0 }, &.{ 'b', 0 }));
    // Code units above 255 are compared as-is, never folded.
    const high_a = [_]u16{ 0x0410, 0 };
    const high_b = [_]u16{ 0x0411, 0 };
    try std.testing.expect(wcsicmp(&high_a, &high_b) < 0);

    try std.testing.expect(wcsnicmp(&mixed, &longer, 5) == 0);
    try std.testing.expect(wcsnicmp(&mixed, &longer, 6) < 0);
    try std.testing.expect(wcsnicmp(&prefix, &folded, 5) < 0);
    try std.testing.expect(wcsnicmp(&prefix, &folded, 0) == 0);
}

test "wcschr, wcsrchr, and wcsstr search by code unit" {
    var buf = wide("abcabc");
    const s: [*]const u16 = @ptrCast(&buf);
    // Pointer arithmetic yields bytes, so each code unit counts twice.
    const unit = @sizeOf(u16);
    try std.testing.expectEqual(@as(usize, 1 * unit), @intFromPtr(wcschr(s, 'b').?) - @intFromPtr(s));
    try std.testing.expectEqual(@as(usize, 4 * unit), @intFromPtr(wcsrchr(s, 'b').?) - @intFromPtr(s));
    try std.testing.expectEqual(@as(usize, 6 * unit), @intFromPtr(wcschr(s, 0).?) - @intFromPtr(s));
    try std.testing.expectEqual(@as(usize, 6 * unit), @intFromPtr(wcsrchr(s, 0).?) - @intFromPtr(s));
    try std.testing.expect(wcschr(s, 'z') == null);
    try std.testing.expect(wcsrchr(s, 'z') == null);

    var empty = wide("");
    try std.testing.expectEqual(@intFromPtr(s), @intFromPtr(wcsstr(s, &empty).?));
    var needle = wide("cab");
    try std.testing.expectEqual(@as(usize, 2 * unit), @intFromPtr(wcsstr(s, &needle).?) - @intFromPtr(s));
    var absent = wide("abd");
    try std.testing.expect(wcsstr(s, &absent) == null);
    var short_hay = wide("ab");
    var longer_needle = wide("abc");
    try std.testing.expect(wcsstr(&short_hay, &longer_needle) == null);
}

test "wtoi and wcstol parse decimal and hexadecimal text" {
    var padded = wide("  123");
    var neg = wide("-7");
    var trailing = wide("12abc");
    var junk = wide("abc");
    try std.testing.expectEqual(@as(i32, 123), wtoi(&padded));
    try std.testing.expectEqual(@as(i32, -7), wtoi(&neg));
    try std.testing.expectEqual(@as(i32, 12), wtoi(&trailing));
    try std.testing.expectEqual(@as(i32, 0), wtoi(&junk));

    var hex = wide("0x1F");
    var end: u32 = 0xDEAD_BEEF;
    try std.testing.expectEqual(@as(i32, 0x1F), wcstol(&hex, @intFromPtr(&end), 0));
    // end is a u32 guest VA, so compare in u32: 4 u16 = 8 bytes past the start.
    try std.testing.expectEqual(@as(u32, 8), end - @as(u32, @truncate(@intFromPtr(&hex))));

    var dec = wide("-42");
    try std.testing.expectEqual(@as(i32, -42), wcstol(&dec, 0, 10));
    try std.testing.expectEqual(@as(i32, 0), wcstol(&junk, 0, 10));
}

test "wcsdup copies the wide span and terminates it" {
    var src = wide("wide");
    const dup = wcsdup(&src).?;
    try std.testing.expectEqual(@as(usize, 4), wcslen(dup));
    try std.testing.expectEqualSlices(u16, &src, dup[0..5]);
    try std.testing.expect(dup != @as([*]u16, @ptrCast(&src)));
}

// --- character classification ---

test "isalpha and friends classify digits, letters, and punctuation" {
    init_pctype();
    inline for (.{ '0', '5', '9' }) |c| {
        try std.testing.expect(isdigit(c) != 0);
        try std.testing.expect(isxdigit(c) != 0);
        try std.testing.expect(isalnum(c) != 0);
        try std.testing.expectEqual(@as(i32, 0), isalpha(c));
        try std.testing.expectEqual(@as(i32, 0), isupper(c));
        try std.testing.expectEqual(@as(i32, 0), islower(c));
    }
    inline for (.{ 'A', 'M', 'Z' }) |c| {
        try std.testing.expect(isalpha(c) != 0);
        try std.testing.expect(isupper(c) != 0);
        try std.testing.expect(isalnum(c) != 0);
        try std.testing.expectEqual(@as(i32, 0), islower(c));
    }
    inline for (.{ 'a', 'm', 'z' }) |c| {
        try std.testing.expect(isalpha(c) != 0);
        try std.testing.expect(islower(c) != 0);
        try std.testing.expect(isalnum(c) != 0);
        try std.testing.expectEqual(@as(i32, 0), isupper(c));
    }
    inline for (.{ ' ', '\t', '\n' }) |c| {
        try std.testing.expect(isspace(c) != 0);
        try std.testing.expectEqual(@as(i32, 0), isalnum(c));
    }
    inline for (.{ '!', '+', '/' }) |c| {
        try std.testing.expect(ispunct(c) != 0);
        try std.testing.expect(isprint(c) != 0);
        try std.testing.expectEqual(@as(i32, 0), isalnum(c));
    }
    inline for (.{ 'a', 'F', '9' }) |c| try std.testing.expect(isxdigit(c) != 0);
    // Control characters are the only non-printing non-space characters.
    try std.testing.expect(iscntrl(0x01) != 0);
    try std.testing.expectEqual(@as(i32, 0), iscntrl('a'));
}

test "classification rejects codes outside the 0..255 table and EOF" {
    init_pctype();
    inline for (.{ isalpha, isalnum, isdigit, isupper, islower, isspace, isxdigit, isprint, ispunct, iscntrl }) |f| {
        try std.testing.expectEqual(@as(i32, 0), f(-1));
        try std.testing.expectEqual(@as(i32, 0), f(256));
        try std.testing.expectEqual(@as(i32, 0), f(0x10000));
    }
    try std.testing.expectEqual(@as(i32, 0), isctype(256, 0xFFFF));
    try std.testing.expectEqual(@as(i32, 0), iswctype(256, 0xFFFF));
}

test "isctype and iswctype consult the mask the caller passes" {
    init_pctype();
    try std.testing.expectEqual(@as(i32, 1), isctype('0', 0x0004)); // _DIGIT
    try std.testing.expectEqual(@as(i32, 0), isctype('0', 0x0002)); // _LOWER
    try std.testing.expectEqual(@as(i32, 1), iswctype('A', 0x0001)); // _UPPER
    try std.testing.expectEqual(@as(i32, 0), iswctype('A', 0x0002));
}

test "the narrow case mappers are identity past 255, the wide ones fold" {
    try std.testing.expectEqual(@as(i32, 'a'), tolower('A'));
    try std.testing.expectEqual(@as(i32, 'a'), tolower('a'));
    try std.testing.expectEqual(@as(i32, '5'), tolower('5'));
    try std.testing.expectEqual(@as(i32, 'A'), toupper('a'));
    // A byte argument has no non-ANSI case, so the narrow mappers pass 0x0410
    // through; towlower and towupper map the full code point.
    try std.testing.expectEqual(@as(i32, 0x0410), toupper(0x0410));
    try std.testing.expectEqual(@as(i32, 0x0410), tolower(0x0410));
    try std.testing.expectEqual(@as(i32, 'A'), towupper('a'));
    try std.testing.expectEqual(@as(i32, 'a'), towlower('A'));
    try std.testing.expectEqual(@as(i32, 0x0430), towlower(0x0410));
    try std.testing.expectEqual(@as(i32, 0x0410), towupper(0x0430));
    // A code point with no case partner is its own answer.
    try std.testing.expectEqual(@as(i32, 0x4E2D), towupper(0x4E2D));
    try std.testing.expectEqual(@as(i32, 0x4E2D), towlower(0x4E2D));
}

test "ismbcspace accepts only the six whitespace code points" {
    inline for (.{ ' ', '\t', '\n', '\r', 0x0B, 0x0C }) |c| try std.testing.expectEqual(@as(i32, 1), ismbcspace(c));
    inline for (.{ 'a', '0', 0x00, 0x0D + 1, 0x20 + 1 }) |c| try std.testing.expectEqual(@as(i32, 0), ismbcspace(c));
}

test "mbsinc, mbccpy, mbclen, and mbsdec step one byte at a time" {
    var buf: [4]u8 = "ab\x00\x00".*;
    const s: [*]const u8 = @ptrCast(&buf);
    try std.testing.expectEqual(@as(usize, 1), @intFromPtr(mbsinc(s).?) - @intFromPtr(s));
    // A NUL or absent pointer ends the walk instead of advancing.
    try std.testing.expect(mbsinc(@as(?[*]const u8, @ptrCast(&buf[2]))) == null);
    try std.testing.expect(mbsinc(null) == null);

    var dst: [2]u8 = undefined;
    mbccpy(&dst, s);
    try std.testing.expectEqualSlices(u8, s[0..1], dst[0..1]);

    try std.testing.expectEqual(@as(usize, 0), mbclen(0));
    try std.testing.expectEqual(@as(usize, 1), mbclen(@intFromPtr(&s)));

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(mbsdec(s, @ptrCast(&buf[1])).?) - @intFromPtr(s));
    // Decrementing at or before the start is rejected rather than underflowing.
    try std.testing.expect(mbsdec(s, s) == null);
    try std.testing.expect(mbsdec(s, null) == null);
    try std.testing.expect(mbsdec(null, @ptrCast(&buf[1])) == null);
}

test "strtok splits on delimiters and continues from saved state" {
    var buf: [6]u8 = "a,,bc\x00".*;
    const s: [*:0]u8 = @ptrCast(&buf);
    const d = ",";

    try std.testing.expectEqualStrings("a", std.mem.span(strtok(s, d).?));
    try std.testing.expectEqualStrings("bc", std.mem.span(strtok(null, d).?));
    try std.testing.expect(strtok(null, d) == null);

    // Leading and trailing delimiters produce no empty tokens.
    var buf2: [6]u8 = ",,x,,\x00".*;
    const s2: [*:0]u8 = @ptrCast(&buf2);
    try std.testing.expectEqualStrings("x", std.mem.span(strtok(s2, ",").?));
    try std.testing.expect(strtok(null, ",") == null);

    // Without a delimiter set the state is left alone and null is returned.
    var buf3: [4]u8 = .{ 'a', 'b', 0, 0 };
    try std.testing.expect(strtok(@ptrCast(&buf3), null) == null);
    try std.testing.expect(strtok(null, null) == null);
}
