//! MSVCRT.dll C++ exception handling registration.

const trace = @import("../../trace.zig");

/// MSVC C++ Exception Handler (__CxxFrameHandler)
/// For C++ exceptions (0xE06D7363): parses the FuncInfo structure from the
/// handler wrapper thunk to find and dispatch to catch blocks.
/// For non-C++ exceptions (SIGSEGV etc): returns 1 (ExceptionContinueSearch)
/// to avoid infinite resume loops.
/// Implementation status: Partially implemented
pub fn CxxFrameHandler(
    pExceptionRecord: usize,
    pEstablisherFrame: usize,
    pContextRecord: usize,
    pDispatcherContext: usize,
) callconv(.c) i32 {
    _ = .{ pContextRecord, pDispatcherContext };

    // Only handle MSVC C++ throw exceptions (0xE06D7363)
    if (pExceptionRecord < 0x1000) return 0;
    const exc_code = @as(*align(1) const u32, @ptrFromInt(pExceptionRecord)).*;
    if (exc_code != 0xE06D7363) return 1; // ContinueSearch for non-C++

    // Read handler address from SEH registration record [frame+4]
    if (pEstablisherFrame < 0x1000) return 0;
    const handler_addr = @as(*align(1) const u32, @ptrFromInt(pEstablisherFrame + 4)).*;

    // The wrapper thunk is: B8 <FuncInfo> E9 <rel32> (MOV EAX, imm32; JMP)
    if (handler_addr < 0x10000) return 0;
    const b0 = @as(*const u8, @ptrFromInt(handler_addr)).*;
    if (b0 != 0xB8) return 1;
    const b5 = @as(*const u8, @ptrFromInt(handler_addr + 5)).*;
    if (b5 != 0xE9) return 1;

    const funcinfo_ptr = @as(*align(1) const u32, @ptrFromInt(handler_addr + 1)).*;
    if (funcinfo_ptr < 0x10000) return 1;

    // Validate FuncInfo magic
    const magic = @as(*align(1) const u32, @ptrFromInt(funcinfo_ptr)).*;
    if (magic != 0x19930520) return 1;

    // Read nTryBlocks and pTryBlockMap
    const n_try = @as(*align(1) const i32, @ptrFromInt(funcinfo_ptr + 12)).*;
    if (n_try <= 0) return 1; // no try blocks — continue search

    const try_map = @as(*align(1) const u32, @ptrFromInt(funcinfo_ptr + 16)).*;
    if (try_map < 0x10000) return 0;

    // Read first TryBlockMapEntry: { tryLow, tryHigh, catchHigh, nCatches, pHandlerArray }
    const n_catches = @as(*align(1) const i32, @ptrFromInt(try_map + 12)).*;
    if (n_catches <= 0) return 0;

    const handler_array = @as(*align(1) const u32, @ptrFromInt(try_map + 16)).*;
    if (handler_array < 0x10000) return 0;

    // Read first HandlerType: { adjectives, pType, dispCatchObj, addressOfHandler }
    const catch_handler = @as(*align(1) const u32, @ptrFromInt(handler_array + 12)).*;
    if (catch_handler < 0x10000) return 0;

    if (trace.enable_tracing) trace.print("MSVCRT: __CxxFrameHandler: dispatching to catch at {x}\n", .{catch_handler});

    // Set try_level to -1 (unwound)
    @as(*align(1) i32, @ptrFromInt(pEstablisherFrame + 12)).* = -1;

    // Jump to the catch handler
    const frame_ebp = pEstablisherFrame + 16;
    @import("except.zig").jump_to_seh_handler(catch_handler, frame_ebp);
    unreachable;
}
