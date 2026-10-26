const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

var next_imagelist_handle: usize = 0xCC000001;

/// Registers and initializes the common control window classes.
/// Implementation status: No-op fallback
pub fn stub_InitCommonControls() callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("COMCTL32: InitCommonControls\n", .{});
}

/// Ensures that the common control DLL is loaded, and registers specific common control classes from the DLL.
/// Implementation status: No-op fallback (always returns TRUE)
pub fn stub_InitCommonControlsEx(lpInitCtrls: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpInitCtrls;
    if (trace.enable_tracing) trace.print("COMCTL32: InitCommonControlsEx\n", .{});
    return 1;
}

/// Creates a new image list.
/// Implementation status: Partially implemented (returns a unique handle)
pub fn ImageList_Create(cx: i32, cy: i32, flags: u32, cInitial: i32, cGrow: i32) callconv(w32cc.WINAPI) usize {
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

/// Destroys an image list.
/// Implementation status: No-op fallback
pub fn stub_ImageList_Destroy(himl: usize) callconv(w32cc.WINAPI) i32 {
    _ = himl;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_Destroy\n", .{});
    return 1;
}

/// Adds an image or images to an image list.
/// Implementation status: Stub
pub fn stub_ImageList_Add(himl: usize, hbmImage: usize, hbmMask: usize) callconv(w32cc.WINAPI) i32 {
    _ = himl;
    _ = hbmImage;
    _ = hbmMask;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_Add\n", .{});
    return 0;
}

/// Replaces an image with an icon or cursor.
/// Implementation status: Stub
pub fn stub_ImageList_ReplaceIcon(himl: usize, i: i32, hicon: usize) callconv(w32cc.WINAPI) i32 {
    _ = himl;
    _ = i;
    _ = hicon;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_ReplaceIcon\n", .{});
    return 0;
}

/// Retrieves the number of images in an image list.
/// Implementation status: Stub (returns 0)
pub fn stub_ImageList_GetImageCount(himl: usize) callconv(w32cc.WINAPI) i32 {
    _ = himl;
    return 0;
}

/// Sets the background color for an image list.
/// Implementation status: No-op fallback
pub fn stub_ImageList_SetBkColor(himl: usize, clrBk: u32) callconv(w32cc.WINAPI) u32 {
    _ = himl;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_SetBkColor\n", .{});
    return clrBk;
}

/// Gets the background color for an image list.
/// Implementation status: No-op fallback (returns CLR_NONE)
pub fn stub_ImageList_GetBkColor(himl: usize) callconv(w32cc.WINAPI) u32 {
    _ = himl;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_GetBkColor\n", .{});
    return 0xFFFFFFFF; // CLR_NONE
}

/// Posts messages when the mouse pointer leaves a window or hovers over a window for a specified amount of time.
/// Implementation status: No-op fallback
pub fn stub_TrackMouseEvent(lpEventTrack: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpEventTrack;
    if (trace.enable_tracing) trace.print("COMCTL32: _TrackMouseEvent\n", .{});
    return 1;
}

/// Creates an up-down control.
/// Implementation status: Stub
pub fn stub_CreateUpDownControl(dwStyle: u32, x: i32, y: i32, cx: i32, cy: i32, hParent: usize, nID: i32, hInst: usize, hBuddy: usize, nUpper: i32, nLower: i32, nPos: i32) callconv(w32cc.WINAPI) usize {
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

/// Creates a status window.
/// Implementation status: Partially implemented (reports the control to the UI renderer)
pub fn CreateStatusWindowA(style: u32, lpszText: usize, hwndParent: usize, wID: u32) callconv(w32cc.WINAPI) usize {
    _ = hwndParent;
    _ = wID;
    const hwnd = next_comctl_hwnd;
    next_comctl_hwnd += 1;
    if (trace.enable_tracing) trace.print("COMCTL32: CreateStatusWindowA -> {x}\n", .{hwnd});

    // Send status bar text to renderer
    if (@import("builtin").target.os.tag != .windows) {
        const text = if (lpszText != 0) trace.c_span(lpszText) else "";
        const r = @import("../../gui/renderer.zig");
        r.addControl("msctls_statusbar32", hwnd, 0, 0, 0, 20, style, text);
        // Register the class so later SendMessage(SB_SETTEXT, …) to this hwnd
        // is dispatched as a status-bar update (not a progress-bar one).
        const msg_mod = @import("../user32/message.zig");
        msg_mod.setControlClass(hwnd, "msctls_statusbar32");
    }

    return hwnd;
}

/// ImageList_GetIconSize — retrieves the dimensions of images in an image list.
/// Returns 16x16 as default icon size.
pub fn ImageList_GetIconSize(himl: usize, cx: usize, cy: usize) callconv(w32cc.WINAPI) i32 {
    _ = himl;
    if (trace.enable_tracing) trace.print("COMCTL32: ImageList_GetIconSize(cx={x}, cy={x}) -> 16x16\n", .{ cx, cy });
    if (cx != 0) @as(*align(1) i32, @ptrFromInt(cx)).* = 16;
    if (cy != 0) @as(*align(1) i32, @ptrFromInt(cy)).* = 16;
    return 1;
}
