//! KERNEL32 error and exception handling functions.

const std = @import("std");
const trace = @import("../../trace.zig");
const platform = @import("../../platform.zig");
const w32cc = @import("../calling_convention.zig");

/// Describes an exception.
pub const EXCEPTION_RECORD = extern struct {
    ExceptionCode: u32,
    ExceptionFlags: u32,
    ExceptionRecord: u32, // pointer
    ExceptionAddress: u32, // pointer
    NumberParameters: u32,
    ExceptionInformation: [15]u32,
};

/// Contains processor-specific register data.
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

/// Represents an entry in the structured exception handling (SEH) chain.
pub const EXCEPTION_REGISTRATION_RECORD = extern struct {
    Next: u32,
    Handler: u32,
};

/// Raises an exception in the calling thread.
/// Implementation status: Partially implemented
pub fn RaiseException(dwExceptionCode: u32, dwExceptionFlags: u32, nNumberOfArguments: u32, lpArguments: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) {
        trace.print("KERNEL32: RaiseException(code={x}, flags={x}, nArgs={d})\n", .{ dwExceptionCode, dwExceptionFlags, nNumberOfArguments });
        // For MSVC C++ exceptions (0xE06D7363), dump the exception args
        if (dwExceptionCode == 0xE06D7363 and lpArguments != 0 and nNumberOfArguments >= 3) {
            const args = @as([*]const u32, @ptrFromInt(lpArguments));
            trace.print("  C++ Exception: magic={x}, throwObj={x}, throwInfo={x}\n", .{ args[0], args[1], args[2] });
            // Try to read the thrown object's type from ThrowInfo
            const throw_info = args[2];
            if (throw_info >= 0x400000) {
                // 32-bit MSVC uses absolute pointers in ThrowInfo
                const catchable_array_ptr = @as(*const u32, @ptrFromInt(throw_info + 12)).*;
                if (catchable_array_ptr >= 0x400000) {
                    const count = @as(*const u32, @ptrFromInt(catchable_array_ptr)).*;
                    if (count > 0 and count < 20) {
                        const first_ptr = @as(*const u32, @ptrFromInt(catchable_array_ptr + 4)).*;
                        if (first_ptr >= 0x400000) {
                            // CatchableType: pType is at offset 4
                            const type_desc_ptr = @as(*const u32, @ptrFromInt(first_ptr + 4)).*;
                            if (type_desc_ptr >= 0x400000) {
                                // type_descriptor: [vtable, spare, name...]
                                const name_ptr = type_desc_ptr + 8;
                                trace.print("  C++ Exception type: {s}\n", .{trace.c_span(name_ptr)});
                            }
                        }
                    }
                }
                // Read thrown object contents
                const obj = args[1];
                if (obj > 0x10000) {
                    // Try as std::exception: [vtable, _Mywhat (char*), _DoFree]
                    const msg_ptr = @as(*const u32, @ptrFromInt(obj + 4)).*;
                    if (msg_ptr > 0x10000 and msg_ptr < 0x70000000) {
                        trace.print("  Exception what(): {s}\n", .{trace.c_span(msg_ptr)});
                    }
                    // Try as UString (7z CMessagePathException): [_chars (wchar_t*), _len, _capacity]
                    const wptr = @as(*const u32, @ptrFromInt(obj)).*;
                    if (wptr > 0x10000 and wptr < 0x70000000) {
                        const wsrc = @as([*]const u16, @ptrFromInt(wptr));
                        var wbuf: [256]u8 = undefined;
                        var wlen: usize = 0;
                        while (wlen < 255 and wsrc[wlen] != 0) : (wlen += 1) {
                            wbuf[wlen] = @truncate(wsrc[wlen]);
                        }
                        if (wlen > 0) {
                            trace.print("  UString content: {s}\n", .{wbuf[0..wlen]});
                        }
                    }
                }
            }
        }
    }

    var exception_list: u32 = platform.readExceptionList();
    // In interpret mode, FS:[0] might not reflect the guest's SEH chain
    // because the interpreter writes through native_linear memory (direct
    // pointer dereference) but readExceptionList uses the FS segment register.
    // If the result is 0 or 0xFFFFFFFF (empty), try reading directly from TEB.
    if (exception_list == 0 or exception_list == 0xFFFFFFFF) {
        const teb_mod = @import("../teb.zig");
        if (teb_mod.teb_base_addr != 0) {
            const teb_val = @as(*const u32, @ptrFromInt(teb_mod.teb_base_addr)).*;
            if (teb_val != 0 and teb_val != 0xFFFFFFFF) {
                exception_list = teb_val;
            }
        }
    }

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

    // Use saved CONTEXT from signal handler if available (hardware exceptions),
    // otherwise create a zeroed CONTEXT (software exceptions like C++ throw).
    var ctx: CONTEXT = if (saved_hw_context) |hwctx|
        @as(*const CONTEXT, @ptrCast(hwctx)).*
    else
        std.mem.zeroes(CONTEXT);
    ctx.ContextFlags = 0x10007; // CONTEXT_FULL
    saved_hw_context = null; // consume it

    var current_node = exception_list;
    while (current_node != 0 and current_node != 0xFFFFFFFF) {
        if (trace.enable_tracing) trace.print("  SEH Node: {x}\n", .{current_node});
        const node = @as(*EXCEPTION_REGISTRATION_RECORD, @ptrFromInt(current_node));
        const handler = node.Handler;

        if (handler != 0) {
            if (trace.enable_tracing) trace.print("  Calling SEH Handler: {x}\n", .{handler});
            const HandlerFn = *const fn (record: *EXCEPTION_RECORD, establisherFrame: u32, contextRecord: *CONTEXT, dispatcherContext: u32) callconv(w32cc.WINAPI) u32;

            const func = @as(HandlerFn, @ptrFromInt(handler));
            const disp = func(&rec, current_node, &ctx, 0);
            if (trace.enable_tracing) trace.print("  Handler returned: {d}\n", .{disp});

            if (disp == 0) { // ExceptionContinueExecution
                if (trace.enable_tracing) trace.print("  ExceptionContinueExecution: resuming at EIP={x}\n", .{ctx.Eip});
                // The handler modified ctx.Eip. We need to resume there.
                // Use noinline setjmp-like asm to transfer control.
                if (comptime platform.is_native) {
                    resumeAtEip(ctx.Eip, ctx.Esp, ctx.Ebp, ctx.Eax, ctx.Ebx, ctx.Ecx, ctx.Edx, ctx.Esi, ctx.Edi);
                    unreachable;
                }
                return;
            } else if (disp == 1) { // ExceptionContinueSearch
            } else {
                if (trace.enable_tracing) trace.print("  Unknown disposition or unwound natively.\n", .{});
            }
        }

        current_node = node.Next;
    }

    // If we get here, no SEH handler handled the exception.

    // STATUS_FATAL_APP_EXIT (0x40000015) — from _amsg_exit (R6025 pure virtual call, etc.)
    // Instead of terminating, return gracefully. The calling code may recover.
    if (dwExceptionCode == 0x40000015) {
        if (trace.enable_tracing) trace.print("KERNEL32: RaiseException(STATUS_FATAL_APP_EXIT) — suppressed, returning\n", .{});
        return;
    }

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

