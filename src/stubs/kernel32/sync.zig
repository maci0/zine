const std = @import("std");
const trace = @import("../../trace.zig");

// --- Interlocked operations ---

pub fn stub_InterlockedIncrement(lpAddend: usize) callconv(.winapi) i32 {
    if (lpAddend == 0) return 0;
    const ptr = @as(*i32, @ptrFromInt(lpAddend));
    return @atomicRmw(i32, ptr, .Add, 1, .seq_cst) + 1;
}

pub fn stub_InterlockedDecrement(lpAddend: usize) callconv(.winapi) i32 {
    if (lpAddend == 0) return 0;
    const ptr = @as(*i32, @ptrFromInt(lpAddend));
    return @atomicRmw(i32, ptr, .Sub, 1, .seq_cst) - 1;
}

// --- Critical sections ---

pub fn stub_InitializeCriticalSection(lpCriticalSection: usize) callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("KERNEL32: InitializeCriticalSection({x})\n", .{lpCriticalSection});
}

pub fn stub_EnterCriticalSection(lpCriticalSection: usize) callconv(.winapi) void {
    _ = lpCriticalSection;
}

pub fn stub_LeaveCriticalSection(lpCriticalSection: usize) callconv(.winapi) void {
    _ = lpCriticalSection;
}

pub fn stub_DeleteCriticalSection(lpCriticalSection: usize) callconv(.winapi) void {
    if (trace.enable_tracing) trace.print("KERNEL32: DeleteCriticalSection({x})\n", .{lpCriticalSection});
}

// --- Events ---

pub fn stub_CreateEventA(lpEventAttributes: usize, bManualReset: i32, bInitialState: i32, lpName: usize) callconv(.winapi) usize {
    _ = lpEventAttributes;
    _ = bManualReset;
    _ = bInitialState;
    _ = lpName;
    if (trace.enable_tracing) trace.print("KERNEL32: CreateEventA\n", .{});
    return 0xE0000001;
}

pub fn stub_ResetEvent(hEvent: usize) callconv(.winapi) i32 {
    _ = hEvent;
    return 1;
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

pub fn stub_TlsAlloc() callconv(.winapi) u32 {
    if (tls_next >= MAX_TLS_SLOTS) return 0xFFFFFFFF; // TLS_OUT_OF_INDEXES
    const idx = tls_next;
    tls_next += 1;
    return idx;
}

pub fn stub_TlsGetValue(dwTlsIndex: u32) callconv(.winapi) usize {
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    const entry = getOrCreateTlsEntry();
    return entry.slots[dwTlsIndex];
}

pub fn stub_TlsSetValue(dwTlsIndex: u32, lpTlsValue: usize) callconv(.winapi) i32 {
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    const entry = getOrCreateTlsEntry();
    entry.slots[dwTlsIndex] = lpTlsValue;
    return 1;
}

// --- Mutexes ---

var next_mutex_handle: usize = 0xB0000001;

pub fn stub_CreateMutexA(lpMutexAttributes: usize, bInitialOwner: i32, lpName: usize) callconv(.winapi) usize {
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
