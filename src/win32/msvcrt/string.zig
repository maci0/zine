const std = @import("std");
const trace = @import("../../trace.zig");
const msvcrt = @import("../msvcrt.zig");
const io = @import("io.zig");


pub fn strlen(str_ptr: usize) callconv(.c) usize {
    if (str_ptr == 0) return 0;
    const len = trace.c_span(str_ptr).len;
    if (trace.enable_tracing) trace.print("MSVCRT: strlen('{s}') -> {d}\n", .{trace.c_span(str_ptr)[0..len], len});
    return len;
}

pub fn strcpy(dest_ptr: usize, src_ptr: usize) callconv(.c) usize {
    if (dest_ptr == 0 or src_ptr == 0) return dest_ptr;
    const dest = @as([*]u8, @ptrFromInt(dest_ptr));
    const src = @as([*]const u8, @ptrFromInt(src_ptr));
    // Element-by-element copy to handle overlapping buffers
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
    dest[i] = 0;
    return dest_ptr;
}

pub fn strncpy(dest_ptr: usize, src_ptr: usize, count: usize) callconv(.c) usize {
    if (dest_ptr == 0 or src_ptr == 0 or count == 0) return dest_ptr;
    const dest = @as([*]u8, @ptrFromInt(dest_ptr));
    const src = @as([*]const u8, @ptrFromInt(src_ptr));
    if (trace.enable_tracing) trace.print("MSVCRT: strncpy(count={d})\n", .{count});
    
    var i: usize = 0;
    while (i < count and src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
    if (i < count) {
        @memset(dest[i..count], 0);
    }
    return dest_ptr;
}

pub fn strcat(dest_ptr: usize, src_ptr: usize) callconv(.c) usize {
    if (dest_ptr == 0 or src_ptr == 0) return dest_ptr;
    const dest = @as([*]u8, @ptrFromInt(dest_ptr));
    // Find end of dest
    var dest_len: usize = 0;
    while (dest[dest_len] != 0) : (dest_len += 1) {}
    // Copy src after dest
    const src = @as([*]const u8, @ptrFromInt(src_ptr));
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) {
        dest[dest_len + i] = src[i];
    }
    dest[dest_len + i] = 0;
    return dest_ptr;
}

