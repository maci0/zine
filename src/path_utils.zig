/// Win32 ↔ POSIX path translation utilities.
///
/// Drive mapping:
///   C:\  →  drive_c/     (virtual Windows drive)
///   Z:\  →  /            (full host filesystem, Wine-style)
///
/// When an exe is launched from `drive_c/`, its module paths use `C:\`.
/// Otherwise, absolute POSIX paths map through `Z:\`.

const std = @import("std");

/// The host-side folder that represents the C: drive root.
pub const DRIVE_ROOT = "drive_c/";
const drive_root_len: usize = 8; // "drive_c/".len

/// Check if a path starts with drive_c/ or drive_c\ (either slash direction).
fn startsWithDriveC(path: []const u8) bool {
    if (path.len < drive_root_len) return false;
    return std.mem.eql(u8, path[0..7], "drive_c") and (path[7] == '/' or path[7] == '\\');
}

/// Convert a Win32 path to a POSIX path for local file operations.
///
/// `C:\Desktop\file.txt`  → `drive_c/Desktop/file.txt`
/// `Z:\home\user\foo`     → `/home/user/foo`
/// `Desktop\file.txt`     → `drive_c/Desktop/file.txt` (relative → inside drive_c)
///
/// Returns the number of bytes written to `out`.
pub fn win32ToPosix(win_path: []const u8, out: []u8) usize {
    var src = win_path;

    // Strip UNC prefix `\\?\` or `\\.\`
    if (src.len >= 4 and src[0] == '\\' and src[1] == '\\' and (src[2] == '?' or src[2] == '.') and src[3] == '\\') {
        src = src[4..];
    }

    // Handle drive letter
    if (src.len >= 2 and src[1] == ':' and std.ascii.isAlphabetic(src[0])) {
        const letter = std.ascii.toUpper(src[0]);
        src = src[2..];

        // Strip leading separators after drive letter
        while (src.len > 0 and (src[0] == '\\' or src[0] == '/')) {
            src = src[1..];
        }

        if (letter == 'Z') {
            // Z: drive = host filesystem root → /path
            var pos: usize = 0;
            if (pos < out.len) {
                out[pos] = '/';
                pos += 1;
            }
            for (src) |c| {
                if (pos >= out.len) break;
                out[pos] = if (c == '\\') '/' else c;
                pos += 1;
            }
            if (pos < out.len) out[pos] = 0;
            return pos;
        } else {
            // C: (or any other) drive → drive_c/ prefix
            var pos: usize = 0;
            for (DRIVE_ROOT) |c| {
                if (pos >= out.len) break;
                out[pos] = c;
                pos += 1;
            }
            for (src) |c| {
                if (pos >= out.len) break;
                out[pos] = if (c == '\\') '/' else c;
                pos += 1;
            }
            if (pos < out.len) out[pos] = 0;
            return pos;
        }
    }

    // No drive letter — check if root-relative or truly relative
    if (src.len > 0 and src[0] == '/') {
        // Forward-slash path: this is a POSIX host path (e.g. from LIB env var).
        // Pass it through unchanged — it's a real filesystem path.
        var pos: usize = 0;
        for (src) |c| {
            if (pos >= out.len) break;
            out[pos] = c;
            pos += 1;
        }
        if (pos < out.len) out[pos] = 0;
        return pos;
    }

    if (src.len > 0 and src[0] == '\\') {
        // Backslash root-relative path: \project\game\... → drive_c/project/game/...
        // This is a Win32 convention for paths relative to the current drive root.
        while (src.len > 0 and src[0] == '\\') {
            src = src[1..];
        }
        var pos: usize = 0;
        for (DRIVE_ROOT) |c| {
            if (pos >= out.len) break;
            out[pos] = c;
            pos += 1;
        }
        for (src) |c| {
            if (pos >= out.len) break;
            out[pos] = if (c == '\\') '/' else c;
            pos += 1;
        }
        if (pos < out.len) out[pos] = 0;
        return pos;
    }

    // Truly relative path: game.ini, project/data/... → just convert slashes
    // posix_fs.resolvePath will prepend CWD
    var pos: usize = 0;
    // If already starts with drive_c/, don't modify
    if (startsWithDriveC(src)) {
        for (src) |c| {
            if (pos >= out.len) break;
            out[pos] = if (c == '\\') '/' else c;
            pos += 1;
        }
    } else {
        for (src) |c| {
            if (pos >= out.len) break;
            out[pos] = if (c == '\\') '/' else c;
            pos += 1;
        }
    }
    if (pos < out.len) out[pos] = 0;
    return pos;
}

