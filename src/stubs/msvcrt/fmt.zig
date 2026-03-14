/// Formatted I/O — printf / sprintf / fprintf / sscanf family.
/// Corresponds to the formatted output portions of <stdio.h>.
/// FILE*-based stream I/O (fopen/fread/fwrite) is in io.zig.
const std = @import("std");
const trace = @import("../../trace.zig");
const io = @import("io.zig");
const platform = @import("../../platform.zig");

// Helper: convert C va_list to a raw usize address.
// On x86, @cVaStart() yields a pointer; on x86_64 it yields a VaListX86_64 struct.
// The callers below need `@intFromPtr(ap)` which only works on pointers.
pub inline fn va_list_to_usize(ap: anytype) usize {
    const T = @TypeOf(ap);
    const info = @typeInfo(T);
    if (info == .pointer) {
        return @intFromPtr(ap);
    } else {
        return @intFromPtr(&ap);
    }
}

pub fn x86_vsnprintf(buf: [*]u8, max: usize, format: [*:0]const u8, args_ptr: usize) usize {
    if (max == 0) return 0;
    const args = @as([*]const usize, @ptrFromInt(args_ptr));
    var ai: usize = 0;
    var oi: usize = 0;
    var ii: usize = 0;
    while (format[ii] != 0 and oi < max - 1) : (ii += 1) {
        if (format[ii] == '%') {
            ii += 1;
            if (format[ii] == 0) break;

            var pad_char: u8 = ' ';
            if (format[ii] == '0') {
                pad_char = '0';
                ii += 1;
            }
            var width: usize = 0;
            while (format[ii] >= '0' and format[ii] <= '9') {
                width = width * 10 + (format[ii] - '0');
                ii += 1;
            }
            if (format[ii] == 'w' or format[ii] == 'l') ii += 1;
            const c = format[ii];
            if (c == 's') {
                if (args[ai] >= 0x10000) {
                    const s = @as([*:0]const u8, @ptrFromInt(trace.addr(args[ai])));
                    const len = std.mem.indexOfScalar(u8, s[0..4096], 0) orelse 0;

                    while (len < width and oi < max - 1) : (width -= 1) {
                        buf[oi] = pad_char;
                        oi += 1;
                    }

                    var si: usize = 0;
                    while (s[si] != 0 and oi < max - 1) {
                        buf[oi] = s[si];
                        oi += 1;
                        si += 1;
                    }
                }
                ai += 1;
            } else if (c == 'd' or c == 'i') {
                const v = @as(i32, @bitCast(@as(u32, @truncate(args[ai]))));
                ai += 1;
                var nb: [32]u8 = undefined;
                const ns = std.fmt.bufPrint(&nb, "{d}", .{v}) catch "";

                const len = ns.len;
                while (len < width and oi < max - 1) : (width -= 1) {
                    buf[oi] = pad_char;
                    oi += 1;
                }

                const copy_len = @min(ns.len, max - 1 - oi);
                @memcpy(buf[oi .. oi + copy_len], ns[0..copy_len]);
                oi += copy_len;
            } else if (c == 'x' or c == 'X') {
                const v = args[ai];
                ai += 1;
                var nb: [32]u8 = undefined;
                var ns: []u8 = "";
                if (c == 'x') {
                    ns = std.fmt.bufPrint(&nb, "{x}", .{v}) catch "";
                } else {
                    ns = std.fmt.bufPrint(&nb, "{X}", .{v}) catch "";
                }

                const len = ns.len;
                while (len < width and oi < max - 1) : (width -= 1) {
                    buf[oi] = pad_char;
                    oi += 1;
                }

                const copy_len = @min(ns.len, max - 1 - oi);
                @memcpy(buf[oi .. oi + copy_len], ns[0..copy_len]);
                oi += copy_len;
            } else if (c == 'u') {
                const v = @as(u32, @truncate(args[ai]));
                ai += 1;
                var nb: [32]u8 = undefined;
                const ns = std.fmt.bufPrint(&nb, "{d}", .{v}) catch "";

                const len = ns.len;
                while (len < width and oi < max - 1) : (width -= 1) {
                    buf[oi] = pad_char;
                    oi += 1;
                }

                const copy_len = @min(ns.len, max - 1 - oi);
                @memcpy(buf[oi .. oi + copy_len], ns[0..copy_len]);
                oi += copy_len;
            } else if (c == 'c') {
                if (oi < max - 1) {
                    buf[oi] = @as(u8, @truncate(args[ai]));
                    oi += 1;
                }
                ai += 1;
            } else if (c == '%') {
                if (oi < max - 1) {
                    buf[oi] = '%';
                    oi += 1;
                }
            }
        } else {
            buf[oi] = format[ii];
            oi += 1;
        }
    }
    buf[oi] = 0;
    return oi;
}

