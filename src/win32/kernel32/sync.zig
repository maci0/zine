const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");
const platform = @import("../../platform.zig");

/// --- Interlocked operations ---
/// Implementation status: Partially implemented
pub fn InterlockedIncrement(lpAddend: *i32) callconv(w32cc.WINAPI) i32 {
    return @atomicRmw(i32, lpAddend, .Add, 1, .seq_cst) + 1;
}

pub fn InterlockedDecrement(lpAddend: *i32) callconv(w32cc.WINAPI) i32 {
    return @atomicRmw(i32, lpAddend, .Sub, 1, .seq_cst) - 1;
}

// -----------------------------------------------------------------------
// Critical Sections
// -----------------------------------------------------------------------
// Win32 CRITICAL_SECTIONs are RECURSIVE — the same thread can enter
// multiple times without deadlocking. We track owner thread + recursion count.

const MAX_CRITICAL_SECTIONS = 256;

const CriticalSection = struct {
    mutex: runtime.Mutex = .{},
    owner: std.atomic.Value(std.Thread.Id) = std.atomic.Value(std.Thread.Id).init(0),
    recursion: u32 = 0,
    addr: usize = 0,
};

var cs_table: [MAX_CRITICAL_SECTIONS]CriticalSection = init_cs: {
    var arr: [MAX_CRITICAL_SECTIONS]CriticalSection = undefined;
    for (&arr) |*cs| cs.* = .{};
    break :init_cs arr;
};

var cs_table_mutex: runtime.Mutex = .{};

fn getOrCreateCS(addr: usize) ?*CriticalSection {
    cs_table_mutex.lock();
    defer cs_table_mutex.unlock();
    for (&cs_table) |*cs| {
        if (cs.addr == addr) return cs;
    }
    for (&cs_table) |*cs| {
        if (cs.addr == 0) {
            cs.* = .{ .addr = addr };
            return cs;
        }
    }
    return null;
}

/// Implementation status: Partially implemented
pub fn InitializeCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: InitializeCriticalSection({x})\n", .{lpCriticalSection});
    if (lpCriticalSection != 0) _ = getOrCreateCS(lpCriticalSection);
}

/// Implementation status: Partially implemented
pub fn EnterCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (lpCriticalSection == 0) return;
    const cs = getOrCreateCS(lpCriticalSection) orelse return;
    const tid = std.Thread.getCurrentId();
    if (cs.owner.load(.monotonic) == tid) {
        // Recursive entry — same thread, just bump count
        cs.recursion += 1;
        return;
    }
    cs.mutex.lock();
    cs.owner.store(tid, .monotonic);
    cs.recursion = 1;
}

/// Implementation status: Partially implemented
pub fn LeaveCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (lpCriticalSection == 0) return;
    const cs = getOrCreateCS(lpCriticalSection) orelse return;
    if (cs.recursion > 1) {
        cs.recursion -= 1;
        return;
    }
    cs.owner.store(0, .monotonic);
    cs.recursion = 0;
    cs.mutex.unlock();
}

/// Implementation status: Partially implemented
pub fn DeleteCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: DeleteCriticalSection({x})\n", .{lpCriticalSection});
    if (lpCriticalSection == 0) return;
    cs_table_mutex.lock();
    defer cs_table_mutex.unlock();
    for (&cs_table) |*cs| {
        if (cs.addr == lpCriticalSection) {
            cs.* = .{};
            return;
        }
    }
}

// -----------------------------------------------------------------------
// Kernel Object Registry
// -----------------------------------------------------------------------
// Unified handle table for Events, Mutexes, and Semaphores.
// WaitForSingleObject/WaitForMultipleObjects dispatch on object type.

const MAX_KERNEL_OBJECTS = 128;

const KernelObjectType = enum { event, mutex, semaphore };

const EventData = struct {
    manual_reset: bool = false,
    signaled: bool = false,
    mutex: runtime.Mutex = .{},
    cond: runtime.Condition = .{},
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: u8 = 0,
};

const MutexData = struct {
    inner: runtime.Mutex = .{},
    /// Ownership is read before `inner` is taken (the recursive-entry check)
    /// and written after it, so it carries its own atomicity rather than
    /// borrowing the lock the recursive path does not hold.
    owner: std.atomic.Value(std.Thread.Id) = std.atomic.Value(std.Thread.Id).init(0),
    recursion: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: u8 = 0,
};

const SemaphoreData = struct {
    mutex: runtime.Mutex = .{},
    cond: runtime.Condition = .{},
    count: i32 = 0,
    max_count: i32 = 1,
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: u8 = 0,
};

const KernelObject = struct {
    handle: usize = 0,
    obj_type: KernelObjectType = .event,
    event: EventData = .{},
    mutex_obj: MutexData = .{},
    semaphore: SemaphoreData = .{},
};

var kernel_objects: [MAX_KERNEL_OBJECTS]KernelObject = [_]KernelObject{.{}} ** MAX_KERNEL_OBJECTS;
var next_kernel_handle: usize = 0xE0000001;

/// Serializes every scan and mutation of `kernel_objects`. A guest thread
/// creating events while another closes one would otherwise race the free-slot
/// scan: two creators can claim the same slot (one `ko.* = .{}` reset landing
/// inside the other's object) and both hand out the same synthetic handle.
var kernel_objects_mutex: runtime.Mutex = .{};

