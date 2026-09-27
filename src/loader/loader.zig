//! PE loader and import resolver.
//!
//! This module handles loading PE files into guest memory, mapping sections,
//! resolving DLL imports, and setting up thunks for Win32 API calls. It also
//! manages the thunk code region used on WASM to bridge guest and host, plus
//! image placement helpers (reverse relocation, BSS zero-fill, .rsrc
//! protection) shared by both entry points.

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

/// Copy a loaded PE DLL into GuestMemory so the x86 interpreter can execute
/// its code. Updates the module's image_base and mapped_memory to point at the
/// guest copy. Applies relocations for the new base address.
/// Called on WASM when resolveImports encounters a real PE dependency.
pub fn copyModuleToGuest(mod: *Module) void {
    log.info("copyModuleToGuest: {s}, guest_memory={?}, heap_start={d}", .{
        mod.name,
        @as(?usize, if (x86_memory.guest_memory) |g| @intFromPtr(g) else null),
        if (x86_memory.guest_memory) |g| g.heap_start else 0,
    });
    const gmem = x86_memory.guest_memory orelse return;

    // Skip if already in guest memory (image_base falls within guest range)
    const guest_end = gmem.base_addr +% @as(u32, @intCast(gmem.base.len));
    if (mod.image_base >= gmem.base_addr and mod.image_base < guest_end) return;

    const image_size: u32 = @intCast(mod.mapped_memory.len);
    const guest_va = gmem.guestAlloc(image_size);
    if (guest_va == 0) {
        log.warn("copyModuleToGuest: OOM for {s} ({d} bytes)", .{ mod.name, image_size });
        return;
    }
    const offset = guest_va - gmem.base_addr;

    // Copy PE image into guest memory
    @memcpy(gmem.base[offset..][0..image_size], mod.mapped_memory[0..image_size]);

    // Apply relocations: Module.load already relocated the image to
    // mod.image_base (the host mapped address). We need to re-relocate
    // from that base to the guest VA.
    const actual_base: u32 = @truncate(mod.image_base);
    applyReverseRelocations(
        gmem.base[offset..][0..image_size],
        &mod.parser,
        image_size,
        actual_base,
        guest_va,
    );
    zeroFillBss(gmem.base[offset..][0..image_size], mod.parser.sections);

    // Update image_base so getExport() returns guest VAs.
    // Keep mapped_memory pointing at original buffer so parser references
    // remain valid for import resolution of this dependency.
    mod.image_base = guest_va;

    log.info("copyModuleToGuest: {s} at guest 0x{X}-0x{X} ({d} bytes), heap_cursor now 0x{X}", .{ mod.name, guest_va, guest_va + image_size, image_size, gmem.heap_cursor + gmem.base_addr });
}

// -----------------------------------------------------------------------
// Reverse Relocation (WASM only)
// -----------------------------------------------------------------------

