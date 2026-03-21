# Phase 2: Sync Primitives — Verification

**Date:** 2026-03-22
**Status:** passed

## Acceptance Criteria

### Task 1: Kernel Object Registry ✅
- [x] `sync.zig` contains `const KernelObject = struct {` (line 132)
- [x] `sync.zig` contains `var kernel_objects: [MAX_KERNEL_OBJECTS]KernelObject` (line 140)
- [x] `sync.zig` contains `pub fn getKernelObject(` (line 157)
- [x] `sync.zig` contains `fn findByName(` (line 164)
- [x] Thread handle range (0xA0010001) doesn't collide with kernel handle range (0xE0000001)

### Task 2: CreateEventA and Event Operations ✅
- [x] `sync.zig` contains `pub fn CreateEventA(` (line 191, not stub_)
- [x] `CreateEventA` uses `allocKernelObject(.event)` (line 201)
- [x] `SetEvent` uses `cond.broadcast()` for manual-reset (line 223), `cond.signal()` for auto-reset (line 225)
- [x] `ResetEvent` sets `signaled = false` (line 237)
- [x] `OpenEventA` looks up by name via `findByName(.event, name)`

### Task 3: CreateMutexA and Mutex Operations ✅
- [x] `sync.zig` contains `pub fn CreateMutexA(` (line 563, not stub_)
- [x] `CreateMutexA` supports `bInitialOwner` (locks mutex if non-zero, line 575)
- [x] `ReleaseMutex` handles recursive release (recursion decrement, line 594)
- [x] Named mutex lookup via `findByName(.mutex, name)`

### Task 4: CreateSemaphoreA and Semaphore Operations ✅
- [x] `sync.zig` contains `pub fn CreateSemaphoreA(` (line 610, not stub_)
- [x] `CreateSemaphoreA` stores initial and max counts
- [x] `ReleaseSemaphore` returns previous count, wakes waiters via `cond.signal()`

### Task 5: WaitForSingleObject Kernel Object Dispatch ✅
- [x] `WaitForSingleObject` contains `getKernelObject(hHandle)` dispatch
- [x] Events: auto-reset clears signaled after one wait; manual-reset doesn't
- [x] Mutexes: recursive acquisition for same thread (line 341)
- [x] Semaphores: decrement count on successful wait
- [x] Poll mode (dwMilliseconds=0) returns WAIT_TIMEOUT (258) if not signaled

### Task 6: WaitForMultipleObjects ✅
- [x] `sync.zig` contains `pub fn WaitForMultipleObjects(` (line 437, not stub_)
- [x] `bWaitAll=FALSE` returns first signaled index
- [x] `bWaitAll=TRUE` waits until all are signaled before acquiring
- [x] `dwMilliseconds=0` polls without blocking
- [x] `dwMilliseconds=0xFFFFFFFF` blocks indefinitely
- [x] `tryAcquire()` helper (line 380) and `isSignaled()` helper (line 424) exist

### Task 7: kernel32.zig Export Registrations ✅
- [x] No `stub_CreateEvent*` or `stub_CreateMutex*` or `stub_CreateSemaphore*` in kernel32.zig

## Build Verification
- `zig build` completes with no errors

## Summary
All Phase 2 acceptance criteria are met. Retroactive validation confirms code matches the plan.
