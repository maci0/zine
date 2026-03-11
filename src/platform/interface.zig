// Platform abstraction interface — comptime backend selection.
//
// All platform-specific code should go through this module.  At comptime the
// correct backend (native or wasm) is chosen based on the target architecture.
//
// Usage:
//   const platform = @import("platform.zig");  // re-exports this file
//   const mem = try platform.mmap(...);

const builtin = @import("builtin");

const backend = if (builtin.target.cpu.arch == .wasm32)
    @import("wasm.zig")
else
    @import("native.zig");

// -------------------------------------------------------------------------
// Re-export everything from the selected backend
// -------------------------------------------------------------------------

pub const is_wasm = backend.is_wasm;
pub const is_native = backend.is_native;
pub const is_x86 = backend.is_x86;
pub const is_x86_64 = backend.is_x86_64;

// Memory
pub const mmap = backend.mmap;
pub const munmap = backend.munmap;

// Threading
pub const yield = backend.yield;

// Process
pub const getProcessId = backend.getProcessId;
pub const exitProcess = backend.exitProcess;
pub const timestamp = backend.timestamp;

// Stack bounds
pub const StackBounds = backend.StackBounds;
pub const getStackBounds = backend.getStackBounds;

// FS segment (TEB)
pub const setupFS = backend.setupFS;

// Signal handling (native only, no-ops on WASM)
pub const installSegfaultHandler = backend.installSegfaultHandler;
pub const mapNullPage = backend.mapNullPage;
pub const raiseStackLimit = backend.raiseStackLimit;
