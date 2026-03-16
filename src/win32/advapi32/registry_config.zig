//! Registry configuration loader.
//! Parses an embedded TOML config at startup and provides lookup
//! for RegQueryValueExA/W and RegOpenKeyExA/W.
//! The TOML file is embedded at compile time via @embedFile.

const std = @import("std");
const toml = @import("toml");

/// A registry value: either a string or a DWORD.
pub const RegValue = union(enum) {
    string: []const u8,
    dword: u32,
};

/// Parsed registry configuration. Keys are normalized to uppercase.
const RegConfig = struct {
    /// Maps "UPPER_KEY_PATH\x00ValueName" → RegValue
    entries: std.StringHashMap(RegValue),
    /// Set of known key paths (uppercase) for RegOpenKeyEx
    keys: std.StringHashMap(void),
};

var global_config: ?RegConfig = null;

/// Embedded TOML config (baked into the binary at compile time).
const embedded_toml = @embedFile("registry.toml");

/// Initialize the registry config from the embedded TOML.
/// Call once at startup. Subsequent calls are no-ops.
pub fn init(allocator: std.mem.Allocator) void {
    if (global_config != null) return;

    var config = RegConfig{
        .entries = std.StringHashMap(RegValue).init(allocator),
        .keys = std.StringHashMap(void).init(allocator),
    };

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    const result = parser.parseString(embedded_toml) catch return;
    const root_table = result.value;

    // Each TOML table header is a registry path, values are name→data pairs.
    var table_it = root_table.iterator();
    while (table_it.next()) |table_entry| {
        const key_path = table_entry.key_ptr.*;
        const table_val = table_entry.value_ptr.*;

        // Register the key path as known (for RegOpenKeyEx)
        const upper_key = allocator.alloc(u8, key_path.len) catch continue;
        _ = std.ascii.upperString(upper_key, key_path);
        config.keys.put(upper_key, {}) catch continue;

        // Only process sub-tables (each TOML table = one registry key)
        if (table_val != .table) continue;
        const sub_table = table_val.table;

        var val_it = sub_table.iterator();
        while (val_it.next()) |val_entry| {
            const value_name = val_entry.key_ptr.*;
            const value = val_entry.value_ptr.*;

            const lookup_key = std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ upper_key, value_name }) catch continue;

            switch (value) {
                .string => |s| {
                    config.entries.put(lookup_key, .{ .string = allocator.dupe(u8, s) catch continue }) catch continue;
                },
                .integer => |i| {
                    config.entries.put(lookup_key, .{ .dword = @truncate(@as(u64, @bitCast(i))) }) catch continue;
                },
                else => {},
            }
        }
    }

    global_config = config;
}

/// Look up a registry value by key path and value name (case-insensitive path).
pub fn lookup(key_path: []const u8, value_name: []const u8) ?RegValue {
    const config = global_config orelse return null;

    var buf: [1024]u8 = undefined;
    if (key_path.len + 1 + value_name.len > buf.len) return null;

    _ = std.ascii.upperString(buf[0..key_path.len], key_path);
    buf[key_path.len] = 0;
    @memcpy(buf[key_path.len + 1 ..][0..value_name.len], value_name);

    return config.entries.get(buf[0 .. key_path.len + 1 + value_name.len]);
}

/// Check if a registry key path exists in the configuration.
pub fn keyExists(key_path: []const u8) bool {
    const config = global_config orelse return false;
    var buf: [512]u8 = undefined;
    if (key_path.len > buf.len) return false;
    _ = std.ascii.upperString(buf[0..key_path.len], key_path);
    return config.keys.contains(buf[0..key_path.len]);
}
