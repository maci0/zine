const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");

// Sub-modules
const window = @import("user32/window.zig");
const message = @import("user32/message.zig");
const dialog = @import("user32/dialog.zig");
const resource = @import("user32/resource.zig");
const menu = @import("user32/menu.zig");
const input = @import("user32/input.zig");
const misc = @import("user32/misc.zig");
const w32 = @import("win32_constants.zig");

pub fn register(environment: *env.Environment) !void {
    // Wire up renderer input callbacks
    const renderer = @import("../gui/renderer.zig");
    renderer.on_command = &handleCommand;
    renderer.on_resize = &handleExternalResize;
    renderer.on_key_event = &handleKeyEvent;
    renderer.on_close = &handleClose;

    const m = "USER32.dll";

    // String & Conversion (misc.zig)
    try environment.addBuiltinExport(m, "CharNextA", @intFromPtr(&misc.stub_CharNextA));
    try environment.addBuiltinExport(m, "CharPrevA", @intFromPtr(&misc.stub_CharPrevA));
    try environment.addBuiltinExport(m, "CharToOemA", @intFromPtr(&misc.stub_CharToOemA));
    try environment.addBuiltinExport(m, "OemToCharA", @intFromPtr(&misc.stub_OemToCharA));
    try environment.addBuiltinExport(m, "wsprintfA", @intFromPtr(&misc.stub_wsprintfA));
    try environment.addBuiltinExport(m, "ChangeDisplaySettingsA", @intFromPtr(&misc.stub_ChangeDisplaySettingsA));
    try environment.addBuiltinExport(m, "EnumDisplaySettingsA", @intFromPtr(&misc.stub_EnumDisplaySettingsA));
    try environment.addBuiltinExport(m, "ShowCursor", @intFromPtr(&misc.stub_ShowCursor));

    // Window Management (window.zig)
    try environment.addBuiltinExport(m, "SetRect", @intFromPtr(&window.stub_SetRect));
    try environment.addBuiltinExport(m, "AdjustWindowRectEx", @intFromPtr(&window.stub_AdjustWindowRectEx));
    try environment.addBuiltinExport(m, "AdjustWindowRect", @intFromPtr(&window.stub_AdjustWindowRect));
    try environment.addBuiltinExport(m, "SystemParametersInfoA", @intFromPtr(&window.stub_SystemParametersInfoA));
    try environment.addBuiltinExport(m, "GetSystemMetrics", @intFromPtr(&window.stub_GetSystemMetrics));
    try environment.addBuiltinExport(m, "SetWindowTextA", @intFromPtr(&window.stub_SetWindowTextA));
    try environment.addBuiltinExport(m, "RegisterClassA", @intFromPtr(&window.stub_RegisterClassA));
    try environment.addBuiltinExport(m, "CreateWindowExA", @intFromPtr(&window.stub_CreateWindowExA));
    try environment.addBuiltinExport(m, "ShowWindow", @intFromPtr(&window.stub_ShowWindow));
    try environment.addBuiltinExport(m, "DestroyWindow", @intFromPtr(&window.stub_DestroyWindow));
    try environment.addBuiltinExport(m, "EnableWindow", @intFromPtr(&window.stub_EnableWindow));
    try environment.addBuiltinExport(m, "IsWindow", @intFromPtr(&window.stub_IsWindow));
    try environment.addBuiltinExport(m, "GetClientRect", @intFromPtr(&window.stub_GetClientRect));
    try environment.addBuiltinExport(m, "GetWindowRect", @intFromPtr(&window.stub_GetWindowRect));
    try environment.addBuiltinExport(m, "DefWindowProcA", @intFromPtr(&window.stub_DefWindowProcA));
    try environment.addBuiltinExport(m, "GetWindowLongA", @intFromPtr(&window.stub_GetWindowLongA));
    try environment.addBuiltinExport(m, "SetWindowLongA", @intFromPtr(&window.stub_SetWindowLongA));
    try environment.addBuiltinExport(m, "SetWindowPos", @intFromPtr(&window.stub_SetWindowPos));
    try environment.addBuiltinExport(m, "MoveWindow", @intFromPtr(&window.stub_MoveWindow));
    try environment.addBuiltinExport(m, "ClientToScreen", @intFromPtr(&window.stub_ClientToScreen));
    try environment.addBuiltinExport(m, "ScreenToClient", @intFromPtr(&window.stub_ScreenToClient));
    try environment.addBuiltinExport(m, "GetForegroundWindow", @intFromPtr(&window.stub_GetForegroundWindow));
    try environment.addBuiltinExport(m, "SetForegroundWindow", @intFromPtr(&window.stub_SetForegroundWindow));
    try environment.addBuiltinExport(m, "GetActiveWindow", @intFromPtr(&window.stub_GetActiveWindow));
    try environment.addBuiltinExport(m, "GetDesktopWindow", @intFromPtr(&window.stub_GetDesktopWindow));
    try environment.addBuiltinExport(m, "SetFocus", @intFromPtr(&window.stub_SetFocus));
    try environment.addBuiltinExport(m, "GetFocus", @intFromPtr(&window.stub_GetFocus));
    try environment.addBuiltinExport(m, "IsIconic", @intFromPtr(&window.stub_IsIconic));
    try environment.addBuiltinExport(m, "UpdateWindow", @intFromPtr(&window.stub_UpdateWindow));
    try environment.addBuiltinExport(m, "RedrawWindow", @intFromPtr(&window.stub_RedrawWindow));
    try environment.addBuiltinExport(m, "InvalidateRect", @intFromPtr(&window.stub_InvalidateRect));
    try environment.addBuiltinExport(m, "MapWindowPoints", @intFromPtr(&window.stub_MapWindowPoints));
    try environment.addBuiltinExport(m, "FillRect", @intFromPtr(&window.stub_FillRect));
    try environment.addBuiltinExport(m, "GetDC", @intFromPtr(&window.stub_GetDC));
    try environment.addBuiltinExport(m, "ReleaseDC", @intFromPtr(&window.stub_ReleaseDC));
    try environment.addBuiltinExport(m, "BeginPaint", @intFromPtr(&window.stub_BeginPaint));
    try environment.addBuiltinExport(m, "EndPaint", @intFromPtr(&window.stub_EndPaint));

    // Messaging (message.zig)
    try environment.addBuiltinExport(m, "PeekMessageA", @intFromPtr(&message.stub_PeekMessageA));
    try environment.addBuiltinExport(m, "GetMessageA", @intFromPtr(&message.stub_GetMessageA));
    try environment.addBuiltinExport(m, "TranslateMessage", @intFromPtr(&message.stub_TranslateMessage));
    try environment.addBuiltinExport(m, "DispatchMessageA", @intFromPtr(&message.stub_DispatchMessageA));
    try environment.addBuiltinExport(m, "PostMessageA", @intFromPtr(&message.stub_PostMessageA));
    try environment.addBuiltinExport(m, "PostQuitMessage", @intFromPtr(&message.stub_PostQuitMessage));
    try environment.addBuiltinExport(m, "SendMessageA", @intFromPtr(&message.stub_SendMessageA));

    // Dialog (dialog.zig)
    try environment.addBuiltinExport(m, "MessageBoxA", @intFromPtr(&dialog.stub_MessageBoxA));
    try environment.addBuiltinExport(m, "DialogBoxParamA", @intFromPtr(&dialog.stub_DialogBoxParamA));
    try environment.addBuiltinExport(m, "EndDialog", @intFromPtr(&dialog.stub_EndDialog));
    try environment.addBuiltinExport(m, "GetDlgItem", @intFromPtr(&dialog.stub_GetDlgItem));
    try environment.addBuiltinExport(m, "SetDlgItemTextA", @intFromPtr(&dialog.stub_SetDlgItemTextA));
    try environment.addBuiltinExport(m, "GetDlgItemTextA", @intFromPtr(&dialog.stub_GetDlgItemTextA));
    try environment.addBuiltinExport(m, "SendDlgItemMessageA", @intFromPtr(&dialog.stub_SendDlgItemMessageA));

    // Resource Loading (resource.zig)
    try environment.addBuiltinExport(m, "LoadIconA", @intFromPtr(&resource.stub_LoadIconA));
    try environment.addBuiltinExport(m, "LoadCursorA", @intFromPtr(&resource.stub_LoadCursorA));
    try environment.addBuiltinExport(m, "LoadStringA", @intFromPtr(&resource.stub_LoadStringA));
    try environment.addBuiltinExport(m, "LoadMenuA", @intFromPtr(&resource.stub_LoadMenuA));

    // Menu (menu.zig)
    try environment.addBuiltinExport(m, "GetMenu", @intFromPtr(&menu.stub_GetMenu));
    try environment.addBuiltinExport(m, "DrawMenuBar", @intFromPtr(&menu.stub_DrawMenuBar));
    try environment.addBuiltinExport(m, "SetMenu", @intFromPtr(&menu.stub_SetMenu));
    try environment.addBuiltinExport(m, "DestroyMenu", @intFromPtr(&menu.stub_DestroyMenu));
    try environment.addBuiltinExport(m, "GetSubMenu", @intFromPtr(&menu.stub_GetSubMenu));
    try environment.addBuiltinExport(m, "TrackPopupMenu", @intFromPtr(&menu.stub_TrackPopupMenu));
    try environment.addBuiltinExport(m, "AppendMenuA", @intFromPtr(&menu.stub_AppendMenuA));
    try environment.addBuiltinExport(m, "CheckMenuItem", @intFromPtr(&menu.stub_CheckMenuItem));

    // Input (input.zig)
    try environment.addBuiltinExport(m, "GetKeyboardState", @intFromPtr(&input.stub_GetKeyboardState));
    try environment.addBuiltinExport(m, "GetKeyState", @intFromPtr(&input.stub_GetKeyState));
    try environment.addBuiltinExport(m, "GetAsyncKeyState", @intFromPtr(&input.stub_GetKeyState));
    try environment.addBuiltinExport(m, "SetCursor", @intFromPtr(&input.stub_SetCursor));
    try environment.addBuiltinExport(m, "GetCursorPos", @intFromPtr(&input.stub_GetCursorPos));
    try environment.addBuiltinExport(m, "GetCapture", @intFromPtr(&input.stub_GetCapture));
    try environment.addBuiltinExport(m, "SetCapture", @intFromPtr(&input.stub_SetCapture));
    try environment.addBuiltinExport(m, "ReleaseCapture", @intFromPtr(&input.stub_ReleaseCapture));
    try environment.addBuiltinExport(m, "SetTimer", @intFromPtr(&input.stub_SetTimer));
    try environment.addBuiltinExport(m, "KillTimer", @intFromPtr(&input.stub_KillTimer));
    try environment.addBuiltinExport(m, "GetQueueStatus", @intFromPtr(&input.stub_GetQueueStatus));

    // Additional misc
    try environment.addBuiltinExport(m, "MessageBeep", @intFromPtr(&misc.stub_MessageBeep));
    try environment.addBuiltinExport(m, "SetActiveWindow", @intFromPtr(&misc.stub_SetActiveWindow));
    try environment.addBuiltinExport(m, "GetSysColor", @intFromPtr(&misc.stub_GetSysColor));
    try environment.addBuiltinExport(m, "GetSysColorBrush", @intFromPtr(&misc.stub_GetSysColorBrush));
    try environment.addBuiltinExport(m, "GetParent", @intFromPtr(&misc.stub_GetParent));
    try environment.addBuiltinExport(m, "FindWindowA", @intFromPtr(&misc.stub_FindWindowA));
    try environment.addBuiltinExport(m, "GetWindowTextA", @intFromPtr(&misc.stub_GetWindowTextA));
    try environment.addBuiltinExport(m, "GetWindowTextLengthA", @intFromPtr(&misc.stub_GetWindowTextLengthA));
    try environment.addBuiltinExport(m, "IsZoomed", @intFromPtr(&misc.stub_IsZoomed));
    try environment.addBuiltinExport(m, "RegisterWindowMessageA", @intFromPtr(&misc.stub_RegisterWindowMessageA));
    try environment.addBuiltinExport(m, "GetSystemMenu", @intFromPtr(&misc.stub_GetSystemMenu));
    try environment.addBuiltinExport(m, "GetMessageTime", @intFromPtr(&misc.stub_GetMessageTime));
    try environment.addBuiltinExport(m, "IsDialogMessageA", @intFromPtr(&misc.stub_IsDialogMessageA));
    try environment.addBuiltinExport(m, "MsgWaitForMultipleObjects", @intFromPtr(&misc.stub_MsgWaitForMultipleObjects));
    try environment.addBuiltinExport(m, "GetWindowPlacement", @intFromPtr(&misc.stub_GetWindowPlacement));
    try environment.addBuiltinExport(m, "SetWindowPlacement", @intFromPtr(&misc.stub_SetWindowPlacement));
    try environment.addBuiltinExport(m, "WinHelpA", @intFromPtr(&misc.stub_WinHelpA));
    try environment.addBuiltinExport(m, "DrawTextA", @intFromPtr(&misc.stub_DrawTextA));
    try environment.addBuiltinExport(m, "DrawTextW", @intFromPtr(&misc.stub_DrawTextW));
    try environment.addBuiltinExport(m, "CharLowerA", @intFromPtr(&misc.stub_CharLowerA));
    try environment.addBuiltinExport(m, "CharUpperW", @intFromPtr(&misc.stub_CharUpperW));
    try environment.addBuiltinExport(m, "CharLowerW", @intFromPtr(&misc.stub_CharLowerW));
    try environment.addBuiltinExport(m, "GetKeyboardLayout", @intFromPtr(&misc.stub_GetKeyboardLayout));
    try environment.addBuiltinExport(m, "GetDoubleClickTime", @intFromPtr(&misc.stub_GetDoubleClickTime));
    try environment.addBuiltinExport(m, "GetCaretBlinkTime", @intFromPtr(&misc.stub_GetCaretBlinkTime));
    try environment.addBuiltinExport(m, "EqualRect", @intFromPtr(&misc.stub_EqualRect));
    try environment.addBuiltinExport(m, "InflateRect", @intFromPtr(&misc.stub_InflateRect));
    try environment.addBuiltinExport(m, "IntersectRect", @intFromPtr(&misc.stub_IntersectRect));
    try environment.addBuiltinExport(m, "MessageBoxIndirectA", @intFromPtr(&misc.stub_MessageBoxIndirectA));
    try environment.addBuiltinExport(m, "SetKeyboardState", @intFromPtr(&misc.stub_SetKeyboardState));
    try environment.addBuiltinExport(m, "ToAsciiEx", @intFromPtr(&misc.stub_ToAsciiEx));
    try environment.addBuiltinExport(m, "FlashWindow", @intFromPtr(&misc.stub_FlashWindow));
    try environment.addBuiltinExport(m, "SetClassLongA", @intFromPtr(&misc.stub_SetClassLongA));
    try environment.addBuiltinExport(m, "DefDlgProcA", @intFromPtr(&misc.stub_DefDlgProcA));
    try environment.addBuiltinExport(m, "MapDialogRect", @intFromPtr(&misc.stub_MapDialogRect));
    try environment.addBuiltinExport(m, "RegisterClipboardFormatA", @intFromPtr(&misc.stub_RegisterClipboardFormatA));

    // Additional menu
    try environment.addBuiltinExport(m, "CreateMenu", @intFromPtr(&menu.stub_CreateMenu));
    try environment.addBuiltinExport(m, "CreatePopupMenu", @intFromPtr(&menu.stub_CreatePopupMenu));
    try environment.addBuiltinExport(m, "EnableMenuItem", @intFromPtr(&menu.stub_EnableMenuItem));
    try environment.addBuiltinExport(m, "InsertMenuA", @intFromPtr(&menu.stub_InsertMenuA));
    try environment.addBuiltinExport(m, "InsertMenuItemA", @intFromPtr(&menu.stub_InsertMenuItemA));
    try environment.addBuiltinExport(m, "DeleteMenu", @intFromPtr(&menu.stub_DeleteMenu));
    try environment.addBuiltinExport(m, "GetMenuItemCount", @intFromPtr(&menu.stub_GetMenuItemCount));
    try environment.addBuiltinExport(m, "GetMenuState", @intFromPtr(&menu.stub_GetMenuState));
    try environment.addBuiltinExport(m, "CheckMenuRadioItem", @intFromPtr(&menu.stub_CheckMenuRadioItem));

    // Additional dialog
    try environment.addBuiltinExport(m, "CheckDlgButton", @intFromPtr(&dialog.stub_CheckDlgButton));
    try environment.addBuiltinExport(m, "CheckRadioButton", @intFromPtr(&dialog.stub_CheckRadioButton));
    try environment.addBuiltinExport(m, "IsDlgButtonChecked", @intFromPtr(&dialog.stub_IsDlgButtonChecked));
    try environment.addBuiltinExport(m, "GetDlgItemInt", @intFromPtr(&dialog.stub_GetDlgItemInt));
    try environment.addBuiltinExport(m, "SetDlgItemInt", @intFromPtr(&dialog.stub_SetDlgItemInt));
    try environment.addBuiltinExport(m, "CreateDialogParamA", @intFromPtr(&dialog.stub_CreateDialogParamA));
    try environment.addBuiltinExport(m, "MessageBoxW", @intFromPtr(&dialog.stub_MessageBoxW));

    // Additional window
    try environment.addBuiltinExport(m, "SetScrollInfo", @intFromPtr(&window.stub_SetScrollInfo));
    try environment.addBuiltinExport(m, "GetScrollInfo", @intFromPtr(&window.stub_GetScrollInfo));
    try environment.addBuiltinExport(m, "CopyImage", @intFromPtr(&window.stub_CopyImage));
    try environment.addBuiltinExport(m, "DrawEdge", @intFromPtr(&window.stub_DrawEdge));
    try environment.addBuiltinExport(m, "DrawFocusRect", @intFromPtr(&window.stub_DrawFocusRect));
    try environment.addBuiltinExport(m, "FrameRect", @intFromPtr(&window.stub_FrameRect));
    try environment.addBuiltinExport(m, "EnumWindows", @intFromPtr(&window.stub_EnumWindows));
    try environment.addBuiltinExport(m, "IsChild", @intFromPtr(&window.stub_IsChild));
    try environment.addBuiltinExport(m, "IsWindowEnabled", @intFromPtr(&window.stub_IsWindowEnabled));
    try environment.addBuiltinExport(m, "GetIconInfo", @intFromPtr(&window.stub_GetIconInfo));
    try environment.addBuiltinExport(m, "DestroyIcon", @intFromPtr(&window.stub_DestroyIcon));
    try environment.addBuiltinExport(m, "DestroyCursor", @intFromPtr(&window.stub_DestroyCursor));

    // Clipboard
    try environment.addBuiltinExport(m, "OpenClipboard", @intFromPtr(&window.stub_OpenClipboard));
    try environment.addBuiltinExport(m, "CloseClipboard", @intFromPtr(&window.stub_CloseClipboard));
    try environment.addBuiltinExport(m, "EmptyClipboard", @intFromPtr(&window.stub_EmptyClipboard));
    try environment.addBuiltinExport(m, "GetClipboardData", @intFromPtr(&window.stub_GetClipboardData));
    try environment.addBuiltinExport(m, "SetClipboardData", @intFromPtr(&window.stub_SetClipboardData));
    try environment.addBuiltinExport(m, "IsClipboardFormatAvailable", @intFromPtr(&window.stub_IsClipboardFormatAvailable));
    try environment.addBuiltinExport(m, "GetClipboardOwner", @intFromPtr(&window.stub_GetClipboardOwner));

    // Caret
    try environment.addBuiltinExport(m, "CreateCaret", @intFromPtr(&window.stub_CreateCaret));
    try environment.addBuiltinExport(m, "DestroyCaret", @intFromPtr(&window.stub_DestroyCaret));
    try environment.addBuiltinExport(m, "SetCaretPos", @intFromPtr(&window.stub_SetCaretPos));
    try environment.addBuiltinExport(m, "ShowCaret", @intFromPtr(&window.stub_ShowCaret));
    try environment.addBuiltinExport(m, "HideCaret", @intFromPtr(&window.stub_HideCaret));

    // Europa 1400 compatibility
    try environment.addBuiltinExport(m, "ValidateRect", @intFromPtr(&misc.stub_ValidateRect));
    try environment.addBuiltinExport(m, "UnregisterClassA", @intFromPtr(&misc.stub_UnregisterClassA));
    try environment.addBuiltinExport(m, "IsWindowVisible", @intFromPtr(&misc.stub_IsWindowVisible));
    try environment.addBuiltinExport(m, "CallNextHookEx", @intFromPtr(&misc.stub_CallNextHookEx));
    try environment.addBuiltinExport(m, "MapVirtualKeyA", @intFromPtr(&misc.stub_MapVirtualKeyA));
    try environment.addBuiltinExport(m, "RegisterClassExA", @intFromPtr(&misc.stub_RegisterClassExA));
    try environment.addBuiltinExport(m, "BringWindowToTop", @intFromPtr(&misc.stub_BringWindowToTop));
    try environment.addBuiltinExport(m, "VkKeyScanA", @intFromPtr(&misc.stub_VkKeyScanA));
    try environment.addBuiltinExport(m, "SetCursorPos", @intFromPtr(&misc.stub_SetCursorPos));
    try environment.addBuiltinExport(m, "SetWindowsHookExA", @intFromPtr(&misc.stub_SetWindowsHookExA));
    try environment.addBuiltinExport(m, "UnhookWindowsHookEx", @intFromPtr(&misc.stub_UnhookWindowsHookEx));
    try environment.addBuiltinExport(m, "GetWindowThreadProcessId", @intFromPtr(&misc.stub_GetWindowThreadProcessId));
    try environment.addBuiltinExport(m, "GetWindow", @intFromPtr(&misc.stub_GetWindow));
    try environment.addBuiltinExport(m, "GetTopWindow", @intFromPtr(&misc.stub_GetTopWindow));

    try environment.addBuiltinExport(m, "LoadAcceleratorsA", @intFromPtr(&resource.stub_LoadAcceleratorsA));
    try environment.addBuiltinExport(m, "LoadImageA", @intFromPtr(&resource.stub_LoadImageA));

    // --- Wide (W) variants for Unicode apps ---
    try environment.addBuiltinExport(m, "RegisterClassExW", @intFromPtr(&misc.stub_RegisterClassExW));
    try environment.addBuiltinExport(m, "CreateWindowExW", @intFromPtr(&window.stub_CreateWindowExW));
    try environment.addBuiltinExport(m, "DefWindowProcW", @intFromPtr(&window.stub_DefWindowProcA));
    try environment.addBuiltinExport(m, "GetMessageW", @intFromPtr(&message.stub_GetMessageA));
    try environment.addBuiltinExport(m, "PeekMessageW", @intFromPtr(&message.stub_PeekMessageA));
    try environment.addBuiltinExport(m, "DispatchMessageW", @intFromPtr(&message.stub_DispatchMessageA));
    try environment.addBuiltinExport(m, "SendMessageW", @intFromPtr(&message.stub_SendMessageA));
    try environment.addBuiltinExport(m, "PostMessageW", @intFromPtr(&message.stub_PostMessageA));
    try environment.addBuiltinExport(m, "TranslateAcceleratorW", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "LoadAcceleratorsW", @intFromPtr(&resource.stub_LoadAcceleratorsW));
    try environment.addBuiltinExport(m, "LoadStringW", @intFromPtr(&resource.stub_LoadStringW));
    try environment.addBuiltinExport(m, "LoadCursorW", @intFromPtr(&resource.stub_LoadCursorA));
    try environment.addBuiltinExport(m, "LoadIconW", @intFromPtr(&resource.stub_LoadIconA));
    try environment.addBuiltinExport(m, "LoadImageW", @intFromPtr(&resource.stub_LoadImageW));
    try environment.addBuiltinExport(m, "GetWindowLongW", @intFromPtr(&window.stub_GetWindowLongA));
    try environment.addBuiltinExport(m, "SetWindowLongW", @intFromPtr(&window.stub_SetWindowLongA));
    try environment.addBuiltinExport(m, "SetWindowTextW", @intFromPtr(&window.stub_SetWindowTextW));
    try environment.addBuiltinExport(m, "GetWindowTextW", @intFromPtr(&misc.stub_GetWindowTextA));
    try environment.addBuiltinExport(m, "DialogBoxParamW", @intFromPtr(&dialog.stub_DialogBoxParamA));
    try environment.addBuiltinExport(m, "CreateDialogParamW", @intFromPtr(&dialog.stub_CreateDialogParamA));
    try environment.addBuiltinExport(m, "SetDlgItemTextW", @intFromPtr(&dialog.stub_SetDlgItemTextA));
    try environment.addBuiltinExport(m, "GetDlgItemTextW", @intFromPtr(&dialog.stub_GetDlgItemTextA));
    try environment.addBuiltinExport(m, "SendDlgItemMessageW", @intFromPtr(&dialog.stub_SendDlgItemMessageA));
    try environment.addBuiltinExport(m, "IsDialogMessageW", @intFromPtr(&misc.stub_IsDialogMessageA));
    try environment.addBuiltinExport(m, "SetScrollPos", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "WinHelpW", @intFromPtr(&misc.stub_WinHelpA));
    try environment.addBuiltinExport(m, "GetDlgCtrlID", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "ChildWindowFromPoint", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "CharNextW", @intFromPtr(&misc.stub_CharNextW));
    try environment.addBuiltinExport(m, "DrawTextExW", @intFromPtr(&stub_ret0_6));
    try environment.addBuiltinExport(m, "wsprintfW", @intFromPtr(&misc.stub_wsprintfW));
    try environment.addBuiltinExport(m, "RegisterWindowMessageW", @intFromPtr(&misc.stub_RegisterWindowMessageW));

    // Rect utilities (win2k apps: 5-6x each)
    try environment.addBuiltinExport(m, "CopyRect", @intFromPtr(&window.stub_CopyRect));
    try environment.addBuiltinExport(m, "PtInRect", @intFromPtr(&window.stub_PtInRect));
    try environment.addBuiltinExport(m, "OffsetRect", @intFromPtr(&window.stub_OffsetRect));
    try environment.addBuiltinExport(m, "SetRectEmpty", @intFromPtr(&window.stub_SetRectEmpty));
    try environment.addBuiltinExport(m, "IsRectEmpty", @intFromPtr(&window.stub_IsRectEmpty));
    try environment.addBuiltinExport(m, "UnionRect", @intFromPtr(&window.stub_UnionRect));
    try environment.addBuiltinExport(m, "SubtractRect", @intFromPtr(&window.stub_SubtractRect));

    // Window/Class W variants (win2k apps: 3-6x each)
    try environment.addBuiltinExport(m, "FindWindowW", @intFromPtr(&window.stub_FindWindowW));
    try environment.addBuiltinExport(m, "FindWindowExW", @intFromPtr(&window.stub_FindWindowExW));
    try environment.addBuiltinExport(m, "GetClassInfoW", @intFromPtr(&window.stub_GetClassInfoW));
    try environment.addBuiltinExport(m, "GetClassInfoExW", @intFromPtr(&window.stub_GetClassInfoExW));
    try environment.addBuiltinExport(m, "SystemParametersInfoW", @intFromPtr(&window.stub_SystemParametersInfoW));
    try environment.addBuiltinExport(m, "GetUpdateRect", @intFromPtr(&window.stub_GetUpdateRect));
    try environment.addBuiltinExport(m, "GetWindowDC", @intFromPtr(&window.stub_GetWindowDC));

    // W variant aliases for resource/menu (win2k apps: 3-6x each)
    try environment.addBuiltinExport(m, "LoadMenuW", @intFromPtr(&resource.stub_LoadMenuA));
    try environment.addBuiltinExport(m, "RegisterClassW", @intFromPtr(&window.stub_RegisterClassA));
    try environment.addBuiltinExport(m, "LoadBitmapW", @intFromPtr(&resource.stub_LoadBitmapW));
    try environment.addBuiltinExport(m, "RegisterClipboardFormatW", @intFromPtr(&misc.stub_RegisterClipboardFormatA));
    try environment.addBuiltinExport(m, "RemoveMenu", @intFromPtr(&menu.stub_DeleteMenu));
    try environment.addBuiltinExport(m, "AppendMenuW", @intFromPtr(&menu.stub_AppendMenuA));
    try environment.addBuiltinExport(m, "TrackPopupMenuEx", @intFromPtr(&stub_ret0_6));
    try environment.addBuiltinExport(m, "CountClipboardFormats", @intFromPtr(&stub_ret0_0));
    try environment.addBuiltinExport(m, "GetMessagePos", @intFromPtr(&stub_ret0_0));
    try environment.addBuiltinExport(m, "DrawIcon", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "OpenDesktopW", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "CloseDesktop", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "GetThreadDesktop", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "GetProcessWindowStation", @intFromPtr(&stub_ret0_0));
    try environment.addBuiltinExport(m, "SetThreadDesktop", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "OpenWindowStationW", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "SetProcessWindowStation", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "GetUserObjectInformationW", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "GrayStringW", @intFromPtr(&stub_ret0_6));
    try environment.addBuiltinExport(m, "TabbedTextOutW", @intFromPtr(&stub_ret0_6));
    try environment.addBuiltinExport(m, "GetWindowTextLengthW", @intFromPtr(&misc.stub_GetWindowTextLengthA));
    try environment.addBuiltinExport(m, "IsMenu", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "GetClassNameW", @intFromPtr(&stub_ret0_3));

    // --- Remaining USER32 stubs for 100% win2k coverage ---
    try environment.addBuiltinExport(m, "CharToOemBuffA", @intFromPtr(&stub_CharToOemBuffA));
    try environment.addBuiltinExport(m, "CallWindowProcW", @intFromPtr(&stub_CallWindowProcW));
    try environment.addBuiltinExport(m, "GetMonitorInfoW", @intFromPtr(&stub_GetMonitorInfoW));
    try environment.addBuiltinExport(m, "SendMessageTimeoutW", @intFromPtr(&stub_ret0_6));
    try environment.addBuiltinExport(m, "DdeUninitialize", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "DdeFreeStringHandle", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "TranslateAcceleratorA", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "TranslateMDISysAccel", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "SetClipboardViewer", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "DdeGetLastError", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "DdeCreateStringHandleA", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "DdeInitializeA", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "ShowScrollBar", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "DefMDIChildProcA", @intFromPtr(&stub_DefMDIChildProcA));
    try environment.addBuiltinExport(m, "DefFrameProcA", @intFromPtr(&stub_DefFrameProcA));
    try environment.addBuiltinExport(m, "DdeFreeDataHandle", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "DdeUnaccessData", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "DdeAccessData", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "DdeKeepStringHandle", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "GetMenuStringA", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "ChangeClipboardChain", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "DdeDisconnect", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "DdeSetUserHandle", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "DdeConnect", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "DdeClientTransaction", @intFromPtr(&stub_ret0_8));
    try environment.addBuiltinExport(m, "DdeGetData", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "SetScrollRange", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "EnumClipboardFormats", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "ScrollWindow", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "GetClipboardFormatNameA", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "GetScrollPos", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "GetScrollRange", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "LoadBitmapA", @intFromPtr(&resource.stub_LoadBitmapA));
    try environment.addBuiltinExport(m, "DdeQueryConvInfo", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "GetClipboardFormatNameW", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "SetProcessDefaultLayout", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "GetProcessDefaultLayout", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "RegisterHotKey", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "UnregisterHotKey", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "OpenInputDesktop", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "WindowFromPoint", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "GetCaretPos", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "SetClassLongW", @intFromPtr(&misc.stub_SetClassLongA));
    try environment.addBuiltinExport(m, "EnableScrollBar", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "wvsprintfW", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "RegisterDeviceNotificationW", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "SetPropW", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "RemovePropW", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "MonitorFromPoint", @intFromPtr(&stub_MonitorFromPoint));
    try environment.addBuiltinExport(m, "CreateDialogIndirectParamW", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "UnhookWindowsHook", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "SetWindowsHookW", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "DefDlgProcW", @intFromPtr(&misc.stub_DefDlgProcA));
    try environment.addBuiltinExport(m, "GetPropW", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "UnregisterDeviceNotification", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "InvertRect", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "PostThreadMessageW", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "CharLowerBuffW", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "GetGuiResources", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "SetMenuDefaultItem", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "EnumWindowStationsW", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "GetClassLongW", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "IsHungAppWindow", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "EnumDesktopsW", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "CloseWindowStation", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "InternalGetWindowText", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "EndTask", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "ShowWindowAsync", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "CascadeWindows", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "TileWindows", @intFromPtr(&stub_ret0_5));
    try environment.addBuiltinExport(m, "SwitchToThisWindow", @intFromPtr(&stub_ret0_2));
    try environment.addBuiltinExport(m, "GetLastActivePopup", @intFromPtr(&stub_GetLastActivePopup));
    try environment.addBuiltinExport(m, "OpenIcon", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "GetShellWindow", @intFromPtr(&stub_ret0_0));
    try environment.addBuiltinExport(m, "BeginDeferWindowPos", @intFromPtr(&stub_BeginDeferWindowPos));
    try environment.addBuiltinExport(m, "DeferWindowPos", @intFromPtr(&stub_DeferWindowPos));
    try environment.addBuiltinExport(m, "EndDeferWindowPos", @intFromPtr(&stub_EndDeferWindowPos));
    try environment.addBuiltinExport(m, "GetMenuItemInfoW", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "GetDialogBaseUnits", @intFromPtr(&stub_GetDialogBaseUnits));
    try environment.addBuiltinExport(m, "MonitorFromRect", @intFromPtr(&stub_MonitorFromRect));
    try environment.addBuiltinExport(m, "GetUpdateRgn", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "GetDCEx", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "AllowSetForegroundWindow", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "GetMenuItemRect", @intFromPtr(&stub_ret0_4));
    try environment.addBuiltinExport(m, "MonitorFromWindow", @intFromPtr(&stub_MonitorFromWindow));
    try environment.addBuiltinExport(m, "OemToCharBuffA", @intFromPtr(&stub_OemToCharBuffA));
    try environment.addBuiltinExport(m, "SetWindowsHookExW", @intFromPtr(&misc.stub_SetWindowsHookExA));
    try environment.addBuiltinExport(m, "GetNextDlgTabItem", @intFromPtr(&stub_ret0_3));
}

