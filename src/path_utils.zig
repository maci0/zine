/// Win32 ↔ POSIX path translation utilities.
///
/// Drive mapping:
///   C:\  →  drive_c/     (virtual Windows drive)
///   Z:\  →  /            (full host filesystem, Wine-style)
///
/// When an exe is launched from `drive_c/`, its module paths use `C:\`.
/// Otherwise, absolute POSIX paths map through `Z:\`.
const std = @import("std");
const runtime = @import("runtime.zig");

/// The host-side folder that represents the C: drive root.
pub const DRIVE_ROOT = "drive_c/";
const drive_root_len: usize = DRIVE_ROOT.len;

/// The guest process's virtual current directory in Win32 form ("C:\...").
/// Canonical storage lives here so `toHostPath` and the kernel32
/// Get/SetCurrentDirectory stubs share one source of truth without this
/// module depending on win32/. Set at startup by main; mutated through
/// SetCurrentDirectory.
pub var current_directory: [1024]u8 = undefined;
/// Length in bytes of the valid prefix of `current_directory` (0 = unset).
pub var current_directory_len: usize = 0;

const builtin = @import("builtin");
const is_wasi = builtin.os.tag == .wasi;

/// On WASI, resolve an absolute path through preopened directories.
/// Returns a Dir handle for the matching preopen and the relative sub-path.
/// Caller must close the returned Dir.
pub const ResolvedPath = struct {
    dir: std.Io.Dir,
    rel_path: []const u8,
};

pub fn resolveWasiPath(abs_path: []const u8) ?ResolvedPath {
    if (comptime !is_wasi) return null;
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

        if (std.mem.startsWith(u8, abs_path, preopen_path)) {
            var rest = abs_path[preopen_path.len..];
            if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
            if (rest.len == 0) rest = ".";
            return .{
                .dir = .{ .handle = fd },
                .rel_path = rest,
            };
        }
    }
    return null;
}

