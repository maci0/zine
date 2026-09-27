const std = @import("std");
const x86_memory = @import("../x86/memory.zig");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const ansi = @import("ansi.zig");
const unicase = @import("unicase.zig");
const text_utils = @import("../text_utils.zig");

// Sub-modules
const window = @import("user32/window.zig");
const message = @import("user32/message.zig");
const dialog = @import("user32/dialog.zig");
const resource = @import("user32/resource.zig");
const menu = @import("user32/menu.zig");
const input = @import("user32/input.zig");
const char = @import("user32/char.zig");
const display = @import("user32/display.zig");
const class = @import("user32/class.zig");
const format = @import("user32/format.zig");
const w32 = @import("constants.zig");

pub fn register(environment: *env.Environment) !void {
    // Wire up renderer input callbacks
    const renderer = @import("../gui/renderer.zig");
    renderer.on_command = &handleCommand;
    renderer.on_listbox_select = &handleListboxSelect;
    renderer.on_resize = &handleExternalResize;
    renderer.on_key_event = &handleKeyEvent;
    renderer.on_mouse_event = &handleMouseEvent;
    renderer.on_wheel_event = &handleWheelEvent;
    renderer.on_close = &handleClose;

    const m = "USER32.dll";

    // Character conversion (char.zig)
    try environment.addBuiltinExportComptime(m, "CharNextA", char.CharNextA);
    try environment.addBuiltinExportComptime(m, "CharPrevA", char.CharPrevA);
    try environment.addBuiltinExportComptime(m, "CharToOemA", char.CharToOemA);
    try environment.addBuiltinExportComptime(m, "OemToCharA", char.OemToCharA);

    // Text formatting (format.zig)
    try environment.addBuiltinExportComptime(m, "wsprintfA", format.wsprintfA);

    // Display/visual (display.zig)
    try environment.addBuiltinExportComptime(m, "ChangeDisplaySettingsA", display.stub_ChangeDisplaySettingsA);
    try environment.addBuiltinExportComptime(m, "EnumDisplaySettingsA", display.EnumDisplaySettingsA);
    try environment.addBuiltinExportComptime(m, "ShowCursor", display.ShowCursor);

    // Window Management (window.zig)
    try environment.addBuiltinExportComptime(m, "SetRect", window.SetRect);
    try environment.addBuiltinExportComptime(m, "AdjustWindowRectEx", window.AdjustWindowRectEx);
    try environment.addBuiltinExportComptime(m, "AdjustWindowRect", window.AdjustWindowRect);
    try environment.addBuiltinExportComptime(m, "SystemParametersInfoA", window.SystemParametersInfoA);
    try environment.addBuiltinExportComptime(m, "GetSystemMetrics", window.GetSystemMetrics);
    try environment.addBuiltinExportComptime(m, "SetWindowTextA", window.stub_SetWindowTextA);
    try environment.addBuiltinExportComptime(m, "RegisterClassA", window.RegisterClassA);
    try environment.addBuiltinExportComptime(m, "CreateWindowExA", window.CreateWindowExA);
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
    try environment.addBuiltinExportComptime(m, "PeekMessageA", message.PeekMessageA);
    try environment.addBuiltinExportComptime(m, "GetMessageA", message.GetMessageA);
    try environment.addBuiltinExportComptime(m, "TranslateMessage", message.TranslateMessage);
    try environment.addBuiltinExportComptime(m, "DispatchMessageA", message.DispatchMessageA);
    try environment.addBuiltinExportComptime(m, "PostMessageA", message.PostMessageA);
    try environment.addBuiltinExportComptime(m, "PostQuitMessage", message.PostQuitMessage);
    try environment.addBuiltinExportComptime(m, "SendMessageA", message.SendMessageA);

    // Dialog (dialog.zig)
    try environment.addBuiltinExportComptime(m, "MessageBoxA", dialog.MessageBoxA);
    try environment.addBuiltinExportComptime(m, "DialogBoxParamA", dialog.DialogBoxParamA);
    try environment.addBuiltinExportComptime(m, "EndDialog", dialog.EndDialog);
    try environment.addBuiltinExportComptime(m, "GetDlgItem", dialog.GetDlgItem);
    try environment.addBuiltinExportComptime(m, "SetDlgItemTextA", dialog.SetDlgItemTextA);
    try environment.addBuiltinExportComptime(m, "GetDlgItemTextA", dialog.GetDlgItemTextA);
    try environment.addBuiltinExportComptime(m, "SendDlgItemMessageA", dialog.stub_SendDlgItemMessageA);

    // Resource Loading (resource.zig)
    try environment.addBuiltinExportComptime(m, "LoadIconA", resource.LoadIconA);
    try environment.addBuiltinExportComptime(m, "LoadCursorA", resource.stub_LoadCursorA);
    try environment.addBuiltinExportComptime(m, "LoadStringA", resource.LoadStringA);
    try environment.addBuiltinExportComptime(m, "LoadMenuA", resource.stub_LoadMenuA);

    // Menu (menu.zig)
    try environment.addBuiltinExportComptime(m, "GetMenu", menu.stub_GetMenu);
    try environment.addBuiltinExportComptime(m, "DrawMenuBar", menu.stub_DrawMenuBar);
    try environment.addBuiltinExportComptime(m, "SetMenu", menu.SetMenu);
    try environment.addBuiltinExportComptime(m, "DestroyMenu", menu.stub_DestroyMenu);
    try environment.addBuiltinExportComptime(m, "GetSubMenu", menu.stub_GetSubMenu);
    try environment.addBuiltinExportComptime(m, "TrackPopupMenu", menu.stub_TrackPopupMenu);
    try environment.addBuiltinExportComptime(m, "AppendMenuA", menu.stub_AppendMenuA);
    try environment.addBuiltinExportComptime(m, "CheckMenuItem", menu.CheckMenuItem);

    // Input (input.zig)
    try environment.addBuiltinExportComptime(m, "GetKeyboardState", input.GetKeyboardState);
    try environment.addBuiltinExportComptime(m, "GetKeyState", input.GetKeyState);
    try environment.addBuiltinExportComptime(m, "GetAsyncKeyState", input.GetKeyState);
    try environment.addBuiltinExportComptime(m, "SetCursor", input.stub_SetCursor);
    try environment.addBuiltinExportComptime(m, "GetCursorPos", input.GetCursorPos);
    try environment.addBuiltinExportComptime(m, "GetCapture", input.GetCapture);
    try environment.addBuiltinExportComptime(m, "SetCapture", input.SetCapture);
    try environment.addBuiltinExportComptime(m, "ReleaseCapture", input.ReleaseCapture);
    try environment.addBuiltinExportComptime(m, "SetTimer", input.SetTimer);
    try environment.addBuiltinExportComptime(m, "KillTimer", input.KillTimer);
    try environment.addBuiltinExportComptime(m, "GetQueueStatus", input.stub_GetQueueStatus);

    // Additional input / window
    try environment.addBuiltinExportComptime(m, "MessageBeep", input.stub_MessageBeep);
    try environment.addBuiltinExportComptime(m, "SetActiveWindow", window.stub_SetActiveWindow);
    try environment.addBuiltinExportComptime(m, "GetSysColor", display.GetSysColor);
    try environment.addBuiltinExportComptime(m, "GetSysColorBrush", display.GetSysColorBrush);
    try environment.addBuiltinExportComptime(m, "GetParent", window.stub_GetParent);
    try environment.addBuiltinExportComptime(m, "FindWindowA", window.stub_FindWindowA);
    try environment.addBuiltinExportComptime(m, "GetWindowTextA", window.stub_GetWindowTextA);
    try environment.addBuiltinExportComptime(m, "GetWindowTextLengthA", window.stub_GetWindowTextLengthA);
    try environment.addBuiltinExportComptime(m, "IsZoomed", window.stub_IsZoomed);
    try environment.addBuiltinExportComptime(m, "RegisterWindowMessageA", class.RegisterWindowMessageA);
    try environment.addBuiltinExportComptime(m, "GetSystemMenu", window.stub_GetSystemMenu);
    try environment.addBuiltinExportComptime(m, "GetMessageTime", message.GetMessageTime);
    try environment.addBuiltinExportComptime(m, "IsDialogMessageA", dialog.IsDialogMessageA);
    try environment.addBuiltinExportComptime(m, "MsgWaitForMultipleObjects", message.stub_MsgWaitForMultipleObjects);
    try environment.addBuiltinExportComptime(m, "GetWindowPlacement", window.GetWindowPlacement);
    try environment.addBuiltinExportComptime(m, "SetWindowPlacement", window.stub_SetWindowPlacement);
    try environment.addBuiltinExportComptime(m, "WinHelpA", dialog.stub_WinHelpA);
    try environment.addBuiltinExportComptime(m, "DrawTextA", format.DrawTextA);
    try environment.addBuiltinExportComptime(m, "DrawTextW", format.DrawTextW);
    try environment.addBuiltinExportComptime(m, "CharLowerA", char.CharLowerA);
    try environment.addBuiltinExportComptime(m, "CharUpperA", char.CharUpperA);
    try environment.addBuiltinExportComptime(m, "CharUpperW", char.CharUpperW);
    try environment.addBuiltinExportComptime(m, "CharLowerW", char.CharLowerW);
    try environment.addBuiltinExportComptime(m, "GetKeyboardLayout", input.stub_GetKeyboardLayout);
    try environment.addBuiltinExportComptime(m, "GetDoubleClickTime", input.stub_GetDoubleClickTime);
    try environment.addBuiltinExportComptime(m, "GetCaretBlinkTime", input.stub_GetCaretBlinkTime);
    try environment.addBuiltinExportComptime(m, "EqualRect", window.EqualRect);
    try environment.addBuiltinExportComptime(m, "InflateRect", window.InflateRect);
    try environment.addBuiltinExportComptime(m, "IntersectRect", window.IntersectRect);
    try environment.addBuiltinExportComptime(m, "MessageBoxIndirectA", dialog.stub_MessageBoxIndirectA);
    try environment.addBuiltinExportComptime(m, "SetKeyboardState", input.SetKeyboardState);
    try environment.addBuiltinExportComptime(m, "ToAsciiEx", input.stub_ToAsciiEx);
    try environment.addBuiltinExportComptime(m, "FlashWindow", display.stub_FlashWindow);
    try environment.addBuiltinExportComptime(m, "SetClassLongA", class.stub_SetClassLongA);
    try environment.addBuiltinExportComptime(m, "GetClassNameA", class.GetClassNameA);
    try environment.addBuiltinExportComptime(m, "GetClassLongA", class.GetClassLongA);
    try environment.addBuiltinExportComptime(m, "GetUserObjectSecurity", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "DefDlgProcA", dialog.stub_DefDlgProcA);
    try environment.addBuiltinExportComptime(m, "MapDialogRect", dialog.stub_MapDialogRect);
    try environment.addBuiltinExportComptime(m, "RegisterClipboardFormatA", class.RegisterClipboardFormatA);

    // Additional menu
    try environment.addBuiltinExportComptime(m, "CreateMenu", menu.CreateMenu);
    try environment.addBuiltinExportComptime(m, "CreatePopupMenu", menu.CreatePopupMenu);
    try environment.addBuiltinExportComptime(m, "EnableMenuItem", menu.EnableMenuItem);
    try environment.addBuiltinExportComptime(m, "InsertMenuA", menu.stub_InsertMenuA);
    try environment.addBuiltinExportComptime(m, "InsertMenuItemA", menu.stub_InsertMenuItemA);
    try environment.addBuiltinExportComptime(m, "DeleteMenu", menu.stub_DeleteMenu);
    try environment.addBuiltinExportComptime(m, "GetMenuItemCount", menu.stub_GetMenuItemCount);
    try environment.addBuiltinExportComptime(m, "GetMenuState", menu.GetMenuState);
    try environment.addBuiltinExportComptime(m, "CheckMenuRadioItem", menu.stub_CheckMenuRadioItem);

    // Additional dialog
    try environment.addBuiltinExportComptime(m, "CheckDlgButton", dialog.stub_CheckDlgButton);
    try environment.addBuiltinExportComptime(m, "CheckRadioButton", dialog.stub_CheckRadioButton);
    try environment.addBuiltinExportComptime(m, "IsDlgButtonChecked", dialog.stub_IsDlgButtonChecked);
    try environment.addBuiltinExportComptime(m, "GetDlgItemInt", dialog.GetDlgItemInt);
    try environment.addBuiltinExportComptime(m, "SetDlgItemInt", dialog.SetDlgItemInt);
    try environment.addBuiltinExportComptime(m, "CreateDialogParamA", dialog.CreateDialogParamA);
    try environment.addBuiltinExportComptime(m, "MessageBoxW", dialog.MessageBoxW);

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
    try environment.addBuiltinExportComptime(m, "ValidateRect", window.stub_ValidateRect);
    try environment.addBuiltinExportComptime(m, "UnregisterClassA", class.stub_UnregisterClassA);
    try environment.addBuiltinExportComptime(m, "IsWindowVisible", window.stub_IsWindowVisible);
    try environment.addBuiltinExportComptime(m, "CallNextHookEx", message.stub_CallNextHookEx);
    try environment.addBuiltinExportComptime(m, "MapVirtualKeyA", input.stub_MapVirtualKeyA);
    try environment.addBuiltinExportComptime(m, "RegisterClassExA", class.RegisterClassExA);
    try environment.addBuiltinExportComptime(m, "BringWindowToTop", window.stub_BringWindowToTop);
    try environment.addBuiltinExportComptime(m, "VkKeyScanA", input.stub_VkKeyScanA);
    try environment.addBuiltinExportComptime(m, "SetCursorPos", input.stub_SetCursorPos);
    try environment.addBuiltinExportComptime(m, "SetWindowsHookExA", message.stub_SetWindowsHookExA);
    try environment.addBuiltinExportComptime(m, "UnhookWindowsHookEx", message.stub_UnhookWindowsHookEx);
    try environment.addBuiltinExportComptime(m, "GetWindowThreadProcessId", window.GetWindowThreadProcessId);
    try environment.addBuiltinExportComptime(m, "GetWindow", window.stub_GetWindow);
    try environment.addBuiltinExportComptime(m, "GetTopWindow", window.stub_GetTopWindow);

    try environment.addBuiltinExportComptime(m, "LoadAcceleratorsA", resource.stub_LoadAcceleratorsA);
    try environment.addBuiltinExportComptime(m, "LoadImageA", resource.stub_LoadImageA);

    // --- Wide (W) variants for Unicode apps ---
    try environment.addBuiltinExportComptime(m, "RegisterClassExW", class.RegisterClassExW);
    try environment.addBuiltinExportComptime(m, "CreateWindowExW", window.CreateWindowExW);
    try environment.addBuiltinExportComptime(m, "DefWindowProcW", window.stub_DefWindowProcA);
    try environment.addBuiltinExportComptime(m, "GetMessageW", message.GetMessageA);
    try environment.addBuiltinExportComptime(m, "PeekMessageW", message.PeekMessageA);
    try environment.addBuiltinExportComptime(m, "DispatchMessageW", message.DispatchMessageA);
    try environment.addBuiltinExportComptime(m, "SendMessageW", message.SendMessageA);
    try environment.addBuiltinExportComptime(m, "PostMessageW", message.PostMessageA);
    try environment.addBuiltinExportComptime(m, "TranslateAcceleratorW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "LoadAcceleratorsW", resource.stub_LoadAcceleratorsW);
    try environment.addBuiltinExportComptime(m, "LoadStringW", resource.LoadStringW);
    try environment.addBuiltinExportComptime(m, "LoadCursorW", resource.stub_LoadCursorA);
    try environment.addBuiltinExportComptime(m, "LoadIconW", resource.LoadIconA);
    try environment.addBuiltinExportComptime(m, "LoadImageW", resource.stub_LoadImageW);
    try environment.addBuiltinExportComptime(m, "GetWindowLongW", window.stub_GetWindowLongA);
    try environment.addBuiltinExportComptime(m, "SetWindowLongW", window.stub_SetWindowLongA);
    try environment.addBuiltinExportComptime(m, "SetWindowTextW", window.stub_SetWindowTextW);
    try environment.addBuiltinExportComptime(m, "GetWindowTextW", window.stub_GetWindowTextA);
    try environment.addBuiltinExportComptime(m, "DialogBoxParamW", dialog.DialogBoxParamA);
    try environment.addBuiltinExportComptime(m, "CreateDialogParamW", dialog.CreateDialogParamA);
    try environment.addBuiltinExportComptime(m, "SetDlgItemTextW", dialog.SetDlgItemTextW);
    try environment.addBuiltinExportComptime(m, "GetDlgItemTextW", dialog.GetDlgItemTextW);
    try environment.addBuiltinExportComptime(m, "SendDlgItemMessageW", dialog.stub_SendDlgItemMessageA);
    try environment.addBuiltinExportComptime(m, "IsDialogMessageW", dialog.IsDialogMessageA);
    try environment.addBuiltinExportComptime(m, "SetScrollPos", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "WinHelpW", dialog.stub_WinHelpA);
    try environment.addBuiltinExportComptime(m, "GetDlgCtrlID", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "ChildWindowFromPoint", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "CharNextW", char.CharNextW);
    try environment.addBuiltinExportComptime(m, "DrawTextExW", stub_ret0_6);
    try environment.addBuiltinExportComptime(m, "wsprintfW", format.stub_wsprintfW);
    try environment.addBuiltinExportComptime(m, "RegisterWindowMessageW", class.RegisterWindowMessageW);

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
    try environment.addBuiltinExportComptime(m, "RegisterClassW", window.RegisterClassA);
    try environment.addBuiltinExportComptime(m, "LoadBitmapW", resource.LoadBitmapW);
    try environment.addBuiltinExportComptime(m, "RegisterClipboardFormatW", class.RegisterClipboardFormatA);
    try environment.addBuiltinExportComptime(m, "RemoveMenu", menu.stub_DeleteMenu);
    try environment.addBuiltinExportComptime(m, "AppendMenuW", menu.AppendMenuW);
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
    try environment.addBuiltinExportComptime(m, "GetWindowTextLengthW", window.stub_GetWindowTextLengthA);
    try environment.addBuiltinExportComptime(m, "IsMenu", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "GetClassNameW", stub_ret0_3);

    // --- Remaining USER32 stubs for 100% win2k coverage ---
    try environment.addBuiltinExportComptime(m, "CharToOemBuffA", stub_CharToOemBuffA);
    try environment.addBuiltinExportComptime(m, "CallWindowProcW", stub_CallWindowProcW);
    try environment.addBuiltinExportComptime(m, "GetMonitorInfoW", stub_GetMonitorInfoW);
    try environment.addBuiltinExportComptime(m, "SendMessageTimeoutA", message.SendMessageTimeoutA);
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
    try environment.addBuiltinExportComptime(m, "LoadBitmapA", resource.LoadBitmapA);
    try environment.addBuiltinExportComptime(m, "DdeQueryConvInfo", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "GetClipboardFormatNameW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "SetProcessDefaultLayout", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "GetProcessDefaultLayout", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "RegisterHotKey", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "UnregisterHotKey", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "OpenInputDesktop", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "WindowFromPoint", window.WindowFromPoint);
    try environment.addBuiltinExportComptime(m, "GetCaretPos", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "SetClassLongW", class.stub_SetClassLongA);
    try environment.addBuiltinExportComptime(m, "EnableScrollBar", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "wvsprintfW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "RegisterDeviceNotificationW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "SetPropW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "RemovePropW", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "MonitorFromPoint", stub_MonitorFromPoint);
    try environment.addBuiltinExportComptime(m, "CreateDialogIndirectParamW", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "UnhookWindowsHook", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "SetWindowsHookW", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "DefDlgProcW", dialog.stub_DefDlgProcA);
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
    try environment.addBuiltinExportComptime(m, "SetWindowsHookExW", message.stub_SetWindowsHookExA);
    try environment.addBuiltinExportComptime(m, "GetNextDlgTabItem", stub_ret0_3);

    // --- Unicode (W) USER32 stubs ---
    try environment.addBuiltinExportComptime(m, "CharPrevW", char.CharPrevA);
    try environment.addBuiltinExportComptime(m, "CharUpperBuffW", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "CreateIconIndirect", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "DialogBoxIndirectParamW", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "DrawAnimatedRects", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "GetMenuStringW", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "InsertMenuW", menu.stub_InsertMenuA);
    try environment.addBuiltinExportComptime(m, "IsCharAlphaNumericA", stub_IsCharAlphaNumericA);
    try environment.addBuiltinExportComptime(m, "IsCharAlphaNumericW", stub_IsCharAlphaNumericW);
    try environment.addBuiltinExportComptime(m, "IsCharLowerA", stub_IsCharLowerA);
    try environment.addBuiltinExportComptime(m, "IsCharLowerW", stub_IsCharLowerW);
    try environment.addBuiltinExportComptime(m, "IsCharUpperA", stub_IsCharUpperA);
    try environment.addBuiltinExportComptime(m, "IsCharUpperW", stub_IsCharUpperW);
    try environment.addBuiltinExportComptime(m, "IsWindowUnicode", window.IsWindowUnicode);
    try environment.addBuiltinExportComptime(m, "MessageBoxExW", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "MessageBoxIndirectW", dialog.stub_MessageBoxIndirectA);
    try environment.addBuiltinExportComptime(m, "ShowOwnedPopups", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "UnregisterClassW", class.stub_UnregisterClassA);

    // --- hgb.exe USER32 stubs ---
    try environment.addBuiltinExportComptime(m, "GetClassInfoA", class.GetClassInfoA);
    try environment.addBuiltinExportComptime(m, "CallWindowProcA", stub_CallWindowProcA);
    try environment.addBuiltinExportComptime(m, "WaitMessage", message.WaitMessage);
    try environment.addBuiltinExportComptime(m, "WaitForInputIdle", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "SetWindowRgn", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "SetPropA", window.SetPropA);
    try environment.addBuiltinExportComptime(m, "RemovePropA", window.GetRemovePropA);
    try environment.addBuiltinExportComptime(m, "GetWindowRgn", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "GetPropA", window.GetRemovePropA);
    try environment.addBuiltinExportComptime(m, "GetKeyNameTextA", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "GetCursor", stub_ret0_0);
    try environment.addBuiltinExportComptime(m, "EnumThreadWindows", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "CreateIcon", stub_ret0_7);

    // --- Additional USER32 stubs ---
    try environment.addBuiltinExportComptime(m, "wvsprintfA", format.wsprintfA);
    try environment.addBuiltinExportComptime(m, "mouse_event", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "keybd_event", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "ToUnicode", stub_ret0_7);
    try environment.addBuiltinExportComptime(m, "ToAscii", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "TabbedTextOutA", stub_ret0_8);
    try environment.addBuiltinExportComptime(m, "SetParent", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "SetMenuItemInfoW", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "SetMenuItemInfoA", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "SetMenuItemBitmaps", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "OpenDesktopA", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "ModifyMenuW", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "ModifyMenuA", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "MapVirtualKeyW", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "LookupIconIdFromDirectoryEx", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "LockWindowUpdate", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "LoadKeyboardLayoutA", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "IsCharAlphaA", stub_IsCharAlphaA);
    try environment.addBuiltinExportComptime(m, "IsCharAlphaW", stub_IsCharAlphaW);
    try environment.addBuiltinExportComptime(m, "InsertMenuItemW", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "GetTabbedTextExtentW", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "GetTabbedTextExtentA", stub_ret0_5);
    try environment.addBuiltinExportComptime(m, "GetMenuItemInfoA", menu.GetMenuItemInfoA);
    try environment.addBuiltinExportComptime(m, "GetMenuItemID", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "FindWindowExA", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "EnumDesktopWindows", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "EnumChildWindows", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "DrawIconEx", stub_ret0_9);
    try environment.addBuiltinExportComptime(m, "DrawFrameControl", stub_ret0_4);
    try environment.addBuiltinExportComptime(m, "CreateIconFromResourceEx", stub_ret0_7);
    try environment.addBuiltinExportComptime(m, "CreateAcceleratorTableA", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "CharPrevExA", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "CharNextExA", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "AttachThreadInput", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "CharLowerBuffA", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "CharUpperBuffA", stub_ret0_2);
    try environment.addBuiltinExportComptime(m, "ActivateKeyboardLayout", stub_ret0_2);
}

// --- Generic stubs (imported from stub_common) ---

const stub_common = @import("shared.zig");
const stub_ret0_0 = stub_common.stub_args(0);
const stub_ret0_1 = stub_common.stub_args(1);
const stub_ret0_2 = stub_common.stub_args(2);
const stub_ret0_3 = stub_common.stub_args(3);
const stub_ret0_4 = stub_common.stub_args(4);
const stub_ret0_5 = stub_common.stub_args(5);
const stub_ret0_6 = stub_common.stub_args(6);
const stub_ret0_7 = stub_common.stub_args(7);
const stub_ret0_8 = stub_common.stub_args(8);
const stub_ret0_9 = stub_common.stub_args(9);
// --- Shared Types ---

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const MSG = extern struct {
    // 32-bit fields: the guest writes/reads this struct directly (Win32 MSG
    // is 28 bytes). usize fields would make it 44 bytes on x86_64, corrupting
    // the guest's stack and its direct msg.hwnd/msg.message reads.
    hwnd: u32,
    message: u32,
    wParam: u32,
    lParam: u32,
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
pub var main_form_created: bool = false;
pub var needs_paint: bool = false;
pub var wndclass_bg_brush: u32 = 0; // hbrBackground from RegisterClass
pub var bg_needs_erase: bool = true; // Set true on first paint / InvalidateRect

/// The window that currently has keyboard focus (SetFocus/GetFocus).
/// Defaults to the main window; IsDialogMessage moves it between the
/// dialog's child controls on Tab and activates buttons on Enter/Escape.
pub var focused_hwnd: usize = 0;

/// Cached title of the main window (set via CreateWindowEx / SetWindowText),
/// so GetWindowText on the main window returns it.
pub var main_window_title: [256]u8 = undefined;
pub var main_window_title_len: usize = 0;

/// Copies a UTF-8 host string into a guest buffer as CP1252 ANSI bytes, the
/// form the `*A` getters return. Returns the byte count written, excluding
/// the terminator.
pub fn copyAnsiToGuest(text: []const u8, lpString: usize, nMaxCount: i32) i32 {
    if (lpString == 0 or nMaxCount <= 0) return 0;
    var buf: [1024]u8 = undefined;
    const converted = ansi.fromUtf8(text, &buf);
    const dst: [*]u8 = @ptrFromInt(trace.addr(lpString));
    const n = @min(converted.len, @as(usize, @intCast(nMaxCount)) - 1);
    @memcpy(dst[0..n], converted[0..n]);
    dst[n] = 0;
    return @intCast(n);
}

/// Byte length a UTF-8 host string occupies once encoded as CP1252, the unit
/// the `*A` length getters report.
pub fn ansiLen(text: []const u8) i32 {
    var buf: [1024]u8 = undefined;
    return @intCast(ansi.fromUtf8(text, &buf).len);
}

/// Store the main window title (copied into the fixed buffer, cut on a
/// UTF-8 code point boundary so the stored text stays decodable).
pub fn setMainWindowTitle(title: []const u8) void {
    const n = text_utils.truncateUtf8(title, main_window_title.len - 1);
    @memcpy(main_window_title[0..n.len], n);
    main_window_title[n.len] = 0;
    main_window_title_len = n.len;
}

// Per-hwnd WndProc lookup table (for dialogs, subclassed windows, etc.)
const MAX_WINDOWS = 128;
pub const WindowInfo = struct {
    hwnd: usize = 0,
    proc: usize = 0,
    original_proc: u32 = 0, // First non-trampoline WndProc (class WndProc before MakeObjectInstance)
    userdata: i32 = 0,
    id: i32 = 0,
    style: i32 = 0,
    exstyle: i32 = 0,
    parent: usize = 0,
};
pub var window_info_table: [MAX_WINDOWS]WindowInfo = [_]WindowInfo{.{}} ** MAX_WINDOWS;
pub var window_info_count: usize = 0;

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

/// Drops a destroyed window's entry so create/destroy cycles don't exhaust
/// the 128-slot table (after which WndProc lookup silently fails).
pub fn removeWindowInfo(hwnd: usize) void {
    for (window_info_table[0..window_info_count], 0..) |*entry, i| {
        if (entry.hwnd == hwnd) {
            window_info_table[i] = window_info_table[window_info_count - 1];
            window_info_table[window_info_count - 1] = .{};
            window_info_count -= 1;
            return;
        }
    }
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
pub var rich_edit_hwnd: usize = 0;
/// Guest-side edit/RichEdit selection (EM_SETSEL/EM_GETSEL), kept in sync
/// with the frontend via renderer.setEditSelection.
pub var edit_sel_start: i32 = 0;
pub var edit_sel_end: i32 = 0;

// --- Per-hwnd control text store ---
// SetWindowTextA/WM_SETTEXT on CreateWindowEx child controls (Button, Static,
// …) write here; GetWindowTextA / WM_GETTEXT read it back, so apps can query
// control text uniformly (control-ization of the window text APIs).
pub const HwndText = struct { hwnd: usize, text: [512]u8, len: u16 };
pub var hwnd_texts: [64]HwndText = undefined;
pub var hwnd_text_count: usize = 0;

pub fn setHwndText(hwnd: usize, text: []const u8) void {
    if (hwnd == 0) return;
    for (hwnd_texts[0..hwnd_text_count]) |*e| {
        if (e.hwnd == hwnd) {
            const n = text_utils.truncateUtf8(text, e.text.len);
            @memcpy(e.text[0..n.len], n);
            e.len = @intCast(n.len);
            return;
        }
    }
    if (hwnd_text_count < hwnd_texts.len) {
        const e = &hwnd_texts[hwnd_text_count];
        hwnd_text_count += 1;
        e.hwnd = hwnd;
        const n = text_utils.truncateUtf8(text, e.text.len);
        @memcpy(e.text[0..n.len], n);
        e.len = @intCast(n.len);
    }
}

pub fn getHwndText(hwnd: usize) []const u8 {
    var i: usize = hwnd_text_count;
    while (i > 0) {
        i -= 1;
        const e = &hwnd_texts[i];
        if (e.hwnd == hwnd) return e.text[0..e.len];
    }
    return "";
}

/// Drops a destroyed window's text entry so the 64-slot store doesn't fill
/// with entries for windows that no longer exist.
pub fn removeHwndText(hwnd: usize) void {
    for (hwnd_texts[0..hwnd_text_count], 0..) |*e, i| {
        if (e.hwnd == hwnd) {
            hwnd_texts[i] = hwnd_texts[hwnd_text_count - 1];
            hwnd_texts[hwnd_text_count - 1] = .{ .hwnd = 0, .text = [_]u8{0} ** 512, .len = 0 };
            hwnd_text_count -= 1;
            return;
        }
    }
}

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

/// The MSG.time stamp for a message entering the queue: a GetTickCount
/// reading, on the same monotonic clock and with the same 32-bit wrap
/// (GetMessageTime and GetTickCount read the same value), so a guest that
/// computes an age as `GetTickCount() - msg.time` gets a duration and not an
/// underflow. A zero here says "posted at boot": the age comes out as the
/// whole session uptime, and a guest that times a loop with
/// `msg.time - start` wraps the other way and gives up instantly.
pub fn msgTime() u32 {
    return @truncate(@as(u64, @bitCast(@import("../runtime.zig").monoMilliTimestamp())));
}

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
            .hwnd = @intCast(global_hwnd),
            .message = msg_id,
            .wParam = @intCast(wParam),
            .lParam = @truncate(@as(u64, @bitCast(@as(i64, @intCast(lParam))))),
            .time = msgTime(),
            .pt_x = 0,
            .pt_y = 0,
        };
        pending_messages_head = next_head;
    }
}

// --- Renderer Input Callbacks ---

fn handleCommand(id: u32) void {
    // Auto checkboxes/radios toggle their state on click before the
    // WM_COMMAND is delivered (real button-class behavior).
    const msg_mod = @import("user32/message.zig");
    msg_mod.toggleAutoButton(id);
    postCommand(id);
}

fn handleListboxSelect(id: u32, index: i32) void {
    const msg_mod = @import("user32/message.zig");
    msg_mod.setListboxCursor(id, index);
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
    const dinput = @import("dinput/dinput.zig");
    const vk: u8 = @intCast(vk_code & 0xFF);

    // Store the key and read the Alt bit as one step: a GUI thread handling
    // Alt concurrently would otherwise let this event classify itself from a
    // keyboard map the other thread was in the middle of rewriting.
    renderer.input_mutex.lock();
    renderer.keyboard_state[vk] = if (is_down) 0x80 else 0;
    // Alt key (VK_MENU=0x12) held → use WM_SYSKEYDOWN/WM_SYSKEYUP (0x0104/0x0105)
    // Alt key itself also gets WM_SYSKEYDOWN
    const alt_held = (renderer.keyboard_state[0x12] & 0x80) != 0;
    renderer.input_mutex.unlock();
    const is_alt_key = (vk == 0x12);
    const is_sys = alt_held or is_alt_key;

    // Push into DirectInput keyboard event buffer (VK → DIK scancode)
    const scancode = dinput.vkToDIK(vk_code);
    if (scancode != 0) {
        dinput.pushKeyEvent(scancode, is_down);
    }

    const msg_id: u32 = if (is_sys)
        (if (is_down) w32.WM_SYSKEYDOWN else w32.WM_SYSKEYUP)
    else
        (if (is_down) w32.WM_KEYDOWN else w32.WM_KEYUP);

    // lParam bit 29 = context code (1 if Alt held during SYSKEYDOWN)
    var lp: u32 = 0;
    if (!is_down) lp |= (1 << 31); // transition state
    if (is_sys and is_down) lp |= (1 << 29); // Alt context code

    // Real Win32 routes keyboard messages to the FOCUSED window. If a child
    // control has focus (SetFocus / IsDialogMessage Tab), deliver there so
    // WM_KEYDOWN → TranslateMessage → WM_CHAR reaches the edit control etc.
    const target_hwnd = if (focused_hwnd != 0 and focused_hwnd != global_hwnd)
        focused_hwnd
    else
        global_hwnd;
    const msg_mod = @import("user32/message.zig");
    msg_mod.postMessageTo(target_hwnd, msg_id, vk_code, @as(isize, @intCast(@as(i32, @bitCast(lp)))));
}

fn handleWheelEvent(delta: i32, x: i32, y: i32) void {
    // WM_MOUSEWHEEL: wParam = (delta << 16) | key flags, lParam = screen coords
    const w: u32 = @bitCast(@as(i32, delta) << 16);
    const lp: i32 = ((y & 0xFFFF) << 16) | (x & 0xFFFF);
    postGenericMessage(w32.WM_MOUSEWHEEL, w, @intCast(lp));
}

fn handleMouseEvent(msg_id: u32, x: i32, y: i32) void {
    // Track last known mouse position for GetCursorPos
    const rend = @import("../gui/renderer.zig");
    const dinput = @import("dinput/dinput.zig");

    // Accumulate position, deltas and button state under the input lock so
    // two GUI threads reporting the same pointer cannot lose a delta. The
    // DirectInput events are recorded here and replayed after the lock is
    // dropped, so dinput's own buffer is never touched with it held.
    rend.input_mutex.lock();
    const dx = x - rend.last_mouse_x;
    const dy = y - rend.last_mouse_y;
    rend.mouse_dx += dx;
    rend.mouse_dy += dy;
    rend.last_mouse_x = x;
    rend.last_mouse_y = y;

    // Button state for DirectInput mouse (0x80 = pressed), paired with the
    // DIMOFS offset to report.
    const button: ?struct { offset: u8, pressed: u8 } = switch (msg_id) {
        w32.WM_LBUTTONDOWN => blk: {
            rend.mouse_buttons[0] = 0x80;
            break :blk .{ .offset = 12, .pressed = 0x80 };
        },
        w32.WM_LBUTTONUP => blk: {
            rend.mouse_buttons[0] = 0;
            break :blk .{ .offset = 12, .pressed = 0x00 };
        },
        w32.WM_RBUTTONDOWN => blk: {
            rend.mouse_buttons[1] = 0x80;
            break :blk .{ .offset = 13, .pressed = 0x80 };
        },
        w32.WM_RBUTTONUP => blk: {
            rend.mouse_buttons[1] = 0;
            break :blk .{ .offset = 13, .pressed = 0x00 };
        },
        w32.WM_MBUTTONDOWN => blk: {
            rend.mouse_buttons[2] = 0x80;
            break :blk .{ .offset = 14, .pressed = 0x80 };
        },
        w32.WM_MBUTTONUP => blk: {
            rend.mouse_buttons[2] = 0;
            break :blk .{ .offset = 14, .pressed = 0x00 };
        },
        else => null,
    };
    rend.input_mutex.unlock();

    if (dx != 0) dinput.pushMouseEvent(0, @bitCast(dx)); // DIMOFS_X = 0
    if (dy != 0) dinput.pushMouseEvent(4, @bitCast(dy)); // DIMOFS_Y = 4
    if (button) |b| dinput.pushMouseEvent(b.offset, b.pressed);

    // lParam = MAKELPARAM(x, y) = (y << 16) | (x & 0xFFFF)
    const lx: u32 = @as(u32, @bitCast(x)) & 0xFFFF;
    const ly: u32 = @as(u32, @bitCast(y)) & 0xFFFF;
    const lParam: isize = @intCast(@as(i32, @bitCast((ly << 16) | lx)));

    // wParam = key flags (MK_LBUTTON / MK_RBUTTON)
    var wParam: usize = 0;
    if (msg_id == w32.WM_LBUTTONDOWN or msg_id == w32.WM_MOUSEMOVE) {
        // Set MK_LBUTTON if this is a down event or if left mouse is held during move
        if (msg_id == w32.WM_LBUTTONDOWN) wParam |= w32.MK_LBUTTON;
    }
    if (msg_id == w32.WM_RBUTTONDOWN) wParam |= w32.MK_RBUTTON;

    postGenericMessage(msg_id, wParam, lParam);
}

// --- SEH / WndProc Safe Call ---

const SEH_Frame = extern struct {
    next: *SEH_Frame,
    handler: usize,
    catch_eip: u32,
    catch_esp: u32,
    catch_ebp: u32,
};

export fn user32_seh_handler(record: *anyopaque, frame_ptr: *SEH_Frame, context: *@import("teb_layout.zig").CONTEXT, dispatch: usize) callconv(.c) u32 {
    _ = record;
    _ = dispatch;
    if (trace.enable_tracing) trace.print("USER32: Swallowing exception in WindowProc, jumping to catch handler.\n", .{});
    context.Eip = frame_ptr.catch_eip;
    context.Esp = frame_ptr.catch_esp;
    context.Ebp = frame_ptr.catch_ebp;
    return 0; // ExceptionContinueExecution
}

const native_arch = @import("builtin").target.cpu.arch;
const platform_mod = @import("../platform.zig");
const w32cc = @import("calling_convention.zig");

comptime {
    if (native_arch == .x86 and @import("builtin").target.os.tag != .windows) {
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
            \\  // Uninstall SEH — pop the saved next pointer into ECX so the
            \\  // WndProc's return value in EAX is preserved.
            \\  popl %ecx
            \\  movl %ecx, %fs:0
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

pub const callWndProcSafe = if (native_arch == .x86 and @import("builtin").target.os.tag != .windows) callWndProcSafe_extern else callWndProcSafe_zig;

extern fn callWndProcSafe_extern(wndproc: usize, hwnd: usize, msg: u32, wParam: usize, lParam: isize, err_out: *u32) callconv(.c) isize;

/// x86_64: the guest WndProc is 32-bit code running in compatibility mode
/// (CS=0x23). It must be entered through the compat transition — a direct
/// call from 64-bit mode executes 32-bit bytes as 64-bit code and faults.
/// WASM: the guest WndProc is x86 code at a guest VA — a guest function
/// pointer is not a valid WASM indirect-call index, so it must run on a
/// nested interpreter CPU (mirrors callComparator's WASM path).
fn callWndProcSafe_zig(wndproc: usize, hwnd: usize, msg: u32, wParam: usize, lParam: isize, err_out: *u32) callconv(.c) isize {
    err_out.* = 0;
    if (wndproc == 0) return 0;
    if (native_arch == .x86_64) {
        const compat = @import("../x86/compat_thunks.zig");
        const result = compat.callCompat32_4(
            @truncate(wndproc),
            @truncate(hwnd),
            msg,
            @truncate(wParam),
            @truncate(@as(u64, @bitCast(lParam))),
        );
        return @as(isize, @bitCast(@as(u64, result)));
    }
    if (comptime @import("../platform.zig").is_wasm) {
        const x86_cpu = @import("../x86/cpu.zig");
        const x86_execute = @import("../x86/execute.zig");
        const teb_mod = @import("teb_layout.zig");
        const stack_size: u32 = 64 * 1024;
        var cpu = x86_cpu.Cpu{};
        if (x86_memory.guest_memory) |gm| cpu.memory = gm.*;
        if (teb_mod.teb_base_addr != 0) cpu.fs_base = @intCast(teb_mod.teb_base_addr);
        const stack_va = cpu.memory.guestAlloc(stack_size);
        if (stack_va == 0) return 0;
        // HLT byte as the return address so the interpreter halts cleanly.
        const halt_va = cpu.memory.guestAlloc(1);
        if (halt_va == 0) return 0;
        cpu.memory.write8(halt_va, 0xF4); // HLT
        cpu.esp = stack_va + stack_size - 16;
        // stdcall: args pushed right-to-left, then the (halting) return addr.
        cpu.push32(@truncate(@as(u64, @bitCast(@as(i64, lParam)))));
        cpu.push32(@truncate(wParam));
        cpu.push32(msg);
        cpu.push32(@truncate(hwnd));
        cpu.push32(halt_va);
        cpu.eip = @truncate(wndproc);
        x86_execute.run(&cpu);
        return @as(i32, @bitCast(cpu.eax));
    }
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
    _ = hwnd;
    _ = dwFlags;
    if (trace.enable_tracing) trace.print("USER32: MonitorFromWindow -> 0x{x}\n", .{FAKE_HMONITOR});
    return FAKE_HMONITOR;
}

fn stub_MonitorFromPoint(ptX: i32, ptY: i32, dwFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = ptX;
    _ = ptY;
    _ = dwFlags;
    if (trace.enable_tracing) trace.print("USER32: MonitorFromPoint -> 0x{x}\n", .{FAKE_HMONITOR});
    return FAKE_HMONITOR;
}

fn stub_MonitorFromRect(lprc: usize, dwFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = lprc;
    _ = dwFlags;
    if (trace.enable_tracing) trace.print("USER32: MonitorFromRect -> 0x{x}\n", .{FAKE_HMONITOR});
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
        return message_mod.handleCommonControlMsg(hWnd, msg, wParam, lParam);
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
    _ = hWnd;
    _ = hWndInsertAfter;
    _ = x;
    _ = y;
    _ = cx;
    _ = cy;
    _ = uFlags;
    return hWinPosInfo; // Return same handle (success)
}

fn stub_EndDeferWindowPos(hWinPosInfo: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWinPosInfo;
    return 1; // TRUE
}

// =============================================================================
// Tests
// =============================================================================

test "calcFrameAdjustments returns correct bounds" {
    // 1. Thick frame + Caption
    const adj1 = calcFrameAdjustments(WS_THICKFRAME | WS_CAPTION, false, 0);
    try std.testing.expectEqual(@as(i32, SM_CXFRAME), adj1.left);
    try std.testing.expectEqual(@as(i32, SM_CXFRAME), adj1.right);
    try std.testing.expectEqual(@as(i32, SM_CYFRAME + SM_CYCAPTION), adj1.top);
    try std.testing.expectEqual(@as(i32, SM_CYFRAME), adj1.bottom);

    // 2. Dialog frame + Menu
    const adj2 = calcFrameAdjustments(WS_DLGFRAME, true, 0);
    try std.testing.expectEqual(@as(i32, SM_CXDLGFRAME), adj2.left);
    try std.testing.expectEqual(@as(i32, SM_CXDLGFRAME), adj2.right);
    try std.testing.expectEqual(@as(i32, SM_CYDLGFRAME + SM_CYMENU), adj2.top);
    try std.testing.expectEqual(@as(i32, SM_CYDLGFRAME), adj2.bottom);

    // 3. Border + Client Edge
    const adj3 = calcFrameAdjustments(WS_BORDER, false, WS_EX_CLIENTEDGE);
    try std.testing.expectEqual(@as(i32, SM_CXBORDER + SM_CXEDGE), adj3.left);
    try std.testing.expectEqual(@as(i32, SM_CXBORDER + SM_CXEDGE), adj3.right);
    try std.testing.expectEqual(@as(i32, SM_CYBORDER + SM_CYEDGE), adj3.top);
    try std.testing.expectEqual(@as(i32, SM_CYBORDER + SM_CYEDGE), adj3.bottom);
}

// IsCharAlphaA/W, IsCharAlphaNumericA/W, IsCharLowerA/W, IsCharUpperA/W.
// The A variants take a CHAR in the ANSI code page, the W variants a WCHAR,
// so each test classifies the argument at the width and encoding the guest
// passed it with. Truncating a WCHAR to a byte to reuse the ASCII test would
// read the wrong character: U+0179 (Z acute, upper case) has 0x79 ('y') as
// its low byte.
fn isCharTestAnsi(comptime pred: fn (u16) bool, c: usize) i32 {
    return if (pred(@intCast(ansi.byteToCodepoint(@truncate(c))))) 1 else 0;
}

fn isCharTestWide(comptime pred: fn (u16) bool, c: usize) i32 {
    return if (pred(@truncate(c))) 1 else 0;
}

/// A letter or a decimal digit. The digits are the ASCII range; the non-ASCII
/// decimal digit blocks (Arabic-Indic, Devanagari) are not classified.
fn isAlphaNumeric(c: u16) bool {
    return unicase.isAlphabetic(c) or (c >= '0' and c <= '9');
}

fn stub_IsCharAlphaNumericA(c: usize) callconv(w32cc.WINAPI) i32 {
    return isCharTestAnsi(isAlphaNumeric, c);
}
fn stub_IsCharAlphaNumericW(c: usize) callconv(w32cc.WINAPI) i32 {
    return isCharTestWide(isAlphaNumeric, c);
}
fn stub_IsCharAlphaA(c: usize) callconv(w32cc.WINAPI) i32 {
    return isCharTestAnsi(unicase.isAlphabetic, c);
}
fn stub_IsCharAlphaW(c: usize) callconv(w32cc.WINAPI) i32 {
    return isCharTestWide(unicase.isAlphabetic, c);
}
fn stub_IsCharLowerA(c: usize) callconv(w32cc.WINAPI) i32 {
    return isCharTestAnsi(unicase.isLower, c);
}
fn stub_IsCharLowerW(c: usize) callconv(w32cc.WINAPI) i32 {
    return isCharTestWide(unicase.isLower, c);
}
fn stub_IsCharUpperA(c: usize) callconv(w32cc.WINAPI) i32 {
    return isCharTestAnsi(unicase.isUpper, c);
}
fn stub_IsCharUpperW(c: usize) callconv(w32cc.WINAPI) i32 {
    return isCharTestWide(unicase.isUpper, c);
}

test "IsCharAlpha/Lower/Upper classify the whole WCHAR, not its low byte" {
    // U+0179 is an upper-case Z with an acute; its low byte is 'y'.
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharUpperW(0x0179));
    try std.testing.expectEqual(@as(i32, 0), stub_IsCharLowerW(0x0179));
    // U+00DF (sharp s) and U+0178 (Y diaeresis) are the reverse trap: the
    // mappings report them as the other case.
    try std.testing.expectEqual(@as(i32, 0), stub_IsCharUpperW(0x00DF));
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharLowerW(0x00DF));
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharUpperW(0x0178));
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharAlphaW(0x00DF));
    // Cyrillic and Greek, above the Latin-1 range.
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharUpperW(0x0416));
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharLowerW(0x0436));
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharLowerW(0x03B1));
    // ASCII keeps its answers, and a non-letter stays a non-letter.
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharUpperW('A'));
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharLowerW('a'));
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharAlphaNumericW('7'));
    try std.testing.expectEqual(@as(i32, 0), stub_IsCharAlphaW('7'));
    try std.testing.expectEqual(@as(i32, 0), stub_IsCharAlphaW(' '));
    try std.testing.expectEqual(@as(i32, 0), stub_IsCharUpperW(0x4F60));
}