fn allocKernelObject(obj_type: KernelObjectType) ?*KernelObject {
    kernel_objects_mutex.lock();
    defer kernel_objects_mutex.unlock();
    for (&kernel_objects) |*ko| {
        if (ko.handle == 0) {
            ko.* = .{ .obj_type = obj_type };
            ko.handle = @atomicRmw(usize, &next_kernel_handle, .Add, 1, .monotonic);
            return ko;
        }
    }
    return null;
}

/// Look up a kernel object by handle.
/// Used by WaitForSingleObject/WaitForMultipleObjects.
pub fn getKernelObject(handle: usize) ?*KernelObject {
    kernel_objects_mutex.lock();
    defer kernel_objects_mutex.unlock();
    for (&kernel_objects) |*ko| {
        if (ko.handle == handle) return ko;
    }
    return null;
}

/// Release a kernel object handle via CloseHandle, freeing its registry slot.
/// Returns true when the handle belonged to this registry. Named objects are
/// not refcounted: the first close frees the object.
pub fn closeKernelObject(handle: usize) bool {
    kernel_objects_mutex.lock();
    defer kernel_objects_mutex.unlock();
    for (&kernel_objects) |*ko| {
        if (ko.handle == handle) {
            ko.* = .{};
            return true;
        }
    }
    return false;
}

fn findByName(obj_type: KernelObjectType, name: []const u8) ?*KernelObject {
    if (name.len == 0) return null;
    kernel_objects_mutex.lock();
    defer kernel_objects_mutex.unlock();
    for (&kernel_objects) |*ko| {
        if (ko.handle == 0) continue;
        if (ko.obj_type != obj_type) continue;
        const stored = switch (obj_type) {
            .event => ko.event.name[0..ko.event.name_len],
            .mutex => ko.mutex_obj.name[0..ko.mutex_obj.name_len],
            .semaphore => ko.semaphore.name[0..ko.semaphore.name_len],
        };
        if (std.mem.eql(u8, stored, name)) return ko;
    }
    return null;
}

fn copyName(dest: *[128]u8, dest_len: *u8, name: []const u8) void {
    const copy_len = @min(name.len, 127);
    @memcpy(dest[0..copy_len], name[0..copy_len]);
    dest_len.* = @intCast(copy_len);
}

// -----------------------------------------------------------------------
// Events
// -----------------------------------------------------------------------

/// CreateEventA: Creates or opens a named or unnamed event object.
/// Implementation status: Partially implemented
pub fn CreateEventA(lpEventAttributes: usize, bManualReset: i32, bInitialState: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = lpEventAttributes;
    if (trace.enable_tracing) trace.print("KERNEL32: CreateEventA(manual={d}, initial={d})\n", .{ bManualReset, bInitialState });

    // Check for existing named event
    if (lpName != 0) {
        const name = trace.c_span(lpName);
        if (findByName(.event, name)) |existing| return existing.handle;
    }

    const ko = allocKernelObject(.event) orelse return 0;
    ko.event.manual_reset = (bManualReset != 0);
    ko.event.signaled = (bInitialState != 0);

    if (lpName != 0) {
        const name = trace.c_span(lpName);
        copyName(&ko.event.name, &ko.event.name_len, name);
    }

    return ko.handle;
}

/// SetEvent: Sets the specified event object to the signaled state.
/// Implementation status: Partially implemented
pub fn SetEvent(hEvent: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: SetEvent({x})\n", .{hEvent});
    const ko = getKernelObject(hEvent) orelse return 1; // Unknown handle — succeed silently
    if (ko.obj_type != .event) return 0;
    ko.event.mutex.lock();
    defer ko.event.mutex.unlock();
    ko.event.signaled = true;
    if (ko.event.manual_reset) {
        ko.event.cond.broadcast();
    } else {
        ko.event.cond.signal();
    }
    return 1;
}

/// ResetEvent: Resets the specified event object to the nonsignaled state.
/// Implementation status: Partially implemented
pub fn ResetEvent(hEvent: usize) callconv(w32cc.WINAPI) i32 {
    const ko = getKernelObject(hEvent) orelse return 1;
    if (ko.obj_type != .event) return 0;
    ko.event.mutex.lock();
    defer ko.event.mutex.unlock();
    ko.event.signaled = false;
    return 1;
}

/// OpenEventA: Opens an existing named event object.
/// Implementation status: Partially implemented
pub fn OpenEventA(dwDesiredAccess: u32, bInheritHandle: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = dwDesiredAccess;
    _ = bInheritHandle;
    if (lpName == 0) return 0;
    const name = trace.c_span(lpName);
    if (trace.enable_tracing) trace.print("KERNEL32: OpenEventA('{s}')\n", .{name});
    if (findByName(.event, name)) |ko| return ko.handle;
    return 0; // Not found
}

// -----------------------------------------------------------------------
// WaitForSingleObject / WaitForMultipleObjects
// -----------------------------------------------------------------------