/// Check if a POSIX path is inside drive_c/ (`drive_c/` or `drive_c\`).
pub fn isInsideDriveC(path: []const u8) bool {
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
pub fn win32ToPosix(win_path: []const u8, out: []u8) !usize {
    var src = win_path;

    // Strip UNC prefix `\\?\` or `\\.\`
    if (src.len >= 4 and src[0] == '\\' and src[1] == '\\' and (src[2] == '?' or src[2] == '.') and src[3] == '\\') {
        src = src[4..];
    }

    // Handle drive letter
    if (hasDriveLetter(src)) {
        const letter = std.ascii.toUpper(src[0]);
        src = std.mem.trimStart(u8, src[2..], "\\/");

        var pos: usize = 0;
        if (letter == 'Z') {
            // Z: drive = host filesystem root → /path
            pos = try appendBytes(out, pos, "/");
        } else {
            // C: (or any other) drive → drive_c/ prefix
            pos = try appendBytes(out, pos, DRIVE_ROOT);
        }
        pos = try appendConverted(out, pos, src, '\\', '/');
        return terminate(out, pos);
    }

    // No drive letter — check if root-relative or truly relative
    if (src.len > 0 and src[0] == '/') {
        // Forward-slash path: this is a POSIX host path (e.g. from LIB env var).
        // Pass it through unchanged — it's a real filesystem path.
        const pos = try appendBytes(out, 0, src);
        return terminate(out, pos);
    }

    if (src.len > 0 and src[0] == '\\') {
        // Backslash root-relative path: \project\game\... → drive_c/project/game/...
        // This is a Win32 convention for paths relative to the current drive root.
        src = std.mem.trimStart(u8, src, "\\");
        const pos = try appendBytes(out, 0, DRIVE_ROOT);
        const end = try appendConverted(out, pos, src, '\\', '/');
        return terminate(out, end);
    }

    // Truly relative path: game.ini, project/data/... → just convert slashes.
    // The caller (toHostPath) resolves these against the virtual CWD.
    const pos = try appendConverted(out, 0, src, '\\', '/');
    return terminate(out, pos);
}

/// Convert a POSIX path to a Win32 path.
///
/// `drive_c/Desktop/file.txt` → `C:\Desktop\file.txt`
/// `/home/user/foo`           → `Z:\home\user\foo`
/// `Desktop/file.txt`         → `C:\Desktop\file.txt`
///
/// Returns the number of bytes written to `out`.
pub fn posixToWin32(posix_path: []const u8, out: []u8) !usize {
    // Already has a drive letter? Just normalize slashes.
    if (hasDriveLetter(posix_path)) {
        const pos = try appendConverted(out, 0, posix_path, '/', '\\');
        return terminate(out, pos);
    }

    // Absolute POSIX path → Z:\...
    if (posix_path.len > 0 and posix_path[0] == '/') {
        var pos = try appendBytes(out, 0, "Z:\\");
        pos = try appendConverted(out, pos, posix_path[1..], '/', '\\');
        return terminate(out, pos);
    }

    // Relative path: strip drive_c/ prefix if present, prepend C:\
    var src = posix_path;
    if (isInsideDriveC(src)) {
        src = src[drive_root_len..];
    }
    var pos = try appendBytes(out, 0, "C:\\");
    pos = try appendConverted(out, pos, src, '/', '\\');
    return terminate(out, pos);
}

/// Append `bytes` to `out` starting at `pos`. Returns the new position,
/// or error.BufferTooSmall if `out` cannot hold all of `bytes`.
fn appendBytes(out: []u8, pos: usize, bytes: []const u8) !usize {
    if (pos + bytes.len > out.len) return error.BufferTooSmall;
    @memcpy(out[pos..][0..bytes.len], bytes);
    return pos + bytes.len;
}

/// Append `src` to `out` starting at `pos`, mapping each `from` separator
/// to `to`. Returns the new position, or error.BufferTooSmall.
fn appendConverted(out: []u8, pos: usize, src: []const u8, comptime from: u8, comptime to: u8) !usize {
    var end = pos;
    for (src) |c| {
        if (end >= out.len) return error.BufferTooSmall;
        out[end] = if (c == from) to else c;
        end += 1;
    }
    return end;
}

/// Write a NUL terminator at `out[pos]` and return `pos`.
/// Returns error.BufferTooSmall if the terminator does not fit.
fn terminate(out: []u8, pos: usize) !usize {
    if (pos < out.len) {
        out[pos] = 0;
        return pos;
    }
    return error.BufferTooSmall;
}

/// Check if a path has a drive letter prefix (e.g. `C:` or `z:`).
pub fn hasDriveLetter(path: []const u8) bool {
    return path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0]);
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

/// Component capacity of `normalizePath`'s in-place stack.
const MAX_PATH_COMPONENTS = 128;

/// Count the non-empty, '/'-separated components of a path.
fn countComponents(path: []const u8) usize {
    var count: usize = 0;
    var in_component = false;
    for (path) |c| {
        if (c == '/') {
            in_component = false;
        } else if (!in_component) {
            in_component = true;
            count += 1;
        }
    }
    return count;
}

/// Map a client-supplied virtual path (what the Web UI sends over the socket,
/// e.g. "Desktop/games") to a host path confined to drive_c/.
///
/// Unlike `toHostPath`, this rejects anything that could leave the sandbox:
/// absolute paths, drive letters, backslashes, NUL bytes, and `.`/`..`
/// components are refused outright rather than resolved. The result is written
/// to `out` (NUL-terminated) and its length returned, or 0 when the input is
/// unusable or does not fit.
pub fn virtualPathToDriveC(virtual_path: []const u8, out: []u8) usize {
    if (virtual_path.len == 0) return 0;
    if (std.mem.indexOfScalar(u8, virtual_path, 0) != null) return 0;
    if (std.mem.indexOfScalar(u8, virtual_path, '\\') != null) return 0;
    if (virtual_path[0] == '/') return 0;
    if (hasDriveLetter(virtual_path)) return 0;
    if (drive_root_len + virtual_path.len >= out.len) return 0;
    // normalizePath drops components past its stack capacity, which would
    // silently retarget the request at a different path. Refuse instead.
    if (countComponents(virtual_path) > MAX_PATH_COMPONENTS) return 0;

    var it = std.mem.splitScalar(u8, virtual_path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) continue;
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return 0;
    }

    @memcpy(out[0..drive_root_len], DRIVE_ROOT);
    @memcpy(out[drive_root_len..][0..virtual_path.len], virtual_path);
    const pos = drive_root_len + virtual_path.len;
    out[pos] = 0;
    return normalizePath(out, pos, drive_root_len);
}

