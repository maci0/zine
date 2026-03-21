//! SHLWAPI.dll export definitions
//! Stubs written directly since the original file mixes registration code with implementations.

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub_PathRemoveFileSpecW, .{ .name = "PathRemoveFileSpecW" });
    @export(&stub_PathFindFileNameW, .{ .name = "PathFindFileNameW" });
    @export(&stub_PathFindExtensionW, .{ .name = "PathFindExtensionW" });
    @export(&stub_PathGetDriveNumberW, .{ .name = "PathGetDriveNumberW" });
    @export(&stub_PathIsRelativeW, .{ .name = "PathIsRelativeW" });
    @export(&stub_identity, .{ .name = "StrDupA" });
    @export(&stub_identity, .{ .name = "StrDupW" });
    @export(&stub_ret0_1, .{ .name = "PathFileExistsW" });
    @export(&stub_ret0_1, .{ .name = "PathIsRootW" });
    @export(&stub_ret0_1, .{ .name = "PathIsUNCW" });
    @export(&stub_ret0_1, .{ .name = "PathIsDirectoryW" });
    @export(&stub_ret0_1, .{ .name = "PathQuoteSpacesW" });
    @export(&stub_ret0_1, .{ .name = "PathStripToRootW" });
    @export(&stub_ret0_1, .{ .name = "PathUnquoteSpacesW" });
    @export(&stub_ret0_2, .{ .name = "PathAppendW" });
    @export(&stub_ret0_2, .{ .name = "PathCanonicalizeW" });
    @export(&stub_ret0_2, .{ .name = "PathMatchSpecW" });
    @export(&stub_ret0_2, .{ .name = "PathRenameExtensionW" });
    @export(&stub_ret0_2, .{ .name = "SHAutoComplete" });
    @export(&stub_ret0_2, .{ .name = "StrCatW" });
    @export(&stub_ret0_2, .{ .name = "StrChrA" });
    @export(&stub_ret0_2, .{ .name = "StrChrIA" });
    @export(&stub_ret0_2, .{ .name = "StrChrIW" });
    @export(&stub_ret0_2, .{ .name = "StrChrW" });
    @export(&stub_ret0_2, .{ .name = "StrCmpIW" });
    @export(&stub_ret0_2, .{ .name = "StrCmpW" });
    @export(&stub_ret0_2, .{ .name = "StrCpyW" });
    @export(&stub_ret0_2, .{ .name = "StrIsPrefixW" });
    @export(&stub_ret0_2, .{ .name = "StrRChrW" });
    @export(&stub_ret0_2, .{ .name = "StrStrA" });
    @export(&stub_ret0_2, .{ .name = "StrStrIA" });
    @export(&stub_ret0_2, .{ .name = "StrStrIW" });
    @export(&stub_ret0_2, .{ .name = "StrStrW" });
    @export(&stub_ret0_2, .{ .name = "StrTrimA" });
    @export(&stub_ret0_2, .{ .name = "StrTrimW" });
    @export(&stub_ret0_3, .{ .name = "PathCommonPrefixW" });
    @export(&stub_ret0_3, .{ .name = "PathCompactPathExW" });
    @export(&stub_ret0_3, .{ .name = "StrCatBuffA" });
    @export(&stub_ret0_3, .{ .name = "StrCatBuffW" });
    @export(&stub_ret0_3, .{ .name = "StrCmpNA" });
    @export(&stub_ret0_3, .{ .name = "StrCmpNIA" });
    @export(&stub_ret0_3, .{ .name = "StrCmpNIW" });
    @export(&stub_ret0_3, .{ .name = "StrCpyNW" });
    @export(&stub_ret0_3, .{ .name = "StrFormatByteSizeW" });
    @export(&stub_ret0_3, .{ .name = "StrNCatW" });
    @export(&stub_ret0_3, .{ .name = "PathUnExpandEnvStringsW" });
    @export(&stub_ret0_4, .{ .name = "StrRetToBufW" });
    @export(&stub_ret0_4, .{ .name = "UrlEscapeW" });
    @export(&stub_ret0_4, .{ .name = "UrlUnescapeW" });
    @export(&stub_ret0_5, .{ .name = "PathRelativePathToW" });
}

fn stub_identity(ptr: usize) callconv(.c) usize {
    return ptr;
}
fn stub_ret0_1(a: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    return 0;
}
fn stub_ret0_2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b };
    return 0;
}
fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c };
    return 0;
}
fn stub_ret0_4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d };
    return 0;
}
fn stub_ret0_5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e };
    return 0;
}

fn wcslen_helper(ptr: usize) usize {
    if (ptr == 0) return 0;
    const s = @as([*]const u16, @ptrFromInt(ptr));
    var i: usize = 0;
    while (i < 32768 and s[i] != 0) i += 1;
    return i;
}

fn stub_PathRemoveFileSpecW(pszPath: usize) callconv(w32cc.WINAPI) i32 {
    if (pszPath == 0) return 0;
    const path = @as([*]u16, @ptrFromInt(pszPath));
    const len = wcslen_helper(pszPath);
    if (len == 0) return 0;
    var last_sep: ?usize = null;
    for (0..len) |i| {
        if (path[i] == '\\' or path[i] == '/') last_sep = i;
    }
    if (last_sep) |sep| {
        if (sep == 2 and len > 2 and path[1] == ':') {
            path[sep + 1] = 0;
        } else {
            path[sep] = 0;
        }
        return 1;
    }
    return 0;
}

fn stub_PathFindFileNameW(pszPath: usize) callconv(w32cc.WINAPI) usize {
    if (pszPath == 0) return pszPath;
    const path = @as([*]const u16, @ptrFromInt(pszPath));
    const len = wcslen_helper(pszPath);
    if (len == 0) return pszPath;
    var last_sep: usize = 0;
    for (0..len) |i| {
        if (path[i] == '\\' or path[i] == '/') last_sep = i + 1;
    }
    return pszPath + last_sep * 2;
}

fn stub_PathFindExtensionW(pszPath: usize) callconv(w32cc.WINAPI) usize {
    if (pszPath == 0) return pszPath;
    const path = @as([*]const u16, @ptrFromInt(pszPath));
    const len = wcslen_helper(pszPath);
    if (len == 0) return pszPath;
    var last_dot: ?usize = null;
    var last_sep: usize = 0;
    for (0..len) |i| {
        if (path[i] == '\\' or path[i] == '/') {
            last_sep = i + 1;
            last_dot = null;
        }
        if (path[i] == '.') last_dot = i;
    }
    if (last_dot) |dot| {
        if (dot >= last_sep) return pszPath + dot * 2;
    }
    return pszPath + len * 2;
}

fn stub_PathGetDriveNumberW(pszPath: usize) callconv(w32cc.WINAPI) i32 {
    if (pszPath == 0) return -1;
    const path = @as([*]const u16, @ptrFromInt(pszPath));
    if (path[1] == ':') {
        const c = path[0];
        if (c >= 'A' and c <= 'Z') return @intCast(c - 'A');
        if (c >= 'a' and c <= 'z') return @intCast(c - 'a');
    }
    return -1;
}

fn stub_PathIsRelativeW(pszPath: usize) callconv(w32cc.WINAPI) i32 {
    if (pszPath == 0) return 1;
    const path = @as([*]const u16, @ptrFromInt(pszPath));
    if (path[0] != 0 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return 0;
    if (path[0] == '\\' and path[1] == '\\') return 0;
    return 1;
}
