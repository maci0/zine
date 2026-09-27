//! RCDLL.dll stub registration.
//!
//! Provides stubs for the two exports that RC.EXE imports from RCDLL.DLL.
//! `RC` is a minimal but real resource compiler: it parses the .rc command
//! line, reads the input .rc, handles STRINGTABLE blocks, and emits a .res
//! file. Enough for the test suite; more resource types can be added.

const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32cc = @import("calling_convention.zig");

// Preprocessor #define map (name -> numeric value) collected from the .rc.
var define_names: [32][32]u8 = undefined;
var define_vals: [32]u32 = undefined;
var define_count: usize = 0;

const MenuCtx = struct {
    buf: []u8,
    pos: *usize,
    text: []const u8,

    fn emit(ctx: *const MenuCtx, name: []const u8, id: u16, flags: u16) bool {
        if (ctx.pos.* + 4 >= ctx.buf.len) return false;
        std.mem.writeInt(u16, ctx.buf[ctx.pos.*..][0..2], flags, .little);
        ctx.pos.* += 2;
        if ((flags & 0x0010) == 0) { // non-popup has an id
            std.mem.writeInt(u16, ctx.buf[ctx.pos.*..][0..2], id, .little);
            ctx.pos.* += 2;
        }
        for (name) |ch| {
            if (ctx.pos.* + 2 >= ctx.buf.len) return false;
            std.mem.writeInt(u16, ctx.buf[ctx.pos.*..][0..2], ch, .little);
            ctx.pos.* += 2;
        }
        if (ctx.pos.* + 2 >= ctx.buf.len) return false;
        std.mem.writeInt(u16, ctx.buf[ctx.pos.*..][0..2], 0, .little);
        ctx.pos.* += 2;
        return true;
    }
};

const DlgItem = struct {
    st: u32,
    ex: u32,
    x: i16,
    y: i16,
    cx: i16,
    cy: i16,
    id: u16,
    class_atom: u16,
    text: [64]u8,
    tlen: u8,
};

const RcMenuItem = struct { name: []const u8 = "", id: u16 = 0, flags: u16 = 0 };

/// Parses one MENUITEM clause at *pos: `MENUITEM SEPARATOR` or
/// `MENUITEM "text", id[, CHECKED|GRAYED|INACTIVE|HELP]` (flags only when
/// `with_flags`). Advances *pos past the consumed text even on failure.
/// Returns null when the text is not a well-formed MENUITEM.
fn parseRcMenuitem(rc_text: []const u8, pos: *usize, with_flags: bool) ?RcMenuItem {
    if (!startsWithIgnoreCase(rc_text[pos.*..], "MENUITEM")) return null;
    var ci = pos.* + 8;
    while (ci < rc_text.len and (std.ascii.isWhitespace(rc_text[ci]) or rc_text[ci] == ',')) ci += 1;
    var item = RcMenuItem{};
    if (startsWithIgnoreCase(rc_text[ci..], "SEPARATOR")) {
        item.flags = 0x0800;
        ci += 9;
    } else {
        item.name = parseQuotedString(rc_text, &ci);
        while (ci < rc_text.len and (std.ascii.isWhitespace(rc_text[ci]) or rc_text[ci] == ',')) ci += 1;
        var val: u32 = 0;
        var have_num = false;
        if (ci < rc_text.len and rc_text[ci] >= '0' and rc_text[ci] <= '9') {
            while (ci < rc_text.len and rc_text[ci] >= '0' and rc_text[ci] <= '9') {
                val = val * 10 + @as(u32, rc_text[ci] - '0');
                ci += 1;
            }
            have_num = true;
        } else {
            // try a #define name
            var ne2 = ci;
            while (ne2 < rc_text.len and !std.ascii.isWhitespace(rc_text[ne2]) and rc_text[ne2] != ',') ne2 += 1;
            if (defineLookup(rc_text[ci..ne2])) |v| {
                val = v;
                have_num = true;
                ci = ne2;
            }
        }
        if (!have_num) {
            pos.* = ci;
            return null;
        }
        item.id = @intCast(val & 0xFFFF);
        if (with_flags) {
            // optional flags
            var lk = ci;
            while (lk < rc_text.len and (std.ascii.isWhitespace(rc_text[lk]) or rc_text[lk] == ',')) lk += 1;
            if (lk < rc_text.len and rc_text[lk] != '\n' and rc_text[lk] != '}') {
                var fend = lk;
                while (fend < rc_text.len and !std.ascii.isWhitespace(rc_text[fend]) and rc_text[fend] != ',') fend += 1;
                const fnm = rc_text[lk..fend];
                if (std.ascii.eqlIgnoreCase(fnm, "CHECKED")) item.flags |= 0x0008;
                if (std.ascii.eqlIgnoreCase(fnm, "GRAYED") or std.ascii.eqlIgnoreCase(fnm, "INACTIVE")) item.flags |= 0x0001;
                if (std.ascii.eqlIgnoreCase(fnm, "HELP")) item.flags |= 0x4000;
            }
        }
    }
    pos.* = ci;
    return item;
}

fn defineLookup(name: []const u8) ?u32 {
    for (0..define_count) |i| {
        const n = define_names[i];
        const len = std.mem.indexOfScalar(u8, &n, 0) orelse n.len;
        if (std.mem.eql(u8, name, n[0..len])) return define_vals[i];
    }
    return null;
}

/// RC entry point. Signature (from the real RCDLL): the last two args are
/// (argc, argv) — RC.EXE passes its full command line that way.
fn rc_main(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d };
    if (trace.enable_tracing) trace.print("RCDLL: RC(argc={d}, argv={x})\n", .{ e, f });
    const argc = e;
    const argv = f;

    // Collect the guest argv strings (guest VAs, translated by c_span).
    var arg_list: [32][]const u8 = undefined;
    var arg_count: usize = 0;
    if (argv != 0 and argc > 0) {
        const argv_host = trace.addr(argv);
        const argv_arr = @as([*]const u32, @ptrFromInt(argv_host));
        var i: usize = 0;
        while (i < argc and i < arg_list.len) : (i += 1) {
            const s = trace.c_span(argv_arr[i]);
            arg_list[i] = s;
            arg_count += 1;
        }
    }

    return compileResources(arg_list[0..arg_count]);
}

