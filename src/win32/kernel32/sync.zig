const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");
const platform = @import("../../platform.zig");

/// --- Interlocked operations ---
/// Implementation status: Partially implemented
pub fn InterlockedIncrement(lpAddend: *i32) callconv(w32cc.WINAPI) i32 {
    return @atomicRmw(i32, lpAddend, .Add, 1, .seq_cst) + 1;
}

pub fn InterlockedDecrement(lpAddend: *i32) callconv(w32cc.WINAPI) i32 {
    return @atomicRmw(i32, lpAddend, .Sub, 1, .seq_cst) - 1;
}

// --- Critical sections ---
// Win32 CRITICAL_SECTIONs are RECURSIVE — the same thread can enter
// multiple times without deadlocking. We track owner thread + recursion count.

const MAX_CRITICAL_SECTIONS = 256;

const CriticalSection = struct {
    mutex: std.Thread.Mutex = .{},
    owner: std.Thread.Id = 0,
    recursion: u32 = 0,
    addr: usize = 0,
};

var cs_table: [MAX_CRITICAL_SECTIONS]CriticalSection = init_cs: {
    var arr: [MAX_CRITICAL_SECTIONS]CriticalSection = undefined;
    for (&arr) |*cs| cs.* = .{};
    break :init_cs arr;
};

fn getOrCreateCS(addr: usize) ?*CriticalSection {
    for (&cs_table) |*cs| {
        if (cs.addr == addr) return cs;
    }
    for (&cs_table) |*cs| {
        if (cs.addr == 0) {
            cs.* = .{ .addr = addr };
            return cs;
        }
    }
    return null;
}

/// Implementation status: Partially implemented
pub fn InitializeCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: InitializeCriticalSection({x})\n", .{lpCriticalSection});
    if (lpCriticalSection != 0) _ = getOrCreateCS(lpCriticalSection);
}

/// Implementation status: Partially implemented
pub fn EnterCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (lpCriticalSection == 0) return;
    const cs = getOrCreateCS(lpCriticalSection) orelse return;
    const tid = std.Thread.getCurrentId();
    if (cs.owner == tid) {
        // Recursive entry — same thread, just bump count
        cs.recursion += 1;
        return;
    }
    cs.mutex.lock();
    cs.owner = tid;
    cs.recursion = 1;
}

/// Implementation status: Partially implemented
pub fn LeaveCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (lpCriticalSection == 0) return;
    const cs = getOrCreateCS(lpCriticalSection) orelse return;
    if (cs.recursion > 1) {
        cs.recursion -= 1;
        return;
    }
    cs.owner = 0;
    cs.recursion = 0;
    cs.mutex.unlock();
}

/// Implementation status: Partially implemented
pub fn DeleteCriticalSection(lpCriticalSection: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: DeleteCriticalSection({x})\n", .{lpCriticalSection});
    if (lpCriticalSection == 0) return;
    for (&cs_table) |*cs| {
        if (cs.addr == lpCriticalSection) {
            cs.* = .{};
            return;
        }
    }
}

/// --- Events ---
/// Implementation status: Stub
pub fn stub_CreateEventA(lpEventAttributes: usize, bManualReset: i32, bInitialState: i32, lpName: usize) callconv(w32cc.WINAPI) usize {
    _ = lpEventAttributes;
    _ = bManualReset;
    _ = bInitialState;
    _ = lpName;
    if (trace.enable_tracing) trace.print("KERNEL32: CreateEventA\n", .{});
    return 0xE0000001;
}

/// stub_ResetEvent
/// Implementation status: No-op fallback
pub fn stub_ResetEvent(hEvent: usize) callconv(w32cc.WINAPI) i32 {
    _ = hEvent;
    return 1;
}

/// stub_SetEvent
/// Implementation status: No-op fallback
pub fn stub_SetEvent(hEvent: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: SetEvent({x})\n", .{hEvent});
    return 1; // Success
}

/// WAIT_OBJECT_0 = 0
/// Implementation status: Partially implemented
pub fn WaitForSingleObject(hHandle: usize, dwMilliseconds: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: WaitForSingleObject({x}, {d})\n", .{ hHandle, dwMilliseconds });

    // Check if this is a child process handle
    const process = @import("process.zig");
    if (process.getChildProc(hHandle)) |cp| {
        if (comptime platform.is_native) {
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
        }
        // On WASM, thread already ran synchronously
        return 0; // WAIT_OBJECT_0
    }

    // Yield to allow other threads to run
    if (dwMilliseconds > 0) {
        const sleep_ns: u64 = @min(@as(u64, dwMilliseconds) * 1_000_000, 10_000_000); // Cap at 10ms
        std.Thread.sleep(sleep_ns);
    }
    return 0; // WAIT_OBJECT_0
}

