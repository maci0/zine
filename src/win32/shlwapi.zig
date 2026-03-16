//! SHLWAPI.dll registration.

const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const stub_common = @import("shared.zig");

/// Registers SHLWAPI.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "SHLWAPI.dll";
    const s0 = stub_common.stub_args0;
    const s1 = stub_common.stub_args1;
    const s2 = stub_common.stub_args2;
    const s3 = stub_common.stub_args3;
    const s4 = stub_common.stub_args4;
    const s5 = stub_common.stub_args5;

    // Path functions
    try environment.addBuiltinExportComptime(m, "PathAppendW", s2);
    try environment.addBuiltinExportComptime(m, "PathCanonicalizeW", s2);
    try environment.addBuiltinExportComptime(m, "PathCommonPrefixW", s3);
    try environment.addBuiltinExportComptime(m, "PathCompactPathExW", s3);
    try environment.addBuiltinExportComptime(m, "PathFileExistsW", s1);
    try environment.addBuiltinExportComptime(m, "PathFindExtensionW", stub_PathFindExtensionW);
    try environment.addBuiltinExportComptime(m, "PathFindFileNameW", stub_PathFindFileNameW);
    try environment.addBuiltinExportComptime(m, "PathGetDriveNumberW", stub_PathGetDriveNumberW);
    try environment.addBuiltinExportComptime(m, "PathIsDirectoryW", s1);
    try environment.addBuiltinExportComptime(m, "PathIsPrefixW", s2);
    try environment.addBuiltinExportComptime(m, "PathIsRelativeW", stub_PathIsRelativeW);
    try environment.addBuiltinExportComptime(m, "PathIsRootW", s1);
    try environment.addBuiltinExportComptime(m, "PathIsUNCW", s1);
    try environment.addBuiltinExportComptime(m, "PathMatchSpecW", s2);
    try environment.addBuiltinExportComptime(m, "PathQuoteSpacesW", s1);
    try environment.addBuiltinExportComptime(m, "PathRelativePathToW", s5);
    try environment.addBuiltinExportComptime(m, "PathRemoveFileSpecW", stub_PathRemoveFileSpecW);
    try environment.addBuiltinExportComptime(m, "PathRenameExtensionW", s2);
    try environment.addBuiltinExportComptime(m, "PathStripToRootW", s1);
    try environment.addBuiltinExportComptime(m, "PathUnExpandEnvStringsW", s3);
    try environment.addBuiltinExportComptime(m, "PathUnquoteSpacesW", s1);

    // String functions
    try environment.addBuiltinExportComptime(m, "SHAutoComplete", s2);
    try environment.addBuiltinExportComptime(m, "StrCatBuffA", s3);
    try environment.addBuiltinExportComptime(m, "StrCatBuffW", s3);
    try environment.addBuiltinExportComptime(m, "StrCatW", s2);
    try environment.addBuiltinExportComptime(m, "StrChrA", s2);
    try environment.addBuiltinExportComptime(m, "StrChrIA", s2);
    try environment.addBuiltinExportComptime(m, "StrChrIW", s2);
    try environment.addBuiltinExportComptime(m, "StrChrW", s2);
    try environment.addBuiltinExportComptime(m, "StrCmpIW", s2);
    try environment.addBuiltinExportComptime(m, "StrCmpNA", s3);
    try environment.addBuiltinExportComptime(m, "StrCmpNIA", s3);
    try environment.addBuiltinExportComptime(m, "StrCmpNIW", s3);
    try environment.addBuiltinExportComptime(m, "StrCmpW", s2);
    try environment.addBuiltinExportComptime(m, "StrCpyNW", s3);
    try environment.addBuiltinExportComptime(m, "StrCpyW", s2);
    try environment.addBuiltinExportComptime(m, "StrDupA", stub_identity);
    try environment.addBuiltinExportComptime(m, "StrDupW", stub_identity);
    try environment.addBuiltinExportComptime(m, "StrFormatByteSizeW", s3);
    try environment.addBuiltinExportComptime(m, "StrNCatW", s3);
    try environment.addBuiltinExportComptime(m, "StrRChrW", s2);
    try environment.addBuiltinExportComptime(m, "StrRetToBufW", s4);
    try environment.addBuiltinExportComptime(m, "StrStrA", s2);
    try environment.addBuiltinExportComptime(m, "StrStrIA", s2);
    try environment.addBuiltinExportComptime(m, "StrStrIW", s2);
    try environment.addBuiltinExportComptime(m, "StrStrW", s2);
    try environment.addBuiltinExportComptime(m, "StrTrimA", s2);
    try environment.addBuiltinExportComptime(m, "StrTrimW", s2);
    try environment.addBuiltinExportComptime(m, "UrlEscapeW", s4);
    try environment.addBuiltinExportComptime(m, "UrlUnescapeW", s4);

    _ = s0;
}

