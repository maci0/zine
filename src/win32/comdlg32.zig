//! COMDLG32.dll registration.

const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");
const stubs = @import("comdlg32/dialogs.zig");

/// Registers COMDLG32.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "comdlg32.dll";
    try environment.addBuiltinExportComptime(m, "GetOpenFileNameA", stubs.GetOpenFileNameA);
    try environment.addBuiltinExportComptime(m, "GetSaveFileNameA", stubs.GetSaveFileNameA);
    try environment.addBuiltinExportComptime(m, "GetOpenFileNameW", stubs.GetOpenFileNameW);
    try environment.addBuiltinExportComptime(m, "GetSaveFileNameW", stubs.GetSaveFileNameW);
    try environment.addBuiltinExportComptime(m, "ChooseColorA", stubs.ChooseColorA);
    try environment.addBuiltinExportComptime(m, "ChooseFontA", stubs.ChooseFontA);
    try environment.addBuiltinExportComptime(m, "PrintDlgA", stubs.PrintDlgA);
    try environment.addBuiltinExportComptime(m, "CommDlgExtendedError", stubs.stub_ret0_0);
    try environment.addBuiltinExportComptime(m, "PageSetupDlgA", stubs.PageSetupDlgA);
    try environment.addBuiltinExportComptime(m, "FindTextA", stubs.FindTextA);
    try environment.addBuiltinExportComptime(m, "ReplaceTextA", stubs.ReplaceTextA);

    // --- Unicode (W) COMDLG32 stubs ---
    try environment.addBuiltinExportComptime(m, "PrintDlgW", stubs.PrintDlgW);
    try environment.addBuiltinExportComptime(m, "ChooseColorW", stubs.ChooseColorA);
    try environment.addBuiltinExportComptime(m, "ChooseFontW", stubs.ChooseFontW);
    try environment.addBuiltinExportComptime(m, "PageSetupDlgW", stubs.PageSetupDlgW);
    try environment.addBuiltinExportComptime(m, "FindTextW", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "ReplaceTextW", stubs.stub_ret0_1);
}