/// stub_WaitForMultipleObjects
/// Implementation status: Stub
pub fn stub_WaitForMultipleObjects(nCount: u32, lpHandles: usize, bWaitAll: i32, dwMilliseconds: u32) callconv(w32cc.WINAPI) u32 {
    _ = nCount;
    _ = lpHandles;
    _ = bWaitAll;
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

/// Implementation status: Partially implemented
pub fn TlsAlloc() callconv(w32cc.WINAPI) u32 {
    if (tls_next >= MAX_TLS_SLOTS) return 0xFFFFFFFF; // TLS_OUT_OF_INDEXES
    const idx = tls_next;
    tls_next += 1;
    return idx;
}

/// Implementation status: Partially implemented
pub fn TlsGetValue(dwTlsIndex: u32) callconv(w32cc.WINAPI) usize {
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    const entry = getOrCreateTlsEntry();
    return entry.slots[dwTlsIndex];
}

/// Implementation status: Partially implemented
pub fn TlsSetValue(dwTlsIndex: u32, lpTlsValue: usize) callconv(w32cc.WINAPI) i32 {
    if (dwTlsIndex >= MAX_TLS_SLOTS) return 0;
    const entry = getOrCreateTlsEntry();
    entry.slots[dwTlsIndex] = lpTlsValue;
    return 1;
}

var next_mutex_handle: usize = 0xB0000001;

/// --- Mutexes ---
/// Implementation status: No-op fallback
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

/// stub_ReleaseMutex
/// Implementation status: No-op fallback
pub fn stub_ReleaseMutex(hMutex: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: ReleaseMutex({x})\n", .{hMutex});
    return 1; // TRUE = success
}

/// stub_ReleaseSemaphore
/// Implementation status: No-op fallback
pub fn stub_ReleaseSemaphore(hSemaphore: usize, lReleaseCount: i32, lpPreviousCount: usize) callconv(w32cc.WINAPI) i32 {
    _ = hSemaphore;
    _ = lReleaseCount;
    if (lpPreviousCount != 0) {
        @as(*i32, @ptrFromInt(lpPreviousCount)).* = 0;
    }
    return 1; // TRUE = success
}

var next_dup_handle: usize = 0xD0000001;

/// Implementation status: Partially implemented
pub fn DuplicateHandle(
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
    if (lpTargetHandle == 0) return 1;

    // For real file descriptors (small values), use dup()
    if (comptime platform.is_native) {
        if (hSourceHandle < 0x10000) {
            const src_fd = @as(i32, @bitCast(@as(u32, @truncate(hSourceHandle))));
            const new_fd = platform.dup(src_fd) catch {
                // Fallback to fake handle
                @as(*u32, @ptrFromInt(lpTargetHandle)).* = @truncate(next_dup_handle);
                next_dup_handle += 1;
                return 1;
            };
            if (trace.enable_tracing) trace.print("KERNEL32: DuplicateHandle fd {d} -> {d}\n", .{ src_fd, new_fd });
            @as(*u32, @ptrFromInt(lpTargetHandle)).* = @as(u32, @bitCast(new_fd));
            return 1;
        }
    }

    // Synthetic handle: return a new fake one
    @as(*u32, @ptrFromInt(lpTargetHandle)).* = @truncate(next_dup_handle);
    next_dup_handle += 1;
    return 1; // TRUE = success
}

/// --- InterlockedCompareExchange ---
/// LONG InterlockedCompareExchange(LONG volatile *Destination, LONG Exchange, LONG Comperand)
/// Implementation status: Partially implemented
pub fn InterlockedCompareExchange(dest: usize, exchange: i32, comperand: i32) callconv(w32cc.WINAPI) i32 {
    if (dest == 0) return 0;
    const ptr = @as(*i32, @ptrFromInt(dest));
    return @cmpxchgStrong(i32, ptr, comperand, exchange, .seq_cst, .seq_cst) orelse comperand;
}

var next_change_handle: usize = 0xCE000001;

/// --- File change notifications (stub: return fake handles, no-op poll) ---
/// Implementation status: No-op fallback
pub fn stub_FindFirstChangeNotificationW(path_ptr: usize, watch_subtree: i32, filter: u32) callconv(w32cc.WINAPI) usize {
    _ = path_ptr;
    _ = watch_subtree;
    _ = filter;
    const h = next_change_handle;
    next_change_handle += 1;
    if (trace.enable_tracing) trace.print("KERNEL32: FindFirstChangeNotificationW -> {x}\n", .{h});
    return h;
}

/// stub_FindNextChangeNotification
/// Implementation status: No-op fallback
pub fn stub_FindNextChangeNotification(hChangeHandle: usize) callconv(w32cc.WINAPI) i32 {
    _ = hChangeHandle;
    return 1; // TRUE
}

/// --- SList (Interlocked Singly Linked Lists) ---
/// Implementation status: Partially implemented
pub fn InitializeSListHead(ListHead: usize) callconv(w32cc.WINAPI) void {
    // SLIST_HEADER is 8 bytes on x86 — zero it out
    if (ListHead != 0) {
        @memset(@as([*]u8, @ptrFromInt(ListHead))[0..8], 0);
    }
}

/// Implementation status: Partially implemented
pub fn InterlockedFlushSList(ListHead: usize) callconv(w32cc.WINAPI) usize {
    if (ListHead != 0) {
        // Read the first pointer (first 4 bytes of SLIST_HEADER)
        const first: usize = @as(*u32, @ptrFromInt(ListHead)).*;
        @as(*u32, @ptrFromInt(ListHead)).* = 0; // Clear the list
        return first;
    }
    return 0; // Empty list
}

/// --- Extended Critical Sections ---
/// Implementation status: Partially implemented
pub fn InitializeCriticalSectionEx(lpCriticalSection: usize, dwSpinCount: u32, flags: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: InitializeCriticalSectionEx(cs={X}, spin={d}, flags={X})\n", .{ lpCriticalSection, dwSpinCount, flags });
    InitializeCriticalSection(lpCriticalSection);
    return 1; // TRUE = success
}

/// Implementation status: Partially implemented
pub fn InitializeCriticalSectionAndSpinCount(lpCriticalSection: usize, dwSpinCount: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: InitializeCriticalSectionAndSpinCount(cs={X}, spin={d})\n", .{ lpCriticalSection, dwSpinCount });
    InitializeCriticalSection(lpCriticalSection);
    return 1; // TRUE = success
}

/// --- Pointer encoding (identity transform in emulation) ---
/// Implementation status: Partially implemented
pub fn EncodePointer(ptr: usize) callconv(w32cc.WINAPI) usize {
    return ptr; // No encoding needed
}

/// Implementation status: Partially implemented
pub fn DecodePointer(ptr: usize) callconv(w32cc.WINAPI) usize {
    return ptr; // No decoding needed
}

var fls_next: u32 = 0;
const MAX_FLS_SLOTS = 128;
var fls_values: [MAX_FLS_SLOTS]usize = [_]usize{0} ** MAX_FLS_SLOTS;
var fls_callbacks: [MAX_FLS_SLOTS]usize = [_]usize{0} ** MAX_FLS_SLOTS;

/// --- Fiber Local Storage (FLS) ---
/// FLS is like TLS but per-fiber. We're single-fiber, so just use simple slots.
/// Implementation status: Partially implemented
pub fn FlsAlloc(lpCallback: usize) callconv(w32cc.WINAPI) u32 {
    if (fls_next >= MAX_FLS_SLOTS) return 0xFFFFFFFF; // FLS_OUT_OF_INDEXES
    const idx = fls_next;
    fls_callbacks[idx] = lpCallback;
    fls_values[idx] = 0;
    fls_next += 1;
    if (trace.enable_tracing) trace.print("KERNEL32: FlsAlloc -> {d}\n", .{idx});
    return idx;
}

/// Implementation status: Partially implemented
pub fn FlsGetValue(dwFlsIndex: u32) callconv(w32cc.WINAPI) usize {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    return fls_values[dwFlsIndex];
}

/// Implementation status: Partially implemented
pub fn FlsSetValue(dwFlsIndex: u32, lpFlsData: usize) callconv(w32cc.WINAPI) i32 {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    fls_values[dwFlsIndex] = lpFlsData;
    return 1; // TRUE
}

/// Implementation status: Partially implemented
pub fn FlsFree(dwFlsIndex: u32) callconv(w32cc.WINAPI) i32 {
    if (dwFlsIndex >= MAX_FLS_SLOTS) return 0;
    fls_values[dwFlsIndex] = 0;
    fls_callbacks[dwFlsIndex] = 0;
    return 1; // TRUE
}

/// --- Additional sync stubs ---
/// Implementation status: Partially implemented
pub fn InterlockedExchange(target: usize, value: i32) callconv(w32cc.WINAPI) i32 {
    if (target == 0) return 0;
    const ptr = @as(*i32, @ptrFromInt(target));
    return @atomicRmw(i32, ptr, .Xchg, value, .seq_cst);
}

/// Implementation status: Partially implemented
pub fn TlsFree(dwTlsIndex: u32) callconv(w32cc.WINAPI) i32 {
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

/// stub_CreateSemaphoreA
/// Implementation status: Stub
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

/// stub_OpenEventA
/// Implementation status: Stub
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
