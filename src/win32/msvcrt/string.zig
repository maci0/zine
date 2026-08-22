const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const io = @import("io.zig");

/// strlen
/// Implementation status: Partially implemented
pub fn strlen(str: [*:0]const u8) callconv(.c) usize {
    const len = std.mem.span(str).len;
    if (trace.enable_tracing) trace.print("MSVCRT: _strlen('{s}') -> {d}\n", .{ std.mem.span(str), len });
    return len;
}

/// strcpy
/// Implementation status: Partially implemented
pub fn strcpy(dest: [*]u8, src: [*:0]const u8) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dest[i] = src[i];
    dest[i] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _strcpy('{s}', '{s}')\n", .{ std.mem.span(@as([*:0]const u8, @ptrCast(dest))), std.mem.span(src) });
    return dest;
}

/// strncpy
/// Implementation status: Partially implemented
pub fn strncpy(dest: [*]u8, src: [*:0]const u8, count: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < count and src[i] != 0) : (i += 1) dest[i] = src[i];
    if (i < count) @memset(dest[i..count], 0);
    return dest;
}

/// strcat
pub fn strcat(dest: [*]u8, src: [*:0]const u8) callconv(.c) [*]u8 {
    var dest_len: usize = 0;
    while (dest[dest_len] != 0) : (dest_len += 1) {}
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dest[dest_len + i] = src[i];
    dest[dest_len + i] = 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _strcat('{s}', '{s}')\n", .{ std.mem.span(@as([*:0]const u8, @ptrCast(dest))), std.mem.span(src) });
    return dest;
}

/// strncat
pub fn strncat(dest: [*]u8, src: [*:0]const u8, count: usize) callconv(.c) [*]u8 {
    var dest_len: usize = 0;
    while (dest[dest_len] != 0) : (dest_len += 1) {}
    var i: usize = 0;
    while (i < count and src[i] != 0) : (i += 1) dest[dest_len + i] = src[i];
    dest[dest_len + i] = 0;
    return dest;
}

