const std = @import("std");

fn stripDrive(path: []const u8) []const u8 {
    if (path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0])) {
        return path[2..];
    }
    return path;
}

fn resolvePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    
    const kernel32 = @import("../kernel32/misc.zig");
    if (kernel32.current_directory_len > 0) {
        // Copy cwd and ensure slashes
        var cwd_buf: [1024]u8 = undefined;
        const cwd_len = @min(kernel32.current_directory_len, 1023);
        @memcpy(cwd_buf[0..cwd_len], kernel32.current_directory[0..cwd_len]);
        std.mem.replaceScalar(u8, cwd_buf[0..cwd_len], '\\', '/');
        const cwd_slice = cwd_buf[0..cwd_len];
        
        // Strip trailing slash if present
        const clean_cwd = if (cwd_slice.len > 0 and cwd_slice[cwd_slice.len - 1] == '/')
            cwd_slice[0 .. cwd_slice.len - 1]
        else
            cwd_slice;
            
        // If cwd is just "." or "./", maybe we don't need to join, but join handles it.
        return std.fs.path.join(allocator, &[_][]const u8{ clean_cwd, path });
    }
    return allocator.dupe(u8, path);
}

fn tryLower(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    var last_slash: usize = 0;
    for (0..path.len) |i| {
        if (buf[i] == '/') last_slash = i + 1;
    }
    for (last_slash..path.len) |i| {
        buf[i] = std.ascii.toLower(buf[i]);
    }
    return buf[0..path.len];
}

/// Try case-insensitive match: scan parent directory for a filename that matches ignoring case.
fn tryCaseInsensitive(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len > buf.len) return null;

    // Find the last slash to split dir/filename
    var last_slash: usize = 0;
    var found_slash = false;
    for (0..path.len) |i| {
        if (path[i] == '/') {
            last_slash = i;
            found_slash = true;
        }
    }

    const filename = if (found_slash) path[last_slash + 1 ..] else path;
    if (filename.len == 0) return null;

    // Open the parent directory
    const dir: std.fs.Dir = open_dir: {
        if (found_slash) {
            const dir_path = path[0..last_slash];
            if (dir_path.len == 0 or (dir_path.len == 1 and dir_path[0] == '/')) {
                break :open_dir std.fs.openDirAbsolute("/", .{ .iterate = true }) catch return null;
            } else if (std.fs.path.isAbsolute(dir_path)) {
                break :open_dir std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch {
                    // Try recursing on parent directory too
                    var dir_buf: [1024]u8 = undefined;
                    const resolved = tryCaseInsensitive(dir_path, &dir_buf) orelse return null;
                    break :open_dir if (std.fs.path.isAbsolute(resolved))
                        std.fs.openDirAbsolute(resolved, .{ .iterate = true }) catch return null
                    else
                        std.fs.cwd().openDir(resolved, .{ .iterate = true }) catch return null;
                };
            } else {
                break :open_dir std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
            }
        } else {
            break :open_dir std.fs.cwd().openDir(".", .{ .iterate = true }) catch return null;
        }
    };
    defer @constCast(&dir).close();

    // Scan for a case-insensitive match
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.name.len == filename.len) {
            if (std.ascii.eqlIgnoreCase(entry.name, filename)) {
                // Found a match — reconstruct the full path
                if (found_slash) {
                    const dir_part = path[0 .. last_slash + 1];
                    const total = dir_part.len + entry.name.len;
                    if (total > buf.len) return null;
                    @memcpy(buf[0..dir_part.len], dir_part);
                    @memcpy(buf[dir_part.len..total], entry.name);
                    return buf[0..total];
                } else {
                    @memcpy(buf[0..entry.name.len], entry.name);
                    return buf[0..entry.name.len];
                }
            }
        }
    }
    return null;
}

fn fsStat(path: []const u8) ?std.fs.File.Stat {
    if (std.fs.path.isAbsolute(path)) {
        var dir = std.fs.openDirAbsolute("/", .{}) catch return null;
        defer dir.close();
        const rel_path = if (path.len > 0 and path[0] == '/') path[1..] else path;
        return dir.statFile(rel_path) catch null;
    } else {
        return std.fs.cwd().statFile(path) catch null;
    }
}

pub fn stat(path: [*:0]const u8) ?std.fs.File.Stat {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const span = std.mem.span(path);
    const resolved = resolvePath(arena.allocator(), span) catch span;
    const p = stripDrive(resolved);

    if (fsStat(p)) |s| {
        return s;
    } else {
        var buf: [1024]u8 = undefined;
        if (tryLower(p, &buf)) |lower_p| {
            if (fsStat(lower_p)) |s| {
                return s;
            }
        }
        var ci_buf: [1024]u8 = undefined;
        if (tryCaseInsensitive(p, &ci_buf)) |ci_path| {
            if (fsStat(ci_path)) |s| {
                return s;
            }
        }
    }
    return null;
}
fn fsAccess(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    } else {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }
}

