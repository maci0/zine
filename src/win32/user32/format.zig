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
                '%' => { lpOut[oi] = '%'; oi += 1; fi += 1; },
                'd', 'i' => {
                    if (ai < args.len) {
                        const val = @as(i32, @bitCast(@as(u32, @truncate(args[ai]))));
                        ai += 1;
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "?";
                        for (str) |c| { if (oi < MAX_OUT - 1) { lpOut[oi] = c; oi += 1; } }
                    }
                    fi += 1;
                },
                'u' => {
                    if (ai < args.len) {
                        const val = @as(u32, @truncate(args[ai]));
                        ai += 1;
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "?";
                        for (str) |c| { if (oi < MAX_OUT - 1) { lpOut[oi] = c; oi += 1; } }
                    }
                    fi += 1;
                },
                'x' => {
                    if (ai < args.len) {
                        const val = @as(u32, @truncate(args[ai]));
                        ai += 1;
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{x}", .{val}) catch "?";
                        for (str) |c| { if (oi < MAX_OUT - 1) { lpOut[oi] = c; oi += 1; } }
                    }
                    fi += 1;
                },
                'X' => {
                    if (ai < args.len) {
                        const val = @as(u32, @truncate(args[ai]));
                        ai += 1;
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{X}", .{val}) catch "?";
                        for (str) |c| { if (oi < MAX_OUT - 1) { lpOut[oi] = c; oi += 1; } }
                    }
                    fi += 1;
                },
                's' => {
                    if (ai < args.len and args[ai] != 0) {
                        const s = trace.c_span(args[ai]);
                        ai += 1;
                        for (s) |c| { if (oi < MAX_OUT - 1) { lpOut[oi] = c; oi += 1; } }
                    } else { ai += 1; }
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
                    lpOut[oi] = '%'; oi += 1;
                    if (oi < MAX_OUT - 1) { lpOut[oi] = lpFmt[fi]; oi += 1; }
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

pub fn stub_DrawTextA(hdc: usize, lpchText: usize, cchText: i32, lprc: usize, format: u32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = lpchText;
    _ = cchText;
    _ = lprc;
    _ = format;
    return 0;
}

pub fn stub_DrawTextW(hdc: usize, lpchText: usize, cchText: i32, lprc: usize, format: u32) callconv(w32cc.WINAPI) i32 {
    _ = hdc;
    _ = lpchText;
    _ = cchText;
    _ = lprc;
    _ = format;
    return 0;
}
