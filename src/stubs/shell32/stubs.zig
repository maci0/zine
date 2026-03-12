const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../../calling_convention.zig");


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

pub fn stub_DragFinish(hDrop: usize) callconv(w32cc.WINAPI) void {
    _ = hDrop;
    if (trace.enable_tracing) trace.print("SHELL32: DragFinish\n", .{});
}

pub fn stub_DragAcceptFiles(hWnd: usize, fAccept: i32) callconv(w32cc.WINAPI) void {
    _ = hWnd;
    _ = fAccept;
    if (trace.enable_tracing) trace.print("SHELL32: DragAcceptFiles\n", .{});
}

pub fn stub_DragQueryFileA(hDrop: usize, iFile: u32, lpszFile: usize, cch: u32) callconv(w32cc.WINAPI) u32 {
    _ = hDrop;
    _ = iFile;
    _ = lpszFile;
    _ = cch;
    if (trace.enable_tracing) trace.print("SHELL32: DragQueryFileA\n", .{});
    return 0;
}

pub fn stub_DragQueryFileW(hDrop: usize, iFile: u32, lpszFile: usize, cch: u32) callconv(w32cc.WINAPI) u32 {
    _ = hDrop;
    _ = iFile;
    _ = lpszFile;
    _ = cch;
    if (trace.enable_tracing) trace.print("SHELL32: DragQueryFileW\n", .{});
    return 0;
}

pub fn stub_SHGetFileInfoA(pszPath: usize, dwFileAttributes: u32, psfi: usize, cbFileInfo: u32, uFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = pszPath;
    _ = dwFileAttributes;
    _ = psfi;
    _ = cbFileInfo;
    _ = uFlags;
    if (trace.enable_tracing) trace.print("SHELL32: SHGetFileInfoA\n", .{});
    return 0;
}

pub fn stub_SHGetPathFromIDListA(pidl: usize, pszPath: usize) callconv(w32cc.WINAPI) i32 {
    _ = pidl;
    _ = pszPath;
    if (trace.enable_tracing) trace.print("SHELL32: SHGetPathFromIDListA\n", .{});
    return 0;
}

pub fn stub_SHBrowseForFolderA(lpbi: usize) callconv(w32cc.WINAPI) usize {
    _ = lpbi;
    if (trace.enable_tracing) trace.print("SHELL32: SHBrowseForFolderA\n", .{});
    return 0; // cancelled
}

pub fn stub_ExtractIconA(hInst: usize, pszExeFileName: usize, nIconIndex: u32) callconv(w32cc.WINAPI) usize {
    _ = hInst;
    _ = nIconIndex;
    if (trace.enable_tracing) {
        const name = if (pszExeFileName != 0) trace.c_span(pszExeFileName) else "(null)";
        trace.print("SHELL32: ExtractIconA('{s}')\n", .{name});
    }
    return 0;
}

pub fn stub_Shell_NotifyIconA(dwMessage: u32, lpData: usize) callconv(w32cc.WINAPI) i32 {
    _ = dwMessage;
    _ = lpData;
    if (trace.enable_tracing) trace.print("SHELL32: Shell_NotifyIconA\n", .{});
    return 1;
}

pub fn stub_ShellAboutW(hWnd: usize, szApp: usize, szOtherStuff: usize, hIcon: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    _ = hIcon;
    if (trace.enable_tracing) trace.print("SHELL32: ShellAboutW\n", .{});

    const window = @import("../user32/window.zig");
    const renderer = @import("../../gui/renderer.zig");

    const app_name = if (szApp != 0) window.wideToUtf8(szApp) else "Application";
    const extra = if (szOtherStuff != 0) window.wideToUtf8(szOtherStuff) else "";

    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf,
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
