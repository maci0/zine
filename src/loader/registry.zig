//! Module registry and search path management.
//!
//! This module implements the `Registry` struct, which tracks loaded modules
//! and handles case-insensitive DLL lookups across configurable search paths.

const std = @import("std");
const runtime = @import("../runtime.zig");
const pe = @import("../pe.zig");
const Module = @import("module.zig").Module;
const builtin = @import("builtin");
const log = @import("../log.zig");
const trace = @import("../trace.zig");
const path_utils = @import("../path_utils.zig");
const is_wasi = builtin.os.tag == .wasi;

/// Check if a file exists by trying to open it. Works on WASI (unlike Dir.access).
fn fileExists(path: []const u8) bool {
    if (comptime builtin.os.tag == .linux) {
        // Raw faccessat: std.Io.Dir.openFile touches TLS, which faults when
        // called from a stub inside the compat-mode SIGSEGV dispatch handler.
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        if (path.len >= buf.len) return false;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, @ptrCast(&buf), 0, 0); // F_OK
        return @as(isize, @bitCast(rc)) == 0;
    }
    // On WASI, absolute paths must be resolved through preopened dirs
    if (comptime is_wasi) {
        if (std.fs.path.isAbsolute(path)) {
            if (path_utils.resolveWasiPath(path)) |resolved| {
                // Don't close resolved.dir — it's a borrowed preopened fd
                const file = resolved.dir.openFile(runtime.io(), resolved.rel_path, .{}) catch return false;
                file.close(runtime.io());
                return true;
            }
            return false;
        }
        // Relative paths normally go through the WASI cwd (fd 3), but hosts
        // may not place the cwd first (zine-host puts "/" at fd 3). Try the
        // path against every preopened dir so it works regardless of order.
        var fd2: std.os.wasi.fd_t = 3;
        while (true) : (fd2 += 1) {
            var prestat: std.os.wasi.prestat_t = undefined;
            switch (std.os.wasi.fd_prestat_get(fd2, &prestat)) {
                .SUCCESS => {},
                else => break,
            }
            const dir = std.Io.Dir{ .handle = fd2 };
            if (dir.openFile(runtime.io(), path, .{})) |f| {
                f.close(runtime.io());
                return true;
            } else |_| {}
        }
    }
    const file = std.Io.Dir.cwd().openFile(runtime.io(), path, .{}) catch return false;
    file.close(runtime.io());
    return true;
}

/// Device and inode of a file, the identity a mapped image is reused by.
const FileId = struct {
    dev_major: u32,
    dev_minor: u32,
    ino: u64,
};

/// statx mask for the fields fileIdLinux reads.
const statx_mask: std.os.linux.STATX = .{ .TYPE = true, .INO = true };

/// Device and inode of `path`, or null when the host cannot report it.
/// std.Io is avoided for the same reason fileExists avoids it: the TLS it
/// touches faults in the compat-mode SIGSEGV dispatch handler.
fn fileIdLinux(path: []const u8) ?FileId {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, @ptrCast(&buf), std.os.linux.AT.SYMLINK_NOFOLLOW, statx_mask, &st);
    if (@as(isize, @bitCast(rc)) < 0 or !st.mask.INO) return null;
    return .{ .dev_major = st.dev_major, .dev_minor = st.dev_minor, .ino = st.ino };
}

/// Whether `a` and `b` name the same file. Guest paths reach the registry in
/// several spellings of one file (`\` for `/`, a relative or absolute root, a
/// different case), so on Linux the comparison is by device and inode; hosts
/// that cannot report those fall back to the normalized path text.
fn sameFile(a: []const u8, b: []const u8) bool {
    if (comptime builtin.os.tag == .linux) {
        if (fileIdLinux(a)) |ida| {
            if (fileIdLinux(b)) |idb| return std.meta.eql(ida, idb);
        }
    }
    return pathsEqualCi(a, b);
}

/// Path text comparison after separator normalization, case-insensitive to
/// match the guest's case-insensitive view of the file system.
fn pathsEqualCi(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na = if (ca == '\\') '/' else ca;
        const nb = if (cb == '\\') '/' else cb;
        if (std.ascii.toLower(na) != std.ascii.toLower(nb)) return false;
    }
    return true;
}

/// Case-insensitive exact filename match.
fn nameEqualsCi(name: []const u8, base: []const u8) bool {
    return name.len == base.len and std.ascii.eqlIgnoreCase(name, base);
}

