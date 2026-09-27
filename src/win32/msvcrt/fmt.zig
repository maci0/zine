//! Formatted I/O — printf / sprintf / fprintf / sscanf family.

const std = @import("std");
const trace = @import("../../trace.zig");
const log = @import("../../log.zig");
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

/// Fold one printed digit into a width or precision, saturating instead of
/// overflowing. A guest format string can spell out an arbitrarily long run
/// ("%99999999999d"), and the padding loops stop at the output buffer anyway.
fn appendDigit(val: usize, digit: u8) usize {
    const scaled = std.math.mul(usize, val, 10) catch return std.math.maxInt(usize);
    return std.math.add(usize, scaled, digit) catch std.math.maxInt(usize);
}

/// Internal helper for vsnprintf implementation.
/// Implementation status: Partially implemented
pub fn x86_vsnprintf(buf: [*]u8, max: usize, format: [*:0]const u8, args_ptr: usize) usize {
    if (max == 0) return 0;
    // Guest args are always 32-bit values on the x86 stack, even on x86_64 hosts.
    // args_ptr is ALREADY a host pointer: variadic stubs receive it via
    // addBuiltinExportComptimeVA (translated guest stack address) or via a typed
    // pointer param (auto-translated). Do NOT run it through trace.addr again —
    // host pointers fall inside the guest VA range on WASM, so a second
    // translation turns them into garbage (e.g. printf %s reading 0xCCCCCCCC).
    const args = @as([*]const u32, @ptrFromInt(args_ptr));
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
            // A width or precision the guest spells out runs no bound; both
            // grow as `x * 10 + digit`, so they saturate instead of trapping
            // the formatter on "%99999999999d".
            var width: usize = 0;
            while (format[ii] >= '0' and format[ii] <= '9') {
                width = appendDigit(width, format[ii] - '0');
                ii += 1;
            }
            // Parse precision (.N). A bare "." is precision 0, which C treats
            // as a request for no fractional digits.
            var precision: usize = 0;
            var precision_given = false;
            if (format[ii] == '.') {
                precision_given = true;
                ii += 1;
                while (format[ii] >= '0' and format[ii] <= '9') {
                    precision = appendDigit(precision, format[ii] - '0');
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
                    // A float with no precision prints six fractional digits,
                    // and an explicit one (including ".0") prints exactly
                    // that many, so "$%.0f" of 3.5 reads "4" and not "3.5".
                    const prec_val: u8 = if (precision_given) @intCast(@min(precision, 20)) else 6;
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
/// Implementation status: Fully implemented
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
    @import("../../win32/host_io.zig").writeAllToFile(out_file, buf[0..len]) catch return -1;
    return @intCast(len);
}

/// Prints formatted output to the standard output stream using a pointer to a list of arguments.
/// Implementation status: Fully implemented
pub fn vprintf(fmt: [*:0]const u8, ap: [*]const u32) callconv(.c) i32 {
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, @intFromPtr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: vprintf '{s}'\n", .{buf[0..len]});
    const out_file = @import("../host_io.zig").fileFromFd(1);
    @import("../../win32/host_io.zig").writeAllToFile(out_file, buf[0..len]) catch return -1;
    return @intCast(len);
}

/// Writes formatted output to a stream using a pointer to a list of arguments.
/// Implementation status: Fully implemented
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
    @import("../../win32/host_io.zig").writeAllToFile(out_file, buf[0..len]) catch return -1;
    return @intCast(len);
}

/// Writes formatted data to a string using a pointer to a list of arguments.
/// Implementation status: Fully implemented
pub fn vsnprintf(out: [*]u8, max: usize, fmt: [*:0]const u8, ap: [*]const u32) callconv(.c) i32 {
    if (max == 0) return 0;
    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt, @intFromPtr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: _vsnprintf '{s}'\n", .{buf[0..len]});
    const copy_len = @min(len, max - 1);
    @memcpy(out[0..copy_len], buf[0..copy_len]);
    out[copy_len] = 0;
    // The counted `_s` family reports -1 when the output did not fit; it does
    // not report the truncated count, which a guest would read as success.
    return if (len >= max) -1 else @as(i32, @intCast(copy_len));
}

/// Writes formatted data to a string.
/// Implementation status: Fully implemented
pub const snprintf = if (platform.is_wasm or platform.is_x86_64) stub_snprintf_wasm else stub_snprintf_native;

// `max` is a count, not an address: the variadic registration path translates
// every usize fixed parameter, so it has to be typed u32 to survive intact.
fn stub_snprintf_wasm(out: [*]u8, max: u32, fmt: [*:0]const u8, ap: usize) callconv(.c) i32 {
    return snprintf_impl(out, @as(usize, max), fmt, ap);
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
    // -1 signals truncation to the caller; the copied length would look like
    // a complete write.
    return if (len >= max) -1 else @as(i32, @intCast(copy_len));
}

/// Writes formatted data to a wide-character string.
/// Implementation status: Partially implemented
pub const swprintf = if (platform.is_wasm or platform.is_x86_64) stub_swprintf_wasm else stub_swprintf_native;

/// `_vsnwprintf`: the counted wide form. The guest buffer holds `u16`
/// characters, so the narrow `_vsnprintf` result cannot be written into it.
/// Returns the number of wide characters written, or -1 when the output did
/// not fit in `max` characters (always NUL-terminated).
pub fn vsnwprintf(out: [*]u16, max: usize, fmt: [*:0]const u16, ap: [*]const u32) callconv(.c) i32 {
    if (max == 0) return -1;
    var fmt_buf: [4096]u8 = undefined;
    const fmt_narrow = narrowWide(fmt, &fmt_buf);

    var buf: [4096]u8 = undefined;
    const len = x86_vsnprintf(&buf, 4096, fmt_narrow, @intFromPtr(ap));
    if (trace.enable_tracing) trace.print("MSVCRT: _vsnwprintf '{s}'\n", .{buf[0..len]});

    const written = @min(len, max - 1);
    for (0..written) |i| {
        out[i] = buf[i];
    }
    out[written] = 0;
    return if (len >= max) -1 else @as(i32, @intCast(written));
}

/// `_snwprintf`: the counted wide form taking a variadic argument list.
pub const snwprintf = if (platform.is_wasm or platform.is_x86_64) stub_snwprintf_wasm else stub_snwprintf_native;

fn stub_snwprintf_wasm(out: [*]u16, max: u32, fmt: [*:0]const u16, ap: usize) callconv(.c) i32 {
    return vsnwprintf(out, @as(usize, max), fmt, @ptrFromInt(ap));
}

fn stub_snwprintf_native(buf_ptr: usize, max: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return vsnwprintf(@ptrFromInt(buf_ptr), max, @ptrFromInt(fmt_ptr), @ptrFromInt(va_list_to_usize(ap)));
}

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
    const fmt_narrow = narrowWide(fmt_w, &fmt_buf);

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
/// Implementation status: Fully implemented
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
/// Implementation status: Fully implemented
pub fn puts(str: [*:0]const u8) callconv(.c) i32 {
    const s = std.mem.span(str);
    const host_io = @import("../host_io.zig");
    const f = host_io.fileFromFd(1);
    // Emit the string and its newline in a single write so a failure cannot
    // leave a stray newline on stdout, and report the failure: returning 0
    // told the guest the text had been written when nothing was.
    var line_buf: [1024]u8 = undefined;
    if (s.len < line_buf.len) {
        @memcpy(line_buf[0..s.len], s);
        line_buf[s.len] = '\n';
        host_io.writeAllToFile(f, line_buf[0 .. s.len + 1]) catch |err| {
            log.err("MSVCRT: puts write to stdout failed: {t}", .{err});
            return -1;
        };
        return 0;
    }
    host_io.writeAllToFile(f, s) catch |err| {
        log.err("MSVCRT: puts write to stdout failed: {t}", .{err});
        return -1;
    };
    host_io.writeAllToFile(f, "\n") catch |err| {
        log.err("MSVCRT: puts newline write to stdout failed: {t}", .{err});
        return -1;
    };
    return 0;
}

/// Writes a string to a stream.
pub fn fputs(str: [*:0]const u8, file_ptr: ?*anyopaque) callconv(.c) i32 {
    const s = std.mem.span(str);
    if (trace.enable_tracing) trace.print("MSVCRT: fputs '{s}'\n", .{s});
    if (io.getFile(file_ptr)) |file| {
        @import("../host_io.zig").writeAllToFile(file, s) catch return -1;
        return 0;
    }
    return -1;
}

/// Reads formatted data from a string.
/// Implementation status: Partially implemented
pub const sscanf = if (platform.is_wasm or platform.is_x86_64) stub_sscanf_wasm else stub_sscanf_native;

fn stub_sscanf_wasm(input: [*:0]const u8, fmt: [*:0]const u8, ap: usize) callconv(.c) i32 {
    return sscanf_impl(input, fmt, ap);
}

fn stub_sscanf_native(buf_ptr: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return sscanf_impl(@ptrFromInt(buf_ptr), @ptrFromInt(fmt_ptr), va_list_to_usize(ap));
}

/// Reads formatted data from a wide-character string.
/// Implementation status: Partially implemented
///
/// The input and the format are narrowed before reaching `sscanf_impl`, which
/// only speaks narrow characters. The va_list is shared with the narrow form,
/// so `%s` and `%c` still write narrow bytes into what the guest sized as
/// `wchar_t` buffers; the guest must not read those back as wide strings.
pub const swscanf = if (platform.is_wasm or platform.is_x86_64) stub_swscanf_wasm else stub_swscanf_native;

fn stub_swscanf_wasm(input: [*:0]const u16, fmt: [*:0]const u16, ap: usize) callconv(.c) i32 {
    return swscanf_impl(input, fmt, ap);
}

fn stub_swscanf_native(buf_ptr: usize, fmt_ptr: usize, ...) callconv(.c) i32 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return swscanf_impl(@ptrFromInt(buf_ptr), @ptrFromInt(fmt_ptr), va_list_to_usize(ap));
}

