//! KERNEL32 memory management functions.

const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const x86_memory = @import("../../x86/memory.zig");
pub const stub_common = @import("../shared.zig");

/// Access the shared guest memory global.
/// Implementation status: Fully implemented
pub inline fn guest_memory() ?*x86_memory.GuestMemory {
    return stub_common.guest_memory;
}

// Re-export shared allocator functions from stub_common.
pub const raw_alloc = stub_common.raw_alloc;
pub const raw_realloc = stub_common.raw_realloc;
pub const get_aligned_hint = stub_common.get_aligned_hint;

/// Reserves, commits, or changes the state of a region of pages in the virtual address space of the calling process.
/// Implementation status: Partially implemented (On WASM uses guest heap; on native uses mmap)
pub fn VirtualAlloc(lpAddress: usize, dwSize: usize, flAllocationType: u32, flProtect: u32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: VirtualAlloc(addr={x}, size={x}, type={x}, prot={x})\n", .{ lpAddress, dwSize, flAllocationType, flProtect });

    const MEM_COMMIT = 0x1000;
    // PAGE_EXECUTE_* protections need executable memory mapping
    const needs_exec = (flProtect & 0xF0) != 0; // PAGE_EXECUTE (0x10), PAGE_EXECUTE_READ (0x20), PAGE_EXECUTE_READWRITE (0x40)

    if (lpAddress != 0) {
        if ((flAllocationType & MEM_COMMIT) != 0) {
            // Committing pages at an existing address — apply the requested protection.
            // MEM_RESERVE maps with PROT_NONE; MEM_COMMIT must enable read/write/exec.
            const platform = @import("../../platform.zig");
            const writable = (flProtect & 0x04) != 0 or (flProtect & 0x08) != 0 or
                (flProtect & 0x40) != 0 or (flProtect & 0x80) != 0;
            if (writable or needs_exec) {
                platform.mprotect(lpAddress, dwSize, true, writable, needs_exec);
            }
            return lpAddress;
        }
    }

    if (dwSize == 0) return 0;

    // On WASM: use guest heap allocator
    if (guest_memory()) |gmem| {
        const alloc_size: u32 = @intCast(@min(dwSize, 0xFFFFFFFF));
        const addr = gmem.guestAlloc(alloc_size);
        if (trace.enable_tracing) trace.print("KERNEL32: VirtualAlloc -> {x}\n", .{addr});
        return addr;
    }

    const platform = @import("../../platform.zig");
    const hint = get_aligned_hint(dwSize);

    const MEM_RESERVE = 0x2000;
    const is_reserve_only = (flAllocationType & MEM_RESERVE) != 0 and (flAllocationType & MEM_COMMIT) == 0;

    if (is_reserve_only) {
        // MEM_RESERVE without MEM_COMMIT: allocate the region as RW.
        // Windows would use PROT_NONE but that breaks apps that don't properly
        // commit pages (their writes fault). Using RW is safer for compatibility.
        const ptr = platform.mmap(@ptrFromInt(hint), dwSize, false, -1, 0, false, false) catch return 0;
        @memset(ptr, 0);
        if (trace.enable_tracing) trace.print("KERNEL32: VirtualAlloc -> {x} (reserved)\n", .{@intFromPtr(ptr.ptr)});
        return @intFromPtr(ptr.ptr);
    }

    // Allocate with extra padding — apps like Delphi's MakeObjectInstance
    // fill pages with trampoline stubs and may read metadata past the page
    // boundary into the next page. Providing an extra page prevents faults.
    const alloc_size = @max(dwSize, 0x2000); // at least 8KB
    const ptr = platform.mmap(@ptrFromInt(hint), alloc_size, needs_exec, -1, 0, false, false) catch return 0;
    @memset(ptr, 0);

    if (trace.enable_tracing) trace.print("KERNEL32: VirtualAlloc -> {x}\n", .{@intFromPtr(ptr.ptr)});
    return @intFromPtr(ptr.ptr);
}