/// Normalize a path in-place by resolving `.` and `..` components.
/// Prevents directory traversal attacks (e.g. `drive_c/game/../../etc/passwd`).
/// The `anchor` parameter specifies a prefix length that `..` cannot escape past
/// (e.g. length of "drive_c/" to keep paths inside the virtual drive).
fn normalizePath(buf: []u8, len: usize, anchor: usize) usize {
    // Split into components, resolve . and .., then rejoin.
    // We work in-place using a stack of component start offsets.
    var comp_starts: [MAX_PATH_COMPONENTS]usize = undefined;
    var comp_lens: [MAX_PATH_COMPONENTS]usize = undefined;
    var n_comps: usize = 0;

    var i: usize = anchor;
    while (i < len) {
        // Skip slashes
        while (i < len and buf[i] == '/') i += 1;
        if (i >= len) break;
        const start = i;
        while (i < len and buf[i] != '/') i += 1;
        const comp = buf[start..i];
        if (comp.len == 1 and comp[0] == '.') {
            // Skip "." component
            continue;
        } else if (comp.len == 2 and comp[0] == '.' and comp[1] == '.') {
            // Pop last component if we have one (but never go below anchor)
            if (n_comps > 0) n_comps -= 1;
        } else {
            if (n_comps < comp_starts.len) {
                comp_starts[n_comps] = start;
                comp_lens[n_comps] = comp.len;
                n_comps += 1;
            }
        }
    }

    // Rebuild the path: anchor prefix + normalized components
    var pos: usize = anchor;
    for (0..n_comps) |ci| {
        if (ci > 0 or (pos > 0 and buf[pos - 1] != '/')) {
            if (pos < buf.len) {
                buf[pos] = '/';
                pos += 1;
            }
        }
        const clen = comp_lens[ci];
        const src_start = comp_starts[ci];
        if (pos + clen <= buf.len) {
            // Copy component (may overlap, use manual copy)
            var j: usize = 0;
            while (j < clen) : (j += 1) {
                buf[pos + j] = buf[src_start + j];
            }
            pos += clen;
        }
    }
    if (pos < buf.len) buf[pos] = 0;
    return pos;
}

