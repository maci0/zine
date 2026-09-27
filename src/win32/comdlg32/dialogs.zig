const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const renderer = if (@import("builtin").os.tag != .windows) @import("../../gui/renderer.zig") else struct {
    pub fn openFileDialog(_: anytype, _: bool) void {}
    pub fn openColorDialog(_: anytype) void {}
    pub fn openFontDialog(_: []const u8, _: i32, _: bool, _: bool) void {}
    pub fn openPrintDialog(_: i32, _: i32, _: i32, _: i32, _: i32) void {}
    pub fn openFindDialog(_: []const u8, _: []const u8, _: bool) void {}
    pub fn openPageSetupDialog(_: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: []const u8) void {}
    pub fn closeDialog() void {}
    pub var on_file_uploaded: ?*const fn ([]const u8) void = null;
    pub var on_cancel_dialog: ?*const fn () void = null;
    pub var on_color_selected: ?*const fn (u32) void = null;
    pub var on_font_chosen: ?*const fn ([]const u8, i32, bool, bool) void = null;
    pub var on_print_chosen: ?*const fn (i32, i32, i32) void = null;
    pub var on_find_action: ?*const fn ([]const u8, []const u8, []const u8, bool, bool) void = null;
    pub var on_page_setup_chosen: ?*const fn (i32, i32, i32, i32, i32, i32, i32) void = null;
};
const kernel32 = @import("../kernel32.zig");
const runtime = @import("../../runtime.zig");

/// Guards every dialog result variable below (pending_file_path,
/// dialog_cancelled, pending_color, font/print/pagesetup results). The guest
/// thread resets and polls them while FLTK/web backend threads store the
/// outcomes from their own threads.
var dlg_result_mutex: runtime.Mutex = .{};

var dialog_cancelled: bool = false;
var pending_file_path: ?[]const u8 = null;
const file_path_allocator = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;

fn fileDialogDone() bool {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    return pending_file_path != null or dialog_cancelled;
}

fn colorDialogDone() bool {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    return pending_color != null or dialog_cancelled;
}

fn fontDialogDone() bool {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    return font_pending or dialog_cancelled;
}

fn printDialogDone() bool {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    return print_pending or dialog_cancelled;
}

fn pageSetupDialogDone() bool {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    return page_setup_pending or dialog_cancelled;
}

fn handleCancelDialog() void {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    dialog_cancelled = true;
}

fn handleFileUploaded(path: []const u8) void {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    const owned = file_path_allocator.dupe(u8, path) catch return;
    clearPendingFilePathLocked();
    pending_file_path = owned;
}

fn clearPendingFilePathLocked() void {
    if (pending_file_path) |p| file_path_allocator.free(p);
    pending_file_path = null;
}

fn takePendingFilePath() ?[]const u8 {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    const path = pending_file_path;
    pending_file_path = null;
    return path;
}

test "file dialog paths own borrowed input and release replaced results" {
    defer clearPendingFilePathLocked();
    var input = "drive_c/first.txt".*;
    handleFileUploaded(&input);
    @memset(&input, 'x');
    try std.testing.expectEqualStrings("drive_c/first.txt", pending_file_path.?);

    for (0..128) |_| {
        handleFileUploaded("drive_c/replacement.txt");
    }
    const taken = takePendingFilePath().?;
    defer file_path_allocator.free(taken);
    try std.testing.expect(pending_file_path == null);
    try std.testing.expectEqualStrings("drive_c/replacement.txt", taken);

    handleFileUploaded("drive_c/next.txt");
    clearPendingFilePathLocked();
    try std.testing.expect(pending_file_path == null);
    try std.testing.expectEqualStrings("drive_c/replacement.txt", taken);
    try std.testing.expect(takePendingFilePath() == null);
}

/// Upper bound on the default-extension scan. The guest string is read as
/// plain bytes, so the walk stops at the bound if the NUL is missing.
const max_def_ext_chars: usize = 32;

fn defExtA(ptr: u32) ?[]const u8 {
    if (ptr == 0) return null;
    const ext = trace.c_span(ptr);
    return if (ext.len > 0) ext else null;
}

fn defExtW(ptr: u32) ?[]const u16 {
    if (ptr == 0) return null;
    const ext = @as([*]const u16, @ptrFromInt(ptr));
    var len: usize = 0;
    while (len < max_def_ext_chars and ext[len] != 0) : (len += 1) {}
    return if (len > 0) ext[0..len] else null;
}

fn commonFileDialogA(lpofn_ptr: usize, is_save: bool) i32 {
    return commonFileDialog(u8, parseFilterStringA, defExtA, lpofn_ptr, is_save);
}

