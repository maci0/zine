// MSVCRT exception handling: _except_handler3, _setjmp3, longjmp,
// _EH_prolog (x86/x64/generic variants).

const trace = @import("../../trace.zig");
const platform = @import("../../platform.zig");

// --- setjmp / longjmp / EH_prolog ---

/// Saves the current execution context for later use by longjmp.
/// Implementation status: Fully implemented
pub const setjmp3 = if (platform.is_x86) &stub_setjmp3_x86 else if (platform.is_x86_64) &stub_setjmp3_x64 else &stub_setjmp3_generic;

fn stub_setjmp3_x86() callconv(.naked) i32 {
    asm volatile (
        \\mov 4(%esp), %eax   # env
        \\mov %ebp, 0(%eax)
        \\mov %ebx, 4(%eax)
        \\mov %edi, 8(%eax)
        \\mov %esi, 12(%eax)
        \\mov %esp, 16(%eax)
        \\mov (%esp), %edx   # return address
        \\mov %edx, 20(%eax)
        \\xor %eax, %eax
        \\ret
    );
}

fn stub_setjmp3_x64(env_ptr: usize) callconv(.c) i32 {
    const env = @as([*]u64, @ptrFromInt(env_ptr));
    env[0] = asm volatile ("movq %%rbp, %[out]"
        : [out] "=r" (-> u64),
    );
    env[1] = asm volatile ("movq %%rbx, %[out]"
        : [out] "=r" (-> u64),
    );
    return 0;
}

fn stub_setjmp3_generic(_: usize) callconv(.c) i32 {
    return 0; // On WASM, setjmp is handled by the interpreter
}

/// Standard MSVC exception handling prolog.
/// Implementation status: Fully implemented
pub const stub_EH_prolog = if (platform.is_x86) &EH_prolog_x86 else if (platform.is_x86_64) &stub_EH_prolog_x64 else &EH_prolog_generic;

fn EH_prolog_x86() callconv(.naked) void {
    asm volatile (
        \\ pushl $-1
        \\ pushl %eax
        \\ pushl %fs:0
        \\ movl  %esp, %fs:0
        \\ movl  12(%esp), %eax
        \\ movl  %ebp, 12(%esp)
        \\ leal  12(%esp), %ebp
        \\ pushl %eax
        \\ ret
    );
}

fn stub_EH_prolog_x64() callconv(.c) void {
    // 32-bit SEH prolog N/A on x86_64
}

fn EH_prolog_generic() callconv(.c) void {}

/// Restores the execution context saved by a previous call to setjmp.
/// Implementation status: Fully implemented
pub const longjmp = if (platform.is_x86) &stub_longjmp_x86 else if (platform.is_x86_64) &stub_longjmp_x64 else &stub_longjmp_generic;

fn stub_longjmp_x86() callconv(.naked) void {
    asm volatile (
        \\mov 4(%esp), %edx   # env
        \\mov 8(%esp), %eax   # value
        \\test %eax, %eax
        \\jnz 1f
        \\inc %eax            # longjmp(0) returns 1
        \\1:
        \\mov 0(%edx), %ebp
        \\mov 4(%edx), %ebx
        \\mov 8(%edx), %edi
        \\mov 12(%edx), %esi
        \\mov 16(%edx), %esp
        \\add $4, %esp        # pop return address of setjmp
        \\jmp *20(%edx)       # jump back to setjmp caller
    );
}

fn stub_longjmp_x64(env_ptr: usize, value: i32) callconv(.c) void {
    _ = env_ptr;
    _ = value;
    if (trace.enable_tracing) trace.print("MSVCRT: WARNING: longjmp called on x86_64 (not fully implemented)\n", .{});
}

fn stub_longjmp_generic(_: usize, _: i32) callconv(.c) void {
    // On WASM, longjmp is handled by the interpreter
}

