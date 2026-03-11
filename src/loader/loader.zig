const std = @import("std");
const pe = @import("../pe.zig");
const Module = @import("module.zig").Module;
const Environment = @import("env.zig").Environment;
const trace = @import("../trace.zig");

pub fn resolveImports(env: *Environment, mod: *Module) !void {
    if (mod.imports_resolved) return;

    const opt_header = &mod.parser.getNtHeaders().OptionalHeader;
    const import_dir_entry = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_IMPORT];

    if (import_dir_entry.Size == 0) {
        mod.imports_resolved = true;
        return;
    }

    var import_desc_offset = import_dir_entry.VirtualAddress;
    while (true) {
        const import_desc = @as(*pe.IMAGE_IMPORT_DESCRIPTOR, @ptrCast(@alignCast(&mod.mapped_memory[import_desc_offset])));
        if (import_desc.Name == 0) break; // Null descriptor terminates the array

        const dll_name = std.mem.span(@as([*:0]const u8, @ptrCast(&mod.mapped_memory[import_desc.Name])));

        // Ensure the dependency is loaded into the registry if we can find it
        if (env.registry.loadModule(dll_name)) |loaded_mod| {
            std.log.info("Loaded dependency: {s}", .{loaded_mod.name});
            // Recursively resolve the dependency's imports (but don't call DllMain yet)
            if (!loaded_mod.imports_resolved) {
                resolveImports(env, loaded_mod) catch |resolve_err| {
                    if (trace.enable_tracing) trace.print("loader: failed to resolve imports for {s}: {}\n", .{ dll_name, resolve_err });
                };
            }
        } else |err| {
            if (err != error.FileNotFound and err != error.ModuleNotFound) return err;
            // Ignore not found, we might resolve via builtins
        }

        const thunk_rva = if (import_desc.OriginalFirstThunk == 0) import_desc.FirstThunk else import_desc.OriginalFirstThunk;

        var thunk_offset: u32 = 0;
        while (true) : (thunk_offset += @sizeOf(u32)) {
            const orig_thunk = @as(*pe.IMAGE_THUNK_DATA32, @ptrCast(@alignCast(&mod.mapped_memory[thunk_rva + thunk_offset])));
            const first_thunk = @as(*u32, @ptrCast(@alignCast(&mod.mapped_memory[import_desc.FirstThunk + thunk_offset])));

            if (orig_thunk.u1.AddressOfData == 0) break;

            if ((orig_thunk.u1.Ordinal & 0x80000000) != 0) {
                const ordinal = orig_thunk.u1.Ordinal & 0xFFFF;
                var ord_name_buf: [32]u8 = undefined;
                const ord_name = std.fmt.bufPrint(&ord_name_buf, "ordinal_{d}", .{ordinal}) catch "ordinal_0";

                if (env.resolveExport(dll_name, ord_name)) |addr| {
                    first_thunk.* = @intCast(addr);
                    if (trace.enable_tracing) {
                        trace.print("loader: {s} -> {s} at {X}\n", .{ dll_name, ord_name, addr });
                    }
                } else {
                    const not_implemented = env.resolveExport("builtin", "not_implemented") orelse 0;
                    std.log.warn("Unresolved ordinal import {s} -> {d}. Patching to 0x{X}", .{ dll_name, ordinal, not_implemented });
                    first_thunk.* = @intCast(not_implemented);
                }
            } else {
                const func_name = std.mem.span(@as([*:0]const u8, @ptrCast(@alignCast(&mod.mapped_memory[orig_thunk.u1.AddressOfData + @sizeOf(pe.IMAGE_IMPORT_BY_NAME)]))));

                if (env.resolveExport(dll_name, func_name)) |addr| {
                    first_thunk.* = @intCast(addr);
                    if (trace.enable_tracing) {
                        trace.print("loader: {s} -> {s} at {X}\n", .{ dll_name, func_name, addr });
                    }
                } else {
                    const not_implemented = env.resolveExport("builtin", "not_implemented") orelse 0;
                    std.log.warn("Unresolved import {s} -> {s}. Patching to 0x{X}", .{ dll_name, func_name, not_implemented });
                    first_thunk.* = @intCast(not_implemented);
                }
            }
        }
        import_desc_offset += @sizeOf(pe.IMAGE_IMPORT_DESCRIPTOR);
    }

    mod.imports_resolved = true;
}

/// Call DllMain(DLL_PROCESS_ATTACH) for all loaded PE dependency DLLs that haven't been attached yet.
/// Must be called after resolveImports to ensure all IATs are resolved.
pub fn attachLoadedDlls(env: *Environment) void {
    var it = env.registry.modules.iterator();
    while (it.next()) |entry| {
        const mod = entry.value_ptr.*;
        if (mod.attached) continue;

        const opt_header = &mod.parser.getNtHeaders().OptionalHeader;
        // Only call DllMain for DLLs (not the main executable)
        if ((opt_header.Subsystem != 0 and opt_header.Subsystem != 2 and opt_header.Subsystem != 3) or
            (opt_header.DllCharacteristics & 0x2000) != 0 or // IMAGE_DLLCHARACTERISTICS_WDM_DRIVER check doesn't help
            opt_header.AddressOfEntryPoint == 0)
        {
            mod.attached = true;
            continue;
        }

        // Heuristic: DLLs typically have Characteristics flag IMAGE_FILE_DLL (0x2000)
        const nt_headers = mod.parser.getNtHeaders();
        const file_header = &nt_headers.FileHeader;
        if ((file_header.Characteristics & 0x2000) == 0) {
            // Not a DLL, skip DllMain
            mod.attached = true;
            continue;
        }

        mod.attached = true;
        const entry_addr = @intFromPtr(mod.mapped_memory.ptr) + opt_header.AddressOfEntryPoint;
        const DllMain = @as(*const fn (usize, u32, usize) callconv(.winapi) i32, @ptrFromInt(entry_addr));
        if (trace.enable_tracing) trace.print("loader: calling DllMain for {s} at {x}\n", .{ entry.key_ptr.*, entry_addr });
        _ = DllMain(@intFromPtr(mod.mapped_memory.ptr), 1, 0);
    }
}
