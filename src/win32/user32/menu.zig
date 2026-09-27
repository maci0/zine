const std = @import("std");
const trace = @import("../../trace.zig");
const ansi = @import("../ansi.zig");
const text_utils = @import("../../text_utils.zig");
const user32 = @import("../user32.zig");
const w32cc = @import("../calling_convention.zig");

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
    return TrackPopupMenu(hMenu, uFlags, x, y, nReserved, hWnd, prcRect);
}

// --- Popup menu content tracking (CreatePopupMenu + AppendMenu* -> TrackPopupMenu) ---
const PopupItem = struct {
    id: i32,
    text: [256]u8,
    len: u16,
    flags: u32, // MF_* flags (CHECKED/GRAYED/DISABLED/SEPARATOR)
};
const PopupMenu = struct {
    hMenu: usize,
    items: [48]PopupItem,
    count: usize,
};
var popup_menus: [16]PopupMenu = undefined;
var popup_menu_count: usize = 0;

fn findPopupMenu(hMenu: usize) ?*PopupMenu {
    var i: usize = popup_menu_count;
    while (i > 0) {
        i -= 1;
        const pm = &popup_menus[i];
        if (pm.hMenu == hMenu) return pm;
    }
    return null;
}

fn getOrCreatePopupMenu(hMenu: usize) *PopupMenu {
    if (findPopupMenu(hMenu)) |pm| return pm;
    if (popup_menu_count < popup_menus.len) {
        const pm = &popup_menus[popup_menu_count];
        popup_menu_count += 1;
        pm.* = .{ .hMenu = hMenu, .items = undefined, .count = 0 };
        return pm;
    }
    return &popup_menus[popup_menu_count - 1];
}

fn addPopupItem(hMenu: usize, id: i32, text: []const u8, flags: u32) void {
    const pm = getOrCreatePopupMenu(hMenu);
    if (pm.count >= pm.items.len) return;
    const it = &pm.items[pm.count];
    pm.count += 1;
    it.* = .{ .id = id, .text = undefined, .len = 0, .flags = flags };
    const n = @min(text.len, it.text.len);
    @memcpy(it.text[0..n], text[0..n]);
    it.len = @intCast(n);
}

pub fn stub_AppendMenuA(hMenu: usize, uFlags: u32, uIDNewItem: usize, lpNewItem: usize) callconv(w32cc.WINAPI) i32 {
    const MF_SEPARATOR: u32 = 0x0800;
    const MF_CHECKED: u32 = 0x0008;
    const MF_GRAYED: u32 = 0x0001;
    const MF_DISABLED: u32 = 0x0002;
    if (trace.enable_tracing) trace.print("USER32: AppendMenuA(menu={X}, id={d}, flags={x})\n", .{ hMenu, uIDNewItem, uFlags });
    if ((uFlags & MF_SEPARATOR) != 0) {
        addPopupItem(hMenu, -1, "", uFlags);
    } else if (lpNewItem != 0) {
        var text_buf: [256]u8 = undefined;
        addPopupItem(hMenu, @intCast(uIDNewItem & 0xFFFF), ansi.toUtf8(trace.c_span(lpNewItem), &text_buf), uFlags);
        // Mirror CHECKED/GRAYED/DISABLED into the item-state table so
        // GetMenuState reports them (like real Win32 menu construction).
        const key = menuItemKey(hMenu, @as(u32, @intCast(uIDNewItem & 0xFFFF)));
        const slot = findOrAllocMenuSlot(key);
        slot.flags = (slot.flags & ~(MF_CHECKED | MF_GRAYED | MF_DISABLED)) | (uFlags & (MF_CHECKED | MF_GRAYED | MF_DISABLED));
    }
    return 1;
}

