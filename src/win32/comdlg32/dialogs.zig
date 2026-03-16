const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const renderer = @import("../../gui/renderer.zig");
const kernel32 = @import("../kernel32.zig");

var dialog_cancelled: bool = false;
var pending_file_path: ?[]const u8 = null;

fn handleCancelDialog() void {
    dialog_cancelled = true;
}

fn handleFileUploaded(path: []const u8) void {
    pending_file_path = path;
}

fn commonFileDialogA(lpofn_ptr: usize, is_save: bool) i32 {
    pending_file_path = null;
    dialog_cancelled = false;

    var filters_json: ?[]const u8 = null;
    if (lpofn_ptr != 0) {
        const ofn = @as(*w32.OPENFILENAMEA, @ptrFromInt(lpofn_ptr));
        if (ofn.lpstrFilter != 0) {
            filters_json = parseFilterStringA(ofn.lpstrFilter);
        }
    }
    defer if (filters_json) |f| std.heap.page_allocator.free(f);

    renderer.openFileDialog(filters_json, is_save);

    const prev_file_cb = renderer.on_file_uploaded;
    const prev_cancel_cb = renderer.on_cancel_dialog;
    renderer.on_file_uploaded = &handleFileUploaded;
    renderer.on_cancel_dialog = &handleCancelDialog;

    while (pending_file_path == null and !dialog_cancelled) {
        std.Thread.sleep(10 * 1000 * 1000); // 10ms
    }

    renderer.on_file_uploaded = prev_file_cb;
    renderer.on_cancel_dialog = prev_cancel_cb;

    renderer.closeDialog();

    if (pending_file_path) |path| {
        if (lpofn_ptr != 0) {
            const ofn = @as(*w32.OPENFILENAMEA, @ptrFromInt(lpofn_ptr));

            if (ofn.lpstrFile != 0 and ofn.nMaxFile > path.len) {
                const lpstrFile = @as([*]u8, @ptrFromInt(ofn.lpstrFile));
                for (0..path.len) |i| {
                    lpstrFile[i] = if (path[i] == '/') '\\' else path[i];
                }
                var final_len = path.len;

                if (ofn.lpstrDefExt != 0) {
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
                        const def_ext = trace.c_span(ofn.lpstrDefExt);
                        if (def_ext.len > 0 and final_len + 1 + def_ext.len < ofn.nMaxFile) {
                            lpstrFile[final_len] = '.';
                            @memcpy(lpstrFile[final_len + 1 .. final_len + 1 + def_ext.len], def_ext);
                            final_len += 1 + def_ext.len;
                        }
                    }
                }
                lpstrFile[final_len] = 0;

                var file_offset: u16 = 0;
                var ext_offset: u16 = 0;
                for (0..final_len) |i| {
                    if (lpstrFile[i] == '/' or lpstrFile[i] == '\\') {
                        file_offset = @intCast(i + 1);
                    }
                    if (lpstrFile[i] == '.') {
                        ext_offset = @intCast(i + 1);
                    }
                }

                ofn.nFileOffset = file_offset;
                ofn.nFileExtension = ext_offset;

                if (ofn.lpstrFileTitle != 0 and ofn.nMaxFileTitle > 0) {
                    const title_len = final_len - file_offset;
                    if (ofn.nMaxFileTitle > title_len) {
                        const lpstrFileTitle = @as([*]u8, @ptrFromInt(ofn.lpstrFileTitle));
                        @memcpy(lpstrFileTitle[0..title_len], lpstrFile[file_offset .. file_offset + title_len]);
                        lpstrFileTitle[title_len] = 0;
                    }
                }

                if ((ofn.Flags & w32.OFN_ENABLEHOOK) != 0) {
                    if (ofn.lpfnHook != 0) {
                        const hook_fn = @as(*const fn (usize, u32, usize, usize) callconv(w32cc.WINAPI) isize, @ptrFromInt(ofn.lpfnHook));
                        _ = hook_fn(0xBEEF, w32.WM_INITDIALOG, 0, lpofn_ptr);
                    }
                }

                pending_file_path = null;
                return 1;
            }
        }
    }

    return 0;
}

/// Creates an Open dialog box that lets the user specify the drive, directory, and the name of a file or set of files to be opened.
/// Implementation status: Partially implemented (delegates to the host browser's file dialog).
pub fn GetOpenFileNameA(lpofn_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("COMDLG32: GetOpenFileNameA({x})\n", .{lpofn_ptr});
    return commonFileDialogA(lpofn_ptr, false);
}

/// Creates a Save dialog box that lets the user specify the drive, directory, and name of a file to save.
/// Implementation status: Partially implemented (delegates to the host browser's file dialog).
pub fn GetSaveFileNameA(lpofn_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("COMDLG32: GetSaveFileNameA({x})\n", .{lpofn_ptr});
    return commonFileDialogA(lpofn_ptr, true);
}