test "IsCharAlphaA classifies the ANSI code page" {
    // CP1252 0xE9 is e acute: a lower-case letter even though the byte is
    // outside ASCII, and 0x80 is the euro sign, which is not a letter.
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharLowerA(0xE9));
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharUpperA(0xC9));
    try std.testing.expectEqual(@as(i32, 0), stub_IsCharUpperA(0xE9));
    try std.testing.expectEqual(@as(i32, 0), stub_IsCharAlphaA(0x80));
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharAlphaA(0xDF));
    try std.testing.expectEqual(@as(i32, 1), stub_IsCharUpperA('Z'));
    try std.testing.expectEqual(@as(i32, 0), stub_IsCharLowerA('Z'));
}

// CallWindowProcA: call a window procedure directly (used by subclassing)
fn stub_CallWindowProcA(lpPrevWndFunc: usize, hWnd: usize, Msg: u32, wParam: usize, lParam: isize) callconv(w32cc.WINAPI) isize {
    if (trace.enable_tracing) trace.print("USER32: CallWindowProcA(proc=0x{X}, hwnd=0x{X}, Msg=0x{X})\n", .{ lpPrevWndFunc, hWnd, Msg });
    if (lpPrevWndFunc == 0) return 0;
    var err_flag: u32 = 0;
    return callWndProcSafe(lpPrevWndFunc, hWnd, Msg, wParam, lParam, &err_flag);
}

