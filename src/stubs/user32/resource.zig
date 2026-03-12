const trace = @import("../../trace.zig");
const pe = @import("../../pe.zig");
const kernel32 = @import("../kernel32.zig");
const renderer = @import("../../gui/renderer.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn stub_LoadIconA(hInstance: usize, lpIconName: usize) callconv(w32cc.WINAPI) usize {
    var hInst = hInstance;
    if (hInst == 0) {
        hInst = kernel32.main_module_handle;
    }

    var mod: ?*@import("../../loader/module.zig").Module = null;
    if (kernel32.global_env) |genv| {
        var it = genv.registry.modules.valueIterator();
        while (it.next()) |m| {
            if (@intFromPtr(m.*.mapped_memory.ptr) == hInst) {
                mod = m.*;
                break;
            }
        }
    }

    if (mod) |m| {
        if (lpIconName <= 0xFFFF) {
            if (trace.enable_tracing) trace.print("USER32: LoadIconA(ID={d})\n", .{lpIconName});
            const icon_parser = @import("../../loader/icon_parser.zig");
            if (icon_parser.parseIconResource(m.allocator, m, @as(u32, @intCast(lpIconName))) catch null) |json_str| {
                renderer.setIcon(json_str);
            }
        } else {
            if (trace.enable_tracing) trace.print("USER32: LoadIconA(Name={s})\n", .{trace.c_span(lpIconName)});
        }
    }

    return 0x12345678; // Dummy handle
}

pub fn stub_LoadCursorA(hInstance: usize, lpCursorName: usize) callconv(w32cc.WINAPI) usize {
    _ = hInstance;
    _ = lpCursorName;
    if (trace.enable_tracing) trace.print("USER32: LoadCursorA\n", .{});
    return 0x87654321; // Dummy handle
}

fn loadStringFromPE(hInst: usize, uID: u32, out_buf: [*]u8, max_len: usize) usize {
    if (hInst == 0) return 0;
    const dos_header = @as(*const pe.IMAGE_DOS_HEADER, @ptrFromInt(hInst));
    if (dos_header.e_magic != pe.IMAGE_DOS_SIGNATURE) return 0;

    const nt_headers = @as(*const pe.IMAGE_NT_HEADERS32, @ptrFromInt(hInst + dos_header.e_lfanew));
    if (nt_headers.Signature != pe.IMAGE_NT_SIGNATURE) return 0;

    const res_dir_info = nt_headers.OptionalHeader.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_RESOURCE];
    if (res_dir_info.VirtualAddress == 0 or res_dir_info.Size == 0) {
        if (trace.enable_tracing) trace.print("USER32: No resource dir\n", .{});
        return 0;
    }

    const res_base = hInst + res_dir_info.VirtualAddress;
    const root_dir = @as(*const pe.IMAGE_RESOURCE_DIRECTORY, @ptrFromInt(res_base));

    const find_entry = struct {
        fn find(dir: *const pe.IMAGE_RESOURCE_DIRECTORY, id: u32) ?u32 {
            const num_named = dir.NumberOfNamedEntries;
            const num_id = dir.NumberOfIdEntries;
            const entries = @as([*]const pe.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrFromInt(@intFromPtr(dir) + @sizeOf(pe.IMAGE_RESOURCE_DIRECTORY)));

            for (0..num_id) |i| {
                const entry = entries[num_named + i];
                if (entry.NameId == id) {
                    return entry.OffsetToData;
                }
            }
            return null;
        }
    }.find;

    const type_offset = find_entry(root_dir, 6) orelse {
        if (trace.enable_tracing) trace.print("USER32: No RT_STRING\n", .{});
        return 0;
    };
    if ((type_offset & 0x80000000) == 0) return 0;

    const name_dir = @as(*const pe.IMAGE_RESOURCE_DIRECTORY, @ptrFromInt(res_base + (type_offset & 0x7FFFFFFF)));

    const block_id = (uID >> 4) + 1;
    const lang_offset = find_entry(name_dir, block_id) orelse {
        if (trace.enable_tracing) trace.print("USER32: No block ID {d}\n", .{block_id});
        return 0;
    };
    if ((lang_offset & 0x80000000) == 0) return 0;

    const lang_dir = @as(*const pe.IMAGE_RESOURCE_DIRECTORY, @ptrFromInt(res_base + (lang_offset & 0x7FFFFFFF)));

    if (lang_dir.NumberOfIdEntries == 0) return 0;
    const entries = @as([*]const pe.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrFromInt(@intFromPtr(lang_dir) + @sizeOf(pe.IMAGE_RESOURCE_DIRECTORY)));
    const data_entry_offset = entries[lang_dir.NumberOfNamedEntries].OffsetToData;
    if ((data_entry_offset & 0x80000000) != 0) return 0;

    const data_entry = @as(*const pe.IMAGE_RESOURCE_DATA_ENTRY, @ptrFromInt(res_base + data_entry_offset));

    var str_ptr = hInst + data_entry.OffsetToData;

    const string_index = uID & 0xF;

    for (0..string_index) |_| {
        if (str_ptr < hInst or str_ptr > hInst + 0x1000000) return 0;
        const len = @as(*const u16, @ptrFromInt(str_ptr)).*;
        str_ptr += 2 + (len * 2);
    }

    if (str_ptr < hInst or str_ptr > hInst + 0x1000000) return 0;
    const target_len = @as(*const u16, @ptrFromInt(str_ptr)).*;
    if (target_len == 0) return 0;

    str_ptr += 2;
    const wide_chars = @as([*]const u16, @ptrFromInt(str_ptr));

    const copy_len = @min(@as(usize, @intCast(target_len)), max_len - 1);
    for (0..copy_len) |i| {
        out_buf[i] = @intCast(wide_chars[i] & 0xFF);
    }
    out_buf[copy_len] = 0;
    return copy_len;
}