/// Releases, decommits, or releases and decommits a region of pages within the virtual address space of the calling process.
/// Implementation status: Stub
pub fn VirtualFree(lpAddress: usize, dwSize: usize, dwFreeType: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: VirtualFree(addr={x}, size={x}, type={x})\n", .{ lpAddress, dwSize, dwFreeType });

    const MEM_DECOMMIT: u32 = 0x4000;
    const MEM_RELEASE: u32 = 0x8000;

    if (lpAddress == 0) return 0;

    if ((dwFreeType & MEM_DECOMMIT) != 0 and dwSize > 0) {
        // MEM_DECOMMIT: zero the pages to prevent stale data from being
        // reused when the region is recommitted. Delphi's FastMM relies on
        // decommitted pages being zeroed when recommitted.
        const page_start = lpAddress & ~@as(usize, 0xFFF);
        const aligned_size = (dwSize + 0xFFF) & ~@as(usize, 0xFFF);
        const ptr = @as([*]u8, @ptrFromInt(page_start));
        @memset(ptr[0..aligned_size], 0);
    } else if ((dwFreeType & MEM_RELEASE) != 0) {
        // MEM_RELEASE: zero the region. We can't easily munmap because
        // we don't track allocation sizes, but zeroing prevents stale data.
        if (dwSize > 0) {
            const ptr = @as([*]u8, @ptrFromInt(lpAddress));
            @memset(ptr[0..dwSize], 0);
        }
    }

    return 1;
}

/// Retrieves information about a range of pages in the virtual address space of the calling process.
/// Implementation status: Partially implemented (Returns hardcoded MEMORY_BASIC_INFORMATION)
pub fn VirtualQuery(lpAddress: usize, lpBuffer_ptr: usize, dwLength: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: VirtualQuery(addr={x})\n", .{lpAddress});

    if (lpBuffer_ptr != 0 and dwLength >= 28) {
        const mbi = @as(*w32.MEMORY_BASIC_INFORMATION, @ptrFromInt(lpBuffer_ptr));
        mbi.BaseAddress = @intCast(lpAddress & ~@as(usize, 0xFFF));
        mbi.AllocationBase = @intCast(lpAddress & ~@as(usize, 0xFFF));
        mbi.AllocationProtect = w32.PAGE_READWRITE;
        mbi.RegionSize = 4096;
        mbi.State = w32.MEM_COMMIT;
        mbi.Protect = w32.PAGE_READWRITE;
        mbi.Type = w32.MEM_MAPPED;
        return 28;
    }
    return 0;
}

/// Creates a private heap object that can be used by the calling process.
/// Implementation status: Stub (Returns sentinel 0xDEADBEEF; allocation handled by shared allocator)
pub fn HeapCreate(flOptions: u32, dwInitialSize: usize, dwMaximumSize: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = flOptions;
    _ = dwInitialSize;
    _ = dwMaximumSize;
    // Sentinel value; HeapAlloc uses win32HeapAlloc regardless of handle.
    return @ptrFromInt(0xDEADBEEF);
}

/// Destroys the specified heap object.
/// Implementation status: Stub
pub fn HeapDestroy(hHeap: ?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    return 1;
}

/// Retrieves a handle to the default heap of the calling process.
/// Implementation status: Stub (Returns sentinel 0xDEADC0DE)
pub fn GetProcessHeap() callconv(w32cc.WINAPI) ?*anyopaque {
    if (trace.enable_tracing) trace.print("KERNEL32: GetProcessHeap()\n", .{});
    return @ptrFromInt(0xDEADC0DE);
}

/// Allocates a block of memory from a heap.
/// Implementation status: Partially implemented (Uses VirtualAlloc-backed win32HeapAlloc)
pub fn HeapAlloc(hHeap: ?*anyopaque, dwFlags: u32, dwBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hHeap;
    const result = win32HeapAlloc(dwBytes, (dwFlags & 0x08) != 0); // HEAP_ZERO_MEMORY
    if (trace.enable_tracing) trace.print("KERNEL32: HeapAlloc(size={d}) -> {x}\n", .{ dwBytes, if (result) |p| @intFromPtr(p) else 0 });
    return result;
}

