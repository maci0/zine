const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

/// Implementation status: Stub
pub fn stub_ShellExecuteA(hwnd: usize, lpOperation: usize, lpFile: usize, lpParameters: usize, lpDirectory: usize, nShowCmd: i32) callconv(w32cc.WINAPI) usize {
    _ = hwnd;
    _ = lpOperation;
    _ = lpParameters;
    _ = lpDirectory;
    _ = nShowCmd;
    if (trace.enable_tracing) {
        const file = if (lpFile != 0) trace.c_span(lpFile) else "(null)";
        trace.print("SHELL32: ShellExecuteA('{s}')\n", .{file});
    }
    return 33; // > 32 means success
}

/// Implementation status: Stub
pub fn stub_DragFinish(hDrop: usize) callconv(w32cc.WINAPI) void {
    _ = hDrop;
    if (trace.enable_tracing) trace.print("SHELL32: DragFinish\n", .{});
}

/// Implementation status: Stub
pub fn stub_DragAcceptFiles(hWnd: usize, fAccept: i32) callconv(w32cc.WINAPI) void {
    _ = hWnd;
    _ = fAccept;
    if (trace.enable_tracing) trace.print("SHELL32: DragAcceptFiles\n", .{});
}

/// Implementation status: Stub
pub fn stub_DragQueryFileA(hDrop: usize, iFile: u32, lpszFile: usize, cch: u32) callconv(w32cc.WINAPI) u32 {
    _ = hDrop;
    _ = iFile;
    _ = lpszFile;
    _ = cch;
    if (trace.enable_tracing) trace.print("SHELL32: DragQueryFileA\n", .{});
    return 0;
}

/// Implementation status: Stub
pub fn stub_DragQueryFileW(hDrop: usize, iFile: u32, lpszFile: usize, cch: u32) callconv(w32cc.WINAPI) u32 {
    _ = hDrop;
    _ = iFile;
    _ = lpszFile;
    _ = cch;
    if (trace.enable_tracing) trace.print("SHELL32: DragQueryFileW\n", .{});
    return 0;
}

/// Implementation status: Partially implemented
pub fn SHGetFileInfoA(pszPath: usize, dwFileAttributes: u32, psfi: usize, cbFileInfo: u32, uFlags: u32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        const path = if (pszPath != 0) trace.c_span(pszPath) else "(null)";
        trace.print("SHELL32: SHGetFileInfoA('{s}', attrs=0x{X}, flags=0x{X})\n", .{ path, dwFileAttributes, uFlags });
    }

    // SHFILEINFOA struct layout (32-bit):
    // HICON  hIcon;          // offset 0, 4 bytes
    // int    iIcon;          // offset 4, 4 bytes
    // DWORD  dwAttributes;   // offset 8, 4 bytes
    // char   szDisplayName[MAX_PATH]; // offset 12, 260 bytes
    // char   szTypeName[80]; // offset 272, 80 bytes
    // Total: 352 bytes
    const SHGFI_ICON: u32 = 0x000000100;
    const SHGFI_DISPLAYNAME: u32 = 0x000000200;
    const SHGFI_TYPENAME: u32 = 0x000000400;
    const SHGFI_SYSICONINDEX: u32 = 0x000004000;

    if (psfi != 0 and cbFileInfo > 0) {
        // Zero the struct first
        const clear_size: usize = @min(@as(usize, cbFileInfo), 352);
        @memset(@as([*]u8, @ptrFromInt(psfi))[0..clear_size], 0);

        if ((uFlags & SHGFI_ICON) != 0) {
            // Return a dummy HICON handle (non-zero = success)
            @as(*u32, @ptrFromInt(psfi)).* = 0x0000BEEF;
        }

        if ((uFlags & SHGFI_SYSICONINDEX) != 0) {
            // iIcon = system image list index (dummy = 1)
            @as(*i32, @ptrFromInt(psfi + 4)).* = 1;
        }

        if ((uFlags & SHGFI_DISPLAYNAME) != 0) {
            // Copy filename to szDisplayName at offset 12
            if (pszPath != 0) {
                const name = trace.c_span(pszPath);
                // Find last backslash to get basename
                var basename_start: usize = 0;
                for (name, 0..) |c, i| {
                    if (c == '\\' or c == '/') basename_start = i + 1;
                }
                const basename = name[basename_start..];
                const display_ptr = @as([*]u8, @ptrFromInt(psfi + 12));
                const copy_len = @min(basename.len, 259);
                @memcpy(display_ptr[0..copy_len], basename[0..copy_len]);
            }
        }

        if ((uFlags & SHGFI_TYPENAME) != 0) {
            // Write type name at offset 272
            const type_ptr = @as([*]u8, @ptrFromInt(psfi + 272));
            const type_str = "Application";
            @memcpy(type_ptr[0..type_str.len], type_str);
        }
    }

    return 1; // Success (non-zero)
}