/// WAIT_OBJECT_0 = 0, WAIT_TIMEOUT = 258
/// Implementation status: Partially implemented
pub fn WaitForSingleObject(hHandle: usize, dwMilliseconds: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: WaitForSingleObject({x}, {d})\n", .{ hHandle, dwMilliseconds });

    // Check if this is a child process handle
    const process = @import("process.zig");
    if (process.getChildProc(hHandle)) |cp| {
        if (comptime platform.is_native) {
            if (cp.child) |*child| {
                if (cp.exitCode() == null) {
                    // Actually wait for the child process
                    const result = child.wait(runtime.io()) catch {
                        cp.setExitCode(1);
                        return 0; // WAIT_OBJECT_0
                    };
                    cp.setExitCode(switch (result) {
                        .exited => |code| @as(u32, code),
                        else => 1,
                    });
                }
                return 0; // WAIT_OBJECT_0
            }
        }
    }

    // Check if this is a thread handle
    if (process.getThreadInfo(hHandle)) |ti| {
        if (comptime platform.is_native) {
            // The registry hands the thread over under its lock; the join
            // itself runs outside it so the joined thread's exit path can
            // still reach the registry.
            if (ti.isRunning()) {
                if (process.takeThreadForJoin(ti)) |thread| thread.join();
            }
        }
        // On WASM, thread already ran synchronously
        return 0; // WAIT_OBJECT_0
    }

    // Check if this is a kernel object (event, mutex, semaphore)
    if (getKernelObject(hHandle)) |ko| {
        return waitOnKernelObject(ko, dwMilliseconds);
    }

    // Fallback: unknown handle — yield
    if (dwMilliseconds > 0) {
        const sleep_ns: u64 = @min(@as(u64, dwMilliseconds) * 1_000_000, 10_000_000); // Cap at 10ms
        runtime.pauseOrAdvance(sleep_ns);
    }
    return 0; // WAIT_OBJECT_0
}

/// Wait on a kernel object with timeout.
fn waitOnKernelObject(ko: *KernelObject, dwMilliseconds: u32) u32 {
    switch (ko.obj_type) {
        .event => {
            ko.event.mutex.lock();
            defer ko.event.mutex.unlock();
            if (dwMilliseconds == 0) {
                // Poll mode
                if (!ko.event.signaled) return 258; // WAIT_TIMEOUT
            } else {
                // Block until signaled or the monotonic deadline expires.
                const deadline_ms = runtime.monoMilliTimestamp() + @as(i64, dwMilliseconds);
                while (!ko.event.signaled) {
                    if (dwMilliseconds == 0xFFFFFFFF) {
                        ko.event.cond.wait(&ko.event.mutex);
                    } else {
                        ko.event.mutex.unlock();
                        // The poll interval is charged to the virtual clock
                        // when one is installed; the spin count is then a
                        // function of the timeout, not of host speed.
                        runtime.pauseOrAdvance(1_000_000); // 1ms
                        ko.event.mutex.lock();
                        if (!ko.event.signaled and runtime.monoMilliTimestamp() >= deadline_ms)
                            return 258; // WAIT_TIMEOUT (defer releases the mutex)
                    }
                }
            }
            if (!ko.event.manual_reset) {
                ko.event.signaled = false; // Auto-reset
            }
            return 0; // WAIT_OBJECT_0
        },
        .mutex => {
            const tid = std.Thread.getCurrentId();
            if (ko.mutex_obj.owner.load(.acquire) == tid) {
                _ = ko.mutex_obj.recursion.fetchAdd(1, .acq_rel);
                return 0; // WAIT_OBJECT_0
            }
            if (dwMilliseconds == 0xFFFFFFFF) {
                ko.mutex_obj.inner.lock();
            } else {
                // A finite timeout is a deadline on the monotonic clock, not a
                // hint: a mutex held elsewhere must report WAIT_TIMEOUT rather
                // than block the guest forever. dwMilliseconds == 0 polls once.
                const deadline_ms = runtime.monoMilliTimestamp() + @as(i64, dwMilliseconds);
                while (!ko.mutex_obj.inner.tryLock()) {
                    if (dwMilliseconds == 0) return 258; // WAIT_TIMEOUT
                    if (runtime.monoMilliTimestamp() >= deadline_ms) return 258; // WAIT_TIMEOUT
                    platform.sleep(1_000_000); // 1ms
                }
            }
            ko.mutex_obj.owner.store(tid, .release);
            ko.mutex_obj.recursion.store(1, .release);
            return 0; // WAIT_OBJECT_0
        },
        .semaphore => {
            ko.semaphore.mutex.lock();
            defer ko.semaphore.mutex.unlock();
            if (dwMilliseconds == 0) {
                if (ko.semaphore.count <= 0) return 258; // WAIT_TIMEOUT
            } else {
                // Block until a slot frees or the monotonic deadline expires.
                const deadline_ms = runtime.monoMilliTimestamp() + @as(i64, dwMilliseconds);
                while (ko.semaphore.count <= 0) {
                    if (dwMilliseconds == 0xFFFFFFFF) {
                        ko.semaphore.cond.wait(&ko.semaphore.mutex);
                    } else {
                        ko.semaphore.mutex.unlock();
                        runtime.pauseOrAdvance(1_000_000);
                        ko.semaphore.mutex.lock();
                        if (ko.semaphore.count <= 0 and runtime.monoMilliTimestamp() >= deadline_ms)
                            return 258; // WAIT_TIMEOUT (defer releases the mutex)
                    }
                }
            }
            ko.semaphore.count -= 1;
            return 0; // WAIT_OBJECT_0
        },
    }
}

