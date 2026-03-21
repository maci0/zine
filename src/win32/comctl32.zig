//! COMCTL32.dll registration.

const env = @import("../loader/env.zig");
const ord = @import("ordinals.zig").COMCTL32;
const stubs = @import("comctl32/controls.zig");

/// Registers COMCTL32.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "comctl32.dll";
    try environment.addBuiltinExportComptime(m, "InitCommonControls", stubs.stub_InitCommonControls);
    try environment.addBuiltinExportComptime(m, "InitCommonControlsEx", stubs.stub_InitCommonControlsEx);
    try environment.addBuiltinExportComptime(m, "ImageList_Create", stubs.ImageList_Create);
    try environment.addBuiltinExportComptime(m, "ImageList_Destroy", stubs.stub_ImageList_Destroy);
    try environment.addBuiltinExportComptime(m, "ImageList_Add", stubs.stub_ImageList_Add);
    try environment.addBuiltinExportComptime(m, "ImageList_ReplaceIcon", stubs.stub_ImageList_ReplaceIcon);
    try environment.addBuiltinExportComptime(m, "ImageList_GetImageCount", stubs.stub_ImageList_GetImageCount);
    try environment.addBuiltinExportComptime(m, "ImageList_SetBkColor", stubs.stub_ImageList_SetBkColor);
    try environment.addBuiltinExportComptime(m, "ImageList_GetBkColor", stubs.stub_ImageList_GetBkColor);

    // Ordinal imports
    try environment.addBuiltinExportComptime(m, ord.TrackMouseEvent_13, stubs.stub_TrackMouseEvent);
    try environment.addBuiltinExportComptime(m, ord.CreateUpDownControl_14, stubs.stub_CreateUpDownControl);
    try environment.addBuiltinExportComptime(m, ord.CreateStatusWindowA_15, stubs.CreateStatusWindowA);
    try environment.addBuiltinExportComptime(m, ord.InitCommonControls, stubs.stub_InitCommonControlsEx);

    // Also register by name for apps that import by name
    try environment.addBuiltinExportComptime(m, "_TrackMouseEvent", stubs.stub_TrackMouseEvent);
    try environment.addBuiltinExportComptime(m, "CreateUpDownControl", stubs.stub_CreateUpDownControl);
    try environment.addBuiltinExportComptime(m, "CreateStatusWindowA", stubs.CreateStatusWindowA);
    try environment.addBuiltinExportComptime(m, "CreateStatusWindowW", stubs.CreateStatusWindowA);

    // --- Remaining COMCTL32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExportComptime(m, ord.CreateStatusWindowA, stubs.CreateStatusWindowA);
    try environment.addBuiltinExportComptime(m, "CreateToolbarEx", kernel32.stub_args10);
    try environment.addBuiltinExportComptime(m, "ImageList_LoadImageW", kernel32.stub_args7);
    try environment.addBuiltinExportComptime(m, "ImageList_SetIconSize", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ImageList_Remove", kernel32.stub_args2);

    // --- Additional COMCTL32 stubs ---
    try environment.addBuiltinExportComptime(m, ord.CreateMappedBitmap, kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "ImageList_AddMasked", kernel32.stub_args3);

    // --- hgb.exe COMCTL32 stubs (ImageList drag) ---
    try environment.addBuiltinExportComptime(m, "ImageList_GetDragImage", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "ImageList_DragShowNolock", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "ImageList_SetDragCursorImage", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "ImageList_DragMove", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "ImageList_DragLeave", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "ImageList_DragEnter", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ImageList_EndDrag", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(m, "ImageList_BeginDrag", kernel32.stub_args4);

    // --- Additional ImageList stubs ---
    try environment.addBuiltinExportComptime(m, "ImageList_GetImageInfo", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ImageList_GetIconSize", stubs.ImageList_GetIconSize);
    try environment.addBuiltinExportComptime(m, "ImageList_GetIcon", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ImageList_DrawEx", kernel32.stub_args9);
    try environment.addBuiltinExportComptime(m, "ImageList_Replace", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ImageList_Draw", kernel32.stub_args5);
}
