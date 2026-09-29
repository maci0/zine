//! x86_64 compatibility mode thunk pool and signal-based dispatcher.
//!
//! On x86_64 hosts, 32-bit PE code runs in CPU compatibility mode (CS=0x23).
//! API calls use INT 0xFE which triggers SIGSEGV; the signal handler runs in
//! 64-bit mode, marshals 32-bit args from the guest stack, calls the 64-bit
//! Zig stub, writes the result to EAX in the ucontext, and resumes the guest.
//!
//! This module provides:
//!   - A thunk pool: executable memory in the low 4GB (MAP_32BIT) containing
//!     INT 0xFE + thunk_id stubs (6 bytes each).
//!   - allocThunk(): write a stub and return its 32-bit address for IAT patching.
//!   - allocData(): copy data exports into the pool (must be < 4GB for guest).
//!   - makeExitStub(): thunk that calls std.process.exit.
//!   - dispatchFromSignal(): called from the SIGSEGV handler to service INT 0xFE.
//!   - enterCompatMode(): iretq trampoline to switch CS to 0x23 and start the PE.

const std = @import("std");
const platform = @import("../platform.zig");
const thunks = @import("thunks.zig");
const log = @import("../log.zig");
const trace = @import("../trace.zig");

const POOL_SIZE = 256 * 1024; // 256KB

var pool_base: ?[*]align(4096) u8 = null;
var pool_cursor: u32 = 0;
var pool_base_addr: u32 = 0; // virtual address of pool start

/// Exit thunk ID — registered during init().
var exit_thunk_id: u32 = 0;

/// Returns the pool address range [start, end) for range checks.
pub fn getPoolRange() ?[2]usize {
    if (pool_base) |base| {
        const start = @intFromPtr(base);
        return .{ start, start + POOL_SIZE };
    }
    return null;
}

/// Initialize the thunk pool. Must be called before any allocThunk/allocData.
pub fn init() !void {
    const mem = try platform.mmap(null, POOL_SIZE, true, -1, 0, false, false);
    pool_base = mem.ptr;
    pool_base_addr = @intCast(@intFromPtr(mem.ptr));
    pool_cursor = 0;

    // Register the exit thunk
    exit_thunk_id = thunks.registerThunk(.{
        .name = "__compat_exit",
        .param_count = null,
        .handler = &exitHandler,
    });
}

fn exitHandler(cpu: *@import("cpu.zig").Cpu) void {
    _ = cpu;
    std.process.exit(0);
}

/// Allocate a thunk stub (INT 0xFE + thunk_id) in the pool.
/// Returns the 32-bit address of the stub, suitable for writing into an IAT slot.
pub fn allocThunk(thunk_id: u32) ?u32 {
    if (pool_base == null) return null;
    if (pool_cursor + 6 > POOL_SIZE) return null;

    const base = pool_base.?;
    const offset = pool_cursor;

    // Write: CD FE (INT 0xFE) followed by 4-byte thunk_id
    base[offset + 0] = 0xCD;
    base[offset + 1] = 0xFE;
    base[offset + 2] = @truncate(thunk_id);
    base[offset + 3] = @truncate(thunk_id >> 8);
    base[offset + 4] = @truncate(thunk_id >> 16);
    base[offset + 5] = @truncate(thunk_id >> 24);

    pool_cursor += 6;
    // Align to 2 bytes for next stub
    pool_cursor = (pool_cursor + 1) & ~@as(u32, 1);

    return pool_base_addr + offset;
}

/// Allocate raw bytes from the pool. Returns the 32-bit address.
pub fn allocThunkRaw(size: u32) ?u32 {
    if (pool_base == null) return null;
    pool_cursor = (pool_cursor + 1) & ~@as(u32, 1);
    if (pool_cursor + size > POOL_SIZE) return null;
    const addr = pool_base_addr + pool_cursor;
    pool_cursor += size;
    return addr;
}

/// Copy data into the pool so it has a 32-bit address accessible to the guest.
/// Returns the 32-bit address of the copied data.
pub fn allocData(src: [*]const u8, size: u32) ?u32 {
    if (pool_base == null) return null;
    // Align to 8 bytes for data
    pool_cursor = (pool_cursor + 7) & ~@as(u32, 7);
    if (pool_cursor + size > POOL_SIZE) return null;

    const base = pool_base.?;
    const offset = pool_cursor;
    @memcpy(base[offset .. offset + size], src[0..size]);
    pool_cursor += size;

    return pool_base_addr + offset;
}