// --- Generic stubs ---

fn stub_ret0_0() callconv(.winapi) usize {
    return 0;
}
fn stub_ret0_1(a: usize) callconv(.winapi) usize {
    _ = a;
    return 0;
}
fn stub_ret0_2(a: usize, b: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    return 0;
}
fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    return 0;
}
fn stub_ret0_4(a: usize, b: usize, c: usize, d: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    return 0;
}
fn stub_ret0_5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    return 0;
}
fn stub_ret0_6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    return 0;
}
fn stub_ret0_7(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize) callconv(.winapi) usize {
    _ = a; _ = b; _ = c; _ = d; _ = e; _ = f; _ = g;
    return 0;
}
fn stub_ret0_8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(.winapi) usize {
    _ = a; _ = b; _ = c; _ = d; _ = e; _ = f; _ = g; _ = h;
    return 0;
}
// --- Shared Types ---

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const MSG = extern struct {
    hwnd: usize,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt_x: i32,
    pt_y: i32,
};

// --- Win2K/2000 System Metrics Constants ---

pub const SM_CXBORDER: i32 = 1;
pub const SM_CYBORDER: i32 = 1;
pub const SM_CXFRAME: i32 = 4; // SM_CXSIZEFRAME
pub const SM_CYFRAME: i32 = 4;
pub const SM_CXDLGFRAME: i32 = 3; // SM_CXFIXEDFRAME
pub const SM_CYDLGFRAME: i32 = 3;
pub const SM_CYCAPTION: i32 = 19;
pub const SM_CYMENU: i32 = 19;
pub const SM_CXEDGE: i32 = 2;
pub const SM_CYEDGE: i32 = 2;