/// Convert any Win32 path to a host-usable POSIX path, resolving CWD and
/// case-insensitive filenames. This is the **single entry point** for path
/// resolution — all stubs should call this instead of assembling their own
/// mix of replaceScalar / win32ToPosix / stripDrive / resolvePath.
pub fn toHostPath(win_path: []const u8, out: []u8) usize {
    if (win_path.len == 0 or out.len < 2) return 0;

    // Step 1: Normalize into a scratch buffer (\ → /, strip ./ prefix)
    var scratch: [1024]u8 = undefined;
    if (win_path.len >= scratch.len) return 0;
    const initial_len = win_path.len;
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
            if (1 + rest.len >= out.len) return 0;
            out[0] = '/';
            @memcpy(out[1 .. 1 + rest.len], rest);
            const total = 1 + rest.len;
            out[total] = 0;
            // Normalize but anchor at "/" so .. can't escape root
            return normalizePath(out, total, 1);
        } else {
            // C: (or other) → drive_c/
            if (drive_root_len + rest.len >= out.len) return 0;
            @memcpy(out[0..drive_root_len], DRIVE_ROOT);
            @memcpy(out[drive_root_len .. drive_root_len + rest.len], rest);
            const pos = drive_root_len + rest.len;
            out[pos] = 0;
            // Normalize with anchor at drive_c/ so .. can't escape sandbox
            return normalizePath(out, pos, drive_root_len);
        }
    }

    // Step 4: Absolute POSIX path — pass through
    if (src.len > 0 and src[0] == '/') {
        if (src.len >= out.len) return 0;
        const abs_len = src.len;
        @memcpy(out[0..abs_len], src[0..abs_len]);
        out[abs_len] = 0;
        return abs_len;
    }

    // Step 5: already inside drive_c/
    if (isInsideDriveC(src)) {
        if (src.len >= out.len) return 0;
        const dc_len = src.len;
        @memcpy(out[0..dc_len], src[0..dc_len]);
        out[dc_len] = 0;
        // Normalize with anchor at drive_c/ so .. can't escape sandbox
        return normalizePath(out, dc_len, drive_root_len);
    }

    // Step 6: Relative path — resolve against virtual CWD
    if (current_directory_len > 0) {
        const cwd_win = current_directory[0..current_directory_len];
        var cwd_posix: [1024]u8 = undefined;
        const cwd_len = win32ToPosix(cwd_win, &cwd_posix) catch return 0;
        // Strip trailing slash
        var cwd_end = cwd_len;
        while (cwd_end > 0 and cwd_posix[cwd_end - 1] == '/') cwd_end -= 1;

        if (cwd_end + 1 + src.len < out.len) {
            @memcpy(out[0..cwd_end], cwd_posix[0..cwd_end]);
            out[cwd_end] = '/';
            @memcpy(out[cwd_end + 1 .. cwd_end + 1 + src.len], src[0..src.len]);
            const total = cwd_end + 1 + src.len;
            out[total] = 0;
            // Normalize: if CWD is inside drive_c, anchor there;
            // if absolute (starts with /), anchor at position 1 to preserve the root slash
            const anchor = if (isInsideDriveC(out[0..total]))
                drive_root_len
            else if (total > 0 and out[0] == '/')
                @as(usize, 1)
            else
                @as(usize, 0);
            return normalizePath(out, total, anchor);
        }
        return 0;
    }

    // Final fallback: just return the relative path with slashes fixed
    if (src.len >= out.len) return 0;
    const fb_len = src.len;
    @memcpy(out[0..fb_len], src[0..fb_len]);
    out[fb_len] = 0;
    return fb_len;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;

test "posixToWin32: drive_c/ prefix → C:\\" {
    var buf: [256]u8 = undefined;
    const len = try posixToWin32("drive_c/Desktop/file.txt", &buf);
    try testing.expectEqualStrings("C:\\Desktop\\file.txt", buf[0..len]);
}

test "posixToWin32: absolute POSIX → Z:\\" {
    var buf: [256]u8 = undefined;
    const len = try posixToWin32("/home/user/foo", &buf);
    try testing.expectEqualStrings("Z:\\home\\user\\foo", buf[0..len]);
}

test "posixToWin32: relative path → C:\\" {
    var buf: [256]u8 = undefined;
    const len = try posixToWin32("Desktop/file.txt", &buf);
    try testing.expectEqualStrings("C:\\Desktop\\file.txt", buf[0..len]);
}

test "posixToWin32: already has drive letter" {
    var buf: [256]u8 = undefined;
    const len = try posixToWin32("D:/games/run.exe", &buf);
    try testing.expectEqualStrings("D:\\games\\run.exe", buf[0..len]);
}

test "posixToWin32: root path" {
    var buf: [256]u8 = undefined;
    const len = try posixToWin32("/", &buf);
    try testing.expectEqualStrings("Z:\\", buf[0..len]);
}

test "win32ToPosix: C:\\ → drive_c/" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("C:\\Desktop\\file.txt", &buf);
    try testing.expectEqualStrings("drive_c/Desktop/file.txt", buf[0..len]);
}

test "win32ToPosix: Z:\\ → /" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("Z:\\home\\user\\foo", &buf);
    try testing.expectEqualStrings("/home/user/foo", buf[0..len]);
}

test "win32ToPosix: lowercase drive letter" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("c:\\test.txt", &buf);
    try testing.expectEqualStrings("drive_c/test.txt", buf[0..len]);
}

test "win32ToPosix: UNC prefix stripped" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("\\\\?\\C:\\Windows\\System32", &buf);
    try testing.expectEqualStrings("drive_c/Windows/System32", buf[0..len]);
}

