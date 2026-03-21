---
phase: 2
plan: 1
title: Sync Primitives Implementation
wave: 1
depends_on: []
files_modified:
  - src/win32/kernel32/sync.zig
  - src/win32/kernel32.zig
  - src/win32/kernel32/process.zig
autonomous: true
requirements_addressed: [THREAD-02, THREAD-03, THREAD-04, THREAD-05]
---

# Plan 01: Sync Primitives Implementation

<objective>
Implement Win32 events (auto-reset, manual-reset), mutexes (recursive, named), and WaitForMultipleObjects with proper blocking semantics using a unified kernel object registry.
</objective>

<must_haves>
- Events signal/unsignal correctly (auto-reset releases one waiter, manual-reset releases all)
- Mutexes are recursive (same thread can acquire multiple times)
- WaitForSingleObject dispatches on event/mutex/semaphore handles
- WaitForMultipleObjects supports bWaitAll=TRUE and bWaitAll=FALSE
- Named objects can be looked up by name (OpenEventA, OpenMutexA)
- Thread handle range doesn't collide with semaphore handles
</must_haves>

## Tasks

### Task 1: Add unified kernel object registry to sync.zig

<read_first>
- src/win32/kernel32/sync.zig (full file — existing handle counters and stubs)
- src/win32/kernel32/process.zig (lines 905-920 — thread handle range 0xA0000001)
</read_first>

<action>
Add a unified kernel object registry at the top of sync.zig (after the interlocked operations):

```zig
// --- Kernel Object Registry ---
// Unified handle table for Events, Mutexes, and Semaphores.
// WaitForSingleObject/WaitForMultipleObjects dispatch on object type.

const MAX_KERNEL_OBJECTS = 128;

const KernelObjectType = enum { event, mutex, semaphore };

const EventData = struct {
    manual_reset: bool = false,
    signaled: bool = false,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: u8 = 0,
};

const MutexData = struct {
    mutex: std.Thread.Mutex = .{},
    owner: std.Thread.Id = 0,
    recursion: u32 = 0,
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: u8 = 0,
};

const SemaphoreData = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    count: i32 = 0,
    max_count: i32 = 1,
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: u8 = 0,
};

const KernelObject = struct {
    handle: usize = 0,
    obj_type: KernelObjectType = .event,
    event: EventData = .{},
    mutex_data: MutexData = .{},    // "mutex_data" to avoid shadowing std.Thread.Mutex
    semaphore: SemaphoreData = .{},
};

var kernel_objects: [MAX_KERNEL_OBJECTS]KernelObject = [_]KernelObject{.{}} ** MAX_KERNEL_OBJECTS;
var next_kernel_handle: usize = 0xE0000001;  // Unified range for all kernel objects

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

pub fn getKernelObject(handle: usize) ?*KernelObject {
    for (&kernel_objects) |*ko| {
        if (ko.handle == handle) return ko;
    }
    return null;
}

fn findByName(obj_type: KernelObjectType, name: []const u8) ?*KernelObject {
    for (&kernel_objects) |*ko| {
        if (ko.handle == 0) continue;
        if (ko.obj_type != obj_type) continue;
        const stored_name = switch (obj_type) {
            .event => ko.event.name[0..ko.event.name_len],
            .mutex => ko.mutex_data.name[0..ko.mutex_data.name_len],
            .semaphore => ko.semaphore.name[0..ko.semaphore.name_len],
        };
        if (std.mem.eql(u8, stored_name, name)) return ko;
    }
    return null;
}
```

Also fix the thread handle range collision: change `next_thread_handle` in process.zig from `0xA0000001` to `0xA0010001` to avoid overlapping with semaphore handles.
</action>

<acceptance_criteria>
- `sync.zig` contains `const KernelObject = struct {`
- `sync.zig` contains `var kernel_objects: [MAX_KERNEL_OBJECTS]KernelObject`
- `sync.zig` contains `pub fn getKernelObject(`
- `sync.zig` contains `fn findByName(`
- `process.zig` thread handle range changed to avoid collision
</acceptance_criteria>