/// Case-insensitive filename match against `base`, `base.exe`, or `base.dll`
/// (Windows module-search semantics).
fn nameMatchesModuleCi(name: []const u8, base: []const u8) bool {
    const suffixes = [_][]const u8{ "", ".exe", ".dll" };
    for (suffixes) |sfx| {
        if (name.len != base.len + sfx.len) continue;
        if (!std.ascii.eqlIgnoreCase(name[0..base.len], base)) continue;
        if (std.ascii.eqlIgnoreCase(name[base.len..], sfx)) return true;
    }
    return false;
}

/// Raw getdents64 scan of `dir_path` for an entry matching `base` via
/// `matches`. Returns a "dir/EntryName" path in `out`, or null.
fn scanDirEntriesCi(dir_path: []const u8, base: []const u8, out: []u8, comptime matches: fn ([]const u8, []const u8) bool) ?[]const u8 {
    const linux = std.os.linux;
    if (base.len == 0 or base.len > 255) return null;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    if (dir_path.len >= buf.len) return null;
    @memcpy(buf[0..dir_path.len], dir_path);
    buf[dir_path.len] = 0;
    const open_rc = linux.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    const fd: isize = @bitCast(open_rc);
    if (fd < 0) return null;
    defer _ = linux.close(@intCast(fd));

    var ent_buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n_rc = linux.getdents64(@intCast(fd), &ent_buf, ent_buf.len);
        const n: isize = @bitCast(n_rc);
        if (n <= 0) break;
        var pos: usize = 0;
        while (pos < @as(usize, @intCast(n))) {
            const d = @as(*align(1) linux.dirent64, @ptrCast(ent_buf[pos..].ptr));
            const name_ptr: [*:0]const u8 = @ptrCast(&d.name);
            const name = std.mem.sliceTo(name_ptr, 0);
            pos += d.reclen;
            if (matches(name, base)) {
                const total = dir_path.len + 1 + name.len;
                if (total >= out.len) return null;
                @memcpy(out[0..dir_path.len], dir_path);
                out[dir_path.len] = '/';
                @memcpy(out[dir_path.len + 1 .. total], name);
                return out[0..total];
            }
        }
    }
    return null;
}

/// Raw getdents64 scan for a case-insensitive filename match (Linux only).
/// Returns a "dir/Name" path in `out`, or null. std.Io.Dir iteration goes
/// through Io.Threaded (TLS), which faults in the compat signal context.
fn findDirEntryCiLinux(dir_path: []const u8, base: []const u8, out: []u8) ?[]const u8 {
    return scanDirEntriesCi(dir_path, base, out, nameEqualsCi);
}

/// Raw getdents64 scan of `dir_path` for a module entry matching `base`
/// (see findDirEntryCiLinux for why std.Io is avoided). Returns a
/// "dir/EntryName" path in `out`, or null.
fn findModuleEntryCiLinux(dir_path: []const u8, base: []const u8, out: []u8) ?[]const u8 {
    return scanDirEntriesCi(dir_path, base, out, nameMatchesModuleCi);
}

