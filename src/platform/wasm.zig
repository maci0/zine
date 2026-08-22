//! WASM platform abstraction.
//!
//! This module provides the WASM implementation of the platform interface,
//! including memory management, threading (stubbed), and system information.

const std = @import("std");
const runtime = @import("../runtime.zig");

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
    pub fn tryLock(_: *@This()) bool {
        return true;
    }
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
/// Parameter names match native.zig for consistency across backends.
pub fn mmap(
    hint: ?[*]align(4096) u8,
    size: usize,
    executable: bool,
    file_fd: i32,
    file_offset: u64,
    shared: bool,
    fixed: bool,
) ![]align(4096) u8 {
    _ = hint;
    _ = executable;
    _ = shared;
    _ = fixed;

    const slice = try std.heap.page_allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), size);

    // When a file descriptor is provided, read file content into the mapping
    // (e.g. CreateFileMappingA + MapViewOfFileEx used by LINK.EXE).
    if (file_fd >= 0) {
        const file = std.Io.File{ .handle = file_fd, .flags = .{ .nonblocking = false } };
        const bytes_read = file.readPositionalAll(runtime.io(), slice, file_offset) catch 0;
        if (bytes_read < slice.len) @memset(slice[bytes_read..], 0);
    }
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
/// Note: wasmtime clamps exit codes ≥126 to 1; wasmer passes them through.
pub fn exitProcess(code: u8) noreturn {
    std.process.exit(code);
}

/// Returns the current timestamp as a Unix epoch value (seconds).
/// Stubbed to 0 on WASM — not needed for current use cases.
pub fn timestamp() i64 {
    return 0;
}

/// Returns the current timestamp in milliseconds since Unix epoch.
/// Stubbed to 0 on WASM.
pub fn milliTimestamp() i64 {
    return 0;
}

/// Returns the current timestamp in nanoseconds since Unix epoch.
/// Stubbed to 0 on WASM.
pub fn nanoTimestamp() i128 {
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

pub fn saveHostFsBase() void {}

pub fn useHostFs() u16 {
    return 0;
}

pub fn restoreFs(sel: u16) void {
    _ = sel;
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

pub fn mprotectExec(addr: *anyopaque, len: usize) !void {
    _ = addr;
    _ = len;
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

/// Seek on WASM: the fd is a WASI fd, so delegate to fd_seek.
/// Returns the new file position, or -1 on error.
pub fn lseek(fd: i32, offset: i64, whence: u32) i64 {
    var new_offset: u64 = undefined;
    const rc = std.os.wasi.fd_seek(fd, offset, @enumFromInt(whence), &new_offset);
    if (rc != .SUCCESS) return -1;
    return @intCast(new_offset);
}
