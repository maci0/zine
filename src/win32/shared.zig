//! Shared Win32 API stubs and memory management utilities.
//!
//! This module provides common functionality used across multiple Win32 DLL
//! implementations, including a shared guest heap allocator and generic
//! no-op stubs for unimplemented APIs.

const std = @import("std");
const trace = @import("../trace.zig");

/// Generic stub functions for unimplemented Win32 APIs.
/// These are variadic no-op stubs that accept N arguments and return 0.
/// Used as placeholders in DLL export tables when a function hasn't been
/// implemented yet but needs a valid entry point.
const w32cc = @import("calling_convention.zig");
const x86_memory = @import("../x86/memory.zig");

/// Spawn handler for WASM mode. Set by wasm_main.zig.
/// Called by _spawnvp to load and execute a child PE in-process.
/// Args: (exe_path, argv_ptr) → exit code, or null if not supported.
pub var spawn_handler: ?*const fn ([]const u8, usize) i32 = null;

/// When non-null, ExitProcess stores the code here instead of calling
/// std.process.exit. Used by the WASM spawn handler so a child PE's
/// ExitProcess doesn't kill the entire WASM process.
pub var child_exit_code: ?*i32 = null;

/// When non-null, points to the CPU that should be halted when
/// ExitProcess/exit is called in child-process mode.
pub var child_cpu: ?*@import("../x86/cpu.zig").Cpu = null;

/// Shared guest memory reference. Set by wasm_main.zig at startup.
/// When non-null, stubs use guest-heap allocation so addresses stay
/// within the GuestMemory range.  All DLL stubs access this through
/// stub_common instead of reaching into kernel32/mem.zig.
pub var guest_memory: ?*x86_memory.GuestMemory = null;

const heap_chunk_size: usize = 16 * 1024 * 1024; // 16 MB per chunk
var heap_base: ?[*]u8 = null;
var heap_pos: usize = 0;
var heap_cap: usize = 0;

// Guest VirtualAlloc allocations use a separate address range from the
// zine internal heap to prevent Delphi's FastMM from confusing them.
var next_alloc_hint: usize = 0x20000000;

/// Returns a 64KB aligned memory address hint for allocations.
///
/// Used by both MSVCRT (malloc, strdup, getenv) and kernel32 (HeapAlloc,
/// GlobalAlloc, VirtualAlloc) stubs. On WASM, all allocations go through
/// the guest heap bump allocator; on native x86-64, we pre-allocate large
/// chunks at low addresses so guest 32-bit code can address them.
///
/// Keeps a rolling hint for 64KB aligned allocations to satisfy Windows memory assumptions.
/// Implementation status: Partially implemented
pub fn get_aligned_hint(size: usize) usize {
    const hint = next_alloc_hint;
    const aligned_size = (size + 0xFFFF) & ~@as(usize, 0xFFFF);
    next_alloc_hint += aligned_size;
    return hint;
}

// Internal heap uses a separate address range (0x50000000+) to avoid
// being adjacent to guest VirtualAlloc regions (0x61000000+).
var internal_heap_hint: usize = 0x50000000;

fn heapAlloc(size: usize) ?[*]u8 {
    const aligned = (size + 7) & ~@as(usize, 7); // 8-byte align
    if (heap_base == null or heap_pos + aligned > heap_cap) {
        const plt = @import("../platform.zig");
        const chunk_size = @max(aligned + 4096, heap_chunk_size);
        const hint = internal_heap_hint;
        internal_heap_hint += (chunk_size + 0xFFFF) & ~@as(usize, 0xFFFF);
        const mem = plt.mmap(@ptrFromInt(hint), chunk_size, false, -1, 0, false, false) catch return null;
        @memset(mem, 0);
        heap_base = mem.ptr;
        heap_pos = 0;
        heap_cap = chunk_size;
    }
    const ptr = heap_base.? + heap_pos;
    heap_pos += aligned;
    return ptr;
}

/// Allocates memory from the shared guest heap.
///
/// On WASM, it uses the guest heap allocator to keep addresses in range and
/// returns a guest virtual address. On native, it bump-allocates from a
/// low-address heap.
///
/// Implementation status: Partially implemented
pub fn raw_alloc(size: usize) ?*anyopaque {
    const actual_size = if (size == 0) @as(usize, 64) else size;

    // On WASM: use guest heap allocator to keep addresses in range.
    // Return a guest virtual address (not a host pointer) so the x86
    // interpreter's address translation works correctly.
    if (guest_memory) |gmem| {
        const alloc_size: u32 = @intCast(@min(actual_size + 16, 0xFFFFFFFF));
        const addr = gmem.guestAlloc(alloc_size);
        if (addr == 0) return null;
        gmem.write32(addr, @intCast(actual_size));
        gmem.write32(addr +% 4, 0);
        return @ptrFromInt(addr +% 8);
    }

    // Native: bump-allocate from low-address heap
    const total = actual_size + 8;
    const ptr = heapAlloc(total) orelse return null;
    const header = @as(*usize, @ptrCast(@alignCast(ptr)));
    header.* = actual_size;
    return @ptrCast(ptr + 8);
}