fn stub_identity(ptr: usize) callconv(.c) usize {
    return ptr;
}

// --- Proper SHLWAPI path implementations ---

const w32cc = @import("calling_convention.zig");

// Helper: get wide string length
fn wcslen(ptr: usize) usize {
    if (ptr == 0) return 0;
    const s = @as([*]const u16, @ptrFromInt(ptr));
    var i: usize = 0;
    while (i < 32768 and s[i] != 0) i += 1;
    return i;
}

// PathRemoveFileSpecW: removes the trailing filename from a path
// "C:\foo\bar.exe" → "C:\foo"
// Returns TRUE if something was removed
fn stub_PathRemoveFileSpecW(pszPath: usize) callconv(w32cc.WINAPI) i32 {
    if (pszPath == 0) return 0;
    const path = @as([*]u16, @ptrFromInt(pszPath));
    const len = wcslen(pszPath);
    if (len == 0) return 0;

    // Find last backslash or forward slash
    var last_sep: ?usize = null;
    for (0..len) |i| {
        if (path[i] == '\\' or path[i] == '/') last_sep = i;
    }

    if (last_sep) |sep| {
        // Don't remove the trailing backslash if it's the root (e.g., "C:\")
        if (sep == 2 and len > 2 and path[1] == ':') {
            path[sep + 1] = 0;
        } else {
            path[sep] = 0;
        }
        if (trace.enable_tracing) {
            var buf: [512]u8 = undefined;
            const new_len = wcslen(pszPath);
            const show_len = @min(new_len, 511);
            for (0..show_len) |i| buf[i] = @intCast(path[i] & 0xFF);
            trace.print("SHLWAPI: PathRemoveFileSpecW -> '{s}'\n", .{buf[0..show_len]});
        }
        return 1; // TRUE
    }
    return 0;
}

// PathFindFileNameW: returns pointer to the filename part
fn stub_PathFindFileNameW(pszPath: usize) callconv(w32cc.WINAPI) usize {
    if (pszPath == 0) return pszPath;
    const path = @as([*]const u16, @ptrFromInt(pszPath));
    const len = wcslen(pszPath);
    if (len == 0) return pszPath;

    var last_sep: usize = 0;
    for (0..len) |i| {
        if (path[i] == '\\' or path[i] == '/') last_sep = i + 1;
    }
    return pszPath + last_sep * 2; // * 2 for u16 offset
}

// PathFindExtensionW: returns pointer to the extension start (including '.')
fn stub_PathFindExtensionW(pszPath: usize) callconv(w32cc.WINAPI) usize {
    if (pszPath == 0) return pszPath;
    const path = @as([*]const u16, @ptrFromInt(pszPath));
    const len = wcslen(pszPath);
    if (len == 0) return pszPath;

    // Find last dot after last separator
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
    // Return pointer to the null terminator
    return pszPath + len * 2;
}

// PathGetDriveNumberW: returns drive number (0=A, 1=B, 2=C, etc.) or -1
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

// PathIsRelativeW: returns TRUE if the path does not begin with drive letter or UNC
fn stub_PathIsRelativeW(pszPath: usize) callconv(w32cc.WINAPI) i32 {
    if (pszPath == 0) return 1; // null = relative
    const path = @as([*]const u16, @ptrFromInt(pszPath));
    // Check for "X:\" pattern
    if (path[0] != 0 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return 0;
    // Check for "\\" UNC
    if (path[0] == '\\' and path[1] == '\\') return 0;
    return 1;
}
