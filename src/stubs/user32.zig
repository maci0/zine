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
const w32 = @import("../win32_constants.zig");

pub fn register(environment: *env.Environment) !void {
    // Wire up renderer input callbacks
    const renderer = @import("../gui/renderer.zig");
    renderer.on_command = &handleCommand;
    renderer.on_resize = &handleExternalResize;
    renderer.on_key_event = &handleKeyEvent;
    renderer.on_close = &handleClose;

    const m = "USER32.dll";

    // String & Conversion (misc.zig)
    try environment.addBuiltinExportComptime(m, "CharNextA", misc.stub_CharNextA);
    try environment.addBuiltinExportComptime(m, "CharPrevA", misc.stub_CharPrevA);
    try environment.addBuiltinExportComptime(m, "CharToOemA", misc.stub_CharToOemA);
    try environment.addBuiltinExportComptime(m, "OemToCharA", misc.stub_OemToCharA);
    try environment.addBuiltinExportComptime(m, "wsprintfA", misc.stub_wsprintfA);
    try environment.addBuiltinExportComptime(m, "ChangeDisplaySettingsA", misc.stub_ChangeDisplaySettingsA);
    try environment.addBuiltinExportComptime(m, "EnumDisplaySettingsA", misc.stub_EnumDisplaySettingsA);
    try environment.addBuiltinExportComptime(m, "ShowCursor", misc.stub_ShowCursor);

    // Window Management (window.zig)
    try environment.addBuiltinExportComptime(m, "SetRect", window.stub_SetRect);
    try environment.addBuiltinExportComptime(m, "AdjustWindowRectEx", window.stub_AdjustWindowRectEx);
    try environment.addBuiltinExportComptime(m, "AdjustWindowRect", window.stub_AdjustWindowRect);
    try environment.addBuiltinExportComptime(m, "SystemParametersInfoA", window.stub_SystemParametersInfoA);
    try environment.addBuiltinExportComptime(m, "GetSystemMetrics", window.stub_GetSystemMetrics);
    try environment.addBuiltinExportComptime(m, "SetWindowTextA", window.stub_SetWindowTextA);
    try environment.addBuiltinExportComptime(m, "RegisterClassA", window.stub_RegisterClassA);
    try environment.addBuiltinExportComptime(m, "CreateWindowExA", window.stub_CreateWindowExA);
    try environment.addBuiltinExportComptime(m, "ShowWindow", window.stub_ShowWindow);
    try environment.addBuiltinExportComptime(m, "DestroyWindow", window.stub_DestroyWindow);
    try environment.addBuiltinExportComptime(m, "EnableWindow", window.stub_EnableWindow);
    try environment.addBuiltinExportComptime(m, "IsWindow", window.stub_IsWindow);
    try environment.addBuiltinExportComptime(m, "GetClientRect", window.stub_GetClientRect);
    try environment.addBuiltinExportComptime(m, "GetWindowRect", window.stub_GetWindowRect);
    try environment.addBuiltinExportComptime(m, "DefWindowProcA", window.stub_DefWindowProcA);
    try environment.addBuiltinExportComptime(m, "GetWindowLongA", window.stub_GetWindowLongA);
    try environment.addBuiltinExportComptime(m, "SetWindowLongA", window.stub_SetWindowLongA);
    try environment.addBuiltinExportComptime(m, "SetWindowPos", window.stub_SetWindowPos);
    try environment.addBuiltinExportComptime(m, "MoveWindow", window.stub_MoveWindow);
    try environment.addBuiltinExportComptime(m, "ClientToScreen", window.stub_ClientToScreen);
    try environment.addBuiltinExportComptime(m, "ScreenToClient", window.stub_ScreenToClient);
    try environment.addBuiltinExportComptime(m, "GetForegroundWindow", window.stub_GetForegroundWindow);
    try environment.addBuiltinExportComptime(m, "SetForegroundWindow", window.stub_SetForegroundWindow);
    try environment.addBuiltinExportComptime(m, "GetActiveWindow", window.stub_GetActiveWindow);
    try environment.addBuiltinExportComptime(m, "GetDesktopWindow", window.stub_GetDesktopWindow);
    try environment.addBuiltinExportComptime(m, "SetFocus", window.stub_SetFocus);
    try environment.addBuiltinExportComptime(m, "GetFocus", window.stub_GetFocus);
    try environment.addBuiltinExportComptime(m, "IsIconic", window.stub_IsIconic);
    try environment.addBuiltinExportComptime(m, "UpdateWindow", window.stub_UpdateWindow);
    try environment.addBuiltinExportComptime(m, "RedrawWindow", window.stub_RedrawWindow);
    try environment.addBuiltinExportComptime(m, "InvalidateRect", window.stub_InvalidateRect);
    try environment.addBuiltinExportComptime(m, "MapWindowPoints", window.stub_MapWindowPoints);
    try environment.addBuiltinExportComptime(m, "FillRect", window.stub_FillRect);
    try environment.addBuiltinExportComptime(m, "GetDC", window.stub_GetDC);
    try environment.addBuiltinExportComptime(m, "ReleaseDC", window.stub_ReleaseDC);
    try environment.addBuiltinExportComptime(m, "BeginPaint", window.stub_BeginPaint);
    try environment.addBuiltinExportComptime(m, "EndPaint", window.stub_EndPaint);

    // Messaging (message.zig)
    try environment.addBuiltinExportComptime(m, "PeekMessageA", message.stub_PeekMessageA);
    try environment.addBuiltinExportComptime(m, "GetMessageA", message.stub_GetMessageA);
    try environment.addBuiltinExportComptime(m, "TranslateMessage", message.stub_TranslateMessage);
    try environment.addBuiltinExportComptime(m, "DispatchMessageA", message.stub_DispatchMessageA);
    try environment.addBuiltinExportComptime(m, "PostMessageA", message.stub_PostMessageA);
    try environment.addBuiltinExportComptime(m, "PostQuitMessage", message.stub_PostQuitMessage);
    try environment.addBuiltinExportComptime(m, "SendMessageA", message.stub_SendMessageA);

    // Dialog (dialog.zig)
    try environment.addBuiltinExportComptime(m, "MessageBoxA", dialog.stub_MessageBoxA);
    try environment.addBuiltinExportComptime(m, "DialogBoxParamA", dialog.stub_DialogBoxParamA);
    try environment.addBuiltinExportComptime(m, "EndDialog", dialog.stub_EndDialog);
    try environment.addBuiltinExportComptime(m, "GetDlgItem", dialog.stub_GetDlgItem);
    try environment.addBuiltinExportComptime(m, "SetDlgItemTextA", dialog.stub_SetDlgItemTextA);
    try environment.addBuiltinExportComptime(m, "GetDlgItemTextA", dialog.stub_GetDlgItemTextA);
    try environment.addBuiltinExportComptime(m, "SendDlgItemMessageA", dialog.stub_SendDlgItemMessageA);

    // Resource Loading (resource.zig)
    try environment.addBuiltinExportComptime(m, "LoadIconA", resource.stub_LoadIconA);
    try environment.addBuiltinExportComptime(m, "LoadCursorA", resource.stub_LoadCursorA);
    try environment.addBuiltinExportComptime(m, "LoadStringA", resource.stub_LoadStringA);
    try environment.addBuiltinExportComptime(m, "LoadMenuA", resource.stub_LoadMenuA);

    // Menu (menu.zig)
    try environment.addBuiltinExportComptime(m, "GetMenu", menu.stub_GetMenu);
    try environment.addBuiltinExportComptime(m, "DrawMenuBar", menu.stub_DrawMenuBar);
    try environment.addBuiltinExportComptime(m, "SetMenu", menu.stub_SetMenu);
    try environment.addBuiltinExportComptime(m, "DestroyMenu", menu.stub_DestroyMenu);
    try environment.addBuiltinExportComptime(m, "GetSubMenu", menu.stub_GetSubMenu);
    try environment.addBuiltinExportComptime(m, "TrackPopupMenu", menu.stub_TrackPopupMenu);
    try environment.addBuiltinExportComptime(m, "AppendMenuA", menu.stub_AppendMenuA);
    try environment.addBuiltinExportComptime(m, "CheckMenuItem", menu.stub_CheckMenuItem);

    // Input (input.zig)
    try environment.addBuiltinExportComptime(m, "GetKeyboardState", input.stub_GetKeyboardState);
    try environment.addBuiltinExportComptime(m, "GetKeyState", input.stub_GetKeyState);
    try environment.addBuiltinExportComptime(m, "GetAsyncKeyState", input.stub_GetKeyState);
    try environment.addBuiltinExportComptime(m, "SetCursor", input.stub_SetCursor);
    try environment.addBuiltinExportComptime(m, "GetCursorPos", input.stub_GetCursorPos);
    try environment.addBuiltinExportComptime(m, "GetCapture", input.stub_GetCapture);
    try environment.addBuiltinExportComptime(m, "SetCapture", input.stub_SetCapture);
    try environment.addBuiltinExportComptime(m, "ReleaseCapture", input.stub_ReleaseCapture);
    try environment.addBuiltinExportComptime(m, "SetTimer", input.stub_SetTimer);
    try environment.addBuiltinExportComptime(m, "KillTimer", input.stub_KillTimer);
    try environment.addBuiltinExportComptime(m, "GetQueueStatus", input.stub_GetQueueStatus);

    // Additional misc
    try environment.addBuiltinExportComptime(m, "MessageBeep", misc.stub_MessageBeep);
    try environment.addBuiltinExportComptime(m, "SetActiveWindow", misc.stub_SetActiveWindow);
    try environment.addBuiltinExportComptime(m, "GetSysColor", misc.stub_GetSysColor);
    try environment.addBuiltinExportComptime(m, "GetSysColorBrush", misc.stub_GetSysColorBrush);
    try environment.addBuiltinExportComptime(m, "GetParent", misc.stub_GetParent);
    try environment.addBuiltinExportComptime(m, "FindWindowA", misc.stub_FindWindowA);
    try environment.addBuiltinExportComptime(m, "GetWindowTextA", misc.stub_GetWindowTextA);
    try environment.addBuiltinExportComptime(m, "GetWindowTextLengthA", misc.stub_GetWindowTextLengthA);
    try environment.addBuiltinExportComptime(m, "IsZoomed", misc.stub_IsZoomed);
    try environment.addBuiltinExportComptime(m, "RegisterWindowMessageA", misc.stub_RegisterWindowMessageA);
    try environment.addBuiltinExportComptime(m, "GetSystemMenu", misc.stub_GetSystemMenu);
    try environment.addBuiltinExportComptime(m, "GetMessageTime", misc.stub_GetMessageTime);
    try environment.addBuiltinExportComptime(m, "IsDialogMessageA", misc.stub_IsDialogMessageA);
    try environment.addBuiltinExportComptime(m, "MsgWaitForMultipleObjects", misc.stub_MsgWaitForMultipleObjects);
    try environment.addBuiltinExportComptime(m, "GetWindowPlacement", misc.stub_GetWindowPlacement);
    try environment.addBuiltinExportComptime(m, "SetWindowPlacement", misc.stub_SetWindowPlacement);
    try environment.addBuiltinExportComptime(m, "WinHelpA", misc.stub_WinHelpA);
    try environment.addBuiltinExportComptime(m, "DrawTextA", misc.stub_DrawTextA);
    try environment.addBuiltinExportComptime(m, "DrawTextW", misc.stub_DrawTextW);
    try environment.addBuiltinExportComptime(m, "CharLowerA", misc.stub_CharLowerA);
    try environment.addBuiltinExportComptime(m, "CharUpperW", misc.stub_CharUpperW);
    try environment.addBuiltinExportComptime(m, "CharLowerW", misc.stub_CharLowerW);
    try environment.addBuiltinExportComptime(m, "GetKeyboardLayout", misc.stub_GetKeyboardLayout);
    try environment.addBuiltinExportComptime(m, "GetDoubleClickTime", misc.stub_GetDoubleClickTime);
    try environment.addBuiltinExportComptime(m, "GetCaretBlinkTime", misc.stub_GetCaretBlinkTime);
    try environment.addBuiltinExportComptime(m, "EqualRect", misc.stub_EqualRect);
    try environment.addBuiltinExportComptime(m, "InflateRect", misc.stub_InflateRect);
    try environment.addBuiltinExportComptime(m, "IntersectRect", misc.stub_IntersectRect);
    try environment.addBuiltinExportComptime(m, "MessageBoxIndirectA", misc.stub_MessageBoxIndirectA);
    try environment.addBuiltinExportComptime(m, "SetKeyboardState", misc.stub_SetKeyboardState);
    try environment.addBuiltinExportComptime(m, "ToAsciiEx", misc.stub_ToAsciiEx);
    try environment.addBuiltinExportComptime(m, "FlashWindow", misc.stub_FlashWindow);
    try environment.addBuiltinExportComptime(m, "SetClassLongA", misc.stub_SetClassLongA);
    try environment.addBuiltinExportComptime(m, "DefDlgProcA", misc.stub_DefDlgProcA);
    try environment.addBuiltinExportComptime(m, "MapDialogRect", misc.stub_MapDialogRect);
    try environment.addBuiltinExportComptime(m, "RegisterClipboardFormatA", misc.stub_RegisterClipboardFormatA);

    // Additional menu
    try environment.addBuiltinExportComptime(m, "CreateMenu", menu.stub_CreateMenu);
    try environment.addBuiltinExportComptime(m, "CreatePopupMenu", menu.stub_CreatePopupMenu);
    try environment.addBuiltinExportComptime(m, "EnableMenuItem", menu.stub_EnableMenuItem);
    try environment.addBuiltinExportComptime(m, "InsertMenuA", menu.stub_InsertMenuA);
    try environment.addBuiltinExportComptime(m, "InsertMenuItemA", menu.stub_InsertMenuItemA);
    try environment.addBuiltinExportComptime(m, "DeleteMenu", menu.stub_DeleteMenu);
    try environment.addBuiltinExportComptime(m, "GetMenuItemCount", menu.stub_GetMenuItemCount);
    try environment.addBuiltinExportComptime(m, "GetMenuState", menu.stub_GetMenuState);
    try environment.addBuiltinExportComptime(m, "CheckMenuRadioItem", menu.stub_CheckMenuRadioItem);

    // Additional dialog
    try environment.addBuiltinExportComptime(m, "CheckDlgButton", dialog.stub_CheckDlgButton);
    try environment.addBuiltinExportComptime(m, "CheckRadioButton", dialog.stub_CheckRadioButton);
    try environment.addBuiltinExportComptime(m, "IsDlgButtonChecked", dialog.stub_IsDlgButtonChecked);
    try environment.addBuiltinExportComptime(m, "GetDlgItemInt", dialog.stub_GetDlgItemInt);
    try environment.addBuiltinExportComptime(m, "SetDlgItemInt", dialog.stub_SetDlgItemInt);
    try environment.addBuiltinExportComptime(m, "CreateDialogParamA", dialog.stub_CreateDialogParamA);
    try environment.addBuiltinExportComptime(m, "MessageBoxW", dialog.stub_MessageBoxW);

    // Additional window
    try environment.addBuiltinExportComptime(m, "SetScrollInfo", window.stub_SetScrollInfo);
    try environment.addBuiltinExportComptime(m, "GetScrollInfo", window.stub_GetScrollInfo);
    try environment.addBuiltinExportComptime(m, "CopyImage", window.stub_CopyImage);
    try environment.addBuiltinExportComptime(m, "DrawEdge", window.stub_DrawEdge);
    try environment.addBuiltinExportComptime(m, "DrawFocusRect", window.stub_DrawFocusRect);
    try environment.addBuiltinExportComptime(m, "FrameRect", window.stub_FrameRect);
    try environment.addBuiltinExportComptime(m, "EnumWindows", window.stub_EnumWindows);
    try environment.addBuiltinExportComptime(m, "IsChild", window.stub_IsChild);
    try environment.addBuiltinExportComptime(m, "IsWindowEnabled", window.stub_IsWindowEnabled);
    try environment.addBuiltinExportComptime(m, "GetIconInfo", window.stub_GetIconInfo);
    try environment.addBuiltinExportComptime(m, "DestroyIcon", window.stub_DestroyIcon);
    try environment.addBuiltinExportComptime(m, "DestroyCursor", window.stub_DestroyCursor);

    // Clipboard
    try environment.addBuiltinExportComptime(m, "OpenClipboard", window.stub_OpenClipboard);
    try environment.addBuiltinExportComptime(m, "CloseClipboard", window.stub_CloseClipboard);
    try environment.addBuiltinExportComptime(m, "EmptyClipboard", window.stub_EmptyClipboard);
    try environment.addBuiltinExportComptime(m, "GetClipboardData", window.stub_GetClipboardData);
    try environment.addBuiltinExportComptime(m, "SetClipboardData", window.stub_SetClipboardData);
    try environment.addBuiltinExportComptime(m, "IsClipboardFormatAvailable", window.stub_IsClipboardFormatAvailable);
    try environment.addBuiltinExportComptime(m, "GetClipboardOwner", window.stub_GetClipboardOwner);

    // Caret
    try environment.addBuiltinExportComptime(m, "CreateCaret", window.stub_CreateCaret);
    try environment.addBuiltinExportComptime(m, "DestroyCaret", window.stub_DestroyCaret);
    try environment.addBuiltinExportComptime(m, "SetCaretPos", window.stub_SetCaretPos);
    try environment.addBuiltinExportComptime(m, "ShowCaret", window.stub_ShowCaret);
    try environment.addBuiltinExportComptime(m, "HideCaret", window.stub_HideCaret);

    // Europa 1400 compatibility
    try environment.addBuiltinExportComptime(m, "ValidateRect", misc.stub_ValidateRect);
    try environment.addBuiltinExportComptime(m, "UnregisterClassA", misc.stub_UnregisterClassA);
    try environment.addBuiltinExportComptime(m, "IsWindowVisible", misc.stub_IsWindowVisible);
    try environment.addBuiltinExportComptime(m, "CallNextHookEx", misc.stub_CallNextHookEx);
    try environment.addBuiltinExportComptime(m, "MapVirtualKeyA", misc.stub_MapVirtualKeyA);
    try environment.addBuiltinExportComptime(m, "RegisterClassExA", misc.stub_RegisterClassExA);
    try environment.addBuiltinExportComptime(m, "BringWindowToTop", misc.stub_BringWindowToTop);
    try environment.addBuiltinExportComptime(m, "VkKeyScanA", misc.stub_VkKeyScanA);
    try environment.addBuiltinExportComptime(m, "SetCursorPos", misc.stub_SetCursorPos);
    try environment.addBuiltinExportComptime(m, "SetWindowsHookExA", misc.stub_SetWindowsHookExA);
    try environment.addBuiltinExportComptime(m, "UnhookWindowsHookEx", misc.stub_UnhookWindowsHookEx);
    try environment.addBuiltinExportComptime(m, "GetWindowThreadProcessId", misc.stub_GetWindowThreadProcessId);
    try environment.addBuiltinExportComptime(m, "GetWindow", misc.stub_GetWindow);
    try environment.addBuiltinExportComptime(m, "GetTopWindow", misc.stub_GetTopWindow);

    try environment.addBuiltinExportComptime(m, "LoadAcceleratorsA", resource.stub_LoadAcceleratorsA);
    try environment.addBuiltinExportComptime(m, "LoadImageA", resource.stub_LoadImageA);

    // --- Wide (W) variants for Unicode apps ---
    try environment.addBuiltinExportComptime(m, "RegisterClassExW", misc.stub_RegisterClassExW);
    try environment.addBuiltinExportComptime(m, "CreateWindowExW", window.stub_CreateWindowExW);
    try environment.addBuiltinExportComptime(m, "DefWindowProcW", window.stub_DefWindowProcA);
    try environment.addBuiltinExportComptime(m, "GetMessageW", message.stub_GetMessageA);
    try environment.addBuiltinExportComptime(m, "PeekMessageW", message.stub_PeekMessageA);
    try environment.addBuiltinExportComptime(m, "DispatchMessageW", message.stub_DispatchMessageA);
    try environment.addBuiltinExportComptime(m, "SendMessageW", message.stub_SendMessageA);
    try environment.addBuiltinExportComptime(m, "PostMessageW", message.stub_PostMessageA);
    try environment.addBuiltinExportComptime(m, "TranslateAcceleratorW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "LoadAcceleratorsW", resource.stub_LoadAcceleratorsW);
    try environment.addBuiltinExportComptime(m, "LoadStringW", resource.stub_LoadStringW);
    try environment.addBuiltinExportComptime(m, "LoadCursorW", resource.stub_LoadCursorA);
    try environment.addBuiltinExportComptime(m, "LoadIconW", resource.stub_LoadIconA);
    try environment.addBuiltinExportComptime(m, "LoadImageW", resource.stub_LoadImageW);
    try environment.addBuiltinExportComptime(m, "GetWindowLongW", window.stub_GetWindowLongA);
    try environment.addBuiltinExportComptime(m, "SetWindowLongW", window.stub_SetWindowLongA);
    try environment.addBuiltinExportComptime(m, "SetWindowTextW", window.stub_SetWindowTextW);
    try environment.addBuiltinExportComptime(m, "GetWindowTextW", misc.stub_GetWindowTextA);
    try environment.addBuiltinExportComptime(m, "DialogBoxParamW", dialog.stub_DialogBoxParamA);
    try environment.addBuiltinExportComptime(m, "CreateDialogParamW", dialog.stub_CreateDialogParamA);
    try environment.addBuiltinExportComptime(m, "SetDlgItemTextW", dialog.stub_SetDlgItemTextA);
    try environment.addBuiltinExportComptime(m, "GetDlgItemTextW", dialog.stub_GetDlgItemTextA);
    try environment.addBuiltinExportComptime(m, "SendDlgItemMessageW", dialog.stub_SendDlgItemMessageA);
    try environment.addBuiltinExportComptime(m, "IsDialogMessageW", misc.stub_IsDialogMessageA);
    try environment.addBuiltinExportComptime(m, "SetScrollPos", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "WinHelpW", misc.stub_WinHelpA);
    try environment.addBuiltinExportComptime(m, "GetDlgCtrlID", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "ChildWindowFromPoint", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "CharNextW", misc.stub_CharNextW);
    try environment.addBuiltinExportComptime(m, "DrawTextExW", stub_ret0_6);
    try environment.addBuiltinExportComptime(m, "wsprintfW", misc.stub_wsprintfW);
    try environment.addBuiltinExportComptime(m, "RegisterWindowMessageW", misc.stub_RegisterWindowMessageW);

    // Rect utilities (win2k apps: 5-6x each)
    try environment.addBuiltinExportComptime(m, "CopyRect", window.stub_CopyRect);
    try environment.addBuiltinExportComptime(m, "PtInRect", window.stub_PtInRect);
    try environment.addBuiltinExportComptime(m, "OffsetRect", window.stub_OffsetRect);
    try environment.addBuiltinExportComptime(m, "SetRectEmpty", window.stub_SetRectEmpty);
    try environment.addBuiltinExportComptime(m, "IsRectEmpty", window.stub_IsRectEmpty);
    try environment.addBuiltinExportComptime(m, "UnionRect", window.stub_UnionRect);
    try environment.addBuiltinExportComptime(m, "SubtractRect", window.stub_SubtractRect);

    // Window/Class W variants (win2k apps: 3-6x each)
    try environment.addBuiltinExportComptime(m, "FindWindowW", window.stub_FindWindowW);
    try environment.addBuiltinExportComptime(m, "FindWindowExW", window.stub_FindWindowExW);
    try environment.addBuiltinExportComptime(m, "GetClassInfoW", window.stub_GetClassInfoW);
    try environment.addBuiltinExportComptime(m, "GetClassInfoExW", window.stub_GetClassInfoExW);
    try environment.addBuiltinExportComptime(m, "SystemParametersInfoW", window.stub_SystemParametersInfoW);
    try environment.addBuiltinExportComptime(m, "GetUpdateRect", window.stub_GetUpdateRect);
    try environment.addBuiltinExportComptime(m, "GetWindowDC", window.stub_GetWindowDC);

    // W variant aliases for resource/menu (win2k apps: 3-6x each)
    try environment.addBuiltinExportComptime(m, "LoadMenuW", resource.stub_LoadMenuA);
    try environment.addBuiltinExportComptime(m, "RegisterClassW", window.stub_RegisterClassA);
    try environment.addBuiltinExportComptime(m, "LoadBitmapW", resource.stub_LoadBitmapW);
    try environment.addBuiltinExportComptime(m, "RegisterClipboardFormatW", misc.stub_RegisterClipboardFormatA);
    try environment.addBuiltinExportComptime(m, "RemoveMenu", menu.stub_DeleteMenu);
    try environment.addBuiltinExportComptime(m, "AppendMenuW", menu.stub_AppendMenuA);
    try environment.addBuiltinExportComptime(m, "TrackPopupMenuEx", stub_ret0_6);
    try environment.addBuiltinExportComptime(m, "CountClipboardFormats", stub_ret0_0);
    try environment.addBuiltinExportComptime(m, "GetMessagePos", stub_ret0_0);
    try environment.addBuiltinExportComptime(m, "DrawIcon", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "OpenDesktopW", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "CloseDesktop", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "GetThreadDesktop", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "GetProcessWindowStation", stub_ret0_0);
    try environment.addBuiltinExportComptime(m, "SetThreadDesktop", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "OpenWindowStationW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "SetProcessWindowStation", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "GetUserObjectInformationW", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "GrayStringW", stub_ret0_6);
    try environment.addBuiltinExportComptime(m, "TabbedTextOutW", stub_ret0_6);
    try environment.addBuiltinExportComptime(m, "GetWindowTextLengthW", misc.stub_GetWindowTextLengthA);
    try environment.addBuiltinExportComptime(m, "IsMenu", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "GetClassNameW", stub_ret0_3);

    // --- Remaining USER32 stubs for 100% win2k coverage ---
    try environment.addBuiltinExportComptime(m, "CharToOemBuffA", stub_CharToOemBuffA);
    try environment.addBuiltinExportComptime(m, "CallWindowProcW", stub_CallWindowProcW);
    try environment.addBuiltinExportComptime(m, "GetMonitorInfoW", stub_GetMonitorInfoW);
    try environment.addBuiltinExportComptime(m, "SendMessageTimeoutW", stub_ret0_6);
    try environment.addBuiltinExportComptime(m, "DdeUninitialize", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "DdeFreeStringHandle", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "TranslateAcceleratorA", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "TranslateMDISysAccel", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "SetClipboardViewer", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "DdeGetLastError", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "DdeCreateStringHandleA", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "DdeInitializeA", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "ShowScrollBar", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "DefMDIChildProcA", stub_DefMDIChildProcA);
    try environment.addBuiltinExportComptime(m, "DefFrameProcA", stub_DefFrameProcA);
    try environment.addBuiltinExportComptime(m, "DdeFreeDataHandle", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "DdeUnaccessData", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "DdeAccessData", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "DdeKeepStringHandle", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "GetMenuStringA", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "ChangeClipboardChain", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "DdeDisconnect", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "DdeSetUserHandle", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "DdeConnect", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "DdeClientTransaction", stub_ret0_8);
    try environment.addBuiltinExportComptime(m, "DdeGetData", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "SetScrollRange", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "EnumClipboardFormats", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "ScrollWindow", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "GetClipboardFormatNameA", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "GetScrollPos", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "GetScrollRange", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "LoadBitmapA", resource.stub_LoadBitmapA);
    try environment.addBuiltinExportComptime(m, "DdeQueryConvInfo", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "GetClipboardFormatNameW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "SetProcessDefaultLayout", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "GetProcessDefaultLayout", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "RegisterHotKey", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "UnregisterHotKey", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "OpenInputDesktop", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "WindowFromPoint", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "GetCaretPos", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "SetClassLongW", misc.stub_SetClassLongA);
    try environment.addBuiltinExportComptime(m, "EnableScrollBar", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "wvsprintfW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "RegisterDeviceNotificationW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "SetPropW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "RemovePropW", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "MonitorFromPoint", stub_MonitorFromPoint);
    try environment.addBuiltinExportComptime(m, "CreateDialogIndirectParamW", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "UnhookWindowsHook", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "SetWindowsHookW", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "DefDlgProcW", misc.stub_DefDlgProcA);
    try environment.addBuiltinExportComptime(m, "GetPropW", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "UnregisterDeviceNotification", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "InvertRect", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "PostThreadMessageW", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "CharLowerBuffW", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "GetGuiResources", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "SetMenuDefaultItem", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "EnumWindowStationsW", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "GetClassLongW", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "IsHungAppWindow", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "EnumDesktopsW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "CloseWindowStation", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "InternalGetWindowText", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "EndTask", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "ShowWindowAsync", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "CascadeWindows", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "TileWindows", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "SwitchToThisWindow", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "GetLastActivePopup", stub_GetLastActivePopup);
    try environment.addBuiltinExportComptime(m, "OpenIcon", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "GetShellWindow", stub_ret0_0);
    try environment.addBuiltinExportComptime(m, "BeginDeferWindowPos", stub_BeginDeferWindowPos);
    try environment.addBuiltinExportComptime(m, "DeferWindowPos", stub_DeferWindowPos);
    try environment.addBuiltinExportComptime(m, "EndDeferWindowPos", stub_EndDeferWindowPos);
    try environment.addBuiltinExportComptime(m, "GetMenuItemInfoW", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "GetDialogBaseUnits", stub_GetDialogBaseUnits);
    try environment.addBuiltinExportComptime(m, "MonitorFromRect", stub_MonitorFromRect);
    try environment.addBuiltinExportComptime(m, "GetUpdateRgn", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "GetDCEx", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "AllowSetForegroundWindow", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "GetMenuItemRect", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "MonitorFromWindow", stub_MonitorFromWindow);
    try environment.addBuiltinExportComptime(m, "OemToCharBuffA", stub_OemToCharBuffA);
    try environment.addBuiltinExportComptime(m, "SetWindowsHookExW", misc.stub_SetWindowsHookExA);
    try environment.addBuiltinExportComptime(m, "GetNextDlgTabItem", stub_ret0_3);
}

// --- Generic stubs ---

fn stub_ret0_0() callconv(w32cc.WINAPI) usize {
    return 0;
}
fn stub_ret0_1(a: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    return 0;
}
fn stub_ret0_2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    return 0;
}
fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    return 0;
}
fn stub_ret0_4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    return 0;
}
fn stub_ret0_5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    return 0;
}
fn stub_ret0_6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    return 0;
}
fn stub_ret0_7(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize) callconv(w32cc.WINAPI) usize {
    _ = a; _ = b; _ = c; _ = d; _ = e; _ = f; _ = g;
    return 0;
}
fn stub_ret0_8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize {
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

pub var global_wndproc: ?*const fn (usize, u32, usize, isize) callconv(w32cc.WINAPI) isize = null;
pub var global_hwnd: usize = 0;

// Per-hwnd WndProc lookup table (for dialogs, subclassed windows, etc.)
const WndProcType = *const fn (usize, u32, usize, isize) callconv(w32cc.WINAPI) isize;
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
pub var pending_command_mutex: platform_mod.Mutex = .{};

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
const w32cc = @import("../calling_convention.zig");

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
    const WndProc = *const fn (usize, u32, usize, isize) callconv(w32cc.WINAPI) isize;
    const func = @as(WndProc, @ptrFromInt(wndproc));
    return func(hwnd, msg, wParam, lParam);
}