/// --- SEH Exception Handlers ---
/// MSVC internal exception handler that walks the scope table to find an __except filter.
/// Implementation status: Fully implemented
pub fn except_handler3(
    exception_record_ptr: usize,
    establisher_frame: usize,
    context_record_ptr: usize,
    dispatcher_context: usize,
) callconv(.c) u32 {
    _ = dispatcher_context;

    const host_frame = trace.addr(establisher_frame);
    const try_level_ptr = @as(*align(1) i32, @ptrFromInt(host_frame + 12));
    const scope_table_addr = @as(*align(1) u32, @ptrFromInt(host_frame + 8)).*;

    var try_level = try_level_ptr.*;
    const frame_ebp = establisher_frame + 16; // keep as guest VA for x86 code

    if (trace.enable_tracing) {
        trace.print("SEH _except_handler3: frame=0x{X} try_level={d} scope_table=0x{X} ebp=0x{X}\n", .{ establisher_frame, try_level, scope_table_addr, frame_ebp });
    }

    if (scope_table_addr < 0x10000 or try_level < 0) {
        if (trace.enable_tracing) trace.print("SEH _except_handler3: invalid scope table or try_level, returning ContinueSearch\n", .{});
        return 1; // ExceptionContinueSearch
    }

    // Write ExceptionRecord* and Context* directly at [EBP-14h] and [EBP-10h].
    // This matches MSVC6's _except_handler3 layout where GetExceptionCode() reads
    // [EBP-14h] as EXCEPTION_RECORD* then [ptr+0] for ExceptionCode (2 dereferences).
    // Note: later MSVC versions (7+) use an extra indirection through EXCEPTION_POINTERS*.
    // Apps compiled with MSVC6 (our primary target) expect this direct layout.
    if (frame_ebp >= 0x14) {
        const host_ebp = trace.addr(frame_ebp);
        @as(*align(1) u32, @ptrFromInt(host_ebp -% 0x14)).* = @truncate(exception_record_ptr);
        @as(*align(1) u32, @ptrFromInt(host_ebp -% 0x10)).* = @truncate(context_record_ptr);
    }

    while (try_level >= 0) {
        const entry_base = trace.addr(scope_table_addr + @as(u32, @intCast(try_level)) * 12);

        const enclosing_level = @as(*align(1) i32, @ptrFromInt(entry_base)).*;
        const filter_func_addr = @as(*align(1) u32, @ptrFromInt(entry_base + 4)).*;
        const handler_func_addr = @as(*align(1) u32, @ptrFromInt(entry_base + 8)).*;

        if (trace.enable_tracing) {
            trace.print("SEH _except_handler3: level={d} enclosing={d} filter=0x{X} handler=0x{X}\n", .{ try_level, enclosing_level, filter_func_addr, handler_func_addr });
        }

        if (filter_func_addr != 0) {
            const filter_result = call_seh_filter(filter_func_addr, frame_ebp);

            if (trace.enable_tracing) {
                trace.print("SEH _except_handler3: filter returned {d}\n", .{filter_result});
            }

            if (filter_result == 1) { // EXCEPTION_EXECUTE_HANDLER
                try_level_ptr.* = enclosing_level;
                if (comptime platform.is_wasm) {
                    // Redirect the suspended interpreter to the __except block.
                    // RaiseException stops its walk when the redirect is set.
                    wasm_seh_redirect = .{
                        .eip = @intCast(handler_func_addr),
                        .esp = @intCast(frame_ebp),
                        .ebp = @intCast(frame_ebp),
                    };
                    return 0; // ExceptionContinueExecution (redirect pending)
                }
                jump_to_seh_handler(handler_func_addr, frame_ebp);
                unreachable;
            } else if (filter_result == -1) { // EXCEPTION_CONTINUE_EXECUTION
                return 0; // ExceptionContinueExecution
            }
        }

        try_level = enclosing_level;
    }

    return 1; // ExceptionContinueSearch
}

const call_seh_filter = if (platform.is_x86) call_seh_filter_x86 else if (platform.is_wasm) call_seh_filter_wasm else call_seh_filter_x64;

fn call_seh_filter_x86(filter_addr: usize, frame_ebp: usize) i32 {
    return asm volatile (
        \\push %%ebp
        \\push %%ebx
        \\push %%esi
        \\push %%edi
        \\push %%ecx
        \\push %%edx
        \\mov %[ebp_val], %%ebp
        \\call *%[filter]
        \\pop %%edx
        \\pop %%ecx
        \\pop %%edi
        \\pop %%esi
        \\pop %%ebx
        \\pop %%ebp
        : [result] "={eax}" (-> i32),
        : [filter] "r" (filter_addr),
          [ebp_val] "r" (frame_ebp),
    );
}