fn compileResources(arg_list: []const []const u8) i32 {
    const arg_count = arg_list.len;
    // Parse options: /fo <out> or /fo<out>, /I <dir> or /I<dir>, <input.rc>
    var output: ?[]const u8 = null;
    var input: ?[]const u8 = null;
    var i: usize = 1;
    while (i < arg_count) : (i += 1) {
        const a2 = arg_list[i];
        if (a2.len == 0) continue;
        if (a2[0] == '/' or a2[0] == '-') {
            if (a2.len >= 3 and (a2[1] == 'f' or a2[1] == 'F') and a2[2] == 'o') {
                if (a2.len > 3) {
                    output = a2[3..];
                } else if (i + 1 < arg_count) {
                    i += 1;
                    output = arg_list[i];
                }
            }
            // /I include dirs are accepted but unused by STRINGTABLE.
        } else if (input == null) {
            input = a2;
        }
    }
    if (input == null) {
        if (trace.enable_tracing) trace.print("RCDLL: RC no input file\n", .{});
        return 1;
    }

    // Read the .rc file (Win32 path → host path).
    const path_utils = @import("../path_utils.zig");
    const runtime = @import("../runtime.zig");
    var rc_host_buf: [1024]u8 = undefined;
    const rc_host_len = path_utils.toHostPath(input.?, &rc_host_buf);
    if (rc_host_len == 0) return 1;
    const rc_host_path = rc_host_buf[0..rc_host_len];
    // host_io wraps raw POSIX syscalls on Linux (std.Io's TLS machinery is
    // unsafe inside the native64 compat dispatch context) and WASI on wasm.
    const hio = @import("host_io.zig");
    const pfs = @import("msvcrt/posix_fs.zig");
    var rc_path_ntz: [1025]u8 = undefined;
    const rc_path_len = @min(rc_host_path.len, 1024);
    @memcpy(rc_path_ntz[0..rc_path_len], rc_host_path[0..rc_path_len]);
    rc_path_ntz[rc_path_len] = 0;
    const rc_fd = pfs.open(rc_path_ntz[0..rc_path_len :0], pfs.O_RDONLY, 0);
    if (rc_fd < 0) {
        if (trace.enable_tracing) trace.print("RCDLL: cannot open '{s}'\n", .{rc_host_path});
        return 1;
    }
    const rc_file = hio.fileFromFd(rc_fd);
    defer hio.closeFile(rc_file);
    var rc_data: [65536]u8 = undefined;
    const rc_len = hio.readFromFile(rc_file, &rc_data) catch |err| {
        trace.print("RCDLL: cannot read '{s}': {s}\n", .{ rc_host_path, @errorName(err) });
        return 1;
    };
    const rc_text = rc_data[0..rc_len];

    if (trace.enable_tracing) trace.print("RCDLL: input '{s}' ({d} bytes)\n", .{ rc_host_path, rc_len });

    // Minimal preprocessor: collect `#define NAME value` numeric defines so
    // dialog/control IDs can use symbolic names (as real .rc files do).
    {
        var di: usize = 0;
        while (di < rc_text.len) {
            // find lines starting with #define
            if (rc_text[di] == '#') {
                var li = di + 1;
                while (li < rc_text.len and std.ascii.isWhitespace(rc_text[li])) li += 1;
                if (startsWithIgnoreCase(rc_text[li..], "define")) {
                    li += 6;
                    while (li < rc_text.len and std.ascii.isWhitespace(rc_text[li])) li += 1;
                    const name_start = li;
                    while (li < rc_text.len and !std.ascii.isWhitespace(rc_text[li])) li += 1;
                    const name = rc_text[name_start..li];
                    while (li < rc_text.len and std.ascii.isWhitespace(rc_text[li])) li += 1;
                    var val: u32 = 0;
                    var is_hex = false;
                    if (li + 1 < rc_text.len and rc_text[li] == '0' and (rc_text[li + 1] == 'x' or rc_text[li + 1] == 'X')) {
                        is_hex = true;
                        li += 2;
                    }
                    while (li < rc_text.len) {
                        const ch = rc_text[li];
                        const dv: u32 = if (ch >= '0' and ch <= '9') @as(u32, ch - '0') else if (is_hex and ch >= 'a' and ch <= 'f') @as(u32, ch - 'a' + 10) else if (is_hex and ch >= 'A' and ch <= 'F') @as(u32, ch - 'A' + 10) else break;
                        val = val * (if (is_hex) @as(u32, 16) else @as(u32, 10)) + dv;
                        li += 1;
                    }
                    if (define_count < define_names.len and name.len > 0 and name.len < 32) {
                        @memcpy(define_names[define_count][0..name.len], name);
                        define_names[define_count][name.len] = 0;
                        define_vals[define_count] = val;
                        define_count += 1;
                    }
                }
            }
            // skip to next line
            while (di < rc_text.len and rc_text[di] != '\n') di += 1;
            if (di < rc_text.len) di += 1;
        }
    }

    // Parse STRINGTABLE blocks: STRINGTABLE { ID, "string" ... }
    // Collect (id, utf16 string) pairs.
    var ids: [64]u16 = undefined;
    var strs: [64][128]u16 = undefined;
    var str_lens: [64]u16 = undefined;
    var str_count: usize = 0;

    var idx: usize = 0;
    while (idx < rc_text.len) {
        // Skip whitespace
        while (idx < rc_text.len and std.ascii.isWhitespace(rc_text[idx])) idx += 1;
        if (idx >= rc_text.len) break;
        // Look for STRINGTABLE
        if (startsWithIgnoreCase(rc_text[idx..], "STRINGTABLE")) {
            idx += "STRINGTABLE".len;
            // Skip to the '{' or BEGIN
            while (idx < rc_text.len) {
                if (rc_text[idx] == '{') {
                    idx += 1;
                    break;
                }
                if (startsWithIgnoreCase(rc_text[idx..], "BEGIN")) {
                    idx += "BEGIN".len;
                    break;
                }
                idx += 1;
            }
            // Parse entries until '}' or END
            while (idx < rc_text.len) {
                while (idx < rc_text.len and (std.ascii.isWhitespace(rc_text[idx]) or rc_text[idx] == ',')) idx += 1;
                if (idx >= rc_text.len) break;
                if (rc_text[idx] == '}') {
                    idx += 1;
                    break;
                }
                if (startsWithIgnoreCase(rc_text[idx..], "END")) {
                    idx += "END".len;
                    break;
                }
                // Parse the numeric ID (hex 0x.. or decimal)
                var id_val: u32 = 0;
                var is_hex = false;
                if (idx + 1 < rc_text.len and rc_text[idx] == '0' and (rc_text[idx + 1] == 'x' or rc_text[idx + 1] == 'X')) {
                    is_hex = true;
                    idx += 2;
                }
                while (idx < rc_text.len) {
                    const ch = rc_text[idx];
                    const dv: u32 = if (ch >= '0' and ch <= '9') @as(u32, ch - '0') else if (is_hex and ch >= 'a' and ch <= 'f') @as(u32, ch - 'a' + 10) else if (is_hex and ch >= 'A' and ch <= 'F') @as(u32, ch - 'A' + 10) else break;
                    const mult: u32 = if (is_hex) 16 else 10;
                    id_val = id_val * mult + dv;
                    idx += 1;
                }
                // Skip whitespace/comma to the string
                while (idx < rc_text.len and (std.ascii.isWhitespace(rc_text[idx]) or rc_text[idx] == ',')) idx += 1;
                if (idx >= rc_text.len or rc_text[idx] != '"') break;
                idx += 1;
                // Parse the quoted string (basic escapes)
                var u16_buf: [128]u16 = undefined;
                var ulen: usize = 0;
                while (idx < rc_text.len and rc_text[idx] != '"' and ulen < 128) {
                    var ch = rc_text[idx];
                    idx += 1;
                    if (ch == '\\' and idx < rc_text.len) {
                        const esc = rc_text[idx];
                        idx += 1;
                        ch = switch (esc) {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            '"' => '"',
                            '\\' => '\\',
                            else => esc,
                        };
                    }
                    u16_buf[ulen] = ch;
                    ulen += 1;
                }
                if (idx < rc_text.len and rc_text[idx] == '"') idx += 1; // closing quote
                // Entries are separated by commas or newlines — the next loop
                // iteration skips whitespace/commas, so do NOT eat past the
                // line (the old code scanned to the next ','/'}' and silently
                // dropped every entry after the first in newline-separated
                // STRINGTABLE blocks).
                if (str_count < ids.len and id_val >= 1 and id_val <= 0xFFFF) {
                    ids[str_count] = @intCast(id_val);
                    @memcpy(strs[str_count][0..ulen], u16_buf[0..ulen]);
                    str_lens[str_count] = @intCast(ulen);
                    str_count += 1;
                }
            }
            while (idx < rc_text.len and rc_text[idx] != '}') idx += 1;
            if (idx < rc_text.len) idx += 1;
        } else {
            // Skip to next line
            while (idx < rc_text.len and rc_text[idx] != '\n') idx += 1;
            if (idx < rc_text.len) idx += 1;
        }
    }

    if (trace.enable_tracing) trace.print("RCDLL: parsed {d} strings\n", .{str_count});

    // Parse DIALOG templates (RT_DIALOG = 5). Each produces a binary
    // DLGTEMPLATE that dialog_parser.zig can read back at runtime.
    var dlg_ids: [8]u32 = undefined;
    var dlg_data: [8][4096]u8 = undefined;
    var dlg_sizes: [8]u32 = undefined;
    var dlg_count: usize = 0;
    // MENU resources (RT_MENU = 4).
    var menu_ids: [8]u32 = undefined;
    var menu_data: [8][2048]u8 = undefined;
    var menu_sizes: [8]u32 = undefined;
    var menu_count: usize = 0;
    // ICON resources: IDI ICON "file.ico" -> RT_ICON(3) + RT_GROUP_ICON(14).
    const IconInfo = struct {
        id: u32,
        image: [4096]u8,
        image_len: u32,
        width: u8,
        height: u8,
        planes: u16,
        bitcount: u16,
        bytes_in_res: u32,
    };
    var icon_infos: [4]IconInfo = undefined;
    var icon_count: usize = 0;
    {
        var mi: usize = 0;
        while (mi < rc_text.len) {
            while (mi < rc_text.len and std.ascii.isWhitespace(rc_text[mi])) mi += 1;
            if (mi >= rc_text.len) break;
            // numeric id or #define name followed by MENU
            var mid: u32 = 0;
            var have_mid = false;
            var is_menu = false;
            if (rc_text[mi] >= '0' and rc_text[mi] <= '9') {
                while (mi < rc_text.len and rc_text[mi] >= '0' and rc_text[mi] <= '9') {
                    mid = mid * 10 + @as(u32, rc_text[mi] - '0');
                    mi += 1;
                }
                have_mid = true;
                while (mi < rc_text.len and (std.ascii.isWhitespace(rc_text[mi]) or rc_text[mi] == ',')) mi += 1;
                if (startsWithIgnoreCase(rc_text[mi..], "MENU")) {
                    is_menu = true;
                    mi += 4;
                }
            } else {
                var ne = mi;
                while (ne < rc_text.len and !std.ascii.isWhitespace(rc_text[ne])) ne += 1;
                var after = ne;
                while (after < rc_text.len and std.ascii.isWhitespace(rc_text[after])) after += 1;
                if (startsWithIgnoreCase(rc_text[after..], "MENU")) {
                    if (defineLookup(rc_text[mi..ne])) |v| {
                        mid = v;
                        have_mid = true;
                        is_menu = true;
                        mi = after + 4;
                    }
                }
            }
            if (!is_menu or !have_mid or menu_count >= menu_ids.len) {
                while (mi < rc_text.len and rc_text[mi] != '\n') mi += 1;
                if (mi < rc_text.len) mi += 1;
                continue;
            }

            // Skip to BEGIN/{
            while (mi < rc_text.len) {
                if (rc_text[mi] == '{') {
                    mi += 1;
                    break;
                }
                if (startsWithIgnoreCase(rc_text[mi..], "BEGIN")) {
                    mi += 5;
                    break;
                }
                mi += 1;
            }

            // Emit: header(version=0, cbHeader=4) + items (flags u16, [id u16], name utf16 + NUL)
            var mb: usize = 0;
            var m_buf = &menu_data[menu_count];
            std.mem.writeInt(u16, m_buf[mb..][0..2], 0, .little);
            mb += 2;
            std.mem.writeInt(u16, m_buf[mb..][0..2], 4, .little);
            mb += 2;

            var ctx = MenuCtx{ .buf = m_buf, .pos = &mb, .text = "" };

            // Parse top-level items until END/}
            const TItem = struct { is_popup: bool, name: []const u8, id: u16, nchildren: usize, children: [16]struct { name: []const u8, id: u16, flags: u16 } };
            var tops: [16]TItem = undefined;
            var top_count: usize = 0;
            while (mi < rc_text.len) {
                while (mi < rc_text.len and (std.ascii.isWhitespace(rc_text[mi]) or rc_text[mi] == ',')) mi += 1;
                if (mi >= rc_text.len) break;
                if (rc_text[mi] == '}') {
                    mi += 1;
                    break;
                }
                if (startsWithIgnoreCase(rc_text[mi..], "END")) {
                    mi += 3;
                    break;
                }
                if (top_count >= tops.len) break;
                if (startsWithIgnoreCase(rc_text[mi..], "POPUP")) {
                    mi += 5;
                    while (mi < rc_text.len and (std.ascii.isWhitespace(rc_text[mi]) or rc_text[mi] == ',')) mi += 1;
                    const popup_name = parseQuotedString(rc_text, &mi);
                    var t = TItem{ .is_popup = true, .name = popup_name, .id = 0, .nchildren = 0, .children = undefined };
                    // children until END/}
                    while (mi < rc_text.len and t.nchildren < t.children.len) {
                        while (mi < rc_text.len and (std.ascii.isWhitespace(rc_text[mi]) or rc_text[mi] == ',')) mi += 1;
                        if (mi >= rc_text.len) break;
                        if (rc_text[mi] == '}') {
                            mi += 1;
                            break;
                        }
                        if (startsWithIgnoreCase(rc_text[mi..], "END")) {
                            mi += 3;
                            break;
                        }
                        // parse a child MENUITEM line: name/id/flags or SEPARATOR
                        if (parseRcMenuitem(rc_text, &mi, true)) |child| {
                            t.children[t.nchildren] = .{ .name = child.name, .id = child.id, .flags = child.flags };
                            t.nchildren += 1;
                        } else {
                            while (mi < rc_text.len and rc_text[mi] != '\n') mi += 1;
                            if (mi < rc_text.len) mi += 1;
                        }
                    }
                    tops[top_count] = t;
                    top_count += 1;
                } else {
                    // top-level MENUITEM
                    if (parseRcMenuitem(rc_text, &mi, false)) |item| {
                        tops[top_count] = .{ .is_popup = false, .name = item.name, .id = item.id, .nchildren = 0, .children = undefined };
                        top_count += 1;
                    } else {
                        while (mi < rc_text.len and rc_text[mi] != '\n') mi += 1;
                        if (mi < rc_text.len) mi += 1;
                    }
                }
            }

            // Emit parsed items: MF_END (0x80) on the last item of each level.
            for (tops[0..top_count], 0..) |*t, ti| {
                var tflags: u16 = if (t.is_popup) 0x0010 else 0;
                if (ti == top_count - 1) tflags |= 0x0080;
                _ = ctx.emit(t.name, t.id, tflags);
                if (t.is_popup) {
                    for (t.children[0..t.nchildren], 0..) |*ch, chi| {
                        var chflags = ch.flags;
                        if (chi == t.nchildren - 1) chflags |= 0x0080;
                        _ = ctx.emit(ch.name, ch.id, chflags);
                    }
                }
            }

            menu_ids[menu_count] = mid;
            menu_sizes[menu_count] = @intCast(mb);
            menu_count += 1;
        }
    }
    if (trace.enable_tracing) trace.print("RCDLL: parsed {d} menus\n", .{menu_count});
    {
        var idx2: usize = 0;
        while (idx2 < rc_text.len) {
            while (idx2 < rc_text.len and std.ascii.isWhitespace(rc_text[idx2])) idx2 += 1;
            if (idx2 >= rc_text.len) break;
            // A DIALOG statement starts with an ID (numeric or #define name)
            // followed by the keyword DIALOG.
            const id_start = idx2;
            var is_dlg = false;
            // parse optional numeric id or define name
            var did: u32 = 0;
            var have_id = false;
            if (rc_text[idx2] >= '0' and rc_text[idx2] <= '9') {
                while (idx2 < rc_text.len and rc_text[idx2] >= '0' and rc_text[idx2] <= '9') {
                    did = did * 10 + @as(u32, rc_text[idx2] - '0');
                    idx2 += 1;
                }
                have_id = true;
                while (idx2 < rc_text.len and (std.ascii.isWhitespace(rc_text[idx2]) or rc_text[idx2] == ',')) idx2 += 1;
                if (startsWithIgnoreCase(rc_text[idx2..], "DIALOG")) {
                    is_dlg = true;
                    idx2 += 6;
                }
            } else {
                // symbol name — only treat as dialog if followed by DIALOG
                var name_end = idx2;
                while (name_end < rc_text.len and !std.ascii.isWhitespace(rc_text[name_end])) name_end += 1;
                var after = name_end;
                while (after < rc_text.len and std.ascii.isWhitespace(rc_text[after])) after += 1;
                if (startsWithIgnoreCase(rc_text[after..], "DIALOG")) {
                    const name = rc_text[idx2..name_end];
                    if (defineLookup(name)) |v| {
                        did = v;
                        have_id = true;
                        is_dlg = true;
                        idx2 = after + 6;
                    }
                }
            }
            if (!is_dlg or !have_id or dlg_count >= dlg_ids.len) {
                // skip to next line
                while (idx2 < rc_text.len and rc_text[idx2] != '\n') idx2 += 1;
                if (idx2 < rc_text.len) idx2 += 1;
                _ = id_start;
                continue;
            }

            // Parse the DLGTEMPLATE body: exstyle?, x, y, cx, cy, then options
            // until BEGIN. We write into a byte buffer as we go.
            var ob: usize = 0;
            var dlg_buf = &dlg_data[dlg_count];
            var style: u32 = 0;
            var exstyle: u32 = 0;
            var dlg_x: i16 = 0;
            var dlg_y: i16 = 0;
            var dlg_cx: i16 = 0;
            var dlg_cy: i16 = 0;
            var caption: []const u8 = "";
            var font_pt: u16 = 0;
            var font_name: []const u8 = "";
            var have_font = false;

            // read up to 5 comma-separated ints (optional leading exstyle).
            // The header numbers are all on the same line and comma-separated;
            // stop as soon as we hit a non-comma token (STYLE/CAPTION/FONT).
            var coords: [5]i32 = .{ 0, 0, 0, 0, 0 };
            var coord_count: usize = 0;
            while (idx2 < rc_text.len and coord_count < 5) {
                while (idx2 < rc_text.len and (std.ascii.isWhitespace(rc_text[idx2]) or rc_text[idx2] == ',')) idx2 += 1;
                if (idx2 >= rc_text.len or rc_text[idx2] == '\n') break;
                if (!(rc_text[idx2] >= '0' and rc_text[idx2] <= '9') and rc_text[idx2] != '-') break;
                var neg = false;
                if (rc_text[idx2] == '-') {
                    neg = true;
                    idx2 += 1;
                }
                var val: i32 = 0;
                while (idx2 < rc_text.len and rc_text[idx2] >= '0' and rc_text[idx2] <= '9') {
                    val = val * 10 + @as(i32, rc_text[idx2] - '0');
                    idx2 += 1;
                }
                coords[coord_count] = if (neg) -val else val;
                coord_count += 1;
                // peek: if next non-ws is a comma, consume it and continue;
                // otherwise the header numbers are done.
                var look = idx2;
                while (look < rc_text.len and std.ascii.isWhitespace(rc_text[look])) look += 1;
                if (look < rc_text.len and rc_text[look] == ',') {
                    idx2 = look + 1;
                } else {
                    break;
                }
            }

            // Determine x,y,cx,cy (and optional exstyle as first coord)
            if (coord_count >= 4) {
                var cx_i: usize = 0;
                // If there were 5 coords, the first is the exstyle.
                if (coord_count == 5) {
                    exstyle = @bitCast(coords[0]);
                    cx_i = 1;
                }
                dlg_x = @intCast(coords[cx_i]);
                dlg_y = @intCast(coords[cx_i + 1]);
                dlg_cx = @intCast(coords[cx_i + 2]);
                dlg_cy = @intCast(coords[cx_i + 3]);
            }

            // Parse option keywords until BEGIN/{: STYLE, EXSTYLE, CAPTION, FONT, MENU, CLASS
            var item_count: usize = 0;
            var items: [16]DlgItem = undefined;
            while (idx2 < rc_text.len) {
                while (idx2 < rc_text.len and (std.ascii.isWhitespace(rc_text[idx2]) or rc_text[idx2] == ',')) idx2 += 1;
                if (idx2 >= rc_text.len) break;
                if (rc_text[idx2] == '{' or startsWithIgnoreCase(rc_text[idx2..], "BEGIN")) {
                    if (rc_text[idx2] == '{') idx2 += 1 else idx2 += 5;
                    break;
                }
                if (startsWithIgnoreCase(rc_text[idx2..], "CAPTION")) {
                    idx2 += 7;
                    caption = parseQuotedString(rc_text, &idx2);
                } else if (startsWithIgnoreCase(rc_text[idx2..], "STYLE")) {
                    idx2 += 5;
                    style = parseStyleExpr(rc_text, &idx2);
                } else if (startsWithIgnoreCase(rc_text[idx2..], "EXSTYLE")) {
                    idx2 += 7;
                    exstyle = parseStyleExpr(rc_text, &idx2);
                } else if (startsWithIgnoreCase(rc_text[idx2..], "FONT")) {
                    idx2 += 4;
                    while (idx2 < rc_text.len and std.ascii.isWhitespace(rc_text[idx2])) idx2 += 1;
                    var pt: u32 = 0;
                    while (idx2 < rc_text.len and rc_text[idx2] >= '0' and rc_text[idx2] <= '9') {
                        pt = pt * 10 + @as(u32, rc_text[idx2] - '0');
                        idx2 += 1;
                    }
                    font_pt = @intCast(pt);
                    have_font = true;
                    while (idx2 < rc_text.len and (std.ascii.isWhitespace(rc_text[idx2]) or rc_text[idx2] == ',')) idx2 += 1;
                    font_name = parseQuotedString(rc_text, &idx2);
                } else if (startsWithIgnoreCase(rc_text[idx2..], "MENU") or startsWithIgnoreCase(rc_text[idx2..], "CLASS") or startsWithIgnoreCase(rc_text[idx2..], "CHARACTERISTICS") or startsWithIgnoreCase(rc_text[idx2..], "LANGUAGE") or startsWithIgnoreCase(rc_text[idx2..], "VERSION")) {
                    // Skip to end of line (these are accepted but unused)
                    while (idx2 < rc_text.len and rc_text[idx2] != '\n') idx2 += 1;
                } else {
                    // Unknown keyword — skip the token
                    while (idx2 < rc_text.len and !std.ascii.isWhitespace(rc_text[idx2])) idx2 += 1;
                }
            }

            if (have_font) style |= 0x40; // DS_SETFONT

            // Parse controls until END/}
            while (idx2 < rc_text.len and item_count < items.len) {
                while (idx2 < rc_text.len and (std.ascii.isWhitespace(rc_text[idx2]) or rc_text[idx2] == ',')) idx2 += 1;
                if (idx2 >= rc_text.len) break;
                if (rc_text[idx2] == '}') {
                    idx2 += 1;
                    break;
                }
                if (startsWithIgnoreCase(rc_text[idx2..], "END")) {
                    idx2 += 3;
                    break;
                }
                if (parseDialogControl(rc_text, &idx2, &items[item_count])) {
                    item_count += 1;
                } else {
                    // skip to next line on parse failure
                    while (idx2 < rc_text.len and rc_text[idx2] != '\n') idx2 += 1;
                    if (idx2 < rc_text.len) idx2 += 1;
                }
            }

            // ---- Emit DLGTEMPLATE ----
            // style(4) exstyle(4) cdit(2) x(2) y(2) cx(2) cy(2)
            std.mem.writeInt(u32, dlg_buf[ob..][0..4], style, .little);
            ob += 4;
            std.mem.writeInt(u32, dlg_buf[ob..][0..4], exstyle, .little);
            ob += 4;
            std.mem.writeInt(u16, dlg_buf[ob..][0..2], @intCast(item_count), .little);
            ob += 2;
            std.mem.writeInt(u16, dlg_buf[ob..][0..2], @bitCast(dlg_x), .little);
            ob += 2;
            std.mem.writeInt(u16, dlg_buf[ob..][0..2], @bitCast(dlg_y), .little);
            ob += 2;
            std.mem.writeInt(u16, dlg_buf[ob..][0..2], @bitCast(dlg_cx), .little);
            ob += 2;
            std.mem.writeInt(u16, dlg_buf[ob..][0..2], @bitCast(dlg_cy), .little);
            ob += 2;
            // menu (0), class (0)
            std.mem.writeInt(u16, dlg_buf[ob..][0..2], 0, .little);
            ob += 2;
            std.mem.writeInt(u16, dlg_buf[ob..][0..2], 0, .little);
            ob += 2;
            // caption: count-less utf16 + NUL
            for (caption) |ch| {
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], ch, .little);
                ob += 2;
            }
            std.mem.writeInt(u16, dlg_buf[ob..][0..2], 0, .little);
            ob += 2;
            // font (DS_SETFONT)
            if (have_font) {
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], font_pt, .little);
                ob += 2;
                for (font_name) |ch| {
                    std.mem.writeInt(u16, dlg_buf[ob..][0..2], ch, .little);
                    ob += 2;
                }
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], 0, .little);
                ob += 2;
            }
            // items
            for (0..item_count) |ii| {
                // align to DWORD
                while (ob % 4 != 0) {
                    dlg_buf[ob] = 0;
                    ob += 1;
                }
                const it = &items[ii];
                std.mem.writeInt(u32, dlg_buf[ob..][0..4], it.st, .little);
                ob += 4;
                std.mem.writeInt(u32, dlg_buf[ob..][0..4], it.ex, .little);
                ob += 4;
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], @bitCast(it.x), .little);
                ob += 2;
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], @bitCast(it.y), .little);
                ob += 2;
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], @bitCast(it.cx), .little);
                ob += 2;
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], @bitCast(it.cy), .little);
                ob += 2;
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], it.id, .little);
                ob += 2;
                // class atom
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], 0xFFFF, .little);
                ob += 2;
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], it.class_atom, .little);
                ob += 2;
                // title: count-less utf16 + NUL
                for (0..it.tlen) |ci| {
                    std.mem.writeInt(u16, dlg_buf[ob..][0..2], it.text[ci], .little);
                    ob += 2;
                }
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], 0, .little);
                ob += 2;
                // creation data length = 0
                std.mem.writeInt(u16, dlg_buf[ob..][0..2], 0, .little);
                ob += 2;
            }
            // align the whole resource to DWORD
            while (ob % 4 != 0) {
                dlg_buf[ob] = 0;
                ob += 1;
            }

            dlg_ids[dlg_count] = did;
            dlg_sizes[dlg_count] = @intCast(ob);
            dlg_count += 1;
        }
    }

    if (trace.enable_tracing) trace.print("RCDLL: parsed {d} dialogs\n", .{dlg_count});

    // Group strings into 16-slot blocks: block = (minID - 1) / 16 + 1
    const StringEntry = struct { len: u16, chars: [128]u16 };
    const Block = struct { base: u16, strs: [16]StringEntry };
    var blocks: [16]Block = undefined;
    var block_count: usize = 0;
    for (0..str_count) |si| {
        const id = ids[si];
        // Win32 STRINGTABLE convention: string ID N lives in block (N>>4)+1
        // at index (N & 0xF) — so ID 1 is at block 1 index 1, ID 16 at
        // block 2 index 0. (The old (id-1)%16 layout mismatched LoadStringA.)
        const block_idx = (id >> 4) & 0xFF;
        if (block_idx >= blocks.len) continue;
        const slot = id & 0xF;
        // find/create the block
        var bi: usize = block_count;
        var found = false;
        for (0..block_count) |k| {
            if (blocks[k].base == block_idx + 1) {
                bi = k;
                found = true;
                break;
            }
        }
        if (!found) {
            var new_block = Block{ .base = @intCast(block_idx + 1), .strs = undefined };
            for (0..16) |k| new_block.strs[k] = StringEntry{ .len = 0, .chars = [_]u16{0} ** 128 };
            blocks[block_count] = new_block;
            block_count += 1;
            bi = block_count - 1;
        }
        blocks[bi].strs[slot].len = str_lens[si];
        @memcpy(blocks[bi].strs[slot].chars[0..str_lens[si]], strs[si][0..str_lens[si]]);
    }

    // Parse ICON statements: NAME ICON "file.ico" (numeric or #define name).
    {
        var ii: usize = 0;
        while (ii < rc_text.len) {
            while (ii < rc_text.len and std.ascii.isWhitespace(rc_text[ii])) ii += 1;
            if (ii >= rc_text.len) break;
            var iid: u32 = 0;
            var have_iid = false;
            var name_end = ii;
            while (name_end < rc_text.len and !std.ascii.isWhitespace(rc_text[name_end])) name_end += 1;
            var after = name_end;
            while (after < rc_text.len and std.ascii.isWhitespace(rc_text[after])) after += 1;
            var is_icon = false;
            if (startsWithIgnoreCase(rc_text[after..], "ICON")) {
                if (rc_text[ii] >= '0' and rc_text[ii] <= '9') {
                    var v: u32 = 0;
                    var dg = ii;
                    while (dg < name_end and rc_text[dg] >= '0' and rc_text[dg] <= '9') {
                        v = v * 10 + @as(u32, rc_text[dg] - '0');
                        dg += 1;
                    }
                    iid = v;
                    have_iid = true;
                } else if (defineLookup(rc_text[ii..name_end])) |v| {
                    iid = v;
                    have_iid = true;
                }
                if (have_iid) is_icon = true;
            }
            if (!is_icon or icon_count >= icon_infos.len) {
                while (ii < rc_text.len and rc_text[ii] != '\n') ii += 1;
                if (ii < rc_text.len) ii += 1;
                continue;
            }
            // Parse the quoted filename
            var q = after + 4;
            while (q < rc_text.len and (std.ascii.isWhitespace(rc_text[q]) or rc_text[q] == ',')) q += 1;
            if (q >= rc_text.len or rc_text[q] != '"') {
                while (ii < rc_text.len and rc_text[ii] != '\n') ii += 1;
                if (ii < rc_text.len) ii += 1;
                continue;
            }
            var fend = q + 1;
            while (fend < rc_text.len and rc_text[fend] != '"') fend += 1;
            const ico_path = rc_text[q + 1 .. fend];

            // Read the .ico file
            var ico_host_buf: [1024]u8 = undefined;
            const ico_host_len = path_utils.toHostPath(ico_path, &ico_host_buf);
            if (ico_host_len == 0) {
                trace.print("RCDLL: cannot resolve icon '{s}'\n", .{ico_path});
                return 1;
            }
            var ico_file = std.Io.Dir.cwd().openFile(runtime.io(), ico_host_buf[0..ico_host_len], .{}) catch |err| {
                trace.print("RCDLL: cannot open icon '{s}': {s}\n", .{ ico_host_buf[0..ico_host_len], @errorName(err) });
                return 1;
            };
            defer ico_file.close(runtime.io());
            var ico_data: [8192]u8 = undefined;
            const ico_len = ico_file.readStreaming(runtime.io(), &.{&ico_data}) catch |err| {
                trace.print("RCDLL: cannot read icon '{s}': {s}\n", .{ ico_host_buf[0..ico_host_len], @errorName(err) });
                return 1;
            };
            if (ico_len < 22) {
                trace.print("RCDLL: icon '{s}' too short ({d} bytes)\n", .{ ico_host_buf[0..ico_host_len], ico_len });
                return 1;
            }
            // ICONDIR: reserved(2) type(2) count(2); first entry at offset 6.
            const count = std.mem.readInt(u16, ico_data[4..6], .little);
            if (count == 0) {
                while (ii < rc_text.len and rc_text[ii] != '\n') ii += 1;
                if (ii < rc_text.len) ii += 1;
                continue;
            }
            // First ICONDIRENTRY (16 bytes at file offset 6):
            // bWidth, bHeight, bColorCount, bReserved, wPlanes(4), wBitCount(6),
            // dwBytesInRes(8), dwImageOffset(12)
            const width: u8 = ico_data[6];
            const height: u8 = ico_data[7];
            const planes = std.mem.readInt(u16, ico_data[10..12], .little);
            const bitcount = std.mem.readInt(u16, ico_data[12..14], .little);
            const bytes_in_res = std.mem.readInt(u32, ico_data[14..18], .little);
            const img_off = std.mem.readInt(u32, ico_data[18..22], .little);
            if (@as(usize, img_off) + bytes_in_res > ico_len) {
                while (ii < rc_text.len and rc_text[ii] != '\n') ii += 1;
                if (ii < rc_text.len) ii += 1;
                continue;
            }
            const ilen = @min(@as(u32, bytes_in_res), @as(u32, icon_infos[icon_count].image.len));
            @memcpy(icon_infos[icon_count].image[0..ilen], ico_data[img_off .. img_off + ilen]);
            icon_infos[icon_count].image_len = ilen;
            icon_infos[icon_count].id = iid;
            icon_infos[icon_count].width = width;
            icon_infos[icon_count].height = height;
            icon_infos[icon_count].planes = planes;
            icon_infos[icon_count].bitcount = bitcount;
            icon_infos[icon_count].bytes_in_res = bytes_in_res;
            icon_count += 1;

            while (ii < rc_text.len and rc_text[ii] != '\n') ii += 1;
            if (ii < rc_text.len) ii += 1;
        }
    }

    if (block_count == 0 and dlg_count == 0 and menu_count == 0 and icon_count == 0) {
        if (trace.enable_tracing) trace.print("RCDLL: no resource data\n", .{});
        return 1;
    }

    // Emit the .res file.
    if (output == null) {
        if (trace.enable_tracing) trace.print("RCDLL: no output file\n", .{});
        return 1;
    }
    var res_host_buf: [1024]u8 = undefined;
    const res_host_len = path_utils.toHostPath(output.?, &res_host_buf);
    if (res_host_len == 0) return 1;
    const posix_fs = @import("msvcrt/posix_fs.zig");
    const out_fd = posix_fs.open(@as([*:0]const u8, @ptrCast(&res_host_buf)), 64 | 2 | 512, 0o666); // O_CREAT|O_RDWR|O_TRUNC
    if (out_fd < 0) {
        if (trace.enable_tracing) trace.print("RCDLL: cannot create '{s}'\n", .{res_host_buf[0..res_host_len]});
        return 1;
    }
    const host_io = @import("host_io.zig");
    const out_file = host_io.fileFromFd(@intCast(out_fd));
    // Raw close — std.Io's close(runtime.io()) hits TLS (%fs:0x308) and
    // faults inside the native64 compat dispatch context.
    defer host_io.closeFile(out_file);

    if (trace.enable_tracing) trace.print("RCDLL: parsed {d} icons\n", .{icon_count});

    var out_buf: [8192]u8 = undefined;
    var ob: usize = 0;

    for (0..block_count) |bi| {
        // Build the string data: 16 slots, each WORD len + chars.
        var data_buf: [1024]u8 = undefined;
        var db: usize = 0;
        var data_size: u32 = 0;
        for (0..16) |slot| {
            const len = blocks[bi].strs[slot].len;
            std.mem.writeInt(u16, data_buf[db..][0..2], len, .little);
            db += 2;
            data_size += 2;
            for (0..len) |ci| {
                std.mem.writeInt(u16, data_buf[db..][0..2], blocks[bi].strs[slot].chars[ci], .little);
                db += 2;
                data_size += 2;
            }
        }
        // Align data to 4
        while (data_size % 4 != 0) {
            data_buf[db] = 0;
            db += 1;
            data_size += 1;
        }

        // RESOURCEHEADER
        std.mem.writeInt(u32, out_buf[ob..][0..4], data_size, .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0x20, .little); // HeaderSize
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 6, .little); // RT_STRING
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], blocks[bi].base, .little); // Name = block number
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little); // DataVersion
        ob += 4;
        std.mem.writeInt(u16, out_buf[ob..][0..2], 0x30, .little); // MemoryFlags
        ob += 2;
        std.mem.writeInt(u16, out_buf[ob..][0..2], 0x409, .little); // LanguageId (US English)
        ob += 2;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little); // Version
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little); // Characteristics
        ob += 4;

        @memcpy(out_buf[ob .. ob + db], data_buf[0..db]);
        ob += db;
    }

    // Emit DIALOG resources (RT_DIALOG = 5).
    for (0..dlg_count) |di| {
        const dsize = dlg_sizes[di];
        // RESOURCEHEADER
        std.mem.writeInt(u32, out_buf[ob..][0..4], dsize, .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0x20, .little); // HeaderSize
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 5, .little); // RT_DIALOG
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], dlg_ids[di], .little); // Name = dialog id
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little); // DataVersion
        ob += 4;
        std.mem.writeInt(u16, out_buf[ob..][0..2], 0x30, .little); // MemoryFlags
        ob += 2;
        std.mem.writeInt(u16, out_buf[ob..][0..2], 0x409, .little); // LanguageId
        ob += 2;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little); // Version
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little); // Characteristics
        ob += 4;

        @memcpy(out_buf[ob .. ob + dsize], dlg_data[di][0..dsize]);
        ob += dsize;
    }

    // Emit MENU resources (RT_MENU = 4).
    for (0..menu_count) |mei| {
        const msize = menu_sizes[mei];
        std.mem.writeInt(u32, out_buf[ob..][0..4], msize, .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0x20, .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 4, .little); // RT_MENU
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], menu_ids[mei], .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little);
        ob += 4;
        std.mem.writeInt(u16, out_buf[ob..][0..2], 0x30, .little);
        ob += 2;
        std.mem.writeInt(u16, out_buf[ob..][0..2], 0x409, .little);
        ob += 2;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little);
        ob += 4;
        @memcpy(out_buf[ob .. ob + msize], menu_data[mei][0..msize]);
        ob += msize;
    }

    // Emit ICON resources: RT_ICON (3) named 1..N, then RT_GROUP_ICON (14).
    for (0..icon_count) |ii| {
        const ic = &icon_infos[ii];
        // RT_ICON
        std.mem.writeInt(u32, out_buf[ob..][0..4], ic.image_len, .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0x20, .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 3, .little); // RT_ICON
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 1, .little); // Name = 1
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little);
        ob += 4;
        std.mem.writeInt(u16, out_buf[ob..][0..2], 0x30, .little);
        ob += 2;
        std.mem.writeInt(u16, out_buf[ob..][0..2], 0x409, .little);
        ob += 2;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little);
        ob += 4;
        @memcpy(out_buf[ob .. ob + ic.image_len], ic.image[0..ic.image_len]);
        ob += ic.image_len;

        // RT_GROUP_ICON: GRPICONDIR
        var grp: [32]u8 = undefined;
        var gb: usize = 0;
        std.mem.writeInt(u16, grp[gb..][0..2], 0, .little); // reserved
        gb += 2;
        std.mem.writeInt(u16, grp[gb..][0..2], 1, .little); // type = icon
        gb += 2;
        std.mem.writeInt(u16, grp[gb..][0..2], 1, .little); // count
        gb += 2;
        grp[gb] = ic.width;
        gb += 1;
        grp[gb] = ic.height;
        gb += 1;
        grp[gb] = 0; // color count
        gb += 1;
        grp[gb] = 0; // reserved
        gb += 1;
        std.mem.writeInt(u16, grp[gb..][0..2], ic.planes, .little);
        gb += 2;
        std.mem.writeInt(u16, grp[gb..][0..2], ic.bitcount, .little);
        gb += 2;
        std.mem.writeInt(u32, grp[gb..][0..4], ic.bytes_in_res, .little);
        gb += 4;
        std.mem.writeInt(u16, grp[gb..][0..2], 1, .little); // nId -> RT_ICON name
        gb += 2;

        std.mem.writeInt(u32, out_buf[ob..][0..4], @intCast(gb), .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0x20, .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 14, .little); // RT_GROUP_ICON
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], ic.id, .little); // Name = icon id
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little);
        ob += 4;
        std.mem.writeInt(u16, out_buf[ob..][0..2], 0x30, .little);
        ob += 2;
        std.mem.writeInt(u16, out_buf[ob..][0..2], 0x409, .little);
        ob += 2;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little);
        ob += 4;
        std.mem.writeInt(u32, out_buf[ob..][0..4], 0, .little);
        ob += 4;
        @memcpy(out_buf[ob .. ob + gb], grp[0..gb]);
        ob += gb;
    }

    host_io.writeAllToFile(out_file, out_buf[0..ob]) catch return 1;
    if (trace.enable_tracing) trace.print("RCDLL: wrote {d} bytes to '{s}'\n", .{ ob, res_host_buf[0..res_host_len] });
    return 0; // success
}