pub fn strcmp(s1_ptr: usize, s2_ptr: usize) callconv(.c) i32 {
    if (s1_ptr == 0 or s2_ptr == 0) return 0;
    const s1 = @as([*]const u8, @ptrFromInt(s1_ptr));
    const s2 = @as([*]const u8, @ptrFromInt(s2_ptr));
    var i: usize = 0;
    while (s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn strncmp(s1_ptr: usize, s2_ptr: usize, count: usize) callconv(.c) i32 {
    if (s1_ptr == 0 or s2_ptr == 0 or count == 0) return 0;
    const s1 = @as([*]const u8, @ptrFromInt(s1_ptr));
    const s2 = @as([*]const u8, @ptrFromInt(s2_ptr));
    var i: usize = 0;
    while (i < count and s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    if (i == count) return 0;
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn stricmp(s1_ptr: usize, s2_ptr: usize) callconv(.c) i32 {
    if (s1_ptr == 0 or s2_ptr == 0) return 0;
    const s1 = trace.c_span(s1_ptr);
    const s2 = trace.c_span(s2_ptr);

    var i: usize = 0;
    var ret: i32 = 0;
    while (i < s1.len and i < s2.len) : (i += 1) {
        const c1 = std.ascii.toLower(s1[i]);
        const c2 = std.ascii.toLower(s2[i]);
        if (c1 != c2) {
            ret = @as(i32, c1) - @as(i32, c2);
            break;
        }
    }
    if (ret == 0) {
        if (s1.len < s2.len) {
            ret = -1;
        } else if (s1.len > s2.len) {
            ret = 1;
        }
    }

    if (trace.enable_tracing) {
        trace.print("MSVCRT: stricmp('{s}', '{s}') = {d}\n", .{ s1, s2, ret });
    }
    return ret;
}

pub fn mbsicmp(s1_ptr: usize, s2_ptr: usize) callconv(.c) i32 {
    if (s1_ptr == 0 or s2_ptr == 0) return 0;
    const s1 = trace.c_span(s1_ptr);
    const s2 = trace.c_span(s2_ptr);

    var i: usize = 0;
    while (i < s1.len and i < s2.len) : (i += 1) {
        const c1 = std.ascii.toLower(s1[i]);
        const c2 = std.ascii.toLower(s2[i]);
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    const ret: i32 = if (s1.len < s2.len) @as(i32, -1) else if (s1.len > s2.len) @as(i32, 1) else @as(i32, 0);
    if (trace.enable_tracing) trace.print("MSVCRT: _mbsicmp('{s}', '{s}') = {d}\n", .{ s1, s2, ret });
    return ret;
}

pub fn strnicmp(s1_ptr: usize, s2_ptr: usize, count: usize) callconv(.c) i32 {
    if (s1_ptr == 0 or s2_ptr == 0 or count == 0) return 0;
    const s1 = trace.c_span(s1_ptr);
    const s2 = trace.c_span(s2_ptr);
    var i: usize = 0;
    while (i < count and i < s1.len and i < s2.len) : (i += 1) {
        const c1 = std.ascii.toLower(s1[i]);
        const c2 = std.ascii.toLower(s2[i]);
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    if (i == count) return 0;
    if (i < s1.len) return 1;
    if (i < s2.len) return -1;
    return 0;
}

pub fn strchr(s_ptr: usize, c: i32) callconv(.c) usize {
    if (s_ptr == 0) return 0;
    const target = @as(u8, @intCast(c & 0xFF));
    const s = trace.c_span(s_ptr);
    if (target == 0) return s_ptr + s.len;
    if (std.mem.indexOfScalar(u8, s, target)) |idx| return s_ptr + idx;
    return 0;
}

pub fn strrchr(str_ptr: usize, c: i32) callconv(.c) usize {
    if (str_ptr == 0) return 0;
    const target = @as(u8, @intCast(c & 0xFF));
    const s = trace.c_span(str_ptr);
    if (target == 0) return str_ptr + s.len;
    if (std.mem.lastIndexOfScalar(u8, s, target)) |idx| return str_ptr + idx;
    return 0;
}

pub fn strstr(str_ptr: usize, substr_ptr: usize) callconv(.c) usize {
    if (str_ptr == 0 or substr_ptr == 0) return 0;
    const str = trace.c_span(str_ptr);
    const substr = trace.c_span(substr_ptr);
    if (substr.len == 0) return str_ptr;
    if (std.mem.indexOf(u8, str, substr)) |idx| return str_ptr + idx;
    return 0;
}

pub fn strpbrk(s1_ptr: usize, s2_ptr: usize) callconv(.c) ?*anyopaque {
    if (s1_ptr == 0 or s2_ptr == 0) return null;
    const s1 = trace.c_span(s1_ptr);
    const s2 = trace.c_span(s2_ptr);
    if (std.mem.indexOfAny(u8, s1, s2)) |idx| return @ptrFromInt(s1_ptr + idx);
    return null;
}

pub fn strcspn(s1_ptr: usize, s2_ptr: usize) callconv(.c) usize {
    if (s1_ptr == 0 or s2_ptr == 0) return 0;
    const s1 = trace.c_span(s1_ptr);
    const s2 = trace.c_span(s2_ptr);
    return std.mem.indexOfAny(u8, s1, s2) orelse s1.len;
}

pub fn strdup(str_ptr: usize) callconv(.c) usize {
    if (str_ptr == 0) return 0;
    const s = trace.c_span(str_ptr);
    const stub_common = @import("../stub_common.zig");
    const raw = stub_common.raw_alloc(s.len + 1) orelse return 0;
    const ptr = @as([*]u8, @ptrCast(raw));
    @memcpy(ptr[0..s.len], s);
    ptr[s.len] = 0;
    return @intFromPtr(raw);
}

pub fn wcsdup(str_ptr: usize) callconv(.c) usize {
    if (str_ptr == 0) return 0;
    const str = @as([*]const u16, @ptrFromInt(str_ptr));
    const len = std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
    
    const stub_common = @import("../stub_common.zig");
    const raw = stub_common.raw_alloc((len + 1) * 2) orelse return 0;
    const ptr = @as([*]u16, @ptrCast(@alignCast(raw)));
    @memcpy(ptr[0..len], str[0..len]);
    ptr[len] = 0;
    return @intFromPtr(raw);
}

pub fn itoa(value: i32, buffer_ptr: usize, radix: i32) callconv(.c) usize {
    if (trace.enable_tracing) trace.print("MSVCRT: _itoa(value={d}, buf={x}, radix={d})\n", .{value, buffer_ptr, radix});
    if (buffer_ptr == 0) return 0;
    const buffer = @as([*]u8, @ptrFromInt(buffer_ptr));
    const slice = buffer[0..33];
    if (radix == 10) {
        _ = std.fmt.bufPrint(slice, "{d}\x00", .{value}) catch return buffer_ptr;
    } else if (radix == 16) {
        _ = std.fmt.bufPrint(slice, "{x}\x00", .{@as(u32, @bitCast(value))}) catch return buffer_ptr;
    } else buffer[0] = 0;
    if (trace.enable_tracing) trace.print("  -> '{s}'\n", .{trace.c_span(buffer_ptr)});
    return buffer_ptr;
}

pub fn strtoul(str_ptr: usize, end_ptr: usize, radix: i32) callconv(.c) u32 {
    if (str_ptr == 0) return 0;
    const str = @as([*:0]const u8, @ptrFromInt(str_ptr));
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
    if (end_ptr != 0) @as(*usize, @ptrFromInt(end_ptr)).* = if (parsed) str_ptr + i else str_ptr;
    const final_val = if (sign == -1) ~val +% 1 else val;
    if (trace.enable_tracing) trace.print("MSVCRT: strtoul('{s}', {d}) -> {d}\n", .{trace.c_span(str_ptr), radix, final_val});
    return final_val;
}

pub fn strtol(str_ptr: usize, end_ptr: usize, radix: i32) callconv(.c) i32 {
    const val = @as(i32, @bitCast(strtoul(str_ptr, end_ptr, radix)));
    if (trace.enable_tracing) {
        trace.print("MSVCRT: strtol('{s}', {d}) -> {d}\n", .{trace.c_span(str_ptr), radix, val});
    }
    return val;
}

pub fn atoi(str_ptr: usize) callconv(.c) i32 {
    const val = @as(i32, @bitCast(strtoul(str_ptr, 0, 10)));
    if (trace.enable_tracing) {
        if (str_ptr != 0) {
            trace.print("MSVCRT: atoi('{s}') -> {d}\n", .{trace.c_span(str_ptr), val});
        }
    }
    return val;
}

// --- Wide String ---

pub fn wcslen(str_ptr: usize) callconv(.c) usize {
    if (str_ptr == 0) return 0;
    const str = @as([*]const u16, @ptrFromInt(str_ptr));
    const len = std.mem.indexOfScalar(u16, str[0..65536], 0) orelse 0;
    return len;
}

pub fn wcsupr(str_ptr: usize) callconv(.c) usize {
    if (str_ptr == 0) return 0;
    const str = @as([*]u16, @ptrFromInt(str_ptr));
    const len = trace.c_span_w(str_ptr).len;
    for (str[0..len]) |*ch| {
        if (ch.* >= 'a' and ch.* <= 'z') ch.* -= 32;
    }
    return str_ptr;
}

pub fn wcscpy(dst_ptr: usize, src_ptr: usize) callconv(.c) usize {
    log_wcs("wcscpy src: ", src_ptr);
    if (dst_ptr == 0 or src_ptr == 0) return dst_ptr;
    const dst = @as([*]u16, @ptrFromInt(dst_ptr));
    const src = @as([*]const u16, @ptrFromInt(src_ptr));
    // Element-by-element copy to handle overlapping buffers (like memmove)
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) {
        dst[i] = src[i];
    }
    dst[i] = 0;
    return dst_ptr;
}

pub fn wcsncpy(dst_ptr: usize, src_ptr: usize, count: usize) callconv(.c) usize {
    if (dst_ptr == 0 or src_ptr == 0) return dst_ptr;
    const dst = @as([*]u16, @ptrFromInt(dst_ptr));
    const src = @as([*]const u16, @ptrFromInt(src_ptr));
    // Element-by-element copy to handle overlapping buffers
    var i: usize = 0;
    while (i < count and src[i] != 0) : (i += 1) {
        dst[i] = src[i];
    }
    while (i < count) : (i += 1) {
        dst[i] = 0;
    }
    return dst_ptr;
}

pub fn wcscat(dst_ptr: usize, src_ptr: usize) callconv(.c) usize {
    if (dst_ptr == 0 or src_ptr == 0) return dst_ptr;
    const dst = @as([*]u16, @ptrFromInt(dst_ptr));
    // Find end of dst
    var dst_len: usize = 0;
    while (dst[dst_len] != 0) : (dst_len += 1) {}
    // Copy src after dst
    const src = @as([*]const u16, @ptrFromInt(src_ptr));
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) {
        dst[dst_len + i] = src[i];
    }
    dst[dst_len + i] = 0;
    return dst_ptr;
}

pub fn wcscmp(s1_ptr: usize, s2_ptr: usize) callconv(.c) i32 {
    if (s1_ptr == 0 or s2_ptr == 0) return 0;
    const s1 = @as([*]const u16, @ptrFromInt(s1_ptr));
    const s2 = @as([*]const u16, @ptrFromInt(s2_ptr));
    var i: usize = 0;
    while (s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn wcsncmp(s1_ptr: usize, s2_ptr: usize, count: usize) callconv(.c) i32 {
    if (s1_ptr == 0 or s2_ptr == 0 or count == 0) return 0;
    const s1 = @as([*]const u16, @ptrFromInt(s1_ptr));
    const s2 = @as([*]const u16, @ptrFromInt(s2_ptr));
    var i: usize = 0;
    while (i < count and s1[i] == s2[i] and s1[i] != 0) : (i += 1) {}
    if (i == count) return 0;
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn wcsicmp(s1_ptr: usize, s2_ptr: usize) callconv(.c) i32 {
    if (s1_ptr == 0 or s2_ptr == 0) return 0;
    const s1 = @as([*]const u16, @ptrFromInt(s1_ptr));
    const s2 = @as([*]const u16, @ptrFromInt(s2_ptr));
    var i: usize = 0;
    while (s1[i] != 0 and s2[i] != 0) : (i += 1) {
        const c1 = if (s1[i] <= 255) std.ascii.toLower(@intCast(s1[i])) else s1[i];
        const c2 = if (s2[i] <= 255) std.ascii.toLower(@intCast(s2[i])) else s2[i];
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn wcsnicmp(s1_ptr: usize, s2_ptr: usize, count: usize) callconv(.c) i32 {
    if (s1_ptr == 0 or s2_ptr == 0 or count == 0) return 0;
    const s1 = @as([*]const u16, @ptrFromInt(s1_ptr));
    const s2 = @as([*]const u16, @ptrFromInt(s2_ptr));
    var i: usize = 0;
    while (i < count and s1[i] != 0 and s2[i] != 0) : (i += 1) {
        const c1 = if (s1[i] <= 255) std.ascii.toLower(@intCast(s1[i])) else s1[i];
        const c2 = if (s2[i] <= 255) std.ascii.toLower(@intCast(s2[i])) else s2[i];
        if (c1 != c2) return @as(i32, c1) - @as(i32, c2);
    }
    if (i == count) return 0;
    return @as(i32, s1[i]) - @as(i32, s2[i]);
}

pub fn wcschr(str_ptr: usize, c: i32) callconv(.c) usize {
    if (str_ptr == 0) return 0;
    const str = @as([*]const u16, @ptrFromInt(str_ptr));
    const target = @as(u16, @intCast(c & 0xFFFF));
    const span = trace.c_span_w(str_ptr);
    if (target == 0) return @intFromPtr(&str[span.len]);
    if (std.mem.indexOfScalar(u16, span, target)) |idx| return @intFromPtr(&str[idx]);
    return 0;
}

pub fn wcsrchr(str_ptr: usize, c: i32) callconv(.c) usize {
    if (str_ptr == 0) return 0;
    const str = @as([*]const u16, @ptrFromInt(str_ptr));
    const target = @as(u16, @intCast(c & 0xFFFF));
    const span = trace.c_span_w(str_ptr);
    if (target == 0) return @intFromPtr(&str[span.len]);
    if (std.mem.lastIndexOfScalar(u16, span, target)) |idx| return @intFromPtr(&str[idx]);
    return 0;
}

pub fn wcsstr(str_ptr: usize, substr_ptr: usize) callconv(.c) usize {
    if (str_ptr == 0 or substr_ptr == 0) return 0;
    const str = trace.c_span_w(str_ptr);
    const substr = trace.c_span_w(substr_ptr);
    if (substr.len == 0) return str_ptr;
    // Search for substr in str
    if (str.len < substr.len) return 0;
    var i: usize = 0;
    while (i <= str.len - substr.len) : (i += 1) {
        if (std.mem.eql(u16, str[i .. i + substr.len], substr)) return str_ptr + i * 2;
    }
    return 0;
}

pub fn wcstol(str_ptr: usize, end_ptr: usize, radix: i32) callconv(.c) i32 {
    if (str_ptr == 0) return 0;
    const str = @as([*]const u16, @ptrFromInt(str_ptr));
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
    if (end_ptr != 0) @as(*usize, @ptrFromInt(end_ptr)).* = if (parsed) str_ptr + i * 2 else str_ptr;
    return val * sign;
}

pub fn wtoi(str_ptr: usize) callconv(.c) i32 {
    if (str_ptr == 0) return 0;
    const str = @as([*]const u16, @ptrFromInt(str_ptr));
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

pub fn p_pctype() callconv(.c) *?*u16 {
    const static = struct {
        var p: ?*u16 = null;
    };
    if (static.p == null) static.p = @ptrCast(@constCast(&msvcrt.msvcrt_pctype[1]));
    return @ptrCast(@constCast(&static.p));
}

pub fn isalnum(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0107; // _ALPHA | _DIGIT
    }
    return 0;
}

pub fn isalpha(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        const res = msvcrt.msvcrt_pctype[index] & 0x0103; // _ALPHA | _UPPER | _LOWER
        if (trace.enable_tracing) trace.print("MSVCRT: isalpha({d}) -> {x}\n", .{c, res});
        return res;
    }
    return 0;
}

pub fn isdigit(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0004; // _DIGIT
    }
    return 0;
}

pub fn isupper(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0001; // _UPPER
    }
    return 0;
}

pub fn islower(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0002; // _LOWER
    }
    return 0;
}

pub fn isspace(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        const res = msvcrt.msvcrt_pctype[index] & 0x0008; // _SPACE
        if (trace.enable_tracing) trace.print("MSVCRT: isspace({d}) -> {x}\n", .{c, res});
        return res;
    }
    return 0;
}

pub fn isxdigit(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0080; // _HEX
    }
    return 0;
}

pub fn isprint(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0157; // _BLANK | _PUNCT | _ALPHA | _DIGIT
    }
    return 0;
}

pub fn ispunct(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0010; // _PUNCT
    }
    return 0;
}

pub fn isctype(c: i32, mask: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return if ((msvcrt.msvcrt_pctype[index] & @as(u16, @intCast(mask & 0xFFFF))) != 0) 1 else 0;
    }
    return 0;
}

