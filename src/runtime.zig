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

/// Maximum number of registered guest->host thunks.
///
/// Lives here (not in `x86/thunks.zig`) so both the thunk registry and the
/// profiler's parallel stats tables can size from one constant without the
/// profiler importing x86-core internals.
pub const MAX_THUNKS = 4096;

/// Directory of the main executable as a Win32 path (backslash-separated),
/// terminated with a trailing `\`. Set at startup, before guest code runs;
/// `main_exe_dir_len` is 0 until then. Lives here rather than in the
/// kernel32 stub facade so low-level bridges (`win32/host_io.zig`) can read
/// it without importing API stub modules.
pub var main_exe_dir: [512]u8 = undefined;
pub var main_exe_dir_len: usize = 0;

/// Bounds of the main PE's executable code (.text section).
/// Set during PE loading so the SIGSEGV handler can distinguish
/// code addresses from data addresses during stack recovery.
pub var app_code_start: usize = 0x401000;
pub var app_code_end: usize = 0x700000;

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

/// Exit status for a CLI that could not write its own output to stdout (a
/// closed pipe, a full device). Separate from the usage-error status 2.
pub const cli_write_failure_status: u8 = 1;

/// Writes emulator-owned output (help, version) to stdout. A failed write is
/// reported on stderr and ends the process: help and version text are the
/// entire result of a successful run, so a partial write is a failure the
/// caller cannot recover from. Guest output is not routed through here.
pub fn writeCliOut(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io(), bytes) catch {
        std.debug.print("Error: failed to write to stdout.\n", .{});
        std.process.exit(cli_write_failure_status);
    };
}

/// Plain spinlock. Deliberately NOT `std.Io.Mutex`:
/// std.Io.Mutex goes through the Io cancel-protection machinery when contended
/// (futexWait via the io instance), which reads per-thread TLS
/// (Io.Threaded.Thread.current). In x86_64 compat mode the guest runs with
/// FS = LDT selector 0x07 (its TEB), so TLS reads from host stubs (which
/// execute inside the SIGSEGV dispatch handler) dereference the guest TEB —
/// crashing (null+0x308) or deadlocking in the park logic while inside a
/// signal handler. A raw spinlock uses neither TLS nor io and its critical
/// sections here are always short (queue pushes, message posts).
pub const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
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

/// Milliseconds on the monotonic clock (CLOCK_MONOTONIC). Unaffected by
/// wall-clock steps (NTP, manual setting). Use for measuring elapsed time;
/// the absolute value is meaningless across processes or boots.
pub fn monoMilliTimestamp() i64 {
    const ts = std.Io.Timestamp.now(io(), .awake);
    return ts.toMilliseconds();
}

/// Nanoseconds on the monotonic clock. Pairs with `monoMilliTimestamp`
/// (same underlying clock); never comparable with `nanoTimestamp`.
pub fn monoNanoTimestamp() i128 {
    const ts = std.Io.Timestamp.now(io(), .awake);
    return ts.nanoseconds;
}

/// Spin-based condition variable (see `Mutex` above for why we avoid
/// `std.Io.Condition` — it parks on the io instance, which breaks inside the
/// compat-mode signal dispatch context).
pub const Condition = struct {
    epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn wait(self: *Condition, m: *Mutex) void {
        const e = self.epoch.load(.acquire);
        m.unlock();
        while (self.epoch.load(.acquire) == e) {
            std.atomic.spinLoopHint();
        }
        m.lock();
    }
    pub fn signal(self: *Condition) void {
        _ = self.epoch.fetchAdd(1, .release);
    }
    pub fn broadcast(self: *Condition) void {
        _ = self.epoch.fetchAdd(1, .release);
    }
};