fn swscanf_impl(input: [*:0]const u16, fmt: [*:0]const u16, ap: usize) i32 {
    var input_buf: [4096]u8 = undefined;
    var fmt_buf: [4096]u8 = undefined;
    return sscanf_impl(narrowWide(input, &input_buf), narrowWide(fmt, &fmt_buf), ap);
}

/// Copies a wide string into `buf` as narrow characters, truncating and always
/// terminating. Format handling downstream is single-byte, matching the rest of
/// this module's wide support.
fn narrowWide(w: [*]const u16, buf: *[4096]u8) [*:0]const u8 {
    const w_len = std.mem.indexOfScalar(u16, w[0..4096], 0) orelse 4096;
    const copy_len = @min(w_len, 4095);
    for (0..copy_len) |i| {
        buf[i] = @truncate(w[i]);
    }
    buf[copy_len] = 0;
    return @ptrCast(buf);
}

/// Accumulate one digit into a parsed number, saturating instead of
/// overflowing. sscanf keeps consuming digits past the type's range and
/// stores the clamped value, so a long digit run must not trap.
fn accumulateDigit(comptime T: type, val: T, base: T, digit: T) T {
    const scaled = std.math.mul(T, val, base) catch return std.math.maxInt(T);
    return std.math.add(T, scaled, digit) catch std.math.maxInt(T);
}