// --- Win32 Style Constants ---

pub const WS_BORDER: u32 = 0x00800000;
pub const WS_CAPTION: u32 = 0x00C00000; // WS_BORDER | WS_DLGFRAME
pub const WS_DLGFRAME: u32 = 0x00400000;
pub const WS_THICKFRAME: u32 = 0x00040000;
pub const WS_VSCROLL: u32 = 0x00200000;
pub const WS_HSCROLL: u32 = 0x00100000;
pub const WS_EX_CLIENTEDGE: u32 = 0x00000200;
pub const WS_EX_WINDOWEDGE: u32 = 0x00000100;
pub const WS_EX_STATICEDGE: u32 = 0x00020000;

// --- Shared Mutable State ---

pub var global_wndproc: ?*const fn (usize, u32, usize, isize) callconv(.winapi) isize = null;
pub var global_hwnd: usize = 0;

// Per-hwnd WndProc lookup table (for dialogs, subclassed windows, etc.)
const WndProcType = *const fn (usize, u32, usize, isize) callconv(.winapi) isize;
const MAX_WINDOWS = 128;
pub const WindowInfo = struct { 
    hwnd: usize = 0, 
    proc: usize = 0,
    userdata: i32 = 0,
    id: i32 = 0,
    style: i32 = 0,
    exstyle: i32 = 0,
};
var window_info_table: [MAX_WINDOWS]WindowInfo = [_]WindowInfo{.{}} ** MAX_WINDOWS;
var window_info_count: usize = 0;

