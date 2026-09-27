const std = @import("std");
const x86_memory = @import("../../x86/memory.zig");
const trace = @import("../../trace.zig");

/// Retrieves information about any valid installed or available code page.
/// Implementation status: Partially implemented
pub fn GetCPInfo(CodePage: u32, lpCPInfo: *anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = CodePage;
    const cpinfo = @as([*]u8, @ptrCast(lpCPInfo));
    @memset(cpinfo[0..18], 0);
    const max_char_size = @as(*u32, @ptrCast(@alignCast(cpinfo)));
    max_char_size.* = 1;
    return 1;
}

/// Retrieves the current Windows ANSI code page identifier for the operating system.
/// Implementation status: Fully implemented
pub fn GetACP() callconv(w32cc.WINAPI) u32 {
    return ansi.code_page;
}

/// Determines whether a specified code page is valid.
/// Implementation status: Partially implemented
pub fn IsValidCodePage(CodePage: u32) callconv(w32cc.WINAPI) i32 {
    _ = CodePage;
    return 1;
}

/// Determines whether a specified character is a lead byte for the specified code page.
/// Implementation status: Partially implemented
pub fn IsDBCSLeadByteEx(CodePage: u32, TestChar: u8) callconv(w32cc.WINAPI) i32 {
    _ = CodePage;
    _ = TestChar;
    return 0;
}

/// Determines whether a character is a lead byte for the system default ANSI code page.
/// Implementation status: Partially implemented
pub fn IsDBCSLeadByte(testChar: u8) callconv(w32cc.WINAPI) i32 {
    _ = testChar;
    // We assume an ASCII/ANSI setup without DBCS
    return 0;
}

/// --- Conversion functions ---
/// Both directions convert the ANSI code page reported by GetACP (CP1252):
/// a single byte maps to one code point, so a surrogate pair in the wide
/// string has no representation and encodes to the default character.
/// Implementation status: Fully implemented
pub fn MultiByteToWideChar(CodePage: u32, dwFlags: u32, lpMultiByteStr_ptr: usize, cbMultiByte: i32, lpWideCharStr_ptr: usize, cchWideChar: i32) callconv(w32cc.WINAPI) i32 {
    _ = dwFlags;
    if (CodePage != 0 and CodePage != ansi.code_page) {
        // Only the ACP and the OEM code page are supported; the OEM page is
        // 437, which differs from 1252, so report the failure rather than
        // returning a string decoded with the wrong table.
        kernel32_error.SetLastError(1); // ERROR_INVALID_FUNCTION
        return 0;
    }

    if (lpMultiByteStr_ptr == 0) return 0;
    // Both pointers are guest VAs (usize params — not auto-translated).
    const mb_str = @as([*]const u8, @ptrFromInt(trace.addr(lpMultiByteStr_ptr)));

    const len: usize = if (cbMultiByte == -1)
        trace.c_span(lpMultiByteStr_ptr).len + 1
    else
        @intCast(cbMultiByte);

    if (trace.enable_tracing and len > 0 and len < 1024) {
        trace.print("MB2WC: ptr=0x{x} ", .{lpMultiByteStr_ptr});
        for (0..@min(len, 16)) |i| {
            trace.print("{x:0>2} ", .{mb_str[i]});
        }
        trace.print(" (cbMultiByte={d}, cchWideChar={d})\n", .{ cbMultiByte, cchWideChar });
    }

    if (cchWideChar == 0 or lpWideCharStr_ptr == 0) return @intCast(len);
    // Safety: reject obviously invalid output buffer pointers
    if (lpWideCharStr_ptr < 0x10000) return @intCast(len);

    const wc_str = @as([*]u16, @ptrFromInt(trace.addr(lpWideCharStr_ptr)));
    if (cchWideChar < len) {
        if (trace.enable_tracing and len > 0 and len < 1024) trace.print("  -> ERROR_INSUFFICIENT_BUFFER\n", .{});
        kernel32_error.SetLastError(122); // ERROR_INSUFFICIENT_BUFFER
        return 0;
    }

    // CP1252 is single-byte: one code point per byte, so the wide count
    // matches the byte count exactly.
    for (0..len) |i| wc_str[i] = @intCast(ansi.byteToCodepoint(mb_str[i]));
    if (trace.enable_tracing and len > 0 and len < 1024) trace.print("  -> success, returning {d}\n", .{len});
    return @intCast(len);
}

/// Maps a UTF-16 (wide character) string to a character string.
/// Implementation status: Fully implemented
pub fn WideCharToMultiByte(CodePage: u32, dwFlags: u32, lpWideCharStr_ptr: usize, cchWideChar: i32, lpMultiByteStr_ptr: usize, cbMultiByte: i32, lpDefaultChar: ?*const u8, lpUsedDefaultChar: ?*i32) callconv(w32cc.WINAPI) i32 {
    _ = dwFlags;
    _ = lpDefaultChar;
    if (CodePage != 0 and CodePage != ansi.code_page) {
        kernel32_error.SetLastError(1); // ERROR_INVALID_FUNCTION
        return 0;
    }

    if (lpWideCharStr_ptr == 0) return 0;
    // Both pointers are guest VAs (usize params — not auto-translated).
    const wc_str = @as([*]const u16, @ptrFromInt(trace.addr(lpWideCharStr_ptr)));

    const len: usize = if (cchWideChar < 0)
        trace.c_span_w(lpWideCharStr_ptr).len + 1
    else
        @intCast(cchWideChar);

    if (cbMultiByte == 0 or lpMultiByteStr_ptr == 0) return @intCast(len);
    if (lpMultiByteStr_ptr < 0x10000) return @intCast(len);

    const mb_str = @as([*]u8, @ptrFromInt(trace.addr(lpMultiByteStr_ptr)));
    const limit = @min(len, @as(usize, @intCast(cbMultiByte)));
    var used_default = false;
    for (0..limit) |i| {
        mb_str[i] = ansi.codepointToByte(wc_str[i]) orelse blk: {
            used_default = true;
            break :blk ansi.default_char;
        };
    }
    if (lpUsedDefaultChar) |used| used.* = @intFromBool(used_default);
    return @intCast(limit);
}

const ansi = @import("../ansi.zig");
const kernel32_error = @import("error.zig");