---

### Task 2: Implement CreateEventA and event operations

<read_first>
- src/win32/kernel32/sync.zig (lines 94-117 — existing event stubs)
</read_first>

<action>
Replace `stub_CreateEventA`, `stub_SetEvent`, `stub_ResetEvent` with real implementations:

```zig
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
        const copy_len = @min(name.len, 127);
        @memcpy(ko.event.name[0..copy_len], name[0..copy_len]);
        ko.event.name_len = @intCast(copy_len);
    }

    return ko.handle;
}

pub fn SetEvent(hEvent: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: SetEvent({x})\n", .{hEvent});
    const ko = getKernelObject(hEvent) orelse return 0;
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

pub fn ResetEvent(hEvent: usize) callconv(w32cc.WINAPI) i32 {
    const ko = getKernelObject(hEvent) orelse return 0;
    if (ko.obj_type != .event) return 0;
    ko.event.mutex.lock();
    defer ko.event.mutex.unlock();
    ko.event.signaled = false;
    return 1;
}
```

Also implement `OpenEventA`:
```zig
pub fn OpenEventA(dwDesiredAccess: u32, bInheritHandle: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = dwDesiredAccess;
    _ = bInheritHandle;
    if (lpName == 0) return 0;
    const name = trace.c_span(lpName);
    if (findByName(.event, name)) |ko| return ko.handle;
    return 0;
}
```
</action>

<acceptance_criteria>
- `sync.zig` contains `pub fn CreateEventA(` (not stub_)
- `CreateEventA` uses `allocKernelObject(.event)`
- `SetEvent` uses `cond.broadcast()` for manual-reset, `cond.signal()` for auto-reset
- `ResetEvent` sets `signaled = false`
- `OpenEventA` looks up by name via `findByName(.event, name)`
</acceptance_criteria>

---

### Task 3: Implement CreateMutexA and mutex operations

<read_first>
- src/win32/kernel32/sync.zig (lines 241-262 — existing mutex stubs)
</read_first>

<action>
Replace `stub_CreateMutexA` and `stub_ReleaseMutex`:

```zig
pub fn CreateMutexA(lpMutexAttributes: usize, bInitialOwner: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = lpMutexAttributes;
    if (lpName != 0) {
        const name = trace.c_span(lpName);
        if (trace.enable_tracing) trace.print("KERNEL32: CreateMutexA('{s}')\n", .{name});
        if (findByName(.mutex, name)) |existing| return existing.handle;
    }

    const ko = allocKernelObject(.mutex) orelse return 0;
    if (bInitialOwner != 0) {
        ko.mutex_data.mutex.lock();
        ko.mutex_data.owner = std.Thread.getCurrentId();
        ko.mutex_data.recursion = 1;
    }

    if (lpName != 0) {
        const name = trace.c_span(lpName);
        const copy_len = @min(name.len, 127);
        @memcpy(ko.mutex_data.name[0..copy_len], name[0..copy_len]);
        ko.mutex_data.name_len = @intCast(copy_len);
    }

    return ko.handle;
}

pub fn ReleaseMutex(hMutex: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: ReleaseMutex({x})\n", .{hMutex});
    const ko = getKernelObject(hMutex) orelse return 0;
    if (ko.obj_type != .mutex) return 0;
    if (ko.mutex_data.recursion > 1) {
        ko.mutex_data.recursion -= 1;
        return 1;
    }
    ko.mutex_data.owner = 0;
    ko.mutex_data.recursion = 0;
    ko.mutex_data.mutex.unlock();
    return 1;
}
```
</action>

<acceptance_criteria>
- `sync.zig` contains `pub fn CreateMutexA(` (not stub_)
- `CreateMutexA` supports `bInitialOwner` (locks mutex if non-zero)
- `ReleaseMutex` handles recursive release (decrement count before unlock)
- Named mutex lookup via `findByName(.mutex, name)`
</acceptance_criteria>

---

### Task 4: Implement CreateSemaphoreA and semaphore operations

