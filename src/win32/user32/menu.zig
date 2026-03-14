const trace = @import("../../trace.zig");
const user32 = @import("../user32.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn stub_GetMenu(hWnd: usize) callconv(w32cc.WINAPI) usize {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: GetMenu\n", .{});
    return 0x00000999; // Dummy menu handle
}

pub fn stub_DrawMenuBar(hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: DrawMenuBar\n", .{});
    return 1;
}

pub fn SetMenu(hWnd: usize, hMenu: usize) callconv(w32cc.WINAPI) i32 {
    _ = hWnd;
    if (trace.enable_tracing) trace.print("USER32: SetMenu\n", .{});
    if (hMenu != 0) user32.window_has_menu = true;
    return 1;
}

pub fn stub_DestroyMenu(hMenu: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMenu;
    return 1;
}

pub fn stub_GetSubMenu(hMenu: usize, nPos: i32) callconv(w32cc.WINAPI) usize {
    _ = hMenu;
    _ = nPos;
    return 0x00000AAA;
}

pub fn stub_TrackPopupMenu(hMenu: usize, uFlags: u32, x: i32, y: i32, nReserved: i32, hWnd: usize, prcRect: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMenu;
    _ = uFlags;
    _ = x;
    _ = y;
    _ = nReserved;
    _ = hWnd;
    _ = prcRect;
    return 0;
}

pub fn stub_AppendMenuA(hMenu: usize, uFlags: u32, uIDNewItem: usize, lpNewItem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMenu;
    _ = uFlags;
    _ = uIDNewItem;
    _ = lpNewItem;
    return 1;
}

// Menu item state tracking: key = (hMenu << 16) | uId, value = MF_* flags
const MenuItemState = struct {
    key: u64 = 0,
    flags: u32 = 0,
    used: bool = false,
};
var menu_item_states: [64]MenuItemState = .{MenuItemState{}} ** 64;

fn menuItemKey(hMenu: usize, uId: u32) u64 {
    return (@as(u64, hMenu) << 16) | @as(u64, uId);
}

fn findOrAllocMenuSlot(key: u64) *MenuItemState {
    // Find existing
    for (&menu_item_states) |*s| {
        if (s.used and s.key == key) return s;
    }
    // Allocate new
    for (&menu_item_states) |*s| {
        if (!s.used) {
            s.key = key;
            s.flags = 0;
            s.used = true;
            return s;
        }
    }
    // Full — reuse last slot
    return &menu_item_states[63];
}

pub fn CheckMenuItem(hMenu: usize, uIDCheckItem: u32, uCheck: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("USER32: CheckMenuItem(menu={X}, item={d}, check={x})\n", .{ hMenu, uIDCheckItem, uCheck });
    const MF_CHECKED: u32 = 0x0008;
    const key = menuItemKey(hMenu, uIDCheckItem);
    const slot = findOrAllocMenuSlot(key);
    const prev = slot.flags & MF_CHECKED;
    if ((uCheck & MF_CHECKED) != 0) {
        slot.flags |= MF_CHECKED;
    } else {
        slot.flags &= ~MF_CHECKED;
    }
    return prev;
}

var next_menu_handle: usize = 0x00001000;

pub fn CreateMenu() callconv(w32cc.WINAPI) usize {
    const handle = next_menu_handle;
    next_menu_handle += 1;
    if (trace.enable_tracing) trace.print("USER32: CreateMenu() -> 0x{X}\n", .{handle});
    return handle;
}

pub fn CreatePopupMenu() callconv(w32cc.WINAPI) usize {
    const handle = next_menu_handle;
    next_menu_handle += 1;
    if (trace.enable_tracing) trace.print("USER32: CreatePopupMenu() -> 0x{X}\n", .{handle});
    return handle;
}

pub fn EnableMenuItem(hMenu: usize, uIDEnableItem: u32, uEnable: u32) callconv(w32cc.WINAPI) i32 {
    const MF_GRAYED: u32 = 0x0001;
    const MF_DISABLED: u32 = 0x0002;
    const key = menuItemKey(hMenu, uIDEnableItem);
    const slot = findOrAllocMenuSlot(key);
    const prev: i32 = @bitCast(slot.flags & (MF_GRAYED | MF_DISABLED));
    // Clear old enable state, set new
    slot.flags &= ~(MF_GRAYED | MF_DISABLED);
    slot.flags |= uEnable & (MF_GRAYED | MF_DISABLED);
    return prev;
}

pub fn stub_InsertMenuA(hMenu: usize, uPosition: u32, uFlags: u32, uIDNewItem: usize, lpNewItem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMenu;
    _ = uPosition;
    _ = uFlags;
    _ = uIDNewItem;
    _ = lpNewItem;
    return 1;
}

pub fn stub_InsertMenuItemA(hMenu: usize, item: u32, fByPosition: i32, lpmi: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMenu;
    _ = item;
    _ = fByPosition;
    _ = lpmi;
    return 1;
}

pub fn stub_DeleteMenu(hMenu: usize, uPosition: u32, uFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = hMenu;
    _ = uPosition;
    _ = uFlags;
    return 1;
}

pub fn stub_GetMenuItemCount(hMenu: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMenu;
    return 0;
}

pub fn GetMenuState(hMenu: usize, uId: u32, uFlags: u32) callconv(w32cc.WINAPI) u32 {
    _ = uFlags;
    const key = menuItemKey(hMenu, uId);
    for (&menu_item_states) |*s| {
        if (s.used and s.key == key) return s.flags;
    }
    return 0;
}

pub fn stub_CheckMenuRadioItem(hMenu: usize, first: u32, last: u32, check: u32, flags: u32) callconv(w32cc.WINAPI) i32 {
    _ = hMenu;
    _ = first;
    _ = last;
    _ = check;
    _ = flags;
    return 1;
}