pub fn tolower(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    if (v <= 255) return std.ascii.toLower(@intCast(v));
    return v;
}

pub fn toupper(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    if (v <= 255) return std.ascii.toUpper(@intCast(v));
    return v;
}

pub fn iswctype(c: i32, desc: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        const res = if ((msvcrt.msvcrt_pctype[index] & @as(u16, @intCast(desc & 0xFFFF))) != 0) @as(i32, 1) else @as(i32, 0);
        if (trace.enable_tracing) trace.print("MSVCRT: iswctype({d}, {x}) -> {d}\n", .{c, desc, res});
        return res;
    }
    if (trace.enable_tracing) trace.print("MSVCRT: iswctype({d}, {x}) -> 0 (out of bounds)\n", .{c, desc});
    return 0;
}

pub fn towupper(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    if (v <= 255) return std.ascii.toUpper(@intCast(v));
    return v;
}

pub fn towlower(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    if (v <= 255) return std.ascii.toLower(@intCast(v));
    return v;
}

pub fn ismbcspace(c: i32) callconv(.c) i32 {
    const v = c & 0xFFFF;
    return if (v == ' ' or v == '\t' or v == '\n' or v == '\r' or v == 0x0B or v == 0x0C) 1 else 0;
}

pub fn mbsinc(str_ptr: usize) callconv(.c) usize {
    return if (str_ptr == 0) 0 else str_ptr + 1;
}