/// Apply reverse base relocations to a PE image buffer, skipping IAT slots.
/// Used in WASM mode where the PE is copied into a combined buffer at a
/// different base address than where Module.load mapped it.
pub fn applyReverseRelocations(
    buf: []u8,
    parser: anytype,
    image_size: u32,
    actual_base: u32,
    preferred_base: u32,
) void {
    if (actual_base == preferred_base) return;
    const reverse_delta = preferred_base -% actual_base;
    const opt_header = &parser.getNtHeaders().OptionalHeader;

    // Collect IAT ranges to skip (resolveImports already wrote correct thunk addresses)
    const import_dir_entry = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_IMPORT];
    var iat_ranges: [32][2]u32 = undefined;
    var iat_range_count: usize = 0;
    if (import_dir_entry.Size > 0) {
        // Every RVA below comes from guest data, so each bound is computed in
        // u64: `rva + n` in u32 wraps and lets a huge RVA pass a range check.
        const img_end: u64 = image_size;
        var imp_off: u64 = import_dir_entry.VirtualAddress;
        while (imp_off + 20 <= img_end) {
            const imp_name = @as(*align(1) const u32, @ptrCast(buf[@intCast(imp_off + 12)..].ptr)).*;
            if (imp_name == 0) break;
            const first_thunk_rva = @as(*align(1) const u32, @ptrCast(buf[@intCast(imp_off + 16)..].ptr)).*;
            const orig_thunk_rva_raw = @as(*align(1) const u32, @ptrCast(buf[@intCast(imp_off)..].ptr)).*;
            const ilt_rva: u64 = if (orig_thunk_rva_raw == 0) first_thunk_rva else orig_thunk_rva_raw;
            var count: u32 = 0;
            var entry_off = ilt_rva;
            while (entry_off + 4 <= img_end) {
                const e_val = @as(*align(1) const u32, @ptrCast(buf[@intCast(entry_off)..].ptr)).*;
                if (e_val == 0) break;
                count += 1;
                entry_off += 4;
            }
            if (iat_range_count < iat_ranges.len) {
                // IAT RVAs in buf are in actual_base terms (from Module.load relocation),
                // but .reloc entries use preferred_base terms. Adjust to match.
                const adj_start = first_thunk_rva +% reverse_delta;
                iat_ranges[iat_range_count] = .{ adj_start, adj_start + count * 4 };
                iat_range_count += 1;
            }
            imp_off += 20;
        }
    }

    const reloc_dir = opt_header.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_BASERELOC];
    if (reloc_dir.Size > 0) {
        var reloc_offset = reloc_dir.VirtualAddress;
        // Clamp the reloc table to the buffer; malformed PEs may declare a
        // directory extending past the image.
        const buf_end: u64 = @min(@as(u64, reloc_offset) + reloc_dir.Size, image_size);
        while (@as(u64, reloc_offset) + 8 <= buf_end) {
            const block_va = @as(*align(1) const u32, @ptrCast(buf[reloc_offset..].ptr)).*;
            const block_size = @as(*align(1) const u32, @ptrCast(buf[reloc_offset + 4 ..].ptr)).*;
            if (block_size < 8) break;
            if (@as(u64, reloc_offset) + block_size > image_size) break;
            const entries_count = (block_size - 8) / 2;
            for (0..entries_count) |e| {
                const entry = @as(*align(1) const u16, @ptrCast(buf[reloc_offset + 8 + e * 2 ..].ptr)).*;
                const IMAGE_REL_BASED_HIGHLOW = 3;
                if (entry >> 12 == IMAGE_REL_BASED_HIGHLOW) {
                    const patch_addr = block_va + (entry & 0x0FFF);
                    var in_iat = false;
                    for (iat_ranges[0..iat_range_count]) |range| {
                        if (patch_addr >= range[0] and patch_addr < range[1]) {
                            in_iat = true;
                            break;
                        }
                    }
                    if (in_iat) continue;
                    if (patch_addr + 4 <= image_size) {
                        const ptr = @as(*align(1) u32, @ptrCast(buf[patch_addr..].ptr));
                        ptr.* = ptr.* +% reverse_delta;
                    }
                }
            }
            reloc_offset += block_size;
        }
    }
}

// -----------------------------------------------------------------------
// BSS Zero-Fill
// -----------------------------------------------------------------------

/// Zero-fill BSS regions in PE sections (VirtualSize > SizeOfRawData).
pub fn zeroFillBss(buf: []u8, sections: anytype) void {
    for (sections) |sec| {
        const vsize = sec.Misc.VirtualSize;
        if (vsize > sec.SizeOfRawData) {
            // u64 arithmetic: a wrapping section address must not produce a
            // reversed slice.
            const bss_start: u64 = @as(u64, sec.VirtualAddress) + sec.SizeOfRawData;
            const bss_end: u64 = @as(u64, sec.VirtualAddress) + vsize;
            if (bss_end <= buf.len and bss_start <= bss_end) {
                @memset(buf[@intCast(bss_start)..@intCast(bss_end)], 0);
            }
        }
    }
}

// -----------------------------------------------------------------------
// .rsrc Write Protection
// -----------------------------------------------------------------------