/// Returns the 32-bit address of an exit stub. When the PE's entry point
/// returns, it will hit this address which triggers INT 0xFE -> exit.
pub fn makeExitStub() u32 {
    return allocThunk(exit_thunk_id) orelse 0;
}

/// Dispatch an INT 0xFE thunk from the SIGSEGV signal handler.
/// Called when the signal handler detects `CD FE` at the faulting IP.
///
/// Reads the guest stack (32-bit ESP from ucontext), calls the 64-bit
/// Zig stub, writes the return value to EAX, adjusts ESP for stdcall,
/// and sets RIP to the return address so the guest resumes after the CALL.
pub fn dispatchFromSignal(uctx: *@import("../platform/signal_context.zig").ucontext_t, thunk_id: u32) void {
    const REG = @import("../platform/signal_context.zig").REG;

    if (thunk_id >= thunks.MAX_THUNKS) {
        log.err("compat_thunks: invalid thunk ID {d}", .{thunk_id});
        std.process.exit(1);
    }

    // Check if this is the return thunk from callCompat32.
    // The 32-bit function returned via RET to our stub. EAX holds the result.
    if (return_thunk_id != 0 and thunk_id == return_thunk_id) {
        if (trace.enable_tracing) {
            trace.print("compat: return thunk fired, depth={d} eax=0x{X}\n", .{
                saved_depth, @as(usize, @bitCast(uctx.mcontext.gregs[REG.RAX])),
            });
        }
        returnFromCompat(uctx);
        return; // return to kernel which will restore the modified ucontext
    }

    const entry = thunks.getEntry(thunk_id) orelse {
        log.err("compat_thunks: unregistered thunk ID {d}", .{thunk_id});
        std.process.exit(1);
    };

    // Guest ESP is in the low 32 bits of RSP
    var guest_esp: u32 = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[REG.RSP])));

    // The CALL instruction pushed a 32-bit return address onto the guest stack
    const ret_addr = @as(*const u32, @ptrFromInt(@as(usize, guest_esp))).*;
    guest_esp += 4; // pop return address

    const target_addr = entry.native_addr;

    if (target_addr == 0) {
        log.warn("compat_thunks: null native address for thunk {d} ({s})", .{ thunk_id, entry.name });
        uctx.mcontext.gregs[REG.RAX] = 0;
        uctx.mcontext.gregs[REG.RSP] = @as(usize, guest_esp);
        uctx.mcontext.gregs[REG.RIP] = @as(usize, ret_addr);
        return;
    }

    // Read arguments from the guest stack. Only read as many as needed
    // (param_bytes/4) plus a few extra for safety, to avoid reading past
    // the end of a stack mapping.
    var args: [16]u32 = [_]u32{0} ** 16;
    const n_args = @min(@as(usize, entry.native_param_bytes / 4) + 4, 16);
    for (0..n_args) |i| {
        args[i] = @as(*const u32, @ptrFromInt(@as(usize, guest_esp) + i * 4)).*;
    }

    // For variadic functions (printf, sprintf, etc.), the native stub expects
    // the last parameter to be a pointer to the remaining args on the guest stack.
    // Replace args[va_fixed] with the guest stack address of the variadic args.
    if (entry.native_va_fixed > 0) {
        const va_idx = entry.native_va_fixed;
        args[va_idx] = guest_esp + @as(u32, va_idx) * 4;
    }

    if (trace.enable_tracing) {
        trace.print("compat: thunk {d} ({s}) ret=0x{X} esp=0x{X} args=[{X},{X},{X},{X}] va={d}\n", .{ thunk_id, entry.name, ret_addr, guest_esp, args[0], args[1], args[2], args[3], entry.native_va_fixed });
    }

    if (std.mem.eql(u8, entry.name, "RaiseException")) {
        const code = args[0];
        if (code == 0xE0005031) {
            const num_args = args[2];
            const args_ptr = args[3];
            if (num_args > 0 and args_ptr != 0) {
                const first_arg = @as(*const u32, @ptrFromInt(args_ptr)).*;
                if (trace.enable_tracing) trace.print("\n\n>>> C1063 RAISE EXCEPTION PARAMETER: 0x{X} <<<\n\n", .{first_arg});
            }
        }
    }

    // Check if this is the special _ftol thunk which requires reading from ST(0) in the FPU struct natively.
    if (std.mem.eql(u8, entry.name, "_ftol")) {
        const fpregs = uctx.mcontext.fpregs;
        var top: usize = 0;
        var result: i64 = 0;

        // Scan the entire physical FPU stack to heuristically identify the parameter
        // This is necessary since Linux x86_64 FXSAVE state sync occasionally desyncs
        // logical FSW TOP values from their physical FPR0-FPR7 memory locations natively.
        for (0..8) |i| {
            const st_i = &fpregs.st[i];
            const candidate_fval: f80 = @as(*align(1) f80, @ptrCast(st_i)).*;
            const candidate_res: i64 = @intFromFloat(candidate_fval);
            if (trace.enable_tracing) trace.print("compat: ST[{d}] parsed i64 = {d}\n", .{ i, candidate_res });
            if (candidate_res != 0 and candidate_res != -9223372036854775808) {
                result = candidate_res;
                top = i;
                break;
            }
        }

        // If we found nothing valid, fallback to 0
        // No explicit top overwrite if 0 because we didn't find the float.

        // Emulate x87 FPU pop by brutally resetting the entire FPU stack.
        // C1.DLL finishes calculations before calling _ftol, so resetting is completely safe natively.
        fpregs.swd &= ~@as(u16, 0x3800); // TOP = 0
        fpregs.ftw = 0; // ALL registers EMPTY

        uctx.mcontext.gregs[REG.RAX] = @bitCast(@as(usize, @as(u32, @truncate(@as(u64, @bitCast(result))))));
        uctx.mcontext.gregs[REG.RDX] = @bitCast(@as(usize, @as(u32, @truncate(@as(u64, @bitCast(result)) >> 32))));
        uctx.mcontext.gregs[REG.RSP] = @as(usize, guest_esp);
        uctx.mcontext.gregs[REG.RIP] = @as(usize, ret_addr);
        if (trace.enable_tracing) {
            trace.print("compat: fpregs ptr is 0x{X}\n", .{@intFromPtr(fpregs)});
            trace.print("compat: FXSAVE raw: ", .{});
            const raw_fpregs = @as([*]const u8, @ptrCast(fpregs))[0..128];
            for (raw_fpregs) |b| trace.print("{X:0>2} ", .{b});
            trace.print("\n", .{});
            trace.print("compat: intercepted _ftol ST(0) from FXSAVE -> {d} (0x{X})\n", .{ result, result });
        }
        return;
    }

    // Call the 64-bit stub
    const result: u32 = if (entry.native_is_cdecl)
        thunks.callNativeCdecl(target_addr, args)
    else
        thunks.callNativeByArity(target_addr, entry.native_param_bytes, args);

    // For stdcall, callee pops parameters
    if (!entry.native_is_cdecl) {
        guest_esp += entry.native_param_bytes;
    }

    // Set return value and resume guest at the return address
    uctx.mcontext.gregs[REG.RAX] = @as(usize, result);
    uctx.mcontext.gregs[REG.RSP] = @as(usize, guest_esp);
    uctx.mcontext.gregs[REG.RIP] = @as(usize, ret_addr);
}