/// Non-blocking attempt to acquire a sync object. Returns true if acquired.
fn tryAcquire(handle: usize) bool {
    // Thread handle?
    const process = @import("process.zig");
    if (process.getThreadInfo(handle)) |ti| {
        return !ti.isRunning(); // Signaled when thread has finished
    }
    // Kernel object?
    const ko = getKernelObject(handle) orelse return true; // Unknown handle = signaled
    switch (ko.obj_type) {
        .event => {
            ko.event.mutex.lock();
            defer ko.event.mutex.unlock();
            if (ko.event.signaled) {
                if (!ko.event.manual_reset) ko.event.signaled = false;
                return true;
            }
            return false;
        },
        .mutex => {
            const tid = std.Thread.getCurrentId();
            if (ko.mutex_obj.owner.load(.acquire) == tid) {
                _ = ko.mutex_obj.recursion.fetchAdd(1, .acq_rel);
                return true;
            }
            if (ko.mutex_obj.inner.tryLock()) {
                ko.mutex_obj.owner.store(tid, .release);
                ko.mutex_obj.recursion.store(1, .release);
                return true;
            }
            return false;
        },
        .semaphore => {
            ko.semaphore.mutex.lock();
            defer ko.semaphore.mutex.unlock();
            if (ko.semaphore.count > 0) {
                ko.semaphore.count -= 1;
                return true;
            }
            return false;
        },
    }
}

/// Check if a sync object is signaled without acquiring it.
fn isSignaled(handle: usize) bool {
    const process = @import("process.zig");
    if (process.getThreadInfo(handle)) |ti| return !ti.isRunning();
    const ko = getKernelObject(handle) orelse return true;
    // Each flag is written under its own object lock by the setter, so the
    // poll has to read it under that lock too.
    return switch (ko.obj_type) {
        .event => blk: {
            ko.event.mutex.lock();
            defer ko.event.mutex.unlock();
            break :blk ko.event.signaled;
        },
        .mutex => blk: {
            const owner = ko.mutex_obj.owner.load(.acquire);
            break :blk owner == 0 or owner == std.Thread.getCurrentId();
        },
        .semaphore => blk: {
            ko.semaphore.mutex.lock();
            defer ko.semaphore.mutex.unlock();
            break :blk ko.semaphore.count > 0;
        },
    };
}

/// WaitForMultipleObjects: Waits until one or all of the specified objects are signaled.
/// Implementation status: Partially implemented
pub fn WaitForMultipleObjects(nCount: u32, lpHandles: usize, bWaitAll: i32, dwMilliseconds: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: WaitForMultipleObjects(n={d}, all={d}, ms={d})\n", .{ nCount, bWaitAll, dwMilliseconds });

    if (nCount == 0 or lpHandles == 0) return 258; // WAIT_TIMEOUT

    const handles = @as([*]const u32, @ptrFromInt(lpHandles));
    const count = @min(nCount, 64); // Win32 max is MAXIMUM_WAIT_OBJECTS (64)

    if (bWaitAll == 0) {
        // Wait for ANY — poll each handle, return first signaled
        var iterations: u32 = 0;
        while (true) {
            for (0..count) |i| {
                const h: usize = handles[i];
                if (tryAcquire(h)) return @intCast(i); // WAIT_OBJECT_0 + i
            }
            if (dwMilliseconds == 0) return 258; // WAIT_TIMEOUT
            iterations += 1;
            if (dwMilliseconds != 0xFFFFFFFF and iterations >= dwMilliseconds) return 258;
            @import("../../platform.zig").sleep(1_000_000); // 1ms between polls
        }
    } else {
        // Wait for ALL
        var iterations: u32 = 0;
        while (true) {
            var all_signaled = true;
            for (0..count) |i| {
                if (!isSignaled(handles[i])) {
                    all_signaled = false;
                    break;
                }
            }
            if (all_signaled) {
                // Acquire all
                for (0..count) |i| _ = tryAcquire(handles[i]);
                return 0; // WAIT_OBJECT_0
            }
            if (dwMilliseconds == 0) return 258;
            iterations += 1;
            if (dwMilliseconds != 0xFFFFFFFF and iterations >= dwMilliseconds) return 258;
            @import("../../platform.zig").sleep(1_000_000);
        }
    }
}

// -----------------------------------------------------------------------
// Thread Local Storage
// -----------------------------------------------------------------------
// Per-thread TLS using thread ID as key

var tls_mutex: runtime.Mutex = .{};
var tls_next: u32 = 0;
const MAX_TLS_SLOTS = 64;
const MAX_TLS_THREADS = 16;

const TlsThreadEntry = struct {
    thread_id: u64,
    slots: [MAX_TLS_SLOTS]usize,
};

var tls_threads: [MAX_TLS_THREADS]TlsThreadEntry = init: {
    var entries: [MAX_TLS_THREADS]TlsThreadEntry = undefined;
    for (&entries) |*e| {
        e.thread_id = 0;
        e.slots = [_]usize{0} ** MAX_TLS_SLOTS;
    }
    break :init entries;
};

fn getOrCreateTlsEntry() *TlsThreadEntry {
    const tid = std.Thread.getCurrentId();
    // Find existing entry for this thread
    for (&tls_threads) |*entry| {
        if (entry.thread_id == tid) return entry;
    }
    // Find a free slot
    for (&tls_threads) |*entry| {
        if (entry.thread_id == 0) {
            entry.thread_id = tid;
            return entry;
        }
    }
    // Fallback: reuse first slot (shouldn't happen with MAX_TLS_THREADS=16)
    return &tls_threads[0];
}