/// Parses a double-quoted string starting at `*idx` (which must point at the
/// opening quote). Advances `*idx` past the closing quote. Returns the slice.
fn parseQuotedString(text: []const u8, idx: *usize) []const u8 {
    while (idx.* < text.len and text[idx.*] != '"') idx.* += 1;
    if (idx.* >= text.len) return "";
    const start = idx.* + 1;
    var end = start;
    while (end < text.len and text[end] != '"') end += 1;
    idx.* = if (end < text.len) end + 1 else end;
    return text[start..end];
}

/// Parses an OR-expression of style names / numeric constants.
fn parseStyleExpr(text: []const u8, idx: *usize) u32 {
    var result: u32 = 0;
    while (true) {
        while (idx.* < text.len and (std.ascii.isWhitespace(text[idx.*]) or text[idx.*] == '|' or text[idx.*] == ',')) idx.* += 1;
        if (idx.* >= text.len) break;
        // numeric?
        if (text[idx.*] >= '0' and text[idx.*] <= '9') {
            var v: u32 = 0;
            while (idx.* < text.len and text[idx.*] >= '0' and text[idx.*] <= '9') {
                v = v * 10 + @as(u32, text[idx.*] - '0');
                idx.* += 1;
            }
            result |= v;
        } else {
            // style name
            const start = idx.*;
            while (idx.* < text.len and !std.ascii.isWhitespace(text[idx.*]) and text[idx.*] != '|') idx.* += 1;
            const name = text[start..idx.*];
            result |= styleFromName(name);
        }
        // after a name, continue if the next non-ws char is '|'
        var look = idx.*;
        while (look < text.len and std.ascii.isWhitespace(text[look])) look += 1;
        if (look >= text.len or text[look] != '|') break;
        idx.* = look + 1;
    }
    return result;
}