pub fn getWindowInfo(hwnd: usize) ?*WindowInfo {
    for (window_info_table[0..window_info_count]) |*entry| {
        if (entry.hwnd == hwnd) return entry;
    }
    if (window_info_count < MAX_WINDOWS) {
        const entry = &window_info_table[window_info_count];
        window_info_count += 1;
        entry.* = .{ .hwnd = hwnd };
        return entry;
    }
    return null;
}

pub fn setWndProc(hwnd: usize, proc_addr: usize) void {
    if (proc_addr == 0) return;
    if (getWindowInfo(hwnd)) |info| {
        info.proc = proc_addr;
    }
}

pub fn getWndProc(hwnd: usize) ?usize {
    if (getWindowInfo(hwnd)) |info| {
        if (info.proc != 0) return info.proc;
    }
    return null;
}
pub var edit_hwnd: usize = 0;

pub var window_style: u32 = 0;
pub var window_exstyle: u32 = 0;
pub var window_x: i32 = 0;
pub var window_y: i32 = 0;
pub var window_width: i32 = 0;
pub var window_height: i32 = 0;
pub var window_has_menu: bool = false;

pub var current_client_width: i32 = 160;
pub var current_client_height: i32 = 144;

pub var has_activated: bool = false;

pub var pending_command: ?u32 = null;
pub var pending_command_mutex: if (platform_mod.is_native) std.Thread.Mutex else struct {
    pub fn lock(_: *@This()) void {}
    pub fn unlock(_: *@This()) void {}
} = .{};

