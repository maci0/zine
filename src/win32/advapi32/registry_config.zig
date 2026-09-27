//! Registry configuration loader.
//! Parses an embedded TOML config at startup and provides lookup
//! for RegQueryValueExA/W and RegOpenKeyExA/W.
//! The TOML file is embedded at compile time via @embedFile.

const std = @import("std");
const toml = @import("toml");
const log = @import("../../log.zig");

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
    /// Per-application overrides: "MODULE\x00UPPER_KEY_PATH\x00ValueName" → RegValue
    app_entries: std.StringHashMap(RegValue),
};

var global_config: ?RegConfig = null;

/// Current application module basename (uppercase), set at startup. When a
/// per-app override exists for this module it takes precedence over the
/// global value.
var current_app_module: []const u8 = "";

/// Embedded TOML config (baked into the binary at compile time).
const embedded_toml = @embedFile("registry.toml");

/// Set the current application module (basename, e.g. "CL.EXE"). Called at
/// startup with the main executable's name so `app:<MODULE>:` overrides apply.
pub fn setAppModule(module_basename: []const u8) void {
    if (module_basename.len == 0) return;
    const upper = std.heap.page_allocator.alloc(u8, module_basename.len) catch return;
    _ = std.ascii.upperString(upper, module_basename);
    current_app_module = upper;
}

/// Initialize the registry config from the embedded TOML.
/// Call once at startup. Subsequent calls are no-ops.
pub fn init(allocator: std.mem.Allocator) void {
    if (global_config != null) return;

    var config = RegConfig{
        .entries = std.StringHashMap(RegValue).init(allocator),
        .keys = std.StringHashMap(void).init(allocator),
        .app_entries = std.StringHashMap(RegValue).init(allocator),
    };

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    // A malformed registry.toml would leave every guest registry lookup
    // reporting "not found", which reads as a guest bug rather than a config
    // error. The file is embedded at build time, so this stops the process.
    const result = parser.parseString(embedded_toml) catch |err| {
        log.fatal("registry.toml is not valid TOML: {}", .{err});
        std.process.exit(1);
    };
    const root_table = result.value;

    // Each TOML table header is a registry path, values are name→data pairs.
    // Headers of the form "app:<MODULE>:<KEY>" are per-application overrides.
    var table_it = root_table.iterator();
    while (table_it.next()) |table_entry| {
        const key_path = table_entry.key_ptr.*;
        const table_val = table_entry.value_ptr.*;

        // Only process sub-tables (each TOML table = one registry key)
        if (table_val != .table) continue;
        const sub_table = table_val.table;

        const base_key = if (std.ascii.startsWithIgnoreCase(key_path, "app:")) blk: {
            // Split "app:<MODULE>:<KEY>" into module + key.
            const rest = key_path[4..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const module_name = rest[0..colon];
            const upper_module = allocator.alloc(u8, module_name.len) catch continue;
            _ = std.ascii.upperString(upper_module, module_name);
            const key_part = rest[colon + 1 ..];
            const upper_key = allocator.alloc(u8, key_part.len) catch continue;
            _ = std.ascii.upperString(upper_key, key_part);
            break :blk .{ .module = upper_module, .key = upper_key };
        } else null;

        if (base_key) |bk| {
            // Per-app entries: "MODULE\x00KEY\x00VALUE"
            var val_it = sub_table.iterator();
            while (val_it.next()) |val_entry| {
                const value_name = val_entry.key_ptr.*;
                const value = val_entry.value_ptr.*;
                const lookup_key = std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}", .{ bk.module, bk.key, value_name }) catch continue;
                switch (value) {
                    .string => |s| {
                        config.app_entries.put(lookup_key, .{ .string = allocator.dupe(u8, s) catch continue }) catch continue;
                    },
                    .integer => |i| {
                        config.app_entries.put(lookup_key, .{ .dword = @truncate(@as(u64, @bitCast(i))) }) catch continue;
                    },
                    else => {},
                }
            }
            continue;
        }

        // Register the key path as known (for RegOpenKeyEx)
        const upper_key = allocator.alloc(u8, key_path.len) catch continue;
        _ = std.ascii.upperString(upper_key, key_path);
        config.keys.put(upper_key, {}) catch continue;

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
/// Per-application overrides (keyed by the current module) take precedence.
pub fn lookup(key_path: []const u8, value_name: []const u8) ?RegValue {
    const config = global_config orelse return null;

    var buf: [1024]u8 = undefined;
    if (key_path.len + 1 + value_name.len > buf.len) return null;

    _ = std.ascii.upperString(buf[0..key_path.len], key_path);
    buf[key_path.len] = 0;
    @memcpy(buf[key_path.len + 1 ..][0..value_name.len], value_name);

    // Per-app override first.
    if (current_app_module.len > 0) {
        var abuf: [2048]u8 = undefined;
        const akey_len = current_app_module.len + 1 + key_path.len + 1 + value_name.len;
        if (akey_len <= abuf.len) {
            @memcpy(abuf[0..current_app_module.len], current_app_module);
            abuf[current_app_module.len] = 0;
            @memcpy(abuf[current_app_module.len + 1 ..][0..key_path.len], buf[0..key_path.len]);
            abuf[current_app_module.len + 1 + key_path.len] = 0;
            @memcpy(abuf[current_app_module.len + 2 + key_path.len ..][0..value_name.len], value_name);
            if (config.app_entries.get(abuf[0..akey_len])) |v| return v;
        }
    }

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