fn styleFromName(name: []const u8) u32 {
    const WS_POPUP: u32 = 0x80000000;
    const WS_CHILD: u32 = 0x40000000;
    const WS_MINIMIZE: u32 = 0x20000000;
    const WS_VISIBLE: u32 = 0x10000000;
    const WS_DISABLED: u32 = 0x08000000;
    const WS_CLIPSIBLINGS: u32 = 0x04000000;
    const WS_CLIPCHILDREN: u32 = 0x02000000;
    const WS_MAXIMIZE: u32 = 0x01000000;
    const WS_CAPTION: u32 = 0x00C00000;
    const WS_BORDER: u32 = 0x00800000;
    const WS_DLGFRAME: u32 = 0x00400000;
    const WS_VSCROLL: u32 = 0x00200000;
    const WS_HSCROLL: u32 = 0x00100000;
    const WS_SYSMENU: u32 = 0x00080000;
    const WS_THICKFRAME: u32 = 0x00040000;
    const WS_GROUP: u32 = 0x00020000;
    const WS_TABSTOP: u32 = 0x00010000;
    const DS_MODALFRAME: u32 = 0x00000080;
    const DS_SETFONT: u32 = 0x00000040;
    const DS_CENTER: u32 = 0x00000800;
    const WS_EX_CLIENTEDGE: u32 = 0x00000200;
    const ES_CENTER: u32 = 0x0001;
    const ES_RIGHT: u32 = 0x0002;
    const ES_MULTILINE: u32 = 0x0004;
    const ES_PASSWORD: u32 = 0x0020;
    const ES_AUTOHSCROLL: u32 = 0x0080;
    const ES_READONLY: u32 = 0x0800;
    const SS_CENTER: u32 = 0x0001;
    const SS_RIGHT: u32 = 0x0002;
    const SS_ICON: u32 = 0x0003;
    const SS_BLACKFRAME: u32 = 0x0007;
    const SS_SUNKEN: u32 = 0x1000;
    const BS_DEFPUSHBUTTON: u32 = 0x0001;
    const BS_CHECKBOX: u32 = 0x0002;
    const BS_AUTOCHECKBOX: u32 = 0x0003;
    const BS_RADIOBUTTON: u32 = 0x0004;
    const BS_3STATE: u32 = 0x0005;
    const BS_AUTO3STATE: u32 = 0x0006;
    const BS_GROUPBOX: u32 = 0x0007;
    const BS_AUTORADIOBUTTON: u32 = 0x0009;
    const BS_OWNERDRAW: u32 = 0x000B;
    const CBS_DROPDOWN: u32 = 0x0002;
    const CBS_DROPDOWNLIST: u32 = 0x0003;
    const LBS_SORT: u32 = 0x0002;
    const LBS_MULTIPLESEL: u32 = 0x0008;
    const SBS_VERT: u32 = 0x0001;
    const table = [_]struct { name: []const u8, val: u32 }{
        .{ .name = "WS_POPUP", .val = WS_POPUP },
        .{ .name = "WS_CHILD", .val = WS_CHILD },
        .{ .name = "WS_MINIMIZE", .val = WS_MINIMIZE },
        .{ .name = "WS_VISIBLE", .val = WS_VISIBLE },
        .{ .name = "WS_DISABLED", .val = WS_DISABLED },
        .{ .name = "WS_CLIPSIBLINGS", .val = WS_CLIPSIBLINGS },
        .{ .name = "WS_CLIPCHILDREN", .val = WS_CLIPCHILDREN },
        .{ .name = "WS_MAXIMIZE", .val = WS_MAXIMIZE },
        .{ .name = "WS_CAPTION", .val = WS_CAPTION },
        .{ .name = "WS_BORDER", .val = WS_BORDER },
        .{ .name = "WS_DLGFRAME", .val = WS_DLGFRAME },
        .{ .name = "WS_VSCROLL", .val = WS_VSCROLL },
        .{ .name = "WS_HSCROLL", .val = WS_HSCROLL },
        .{ .name = "WS_SYSMENU", .val = WS_SYSMENU },
        .{ .name = "WS_THICKFRAME", .val = WS_THICKFRAME },
        .{ .name = "WS_GROUP", .val = WS_GROUP },
        .{ .name = "WS_TABSTOP", .val = WS_TABSTOP },
        .{ .name = "DS_MODALFRAME", .val = DS_MODALFRAME },
        .{ .name = "DS_SETFONT", .val = DS_SETFONT },
        .{ .name = "DS_CENTER", .val = DS_CENTER },
        .{ .name = "WS_EX_CLIENTEDGE", .val = WS_EX_CLIENTEDGE },
        .{ .name = "ES_CENTER", .val = ES_CENTER },
        .{ .name = "ES_RIGHT", .val = ES_RIGHT },
        .{ .name = "ES_MULTILINE", .val = ES_MULTILINE },
        .{ .name = "ES_PASSWORD", .val = ES_PASSWORD },
        .{ .name = "ES_AUTOHSCROLL", .val = ES_AUTOHSCROLL },
        .{ .name = "ES_READONLY", .val = ES_READONLY },
        .{ .name = "SS_CENTER", .val = SS_CENTER },
        .{ .name = "SS_RIGHT", .val = SS_RIGHT },
        .{ .name = "SS_ICON", .val = SS_ICON },
        .{ .name = "SS_BLACKFRAME", .val = SS_BLACKFRAME },
        .{ .name = "SS_SUNKEN", .val = SS_SUNKEN },
        .{ .name = "BS_DEFPUSHBUTTON", .val = BS_DEFPUSHBUTTON },
        .{ .name = "BS_CHECKBOX", .val = BS_CHECKBOX },
        .{ .name = "BS_AUTOCHECKBOX", .val = BS_AUTOCHECKBOX },
        .{ .name = "BS_RADIOBUTTON", .val = BS_RADIOBUTTON },
        .{ .name = "BS_3STATE", .val = BS_3STATE },
        .{ .name = "BS_AUTO3STATE", .val = BS_AUTO3STATE },
        .{ .name = "BS_GROUPBOX", .val = BS_GROUPBOX },
        .{ .name = "BS_AUTORADIOBUTTON", .val = BS_AUTORADIOBUTTON },
        .{ .name = "BS_OWNERDRAW", .val = BS_OWNERDRAW },
        .{ .name = "CBS_DROPDOWN", .val = CBS_DROPDOWN },
        .{ .name = "CBS_DROPDOWNLIST", .val = CBS_DROPDOWNLIST },
        .{ .name = "LBS_SORT", .val = LBS_SORT },
        .{ .name = "LBS_MULTIPLESEL", .val = LBS_MULTIPLESEL },
        .{ .name = "SBS_VERT", .val = SBS_VERT },
    };
    for (table) |t| {
        if (std.ascii.eqlIgnoreCase(t.name, name)) return t.val;
    }
    return 0;
}