/// Convert a POSIX path to a Win32 path.
///
/// `drive_c/Desktop/file.txt` → `C:\Desktop\file.txt`
/// `/home/user/foo`           → `Z:\home\user\foo`
/// `Desktop/file.txt`         → `C:\Desktop\file.txt`
///
/// Returns the number of bytes written to `out`.
pub fn posixToWin32(posix_path: []const u8, out: []u8) usize {
    var pos: usize = 0;

    // Already has a drive letter? Just normalize slashes.
    if (hasDriveLetter(posix_path)) {
        for (posix_path) |c| {
            if (pos >= out.len) break;
            out[pos] = if (c == '/') '\\' else c;
            pos += 1;
        }
        if (pos < out.len) out[pos] = 0;
        return pos;
    }

    // Absolute POSIX path → Z:\...
    if (posix_path.len > 0 and posix_path[0] == '/') {
        if (out.len >= 3) {
            out[0] = 'Z';
            out[1] = ':';
            out[2] = '\\';
            pos = 3;
        }
        for (posix_path[1..]) |c| { // skip leading /
            if (pos >= out.len) break;
            out[pos] = if (c == '/') '\\' else c;
            pos += 1;
        }
        if (pos < out.len) out[pos] = 0;
        return pos;
    }

    // Relative path: strip drive_c/ prefix if present, prepend C:\
    var src = posix_path;
    if (startsWithDriveC(src)) {
        src = src[drive_root_len..];
    }

    if (out.len >= 3) {
        out[0] = 'C';
        out[1] = ':';
        out[2] = '\\';
        pos = 3;
    }

    for (src) |c| {
        if (pos >= out.len) break;
        out[pos] = if (c == '/') '\\' else c;
        pos += 1;
    }

    if (pos < out.len) out[pos] = 0;
    return pos;
}

/// Check if a path has a drive letter prefix (e.g. `C:` or `z:`).
pub fn hasDriveLetter(path: []const u8) bool {
    return path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0]);
}

/// Check if a POSIX path is inside drive_c/.
pub fn isInsideDriveC(path: []const u8) bool {
    return startsWithDriveC(path);
}

/// Ensure the drive_c directory exists, creating it if needed.
pub fn ensureDriveRoot() void {
    std.fs.cwd().makeDir("drive_c") catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => {},
        }
    };
}

// ============================================================================
// Centralized Win32 → Host path resolution
// ============================================================================
//
// Every stub that handles a Win32 file path should call `toHostPath()`.
// It performs these steps in order:
//   1. Normalize \ → /
//   2. Strip ./ or .\ prefix ("same dir as me" on Windows)
//   3. Handle drive letters: Z:\path → /path, C:\path → drive_c/path
//   4. Resolve relative paths against the virtual CWD
//   5. Try case-insensitive filename fallback if file not found
//
// The result is written to `out` and the length is returned.
// Returns 0 if the input is empty/null.