/// Open a directory portably — resolves through WASI preopened dirs for absolute paths.
fn openDirPortable(path: []const u8, args: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (comptime builtin.os.tag == .linux) {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        if (path.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const rc = std.os.linux.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        const fd: isize = @bitCast(rc);
        if (fd < 0) return error.FileNotFound;
        return std.Io.Dir{ .handle = @intCast(fd) };
    }
    if (comptime is_wasi) {
        if (std.fs.path.isAbsolute(path)) {
            if (path_utils.resolveWasiPath(path)) |resolved| {
                // Don't close resolved.dir — it's a borrowed preopened fd
                return resolved.dir.openDir(runtime.io(), resolved.rel_path, args);
            }
            return error.FileNotFound;
        }
        // Relative path: try every preopened dir (cwd fd 3 may be "/" under
        // zine-host, so a cwd-relative open would fail).
        var fd2: std.os.wasi.fd_t = 3;
        while (true) : (fd2 += 1) {
            var prestat: std.os.wasi.prestat_t = undefined;
            switch (std.os.wasi.fd_prestat_get(fd2, &prestat)) {
                .SUCCESS => {},
                else => break,
            }
            const dir = std.Io.Dir{ .handle = fd2 };
            if (dir.openDir(runtime.io(), path, args)) |d| return d else |_| {}
        }
        return error.FileNotFound;
    }
    return std.Io.Dir.cwd().openDir(runtime.io(), path, args);
}

/// The module registry manages loaded PE modules and search paths.
pub const Registry = struct {
    /// The allocator used for registry metadata.
    allocator: std.mem.Allocator,
    /// Mapping from lowercase DLL name to loaded Module instance.
    modules: std.StringHashMap(*Module),
    /// The same modules in the order they were loaded. Anything that walks
    /// every module (import resolution, or a name that two modules share)
    /// reads this instead of the map, whose iteration order follows the hash
    /// of the keys and so is not the order the guest caused.
    load_order: std.ArrayListUnmanaged(*Module),
    /// List of directories to search for DLLs.
    search_paths: std.ArrayListUnmanaged([]const u8),

    /// Initializes a new module registry.
    pub fn init(allocator: std.mem.Allocator) Registry {
        return Registry{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
            .load_order = .empty,
            .search_paths = .empty,
        };
    }

    /// Frees all loaded modules and search path strings.
    pub fn deinit(self: *Registry) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.modules.deinit();
        self.load_order.deinit(self.allocator);

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
                    if (comptime builtin.os.tag == .linux) {
                        var ci_buf: [std.fs.max_path_bytes]u8 = undefined;
                        if (findDirEntryCiLinux(dir, base, &ci_buf)) |ci_path| {
                            file_path = try self.allocator.dupe(u8, ci_path);
                        }
                    } else {
                        var d = openDirPortable(dir, .{ .iterate = true }) catch return error.ModuleNotFound;
                        defer d.close(runtime.io());
                        var it = d.iterate();
                        while (it.next(runtime.io()) catch null) |entry| {
                            if (std.ascii.eqlIgnoreCase(entry.name, base)) {
                                file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, entry.name });
                                break;
                            }
                        }
                    }
                }
            }
        }

        if (file_path == null) {
            for (self.search_paths.items) |path| {
                trace.print("Searching for {s} in {s}", .{ name, path });
                // Check exact match first
                const full_path_exact = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, name });
                defer self.allocator.free(full_path_exact);

                if (fileExists(full_path_exact)) {
                    file_path = try self.allocator.dupe(u8, full_path_exact);
                    break;
                }

                // Open the directory and search case-insensitively
                if (comptime builtin.os.tag == .linux) {
                    // Raw getdents64 scans: std.Io.Dir iteration goes through
                    // Io.Threaded (TLS), which faults inside the compat-mode
                    // SIGSEGV dispatch handler (FS points at the guest TEB).
                    var scan_buf: [std.fs.max_path_bytes]u8 = undefined;
                    if (findModuleEntryCiLinux(path, name, &scan_buf)) |found| {
                        file_path = try self.allocator.dupe(u8, found);
                        break;
                    }
                    // Casing fallback: the search dir itself may use different
                    // case (e.g. BIN vs Bin) — resolve it via the parent scan.
                    if (std.fs.path.dirname(path)) |parent| {
                        const base = std.fs.path.basename(path);
                        var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
                        if (findDirEntryCiLinux(parent, base, &parent_buf)) |real_dir| {
                            if (findModuleEntryCiLinux(real_dir, name, &scan_buf)) |found| {
                                file_path = try self.allocator.dupe(u8, found);
                                break;
                            }
                        }
                    }
                } else {
                    var dir = openDirPortable(path, .{ .iterate = true }) catch {
                        // If the path itself fails to open, it might be due to casing (e.g. BIN vs Bin)
                        // Check parent directory
                        const parent = std.fs.path.dirname(path) orelse continue;
                        const base = std.fs.path.basename(path);
                        var parent_dir = openDirPortable(parent, .{ .iterate = true }) catch continue;
                        defer parent_dir.close(runtime.io());

                        var found_real_base: ?[]const u8 = null;
                        var p_it = parent_dir.iterate();
                        while (p_it.next(runtime.io()) catch null) |entry| {
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
                            const real_name_exe = try std.fmt.allocPrint(self.allocator, "{s}.exe", .{name});
                            defer self.allocator.free(real_name_exe);
                            const real_name_dll = try std.fmt.allocPrint(self.allocator, "{s}.dll", .{name});
                            defer self.allocator.free(real_name_dll);
                            while (it.next(runtime.io()) catch null) |entry| {
                                if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                                    file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ real_path, entry.name });
                                    break;
                                }
                                if (std.ascii.eqlIgnoreCase(entry.name, real_name_exe)) {
                                    file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ real_path, entry.name });
                                    break;
                                }
                                if (std.ascii.eqlIgnoreCase(entry.name, real_name_dll)) {
                                    file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ real_path, entry.name });
                                    break;
                                }
                            }
                            real_dir.close(runtime.io());
                            if (file_path != null) break;
                        }
                        continue;
                    };
                    defer dir.close(runtime.io());

                    var it = dir.iterate();
                    // Built once per directory, not once per entry: the
                    // extension variants are compared against every name the
                    // directory holds.
                    const name_exe = try std.fmt.allocPrint(self.allocator, "{s}.exe", .{name});
                    defer self.allocator.free(name_exe);
                    const name_dll = try std.fmt.allocPrint(self.allocator, "{s}.dll", .{name});
                    defer self.allocator.free(name_dll);
                    while (it.next(runtime.io()) catch null) |entry| {
                        if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                            file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                            break;
                        }

                        if (std.ascii.eqlIgnoreCase(entry.name, name_exe)) {
                            file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                            break;
                        }

                        if (std.ascii.eqlIgnoreCase(entry.name, name_dll)) {
                            file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                            log.info("Found match for {s} -> {s}", .{ name, file_path.? });
                            break;
                        }
                    }
                    if (file_path != null) break;
                }
            }
        }

        if (file_path) |path| {
            defer self.allocator.free(path);

            // Entries are keyed by the module's own basename, so a request
            // spelled as a path misses the lookup above. Re-check by basename
            // before loading a second copy of an already-mapped image: two
            // mappings of one DLL give the guest two module bases for the same
            // file, each with its own writable data, and leak the first. The
            // basename only narrows the search; the file itself must match, or
            // a same-named file from another directory would be served in
            // place of the one requested.
            if (self.cachedFile(path)) |mod| return mod;

            const mod = try Module.load(self.allocator, path);
            errdefer mod.deinit();

            const mod_lower_name = try self.allocator.alloc(u8, mod.name.len);
            errdefer self.allocator.free(mod_lower_name);
            _ = std.ascii.lowerString(mod_lower_name, mod.name);

            // A different file already owns this basename. Windows keeps one
            // module per name, so refusing keeps the guest from seeing two
            // images under one name; overwriting the entry would strand the
            // first mapping with nothing left to free it.
            if (self.modules.get(mod_lower_name)) |existing| {
                if (!sameFile(existing.path, mod.path)) {
                    log.err("Module {s} is already loaded from {s}, refusing {s}", .{ mod.name, existing.path, mod.path });
                    return error.ModuleAlreadyLoaded;
                }
                mod.deinit();
                return existing;
            }

            try self.modules.put(mod_lower_name, mod);
            errdefer _ = self.modules.remove(mod_lower_name);
            try self.load_order.append(self.allocator, mod);

            return mod;
        }

        return error.ModuleNotFound;
    }

    /// Returns the already-loaded module mapped from the same file as `path`.
    /// Used to avoid mapping one image twice when a later request names it by a
    /// different spelling. A same-named file in another directory is a
    /// different image and is not returned.
    fn cachedFile(self: *Registry, path: []const u8) ?*Module {
        const base = std.fs.path.basename(path);
        if (base.len == 0) return null;
        const key = self.allocator.alloc(u8, base.len) catch return null;
        defer self.allocator.free(key);
        _ = std.ascii.lowerString(key, base);
        const mod = self.modules.get(key) orelse return null;
        if (!sameFile(mod.path, path)) return null;
        return mod;
    }

    /// Every loaded module, oldest first. The order a guest caused, so a walk
    /// over it resolves imports and picks between same-named modules the same
    /// way on every run.
    pub fn modulesInLoadOrder(self: *const Registry) []const *Module {
        return self.load_order.items;
    }

    /// Looks a loaded module up by the name the guest passed, matching its
    /// basename case-insensitively. Two modules can share a basename (the
    /// registry keys by basename), so the first one loaded wins: the answer
    /// depends on the guest's own load sequence, not on map order.
    pub fn findModuleByName(self: *const Registry, name: []const u8) ?*Module {
        var basename = name;
        for (name, 0..) |c, i| {
            if (c == '\\' or c == '/') basename = name[i + 1 ..];
        }
        for (self.load_order.items) |m| {
            if (std.ascii.eqlIgnoreCase(m.name, basename)) return m;
        }
        return null;
    }

    /// Finds the loaded module whose mapping starts at `handle`, the guest
    /// HINSTANCE form. A handle that names no mapping is not readable: every
    /// offset inside such an image would be unchecked.
    pub fn moduleForHandle(self: *const Registry, handle: usize) ?*Module {
        var it = self.modules.valueIterator();
        while (it.next()) |m| {
            if (@intFromPtr(m.*.mapped_memory.ptr) == handle) return m.*;
        }
        return null;
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

const testing = std.testing;

test "registry: name lookup follows load order, not map order" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();

    // Two mappings sharing a basename cannot both be keyed, so the first one
    // loaded has to be the answer for every later request. Stand-ins:
    // deinit would try to unmap them, so drop them from the table first.
    var first: Module = undefined;
    first.name = "game.dll";
    var second: Module = undefined;
    second.name = "other.dll";
    try reg.modules.put("game.dll", &first);
    try reg.load_order.append(testing.allocator, &first);
    try reg.modules.put("other.dll", &second);
    try reg.load_order.append(testing.allocator, &second);
    defer {
        _ = reg.modules.fetchRemove("game.dll");
        _ = reg.modules.fetchRemove("other.dll");
    }

    try testing.expectEqualSlices(*Module, &.{ &first, &second }, reg.modulesInLoadOrder());
    // Any spelling of the name, and any case, finds the same module.
    try testing.expect(reg.findModuleByName("GAME.DLL") == &first);
    try testing.expect(reg.findModuleByName("bin\\game.dll") == &first);
    try testing.expect(reg.findModuleByName("other.dll") == &second);
    try testing.expect(reg.findModuleByName("missing.dll") == null);
}

