//! Formatted I/O — printf / sprintf / fprintf / sscanf family.

const std = @import("std");
const trace = @import("../../trace.zig");
const io = @import("io.zig");
const string = @import("string.zig");
const platform = @import("../../platform.zig");

/// Helper to convert C va_list to a raw usize address.
/// Implementation status: Fully implemented
pub inline fn va_list_to_usize(ap: anytype) usize {
    const T = @TypeOf(ap);
    const info = @typeInfo(T);
    if (info == .pointer) {
        return @intFromPtr(ap);
    } else {
        return @intFromPtr(&ap);
    }
}

/// Internal helper for vsnprintf implementation.
/// Implementation status: Partially implemented
pub fn x86_vsnprintf(buf: [*]u8, max: usize, format: [*:0]const u8, args_ptr: usize) usize {
    if (max == 0) return 0;
    // Guest args are always 32-bit values on the x86 stack, even on x86_64 hosts.
    const args = @as([*]const u32, @ptrFromInt(trace.addr(args_ptr)));
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
            // Parse precision (.N)
            var precision: usize = 0;
            if (format[ii] == '.') {
                ii += 1;
                while (format[ii] >= '0' and format[ii] <= '9') {
                    precision = precision * 10 + (format[ii] - '0');
                    ii += 1;
                }
            }
            // Skip length modifiers (l, ll, h, w, I64, z)
            while (format[ii] == 'w' or format[ii] == 'l' or format[ii] == 'h' or
                format[ii] == 'I' or format[ii] == 'z' or format[ii] == 'j' or
                format[ii] == 't' or format[ii] == 'q') ii += 1;
            if (ii > 0 and format[ii - 1] == 'I' and format[ii] == '6' and format[ii + 1] == '4') ii += 2;
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
            } else if (c == 'f' or c == 'e' or c == 'E' or c == 'g' or c == 'G') {
                // Floating point: double is 8 bytes (2 x u32 on stack)
                {
                    const lo: u32 = @truncate(args[ai]);
                    const hi: u32 = @truncate(args[ai + 1]);
                    ai += 2;
                    const bits: u64 = (@as(u64, hi) << 32) | @as(u64, lo);
                    const val: f64 = @bitCast(bits);
                    var nb: [64]u8 = undefined;
                    const prec_val: u8 = if (precision > 0) @intCast(@min(precision, 20)) else 6;
                    const ns = std.fmt.bufPrint(&nb, "{d:.[1]}", .{ val, prec_val }) catch "?";
                    const copy_len = @min(ns.len, max - 1 - oi);
                    @memcpy(buf[oi .. oi + copy_len], ns[0..copy_len]);
                    oi += copy_len;
                }
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

/// Prints formatted output to the standard output stream.
/// Implementation status: Fully implemented.
// On x86_64 compat mode, use the WASM-style stub (positional fmt + ap args)
// because the compat thunk dispatcher passes the va_list as a positional arg,
// not through the C variadic mechanism.
pub const printf = if (platform.is_wasm or platform.is_x86_64) stub_printf_wasm else stub_printf_native;

fn stub_printf_wasm(fmt: [*:0]const u8, ap: usize) callconv(.c) i32 {
    return printf_impl(fmt, ap);
}

fn stub_printf_native(fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return printf_impl(@ptrFromInt(fmt_ptr), va_list_to_usize(ap));
}

fn printf_impl(fmt: [*:0]const u8, ap: usize) i32 {
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, ap);
    if (trace.enable_tracing) trace.print("MSVCRT: printf '{s}'\n", .{buf[0..len]});
    const out_file = @import("../host_io.zig").fileFromFd(1); // stdout
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

/// Prints formatted output to the standard output stream using a pointer to a list of arguments.
/// Implementation status: Fully implemented.
pub fn vprintf(fmt: [*:0]const u8, ap: [*]const u32) callconv(.c) i32 {
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, @intFromPtr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: vprintf '{s}'\n", .{buf[0..len]});
    const out_file = @import("../host_io.zig").fileFromFd(1);
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

/// Writes formatted output to a stream using a pointer to a list of arguments.
/// Implementation status: Fully implemented.
pub fn vfprintf(stream: ?*anyopaque, fmt: [*:0]const u8, ap: [*]const u32) callconv(.c) i32 {
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, @intFromPtr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: vfprintf '{s}'\n", .{buf[0..len]});

    // Detect stdout/stderr by comparing stream pointer to known FILE addresses
    const iob_base = @intFromPtr(&io.msvcrt_iob);
    const iob_end = iob_base + @sizeOf(@TypeOf(io.msvcrt_iob));
    const stream_addr = if (stream) |s| @intFromPtr(s) else 0;
    const out_file = if (stream_addr >= iob_base and stream_addr < iob_end)
        @import("../host_io.zig").fileFromFd(@intCast((stream_addr - iob_base) / @sizeOf(io.MSVCRT_FILE)))
    else if (stream != null)
        io.getFile(stream) orelse @import("../host_io.zig").fileFromFd(1)
    else
        @import("../host_io.zig").fileFromFd(1);
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

/// Writes formatted data to a string using a pointer to a list of arguments.
/// Implementation status: Fully implemented.
pub fn vsnprintf(out: [*]u8, max: usize, fmt: [*:0]const u8, ap: [*]const u32) callconv(.c) i32 {
    if (max == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, @intFromPtr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: _vsnprintf '{s}'\n", .{buf[0..len]});
    const copy_len = @min(len, max - 1);
    @memcpy(out[0..copy_len], buf[0..copy_len]);
    out[copy_len] = 0;
    return @intCast(copy_len);
}

/// Writes formatted data to a string.
/// Implementation status: Fully implemented.
pub const snprintf = if (platform.is_wasm or platform.is_x86_64) stub_snprintf_wasm else stub_snprintf_native;

fn stub_snprintf_wasm(out: [*]u8, max: usize, fmt: [*:0]const u8, ap: usize) callconv(.c) i32 {
    return snprintf_impl(out, max, fmt, ap);
}

fn stub_snprintf_native(buf_ptr: usize, max: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return snprintf_impl(@ptrFromInt(buf_ptr), max, @ptrFromInt(fmt_ptr), va_list_to_usize(ap));
}

fn snprintf_impl(out: [*]u8, max: usize, fmt: [*:0]const u8, ap: usize) i32 {
    if (max == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, ap);
    if (trace.enable_tracing) trace.print("MSVCRT: _snprintf '{s}'\n", .{buf[0..len]});
    const copy_len = @min(len, max - 1);
    @memcpy(out[0..copy_len], buf[0..copy_len]);
    out[copy_len] = 0;
    return @intCast(copy_len);
}

/// Writes formatted data to a wide-character string.
/// Implementation status: Partially implemented.
pub const swprintf = if (platform.is_wasm or platform.is_x86_64) stub_swprintf_wasm else stub_swprintf_native;

fn stub_swprintf_wasm(out: [*]u16, fmt_w: [*]const u16, ap: usize) callconv(.c) i32 {
    return swprintf_impl(out, fmt_w, ap);
}

fn stub_swprintf_native(buf_ptr: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return swprintf_impl(@ptrFromInt(buf_ptr), @ptrFromInt(fmt_ptr), va_list_to_usize(ap));
}

fn swprintf_impl(out: [*]u16, fmt_w: [*]const u16, ap: usize) i32 {
    // Convert wide format to narrow
    var fmt_buf: [4096]u8 = undefined;
    const fmt_w_len = std.mem.indexOfScalar(u16, fmt_w[0..4096], 0) orelse 4096;
    const copy_len = @min(fmt_w_len, 4095);
    for (0..copy_len) |i| {
        fmt_buf[i] = @intCast(fmt_w[i] & 0xFF);
    }
    fmt_buf[copy_len] = 0;
    const fmt_narrow = @as([*:0]const u8, @ptrCast(&fmt_buf));

    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt_narrow, ap);
    if (trace.enable_tracing) trace.print("MSVCRT: swprintf '{s}' -> '{s}'\n", .{ fmt_narrow, buf[0..len] });

    for (0..len) |i| {
        out[i] = buf[i];
    }
    out[len] = 0;
    return @intCast(len);
}

/// Writes formatted data to a string.
/// Implementation status: Fully implemented.
pub const sprintf = if (platform.is_wasm or platform.is_x86_64) stub_sprintf_wasm else stub_sprintf_native;

fn stub_sprintf_wasm(out: [*]u8, fmt: [*:0]const u8, ap: usize) callconv(.c) i32 {
    return sprintf_impl(out, fmt, ap);
}

fn stub_sprintf_native(buf_ptr: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return sprintf_impl(@ptrFromInt(buf_ptr), @ptrFromInt(fmt_ptr), va_list_to_usize(ap));
}

fn sprintf_impl(out: [*]u8, fmt: [*:0]const u8, ap: usize) i32 {
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, ap);
    if (trace.enable_tracing) trace.print("MSVCRT: sprintf '{s}'\n", .{buf[0..len]});
    @memcpy(out[0..len], buf[0..len]);
    out[len] = 0;
    return @intCast(len);
}

/// Writes a string to the standard output stream and appends a newline character.
/// Implementation status: Fully implemented.
pub fn puts(str: [*:0]const u8) callconv(.c) i32 {
    const s = std.mem.span(str);
    const f = @import("../host_io.zig").fileFromFd(1);
    _ = f.writeAll(s) catch {};
    _ = f.writeAll("\n") catch {};
    return 0;
}

/// Writes a string to a stream.
pub fn fputs(str: [*:0]const u8, file_ptr: ?*anyopaque) callconv(.c) i32 {
    const s = std.mem.span(str);
    if (trace.enable_tracing) trace.print("MSVCRT: fputs '{s}'\n", .{s});
    if (io.getFile(file_ptr)) |file| {
        file.writeAll(s) catch return -1;
        return 0;
    }
    return -1;
}

/// Reads formatted data from a string.
/// Implementation status: Partially implemented.
pub const sscanf = if (platform.is_wasm or platform.is_x86_64) stub_sscanf_wasm else stub_sscanf_native;

fn stub_sscanf_wasm(input: [*:0]const u8, fmt: [*:0]const u8, ap: usize) callconv(.c) i32 {
    return sscanf_impl(input, fmt, ap);
}

fn stub_sscanf_native(buf_ptr: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return sscanf_impl(@ptrFromInt(buf_ptr), @ptrFromInt(fmt_ptr), va_list_to_usize(ap));
}

fn sscanf_impl(input: [*:0]const u8, fmt_str: [*:0]const u8, ap: usize) i32 {
    const buf = std.mem.span(input);
    const fmt = std.mem.span(fmt_str);
    if (trace.enable_tracing) trace.print("MSVCRT: sscanf('{s}', '{s}')\n", .{ buf, fmt });

    // Read output pointer addresses from va_list.
    // NOTE: args[i] values are raw guest VAs — inner trace.addr is needed.
    const args = @as([*]const u32, @ptrFromInt(trace.addr(ap)));
    const a1 = trace.addr(args[0]);

    // Super hacky sscanf for single %d/%i/%x
    if (std.mem.eql(u8, fmt, "%d") or std.mem.eql(u8, fmt, "%i") or std.mem.eql(u8, fmt, "%ld")) {
        if (a1 != 0) {
            const val = string.strtol(@intFromPtr(input), 0, 10);
            @as(*i32, @ptrFromInt(a1)).* = val;
            return 1;
        }
    } else if (std.mem.eql(u8, fmt, "%x") or std.mem.eql(u8, fmt, "%X")) {
        if (a1 != 0) {
            const val = string.strtoul(@intFromPtr(input), 0, 16);
            @as(*u32, @ptrFromInt(a1)).* = val;
            return 1;
        }
    } else {
        if (trace.enable_tracing) trace.print("  -> unhandled format!\n", .{});
    }

    return 0;
}

/// UCRT common vfprintf wrapper.
/// Implementation status: Fully implemented
pub fn stdio_common_vfprintf(_options: u64, stream: ?*anyopaque, fmt: [*:0]const u8, _locale: usize, ap: [*]const u32) callconv(.c) i32 {
    _ = _options;
    _ = _locale;
    return vfprintf(stream, fmt, ap);
}

/// UCRT common vsprintf wrapper.
pub fn stdio_common_vsprintf(_options: u64, out: [*]u8, buf_size: usize, fmt: [*:0]const u8, _locale: usize, ap: [*]const u32) callconv(.c) i32 {
    _ = _options;
    _ = _locale;
    return vsnprintf(out, buf_size, fmt, ap);
}

/// UCRT common vfscanf wrapper.
/// Implementation status: Stub
pub fn stdio_common_vfscanf(_options: u64, _stream: usize, _fmt: usize, _locale: usize, _ap: usize) callconv(.c) i32 {
    _ = .{ _options, _stream, _fmt, _locale, _ap };
    return 0;
}