/// Implementation status: Partially implemented
pub fn TlsAlloc() callconv(w32cc.WINAPI) u32 {
    tls_mutex.lock();
    defer tls_mutex.unlock();
    if (tls_next >= MAX_TLS_SLOTS) return 0xFFFFFFFF; // TLS_OUT_OF_INDEXES
    const idx = tls_next;
    tls_next += 1;
    return idx;
}

/// Implementation status: Partially implemented
pub fn TlsGetValue(dwTlsIndex: u32) callconv(w32cc.WINAPI) usize {
    tls_mutex.lock();
    defer tls_mutex.unlock();
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    const entry = getOrCreateTlsEntry();
    return entry.slots[dwTlsIndex];
}

/// Implementation status: Partially implemented
pub fn TlsSetValue(dwTlsIndex: u32, lpTlsValue: usize) callconv(w32cc.WINAPI) i32 {
    tls_mutex.lock();
    defer tls_mutex.unlock();
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    const entry = getOrCreateTlsEntry();
    entry.slots[dwTlsIndex] = lpTlsValue;
    return 1;
}

/// Implementation status: Partially implemented
pub fn TlsFree(dwTlsIndex: u32) callconv(w32cc.WINAPI) i32 {
    tls_mutex.lock();
    defer tls_mutex.unlock();
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    // Clear the value in all thread entries
    for (&tls_threads) |*entry| {
        if (entry.thread_id != 0) {
            entry.slots[dwTlsIndex] = 0;
        }
    }
    return 1; // TRUE
}

// -----------------------------------------------------------------------
// Mutexes
// -----------------------------------------------------------------------

/// CreateMutexA: Creates or opens a named or unnamed mutex object.
/// Implementation status: Partially implemented
pub fn CreateMutexA(lpMutexAttributes: usize, bInitialOwner: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = lpMutexAttributes;
    if (lpName != 0) {
        const name = trace.c_span(lpName);
        if (trace.enable_tracing) trace.print("KERNEL32: CreateMutexA('{s}')\n", .{name});
        if (findByName(.mutex, name)) |existing| return existing.handle;
    } else {
        if (trace.enable_tracing) trace.print("KERNEL32: CreateMutexA(unnamed)\n", .{});
    }

    const ko = allocKernelObject(.mutex) orelse return 0;
    if (bInitialOwner != 0) {
        ko.mutex_obj.inner.lock();
        ko.mutex_obj.owner.store(std.Thread.getCurrentId(), .release);
        ko.mutex_obj.recursion.store(1, .release);
    }

    if (lpName != 0) {
        const name = trace.c_span(lpName);
        copyName(&ko.mutex_obj.name, &ko.mutex_obj.name_len, name);
    }

    return ko.handle;
}

/// ReleaseMutex: Releases ownership of the specified mutex object.
/// Implementation status: Partially implemented
pub fn ReleaseMutex(hMutex: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: ReleaseMutex({x})\n", .{hMutex});
    const ko = getKernelObject(hMutex) orelse return 1; // Unknown handle — succeed silently
    if (ko.obj_type != .mutex) return 0;
    const recursion = ko.mutex_obj.recursion.load(.acquire);
    if (recursion > 1) {
        _ = ko.mutex_obj.recursion.fetchSub(1, .acq_rel);
        return 1;
    }
    ko.mutex_obj.owner.store(0, .release);
    ko.mutex_obj.recursion.store(0, .release);
    ko.mutex_obj.inner.unlock();
    return 1; // TRUE = success
}

// -----------------------------------------------------------------------
// Semaphores
// -----------------------------------------------------------------------

/// CreateSemaphoreA: Creates or opens a named or unnamed semaphore object.
/// Implementation status: Partially implemented
pub fn CreateSemaphoreA(lpSemaphoreAttributes: usize, lInitialCount: i32, lMaximumCount: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = lpSemaphoreAttributes;
    if (lpName != 0) {
        const name = trace.c_span(lpName);
        if (trace.enable_tracing) trace.print("KERNEL32: CreateSemaphoreA('{s}')\n", .{name});
        if (findByName(.semaphore, name)) |existing| return existing.handle;
    } else {
        if (trace.enable_tracing) trace.print("KERNEL32: CreateSemaphoreA(unnamed, init={d}, max={d})\n", .{ lInitialCount, lMaximumCount });
    }

    const ko = allocKernelObject(.semaphore) orelse return 0;
    ko.semaphore.count = lInitialCount;
    ko.semaphore.max_count = lMaximumCount;

    if (lpName != 0) {
        const name = trace.c_span(lpName);
        copyName(&ko.semaphore.name, &ko.semaphore.name_len, name);
    }

    return ko.handle;
}

/// ReleaseSemaphore: Increases the count of the specified semaphore object.
/// Implementation status: Partially implemented
pub fn ReleaseSemaphore(hSemaphore: usize, lReleaseCount: i32, lpPreviousCount: usize) callconv(w32cc.WINAPI) i32 {
    const ko = getKernelObject(hSemaphore) orelse {
        if (lpPreviousCount != 0) @as(*i32, @ptrFromInt(lpPreviousCount)).* = 0;
        return 1;
    };
    if (ko.obj_type != .semaphore) {
        if (lpPreviousCount != 0) @as(*i32, @ptrFromInt(lpPreviousCount)).* = 0;
        return 1;
    }
    ko.semaphore.mutex.lock();
    defer ko.semaphore.mutex.unlock();
    if (lpPreviousCount != 0) @as(*i32, @ptrFromInt(lpPreviousCount)).* = ko.semaphore.count;
    ko.semaphore.count = @min(ko.semaphore.count + lReleaseCount, ko.semaphore.max_count);
    // Wake waiters
    var i: i32 = 0;
    while (i < lReleaseCount) : (i += 1) {
        ko.semaphore.cond.signal();
    }
    return 1;
}

