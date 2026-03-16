//! Module registry and search path management.
//!
//! This module implements the `Registry` struct, which tracks loaded modules
//! and handles case-insensitive DLL lookups across configurable search paths.

const std = @import("std");
const pe = @import("../pe.zig");
const Module = @import("module.zig").Module;
const builtin = @import("builtin");
const log = @import("../log.zig");
const is_wasi = builtin.os.tag == .wasi;

/// On WASI, resolve an absolute path through preopened directories.
/// Returns a Dir handle for the matching preopen and the relative sub-path.
/// Caller must close the returned Dir.
const ResolvedPath = struct {
    dir: std.fs.Dir,
    rel_path: []const u8,
};

fn resolveWasiPath(abs_path: []const u8) ?ResolvedPath {
    if (comptime !is_wasi) return null;
    // Iterate WASI preopened fds (start at fd 3, after stdin/stdout/stderr)
    var fd: std.os.wasi.fd_t = 3;
    while (true) : (fd += 1) {
        var prestat: std.os.wasi.prestat_t = undefined;
        switch (std.os.wasi.fd_prestat_get(fd, &prestat)) {
            .SUCCESS => {},
            .OPNOTSUPP, .BADF => break,
            else => break,
        }
        const name_len = prestat.u.dir.pr_name_len;
        var name_buf: [4096]u8 = undefined;
        if (name_len > name_buf.len) continue;
        switch (std.os.wasi.fd_prestat_dir_name(fd, &name_buf, name_len)) {
            .SUCCESS => {},
            else => continue,
        }
        const preopen_path = name_buf[0..name_len];

        // Check if the absolute path starts with this preopened dir path
        if (std.mem.startsWith(u8, abs_path, preopen_path)) {
            var rest = abs_path[preopen_path.len..];
            // Strip leading / from relative path
            if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
            if (rest.len == 0) rest = ".";
            return .{
                .dir = .{ .fd = fd },
                .rel_path = rest,
            };
        }
    }
    return null;
}

/// Check if a file exists by trying to open it. Works on WASI (unlike Dir.access).
fn fileExists(path: []const u8) bool {
    // On WASI, absolute paths must be resolved through preopened dirs
    if (comptime is_wasi) {
        if (std.fs.path.isAbsolute(path)) {
            if (resolveWasiPath(path)) |resolved| {
                // Don't close resolved.dir — it's a borrowed preopened fd
                const file = resolved.dir.openFile(resolved.rel_path, .{}) catch return false;
                file.close();
                return true;
            }
            return false;
        }
    }
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

/// Open a directory portably — resolves through WASI preopened dirs for absolute paths.
fn openDirPortable(path: []const u8, args: std.fs.Dir.OpenOptions) !std.fs.Dir {
    if (comptime is_wasi) {
        if (std.fs.path.isAbsolute(path)) {
            if (resolveWasiPath(path)) |resolved| {
                // Don't close resolved.dir — it's a borrowed preopened fd
                return resolved.dir.openDir(resolved.rel_path, args);
            }
            return error.FileNotFound;
        }
    }
    return std.fs.cwd().openDir(path, args);
}


/// The module registry manages loaded PE modules and search paths.
pub const Registry = struct {
    /// The allocator used for registry metadata.
    allocator: std.mem.Allocator,
    /// Mapping from lowercase DLL name to loaded Module instance.
    modules: std.StringHashMap(*Module),
    /// List of directories to search for DLLs.
    search_paths: std.ArrayListUnmanaged([]const u8),

    /// Initializes a new module registry.
    pub fn init(allocator: std.mem.Allocator) Registry {
        return Registry{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
            .search_paths = .{},
        };
    }

    /// Frees all loaded modules and search path strings.
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

    /// Adds a directory to the search path list.
    pub fn addSearchPath(self: *Registry, path: []const u8) !void {
        try self.search_paths.append(self.allocator, try self.allocator.dupe(u8, path));
    }

    /// Loads a PE module by name (or path), searching through registered search paths.
    /// Returns the loaded Module or an error if not found.
    pub fn loadModule(self: *Registry, name: []const u8) !*Module {
        const lower_name = try self.allocator.alloc(u8, name.len);
        defer self.allocator.free(lower_name);
        _ = std.ascii.lowerString(lower_name, name);

        if (self.modules.get(lower_name)) |mod| {
            return mod;
        }

        var file_path: ?[]const u8 = null;

        if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, '\\') != null) {
            const fixed_path = try self.allocator.alloc(u8, name.len);
            defer self.allocator.free(fixed_path);
            @memcpy(fixed_path, name);
            std.mem.replaceScalar(u8, fixed_path, '\\', '/');

            if (fileExists(fixed_path)) {
                file_path = try self.allocator.dupe(u8, fixed_path);
            } else {
                if (std.fs.path.dirname(fixed_path)) |dir| {
                    const base = std.fs.path.basename(fixed_path);
                    var d = openDirPortable(dir, .{ .iterate = true }) catch return error.ModuleNotFound;
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

        if (file_path == null) {
            for (self.search_paths.items) |path| {
                log.trace("Searching for {s} in {s}", .{ name, path });
                // Check exact match first
                const full_path_exact = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, name });
                defer self.allocator.free(full_path_exact);

                if (fileExists(full_path_exact)) {
                    file_path = try self.allocator.dupe(u8, full_path_exact);
                    break;
                }

                // Open the directory and search case-insensitively
                var dir = openDirPortable(path, .{ .iterate = true }) catch {
                    // If the path itself fails to open, it might be due to casing (e.g. BIN vs Bin)
                    // Check parent directory
                    const parent = std.fs.path.dirname(path) orelse continue;
                    const base = std.fs.path.basename(path);
                    var parent_dir = openDirPortable(parent, .{ .iterate = true }) catch continue;
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
                        const real_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent, real_base });
                        defer self.allocator.free(real_path);
                        var real_dir = openDirPortable(real_path, .{ .iterate = true }) catch continue;

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
                        log.info("Found match for {s} -> {s}", .{ name, file_path.? });
                        break;
                    }
                }
                if (file_path != null) break;
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

    /// Resolves an export from a loaded PE module.
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
