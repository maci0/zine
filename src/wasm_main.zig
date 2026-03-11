// WASM entry point for winloader.
//
// This module exports functions that the JavaScript host calls to:
// 1. Load a PE binary into the WASM linear memory
// 2. Initialize the Win32 stub environment
// 3. Run the x86 interpreter
//
// Currently a minimal skeleton proving the WASM build target works.

const std = @import("std");
const platform = @import("platform.zig");

// Re-export platform to ensure WASM imports are declared
comptime {
    _ = platform;
}

var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// Called by JS host to initialize the winloader environment.
export fn wl_init() u32 {
    _ = arena.allocator();
    return 1; // success
}

/// Called by JS host to get the base address for loading PE data.
/// JS should write the PE file bytes starting at this address.
export fn wl_alloc(size: u32) u32 {
    const allocator = arena.allocator();
    const mem = allocator.alloc(u8, size) catch return 0;
    return @intFromPtr(mem.ptr);
}

/// Called by JS host to get a pointer to WASM memory for reading results.
export fn wl_memory_base() u32 {
    return 0; // WASM linear memory starts at 0
}

/// Main execution entry point (x86 interpreter not yet implemented).
/// For now, just validates that the build and JS interop work.
export fn wl_run(pe_data_ptr: u32, pe_data_len: u32) u32 {
    _ = pe_data_ptr;
    _ = pe_data_len;
    std.fs.File.stderr().writeAll("winloader WASM: wl_run called (interpreter not yet implemented)\n") catch {};
    return 0;
}
