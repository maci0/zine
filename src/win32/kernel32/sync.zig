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
    owner: std.Thread.Id = 0,
    recursion: u32 = 0,
    addr: usize = 0,
};

var cs_table: [MAX_CRITICAL_SECTIONS]CriticalSection = init_cs: {
    var arr: [MAX_CRITICAL_SECTIONS]CriticalSection = undefined;
    for (&arr) |*cs| cs.* = .{};
    break :init_cs arr;
};

fn getOrCreateCS(addr: usize) ?*CriticalSection {
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
    if (cs.owner == tid) {
        // Recursive entry — same thread, just bump count
        cs.recursion += 1;
        return;
    }
    cs.mutex.lock();
    cs.owner = tid;
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
    cs.owner = 0;
    cs.recursion = 0;
    cs.mutex.unlock();
}

/// Implementation status: Partially implemented
pub fn DeleteCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: DeleteCriticalSection({x})\n", .{lpCriticalSection});
    if (lpCriticalSection == 0) return;
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
    owner: std.Thread.Id = 0,
    recursion: u32 = 0,
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

fn allocKernelObject(obj_type: KernelObjectType) ?*KernelObject {
    for (&kernel_objects) |*ko| {
        if (ko.handle == 0) {
            ko.* = .{ .obj_type = obj_type };
            ko.handle = next_kernel_handle;
            next_kernel_handle += 1;
            return ko;
        }
    }
    return null;
}

/// Look up a kernel object by handle.
/// Used by WaitForSingleObject/WaitForMultipleObjects.
pub fn getKernelObject(handle: usize) ?*KernelObject {
    for (&kernel_objects) |*ko| {
        if (ko.handle == handle) return ko;
    }
    return null;
}