pub fn stub_LoadStringA(hInstance: ?*anyopaque, uID: u32, lpBuffer_ptr: usize, nBufferMax: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) {
        trace.print("USER32: LoadStringA(hInst={*}, uID={d}, buffer={x}, max={d})\n", .{ hInstance, uID, lpBuffer_ptr, nBufferMax });
    }
    if (nBufferMax > 0 and lpBuffer_ptr > 0x10000) {
        const lpBuffer = @as([*]u8, @ptrFromInt(lpBuffer_ptr));
        const max_len = @as(usize, @intCast(nBufferMax));

        var hInst: usize = if (hInstance != null) @intFromPtr(hInstance.?) else 0;
        if (hInst == 0) hInst = kernel32.main_module_handle;

        if (hInst != 0) {
            const len = loadStringFromPE(hInst, uID, lpBuffer, max_len);
            if (len > 0) {
                if (trace.enable_tracing) {
                    trace.print("USER32: loaded from PE -> '{s}'\n", .{lpBuffer[0..len]});
                }
                return @intCast(len);
            }
        }

        lpBuffer[0] = 0;
    }
    return 0;
}

pub fn stub_LoadStringW(hInstance: ?*anyopaque, uID: u32, lpBuffer_ptr: usize, nBufferMax: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) {
        trace.print("USER32: LoadStringW(hInst={*}, uID={d}, buffer={x}, max={d})\n", .{ hInstance, uID, lpBuffer_ptr, nBufferMax });
    }
    if (nBufferMax > 0 and lpBuffer_ptr > 0x10000) {
        const lpBuffer = @as([*]u16, @ptrFromInt(lpBuffer_ptr));
        const max_len = @as(usize, @intCast(nBufferMax));

        var hInst: usize = if (hInstance != null) @intFromPtr(hInstance.?) else 0;
        if (hInst == 0) hInst = kernel32.main_module_handle;

        if (hInst != 0) {
            // Reuse the PE resource lookup but output wide chars
            const len = loadStringFromPEW(hInst, uID, lpBuffer, max_len);
            if (len > 0) return @intCast(len);
        }

        lpBuffer[0] = 0;
    }
    return 0;
}

