const trace = @import("../../trace.zig");
const kernel32 = @import("../kernel32.zig");
const w32cc = @import("../calling_convention.zig");

/// Determines the location of a resource with the specified type and name in the specified module.
/// Implementation status: Partially implemented (supports integer IDs)
pub fn FindResourceA(hModule: usize, lpName: usize, lpType: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        const name_s = if (lpName > 0xFFFF) trace.c_span(lpName) else "INTRESOURCE";
        const type_s = if (lpType > 0xFFFF) trace.c_span(lpType) else "INTRESOURCE";
        trace.print("KERNEL32: FindResourceA(hMod={x}, name={s}({x}), type={s}({x}))\n", .{ hModule, name_s, lpName, type_s, lpType });
    }
    return findResourceImpl(hModule, lpName, lpType);
}

/// Determines the location of a resource with the specified type and name in the specified module (Unicode version).
/// Implementation status: Partially implemented (supports integer IDs)
pub fn FindResourceW(hModule: usize, lpName: usize, lpType: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        trace.print("KERNEL32: FindResourceW(hMod={x}, name={x}, type={x})\n", .{ hModule, lpName, lpType });
    }
    return findResourceImpl(hModule, lpName, lpType);
}

fn findResourceImpl(hModule: usize, lpName: usize, lpType: usize) usize {
    // Type must be an integer resource ID for now
    if (lpType > 0xFFFF) return 0;
    const resource_type: u32 = @intCast(lpType & 0xFFFF);

    // Find the module to get its resource data
    if (kernel32.global_env) |genv| {
        var mod_handle = hModule;
        if (mod_handle == 0) mod_handle = kernel32.main_module_handle;

        var it = genv.registry.modules.valueIterator();
        while (it.next()) |m| {
            if (@intFromPtr(m.*.mapped_memory.ptr) == mod_handle) {
                if (lpName <= 0xFFFF) {
                    // Integer resource ID
                    const resource_id: u32 = @intCast(lpName & 0xFFFF);
                    if (m.*.getResource(resource_type, resource_id)) |data| {
                        if (trace.enable_tracing) trace.print("KERNEL32: FindResource -> {x} (size={d})\n", .{ @intFromPtr(data.ptr), data.len });
                        return @intFromPtr(data.ptr);
                    }
                } else {
                    // String resource name — look up by name in the PE resource directory
                    const name_str = trace.c_span(lpName);
                    if (m.*.getResourceByName(resource_type, name_str)) |data| {
                        if (trace.enable_tracing) trace.print("KERNEL32: FindResource('{s}') -> {x} (size={d})\n", .{ name_str, @intFromPtr(data.ptr), data.len });
                        return @intFromPtr(data.ptr);
                    }
                }
                break;
            }
        }
    }
    if (trace.enable_tracing) trace.print("KERNEL32: FindResource -> 0 (not found)\n", .{});
    return 0;
}

/// Retrieves a handle that can be used to obtain a pointer to the first byte of the specified resource in memory.
/// Implementation status: Partially implemented (returns the resource info handle directly)
pub fn LoadResource(hModule: usize, hResInfo: usize) callconv(w32cc.WINAPI) usize {
    _ = hModule;
    if (trace.enable_tracing) trace.print("KERNEL32: LoadResource({x}) -> {x}\n", .{ hResInfo, hResInfo });
    return hResInfo;
}

/// Retrieves the size, in bytes, of the specified resource.
/// Our FindResource returns a pointer to the PE's mapped resource data.
/// The resource data entry's Size field is at (data_entry_ptr - 8).Size,
/// but since we return the data pointer directly, we store the size just
/// before the data in the PE's resource data entry structure.
pub fn stub_SizeofResource(hModule: usize, hResInfo: usize) callconv(w32cc.WINAPI) u32 {
    _ = hModule;
    if (hResInfo == 0) return 0;
    // Walk backwards from the data pointer to find the IMAGE_RESOURCE_DATA_ENTRY
    // that contains the Size field. Our FindResource returns the actual data start
    // (mapped_memory[OffsetToData]). The DATA_ENTRY is elsewhere in the resource
    // directory, so we can't easily find the size from just the pointer.
    // Pragmatic approach: scan backwards for the data entry that points to this offset.
    if (kernel32.global_env) |genv| {
        const mod_handle = kernel32.main_module_handle;
        var it = genv.registry.modules.valueIterator();
        while (it.next()) |m| {
            if (@intFromPtr(m.*.mapped_memory.ptr) == mod_handle) {
                const base = @intFromPtr(m.*.mapped_memory.ptr);
                if (hResInfo >= base and hResInfo < base + m.*.mapped_memory.len) {
                    const offset = hResInfo - base;
                    // Search for a DATA_ENTRY with OffsetToData == offset
                    const pe_res = @import("../../pe_resources.zig");
                    const opt_header = &m.*.parser.getNtHeaders().OptionalHeader;
                    const res_dir_rva = opt_header.DataDirectory[@import("../../pe.zig").IMAGE_DIRECTORY_ENTRY_RESOURCE].VirtualAddress;
                    if (res_dir_rva == 0) return 0;
                    // Scan all potential data entries in the resource directory.
                    // The directory RVA and size come from the PE but are not
                    // covered by any image-bound check, so both the end offset
                    // and the cursor are widened to u64 and clamped to the
                    // mapped image before the walk starts.
                    const res_dir = opt_header.DataDirectory[@import("../../pe.zig").IMAGE_DIRECTORY_ENTRY_RESOURCE];
                    const image_len: u64 = m.*.mapped_memory.len;
                    const res_end: u64 = @min(@as(u64, res_dir_rva) + res_dir.Size, image_len);
                    var pos: u64 = res_dir_rva;
                    while (pos + @sizeOf(pe_res.IMAGE_RESOURCE_DATA_ENTRY) <= res_end) : (pos += 4) {
                        const de = @as(*align(1) const pe_res.IMAGE_RESOURCE_DATA_ENTRY, @ptrCast(&m.*.mapped_memory[@intCast(pos)]));
                        if (de.OffsetToData == offset and de.Size > 0 and de.Size < m.*.mapped_memory.len) {
                            return de.Size;
                        }
                    }
                }
                break;
            }
        }
    }
    return 0;
}

/// Retrieves a pointer to the specified resource in memory.
/// Implementation status: Partially implemented (returns the resource data handle directly)
pub fn LockResource(hResData: usize) callconv(w32cc.WINAPI) usize {
    // In Win32, LockResource just returns the pointer.
    return hResData;
}

/// Decrements (decreases by one) the reference count of a loaded resource.
/// In 32-bit Windows, this function is obsolete and simply returns TRUE.
/// Implementation status: Complete
pub fn FreeResource(hResData: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: FreeResource({x}) -> 1 (no-op)\n", .{hResData});
    return 1; // TRUE — always succeeds (obsolete in Win32)
}