fn commonFileDialog(
    comptime C: type,
    comptime filter_of: fn (u32) ?[]const u8,
    comptime def_ext_of: fn (u32) ?[]const C,
    lpofn_ptr: usize,
    is_save: bool,
) i32 {
    {
        dlg_result_mutex.lock();
        defer dlg_result_mutex.unlock();
        clearPendingFilePathLocked();
        dialog_cancelled = false;
    }

    const sep: C = std.math.lossyCast(C, '\\');
    const dot: C = std.math.lossyCast(C, '.');

    var filters_json: ?[]const u8 = null;
    var def_ext: ?[]const C = null;
    if (lpofn_ptr != 0) {
        const ofn = @as(*w32.OPENFILENAMEA, @ptrFromInt(lpofn_ptr));
        if (ofn.lpstrFilter != 0) {
            filters_json = filter_of(ofn.lpstrFilter);
        }
        def_ext = def_ext_of(ofn.lpstrDefExt);
    }
    defer if (filters_json) |f| std.heap.page_allocator.free(f);

    renderer.openFileDialog(filters_json, is_save);

    const prev_file_cb = renderer.on_file_uploaded;
    const prev_cancel_cb = renderer.on_cancel_dialog;
    renderer.on_file_uploaded = &handleFileUploaded;
    renderer.on_cancel_dialog = &handleCancelDialog;

    while (!fileDialogDone()) {
        @import("../../runtime.zig").pauseOrAdvance(10 * std.time.ns_per_ms);
    }

    renderer.on_file_uploaded = prev_file_cb;
    renderer.on_cancel_dialog = prev_cancel_cb;

    renderer.closeDialog();

    if (takePendingFilePath()) |path| {
        defer file_path_allocator.free(path);
        if (lpofn_ptr != 0) {
            const ofn = @as(*w32.OPENFILENAMEA, @ptrFromInt(lpofn_ptr));

            if (ofn.lpstrFile != 0 and ofn.nMaxFile > path.len) {
                const lpstrFile = @as([*]C, @ptrFromInt(ofn.lpstrFile));
                for (0..path.len) |i| {
                    lpstrFile[i] = if (path[i] == '/') sep else std.math.lossyCast(C, path[i]);
                }
                var final_len = path.len;

                if (def_ext) |ext| {
                    var has_dot = false;
                    var last_sep: usize = 0;
                    for (0..path.len) |i| {
                        if (path[i] == '/' or path[i] == '\\') last_sep = i + 1;
                    }
                    for (last_sep..path.len) |i| {
                        if (path[i] == '.') {
                            has_dot = true;
                            break;
                        }
                    }
                    if (!has_dot) {
                        if (final_len + 1 + ext.len < ofn.nMaxFile) {
                            lpstrFile[final_len] = dot;
                            for (ext, 0..) |ch, i| lpstrFile[final_len + 1 + i] = ch;
                            final_len += 1 + ext.len;
                        }
                    }
                }
                lpstrFile[final_len] = 0;

                var file_offset: u16 = 0;
                var ext_offset: u16 = 0;
                for (0..final_len) |i| {
                    if (lpstrFile[i] == sep) {
                        file_offset = @intCast(i + 1);
                    }
                    if (lpstrFile[i] == dot) {
                        ext_offset = @intCast(i + 1);
                    }
                }

                ofn.nFileOffset = file_offset;
                ofn.nFileExtension = ext_offset;

                if (ofn.lpstrFileTitle != 0 and ofn.nMaxFileTitle > 0) {
                    const title_len = final_len - file_offset;
                    if (ofn.nMaxFileTitle > title_len) {
                        const lpstrFileTitle = @as([*]C, @ptrFromInt(ofn.lpstrFileTitle));
                        for (0..title_len) |i| {
                            lpstrFileTitle[i] = lpstrFile[file_offset + i];
                        }
                        lpstrFileTitle[title_len] = 0;
                    }
                }

                if ((ofn.Flags & w32.OFN_ENABLEHOOK) != 0) {
                    if (ofn.lpfnHook != 0) {
                        const hook_fn = @as(*const fn (usize, u32, usize, usize) callconv(w32cc.WINAPI) isize, @ptrFromInt(ofn.lpfnHook));
                        _ = hook_fn(0xBEEF, w32.WM_INITDIALOG, 0, lpofn_ptr);
                    }
                }

                return 1;
            }
        }
    }

    return 0;
}

/// Creates an Open dialog box that lets the user specify the drive, directory, and the name of a file or set of files to be opened.
/// Implementation status: Partially implemented (delegates to the host browser's file dialog)
pub fn GetOpenFileNameA(lpofn_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("COMDLG32: GetOpenFileNameA({x})\n", .{lpofn_ptr});
    return commonFileDialogA(lpofn_ptr, false);
}

/// Creates a Save dialog box that lets the user specify the drive, directory, and name of a file to save.
/// Implementation status: Partially implemented (delegates to the host browser's file dialog)
pub fn GetSaveFileNameA(lpofn_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("COMDLG32: GetSaveFileNameA({x})\n", .{lpofn_ptr});
    return commonFileDialogA(lpofn_ptr, true);
}

fn commonFileDialogW(lpofn_ptr: usize, is_save: bool) i32 {
    return commonFileDialog(u16, parseFilterStringW, defExtW, lpofn_ptr, is_save);
}

/// Creates an Open dialog box that lets the user specify the drive, directory, and the name of a file or set of files to be opened (Unicode version).
/// Implementation status: Partially implemented (delegates to the host browser's file dialog)
pub fn GetOpenFileNameW(lpofn_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("COMDLG32: GetOpenFileNameW({x})\n", .{lpofn_ptr});
    return commonFileDialogW(lpofn_ptr, false);
}