// --- printf ---

pub const stub_printf = if (platform.is_wasm) stub_printf_wasm else stub_printf_native;

fn stub_printf_wasm(fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    return printf_impl(fmt_ptr, ap);
}

fn stub_printf_native(fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return printf_impl(fmt_ptr, va_list_to_usize(ap));
}

fn printf_impl(fmt_ptr: usize, ap: usize) i32 {
    if (fmt_ptr == 0) return 0;
    const fmt = @as([*:0]const u8, @ptrFromInt(trace.addr(fmt_ptr)));
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, ap);
    if (trace.enable_tracing) trace.print("MSVCRT: printf '{s}'\n", .{buf[0..len]});
    const out_file = std.fs.File{ .handle = 1 }; // stdout
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

// --- vprintf ---

pub fn stub_vprintf(fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    if (fmt_ptr == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, @ptrFromInt(trace.addr(fmt_ptr)), trace.addr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: vprintf '{s}'\n", .{buf[0..len]});
    const out_file = std.fs.File{ .handle = 1 }; // stdout
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

// --- vfprintf ---

pub fn stub_vfprintf(stream: usize, fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    if (fmt_ptr == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, @ptrFromInt(trace.addr(fmt_ptr)), trace.addr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: vfprintf '{s}'\n", .{buf[0..len]});

    const out_file = if (stream != 0) io.getFile(@ptrFromInt(trace.addr(stream))) orelse std.fs.File{ .handle = 1 } else std.fs.File{ .handle = 1 };
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

// --- vsnprintf ---

pub fn stub_vsnprintf(buf_ptr: usize, max: usize, fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    if (buf_ptr == 0 or max == 0 or fmt_ptr == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, @ptrFromInt(trace.addr(fmt_ptr)), trace.addr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: _vsnprintf '{s}'\n", .{buf[0..len]});
    const copy_len = @min(len, max - 1);
    const out_buf = @as([*]u8, @ptrFromInt(trace.addr(buf_ptr)));
    @memcpy(out_buf[0..copy_len], buf[0..copy_len]);
    out_buf[copy_len] = 0;
    return @intCast(copy_len);
}

// --- snprintf ---

pub const stub_snprintf = if (platform.is_wasm) stub_snprintf_wasm else stub_snprintf_native;

fn stub_snprintf_wasm(buf_ptr: usize, max: usize, fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    return snprintf_impl(buf_ptr, max, fmt_ptr, ap);
}

fn stub_snprintf_native(buf_ptr: usize, max: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return snprintf_impl(buf_ptr, max, fmt_ptr, va_list_to_usize(ap));
}

fn snprintf_impl(buf_ptr: usize, max: usize, fmt_ptr: usize, ap: usize) i32 {
    if (buf_ptr == 0 or max == 0 or fmt_ptr == 0) return 0;
    const fmt = @as([*:0]const u8, @ptrFromInt(trace.addr(fmt_ptr)));
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, ap);
    if (trace.enable_tracing) trace.print("MSVCRT: _snprintf '{s}'\n", .{buf[0..len]});
    const copy_len = @min(len, max - 1);
    const out_buf = @as([*]u8, @ptrFromInt(trace.addr(buf_ptr)));
    @memcpy(out_buf[0..copy_len], buf[0..copy_len]);
    out_buf[copy_len] = 0;
    return @intCast(copy_len);
}

// --- swprintf ---

pub const stub_swprintf = if (platform.is_wasm) stub_swprintf_wasm else stub_swprintf_native;

fn stub_swprintf_wasm(buf_ptr: usize, fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    return swprintf_impl(buf_ptr, fmt_ptr, ap);
}

fn stub_swprintf_native(buf_ptr: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return swprintf_impl(buf_ptr, fmt_ptr, va_list_to_usize(ap));
}

fn swprintf_impl(buf_ptr: usize, fmt_ptr: usize, ap: usize) i32 {
    if (buf_ptr == 0 or fmt_ptr == 0) return 0;

    var fmt_buf: [4096]u8 = undefined;
    const fmt_w_len = trace.c_span_w(fmt_ptr).len;
    const fmt_w = @as([*]const u16, @ptrFromInt(trace.addr(fmt_ptr)));
    const copy_len = @min(fmt_w_len, 4095);
    for (0..copy_len) |i| {
        fmt_buf[i] = @intCast(fmt_w[i] & 0xFF);
    }
    fmt_buf[copy_len] = 0;
    const fmt_narrow = @as([*:0]const u8, @ptrCast(&fmt_buf));

    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt_narrow, ap);
    if (trace.enable_tracing) trace.print("MSVCRT: swprintf '{s}' -> '{s}'\n", .{ fmt_narrow, buf[0..len] });

    const out_buf = @as([*]u16, @ptrFromInt(trace.addr(buf_ptr)));
    for (0..len) |i| {
        out_buf[i] = buf[i];
    }
    out_buf[len] = 0;
    return @intCast(len);
}

// --- sprintf ---

pub const stub_sprintf = if (platform.is_wasm) stub_sprintf_wasm else stub_sprintf_native;

fn stub_sprintf_wasm(buf_ptr: usize, fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    return sprintf_impl(buf_ptr, fmt_ptr, ap);
}

fn stub_sprintf_native(buf_ptr: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return sprintf_impl(buf_ptr, fmt_ptr, va_list_to_usize(ap));
}

fn sprintf_impl(buf_ptr: usize, fmt_ptr: usize, ap: usize) i32 {
    if (buf_ptr == 0 or fmt_ptr == 0) return 0;
    const fmt = @as([*:0]const u8, @ptrFromInt(trace.addr(fmt_ptr)));
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, ap);
    if (trace.enable_tracing) trace.print("MSVCRT: sprintf '{s}'\n", .{buf[0..len]});
    const out_buf = @as([*]u8, @ptrFromInt(trace.addr(buf_ptr)));
    @memcpy(out_buf[0..len], buf[0..len]);
    out_buf[len] = 0;
    return @intCast(len);
}

// --- puts / fputs ---

pub fn stub_puts(str_ptr: usize) callconv(.c) i32 {
    if (str_ptr >= 0x10000) {
        const s = std.mem.span(@as([*:0]const u8, @ptrFromInt(trace.addr(str_ptr))));
        const f = std.fs.File{ .handle = 1 };
        _ = f.writeAll(s) catch {};
        _ = f.writeAll("\n") catch {};
        return 0;
    }
    return -1;
}

pub fn stub_fputs(str_ptr: usize, file_ptr: usize) callconv(.c) i32 {
    if (str_ptr >= 0x10000) {
        const s = std.mem.span(@as([*:0]const u8, @ptrFromInt(trace.addr(str_ptr))));
        if (trace.enable_tracing) trace.print("MSVCRT: fputs '{s}'\n", .{s});
        if (io.getFile(@ptrFromInt(trace.addr(file_ptr)))) |file| {
            file.writeAll(s) catch return -1;
            return 0;
        }
        return -1;
    }
    return -1;
}

// --- sscanf ---

pub const stub_sscanf = if (platform.is_wasm) stub_sscanf_wasm else stub_sscanf_native;

fn stub_sscanf_wasm(buf_ptr: usize, fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    return sscanf_impl(buf_ptr, fmt_ptr, ap);
}

fn stub_sscanf_native(buf_ptr: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return sscanf_impl(buf_ptr, fmt_ptr, va_list_to_usize(ap));
}

fn sscanf_impl(buf_ptr: usize, fmt_ptr: usize, ap: usize) i32 {
    if (buf_ptr < 0x10000 or fmt_ptr < 0x10000) return 0;
    const buf = std.mem.span(@as([*:0]const u8, @ptrFromInt(trace.addr(buf_ptr))));
    const fmt = std.mem.span(@as([*:0]const u8, @ptrFromInt(trace.addr(fmt_ptr))));
    if (trace.enable_tracing) trace.print("MSVCRT: sscanf('{s}', '{s}')\n", .{ buf, fmt });

    // Read output pointer addresses from va_list
    const args = @as([*]const u32, @ptrFromInt(ap));
    const a1 = trace.addr(args[0]);

    // Super hacky sscanf for single %d/%i/%x
    if (std.mem.eql(u8, fmt, "%d") or std.mem.eql(u8, fmt, "%i") or std.mem.eql(u8, fmt, "%ld")) {
        if (a1 != 0) {
            const val = @import("string.zig").stub_strtol(trace.addr(buf_ptr), 0, 10);
            @as(*i32, @ptrFromInt(a1)).* = val;
            return 1;
        }
    } else if (std.mem.eql(u8, fmt, "%x") or std.mem.eql(u8, fmt, "%X")) {
        if (a1 != 0) {
            const val = @import("string.zig").stub_strtoul(trace.addr(buf_ptr), 0, 16);
            @as(*u32, @ptrFromInt(a1)).* = val;
            return 1;
        }
    } else {
        if (trace.enable_tracing) trace.print("  -> unhandled format!\n", .{});
    }

    return 0;
}
