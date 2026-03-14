const std = @import("std");
const pe = @import("../pe.zig");
const Module = @import("module.zig").Module;
const Environment = @import("env.zig").Environment;
const BuiltinExport = @import("env.zig").BuiltinExport;
const trace = @import("../trace.zig");
const log = @import("../log.zig");
const x86_thunks = @import("../x86/thunks.zig");
const x86_memory = @import("../x86/memory.zig");
const w32cc = @import("../calling_convention.zig");
const platform = @import("../platform.zig");

// -----------------------------------------------------------------------
// Thunk code region for WASM
// -----------------------------------------------------------------------

var thunk_memory: ?*x86_memory.GuestMemory = null;
var thunk_write_addr: u32 = 0;

/// Set the guest memory that the thunk allocator writes into.
pub fn setThunkMemory(mem: *x86_memory.GuestMemory, start_addr: u32) void {
    thunk_memory = mem;
    thunk_write_addr = start_addr;
}

/// Allocate and write a thunk stub in guest memory. Returns the guest address.
fn allocThunkCode(mem: *x86_memory.GuestMemory, thunk_id: u32) u32 {
    const addr = thunk_write_addr;
    thunk_write_addr = x86_thunks.writeThunkCode(mem, addr, thunk_id);
    return addr;
}

fn patchImport(
    first_thunk: *u32,
    exp: BuiltinExport,
    dll_name: []const u8,
    func_name: []const u8,
) void {
    if (comptime platform.is_wasm) {
        if (exp.is_data) {
            // Data export (e.g., _iob, _adjust_fdiv) —
            // write the data address directly to the IAT. Do NOT create
            // a thunk; the PE code dereferences this address as data.
            first_thunk.* = @intCast(exp.addr);
            if (trace.enable_tracing) {
                trace.print("loader: {s} -> {s} at {X} (data export)\n", .{ dll_name, func_name, exp.addr });
            }
        } else if (exp.thunk_handler) |handler| {
            // Use the comptime-generated handler that calls the stub with
            // the exact correct signature (avoids WASM type mismatch)
            const thunk_id = x86_thunks.registerThunk(.{
                .name = func_name,
                .param_count = null, // handler manages ESP itself
                .handler = handler,
            });
            if (thunk_memory) |mem| {
                const guest_addr = allocThunkCode(mem, thunk_id);
                first_thunk.* = guest_addr;
                if (trace.enable_tracing) {
                    trace.print("loader: {s} -> {s} at thunk {X} (id={d})\n", .{ dll_name, func_name, guest_addr, thunk_id });
                }
            } else {
                first_thunk.* = @intCast(exp.addr);
                if (trace.enable_tracing) {
                    trace.print("loader: {s} -> {s} at {X} (no thunk mem!)\n", .{ dll_name, func_name, exp.addr });
                }
            }
        } else {
            // Non-comptime function export (e.g., _EH_prolog, _ftol) —
            // create a generic thunk to dispatch to the native function.
            const thunk_id = x86_thunks.registerNativeThunk(func_name, exp.addr, exp.param_bytes, false);
            if (thunk_memory) |mem| {
                const guest_addr = allocThunkCode(mem, thunk_id);
                first_thunk.* = guest_addr;
                if (trace.enable_tracing) {
                    trace.print("loader: {s} -> {s} at thunk {X} (id={d})\n", .{ dll_name, func_name, guest_addr, thunk_id });
                }
            } else {
                first_thunk.* = @intCast(exp.addr);
                if (trace.enable_tracing) {
                    trace.print("loader: {s} -> {s} at {X} (no thunk mem!)\n", .{ dll_name, func_name, exp.addr });
                }
            }
        }
    } else {
        // On native: write the address directly.
        first_thunk.* = @intCast(exp.addr);
        if (exp.is_native) {
            // Register for dispatchNativeCall
            x86_thunks.registerNativeImport(@intCast(exp.addr), dll_name, func_name, exp.param_bytes);
            if (trace.enable_tracing) {
                trace.print("loader: {s} -> {s} at {X} (native IAT=0x{x})\n", .{ dll_name, func_name, exp.addr, @intFromPtr(first_thunk) });
            }
        } else {
            // Guest export
            if (trace.enable_tracing) {
                trace.print("loader: {s} -> {s} at {X} (guest IAT=0x{x})\n", .{ dll_name, func_name, exp.addr, @intFromPtr(first_thunk) });
            }
        }
    }
}

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
        if (import_desc.Name == 0) break;

        const dll_name = std.mem.span(@as([*:0]const u8, @ptrCast(&mod.mapped_memory[import_desc.Name])));

        if (env.registry.loadModule(dll_name)) |loaded_mod| {
            log.info("Loaded dependency: {s}", .{loaded_mod.name});
            if (!loaded_mod.imports_resolved) {
                resolveImports(env, loaded_mod) catch |resolve_err| {
                    if (trace.enable_tracing) trace.print("loader: failed to resolve imports for {s}: {}\n", .{ dll_name, resolve_err });
                };
            }
        } else |err| {
            if (err != error.FileNotFound and err != error.ModuleNotFound) return err;
        }

        const thunk_rva = if (import_desc.OriginalFirstThunk == 0) import_desc.FirstThunk else import_desc.OriginalFirstThunk;

        var thunk_offset: u32 = 0;
        while (true) : (thunk_offset += @sizeOf(u32)) {
            const orig_thunk = @as(*pe.IMAGE_THUNK_DATA32, @ptrCast(@alignCast(&mod.mapped_memory[thunk_rva + thunk_offset])));
            const first_thunk = @as(*u32, @ptrCast(@alignCast(&mod.mapped_memory[import_desc.FirstThunk + thunk_offset])));

            if (orig_thunk.u1.AddressOfData == 0) break;

            if (import_desc.FirstThunk + thunk_offset == 0x5A68) {
                if (trace.enable_tracing) trace.print("WATCHPOINT: IAT overwrite detected! dll={s} orig_thunk_u1={x}\n", .{ dll_name, orig_thunk.u1.Ordinal });
            }

            if ((orig_thunk.u1.Ordinal & 0x80000000) != 0) {
                const ordinal = orig_thunk.u1.Ordinal & 0xFFFF;
                var ord_name_buf: [32]u8 = undefined;
                const ord_name = std.fmt.bufPrint(&ord_name_buf, "ordinal_{d}", .{ordinal}) catch "ordinal_0";

                if (env.resolveExport(dll_name, ord_name)) |exp| {
                    patchImport(first_thunk, exp, dll_name, ord_name);
                } else {
                    const not_implemented = env.resolveExport("builtin", "not_implemented");
                    if (not_implemented) |ni| {
                        patchImport(first_thunk, ni, dll_name, ord_name);
                    } else {
                        first_thunk.* = 0;
                    }
                    const ord_str = std.fmt.bufPrint(&ord_name_buf, "ordinal_{d}", .{ordinal}) catch "ordinal_?";
                    log.warn("Unresolved ordinal import {s} -> {d}", .{ dll_name, ordinal });
                    x86_thunks.registerUnresolvedImport(@intCast(@intFromPtr(first_thunk)), dll_name, ord_str);
                }
            } else {
                const func_name = std.mem.span(@as([*:0]const u8, @ptrCast(@alignCast(&mod.mapped_memory[orig_thunk.u1.AddressOfData + @sizeOf(pe.IMAGE_IMPORT_BY_NAME)]))));

                if (env.resolveExport(dll_name, func_name)) |exp| {
                    patchImport(first_thunk, exp, dll_name, func_name);
                } else {
                    const not_implemented = env.resolveExport("builtin", "not_implemented");
                    if (not_implemented) |ni| {
                        patchImport(first_thunk, ni, dll_name, func_name);
                    } else {
                        first_thunk.* = 0;
                    }
                    log.warn("Unresolved import {s} -> {s}", .{ dll_name, func_name });
                    x86_thunks.registerUnresolvedImport(@intCast(@intFromPtr(first_thunk)), dll_name, func_name);
                }
            }
        }
        import_desc_offset += @sizeOf(pe.IMAGE_IMPORT_DESCRIPTOR);
    }

    mod.imports_resolved = true;
}