/// Creates a Save dialog box that lets the user specify the drive, directory, and name of a file to save (Unicode version).
/// Implementation status: Partially implemented (delegates to the host browser's file dialog)
pub fn GetSaveFileNameW(lpofn_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("COMDLG32: GetSaveFileNameW({x})\n", .{lpofn_ptr});
    return commonFileDialogW(lpofn_ptr, true);
}

var pending_color: ?u32 = null;

fn handleColorSelected(color: u32) void {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    pending_color = color;
}

/// Creates a Color dialog box that lets the user select a color.
/// Implementation status: Host color chooser (FLTK Fl_Color_Chooser / web).
pub fn ChooseColorA(lpcc_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (lpcc_ptr == 0) return 0;
    const cc = @as([*]u8, @ptrFromInt(trace.addr(lpcc_ptr)));
    const initial = @as(*align(1) const u32, @ptrCast(cc + 12)).*; // rgbResult
    if (trace.enable_tracing) trace.print("COMDLG32: ChooseColorA(initial={x})\n", .{initial});

    {
        dlg_result_mutex.lock();
        defer dlg_result_mutex.unlock();
        pending_color = null;
        dialog_cancelled = false;
    }
    renderer.openColorDialog(initial & 0xFFFFFF);

    const prev_color_cb = renderer.on_color_selected;
    const prev_cancel_cb = renderer.on_cancel_dialog;
    renderer.on_color_selected = &handleColorSelected;
    renderer.on_cancel_dialog = &handleCancelDialog;

    while (!colorDialogDone()) {
        @import("../../runtime.zig").pauseOrAdvance(10 * std.time.ns_per_ms);
    }

    renderer.on_color_selected = prev_color_cb;
    renderer.on_cancel_dialog = prev_cancel_cb;
    renderer.closeDialog();

    const color_opt: ?u32 = blk: {
        dlg_result_mutex.lock();
        defer dlg_result_mutex.unlock();
        break :blk pending_color;
    };
    if (color_opt) |color| {
        @as(*align(1) u32, @ptrCast(cc + 12)).* = color & 0xFFFFFF; // rgbResult
        if (trace.enable_tracing) trace.print("COMDLG32: ChooseColorA -> {x} (ok)\n", .{color});
        return 1;
    }
    if (trace.enable_tracing) trace.print("COMDLG32: ChooseColorA -> 0 (cancelled)\n", .{});
    return 0;
}

// CHOOSEFONT Flags (CF_*) and nFontType bits used by ChooseFontA/W.
const CF_LIMITSIZE: u32 = 0x00002000;
const SCREEN_FONTTYPE: u16 = 0x0001;
const BOLD_FONTTYPE: u16 = 0x0100;
const ITALIC_FONTTYPE: u16 = 0x0200;
// PRINTDLG Flags (PD_*) used by PrintDlgA/W.
const PD_RETURNDEFAULT: u32 = 0x00000400;
const PD_RETURNDC: u32 = 0x00000100;

var font_pending: bool = false;
var pending_font_face: [33]u8 = undefined;
var pending_font_len: usize = 0;
var pending_font_size: i32 = 0;
var pending_font_bold: bool = false;
var pending_font_italic: bool = false;

fn handleFontChosen(face: []const u8, size: i32, bold: bool, italic: bool) void {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    const n = @min(face.len, pending_font_face.len - 1);
    @memcpy(pending_font_face[0..n], face[0..n]);
    pending_font_face[n] = 0;
    pending_font_len = n;
    pending_font_size = size;
    pending_font_bold = bold;
    pending_font_italic = italic;
    font_pending = true;
}