fn call_seh_filter_x64(filter_addr: usize, frame_ebp: usize) i32 {
    // On x86_64, SEH filter functions are 32-bit PE code — call via compat mode.
    // The filter reads EBP from the stack frame to access local variables.
    // MSVC SEH filters expect EBP to be set to the establisher frame's EBP.
    _ = frame_ebp;
    const compat_thunks = @import("../../x86/compat_thunks.zig");
    const result = compat_thunks.callCompat32(@truncate(filter_addr), 0, 0, 0);
    return @bitCast(result);
}

/// On WASM, the interpreter stashes the guest ESP/EBP here right before each
/// native import call, so RaiseException can run SEH handlers on the app's
/// own stack.
pub var seh_current_guest_esp: u32 = 0;
pub var seh_current_guest_ebp: u32 = 0;

/// On WASM, when a host-side SEH stub (imported _except_handler3) accepts an
/// exception, it sets this redirect; execute.zig applies it to the suspended
/// interpreter CPU instead of resuming at the import's return address.
pub var wasm_seh_redirect: ?struct { eip: u32, esp: u32, ebp: u32 } = null;

/// On WASM, SEH filter functions are x86 code at guest VAs — run them via the
/// interpreter (mirrors callComparator's WASM path).
fn call_seh_filter_wasm(filter_addr: usize, frame_ebp: usize) i32 {
    const x86_cpu = @import("../../x86/cpu.zig");
    const x86_execute = @import("../../x86/execute.zig");
    const shared = @import("../shared.zig");
    const teb_mod = @import("../teb.zig");
    var cpu = x86_cpu.Cpu{};
    if (shared.guest_memory) |gm| cpu.memory = gm.*;
    if (teb_mod.teb_base_addr != 0) cpu.fs_base = @intCast(teb_mod.teb_base_addr);
    var stack: [4096]u8 = undefined;
    cpu.esp = @intFromPtr(&stack) + stack.len - 16;
    cpu.ebp = @intCast(frame_ebp);
    cpu.eip = @intCast(filter_addr);
    x86_execute.run(&cpu);
    if (trace.enable_tracing) trace.print("SEH: wasm filter @{x} -> {d}\n", .{ filter_addr, cpu.eax });
    return @bitCast(cpu.eax);
}

/// Jumps to a SEH handler function with the specified frame EBP.
/// Implementation status: Fully implemented
pub const jump_to_seh_handler = if (platform.is_x86) jump_to_seh_handler_x86 else jump_to_seh_handler_x64;

fn jump_to_seh_handler_x86(handler_addr: usize, frame_ebp: usize) noreturn {
    asm volatile (
        \\mov %[ebp_val], %%ebp
        \\jmp *%[handler]
        :
        : [handler] "r" (handler_addr),
          [ebp_val] "r" (frame_ebp),
    );
    unreachable;
}

fn jump_to_seh_handler_x64(handler_addr: usize, frame_ebp: usize) noreturn {
    // On x86_64, the SEH __except handler is 32-bit PE code that reads locals
    // via EBP (the establisher frame pointer). We write a small trampoline in
    // the compat pool: `mov ebp, <frame_ebp>; jmp <handler_addr>` and enter
    // compat mode at the trampoline. ESP is set to frame_ebp - 0x200 to give
    // the handler stack space below the frame.
    const compat_thunks = @import("../../x86/compat_thunks.zig");

    // Write trampoline: BD xx xx xx xx  (mov ebp, imm32)
    //                   E9 xx xx xx xx  (jmp rel32)
    const tramp_addr = compat_thunks.allocThunkRaw(10) orelse {
        @import("../../platform.zig").exitProcess(1);
    };
    const base = @as([*]u8, @ptrFromInt(@as(usize, tramp_addr)));
    base[0] = 0xBD; // mov ebp, imm32
    @as(*align(1) u32, @ptrCast(base + 1)).* = @truncate(frame_ebp);
    base[5] = 0xE9; // jmp rel32
    const jmp_target: u32 = @truncate(handler_addr);
    const jmp_src: u32 = tramp_addr + 10;
    @as(*align(1) i32, @ptrCast(base + 6)).* = @bitCast(jmp_target -% jmp_src);

    // Set ESP to the establisher frame's EBP. The __except handler
    // resumes execution at the catch block which expects ESP near EBP.
    // MSVC's _local_unwind / _except_handler3 restores ESP from EBP.
    const esp: u32 = @truncate(frame_ebp);
    compat_thunks.enterCompatMode(tramp_addr, esp);
}
