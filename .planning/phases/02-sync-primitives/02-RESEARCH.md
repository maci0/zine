# Phase 2: Sync Primitives — Research

## RESEARCH COMPLETE

### Findings

#### 1. Current Sync State (sync.zig, 488 lines)
- **Critical sections** ✅ — Recursive, mutex-backed, address-indexed in 256-entry table
- **Interlocked ops** ✅ — Atomic intrinsics, correct
- **TLS** ✅ — Per-thread via thread ID, 64 slots
- **FLS** ✅ — Simple global slots (no per-fiber)
- **SList** ✅ — Atomic linked list heads

#### 2. Stubs to Replace

| Stub | Line | Handle Range | Win32 Semantics |
|------|------|--------------|-----------------|
| `stub_CreateEventA` | 96 | 0xE0000001+ | Auto/manual reset, named, signaled/unsignaled |
| `stub_SetEvent` | 114 | — | Signal event, wake waiters |
| `stub_ResetEvent` | 107 | — | Unsignal event |
| `stub_CreateMutexA` | 245 | 0xB0000001+ | Recursive, named, owned/unowned |
| `stub_ReleaseMutex` | 259 | — | Release ownership |
| `stub_WaitForMultipleObjects` | 169 | — | Wait on array of handles |
| `stub_CreateSemaphoreA` | 456 | 0xA0000001+ | Counted, named |
| `stub_ReleaseSemaphore` | 266 | — | Increment semaphore count |
| `stub_OpenEventA` | 476 | 0xE0000010+ | Look up named event |

#### 3. Handle-Based Type Dispatch
Existing code uses non-overlapping handle ranges for type identification:
- Events: 0xE0000001+ (also 0xE0000010+ for OpenEvent)
- Mutexes: 0xB0000001+
- Semaphores: 0xA0000001+
- Threads: 0xA0000001+ (from Phase 1 — **COLLISION with semaphores!**)
- Processes: 0xCB000001+
- Duplicated: 0xD0000001+
- Change notifications: 0xCE000001+

**Fix needed:** Thread handles use 0xA0000001 which collides with semaphore handles. Need to separate.

#### 4. Kernel Object Registry Design
Instead of per-type handle ranges and separate registries, use a unified kernel object table:

```
KernelObject = union(enum) {
    event: *Event,
    mutex: *MutexObj,
    semaphore: *Semaphore,
    // thread handles are already in thread_registry
};

var kernel_objects: [MAX_KERNEL_OBJECTS]KernelObjectEntry = ...;
```

This lets WaitForSingleObject/WaitForMultipleObjects dispatch on object type rather than handle range.

#### 5. Win32 Event Semantics
- **Auto-reset:** SetEvent wakes ONE waiter, then auto-resets to unsignaled
- **Manual-reset:** SetEvent wakes ALL waiters, stays signaled until ResetEvent
- **Named:** Can be opened by name from other "processes" (for us: same address space)
- Implementation: `std.Thread.Condition` + `std.Thread.Mutex` + signaled flag

#### 6. Win32 Mutex Semantics
- **Recursive:** Same thread can acquire multiple times (like CriticalSection)
- **Named:** Can be opened by name
- **Owned:** Initially owned or unowned
- Implementation: `std.Thread.Mutex` + owner thread ID + recursion count (same pattern as CriticalSection)

#### 7. WaitForMultipleObjects Semantics
- `bWaitAll=FALSE`: Returns index of first signaled object (WAIT_OBJECT_0 + index)
- `bWaitAll=TRUE`: Returns only when ALL objects are signaled
- `dwMilliseconds=INFINITE (0xFFFFFFFF)`: Block forever
- `dwMilliseconds=0`: Poll, don't block
- Returns `WAIT_TIMEOUT (258)` on timeout

### Implementation Approach
1. **Unified kernel object table** — single registry for events, mutexes, semaphores
2. **Event** — Condition + Mutex + signaled flag + auto/manual reset mode
3. **Mutex** — Mutex + owner + recursion (reuse CriticalSection pattern)
4. **Semaphore** — Condition + Mutex + count + max
5. **WaitForSingleObject** — dispatch on kernel object type
6. **WaitForMultipleObjects** — polling loop with Condition broadcasting