/// Protect the .rsrc section from guest buffer overflows.
/// Only .rsrc is protected — .rdata/.text must remain writable because
/// some CRT startup code writes to IAT slots and other "read-only" areas.
pub fn protectRsrc(
    sections: anytype,
    memory: *x86_memory.GuestMemory,
    preferred_base: u32,
    image_size: u32,
) void {
    for (sections) |sec| {
        if (std.mem.startsWith(u8, &sec.Name, ".rsrc")) {
            memory.pe_image_end = preferred_base +% image_size;
            const rsrc_start = preferred_base +% sec.VirtualAddress;
            const rsrc_end = rsrc_start +% sec.Misc.VirtualSize;
            if (rsrc_start > preferred_base)
                protectFatal(memory.addWritableSection(preferred_base, rsrc_start));
            if (rsrc_end < preferred_base +% image_size)
                protectFatal(memory.addWritableSection(rsrc_end, preferred_base +% image_size));
            break;
        }
    }
}

/// Dropping a writable section leaves the guest's writes to it silently
/// discarded, which reads as an unrelated misbehaviour much later. Two
/// sections always fit, so running out means the table is undersized.
fn protectFatal(ok: bool) void {
    if (!ok) log.fatal("PE write-protection table overflow ({d} entries)", .{x86_memory.MAX_WRITABLE_SECTIONS});
}