/// Parses one dialog control statement. Returns false if the line is not a
/// known control type. `out` receives the parsed DLGITEMTEMPLATE fields.
fn parseDialogControl(text: []const u8, idx: *usize, out: *DlgItem) bool {
    const WS_CHILD: u32 = 0x40000000;
    const WS_VISIBLE: u32 = 0x10000000;
    const WS_BORDER: u32 = 0x00800000;
    const WS_TABSTOP: u32 = 0x00010000;
    const ctrl_type = struct {
        name: []const u8,
        class_atom: u16,
        base_style: u32,
        needs_text: bool, // text is the first quoted arg
        text_is_id: bool, // "text" is actually a resource id (e.g. ICON)
    };
    const types = [_]ctrl_type{
        .{ .name = "PUSHBUTTON", .class_atom = 0x0080, .base_style = 0x0000, .needs_text = true, .text_is_id = false },
        .{ .name = "DEFPUSHBUTTON", .class_atom = 0x0080, .base_style = 0x0001, .needs_text = true, .text_is_id = false },
        .{ .name = "CHECKBOX", .class_atom = 0x0080, .base_style = 0x0002, .needs_text = true, .text_is_id = false },
        .{ .name = "AUTOCHECKBOX", .class_atom = 0x0080, .base_style = 0x0003, .needs_text = true, .text_is_id = false },
        .{ .name = "RADIOBUTTON", .class_atom = 0x0080, .base_style = 0x0004, .needs_text = true, .text_is_id = false },
        .{ .name = "AUTORADIOBUTTON", .class_atom = 0x0080, .base_style = 0x0009, .needs_text = true, .text_is_id = false },
        .{ .name = "GROUPBOX", .class_atom = 0x0080, .base_style = 0x0007, .needs_text = true, .text_is_id = false },
        .{ .name = "PUSHBOX", .class_atom = 0x0080, .base_style = 0x000A, .needs_text = true, .text_is_id = false },
        .{ .name = "LTEXT", .class_atom = 0x0082, .base_style = 0x0000, .needs_text = true, .text_is_id = false },
        .{ .name = "CTEXT", .class_atom = 0x0082, .base_style = 0x0001, .needs_text = true, .text_is_id = false },
        .{ .name = "RTEXT", .class_atom = 0x0082, .base_style = 0x0002, .needs_text = true, .text_is_id = false },
        .{ .name = "EDITTEXT", .class_atom = 0x0081, .base_style = 0x0080, .needs_text = false, .text_is_id = false },
        .{ .name = "COMBOBOX", .class_atom = 0x0085, .base_style = 0x0002, .needs_text = false, .text_is_id = false },
        .{ .name = "LISTBOX", .class_atom = 0x0083, .base_style = 0x0002, .needs_text = false, .text_is_id = false },
        .{ .name = "SCROLLBAR", .class_atom = 0x0084, .base_style = 0x0000, .needs_text = false, .text_is_id = false },
        .{ .name = "ICON", .class_atom = 0x0082, .base_style = 0x0003, .needs_text = false, .text_is_id = true },
    };

    var t: ?ctrl_type = null;
    for (types) |ct| {
        if (startsWithIgnoreCase(text[idx.*..], ct.name)) {
            t = ct;
            idx.* += ct.name.len;
            break;
        }
    }
    if (t == null) return false;
    const ct = t.?;

    // skip whitespace
    while (idx.* < text.len and (std.ascii.isWhitespace(text[idx.*]) or text[idx.*] == ',')) idx.* += 1;

    var ctl_text: []const u8 = "";
    if (ct.needs_text or ct.text_is_id) {
        if (idx.* >= text.len or text[idx.*] != '"') return false;
        ctl_text = parseQuotedString(text, idx);
        while (idx.* < text.len and (std.ascii.isWhitespace(text[idx.*]) or text[idx.*] == ',')) idx.* += 1;
    }

    // id (numeric or #define name)
    var id: u32 = 0;
    var have_numeric = false;
    while (idx.* < text.len and text[idx.*] >= '0' and text[idx.*] <= '9') {
        id = id * 10 + @as(u32, text[idx.*] - '0');
        idx.* += 1;
        have_numeric = true;
    }
    if (!have_numeric) {
        // optional negative id (-1)
        var look = idx.*;
        while (look < text.len and std.ascii.isWhitespace(text[look])) look += 1;
        if (look < text.len and text[look] == '-') {
            idx.* = look + 1;
            var neg: u32 = 0;
            while (idx.* < text.len and text[idx.*] >= '0' and text[idx.*] <= '9') {
                neg = neg * 10 + @as(u32, text[idx.*] - '0');
                idx.* += 1;
            }
            id = (~neg) +% 1; // two's complement
            have_numeric = true;
        }
    }
    if (!have_numeric) {
        // try a #define name
        var name_end = idx.*;
        while (name_end < text.len and !std.ascii.isWhitespace(text[name_end]) and text[name_end] != ',') name_end += 1;
        if (name_end > idx.*) {
            if (defineLookup(text[idx.*..name_end])) |v| {
                id = v;
                have_numeric = true;
                idx.* = name_end;
            }
        }
    }
    if (!have_numeric) return false;

    // coords x, y, cx, cy
    var vals: [4]i32 = undefined;
    for (0..4) |vi| {
        while (idx.* < text.len and (std.ascii.isWhitespace(text[idx.*]) or text[idx.*] == ',')) idx.* += 1;
        var v: i32 = 0;
        var neg = false;
        if (idx.* < text.len and text[idx.*] == '-') {
            neg = true;
            idx.* += 1;
        }
        while (idx.* < text.len and text[idx.*] >= '0' and text[idx.*] <= '9') {
            v = v * 10 + @as(i32, text[idx.*] - '0');
            idx.* += 1;
        }
        vals[vi] = if (neg) -v else v;
    }

    // optional trailing style expression (after the 4 coords)
    var extra_style: u32 = 0;
    {
        var look = idx.*;
        while (look < text.len and std.ascii.isWhitespace(text[look])) look += 1;
        if (look < text.len and text[look] != '\n' and text[look] != '}' and text[look] != ',') {
            // there may be a comma then the style
            if (text[look] == ',') {
                idx.* = look + 1;
                extra_style = parseStyleExpr(text, idx);
            }
        }
    }

    var style: u32 = WS_CHILD | WS_VISIBLE;
    // controls are dialog units; WS_BORDER for edit, WS_TABSTOP for buttons
    switch (ct.class_atom) {
        0x0081 => style |= WS_BORDER | WS_TABSTOP, // edit
        0x0080 => style |= WS_TABSTOP, // button
        else => {},
    }
    style |= ct.base_style | extra_style;

    out.st = style;
    out.ex = 0;
    out.x = @intCast(vals[0]);
    out.y = @intCast(vals[1]);
    out.cx = @intCast(vals[2]);
    out.cy = @intCast(vals[3]);
    out.id = @intCast(id & 0xFFFF);
    out.class_atom = ct.class_atom;
    out.tlen = 0;
    if (ctl_text.len > 0) {
        const copy = @min(ctl_text.len, 63);
        @memcpy(out.text[0..copy], ctl_text[0..copy]);
        out.tlen = @intCast(copy);
    }
    return true;
}

