const std = @import("std");
const pe = @import("../pe.zig");
const Module = @import("module.zig").Module;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(*Module),
    search_paths: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return Registry{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
            .search_paths = .{},
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.modules.deinit();

        for (self.search_paths.items) |path| {
            self.allocator.free(path);
        }
        self.search_paths.deinit(self.allocator);
    }

    pub fn addSearchPath(self: *Registry, path: []const u8) !void {
        try self.search_paths.append(self.allocator, try self.allocator.dupe(u8, path));
    }

    pub fn loadModule(self: *Registry, name: []const u8) !*Module {
        // Create lowercased name for map
        const lower_name = try self.allocator.alloc(u8, name.len);
        defer self.allocator.free(lower_name);
        _ = std.ascii.lowerString(lower_name, name);

        if (self.modules.get(lower_name)) |mod| {
            return mod;
        }

        var file_path: ?[]const u8 = null;

        // If the name contains a directory separator, treat it as a direct path
        if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, '\\') != null) {
            // Fix path separators
            const fixed_path = try self.allocator.alloc(u8, name.len);
            defer self.allocator.free(fixed_path);
            @memcpy(fixed_path, name);
            std.mem.replaceScalar(u8, fixed_path, '\\', '/');

            if (std.fs.cwd().access(fixed_path, .{})) |_| {
                file_path = try self.allocator.dupe(u8, fixed_path);
            } else |_| {
                // Try case-insensitive scan in the directory
                if (std.fs.path.dirname(fixed_path)) |dir| {
                    const base = std.fs.path.basename(fixed_path);
                    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return error.ModuleNotFound;
                    defer d.close();
                    var it = d.iterate();
                    while (it.next() catch null) |entry| {
                        if (std.ascii.eqlIgnoreCase(entry.name, base)) {
                            file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, entry.name });
                            break;
                        }
                    }
                }
            }
        }

        // Try to find the file in search paths if not a direct path
        if (file_path == null) {
            for (self.search_paths.items) |path| {
                std.log.debug("Searching for {s} in {s}", .{ name, path });
                // Check exact match first
                const full_path_exact = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, name });
                defer self.allocator.free(full_path_exact);

                if (std.fs.cwd().access(full_path_exact, .{})) |_| {
                    file_path = try self.allocator.dupe(u8, full_path_exact);
                    break;
                } else |err| switch (err) {
                    error.FileNotFound => {
                        // Open the directory and search case-insensitively
                        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
                            // If the path itself fails to open, it might be due to casing (e.g. BIN vs Bin)
                            // We do a very basic parent-level check here just to be robust if needed, 
                            // but usually the paths coming from PATH are exact on the system.
                            // If it's a BAT mapped path it might be wrong.
                            
                            // Check parent directory
                            const parent = std.fs.path.dirname(path) orelse continue;
                            const base = std.fs.path.basename(path);
                            var parent_dir = std.fs.cwd().openDir(parent, .{ .iterate = true }) catch continue;
                            defer parent_dir.close();
                            
                            var found_real_base: ?[]const u8 = null;
                            var p_it = parent_dir.iterate();
                            while (p_it.next() catch null) |entry| {
                                if (entry.kind == .directory and std.ascii.eqlIgnoreCase(entry.name, base)) {
                                    found_real_base = try self.allocator.dupe(u8, entry.name);
                                    break;
                                }
                            }
                            
                            if (found_real_base) |real_base| {
                                defer self.allocator.free(real_base);
                                const real_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{parent, real_base});
                                defer self.allocator.free(real_path);
                                var real_dir = std.fs.cwd().openDir(real_path, .{ .iterate = true }) catch continue;
                                
                                var it = real_dir.iterate();
                                while (it.next() catch null) |entry| {
                                    if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                                        file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ real_path, entry.name });
                                        break;
                                    }
                                    const name_exe = std.fmt.allocPrint(self.allocator, "{s}.exe", .{name}) catch continue;
                                    defer self.allocator.free(name_exe);
                                    if (std.ascii.eqlIgnoreCase(entry.name, name_exe)) {
                                        file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ real_path, entry.name });
                                        break;
                                    }
                                    const name_dll = std.fmt.allocPrint(self.allocator, "{s}.dll", .{name}) catch continue;
                                    defer self.allocator.free(name_dll);
                                    if (std.ascii.eqlIgnoreCase(entry.name, name_dll)) {
                                        file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ real_path, entry.name });
                                        break;
                                    }
                                }
                                real_dir.close();
                                if (file_path != null) break;
                            }
                            continue;
                        };
                        defer dir.close();

                        var it = dir.iterate();
                        while (it.next() catch null) |entry| {
                            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                                file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                                break;
                            }

                            // Check if name + .exe matches
                            const name_exe = std.fmt.allocPrint(self.allocator, "{s}.exe", .{name}) catch continue;
                            defer self.allocator.free(name_exe);
                            if (std.ascii.eqlIgnoreCase(entry.name, name_exe)) {
                                file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                                break;
                            }

                            // Check if name + .dll matches
                            const name_dll = std.fmt.allocPrint(self.allocator, "{s}.dll", .{name}) catch continue;
                            defer self.allocator.free(name_dll);
                            if (std.ascii.eqlIgnoreCase(entry.name, name_dll)) {
                                file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                                std.log.info("Found match for {s} -> {s}", .{ name, file_path.? });
                                break;
                            }
                        }
                        if (file_path != null) break;
                    },
                    else => return err,
                }
            }
        }

        if (file_path) |path| {
            defer self.allocator.free(path);
            const mod = try Module.load(self.allocator, path);

            const mod_lower_name = try self.allocator.alloc(u8, mod.name.len);
            _ = std.ascii.lowerString(mod_lower_name, mod.name);

            try self.modules.put(mod_lower_name, mod);

            return mod;
        }

        return error.ModuleNotFound;
    }

    pub fn getExport(self: *Registry, dll_name: []const u8, func_name: []const u8) ?usize {
        const lower_name = self.allocator.alloc(u8, dll_name.len) catch return null;
        defer self.allocator.free(lower_name);
        _ = std.ascii.lowerString(lower_name, dll_name);

        if (self.modules.get(lower_name)) |mod| {
            return mod.getExport(func_name);
        }
        return null;
    }
};
