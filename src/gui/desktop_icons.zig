//! Desktop icon listing for the web backend.
//!
//! Scans the guest's `drive_c/Desktop` directory and builds the JSON message
//! that describes it: entry names, kinds, extensions, and the icon group
//! lifted out of a PE image for an `.exe` entry. The message is returned to
//! the caller, which owns caching it and handing it to the backend.

const std = @import("std");
const runtime = @import("../runtime.zig");
const renderer = @import("renderer.zig");

/// Builds the `desktop_icons` message for the current Desktop directory.
/// The caller owns the returned bytes and frees them with `allocator`.
pub fn build(allocator: std.mem.Allocator) ![]const u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    json.appendSlice(allocator, "{\"type\":\"desktop_icons\",\"items\":[") catch return error.OutOfMemory;
    errdefer json.deinit(allocator);

    var dir = std.Io.Dir.cwd().openDir(runtime.io(), "drive_c/Desktop", .{ .iterate = true }) catch return error.DesktopMissing;
    defer dir.close(runtime.io());

    var first = true;
    var it = dir.iterate();
    while (it.next(runtime.io()) catch null) |entry| {
        // Skip hidden files
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        if (!first) json.appendSlice(allocator, ",") catch {};
        first = false;

        json.appendSlice(allocator, "{\"name\":\"") catch {};
        renderer.jsonEscapeAppend(&json, entry.name);
        json.appendSlice(allocator, "\",\"is_dir\":") catch {};
        json.appendSlice(allocator, if (entry.kind == .directory) "true" else "false") catch {};

        // Extract extension
        const ext = blk: {
            var i = entry.name.len;
            while (i > 0) {
                i -= 1;
                if (entry.name[i] == '.') break :blk entry.name[i + 1 ..];
            }
            break :blk "";
        };
        json.appendSlice(allocator, ",\"ext\":\"") catch {};
        renderer.jsonEscapeAppend(&json, ext);
        json.appendSlice(allocator, "\"") catch {};

        // For .exe files, try to extract icon from PE resources
        if (entry.kind == .file and ext.len >= 3 and
            (ext[0] == 'e' or ext[0] == 'E') and
            (ext[1] == 'x' or ext[1] == 'X') and
            (ext[2] == 'e' or ext[2] == 'E'))
        {
            if (extractExeIconBase64(allocator, entry.name)) |icon_b64| {
                json.appendSlice(allocator, ",\"icon\":\"") catch {};
                json.appendSlice(allocator, icon_b64) catch {};
                json.appendSlice(allocator, "\"") catch {};
                allocator.free(icon_b64);
            }
        }

        json.appendSlice(allocator, "}") catch {};
    }

    json.appendSlice(allocator, "]}") catch {};

    return json.items;
}

/// Extract icon from a .exe file in drive_c/Desktop/ and return base64-encoded ICO data.
fn extractExeIconBase64(allocator: std.mem.Allocator, filename: []const u8) ?[]const u8 {
    // Build path to the exe
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "drive_c/Desktop/{s}", .{filename}) catch return null;

    // Read the file into memory
    const file = std.Io.Dir.cwd().openFile(runtime.io(), path, .{}) catch return null;
    defer file.close(runtime.io());

    const file_size = file.length(runtime.io()) catch return null;
    if (file_size < 64 or file_size > 50 * 1024 * 1024) return null; // sanity check

    const file_data = allocator.alloc(u8, @intCast(file_size)) catch return null;
    defer allocator.free(file_data);
    const bytes_read = file.readPositionalAll(runtime.io(), file_data, 0) catch return null;
    if (bytes_read < 64) return null;

    // Parse PE to find icon resources
    return extractIconFromPEData(allocator, file_data[0..bytes_read]);
}

