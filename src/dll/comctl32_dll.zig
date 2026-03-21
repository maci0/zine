//! COMCTL32.dll export definitions

const ctl = @import("win32").comctl32.controls;

comptime {
    _ = @import("dll_common.zig");

    @export(&ctl.stub_InitCommonControls, .{ .name = "InitCommonControls" });
    @export(&ctl.stub_InitCommonControlsEx, .{ .name = "InitCommonControlsEx" });
    @export(&ctl.ImageList_Create, .{ .name = "ImageList_Create" });
    @export(&ctl.stub_ImageList_Destroy, .{ .name = "ImageList_Destroy" });
    @export(&ctl.stub_ImageList_Add, .{ .name = "ImageList_Add" });
    @export(&ctl.stub_ImageList_ReplaceIcon, .{ .name = "ImageList_ReplaceIcon" });
    @export(&ctl.stub_ImageList_GetImageCount, .{ .name = "ImageList_GetImageCount" });
    @export(&ctl.stub_ImageList_SetBkColor, .{ .name = "ImageList_SetBkColor" });
    @export(&ctl.stub_TrackMouseEvent, .{ .name = "_TrackMouseEvent" });
    @export(&ctl.stub_CreateUpDownControl, .{ .name = "CreateUpDownControl" });
    @export(&ctl.CreateStatusWindowA, .{ .name = "CreateStatusWindowA" });
}
