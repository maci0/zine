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

/// Guest-visible clock under a virtual (simulated) time source.
///
/// One cursor serves both the wall and the monotonic readings, so a simulated
/// guest sees the two move together from a fixed origin, where the host clocks
/// differ by the boot time. Every read advances the cursor by `step_ns`, and
/// every guest wait advances it by the wait's duration (see
/// `advanceVirtualClock`), so the observable clock depends only on the order
/// of guest calls, not on how long the host took to serve them.
pub const VirtualClock = struct {
    now_ns: i128,
    step_ns: i128,
};

var virtual_clock: ?*VirtualClock = null;

/// Guards `VirtualClock.now_ns`: a guest may read the clock from any of its
/// threads, and the cursor is a plain field. The section is a few adds.
var virtual_clock_mutex: Mutex = .{};

/// Process-lifetime storage for the clock `installVirtualClock` points at.
/// Lives here rather than in an entry point so every build shares one.
var configured_clock: VirtualClock = undefined;

/// Installs the guest clock the startup settings selected. The pointer must
/// outlive every guest clock read, so the storage is a module-level variable
/// rather than a local the caller owns.
pub fn installConfiguredClock(start_ns: i64, step_ns: i64) void {
    configured_clock = .{ .now_ns = start_ns, .step_ns = step_ns };
    installVirtualClock(&configured_clock);
}

/// Makes `clock` the source for every guest-visible time reading until
/// `useHostClock` runs. The callee owns the clock; it must outlive every
/// reading that can reach it.
pub fn installVirtualClock(clock: *VirtualClock) void {
    virtual_clock_mutex.lock();
    defer virtual_clock_mutex.unlock();
    virtual_clock = clock;
}

/// Returns to the host clocks. The counterpart of `installVirtualClock`, so a
/// caller that simulates a run can hand the process back its real time.
pub fn useHostClock() void {
    virtual_clock_mutex.lock();
    defer virtual_clock_mutex.unlock();
    virtual_clock = null;
}

/// Whether a virtual clock is installed, so a caller can tell whether a
/// reading is simulated without consuming a clock tick to find out.
pub fn useVirtualClock() bool {
    virtual_clock_mutex.lock();
    defer virtual_clock_mutex.unlock();
    return virtual_clock != null;
}

/// Charges a guest wait to the virtual clock and reports whether it did. A
/// real clock is never advanced, so the caller must sleep for the same
/// duration when this returns false.
pub fn advanceVirtualClock(ns: u64) bool {
    virtual_clock_mutex.lock();
    defer virtual_clock_mutex.unlock();
    const clock = virtual_clock orelse return false;
    clock.now_ns += ns;
    return true;
}

/// Blocks for `ns` on the host clock, or charges the duration to the virtual
/// clock when one is installed. Every guest-visible wait goes through here, so
/// a simulated run spends no real time and its clock moves by exactly the
/// duration the guest asked for.
pub fn pauseOrAdvance(ns: u64) void {
    if (advanceVirtualClock(ns)) return;
    // Imported here: platform sleeps without touching std.Io, which reads
    // per-thread TLS and is unsafe inside the compat-mode dispatch handler.
    @import("platform.zig").sleep(ns);
}

/// Reads and advances the virtual clock; null when the host clocks are in use.
fn virtualNow() ?i128 {
    virtual_clock_mutex.lock();
    defer virtual_clock_mutex.unlock();
    const clock = virtual_clock orelse return null;
    const now = clock.now_ns;
    clock.now_ns += clock.step_ns;
    return now;
}

/// Returns milliseconds since UNIX epoch using the process-wide io, or the
/// virtual clock when one is installed.
pub fn milliTimestamp() i64 {
    if (virtualNow()) |ns| return @intCast(@divTrunc(ns, std.time.ns_per_ms));
    const ts = std.Io.Timestamp.now(io(), .real);
    return ts.toMilliseconds();
}

/// Nanoseconds since the UNIX epoch. Under a virtual clock this returns the
/// simulated cursor, which advances by one step on every call, not a host
/// reading.
pub fn nanoTimestamp() i128 {
    if (virtualNow()) |ns| return ns;
    const ts = std.Io.Timestamp.now(io(), .real);
    return ts.nanoseconds;
}

/// Milliseconds on the monotonic clock (CLOCK_MONOTONIC). Unaffected by
/// wall-clock steps (NTP, manual setting). Use for measuring elapsed time;
/// the absolute value is meaningless across processes or boots.
pub fn monoMilliTimestamp() i64 {
    if (virtualNow()) |ns| return @intCast(@divTrunc(ns, std.time.ns_per_ms));
    const ts = std.Io.Timestamp.now(io(), .awake);
    return ts.toMilliseconds();
}