/// Saved signal context when dispatching SEH from a signal handler.
pub var signal_context: ?*std.posix.ucontext_t = null;

/// Saved CONTEXT from signal handler for hardware exceptions (SIGILL/SIGSEGV).
pub var saved_hw_context: ?*@import("../teb.zig").CONTEXT = null;

/// Unwinds the stack to TargetFrame, calling SEH handlers along the way, then transfer control to TargetIp.
/// Implementation status: Partially implemented
pub fn RtlUnwind(targetFrame: u32, targetIp: u32, pExceptionRecord: usize, returnValue: u32) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: RtlUnwind(frame={x}, ip={x}, retVal={x})\n", .{ targetFrame, targetIp, returnValue });

    // Walk the SEH chain and call handlers with EXCEPTION_UNWIND (0x2)
    var exception_list: u32 = platform.readExceptionList();
    if (exception_list == 0 or exception_list == 0xFFFFFFFF) {
        const teb_mod = @import("../teb.zig");
        if (teb_mod.teb_base_addr != 0) {
            const teb_val = @as(*const u32, @ptrFromInt(teb_mod.teb_base_addr)).*;
            if (teb_val != 0 and teb_val != 0xFFFFFFFF) {
                exception_list = teb_val;
            }
        }
    }

    _ = pExceptionRecord;

    // Remove SEH frames from the chain up to (but not including) targetFrame.
    // We do NOT call the handlers with EXCEPTION_UNWINDING because we're
    // already inside a handler call from RaiseException — calling handlers
    // re-entrantly corrupts the stack. The MSVC C++ exception handler
    // (__CxxFrameHandler) that called us will handle the control transfer.
    const teb_mod = @import("../teb.zig");
    var current_node = exception_list;
    while (current_node != 0 and current_node != 0xFFFFFFFF) {
        if (targetFrame != 0 and current_node == targetFrame) break;
        const next = @as(*const u32, @ptrFromInt(current_node)).*;
        if (trace.enable_tracing) trace.print("  RtlUnwind: removing frame {x}\n", .{current_node});
        current_node = next;
    }
    // Update FS:[0] / TEB to point to the target frame (or the frame we stopped at)
    if (teb_mod.teb_base_addr != 0) {
        @as(*u32, @ptrFromInt(teb_mod.teb_base_addr)).* = current_node;
    }
    if (trace.enable_tracing) trace.print("  RtlUnwind: chain head now {x}\n", .{current_node});

    // If called from within signal handler's SEH dispatch, modify the signal
    // context to resume at targetIp with EBP set to the target frame.
    // This prevents the handler from jumping out of the signal handler context.
    if (signal_context) |uctx| {
        if (targetIp != 0 and comptime platform.is_native) {
            const REG = std.os.linux.REG;
            const frame_ebp = targetFrame +% 8;
            uctx.mcontext.gregs[REG.EIP] = targetIp;
            uctx.mcontext.gregs[REG.EBP] = frame_ebp;
            uctx.mcontext.gregs[REG.EAX] = returnValue;
            if (trace.enable_tracing) trace.print("  RtlUnwind: modified signal context EIP={x} EBP={x}\n", .{ targetIp, frame_ebp });
        }
    }
}