/// Convert any Win32 path to a host-usable POSIX path, resolving CWD and
/// case-insensitive filenames. This is the **single entry point** for path
/// resolution — all stubs should call this instead of assembling their own
/// mix of replaceScalar / win32ToPosix / stripDrive / resolvePath.
pub fn toHostPath(win_path: []const u8, out: []u8) usize {
    if (win_path.len == 0 or out.len < 2) return 0;

    // Step 1: Normalize into a scratch buffer (\ → /, strip ./ prefix)
    var scratch: [1024]u8 = undefined;
    const initial_len = @min(win_path.len, scratch.len - 1);
    @memcpy(scratch[0..initial_len], win_path[0..initial_len]);
    std.mem.replaceScalar(u8, scratch[0..initial_len], '\\', '/');

    // Step 2: Strip "./" prefix (Win32 ".\foo" = "relative to my dir")
    var src = scratch[0..initial_len];
    if (src.len >= 2 and src[0] == '.' and src[1] == '/') {
        src = src[2..];
    }

    // Step 3: Handle drive letters
    if (src.len >= 2 and src[1] == ':' and std.ascii.isAlphabetic(src[0])) {
        const letter = std.ascii.toUpper(src[0]);
        var rest = src[2..];
        // Strip leading slashes after drive letter
        while (rest.len > 0 and rest[0] == '/') rest = rest[1..];

        if (letter == 'Z') {
            // Z: → host filesystem root
            out[0] = '/';
            const copy_len = @min(rest.len, out.len - 1);
            @memcpy(out[1 .. 1 + copy_len], rest[0..copy_len]);
            const total = 1 + copy_len;
            if (total < out.len) out[total] = 0;
            return total;
        } else {
            // C: (or other) → drive_c/
            const prefix = DRIVE_ROOT;
            var pos: usize = 0;
            for (prefix) |c| {
                if (pos >= out.len) break;
                out[pos] = c;
                pos += 1;
            }
            const copy_len = @min(rest.len, out.len - pos);
            @memcpy(out[pos .. pos + copy_len], rest[0..copy_len]);
            pos += copy_len;
            if (pos < out.len) out[pos] = 0;
            return pos;
        }
    }

    // Step 4: Absolute POSIX path — pass through
    if (src.len > 0 and src[0] == '/') {
        const abs_len = @min(src.len, out.len - 1);
        @memcpy(out[0..abs_len], src[0..abs_len]);
        if (abs_len < out.len) out[abs_len] = 0;
        return abs_len;
    }

    // Step 5: already inside drive_c/
    if (isInsideDriveC(src)) {
        const dc_len = @min(src.len, out.len - 1);
        @memcpy(out[0..dc_len], src[0..dc_len]);
        if (dc_len < out.len) out[dc_len] = 0;
        return dc_len;
    }

    // Step 6: Relative path — resolve against virtual CWD
    const kernel32_misc = @import("win32/kernel32/misc.zig");
    if (kernel32_misc.current_directory_len > 0) {
        const cwd_win = kernel32_misc.current_directory[0..kernel32_misc.current_directory_len];
        var cwd_posix: [1024]u8 = undefined;
        const cwd_len = win32ToPosix(cwd_win, &cwd_posix);
        // Strip trailing slash
        var cwd_end = cwd_len;
        while (cwd_end > 0 and cwd_posix[cwd_end - 1] == '/') cwd_end -= 1;

        if (cwd_end + 1 + src.len < out.len) {
            @memcpy(out[0..cwd_end], cwd_posix[0..cwd_end]);
            out[cwd_end] = '/';
            @memcpy(out[cwd_end + 1 .. cwd_end + 1 + src.len], src[0..src.len]);
            const total = cwd_end + 1 + src.len;
            if (total < out.len) out[total] = 0;
            return total;
        }
    }

    // Final fallback: just return the relative path with slashes fixed
    const fb_len = @min(src.len, out.len - 1);
    @memcpy(out[0..fb_len], src[0..fb_len]);
    if (fb_len < out.len) out[fb_len] = 0;
    return fb_len;
}

/// Quick file existence check using a Win32 path. Uses `toHostPath` internally.
pub fn fileExistsHost(win_path: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const len = toHostPath(win_path, &buf);
    if (len == 0) return false;
    const p = buf[0..len];
    if (std.fs.path.isAbsolute(p)) {
        var dir = std.fs.openDirAbsolute("/", .{}) catch return false;
        defer dir.close();
        _ = dir.statFile(p[1..]) catch return false;
        return true;
    } else {
        _ = std.fs.cwd().statFile(p) catch return false;
        return true;
    }
}

// --- Internal helpers for toHostPath ---

