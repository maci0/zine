const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");

var next_imagelist_handle: usize = 0xCC000001;

pub fn register(environment: *env.Environment) !void {
    const m = "comctl32.dll";
    try environment.addBuiltinExport(m, "InitCommonControls", @intFromPtr(&stub_InitCommonControls));
    try environment.addBuiltinExport(m, "InitCommonControlsEx", @intFromPtr(&stub_InitCommonControlsEx));
    try environment.addBuiltinExport(m, "ImageList_Create", @intFromPtr(&stub_ImageList_Create));
    try environment.addBuiltinExport(m, "ImageList_Destroy", @intFromPtr(&stub_ImageList_Destroy));
    try environment.addBuiltinExport(m, "ImageList_Add", @intFromPtr(&stub_ImageList_Add));
    try environment.addBuiltinExport(m, "ImageList_ReplaceIcon", @intFromPtr(&stub_ImageList_ReplaceIcon));
    try environment.addBuiltinExport(m, "ImageList_GetImageCount", @intFromPtr(&stub_ImageList_GetImageCount));
    try environment.addBuiltinExport(m, "ImageList_SetBkColor", @intFromPtr(&stub_ImageList_SetBkColor));

    // Ordinal imports — COMCTL32 exports many functions by ordinal
    // 13 = _TrackMouseEvent (TRACKMOUSEEVENT wrapper)
    try environment.addBuiltinExport(m, "ordinal_13", @intFromPtr(&stub_TrackMouseEvent));
    // 14 = CreateUpDownControl
    try environment.addBuiltinExport(m, "ordinal_14", @intFromPtr(&stub_CreateUpDownControl));
    // 15 = CreateStatusWindowA
    try environment.addBuiltinExport(m, "ordinal_15", @intFromPtr(&stub_CreateStatusWindowA));
    // 17 = InitCommonControlsEx
    try environment.addBuiltinExport(m, "ordinal_17", @intFromPtr(&stub_InitCommonControlsEx));

    // Also register by name for apps that import by name
    try environment.addBuiltinExport(m, "_TrackMouseEvent", @intFromPtr(&stub_TrackMouseEvent));
    try environment.addBuiltinExport(m, "CreateUpDownControl", @intFromPtr(&stub_CreateUpDownControl));
    try environment.addBuiltinExport(m, "CreateStatusWindowA", @intFromPtr(&stub_CreateStatusWindowA));
    try environment.addBuiltinExport(m, "CreateStatusWindowW", @intFromPtr(&stub_CreateStatusWindowA));

    // --- Remaining COMCTL32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExport(m, "ordinal_6", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "CreateToolbarEx", @intFromPtr(&kernel32.stub_args10));
    try environment.addBuiltinExport(m, "ImageList_LoadImageW", @intFromPtr(&kernel32.stub_args7));
    try environment.addBuiltinExport(m, "ImageList_SetIconSize", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(m, "ImageList_Remove", @intFromPtr(&kernel32.stub_args2));
}

fn stub_InitCommonControls() callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("COMCTL32: InitCommonControls\n", .{});
}

fn stub_InitCommonControlsEx(lpInitCtrls: usize) callconv(.winapi) i32 {
    _ = lpInitCtrls;
    if (trace.enable_tracing) trace.print("COMCTL32: InitCommonControlsEx\n", .{});
    return 1;
}

fn stub_ImageList_Create(cx: i32, cy: i32, flags: u32, cInitial: i32, cGrow: i32) callconv(.winapi) usize {
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

fn stub_ImageList_Destroy(himl: usize) callconv(.winapi) i32 {
    _ = himl;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_Destroy\n", .{});
    return 1;
}

fn stub_ImageList_Add(himl: usize, hbmImage: usize, hbmMask: usize) callconv(.winapi) i32 {
    _ = himl;
    _ = hbmImage;
    _ = hbmMask;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_Add\n", .{});
    return 0;
}

fn stub_ImageList_ReplaceIcon(himl: usize, i: i32, hicon: usize) callconv(.winapi) i32 {
    _ = himl;
    _ = i;
    _ = hicon;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_ReplaceIcon\n", .{});
    return 0;
}

fn stub_ImageList_GetImageCount(himl: usize) callconv(.winapi) i32 {
    _ = himl;
    return 0;
}

fn stub_ImageList_SetBkColor(himl: usize, clrBk: u32) callconv(.winapi) u32 {
    _ = himl;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_SetBkColor\n", .{});
    return clrBk;
}

fn stub_TrackMouseEvent(lpEventTrack: usize) callconv(.winapi) i32 {
    _ = lpEventTrack;
    if (trace.enable_tracing) trace.print("COMCTL32: _TrackMouseEvent\n", .{});
    return 1;
}

fn stub_CreateUpDownControl(dwStyle: u32, x: i32, y: i32, cx: i32, cy: i32, hParent: usize, nID: i32, hInst: usize, hBuddy: usize, nUpper: i32, nLower: i32, nPos: i32) callconv(.winapi) usize {
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

fn stub_CreateStatusWindowA(style: u32, lpszText: usize, hwndParent: usize, wID: u32) callconv(.winapi) usize {
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