/// Resume execution at a new EIP with specified register state.
noinline fn resumeAtEip(eip: u32, esp_val: u32, ebp_val: u32, eax: u32, ebx: u32, ecx: u32, edx: u32, esi: u32, edi: u32) void {
    _ = .{ eax, ebx, ecx, edx, esi, edi }; // passed in regs but asm accesses via stack
    asm volatile (
        \\movl %[ebp_r], %%ebp
        \\movl %[esp_r], %%esp
        \\jmp *%[eip_r]
        :
        : [eip_r] "r" (eip),
          [esp_r] "r" (esp_val),
          [ebp_r] "r" (ebp_val),
    );
    unreachable;
}

/// Last error code for the calling thread.
pub var last_error: u32 = 0;

/// Sets the last-error code for the calling thread.
/// Implementation status: Partially implemented
pub fn SetLastError(dwErrCode: u32) callconv(w32cc.WINAPI) void {
    last_error = dwErrCode;
}

/// Retrieves the calling thread's last-error code value.
/// Implementation status: Partially implemented
pub fn GetLastError() callconv(w32cc.WINAPI) u32 {
    return last_error;
}

/// Top-level exception filter.
pub var unhandled_exception_filter: usize = 0;

/// Enables an application to supersede the top-level exception handler of each thread and process.
/// Implementation status: Partially implemented
pub fn SetUnhandledExceptionFilter(lpTopLevelExceptionFilter: usize) callconv(w32cc.WINAPI) usize {
    const prev = unhandled_exception_filter;
    unhandled_exception_filter = lpTopLevelExceptionFilter;
    return prev;
}

/// Controls whether the system will handle the specified types of serious errors or whether the process will handle them.
/// Implementation status: Stub
pub fn stub_SetErrorMode(uMode: u32) callconv(w32cc.WINAPI) u32 {
    _ = uMode;
    return 0; // Return old mode
}

/// Displays a message box and terminates the application.
/// Implementation status: Partially implemented
pub fn FatalAppExitA(uAction: u32, lpMessageText: usize) callconv(w32cc.WINAPI) void {
    _ = uAction;
    if (lpMessageText != 0) {
        const msg = trace.c_span(lpMessageText);
        trace.print("KERNEL32: FatalAppExitA: {s}\n", .{msg});
    }
    platform.exitProcess(1);
}

/// Sends a string to the debugger for display.
/// Implementation status: Partially implemented
pub fn OutputDebugStringA(lpOutputString: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing and lpOutputString != 0) {
        const s = trace.c_span(lpOutputString);
        trace.print("KERNEL32: OutputDebugStringA('{s}')\n", .{s});
    }
}