const kernel32_mem = @import("mem.zig");
const w32cc = @import("../calling_convention.zig");

/// Formats a message string.
/// Implementation status: Partially implemented
pub fn FormatMessageA(dwFlags: u32, lpSource: ?*anyopaque, dwMessageId: u32, dwLanguageId: u32, lpBuffer: [*]u8, nSize: u32, Arguments: ?*anyopaque) callconv(w32cc.WINAPI) u32 {
    _ = dwLanguageId;

    if (trace.enable_tracing) {
        trace.print("KERNEL32: FormatMessageA(id={d}, flags={x})\n", .{ dwMessageId, dwFlags });
        if (Arguments != null) {
            const args = @as([*]usize, @ptrCast(@alignCast(Arguments.?)));
            const arg1 = args[0];
            if (arg1 != 0 and arg1 > 0x10000) {
                const wc_str = trace.c_span(@intFromPtr(@as([*:0]const u16, @ptrFromInt(arg1))));
                var buf: [1024]u8 = undefined;
                const copy_len = @min(wc_str.len, 1023);
                for (wc_str[0..copy_len], 0..) |c, i| {
                    buf[i] = @intCast(c & 0xFF);
                }
                buf[copy_len] = 0;
                trace.print("  Arg1 (ws): {s}\n", .{buf[0..copy_len]});
            }
        }
    }

    const FORMAT_MESSAGE_ALLOCATE_BUFFER = 0x0100;
    const FORMAT_MESSAGE_FROM_STRING = 0x0400;
    var msg: []const u8 = "Error message not available.\n\x00";

    if ((dwFlags & FORMAT_MESSAGE_FROM_STRING) != 0 and lpSource != null) {
        msg = trace.c_span(@intFromPtr(@as([*:0]const u8, @ptrCast(lpSource.?))));
    } else if (dwMessageId == 2101) {
        msg = "invalid directive in preprocessed RC file\n\x00";
    }

    if ((dwFlags & FORMAT_MESSAGE_ALLOCATE_BUFFER) != 0) {
        const ptr = kernel32_mem.raw_alloc(256);
        if (ptr) |p| {
            const out_buf = @as([*]u8, @ptrCast(p));
            @memcpy(out_buf[0..msg.len], msg);

            // lpBuffer is a typed pointer (auto-translated to host). The slot
            // must receive the GUEST VA of the message so the x86 code can
            // read it back through the interpreter.
            const shared = @import("../shared.zig");
            const out_ptr = @as(*?[*]u8, @ptrCast(@alignCast(lpBuffer)));
            out_ptr.* = @ptrFromInt(shared.hostToGuest(@intFromPtr(p)));
            if (trace.enable_tracing) trace.print("  -> returning {d}\n", .{msg.len - 1});
            return @intCast(msg.len - 1);
        }
        if (trace.enable_tracing) trace.print("  -> returning 0 (alloc failed)\n", .{});
        return 0;
    } else {
        if (nSize > 0) {
            const copy_len = @min(nSize - 1, msg.len - 1);
            @memcpy(lpBuffer[0..copy_len], msg[0..copy_len]);
            lpBuffer[copy_len] = 0;
            if (trace.enable_tracing) trace.print("  -> returning {d}\n", .{copy_len});
            return @intCast(copy_len);
        }
    }
    if (trace.enable_tracing) trace.print("  -> returning 0 (nSize 0)\n", .{});
    return 0;
}

// --- String type/comparison functions ---

/// Upper case characters
const C1_UPPER = 0x0001;
/// Lower case characters
const C1_LOWER = 0x0002;
/// Decimal digits
const C1_DIGIT = 0x0004;
/// Space characters
const C1_SPACE = 0x0008;
/// Punctuation characters
const C1_PUNCT = 0x0010;
/// Control characters
const C1_CNTRL = 0x0020;
/// Blank characters
const C1_BLANK = 0x0040;
/// Hexadecimal digits
const C1_XDIGIT = 0x0080;
/// Any alphabetic character
const C1_ALPHA = 0x0100;
/// Any defined character
const C1_DEFINED = 0x0200;

fn getCharTypeW(ch: u16) u16 {
    if (ch > 0xFF) return C1_ALPHA | C1_DEFINED; // Non-ASCII: assume alpha
    const c: u8 = @intCast(ch & 0xFF);
    var ct: u16 = C1_DEFINED;
    if (c < 0x20 or c == 0x7F) ct |= C1_CNTRL;
    if (c >= 'A' and c <= 'Z') ct |= C1_UPPER | C1_ALPHA;
    if (c >= 'a' and c <= 'z') ct |= C1_LOWER | C1_ALPHA;
    if (c >= '0' and c <= '9') ct |= C1_DIGIT;
    if ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f')) ct |= C1_XDIGIT;
    if (c == ' ' or (c >= 0x09 and c <= 0x0D)) ct |= C1_SPACE;
    if (c == ' ' or c == 0x09) ct |= C1_BLANK;
    if ((c >= 0x21 and c <= 0x2F) or (c >= 0x3A and c <= 0x40) or
        (c >= 0x5B and c <= 0x60) or (c >= 0x7B and c <= 0x7E)) ct |= C1_PUNCT;
    return ct;
}

/// Retrieves character-type information for the characters in the specified Unicode source string.
/// Implementation status: Partially implemented
pub fn GetStringTypeW(dwInfoType: u32, lpSrcStr: usize, cchSrc: i32, lpCharType: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetStringTypeW(type={d}, src={x}, len={d})\n", .{ dwInfoType, lpSrcStr, cchSrc });

    if (lpCharType == 0 or lpSrcStr == 0) return 0;
    const len: usize = if (cchSrc < 0) trace.c_span_w(lpSrcStr).len else @intCast(cchSrc);
    if (len == 0) return 0;

    // lpSrcStr/lpCharType are guest VAs (usize params — not auto-translated).
    const src = @as([*]const u16, @ptrFromInt(trace.addr(lpSrcStr)));
    const out = @as([*]u16, @ptrFromInt(trace.addr(lpCharType)));

    // CT_CTYPE1 = 1, CT_CTYPE2 = 2, CT_CTYPE3 = 4
    if (dwInfoType == 1) {
        for (0..len) |i| out[i] = getCharTypeW(src[i]);
    } else {
        // Types 2/3 are less commonly needed; zero-fill for now
        for (0..len) |i| out[i] = 0;
    }
    return 1;
}