/// Allocate from a VirtualAlloc-backed heap, separate from the zine internal
/// heap. This prevents Delphi's FastMM from confusing LocalAlloc/HeapAlloc
/// memory with its own VirtualAlloc pools.
var win32_heap_base: ?[*]u8 = null;
var win32_heap_pos: usize = 0;
var win32_heap_cap: usize = 0;

fn win32HeapAlloc(size: usize, zero: bool) ?*anyopaque {
    const actual = if (size == 0) @as(usize, 16) else size;
    const aligned = (actual + 15) & ~@as(usize, 15); // 16-byte align
    const total = aligned + 16; // 16 bytes header (size + padding)

    if (win32_heap_base == null or win32_heap_pos + total > win32_heap_cap) {
        // Allocate a new chunk via VirtualAlloc (MEM_COMMIT | MEM_RESERVE)
        // Uses the guest VirtualAlloc hint range so addresses are in the
        // same space as VirtualAlloc'd memory (expected by FastMM).
        const chunk = @max(total + 4096, 256 * 1024); // at least 256KB
        const hint = stub_common.get_aligned_hint(chunk);
        const platform = @import("../../platform.zig");
        const mem = platform.mmap(@ptrFromInt(hint), chunk, false, -1, 0, false, false) catch return null;
        @memset(mem, 0);
        win32_heap_base = mem.ptr;
        win32_heap_pos = 0;
        win32_heap_cap = chunk;
    }

    const ptr = win32_heap_base.? + win32_heap_pos;
    const header = @as(*usize, @ptrCast(@alignCast(ptr)));
    header.* = actual;
    win32_heap_pos += total;
    const result = ptr + 16;
    if (!zero) {
        // Don't zero — already zeroed from mmap
    }
    return @ptrCast(result);
}

/// Reallocates a block of memory from a heap.
/// Implementation status: Partially implemented (Uses shared raw_realloc)
pub fn HeapReAlloc(hHeap: ?*anyopaque, dwFlags: u32, lpMem: ?*anyopaque, dwBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hHeap;
    _ = dwFlags;
    return raw_realloc(lpMem, dwBytes);
}

/// Frees a memory block allocated from a heap.
/// Implementation status: Stub
pub fn HeapFree(hHeap: ?*anyopaque, dwFlags: u32, lpMem: ?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    _ = dwFlags;
    _ = lpMem;
    return 1;
}

/// Allocates the specified number of bytes from the local heap.
/// Implementation status: Partially implemented (Uses VirtualAlloc-backed win32HeapAlloc)
pub fn LocalAlloc(uFlags: u32, uBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    const result = win32HeapAlloc(uBytes, (uFlags & 0x40) != 0); // LMEM_ZEROINIT
    if (trace.enable_tracing) trace.print("KERNEL32: LocalAlloc(size={d}) -> {x}\n", .{ uBytes, if (result) |p| @intFromPtr(p) else 0 });
    return result;
}

/// Frees the specified local memory object and invalidates its handle.
/// Implementation status: Stub
pub fn LocalFree(hMem: ?*anyopaque) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hMem;
    return null;
}

/// Locks a local memory object and returns a pointer to the first byte.
/// Implementation status: Stub (Returns handle; assumes LMEM_FIXED)
pub fn LocalLock(hMem: usize) callconv(w32cc.WINAPI) usize {
    // For LMEM_FIXED, the handle IS the pointer
    return hMem;
}

/// Decrements the lock count associated with a memory object.
/// Implementation status: Stub
pub fn LocalUnlock(hMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMem;
    return 0;
}

/// Retrieves the current size of the specified local memory object.
/// Implementation status: Partially implemented (Reads size from win32HeapAlloc header)
pub fn LocalSize(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (hMem == 0) return 0;
    // win32HeapAlloc stores size in the first 8 bytes of a 16-byte header
    const header = @as(*const usize, @ptrFromInt(hMem - 16));
    return header.*;
}

/// Changes the size or the attributes of a specified local memory object.
/// Implementation status: Partially implemented (Uses shared raw_realloc)
pub fn LocalReAlloc(hMem: usize, uBytes: usize, uFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = uFlags;
    if (hMem == 0) {
        const ptr = raw_alloc(uBytes) orelse return 0;
        return @intFromPtr(ptr);
    }
    const ptr = raw_realloc(@ptrFromInt(hMem), uBytes) orelse return 0;
    return @intFromPtr(ptr);
}