// -----------------------------------------------------------------------
// DuplicateHandle
// -----------------------------------------------------------------------

var next_dup_handle: usize = 0xD0000001;

/// Implementation status: Partially implemented
pub fn DuplicateHandle(
    hSourceProcessHandle: usize,
    hSourceHandle: usize,
    hTargetProcessHandle: usize,
    lpTargetHandle: usize,
    dwDesiredAccess: u32,
    bInheritHandle: i32,
    dwOptions: u32,
) callconv(w32cc.WINAPI) i32 {
    _ = hSourceProcessHandle;
    _ = hTargetProcessHandle;
    _ = dwDesiredAccess;
    _ = bInheritHandle;
    _ = dwOptions;
    if (trace.enable_tracing) trace.print("KERNEL32: DuplicateHandle(src={x})\n", .{hSourceHandle});
    if (lpTargetHandle == 0) return 1;

    // For real file descriptors (small values), use dup()
    if (comptime platform.is_native) {
        if (hSourceHandle < 0x10000) {
            const src_fd = @as(i32, @bitCast(@as(u32, @truncate(hSourceHandle))));
            const new_fd = platform.dup(src_fd) catch {
                // Fallback to fake handle
                @as(*u32, @ptrFromInt(lpTargetHandle)).* = @truncate(@atomicRmw(usize, &next_dup_handle, .Add, 1, .monotonic));
                return 1;
            };
            if (trace.enable_tracing) trace.print("KERNEL32: DuplicateHandle fd {d} -> {d}\n", .{ src_fd, new_fd });
            @as(*u32, @ptrFromInt(lpTargetHandle)).* = @as(u32, @bitCast(new_fd));
            return 1;
        }
    }

    // Synthetic handle: return a new fake one
    @as(*u32, @ptrFromInt(lpTargetHandle)).* = @truncate(@atomicRmw(usize, &next_dup_handle, .Add, 1, .monotonic));
    return 1; // TRUE = success
}

// -----------------------------------------------------------------------
// InterlockedCompareExchange / InterlockedExchange
// -----------------------------------------------------------------------

/// LONG InterlockedCompareExchange(LONG volatile *Destination, LONG Exchange, LONG Comperand)
/// Implementation status: Partially implemented
pub fn InterlockedCompareExchange(dest: usize, exchange: i32, comperand: i32) callconv(w32cc.WINAPI) i32 {
    if (dest == 0) return 0;
    const ptr = @as(*i32, @ptrFromInt(dest));
    return @cmpxchgStrong(i32, ptr, comperand, exchange, .seq_cst, .seq_cst) orelse comperand;
}

/// Implementation status: Partially implemented
pub fn InterlockedExchange(target: usize, value: i32) callconv(w32cc.WINAPI) i32 {
    if (target == 0) return 0;
    const ptr = @as(*i32, @ptrFromInt(target));
    return @atomicRmw(i32, ptr, .Xchg, value, .seq_cst);
}

// -----------------------------------------------------------------------
// File Change Notifications (stub)
// -----------------------------------------------------------------------

var next_change_handle: usize = 0xCE000001;

/// Implementation status: No-op fallback
pub fn stub_FindFirstChangeNotificationW(path_ptr: usize, watch_subtree: i32, filter: u32) callconv(w32cc.WINAPI) usize {
    _ = path_ptr;
    _ = watch_subtree;
    _ = filter;
    const h = @atomicRmw(usize, &next_change_handle, .Add, 1, .monotonic);
    if (trace.enable_tracing) trace.print("KERNEL32: FindFirstChangeNotificationW -> {x}\n", .{h});
    return h;
}

/// Implementation status: No-op fallback
pub fn stub_FindNextChangeNotification(hChangeHandle: usize) callconv(w32cc.WINAPI) i32 {
    _ = hChangeHandle;
    return 1; // TRUE
}

// -----------------------------------------------------------------------
// SList (Interlocked Singly Linked Lists)
// -----------------------------------------------------------------------

/// Implementation status: Partially implemented
pub fn InitializeSListHead(ListHead: usize) callconv(w32cc.WINAPI) void {
    // SLIST_HEADER is 8 bytes on x86 — zero it out
    if (ListHead != 0) {
        @memset(@as([*]u8, @ptrFromInt(ListHead))[0..8], 0);
    }
}

/// Implementation status: Partially implemented
pub fn InterlockedFlushSList(ListHead: usize) callconv(w32cc.WINAPI) usize {
    if (ListHead != 0) {
        // Read the first pointer (first 4 bytes of SLIST_HEADER)
        const first: usize = @as(*u32, @ptrFromInt(ListHead)).*;
        @as(*u32, @ptrFromInt(ListHead)).* = 0; // Clear the list
        return first;
    }
    return 0; // Empty list
}

// -----------------------------------------------------------------------
// Extended Critical Sections
// -----------------------------------------------------------------------

/// Implementation status: Partially implemented
pub fn InitializeCriticalSectionEx(lpCriticalSection: usize, dwSpinCount: u32, flags: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: InitializeCriticalSectionEx(cs={X}, spin={d}, flags={X})\n", .{ lpCriticalSection, dwSpinCount, flags });
    InitializeCriticalSection(lpCriticalSection);
    return 1; // TRUE = success
}

