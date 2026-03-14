const std = @import("std");
const trace = @import("../../trace.zig");
const platform = @import("../../platform.zig");
const w32cc = @import("../../calling_convention.zig");

pub const EXCEPTION_RECORD = extern struct {
    ExceptionCode: u32,
    ExceptionFlags: u32,
    ExceptionRecord: u32, // pointer
    ExceptionAddress: u32, // pointer
    NumberParameters: u32,
    ExceptionInformation: [15]u32,
};

pub const CONTEXT = extern struct {
    ContextFlags: u32,
    Dr0: u32,
    Dr1: u32,
    Dr2: u32,
    Dr3: u32,
    Dr6: u32,
    Dr7: u32,
    FloatSave: [112]u8, // dummy
    SegGs: u32,
    SegFs: u32,
    SegEs: u32,
    SegDs: u32,
    Edi: u32,
    Esi: u32,
    Ebx: u32,
    Edx: u32,
    Ecx: u32,
    Eax: u32,
    Ebp: u32,
    Eip: u32,
    SegCs: u32,
    EFlags: u32,
    Esp: u32,
    SegSs: u32,
    ExtendedRegisters: [512]u8,
};

pub const EXCEPTION_REGISTRATION_RECORD = extern struct {
    Next: u32,
    Handler: u32,
};

pub fn RaiseException(dwExceptionCode: u32, dwExceptionFlags: u32, nNumberOfArguments: u32, lpArguments: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) {
        trace.print("KERNEL32: RaiseException(code={x})\n", .{dwExceptionCode});
    }

    const exception_list: u32 = platform.readExceptionList();

    var rec = std.mem.zeroes(EXCEPTION_RECORD);
    rec.ExceptionCode = dwExceptionCode;
    rec.ExceptionFlags = dwExceptionFlags;
    rec.NumberParameters = nNumberOfArguments;
    if (nNumberOfArguments > 0 and lpArguments != 0) {
        const args = @as([*]u32, @ptrFromInt(lpArguments));
        const limit = @min(nNumberOfArguments, 15);
        for (0..limit) |i| {
            rec.ExceptionInformation[i] = args[i];
        }
    }

    var ctx = std.mem.zeroes(CONTEXT);
    ctx.ContextFlags = 0x1003f; // CONTEXT_ALL

    var current_node = exception_list;
    while (current_node != 0 and current_node != 0xFFFFFFFF) {
        if (trace.enable_tracing) trace.print("  SEH Node: {x}\n", .{current_node});
        const node = @as(*EXCEPTION_REGISTRATION_RECORD, @ptrFromInt(current_node));
        const handler = node.Handler;

        if (handler != 0) {
            if (trace.enable_tracing) trace.print("  Calling SEH Handler: {x}\n", .{handler});
            const HandlerFn = *const fn (record: *EXCEPTION_RECORD, establisherFrame: u32, contextRecord: *CONTEXT, dispatcherContext: u32) callconv(w32cc.WINAPI) u32; // SEH handlers use C calling convention

            const func = @as(HandlerFn, @ptrFromInt(handler));
            const disp = func(&rec, current_node, &ctx, 0);
            if (trace.enable_tracing) trace.print("  Handler returned: {d}\n", .{disp});

            if (disp == 0) { // ExceptionContinueExecution
                if (trace.enable_tracing) trace.print("  ExceptionContinueExecution requested!\n", .{});
                return;
            } else if (disp == 1) { // ExceptionContinueSearch
            } else {
                if (trace.enable_tracing) trace.print("  Unknown disposition or unwound natively.\n", .{});
            }
        }

        current_node = node.Next;
    }

    // If we get here, no SEH handler handled the exception.
    // Software exceptions (bit 29 set, e.g. 0xE0005031 from MSVC CRT longjmp)
    // are non-fatal control flow mechanisms.  Return gracefully instead of
    // crashing — the guest code may be able to continue.
    if (dwExceptionCode & 0x20000000 != 0) {
        if (trace.enable_tracing) trace.print("KERNEL32: RaiseException(code={x}) — software exception, returning\n", .{dwExceptionCode});
        return;
    }

    if (trace.enable_tracing) trace.print("KERNEL32: Unhandled exception! Terminating.\n", .{});
    platform.exitProcess(1);
}

// --- Error handling ---

pub var last_error: u32 = 0;

pub fn SetLastError(dwErrCode: u32) callconv(w32cc.WINAPI) void {
    last_error = dwErrCode;
}

pub var unhandled_exception_filter: usize = 0;

pub fn SetUnhandledExceptionFilter(lpTopLevelExceptionFilter: usize) callconv(w32cc.WINAPI) usize {
    const prev = unhandled_exception_filter;
    unhandled_exception_filter = lpTopLevelExceptionFilter;
    return prev;
}

pub fn stub_SetErrorMode(uMode: u32) callconv(w32cc.WINAPI) u32 {
    _ = uMode;
    return 0; // Return old mode
}

pub fn FatalAppExitA(uAction: u32, lpMessageText: usize) callconv(w32cc.WINAPI) void {
    _ = uAction;
    if (lpMessageText != 0) {
        const msg = trace.c_span(lpMessageText);
        trace.print("KERNEL32: FatalAppExitA: {s}\n", .{msg});
    }
    platform.exitProcess(1);
}

pub fn OutputDebugStringA(lpOutputString: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing and lpOutputString != 0) {
        const s = trace.c_span(lpOutputString);
        trace.print("KERNEL32: OutputDebugStringA('{s}')\n", .{s});
    }
}