fn loadStringFromPEW(hInst: usize, uID: u32, out_buf: [*]u16, max_len: usize) usize {
    if (hInst == 0) return 0;
    const dos_header = @as(*const pe.IMAGE_DOS_HEADER, @ptrFromInt(hInst));
    if (dos_header.e_magic != pe.IMAGE_DOS_SIGNATURE) return 0;

    const nt_headers = @as(*const pe.IMAGE_NT_HEADERS32, @ptrFromInt(hInst + dos_header.e_lfanew));
    if (nt_headers.Signature != pe.IMAGE_NT_SIGNATURE) return 0;

    const res_dir_info = nt_headers.OptionalHeader.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_RESOURCE];
    if (res_dir_info.VirtualAddress == 0 or res_dir_info.Size == 0) return 0;

    const res_base = hInst + res_dir_info.VirtualAddress;
    const root_dir = @as(*const pe.IMAGE_RESOURCE_DIRECTORY, @ptrFromInt(res_base));

    const find_entry_w = struct {
        fn find(dir: *const pe.IMAGE_RESOURCE_DIRECTORY, id: u32) ?u32 {
            const num_named = dir.NumberOfNamedEntries;
            const num_id = dir.NumberOfIdEntries;
            const entries = @as([*]const pe.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrFromInt(@intFromPtr(dir) + @sizeOf(pe.IMAGE_RESOURCE_DIRECTORY)));
            for (0..num_id) |i| {
                const entry = entries[num_named + i];
                if (entry.NameId == id) return entry.OffsetToData;
            }
            return null;
        }
    }.find;

    const type_offset = find_entry_w(root_dir, 6) orelse return 0;
    if ((type_offset & 0x80000000) == 0) return 0;

    const name_dir = @as(*const pe.IMAGE_RESOURCE_DIRECTORY, @ptrFromInt(res_base + (type_offset & 0x7FFFFFFF)));
    const block_id = (uID >> 4) + 1;
    const lang_offset = find_entry_w(name_dir, block_id) orelse return 0;
    if ((lang_offset & 0x80000000) == 0) return 0;

    const lang_dir = @as(*const pe.IMAGE_RESOURCE_DIRECTORY, @ptrFromInt(res_base + (lang_offset & 0x7FFFFFFF)));
    if (lang_dir.NumberOfIdEntries == 0) return 0;
    const entries = @as([*]const pe.IMAGE_RESOURCE_DIRECTORY_ENTRY, @ptrFromInt(@intFromPtr(lang_dir) + @sizeOf(pe.IMAGE_RESOURCE_DIRECTORY)));
    const data_entry_offset = entries[lang_dir.NumberOfNamedEntries].OffsetToData;
    if ((data_entry_offset & 0x80000000) != 0) return 0;

    const data_entry = @as(*const pe.IMAGE_RESOURCE_DATA_ENTRY, @ptrFromInt(res_base + data_entry_offset));
    var str_ptr = hInst + data_entry.OffsetToData;
    const string_index = uID & 0xF;

    for (0..string_index) |_| {
        if (str_ptr < hInst or str_ptr > hInst + 0x1000000) return 0;
        const len = @as(*const u16, @ptrFromInt(str_ptr)).*;
        str_ptr += 2 + (len * 2);
    }

    if (str_ptr < hInst or str_ptr > hInst + 0x1000000) return 0;
    const target_len = @as(*const u16, @ptrFromInt(str_ptr)).*;
    if (target_len == 0) return 0;

    str_ptr += 2;
    const wide_chars = @as([*]const u16, @ptrFromInt(str_ptr));
    const copy_len = @min(@as(usize, @intCast(target_len)), max_len - 1);
    for (0..copy_len) |i| {
        out_buf[i] = wide_chars[i];
    }
    out_buf[copy_len] = 0;
    return copy_len;
}

