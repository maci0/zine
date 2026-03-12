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