pub fn AppendMenuW(hMenu: usize, uFlags: u32, uIDNewItem: usize, lpNewItem: usize) callconv(w32cc.WINAPI) i32 {
    const MF_SEPARATOR: u32 = 0x0800;
    const MF_CHECKED: u32 = 0x0008;
    const MF_GRAYED: u32 = 0x0001;
    const MF_DISABLED: u32 = 0x0002;
    if ((uFlags & MF_SEPARATOR) != 0) {
        addPopupItem(hMenu, -1, "", uFlags);
    } else if (lpNewItem != 0) {
        const w = trace.c_span_w(lpNewItem);
        var buf: [256]u8 = undefined;
        const name = text_utils.wideToUtf8(w, &buf);
        addPopupItem(hMenu, @intCast(uIDNewItem & 0xFFFF), name, uFlags);
        const key = menuItemKey(hMenu, @as(u32, @intCast(uIDNewItem & 0xFFFF)));
        const slot = findOrAllocMenuSlot(key);
        slot.flags = (slot.flags & ~(MF_CHECKED | MF_GRAYED | MF_DISABLED)) | (uFlags & (MF_CHECKED | MF_GRAYED | MF_DISABLED));
    }
    return 1;
}

/// TrackPopupMenu: show the popup menu in the web/FLTK UI and block modally
/// until the user picks an item (context_menu_select) or dismisses it.
pub fn TrackPopupMenu(hMenu: usize, uFlags: u32, x: i32, y: i32, nReserved: i32, hWnd: usize, prcRect: usize) callconv(w32cc.WINAPI) i32 {
    _ = uFlags;
    _ = nReserved;
    _ = hWnd;
    _ = prcRect;
    const renderer = @import("../../gui/renderer.zig");
    const platform = @import("../../platform.zig");
    if (!platform.is_native or renderer.active_backend == .none) return 0; // no UI to show — don't block

    const pm = findPopupMenu(hMenu) orelse return 0;

    // Items JSON for the frontend: [{"id":N,"text":"...","separator":..,"disabled":..,"checked":..}]
    var items_buf: [4096]u8 = undefined;
    var items_len: usize = 0;
    items_len = 1;
    items_buf[0] = '[';
    const MF_SEPARATOR: u32 = 0x0800;
    const MF_CHECKED: u32 = 0x0008;
    const MF_GRAYED: u32 = 0x0001;
    const MF_DISABLED: u32 = 0x0002;
    for (pm.items[0..pm.count], 0..) |it, idx| {
        var item_json: [512]u8 = undefined;
        var item_len: usize = 0;
        if ((it.flags & MF_SEPARATOR) != 0) {
            item_json[0] = '{';
            item_json[1] = '"';
            item_json[2] = 'i';
            item_json[3] = 'd';
            item_json[4] = '"';
            item_json[5] = ':';
            item_json[6] = '0';
            item_json[7] = ',';
            item_json[8] = '"';
            item_json[9] = 't';
            item_json[10] = 'e';
            item_json[11] = 'x';
            item_json[12] = 't';
            item_json[13] = '"';
            item_json[14] = ':';
            item_json[15] = '"';
            item_json[16] = '"';
            item_json[17] = ',';
            item_json[18] = '"';
            item_json[19] = 's';
            item_json[20] = 'e';
            item_json[21] = 'p';
            item_json[22] = 'a';
            item_json[23] = 'r';
            item_json[24] = 'a';
            item_json[25] = 't';
            item_json[26] = 'o';
            item_json[27] = 'r';
            item_json[28] = '"';
            item_json[29] = ':';
            item_json[30] = 't';
            item_json[31] = 'r';
            item_json[32] = 'u';
            item_json[33] = 'e';
            item_json[34] = '}';
            item_len = 35;
        } else {
            const disabled = (it.flags & (MF_GRAYED | MF_DISABLED)) != 0;
            const checked = (it.flags & MF_CHECKED) != 0;
            const written = std.fmt.bufPrint(&item_json, "{{\"id\":{d},\"text\":\"", .{it.id}) catch return 0;
            item_len = written.len;
            // JSON-escape the item text
            for (it.text[0..it.len]) |c| {
                switch (c) {
                    '"' => {
                        if (item_len + 2 <= item_json.len) {
                            item_json[item_len] = '\\';
                            item_json[item_len + 1] = '"';
                            item_len += 2;
                        }
                    },
                    '\\' => {
                        if (item_len + 2 <= item_json.len) {
                            item_json[item_len] = '\\';
                            item_json[item_len + 1] = '\\';
                            item_len += 2;
                        }
                    },
                    '\n' => {
                        if (item_len + 2 <= item_json.len) {
                            item_json[item_len] = '\\';
                            item_json[item_len + 1] = 'n';
                            item_len += 2;
                        }
                    },
                    '\r' => {},
                    '\t' => {
                        if (item_len + 2 <= item_json.len) {
                            item_json[item_len] = '\\';
                            item_json[item_len + 1] = 't';
                            item_len += 2;
                        }
                    },
                    else => {
                        if (item_len < item_json.len) {
                            item_json[item_len] = c;
                            item_len += 1;
                        }
                    },
                }
            }
            const tail = std.fmt.bufPrint(item_json[item_len..], "\",\"disabled\":{s},\"checked\":{s}}}", .{ if (disabled) "true" else "false", if (checked) "true" else "false" }) catch return 0;
            item_len += tail.len;
        }
        if (idx > 0) {
            if (items_len < items_buf.len) {
                items_buf[items_len] = ',';
                items_len += 1;
            }
        }
        if (items_len + item_len > items_buf.len) break;
        @memcpy(items_buf[items_len .. items_len + item_len], item_json[0..item_len]);
        items_len += item_len;
    }
    if (items_len < items_buf.len) {
        items_buf[items_len] = ']';
        items_len += 1;
    }

    if (trace.enable_tracing) trace.print("USER32: TrackPopupMenu({x}) -> show_context_menu({d},{d})\n", .{ hMenu, x, y });

    // Reset BEFORE publishing the menu: a selection stored by the backend
    // threads is only valid after this point, so it cannot be wiped by a
    // late-running reset on this thread.
    renderer.context_menu_chosen.store(false, .release);
    renderer.context_menu_result.store(0, .release);

    renderer.showContextMenu(x, y, items_buf[0..items_len]);

    // Block until the frontend reports a selection (context_menu_select).
    // Atomic load: the flag is stored from FLTK/web backend threads; a plain
    // bool could be hoisted out of this loop by the optimizer.
    while (!renderer.context_menu_chosen.load(.acquire)) {
        platform.sleep(10 * std.time.ns_per_ms);
    }
    const chosen = renderer.context_menu_result.load(.acquire);
    if (trace.enable_tracing) trace.print("USER32: TrackPopupMenu -> {d}\n", .{chosen});
    return @intCast(chosen);
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
    if (trace.enable_tracing) trace.print("USER32: GetMenuState(menu={X}, id={d})\n", .{ hMenu, uId });
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

/// Retrieves information about a menu item.
/// Implementation status: Partially implemented (returns safe defaults for common fMask values)
pub fn GetMenuItemInfoA(hMenu: usize, uItem: u32, fByPosition: i32, lpmii: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMenu;
    if (trace.enable_tracing) trace.print("USER32: GetMenuItemInfoA(item={d}, byPos={d})\n", .{ uItem, fByPosition });
    if (lpmii == 0) return 0;

    // Read fMask at offset +4
    const fMask = @as(*align(1) const u32, @ptrFromInt(lpmii + 4)).*;

    const MIIM_ID: u32 = 0x02;
    const MIIM_SUBMENU: u32 = 0x04;
    const MIIM_TYPE: u32 = 0x10;
    const MIIM_STRING: u32 = 0x40;

    // If fMask has MIIM_TYPE (0x10), set fType at +8 to MFT_STRING (0)
    if (fMask & MIIM_TYPE != 0) {
        @as(*align(1) u32, @ptrFromInt(lpmii + 8)).* = 0; // MFT_STRING
    }

    // If fMask has MIIM_ID (0x02), set wID at +12 to uItem
    if (fMask & MIIM_ID != 0) {
        @as(*align(1) u32, @ptrFromInt(lpmii + 12)).* = uItem;
    }

    // If fMask has MIIM_SUBMENU (0x04), set hSubMenu at +20 to 0
    if (fMask & MIIM_SUBMENU != 0) {
        @as(*align(1) u32, @ptrFromInt(lpmii + 20)).* = 0;
    }

    // If fMask has MIIM_STRING (0x40), write empty string to dwTypeData
    if (fMask & MIIM_STRING != 0) {
        const dwTypeData = @as(*align(1) u32, @ptrFromInt(lpmii + 32)).*;
        if (dwTypeData != 0) {
            @as(*u8, @ptrFromInt(dwTypeData)).* = 0; // empty string
        }
        // Set cch at +36 to 0 (empty string length)
        @as(*align(1) u32, @ptrFromInt(lpmii + 36)).* = 0;
    }

    return 1; // success
}
