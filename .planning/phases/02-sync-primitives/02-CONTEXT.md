# Phase 2: Sync Primitives - Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Implement Win32 synchronization primitives: events (auto-reset, manual-reset), mutexes (named, unnamed), and WaitForMultipleObjects with proper signaling semantics.

</domain>

<decisions>
## Implementation Decisions

### Event Implementation
- **D-01:** Use idiomatic Zig — `std.Thread.Condition` + `std.Thread.Mutex` to implement Win32 events. Both auto-reset (signal releases one waiter) and manual-reset (signal releases all waiters, stays signaled until ResetEvent) must be supported.

### Mutex Implementation
- **D-02:** Follow Win32 behavior — named mutexes support in-process naming for single-instance app detection patterns. Mutexes are recursive (same thread can acquire multiple times). Cross-process naming is NOT needed (we're single-process).

### WaitForMultipleObjects
- **D-03:** Follow Win32 behavior — support both `bWaitAll=TRUE` (wait for all objects) and `bWaitAll=FALSE` (wait for any). Must work with a mix of events, mutexes, and thread handles.

### Agent's Discretion
- Handle registry design (how events/mutexes get handles that WaitForSingleObject/WaitForMultipleObjects can look up)
- WASM fallback behavior (no real threading — cooperative scheduling?)
- Whether to implement semaphores in this phase or defer

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Existing Sync Code
- `src/win32/kernel32/sync.zig` — All current sync primitives: critical sections (lines 16-92), events (94-117), mutexes (227-248), WaitForSingleObject (119-165), WaitForMultipleObjects (153-164), TLS (166-236)
- `src/win32/kernel32/process.zig` §905-1040 — Thread registry and getThreadInfo (from Phase 1)

### Platform
- `src/platform/native.zig` — `std.Thread.Mutex` typedef
- `src/platform.zig` — `is_native`, `is_x86_64` comptime flags

### Registration
- `src/win32/kernel32.zig` — Export registration (CreateEventA, SetEvent, ResetEvent, CreateMutexA, ReleaseMutex, WaitForMultipleObjects, etc.)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `CriticalSection` pattern (sync.zig:22-92) — address-based lookup in fixed table, could be extended for handle-based kernel objects
- Thread handle registry (process.zig:ThreadInfo) — handle allocation pattern from Phase 1
- `next_*_handle` counters — existing handle ranges: events 0xE0000001, mutexes 0xB0000001, semaphores 0xA0000001

### Established Patterns
- Sync objects use fixed-size arrays with linear scan (MAX_CRITICAL_SECTIONS=256)
- Win32 stubs use `callconv(w32cc.WINAPI)` and `usize` parameters
- Handle ranges are non-overlapping for type identification

### Integration Points
- `WaitForSingleObject` already handles child processes and threads — add event/mutex cases
- `WaitForMultipleObjects` needs complete rewrite from sleep-only stub
- kernel32.zig export table needs stub_ prefixes removed for newly implemented functions

</code_context>

<specifics>
## Specific Ideas

No specific requirements — user wants standard Win32 synchronization behavior implemented idiomatically in Zig.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 02-sync-primitives*
*Context gathered: 2026-03-21*