<read_first>
- src/win32/kernel32/sync.zig (lines 452-470 — existing semaphore stubs)
</read_first>

<action>
Replace `stub_CreateSemaphoreA` and `stub_ReleaseSemaphore`:

```zig
pub fn CreateSemaphoreA(lpSemaphoreAttributes: usize, lInitialCount: i32, lMaximumCount: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = lpSemaphoreAttributes;
    if (lpName != 0) {
        const name = trace.c_span(lpName);
        if (trace.enable_tracing) trace.print("KERNEL32: CreateSemaphoreA('{s}')\n", .{name});
        if (findByName(.semaphore, name)) |existing| return existing.handle;
    }

    const ko = allocKernelObject(.semaphore) orelse return 0;
    ko.semaphore.count = lInitialCount;
    ko.semaphore.max_count = lMaximumCount;

    if (lpName != 0) {
        const name = trace.c_span(lpName);
        const copy_len = @min(name.len, 127);
        @memcpy(ko.semaphore.name[0..copy_len], name[0..copy_len]);
        ko.semaphore.name_len = @intCast(copy_len);
    }

    return ko.handle;
}

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
```
</action>

<acceptance_criteria>
- `sync.zig` contains `pub fn CreateSemaphoreA(` (not stub_)
- `CreateSemaphoreA` stores initial and max counts
- `ReleaseSemaphore` returns previous count, wakes waiters
</acceptance_criteria>

---

### Task 5: Update WaitForSingleObject to handle kernel objects

<read_first>
- src/win32/kernel32/sync.zig (lines 119-165 — current WaitForSingleObject)
</read_first>

<action>
Add kernel object dispatch to `WaitForSingleObject` after the thread handle check:

```zig
    // Check if this is a kernel object (event, mutex, semaphore)
    if (getKernelObject(hHandle)) |ko| {
        switch (ko.obj_type) {
            .event => {
                ko.event.mutex.lock();
                defer ko.event.mutex.unlock();
                if (dwMilliseconds == 0) {
                    // Poll mode
                    if (!ko.event.signaled) return 258; // WAIT_TIMEOUT
                } else {
                    while (!ko.event.signaled) {
                        ko.event.cond.wait(&ko.event.mutex);
                    }
                }
                if (!ko.event.manual_reset) {
                    ko.event.signaled = false; // Auto-reset
                }
                return 0; // WAIT_OBJECT_0
            },
            .mutex => {
                const tid = std.Thread.getCurrentId();
                if (ko.mutex_data.owner == tid) {
                    ko.mutex_data.recursion += 1;
                    return 0;
                }
                ko.mutex_data.mutex.lock();
                ko.mutex_data.owner = tid;
                ko.mutex_data.recursion = 1;
                return 0;
            },
            .semaphore => {
                ko.semaphore.mutex.lock();
                defer ko.semaphore.mutex.unlock();
                if (dwMilliseconds == 0) {
                    if (ko.semaphore.count <= 0) return 258;
                } else {
                    while (ko.semaphore.count <= 0) {
                        ko.semaphore.cond.wait(&ko.semaphore.mutex);
                    }
                }
                ko.semaphore.count -= 1;
                return 0;
            },
        }
    }
```
</action>

<acceptance_criteria>
- `WaitForSingleObject` contains `getKernelObject(hHandle)` dispatch
- Events: auto-reset clears signaled after one wait; manual-reset doesn't
- Mutexes: recursive acquisition for same thread
- Semaphores: decrement count on successful wait
- Poll mode (dwMilliseconds=0) returns WAIT_TIMEOUT (258) if not signaled
</acceptance_criteria>

---

### Task 6: Implement WaitForMultipleObjects

<read_first>
- src/win32/kernel32/sync.zig (lines 167-178 — current stub)
</read_first>

<action>
Replace `stub_WaitForMultipleObjects` with a working implementation:

```zig
pub fn WaitForMultipleObjects(nCount: u32, lpHandles: usize, bWaitAll: i32, dwMilliseconds: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: WaitForMultipleObjects(n={d}, all={d}, ms={d})\n", .{ nCount, bWaitAll, dwMilliseconds });

    if (nCount == 0 or lpHandles == 0) return 258; // WAIT_TIMEOUT

    const handles = @as([*]const u32, @ptrFromInt(lpHandles));
    const count = @min(nCount, 64); // Win32 max is MAXIMUM_WAIT_OBJECTS (64)

    if (bWaitAll == 0) {
        // Wait for ANY — poll each handle, return first signaled
        // Simple polling loop with progressive backoff
        var iterations: u32 = 0;
        const max_iterations = if (dwMilliseconds == 0xFFFFFFFF) @as(u32, 0xFFFFFFFF) else dwMilliseconds;
        while (iterations < max_iterations or dwMilliseconds == 0xFFFFFFFF) : (iterations += 1) {
            for (0..count) |i| {
                const h: usize = handles[i];
                if (tryAcquire(h)) return @intCast(i); // WAIT_OBJECT_0 + i
            }
            if (dwMilliseconds == 0) return 258; // WAIT_TIMEOUT
            std.Thread.sleep(1_000_000); // 1ms between polls
        }
        return 258; // WAIT_TIMEOUT
    } else {
        // Wait for ALL
        var iterations: u32 = 0;
        const max_iterations = if (dwMilliseconds == 0xFFFFFFFF) @as(u32, 0xFFFFFFFF) else dwMilliseconds;
        while (iterations < max_iterations or dwMilliseconds == 0xFFFFFFFF) : (iterations += 1) {
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
            std.Thread.sleep(1_000_000);
        }
        return 258;
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
            if (ko.mutex_data.owner == tid) {
                ko.mutex_data.recursion += 1;
                return true;
            }
            if (ko.mutex_data.mutex.tryLock()) {
                ko.mutex_data.owner = tid;
                ko.mutex_data.recursion = 1;
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
        .mutex => ko.mutex_data.owner == 0 or ko.mutex_data.owner == std.Thread.getCurrentId(),
        .semaphore => ko.semaphore.count > 0,
    };
}
```
</action>

<acceptance_criteria>
- `sync.zig` contains `pub fn WaitForMultipleObjects(` (not stub_)
- `bWaitAll=FALSE` returns first signaled index
- `bWaitAll=TRUE` waits until all are signaled before acquiring
- `dwMilliseconds=0` polls without blocking
- `dwMilliseconds=0xFFFFFFFF` blocks indefinitely
- Returns 258 (WAIT_TIMEOUT) on timeout
</acceptance_criteria>

---

### Task 7: Update kernel32.zig export registrations

<read_first>
- src/win32/kernel32.zig (lines 206-212, 335, 395, 459, 463 — current stub registrations)
</read_first>

<action>
Replace all `stub_` prefixed sync exports with the new implementations:

| Old | New |
|-----|-----|
| `stub_CreateEventA` | `CreateEventA` |
| `stub_SetEvent` | `SetEvent` |
| `stub_ResetEvent` | `ResetEvent` |
| `stub_CreateMutexA` | `CreateMutexA` |
| `stub_ReleaseMutex` | `ReleaseMutex` |
| `stub_WaitForMultipleObjects` | `WaitForMultipleObjects` |
| `stub_CreateSemaphoreA` | `CreateSemaphoreA` |
| `stub_ReleaseSemaphore` | `ReleaseSemaphore` |
| `stub_OpenEventA` | `OpenEventA` |

Also update the W variants (CreateEventW, CreateMutexW, CreateSemaphoreW, OpenEventW) to point to the A versions.
</action>

<acceptance_criteria>
- No `stub_Create*Event*` or `stub_Create*Mutex*` or `stub_Create*Semaphore*` in kernel32.zig
- All W variants point to A implementations
- `WaitForMultipleObjects` export points to the new function
</acceptance_criteria>

---

## Verification

### Build verification
```bash
cd /home/maci/Desktop/Projects/zine && zig build 2>&1 | head -20
```

### Manual verification
- Run Europa1400Gold.exe and verify threading/sync doesn't crash
- Trace output should show real event/mutex creation with handle allocation