/// Implementation status: Partially implemented
pub fn InitializeCriticalSectionAndSpinCount(lpCriticalSection: usize, dwSpinCount: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: InitializeCriticalSectionAndSpinCount(cs={X}, spin={d})\n", .{ lpCriticalSection, dwSpinCount });
    InitializeCriticalSection(lpCriticalSection);
    return 1; // TRUE = success
}

// -----------------------------------------------------------------------
// Pointer Encoding (identity transform in emulation)
// -----------------------------------------------------------------------

/// Implementation status: Partially implemented
pub fn EncodePointer(ptr: usize) callconv(w32cc.WINAPI) usize {
    return ptr; // No encoding needed
}

/// Implementation status: Partially implemented
pub fn DecodePointer(ptr: usize) callconv(w32cc.WINAPI) usize {
    return ptr; // No decoding needed
}

// -----------------------------------------------------------------------
// Fiber Local Storage (FLS)
// -----------------------------------------------------------------------

var fls_next: u32 = 0;
const MAX_FLS_SLOTS = 128;
var fls_values: [MAX_FLS_SLOTS]usize = [_]usize{0} ** MAX_FLS_SLOTS;
var fls_callbacks: [MAX_FLS_SLOTS]usize = [_]usize{0} ** MAX_FLS_SLOTS;
/// The tables above are shared by every guest thread, so allocation (a
/// check-then-claim over `fls_next`) and value access take the same lock the
/// TLS stubs use. Without it two threads calling FlsAlloc race for one index
/// and their values alias.
var fls_mutex: runtime.Mutex = .{};

/// FLS is like TLS but per-fiber. We're single-fiber, so just use simple slots.
/// Implementation status: Partially implemented
pub fn FlsAlloc(lpCallback: usize) callconv(w32cc.WINAPI) u32 {
    fls_mutex.lock();
    defer fls_mutex.unlock();
    if (fls_next >= MAX_FLS_SLOTS) return 0xFFFFFFFF; // FLS_OUT_OF_INDEXES
    const idx = fls_next;
    fls_callbacks[idx] = lpCallback;
    fls_values[idx] = 0;
    fls_next += 1;
    if (trace.enable_tracing) trace.print("KERNEL32: FlsAlloc -> {d}\n", .{idx});
    return idx;
}

/// Implementation status: Partially implemented
pub fn FlsGetValue(dwFlsIndex: u32) callconv(w32cc.WINAPI) usize {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    fls_mutex.lock();
    defer fls_mutex.unlock();
    return fls_values[dwFlsIndex];
}

/// Implementation status: Partially implemented
pub fn FlsSetValue(dwFlsIndex: u32, lpFlsData: usize) callconv(w32cc.WINAPI) i32 {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    fls_mutex.lock();
    defer fls_mutex.unlock();
    fls_values[dwFlsIndex] = lpFlsData;
    return 1; // TRUE
}

/// Implementation status: Partially implemented
pub fn FlsFree(dwFlsIndex: u32) callconv(w32cc.WINAPI) i32 {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    fls_mutex.lock();
    defer fls_mutex.unlock();
    fls_values[dwFlsIndex] = 0;
    fls_callbacks[dwFlsIndex] = 0;
    return 1; // TRUE
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "critical sections serialize recursive access during concurrent registration" {
    const saved_sections = cs_table;
    defer cs_table = saved_sections;
    cs_table = [_]CriticalSection{.{}} ** MAX_CRITICAL_SECTIONS;

    const Context = struct {
        start: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        count: usize = 0,

        fn run(ctx: *@This(), addr: usize) void {
            while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();
            for (0..1000) |_| {
                InitializeCriticalSection(addr);
                EnterCriticalSection(addr);
                EnterCriticalSection(1);
                EnterCriticalSection(1);
                ctx.count += 1;
                LeaveCriticalSection(1);
                LeaveCriticalSection(1);
                LeaveCriticalSection(addr);
                DeleteCriticalSection(addr);
            }
        }
    };
    var ctx: Context = .{};
    InitializeCriticalSection(1);
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    {
        defer {
            ctx.start.store(true, .release);
            for (threads[0..spawned]) |thread| thread.join();
        }
        for (&threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, Context.run, .{ &ctx, i + 2 });
            spawned += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 8000), ctx.count);
    const cs = getOrCreateCS(1).?;
    try std.testing.expectEqual(@as(std.Thread.Id, 0), cs.owner.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), cs.recursion);
    try std.testing.expect(cs.mutex.tryLock());
    cs.mutex.unlock();
    DeleteCriticalSection(1);
    for (&cs_table) |*entry| try std.testing.expectEqual(@as(usize, 0), entry.addr);
}