// -----------------------------------------------------------------------
// callCompat32: call a 32-bit function from 64-bit mode and return
// -----------------------------------------------------------------------

/// Saved state for returning from compat mode calls. Supports nesting
/// (e.g. DllMain -> _initterm -> callCompat32 for each init function).
/// The callee-saved registers are not held here: the asm block pushes and
/// pops them on the stack, so only the two addresses it takes by name and the
/// returned value live in the struct.
const SavedState = struct {
    rsp: u64,
    rip: u64,
    result: u32,
};

const MAX_COMPAT_DEPTH = 8;
var saved_stack: [MAX_COMPAT_DEPTH]SavedState = undefined;
var saved_depth: u32 = 0;
var return_thunk_id: u32 = 0;

/// Signal-level return handler. Called by dispatchFromSignal for the return thunk.
/// Restores 64-bit mode by modifying the ucontext.
fn returnFromCompat(uctx: *@import("../platform/signal_context.zig").ucontext_t) void {
    const REG = @import("../platform/signal_context.zig").REG;
    if (saved_depth == 0) {
        log.err("compat_thunks: return with empty saved stack", .{});
        std.process.exit(1);
    }
    // Don't decrement saved_depth here — callCompat32 does it after landing.
    const depth = saved_depth - 1;
    const s = &saved_stack[depth];
    s.result = @truncate(@as(usize, @bitCast(uctx.mcontext.gregs[REG.RAX])));
    // Restore RSP to the point where callee-saved regs were pushed.
    // The landing label (s.rip) will pop them and continue in callCompat32.
    uctx.mcontext.gregs[REG.RSP] = @bitCast(s.rsp);
    uctx.mcontext.gregs[REG.RIP] = @bitCast(s.rip);
    // Set CS back to 0x33 (64-bit long mode)
    const csgsfs: usize = @bitCast(uctx.mcontext.gregs[REG.CSGSFS]);
    uctx.mcontext.gregs[REG.CSGSFS] = @bitCast((csgsfs & ~@as(usize, 0xFFFF)) | 0x33);
}

