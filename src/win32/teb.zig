//! Thread Environment Block (TEB) and Process Environment Block (PEB) setup.
//!
//! The TEB and PEB are the core Windows internal structures used for thread and
//! process state, accessed by guest code via the FS segment (e.g. FS:[0x30] for
//! PEB). Their layouts and the host-visible TEB address live in
//! `teb_layout.zig`; this module allocates them and installs the FS segment.

const std = @import("std");
const platform = @import("../platform.zig");
const teb_layout = @import("teb_layout.zig");

const TEB = teb_layout.TEB;
const PEB = teb_layout.PEB;
const RTL_USER_PROCESS_PARAMETERS = teb_layout.RTL_USER_PROCESS_PARAMETERS;

/// Implementation status: Partially implemented
pub fn initTEB() !*TEB {
    // On x86_64, TEB must be in low 4GB because guest code reads it via
    // FS-relative 32-bit pointers. Use platform.mmap which sets MAP_32BIT.
    // On x86, page_allocator is fine (everything is 32-bit).
    const slice = if (comptime platform.is_x86_64)
        try platform.mmap(null, @sizeOf(TEB), false, -1, 0, false, false)
    else
        try std.heap.page_allocator.alloc(u8, @sizeOf(TEB));
    const teb_val = @as(*TEB, @ptrCast(@alignCast(slice.ptr)));
    @memset(slice, 0);

    // PEB and ProcessParameters must be in the low 32-bit memory range
    // because guest x86 code reads them via fs:[0x30] and follows the pointer
    // chain.  The arena allocator can return addresses above 4GB on x86-64.
    const kernel32_mem = @import("kernel32/mem.zig");
    const peb = blk: {
        const raw = kernel32_mem.raw_alloc(@sizeOf(PEB)) orelse return error.OutOfMemory;
        break :blk @as(*PEB, @ptrCast(@alignCast(raw)));
    };
    peb.* = .{};
    peb.ProcessHeap = 0xDEADC0DE;

    const params = blk: {
        const raw = kernel32_mem.raw_alloc(@sizeOf(RTL_USER_PROCESS_PARAMETERS)) orelse return error.OutOfMemory;
        break :blk @as(*RTL_USER_PROCESS_PARAMETERS, @ptrCast(@alignCast(raw)));
    };
    params.* = .{};
    peb.ProcessParameters = @truncate(@intFromPtr(params));

    teb_val.NtTib.Self = @truncate(@intFromPtr(teb_val));
    teb_val.ProcessEnvironmentBlock = @truncate(@intFromPtr(peb));

    // Allocate TLS array (Thread Local Storage) — MinGW UCRT uses TLS for
    // per-thread locale data in printf. TEB.ThreadLocalStoragePointer (offset 0x2C)
    // points to an array of pointers indexed by TLS module ID.
    // TLS array: each slot points to a per-module TLS data block.
    // Allocate 64 slots, each pointing to a 256-byte zeroed data block.
    const tls_array = blk: {
        const raw = kernel32_mem.raw_alloc(64 * 4) orelse return error.OutOfMemory;
        const arr = @as(*[64]u32, @ptrCast(@alignCast(raw)));
        // Allocate a shared TLS data block for slots that get accessed
        const tls_data = kernel32_mem.raw_alloc(4096) orelse return error.OutOfMemory;
        @memset(@as([*]u8, @ptrCast(tls_data))[0..4096], 0);
        const data_addr: u32 = @truncate(@intFromPtr(tls_data));
        for (0..64) |i| arr[i] = data_addr;
        break :blk arr;
    };
    teb_val.ThreadLocalStoragePointer = @truncate(@intFromPtr(tls_array));

    // Setup stack limits via platform abstraction.
    // Windows MSVC compilers (like c1.dll) check fs:[4] (StackBase) and fs:[8] (StackLimit)
    // to detect stack overflows. If they are 0 or unrealistic, they abort with C1063.
    const frame_addr: usize = @frameAddress();
    const bounds = platform.getStackBounds(frame_addr);
    teb_val.NtTib.StackBase = @truncate(bounds.stack_base);
    teb_val.NtTib.StackLimit = @truncate(bounds.stack_limit);

    return teb_val;
}

/// Implementation status: Partially implemented
pub fn setupFS(teb_ptr: *TEB) !void {
    teb_layout.teb_address = @intFromPtr(teb_ptr);
    try platform.setupFS(teb_ptr);
}