pub fn stub_LoadAcceleratorsA(hInstance: usize, lpTableName: usize) callconv(w32cc.WINAPI) usize {
    _ = hInstance;
    if (trace.enable_tracing) {
        if (lpTableName <= 0xFFFF) {
            trace.print("USER32: LoadAcceleratorsA(ID={d})\n", .{lpTableName});
        } else {
            trace.print("USER32: LoadAcceleratorsA(Name={s})\n", .{trace.c_span(lpTableName)});
        }
    }
    return 0xACCE0001; // Dummy accelerator table handle
}

pub fn stub_LoadAcceleratorsW(hInstance: usize, lpTableName: usize) callconv(w32cc.WINAPI) usize {
    _ = hInstance;
    if (trace.enable_tracing) {
        const window = @import("window.zig");
        if (lpTableName <= 0xFFFF) {
            trace.print("USER32: LoadAcceleratorsW(ID={d})\n", .{lpTableName});
        } else {
            trace.print("USER32: LoadAcceleratorsW(Name={s})\n", .{window.wideToUtf8(lpTableName)});
        }
    }
    return 0xACCE0001; // Dummy accelerator table handle
}

pub fn stub_LoadImageA(hInstance: usize, name: usize, img_type: u32, cx: i32, cy: i32, fuLoad: u32) callconv(w32cc.WINAPI) usize {
    _ = hInstance;
    _ = cx;
    _ = cy;
    _ = fuLoad;
    if (trace.enable_tracing) {
        if (name <= 0xFFFF) {
            trace.print("USER32: LoadImageA(ID={d}, type={d})\n", .{ name, img_type });
        } else {
            trace.print("USER32: LoadImageA(Name={s}, type={d})\n", .{ trace.c_span(name), img_type });
        }
    }
    return 0x11A6E001; // Dummy image handle
}

pub fn stub_LoadImageW(hInstance: usize, name: usize, img_type: u32, cx: i32, cy: i32, fuLoad: u32) callconv(w32cc.WINAPI) usize {
    _ = hInstance;
    _ = cx;
    _ = cy;
    _ = fuLoad;
    if (trace.enable_tracing) {
        const window = @import("window.zig");
        if (name <= 0xFFFF) {
            trace.print("USER32: LoadImageW(ID={d}, type={d})\n", .{ name, img_type });
        } else {
            trace.print("USER32: LoadImageW(Name={s}, type={d})\n", .{ window.wideToUtf8(name), img_type });
        }
    }
    return 0x11A6E001; // Dummy image handle
}

pub fn stub_LoadMenuA(hInstance: usize, lpMenuName: usize) callconv(w32cc.WINAPI) usize {
    _ = hInstance;
    if (trace.enable_tracing) trace.print("USER32: LoadMenuA({x})\n", .{lpMenuName});
    return 0x00000999; // Dummy menu handle
}

pub fn stub_LoadBitmapA(hInstance: usize, lpBitmapName: usize) callconv(w32cc.WINAPI) usize {
    _ = hInstance;
    if (trace.enable_tracing) {
        if (lpBitmapName <= 0xFFFF) {
            trace.print("USER32: LoadBitmapA(ID={d})\n", .{lpBitmapName});
        } else {
            trace.print("USER32: LoadBitmapA(Name={s})\n", .{trace.c_span(lpBitmapName)});
        }
    }
    return 0xB17B0001; // Dummy bitmap handle
}

pub fn stub_LoadBitmapW(hInstance: usize, lpBitmapName: usize) callconv(w32cc.WINAPI) usize {
    _ = hInstance;
    if (trace.enable_tracing) {
        if (lpBitmapName <= 0xFFFF) {
            trace.print("USER32: LoadBitmapW(ID={d})\n", .{lpBitmapName});
        } else {
            const window = @import("window.zig");
            trace.print("USER32: LoadBitmapW(Name={s})\n", .{window.wideToUtf8(lpBitmapName)});
        }
    }
    return 0xB17B0001; // Dummy bitmap handle
}