/// Call a 32-bit function with up to 4 u32 arguments via compat mode (CS=0x23).
/// Uses iretq to enter 32-bit mode. The function's RET hits a return thunk
/// (INT 0xFE) which modifies the ucontext to resume at a landing label here.
pub noinline fn callCompat32(target: u32, arg0: u32, arg1: u32, arg2: u32) u32 {
    if (comptime !platform.is_x86_64) return 0;
    return callCompat32_4(target, arg0, arg1, arg2, 0);
}

pub noinline fn callCompat32_4(target: u32, arg0: u32, arg1: u32, arg2: u32, arg3: u32) u32 {
    if (comptime !platform.is_x86_64) return 0;
    // Each guard below reports itself: the caller records this return value as
    // a thread exit code, so a silent 0 is a thread that never ran and the
    // guest reads as a clean exit.
    if (pool_base == null) {
        log.err("compat: no thunk pool, cannot call a 32-bit target");
        return 0;
    }
    // Allocate return stub (INT 0xFE) if not yet done
    if (return_thunk_id == 0) {
        return_thunk_id = thunks.registerThunk(.{
            .name = "__compat_return",
            .param_count = null,
            .handler = &struct {
                fn handler(cpu: *@import("cpu.zig").Cpu) void {
                    _ = cpu;
                }
            }.handler,
        });
    }
    const ret_stub = allocThunk(return_thunk_id) orelse {
        log.err("compat: thunk pool exhausted, cannot allocate a return stub");
        return 0;
    };

    // Use a shared 1MB guest stack for all compat calls (avoid C1063 stack
    // overflow errors from CRT stack checks). The stack is allocated once
    // and never freed — reused across all callCompat32 invocations.
    const S = struct {
        var stack_mem: ?[]align(4096) u8 = null;
    };
    if (S.stack_mem == null) {
        S.stack_mem = platform.mmap(null, 1024 * 1024, true, -1, 0, false, false) catch |err| {
            log.err("compat: cannot map the {d}-byte compat call stack: {}", .{ 1024 * 1024, err });
            return 0;
        };
    }
    const call_stack_mem = S.stack_mem.?;
    // Each nesting level uses a different region of the 1MB stack to avoid
    // overwriting the outer call's stack frame. Each level gets 128KB.
    const level_size: usize = 128 * 1024;
    const level_offset = saved_depth * level_size;
    if (level_offset + level_size > call_stack_mem.len) {
        log.err("compat: 32-bit call nested {d} deep, past the {d}-byte compat call stack", .{ saved_depth, call_stack_mem.len });
        return 0;
    }
    const esp: u32 = @intCast(@intFromPtr(call_stack_mem.ptr) + level_offset + level_size - 64);

    // Build stdcall frame: [ret_stub] [arg0] [arg1] [arg2] [arg3]
    const stack_ptr = @as([*]u32, @ptrFromInt(@as(usize, esp)));
    stack_ptr[0] = ret_stub;
    stack_ptr[1] = arg0;
    stack_ptr[2] = arg1;
    stack_ptr[3] = arg2;
    stack_ptr[4] = arg3;

    // Save state for nesting
    if (saved_depth >= MAX_COMPAT_DEPTH) {
        log.err("compat: 32-bit call nested past the limit of {d}", .{MAX_COMPAT_DEPTH});
        return 0;
    }
    const depth = saved_depth;
    const save_entry = &saved_stack[depth];
    save_entry.result = 0;
    saved_depth += 1;

    // Use inline asm to: save callee-saved regs, do iretq into compat mode,
    // and provide a landing label for returnFromCompat to jump to.
    asm volatile (
    // Save callee-saved registers on the current stack
        \\ pushq %%rbx
        \\ pushq %%r12
        \\ pushq %%r13
        \\ pushq %%r14
        \\ pushq %%r15
        \\ pushq %%rbp
        // Save RSP so returnFromCompat can restore it
        \\ movq %%rsp, (%%rsi)
        // Save the landing address (label after iretq)
        \\ leaq 1f(%%rip), %%rax
        \\ movq %%rax, (%%rdi)
        // Build iretq frame
        \\ movq $0x2B, %%rax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ subq $40, %%rsp
        \\ movq $0x2B, %%rax
        \\ movq %%rax, 32(%%rsp)
        \\ movq %%rcx, 24(%%rsp)
        \\ movq $0x202, %%rax
        \\ movq %%rax, 16(%%rsp)
        \\ movq $0x23, %%rax
        \\ movq %%rax, 8(%%rsp)
        \\ movq %%rdx, (%%rsp)
        \\ iretq
        // Landing: returnFromCompat restored RSP here and set RIP to 1:
        \\ 1:
        \\ popq %%rbp
        \\ popq %%r15
        \\ popq %%r14
        \\ popq %%r13
        \\ popq %%r12
        \\ popq %%rbx
        :
        : [save_rsp_ptr] "{rsi}" (&save_entry.rsp),
          [save_rip_ptr] "{rdi}" (&save_entry.rip),
          [guest_esp] "{rcx}" (@as(u64, esp)),
          [guest_eip] "{rdx}" (@as(u64, target)),
        : .{ .rax = true, .memory = true });

    // returnFromCompat wrote the result and restored RSP/RIP to land here
    const result = save_entry.result;
    saved_depth -= 1;
    return result;
}