fn fsCreateFile(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, flags);
    } else {
        return std.fs.cwd().createFile(path, flags);
    }
}

fn fsOpenFile(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, flags);
    } else {
        return std.fs.cwd().openFile(path, flags);
    }
}

pub fn access(path: [*:0]const u8, mode: i32) i32 {
    _ = mode;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const span = std.mem.span(path);
    const resolved = resolvePath(arena.allocator(), span) catch span;
    const p = stripDrive(resolved);
    
    if (fsAccess(p)) {
        return 0;
    } else {
        var buf: [1024]u8 = undefined;
        if (tryLower(p, &buf)) |lower_p| {
            if (fsAccess(lower_p)) {
                return 0;
            }
        }
        var ci_buf: [1024]u8 = undefined;
        if (tryCaseInsensitive(p, &ci_buf)) |ci_path| {
            if (fsAccess(ci_path)) {
                return 0;
            }
        }
        return -1;
    }
}

pub fn open(path: [*:0]const u8, flags: u32, mode: u32) i32 {
    _ = mode;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    
    const span = std.mem.span(path);
    const resolved = resolvePath(arena.allocator(), span) catch span;
    const p = stripDrive(resolved);
    
    const trace = @import("../../trace.zig");
    if (trace.enable_tracing) trace.print("POSIX_FS OPEN: {s} (flags {d})\n", .{p, flags});
    
    // O_RDONLY = 0, O_WRONLY = 1, O_RDWR = 2
    // O_CREAT = 0o100 (64)
    // O_TRUNC = 0o1000 (512)
    // O_APPEND = 0o2000 (1024)
    const O_WRONLY = 1;
    const O_RDWR = 2;
    const O_CREAT = 64;
    const O_TRUNC = 512;
    const O_APPEND = 1024;
    
    const is_write = (flags & O_WRONLY) != 0 or (flags & O_RDWR) != 0;
    const is_create = (flags & O_CREAT) != 0;
    const is_trunc = (flags & O_TRUNC) != 0;
    const is_append = (flags & O_APPEND) != 0;
    
    var file: std.fs.File = undefined;
    var attempt_path = p;
    var buf: [1024]u8 = undefined;
    
    var success = false;
    
    inline for (0..2) |attempt| {
        if (attempt == 1) {
            if (!success) {
                if (tryLower(p, &buf)) |lower_p| {
                    attempt_path = lower_p;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        
        if (is_write) {
            if (is_create) {
                if (fsCreateFile(attempt_path, .{
                    .read = (flags & O_RDWR) != 0,
                    .truncate = is_trunc,
                    .exclusive = false,
                })) |f| {
                    file = f;
                    success = true;
                } else |_| {}
            } else {
                if (fsOpenFile(attempt_path, .{
                    .mode = if ((flags & O_RDWR) != 0) .read_write else .write_only,
                })) |f| {
                    file = f;
                    success = true;
                    if (is_trunc) {
                        file.setEndPos(0) catch {};
                        file.seekTo(0) catch {};
                    }
                } else |_| {}
            }
            if (success and is_append) {
                file.seekFromEnd(0) catch {};
            }
        } else {
            if (fsOpenFile(attempt_path, .{ .mode = .read_only })) |f| {
                file = f;
                success = true;
            } else |_| {}
        }
    }
    
    if (success) {
        return @intCast(file.handle);
    }

    // Third attempt: case-insensitive directory scan
    var ci_buf: [1024]u8 = undefined;
    if (tryCaseInsensitive(p, &ci_buf)) |ci_path| {
        if (is_write) {
            if (is_create) {
                if (fsCreateFile(ci_path, .{
                    .read = (flags & O_RDWR) != 0,
                    .truncate = is_trunc,
                    .exclusive = false,
                })) |f| {
                    return @intCast(f.handle);
                } else |_| {}
            } else {
                if (fsOpenFile(ci_path, .{
                    .mode = if ((flags & O_RDWR) != 0) .read_write else .write_only,
                })) |f| {
                    if (is_trunc) {
                        f.setEndPos(0) catch {};
                        f.seekTo(0) catch {};
                    }
                    if (is_append) f.seekFromEnd(0) catch {};
                    return @intCast(f.handle);
                } else |_| {}
            }
        } else {
            if (fsOpenFile(ci_path, .{ .mode = .read_only })) |f| {
                return @intCast(f.handle);
            } else |_| {}
        }
    }
    return -1;
}