/// SHGetSpecialFolderLocation — returns a PIDL for a special folder.
/// We use a simple encoding: the PIDL is a small allocated buffer containing
/// the CSIDL value so SHGetPathFromIDList can decode it.
pub fn SHGetSpecialFolderLocation(hwndOwner: usize, nFolder: i32, ppidl: usize) callconv(w32cc.WINAPI) i32 {
    _ = hwndOwner;
    if (trace.enable_tracing) trace.print("SHELL32: SHGetSpecialFolderLocation(folder={d})\n", .{nFolder});
    if (ppidl == 0) return @bitCast(@as(u32, 0x80004003)); // E_POINTER

    // Allocate a fake PIDL: [cb=6(u16)][csidl(u16)][padding(u16)][terminator cb=0(u16)]
    const mem = @import("../kernel32/mem.zig");
    const pidl_size: usize = 8;
    const pidl_ptr = mem.raw_alloc(pidl_size) orelse return @bitCast(@as(u32, 0x8007000E)); // E_OUTOFMEMORY
    const buf = @as([*]u16, @ptrCast(@alignCast(pidl_ptr)));
    buf[0] = 6; // cb = size of this SHITEMID (6 bytes: cb + 4 data bytes)
    buf[1] = @bitCast(@as(i16, @truncate(nFolder))); // store CSIDL
    buf[2] = 0; // padding
    buf[3] = 0; // terminator SHITEMID (cb=0)

    @as(*u32, @ptrFromInt(ppidl)).* = @truncate(@intFromPtr(pidl_ptr));
    return 0; // S_OK
}

/// SHGetPathFromIDListA — converts a PIDL to a filesystem path.
/// Recognizes our fake PIDLs from SHGetSpecialFolderLocation.
pub fn stub_SHGetPathFromIDListA(pidl: usize, pszPath: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("SHELL32: SHGetPathFromIDListA(pidl={x})\n", .{pidl});
    if (pidl == 0 or pszPath == 0) return 0;

    const buf = @as(*const [4]u16, @ptrFromInt(pidl));
    const cb = buf[0];
    if (cb == 6) {
        // Our fake PIDL — decode CSIDL
        const csidl = @as(i16, @bitCast(buf[1]));
        const path: []const u8 = switch (csidl) {
            0x00 => "C:\\Desktop", // CSIDL_DESKTOP
            0x05 => "C:\\My Documents", // CSIDL_PERSONAL
            0x14 => "C:\\WINDOWS\\Fonts", // CSIDL_FONTS
            0x1A => "C:\\Users\\User\\AppData\\Roaming", // CSIDL_APPDATA
            0x24 => "C:\\WINDOWS", // CSIDL_WINDOWS
            0x25 => "C:\\WINDOWS\\SYSTEM32", // CSIDL_SYSTEM
            0x26 => "C:\\Program Files", // CSIDL_PROGRAM_FILES
            else => "C:\\",
        };
        const dst = @as([*]u8, @ptrFromInt(pszPath));
        @memcpy(dst[0..path.len], path);
        dst[path.len] = 0;
        if (trace.enable_tracing) trace.print("SHELL32: SHGetPathFromIDListA -> '{s}'\n", .{path});
        return 1; // TRUE
    }

    // Unknown PIDL format — return empty
    @as(*u8, @ptrFromInt(pszPath)).* = 0;
    return 0;
}

/// Implementation status: Stub
pub fn stub_SHBrowseForFolderA(lpbi: usize) callconv(w32cc.WINAPI) usize {
    _ = lpbi;
    if (trace.enable_tracing) trace.print("SHELL32: SHBrowseForFolderA\n", .{});
    return 0; // cancelled
}

/// Implementation status: Stub
pub fn stub_ExtractIconA(hInst: usize, pszExeFileName: usize, nIconIndex: u32) callconv(w32cc.WINAPI) usize {
    _ = hInst;
    if (trace.enable_tracing) {
        const name = if (pszExeFileName != 0) trace.c_span(pszExeFileName) else "(null)";
        trace.print("SHELL32: ExtractIconA('{s}', index={d})\n", .{ name, nIconIndex });
    }
    // Return a dummy non-zero HICON handle to indicate success.
    // Win32 contract: returns NULL on failure, 1 if file has no icons,
    // or a valid HICON on success.
    return 0x0000BEEF; // Dummy icon handle
}

/// Implementation status: No-op fallback
pub fn stub_Shell_NotifyIconA(dwMessage: u32, lpData: usize) callconv(w32cc.WINAPI) i32 {
    _ = dwMessage;
    _ = lpData;
    if (trace.enable_tracing) trace.print("SHELL32: Shell_NotifyIconA\n", .{});
    return 1;
}

/// Implementation status: Partially implemented
pub fn ShellAboutW(hWnd: usize, szApp: usize, szOtherStuff: usize, hIcon: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = hIcon;
    if (trace.enable_tracing) trace.print("SHELL32: ShellAboutW\n", .{});

    const window = @import("../user32/window.zig");
    const renderer = if (@import("builtin").target.os.tag != .windows) @import("../../gui/renderer.zig") else return 1;

    const app_name = if (szApp != 0) window.wideToUtf8(szApp) else "Application";
    const extra = if (szOtherStuff != 0) window.wideToUtf8(szOtherStuff) else "";

    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "{s}\n" ++
            "{s}" ++
            "{s}" ++
            "\n" ++
            "Microsoft Windows 2000\n" ++
            "5.00.2195\n" ++
            "\n" ++
            "Powered by zine — Win2K emulation layer\n" ++
            "github.com/maci0/zine",
        .{
            app_name,
            extra,
            if (extra.len > 0) "\n" else "",
        },
    ) catch app_name;

    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "About {s}", .{app_name}) catch "About";

    renderer.showMessageBox(title, text);
    return 1;
}
