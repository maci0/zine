//! PE icon resource parser.
//!
//! This module provides functions to extract icon resources from PE files
//! and convert them to ICO format or base64-encoded strings for the UI.

const std = @import("std");
const Module = @import("module.zig").Module;
const log = @import("../log.zig");
const trace = @import("../trace.zig");
const res = @import("../pe_resources.zig");

/// Extracts an icon resource from a PE module and returns it as a base64-encoded JSON message.
/// If icon_group_id is null, the first available icon group is used.
pub fn parseIconResource(allocator: std.mem.Allocator, module: *Module, icon_group_id: ?u32) !?[]const u8 {
    var group_data: ?[]const u8 = null;

    if (icon_group_id) |id| {
        group_data = module.getResource(res.RT_GROUP_ICON, id);
    } else {
        group_data = module.getFirstResource(res.RT_GROUP_ICON);
    }

    if (group_data) |data| {
        const icon_data = module.getResource(res.RT_ICON, groupIconId(data) orelse return null) orelse return null;
        return parseIconData(allocator, data, icon_data);
    }

    if (trace.enable_tracing) trace.print("ICON PARSER: Failed to extract icon\n", .{});
    return null;
}

/// The first icon's resource ID, read from a raw RT_GROUP_ICON blob. Returns
/// null when the group header is malformed, names no images, or is too short
/// to hold the one entry the parser reads.
fn groupIconId(data: []const u8) ?u16 {
    if (data.len < group_dir_len) return null;
    const id_reserved = std.mem.readInt(u16, data[0..2], .little);
    const id_type = std.mem.readInt(u16, data[2..4], .little);
    const id_count = std.mem.readInt(u16, data[4..6], .little);
    if (id_reserved != 0 or id_type != 1 or id_count == 0) return null;
    return std.mem.readInt(u16, data[entry_offset + 12 ..][0..2], .little);
}

/// Bytes a group directory must have for the first entry to be readable:
/// 6-byte header plus one 14-byte ICONDIRENTRY.
const group_dir_len = 6 + 14;
const entry_offset = 6;

/// Parses a raw RT_GROUP_ICON directory together with the RT_ICON blob it
/// points at, and returns the ICO payload as a base64 JSON message. Both
/// slices come from the PE resource directory and are untrusted.
pub fn parseIconData(allocator: std.mem.Allocator, data: []const u8, icon_data: []const u8) !?[]const u8 {
    _ = groupIconId(data) orelse return null;

    // The first icon entry from the group
    const entry = data[entry_offset..group_dir_len];
    const bWidth = entry[0];
    const bHeight = entry[1];
    const bColorCount = entry[2];
    const bReserved = entry[3];
    const wPlanes = std.mem.readInt(u16, entry[4..6], .little);
    const wBitCount = std.mem.readInt(u16, entry[6..8], .little);
    const dwBytesInRes = std.mem.readInt(u32, entry[8..12], .little);

    if (icon_data.len != dwBytesInRes) {
        log.warn("Icon data length mismatch: expected {}, got {}", .{ dwBytesInRes, icon_data.len });
        // Size mismatch is common with compressed icons; proceed with actual data length
    }

    // Build ICO buffer
    var ico_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer ico_alloc.deinit();
    const writer = &ico_alloc.writer;
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, 1, .little);

    try writer.writeByte(bWidth);
    try writer.writeByte(bHeight);
    try writer.writeByte(bColorCount);
    try writer.writeByte(bReserved);
    try writer.writeInt(u16, wPlanes, .little);
    try writer.writeInt(u16, wBitCount, .little);
    try writer.writeInt(u32, @intCast(icon_data.len), .little);
    try writer.writeInt(u32, 22, .little);

    try writer.writeAll(icon_data);

    const ico_bytes = writer.buffer[0..writer.end];

    // Base64 encode
    const b64_encoder = std.base64.standard.Encoder;
    const b64_len = b64_encoder.calcSize(ico_bytes.len);

    const b64_buf = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64_buf);
    _ = b64_encoder.encode(b64_buf, ico_bytes);

    const json_str = try std.fmt.allocPrint(allocator, "{{\"type\":\"set_icon\",\"base64\":\"{s}\"}}", .{b64_buf});

    if (trace.enable_tracing) trace.print("ICON PARSER: Successfully extracted icon and encoded to base64\n", .{});
    return json_str;
}
