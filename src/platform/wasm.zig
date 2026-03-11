// Platform backend: WASM (wasm32-wasi / wasm32-freestanding)
//
// Stubs and lightweight implementations for running inside a browser or
// WASI runtime.  Real JS-interop implementations will be added in Phase 3;
// for now these are functional enough to let the codebase compile and run
// with the WASM target.

const std = @import("std");

// -------------------------------------------------------------------------
// Architecture constants
// -------------------------------------------------------------------------

pub const is_wasm = true;
pub const is_native = false;
pub const is_x86 = false;
pub const is_x86_64 = false;

// -------------------------------------------------------------------------
// Threading
// -------------------------------------------------------------------------

pub fn yield() void {
    // No threading on single-threaded WASM
}

// -------------------------------------------------------------------------
// Memory Mapping
// -------------------------------------------------------------------------

pub fn mmap(
    hint: ?*anyopaque,
    size: usize,
    executable: bool,
    file_fd: i32,
    file_offset: u64,
    shared: bool,
    fixed: bool,
) ![]align(4096) u8 {
    _ = hint;
    _ = executable;
    _ = file_fd;
    _ = file_offset;
    _ = shared;
    _ = fixed;

    // On WASM, use the page allocator for aligned allocations.
    // File-backed mappings are not supported yet (Phase 3).
    const mem = try std.heap.page_allocator.alignedAlloc(u8, 4096, size);
    @memset(mem, 0);
    return mem[0..size];
}

pub fn munmap(slice: []align(4096) u8) void {
    // On WASM, we can't easily free aligned page allocations.
    // Just leak for now (matches existing VirtualFree behavior).
    _ = slice;
}

// -------------------------------------------------------------------------
// Process
// -------------------------------------------------------------------------

pub fn getProcessId() u32 {
    return 1; // Dummy PID for WASM
}

pub fn exitProcess(code: u8) noreturn {
    _ = code;
    @trap();
}

pub fn timestamp() i64 {
    // TODO Phase 3: call performance.now() via JS import
    return 0;
}

// -------------------------------------------------------------------------
// Stack bounds
// -------------------------------------------------------------------------

pub const StackBounds = struct {
    stack_base: u32,
    stack_limit: u32,
};

pub fn getStackBounds(frame_addr: usize) StackBounds {
    // Conservative defaults; the x86 interpreter manages its own guest stack.
    return .{
        .stack_base = @truncate((frame_addr +% 0x100000) & 0xFFFFF000),
        .stack_limit = @truncate((frame_addr -% 0x700000) & 0xFFFFF000),
    };
}

// -------------------------------------------------------------------------
// FS Segment Setup (TEB)
// -------------------------------------------------------------------------

pub fn setupFS(teb_ptr: *anyopaque) !void {
    // On WASM, there is no FS segment register. The x86 interpreter
    // handles FS-relative accesses by looking up cpu.fs_base directly.
    _ = teb_ptr;
}

// -------------------------------------------------------------------------
// Signal Handler Setup (no-ops on WASM)
// -------------------------------------------------------------------------

/// No signals on WASM — the x86 interpreter catches faults directly.
pub fn installSegfaultHandler(handler: anytype) void {
    _ = handler;
}

pub fn mapNullPage() void {
    // Not applicable on WASM
}

pub fn raiseStackLimit() void {
    // Not applicable on WASM
}