/// If the path doesn't exist on disk, try lowercasing the filename component.
/// Returns the (possibly corrected) length. Output is written in-place to `out`.
fn tryFixCase(path: []const u8, out: []u8) usize {
    // First, check if file exists as-is
    if (hostPathExists(path)) return path.len;

    // Try lowercasing just the filename
    var last_slash: usize = 0;
    for (0..path.len) |i| {
        if (path[i] == '/') {
            last_slash = i + 1;
        }
    }

    // Lowercase the filename portion in-place
    for (last_slash..path.len) |i| {
        out[i] = std.ascii.toLower(out[i]);
    }
    if (hostPathExists(out[0..path.len])) return path.len;

    // Try full case-insensitive directory scan
    var ci_buf: [1024]u8 = undefined;
    if (tryCaseInsensitiveResolve(path, &ci_buf)) |ci_path| {
        const copy_len = @min(ci_path.len, out.len - 1);
        @memcpy(out[0..copy_len], ci_path[0..copy_len]);
        if (copy_len < out.len) out[copy_len] = 0;
        return copy_len;
    }

    // Restore original case (undo lowercase) and return as-is
    @memcpy(out[0..path.len], path);
    return path.len;
}

fn hostPathExists(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) {
        var dir = std.fs.openDirAbsolute("/", .{}) catch return false;
        defer dir.close();
        _ = dir.statFile(if (path[0] == '/') path[1..] else path) catch return false;
        return true;
    } else {
        _ = std.fs.cwd().statFile(path) catch return false;
        return true;
    }
}

/// Case-insensitive path resolution: scan parent directory for matching filename.
pub fn tryCaseInsensitiveResolve(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len > buf.len) return null;

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

    var resolved_dir: [1024]u8 = undefined;
    var resolved_dir_len: usize = 0;

    const dir: std.fs.Dir = open_dir: {
        if (found_slash) {
            const dir_path = path[0..last_slash];
            if (dir_path.len == 0 or (dir_path.len == 1 and dir_path[0] == '/')) {
                resolved_dir[0] = '/';
                resolved_dir_len = 1;
                break :open_dir std.fs.openDirAbsolute("/", .{ .iterate = true }) catch return null;
            }
            if (std.fs.path.isAbsolute(dir_path)) {
                if (std.fs.openDirAbsolute(dir_path, .{ .iterate = true })) |d| {
                    @memcpy(resolved_dir[0..dir_path.len], dir_path);
                    resolved_dir_len = dir_path.len;
                    break :open_dir d;
                } else |_| {}
            } else {
                if (std.fs.cwd().openDir(dir_path, .{ .iterate = true })) |d| {
                    @memcpy(resolved_dir[0..dir_path.len], dir_path);
                    resolved_dir_len = dir_path.len;
                    break :open_dir d;
                } else |_| {}
            }
            // Recurse on parent directory
            var dir_buf: [1024]u8 = undefined;
            const resolved = tryCaseInsensitiveResolve(dir_path, &dir_buf) orelse return null;
            @memcpy(resolved_dir[0..resolved.len], resolved);
            resolved_dir_len = resolved.len;
            if (std.fs.path.isAbsolute(resolved))
                break :open_dir std.fs.openDirAbsolute(resolved, .{ .iterate = true }) catch return null
            else
                break :open_dir std.fs.cwd().openDir(resolved, .{ .iterate = true }) catch return null;
        } else {
            break :open_dir std.fs.cwd().openDir(".", .{ .iterate = true }) catch return null;
        }
    };
    defer @constCast(&dir).close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.name.len == filename.len) {
            if (std.ascii.eqlIgnoreCase(entry.name, filename)) {
                if (found_slash) {
                    const total = resolved_dir_len + 1 + entry.name.len;
                    if (total > buf.len) return null;
                    @memcpy(buf[0..resolved_dir_len], resolved_dir[0..resolved_dir_len]);
                    buf[resolved_dir_len] = '/';
                    @memcpy(buf[resolved_dir_len + 1 .. total], entry.name);
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
