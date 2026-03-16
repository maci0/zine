//! Platform abstraction interface — comptime backend selection.
//!
//! All platform-specific code should go through this module. At comptime the
//! correct backend (native or wasm) is chosen based on the target architecture.
//!
//! Usage:
//!   const platform = @import("platform.zig");  // re-exports this file
//!   const mem = try platform.mmap(...);

const builtin = @import("builtin");

const backend = if (builtin.target.cpu.arch == .wasm32)
    @import("wasm.zig")
else
    @import("native.zig");

// -------------------------------------------------------------------------
// Re-export everything from the selected backend
// -------------------------------------------------------------------------

/// True if the current backend is WASM.
pub const is_wasm = backend.is_wasm;
/// True if the current backend is native.
pub const is_native = backend.is_native;
/// True if the current architecture is x86.
pub const is_x86 = backend.is_x86;
/// True if the current architecture is x86_64.
pub const is_x86_64 = backend.is_x86_64;

// Memory
/// Map memory into the address space.
pub const mmap = backend.mmap;
/// Unmap memory from the address space.
pub const munmap = backend.munmap;
/// Change memory protection.
pub const mprotect = backend.mprotect;

// Threading
/// Yield the current thread.
pub const yield = backend.yield;
/// Sleep the current thread.
pub const sleep = backend.sleep;
/// Platform-specific mutex type.
pub const Mutex = backend.Mutex;
/// Spawn a new thread.
pub const spawnThread = backend.spawnThread;

// Process
/// Get the current process ID.
pub const getProcessId = backend.getProcessId;
/// Exit the current process.
pub const exitProcess = backend.exitProcess;
/// Get a high-resolution timestamp.
pub const timestamp = backend.timestamp;

// Stack bounds
/// Stack bounds information.
pub const StackBounds = backend.StackBounds;
/// Get the current thread's stack bounds.
pub const getStackBounds = backend.getStackBounds;

// FS segment (TEB)
/// Setup the FS segment (Thread Environment Block).
pub const setupFS = backend.setupFS;

// SEH
/// Read the current exception list (SEH).
pub const readExceptionList = backend.readExceptionList;

// Signal handling (native only, no-ops on WASM)
/// Install a handler for segmentation faults.
pub const installSegfaultHandler = backend.installSegfaultHandler;
/// Map the null page to catch null pointer dereferences.
pub const mapNullPage = backend.mapNullPage;
/// Raise the stack limit.
pub const raiseStackLimit = backend.raiseStackLimit;

// Pipe / Dup
/// Create a pipe.
pub const pipe = backend.pipe;
/// Duplicate a file descriptor.
pub const dup = backend.dup;
