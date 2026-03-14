const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../../calling_convention.zig");

// --- Interlocked operations ---

pub fn stub_InterlockedIncrement(lpAddend: usize) callconv(w32cc.WINAPI) i32 {
    if (lpAddend == 0) return 0;
    const ptr = @as(*i32, @ptrFromInt(lpAddend));
    return @atomicRmw(i32, ptr, .Add, 1, .seq_cst) + 1;
}

pub fn stub_InterlockedDecrement(lpAddend: usize) callconv(w32cc.WINAPI) i32 {
    if (lpAddend == 0) return 0;
    const ptr = @as(*i32, @ptrFromInt(lpAddend));
    return @atomicRmw(i32, ptr, .Sub, 1, .seq_cst) - 1;
}

// --- Critical sections ---

pub fn stub_InitializeCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: InitializeCriticalSection({x})\n", .{lpCriticalSection});
}

pub fn stub_EnterCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    _ = lpCriticalSection;
}

pub fn stub_LeaveCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    _ = lpCriticalSection;
}

pub fn stub_DeleteCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: DeleteCriticalSection({x})\n", .{lpCriticalSection});
}

// --- Events ---

pub fn stub_CreateEventA(lpEventAttributes: usize, bManualReset: i32, bInitialState: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = lpEventAttributes;
    _ = bManualReset;
    _ = bInitialState;
    _ = lpName;
    if (trace.enable_tracing) trace.print("KERNEL32: CreateEventA\n", .{});
    return 0xE0000001;
}

pub fn stub_ResetEvent(hEvent: usize) callconv(w32cc.WINAPI) i32 {
    _ = hEvent;
    return 1;
}

pub fn stub_SetEvent(hEvent: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: SetEvent({x})\n", .{hEvent});
    return 1; // Success
}

// WAIT_OBJECT_0 = 0
pub fn stub_WaitForSingleObject(hHandle: usize, dwMilliseconds: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: WaitForSingleObject({x}, {d})\n", .{ hHandle, dwMilliseconds });

    // Check if this is a child process handle
    const process = @import("process.zig");
    if (process.getChildProc(hHandle)) |cp| {
        if (cp.child) |*child| {
            if (cp.exit_code == null) {
                // Actually wait for the child process
                const result = child.wait() catch {
                    cp.exit_code = 1;
                    return 0; // WAIT_OBJECT_0
                };
                cp.exit_code = switch (result) {
                    .Exited => |code| @as(u32, code),
                    else => 1,
                };
            }
            return 0; // WAIT_OBJECT_0
        }
    }

    // Yield to allow other threads to run
    if (dwMilliseconds > 0) {
        const sleep_ns: u64 = @min(@as(u64, dwMilliseconds) * 1_000_000, 10_000_000); // Cap at 10ms
        std.Thread.sleep(sleep_ns);
    }
    return 0; // WAIT_OBJECT_0
}


pub fn stub_WaitForMultipleObjects(nCount: u32, lpHandles: usize, bWaitAll: i32, dwMilliseconds: u32) callconv(w32cc.WINAPI) u32 {
    _ = nCount; _ = lpHandles; _ = bWaitAll;
    if (dwMilliseconds > 0) {
        const sleep_ns: u64 = @min(@as(u64, dwMilliseconds) * 1_000_000, 10_000_000);
        std.Thread.sleep(sleep_ns);
    }
    return 0; // WAIT_OBJECT_0
}

// --- Thread Local Storage ---
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

pub fn stub_TlsAlloc() callconv(w32cc.WINAPI) u32 {
    if (tls_next >= MAX_TLS_SLOTS) return 0xFFFFFFFF; // TLS_OUT_OF_INDEXES
    const idx = tls_next;
    tls_next += 1;
    return idx;
}

pub fn stub_TlsGetValue(dwTlsIndex: u32) callconv(w32cc.WINAPI) usize {
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    const entry = getOrCreateTlsEntry();
    return entry.slots[dwTlsIndex];
}

pub fn stub_TlsSetValue(dwTlsIndex: u32, lpTlsValue: usize) callconv(w32cc.WINAPI) i32 {
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    const entry = getOrCreateTlsEntry();
    entry.slots[dwTlsIndex] = lpTlsValue;
    return 1;
}

