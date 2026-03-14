// Platform abstraction layer for native (Linux x86/x86_64) and WASM targets.
//
// This is a thin re-export of platform/interface.zig, which selects the
// correct backend (native or wasm) at comptime.
//
// All platform-specific code should go through this module.

const interface = @import("platform/interface.zig");

pub const is_wasm = interface.is_wasm;
pub const is_native = interface.is_native;
pub const is_x86 = interface.is_x86;
pub const is_x86_64 = interface.is_x86_64;

pub const mmap = interface.mmap;
pub const munmap = interface.munmap;
pub const mprotect = interface.mprotect;

pub const yield = interface.yield;
pub const sleep = interface.sleep;
pub const Mutex = interface.Mutex;
pub const spawnThread = interface.spawnThread;

pub const getProcessId = interface.getProcessId;
pub const exitProcess = interface.exitProcess;
pub const timestamp = interface.timestamp;

pub const StackBounds = interface.StackBounds;
pub const getStackBounds = interface.getStackBounds;

pub const setupFS = interface.setupFS;

pub const readExceptionList = interface.readExceptionList;

pub const installSegfaultHandler = interface.installSegfaultHandler;
pub const mapNullPage = interface.mapNullPage;
pub const raiseStackLimit = interface.raiseStackLimit;

pub const pipe = interface.pipe;
pub const dup = interface.dup;
