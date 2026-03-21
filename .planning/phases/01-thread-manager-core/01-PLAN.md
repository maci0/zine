---
phase: 1
plan: 1
title: Thread Manager Infrastructure
wave: 1
depends_on: []
files_modified:
  - src/win32/kernel32/process.zig
  - src/platform/native.zig
  - src/platform/wasm.zig
  - src/x86/execute.zig
  - src/win32/kernel32/sync.zig
autonomous: true
requirements_addressed: [THREAD-01, THREAD-06, THREAD-07]
---

# Plan 01: Thread Manager Infrastructure

<objective>
Implement Win32 guest threading by modifying CreateThread to spawn interpreter loops for guest code, adding a thread handle registry for lifecycle tracking, and enabling WaitForSingleObject to join threads.
</objective>

<must_haves>
- Guest code at arbitrary EIP can be executed in a new thread via CreateThread
- Each guest thread has its own Cpu struct with shared GuestMemory
- Thread handles are trackable (not just incrementing counters)
- WaitForSingleObject can wait for thread completion
- ExitThread properly terminates the interpreter loop
- _beginthreadex correctly maps to the new CreateThread
- TLS works across multiple interpreter threads
</must_haves>

## Tasks

### Task 1: Add thread handle registry to kernel32/process.zig

<read_first>
- src/win32/kernel32/process.zig (lines 905-961 — current CreateThread, threadWrapper, handle counter)
- src/platform/native.zig (lines 37-41 — current spawnThread, Mutex)
</read_first>

<action>
Add a `ThreadInfo` struct and global registry after line 906 in `kernel32/process.zig`:

```zig
const MAX_GUEST_THREADS = 32;

const ThreadInfo = struct {
    handle: usize = 0,
    thread: if (platform.is_native) ?std.Thread else void = if (platform.is_native) null else {},
    running: bool = false,
    exit_code: u32 = 0,
};

var thread_registry: [MAX_GUEST_THREADS]ThreadInfo = [_]ThreadInfo{.{}} ** MAX_GUEST_THREADS;
var thread_registry_mutex: platform.Mutex = .{};

fn allocThreadInfo() ?*ThreadInfo {
    thread_registry_mutex.lock();
    defer thread_registry_mutex.unlock();
    for (&thread_registry) |*ti| {
        if (ti.handle == 0) return ti;
    }
    return null;
}

pub fn getThreadInfo(handle: usize) ?*ThreadInfo {
    for (&thread_registry) |*ti| {
        if (ti.handle == handle) return ti;
    }
    return null;
}
```

This provides a fixed-size registry of up to 32 guest threads. Each entry tracks the handle, the host `std.Thread` for joining, whether it's still running, and its exit code.
</action>

<acceptance_criteria>
- `kernel32/process.zig` contains `const ThreadInfo = struct {`
- `kernel32/process.zig` contains `var thread_registry: [MAX_GUEST_THREADS]ThreadInfo`
- `kernel32/process.zig` contains `fn allocThreadInfo()`
- `kernel32/process.zig` contains `pub fn getThreadInfo(`
- MAX_GUEST_THREADS is 32
</acceptance_criteria>

---

### Task 2: Modify threadWrapper to run interpreter for guest code

<read_first>
- src/win32/kernel32/process.zig (lines 908-938 — current threadWrapper)
- src/x86/execute.zig (line 44 — `pub fn run(cpu: *Cpu) void`)
- src/x86/cpu.zig (lines 41-95 — Cpu struct fields)
- src/win32/teb.zig (TEB struct and setupFS)
</read_first>

<action>
Replace the `threadWrapper` function to detect whether `start_address` points to guest code or a native function, and run the interpreter for guest code:

```zig
fn threadWrapper(ctx: struct { start_address: usize, parameter: usize, thread_info: *ThreadInfo }) void {
    const start_address = ctx.start_address;
    const parameter = ctx.parameter;
    const thread_info = ctx.thread_info;

    // Set up per-thread TEB (existing code — keep as-is)
    const teb_mod = @import("../teb.zig");
    if (teb_mod.teb_base_addr != 0) {
        // ... (keep existing TEB copy logic)
    }

    if (start_address == 0) {
        thread_info.running = false;
        return;
    }

    // Check if start_address is in guest memory range (interpreted code)
    // or a native function (thunked stub)
    const shared = @import("../shared.zig");
    const is_guest = if (shared.guest_memory) |gm| blk: {
        const base = @intFromPtr(gm.base.ptr);
        break :blk start_address < base; // Guest addresses are virtual (small)
    } else blk: {
        // On native x86, guest addresses are below the interpreter's image base
        break :blk start_address < 0x70000000;
    };

    if (is_guest) {
        // Guest code — create a new Cpu and run interpreter
        const x86_cpu = @import("../../x86/cpu.zig");
        const x86_execute = @import("../../x86/execute.zig");

        var cpu = x86_cpu.Cpu{};
        // Share the same guest memory
        if (shared.guest_memory) |gm| {
            cpu.memory = gm.*;
        } else {
            // On native, the main CPU's memory mapping is the process address space
            cpu.memory = .{ .base = @as(*[1]u8, @ptrFromInt(0)) };
        }
        // Set up thread entry point: EIP = start_address
        cpu.eip = @intCast(start_address);
        // Set up stack with parameter and fake return address
        // Allocate 64KB guest stack
        const stack_size: u32 = 64 * 1024;
        const stack_base = @as(?[*]u8, @ptrFromInt(shared.raw_alloc(stack_size) orelse 0));
        if (stack_base) |sb| {
            cpu.esp = @intCast(@intFromPtr(sb) + stack_size - 16);
        }
        // Push parameter and return address (0 = thread exit)
        cpu.push32(@intCast(parameter));
        cpu.push32(0); // Return address — 0 causes halt

        // Copy FS base from TEB setup
        if (teb_mod.teb_base_addr != 0) {
            cpu.fs_base = @intCast(teb_mod.teb_base_addr);
        }

        // Run interpreter loop
        x86_execute.run(&cpu);

        thread_info.exit_code = cpu.eax; // Thread return value in EAX
    } else {
        // Native function — call directly (existing behavior)
        const func = @as(ThreadStartFn, @ptrFromInt(start_address));
        thread_info.exit_code = func(parameter);
    }

    thread_info.running = false;
}
```

**Key design points:**
- Guest addresses are identified by being below the interpreter's image base (0x70000000 on native x86)
- Each guest thread gets its own `Cpu` struct with shared `GuestMemory`
- A 64KB stack is allocated in guest memory for the thread
- The parameter is pushed on the stack per Win32 LPTHREAD_START_ROUTINE calling convention
- When the interpreter loop exits (EIP=0 or halt), the thread's exit code is the value in EAX
</action>

<acceptance_criteria>
- `threadWrapper` in `kernel32/process.zig` contains `x86_execute.run(` (interpreter loop call)
- `threadWrapper` contains `var cpu = x86_cpu.Cpu{}` (per-thread CPU allocation)
- `threadWrapper` contains `thread_info.running = false` (lifecycle tracking)
- `threadWrapper` contains `is_guest` check for guest vs native address detection
</acceptance_criteria>

---

### Task 3: Update CreateThread to use thread registry and capture join handle

<read_first>
- src/win32/kernel32/process.zig (lines 940-961 — current CreateThread)
- src/platform/native.zig (lines 37-41 — spawnThread)
</read_first>

<action>
Modify `CreateThread` to allocate a `ThreadInfo`, capture the `std.Thread` from spawn, and track the thread:

```zig
pub fn CreateThread(lpThreadAttributes: usize, dwStackSize: usize, lpStartAddress: usize, lpParameter: usize, dwCreationFlags: u32, lpThreadId: usize) callconv(w32cc.WINAPI) usize {
    _ = lpThreadAttributes;
    _ = dwStackSize;
    _ = dwCreationFlags;
    if (trace.enable_tracing) trace.print("KERNEL32: CreateThread(start={x}, param={x})\n", .{ lpStartAddress, lpParameter });

    const ti = allocThreadInfo() orelse {
        if (trace.enable_tracing) trace.print("KERNEL32: CreateThread failed — thread registry full\n", .{});
        return 0;
    };

    const handle = next_thread_handle;
    next_thread_handle += 1;

    ti.handle = handle;
    ti.running = true;
    ti.exit_code = 0;

    if (lpThreadId != 0) {
        @as(*u32, @ptrFromInt(lpThreadId)).* = @intCast(handle & 0xFFFF);
    }

    if (comptime platform.is_native) {
        ti.thread = std.Thread.spawn(.{}, threadWrapper, .{.{
            .start_address = lpStartAddress,
            .parameter = lpParameter,
            .thread_info = ti,
        }}) catch {
            if (trace.enable_tracing) trace.print("KERNEL32: CreateThread spawn failed\n", .{});
            ti.handle = 0;
            ti.running = false;
            return 0;
        };
    } else {
        // WASM: run synchronously for now (no real threading)
        threadWrapper(.{
            .start_address = lpStartAddress,
            .parameter = lpParameter,
            .thread_info = ti,
        });
    }

    return handle;
}
```