/// Release a kernel object handle via CloseHandle, freeing its registry slot.
/// Returns true when the handle belonged to this registry. Named objects are
/// not refcounted: the first close frees the object.
pub fn closeKernelObject(handle: usize) bool {
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
                if (cp.exit_code == null) {
                    // Actually wait for the child process
                    const result = child.wait(runtime.io()) catch {
                        cp.exit_code = 1;
                        return 0; // WAIT_OBJECT_0
                    };
                    cp.exit_code = switch (result) {
                        .exited => |code| @as(u32, code),
                        else => 1,
                    };
                }
                return 0; // WAIT_OBJECT_0
            }
        }
    }

    // Check if this is a thread handle
    if (process.getThreadInfo(hHandle)) |ti| {
        if (comptime platform.is_native) {
            if (ti.thread) |thread| {
                if (ti.running) {
                    thread.join();
                    ti.thread = null;
                }
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
        @import("../../platform.zig").sleep(sleep_ns);
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
                // Block until signaled
                while (!ko.event.signaled) {
                    if (dwMilliseconds == 0xFFFFFFFF) {
                        ko.event.cond.wait(&ko.event.mutex);
                    } else {
                        // Timed wait — use polling with sleep
                        ko.event.mutex.unlock();
                        @import("../../platform.zig").sleep(1_000_000); // 1ms
                        ko.event.mutex.lock();
                        // For simplicity, just check again — real timeout tracking TBD
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
            if (ko.mutex_obj.owner == tid) {
                ko.mutex_obj.recursion += 1;
                return 0; // WAIT_OBJECT_0
            }
            if (dwMilliseconds == 0) {
                if (ko.mutex_obj.inner.tryLock()) {
                    ko.mutex_obj.owner = tid;
                    ko.mutex_obj.recursion = 1;
                    return 0;
                }
                return 258; // WAIT_TIMEOUT
            }
            ko.mutex_obj.inner.lock();
            ko.mutex_obj.owner = tid;
            ko.mutex_obj.recursion = 1;
            return 0; // WAIT_OBJECT_0
        },
        .semaphore => {
            ko.semaphore.mutex.lock();
            defer ko.semaphore.mutex.unlock();
            if (dwMilliseconds == 0) {
                if (ko.semaphore.count <= 0) return 258; // WAIT_TIMEOUT
            } else {
                while (ko.semaphore.count <= 0) {
                    if (dwMilliseconds == 0xFFFFFFFF) {
                        ko.semaphore.cond.wait(&ko.semaphore.mutex);
                    } else {
                        ko.semaphore.mutex.unlock();
                        @import("../../platform.zig").sleep(1_000_000);
                        ko.semaphore.mutex.lock();
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
        return !ti.running; // Signaled when thread has finished
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
            if (ko.mutex_obj.owner == tid) {
                ko.mutex_obj.recursion += 1;
                return true;
            }
            if (ko.mutex_obj.inner.tryLock()) {
                ko.mutex_obj.owner = tid;
                ko.mutex_obj.recursion = 1;
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
    if (process.getThreadInfo(handle)) |ti| return !ti.running;
    const ko = getKernelObject(handle) orelse return true;
    return switch (ko.obj_type) {
        .event => ko.event.signaled,
        .mutex => ko.mutex_obj.owner == 0 or ko.mutex_obj.owner == std.Thread.getCurrentId(),
        .semaphore => ko.semaphore.count > 0,
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
    if (tls_next >= MAX_TLS_SLOTS) return 0xFFFFFFFF; // TLS_OUT_OF_INDEXES
    const idx = tls_next;
    tls_next += 1;
    return idx;
}

/// Implementation status: Partially implemented
pub fn TlsGetValue(dwTlsIndex: u32) callconv(w32cc.WINAPI) usize {
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    const entry = getOrCreateTlsEntry();
    return entry.slots[dwTlsIndex];
}

/// Implementation status: Partially implemented
pub fn TlsSetValue(dwTlsIndex: u32, lpTlsValue: usize) callconv(w32cc.WINAPI) i32 {
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    const entry = getOrCreateTlsEntry();
    entry.slots[dwTlsIndex] = lpTlsValue;
    return 1;
}

/// Implementation status: Partially implemented
pub fn TlsFree(dwTlsIndex: u32) callconv(w32cc.WINAPI) i32 {
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
        ko.mutex_obj.owner = std.Thread.getCurrentId();
        ko.mutex_obj.recursion = 1;
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
    if (ko.mutex_obj.recursion > 1) {
        ko.mutex_obj.recursion -= 1;
        return 1;
    }
    ko.mutex_obj.owner = 0;
    ko.mutex_obj.recursion = 0;
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
                @as(*u32, @ptrFromInt(lpTargetHandle)).* = @truncate(next_dup_handle);
                next_dup_handle += 1;
                return 1;
            };
            if (trace.enable_tracing) trace.print("KERNEL32: DuplicateHandle fd {d} -> {d}\n", .{ src_fd, new_fd });
            @as(*u32, @ptrFromInt(lpTargetHandle)).* = @as(u32, @bitCast(new_fd));
            return 1;
        }
    }

    // Synthetic handle: return a new fake one
    @as(*u32, @ptrFromInt(lpTargetHandle)).* = @truncate(next_dup_handle);
    next_dup_handle += 1;
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
    const h = next_change_handle;
    next_change_handle += 1;
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

/// FLS is like TLS but per-fiber. We're single-fiber, so just use simple slots.
/// Implementation status: Partially implemented
pub fn FlsAlloc(lpCallback: usize) callconv(w32cc.WINAPI) u32 {
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
    return fls_values[dwFlsIndex];
}

/// Implementation status: Partially implemented
pub fn FlsSetValue(dwFlsIndex: u32, lpFlsData: usize) callconv(w32cc.WINAPI) i32 {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    fls_values[dwFlsIndex] = lpFlsData;
    return 1; // TRUE
}

/// Implementation status: Partially implemented
pub fn FlsFree(dwFlsIndex: u32) callconv(w32cc.WINAPI) i32 {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    fls_values[dwFlsIndex] = 0;
    fls_callbacks[dwFlsIndex] = 0;
    return 1; // TRUE
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

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