/// Retrieves character-type information for the characters in the specified ANSI source string.
/// Implementation status: Partially implemented
pub fn GetStringTypeA(dwInfoType: u32, lpSrcStr: usize, cchSrc: i32, lpCharType: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetStringTypeA(type={d}, src={x}, len={d})\n", .{ dwInfoType, lpSrcStr, cchSrc });

    if (lpCharType == 0 or lpSrcStr == 0) return 0;
    const len: usize = if (cchSrc < 0) trace.c_span(lpSrcStr).len else @intCast(cchSrc);
    if (len == 0) return 0;

    // lpSrcStr/lpCharType are guest VAs (usize params — not auto-translated).
    const src = @as([*]const u8, @ptrFromInt(trace.addr(lpSrcStr)));
    const out = @as([*]u16, @ptrFromInt(trace.addr(lpCharType)));

    if (dwInfoType == 1) {
        for (0..len) |i| out[i] = getCharTypeW(src[i]);
    } else {
        for (0..len) |i| out[i] = 0;
    }
    return 1;
}

/// --- LCMapString functions ---
/// Implementation status: Partially implemented
pub fn LCMapStringA(Locale: u32, dwMapFlags: u32, lpSrcStr: usize, cchSrc: i32, lpDestStr: usize, cchDest: i32) callconv(w32cc.WINAPI) i32 {
    _ = Locale;
    if (trace.enable_tracing) trace.print("KERNEL32: LCMapStringA(flags=0x{X})\n", .{dwMapFlags});

    if (lpSrcStr == 0) return 0;
    const src_len: usize = if (cchSrc < 0) trace.c_span(lpSrcStr).len + 1 else @intCast(cchSrc);
    if (cchDest == 0 or lpDestStr == 0) return @intCast(src_len);

    // lpSrcStr/lpDestStr are guest VAs (usize params — not auto-translated).
    const src = @as([*]const u8, @ptrFromInt(trace.addr(lpSrcStr)));
    const dst = @as([*]u8, @ptrFromInt(trace.addr(lpDestStr)));
    const copy_len = @min(src_len, @as(usize, @intCast(cchDest)));

    const LCMAP_UPPERCASE = 0x00000200;
    const LCMAP_LOWERCASE = 0x00000100;

    for (0..copy_len) |i| {
        if ((dwMapFlags & LCMAP_UPPERCASE) != 0) {
            dst[i] = std.ascii.toUpper(src[i]);
        } else if ((dwMapFlags & LCMAP_LOWERCASE) != 0) {
            dst[i] = std.ascii.toLower(src[i]);
        } else {
            dst[i] = src[i];
        }
    }
    return @intCast(copy_len);
}

/// Maps one Unicode character string to another.
/// Implementation status: Partially implemented
pub fn LCMapStringW(Locale: u32, dwMapFlags: u32, lpSrcStr: usize, cchSrc: i32, lpDestStr: usize, cchDest: i32) callconv(w32cc.WINAPI) i32 {
    _ = Locale;
    if (trace.enable_tracing) trace.print("KERNEL32: LCMapStringW(flags=0x{X})\n", .{dwMapFlags});

    if (lpSrcStr == 0) return 0;
    const src_len: usize = if (cchSrc < 0) trace.c_span_w(lpSrcStr).len + 1 else @intCast(cchSrc);
    if (cchDest == 0 or lpDestStr == 0) return @intCast(src_len);

    // lpSrcStr/lpDestStr are guest VAs (usize params — not auto-translated).
    const src = @as([*]const u16, @ptrFromInt(trace.addr(lpSrcStr)));
    const dst = @as([*]u16, @ptrFromInt(trace.addr(lpDestStr)));
    const copy_len = @min(src_len, @as(usize, @intCast(cchDest)));

    const LCMAP_UPPERCASE = 0x00000200;
    const LCMAP_LOWERCASE = 0x00000100;

    for (0..copy_len) |i| {
        const ch = src[i];
        if ((dwMapFlags & LCMAP_UPPERCASE) != 0 and ch >= 'a' and ch <= 'z') {
            dst[i] = ch - 0x20;
        } else if ((dwMapFlags & LCMAP_LOWERCASE) != 0 and ch >= 'A' and ch <= 'Z') {
            dst[i] = ch + 0x20;
        } else {
            dst[i] = ch;
        }
    }
    return @intCast(copy_len);
}

/// Compares two character strings, for a specified locale.
/// Implementation status: Partially implemented
pub fn CompareStringA(Locale: u32, dwCmpFlags: u32, lpString1: usize, cchCount1: i32, lpString2: usize, cchCount2: i32) callconv(w32cc.WINAPI) i32 {
    _ = Locale;
    const s1 = if (lpString1 != 0) trace.c_span(lpString1) else "";
    const s2 = if (lpString2 != 0) trace.c_span(lpString2) else "";
    const len1: usize = if (cchCount1 < 0) s1.len else @intCast(cchCount1);
    const len2: usize = if (cchCount2 < 0) s2.len else @intCast(cchCount2);
    const sl1 = s1[0..@min(len1, s1.len)];
    const sl2 = s2[0..@min(len2, s2.len)];
    if (trace.enable_tracing) trace.print("KERNEL32: CompareStringA('{s}', '{s}', flags={x})\n", .{ sl1, sl2, dwCmpFlags });

    const NORM_IGNORECASE = 0x00000001;
    const ignore_case = (dwCmpFlags & NORM_IGNORECASE) != 0;

    const min_len = @min(sl1.len, sl2.len);
    for (0..min_len) |i| {
        var c1 = sl1[i];
        var c2 = sl2[i];
        if (ignore_case) {
            c1 = std.ascii.toLower(c1);
            c2 = std.ascii.toLower(c2);
        }
        if (c1 < c2) return 1; // CSTR_LESS_THAN
        if (c1 > c2) return 3; // CSTR_GREATER_THAN
    }
    if (sl1.len < sl2.len) return 1;
    if (sl1.len > sl2.len) return 3;
    return 2; // CSTR_EQUAL
}