/// Shared ChooseFont core. CHOOSEFONT layout (32-bit):
///   +0 lStructSize, +4 hwndOwner, +8 hDC, +12 lpLogFont, +16 iPointSize
///   (1/10 pt), +20 Flags, +24 rgbColors, +28 lCustData, +32 lpfnHook,
///   +36 lpTemplateName, +40 hInstance, +44 lpszStyle, +48 nFontType (u16),
///   +52 nSizeMin, +56 nSizeMax.
/// LOGFONT layout: +0 lfHeight, +4 lfWidth, +16 lfWeight, +20 lfItalic,
///   +28 lfFaceName (A: char[32], W: WCHAR[32]).
/// When `wide` is set the face name is read/written as UTF-16LE (LOGFONTW /
/// CHOOSEFONTW); the numeric fields are layout-identical.
fn commonChooseFont(lpcf_ptr: usize, wide: bool) i32 {
    if (lpcf_ptr == 0) return 0;
    const cf = @as([*]u8, @ptrFromInt(trace.addr(lpcf_ptr)));
    const lp_logfont = @as(*align(1) const u32, @ptrCast(cf + 12)).*;
    const ipt_size = @as(*align(1) const i32, @ptrCast(cf + 16)).*;
    const flags = @as(*align(1) const u32, @ptrCast(cf + 20)).*;
    const nsize_min = @as(*align(1) const i32, @ptrCast(cf + 52)).*;
    const nsize_max = @as(*align(1) const i32, @ptrCast(cf + 56)).*;

    var face_buf: [32]u8 = [_]u8{0} ** 32;
    var face_len: usize = 0;
    var lf_height: i32 = 0;
    var lf_weight: i32 = 0;
    var lf_italic: u8 = 0;
    if (lp_logfont != 0) {
        const lf = @as([*]const u8, @ptrFromInt(trace.addr(lp_logfont)));
        lf_height = @as(*align(1) const i32, @ptrCast(lf + 0)).*;
        lf_weight = @as(*align(1) const i32, @ptrCast(lf + 16)).*;
        lf_italic = @as(*align(1) const u8, @ptrCast(lf + 20)).*;
        if (wide) {
            const wface: [*]const u16 = @ptrCast(@alignCast(lf + 28));
            while (face_len < 32 and wface[face_len] != 0) : (face_len += 1) {
                face_buf[face_len] = if (wface[face_len] < 128) @intCast(wface[face_len]) else '?';
            }
        } else {
            while (face_len < 32 and lf[28 + face_len] != 0) : (face_len += 1) {
                face_buf[face_len] = lf[28 + face_len];
            }
        }
    }
    if (face_len == 0) {
        @memcpy(face_buf[0.."MS Sans Serif".len], "MS Sans Serif");
        face_len = "MS Sans Serif".len;
    }
    if (trace.enable_tracing) trace.print("COMDLG32: ChooseFont(face='{s}')\n", .{face_buf[0..face_len]});

    // Point size: prefer iPointSize (1/10 pt), else derive from lfHeight at 96 dpi.
    var pt: i32 = if (ipt_size > 0) @divTrunc(ipt_size, 10) else @divTrunc(-lf_height * 72, 96);
    if (pt < 1) pt = 1;
    if (pt > 72) pt = 72;
    if ((flags & CF_LIMITSIZE) != 0 and nsize_max >= nsize_min and nsize_max > 0) {
        const lo = @divTrunc(nsize_min, 10);
        const hi = @divTrunc(nsize_max, 10);
        if (pt < lo) pt = lo;
        if (pt > hi) pt = hi;
        if (pt < 1) pt = 1;
    }

    {
        dlg_result_mutex.lock();
        defer dlg_result_mutex.unlock();
        font_pending = false;
        dialog_cancelled = false;
    }
    renderer.openFontDialog(face_buf[0..face_len], pt, lf_weight >= 600, lf_italic != 0);

    const prev_font_cb = renderer.on_font_chosen;
    const prev_cancel_cb = renderer.on_cancel_dialog;
    renderer.on_font_chosen = &handleFontChosen;
    renderer.on_cancel_dialog = &handleCancelDialog;

    while (!fontDialogDone()) {
        @import("../../runtime.zig").pauseOrAdvance(10 * std.time.ns_per_ms);
    }

    renderer.on_font_chosen = prev_font_cb;
    renderer.on_cancel_dialog = prev_cancel_cb;
    renderer.closeDialog();

    if (font_pending) {
        // Write the chosen font back into the caller's LOGFONT.
        if (lp_logfont != 0) {
            const lf = @as([*]u8, @ptrFromInt(trace.addr(lp_logfont)));
            @as(*align(1) i32, @ptrCast(lf + 0)).* = -@divTrunc(pending_font_size * 96, 72); // lfHeight
            @as(*align(1) i32, @ptrCast(lf + 4)).* = 0; // lfWidth
            @as(*align(1) i32, @ptrCast(lf + 16)).* = if (pending_font_bold) 700 else 400; // lfWeight
            @as(*align(1) u8, @ptrCast(lf + 20)).* = if (pending_font_italic) 1 else 0; // lfItalic
            const flen = @min(pending_font_len, 31);
            if (wide) {
                const wface: [*]u16 = @ptrCast(@alignCast(lf + 28));
                for (0..flen) |i| wface[i] = pending_font_face[i];
                var wi: usize = flen;
                wface[wi] = 0;
                wi += 1;
                wface[wi] = 0; // keep the wide string double-terminated
                wi += 1;
                while (wi < 32) : (wi += 1) wface[wi] = 0;
            } else {
                const dst: [*]u8 = @ptrFromInt(trace.addr(lp_logfont) + 28);
                for (0..flen) |i| dst[i] = pending_font_face[i];
                dst[flen] = 0;
                var zi: usize = flen + 1;
                while (zi < 32) : (zi += 1) dst[zi] = 0;
            }
        }
        @as(*align(1) i32, @ptrCast(cf + 16)).* = pending_font_size * 10; // iPointSize
        var nft: u16 = SCREEN_FONTTYPE;
        if (pending_font_bold) nft |= BOLD_FONTTYPE;
        if (pending_font_italic) nft |= ITALIC_FONTTYPE;
        @as(*align(1) u16, @ptrCast(cf + 48)).* = nft; // nFontType
        if (trace.enable_tracing) trace.print("COMDLG32: ChooseFont -> '{s}' {d}pt (ok)\n", .{ pending_font_face[0..pending_font_len], pending_font_size });
        return 1;
    }
    if (trace.enable_tracing) trace.print("COMDLG32: ChooseFont -> 0 (cancelled)\n", .{});
    return 0;
}

/// Creates a Font dialog box that lets the user choose attributes for a logical font (ANSI).
/// Implementation status: Host font chooser (FLTK / web).
pub fn ChooseFontA(lpcf: usize) callconv(w32cc.WINAPI) i32 {
    return commonChooseFont(lpcf, false);
}