// --- Mutexes ---

var next_mutex_handle: usize = 0xB0000001;

pub fn stub_CreateMutexA(lpMutexAttributes: usize, bInitialOwner: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = lpMutexAttributes;
    _ = bInitialOwner;
    if (lpName != 0) {
        const name = trace.c_span(lpName);
        if (trace.enable_tracing) trace.print("KERNEL32: CreateMutexA('{s}')\n", .{name});
    }
    const handle = next_mutex_handle;
    next_mutex_handle += 1;
    return handle;
}

pub fn stub_ReleaseMutex(hMutex: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: ReleaseMutex({x})\n", .{hMutex});
    return 1; // TRUE = success
}

pub fn stub_ReleaseSemaphore(hSemaphore: usize, lReleaseCount: i32, lpPreviousCount: usize) callconv(w32cc.WINAPI) i32 {
    _ = hSemaphore;
    _ = lReleaseCount;
    if (lpPreviousCount != 0) {
        @as(*i32, @ptrFromInt(lpPreviousCount)).* = 0;
    }
    return 1; // TRUE = success
}

var next_dup_handle: usize = 0xD0000001;

pub fn stub_DuplicateHandle(
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
    if (lpTargetHandle != 0) {
        // Return the same handle (or a new fake one)
        @as(*usize, @ptrFromInt(lpTargetHandle)).* = next_dup_handle;
        next_dup_handle += 1;
    }
    return 1; // TRUE = success
}

// --- InterlockedCompareExchange ---
// LONG InterlockedCompareExchange(LONG volatile *Destination, LONG Exchange, LONG Comperand)
pub fn stub_InterlockedCompareExchange(dest: usize, exchange: i32, comperand: i32) callconv(w32cc.WINAPI) i32 {
    if (dest == 0) return 0;
    const ptr = @as(*i32, @ptrFromInt(dest));
    return @cmpxchgStrong(i32, ptr, comperand, exchange, .seq_cst, .seq_cst) orelse comperand;
}

// --- File change notifications (stub: return fake handles, no-op poll) ---
var next_change_handle: usize = 0xCE000001;

pub fn stub_FindFirstChangeNotificationW(path_ptr: usize, watch_subtree: i32, filter: u32) callconv(w32cc.WINAPI) usize {
    _ = path_ptr;
    _ = watch_subtree;
    _ = filter;
    const h = next_change_handle;
    next_change_handle += 1;
    if (trace.enable_tracing) trace.print("KERNEL32: FindFirstChangeNotificationW -> {x}\n", .{h});
    return h;
}

pub fn stub_FindNextChangeNotification(hChangeHandle: usize) callconv(w32cc.WINAPI) i32 {
    _ = hChangeHandle;
    return 1; // TRUE
}

// --- SList (Interlocked Singly Linked Lists) ---

pub fn stub_InitializeSListHead(ListHead: usize) callconv(w32cc.WINAPI) void {
    // SLIST_HEADER is 8 bytes on x86 — zero it out
    if (ListHead != 0) {
        @memset(@as([*]u8, @ptrFromInt(ListHead))[0..8], 0);
    }
}

pub fn stub_InterlockedFlushSList(ListHead: usize) callconv(w32cc.WINAPI) usize {
    if (ListHead != 0) {
        // Read the first pointer (first 4 bytes of SLIST_HEADER)
        const first = @as(*usize, @ptrFromInt(ListHead)).*;
        @as(*usize, @ptrFromInt(ListHead)).* = 0; // Clear the list
        return first;
    }
    return 0; // Empty list
}

// --- Extended Critical Sections ---

pub fn stub_InitializeCriticalSectionEx(lpCriticalSection: usize, dwSpinCount: u32, flags: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: InitializeCriticalSectionEx(cs={X}, spin={d}, flags={X})\n", .{ lpCriticalSection, dwSpinCount, flags });
    stub_InitializeCriticalSection(lpCriticalSection);
    return 1; // TRUE = success
}