/// Compares two Unicode character strings.
/// Implementation status: Partially implemented
pub fn CompareStringW(Locale: u32, dwCmpFlags: u32, lpString1: usize, cchCount1: i32, lpString2: usize, cchCount2: i32) callconv(w32cc.WINAPI) i32 {
    _ = Locale;
    if (trace.enable_tracing) trace.print("KERNEL32: CompareStringW(flags={x})\n", .{dwCmpFlags});

    const s1 = if (lpString1 != 0) @as([*]const u16, @ptrFromInt(lpString1)) else @as([*]const u16, @ptrFromInt(lpString1));
    const s2 = if (lpString2 != 0) @as([*]const u16, @ptrFromInt(lpString2)) else @as([*]const u16, @ptrFromInt(lpString2));

    const len1: usize = if (cchCount1 < 0) trace.c_span_w(lpString1).len else @intCast(cchCount1);
    const len2: usize = if (cchCount2 < 0) trace.c_span_w(lpString2).len else @intCast(cchCount2);

    const NORM_IGNORECASE = 0x00000001;
    const ignore_case = (dwCmpFlags & NORM_IGNORECASE) != 0;

    const min_len = @min(len1, len2);
    for (0..min_len) |i| {
        var c1 = s1[i];
        var c2 = s2[i];
        if (ignore_case) {
            if (c1 >= 'A' and c1 <= 'Z') c1 += 0x20;
            if (c2 >= 'A' and c2 <= 'Z') c2 += 0x20;
        }
        if (c1 < c2) return 1; // CSTR_LESS_THAN
        if (c1 > c2) return 3; // CSTR_GREATER_THAN
    }
    if (len1 < len2) return 1;
    if (len1 > len2) return 3;
    return 2; // CSTR_EQUAL
}

/// Returns the locale identifier for the system default locale.
/// Implementation status: Partially implemented
pub fn GetSystemDefaultLCID() callconv(w32cc.WINAPI) u32 {
    return 1033; // English (US)
}

/// Returns the locale identifier for the user default locale.
/// Implementation status: Partially implemented
pub fn GetUserDefaultLCID() callconv(w32cc.WINAPI) u32 {
    return 0x0409; // English (US)
}

/// Determines whether a locale identifier is valid.
/// Implementation status: No-op fallback
pub fn stub_IsValidLocale(Locale: u32, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = Locale;
    _ = dwFlags;
    return 1;
}

/// Enumerates the locales that are either installed on or supported by an operating system.
/// Implementation status: Partially implemented
pub fn EnumSystemLocalesA(lpLocaleEnumProc: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwFlags;
    if (lpLocaleEnumProc != 0) {
        // Call callback with "00000409" (English US)
        var buf: [9]u8 = .{ '0', '0', '0', '0', '0', '4', '0', '9', 0 };
        callGuestCallback1(lpLocaleEnumProc, @intFromPtr(&buf));
    }
    return 1;
}

/// Enumerates the Unicode locales that are either installed on or supported by an operating system.
/// Implementation status: Partially implemented
pub fn EnumSystemLocalesW(lpLocaleEnumProc: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwFlags;
    if (lpLocaleEnumProc != 0) {
        // Call callback with L"00000409" (English US)
        var buf: [9]u16 = .{ '0', '0', '0', '0', '0', '4', '0', '9', 0 };
        callGuestCallback1(lpLocaleEnumProc, @intFromPtr(&buf));
    }
    return 1;
}

