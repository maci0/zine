const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32cc = @import("../calling_convention.zig");

var next_imagelist_handle: usize = 0xCC000001;

pub fn register(environment: *env.Environment) !void {
    const m = "comctl32.dll";
    try environment.addBuiltinExportComptime(m, "InitCommonControls", stub_InitCommonControls);
    try environment.addBuiltinExportComptime(m, "InitCommonControlsEx", stub_InitCommonControlsEx);
    try environment.addBuiltinExportComptime(m, "ImageList_Create", stub_ImageList_Create);
    try environment.addBuiltinExportComptime(m, "ImageList_Destroy", stub_ImageList_Destroy);
    try environment.addBuiltinExportComptime(m, "ImageList_Add", stub_ImageList_Add);
    try environment.addBuiltinExportComptime(m, "ImageList_ReplaceIcon", stub_ImageList_ReplaceIcon);
    try environment.addBuiltinExportComptime(m, "ImageList_GetImageCount", stub_ImageList_GetImageCount);
    try environment.addBuiltinExportComptime(m, "ImageList_SetBkColor", stub_ImageList_SetBkColor);

    // Ordinal imports — COMCTL32 exports many functions by ordinal
    // 13 = _TrackMouseEvent (TRACKMOUSEEVENT wrapper)
    try environment.addBuiltinExportComptime(m, "ordinal_13", stub_TrackMouseEvent);
    // 14 = CreateUpDownControl
    try environment.addBuiltinExportComptime(m, "ordinal_14", stub_CreateUpDownControl);
    // 15 = CreateStatusWindowA
    try environment.addBuiltinExportComptime(m, "ordinal_15", stub_CreateStatusWindowA);
    // 17 = InitCommonControlsEx
    try environment.addBuiltinExportComptime(m, "ordinal_17", stub_InitCommonControlsEx);

    // Also register by name for apps that import by name
    try environment.addBuiltinExportComptime(m, "_TrackMouseEvent", stub_TrackMouseEvent);
    try environment.addBuiltinExportComptime(m, "CreateUpDownControl", stub_CreateUpDownControl);
    try environment.addBuiltinExportComptime(m, "CreateStatusWindowA", stub_CreateStatusWindowA);
    try environment.addBuiltinExportComptime(m, "CreateStatusWindowW", stub_CreateStatusWindowA);

    // --- Remaining COMCTL32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExportComptime(m, "ordinal_6", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "CreateToolbarEx", kernel32.stub_args10);
    try environment.addBuiltinExportComptime(m, "ImageList_LoadImageW", kernel32.stub_args7);
    try environment.addBuiltinExportComptime(m, "ImageList_SetIconSize", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ImageList_Remove", kernel32.stub_args2);
}

fn stub_InitCommonControls() callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("COMCTL32: InitCommonControls\n", .{});
}

fn stub_InitCommonControlsEx(lpInitCtrls: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpInitCtrls;
    if (trace.enable_tracing) trace.print("COMCTL32: InitCommonControlsEx\n", .{});
    return 1;
}

fn stub_ImageList_Create(cx: i32, cy: i32, flags: u32, cInitial: i32, cGrow: i32) callconv(w32cc.WINAPI) usize {
    _ = cx;
    _ = cy;
    _ = flags;
    _ = cInitial;
    _ = cGrow;
    const h = next_imagelist_handle;
    next_imagelist_handle +%= 1;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_Create -> 0x{x}\n", .{h});
    return h;
}

fn stub_ImageList_Destroy(himl: usize) callconv(w32cc.WINAPI) i32 {
    _ = himl;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_Destroy\n", .{});
    return 1;
}

fn stub_ImageList_Add(himl: usize, hbmImage: usize, hbmMask: usize) callconv(w32cc.WINAPI) i32 {
    _ = himl;
    _ = hbmImage;
    _ = hbmMask;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_Add\n", .{});
    return 0;
}

fn stub_ImageList_ReplaceIcon(himl: usize, i: i32, hicon: usize) callconv(w32cc.WINAPI) i32 {
    _ = himl;
    _ = i;
    _ = hicon;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_ReplaceIcon\n", .{});
    return 0;
}

fn stub_ImageList_GetImageCount(himl: usize) callconv(w32cc.WINAPI) i32 {
    _ = himl;
    return 0;
}

fn stub_ImageList_SetBkColor(himl: usize, clrBk: u32) callconv(w32cc.WINAPI) u32 {
    _ = himl;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_SetBkColor\n", .{});
    return clrBk;
}

fn stub_TrackMouseEvent(lpEventTrack: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpEventTrack;
    if (trace.enable_tracing) trace.print("COMCTL32: _TrackMouseEvent\n", .{});
    return 1;
}

fn stub_CreateUpDownControl(dwStyle: u32, x: i32, y: i32, cx: i32, cy: i32, hParent: usize, nID: i32, hInst: usize, hBuddy: usize, nUpper: i32, nLower: i32, nPos: i32) callconv(w32cc.WINAPI) usize {
    _ = dwStyle;
    _ = x;
    _ = y;
    _ = cx;
    _ = cy;
    _ = hParent;
    _ = nID;
    _ = hInst;
    _ = hBuddy;
    _ = nUpper;
    _ = nLower;
    _ = nPos;
    if (trace.enable_tracing) trace.print("COMCTL32: CreateUpDownControl\n", .{});
    return 0;
}

var next_comctl_hwnd: usize = 0x00002000;

fn stub_CreateStatusWindowA(style: u32, lpszText: usize, hwndParent: usize, wID: u32) callconv(w32cc.WINAPI) usize {
    _ = hwndParent;
    _ = wID;
    const hwnd = next_comctl_hwnd;
    next_comctl_hwnd += 1;
    if (trace.enable_tracing) trace.print("COMCTL32: CreateStatusWindowA -> {x}\n", .{hwnd});

    // Send status bar text to renderer
    const text = if (lpszText != 0) trace.c_span(lpszText) else "";
    const renderer = @import("../gui/renderer.zig");
    renderer.addControl("msctls_statusbar32", hwnd, 0, 0, 0, 20, style, text);

    return hwnd;
}