/// Creates a Font dialog box that lets the user choose attributes for a logical font (Unicode).
/// Implementation status: Host font chooser (FLTK / web).
pub fn ChooseFontW(lpcf: usize) callconv(w32cc.WINAPI) i32 {
    return commonChooseFont(lpcf, true);
}

// PrintDlg state: pending result + the print-pending flag (set by the host
// dialog callback, like the ChooseFont flow).
var print_pending: bool = false;
var pending_print_from: i32 = 1;
var pending_print_to: i32 = 1;
var pending_print_copies: i32 = 1;

fn handlePrintChosen(from_page: i32, to_page: i32, copies: i32) void {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    pending_print_from = from_page;
    pending_print_to = to_page;
    pending_print_copies = copies;
    print_pending = true;
}

/// Shared PrintDlg core. PRINTDLGA layout (32-bit):
///   +0 lStructSize, +4 hwndOwner, +8 hDevMode, +12 hDevNames, +16 hDC,
///   +20 Flags, +24 nFromPage (u16), +26 nToPage, +28 nMinPage, +30 nMaxPage,
///   +32 nCopies, +36 hInstance, +40 lCustData, +44 lpfnPrintHook, ...
/// `wide` selects PRINTDLGW (same numeric layout; the template-name string
/// pointers differ but we never read them).
fn commonPrintDlg(lppd_ptr: usize, wide: bool) i32 {
    _ = wide;
    if (lppd_ptr == 0) return 0;
    const pd = @as([*]u8, @ptrFromInt(trace.addr(lppd_ptr)));
    const flags = @as(*align(1) const u32, @ptrCast(pd + 20)).*;

    // PD_RETURNDEFAULT: report the default printer without showing the dialog.
    if ((flags & PD_RETURNDEFAULT) != 0) {
        if (trace.enable_tracing) trace.print("COMDLG32: PrintDlg -> 1 (default printer, no UI)\n", .{});
        return 1;
    }

    const from_page = @as(*align(1) const u16, @ptrCast(pd + 24)).*;
    const to_page = @as(*align(1) const u16, @ptrCast(pd + 26)).*;
    const min_page = @as(*align(1) const u16, @ptrCast(pd + 28)).*;
    const max_page = @as(*align(1) const u16, @ptrCast(pd + 30)).*;
    const copies = @as(*align(1) const u16, @ptrCast(pd + 32)).*;
    if (trace.enable_tracing) trace.print("COMDLG32: PrintDlg(pages={d}-{d}/{d}-{d}, copies={d})\n", .{ from_page, to_page, min_page, max_page, copies });

    {
        dlg_result_mutex.lock();
        defer dlg_result_mutex.unlock();
        print_pending = false;
        dialog_cancelled = false;
    }
    renderer.openPrintDialog(from_page, to_page, min_page, max_page, copies);

    const prev_print_cb = renderer.on_print_chosen;
    const prev_cancel_cb = renderer.on_cancel_dialog;
    renderer.on_print_chosen = &handlePrintChosen;
    renderer.on_cancel_dialog = &handleCancelDialog;

    while (!printDialogDone()) {
        @import("../../runtime.zig").pauseOrAdvance(10 * std.time.ns_per_ms);
    }

    renderer.on_print_chosen = prev_print_cb;
    renderer.on_cancel_dialog = prev_cancel_cb;
    renderer.closeDialog();

    if (print_pending) {
        @as(*align(1) u16, @ptrCast(pd + 24)).* = @intCast(pending_print_from); // nFromPage
        @as(*align(1) u16, @ptrCast(pd + 26)).* = @intCast(pending_print_to); // nToPage
        @as(*align(1) u16, @ptrCast(pd + 32)).* = @intCast(pending_print_copies); // nCopies
        if ((flags & PD_RETURNDC) != 0) {
            // Return a dummy printer DC (nonzero handle).
            @as(*align(1) u32, @ptrCast(pd + 16)).* = 1; // hDC
        }
        if (trace.enable_tracing) trace.print("COMDLG32: PrintDlg -> pages={d}-{d} copies={d} (ok)\n", .{ pending_print_from, pending_print_to, pending_print_copies });
        return 1;
    }
    if (trace.enable_tracing) trace.print("COMDLG32: PrintDlg -> 0 (cancelled)\n", .{});
    return 0;
}

/// Displays a Print dialog box or a Print Setup dialog box (ANSI).
/// Implementation status: Host print dialog (FLTK / web).
pub fn PrintDlgA(lppd: usize) callconv(w32cc.WINAPI) i32 {
    return commonPrintDlg(lppd, false);
}

/// Displays a Print dialog box or a Print Setup dialog box (Unicode).
/// Implementation status: Host print dialog (FLTK / web).
pub fn PrintDlgW(lppd: usize) callconv(w32cc.WINAPI) i32 {
    return commonPrintDlg(lppd, true);
}