pub var pending_messages: [32]MSG = undefined;
pub var pending_messages_head: usize = 0;
pub var pending_messages_tail: usize = 0;

// --- Shared Helpers ---

pub fn calcFrameAdjustments(dwStyle: u32, bMenu: bool, dwExStyle: u32) struct { left: i32, top: i32, right: i32, bottom: i32 } {
    var left: i32 = 0;
    var top: i32 = 0;
    var right: i32 = 0;
    var bottom: i32 = 0;

    if ((dwStyle & WS_THICKFRAME) != 0) {
        left += SM_CXFRAME;
        right += SM_CXFRAME;
        top += SM_CYFRAME;
        bottom += SM_CYFRAME;
    } else if ((dwStyle & WS_DLGFRAME) != 0) {
        left += SM_CXDLGFRAME;
        right += SM_CXDLGFRAME;
        top += SM_CYDLGFRAME;
        bottom += SM_CYDLGFRAME;
    } else if ((dwStyle & WS_BORDER) != 0) {
        left += SM_CXBORDER;
        right += SM_CXBORDER;
        top += SM_CYBORDER;
        bottom += SM_CYBORDER;
    }

    if ((dwStyle & WS_CAPTION) == WS_CAPTION) {
        top += SM_CYCAPTION;
    }

    if (bMenu) {
        top += SM_CYMENU;
    }

    if ((dwStyle & WS_VSCROLL) != 0) {
        right += 17; // SM_CXVSCROLL
    }
    if ((dwStyle & WS_HSCROLL) != 0) {
        bottom += 17; // SM_CYHSCROLL
    }

    if ((dwExStyle & WS_EX_CLIENTEDGE) != 0) {
        left += SM_CXEDGE;
        right += SM_CXEDGE;
        top += SM_CYEDGE;
        bottom += SM_CYEDGE;
    }

    if ((dwExStyle & WS_EX_WINDOWEDGE) != 0) {
        left += SM_CXEDGE;
        right += SM_CXEDGE;
        top += SM_CYEDGE;
        bottom += SM_CYEDGE;
    }

    if ((dwExStyle & WS_EX_STATICEDGE) != 0) {
        left += SM_CXBORDER;
        right += SM_CXBORDER;
        top += SM_CYBORDER;
        bottom += SM_CYBORDER;
    }

    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

// --- Public API for web_ui ---

pub fn postCommand(id: u32) void {
    pending_command_mutex.lock();
    defer pending_command_mutex.unlock();
    pending_command = id;
}

pub fn postGenericMessage(msg_id: u32, wParam: usize, lParam: isize) void {
    pending_command_mutex.lock();
    defer pending_command_mutex.unlock();

    const next_head = (pending_messages_head + 1) % pending_messages.len;
    if (next_head != pending_messages_tail) {
        pending_messages[pending_messages_head] = .{
            .hwnd = global_hwnd,
            .message = msg_id,
            .wParam = wParam,
            .lParam = lParam,
            .time = 0,
            .pt_x = 0,
            .pt_y = 0,
        };
        pending_messages_head = next_head;
    }
}

pub fn postKeyboardMessage(msg_id: u32, wParam: usize, lParam: isize) void {
    pending_command_mutex.lock();
    defer pending_command_mutex.unlock();

    const next_head = (pending_messages_head + 1) % pending_messages.len;
    if (next_head != pending_messages_tail) {
        pending_messages[pending_messages_head] = .{
            .hwnd = global_hwnd,
            .message = msg_id,
            .wParam = wParam,
            .lParam = lParam,
            .time = 0,
            .pt_x = 0,
            .pt_y = 0,
        };
        pending_messages_head = next_head;
    }
}

// --- Renderer Input Callbacks ---

fn handleCommand(id: u32) void {
    postCommand(id);
}

fn handleClose() void {
    postGenericMessage(w32.WM_CLOSE, 0, 0);
}

fn handleExternalResize(clientW: i32, clientH: i32, sizeType: usize) void {
    if (clientW <= 0 or clientH <= 0) return;

    const adj = calcFrameAdjustments(window_style, window_has_menu, window_exstyle);
    current_client_width = clientW;
    current_client_height = clientH;
    window_width = clientW + adj.left + adj.right;
    window_height = clientH + adj.top + adj.bottom;

    const w: u32 = @intCast(@as(u16, @truncate(@as(u32, @bitCast(clientW)))));
    const h: u32 = @intCast(@as(u16, @truncate(@as(u32, @bitCast(clientH)))));
    postGenericMessage(w32.WM_SIZE, sizeType, @as(isize, @intCast((h << 16) | w)));
}

fn handleKeyEvent(vk_code: usize, is_down: bool) void {
    const renderer = @import("../gui/renderer.zig");
    const vk: u8 = @intCast(vk_code & 0xFF);
    renderer.keyboard_state[vk] = if (is_down) 0x80 else 0;

    // Alt key (VK_MENU=0x12) held → use WM_SYSKEYDOWN/WM_SYSKEYUP (0x0104/0x0105)
    // Alt key itself also gets WM_SYSKEYDOWN
    const alt_held = (renderer.keyboard_state[0x12] & 0x80) != 0;
    const is_alt_key = (vk == 0x12);
    const is_sys = alt_held or is_alt_key;

    const msg_id: u32 = if (is_sys)
        (if (is_down) w32.WM_SYSKEYDOWN else w32.WM_SYSKEYUP)
    else
        (if (is_down) w32.WM_KEYDOWN else w32.WM_KEYUP);

    // lParam bit 29 = context code (1 if Alt held during SYSKEYDOWN)
    var lp: u32 = 0;
    if (!is_down) lp |= (1 << 31); // transition state
    if (is_sys and is_down) lp |= (1 << 29); // Alt context code
    postKeyboardMessage(msg_id, vk_code, @as(isize, @intCast(@as(i32, @bitCast(lp)))));
}

// --- SEH / WndProc Safe Call ---

const SEH_Frame = extern struct {
    next: *SEH_Frame,
    handler: usize,
    catch_eip: u32,
    catch_esp: u32,
    catch_ebp: u32,
};

export fn user32_seh_handler(record: *anyopaque, frame_ptr: *SEH_Frame, context: *@import("../teb.zig").CONTEXT, dispatch: usize) callconv(.c) u32 {
    _ = record; _ = dispatch;
    if (trace.enable_tracing) trace.print("USER32: Swallowing exception in WindowProc, jumping to catch handler.\n", .{});
    context.Eip = frame_ptr.catch_eip;
    context.Esp = frame_ptr.catch_esp;
    context.Ebp = frame_ptr.catch_ebp;
    return 0; // ExceptionContinueExecution
}

const native_arch = @import("builtin").target.cpu.arch;
const platform_mod = @import("../platform.zig");

comptime {
    if (native_arch == .x86) {
        asm (
            \\.global callWndProcSafe_extern
            \\.type callWndProcSafe_extern, @function
            \\callWndProcSafe_extern:
            \\  pushl %ebp
            \\  movl %esp, %ebp
            \\
            \\  // Build SEH frame on stack
            \\  pushl %ebp       // frame.catch_ebp
            \\  pushl %esp       // frame.catch_esp
            \\  pushl $.L_catch  // frame.catch_eip
            \\  pushl $user32_seh_handler // frame.handler
            \\  movl %fs:0, %eax
            \\  pushl %eax       // frame.next
            \\
            \\  // Install SEH
            \\  movl %esp, %fs:0
            \\
            \\  // Call WndProc (stdcall)
            \\  pushl 24(%ebp)
            \\  pushl 20(%ebp)
            \\  pushl 16(%ebp)
            \\  pushl 12(%ebp)
            \\  movl 8(%ebp), %eax
            \\  call *%eax
            \\
            \\.L_cleanup:
            \\  // Uninstall SEH
            \\  popl %eax
            \\  movl %eax, %fs:0
            \\  addl $16, %esp   // Pop rest of SEH frame
            \\
            \\  movl %ebp, %esp
            \\  popl %ebp
            \\  ret
            \\
            \\.L_catch:
            \\  movl 28(%ebp), %edx
            \\  movl $1, (%edx)
            \\  xorl %eax, %eax
            \\  subl $16, %esp
            \\  jmp .L_cleanup
        );
    }
}

pub const callWndProcSafe = if (platform_mod.is_x86) callWndProcSafe_extern else callWndProcSafe_zig;

extern fn callWndProcSafe_extern(wndproc: usize, hwnd: usize, msg: u32, wParam: usize, lParam: isize, err_out: *u32) callconv(.c) isize;

/// x86_64: direct call without SEH frame (no 32-bit SEH on x86_64)
fn callWndProcSafe_zig(wndproc: usize, hwnd: usize, msg: u32, wParam: usize, lParam: isize, err_out: *u32) callconv(.c) isize {
    err_out.* = 0;
    if (wndproc == 0) return 0;
    const WndProc = *const fn (usize, u32, usize, isize) callconv(.c) isize;
    const func = @as(WndProc, @ptrFromInt(wndproc));
    return func(hwnd, msg, wParam, lParam);
}

// =============================================================================
// Faithful implementations — Tier 3
// =============================================================================

const FAKE_HMONITOR: usize = 0xD0000001;

// --- Monitor functions ---
// All return a valid HMONITOR since we have a single virtual monitor
fn stub_MonitorFromWindow(hwnd: usize, dwFlags: u32) callconv(.winapi) usize {
    _ = hwnd; _ = dwFlags;
    if (trace.enable_tracing) trace.print("USER32: MonitorFromWindow -> 0x{x}\n", .{FAKE_HMONITOR});
    return FAKE_HMONITOR;
}

fn stub_MonitorFromPoint(ptX: i32, ptY: i32, dwFlags: u32) callconv(.winapi) usize {
    _ = ptX; _ = ptY; _ = dwFlags;
    return FAKE_HMONITOR;
}

fn stub_MonitorFromRect(lprc: usize, dwFlags: u32) callconv(.winapi) usize {
    _ = lprc; _ = dwFlags;
    return FAKE_HMONITOR;
}

// BOOL GetMonitorInfoW(HMONITOR hMonitor, LPMONITORINFO lpmi)
// MONITORINFO: { cbSize(4), rcMonitor(RECT=16), rcWork(RECT=16), dwFlags(4) } = 40 bytes total
fn stub_GetMonitorInfoW(hMonitor: usize, lpmi: usize) callconv(.winapi) i32 {
    _ = hMonitor;
    if (lpmi == 0) return 0;

    const cbSize = @as(*align(1) const u32, @ptrFromInt(lpmi)).*;
    if (cbSize < 40) return 0;

    const mi = @as(*w32.MONITORINFO, @ptrFromInt(lpmi));
    mi.rcMonitor = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    mi.rcWork = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    mi.dwFlags = w32.MONITORINFOF_PRIMARY;

    if (trace.enable_tracing) trace.print("USER32: GetMonitorInfoW -> 800x600 primary\n", .{});
    return 1; // TRUE
}

// --- GetDialogBaseUnits ---
// Returns MAKELONG(baseX, baseY) where baseX is average char width and
// baseY is char height of the system font. Standard values: 8, 16
fn stub_GetDialogBaseUnits() callconv(.winapi) u32 {
    const baseX: u32 = 8;
    const baseY: u32 = 16;
    return baseX | (baseY << 16); // MAKELONG(8, 16)
}

// --- CallWindowProcW ---
// LRESULT CallWindowProcW(WNDPROC lpPrevWndFunc, HWND hWnd, UINT Msg, WPARAM wParam, LPARAM lParam)
// Must actually call the window proc!
fn stub_CallWindowProcW(lpPrevWndFunc: usize, hWnd: usize, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize {
    // If the old WndProc is 0, this might be a subclassed common control where we don't
    // have a real WndProc for it. Fall back to our common control message handler.
    if (lpPrevWndFunc == 0) {
        if (trace.enable_tracing) trace.print("USER32: CallWindowProcW(proc=0, msg={x}) -> fallback to common controls\n", .{msg});
        const message_mod = @import("user32/message.zig");
        return message_mod.handleCommonControlMsg(msg, wParam);
    }
    
    if (trace.enable_tracing) trace.print("USER32: CallWindowProcW(proc={x}, msg={x})\n", .{ lpPrevWndFunc, msg });
    
    // Safety check - use callWndProcSafe to prevent SEH crashes if the old proc faults
    var err_flag: u32 = 0;
    return callWndProcSafe(lpPrevWndFunc, hWnd, msg, wParam, lParam, &err_flag);
}

// --- DefFrameProcA / DefMDIChildProcA ---
// Forward to DefWindowProcA for proper MDI message handling
fn stub_DefFrameProcA(hWnd: usize, hWndMDIClient: usize, uMsg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize {
    _ = hWndMDIClient;
    if (trace.enable_tracing) trace.print("USER32: DefFrameProcA(msg={d})\n", .{uMsg});
    return window.stub_DefWindowProcA(hWnd, uMsg, wParam, lParam);
}

fn stub_DefMDIChildProcA(hWnd: usize, uMsg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize {
    if (trace.enable_tracing) trace.print("USER32: DefMDIChildProcA(msg={d})\n", .{uMsg});
    return window.stub_DefWindowProcA(hWnd, uMsg, wParam, lParam);
}

// --- CharToOemBuffA / OemToCharBuffA ---
// For Latin-1 (Western European), these are identity copies
fn stub_CharToOemBuffA(lpszSrc: usize, lpszDst: usize, cchDstLength: u32) callconv(.winapi) i32 {
    if (lpszSrc != 0 and lpszDst != 0 and cchDstLength > 0) {
        const src = @as([*]const u8, @ptrFromInt(lpszSrc));
        const dst = @as([*]u8, @ptrFromInt(lpszDst));
        for (0..cchDstLength) |i| dst[i] = src[i];
    }
    return 1; // TRUE
}

fn stub_OemToCharBuffA(lpszSrc: usize, lpszDst: usize, cchDstLength: u32) callconv(.winapi) i32 {
    if (lpszSrc != 0 and lpszDst != 0 and cchDstLength > 0) {
        const src = @as([*]const u8, @ptrFromInt(lpszSrc));
        const dst = @as([*]u8, @ptrFromInt(lpszDst));
        for (0..cchDstLength) |i| dst[i] = src[i];
    }
    return 1; // TRUE
}

// --- GetLastActivePopup ---
// Returns the most recently active popup window owned by hWnd.
// If hWnd has no popup, returns hWnd itself.
fn stub_GetLastActivePopup(hWnd: usize) callconv(.winapi) usize {
    return hWnd; // No popups → return hWnd itself
}

// --- DeferWindowPos API ---
var defer_wp_counter: usize = 0xDEFE0001;

fn stub_BeginDeferWindowPos(nNumWindows: i32) callconv(.winapi) usize {
    _ = nNumWindows;
    const handle = defer_wp_counter;
    defer_wp_counter +%= 1;
    if (trace.enable_tracing) trace.print("USER32: BeginDeferWindowPos -> 0x{x}\n", .{handle});
    return handle;
}

fn stub_DeferWindowPos(hWinPosInfo: usize, hWnd: usize, hWndInsertAfter: usize, x: i32, y: i32, cx: i32, cy: i32, uFlags: u32) callconv(.winapi) usize {
    _ = hWnd; _ = hWndInsertAfter; _ = x; _ = y; _ = cx; _ = cy; _ = uFlags;
    return hWinPosInfo; // Return same handle (success)
}

fn stub_EndDeferWindowPos(hWinPosInfo: usize) callconv(.winapi) i32 {
    _ = hWinPosInfo;
    return 1; // TRUE
}

// =============================================================================
// Tests
// =============================================================================

test "GetDialogBaseUnits returns MAKELONG(8, 16)" {
    const result = stub_GetDialogBaseUnits();
    const baseX = result & 0xFFFF;
    const baseY = (result >> 16) & 0xFFFF;
    try std.testing.expectEqual(@as(u32, 8), baseX);
    try std.testing.expectEqual(@as(u32, 16), baseY);
}

test "GetLastActivePopup returns hWnd" {
    try std.testing.expectEqual(@as(usize, 0x1234), stub_GetLastActivePopup(0x1234));
}

test "MonitorFromWindow returns valid handle" {
    const handle = stub_MonitorFromWindow(0x1234, 0);
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(FAKE_HMONITOR, handle);
}

test "CharToOemBuffA copies data" {
    var src = [_]u8{ 'H', 'e', 'l', 'l', 'o' };
    var dst: [5]u8 = undefined;
    const result = stub_CharToOemBuffA(@intFromPtr(&src), @intFromPtr(&dst), 5);
    try std.testing.expectEqual(@as(i32, 1), result);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "BeginDeferWindowPos returns non-zero" {
    const handle = stub_BeginDeferWindowPos(5);
    try std.testing.expect(handle != 0);
    // DeferWindowPos returns the same handle
    const handle2 = stub_DeferWindowPos(handle, 0, 0, 0, 0, 100, 100, 0);
    try std.testing.expectEqual(handle, handle2);
    // EndDeferWindowPos returns TRUE
    try std.testing.expectEqual(@as(i32, 1), stub_EndDeferWindowPos(handle));
}