test "resource compilation preserves output when an icon cannot be loaded" {
    const io = @import("../runtime.zig").io();
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..dir_len];
    const input = try std.fmt.allocPrint(allocator, "Z:{s}/input.rc", .{dir});
    defer allocator.free(input);
    const output = try std.fmt.allocPrint(allocator, "{s}/output.res", .{dir});
    defer allocator.free(output);
    try tmp.dir.createDir(io, "directory", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "short.ico", .data = "short" });

    for ([_][]const u8{ "missing.ico", "directory", "short.ico" }) |icon| {
        const source = try std.fmt.allocPrint(allocator, "STRINGTABLE\nBEGIN\n1, \"hello\"\nEND\n2 ICON \"{s}/{s}\"\n", .{ dir, icon });
        defer allocator.free(source);
        try tmp.dir.writeFile(io, .{ .sub_path = "input.rc", .data = source });
        try tmp.dir.writeFile(io, .{ .sub_path = "output.res", .data = "previous output" });
        try std.testing.expectEqual(@as(i32, 1), compileResources(&.{ "rc", "/fo", output, input }));
        const file = try tmp.dir.openFile(io, "output.res", .{});
        defer file.close(io);
        var contents: [32]u8 = undefined;
        const len = try file.readPositionalAll(io, &contents, 0);
        try std.testing.expectEqualStrings("previous output", contents[0..len]);
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "input.rc", .data = "STRINGTABLE\nBEGIN\n1, \"hello\"\nEND\n" });
    try std.testing.expectEqual(@as(i32, 0), compileResources(&.{ "rc", "/fo", output, input }));
    const file = try tmp.dir.openFile(io, "output.res", .{});
    defer file.close(io);
    var contents: [128]u8 = undefined;
    const len = try file.readPositionalAll(io, &contents, 0);
    try std.testing.expectEqual(@as(usize, 76), len);
    try std.testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, contents[8..12], .little));
    try std.testing.expectEqualSlices(u8, "h\x00e\x00l\x00l\x00o\x00", contents[36..46]);
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

/// Handler callback registration — no-op.
fn rc_handler(a: usize) callconv(w32cc.WINAPI) void {
    _ = a;
    if (trace.enable_tracing) trace.print("RCDLL: Handler() (stub)\n", .{});
}

/// Registers RCDLL.dll functions with the environment.
pub fn register(environment: *env.Environment) !void {
    const m = "RCDLL.dll";
    try environment.addBuiltinExportComptime(m, "RC", rc_main);
    try environment.addBuiltinExportComptime(m, "Handler", rc_handler);
}