/// Parse a Win32 ANSI lpstrFilter (double-null-terminated pairs: "desc\0pattern\0...\0\0")
/// Returns a JSON array string like: ["Text Documents (*.txt)","All Files (*.*)"]
fn parseFilterStringA(filter_ptr: u32) ?[]const u8 {
    const ptr = @as([*]const u8, @ptrFromInt(filter_ptr));
    var result: std.ArrayListUnmanaged(u8) = .empty;
    const alloc = std.heap.page_allocator;

    result.appendSlice(alloc, "[") catch return null;
    var pos: usize = 0;
    var first = true;
    const max_len: usize = 4096; // safety limit

    while (pos < max_len) {
        // Read description (null-terminated)
        const desc_start = pos;
        while (pos < max_len and ptr[pos] != 0) : (pos += 1) {}
        if (pos == desc_start) break; // empty string = end of list
        const desc = ptr[desc_start..pos];
        pos += 1;

        // Read pattern (null-terminated)
        const pat_start = pos;
        while (pos < max_len and ptr[pos] != 0) : (pos += 1) {}
        _ = ptr[pat_start..pos];
        pos += 1;

        if (!first) result.appendSlice(alloc, ",") catch {};
        first = false;
        result.appendSlice(alloc, "\"") catch {};
        // JSON-escape the description
        for (desc) |c| {
            if (c == '"') {
                result.appendSlice(alloc, "\\\"") catch {};
            } else if (c == '\\') {
                result.appendSlice(alloc, "\\\\") catch {};
            } else {
                result.append(alloc, c) catch {};
            }
        }
        result.appendSlice(alloc, "\"") catch {};
    }

    result.appendSlice(alloc, "]") catch {};
    return result.items;
}

/// Parse a Win32 Wide lpstrFilter (double-null-terminated UTF-16LE pairs)
fn parseFilterStringW(filter_ptr: u32) ?[]const u8 {
    const ptr = @as([*]const u16, @ptrFromInt(filter_ptr));
    var result: std.ArrayListUnmanaged(u8) = .empty;
    const alloc = std.heap.page_allocator;

    result.appendSlice(alloc, "[") catch return null;
    var pos: usize = 0;
    var first = true;
    const max_len: usize = 4096;

    while (pos < max_len) {
        // Read description
        const desc_start = pos;
        while (pos < max_len and ptr[pos] != 0) : (pos += 1) {}
        if (pos == desc_start) break;
        const desc = ptr[desc_start..pos];
        pos += 1;

        // Read pattern
        const pat_start = pos;
        while (pos < max_len and ptr[pos] != 0) : (pos += 1) {}
        _ = ptr[pat_start..pos];
        pos += 1;

        if (!first) result.appendSlice(alloc, ",") catch {};
        first = false;
        result.appendSlice(alloc, "\"") catch {};
        for (desc) |wc| {
            const c: u8 = if (wc < 128) @intCast(wc) else '?';
            if (c == '"') {
                result.appendSlice(alloc, "\\\"") catch {};
            } else if (c == '\\') {
                result.appendSlice(alloc, "\\\\") catch {};
            } else {
                result.append(alloc, c) catch {};
            }
        }
        result.appendSlice(alloc, "\"") catch {};
    }

    result.appendSlice(alloc, "]") catch {};
    return result.items;
}

// --- FindTextA / ReplaceTextA (modeless find/replace dialog) ---
// FINDREPLACEA layout (32-bit): +0 lStructSize, +4 hwndOwner, +8 hInstance,
// +12 Flags, +16 lpstrFindWhat, +20 lpstrReplaceWith, +24 wFindWhatLen (u16),
// +26 wReplaceWithLen (u16), +28 lCustData, +32 lpfnHook, +36 lpTemplateName.
// The dialog is MODELESS: FindTextA/ReplaceTextA return a dialog hwnd and the
// app keeps pumping messages. When the user acts, we fill the caller's
// FINDREPLACEA and post the registered FINDMSGSTRING message to the owner.
const FR_DOWN: u32 = 0x00000001;
const FR_MATCHCASE: u32 = 0x00000004;
const FR_FINDNEXT: u32 = 0x00000008;
const FR_REPLACE: u32 = 0x00000010;
const FR_REPLACEALL: u32 = 0x00000020;

var find_pfr: usize = 0; // guest FINDREPLACEA pointer (kept alive by the app)
var find_owner: usize = 0;
var find_msg: u32 = 0; // registered FINDMSGSTRING id
var find_hwnd: usize = 0;

