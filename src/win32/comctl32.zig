const env = @import("../loader/env.zig");
const stubs = @import("comctl32/controls.zig");

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

    // Ordinal imports
    try environment.addBuiltinExportComptime(m, "ordinal_13", stubs.stub_TrackMouseEvent);
    try environment.addBuiltinExportComptime(m, "ordinal_14", stubs.stub_CreateUpDownControl);
    try environment.addBuiltinExportComptime(m, "ordinal_15", stubs.CreateStatusWindowA);
    try environment.addBuiltinExportComptime(m, "ordinal_17", stubs.stub_InitCommonControlsEx);

    // Also register by name for apps that import by name
    try environment.addBuiltinExportComptime(m, "_TrackMouseEvent", stubs.stub_TrackMouseEvent);
    try environment.addBuiltinExportComptime(m, "CreateUpDownControl", stubs.stub_CreateUpDownControl);
    try environment.addBuiltinExportComptime(m, "CreateStatusWindowA", stubs.CreateStatusWindowA);
    try environment.addBuiltinExportComptime(m, "CreateStatusWindowW", stubs.CreateStatusWindowA);

    // --- Remaining COMCTL32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExportComptime(m, "ordinal_6", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "CreateToolbarEx", kernel32.stub_args10);
    try environment.addBuiltinExportComptime(m, "ImageList_LoadImageW", kernel32.stub_args7);
    try environment.addBuiltinExportComptime(m, "ImageList_SetIconSize", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ImageList_Remove", kernel32.stub_args2);

    // --- Notepad2 COMCTL32 stubs ---
    try environment.addBuiltinExportComptime(m, "ordinal_8", kernel32.stub_args4);
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
}
