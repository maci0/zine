const std = @import("std");
const Module = @import("module.zig").Module;
const log = @import("../log.zig");

pub fn parseIconResource(allocator: std.mem.Allocator, module: *Module, icon_group_id: ?u32) !?[]const u8 {
    var group_data: ?[]const u8 = null;

    if (icon_group_id) |id| {
        group_data = module.getResource(14, id); // RT_GROUP_ICON = 14
    } else {
        group_data = module.getFirstResource(14);
    }

    if (group_data) |data| {
        if (data.len < 6) return null;
        
        var stream = std.io.fixedBufferStream(data);
        var reader = stream.reader();
        
        const idReserved = try reader.readInt(u16, .little);
        const idType = try reader.readInt(u16, .little);
        const idCount = try reader.readInt(u16, .little);
        
        if (idReserved != 0 or idType != 1 or idCount == 0) return null;
        
        // Just take the first icon from the group for now
        if (data.len < 6 + 14) return null;
        
        const bWidth = try reader.readByte();
        const bHeight = try reader.readByte();
        const bColorCount = try reader.readByte();
        const bReserved = try reader.readByte();
        const wPlanes = try reader.readInt(u16, .little);
        const wBitCount = try reader.readInt(u16, .little);
        const dwBytesInRes = try reader.readInt(u32, .little);
        const nId = try reader.readInt(u16, .little);
        
        const icon_data = module.getResource(3, nId) orelse return null; // RT_ICON = 3
        
        if (icon_data.len != dwBytesInRes) {
            log.warn("Icon data length mismatch: expected {}, got {}", .{dwBytesInRes, icon_data.len});
            // Proceed anyway
        }
        
        // Build ICO buffer
        var ico_buf: std.ArrayListUnmanaged(u8) = .{};
        defer ico_buf.deinit(allocator);
        
        var writer = ico_buf.writer(allocator);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 1, .little);
        try writer.writeInt(u16, 1, .little); // 1 icon
        
        try writer.writeByte(bWidth);
        try writer.writeByte(bHeight);
        try writer.writeByte(bColorCount);
        try writer.writeByte(bReserved);
        try writer.writeInt(u16, wPlanes, .little);
        try writer.writeInt(u16, wBitCount, .little);
        try writer.writeInt(u32, @intCast(icon_data.len), .little);
        try writer.writeInt(u32, 22, .little); // Offset to image data
        
        try writer.writeAll(icon_data);
        
        // Base64 encode
        const b64_encoder = std.base64.standard.Encoder;
        const b64_len = b64_encoder.calcSize(ico_buf.items.len);
        
        const b64_buf = try allocator.alloc(u8, b64_len);
        defer allocator.free(b64_buf);
        _ = b64_encoder.encode(b64_buf, ico_buf.items);
        
        const json_str = try std.fmt.allocPrint(allocator, "{{\"type\":\"set_icon\",\"base64\":\"{s}\"}}", .{b64_buf});
        
        const trace = @import("../trace.zig");
        if (trace.enable_tracing) trace.print("ICON PARSER: Successfully extracted icon and encoded to base64\n", .{});
        return json_str;
    }
    
    const trace = @import("../trace.zig");
    if (trace.enable_tracing) trace.print("ICON PARSER: Failed to extract icon\n", .{});
    return null;
}
