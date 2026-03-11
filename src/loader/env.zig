const std = @import("std");
const pe = @import("../pe.zig");
pub const Module = @import("module.zig").Module;
const Registry = @import("registry.zig").Registry;

pub const BuiltinModule = struct {
    handle: usize,
    exports: std.StringHashMap(usize),
};

pub const Environment = struct {
    allocator: std.mem.Allocator,
    registry: Registry,

    // Fallback static map for built-in/stubbed exports
    builtins: std.StringHashMap(BuiltinModule),

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{
            .allocator = allocator,
            .registry = Registry.init(allocator),
            .builtins = std.StringHashMap(BuiltinModule).init(allocator),
        };
    }

    pub fn deinit(self: *Environment) void {
        var it = self.builtins.iterator();
        while (it.next()) |entry| {
            var val = entry.value_ptr.*;
            val.exports.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.builtins.deinit();
        self.registry.deinit();
    }

    pub fn addBuiltinExport(self: *Environment, dll: []const u8, name: []const u8, addr: usize) !void {
        const lower_dll = try self.allocator.alloc(u8, dll.len);
        defer self.allocator.free(lower_dll);
        _ = std.ascii.lowerString(lower_dll, dll);

        var builtin = self.builtins.getPtr(lower_dll);
        if (builtin == null) {
            // Allocate a page for the fake PE header
            const header = try self.allocator.alloc(u8, 4096);
            @memset(header, 0);

            // Minimal MZ/PE header
            const mz = @as(*align(1) u16, @ptrCast(&header[0]));
            mz.* = 0x5A4D; // "MZ"
            const e_lfanew = @as(*align(1) u32, @ptrCast(&header[0x3C]));
            e_lfanew.* = 0x40;
            const pe_sig = @as(*align(1) u32, @ptrCast(&header[0x40]));
            pe_sig.* = 0x00004550; // "PE\0\0"

            const new_builtin = BuiltinModule{
                .handle = @intFromPtr(header.ptr),
                .exports = std.StringHashMap(usize).init(self.allocator),
            };
            try self.builtins.put(try self.allocator.dupe(u8, lower_dll), new_builtin);
            builtin = self.builtins.getPtr(lower_dll);
        }
        try builtin.?.*.exports.put(name, addr); // Assuming name is a static string
    }

    pub fn getBuiltinHandle(self: *Environment, dll_name: []const u8) ?usize {
        var search_name: []const u8 = dll_name;
        var with_ext: ?[]u8 = null;
        if (!std.ascii.endsWithIgnoreCase(dll_name, ".dll")) {
            const ext = ".dll";
            if (self.allocator.alloc(u8, dll_name.len + ext.len)) |new_name| {
                @memcpy(new_name[0..dll_name.len], dll_name);
                @memcpy(new_name[dll_name.len .. dll_name.len + ext.len], ext);
                search_name = new_name;
                with_ext = new_name;
            } else |_| {}
        }
        defer if (with_ext) |buf| self.allocator.free(buf);

        if (self.allocator.alloc(u8, search_name.len)) |lower_dll| {
            defer self.allocator.free(lower_dll);
            _ = std.ascii.lowerString(lower_dll, search_name);

            if (self.builtins.get(lower_dll)) |builtin| {
                return builtin.handle;
            }
        } else |_| {}
        return null;
    }
    pub fn resolveExport(self: *Environment, dll_name: []const u8, func_name: []const u8) ?usize {
        // Special case for builtin module handles
        if (std.mem.eql(u8, dll_name, "builtin")) {
            if (self.builtins.get("builtin")) |builtin| {
                if (builtin.exports.get(func_name)) |addr| {
                    return addr;
                }
            }
        }

        // First try loaded modules
        if (self.registry.getExport(dll_name, func_name)) |addr| {
            return addr;
        }

        // Fallback to builtins (case-insensitive)
        if (self.allocator.alloc(u8, dll_name.len)) |lower_dll| {
            defer self.allocator.free(lower_dll);
            _ = std.ascii.lowerString(lower_dll, dll_name);

            if (self.builtins.get(lower_dll)) |builtin| {
                if (builtin.exports.get(func_name)) |addr| {
                    return addr;
                }
            }
        } else |_| {}

        return null;
    }
};
