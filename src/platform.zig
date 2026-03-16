//! Platform abstraction layer for native (Linux x86/x86_64) and WASM targets.
//!
//! This is a thin re-export of platform/interface.zig, which selects the
//! correct backend (native or wasm) at comptime.
//!
//! All platform-specific code should go through this module.

const interface = @import("platform/interface.zig");

/// Returns true if the current target is WASM.
pub const is_wasm = interface.is_wasm;
/// Returns true if the current target is native.
pub const is_native = interface.is_native;
/// Returns true if the current target is x86.
pub const is_x86 = interface.is_x86;
/// Returns true if the current target is x86_64.
pub const is_x86_64 = interface.is_x86_64;

/// Allocates virtual memory.
pub const mmap = interface.mmap;
/// Frees virtual memory.
pub const munmap = interface.munmap;
/// Changes the protection of virtual memory.
pub const mprotect = interface.mprotect;

/// Yields the current thread.
pub const yield = interface.yield;
/// Sleeps the current thread for the specified duration in nanoseconds.
pub const sleep = interface.sleep;
/// A mutex for thread synchronization.
pub const Mutex = interface.Mutex;
/// Spawns a new thread.
pub const spawnThread = interface.spawnThread;

/// Returns the current process ID.
pub const getProcessId = interface.getProcessId;
/// Exits the current process with the specified status code.
pub const exitProcess = interface.exitProcess;
/// Returns the current timestamp in nanoseconds.
pub const timestamp = interface.timestamp;

/// Represents the bounds of a thread stack.
pub const StackBounds = interface.StackBounds;
/// Returns the stack bounds of the current thread.
pub const getStackBounds = interface.getStackBounds;

/// Sets up the FS segment for the current thread.
pub const setupFS = interface.setupFS;

/// Reads the current exception list (FS:0).
pub const readExceptionList = interface.readExceptionList;

/// Installs a segfault handler.
pub const installSegfaultHandler = interface.installSegfaultHandler;
/// Maps a null page to catch null pointer dereferences.
pub const mapNullPage = interface.mapNullPage;
/// Raises the stack limit for the current process.
pub const raiseStackLimit = interface.raiseStackLimit;

/// Creates a pipe.
pub const pipe = interface.pipe;
/// Duplicates a file descriptor.
pub const dup = interface.dup;