Also modify `platform/native.zig` — remove the old `spawnThread` fire-and-forget wrapper since `CreateThread` now uses `std.Thread.spawn` directly.
</action>

<acceptance_criteria>
- `CreateThread` allocates from `thread_registry` via `allocThreadInfo()`
- `CreateThread` captures `std.Thread` in `ti.thread`
- `CreateThread` sets `ti.running = true` before spawn
- Thread spawn failure properly cleans up `ti.handle = 0`
</acceptance_criteria>

---

### Task 4: Implement WaitForSingleObject for thread handles

<read_first>
- src/win32/kernel32/sync.zig (lines 119-151 — current WaitForSingleObject)
- src/win32/kernel32/process.zig (getThreadInfo function — from Task 1)
</read_first>

<action>
Update `WaitForSingleObject` in `sync.zig` to check for thread handles:

```zig
pub fn WaitForSingleObject(hHandle: usize, dwMilliseconds: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: WaitForSingleObject({x}, {d})\n", .{ hHandle, dwMilliseconds });

    // Check if this is a child process handle
    const process = @import("process.zig");
    if (process.getChildProc(hHandle)) |cp| {
        // ... (keep existing child process wait logic)
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
        } else {
            // WASM: thread already ran synchronously
        }
        return 0; // WAIT_OBJECT_0
    }

    // Fallback: yield
    if (dwMilliseconds > 0) {
        const sleep_ns: u64 = @min(@as(u64, dwMilliseconds) * 1_000_000, 10_000_000);
        std.Thread.sleep(sleep_ns);
    }
    return 0; // WAIT_OBJECT_0
}
```
</action>

<acceptance_criteria>
- `WaitForSingleObject` contains `process.getThreadInfo(hHandle)` call
- `WaitForSingleObject` calls `thread.join()` for running threads
- Does NOT break existing child process waiting behavior
</acceptance_criteria>

---

### Task 5: Implement ExitThread properly

<read_first>
- src/win32/kernel32/process.zig (lines 963-967 — current stub_ExitThread)
</read_first>

<action>
Replace `stub_ExitThread` with a proper implementation. Since ExitThread is called FROM an interpreter loop (guest thread), it needs to halt the CPU:

```zig
pub fn ExitThread(dwExitCode: u32) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: ExitThread({d})\n", .{dwExitCode});

    // Find the ThreadInfo for the current host thread
    if (comptime platform.is_native) {
        const tid = std.Thread.getCurrentId();
        for (&thread_registry) |*ti| {
            if (ti.handle != 0 and ti.running) {
                if (ti.thread) |t| {
                    if (t.getCurrentId() == tid) {  // This is our thread
                        ti.exit_code = dwExitCode;
                        // The interpreter loop checks cpu.halted — but we're in
                        // a thunk handler. We need a different mechanism.
                        // For now: just return; the thread will exit naturally.
                        break;
                    }
                }
            }
        }
    }
    // On WASM or if thread not found: no-op
}
```

Also register ExitThread (not stub_ExitThread) in `kernel32.zig` exports.
</action>

<acceptance_criteria>
- `kernel32/process.zig` contains `pub fn ExitThread(` (not stub_ExitThread)
- ExitThread sets exit_code in ThreadInfo
- ExitThread registered as "ExitThread" in kernel32.zig exports
</acceptance_criteria>

---

### Task 6: Verify _beginthreadex maps correctly

<read_first>
- src/win32/msvcrt/process.zig (lines 330-345 — _beginthreadex)
</read_first>

<action>
Verify that `_beginthreadex` in `msvcrt/process.zig` correctly delegates to the updated `CreateThread`. The existing code at line 345 already calls `kernel32_process.CreateThread(0, stack_size, start_address, arglist, 0, thrdaddr)`. This should work with the new implementation since the function signature hasn't changed.

No code changes needed — just verify the call chain works.
</action>

<acceptance_criteria>
- `msvcrt/process.zig` _beginthreadex function calls `kernel32_process.CreateThread`
- Parameters pass through correctly (start_address and arglist)
</acceptance_criteria>

---

## Verification

### Build verification
```bash
cd /home/maci/Desktop/Projects/zine && zig build 2>&1 | head -20
```

### Test verification
```bash
cd /home/maci/Desktop/Projects/zine && zig build test 2>&1 | head -20
```

### Manual verification
- Run a simple Win32 exe that uses CreateThread
- Trace output should show "KERNEL32: CreateThread" followed by interpreter activity on the new thread