/// Parse PE data in memory and extract the first icon group as a base64-encoded .ICO file.
fn extractIconFromPEData(allocator: std.mem.Allocator, data: []const u8) ?[]const u8 {
    if (data.len < 64) return null;

    // Check MZ signature
    if (data[0] != 'M' or data[1] != 'Z') return null;

    // Get PE offset
    const pe_offset = std.mem.readInt(u32, data[0x3C..0x40], .little);
    if (pe_offset + 4 > data.len) return null;

    // Check PE signature
    if (data[pe_offset] != 'P' or data[pe_offset + 1] != 'E' or data[pe_offset + 2] != 0 or data[pe_offset + 3] != 0) return null;

    // COFF header
    const coff_start = pe_offset + 4;
    if (coff_start + 20 > data.len) return null;
    const num_sections = std.mem.readInt(u16, data[coff_start + 2 ..][0..2], .little);
    const optional_header_size = std.mem.readInt(u16, data[coff_start + 16 ..][0..2], .little);

    // Optional header
    const opt_start = coff_start + 20;
    if (opt_start + optional_header_size > data.len) return null;

    // Data directories start at offset 96 in PE32 optional header
    const data_dir_start = opt_start + 96;
    // Resource table is data directory index 2
    const rsrc_rva_offset = data_dir_start + 2 * 8;
    if (rsrc_rva_offset + 8 > data.len) return null;
    const rsrc_rva = std.mem.readInt(u32, data[rsrc_rva_offset..][0..4], .little);
    const rsrc_size = std.mem.readInt(u32, data[rsrc_rva_offset + 4 ..][0..4], .little);
    if (rsrc_rva == 0 or rsrc_size == 0) return null;

    // Find the section containing the resource RVA
    const section_start = opt_start + optional_header_size;
    var rsrc_file_offset: u32 = 0;

    for (0..num_sections) |i| {
        const s = section_start + i * 40;
        if (s + 40 > data.len) break;
        const s_rva = std.mem.readInt(u32, data[s + 12 ..][0..4], .little);
        const s_size = std.mem.readInt(u32, data[s + 8 ..][0..4], .little);
        const s_raw = std.mem.readInt(u32, data[s + 20 ..][0..4], .little);
        if (rsrc_rva >= s_rva and rsrc_rva < s_rva + s_size) {
            rsrc_file_offset = s_raw + (rsrc_rva - s_rva);
            break;
        }
    }
    if (rsrc_file_offset == 0) return null;

    // Now parse the resource directory tree to find RT_GROUP_ICON (type 14)
    return parseResourceDirForIcon(allocator, data, rsrc_file_offset, rsrc_rva);
}

fn parseResourceDirForIcon(allocator: std.mem.Allocator, data: []const u8, rsrc_offset: u32, rsrc_rva: u32) ?[]const u8 {
    if (rsrc_offset + 16 > data.len) return null;

    const num_named = std.mem.readInt(u16, data[rsrc_offset + 12 ..][0..2], .little);
    const num_id = std.mem.readInt(u16, data[rsrc_offset + 14 ..][0..2], .little);

    var entry_offset = rsrc_offset + 16;

    // Skip named entries, then look for RT_GROUP_ICON (14) and RT_ICON (3)
    entry_offset += @as(u32, num_named) * 8;

    var group_icon_offset: u32 = 0;
    var icon_dir_offset: u32 = 0;

    for (0..num_id) |_| {
        if (entry_offset + 8 > data.len) break;
        const id = std.mem.readInt(u32, data[entry_offset..][0..4], .little);
        const offset_or_dir = std.mem.readInt(u32, data[entry_offset + 4 ..][0..4], .little);

        if (id == 14) { // RT_GROUP_ICON
            group_icon_offset = rsrc_offset + (offset_or_dir & 0x7FFFFFFF);
        } else if (id == 3) { // RT_ICON
            icon_dir_offset = rsrc_offset + (offset_or_dir & 0x7FFFFFFF);
        }
        entry_offset += 8;
    }

    if (group_icon_offset == 0) return null;

    // Navigate: type dir → first name/id → first language → data entry
    const group_data = getFirstResourceData(data, group_icon_offset, rsrc_offset, rsrc_rva) orelse return null;

    // Parse GROUP_ICON header
    if (group_data.len < 20) return null;
    const id_type = std.mem.readInt(u16, group_data[2..4], .little);
    if (id_type != 1) return null;

    // Get first icon entry
    const bWidth = group_data[6];
    const bHeight = group_data[7];
    const bColorCount = group_data[8];
    const bReserved = group_data[9];
    const wPlanes = std.mem.readInt(u16, group_data[10..12], .little);
    const wBitCount = std.mem.readInt(u16, group_data[12..14], .little);
    const dwBytesInRes = std.mem.readInt(u32, group_data[14..18], .little);
    const nId = std.mem.readInt(u16, group_data[18..20], .little);

    // Now find the RT_ICON data for this nId
    if (icon_dir_offset == 0) return null;
    const icon_data = getResourceDataById(data, icon_dir_offset, rsrc_offset, rsrc_rva, nId) orelse return null;
    _ = dwBytesInRes;

    // Build ICO file
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;
    writer.writeInt(u16, 0, .little) catch return null;
    writer.writeInt(u16, 1, .little) catch return null;
    writer.writeInt(u16, 1, .little) catch return null;
    writer.writeByte(bWidth) catch return null;
    writer.writeByte(bHeight) catch return null;
    writer.writeByte(bColorCount) catch return null;
    writer.writeByte(bReserved) catch return null;
    writer.writeInt(u16, wPlanes, .little) catch return null;
    writer.writeInt(u16, wBitCount, .little) catch return null;
    writer.writeInt(u32, @intCast(icon_data.len), .little) catch return null;
    writer.writeInt(u32, 22, .little) catch return null; // data offset
    writer.writeAll(icon_data) catch return null;

    const ico_bytes = writer.buffer[0..writer.end];

    // Base64 encode
    const b64_encoder = std.base64.standard.Encoder;
    const b64_len = b64_encoder.calcSize(ico_bytes.len);
    const b64_buf = allocator.alloc(u8, b64_len) catch return null;
    _ = b64_encoder.encode(b64_buf, ico_bytes);
    return b64_buf;
}