/// strcmp
/// Implementation status: Partially implemented
pub fn strcmp(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) i32 {
    var i: usize = 0;
    while (s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

/// strncmp
pub fn strncmp(s1: [*:0]const u8, s2: [*:0]const u8, count: usize) callconv(.c) i32 {
    if (trace.enable_tracing) trace.print("MSVCRT: _strncmp('{s}', '{s}', {d})\n", .{ std.mem.span(s1), std.mem.span(s2), count });
    if (count == 0) return 0;
    var i: usize = 0;
    while (i < count and s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    if (i == count) return 0;
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

/// stricmp
/// Implementation status: Partially implemented
pub fn stricmp(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) i32 {
    const sp1 = std.mem.span(s1);
    const sp2 = std.mem.span(s2);
    var i: usize = 0;
    var ret: i32 = 0;
    while (i < sp1.len and i < sp2.len) : (i += 1) {
        const c1 = std.ascii.toLower(sp1[i]);
        const c2 = std.ascii.toLower(sp2[i]);
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

/// mbsicmp
pub fn mbsicmp(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) i32 {
    const sp1 = std.mem.span(s1);
    const sp2 = std.mem.span(s2);
    var i: usize = 0;
    while (i < sp1.len and i < sp2.len) : (i += 1) {
        const c1 = std.ascii.toLower(sp1[i]);
        const c2 = std.ascii.toLower(sp2[i]);
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    const ret: i32 = if (sp1.len < sp2.len) -1 else if (sp1.len > sp2.len) @as(i32, 1) else 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _mbsicmp('{s}', '{s}') = {d}\n", .{ sp1, sp2, ret });
    return ret;
}

/// strnicmp
pub fn strnicmp(s1: [*:0]const u8, s2: [*:0]const u8, count: usize) callconv(.c) i32 {
    if (count == 0) return 0;
    const sp1 = std.mem.span(s1);
    const sp2 = std.mem.span(s2);
    var i: usize = 0;
    while (i < count and i < sp1.len and i < sp2.len) : (i += 1) {
        const c1 = std.ascii.toLower(sp1[i]);
        const c2 = std.ascii.toLower(sp2[i]);
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    if (i == count) return 0;
    if (i < sp1.len) return 1;
    if (i < sp2.len) return -1;
    return 0;
}

/// strchr
pub fn strchr(s: [*:0]const u8, c: i32) callconv(.c) ?[*:0]const u8 {
    const target = @as(u8, @intCast(c & 0xFF));
    const span = std.mem.span(s);
    if (target == 0) return @ptrCast(s + span.len);
    if (std.mem.indexOfScalar(u8, span, target)) |idx| return @ptrCast(s + idx);
    return null;
}

/// strrchr
pub fn strrchr(s: [*:0]const u8, c: i32) callconv(.c) ?[*:0]const u8 {
    const target = @as(u8, @intCast(c & 0xFF));
    const span = std.mem.span(s);
    if (target == 0) return @ptrCast(s + span.len);
    if (std.mem.lastIndexOfScalar(u8, span, target)) |idx| return @ptrCast(s + idx);
    return null;
}

/// strstr
pub fn strstr(haystack: [*:0]const u8, needle: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const h = std.mem.span(haystack);
    const n = std.mem.span(needle);
    if (n.len == 0) return haystack;
    if (std.mem.indexOf(u8, h, n)) |idx| return @ptrCast(haystack + idx);
    return null;
}

/// strpbrk
pub fn strpbrk(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) ?[*]u8 {
    const sp1 = std.mem.span(s1);
    const sp2 = std.mem.span(s2);
    if (std.mem.indexOfAny(u8, sp1, sp2)) |idx| return @ptrFromInt(@intFromPtr(s1) + idx);
    return null;
}

/// strcspn
pub fn strcspn(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) usize {
    return std.mem.indexOfAny(u8, std.mem.span(s1), std.mem.span(s2)) orelse std.mem.span(s1).len;
}

/// strdup
pub fn strdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const span = std.mem.span(s);
    const stub_common = @import("../shared.zig");
    const raw = stub_common.raw_alloc(span.len + 1) orelse return null;
    const ptr = @as([*]u8, @ptrCast(raw));
    @memcpy(ptr[0..span.len], span);
    ptr[span.len] = 0;
    return @ptrCast(ptr);
}

/// wcsdup
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

/// itoa
/// Implementation status: Partially implemented
pub fn itoa(value: i32, buffer: [*]u8, radix: i32) callconv(.c) [*]u8 {
    if (trace.enable_tracing) trace.print("MSVCRT: _itoa(value={d}, radix={d})\n", .{ value, radix });
    const slice = buffer[0..33];
    if (radix == 10) {
        _ = std.fmt.bufPrint(slice, "{d}\x00", .{value}) catch return buffer;
    } else if (radix == 16) {
        _ = std.fmt.bufPrint(slice, "{x}\x00", .{@as(u32, @bitCast(value))}) catch return buffer;
    } else buffer[0] = 0;
    return buffer;
}

/// strtoul
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

    var r = radix;
    if (r == 0) {
        if (str[i] == '0' and (str[i + 1] == 'x' or str[i + 1] == 'X')) {
            r = 16;
            i += 2;
        } else if (str[i] == '0') {
            r = 8;
            i += 1;
        } else r = 10;
    } else if (r == 16 and str[i] == '0' and (str[i + 1] == 'x' or str[i + 1] == 'X')) i += 2;

    var val: u32 = 0;
    var parsed = false;
    while (str[i] != 0) : (i += 1) {
        const digit = std.fmt.charToDigit(str[i], @intCast(r)) catch break;
        val = val * @as(u32, @intCast(r)) + @as(u32, digit);
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

/// strtol
/// Implementation status: Partially implemented
pub fn strtol(str_ptr: usize, end_ptr: usize, radix: i32) callconv(.c) i32 {
    const val = @as(i32, @bitCast(strtoul(str_ptr, end_ptr, radix)));
    if (trace.enable_tracing) {
        trace.print("MSVCRT: strtol('{s}', {d}) -> {d}\n", .{ trace.c_span(str_ptr), radix, val });
    }
    return val;
}

/// atoi
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

/// wcsupr
pub fn wcsupr(str: [*]u16) callconv(.c) [*]u16 {
    const len = std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
    for (str[0..len]) |*ch| {
        if (ch.* >= 'a' and ch.* <= 'z') ch.* -= 32;
    }
    return str;
}

/// wcscpy
pub fn wcscpy(dst: [*]u16, src: [*]const u16) callconv(.c) [*]u16 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dst[i] = src[i];
    dst[i] = 0;
    return dst;
}

/// wcsncpy
pub fn wcsncpy(dst: [*]u16, src: [*]const u16, count: usize) callconv(.c) [*]u16 {
    var i: usize = 0;
    while (i < count and src[i] != 0) : (i += 1) dst[i] = src[i];
    while (i < count) : (i += 1) dst[i] = 0;
    return dst;
}

/// wcscat
pub fn wcscat(dst: [*]u16, src: [*]const u16) callconv(.c) [*]u16 {
    var dst_len: usize = 0;
    while (dst[dst_len] != 0) : (dst_len += 1) {}
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dst[dst_len + i] = src[i];
    dst[dst_len + i] = 0;
    return dst;
}

/// wcscmp
pub fn wcscmp(s1: [*]const u16, s2: [*]const u16) callconv(.c) i32 {
    var i: usize = 0;
    while (s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

/// wcsncmp
pub fn wcsncmp(s1: [*]const u16, s2: [*]const u16, count: usize) callconv(.c) i32 {
    if (count == 0) return 0;
    var i: usize = 0;
    while (i < count and s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    if (i == count) return 0;
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

/// wcsicmp
pub fn wcsicmp(s1: [*]const u16, s2: [*]const u16) callconv(.c) i32 {
    var i: usize = 0;
    while (s1[i] != 0 and s2[i] != 0) : (i += 1) {
        const c1 = if (s1[i] <= 255) std.ascii.toLower(@intCast(s1[i])) else s1[i];
        const c2 = if (s2[i] <= 255) std.ascii.toLower(@intCast(s2[i])) else s2[i];
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

/// wcsnicmp
pub fn wcsnicmp(s1: [*]const u16, s2: [*]const u16, count: usize) callconv(.c) i32 {
    if (count == 0) return 0;
    var i: usize = 0;
    while (i < count and s1[i] != 0 and s2[i] != 0) : (i += 1) {
        const c1 = if (s1[i] <= 255) std.ascii.toLower(@intCast(s1[i])) else s1[i];
        const c2 = if (s2[i] <= 255) std.ascii.toLower(@intCast(s2[i])) else s2[i];
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    if (i == count) return 0;
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

/// wcschr
pub fn wcschr(str: [*]const u16, c: i32) callconv(.c) ?[*]const u16 {
    const target = @as(u16, @intCast(c & 0xFFFF));
    const len = std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
    if (target == 0) return str + len;
    if (std.mem.indexOfScalar(u16, str[0..len], target)) |idx| return str + idx;
    return null;
}

/// wcsrchr
pub fn wcsrchr(str: [*]const u16, c: i32) callconv(.c) ?[*]const u16 {
    const target = @as(u16, @intCast(c & 0xFFFF));
    const len = std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
    if (target == 0) return str + len;
    if (std.mem.lastIndexOfScalar(u16, str[0..len], target)) |idx| return str + idx;
    return null;
}

/// wcsstr
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
    var r = radix;
    if (r == 0) {
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
    while (str[i] != 0) : (i += 1) {
        const digit = std.fmt.charToDigit(@intCast(str[i] & 0xFF), @intCast(r)) catch break;
        val = val * r + @as(i32, @intCast(digit));
        parsed = true;
    }
    // end_ptr stays usize — writes back a guest VA for x86 code
    if (end_ptr != 0) {
        const end_val: u32 = @truncate(if (parsed) @intFromPtr(str) + i * 2 else @intFromPtr(str));
        @as(*u32, @ptrFromInt(end_ptr)).* = end_val;
    }
    return val * sign;
}

/// wtoi
pub fn wtoi(str: [*]const u16) callconv(.c) i32 {
    var i: usize = 0;
    while (str[i] != 0 and std.ascii.isWhitespace(@intCast(str[i] & 0xFF))) i += 1;
    var sign: i32 = 1;
    if (str[i] == '-') {
        sign = -1;
        i += 1;
    } else if (str[i] == '+') i += 1;
    var val: i32 = 0;
    while (str[i] >= '0' and str[i] <= '9') {
        val = val * 10 + @as(i32, str[i] - '0');
        i += 1;
    }
    return val * sign;
}

/// init_pctype
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

/// p_pctype
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

/// isalnum
/// Implementation status: Partially implemented
pub fn isalnum(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0107; // _ALPHA | _DIGIT
    }
    return 0;
}

/// isalpha
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

/// isdigit
/// Implementation status: Partially implemented
pub fn isdigit(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0004; // _DIGIT
    }
    return 0;
}

/// isupper
/// Implementation status: Partially implemented
pub fn isupper(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0001; // _UPPER
    }
    return 0;
}

/// islower
/// Implementation status: Partially implemented
pub fn islower(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0002; // _LOWER
    }
    return 0;
}

/// isspace
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

/// isxdigit
/// Implementation status: Partially implemented
pub fn isxdigit(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0080; // _HEX
    }
    return 0;
}

/// isprint
/// Implementation status: Partially implemented
pub fn isprint(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0157; // _BLANK | _PUNCT | _ALPHA | _DIGIT
    }
    return 0;
}

/// ispunct
/// Implementation status: Partially implemented
pub fn ispunct(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0010; // _PUNCT
    }
    return 0;
}

/// isctype
/// Implementation status: Partially implemented
pub fn isctype(c: i32, mask: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return if ((msvcrt.msvcrt_pctype[index] & @as(u16, @intCast(mask & 0xFFFF))) != 0) 1 else 0;
    }
    return 0;
}

/// tolower
/// Implementation status: Partially implemented
pub fn tolower(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    if (v <= 255) return std.ascii.toLower(@intCast(v));
    return v;
}

/// toupper
/// Implementation status: Partially implemented
pub fn toupper(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    if (v <= 255) return std.ascii.toUpper(@intCast(v));
    return v;
}

/// iswctype
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

/// towupper
/// Implementation status: Partially implemented
pub fn towupper(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    if (v <= 255) return std.ascii.toUpper(@intCast(v));
    return v;
}

/// towlower
/// Implementation status: Partially implemented
pub fn towlower(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    if (v <= 255) return std.ascii.toLower(@intCast(v));
    return v;
}

/// ismbcspace
/// Implementation status: Partially implemented
pub fn ismbcspace(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    return if (v == ' ' or v == '\t' or v == '\n' or v == '\r' or v == 0x0B or v == 0x0C) 1 else 0;
}

/// mbsinc
/// Implementation status: Partially implemented
pub fn mbsinc(str: ?[*]const u8) callconv(.c) ?[*]const u8 {
    if (str) |s| {
        if (s[0] == 0) return null;
        return s + 1;
    }
    return null;
}

/// mbccpy
/// Implementation status: Partially implemented
pub fn mbccpy(dest: [*]u8, src: [*]const u8) callconv(.c) void {
    dest[0] = src[0];
}

/// mbclen
/// Implementation status: Partially implemented
pub fn mbclen(c_ptr: usize) callconv(.c) usize {
    return if (c_ptr == 0) 0 else 1;
}

/// mbsdec
/// Implementation status: Partially implemented
pub fn mbsdec(start: ?[*]const u8, current: ?[*]const u8) callconv(.c) ?[*]const u8 {
    if (start == null or current == null or @intFromPtr(current.?) <= @intFromPtr(start.?)) return null;
    if (trace.enable_tracing) trace.print("MSVCRT: _mbsdec(start={x}, current={x}) -> {x}\n", .{ @intFromPtr(start.?), @intFromPtr(current.?), @intFromPtr(current.?) - 1 });
    return current.? - 1;
}

/// --- Setjmp / Longjmp ---
/// Implementation status: Partially implemented
pub fn log_wcs(prefix: []const u8, str_ptr: usize) void {
    if (!trace.enable_tracing) return;
    trace.print("{s}(ptr=0x{x}) ", .{ prefix, str_ptr });
    if (str_ptr != 0) {
        const str = @as([*]const u16, @ptrFromInt(trace.addr(str_ptr)));
        var i: usize = 0;
        var buf: [2]u8 = undefined;
        while (str[i] != 0 and i < 256) : (i += 1) {
            buf[0] = @intCast(str[i] & 0xFF);
            buf[1] = 0;
            trace.print("{s}", .{buf[0..1]});
        }
    }
    trace.print("\n", .{});
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

/// _strlwr
pub fn strlwr(str: ?[*:0]u8) callconv(.c) ?[*:0]u8 {
    if (str) |s_ptr| {
        const s = std.mem.span(s_ptr);
        for (s) |*c| {
            if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
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
            if (c.* >= 'a' and c.* <= 'z') c.* -= 32;
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
