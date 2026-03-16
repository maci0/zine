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
pub const printf = if (platform.is_wasm) stub_printf_wasm else stub_printf_native;

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

/// Prints formatted output to the standard output stream using a pointer to a list of arguments.
/// Implementation status: Fully implemented.
pub fn vprintf(fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    if (fmt_ptr == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, @ptrFromInt(trace.addr(fmt_ptr)), trace.addr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: vprintf '{s}'\n", .{buf[0..len]});
    const out_file = std.fs.File{ .handle = 1 }; // stdout
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

/// Writes formatted output to a stream using a pointer to a list of arguments.
/// Implementation status: Fully implemented.
pub fn vfprintf(stream: usize, fmt_ptr: usize, ap: usize) callconv(.c) i32 {
    if (fmt_ptr == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, @ptrFromInt(trace.addr(fmt_ptr)), trace.addr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: vfprintf '{s}'\n", .{buf[0..len]});

    // Detect stdout/stderr by comparing stream pointer to known FILE addresses
    const iob_base = @intFromPtr(&io.msvcrt_iob);
    const iob_end = iob_base + @sizeOf(@TypeOf(io.msvcrt_iob));
    const stream_addr = trace.addr(stream);
    const out_file = if (stream_addr >= iob_base and stream_addr < iob_end)
        // Known iob entry — compute fd from offset
        std.fs.File{ .handle = @intCast((stream_addr - iob_base) / @sizeOf(io.MSVCRT_FILE)) }
    else if (stream != 0)
        io.getFile(@ptrFromInt(stream_addr)) orelse std.fs.File{ .handle = 1 }
    else
        std.fs.File{ .handle = 1 };
    out_file.writeAll(buf[0..len]) catch return -1;
    return @intCast(len);
}

/// Writes formatted data to a string using a pointer to a list of arguments.
/// Implementation status: Fully implemented.
pub fn vsnprintf(buf_ptr: usize, max: usize, fmt_ptr: usize, ap: usize) callconv(.c) i32 {
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

/// Writes formatted data to a string.
/// Implementation status: Fully implemented.
pub const snprintf = if (platform.is_wasm) stub_snprintf_wasm else stub_snprintf_native;

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

/// Writes formatted data to a wide-character string.
/// Implementation status: Partially implemented.
pub const swprintf = if (platform.is_wasm) stub_swprintf_wasm else stub_swprintf_native;

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

/// Writes formatted data to a string.
/// Implementation status: Fully implemented.
pub const sprintf = if (platform.is_wasm) stub_sprintf_wasm else stub_sprintf_native;

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

/// Writes a string to the standard output stream and appends a newline character.
/// Implementation status: Fully implemented.
pub fn puts(str_ptr: usize) callconv(.c) i32 {
    if (str_ptr >= 0x10000) {
        const s = std.mem.span(@as([*:0]const u8, @ptrFromInt(trace.addr(str_ptr))));
        const f = std.fs.File{ .handle = 1 };
        _ = f.writeAll(s) catch {};
        _ = f.writeAll("\n") catch {};
        return 0;
    }
    return -1;
}

/// Writes a string to a stream.
/// Implementation status: Fully implemented.
pub fn fputs(str_ptr: usize, file_ptr: usize) callconv(.c) i32 {
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

/// Reads formatted data from a string.
/// Implementation status: Partially implemented.
pub const sscanf = if (platform.is_wasm) stub_sscanf_wasm else stub_sscanf_native;

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
            const val = string.strtol(trace.addr(buf_ptr), 0, 10);
            @as(*i32, @ptrFromInt(a1)).* = val;
            return 1;
        }
    } else if (std.mem.eql(u8, fmt, "%x") or std.mem.eql(u8, fmt, "%X")) {
        if (a1 != 0) {
            const val = string.strtoul(trace.addr(buf_ptr), 0, 16);
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
pub fn stdio_common_vfprintf(_options: u64, stream: usize, fmt_ptr: usize, _locale: usize, ap: usize) callconv(.c) i32 {
    _ = _options;
    _ = _locale;
    return vfprintf(stream, fmt_ptr, ap);
}

/// UCRT common vsprintf wrapper.
/// Implementation status: Fully implemented
pub fn stdio_common_vsprintf(_options: u64, buf_ptr: usize, buf_size: usize, fmt_ptr: usize, _locale: usize, ap: usize) callconv(.c) i32 {
    _ = _options;
    _ = _locale;
    return vsnprintf(buf_ptr, buf_size, fmt_ptr, ap);
}

/// UCRT common vfscanf wrapper.
/// Implementation status: Stub
pub fn stdio_common_vfscanf(_options: u64, _stream: usize, _fmt: usize, _locale: usize, _ap: usize) callconv(.c) i32 {
    _ = .{ _options, _stream, _fmt, _locale, _ap };
    return 0;
}