// =============================================================================
// Faithful implementations — Tier 3
// =============================================================================

const FAKE_HMONITOR: usize = 0xD0000001;

// --- Monitor functions ---
// All return a valid HMONITOR since we have a single virtual monitor
fn stub_MonitorFromWindow(hwnd: usize, dwFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = hwnd; _ = dwFlags;
    if (trace.enable_tracing) trace.print("USER32: MonitorFromWindow -> 0x{x}\n", .{FAKE_HMONITOR});
    return FAKE_HMONITOR;
}

fn stub_MonitorFromPoint(ptX: i32, ptY: i32, dwFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = ptX; _ = ptY; _ = dwFlags;
    return FAKE_HMONITOR;
}

fn stub_MonitorFromRect(lprc: usize, dwFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = lprc; _ = dwFlags;
    return FAKE_HMONITOR;
}

// BOOL GetMonitorInfoW(HMONITOR hMonitor, LPMONITORINFO lpmi)
// MONITORINFO: { cbSize(4), rcMonitor(RECT=16), rcWork(RECT=16), dwFlags(4) } = 40 bytes total
fn stub_GetMonitorInfoW(hMonitor: usize, lpmi: usize) callconv(w32cc.WINAPI) i32 {
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
fn stub_GetDialogBaseUnits() callconv(w32cc.WINAPI) u32 {
    const baseX: u32 = 8;
    const baseY: u32 = 16;
    return baseX | (baseY << 16); // MAKELONG(8, 16)
}

// --- CallWindowProcW ---
// LRESULT CallWindowProcW(WNDPROC lpPrevWndFunc, HWND hWnd, UINT Msg, WPARAM wParam, LPARAM lParam)
// Must actually call the window proc!
fn stub_CallWindowProcW(lpPrevWndFunc: usize, hWnd: usize, msg: u32, wParam: usize, lParam: isize) callconv(w32cc.WINAPI) isize {
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
fn stub_DefFrameProcA(hWnd: usize, hWndMDIClient: usize, uMsg: u32, wParam: usize, lParam: isize) callconv(w32cc.WINAPI) isize {
    _ = hWndMDIClient;
    if (trace.enable_tracing) trace.print("USER32: DefFrameProcA(msg={d})\n", .{uMsg});
    return window.stub_DefWindowProcA(hWnd, uMsg, wParam, lParam);
}

fn stub_DefMDIChildProcA(hWnd: usize, uMsg: u32, wParam: usize, lParam: isize) callconv(w32cc.WINAPI) isize {
    if (trace.enable_tracing) trace.print("USER32: DefMDIChildProcA(msg={d})\n", .{uMsg});
    return window.stub_DefWindowProcA(hWnd, uMsg, wParam, lParam);
}

// --- CharToOemBuffA / OemToCharBuffA ---
// For Latin-1 (Western European), these are identity copies
fn stub_CharToOemBuffA(lpszSrc: usize, lpszDst: usize, cchDstLength: u32) callconv(w32cc.WINAPI) i32 {
    if (lpszSrc != 0 and lpszDst != 0 and cchDstLength > 0) {
        const src = @as([*]const u8, @ptrFromInt(lpszSrc));
        const dst = @as([*]u8, @ptrFromInt(lpszDst));
        for (0..cchDstLength) |i| dst[i] = src[i];
    }
    return 1; // TRUE
}

fn stub_OemToCharBuffA(lpszSrc: usize, lpszDst: usize, cchDstLength: u32) callconv(w32cc.WINAPI) i32 {
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
fn stub_GetLastActivePopup(hWnd: usize) callconv(w32cc.WINAPI) usize {
    return hWnd; // No popups → return hWnd itself
}

// --- DeferWindowPos API ---
var defer_wp_counter: usize = 0xDEFE0001;

fn stub_BeginDeferWindowPos(nNumWindows: i32) callconv(w32cc.WINAPI) usize {
    _ = nNumWindows;
    const handle = defer_wp_counter;
    defer_wp_counter +%= 1;
    if (trace.enable_tracing) trace.print("USER32: BeginDeferWindowPos -> 0x{x}\n", .{handle});
    return handle;
}

fn stub_DeferWindowPos(hWinPosInfo: usize, hWnd: usize, hWndInsertAfter: usize, x: i32, y: i32, cx: i32, cy: i32, uFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = hWnd; _ = hWndInsertAfter; _ = x; _ = y; _ = cx; _ = cy; _ = uFlags;
    return hWinPosInfo; // Return same handle (success)
}

fn stub_EndDeferWindowPos(hWinPosInfo: usize) callconv(w32cc.WINAPI) i32 {
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