test "win32ToPosix: backslash-rooted path → drive_c/" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("\\project\\game", &buf);
    try testing.expectEqualStrings("drive_c/project/game", buf[0..len]);
}

test "win32ToPosix: POSIX path passed through" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("/usr/lib/foo.so", &buf);
    try testing.expectEqualStrings("/usr/lib/foo.so", buf[0..len]);
}

test "win32ToPosix: relative path" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("game.ini", &buf);
    try testing.expectEqualStrings("game.ini", buf[0..len]);
}

test "hasDriveLetter: positive cases" {
    try testing.expect(hasDriveLetter("C:\\"));
    try testing.expect(hasDriveLetter("D:file"));
    try testing.expect(hasDriveLetter("z:\\path"));
}

test "hasDriveLetter: negative cases" {
    try testing.expect(!hasDriveLetter(""));
    try testing.expect(!hasDriveLetter("C"));
    try testing.expect(!hasDriveLetter("/path"));
    try testing.expect(!hasDriveLetter("1:bad"));
}

test "isInsideDriveC: positive" {
    try testing.expect(isInsideDriveC("drive_c/file.txt"));
    try testing.expect(isInsideDriveC("drive_c\\file.txt"));
}

test "isInsideDriveC: negative" {
    try testing.expect(!isInsideDriveC("drive_d/file.txt"));
    try testing.expect(!isInsideDriveC("/home/user"));
    try testing.expect(!isInsideDriveC(""));
    try testing.expect(!isInsideDriveC("drive_c")); // no trailing separator
}

test "win32ToPosix and posixToWin32 roundtrip" {
    // C:\ path roundtrip
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const posix_len = try win32ToPosix("C:\\Program Files\\app.exe", &buf1);
    const win_len = try posixToWin32(buf1[0..posix_len], &buf2);
    try testing.expectEqualStrings("C:\\Program Files\\app.exe", buf2[0..win_len]);
}

test "win32ToPosix: Z:\\ root only" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("Z:\\", &buf);
    try testing.expectEqualStrings("/", buf[0..len]);
}

test "win32ToPosix: drive_c/ already present in relative" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("drive_c/test/file.txt", &buf);
    try testing.expectEqualStrings("drive_c/test/file.txt", buf[0..len]);
}

test "normalizePath: removes .. components" {
    var buf: [256]u8 = undefined;
    const input = "drive_c/game/../../etc/passwd";
    @memcpy(buf[0..input.len], input);
    const len = normalizePath(&buf, input.len, drive_root_len);
    try testing.expectEqualStrings("drive_c/etc/passwd", buf[0..len]);
}

test "normalizePath: .. cannot escape anchor" {
    var buf: [256]u8 = undefined;
    const input = "drive_c/../../../../etc/passwd";
    @memcpy(buf[0..input.len], input);
    const len = normalizePath(&buf, input.len, drive_root_len);
    try testing.expectEqualStrings("drive_c/etc/passwd", buf[0..len]);
}

test "normalizePath: removes . components" {
    var buf: [256]u8 = undefined;
    const input = "drive_c/./game/./file.txt";
    @memcpy(buf[0..input.len], input);
    const len = normalizePath(&buf, input.len, drive_root_len);
    try testing.expectEqualStrings("drive_c/game/file.txt", buf[0..len]);
}

test "toHostPath: C: drive traversal is blocked" {
    var buf: [256]u8 = undefined;
    const len = toHostPath("C:\\game\\..\\..\\..\\..\\etc\\passwd", &buf);
    // Should stay inside drive_c/ — ".." cannot escape the sandbox
    const result = buf[0..len];
    try testing.expect(std.mem.startsWith(u8, result, "drive_c/"));
}

test "win32ToPosix: empty string" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("", &buf);
    try testing.expectEqual(@as(usize, 0), len);
}

test "posixToWin32: empty string becomes C:\\" {
    var buf: [256]u8 = undefined;
    const len = try posixToWin32("", &buf);
    // Empty relative path gets C:\ prefix (relative path handling)
    try testing.expectEqualStrings("C:\\", buf[0..len]);
}