/// Call DllMain(DLL_PROCESS_ATTACH) for all loaded PE dependency DLLs that haven't been attached yet.
pub fn attachLoadedDlls(env: *Environment) void {
    var it = env.registry.modules.iterator();
    while (it.next()) |entry| {
        const mod = entry.value_ptr.*;
        if (mod.attached) continue;

        const opt_header = &mod.parser.getNtHeaders().OptionalHeader;
        if ((opt_header.Subsystem != 0 and opt_header.Subsystem != 2 and opt_header.Subsystem != 3) or
            (opt_header.DllCharacteristics & 0x2000) != 0 or
            opt_header.AddressOfEntryPoint == 0)
        {
            mod.attached = true;
            continue;
        }

        const nt_headers = mod.parser.getNtHeaders();
        const file_header = &nt_headers.FileHeader;
        if ((file_header.Characteristics & 0x2000) == 0) {
            mod.attached = true;
            continue;
        }

        mod.attached = true;
        const entry_addr = @intFromPtr(mod.mapped_memory.ptr) + opt_header.AddressOfEntryPoint;
        const DllMain = @as(*const fn (usize, u32, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(entry_addr));
        if (trace.enable_tracing) trace.print("loader: calling DllMain for {s} at {x}\n", .{ entry.key_ptr.*, entry_addr });
        _ = DllMain(@intFromPtr(mod.mapped_memory.ptr), 1, 0);
    }
}
