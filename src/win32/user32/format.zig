const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

pub fn wsprintfA(lpOut: [*]u8, lpFmt: [*:0]const u8, a1: usize, a2: usize, a3: usize, a4: usize) callconv(w32cc.WINAPI) i32 {
    // Simple sprintf implementation supporting %d, %s, %x, %X, %u, %%
    const args = [_]usize{ a1, a2, a3, a4 };
    var ai: usize = 0;
    var oi: usize = 0;
    var fi: usize = 0;
    const MAX_OUT: usize = 1024;

    while (lpFmt[fi] != 0 and oi < MAX_OUT - 1) {
        if (lpFmt[fi] == '%') {
            fi += 1;
            if (lpFmt[fi] == 0) break;

            // Skip width/flags (simplified)
            while (lpFmt[fi] == '-' or lpFmt[fi] == '+' or lpFmt[fi] == ' ' or lpFmt[fi] == '0') fi += 1;
            while (lpFmt[fi] >= '0' and lpFmt[fi] <= '9') fi += 1;

            switch (lpFmt[fi]) {
                '%' => {
                    lpOut[oi] = '%';
                    oi += 1;
                    fi += 1;
                },
                'd', 'i' => {
                    if (ai < args.len) {
                        const val = @as(i32, @bitCast(@as(u32, @truncate(args[ai]))));
                        ai += 1;
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "?";
                        for (str) |c| {
                            if (oi < MAX_OUT - 1) {
                                lpOut[oi] = c;
                                oi += 1;
                            }
                        }
                    }
                    fi += 1;
                },
                'u' => {
                    if (ai < args.len) {
                        const val = @as(u32, @truncate(args[ai]));
                        ai += 1;
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "?";
                        for (str) |c| {
                            if (oi < MAX_OUT - 1) {
                                lpOut[oi] = c;
                                oi += 1;
                            }
                        }
                    }
                    fi += 1;
                },
                'x' => {
                    if (ai < args.len) {
                        const val = @as(u32, @truncate(args[ai]));
                        ai += 1;
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{x}", .{val}) catch "?";
                        for (str) |c| {
                            if (oi < MAX_OUT - 1) {
                                lpOut[oi] = c;
                                oi += 1;
                            }
                        }
                    }
                    fi += 1;
                },
                'X' => {
                    if (ai < args.len) {
                        const val = @as(u32, @truncate(args[ai]));
                        ai += 1;
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{X}", .{val}) catch "?";
                        for (str) |c| {
                            if (oi < MAX_OUT - 1) {
                                lpOut[oi] = c;
                                oi += 1;
                            }
                        }
                    }
                    fi += 1;
                },
                's' => {
                    if (ai < args.len and args[ai] != 0) {
                        const s = trace.c_span(args[ai]);
                        ai += 1;
                        for (s) |c| {
                            if (oi < MAX_OUT - 1) {
                                lpOut[oi] = c;
                                oi += 1;
                            }
                        }
                    } else {
                        ai += 1;
                    }
                    fi += 1;
                },
                'c' => {
                    if (ai < args.len) {
                        lpOut[oi] = @truncate(args[ai]);
                        oi += 1;
                        ai += 1;
                    }
                    fi += 1;
                },
                else => {
                    // Unknown specifier — output literal
                    lpOut[oi] = '%';
                    oi += 1;
                    if (oi < MAX_OUT - 1) {
                        lpOut[oi] = lpFmt[fi];
                        oi += 1;
                    }
                    fi += 1;
                },
            }
        } else {
            lpOut[oi] = lpFmt[fi];
            oi += 1;
            fi += 1;
        }
    }
    lpOut[oi] = 0;
    return @intCast(oi);
}

pub fn stub_wsprintfW(lpOut: [*]u16, lpFmt: [*]const u16, a1: usize, a2: usize, a3: usize, a4: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpFmt;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    lpOut[0] = 0;
    return 0;
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