test "toHostPath: empty string returns 0" {
    var buf: [256]u8 = undefined;
    const len = toHostPath("", &buf);
    try testing.expectEqual(@as(usize, 0), len);
}

test "toHostPath: insufficient capacity never returns a partial path" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "C:\\file.txt", .expected = "drive_c/file.txt" },
        .{ .input = "C:\\", .expected = "drive_c/" },
        .{ .input = "Z:\\file.txt", .expected = "/file.txt" },
        .{ .input = "/file.txt", .expected = "/file.txt" },
        .{ .input = "drive_c/file.txt", .expected = "drive_c/file.txt" },
        .{ .input = "file.txt", .expected = "file.txt" },
    };
    var buf: [64]u8 = undefined;
    for (cases) |case| {
        for (0..case.expected.len + 1) |capacity| {
            try testing.expectEqual(@as(usize, 0), toHostPath(case.input, buf[0..capacity]));
        }
        const len = toHostPath(case.input, buf[0 .. case.expected.len + 1]);
        try testing.expectEqualStrings(case.expected, buf[0..len]);
        try testing.expectEqual(@as(u8, 0), buf[len]);
    }
}

test "toHostPath: oversized input is rejected before truncation" {
    const input = [_]u8{'a'} ** 1024;
    var buf: [2048]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), toHostPath(&input, &buf));
}

test "toHostPath: insufficient capacity does not discard virtual CWD" {
    const saved_directory = current_directory;
    const saved_len = current_directory_len;
    defer {
        current_directory = saved_directory;
        current_directory_len = saved_len;
    }
    const cwd = "C:\\game";
    @memcpy(current_directory[0..cwd.len], cwd);
    current_directory_len = cwd.len;
    var buf: [64]u8 = undefined;
    const expected = "drive_c/game/file.txt";
    for (0..expected.len + 1) |capacity| {
        try testing.expectEqual(@as(usize, 0), toHostPath("file.txt", buf[0..capacity]));
    }
    const len = toHostPath("file.txt", buf[0 .. expected.len + 1]);
    try testing.expectEqualStrings(expected, buf[0..len]);
    try testing.expectEqual(@as(u8, 0), buf[len]);
}

test "virtualPathToDriveC: maps inside the sandbox" {
    var buf: [256]u8 = undefined;
    const len = virtualPathToDriveC("Desktop/games", &buf);
    try testing.expectEqualStrings("drive_c/Desktop/games", buf[0..len]);
    try testing.expectEqual(@as(u8, 0), buf[len]);
}

test "virtualPathToDriveC: rejects dot components" {
    var buf: [256]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), virtualPathToDriveC("Desktop/../Windows", &buf));
    try testing.expectEqual(@as(usize, 0), virtualPathToDriveC(".", &buf));
}

test "virtualPathToDriveC: refuses inputs that escape the sandbox" {
    const rejected = [_][]const u8{
        "/etc",
        "//etc/passwd",
        "C:\\Windows",
        "c:/Windows",
        ".",
        "..",
        "./Desktop",
        "Desktop/./games",
        "Desktop/../Windows",
        "Desktop/../../etc",
        "Desktop\\..\\..\\etc",
        "Desktop/\x00/etc",
        "",
    };
    var buf: [256]u8 = undefined;
    for (rejected) |path| {
        try testing.expectEqual(@as(usize, 0), virtualPathToDriveC(path, &buf));
    }
}

test "virtualPathToDriveC: rejects input that does not fit" {
    const input = [_]u8{'a'} ** 512;
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), virtualPathToDriveC(&input, &buf));
}

test "virtualPathToDriveC: rejects deeper paths than normalizePath can hold" {
    var deep_buf: [4096]u8 = undefined;
    const deep = "a/" ** 200 ++ "file.txt";
    var buf: [4096]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), virtualPathToDriveC(deep, &buf));
    // 128 components is still accepted and keeps its full depth.
    const ok_deep = "a/" ** 127 ++ "file.txt";
    const len = virtualPathToDriveC(ok_deep, &deep_buf);
    try testing.expect(std.mem.endsWith(u8, deep_buf[0..len], "a/file.txt"));
}

