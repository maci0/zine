//! PE loader and import resolver.
//!
//! This module handles loading PE files into guest memory, mapping sections,
//! resolving DLL imports, and setting up thunks for Win32 API calls. It also
//! manages the thunk code region used on WASM to bridge guest and host.

const std = @import("std");
const pe = @import("../pe.zig");
const Module = @import("module.zig").Module;
const Environment = @import("env.zig").Environment;
const BuiltinExport = @import("env.zig").BuiltinExport;
const trace = @import("../trace.zig");
const log = @import("../log.zig");
const x86_thunks = @import("../x86/thunks.zig");
const x86_memory = @import("../x86/memory.zig");
const w32cc = @import("../win32/calling_convention.zig");
const platform = @import("../platform.zig");

// -----------------------------------------------------------------------
// Thunk code region for WASM
// -----------------------------------------------------------------------

var thunk_memory: ?*x86_memory.GuestMemory = null;
var thunk_write_addr: u32 = 0;

/// Configures the guest memory region and base address for thunk allocation.
/// This memory is used on WASM to store small code snippets that bridge
/// guest x86 calls to host WASM functions.
pub fn setThunkMemory(mem: *x86_memory.GuestMemory, start_addr: u32) void {
    thunk_memory = mem;
    thunk_write_addr = start_addr;
}

/// Save and restore thunk state for nested PE execution (WASM spawn handler).
pub const ThunkState = struct { mem: ?*x86_memory.GuestMemory, addr: u32 };

pub fn saveThunkState() ThunkState {
    return .{ .mem = thunk_memory, .addr = thunk_write_addr };
}

pub fn restoreThunkState(state: ThunkState) void {
    thunk_memory = state.mem;
    thunk_write_addr = state.addr;
}

/// Allocates and writes a thunk stub in guest memory at the current write address.
/// Returns the guest address of the written thunk and advances the write address.
///
/// This is used on WASM to generate the actual machine code (INT 0xFE + ID)
/// that the interpreter will trap on to call the host function.
fn allocThunkCode(mem: *x86_memory.GuestMemory, thunk_id: u32) u32 {
    const addr = thunk_write_addr;
    thunk_write_addr = x86_thunks.writeThunkCode(mem, addr, thunk_id);
    return addr;
}

/// Patches a single Import Address Table (IAT) slot with the address of a resolved export.
///
/// On WASM targets, this is a complex operation:
/// - If the export is data, the guest address of the data is written directly.
/// - If the export is a function with a comptime handler, a thunk is allocated that
///   calls that specific handler (avoiding WASM indirect call type mismatches).
/// - Otherwise, a generic native thunk is created to dispatch to the host function.
///
/// On native targets, the address is written directly to the IAT slot, and
/// native imports are registered in the thunk table for host-side dispatch.
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

/// Recursively resolves all imports for a given module, patching its Import
/// Address Table (IAT) with either host stub addresses (on native) or guest
/// thunk addresses (on WASM). 
///
/// For each imported DLL, it:
/// 1. Loads the dependency DLL if it is not already loaded.
/// 2. Iterates through all imported functions.
/// 3. Resolves each function to its export in the corresponding module.
/// 4. Patches the IAT slot with the resolved address or a thunk.
/// 5. Registers unresolved imports for diagnostic purposes if they cannot be found.
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

/// Calls the entry point (DllMain) for all loaded PE dependency DLLs that
/// have not yet been initialized. This is typically called after all imports
/// for a module and its dependencies have been resolved.
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