test "TLS allocation and values remain isolated across concurrent threads" {
    const saved_next = tls_next;
    const saved_threads = tls_threads;
    defer {
        tls_next = saved_next;
        tls_threads = saved_threads;
    }
    tls_next = 0;
    for (&tls_threads) |*entry| entry.* = .{ .thread_id = 0, .slots = [_]usize{0} ** MAX_TLS_SLOTS };

    const Context = struct {
        start: std.atomic.Value(bool) = .init(false),
        indices: [8][8]u32 = undefined,
        valid: [8]bool = [_]bool{true} ** 8,

        fn run(ctx: *@This(), worker: usize) void {
            while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();
            for (&ctx.indices[worker]) |*index| index.* = TlsAlloc();
            for (0..1000) |iteration| {
                const value = (worker + 1) * 1000 + iteration;
                if (TlsSetValue(0, value) != 1 or TlsGetValue(0) != value) ctx.valid[worker] = false;
                _ = TlsFree(1);
            }
        }
    };
    var ctx: Context = .{};
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    {
        defer {
            ctx.start.store(true, .release);
            for (threads[0..spawned]) |thread| thread.join();
        }
        for (&threads, 0..) |*thread, worker| {
            thread.* = try std.Thread.spawn(.{}, Context.run, .{ &ctx, worker });
            spawned += 1;
        }
    }
    var seen: [MAX_TLS_SLOTS]bool = [_]bool{false} ** MAX_TLS_SLOTS;
    for (ctx.indices, ctx.valid) |indices, valid| {
        try std.testing.expect(valid);
        for (indices) |index| {
            try std.testing.expect(index < MAX_TLS_SLOTS);
            try std.testing.expect(!seen[index]);
            seen[index] = true;
        }
    }
    try std.testing.expectEqual(@as(u32, MAX_TLS_SLOTS), tls_next);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), TlsAlloc());
}

test "CloseHandle frees kernel object slots" {
    const saved_objects = kernel_objects;
    defer kernel_objects = saved_objects;
    kernel_objects = [_]KernelObject{.{}} ** MAX_KERNEL_OBJECTS;

    const h = CreateEventA(0, 0, 0, 0);
    try std.testing.expect(h != 0);
    try std.testing.expect(getKernelObject(h) != null);

    // Closing must free the slot: a fresh create succeeds and the old handle
    // is gone from the registry.
    try std.testing.expect(closeKernelObject(h));
    try std.testing.expect(getKernelObject(h) == null);
    try std.testing.expect(CreateEventA(0, 0, 0, 0) != 0);
}

test "closeKernelObject ignores unknown handles" {
    const saved_objects = kernel_objects;
    defer kernel_objects = saved_objects;
    kernel_objects = [_]KernelObject{.{}} ** MAX_KERNEL_OBJECTS;
    try std.testing.expect(!closeKernelObject(0xE0000001));
}

test "WaitForSingleObject times out on unsignaled event" {
    const saved_objects = kernel_objects;
    defer kernel_objects = saved_objects;
    kernel_objects = [_]KernelObject{.{}} ** MAX_KERNEL_OBJECTS;

    // Auto-reset event created nonsignaled: a finite wait must return
    // WAIT_TIMEOUT instead of blocking forever.
    const h = CreateEventA(0, 0, 0, 0);
    try std.testing.expect(h != 0);
    const started = runtime.monoMilliTimestamp();
    try std.testing.expectEqual(@as(u32, 258), WaitForSingleObject(h, 40));
    const elapsed = runtime.monoMilliTimestamp() - started;
    try std.testing.expect(elapsed >= 30); // honored at least roughly
    try std.testing.expect(elapsed < 5000); // and did not hang
}

test "event signaled during timed wait returns WAIT_OBJECT_0" {
    const saved_objects = kernel_objects;
    defer kernel_objects = saved_objects;
    kernel_objects = [_]KernelObject{.{}} ** MAX_KERNEL_OBJECTS;

    const h = CreateEventA(0, 0, 0, 0);
    try std.testing.expect(h != 0);
    const waiter = try std.Thread.spawn(.{}, struct {
        fn run(handle: usize) void {
            platform.sleep(20 * std.time.ns_per_ms);
            _ = SetEvent(handle);
        }
    }.run, .{h});
    defer waiter.join();
    try std.testing.expectEqual(@as(u32, 0), WaitForSingleObject(h, 10_000));
}

test "semaphore timed wait returns WAIT_TIMEOUT when empty" {
    const saved_objects = kernel_objects;
    defer kernel_objects = saved_objects;
    kernel_objects = [_]KernelObject{.{}} ** MAX_KERNEL_OBJECTS;

    const ko = allocKernelObject(.semaphore) orelse return error.NoSlots;
    ko.semaphore.max_count = 4;
    try std.testing.expectEqual(@as(u32, 258), WaitForSingleObject(ko.handle, 30));
}

test "WaitForSingleObject times out on a mutex held by another thread" {
    const saved_objects = kernel_objects;
    defer kernel_objects = saved_objects;
    kernel_objects = [_]KernelObject{.{}} ** MAX_KERNEL_OBJECTS;

    const ko = allocKernelObject(.mutex) orelse return error.NoSlots;
    // Held without recording an owner, so the waiter takes the contended path
    // rather than the recursive one.
    ko.mutex_obj.inner.lock();
    defer ko.mutex_obj.inner.unlock();

    const started = runtime.monoMilliTimestamp();
    try std.testing.expectEqual(@as(u32, 258), WaitForSingleObject(ko.handle, 40));
    const elapsed = runtime.monoMilliTimestamp() - started;
    try std.testing.expect(elapsed >= 30); // honored at least roughly
    try std.testing.expect(elapsed < 5000); // and returned instead of hanging

    // A zero timeout polls once and must not sleep.
    const poll_started = runtime.monoMilliTimestamp();
    try std.testing.expectEqual(@as(u32, 258), WaitForSingleObject(ko.handle, 0));
    try std.testing.expect(runtime.monoMilliTimestamp() - poll_started < 1000);
}
