const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");
const stubs = @import("comdlg32/dialogs.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "comdlg32.dll";
    try environment.addBuiltinExportComptime(m, "GetOpenFileNameA", stubs.GetOpenFileNameA);
    try environment.addBuiltinExportComptime(m, "GetSaveFileNameA", stubs.GetSaveFileNameA);
    try environment.addBuiltinExportComptime(m, "GetOpenFileNameW", stubs.GetOpenFileNameW);
    try environment.addBuiltinExportComptime(m, "GetSaveFileNameW", stubs.GetSaveFileNameW);
    try environment.addBuiltinExportComptime(m, "ChooseColorA", stubs.stub_ChooseColorA);
    try environment.addBuiltinExportComptime(m, "ChooseFontA", stubs.stub_ChooseFontA);
    try environment.addBuiltinExportComptime(m, "PrintDlgA", stubs.stub_PrintDlgA);
    try environment.addBuiltinExportComptime(m, "CommDlgExtendedError", stubs.stub_ret0_0);
    try environment.addBuiltinExportComptime(m, "PageSetupDlgA", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "FindTextA", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "ReplaceTextA", stubs.stub_ret0_1);

    // --- Notepad2 COMDLG32 stubs (W variants) ---
    try environment.addBuiltinExportComptime(m, "PrintDlgW", stubs.stub_PrintDlgA);
    try environment.addBuiltinExportComptime(m, "ChooseColorW", stubs.stub_ChooseColorA);
    try environment.addBuiltinExportComptime(m, "ChooseFontW", stubs.stub_ChooseFontA);
    try environment.addBuiltinExportComptime(m, "PageSetupDlgW", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "FindTextW", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "ReplaceTextW", stubs.stub_ret0_1);
}
