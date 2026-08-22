//! IMAGEHLP.dll registration.

const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32cc = @import("calling_convention.zig");

/// Registers IMAGEHLP.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const imagehlp = "IMAGEHLP.dll";
    try environment.addBuiltinExportComptime(imagehlp, "UnDecorateSymbolName", stub_UnDecorateSymbolName);
}

fn stub_UnDecorateSymbolName(lpName_ptr: usize, lpOutput_ptr: usize, nSize: u32, Flags: u32) callconv(w32cc.WINAPI) u32 {
    _ = Flags;
    if (lpOutput_ptr == 0 or nSize == 0) return 0;
    var name: []const u8 = "";
    if (lpName_ptr != 0) {
        name = trace.c_span(lpName_ptr);
    }

    if (name.len == 0) {
        // Fall back to the last argv entry (UNDNAME calls with lpName on the
        // stack, but some callers pass null and expect argv[argc-1]).
        const msvcrt = @import("msvcrt.zig");
        if (msvcrt.global_argc > 1) {
            if (msvcrt.global_argv[@as(usize, @intCast(msvcrt.global_argc - 1))]) |last_arg| {
                // global_argv entries are HOST pointers — read without translation.
                name = trace.host_c_span(@intFromPtr(last_arg));
            }
        }
    }

    if (trace.enable_tracing) trace.print("IMAGEHLP: UnDecorateSymbolName('{s}', size={d})\n", .{ name, nSize });

    // Decode the decorated name; unrecognized names pass through verbatim.
    var out_buf: [1024]u8 = undefined;
    const result = demangleMsName(name, &out_buf);

    // lpOutput_ptr is a guest VA (usize param — not auto-translated).
    const out = @as([*]u8, @ptrFromInt(trace.addr(lpOutput_ptr)));
    const copy_len = @min(result.len, @as(usize, @intCast(nSize)) - 1);
    @memcpy(out[0..copy_len], result[0..copy_len]);
    out[copy_len] = 0;
    return @intCast(copy_len);
}

/// Appends the C spelling of one MSVC type code to `out` at `*wp`.
/// Returns false if the code is unrecognized or the buffer would overflow.
fn appendMsType(code: u8, out: []u8, wp: *usize) bool {
    const text: []const u8 = switch (code) {
        'X' => "void",
        'D' => "char",
        'C' => "signed char",
        'E' => "unsigned char",
        'F' => "short",
        'G' => "unsigned short",
        'H' => "int",
        'I' => "unsigned int",
        'J' => "long",
        'K' => "unsigned long",
        'M' => "float",
        'N' => "double",
        'O' => "long double",
        'A' => "int",
        else => return false,
    };
    if (wp.* + text.len >= out.len) return false;
    @memcpy(out[wp.*..][0..text.len], text);
    wp.* += text.len;
    return true;
}

/// Minimal MSVC name demangler for the common "?name@@..." form emitted by
/// MSVC 6-era tools. Handles the function signature alphabet (calling
/// convention + return type + parameter list terminated by "@Z"). Anything
/// unrecognized is returned verbatim so callers still get the decorated text.
fn demangleMsName(name: []const u8, out: *[1024]u8) []const u8 {
    if (name.len < 4 or name[0] != '?') return name;
    const sep = std.mem.indexOfPos(u8, name, 1, "@@") orelse return name;
    const qualified = name[1..sep];
    const sig = name[sep + 2 ..];
    if (sig.len < 2) return name;

    const cc: []const u8 = switch (sig[0]) {
        'Y' => "__cdecl",
        'G' => "__stdcall",
        'Q' => "__pascal",
        'S' => "__thiscall",
        'J' => "__fastcall",
        else => return name,
    };

    // Leaf component of a qualified name (last '@'-separated piece).
    const leaf = if (std.mem.lastIndexOfScalar(u8, qualified, '@')) |at| qualified[at + 1 ..] else qualified;

    // Collect the parameter list (with commas) into a scratch area.
    var params_buf: [512]u8 = undefined;
    var pp: usize = 0;
    var pos: usize = 1; // skip calling convention
    const ret_code = sig[pos];
    pos += 1;
    var any_param = false;
    while (pos < sig.len) : (pos += 1) {
        if (sig[pos] == '@' and pos + 1 < sig.len and sig[pos + 1] == 'Z') {
            pos += 1; // consume the '@Z' terminator
            break;
        }
        if (sig[pos] == 'X') {
            // Explicit void parameter — render as "void" and stop.
            if (pp + 4 >= params_buf.len) return name;
            @memcpy(params_buf[pp..][0..4], "void");
            pp += 4;
            any_param = true;
            break;
        }
        if (any_param) {
            if (pp + 2 >= params_buf.len) return name;
            @memcpy(params_buf[pp..][0..2], ", ");
            pp += 2;
        }
        if (!appendMsType(sig[pos], &params_buf, &pp)) return name;
        any_param = true;
    }

    // Compose: "<ret> <cc> <leaf>(<params>)"
    var wp: usize = 0;
    if (!appendMsType(ret_code, out, &wp)) return name;
    if (wp + cc.len + leaf.len + 4 >= out.len) return name;
    out[wp] = ' ';
    wp += 1;
    @memcpy(out[wp..][0..cc.len], cc);
    wp += cc.len;
    out[wp] = ' ';
    wp += 1;
    @memcpy(out[wp..][0..leaf.len], leaf);
    wp += leaf.len;
    out[wp] = '(';
    wp += 1;
    if (any_param) {
        @memcpy(out[wp..][0..pp], params_buf[0..pp]);
        wp += pp;
    } else {
        @memcpy(out[wp..][0..4], "void");
        wp += 4;
    }
    out[wp] = ')';
    wp += 1;
    return out[0..wp];
}
