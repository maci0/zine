const trace = @import("../../trace.zig");
const user32 = @import("../user32.zig");

pub fn stub_GetMenu(hWnd: usize) callconv(.winapi) usize {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: GetMenu\n", .{});
    return 0x00000999; // Dummy menu handle
}

pub fn stub_DrawMenuBar(hWnd: usize) callconv(.winapi) i32 {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: DrawMenuBar\n", .{});
    return 1;
}

pub fn stub_SetMenu(hWnd: usize, hMenu: usize) callconv(.winapi) i32 {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: SetMenu\n", .{});
    if (hMenu != 0) user32.window_has_menu = true;
    return 1;
}

pub fn stub_DestroyMenu(hMenu: usize) callconv(.winapi) i32 {
    _ = hMenu;
    return 1;
}

pub fn stub_GetSubMenu(hMenu: usize, nPos: i32) callconv(.winapi) usize {
    _ = hMenu;
    _ = nPos;
    return 0x00000AAA;
}

pub fn stub_TrackPopupMenu(hMenu: usize, uFlags: u32, x: i32, y: i32, nReserved: i32, hWnd: usize, prcRect: usize) callconv(.winapi) i32 {
    _ = hMenu;
    _ = uFlags;
    _ = x;
    _ = y;
    _ = nReserved;
    _ = hWnd;
    _ = prcRect;
    return 0;
}

pub fn stub_AppendMenuA(hMenu: usize, uFlags: u32, uIDNewItem: usize, lpNewItem: usize) callconv(.winapi) i32 {
    _ = hMenu;
    _ = uFlags;
    _ = uIDNewItem;
    _ = lpNewItem;
    return 1;
}

pub fn stub_CheckMenuItem(hMenu: usize, uIDCheckItem: u32, uCheck: u32) callconv(.winapi) u32 {
    _ = uCheck;
    if (trace.enable_tracing) trace.print("USER32: CheckMenuItem(menu={X}, item={d})\n", .{hMenu, uIDCheckItem});
    return 0;
}

var next_menu_handle: usize = 0x00001000;

pub fn stub_CreateMenu() callconv(.winapi) usize {
    const handle = next_menu_handle;
    next_menu_handle += 1;
    if (trace.enable_tracing) trace.print("USER32: CreateMenu() -> 0x{X}\n", .{handle});
    return handle;
}

pub fn stub_CreatePopupMenu() callconv(.winapi) usize {
    const handle = next_menu_handle;
    next_menu_handle += 1;
    if (trace.enable_tracing) trace.print("USER32: CreatePopupMenu() -> 0x{X}\n", .{handle});
    return handle;
}

pub fn stub_EnableMenuItem(hMenu: usize, uIDEnableItem: u32, uEnable: u32) callconv(.winapi) i32 {
    _ = hMenu;
    _ = uIDEnableItem;
    _ = uEnable;
    return 0;
}

pub fn stub_InsertMenuA(hMenu: usize, uPosition: u32, uFlags: u32, uIDNewItem: usize, lpNewItem: usize) callconv(.winapi) i32 {
    _ = hMenu;
    _ = uPosition;
    _ = uFlags;
    _ = uIDNewItem;
    _ = lpNewItem;
    return 1;
}

pub fn stub_InsertMenuItemA(hMenu: usize, item: u32, fByPosition: i32, lpmi: usize) callconv(.winapi) i32 {
    _ = hMenu;
    _ = item;
    _ = fByPosition;
    _ = lpmi;
    return 1;
}

pub fn stub_DeleteMenu(hMenu: usize, uPosition: u32, uFlags: u32) callconv(.winapi) i32 {
    _ = hMenu;
    _ = uPosition;
    _ = uFlags;
    return 1;
}

pub fn stub_GetMenuItemCount(hMenu: usize) callconv(.winapi) i32 {
    _ = hMenu;
    return 0;
}

pub fn stub_GetMenuState(hMenu: usize, uId: u32, uFlags: u32) callconv(.winapi) u32 {
    _ = hMenu;
    _ = uId;
    _ = uFlags;
    return 0;
}

pub fn stub_CheckMenuRadioItem(hMenu: usize, first: u32, last: u32, check: u32, flags: u32) callconv(.winapi) i32 {
    _ = hMenu;
    _ = first;
    _ = last;
    _ = check;
    _ = flags;
    return 1;
}