fn sscanf_impl(input: [*:0]const u8, fmt_str: [*:0]const u8, ap: usize) i32 {
    const buf = std.mem.span(input);
    const fmt = std.mem.span(fmt_str);
    if (trace.enable_tracing) trace.print("MSVCRT: sscanf('{s}', '{s}')\n", .{ buf, fmt });

    // ap is a HOST pointer (variadic stubs receive it via addBuiltinExportComptimeVA).
    // Do NOT run it through trace.addr — a second translation turns it into
    // garbage on WASM, corrupting the parsed output pointers.
    const args = @as([*]const u32, @ptrFromInt(ap));
    var arg_idx: usize = 0;
    var buf_idx: usize = 0;
    var fmt_idx: usize = 0;
    var match_count: i32 = 0;

    while (fmt_idx < fmt.len) {
        const fc = fmt[fmt_idx];
        if (fc == '%') {
            fmt_idx += 1;
            if (fmt_idx >= fmt.len) break;

            // Skip whitespaces in buf before parsing formatted types
            while (buf_idx < buf.len and std.ascii.isWhitespace(buf[buf_idx])) {
                buf_idx += 1;
            }
            if (buf_idx >= buf.len) break; // End of input

            const specifier = fmt[fmt_idx];
            const out_addr = trace.addr(args[arg_idx]);
            arg_idx += 1;

            if (specifier == 'd' or specifier == 'i' or (specifier == 'l' and fmt_idx + 1 < fmt.len and fmt[fmt_idx + 1] == 'd')) {
                if (specifier == 'l') fmt_idx += 1;

                var sign: i32 = 1;
                if (buf_idx < buf.len and (buf[buf_idx] == '-' or buf[buf_idx] == '+')) {
                    if (buf[buf_idx] == '-') sign = -1;
                    buf_idx += 1;
                }
                var val: i32 = 0;
                var parsed = false;
                while (buf_idx < buf.len and std.ascii.isDigit(buf[buf_idx])) {
                    val = accumulateDigit(i32, val, 10, @as(i32, buf[buf_idx] - '0'));
                    parsed = true;
                    buf_idx += 1;
                }

                if (parsed) {
                    if (out_addr != 0) {
                        // val is never negative here, so negation cannot
                        // overflow even at the saturation point.
                        @as(*i32, @ptrFromInt(out_addr)).* = if (sign < 0) -val else val;
                        match_count += 1;
                    }
                } else {
                    break;
                }
            } else if (specifier == 'x' or specifier == 'X') {
                var parsed = false;
                var val: u32 = 0;

                // skip optional 0x
                if (buf_idx + 1 < buf.len and buf[buf_idx] == '0' and (buf[buf_idx + 1] == 'x' or buf[buf_idx + 1] == 'X')) {
                    buf_idx += 2;
                }

                while (buf_idx < buf.len) {
                    const c = buf[buf_idx];
                    var digit: u32 = 0;
                    if (c >= '0' and c <= '9') {
                        digit = c - '0';
                    } else if (c >= 'a' and c <= 'f') {
                        digit = c - 'a' + 10;
                    } else if (c >= 'A' and c <= 'F') {
                        digit = c - 'A' + 10;
                    } else {
                        break;
                    }
                    val = accumulateDigit(u32, val, 16, digit);
                    parsed = true;
                    buf_idx += 1;
                }

                if (parsed) {
                    if (out_addr != 0) {
                        @as(*u32, @ptrFromInt(out_addr)).* = val;
                        match_count += 1;
                    }
                } else {
                    break;
                }
            } else if (specifier == 's') {
                if (out_addr != 0) {
                    var out_ptr = @as([*]u8, @ptrFromInt(out_addr));
                    var copied: usize = 0;
                    while (buf_idx < buf.len and !std.ascii.isWhitespace(buf[buf_idx])) {
                        out_ptr[copied] = buf[buf_idx];
                        copied += 1;
                        buf_idx += 1;
                    }
                    if (copied > 0) {
                        out_ptr[copied] = 0;
                        match_count += 1;
                    } else {
                        break;
                    }
                }
            } else {
                if (trace.enable_tracing) trace.print("  -> unhandled sscanf format '{c}'!\n", .{specifier});
                break;
            }
            fmt_idx += 1;
        } else if (std.ascii.isWhitespace(fc)) {
            // Space in format matches any whitespace in input
            while (buf_idx < buf.len and std.ascii.isWhitespace(buf[buf_idx])) {
                buf_idx += 1;
            }
            fmt_idx += 1;
        } else {
            // Exact match
            if (buf_idx < buf.len and buf[buf_idx] == fc) {
                buf_idx += 1;
                fmt_idx += 1;
            } else {
                break; // Mismatch
            }
        }
    }

    return match_count;
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

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "sscanf digit accumulation saturates instead of overflowing" {
    // A decimal or hex run longer than the target type can hold must clamp,
    // not trap: sscanf keeps consuming digits past the range.
    try testing.expectEqual(@as(i32, 1234), accumulateDigit(i32, 123, 10, 4));
    try testing.expectEqual(std.math.maxInt(i32), accumulateDigit(i32, 2147483647, 10, 9));
    try testing.expectEqual(std.math.maxInt(u32), accumulateDigit(u32, 0xFFFFFFFF, 16, 0xF));
    try testing.expectEqual(@as(u32, 0), accumulateDigit(u32, 0, 16, 0));
}

test "vsnprintf rounds to the requested precision and survives a huge width" {
    // A double reaches the formatter as two 32-bit halves, low word first.
    const doubleArg = struct {
        fn of(v: f64) [2]u32 {
            const bits: u64 = @bitCast(v);
            return .{ @truncate(bits), @truncate(bits >> 32) };
        }
    }.of;

    var buf: [64]u8 = undefined;
    var args = doubleArg(3.5);
    try testing.expectEqualStrings("4", buf[0..x86_vsnprintf(&buf, 64, "%.0f", @intFromPtr(&args))]);

    args = doubleArg(3.14159);
    try testing.expectEqualStrings("3.14", buf[0..x86_vsnprintf(&buf, 64, "%.2f", @intFromPtr(&args))]);
    try testing.expectEqualStrings("3.141590", buf[0..x86_vsnprintf(&buf, 64, "%f", @intFromPtr(&args))]);

    // A width longer than usize can hold saturates instead of trapping; the
    // padding loop still stops at the buffer. The padding goes out first and
    // never fits alongside the digits, so the buffer comes back full of
    // spaces with the number cut off after it.
    var int_args = [_]u32{std.math.maxInt(i32)};
    try testing.expectEqual(@as(usize, 63), x86_vsnprintf(&buf, 64, "%99999999999d", @intFromPtr(&int_args)));
    // The count alone would pass with a missing terminator or with the
    // saturation dropped, so pin both.
    try testing.expectEqual(@as(u8, 0), buf[63]);
    for (buf[0..63]) |pad| try testing.expectEqual(@as(u8, ' '), pad);

    // A width that does fit keeps the digits after the padding, and "%0"
    // moves the padding to the left of them.
    try testing.expectEqualStrings("      2147483647", buf[0..x86_vsnprintf(&buf, 64, "%16d", @intFromPtr(&int_args))]);
    try testing.expectEqualStrings("0000002147483647", buf[0..x86_vsnprintf(&buf, 64, "%016d", @intFromPtr(&int_args))]);
}

test "narrowWide truncates and always terminates" {
    var buf: [4096]u8 = undefined;

    const short_in = [_]u16{ 'a', 'b', 'c', 0 };
    const short_out: [*:0]const u8 = narrowWide(&short_in, &buf);
    try testing.expectEqualStrings("abc", std.mem.span(short_out));

    // A wide string with no terminator inside the window is cut to the
    // buffer size minus one, and the result stays NUL-terminated.
    var long_in: [4096]u16 = undefined;
    @memset(&long_in, 'x');
    const long_out: [*:0]const u8 = narrowWide(&long_in, &buf);
    try testing.expectEqual(@as(usize, 4095), std.mem.span(long_out).len);
    try testing.expectEqual(@as(u8, 0), long_out[4095]);
}