/// Invoke a 32-bit guest callback: direct on native x86, via the compat
/// dispatcher on native x86_64 (a direct 64-bit call misdecodes the 32-bit
/// machine code), and via the interpreter on WASM.
fn callGuestCallback1(cb_addr: usize, arg0: usize) void {
    const platform = @import("../../platform.zig");
    if (comptime platform.is_x86) {
        const cb = @as(*const fn (usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(cb_addr));
        _ = cb(arg0);
    } else if (comptime platform.is_x86_64) {
        const compat = @import("../../x86/compat_thunks.zig");
        _ = compat.callCompat32_4(@truncate(cb_addr), @truncate(arg0), 0, 0, 0);
    } else {
        // WASM: run the callback via the interpreter (guest fn ptr is not a
        // valid WASM indirect-call index).
        const x86_cpu = @import("../../x86/cpu.zig");
        const x86_execute = @import("../../x86/execute.zig");
        var cpu = x86_cpu.Cpu{};
        if (x86_memory.guest_memory) |gm| cpu.memory = gm.*;
        var stack: [256]u8 = undefined;
        cpu.esp = @truncate(@intFromPtr(&stack) + stack.len - 16);
        cpu.push32(@intCast(arg0));
        cpu.push32(0);
        cpu.eip = @intCast(cb_addr);
        x86_execute.run(&cpu);
    }
}

/// Maps one character string to another, performing a specified locale-dependent transformation using a locale name.
/// Implementation status: Partially implemented
pub fn LCMapStringEx(lpLocaleName: usize, dwMapFlags: u32, lpSrcStr: usize, cchSrc: i32, lpDestStr: usize, cchDest: i32, lpVersionInformation: usize, lpReserved: usize, sortHandle: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: LCMapStringEx(flags=0x{X}, localeName={X}, ver={X}, reserved={X}, sort={X})\n", .{ dwMapFlags, lpLocaleName, lpVersionInformation, lpReserved, sortHandle });

    if (lpSrcStr == 0) return 0;

    const src_len: usize = if (cchSrc < 0) trace.c_span_w(lpSrcStr).len + 1 else @intCast(cchSrc);

    // If output buffer is 0, return required size
    if (cchDest == 0 or lpDestStr == 0) return @intCast(src_len);

    // Simple identity copy (sufficient for MSVC CRT usage)
    const src = @as([*]const u16, @ptrFromInt(lpSrcStr));
    const dst = @as([*]u16, @ptrFromInt(lpDestStr));
    const copy_len = @min(src_len, @as(usize, @intCast(cchDest)));
    for (0..copy_len) |i| dst[i] = src[i];
    return @intCast(copy_len);
}

/// Retrieves information about a locale specified by identifier.
/// Implementation status: Partially implemented
pub fn GetLocaleInfoA(Locale: u32, LCType: u32, lpLCData: usize, cchData: i32) callconv(w32cc.WINAPI) i32 {
    _ = Locale;
    if (trace.enable_tracing) trace.print("KERNEL32: GetLocaleInfoA(LCType={x})\n", .{LCType});

    // Return en-US locale data for common LCType values
    const val = switch (LCType & 0xFFFF) { // mask off flags
        0x0001 => "0409", // LOCALE_ILANGUAGE
        0x0002 => "English (United States)", // LOCALE_SLANGUAGE
        0x0003 => "ENU", // LOCALE_SABBREVLANGNAME
        0x000B => "1252", // LOCALE_IDEFAULTANSICODEPAGE
        0x000C => "437", // LOCALE_IDEFAULTCODEPAGE (OEM)
        0x000D => "-", // LOCALE_SNEGATIVESIGN
        0x000E => "dddd, MMMM dd, yyyy", // LOCALE_SLONGDATE
        0x000F => "USD", // LOCALE_SINTLSYMBOL
        0x0014 => "Monday", // LOCALE_SDAYNAME1
        0x0015 => "Tuesday", // LOCALE_SDAYNAME2
        0x0016 => "Wednesday", // LOCALE_SDAYNAME3
        0x0017 => "Thursday", // LOCALE_SDAYNAME4
        0x0018 => "Friday", // LOCALE_SDAYNAME5
        0x0019 => "Saturday", // LOCALE_SDAYNAME6
        0x001A => "Sunday", // LOCALE_SDAYNAME7
        0x001B => "1", // LOCALE_IFIRSTDAYOFWEEK (0=Mon)
        0x001C => "M/d/yyyy", // LOCALE_SSHORTDATE
        0x001D => ".", // LOCALE_SDECIMAL
        0x001E => ",", // LOCALE_STHOUSAND
        0x001F => "3;0", // LOCALE_SGROUPING
        0x0020 => "2", // LOCALE_IDIGITS
        0x0025 => "/", // LOCALE_SDATE
        0x0026 => ":", // LOCALE_STIME
        0x0027 => "h:mm:ss tt", // LOCALE_STIMEFORMAT
        0x0028 => "M/d/yyyy", // LOCALE_SSHORTDATE (alt)
        0x0029 => "AM", // LOCALE_S1159
        0x002A => "PM", // LOCALE_S2359
        0x002D => "Mon", // LOCALE_SABBREVDAYNAME1
        0x002E => "Tue", // LOCALE_SABBREVDAYNAME2
        0x002F => "Wed", // LOCALE_SABBREVDAYNAME3
        0x0030 => "Thu", // LOCALE_SABBREVDAYNAME4
        0x0031 => "Fri", // LOCALE_SABBREVDAYNAME5
        0x0032 => "Sat", // LOCALE_SABBREVDAYNAME6
        0x0033 => "Sun", // LOCALE_SABBREVDAYNAME7
        0x0034 => "January", // LOCALE_SMONTHNAME1 (alt position used by some apps)
        0x0035 => "February",
        0x0036 => "March",
        0x0038 => "Jan", // LOCALE_SABBREVMONTHNAME1
        0x0039 => "Feb",
        0x003A => "Mar",
        0x003B => "Apr",
        0x003C => "May",
        0x003D => "Jun",
        0x003E => "Jul",
        0x003F => "Aug",
        0x0040 => "Sep",
        0x0041 => "Oct",
        0x0042 => "Nov",
        0x0043 => "Dec",
        0x0044 => "January", // LOCALE_SMONTHNAME1
        0x0045 => "February",
        0x0046 => "March",
        0x0047 => "April",
        0x0048 => "May",
        0x0049 => "June",
        0x004A => "July",
        0x004B => "August",
        0x004C => "September",
        0x004D => "October",
        0x004E => "November",
        0x004F => "December",
        0x0050 => "$", // LOCALE_SCURRENCY
        0x1003 => "ENU", // LOCALE_SABBREVLANGNAME
        0x1004 => "English", // LOCALE_SNATIVELANGNAME
        else => "", // return empty for unknown — avoids poisoning with wrong data
    };

    if (val.len == 0) return 0; // unknown LCType

    if (cchData == 0) {
        return @intCast(val.len + 1);
    }

    if (lpLCData != 0) {
        const out = @as([*]u8, @ptrFromInt(lpLCData));
        const copy_len = @min(val.len, @as(usize, @intCast(cchData)) - 1);
        @memcpy(out[0..copy_len], val[0..copy_len]);
        out[copy_len] = 0;
        return @intCast(copy_len + 1);
    }
    return 0;
}

/// Retrieves Unicode information about a locale specified by identifier.
/// Implementation status: Partially implemented
pub fn GetLocaleInfoW(Locale: u32, LCType: u32, lpLCData: usize, cchData: i32) callconv(w32cc.WINAPI) i32 {
    _ = Locale;
    if (trace.enable_tracing) trace.print("KERNEL32: GetLocaleInfoW(LCType={x})\n", .{LCType});
    const default_val = "1252";
    if (cchData == 0) return @intCast(default_val.len + 1);
    if (lpLCData != 0) {
        const out = @as([*]u16, @ptrFromInt(lpLCData));
        const copy_len = @min(default_val.len, @as(usize, @intCast(cchData)) - 1);
        for (0..copy_len) |i| out[i] = default_val[i];
        out[copy_len] = 0;
        return @intCast(copy_len + 1);
    }
    return 0;
}

/// Retrieves the locale identifier for the current thread.
/// Implementation status: Partially implemented
pub fn GetThreadLocale() callconv(w32cc.WINAPI) u32 {
    return 1033; // en-US
}

const kernel32_time = @import("time.zig");
const w32 = @import("../constants.zig");

const full_day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const full_month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

/// SYSTEMTIME the caller asked to format; null lpDate means "now" on the UTC
/// guest clock (same policy as GetLocalTime).
fn formatInputSystemTime(lpSystemTime: usize) w32.SYSTEMTIME {
    if (lpSystemTime != 0) {
        const st = @as(*const w32.SYSTEMTIME, @ptrFromInt(lpSystemTime));
        return st.*;
    }
    var now = w32.SYSTEMTIME{};
    kernel32_time.GetLocalTime(@intFromPtr(&now));
    return now;
}

/// Month/day indices folded into range so guest garbage cannot index out of
/// bounds. Windows validates and fails; zine folds like mktime/asctime do.
fn monthIndex(st: *const w32.SYSTEMTIME) usize {
    return @intCast(@mod(@as(i64, st.wMonth) - 1, 12));
}
fn dayOfWeekIndex(st: *const w32.SYSTEMTIME) usize {
    return @intCast(@mod(@as(i64, st.wDayOfWeek), 7));
}

/// Copy `formatted` into the guest NUL-terminated output buffer with Win32
/// buffer semantics: cch==0 queries the size, a too-small buffer fails with 0,
/// success returns chars written including the NUL.
fn writeFormattedOut(out_ptr: usize, cch: i32, formatted: []const u8) i32 {
    if (cch == 0) return @intCast(formatted.len + 1);
    if (out_ptr == 0 or cch <= 0 or @as(usize, @intCast(cch)) <= formatted.len) return 0;
    const buf = @as([*]u8, @ptrFromInt(out_ptr));
    @memcpy(buf[0..formatted.len], formatted);
    buf[formatted.len] = 0;
    return @intCast(formatted.len + 1);
}

/// Formats a date as a date string for the fixed en-US locale
/// (short "M/d/yyyy", long "dddd, MMMM dd, yyyy"). A custom lpFormat picture
/// string is not interpreted and falls back to the default short format.
/// Implementation status: Partially implemented
pub fn stub_GetDateFormatA(Locale: u32, dwFlags: u32, lpDate: usize, lpFormat: usize, lpDateStr: usize, cchDate: i32) callconv(w32cc.WINAPI) i32 {
    _ = Locale;
    if (trace.enable_tracing) trace.print("KERNEL32: GetDateFormatA(flags={x})\n", .{dwFlags});
    const st = formatInputSystemTime(lpDate);

    var buf: [64]u8 = undefined;
    // DATE_LONGDATE 0x2, DATE_YEARMONTH 0x8; anything else is the default
    // short date (DATE_SHORTDATE).
    const formatted = if (dwFlags & 0x2 != 0) blk: {
        break :blk std.fmt.bufPrint(&buf, "{s}, {s} {d}, {d:0>4}", .{
            full_day_names[dayOfWeekIndex(&st)],
            full_month_names[monthIndex(&st)],
            st.wDay,
            st.wYear,
        }) catch return 0;
    } else if (dwFlags & 0x8 != 0) blk: {
        break :blk std.fmt.bufPrint(&buf, "{s} {d:0>4}", .{
            full_month_names[monthIndex(&st)],
            st.wYear,
        }) catch return 0;
    } else blk: {
        _ = lpFormat;
        break :blk std.fmt.bufPrint(&buf, "{d}/{d}/{d:0>4}", .{ st.wMonth, st.wDay, st.wYear }) catch return 0;
    };
    return writeFormattedOut(lpDateStr, cchDate, formatted);
}

/// Formats time as a time string for the fixed en-US locale ("h:mm:ss tt").
/// Honors TIME_NOMINUTESORSECONDS, TIME_NOSECONDS, TIME_NOTIMEMARKER and
/// TIME_FORCE24HOURFORMAT; a custom lpFormat picture string falls back to the
/// default format.
/// Implementation status: Partially implemented
pub fn stub_GetTimeFormatA(Locale: u32, dwFlags: u32, lpTime: usize, lpFormat: usize, lpTimeStr: usize, cchTime: i32) callconv(w32cc.WINAPI) i32 {
    _ = Locale;
    if (trace.enable_tracing) trace.print("KERNEL32: GetTimeFormatA(flags={x})\n", .{dwFlags});
    _ = lpFormat;
    const st = formatInputSystemTime(lpTime);

    // TIME_FORCE24HOURFORMAT 0x8 implies no AM/PM marker on real Windows.
    const force24 = dwFlags & 0x8 != 0;
    const show_marker = !force24 and dwFlags & 0x4 == 0; // TIME_NOTIMEMARKER 0x4

    var buf: [64]u8 = undefined;
    var formatted: []const u8 = "";
    if (dwFlags & 0x1 != 0) { // TIME_NOMINUTESORSECONDS
        formatted = if (force24)
            std.fmt.bufPrint(&buf, "{d:0>2}", .{st.wHour}) catch return 0
        else
            std.fmt.bufPrint(&buf, "{d}{s}", .{ hour12(st.wHour), ampmSuffix(&st, show_marker) }) catch return 0;
    } else if (dwFlags & 0x2 != 0) { // TIME_NOSECONDS
        formatted = if (force24)
            std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ st.wHour, st.wMinute }) catch return 0
        else
            std.fmt.bufPrint(&buf, "{d}:{d:0>2}{s}", .{ hour12(st.wHour), st.wMinute, ampmSuffix(&st, show_marker) }) catch return 0;
    } else if (force24) {
        formatted = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ st.wHour, st.wMinute, st.wSecond }) catch return 0;
    } else {
        formatted = std.fmt.bufPrint(&buf, "{d}:{d:0>2}:{d:0>2}{s}", .{
            hour12(st.wHour), st.wMinute, st.wSecond, ampmSuffix(&st, show_marker),
        }) catch return 0;
    }
    return writeFormattedOut(lpTimeStr, cchTime, formatted);
}

