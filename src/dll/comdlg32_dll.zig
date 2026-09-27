//! COMDLG32.dll export definitions

const dlg = @import("win32").comdlg32.dialogs;

comptime {
    _ = @import("dll_common.zig");

    @export(&dlg.GetOpenFileNameA, .{ .name = "GetOpenFileNameA" });
    @export(&dlg.GetSaveFileNameA, .{ .name = "GetSaveFileNameA" });
    @export(&dlg.GetOpenFileNameW, .{ .name = "GetOpenFileNameW" });
    @export(&dlg.GetSaveFileNameW, .{ .name = "GetSaveFileNameW" });
    @export(&dlg.ChooseColorA, .{ .name = "ChooseColorA" });
    @export(&dlg.ChooseFontA, .{ .name = "ChooseFontA" });
    @export(&dlg.PrintDlgA, .{ .name = "PrintDlgA" });
}