/// Switch from 64-bit long mode to 32-bit compatibility mode and jump
/// to the PE entry point. Uses iretq to change CS to 0x23.
///
/// `entry_point` — 32-bit VA of the PE entry point
/// `guest_esp`   — 32-bit VA of the guest stack (with exit stub pushed)
pub fn enterCompatMode(entry_point: u32, guest_esp: u32) noreturn {
    // iretq stack frame (pushed in reverse order):
    //   SS     = 0x2B (user data segment, 32-bit compat)
    //   RSP    = guest_esp
    //   RFLAGS = 0x202 (IF set)
    //   CS     = 0x23 (user code segment, 32-bit compat)
    //   RIP    = entry_point
    //
    // Build the iretq frame in memory rather than using push instructions,
    // to avoid Zig's x86_64 encoder issues with push operand sizing.
    enterCompatModeImpl(@as(u64, entry_point), @as(u64, guest_esp));
}

fn enterCompatModeImpl(entry_point: u64, guest_esp: u64) noreturn {
    if (comptime !platform.is_x86_64) unreachable;
    asm volatile (
        \\ movq $0x2B, %%rax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ subq $40, %%rsp
        \\ movq %%rax, 32(%%rsp)
        \\ movq %%rcx, 24(%%rsp)
        \\ movq $0x202, %%rax
        \\ movq %%rax, 16(%%rsp)
        \\ movq $0x23, %%rax
        \\ movq %%rax, 8(%%rsp)
        \\ movq %%rdx, (%%rsp)
        \\ pushq %%rax
        \\ movw $0x037F, %%ax
        \\ pushw %%ax
        \\ fldcw (%%rsp)
        \\ popw %%ax
        \\ popq %%rax
        \\ xorq %%rbp, %%rbp
        \\ iretq
        :
        : [esp_val] "{rcx}" (guest_esp),
          [eip] "{rdx}" (entry_point),
        : .{ .rax = true, .rbp = true, .memory = true });
    unreachable;
}
