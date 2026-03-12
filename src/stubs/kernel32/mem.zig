const std = @import("std");
const trace = @import("../../trace.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");
const x86_memory = @import("../../x86/memory.zig");

/// Set by wasm_main.zig to enable guest-side allocation.
/// When non-null, all memory allocations go through the guest heap
/// bump allocator so addresses stay within the GuestMemory range.
pub var guest_memory: ?*x86_memory.GuestMemory = null;

pub fn raw_alloc(size: usize) ?*anyopaque {
    const actual_size = if (size == 0) @as(usize, 64) else size;

    // On WASM: use guest heap allocator to keep addresses in range
    if (guest_memory) |gmem| {
        const alloc_size: u32 = @intCast(@min(actual_size + 16, 0xFFFFFFFF));
        const addr = gmem.guestAlloc(alloc_size);
        if (addr == 0) return null;
        // Store size header at the start (8 bytes), return pointer after header
        gmem.write32(addr, @intCast(actual_size));
        gmem.write32(addr +% 4, 0);
        // Return a host pointer into the guest buffer for the header area
        const buf_offset = addr -% gmem.base_addr;
        return @ptrCast(gmem.base.ptr + buf_offset + 8);
    }

    const ptr = std.heap.page_allocator.alloc(u8, actual_size + 8) catch return null;
    @memset(ptr, 0);
    const header = @as(*usize, @ptrCast(@alignCast(ptr.ptr)));
    header.* = actual_size;
    return @ptrCast(ptr.ptr + 8);
}

pub fn raw_realloc(old_ptr: ?*anyopaque, new_size: usize) ?*anyopaque {
    if (new_size == 0) return null;
    if (old_ptr == null) return raw_alloc(new_size);

    // On WASM with guest heap: simple alloc + copy (we don't free)
    if (guest_memory) |_| {
        const old_u8 = @as([*]u8, @ptrCast(old_ptr.?));
        // Read old size from header (8 bytes before the data pointer)
        const old_header_ptr = old_u8 - 8;
        const old_size_32 = @as(*align(1) const u32, @ptrCast(old_header_ptr)).*;
        const old_size: usize = old_size_32;

        const new_mem = raw_alloc(new_size) orelse return null;
        const copy_len = @min(old_size, new_size);
        const new_u8 = @as([*]u8, @ptrCast(new_mem));
        @memcpy(new_u8[0..copy_len], old_u8[0..copy_len]);
        return new_mem;
    }


    const old_u8_ptr = @as([*]u8, @ptrCast(old_ptr.?)) - 8;
    const old_header = @as(*usize, @ptrCast(@alignCast(old_u8_ptr)));
    const old_size = old_header.*;

    const new_mem = std.heap.page_allocator.alloc(u8, new_size + 8) catch return null;
    @memset(new_mem, 0);

    const new_header = @as(*usize, @ptrCast(@alignCast(new_mem.ptr)));
    new_header.* = new_size;

    const copy_len = @min(old_size, new_size);
    const old_data = @as([*]u8, @ptrCast(old_ptr.?));
    const new_data = new_mem.ptr + 8;
    @memcpy(new_data[0..copy_len], old_data[0..copy_len]);

    // Free old allocation
    const old_total = old_size + 8;
    std.heap.page_allocator.free(old_u8_ptr[0..old_total]);

    return @ptrCast(new_data);
}

// Keep a rolling hint for 64KB aligned allocations to satisfy Windows memory assumptions
var next_alloc_hint: usize = 0x60000000;

pub fn get_aligned_hint(size: usize) usize {
    const hint = next_alloc_hint;
    const aligned_size = (size + 0xFFFF) & ~@as(usize, 0xFFFF);
    next_alloc_hint += aligned_size;
    return hint;
}