/// Allocate a guest thunk for a builtin export resolved at runtime (e.g. via
/// GetProcAddress).  Returns the guest VA of the thunk, or 0 on failure.
/// On native targets this is a no-op and returns the host address unchanged.
pub fn allocThunkForExport(exp: BuiltinExport, dll_name: []const u8, func_name: []const u8) usize {
    if (comptime !platform.is_wasm) {
        // Native: register for dispatch and return host addr directly
        x86_thunks.registerNativeImport(exp.addr, dll_name, func_name, exp.param_bytes);
        if (comptime platform.is_x86_64) {
            // On x86_64 compat mode, allocate an INT 0xFE stub in the low 4GB pool
            const compat_thunks = @import("../x86/compat_thunks.zig");
            const is_cdecl_rt = std.ascii.eqlIgnoreCase(dll_name, "MSVCRT.dll") or
                std.ascii.startsWithIgnoreCase(dll_name, "MSVCP");
            const thunk_id = x86_thunks.registerNativeThunkVA(func_name, exp.addr, exp.param_bytes, is_cdecl_rt, exp.va_fixed);
            if (compat_thunks.allocThunk(thunk_id)) |addr32| {
                return @as(usize, addr32);
            }
        }
        return exp.addr;
    }
    if (exp.is_data) return exp.addr;
    if (exp.thunk_handler) |handler| {
        const thunk_id = x86_thunks.registerThunk(.{
            .name = func_name,
            .param_count = null,
            .handler = handler,
        });
        if (thunk_memory) |mem| {
            return allocThunkCode(mem, thunk_id);
        }
    } else {
        const thunk_id = x86_thunks.registerNativeThunk(func_name, exp.addr, exp.param_bytes, false);
        if (thunk_memory) |mem| {
            return allocThunkCode(mem, thunk_id);
        }
    }
    return exp.addr; // fallback
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
    first_thunk: *align(1) u32,
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
    } else if (comptime platform.is_x86_64) {
        // On x86_64 compat mode: 64-bit stub addresses don't fit in 32-bit IAT slots.
        // Use compat_thunks to allocate INT 0xFE stubs in the low 4GB pool.
        const compat_thunks = @import("../x86/compat_thunks.zig");
        if (exp.is_data) {
            // Data export: copy into pool so guest has a <4GB address
            if (exp.addr <= 0xFFFFFFFF) {
                first_thunk.* = @truncate(exp.addr);
            } else if (exp.data_size > 0) {
                if (compat_thunks.allocData(@ptrFromInt(exp.addr), exp.data_size)) |addr32| {
                    first_thunk.* = addr32;
                } else {
                    first_thunk.* = @truncate(exp.addr);
                }
            } else {
                first_thunk.* = @truncate(exp.addr);
            }
            if (trace.enable_tracing) {
                trace.print("loader: {s} -> {s} at {X} (data compat)\n", .{ dll_name, func_name, first_thunk.* });
            }
        } else if (exp.is_native) {
            // Function export: register as a native thunk for signal dispatch.
            // Detect cdecl vs stdcall from the DLL name (MSVCRT/MSVCP use cdecl).
            const is_cdecl = std.ascii.eqlIgnoreCase(dll_name, "MSVCRT.dll") or
                std.ascii.startsWithIgnoreCase(dll_name, "MSVCP");
            const thunk_id = x86_thunks.registerNativeThunkVA(func_name, exp.addr, exp.param_bytes, is_cdecl, exp.va_fixed);
            if (compat_thunks.allocThunk(thunk_id)) |addr32| {
                first_thunk.* = addr32;
            } else {
                log.warn("compat: pool full for {s}::{s}", .{ dll_name, func_name });
                first_thunk.* = 0;
            }
            x86_thunks.registerNativeImport(exp.addr, dll_name, func_name, exp.param_bytes);
            if (trace.enable_tracing) {
                trace.print("loader: {s} -> {s} via compat thunk at {X} (native 0x{X})\n", .{ dll_name, func_name, first_thunk.*, exp.addr });
            }
        } else {
            // Guest PE export — already in low 4GB via MAP_32BIT
            first_thunk.* = @truncate(exp.addr);
            if (trace.enable_tracing) {
                trace.print("loader: {s} -> {s} at {X} (guest compat)\n", .{ dll_name, func_name, exp.addr });
            }
        }
    } else {
        // On native x86: write the address directly.
        first_thunk.* = @intCast(exp.addr);
        if (exp.is_native) {
            // Register for dispatchNativeCall
            x86_thunks.registerNativeImport(exp.addr, dll_name, func_name, exp.param_bytes);
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
/// thunk addresses (on WASM). Imports that resolve to nothing are registered
/// for diagnostics rather than aborting the load.
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
        if (@as(u64, import_desc_offset) + @sizeOf(pe.IMAGE_IMPORT_DESCRIPTOR) > mod.mapped_memory.len) {
            log.warn("loader: {s}: import descriptor table out of bounds at RVA 0x{X}, stopping", .{ mod.name, import_desc_offset });
            break;
        }
        const import_desc = @as(*align(1) pe.IMAGE_IMPORT_DESCRIPTOR, @ptrCast(&mod.mapped_memory[import_desc_offset]));
        if (import_desc.Name == 0) break;
        if (import_desc.Name >= mod.mapped_memory.len) {
            log.warn("loader: {s}: import DLL name RVA 0x{X} out of bounds, stopping", .{ mod.name, import_desc.Name });
            break;
        }

        const dll_name = mod.stringAt(import_desc.Name) orelse {
            log.warn("loader: {s}: unterminated import DLL name at RVA 0x{X}, stopping", .{ mod.name, import_desc.Name });
            break;
        };

        if (env.registry.loadModule(dll_name)) |loaded_mod| {
            log.info("Loaded dependency: {s}", .{loaded_mod.name});

            if (!loaded_mod.imports_resolved) {
                resolveImports(env, loaded_mod) catch |resolve_err| {
                    log.warn("loader: failed to resolve imports for {s}: {} — its exports will be stubs", .{ dll_name, resolve_err });
                };
            }

            // On WASM, copy DLL into GuestMemory AFTER its imports are resolved.
            // This way the guest copy has the final IAT values (thunk addresses).
            if (comptime platform.is_wasm) {
                copyModuleToGuest(loaded_mod);
            }
        } else |err| {
            if (err != error.FileNotFound and err != error.ModuleNotFound) return err;
        }

        const thunk_rva = if (import_desc.OriginalFirstThunk == 0) import_desc.FirstThunk else import_desc.OriginalFirstThunk;

        var thunk_offset: u32 = 0;
        while (true) : (thunk_offset += @sizeOf(u32)) {
            const orig_rva: u64 = @as(u64, thunk_rva) + thunk_offset;
            const iat_rva: u64 = @as(u64, import_desc.FirstThunk) + thunk_offset;
            if (orig_rva + @sizeOf(pe.IMAGE_THUNK_DATA32) > mod.mapped_memory.len or
                iat_rva + @sizeOf(u32) > mod.mapped_memory.len)
            {
                log.warn("loader: {s}: import thunk table for {s} out of bounds at offset {d}, stopping", .{ mod.name, dll_name, thunk_offset });
                break;
            }
            const orig_thunk = @as(*align(1) pe.IMAGE_THUNK_DATA32, @ptrCast(&mod.mapped_memory[@intCast(orig_rva)]));
            const first_thunk = @as(*align(1) u32, @ptrCast(&mod.mapped_memory[@intCast(iat_rva)]));

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
                if (orig_thunk.u1.AddressOfData + @sizeOf(pe.IMAGE_IMPORT_BY_NAME) >= mod.mapped_memory.len) {
                    log.warn("loader: {s}: import name RVA 0x{X} for {s} out of bounds, skipping", .{ mod.name, orig_thunk.u1.AddressOfData, dll_name });
                    first_thunk.* = 0;
                    continue;
                }
                const func_name = mod.stringAt(orig_thunk.u1.AddressOfData + @sizeOf(pe.IMAGE_IMPORT_BY_NAME)) orelse {
                    log.warn("loader: {s}: unterminated import name RVA 0x{X} for {s}, skipping", .{ mod.name, orig_thunk.u1.AddressOfData, dll_name });
                    first_thunk.* = 0;
                    continue;
                };

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

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;

const FakeParser = struct {
    nt: *const pe.IMAGE_NT_HEADERS32,
    pub fn getNtHeaders(self: *const FakeParser) *const pe.IMAGE_NT_HEADERS32 {
        return self.nt;
    }
};

fn makeNtHeaders() pe.IMAGE_NT_HEADERS32 {
    var nt = std.mem.zeroes(pe.IMAGE_NT_HEADERS32);
    nt.OptionalHeader.Magic = 0x10b;
    return nt;
}

test "applyReverseRelocations: patches HIGHLOW entries" {
    var nt = comptime makeNtHeaders();
    const parser = FakeParser{ .nt = &nt };

    // Image with one reloc block at RVA 0 patching the u32 at RVA 12.
    var buf = [_]u8{0} ** 16;
    std.mem.writeInt(u32, buf[0..4], 0, .little); // block VirtualAddress
    std.mem.writeInt(u32, buf[4..8], 10, .little); // block SizeOfBlock (1 entry)
    const entry: u16 = (3 << 12) | 0xC; // HIGHLOW, offset 12 -> patch RVA 12
    std.mem.writeInt(u16, buf[8..10], entry, .little);
    std.mem.writeInt(u32, buf[12..16], 0x0000_0001, .little);

    nt.OptionalHeader.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_BASERELOC] =
        .{ .VirtualAddress = 0, .Size = 10 };

    applyReverseRelocations(&buf, &parser, buf.len, 0x0001_0000, 0x0002_0000);

    // reverse_delta = preferred - actual = 0x10000
    try testing.expectEqual(@as(u32, 0x0001_0001), std.mem.readInt(u32, buf[12..16], .little));
}

test "applyReverseRelocations: reloc directory beyond image is clamped" {
    var nt = comptime makeNtHeaders();
    const parser = FakeParser{ .nt = &nt };
    nt.OptionalHeader.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_BASERELOC] =
        .{ .VirtualAddress = 0x1000, .Size = 0x100 }; // entirely past image_size

    var buf = [_]u8{0xAB} ** 64;
    // Must not read out of bounds or panic, and must not patch anything:
    // every byte stays untouched when the directory lies past the image.
    applyReverseRelocations(&buf, &parser, buf.len, 0x0001_0000, 0x0002_0000);
    for (buf) |byte| try testing.expectEqual(@as(u8, 0xAB), byte);
}

test "applyReverseRelocations: out-of-bounds HIGHLOW entry is skipped" {
    var nt = comptime makeNtHeaders();
    const parser = FakeParser{ .nt = &nt };

    // Reloc block claims an entry pointing past the end of the image.
    var buf = [_]u8{0} ** 16;
    std.mem.writeInt(u32, buf[0..4], 0, .little); // block VirtualAddress
    std.mem.writeInt(u32, buf[4..8], 10, .little); // block SizeOfBlock (1 entry)
    const entry: u16 = (3 << 12) | 0xFC; // patch RVA 252 — far beyond 16 bytes
    std.mem.writeInt(u16, buf[8..10], entry, .little);

    nt.OptionalHeader.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_BASERELOC] =
        .{ .VirtualAddress = 0, .Size = 10 };

    // The out-of-bounds patch address must be skipped without writing:
    // the image must come back byte-for-byte identical.
    const expected = buf;
    applyReverseRelocations(&buf, &parser, buf.len, 0x0001_0000, 0x0002_0000);
    try testing.expectEqualSlices(u8, &expected, &buf);
}