/// Nanoseconds on the monotonic clock. Pairs with `monoMilliTimestamp`
/// (same underlying clock); never comparable with `nanoTimestamp`.
pub fn monoNanoTimestamp() i128 {
    if (virtualNow()) |ns| return ns;
    const ts = std.Io.Timestamp.now(io(), .awake);
    return ts.nanoseconds;
}

/// Elapsed time measured by the emulator itself (log timestamps, profiler).
/// Always the host monotonic clock: instrumentation must not report the
/// simulated time a guest asked for.
pub fn hostMonoNanoTimestamp() i128 {
    return std.Io.Timestamp.now(io(), .awake).nanoseconds;
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

const testing = std.testing;

/// A scripted run: alternating clock reads and guest waits, the shape of
/// everything a Win32 guest does to the passage of time.
const run_reads = 6;

fn scriptedRun(seed_ns: i128) [run_reads]i128 {
    var clock = VirtualClock{ .now_ns = seed_ns, .step_ns = std.time.ns_per_ms };
    installVirtualClock(&clock);
    defer useHostClock();

    var out: [run_reads]i128 = undefined;
    for (0..run_reads) |i| {
        if (i % 2 == 0) {
            _ = advanceVirtualClock(std.time.ns_per_ms);
        } else {
            out[i] = monoNanoTimestamp();
        }
    }
    return out;
}

test "virtual clock: readings follow the configured start and step" {
    var clock = VirtualClock{ .now_ns = 1_700_000_000_000_000_000, .step_ns = std.time.ns_per_ms };
    installVirtualClock(&clock);
    defer useHostClock();

    try testing.expect(useVirtualClock());
    try testing.expectEqual(@as(i128, 1_700_000_000_000_000_000), nanoTimestamp());
    try testing.expectEqual(@as(i128, 1_700_000_000_000_000_000 + std.time.ns_per_ms), milliTimestamp() * std.time.ns_per_ms);
    // Wall and monotonic share the cursor, so a tick delta the guest computes
    // matches the wait it asked for.
    const before = monoMilliTimestamp();
    try testing.expect(advanceVirtualClock(50 * std.time.ns_per_ms));
    // The wait plus the step this reading itself advances the cursor by.
    try testing.expectEqual(@as(i64, 50) + @divExact(clock.step_ns, std.time.ns_per_ms), monoMilliTimestamp() - before);
}

test "virtual clock: the same start replays the same readings" {
    const first = scriptedRun(1_700_000_000_000_000_000);
    const second = scriptedRun(1_700_000_000_000_000_000);
    try testing.expectEqualSlices(i128, &first, &second);
    try testing.expect(first[1] != first[3]);
}

test "virtual clock: waits are charged to it and never to the host clock" {
    var clock = VirtualClock{ .now_ns = 0, .step_ns = 1 };
    installVirtualClock(&clock);
    defer useHostClock();

    _ = nanoTimestamp();
    try testing.expect(advanceVirtualClock(std.time.ns_per_s));
    // Exactly one virtual second plus the scripted step. A real clock could
    // not land on that value, so it is what proves the wait was not charged
    // to the host.
    try testing.expectEqual(@as(i128, std.time.ns_per_s + 1), nanoTimestamp());
}

test "pauseOrAdvance: a simulated wait charges the virtual clock and no host time" {
    var clock = VirtualClock{ .now_ns = 0, .step_ns = 0 };
    installVirtualClock(&clock);
    defer useHostClock();

    for (0..8) |_| pauseOrAdvance(5 * std.time.ns_per_ms);
    try testing.expectEqual(@as(i128, 40 * std.time.ns_per_ms), clock.now_ns);
}

test "host clock: without a virtual clock the host clocks answer" {
    useHostClock();
    try testing.expect(!useVirtualClock());
    try testing.expect(!advanceVirtualClock(std.time.ns_per_ms));

    // The monotonic reading is only ordered against itself; two reads of the
    // same clock never go backwards.
    const mono_first = hostMonoNanoTimestamp();
    const mono_second = hostMonoNanoTimestamp();
    try testing.expect(mono_second >= mono_first);

    // The wall-clock branch reports milliseconds since the epoch, so it must
    // sit well past 2001-01-01T00:00:00Z (978307200000 ms).
    const epoch_ms = milliTimestamp();
    try testing.expect(epoch_ms > 978_307_200_000);
}