pub fn mbccpy(dest: usize, src: usize) callconv(.c) void {
    if (dest != 0 and src != 0) @as([*]u8, @ptrFromInt(dest))[0] = @as([*]const u8, @ptrFromInt(src))[0];
}

pub fn mbclen(c_ptr: usize) callconv(.c) usize {
    return if (c_ptr == 0) 0 else 1;
}

pub fn mbsdec(start: usize, current: usize) callconv(.c) usize {
    if (start == 0 or current <= start) return 0;
    if (trace.enable_tracing) trace.print("MSVCRT: _mbsdec(start={x}, current={x}) -> {x}\n", .{start, current, current - 1});
    return current - 1;
}

// --- Setjmp / Longjmp ---

pub fn log_wcs(prefix: []const u8, str_ptr: usize) void {
    if (!trace.enable_tracing) return;
    trace.print("{s}(ptr=0x{x}) ", .{ prefix, str_ptr });
    if (str_ptr != 0) {
        const str = @as([*]const u16, @ptrFromInt(str_ptr));
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

// --- Generic Stubs ---

pub fn iscntrl(c: i32) callconv(.c) i32 {
    if (c >= -1 and c <= 255) {
        const index = @as(usize, @intCast(c + 1));
        return msvcrt.msvcrt_pctype[index] & 0x0020; // _CONTROL
    }
    return 0;
}
