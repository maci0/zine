//! Process-global Io + allocator handles.
//!
//! Win32 stubs are invoked via x86 cdecl/stdcall from guest code, so they
//! cannot accept an `io` parameter. Signal handlers, thunks, and log
//! functions also run outside any threaded chain. This module holds the
//! singletons set up at startup.

const std = @import("std");

// Default to the debug Io so hot callers (log/trace/stubs) skip a null-check.
// `init` overwrites these at startup before guest code runs.
var io_instance: std.Io = std.Options.debug_io;
var gpa_instance: ?std.mem.Allocator = null;
var environ_instance: std.process.Environ = .empty;

/// Install the process-wide Io + allocator. Call once from main.
pub fn init(io_value: std.Io, gpa_value: std.mem.Allocator, env: std.process.Environ) void {
    io_instance = io_value;
    gpa_instance = gpa_value;
    environ_instance = env;
}

/// Process-wide Io. Returns `std.Options.debug_io` before `init` is called.
pub fn io() std.Io {
    return io_instance;
}

/// Process-wide general-purpose allocator.
pub fn gpa() std.mem.Allocator {
    return gpa_instance orelse @panic("runtime.gpa accessed before runtime.init");
}

/// Process-wide environment.
pub fn environ() std.process.Environ {
    return environ_instance;
}

/// Wraps `std.Io.Mutex` and hides the `io` parameter by pulling it from the
/// process-wide singleton. Used by code that predates the 0.16 Io interface
/// (Win32 stubs, signal-driven paths) where threading `io` through is infeasible.
pub const Mutex = struct {
    inner: std.Io.Mutex = std.Io.Mutex.init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }
    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }
    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

/// Returns milliseconds since UNIX epoch using the process-wide io.
pub fn milliTimestamp() i64 {
    const ts = std.Io.Timestamp.now(io(), .real);
    return ts.toMilliseconds();
}

pub fn nanoTimestamp() i128 {
    const ts = std.Io.Timestamp.now(io(), .real);
    return ts.nanoseconds;
}

/// Wraps `std.Io.Condition` like `Mutex` above.
pub const Condition = struct {
    inner: std.Io.Condition = std.Io.Condition.init,

    pub fn wait(self: *Condition, m: *Mutex) void {
        self.inner.waitUncancelable(io(), &m.inner);
    }
    pub fn signal(self: *Condition) void {
        self.inner.signal(io());
    }
    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(io());
    }
};