pub fn stub_InitializeCriticalSectionAndSpinCount(lpCriticalSection: usize, dwSpinCount: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: InitializeCriticalSectionAndSpinCount(cs={X}, spin={d})\n", .{ lpCriticalSection, dwSpinCount });
    stub_InitializeCriticalSection(lpCriticalSection);
    return 1; // TRUE = success
}

// --- Pointer encoding (identity transform in emulation) ---

pub fn stub_EncodePointer(ptr: usize) callconv(w32cc.WINAPI) usize {
    return ptr; // No encoding needed
}

pub fn stub_DecodePointer(ptr: usize) callconv(w32cc.WINAPI) usize {
    return ptr; // No decoding needed
}

// --- Fiber Local Storage (FLS) ---
// FLS is like TLS but per-fiber. We're single-fiber, so just use simple slots.

var fls_next: u32 = 0;
const MAX_FLS_SLOTS = 128;
var fls_values: [MAX_FLS_SLOTS]usize = [_]usize{0} ** MAX_FLS_SLOTS;
var fls_callbacks: [MAX_FLS_SLOTS]usize = [_]usize{0} ** MAX_FLS_SLOTS;

pub fn stub_FlsAlloc(lpCallback: usize) callconv(w32cc.WINAPI) u32 {
    if (fls_next >= MAX_FLS_SLOTS) return 0xFFFFFFFF; // FLS_OUT_OF_INDEXES
    const idx = fls_next;
    fls_callbacks[idx] = lpCallback;
    fls_values[idx] = 0;
    fls_next += 1;
    if (trace.enable_tracing) trace.print("KERNEL32: FlsAlloc -> {d}\n", .{idx});
    return idx;
}

pub fn stub_FlsGetValue(dwFlsIndex: u32) callconv(w32cc.WINAPI) usize {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    return fls_values[dwFlsIndex];
}

pub fn stub_FlsSetValue(dwFlsIndex: u32, lpFlsData: usize) callconv(w32cc.WINAPI) i32 {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    fls_values[dwFlsIndex] = lpFlsData;
    return 1; // TRUE
}

pub fn stub_FlsFree(dwFlsIndex: u32) callconv(w32cc.WINAPI) i32 {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    fls_values[dwFlsIndex] = 0;
    fls_callbacks[dwFlsIndex] = 0;
    return 1; // TRUE
}

// --- Additional sync stubs ---

pub fn stub_InterlockedExchange(target: usize, value: i32) callconv(w32cc.WINAPI) i32 {
    if (target == 0) return 0;
    const ptr = @as(*i32, @ptrFromInt(target));
    return @atomicRmw(i32, ptr, .Xchg, value, .seq_cst);
}

pub fn stub_TlsFree(dwTlsIndex: u32) callconv(w32cc.WINAPI) i32 {
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    // Clear the value in all thread entries
    for (&tls_threads) |*entry| {
        if (entry.thread_id != 0) {
            entry.slots[dwTlsIndex] = 0;
        }
    }
    return 1; // TRUE
}

var next_semaphore_handle: usize = 0xA0000001;

pub fn stub_CreateSemaphoreA(lpSemaphoreAttributes: usize, lInitialCount: i32, lMaximumCount: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = lpSemaphoreAttributes;
    _ = lInitialCount;
    _ = lMaximumCount;
    if (trace.enable_tracing) {
        if (lpName != 0) {
            trace.print("KERNEL32: CreateSemaphoreA('{s}')\n", .{trace.c_span(lpName)});
        } else {
            trace.print("KERNEL32: CreateSemaphoreA(unnamed)\n", .{});
        }
    }
    const handle = next_semaphore_handle;
    next_semaphore_handle += 1;
    return handle;
}

var next_event_handle: usize = 0xE0000010;

pub fn stub_OpenEventA(dwDesiredAccess: u32, bInheritHandle: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = dwDesiredAccess;
    _ = bInheritHandle;
    if (trace.enable_tracing) {
        if (lpName != 0) {
            trace.print("KERNEL32: OpenEventA('{s}')\n", .{trace.c_span(lpName)});
        }
    }
    const handle = next_event_handle;
    next_event_handle += 1;
    return handle;
}
