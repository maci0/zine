const trace = @import("../../trace.zig");
const pe = @import("../../pe.zig");
const pe_resources = @import("../../pe_resources.zig");
const kernel32 = @import("../kernel32.zig");
const renderer = @import("../../gui/renderer.zig");
const w32cc = @import("../calling_convention.zig");
const std = @import("std");
const w32 = @import("../constants.zig");

pub fn LoadIconA(hInstance: usize, lpIconName: usize) callconv(w32cc.WINAPI) usize {
    var hInst = hInstance;
    if (hInst == 0) {
        hInst = kernel32.main_module_handle;
    }

    const mod = kernel32.moduleForInstance(hInst);

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

/// Resource-directory entry count, or null when the directory header does not
/// fit in the image.
fn dirEntryCount(image: []const u8, dir_off: usize) ?u32 {
    if (dir_off > image.len or image.len - dir_off < @sizeOf(pe.IMAGE_RESOURCE_DIRECTORY)) return null;
    const named = std.mem.readInt(u16, image[dir_off + 12 ..][0..2], .little);
    const ids = std.mem.readInt(u16, image[dir_off + 14 ..][0..2], .little);
    return @as(u32, named) + ids;
}

/// Offset of entry `index` in the table at `entries_off`, or null when the
/// arithmetic would leave the address space.
fn nthEntry(entries_off: usize, index: usize) ?usize {
    const delta = std.math.mul(u64, index, @sizeOf(pe.IMAGE_RESOURCE_DIRECTORY_ENTRY)) catch return null;
    const off = std.math.add(u64, entries_off, delta) catch return null;
    return std.math.cast(usize, off) orelse null;
}

fn readEntry(image: []const u8, off: usize) ?pe.IMAGE_RESOURCE_DIRECTORY_ENTRY {
    if (off > image.len or image.len - off < @sizeOf(pe.IMAGE_RESOURCE_DIRECTORY_ENTRY)) return null;
    return .{
        .NameOrId = std.mem.readInt(u32, image[off..][0..4], .little),
        .OffsetToData = std.mem.readInt(u32, image[off + 4 ..][0..4], .little),
    };
}

fn readU16(image: []const u8, off: usize) ?u16 {
    if (off > image.len or image.len - off < 2) return null;
    return std.mem.readInt(u16, image[off..][0..2], .little);
}

fn readU32(image: []const u8, off: usize) ?u32 {
    if (off > image.len or image.len - off < 4) return null;
    return std.mem.readInt(u32, image[off..][0..4], .little);
}

/// Finds the entry with `id` in the resource directory at `dir_off`. Named
/// entries (bit 31 set) resolve through the UTF-16 name holding the numeric
/// id, as CVTRES under the emulator writes them, bounded by the resource
/// directory itself.
fn findResEntry(image: []const u8, res_base: usize, res_size: u32, dir_off: usize, id: u32) ?u32 {
    const count = dirEntryCount(image, dir_off) orelse return null;
    const limit = @as(u64, res_base) + res_size;
    const entries_off = std.math.add(usize, dir_off, @sizeOf(pe.IMAGE_RESOURCE_DIRECTORY)) catch return null;

    for (0..count) |i| {
        const entry = readEntry(image, nthEntry(entries_off, i) orelse return null) orelse return null;
        var resolved: ?u32 = null;
        if (entry.NameOrId & 0x80000000 != 0) {
            const s_off = @as(u64, res_base) + (entry.NameOrId & 0x7FFFFFFF);
            if (s_off + 4 <= limit) {
                const name_off: usize = @intCast(s_off);
                if (readU16(image, name_off) == 1) resolved = readU16(image, name_off + 2) orelse return null;
            }
        } else {
            resolved = entry.NameOrId;
        }
        if (resolved != null and resolved.? == id) return entry.OffsetToData;
    }
    return null;
}

/// Where the wide characters of one string live inside a mapped image.
const BlockString = struct {
    off: usize,
    len: u16,
    /// First byte past the string-table block, the hard bound on the walk.
    end: usize,
};

/// Resolves `uID` to its string in the RT_STRING block, walking only bytes
/// inside `image` and inside the block's declared size. Every offset on the
/// way comes from the PE file, so a malformed one returns null instead of
/// reading past the mapping.
fn findBlockString(image: []const u8, uID: u32) ?BlockString {
    if (readU16(image, @offsetOf(pe.IMAGE_DOS_HEADER, "e_magic")) != pe.IMAGE_DOS_SIGNATURE) return null;
    const lfanew = std.math.cast(usize, readU32(image, @offsetOf(pe.IMAGE_DOS_HEADER, "e_lfanew")) orelse return null) orelse return null;
    if (readU32(image, lfanew) != pe.IMAGE_NT_SIGNATURE) return null;

    const res_dir_off = std.math.add(usize, lfanew, @offsetOf(pe.IMAGE_NT_HEADERS32, "OptionalHeader")) catch return null;
    const data_dir_off = std.math.add(usize, res_dir_off, @offsetOf(pe.IMAGE_OPTIONAL_HEADER32, "DataDirectory")) catch return null;
    const res_entry_off = std.math.add(usize, data_dir_off, @as(usize, pe.IMAGE_DIRECTORY_ENTRY_RESOURCE) * @sizeOf(pe.IMAGE_DATA_DIRECTORY)) catch return null;
    if (res_entry_off > image.len or image.len - res_entry_off < 2 * @sizeOf(pe.IMAGE_DATA_DIRECTORY)) return null;
    const res_rva = std.mem.readInt(u32, image[res_entry_off..][0..4], .little);
    const res_size = std.mem.readInt(u32, image[res_entry_off + 4 ..][0..4], .little);
    if (res_rva == 0 or res_size == 0) {
        if (trace.enable_tracing) trace.print("USER32: No resource dir\n", .{});
        return null;
    }
    const res_base = std.math.cast(usize, res_rva) orelse return null;

    const type_offset = findResEntry(image, res_base, res_size, res_base, pe_resources.RT_STRING) orelse {
        if (trace.enable_tracing) trace.print("USER32: No RT_STRING\n", .{});
        return null;
    };
    if ((type_offset & 0x80000000) == 0) return null;
    const name_off = std.math.add(usize, res_base, type_offset & 0x7FFFFFFF) catch return null;

    const block_id = (uID >> 4) + 1;
    const lang_offset = findResEntry(image, res_base, res_size, name_off, block_id) orelse {
        if (trace.enable_tracing) trace.print("USER32: No block ID {d}\n", .{block_id});
        return null;
    };
    if ((lang_offset & 0x80000000) == 0) return null;
    const lang_off = std.math.add(usize, res_base, lang_offset & 0x7FFFFFFF) catch return null;

    const lang_count = dirEntryCount(image, lang_off) orelse return null;
    if (lang_count == 0) return null;
    const named = std.mem.readInt(u16, image[lang_off + 12 ..][0..2], .little);
    const lang_entries = std.math.add(usize, lang_off, @sizeOf(pe.IMAGE_RESOURCE_DIRECTORY)) catch return null;
    const first = readEntry(image, nthEntry(lang_entries, named) orelse return null) orelse return null;
    if ((first.OffsetToData & 0x80000000) != 0) return null;

    const data_off = std.math.add(usize, res_base, first.OffsetToData) catch return null;
    if (data_off > image.len or image.len - data_off < @sizeOf(pe.IMAGE_RESOURCE_DATA_ENTRY)) return null;
    var data_rva = std.mem.readInt(u32, image[data_off..][0..4], .little);
    const data_size = std.mem.readInt(u32, image[data_off + 4 ..][0..4], .little);
    // CVTRES byte-swaps the data RVA's 16-bit halves in stale builds.
    if (@as(u64, data_rva) > @as(u64, res_base) + res_size) {
        data_rva = ((data_rva & 0xFFFF) << 16) | (data_rva >> 16);
    }

    const str_off = std.math.cast(usize, data_rva) orelse return null;
    if (str_off > image.len) return null;
    const block_end = std.math.add(usize, str_off, data_size) catch return null;
    if (block_end > image.len) return null;

    var off = str_off;
    for (0..uID & 0xF) |i| {
        const len = readU16(image, off) orelse return null;
        if (trace.enable_tracing) {
            trace.print("USER32: loadString: block {d} string {d} at 0x{X} len 0x{X}\n", .{ block_id, i, off, len });
        }
        off = std.math.add(usize, off, 2 + @as(usize, len) * 2) catch return null;
        if (off > block_end) return null;
    }
    const target_len = readU16(image, off) orelse return null;
    if (trace.enable_tracing) {
        trace.print("USER32: loadString: block {d} target string at 0x{X} target_len 0x{X}\n", .{ block_id, off, target_len });
    }
    if (target_len == 0) return null;
    if (off + 2 > block_end) return null;
    return .{ .off = off + 2, .len = target_len, .end = block_end };
}

/// Narrow copy of string `uID` out of a mapped image. `image` is one loaded
/// module, so every byte read is inside its mapping.
pub fn loadStringFromImage(image: []const u8, uID: u32, out_buf: [*]u8, max_len: usize) usize {
    if (max_len == 0) return 0;
    const s = findBlockString(image, uID) orelse return 0;
    const avail = (s.end - s.off) / 2;
    const copy_len = @min(@as(usize, s.len), @min(max_len - 1, avail));
    for (0..copy_len) |i| {
        out_buf[i] = @intCast(std.mem.readInt(u16, image[s.off + i * 2 ..][0..2], .little) & 0xFF);
    }
    out_buf[copy_len] = 0;
    return copy_len;
}

/// Wide copy of string `uID` out of a mapped image. Same walk as
/// `loadStringFromImage`, so both return the same length for the same image.
pub fn loadStringFromImageW(image: []const u8, uID: u32, out_buf: [*]u16, max_len: usize) usize {
    if (max_len == 0) return 0;
    const s = findBlockString(image, uID) orelse return 0;
    const avail = (s.end - s.off) / 2;
    const copy_len = @min(@as(usize, s.len), @min(max_len - 1, avail));
    for (0..copy_len) |i| {
        out_buf[i] = std.mem.readInt(u16, image[s.off + i * 2 ..][0..2], .little);
    }
    out_buf[copy_len] = 0;
    return copy_len;
}

/// The mapped image of the loaded module `handle` names, or null when it
/// names no mapping. A handle outside the registry has no known length, so
/// nothing inside it can be read within bounds.
fn imageForHandle(handle: usize) ?[]const u8 {
    if (handle == 0) return null;
    const genv = kernel32.global_env orelse return null;
    const mod = genv.registry.moduleForHandle(handle) orelse return null;
    return mod.mapped_memory;
}

pub fn LoadStringA(hInstance: ?*anyopaque, uID: u32, lpBuffer: [*]u8, nBufferMax: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) {
        trace.print("USER32: LoadStringA(hInst={*}, uID={d}, max={d})\n", .{ hInstance, uID, nBufferMax });
    }
    if (nBufferMax > 0) {
        const max_len = @as(usize, @intCast(nBufferMax));

        var hInst: usize = if (hInstance != null) @intFromPtr(hInstance.?) else 0;
        if (hInst == 0) hInst = kernel32.main_module_handle;

        if (imageForHandle(hInst)) |image| {
            const len = loadStringFromImage(image, uID, lpBuffer, max_len);
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

pub fn LoadStringW(hInstance: ?*anyopaque, uID: u32, lpBuffer_ptr: usize, nBufferMax: i32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) {
        trace.print("USER32: LoadStringW(hInst={*}, uID={d}, buffer={x}, max={d})\n", .{ hInstance, uID, lpBuffer_ptr, nBufferMax });
    }
    if (nBufferMax > 0 and lpBuffer_ptr > 0x10000) {
        const lpBuffer = @as([*]u16, @ptrFromInt(lpBuffer_ptr));
        const max_len = @as(usize, @intCast(nBufferMax));

        var hInst: usize = if (hInstance != null) @intFromPtr(hInstance.?) else 0;
        if (hInst == 0) hInst = kernel32.main_module_handle;

        if (imageForHandle(hInst)) |image| {
            const len = loadStringFromImageW(image, uID, lpBuffer, max_len);
            if (len > 0) return @intCast(len);
        }

        lpBuffer[0] = 0;
    }
    return 0;
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

fn loadBitmapFromPE(hInst: usize, lpBitmapName: usize) usize {
    const mod = kernel32.moduleForInstance(hInst);
    if (mod) |m| {
        if (lpBitmapName <= 0xFFFF) {
            // RT_BITMAP is 2
            if (m.getResource(2, @as(u32, @intCast(lpBitmapName)))) |bmp_data| {
                const hdr = @as(*const w32.BITMAPINFOHEADER, @ptrCast(@alignCast(bmp_data.ptr)));
                const w: u32 = @intCast(if (hdr.biWidth < 0) -hdr.biWidth else hdr.biWidth);
                const h: u32 = @intCast(if (hdr.biHeight < 0) -hdr.biHeight else hdr.biHeight);
                const bitcount = hdr.biBitCount;

                const bytes = w * h * 4;
                const buf = std.heap.page_allocator.alloc(u8, bytes) catch return 0;
                @memset(buf, 0);

                const palette_num_colors: u32 = if (hdr.biClrUsed > 0) hdr.biClrUsed else if (bitcount <= 8) @as(u32, 1) << @as(u5, @intCast(bitcount)) else 0;
                const bits_offset = hdr.biSize + palette_num_colors * 4;
                const lpvBits = @intFromPtr(bmp_data.ptr) + bits_offset;
                const lpbmi = @intFromPtr(bmp_data.ptr);

                const drawing = @import("../gdi32/drawing.zig");
                drawing.blitDIBToBufferAt(lpvBits, lpbmi, buf, w, h, 0, 0, 0, 0, w, h, null, 0x00CC0020); // SRCCOPY

                const gdi32 = @import("../gdi32.zig");
                const handle = gdi32.nextHandle();
                // Owned allocation: DeleteObject releases it, so reload
                // cycles (per-dialog, per-state icons) don't grow the heap.
                if (!gdi32.registerDib(handle, @intFromPtr(buf.ptr), w, h, 32, bytes, true)) {
                    std.heap.page_allocator.free(buf);
                    return 0;
                }
                if (trace.enable_tracing) trace.print("USER32: LoadBitmap loaded {d}x{d} bpp={d} from PE resource\n", .{ w, h, bitcount });
                return handle;
            }
        }
    }
    return 0;
}

pub fn LoadBitmapA(hInstance: usize, lpBitmapName: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        if (lpBitmapName <= 0xFFFF) {
            trace.print("USER32: LoadBitmapA(ID={d})\n", .{lpBitmapName});
        } else {
            trace.print("USER32: LoadBitmapA(Name={s})\n", .{trace.c_span(lpBitmapName)});
        }
    }
    var hInst = hInstance;
    if (hInst == 0) hInst = kernel32.main_module_handle;
    const bmp = loadBitmapFromPE(hInst, lpBitmapName);
    if (bmp != 0) return bmp;
    return 0xB17B0001; // Dummy bitmap handle
}

pub fn LoadBitmapW(hInstance: usize, lpBitmapName: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        if (lpBitmapName <= 0xFFFF) {
            trace.print("USER32: LoadBitmapW(ID={d})\n", .{lpBitmapName});
        } else {
            const window = @import("window.zig");
            trace.print("USER32: LoadBitmapW(Name={s})\n", .{window.wideToUtf8(lpBitmapName)});
        }
    }
    var hInst = hInstance;
    if (hInst == 0) hInst = kernel32.main_module_handle;
    const bmp = loadBitmapFromPE(hInst, lpBitmapName);
    if (bmp != 0) return bmp;
    return 0xB17B0001; // Dummy bitmap handle
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a handle that names no mapping resolves to no image" {
    // A guest can pass any hInstance. Only a mapping the registry knows has a
    // length, so an address one byte past the mapped base, or a readable host
    // address the registry never saw, must resolve to nothing rather than to
    // an image whose offsets are unchecked.
    const env_mod = @import("../../loader/env.zig");
    const Module = @import("../../loader/module.zig").Module;
    const testing = std.testing;

    const saved_env = kernel32.global_env;
    const saved_main = kernel32.main_module_handle;
    defer {
        kernel32.global_env = saved_env;
        kernel32.main_module_handle = saved_main;
    }

    var environment = env_mod.Environment.init(testing.allocator);
    defer {
        _ = environment.registry.modules.fetchRemove("game.dll");
        environment.deinit();
    }

    const image = try testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    defer testing.allocator.free(image);
    @memset(image, 0);

    var stand_in: Module = undefined;
    stand_in.path = "bin/game.dll";
    stand_in.mapped_memory = image;
    try environment.registry.modules.put("game.dll", &stand_in);
    kernel32.global_env = &environment;
    kernel32.main_module_handle = 0;

    const base = @intFromPtr(image.ptr);
    try testing.expectEqual(@as(usize, image.len), imageForHandle(base).?.len);

    for ([_]usize{ 0, base + 1, base - 1, @intFromPtr(&stand_in), std.math.maxInt(usize) }) |handle| {
        try testing.expect(imageForHandle(handle) == null);
    }

    // The stubs must clear the caller's buffer and report zero for an
    // unregistered handle, rather than walking a length they never learned.
    var decoy: [64]u8 = @splat('A');
    try testing.expectEqual(@as(i32, 0), LoadStringA(@ptrFromInt(base + 1), 1, &decoy, decoy.len));
    try testing.expectEqual(@as(u8, 0), decoy[0]);
    // The rest of the buffer is the caller's to reuse; the stub writes only
    // the terminator it promises.
    try testing.expectEqual(@as(u8, 'A'), decoy[1]);

    var wide: [64]u16 = @splat(0x0041);
    try testing.expectEqual(@as(i32, 0), LoadStringW(@ptrFromInt(base + 1), 1, @intFromPtr(&wide), wide.len));
    try testing.expectEqual(@as(u16, 0), wide[0]);
    try testing.expectEqual(@as(u16, 0x0041), wide[1]);
}