fn hour12(wHour: u16) u16 {
    const h = wHour % 12;
    return if (h == 0) 12 else h;
}

fn ampmSuffix(st: *const w32.SYSTEMTIME, show: bool) []const u8 {
    if (!show) return "";
    return if (st.wHour < 12) " AM" else " PM";
}

/// --- String functions (lstr*) ---
/// Copies a specified number of characters from a source string into a buffer.
/// Implementation status: Partially implemented
pub fn lstrcpynA(lpString1: usize, lpString2: usize, iMaxLength: i32) callconv(w32cc.WINAPI) usize {
    if (lpString1 == 0 or lpString2 == 0 or iMaxLength <= 0) return lpString1;
    const src = trace.c_span(lpString2);
    const dst = @as([*]u8, @ptrFromInt(lpString1));
    const max_len: usize = @intCast(iMaxLength);
    const copy_len = @min(src.len, max_len - 1);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    dst[copy_len] = 0;
    return lpString1;
}

/// Compares two character strings.
/// Implementation status: Partially implemented
pub fn lstrcmpA(lpString1: usize, lpString2: usize) callconv(w32cc.WINAPI) i32 {
    const s1 = if (lpString1 != 0) trace.c_span(lpString1) else "";
    const s2 = if (lpString2 != 0) trace.c_span(lpString2) else "";
    const order = std.mem.order(u8, s1, s2);
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// Copies a string to a buffer.
/// Implementation status: Partially implemented
pub fn lstrcpyA(lpString1: usize, lpString2: usize) callconv(w32cc.WINAPI) usize {
    if (lpString1 == 0 or lpString2 == 0) return lpString1;
    const src = trace.c_span(lpString2);
    const dst = @as([*]u8, @ptrFromInt(lpString1));
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    return lpString1;
}

/// Returns the length of the specified string (not including the terminating null character).
/// Implementation status: Partially implemented
pub fn lstrlenA(lpString: usize) callconv(w32cc.WINAPI) i32 {
    if (lpString == 0) return 0;
    const s = trace.c_span(lpString);
    return @intCast(s.len);
}

/// Appends one string to another.
/// Implementation status: Partially implemented
pub fn lstrcatA(lpString1: usize, lpString2: usize) callconv(w32cc.WINAPI) usize {
    if (lpString1 == 0) return 0;
    if (lpString2 == 0) return lpString1;
    const dst = @as([*]u8, @ptrFromInt(lpString1));
    const src = trace.c_span(lpString2);
    var len: usize = 0;
    while (dst[len] != 0) : (len += 1) {}
    @memcpy(dst[len .. len + src.len], src);
    dst[len + src.len] = 0;
    return lpString1;
}

/// Compares two character strings. The comparison is not case-sensitive.
/// Implementation status: Partially implemented
pub fn lstrcmpiA(lpString1: usize, lpString2: usize) callconv(w32cc.WINAPI) i32 {
    if (lpString1 == 0 or lpString2 == 0) return 0;
    const s1 = trace.c_span(lpString1);
    const s2 = trace.c_span(lpString2);
    const len = @min(s1.len, s2.len);
    for (0..len) |i| {
        const c1 = std.ascii.toLower(s1[i]);
        const c2 = std.ascii.toLower(s2[i]);
        if (c1 < c2) return -1;
        if (c1 > c2) return 1;
    }
    if (s1.len < s2.len) return -1;
    if (s1.len > s2.len) return 1;
    return 0;
}

/// Returns the language identifier of the user default locale.
/// Implementation status: Partially implemented
pub fn GetUserDefaultLangID() callconv(w32cc.WINAPI) u16 {
    return 0x0409; // English (US)
}

// --- Wide string (W) lstr* functions ---

fn wlen(ptr: [*]const u16) usize {
    var i: usize = 0;
    while (ptr[i] != 0) : (i += 1) {}
    return i;
}

/// Returns the length of the specified Unicode string.
/// Implementation status: Partially implemented
pub fn lstrlenW(lpString: usize) callconv(w32cc.WINAPI) i32 {
    if (lpString == 0) return 0;
    return @intCast(wlen(@ptrFromInt(lpString)));
}

/// Copies a Unicode string to a buffer.
/// Implementation status: Partially implemented
pub fn lstrcpyW(lpString1: usize, lpString2: usize) callconv(w32cc.WINAPI) usize {
    if (lpString1 == 0) return 0;
    if (lpString2 == 0) return lpString1;
    const dst = @as([*]u16, @ptrFromInt(lpString1));
    const src = @as([*]const u16, @ptrFromInt(lpString2));
    const len = wlen(src);
    for (0..len) |i| dst[i] = src[i];
    dst[len] = 0;
    return lpString1;
}

/// Copies a specified number of characters from a source Unicode string into a buffer.
/// Implementation status: Partially implemented
pub fn lstrcpynW(lpString1: usize, lpString2: usize, iMaxLength: i32) callconv(w32cc.WINAPI) usize {
    if (lpString1 == 0 or iMaxLength <= 0) return lpString1;
    const dst = @as([*]u16, @ptrFromInt(lpString1));
    if (lpString2 == 0) {
        dst[0] = 0;
        return lpString1;
    }
    const src = @as([*]const u16, @ptrFromInt(lpString2));
    const max: usize = @intCast(iMaxLength);
    const src_len = wlen(src);
    const copy_len = @min(src_len, max - 1);
    for (0..copy_len) |i| dst[i] = src[i];
    dst[copy_len] = 0;
    return lpString1;
}

/// Appends one Unicode string to another.
/// Implementation status: Partially implemented
pub fn lstrcatW(lpString1: usize, lpString2: usize) callconv(w32cc.WINAPI) usize {
    if (lpString1 == 0) return 0;
    if (lpString2 == 0) return lpString1;
    const dst = @as([*]u16, @ptrFromInt(lpString1));
    const src = @as([*]const u16, @ptrFromInt(lpString2));
    const dst_len = wlen(dst);
    const src_len = wlen(src);
    for (0..src_len) |i| dst[dst_len + i] = src[i];
    dst[dst_len + src_len] = 0;
    return lpString1;
}

/// Compares two Unicode character strings.
/// Implementation status: Partially implemented
pub fn lstrcmpW(lpString1: usize, lpString2: usize) callconv(w32cc.WINAPI) i32 {
    if (lpString1 == 0 or lpString2 == 0) return 0;
    const s1 = @as([*]const u16, @ptrFromInt(lpString1));
    const s2 = @as([*]const u16, @ptrFromInt(lpString2));
    var i: usize = 0;
    while (s1[i] != 0 and s2[i] != 0) : (i += 1) {
        if (s1[i] < s2[i]) return -1;
        if (s1[i] > s2[i]) return 1;
    }
    if (s1[i] == 0 and s2[i] != 0) return -1;
    if (s1[i] != 0 and s2[i] == 0) return 1;
    return 0;
}

/// Compares two Unicode character strings. The comparison is not case-sensitive.
/// Implementation status: Partially implemented
pub fn lstrcmpiW(lpString1: usize, lpString2: usize) callconv(w32cc.WINAPI) i32 {
    if (lpString1 == 0 or lpString2 == 0) return 0;
    const s1 = @as([*]const u16, @ptrFromInt(lpString1));
    const s2 = @as([*]const u16, @ptrFromInt(lpString2));
    var i: usize = 0;
    while (s1[i] != 0 and s2[i] != 0) : (i += 1) {
        const c1: u16 = if (s1[i] < 128) std.ascii.toLower(@intCast(s1[i])) else s1[i];
        const c2: u16 = if (s2[i] < 128) std.ascii.toLower(@intCast(s2[i])) else s2[i];
        if (c1 < c2) return -1;
        if (c1 > c2) return 1;
    }
    if (s1[i] == 0 and s2[i] != 0) return -1;
    if (s1[i] != 0 and s2[i] == 0) return 1;
    return 0;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn formatDate(st: *const w32.SYSTEMTIME, flags: u32, buf: []u8) []const u8 {
    const n = stub_GetDateFormatA(0, flags, @intFromPtr(st), 0, @intFromPtr(buf.ptr), @intCast(buf.len));
    return std.mem.sliceTo(buf[0..@intCast(n - 1)], 0);
}

fn formatTime(st: *const w32.SYSTEMTIME, flags: u32, buf: []u8) []const u8 {
    const n = stub_GetTimeFormatA(0, flags, @intFromPtr(st), 0, @intFromPtr(buf.ptr), @intCast(buf.len));
    return std.mem.sliceTo(buf[0..@intCast(n - 1)], 0);
}

test "lstrcmpiW preserves non-ASCII UTF-16 code units" {
    const pairs = .{
        .{ [_:0]u16{0x0101}, [_:0]u16{0x0201} },
        .{ [_:0]u16{0x0161}, [_:0]u16{'a'} },
        .{ [_:0]u16{ 0xD83D, 0xDE00 }, [_:0]u16{ 0xD83D, 0xDF00 } },
    };
    inline for (pairs) |pair| {
        var first_text = pair[0];
        var second_text = pair[1];
        const first = @intFromPtr(&first_text);
        const second = @intFromPtr(&second_text);
        try testing.expect(lstrcmpiW(first, second) != 0);
        try testing.expectEqual(-lstrcmpiW(first, second), lstrcmpiW(second, first));
        try testing.expectEqual(@as(i32, 0), lstrcmpiW(first, first));
    }

    const upper = [_:0]u16{ 'A', 0x0101, 'Z' };
    const lower = [_:0]u16{ 'a', 0x0101, 'z' };
    try testing.expectEqual(@as(i32, 0), lstrcmpiW(@intFromPtr(&upper), @intFromPtr(&lower)));
    try testing.expect(lstrcmpiW(@intFromPtr(&[_:0]u16{}), @intFromPtr(&lower)) < 0);
}

test "GetDateFormatA honors the caller's SYSTEMTIME" {
    // Leap day pins the calendar arithmetic; wDayOfWeek 4 = Thursday.
    const st: w32.SYSTEMTIME = .{ .wYear = 2024, .wMonth = 2, .wDayOfWeek = 4, .wDay = 29 };

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("2/29/2024", formatDate(&st, 0, &buf)); // DATE_SHORTDATE
    try testing.expectEqualStrings("Thursday, February 29, 2024", formatDate(&st, 0x2, &buf)); // DATE_LONGDATE
    try testing.expectEqualStrings("February 2024", formatDate(&st, 0x8, &buf)); // DATE_YEARMONTH
}

test "GetDateFormatA buffer semantics follow Win32" {
    const st: w32.SYSTEMTIME = .{ .wYear = 2024, .wMonth = 2, .wDay = 29 };
    var buf: [64]u8 = undefined;

    // cchDate == 0 queries the required size including the NUL.
    try testing.expectEqual(@as(i32, "2/29/2024".len + 1), stub_GetDateFormatA(0, 0, @intFromPtr(&st), 0, 0, 0));

    // A buffer that cannot hold text + NUL fails without touching it.
    try testing.expectEqual(@as(i32, 0), stub_GetDateFormatA(0, 0, @intFromPtr(&st), 0, @intFromPtr(&buf), "2/29/2024".len));

    // Exactly text + NUL succeeds.
    try testing.expectEqual(@as(i32, "2/29/2024".len + 1), stub_GetDateFormatA(0, 0, @intFromPtr(&st), 0, @intFromPtr(&buf), "2/29/2024".len + 1));
    try testing.expectEqualStrings("2/29/2024", std.mem.sliceTo(&buf, 0));

    // Out-of-range month folds into range instead of indexing out of bounds.
    const weird: w32.SYSTEMTIME = .{ .wYear = 2024, .wMonth = 25, .wDay = 1 };
    _ = formatDate(&weird, 0x2, &buf);
}

test "GetTimeFormatA formats en-US 12-hour clock with AM/PM" {
    var buf: [64]u8 = undefined;

    const afternoon: w32.SYSTEMTIME = .{ .wHour = 13, .wMinute = 5, .wSecond = 9 };
    try testing.expectEqualStrings("1:05:09 PM", formatTime(&afternoon, 0, &buf));

    // Midnight is hour 12 AM, noon is hour 12 PM on a 12-hour clock.
    const midnight: w32.SYSTEMTIME = .{ .wHour = 0, .wMinute = 15 };
    try testing.expectEqualStrings("12:15:00 AM", formatTime(&midnight, 0, &buf));
    const noon: w32.SYSTEMTIME = .{ .wHour = 12 };
    try testing.expectEqualStrings("12:00:00 PM", formatTime(&noon, 0, &buf));

    // TIME_NOSECONDS 0x2 / TIME_NOMINUTESORSECONDS 0x1 / TIME_FORCE24HOURFORMAT 0x8
    try testing.expectEqualStrings("1:05 PM", formatTime(&afternoon, 0x2, &buf));
    try testing.expectEqualStrings("1 PM", formatTime(&afternoon, 0x1, &buf));
    try testing.expectEqualStrings("13:05:09", formatTime(&afternoon, 0x8, &buf));
}