fn findWriteBackAndNotify(action: []const u8, find_text: []const u8, replace_text: []const u8, match_case: bool, search_down: bool) void {
    if (find_pfr == 0) return;
    if (std.mem.eql(u8, action, "close")) {
        renderer.closeDialog();
        return;
    }
    const pfr = @as([*]u8, @ptrFromInt(trace.addr(find_pfr)));
    const flags = @as(*align(1) const u32, @ptrCast(pfr + 12)).*;
    const lpstr_find = @as(*align(1) const u32, @ptrCast(pfr + 16)).*;
    const lpstr_repl = @as(*align(1) const u32, @ptrCast(pfr + 20)).*;
    const find_cap = @as(*align(1) const u16, @ptrCast(pfr + 24)).*;
    const repl_cap = @as(*align(1) const u16, @ptrCast(pfr + 26)).*;

    if (lpstr_find != 0 and find_text.len > 0) {
        const dst: [*]u8 = @ptrFromInt(trace.addr(lpstr_find));
        const n = @min(find_text.len, @as(usize, find_cap) - 1);
        @memcpy(dst[0..n], find_text[0..n]);
        dst[n] = 0;
    }
    if (lpstr_repl != 0 and replace_text.len > 0) {
        const dst: [*]u8 = @ptrFromInt(trace.addr(lpstr_repl));
        const n = @min(replace_text.len, @as(usize, repl_cap) - 1);
        @memcpy(dst[0..n], replace_text[0..n]);
        dst[n] = 0;
    }

    var new_flags: u32 = if (search_down) FR_DOWN else 0;
    if (match_case) new_flags |= FR_MATCHCASE;
    if (std.mem.eql(u8, action, "replace")) {
        new_flags |= FR_REPLACE;
    } else if (std.mem.eql(u8, action, "replace_all")) {
        new_flags |= FR_REPLACEALL;
    } else {
        new_flags |= FR_FINDNEXT;
    }
    // Preserve the app's option flags (FR_NOUPDOWN etc.) outside the action bits.
    new_flags |= flags & ~(FR_FINDNEXT | FR_REPLACE | FR_REPLACEALL | FR_MATCHCASE | FR_DOWN);
    @as(*align(1) u32, @ptrCast(pfr + 12)).* = new_flags;

    if (find_owner != 0 and find_msg != 0) {
        const msg_mod = @import("../user32/message.zig");
        _ = msg_mod.PostMessageA(find_owner, find_msg, 0, @as(isize, @bitCast(find_pfr)));
        if (trace.enable_tracing) trace.print("COMDLG32: Find/Replace -> FINDMSG to owner {x} ('{s}')\n", .{ find_owner, find_text });
    }
}

fn commonFindText(lpfr_ptr: usize, is_replace: bool) usize {
    if (lpfr_ptr == 0) return 0;
    const pfr = @as([*]u8, @ptrFromInt(trace.addr(lpfr_ptr)));
    const owner = @as(*align(1) const u32, @ptrCast(pfr + 4)).*;
    const lpstr_find = @as(*align(1) const u32, @ptrCast(pfr + 16)).*;
    const lpstr_repl = @as(*align(1) const u32, @ptrCast(pfr + 20)).*;

    // Initial values from the caller's struct (guest strings).
    var find_buf: [256]u8 = [_]u8{0} ** 256;
    var find_len: usize = 0;
    if (lpstr_find != 0) {
        const s = trace.c_span(@as(usize, @intCast(lpstr_find)));
        find_len = @min(s.len, 255);
        @memcpy(find_buf[0..find_len], s[0..find_len]);
    }
    var repl_buf: [256]u8 = [_]u8{0} ** 256;
    var repl_len: usize = 0;
    if (lpstr_repl != 0 and is_replace) {
        const s = trace.c_span(@as(usize, @intCast(lpstr_repl)));
        repl_len = @min(s.len, 255);
        @memcpy(repl_buf[0..repl_len], s[0..repl_len]);
    }

    find_pfr = lpfr_ptr;
    find_owner = owner;
    if (find_msg == 0) {
        const class = @import("../user32/class.zig");
        find_msg = class.RegisterWindowMessageA(@intFromPtr("commdlg_FindReplace"));
    }
    find_hwnd += 1;
    if (find_hwnd == 0) find_hwnd = 1;
    renderer.on_find_action = &findWriteBackAndNotify;
    renderer.openFindDialog(find_buf[0..find_len], repl_buf[0..repl_len], is_replace);
    if (trace.enable_tracing) trace.print("COMDLG32: {s} -> hwnd={x} owner={x}\n", .{ if (is_replace) "ReplaceTextA" else "FindTextA", find_hwnd, owner });
    return find_hwnd;
}

/// Creates a modeless Find dialog (FindTextA).
/// Implementation status: Host find dialog (web / FLTK) + FINDMSG delivery.
pub fn FindTextA(lpfr: usize) callconv(w32cc.WINAPI) usize {
    return commonFindText(lpfr, false);
}

/// Creates a modeless Replace dialog (ReplaceTextA).
/// Implementation status: Host find dialog (web / FLTK) + FINDMSG delivery.
pub fn ReplaceTextA(lpfr: usize) callconv(w32cc.WINAPI) usize {
    return commonFindText(lpfr, true);
}

/// Stub function returning 0.
/// Implementation status: Stub
pub fn stub_ret0_0() callconv(w32cc.WINAPI) u32 {
    return 0;
}
/// Stub function returning 0 with one argument.
/// Implementation status: Stub
pub fn stub_ret0_1(a: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    return 0;
}

// --- PageSetupDlgA/W ---
// PAGESETUPDLG layout (32-bit): +0 lStructSize, +4 hwndOwner, +8 hDevMode,
// +12 hDevNames, +16 Flags, +20 ptPaperSize (POINT), +28 rtMinMargin (RECT),
// +44 rtMargin (RECT), +60 hInstance, +64 lCustData, ...
// Margins/paper are in thousandths of an inch (default), 1/100 mm
// (PSD_INHUNDREDTHSOFMILLIMETERS) or 1/10 mm (PSD_INTENT? no — PSD_ units).
const PSD_MARGINS: u32 = 0x00000002;
const PSD_INHUNDREDTHSOFMILLIMETERS: u32 = 0x00000008;
const PSD_RETURNDEFAULT: u32 = 0x00000400;

