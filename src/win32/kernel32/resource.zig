const trace = @import("../../trace.zig");
const kernel32 = @import("../kernel32.zig");
const w32cc = @import("../calling_convention.zig");

/// Determines the location of a resource with the specified type and name in the specified module.
/// Implementation status: Partially implemented (supports integer IDs).
pub fn FindResourceA(hModule: usize, lpName: usize, lpType: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        const name_s = if (lpName > 0xFFFF) trace.c_span(lpName) else "INTRESOURCE";
        const type_s = if (lpType > 0xFFFF) trace.c_span(lpType) else "INTRESOURCE";
        trace.print("KERNEL32: FindResourceA(hMod={x}, name={s}({x}), type={s}({x}))\n", .{ hModule, name_s, lpName, type_s, lpType });
    }
    return findResourceImpl(hModule, lpName, lpType);
}

/// Determines the location of a resource with the specified type and name in the specified module (Unicode version).
/// Implementation status: Partially implemented (supports integer IDs).
pub fn FindResourceW(hModule: usize, lpName: usize, lpType: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        trace.print("KERNEL32: FindResourceW(hMod={x}, name={x}, type={x})\n", .{ hModule, lpName, lpType });
    }
    return findResourceImpl(hModule, lpName, lpType);
}

fn findResourceImpl(hModule: usize, lpName: usize, lpType: usize) usize {
    // Only support MAKEINTRESOURCE (integer IDs <= 0xFFFF) for now
    if (lpType > 0xFFFF or lpName > 0xFFFF) return 0;

    const resource_type: u32 = @intCast(lpType & 0xFFFF);
    const resource_id: u32 = @intCast(lpName & 0xFFFF);

    // Find the module to get its resource data
    if (kernel32.global_env) |genv| {
        var mod_handle = hModule;
        if (mod_handle == 0) mod_handle = kernel32.main_module_handle;

        var it = genv.registry.modules.valueIterator();
        while (it.next()) |m| {
            if (@intFromPtr(m.*.mapped_memory.ptr) == mod_handle) {
                if (m.*.getResource(resource_type, resource_id)) |data| {
                    if (trace.enable_tracing) trace.print("KERNEL32: FindResource -> {x} (size={d})\n", .{ @intFromPtr(data.ptr), data.len });
                    return @intFromPtr(data.ptr);
                }
                break;
            }
        }
    }
    if (trace.enable_tracing) trace.print("KERNEL32: FindResource -> 0 (not found)\n", .{});
    return 0;
}

/// Retrieves a handle that can be used to obtain a pointer to the first byte of the specified resource in memory.
/// Implementation status: Partially implemented (returns the resource info handle directly).
pub fn LoadResource(hModule: usize, hResInfo: usize) callconv(w32cc.WINAPI) usize {
    _ = hModule;
    // In Win32, LoadResource just returns the HGLOBAL handle.
    // Since our FindResource already returns a direct pointer to the data, just pass it through.
    return hResInfo;
}

/// Retrieves the size, in bytes, of the specified resource.
/// Implementation status: Stub (currently returns 0).
pub fn stub_SizeofResource(hModule: usize, hResInfo: usize) callconv(w32cc.WINAPI) u32 {
    _ = hModule;
    // We need to find the size. Since FindResource returned the data pointer,
    // we need to look up the resource again. For now, return 0 — most apps
    // don't need SizeofResource if they know the format.
    _ = hResInfo;
    return 0;
}

/// Retrieves a pointer to the specified resource in memory.
/// Implementation status: Partially implemented (returns the resource data handle directly).
pub fn LockResource(hResData: usize) callconv(w32cc.WINAPI) usize {
    // In Win32, LockResource just returns the pointer.
    return hResData;
}
