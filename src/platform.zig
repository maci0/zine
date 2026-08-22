//! Platform abstraction layer for native (Linux x86/x86_64) and WASM targets.
//!
//! At comptime the correct backend (native or wasm) is chosen based on the
//! target architecture. All platform-specific code should go through this module.

const builtin = @import("builtin");

const backend = if (builtin.target.cpu.arch.isWasm())
    @import("platform/wasm.zig")
else
    @import("platform/native.zig");

// -------------------------------------------------------------------------
// Target detection
// -------------------------------------------------------------------------

/// True if the current target is WASM.
pub const is_wasm = backend.is_wasm;
/// True if the current target is native.
pub const is_native = backend.is_native;
/// True if the current target is x86.
pub const is_x86 = backend.is_x86;
/// True if the current target is x86_64.
pub const is_x86_64 = backend.is_x86_64;

// -------------------------------------------------------------------------
// Memory
// -------------------------------------------------------------------------

/// Allocates virtual memory.
pub const mmap = backend.mmap;
/// Frees virtual memory.
pub const munmap = backend.munmap;
/// Changes the protection of virtual memory.
pub const mprotect = backend.mprotect;
/// Mark a memory region as read-write-execute.
pub const mprotectExec = backend.mprotectExec;

// -------------------------------------------------------------------------
// Threading
// -------------------------------------------------------------------------

/// Yields the current thread.
pub const yield = backend.yield;
/// Sleeps the current thread for the specified duration in nanoseconds.
pub const sleep = backend.sleep;
/// A mutex for thread synchronization.
pub const Mutex = backend.Mutex;
/// Spawns a new thread.
pub const spawnThread = backend.spawnThread;

// -------------------------------------------------------------------------
// Process
// -------------------------------------------------------------------------

/// Returns the current process ID.
pub const getProcessId = backend.getProcessId;
/// Exits the current process with the specified status code.
pub const exitProcess = backend.exitProcess;
/// Returns the current timestamp as a Unix epoch value (seconds).
pub const timestamp = backend.timestamp;
/// lseek wrapper; returns new offset or -1 on error.
pub const lseek = backend.lseek;

// -------------------------------------------------------------------------
// Stack bounds
// -------------------------------------------------------------------------

/// Represents the bounds of a thread stack.
pub const StackBounds = backend.StackBounds;
/// Returns the stack bounds of the current thread.
pub const getStackBounds = backend.getStackBounds;

// -------------------------------------------------------------------------
// FS segment (TEB)
// -------------------------------------------------------------------------

/// Sets up the FS segment for the current thread.
pub const setupFS = backend.setupFS;
pub const saveHostFsBase = backend.saveHostFsBase;
pub const useHostFs = backend.useHostFs;
pub const restoreFs = backend.restoreFs;

// -------------------------------------------------------------------------
// SEH
// -------------------------------------------------------------------------

/// Reads the current exception list (FS:0).
pub const readExceptionList = backend.readExceptionList;

// -------------------------------------------------------------------------
// Signal handling (native only, no-ops on WASM)
// -------------------------------------------------------------------------

/// Installs a segfault handler.
pub const installSegfaultHandler = backend.installSegfaultHandler;
/// Maps a null page to catch null pointer dereferences.
pub const mapNullPage = backend.mapNullPage;
/// Raises the stack limit for the current process.
pub const raiseStackLimit = backend.raiseStackLimit;

// -------------------------------------------------------------------------
// Pipe / Dup
// -------------------------------------------------------------------------

/// Creates a pipe.
pub const pipe = backend.pipe;
/// Duplicates a file descriptor.
pub const dup = backend.dup;

// -------------------------------------------------------------------------
// Guest pointer helpers
// -------------------------------------------------------------------------

/// Write a guest pointer-sized value (u32) to a guest memory address.
/// On x86 native, usize == u32 so this is a normal write.
/// On x86_64 compat mode, guest pointers are 32-bit — writes u32 to avoid
/// corrupting adjacent stack/data by writing 8 bytes into a 4-byte slot.
pub inline fn writeGuestPtr(addr: usize, value: usize) void {
    if (addr == 0) return;
    @as(*u32, @ptrFromInt(addr)).* = @truncate(value);
}