var page_setup_pending: bool = false;
var pending_ps_left: i32 = 0;
var pending_ps_top: i32 = 0;
var pending_ps_right: i32 = 0;
var pending_ps_bottom: i32 = 0;
var pending_ps_paper_w: i32 = 8500;
var pending_ps_paper_h: i32 = 11000;
var pending_ps_orientation: i32 = 0;

fn handlePageSetupChosen(left: i32, top: i32, right: i32, bottom: i32, paper_w: i32, paper_h: i32, orientation: i32) void {
    dlg_result_mutex.lock();
    defer dlg_result_mutex.unlock();
    pending_ps_left = left;
    pending_ps_top = top;
    pending_ps_right = right;
    pending_ps_bottom = bottom;
    pending_ps_paper_w = paper_w;
    pending_ps_paper_h = paper_h;
    pending_ps_orientation = orientation;
    page_setup_pending = true;
}

/// Shared PageSetupDlg core.
fn commonPageSetupDlg(lppsd_ptr: usize, wide: bool) i32 {
    _ = wide;
    if (lppsd_ptr == 0) return 0;
    const psd = @as([*]u8, @ptrFromInt(trace.addr(lppsd_ptr)));
    const flags = @as(*align(1) const u32, @ptrCast(psd + 16)).*;

    if ((flags & PSD_RETURNDEFAULT) != 0) {
        if (trace.enable_tracing) trace.print("COMDLG32: PageSetupDlg -> 1 (default, no UI)\n", .{});
        return 1;
    }

    // Initial margins (rtMargin at +44, 4×i32) + paper size (ptPaperSize +20).
    const init_left = @as(*align(1) const i32, @ptrCast(psd + 44)).*;
    const init_top = @as(*align(1) const i32, @ptrCast(psd + 48)).*;
    const init_right = @as(*align(1) const i32, @ptrCast(psd + 52)).*;
    const init_bottom = @as(*align(1) const i32, @ptrCast(psd + 56)).*;
    const paper_w = @as(*align(1) const i32, @ptrCast(psd + 20)).*;
    const paper_h = @as(*align(1) const i32, @ptrCast(psd + 24)).*;
    // Orientation: from the DEVMODE dmOrientation, which we don't track — the
    // host dialog defaults to portrait (0); landscape = 1.
    const units_label: []const u8 = if ((flags & PSD_INHUNDREDTHSOFMILLIMETERS) != 0) "0.01 mm" else "0.001 in";
    if (trace.enable_tracing) trace.print("COMDLG32: PageSetupDlg(margins={d},{d},{d},{d} paper={d}x{d})\n", .{ init_left, init_top, init_right, init_bottom, paper_w, paper_h });

    {
        dlg_result_mutex.lock();
        defer dlg_result_mutex.unlock();
        page_setup_pending = false;
        dialog_cancelled = false;
    }
    renderer.openPageSetupDialog(init_left, init_top, init_right, init_bottom, paper_w, paper_h, 0, units_label);

    const prev_cb = renderer.on_page_setup_chosen;
    const prev_cancel_cb = renderer.on_cancel_dialog;
    renderer.on_page_setup_chosen = &handlePageSetupChosen;
    renderer.on_cancel_dialog = &handleCancelDialog;

    while (!pageSetupDialogDone()) {
        @import("../../runtime.zig").pauseOrAdvance(10 * std.time.ns_per_ms);
    }

    renderer.on_page_setup_chosen = prev_cb;
    renderer.on_cancel_dialog = prev_cancel_cb;
    renderer.closeDialog();

    if (page_setup_pending) {
        @as(*align(1) i32, @ptrCast(psd + 44)).* = pending_ps_left;
        @as(*align(1) i32, @ptrCast(psd + 48)).* = pending_ps_top;
        @as(*align(1) i32, @ptrCast(psd + 52)).* = pending_ps_right;
        @as(*align(1) i32, @ptrCast(psd + 56)).* = pending_ps_bottom;
        @as(*align(1) i32, @ptrCast(psd + 20)).* = pending_ps_paper_w;
        @as(*align(1) i32, @ptrCast(psd + 24)).* = pending_ps_paper_h;
        @as(*align(1) u32, @ptrCast(psd + 16)).* = flags | PSD_MARGINS;
        if (trace.enable_tracing) trace.print("COMDLG32: PageSetupDlg -> margins={d},{d},{d},{d} (ok)\n", .{ pending_ps_left, pending_ps_top, pending_ps_right, pending_ps_bottom });
        return 1;
    }
    if (trace.enable_tracing) trace.print("COMDLG32: PageSetupDlg -> 0 (cancelled)\n", .{});
    return 0;
}

/// Creates a Page Setup dialog box (ANSI).
/// Implementation status: Host page-setup dialog (FLTK / web).
pub fn PageSetupDlgA(lppsd: usize) callconv(w32cc.WINAPI) i32 {
    return commonPageSetupDlg(lppsd, false);
}

/// Creates a Page Setup dialog box (Unicode).
/// Implementation status: Host page-setup dialog (FLTK / web).
pub fn PageSetupDlgW(lppsd: usize) callconv(w32cc.WINAPI) i32 {
    return commonPageSetupDlg(lppsd, true);
}
/// Stub function returning 0 with three arguments.
/// Implementation status: Stub
pub fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    _ = c;
    return 0;
}
