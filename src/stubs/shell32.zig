const env = @import("../loader/env.zig");
const stubs = @import("shell32/stubs.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "SHELL32.dll";
    try environment.addBuiltinExportComptime(m, "ShellExecuteA", stubs.stub_ShellExecuteA);
    try environment.addBuiltinExportComptime(m, "DragFinish", stubs.stub_DragFinish);
    try environment.addBuiltinExportComptime(m, "DragAcceptFiles", stubs.stub_DragAcceptFiles);
    try environment.addBuiltinExportComptime(m, "DragQueryFileA", stubs.stub_DragQueryFileA);
    try environment.addBuiltinExportComptime(m, "DragQueryFileW", stubs.stub_DragQueryFileW);
    try environment.addBuiltinExportComptime(m, "SHGetFileInfoA", stubs.stub_SHGetFileInfoA);
    try environment.addBuiltinExportComptime(m, "SHGetPathFromIDListA", stubs.stub_SHGetPathFromIDListA);
    try environment.addBuiltinExportComptime(m, "SHBrowseForFolderA", stubs.stub_SHBrowseForFolderA);
    try environment.addBuiltinExportComptime(m, "ExtractIconA", stubs.stub_ExtractIconA);
    try environment.addBuiltinExportComptime(m, "Shell_NotifyIconA", stubs.stub_Shell_NotifyIconA);
    try environment.addBuiltinExportComptime(m, "ShellAboutW", stubs.stub_ShellAboutW);

    // --- Remaining SHELL32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExportComptime(m, "SHAppBarMessage", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "ordinal_258", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "ShellExecuteW", stubs.stub_ShellExecuteA);
    try environment.addBuiltinExportComptime(m, "ExtractIconW", stubs.stub_ExtractIconA);
    try environment.addBuiltinExportComptime(m, "CommandLineToArgvW", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "Shell_NotifyIconW", stubs.stub_Shell_NotifyIconA);
    try environment.addBuiltinExportComptime(m, "ordinal_100", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(m, "ordinal_61", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "SHGetSpecialFolderPathW", kernel32.stub_args4);
}
