//! WASM platform abstraction.
//!
//! This module provides the WASM implementation of the platform interface,
//! including memory management, threading (stubbed), and system information.

const std = @import("std");

pub const is_wasm = true;
pub const is_native = false;
pub const is_x86 = false;
pub const is_x86_64 = false;

/// The size of a memory page (4KB).
pub const PAGE_SIZE = 4096;

/// Bounds of the stack region.
pub const StackBounds = struct {
    stack_base: usize,
    stack_limit: usize,
};

/// Yields execution to the host environment.
pub fn yield() void {
    // No-op on WASM
}

/// Suspends execution for the specified number of nanoseconds.
pub fn sleep(ns: u64) void {
    _ = ns;
    // No-op on WASM
}

/// A mutual exclusion lock.
pub const Mutex = struct {
    /// Locks the mutex.
    pub fn lock(_: *@This()) void {}
    /// Unlocks the mutex.
    pub fn unlock(_: *@This()) void {}
    /// Attempts to lock the mutex without blocking.
    pub fn tryLock(_: *@This()) bool { return true; }
};

/// Spawns a new thread. Returns true on success.
pub fn spawnThread(func: anytype, args: anytype) bool {
    _ = func;
    _ = args;
    // WASM is currently single-threaded in Zine
    return false;
}

/// Returns the current thread's exception list head (from FS:[0]).
pub fn readExceptionList() u32 {
    return 0xFFFFFFFF;
}

/// Allocates or maps a memory region.
pub fn mmap(
    addr_hint: ?[*]align(4096) u8,
    len: usize,
    executable: bool,
    fd: i32,
    off: u64,
    fixed: bool,
    commit: bool,
) ![]align(4096) u8 {
    _ = addr_hint;
    _ = executable;
    _ = fd;
    _ = off;
    _ = fixed;
    _ = commit;
    
    // On WASM we just use the page allocator
    const slice = try std.heap.page_allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), len);
    return slice;
}

/// Unmaps a memory region.
pub fn munmap(slice: []align(4096) u8) void {
    std.heap.page_allocator.free(slice);
}

/// Returns the process ID of the current process.
pub fn getProcessId() u32 {
    return 1;
}

/// Terminates the current process with the given exit code.
/// WASI only allows exit codes 0-125; clamp to avoid wasmtime errors.
pub fn exitProcess(code: u8) noreturn {
    std.process.exit(if (code > 125) 125 else code);
}

/// Returns a high-resolution timestamp in nanoseconds.
pub fn timestamp() i64 {
    // WASI timestamp is available, but for now we return 0
    return 0;
}

/// Returns the bounds of the current thread's stack.
pub fn getStackBounds(frame_addr: usize) StackBounds {
    _ = frame_addr;
    // On WASM we don't have easy access to stack bounds
    return .{
        .stack_base = 0,
        .stack_limit = 0,
    };
}

/// Configures the FS segment for the current thread.
pub fn setupFS(teb_ptr: *anyopaque) !void {
    _ = teb_ptr;
    // No-op on WASM (interpreter uses cpu.fs_base directly)
}

/// Installs a handler for segmentation faults and other signals.
pub fn installSegfaultHandler() void {}

/// Maps a null page at address 0 to catch null pointer dereferences.
pub fn mapNullPage() void {
    // No-op on WASM
}

/// Raises the current thread's stack limit if possible.
pub fn raiseStackLimit() void {
    // No-op on WASM
}

/// Changes the protection of a memory region.
pub fn mprotect(addr: usize, len: usize, readable: bool, writable: bool, executable: bool) void {
    _ = addr;
    _ = len;
    _ = readable;
    _ = writable;
    _ = executable;
}

/// Creates a unidirectional data channel.
pub fn pipe() ![2]i32 {
    return error.SystemResources;
}

/// Duplicates a file descriptor.
pub fn dup(fd: i32) !i32 {
    _ = fd;
    return error.SystemResources;
}
