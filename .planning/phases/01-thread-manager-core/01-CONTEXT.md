# Phase 1: Thread Manager Core - Context

**Gathered:** 2026-03-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Implement Win32 thread creation with isolated x86 CPU state per guest thread, including TLS and MSVCRT `_beginthread`/`_beginthreadex` mapping.

</domain>

<decisions>
## Implementation Decisions

### Interpreter Per Thread
- **D-01:** Agent's discretion — User defers implementation approach for how guest threads get their own x86 interpreter loop. Key constraint: `threadWrapper` currently calls `@ptrFromInt(start_address)` as a native function — this only works for thunked (native) functions, not guest code at arbitrary EIP values. The solution must enable guest threads to execute interpreted x86 code.

### CPU State Isolation
- **D-02:** Same behavior as Win32 — each thread gets its own registers, flags, EIP, and stack. Memory (GuestMemory) is shared across all threads. Loaded modules and the export registry are shared. Each thread must have its own `Cpu` struct.

### Thread Lifecycle
- **D-03:** Same behavior as Win32 — threads are joinable via `WaitForSingleObject(thread_handle)`. `ExitThread` terminates the calling thread. Thread handles must be trackable (not just incrementing counters) so `WaitForSingleObject` can actually wait for completion.

### Agent's Discretion
- How to plumb a per-thread interpreter loop (whether to pass the main `Cpu` constructor, clone it, or use a thread-local CPU pool)
- Stack size defaults and allocation strategy for guest thread stacks

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Threading Infrastructure
- `src/win32/kernel32/process.zig` §941-961 — Existing `CreateThread` implementation and `threadWrapper`
- `src/win32/kernel32/sync.zig` §166-236 — Existing TLS implementation
- `src/win32/msvcrt/process.zig` §330-345 — `_beginthreadex` wrapping CreateThread

### CPU & Interpreter
- `src/x86/cpu.zig` — CPU state struct that must be per-thread
- `src/x86/execute.zig` — Interpreter loop that must run per-thread
- `src/x86/thunks.zig` — Native↔guest calling convention bridges

### Platform
- `src/platform/native.zig` §37-41 — `Mutex` and `spawnThread` abstractions
- `src/win32/teb.zig` — Thread Environment Block (already copied per-thread)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `threadWrapper` in `kernel32/process.zig` — Already handles per-thread TEB allocation and FS segment setup
- `CriticalSection` in `sync.zig` — Fully implemented with recursive locking via `std.Thread.Mutex`
- TLS system in `sync.zig` — Per-thread via thread ID lookup, 64 slots, 16 threads max
- `platform.spawnThread()` — Abstraction for OS thread creation
- `platform.Mutex` — Maps to `std.Thread.Mutex` on native

### Established Patterns
- Win32 stubs use `callconv(w32cc.WINAPI)` and `usize` parameters
- `trace.addr()` for guest→host address translation
- Handle allocation uses incrementing counters with 0xXX000001 bases

### Integration Points
- `CreateThread` entry point in `kernel32/process.zig` — needs to spawn interpreter loop instead of calling native function
- `runner.zig` interpreter loop — needs to be callable per-thread
- `WaitForSingleObject` in `sync.zig` — needs thread handle awareness (currently only handles child processes)

</code_context>

<specifics>
## Specific Ideas

No specific requirements — user wants standard Win32 threading behavior. Agent has discretion on interpreter-per-thread approach.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-thread-manager-core*
*Context gathered: 2026-03-21*
