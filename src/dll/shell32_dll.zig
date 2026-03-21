//! SHELL32.dll export definitions

const shell = @import("win32").shell32.shell;

comptime {
    _ = @import("dll_common.zig");

    @export(&shell.stub_ShellExecuteA, .{ .name = "ShellExecuteA" });
    @export(&shell.stub_DragFinish, .{ .name = "DragFinish" });
    @export(&shell.stub_DragAcceptFiles, .{ .name = "DragAcceptFiles" });
    @export(&shell.stub_DragQueryFileA, .{ .name = "DragQueryFileA" });
    @export(&shell.stub_DragQueryFileW, .{ .name = "DragQueryFileW" });
    @export(&shell.SHGetFileInfoA, .{ .name = "SHGetFileInfoA" });
    @export(&shell.stub_SHGetPathFromIDListA, .{ .name = "SHGetPathFromIDListA" });
    @export(&shell.stub_SHBrowseForFolderA, .{ .name = "SHBrowseForFolderA" });
    @export(&shell.stub_ExtractIconA, .{ .name = "ExtractIconA" });
    @export(&shell.stub_Shell_NotifyIconA, .{ .name = "Shell_NotifyIconA" });
    @export(&shell.ShellAboutW, .{ .name = "ShellAboutW" });
}