test "registry: cachedFile reuses a mapping only for the same file" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();

    // Stand-in for a mapped module: cachedFile only reads its path, but
    // deinit would try to unmap it, so drop it from the table first.
    var stand_in: Module = undefined;
    stand_in.path = "bin/game.dll";
    try reg.modules.put("game.dll", &stand_in);
    defer _ = reg.modules.fetchRemove("game.dll");

    // Same file, other spellings: no file exists here, so the comparison falls
    // back to the normalized path text.
    try testing.expect(reg.cachedFile("bin/GAME.DLL") == &stand_in);
    try testing.expect(reg.cachedFile("./bin/game.dll") != &stand_in);
    // Same basename, different directory: a different image.
    try testing.expect(reg.cachedFile("other/game.dll") == null);
    try testing.expect(reg.cachedFile("bin/other.dll") == null);
    try testing.expect(reg.cachedFile("") == null);
}

test "registry: sameFile separates two real files sharing a basename" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.createDirPath(testing.io, "b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/game.dll", .data = "first" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b/game.dll", .data = "second" });

    // sameFile takes a path, not a Dir, so resolve each file the way the
    // loader would see it. Spelling the temp root out by hand would make the
    // test silently fall back to path text the moment the layout changed,
    // which is the very branch this test exists to reject.
    const a = try tmp.dir.realPathFileAlloc(testing.io, "a/game.dll", testing.allocator);
    defer testing.allocator.free(a);
    const b = try tmp.dir.realPathFileAlloc(testing.io, "b/game.dll", testing.allocator);
    defer testing.allocator.free(b);

    // The inode path must be the one under test; a null id means the test
    // would pass on the fallback alone.
    if (comptime builtin.os.tag == .linux) {
        const ida = fileIdLinux(a) orelse return error.TestUnexpectedResult;
        const idb = fileIdLinux(b) orelse return error.TestUnexpectedResult;
        try testing.expect(ida.ino != idb.ino);
    }

    try testing.expect(!sameFile(a, b));
    try testing.expect(sameFile(a, a));
    // A `./` segment in the text must not change the identity.
    const dir_a = try tmp.dir.realPathFileAlloc(testing.io, "a", testing.allocator);
    defer testing.allocator.free(dir_a);
    var alias_buf: [std.fs.max_path_bytes]u8 = undefined;
    const a_alias = try std.fmt.bufPrint(&alias_buf, "{s}/./game.dll", .{dir_a});
    try testing.expect(sameFile(a, a_alias));
}
