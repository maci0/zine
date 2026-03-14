const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");
const x86_memory = @import("../../x86/memory.zig");
pub const stub_common = @import("../stub_common.zig");

/// Access the shared guest memory global from stub_common.
pub inline fn guest_memory() ?*x86_memory.GuestMemory {
    return stub_common.guest_memory;
}

// Re-export shared allocator functions from stub_common.
// These were moved out of kernel32/mem.zig because both MSVCRT and
// kernel32 stubs use them — keeping them here was a boundary violation.
pub const raw_alloc = stub_common.raw_alloc;
pub const raw_realloc = stub_common.raw_realloc;
pub const get_aligned_hint = stub_common.get_aligned_hint;

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

pub fn VirtualFree(lpAddress: usize, dwSize: usize, dwFreeType: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwSize;
    _ = dwFreeType;
    if (trace.enable_tracing) trace.print("KERNEL32: VirtualFree(addr={x})\n", .{lpAddress});
    return 1;
}

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

pub fn HeapCreate(flOptions: u32, dwInitialSize: usize, dwMaximumSize: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = flOptions;
    _ = dwInitialSize;
    _ = dwMaximumSize;
    // Sentinel value; all heap functions use raw_alloc regardless of handle.
    return @ptrFromInt(0xDEADBEEF);
}

pub fn HeapDestroy(hHeap: ?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    return 1;
}

pub fn GetProcessHeap() callconv(w32cc.WINAPI) ?*anyopaque {
    if (trace.enable_tracing) trace.print("KERNEL32: GetProcessHeap()\n", .{});
    return @ptrFromInt(0xDEADC0DE);
}

pub fn HeapAlloc(hHeap: ?*anyopaque, dwFlags: u32, dwBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hHeap;
    _ = dwFlags;
    return raw_alloc(dwBytes);
}

pub fn HeapReAlloc(hHeap: ?*anyopaque, dwFlags: u32, lpMem: ?*anyopaque, dwBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hHeap;
    _ = dwFlags;
    return raw_realloc(lpMem, dwBytes);
}

pub fn HeapFree(hHeap: ?*anyopaque, dwFlags: u32, lpMem: ?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    _ = dwFlags;
    _ = lpMem;
    return 1;
}

pub fn LocalAlloc(uFlags: u32, uBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = uFlags;
    return raw_alloc(uBytes);
}

pub fn LocalFree(hMem: ?*anyopaque) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hMem;
    return null;
}

pub fn LocalLock(hMem: usize) callconv(w32cc.WINAPI) usize {
    // For LMEM_FIXED, the handle IS the pointer
    return hMem;
}

pub fn LocalUnlock(hMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMem;
    return 0;
}

pub fn LocalSize(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (hMem == 0) return 0;
    // raw_alloc stores size in the 8 bytes before the returned pointer
    const header = @as(*const usize, @ptrFromInt(hMem - 8));
    return header.*;
}

pub fn LocalReAlloc(hMem: usize, uBytes: usize, uFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = uFlags;
    if (hMem == 0) {
        const ptr = raw_alloc(uBytes) orelse return 0;
        return @intFromPtr(ptr);
    }
    const ptr = raw_realloc(@ptrFromInt(hMem), uBytes) orelse return 0;
    return @intFromPtr(ptr);
}

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

pub fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(w32cc.WINAPI) usize {
    _ = uFlags;
    const ret_addr = @returnAddress();
    const ptr = raw_alloc(dwBytes) orelse return 0;
    if (trace.enable_tracing) trace.print("KERNEL32: GlobalAlloc(size={d}) = {x} (from {x})\n", .{ dwBytes, @intFromPtr(ptr), ret_addr });
    return @intFromPtr(ptr);
}

pub fn GlobalFree(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GlobalFree({x})\n", .{hMem});
    return 0; // Success
}

pub fn GlobalLock(hMem: usize) callconv(w32cc.WINAPI) usize {
    // For GMEM_FIXED, the handle IS the pointer
    return hMem;
}

pub fn GlobalUnlock(hMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMem;
    return 0;
}

pub fn GlobalSize(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (hMem == 0) return 0;
    // raw_alloc stores size in the 8 bytes before the returned pointer
    const header = @as(*const usize, @ptrFromInt(hMem - 8));
    return header.*;
}

pub fn GlobalReAlloc(hMem: usize, dwBytes: usize, uFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = uFlags;
    if (hMem == 0) {
        const ptr = raw_alloc(dwBytes) orelse return 0;
        return @intFromPtr(ptr);
    }
    const ptr = raw_realloc(@ptrFromInt(hMem), dwBytes) orelse return 0;
    return @intFromPtr(ptr);
}

pub fn VirtualProtect(lpAddress: usize, dwSize: usize, flNewProtect: u32, lpflOldProtect: usize) callconv(w32cc.WINAPI) i32 {
    _ = dwSize;
    if (trace.enable_tracing) trace.print("KERNEL32: VirtualProtect(addr={x}, prot={x})\n", .{ lpAddress, flNewProtect });
    // Write old protection value (pretend everything was PAGE_READWRITE)
    if (lpflOldProtect != 0) {
        @as(*u32, @ptrFromInt(lpflOldProtect)).* = w32.PAGE_READWRITE;
    }
    return 1; // TRUE
}

pub fn GlobalHandle(pMem: usize) callconv(w32cc.WINAPI) usize {
    // For GMEM_FIXED allocations (which we always use), the handle IS the pointer
    return pMem;
}