test "toHostPath: dot-backslash prefix stripped" {
    var buf: [256]u8 = undefined;
    const len = toHostPath(".\\file.txt", &buf);
    const result = buf[0..len];
    try testing.expectEqualStrings("file.txt", result);
}

test "toHostPath: Z: drive resolves to root" {
    var buf: [256]u8 = undefined;
    const len = toHostPath("Z:\\usr\\lib", &buf);
    try testing.expectEqualStrings("/usr/lib", buf[0..len]);
}

test "toHostPath: Z: drive traversal cannot escape root" {
    var buf: [256]u8 = undefined;
    const len = toHostPath("Z:\\..\\..\\..\\etc\\passwd", &buf);
    try testing.expectEqualStrings("/etc/passwd", buf[0..len]);
}

test "normalizePath: only dots" {
    var buf: [256]u8 = undefined;
    const input = "drive_c/./././.";
    @memcpy(buf[0..input.len], input);
    const len = normalizePath(&buf, input.len, drive_root_len);
    try testing.expectEqualStrings("drive_c/", buf[0..len]);
}

test "win32ToPosix: multiple trailing backslashes after drive" {
    var buf: [256]u8 = undefined;
    const len = try win32ToPosix("C:\\\\\\file.txt", &buf);
    try testing.expectEqualStrings("drive_c/file.txt", buf[0..len]);
}

test "hasDriveLetter: exactly two chars" {
    try testing.expect(hasDriveLetter("C:"));
    try testing.expect(!hasDriveLetter("C"));
    try testing.expect(!hasDriveLetter(":C"));
}

test "tryCaseInsensitiveResolve matches on-disk filename casing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = runtime.io();
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "ReadMe.TXT", .data = "x" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp_dir.dir.realPath(io, &dir_buf);
    const abs_dir = dir_buf[0..dir_len];

    var buf: [1024]u8 = undefined;

    // Wrong-case query resolves to the on-disk spelling.
    var query_buf: [1024]u8 = undefined;
    const wrong_case = try std.fmt.bufPrint(&query_buf, "{s}/readme.txt", .{abs_dir});
    const resolved = tryCaseInsensitiveResolve(wrong_case, &buf) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.endsWith(u8, resolved, "/ReadMe.TXT"));

    // Exact-case queries still resolve.
    const exact = try std.fmt.bufPrint(&query_buf, "{s}/ReadMe.TXT", .{abs_dir});
    try testing.expect(tryCaseInsensitiveResolve(exact, &buf) != null);

    // Missing files return null instead of fabricating a path.
    const missing = try std.fmt.bufPrint(&query_buf, "{s}/no_such_file.bin", .{abs_dir});
    try testing.expect(tryCaseInsensitiveResolve(missing, &buf) == null);
}