/// Resolve a directory entry's high-bit-cleared offset as a data entry and
/// return the bytes it points at.
fn resourceDataAt(data: []const u8, data_entry: u32, rsrc_base: u32, rsrc_rva: u32) ?[]const u8 {
    if (data_entry + 16 > data.len) return null;
    const data_rva = std.mem.readInt(u32, data[data_entry..][0..4], .little);
    const data_size = std.mem.readInt(u32, data[data_entry + 4 ..][0..4], .little);
    const file_offset = data_rva - rsrc_rva + rsrc_base;
    if (file_offset + data_size > data.len) return null;
    return data[file_offset..][0..data_size];
}

/// Navigate a resource directory (type → first ID → first language) to get data
fn getFirstResourceData(data: []const u8, dir_offset: u32, rsrc_base: u32, rsrc_rva: u32) ?[]const u8 {
    if (dir_offset + 16 > data.len) return null;
    const num_named = std.mem.readInt(u16, data[dir_offset + 12 ..][0..2], .little);
    const num_id = std.mem.readInt(u16, data[dir_offset + 14 ..][0..2], .little);
    const total = @as(u32, num_named) + @as(u32, num_id);
    if (total == 0) return null;

    // Take first entry
    const first_entry = dir_offset + 16;
    if (first_entry + 8 > data.len) return null;
    const sub_offset = std.mem.readInt(u32, data[first_entry + 4 ..][0..4], .little);

    if ((sub_offset & 0x80000000) != 0) {
        // It's a subdirectory — recurse one more level
        const sub_dir = rsrc_base + (sub_offset & 0x7FFFFFFF);
        return getFirstResourceData(data, sub_dir, rsrc_base, rsrc_rva);
    } else {
        // It's a data entry
        return resourceDataAt(data, rsrc_base + sub_offset, rsrc_base, rsrc_rva);
    }
}

/// Find a specific resource ID in a resource directory and return its data
fn getResourceDataById(data: []const u8, dir_offset: u32, rsrc_base: u32, rsrc_rva: u32, target_id: u16) ?[]const u8 {
    if (dir_offset + 16 > data.len) return null;
    const num_named = std.mem.readInt(u16, data[dir_offset + 12 ..][0..2], .little);
    const num_id = std.mem.readInt(u16, data[dir_offset + 14 ..][0..2], .little);

    var entry = dir_offset + 16 + @as(u32, num_named) * 8;
    for (0..num_id) |_| {
        if (entry + 8 > data.len) break;
        const id = std.mem.readInt(u32, data[entry..][0..4], .little);
        const sub_offset = std.mem.readInt(u32, data[entry + 4 ..][0..4], .little);

        if (id == target_id) {
            if ((sub_offset & 0x80000000) != 0) {
                const sub_dir = rsrc_base + (sub_offset & 0x7FFFFFFF);
                return getFirstResourceData(data, sub_dir, rsrc_base, rsrc_rva);
            } else {
                return resourceDataAt(data, rsrc_base + sub_offset, rsrc_base, rsrc_rva);
            }
        }
        entry += 8;
    }
    return null;
}
