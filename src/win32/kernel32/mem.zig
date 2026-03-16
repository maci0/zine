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
/// Implementation status: Partially implemented (On WASM uses guest heap; on native uses mmap).
pub fn VirtualAlloc(lpAddress: usize, dwSize: usize, flAllocationType: u32, flProtect: u32) callconv(w32cc.WINAPI) usize {
    _ = flProtect;
    if (trace.enable_tracing) trace.print("KERNEL32: VirtualAlloc(addr={x}, size={x}, type={x})\n", .{ lpAddress, dwSize, flAllocationType });

    const MEM_COMMIT = 0x1000;

    if (lpAddress != 0) {
        if ((flAllocationType & MEM_COMMIT) != 0) {
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
    const ptr = platform.mmap(@ptrFromInt(hint), dwSize, false, -1, 0, false, false) catch return 0;
    @memset(ptr, 0);

    if (trace.enable_tracing) trace.print("KERNEL32: VirtualAlloc -> {x}\n", .{@intFromPtr(ptr.ptr)});
    return @intFromPtr(ptr.ptr);
}

/// Releases, decommits, or releases and decommits a region of pages within the virtual address space of the calling process.
/// Implementation status: Stub.
pub fn VirtualFree(lpAddress: usize, dwSize: usize, dwFreeType: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwSize;
    _ = dwFreeType;
    if (trace.enable_tracing) trace.print("KERNEL32: VirtualFree(addr={x})\n", .{lpAddress});
    return 1;
}

/// Retrieves information about a range of pages in the virtual address space of the calling process.
/// Implementation status: Partially implemented (Returns hardcoded MEMORY_BASIC_INFORMATION).
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
/// Implementation status: Stub (Returns sentinel 0xDEADBEEF; allocation handled by shared allocator).
pub fn HeapCreate(flOptions: u32, dwInitialSize: usize, dwMaximumSize: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = flOptions;
    _ = dwInitialSize;
    _ = dwMaximumSize;
    // Sentinel value; all heap functions use raw_alloc regardless of handle.
    return @ptrFromInt(0xDEADBEEF);
}

/// Destroys the specified heap object.
/// Implementation status: Stub.
pub fn HeapDestroy(hHeap: ?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    return 1;
}

/// Retrieves a handle to the default heap of the calling process.
/// Implementation status: Stub (Returns sentinel 0xDEADC0DE).
pub fn GetProcessHeap() callconv(w32cc.WINAPI) ?*anyopaque {
    if (trace.enable_tracing) trace.print("KERNEL32: GetProcessHeap()\n", .{});
    return @ptrFromInt(0xDEADC0DE);
}

/// Allocates a block of memory from a heap.
/// Implementation status: Partially implemented (Uses shared raw_alloc).
pub fn HeapAlloc(hHeap: ?*anyopaque, dwFlags: u32, dwBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hHeap;
    _ = dwFlags;
    return raw_alloc(dwBytes);
}

/// Reallocates a block of memory from a heap.
/// Implementation status: Partially implemented (Uses shared raw_realloc).
pub fn HeapReAlloc(hHeap: ?*anyopaque, dwFlags: u32, lpMem: ?*anyopaque, dwBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hHeap;
    _ = dwFlags;
    return raw_realloc(lpMem, dwBytes);
}

/// Frees a memory block allocated from a heap.
/// Implementation status: Stub.
pub fn HeapFree(hHeap: ?*anyopaque, dwFlags: u32, lpMem: ?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    _ = dwFlags;
    _ = lpMem;
    return 1;
}

/// Allocates the specified number of bytes from the local heap.
/// Implementation status: Partially implemented (Uses shared raw_alloc).
pub fn LocalAlloc(uFlags: u32, uBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = uFlags;
    return raw_alloc(uBytes);
}

/// Frees the specified local memory object and invalidates its handle.
/// Implementation status: Stub.
pub fn LocalFree(hMem: ?*anyopaque) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hMem;
    return null;
}

/// Locks a local memory object and returns a pointer to the first byte.
/// Implementation status: Stub (Returns handle; assumes LMEM_FIXED).
pub fn LocalLock(hMem: usize) callconv(w32cc.WINAPI) usize {
    // For LMEM_FIXED, the handle IS the pointer
    return hMem;
}

/// Decrements the lock count associated with a memory object.
/// Implementation status: Stub.
pub fn LocalUnlock(hMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMem;
    return 0;
}

/// Retrieves the current size of the specified local memory object.
/// Implementation status: Partially implemented (Reads size from shared allocator header).
pub fn LocalSize(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (hMem == 0) return 0;
    // raw_alloc stores size in the 8 bytes before the returned pointer
    const header = @as(*const usize, @ptrFromInt(hMem - 8));
    return header.*;
}

/// Changes the size or the attributes of a specified local memory object.
/// Implementation status: Partially implemented (Uses shared raw_realloc).
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
/// Implementation status: Partially implemented (Returns hardcoded MEMORYSTATUS).
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
/// Implementation status: Partially implemented (Uses shared raw_alloc).
pub fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(w32cc.WINAPI) usize {
    _ = uFlags;
    const ret_addr = @returnAddress();
    const ptr = raw_alloc(dwBytes) orelse return 0;
    if (trace.enable_tracing) trace.print("KERNEL32: GlobalAlloc(size={d}) = {x} (from {x})\n", .{ dwBytes, @intFromPtr(ptr), ret_addr });
    return @intFromPtr(ptr);
}

/// Frees the specified global memory object and invalidates its handle.
/// Implementation status: Stub.
pub fn GlobalFree(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GlobalFree({x})\n", .{hMem});
    return 0; // Success
}

/// Locks a global memory object and returns a pointer to the first byte.
/// Implementation status: Stub (Returns handle; assumes GMEM_FIXED).
pub fn GlobalLock(hMem: usize) callconv(w32cc.WINAPI) usize {
    // For GMEM_FIXED, the handle IS the pointer
    return hMem;
}

/// Decrements the lock count associated with a memory object.
/// Implementation status: Stub.
pub fn GlobalUnlock(hMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMem;
    return 0;
}

/// Retrieves the current size of the specified global memory object.
/// Implementation status: Partially implemented (Reads size from shared allocator header).
pub fn GlobalSize(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (hMem == 0) return 0;
    // raw_alloc stores size in the 8 bytes before the returned pointer
    const header = @as(*const usize, @ptrFromInt(hMem - 8));
    return header.*;
}

/// Changes the size or attributes of a specified global memory object.
/// Implementation status: Partially implemented (Uses shared raw_realloc).
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
/// Implementation status: Stub (Pretends old protection was PAGE_READWRITE).
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
/// Implementation status: Stub (Returns pointer; assumes GMEM_FIXED).
pub fn GlobalHandle(pMem: usize) callconv(w32cc.WINAPI) usize {
    // For GMEM_FIXED allocations (which we always use), the handle IS the pointer
    return pMem;
}