// Window info / hwnd text registry lifecycle: entries must be removed on
// destroy so create/destroy cycles stay bounded.
test "removeWindowInfo drops destroyed windows" {
    const saved_table = window_info_table;
    const saved_count = window_info_count;
    defer {
        window_info_table = saved_table;
        window_info_count = saved_count;
    }

    window_info_count = 0;
    _ = getWindowInfo(0x1111).?;
    _ = getWindowInfo(0x2222).?;
    _ = getWindowInfo(0x3333).?;
    try std.testing.expectEqual(@as(usize, 3), window_info_count);

    setWndProc(0x1111, 0xBEEF);
    removeWindowInfo(0x2222);
    try std.testing.expectEqual(@as(usize, 2), window_info_count);
    for (window_info_table[0..window_info_count]) |*e| {
        try std.testing.expect(e.hwnd != 0x2222);
    }

    // Remaining lookups still resolve.
    try std.testing.expectEqual(@as(usize, 0xBEEF), getWndProc(0x1111).?);

    removeWindowInfo(0x1111);
    removeWindowInfo(0x3333);
    try std.testing.expectEqual(@as(usize, 0), window_info_count);
}

test "removeHwndText drops destroyed windows" {
    const saved_texts = hwnd_texts;
    const saved_count = hwnd_text_count;
    defer {
        hwnd_texts = saved_texts;
        hwnd_text_count = saved_count;
    }

    hwnd_text_count = 0;
    setHwndText(0x4444, "hello");
    setHwndText(0x5555, "world");
    try std.testing.expectEqual(@as(usize, 2), hwnd_text_count);

    removeHwndText(0x4444);
    try std.testing.expectEqual(@as(usize, 1), hwnd_text_count);
    try std.testing.expectEqualStrings("world", getHwndText(0x5555));

    removeHwndText(0x4444); // unknown hwnd is a no-op
    try std.testing.expectEqual(@as(usize, 1), hwnd_text_count);
}
