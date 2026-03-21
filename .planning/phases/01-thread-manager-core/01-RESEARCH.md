# Phase 1: Thread Manager Core — Research

## RESEARCH COMPLETE

### Findings

#### 1. Interpreter Loop Architecture
- **`x86/execute.zig:44`** — `pub fn run(cpu: *Cpu) void` is the main interpreter loop
- Takes a `*Cpu` and runs until `cpu.halted` is true
- Each guest thread needs its own `Cpu` with `eip` set to start address
- Memory (`GuestMemory`) is shared — it's a pointer to the same buffer

#### 2. CPU State (cpu.zig:41)
The `Cpu` struct contains:
- 8 general-purpose registers (eax-edi) + eip
- Segment registers (cs, ds, es, fs, gs, ss) + fs_base
- LazyFlags (EFLAGS computation)
- FpuState (x87 FPU stack + control)
- XMM registers (SSE/SSE2)
- MXCSR register
- GuestMemory reference (pointer — shared across threads)
- DecodeCache (per-thread, not shared)
- halted flag + pending_interrupt

**Size:** ~400 bytes. Cheap to allocate per thread.

#### 3. Current CreateThread Implementation (kernel32/process.zig:908-960)
```
threadWrapper(start_address, parameter):
  1. Allocate per-thread TEB (copies main thread's TEB)
  2. Set up FS segment via teb_mod.setupFS()
  3. Cast start_address to native ThreadStartFn
  4. Call func(parameter) directly ← THIS IS THE BUG
```
Step 4 calls the start address as a native function. For thunked functions this works (they're real host functions). For guest code at arbitrary EIP values, this crashes.

**Fix:** Check if start_address is a guest address (not a native/thunk address). If guest, create a new Cpu and run the interpreter loop.

#### 4. Thread Handle Tracking (kernel32/process.zig:906)
```zig
var next_thread_handle: usize = 0xA0000001;
```
Handles are just incrementing counters with no tracking. Need:
- Array/map of thread handles → thread state (running/exited, exit code)
- `WaitForSingleObject` integration to actually wait for thread completion
- Host thread join mechanism (std.Thread.join)

#### 5. Thunk System (thunks.zig)
- INT 0xFE triggers thunk dispatch
- Thunks bridge guest code → native Win32 stubs
- Guest threads running interpreted code naturally use thunks when calling APIs
- No changes needed to thunk system for threading

#### 6. Platform Threading (platform/native.zig:37-41)
```zig
pub const Mutex = std.Thread.Mutex;
pub fn spawnThread(func, args) bool { std.Thread.spawn(...) }
```
`spawnThread` fire-and-forgets — returns bool, discards the Thread handle. Need to capture `std.Thread` for join support.

#### 7. Existing Sync Primitives (kernel32/sync.zig)
- **Critical sections:** ✅ Fully implemented with recursive locking
- **TLS:** ✅ Per-thread via thread ID, 64 slots, 16 threads
- **Events:** ❌ Stub only (fake handles, no signaling)
- **Mutexes:** ❌ Stub only (fake handles, no locking)
- **WaitForSingleObject:** ⚠️ Only handles child processes, sleeps for others
- **WaitForMultipleObjects:** ❌ Stub (just sleeps)

### Implementation Approach

1. **Modify `threadWrapper`** to detect guest vs native start addresses
   - If `start_address` is in guest memory range → create new Cpu, run interpreter
   - If `start_address` is a native/thunk address → call directly (current behavior)

2. **Add thread handle registry** (ThreadInfo array)
   - Track: handle, std.Thread, running state, exit code
   - Capture `std.Thread` from spawn for join support

3. **Modify `spawnThread`** to return `?std.Thread` instead of `bool`

4. **Implement `WaitForSingleObject` for thread handles**
   - Look up ThreadInfo by handle
   - Call `thread.join()` if running

5. **Implement `ExitThread`** properly
   - Set exit code in ThreadInfo
   - Stop interpreter loop (set `cpu.halted = true`)

### Validation Architecture

#### Dimension 1: Unit isolation
- Test Cpu allocation per thread
- Test thread handle registry CRUD

#### Dimension 2: Integration
- Test CreateThread → interpreter loop → ExitThread → WaitForSingleObject flow

#### Dimension 3: Edge cases
- Thread creating threads
- Max thread limit
- ExitThread before WaitForSingleObject