fn commonFileDialogW(lpofn_ptr: usize, is_save: bool) i32 {
    pending_file_path = null;
    dialog_cancelled = false;

    var filters_json: ?[]const u8 = null;
    if (lpofn_ptr != 0) {
        const ofn = @as(*w32.OPENFILENAMEA, @ptrFromInt(lpofn_ptr));
        if (ofn.lpstrFilter != 0) {
            filters_json = parseFilterStringW(ofn.lpstrFilter);
        }
    }
    defer if (filters_json) |f| std.heap.page_allocator.free(f);

    renderer.openFileDialog(filters_json, is_save);

    const prev_file_cb = renderer.on_file_uploaded;
    const prev_cancel_cb = renderer.on_cancel_dialog;
    renderer.on_file_uploaded = &handleFileUploaded;
    renderer.on_cancel_dialog = &handleCancelDialog;

    while (pending_file_path == null and !dialog_cancelled) {
        std.Thread.sleep(10 * 1000 * 1000); // 10ms
    }

    renderer.on_file_uploaded = prev_file_cb;
    renderer.on_cancel_dialog = prev_cancel_cb;

    renderer.closeDialog();

    if (pending_file_path) |path| {
        if (lpofn_ptr != 0) {
            const ofn = @as(*w32.OPENFILENAMEA, @ptrFromInt(lpofn_ptr));

            if (ofn.lpstrFile != 0 and ofn.nMaxFile > path.len) {
                const lpstrFile = @as([*]u16, @ptrFromInt(ofn.lpstrFile));
                for (0..path.len) |i| {
                    lpstrFile[i] = if (path[i] == '/') '\\' else path[i];
                }
                var final_len = path.len;

                if (ofn.lpstrDefExt != 0) {
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
                        const def_ext_w = @as([*]const u16, @ptrFromInt(ofn.lpstrDefExt));
                        var ext_len: usize = 0;
                        while (ext_len < 32 and def_ext_w[ext_len] != 0) : (ext_len += 1) {}
                        if (ext_len > 0 and final_len + 1 + ext_len < ofn.nMaxFile) {
                            lpstrFile[final_len] = '.';
                            for (0..ext_len) |i| {
                                lpstrFile[final_len + 1 + i] = def_ext_w[i];
                            }
                            final_len += 1 + ext_len;
                        }
                    }
                }
                lpstrFile[final_len] = 0;

                var file_offset: u16 = 0;
                var ext_offset: u16 = 0;
                for (0..final_len) |i| {
                    if (lpstrFile[i] == '/' or lpstrFile[i] == '\\') {
                        file_offset = @intCast(i + 1);
                    }
                    if (lpstrFile[i] == '.') {
                        ext_offset = @intCast(i + 1);
                    }
                }

                ofn.nFileOffset = file_offset;
                ofn.nFileExtension = ext_offset;

                if (ofn.lpstrFileTitle != 0 and ofn.nMaxFileTitle > 0) {
                    const title_len = final_len - file_offset;
                    if (ofn.nMaxFileTitle > title_len) {
                        const lpstrFileTitle = @as([*]u16, @ptrFromInt(ofn.lpstrFileTitle));
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

                pending_file_path = null;
                return 1;
            }
        }
    }

    return 0;
}

/// Creates an Open dialog box that lets the user specify the drive, directory, and the name of a file or set of files to be opened (Unicode version).
/// Implementation status: Partially implemented (delegates to the host browser's file dialog).
pub fn GetOpenFileNameW(lpofn_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("COMDLG32: GetOpenFileNameW({x})\n", .{lpofn_ptr});
    return commonFileDialogW(lpofn_ptr, false);
}

/// Creates a Save dialog box that lets the user specify the drive, directory, and name of a file to save (Unicode version).
/// Implementation status: Partially implemented (delegates to the host browser's file dialog).
pub fn GetSaveFileNameW(lpofn_ptr: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("COMDLG32: GetSaveFileNameW({x})\n", .{lpofn_ptr});
    return commonFileDialogW(lpofn_ptr, true);
}

/// Creates a Color dialog box that lets the user select a color.
/// Implementation status: Stub (always returns cancelled).
pub fn stub_ChooseColorA(lpcc: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpcc;
    if (trace.enable_tracing) trace.print("COMDLG32: ChooseColorA -> 0 (cancelled)\n", .{});
    return 0;
}

/// Creates a Font dialog box that lets the user choose attributes for a logical font.
/// Implementation status: Stub (always returns cancelled).
pub fn stub_ChooseFontA(lpcf: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpcf;
    if (trace.enable_tracing) trace.print("COMDLG32: ChooseFontA -> 0 (cancelled)\n", .{});
    return 0;
}

/// Displays a Print dialog box or a Print Setup dialog box.
/// Implementation status: Stub (always returns cancelled).
pub fn stub_PrintDlgA(lppd: usize) callconv(w32cc.WINAPI) i32 {
    _ = lppd;
    if (trace.enable_tracing) trace.print("COMDLG32: PrintDlgA -> 0 (cancelled)\n", .{});
    return 0;
}

/// Parse a Win32 ANSI lpstrFilter (double-null-terminated pairs: "desc\0pattern\0...\0\0")
/// Returns a JSON array string like: ["Text Documents (*.txt)","All Files (*.*)"]
fn parseFilterStringA(filter_ptr: u32) ?[]const u8 {
    const ptr = @as([*]const u8, @ptrFromInt(filter_ptr));
    var result: std.ArrayListUnmanaged(u8) = .{};
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
    var result: std.ArrayListUnmanaged(u8) = .{};
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

/// Stub function returning 0.
/// Implementation status: Stub.
pub fn stub_ret0_0() callconv(w32cc.WINAPI) u32 {
    return 0;
}
/// Stub function returning 0 with one argument.
/// Implementation status: Stub.
pub fn stub_ret0_1(a: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    return 0;
}
/// Stub function returning 0 with three arguments.
/// Implementation status: Stub.
pub fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    _ = c;
    return 0;
}