/// Reallocates memory from the shared guest heap.
///
/// If `old_ptr` is null, this is equivalent to `raw_alloc`.
///
/// Implementation status: Partially implemented
pub fn raw_realloc(old_ptr: ?*anyopaque, new_size: usize) ?*anyopaque {
    if (new_size == 0) return null;
    if (old_ptr == null) return raw_alloc(new_size);

    // On WASM with guest heap: alloc + copy via guest memory (we don't free).
    // Pointers are guest virtual addresses, not host pointers.
    if (guest_memory) |gmem| {
        const old_guest_va = @as(u32, @truncate(@intFromPtr(old_ptr.?)));
        const old_size = gmem.read32(old_guest_va -% 8);

        const new_mem = raw_alloc(new_size) orelse return null;
        const new_guest_va = @as(u32, @truncate(@intFromPtr(new_mem)));
        const copy_len = @min(old_size, @as(u32, @intCast(@min(new_size, 0xFFFFFFFF))));

        // Copy data through guest memory translation
        const old_offset = old_guest_va -% gmem.base_addr;
        const new_offset = new_guest_va -% gmem.base_addr;
        if (old_offset + copy_len <= gmem.base.len and new_offset + copy_len <= gmem.base.len) {
            const src = gmem.base[old_offset..][0..copy_len];
            const dst = gmem.base[new_offset..][0..copy_len];
            @memcpy(dst, src);
        }
        return new_mem;
    }

    const old_u8_ptr = @as([*]u8, @ptrCast(old_ptr.?)) - 8;
    const old_header = @as(*usize, @ptrCast(@alignCast(old_u8_ptr)));
    const old_size = old_header.*;

    const new_mem = heapAlloc(new_size + 8) orelse return null;
    const new_header = @as(*usize, @ptrCast(@alignCast(new_mem)));
    new_header.* = new_size;

    const copy_len = @min(old_size, new_size);
    const old_data = @as([*]u8, @ptrCast(old_ptr.?));
    const new_data = new_mem + 8;
    @memcpy(new_data[0..copy_len], old_data[0..copy_len]);

    return @ptrCast(new_data);
}



/// Shared tracing logic for all stubs. Must be `inline` so that
/// `@returnAddress()` resolves to the caller of the stub, not this helper.
inline fn traceStub(comptime n: comptime_int) void {
    if (trace.enable_tracing) {
        const x86_thunks = @import("../x86/thunks.zig");
        const ret_addr = @returnAddress();
        const label = "generic " ++ std.fmt.comptimePrint("stub{d}", .{n});
        if (x86_thunks.lookupUnresolvedName(ret_addr)) |name| {
            trace.print(label ++ " [{s}] called from {x}\n", .{ name, ret_addr });
        } else {
            // Try to read the call instruction before the return address
            // to find the IAT target (FF 15 xx xx xx xx = call [iat_addr])
            const ret_ptr: [*]const u8 = @ptrFromInt(ret_addr);
            const call_site = ret_ptr - 6; // FF 15 + 4 bytes
            if (call_site[0] == 0xFF and call_site[1] == 0x15) {
                const iat_addr = @as(*align(1) const u32, @ptrCast(call_site + 2)).*;
                // Read the function pointer from the IAT
                const func_ptr = @as(*align(1) const u32, @ptrFromInt(iat_addr)).*;
                // Try to find unresolved name from the IAT address
                if (x86_thunks.lookupUnresolvedName(iat_addr)) |name| {
                    trace.print(label ++ " [{s}] called from {x} (IAT=0x{x} -> 0x{x})\n", .{ name, ret_addr, iat_addr, func_ptr });
                } else {
                    trace.print(label ++ " called from {x} (IAT=0x{x} -> 0x{x})\n", .{ ret_addr, iat_addr, func_ptr });
                }
            } else {
                trace.print(label ++ " called from {x}\n", .{ret_addr});
            }
        }
    }
}

/// No-op stub taking 0 arguments.
/// Implementation status: No-op fallback
pub fn stub_args0() callconv(w32cc.WINAPI) usize {
    traceStub(0);
    return 0;
}

/// No-op stub taking 1 argument.
/// Implementation status: No-op fallback
pub fn stub_args1(a: usize) callconv(w32cc.WINAPI) u32 {
    _ = a;
    traceStub(1);
    return 0;
}

/// No-op stub taking 2 arguments.
/// Implementation status: No-op fallback
pub fn stub_args2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b };
    traceStub(2);
    return 0;
}

/// No-op stub taking 3 arguments.
/// Implementation status: No-op fallback
pub fn stub_args3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c };
    traceStub(3);
    return 0;
}

/// No-op stub taking 4 arguments.
/// Implementation status: No-op fallback
pub fn stub_args4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d };
    traceStub(4);
    return 0;
}

/// No-op stub taking 5 arguments.
/// Implementation status: No-op fallback
pub fn stub_args5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e };
    traceStub(5);
    return 0;
}

/// No-op stub taking 6 arguments.
/// Implementation status: No-op fallback
pub fn stub_args6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f };
    traceStub(6);
    return 0;
}

/// No-op stub taking 7 arguments.
/// Implementation status: No-op fallback
pub fn stub_args7(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f, g };
    traceStub(7);
    return 0;
}

/// No-op stub taking 8 arguments.
/// Implementation status: No-op fallback
pub fn stub_args8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f, g, h };
    traceStub(8);
    return 0;
}

/// No-op stub taking 9 arguments.
/// Implementation status: No-op fallback
pub fn stub_args9(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f, g, h, i };
    traceStub(9);
    return 0;
}

/// No-op stub taking 10 arguments.
/// Implementation status: No-op fallback
pub fn stub_args10(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize, j: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f, g, h, i, j };
    traceStub(10);
    return 0;
}