pub fn stub_VirtualAlloc(lpAddress: usize, dwSize: usize, flAllocationType: u32, flProtect: u32) callconv(w32cc.WINAPI) usize {
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
    if (guest_memory) |gmem| {
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

pub fn stub_VirtualFree(lpAddress: usize, dwSize: usize, dwFreeType: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwSize;
    _ = dwFreeType;
    if (trace.enable_tracing) trace.print("KERNEL32: VirtualFree(addr={x})\n", .{lpAddress});
    return 1;
}

pub fn stub_VirtualQuery(lpAddress: usize, lpBuffer_ptr: usize, dwLength: usize) callconv(w32cc.WINAPI) usize {
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

pub fn stub_HeapCreate(flOptions: u32, dwInitialSize: usize, dwMaximumSize: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = flOptions;
    _ = dwInitialSize;
    _ = dwMaximumSize;
    // Sentinel value; all heap functions use raw_alloc regardless of handle.
    return @ptrFromInt(0xDEADBEEF);
}

pub fn stub_HeapDestroy(hHeap: ?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    return 1;
}

pub fn stub_GetProcessHeap() callconv(w32cc.WINAPI) ?*anyopaque {
    if (trace.enable_tracing) trace.print("KERNEL32: GetProcessHeap()\n", .{});
    return @ptrFromInt(0xDEADC0DE);
}

pub fn stub_HeapAlloc(hHeap: ?*anyopaque, dwFlags: u32, dwBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hHeap;
    _ = dwFlags;
    return raw_alloc(dwBytes);
}

pub fn stub_HeapReAlloc(hHeap: ?*anyopaque, dwFlags: u32, lpMem: ?*anyopaque, dwBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hHeap;
    _ = dwFlags;
    return raw_realloc(lpMem, dwBytes);
}

pub fn stub_HeapFree(hHeap: ?*anyopaque, dwFlags: u32, lpMem: ?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    _ = dwFlags;
    _ = lpMem;
    return 1;
}

pub fn stub_LocalAlloc(uFlags: u32, uBytes: usize) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = uFlags;
    return raw_alloc(uBytes);
}

pub fn stub_LocalFree(hMem: ?*anyopaque) callconv(w32cc.WINAPI) ?*anyopaque {
    _ = hMem;
    return null;
}

pub fn stub_LocalLock(hMem: usize) callconv(w32cc.WINAPI) usize {
    // For LMEM_FIXED, the handle IS the pointer
    return hMem;
}

pub fn stub_LocalUnlock(hMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMem;
    return 0;
}

pub fn stub_LocalSize(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (hMem == 0) return 0;
    // raw_alloc stores size in the 8 bytes before the returned pointer
    const header = @as(*const usize, @ptrFromInt(hMem - 8));
    return header.*;
}

pub fn stub_LocalReAlloc(hMem: usize, uBytes: usize, uFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = uFlags;
    if (hMem == 0) {
        const ptr = raw_alloc(uBytes) orelse return 0;
        return @intFromPtr(ptr);
    }
    const ptr = raw_realloc(@ptrFromInt(hMem), uBytes) orelse return 0;
    return @intFromPtr(ptr);
}

pub fn stub_GlobalMemoryStatus(lpBuffer: usize) callconv(w32cc.WINAPI) void {
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

pub fn stub_GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(w32cc.WINAPI) usize {
    _ = uFlags;
    const ret_addr = @returnAddress();
    const ptr = raw_alloc(dwBytes) orelse return 0;
    if (trace.enable_tracing) trace.print("KERNEL32: GlobalAlloc(size={d}) = {x} (from {x})\n", .{ dwBytes, @intFromPtr(ptr), ret_addr });
    return @intFromPtr(ptr);
}

pub fn stub_GlobalFree(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) trace.print("KERNEL32: GlobalFree({x})\n", .{hMem});
    return 0; // Success
}

pub fn stub_GlobalLock(hMem: usize) callconv(w32cc.WINAPI) usize {
    // For GMEM_FIXED, the handle IS the pointer
    return hMem;
}

pub fn stub_GlobalUnlock(hMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hMem;
    return 0;
}

pub fn stub_GlobalSize(hMem: usize) callconv(w32cc.WINAPI) usize {
    if (hMem == 0) return 0;
    // raw_alloc stores size in the 8 bytes before the returned pointer
    const header = @as(*const usize, @ptrFromInt(hMem - 8));
    return header.*;
}

pub fn stub_GlobalReAlloc(hMem: usize, dwBytes: usize, uFlags: u32) callconv(w32cc.WINAPI) usize {
    _ = uFlags;
    if (hMem == 0) {
        const ptr = raw_alloc(dwBytes) orelse return 0;
        return @intFromPtr(ptr);
    }
    const ptr = raw_realloc(@ptrFromInt(hMem), dwBytes) orelse return 0;
    return @intFromPtr(ptr);
}