/// Case-insensitive path resolution: scan parent directory for matching filename.
pub fn tryCaseInsensitiveResolve(path: []const u8, buf: []u8) ?[]const u8 {
    if (comptime builtin.target.os.tag == .linux) return tryCaseInsensitiveResolveLinux(path, buf);
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

    const dir: std.Io.Dir = open_dir: {
        if (found_slash) {
            const dir_path = path[0..last_slash];
            if (dir_path.len == 0 or (dir_path.len == 1 and dir_path[0] == '/')) {
                resolved_dir[0] = '/';
                resolved_dir_len = 1;
                if (comptime !is_wasi) {
                    break :open_dir std.Io.Dir.openDirAbsolute(runtime.io(), "/", .{ .iterate = true }) catch return null;
                } else {
                    if (resolveWasiPath("/")) |resolved| {
                        break :open_dir resolved.dir.openDir(runtime.io(), resolved.rel_path, .{ .iterate = true }) catch return null;
                    }
                    return null;
                }
            }
            if (std.fs.path.isAbsolute(dir_path)) {
                if (comptime !is_wasi) {
                    if (std.Io.Dir.openDirAbsolute(runtime.io(), dir_path, .{ .iterate = true })) |d| {
                        @memcpy(resolved_dir[0..dir_path.len], dir_path);
                        resolved_dir_len = dir_path.len;
                        break :open_dir d;
                    } else |_| {}
                } else {
                    if (resolveWasiPath(dir_path)) |resolved| {
                        if (resolved.dir.openDir(runtime.io(), resolved.rel_path, .{ .iterate = true })) |d| {
                            @memcpy(resolved_dir[0..dir_path.len], dir_path);
                            resolved_dir_len = dir_path.len;
                            break :open_dir d;
                        } else |_| {}
                    }
                }
            } else {
                if (std.Io.Dir.cwd().openDir(runtime.io(), dir_path, .{ .iterate = true })) |d| {
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
            if (std.fs.path.isAbsolute(resolved)) {
                if (comptime !is_wasi) {
                    break :open_dir std.Io.Dir.openDirAbsolute(runtime.io(), resolved, .{ .iterate = true }) catch return null;
                } else {
                    if (resolveWasiPath(resolved)) |r| {
                        break :open_dir r.dir.openDir(runtime.io(), r.rel_path, .{ .iterate = true }) catch return null;
                    }
                    return null;
                }
            } else {
                break :open_dir std.Io.Dir.cwd().openDir(runtime.io(), resolved, .{ .iterate = true }) catch return null;
            }
        } else {
            break :open_dir std.Io.Dir.cwd().openDir(runtime.io(), ".", .{ .iterate = true }) catch return null;
        }
    };
    defer @constCast(&dir).close(runtime.io());

    var iter = dir.iterate();
    while (iter.next(runtime.io()) catch null) |entry| {
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

/// Linux native version of `tryCaseInsensitiveResolve` using only raw
/// syscalls (open + getdents64). std.Io.Dir iteration goes through
/// Io.Threaded (TLS), which faults when invoked from a stub running inside
/// the compat-mode SIGSEGV dispatch handler (FS points at the guest TEB).
fn tryCaseInsensitiveResolveLinux(path: []const u8, buf: []u8) ?[]const u8 {
    const linux = std.os.linux;

    var last_slash: usize = 0;
    var found_slash = false;
    for (0..path.len) |i| {
        if (path[i] == '/') {
            last_slash = i;
            found_slash = true;
        }
    }
    const filename = if (found_slash) path[last_slash + 1 ..] else path;
    if (filename.len == 0 or filename.len > 255) return null;

    // Build the directory path (NUL-terminated).
    var dir_buf: [std.posix.PATH_MAX]u8 = undefined;
    var dir_len: usize = 0;
    if (found_slash) {
        const dir_path = path[0..last_slash];
        if (dir_path.len == 0 or (dir_path.len == 1 and dir_path[0] == '/')) {
            dir_buf[0] = '/';
            dir_len = 1;
        } else {
            if (dir_path.len >= dir_buf.len) return null;
            @memcpy(dir_buf[0..dir_path.len], dir_path);
            dir_len = dir_path.len;
        }
    } else {
        dir_buf[0] = '.';
        dir_len = 1;
    }
    dir_buf[dir_len] = 0;

    const oflags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const open_rc = linux.open(@ptrCast(&dir_buf), oflags, 0);
    const fd: isize = @bitCast(open_rc);
    if (fd < 0) return null;

    var ent_buf: [4096]u8 align(8) = undefined;
    var matched_name: [256]u8 = undefined;
    var matched = false;
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
            if (name.len == filename.len and std.ascii.eqlIgnoreCase(name, filename)) {
                @memcpy(matched_name[0..name.len], name);
                matched = true;
                break;
            }
        }
        if (matched) break;
    }
    _ = linux.close(@intCast(fd));
    if (!matched) return null;

    if (found_slash) {
        const total = dir_len + 1 + filename.len;
        if (total > buf.len) return null;
        @memcpy(buf[0..dir_len], dir_buf[0..dir_len]);
        buf[dir_len] = '/';
        @memcpy(buf[dir_len + 1 .. total], matched_name[0..filename.len]);
        return buf[0..total];
    }
    if (filename.len > buf.len) return null;
    @memcpy(buf[0..filename.len], matched_name[0..filename.len]);
    return buf[0..filename.len];
}
