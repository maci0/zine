const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

const platform = @import("../../platform.zig");
const crt_fmt = @import("../msvcrt/fmt.zig");

/// Implementation status: Partially implemented (CRT formatter, 1024-character limit).
/// wsprintf is cdecl even though it is exported by USER32.
pub const wsprintfA = if (platform.is_x86) wsprintfANative else wsprintfAThunk;
pub const wsprintfW = if (platform.is_x86) wsprintfWNative else wsprintfWThunk;

fn wsprintfANative(out: [*]u8, format: [*:0]const u8, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return wsprintfAThunk(out, format, crt_fmt.va_list_to_usize(ap));
}

fn wsprintfWNative(out: [*]u16, format: [*:0]const u16, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return wsprintfWThunk(out, format, crt_fmt.va_list_to_usize(ap));
}

fn wsprintfAThunk(out: [*]u8, format: [*:0]const u8, ap: usize) callconv(.c) i32 {
    return crt_fmt.vsnprintf(out, 1024, format, @ptrFromInt(ap));
}

fn wsprintfWThunk(out: [*]u16, format: [*:0]const u16, ap: usize) callconv(.c) i32 {
    return crt_fmt.vsnwprintf(out, 1024, format, @ptrFromInt(ap));
}

/// Implementation status: Partially implemented (same formatter as wsprintf).
pub fn wvsprintfA(out: [*]u8, format: [*:0]const u8, ap: [*]const u32) callconv(w32cc.WINAPI) i32 {
    return crt_fmt.vsnprintf(out, 1024, format, ap);
}

/// Implementation status: Partially implemented (same formatter as wsprintf).
pub fn wvsprintfW(out: [*]u16, format: [*:0]const u16, ap: [*]const u32) callconv(w32cc.WINAPI) i32 {
    return crt_fmt.vsnwprintf(out, 1024, format, ap);
}

const dc = @import("../gdi32/dc.zig");
const gdi32 = @import("../gdi32.zig");
const drawing = @import("../gdi32/drawing.zig");

/// DrawTextA: formats text within a rectangle, supports DT_CALCRECT and basic alignment.
/// Implementation status: Partially implemented (calculates rect, draws placeholder)
pub fn DrawTextA(hdc: usize, lpchText: usize, cchText: i32, lprc: usize, fmt: u32) callconv(w32cc.WINAPI) i32 {
    // DT_CALCRECT = 0x0400 — compute rect but don't draw
    const DT_CALCRECT: u32 = 0x0400;

    // Get font metrics for height calculation
    var fh: i32 = 13;
    var aw: i32 = 6;
    if (gdi32.getDc(hdc)) |dc_entry| {
        if (dc_entry.font != 0) {
            if (gdi32.findObject(dc_entry.font)) |obj| {
                if (obj.obj_type == .Font) {
                    fh = obj.data.font.tmHeight();
                    aw = obj.data.font.aveCharWidth();
                }
            }
        }
    }

    // Determine text length
    const len: i32 = if (cchText >= 0) cchText else blk: {
        if (lpchText == 0) break :blk 0;
        const s = trace.c_span(lpchText);
        break :blk @intCast(s.len);
    };

    // Calculate bounding rect
    const text_width = len * aw;
    const text_height = fh;

    if (lprc != 0) {
        if (fmt & DT_CALCRECT != 0) {
            // Just update the rect with computed dimensions
            const bottom_ptr = @as(*i32, @ptrFromInt(lprc + 12));
            const top_val = @as(*const i32, @ptrFromInt(lprc + 4)).*;
            bottom_ptr.* = top_val + text_height;
            const right_ptr = @as(*i32, @ptrFromInt(lprc + 8));
            const left_val = @as(*const i32, @ptrFromInt(lprc)).*;
            right_ptr.* = left_val + text_width;
        } else {
            // Draw text at rect's top-left
            const left = @as(*const i32, @ptrFromInt(lprc)).*;
            const top = @as(*const i32, @ptrFromInt(lprc + 4)).*;
            _ = drawing.TextOutA(hdc, left, top, lpchText, len);
        }
    }

    return text_height;
}

/// DrawTextW: Unicode variant, delegates to DrawTextA.
pub fn DrawTextW(hdc: usize, lpchText: usize, cchText: i32, lprc: usize, fmt: u32) callconv(w32cc.WINAPI) i32 {
    return DrawTextA(hdc, lpchText, cchText, lprc, fmt);
}

test "USER32 formatters use cdecl variadics and stdcall argument lists" {
    const testing = std.testing;
    var narrow: [1024]u8 = undefined;
    var wide: [1024]u16 = undefined;
    const args = [_]u32{42};
    try testing.expectEqual(@as(i32, 2), wvsprintfA(&narrow, "%u", &args));
    try testing.expectEqualStrings("42", std.mem.sliceTo(&narrow, 0));
    const wide_fmt = [_:0]u16{ '%', 'u' };
    try testing.expectEqual(@as(i32, 2), wvsprintfW(&wide, &wide_fmt, &args));
    try testing.expectEqualSlices(u16, &.{ '4', '2', 0 }, wide[0..3]);
    if (comptime platform.is_native and platform.is_x86) {
        try testing.expectEqual(@as(i32, 2), wsprintfA(&narrow, "%u", @as(u32, 42)));
        try testing.expectEqual(@as(i32, 2), wsprintfW(&wide, &wide_fmt, @as(u32, 42)));
    }
}