/// Retrieves information about the system's current usage of both physical and virtual memory.
/// Implementation status: Partially implemented (Returns hardcoded MEMORYSTATUS)
pub fn GlobalMemoryStatus(lpBuffer: usize) callconv(w32cc.WINAPI) void {
    if (lpBuffer != 0) {
        const status = @as(*w32.MEMORYSTATUS, @ptrFromInt(lpBuffer));
        status.* = .{
            .dwMemoryLoad = 50,
            .dwTotalPhys = 1024 * 1024 * 1024,
            .dwAvailPhys = 512 * 1024 * 1024,
            .dwTotalPageFile = 1024 * 1024 * 1024,
            .dwAvailPageFile = 512 * 1024 * 1024,
            .dwTotalVirtual = 2048 * 1024 * 1024,
            .dwAvailVirtual = 1024 * 1024 * 1024,
        };
    }
}

/// Allocates the specified number of bytes from the global heap.
/// Implementation status: Partially implemented (Uses shared raw_alloc)
pub fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(w32cc.WINAPI) usize {
    _ = uFlags;
    const ret_addr = @returnAddress();
    const ptr = raw_alloc(dwBytes) orelse return 0;
    if (trace.enable_tracing) trace.print("KERNEL32: GlobalAlloc(size={d}) = {x} (from {x})\n", .{ dwBytes, @intFromPtr(ptr), ret_addr });
    return @intFromPtr(ptr);
}

/// Frees the specified global memory object and invalidates its handle.
/// Implementation status: Stub
pub fn GlobalFree(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GlobalFree({x})\n", .{hMem});
    return 0; // Success
}

/// Locks a global memory object and returns a pointer to the first byte.
/// Implementation status: Stub (Returns handle; assumes GMEM_FIXED)
pub fn GlobalLock(hMem: usize) callconv(w32cc.WINAPI) usize {
    // For GMEM_FIXED, the handle IS the pointer
    return hMem;
}

/// Decrements the lock count associated with a memory object.
/// Implementation status: Stub
pub fn GlobalUnlock(hMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMem;
    return 0;
}

/// Retrieves the current size of the specified global memory object.
/// Implementation status: Partially implemented (Reads size from shared allocator header)
pub fn GlobalSize(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (hMem == 0) return 0;
    // raw_alloc stores size in the 8 bytes before the returned pointer
    const header = @as(*const usize, @ptrFromInt(hMem - 8));
    return header.*;
}

/// Changes the size or attributes of a specified global memory object.
/// Implementation status: Partially implemented (Uses shared raw_realloc)
pub fn GlobalReAlloc(hMem: usize, dwBytes: usize, uFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = uFlags;
    if (hMem == 0) {
        const ptr = raw_alloc(dwBytes) orelse return 0;
        return @intFromPtr(ptr);
    }
    const ptr = raw_realloc(@ptrFromInt(hMem), dwBytes) orelse return 0;
    return @intFromPtr(ptr);
}

/// Changes the protection on a region of committed pages.
/// Implementation status: Stub (Pretends old protection was PAGE_READWRITE)
pub fn VirtualProtect(lpAddress: usize, dwSize: usize, flNewProtect: u32, lpflOldProtect: usize) callconv(w32cc.WINAPI) i32 {
    _ = dwSize;
    if (trace.enable_tracing) trace.print("KERNEL32: VirtualProtect(addr={x}, prot={x})\n", .{ lpAddress, flNewProtect });
    // Write old protection value (pretend everything was PAGE_READWRITE)
    if (lpflOldProtect != 0) {
        @as(*u32, @ptrFromInt(lpflOldProtect)).* = w32.PAGE_READWRITE;
    }
    return 1; // TRUE
}

/// Retrieves the handle associated with the specified pointer to a global memory block.
/// Implementation status: Stub (Returns pointer; assumes GMEM_FIXED)
pub fn GlobalHandle(pMem: usize) callconv(w32cc.WINAPI) usize {
    // For GMEM_FIXED allocations (which we always use), the handle IS the pointer
    return pMem;
}
