//! x86 instruction execution loop and dispatcher.
//!
//! This module implements the fetch-decode-execute interpreter loop with
//! several Blink-inspired optimizations:
//!
//! - **Decode cache**: A 1024-entry hash-indexed cache (`decode_cache.zig`)
//!   eliminates redundant instruction decoding in loops.
//! - **Branch fusion**: Short Jcc (0x70–0x7F) and near Jcc (0F 80–8F)
//!   instructions are executed inline after the preceding instruction,
//!   saving a full step() cycle for the common CMP/TEST + Jcc pattern.
//! - **Inline hot paths**: readOperand, writeOperand, computeEffectiveAddress
//!   and all register/memory accessors are marked inline.
//!
//! Execution flows through:
//!   1. Instruction fetching from guest memory
//!   2. Decode cache lookup (or decode + cache store on miss)
//!   3. Opcode dispatching to specific execution handlers
//!   4. Flag updates and PC advancement
//!   5. Branch fusion: peek at next instruction for Jcc

const std = @import("std");
const runtime = @import("../runtime.zig");
const cpu_mod = @import("cpu.zig");
const decoder = @import("decoder.zig");
const decode_cache = @import("decode_cache.zig");
const flags_mod = @import("flags.zig");
const thunks = @import("thunks.zig");
const fpu = @import("fpu.zig");
const trace = @import("../trace.zig");
const log = @import("../log.zig");
const profiler = @import("../profiler.zig");

const Cpu = cpu_mod.Cpu;
const Instruction = decoder.Instruction;
const OpKind = decoder.OpKind;
const OpSize = flags_mod.OpSize;
const FlagOp = flags_mod.FlagOp;
const Segment = cpu_mod.Segment;

// -----------------------------------------------------------------------
// Entry point
// -----------------------------------------------------------------------

/// Continually executes instructions in the provided CPU context until the `halted` flag is set.
pub fn run(cpu: *Cpu) void {
    while (!cpu.halted) {
        step(cpu);
    }
}

/// Executes a single x86 instruction at the current EIP.
/// This function handles:
///   1. Checking for native imports (thunks).
///   2. Decode cache lookup, falling back to full decode on miss.
///   3. Advancing EIP.
///   4. Dispatching to the appropriate execution handler via `executeInsn`.
pub fn step(cpu: *Cpu) void {
    const eip = cpu.eip;

    // Check if EIP points to a native Zig stub (resolved import).
    // Must check BEFORE readSlice because on x86-linux, native stubs
    // share the 32-bit address space and readSlice would succeed,
    // causing the interpreter to execute host machine code as guest instructions.
    if (thunks.isNativeImport(eip)) {
        dispatchNativeCall(cpu);
        return;
    }

    // On native x86 (32-bit): if EIP is in a loaded DLL (not the main exe,
    // not a thunk), execute natively via stack switching. DLL code may use
    // SSE/MMX/FPU instructions that the interpreter cannot handle.
    // On x86_64, this shortcut is disabled because the callDllNative asm is
    // x86-only, and compat thunk stubs in low 4GB must be interpreted.
    if (comptime @import("../platform.zig").is_x86) {
        if (cpu.memory.native_linear) {
            const is_main_exe = (eip >= runtime.app_code_start and eip < runtime.app_code_end);
            if (!is_main_exe and eip >= 0x10000 and eip < 0x70000000) {
                callDllNative(cpu);
                return;
            }
        }
    }

    const code = cpu.memory.readSlice(eip, 16) orelse {
        log.err("x86: EIP 0x{X} out of bounds", .{eip});
        cpu.halted = true;
        return;
    };

    const insn = cpu.decode_cache.lookup(eip, code) orelse blk: {
        const decoded = decoder.decode(code);
        if (decoded.length > 0) {
            cpu.decode_cache.store(eip, code, decoded);
        }
        break :blk decoded;
    };

    if (insn.length == 0) {
        log.err("x86: zero-length instruction at 0x{X} (byte 0x{X:0>2})", .{ eip, code[0] });
        cpu.halted = true;
        return;
    }

    // Advance EIP past the instruction before execution —
    // branch instructions will override this.
    cpu.eip = eip +% insn.length;

    if (trace.enable_instructions) {
        trace.print("x86: [EIP={X:0>8}] opcode={X:0>2} len={d} EAX={X}\n", .{ eip, insn.opcode, insn.length, cpu.eax });
    }

    profiler.tickEip(eip);
    profiler.tickOpcode(insn.opcode);

    executeInsn(cpu, &insn, eip);

    // --- Branch fusion: fuse compare/test + conditional jump ---
    // After executing an ALU/CMP/TEST instruction that sets flags, peek at
    // the next instruction. If it is a short Jcc (70-7F, 2 bytes) or a
    // near Jcc (0F 80-8F, 6 bytes), execute it inline to avoid a full
    // decode cycle. This is a software analogue of hardware macro-op fusion.
    const next_eip = cpu.eip;
    if (cpu.memory.readSlice(next_eip, 2)) |peek| {
        const next_byte = peek[0];
        // Short Jcc fusion (70-7F): 1-byte opcode + 1-byte rel8
        if (next_byte >= 0x70 and next_byte <= 0x7F) {
            const cc: u4 = @truncate(next_byte);
            cpu.eip = next_eip +% 2;
            const rel8: i32 = @as(i32, @as(i8, @bitCast(peek[1])));

            if (trace.enable_instructions) {
                trace.print("x86: [EIP={X:0>8}] fused short Jcc {X:0>2}\n", .{ next_eip, next_byte });
            }
            profiler.tickEip(next_eip);
            profiler.tickOpcode(@as(u16, next_byte));

            if (cpu.flags.evaluateCC(cc)) {
                cpu.eip = cpu.eip +% @as(u32, @bitCast(rel8));
            }
        }
        // Near Jcc fusion (0F 80-8F): 2-byte opcode + 4-byte rel32
        else if (next_byte == 0x0F) {
            const next2 = peek[1];
            if (next2 >= 0x80 and next2 <= 0x8F) {
                if (cpu.memory.readSlice(next_eip + 2, 4)) |rel_bytes| {
                    const cc: u4 = @truncate(next2);
                    cpu.eip = next_eip +% 6;
                    const b0: u32 = rel_bytes[0];
                    const b1: u32 = rel_bytes[1];
                    const b2: u32 = rel_bytes[2];
                    const b3: u32 = rel_bytes[3];
                    const rel32: u32 = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);

                    if (trace.enable_instructions) {
                        trace.print("x86: [EIP={X:0>8}] fused near Jcc 0F {X:0>2}\n", .{ next_eip, next2 });
                    }
                    profiler.tickEip(next_eip);
                    profiler.tickOpcode(0x0F00 | @as(u16, next2));

                    if (cpu.flags.evaluateCC(cc)) {
                        cpu.eip = cpu.eip +% rel32;
                    }
                }
            }
        }
    }
}

/// Execute DLL code natively by calling through a cdecl trampoline.
/// The trampoline switches to the guest stack, calls the DLL function,
/// and returns with the result.
fn callDllNative(cpu: *Cpu) void {
    const target = cpu.eip;
    const ret_addr = cpu.pop32();

    if (trace.enable_tracing) {
        trace.print("x86: callDllNative target=0x{X:0>8} ret=0x{X:0>8} ESP=0x{X:0>8}\n", .{ target, ret_addr, cpu.esp });
    }

    const result = callWithGuestStack(target, cpu.esp);
    cpu.eax = result.eax;
    cpu.esp = result.esp;
    cpu.eip = ret_addr;

    if (trace.enable_tracing) {
        trace.print("x86: callDllNative returned EAX=0x{X} ESP=0x{X:0>8}\n", .{ cpu.eax, cpu.esp });
    }
}

const NativeCallResult = struct { eax: u32, esp: u32 };

/// Noinline to ensure the compiler doesn't inline the asm into a complex function.
noinline fn callWithGuestStack(target: u32, guest_esp: u32) NativeCallResult {
    var result_eax: u32 = 0;
    var new_esp: u32 = 0;
    if (comptime @import("../platform.zig").is_x86) {
        asm volatile (
        // Save callee-saved regs on host stack
            \\pushl %%ebp
            \\pushl %%ebx
            \\pushl %%esi
            \\pushl %%edi
            // Save host ESP in ESI (callee-saved, will be restored after)
            \\movl %%esp, %%esi
            // Switch to guest stack and call DLL function
            \\movl %%eax, %%esp
            \\call *%%ecx
            // Save new guest ESP to memory (before restoring host stack)
            \\movl %%esp, %[out_esp]
            // Restore host stack
            \\movl %%esi, %%esp
            \\popl %%edi
            \\popl %%esi
            \\popl %%ebx
            \\popl %%ebp
            : [out_eax] "={eax}" (result_eax),
              [out_esp] "=m" (new_esp),
            : [in_esp] "{eax}" (guest_esp),
              [in_target] "{ecx}" (target),
            : .{ .memory = true, .cc = true });
    } else {
        _ = .{ target, guest_esp };
        // This path is never reached on non-x86 because callDllNative is guarded
        // by cpu.memory.native_linear, which is only true on x86.
    }
    return .{ .eax = result_eax, .esp = new_esp };
}

/// Handle the case where EIP points outside guest memory.
/// This happens when x86 code CALLs through the IAT — the IAT contains
/// native function pointers (Zig stubs compiled into the host binary).
///
/// The CALL instruction already pushed the return address onto the guest
/// stack.  We pop it, call the native function with up to 16 arguments
/// from the guest stack, and put the result in EAX.
fn dispatchNativeCall(cpu: *Cpu) void {
    const target_addr = cpu.eip;

    // Null function pointer — unresolved or data-address import
    if (target_addr == 0) {
        log.warn("x86: CALL to null function pointer", .{});
        cpu.eip = cpu.pop32();
        cpu.eax = 0;
        return;
    }

    // The return address was pushed by the CALL instruction
    const ret_addr = cpu.pop32();

    // Read up to 16 dword arguments from guest stack for the native call.
    // Stdcall/cdecl functions won't read more than they need.
    var args: [16]u32 = undefined;
    for (0..16) |i| {
        args[i] = cpu.memory.read32(cpu.esp +% @as(u32, @intCast(i * 4)));
    }
    // Check if this is a call to the not_implemented stub — decode the guest's
    // CALL instruction to identify which unresolved API is being called.
    // Must happen before the call because not_implemented exits the process.
    if (ret_addr >= 6) {
        var iat_slot: ?u32 = null;

        // Pattern 1: CALL dword ptr [IAT_slot] → FF 15 [addr32]
        if (cpu.memory.readSlice(ret_addr - 6, 6)) |bytes| {
            if (bytes[0] == 0xFF and bytes[1] == 0x15) {
                iat_slot = @as(*align(1) const u32, @ptrCast(bytes[2..6])).*;
            }
        }

        // Pattern 2: CALL rel32 (E8) → JMP [IAT_slot] (FF 25)
        // Common PE pattern: E8 calls a thunk that does FF 25 [IAT_slot]
        if (iat_slot == null and ret_addr >= 5) {
            if (cpu.memory.readSlice(ret_addr - 5, 5)) |bytes| {
                if (bytes[0] == 0xE8) {
                    const rel32 = @as(*align(1) const i32, @ptrCast(bytes[1..5])).*;
                    const thunk_addr = @as(u32, @bitCast(@as(i32, @bitCast(ret_addr)) +% rel32));
                    // Guard: only read if thunk_addr is in a plausible PE code range
                    // In native_linear mode, readSlice never returns null and would
                    // SIGSEGV on unmapped memory.
                    if (thunk_addr >= 0x10000 and thunk_addr < 0x70000000) {
                        if (cpu.memory.readSlice(thunk_addr, 6)) |thunk_bytes| {
                            if (thunk_bytes[0] == 0xFF and thunk_bytes[1] == 0x25) {
                                iat_slot = @as(*align(1) const u32, @ptrCast(thunk_bytes[2..6])).*;
                            }
                        }
                    }
                }
            }
        }

        if (iat_slot) |slot| {
            if (thunks.lookupUnresolvedName_bySlot(slot)) |name| {
                log.fatal("Unimplemented Win32 API: {s} (called from guest 0x{X})", .{ name, ret_addr });
            }
        }
    }

    // Special case: _EH_prolog is a naked function with non-standard calling
    // convention — it reads EAX (scope table), manipulates ESP/EBP/FS directly.
    // Can't dispatch through the generic native call mechanism.
    const msvcrt_except = @import("../win32/msvcrt/except.zig");
    if (target_addr == @intFromPtr(msvcrt_except.stub_EH_prolog)) {
        // Emulate what _EH_prolog does:
        //   push -1             ; try_level = -1
        //   push eax            ; scope table (passed by caller in eax)
        //   push fs:[0]         ; old SEH chain head
        //   mov fs:[0], esp     ; install new SEH frame
        //   mov eax, [esp+12]   ; original return address
        //   mov [esp+12], ebp   ; save caller's EBP
        //   lea ebp, [esp+12]   ; EBP = frame base
        //   push eax            ; push return address
        //   ret                 ; "return" to original caller
        // Net effect: 3 dwords pushed before ret_addr, EBP set to frame base.
        // The 'push eax; ret' at the end jumps back to ret_addr.
        cpu.push32(0xFFFFFFFF); // push -1
        cpu.push32(cpu.eax); // push scope table
        const old_seh = cpu.memory.read32(cpu.fs_base); // fs:[0]
        cpu.push32(old_seh);
        cpu.memory.write32(cpu.fs_base, cpu.esp); // mov fs:[0], esp
        // We already popped ret_addr above in dispatchNativeCall, then
        // pushed 3 values (-1, scope table, old SEH). [ESP+12] is the
        // slot where ret_addr was — now the caller's EBP save slot.
        cpu.memory.write32(cpu.esp +% 12, cpu.ebp);
        cpu.ebp = cpu.esp +% 12;
        cpu.eip = ret_addr;
        if (trace.enable_tracing) {
            trace.print("x86_execute: _EH_prolog emulated (scope_table=0x{X}, old_seh=0x{X}, ebp=0x{X})\n", .{ cpu.eax, old_seh, cpu.ebp });
        }
        return;
    }

    // Special case: _ftol reads from x87 FPU stack (ST0), but in interpreter
    // mode the FPU state is emulated — the real x87 stack is empty.
    const msvcrt_math = @import("../win32/msvcrt/math.zig");
    if (target_addr == @intFromPtr(msvcrt_math.ftol)) {
        const fval = cpu.fpu.pop();
        const ival = safeFloatToInt(i64, fval);
        const uval = @as(u64, @bitCast(ival));
        cpu.eax = @truncate(uval);
        cpu.edx = @truncate(uval >> 32);
        cpu.eip = ret_addr;
        if (trace.enable_tracing) {
            trace.print("x86_execute: _ftol(ST0={d}) -> EDX:EAX={X}:{X}\n", .{ fval, cpu.edx, cpu.eax });
        }
        // _ftol is cdecl (no cleanup)
        return;
    }

    // Call the native function through a generic function pointer.
    // Single lookup to get both calling convention and param count.
    const import_info = thunks.getImportInfo(target_addr);
    var result: u32 = 0;

    // Stash the guest ESP/EBP so RaiseException can run WASM SEH handlers on
    // the app's own stack.
    if (comptime @import("../platform.zig").is_wasm) {
        const except_mod = @import("../win32/msvcrt/except.zig");
        except_mod.seh_current_guest_esp = cpu.esp;
        except_mod.seh_current_guest_ebp = cpu.ebp;
    }

    if (import_info.is_cdecl) {
        result = thunks.callNativeCdecl(target_addr, args);
    } else {
        result = thunks.callNativeByArity(target_addr, import_info.param_bytes, args);
    }

    // On WASM, an SEH handler that accepted sets a redirect — apply it to this
    // CPU instead of resuming at the import's return address (the handler's
    // catch block continues the app from there).
    if (comptime @import("../platform.zig").is_wasm) {
        const except_mod = @import("../win32/msvcrt/except.zig");
        if (except_mod.wasm_seh_redirect) |rd| {
            except_mod.wasm_seh_redirect = null;
            cpu.eip = rd.eip;
            cpu.esp = rd.esp;
            cpu.ebp = rd.ebp;
            return;
        }
    }

    cpu.eax = result;
    cpu.eip = ret_addr;

    // Adjust guest ESP for stdcall cleanup — the PE code expects the
    // callee to have popped parameter bytes, but our cdecl call didn't.
    const cleanup = import_info.param_bytes;

    if (trace.enable_tracing) {
        // Try to identify the function name for unresolved imports.
        // The guest code before ret_addr may have FF 15 [IAT_slot].
        var func_name: ?[]const u8 = null;
        if (ret_addr >= 6) {
            const call_bytes = cpu.memory.readSlice(ret_addr - 6, 6);
            if (call_bytes) |bytes| {
                if (bytes[0] == 0xFF and bytes[1] == 0x15) {
                    const iat_slot = @as(*align(1) const u32, @ptrCast(bytes[2..6])).*;
                    func_name = thunks.lookupUnresolvedName_bySlot(iat_slot);
                }
            }
        }
        if (func_name) |name| {
            trace.print("x86_execute: Native call to {X:0>8} [{s}] (cleanup={d} is_cdecl={}) ret={X}\n", .{ target_addr, name, cleanup, import_info.is_cdecl, result });
        } else {
            trace.print("x86_execute: Native call to {X:0>8} (cleanup={d} is_cdecl={}) ret={X}\n", .{ target_addr, cleanup, import_info.is_cdecl, result });
        }
    }

    // For cdecl functions, the caller cleans up — the guest code will
    // do `add esp, N` itself. We should NOT adjust ESP here.
    // For stdcall, the callee cleans up — we must simulate that.
    if (!import_info.is_cdecl) {
        cpu.esp +%= cleanup;
    }

    // On WASM, check if _initterm enqueued any guest init functions.
    // If so, build an x86 trampoline in guest memory to execute them.
    if (comptime !@import("../platform.zig").is_native) {
        if (thunks.pending_initterm_count > 0) {
            buildInittermTrampoline(cpu);
        }
    }
}

/// Build an x86 trampoline in guest memory to execute pending _initterm callbacks.
/// Each callback is a CALL rel32 to a guest function address, followed by a final RET.
/// The current EIP (CRT return address) is pushed onto the guest stack so the
/// trampoline's RET returns control to the CRT startup code.
pub fn buildInittermTrampoline(cpu: *Cpu) void {
    const count = thunks.pending_initterm_count;
    if (count == 0) return;

    // Find a location in guest memory for the trampoline.
    // Use guestAlloc from the heap to get guest-addressable memory.
    const trampoline_size: u32 = @intCast(count * 5 + 1);
    const trampoline_va = cpu.memory.guestAlloc(trampoline_size);
    if (trampoline_va == 0) return;

    // Write the trampoline x86 code
    var offset: u32 = 0;
    for (0..count) |i| {
        const func_va = thunks.pending_initterm_callbacks[i];
        // CALL rel32 (E8 xx xx xx xx)
        // rel32 = target - (trampoline_va + offset + 5)
        const call_end: u32 = trampoline_va + offset + 5;
        const rel32: i32 = @as(i32, @bitCast(func_va)) -% @as(i32, @bitCast(call_end));
        cpu.memory.write8(trampoline_va + offset, 0xE8);
        cpu.memory.write32(trampoline_va + offset + 1, @bitCast(rel32));
        offset += 5;

        if (trace.enable_tracing) {
            trace.print("_initterm trampoline: CALL {x} (rel32={x}) at {x}\n", .{ func_va, @as(u32, @bitCast(rel32)), trampoline_va + offset - 5 });
        }
    }
    // Final RET (C3)
    cpu.memory.write8(trampoline_va + offset, 0xC3);

    // Clear pending callbacks
    thunks.pending_initterm_count = 0;

    // Push the current return address (where CRT code resumes)
    // and redirect EIP to the trampoline
    cpu.push32(cpu.eip);
    cpu.eip = trampoline_va;

    if (trace.enable_tracing) {
        trace.print("_initterm trampoline: {d} funcs at {x}, return to {x}\n", .{ count, trampoline_va, cpu.memory.read32(cpu.esp) });
    }
}

/// Executes an x87 FPU instruction.
/// This acts as a secondary dispatcher for opcodes D8 through DF, decoding the
/// ModRM byte to determine the specific FPU operation. It interacts with the
/// 8-register FPU stack and handles both register-to-register and memory-to-register operations.
fn executeFpu(cpu: anytype, insn: anytype) void {
    if (!insn.has_modrm) return;
    const reg: u8 = insn.modrm_reg;
    const mem_addr: ?u32 = if (insn.op0_kind == .mem) computeEffectiveAddress(cpu, insn) else null;
    const is_mem = (insn.op0_kind == .mem);

    switch (insn.opcode) {
        0xD8 => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    const fval: f64 = @floatCast(@as(f32, @bitCast(cpu.memory.read32(addr))));
                    fpuArithMemOp(cpu, reg, fval);
                }
            } else {
                const sti = cpu.fpu.st(insn.op0_reg);
                switch (reg) {
                    0 => cpu.fpu.setSt(0, cpu.fpu.st(0) + sti),
                    1 => cpu.fpu.setSt(0, cpu.fpu.st(0) * sti),
                    2, 3 => {
                        fpuCompare(cpu, cpu.fpu.st(0), sti);
                        if (reg == 3) _ = cpu.fpu.pop();
                    },
                    4 => cpu.fpu.setSt(0, cpu.fpu.st(0) - sti),
                    5 => cpu.fpu.setSt(0, sti - cpu.fpu.st(0)),
                    // Masked x87: division by zero yields +/-inf (ZE flag), not a skipped op.
                    6 => cpu.fpu.setSt(0, cpu.fpu.st(0) / sti),
                    7 => cpu.fpu.setSt(0, sti / cpu.fpu.st(0)),
                    else => {},
                }
            }
        },
        0xD9 => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    switch (reg) {
                        0 => cpu.fpu.push(@floatCast(@as(f32, @bitCast(cpu.memory.read32(addr))))), // FLD m32
                        2 => cpu.memory.write32(addr, @bitCast(@as(f32, @floatCast(cpu.fpu.st(0))))), // FST m32
                        3 => {
                            cpu.memory.write32(addr, @bitCast(@as(f32, @floatCast(cpu.fpu.st(0)))));
                            _ = cpu.fpu.pop();
                        }, // FSTP
                        5 => cpu.fpu.control_word = cpu.memory.read16(addr), // FLDCW
                        7 => cpu.memory.write16(addr, cpu.fpu.control_word), // FNSTCW
                        else => {},
                    }
                }
            } else {
                const rm3: u3 = insn.op0_reg;
                switch (reg) {
                    0 => cpu.fpu.push(cpu.fpu.st(rm3)), // FLD ST(i)
                    1 => {
                        const t = cpu.fpu.st(0);
                        cpu.fpu.setSt(0, cpu.fpu.st(rm3));
                        cpu.fpu.setSt(rm3, t);
                    }, // FXCH
                    4 => switch (insn.op0_reg) {
                        0 => cpu.fpu.setSt(0, -cpu.fpu.st(0)),
                        1 => cpu.fpu.setSt(0, @abs(cpu.fpu.st(0))),
                        else => {},
                    }, // FCHS/FABS
                    5 => switch (insn.op0_reg) {
                        6 => cpu.fpu.push(0.0),
                        0 => cpu.fpu.push(1.0),
                        else => {},
                    }, // FLDZ/FLD1
                    else => {},
                }
            }
        },
        0xDA => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    const ival: f64 = @floatFromInt(@as(i32, @bitCast(cpu.memory.read32(addr))));
                    switch (reg) {
                        0 => cpu.fpu.setSt(0, cpu.fpu.st(0) + ival),
                        1 => cpu.fpu.setSt(0, cpu.fpu.st(0) * ival),
                        2, 3 => {
                            fpuCompare(cpu, cpu.fpu.st(0), ival);
                            if (reg == 3) _ = cpu.fpu.pop();
                        },
                        4 => cpu.fpu.setSt(0, cpu.fpu.st(0) - ival),
                        5 => cpu.fpu.setSt(0, ival - cpu.fpu.st(0)),
                        // Masked x87: division by zero yields +/-inf (ZE flag), not a skipped op.
                        6 => cpu.fpu.setSt(0, cpu.fpu.st(0) / ival),
                        7 => cpu.fpu.setSt(0, ival / cpu.fpu.st(0)),
                        else => {},
                    }
                }
            }
        },
        0xDB => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    switch (reg) {
                        0 => cpu.fpu.push(@floatFromInt(@as(i32, @bitCast(cpu.memory.read32(addr))))), // FILD m32
                        2 => cpu.memory.write32(addr, @bitCast(fistToInt(i32, cpu.fpu.control_word, cpu.fpu.st(0)))), // FIST m32
                        3 => {
                            cpu.memory.write32(addr, @bitCast(fistToInt(i32, cpu.fpu.control_word, cpu.fpu.st(0))));
                            _ = cpu.fpu.pop();
                        }, // FISTP
                        5 => { // FLD m80 (approx as f64)
                            const lo = cpu.memory.read32(addr);
                            const hi = cpu.memory.read32(addr +% 4);
                            cpu.fpu.push(@bitCast(@as(u64, hi) << 32 | lo));
                        },
                        7 => { // FSTP m80
                            const bits: u64 = @bitCast(cpu.fpu.st(0));
                            cpu.memory.write32(addr, @truncate(bits));
                            cpu.memory.write32(addr +% 4, @truncate(bits >> 32));
                            cpu.memory.write16(addr +% 8, 0);
                            _ = cpu.fpu.pop();
                        },
                        else => {},
                    }
                }
            } else {
                if (reg == 4 and insn.op0_reg == 3) cpu.fpu.init(); // FNINIT (DB E3)
            }
        },
        0xDC => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    const lo = cpu.memory.read32(addr);
                    const hi = cpu.memory.read32(addr +% 4);
                    const fval: f64 = @bitCast(@as(u64, hi) << 32 | lo);
                    fpuArithMemOp(cpu, reg, fval);
                }
            } else {
                const i: u3 = insn.op0_reg;
                switch (reg) {
                    0 => cpu.fpu.setSt(i, cpu.fpu.st(i) + cpu.fpu.st(0)),
                    1 => cpu.fpu.setSt(i, cpu.fpu.st(i) * cpu.fpu.st(0)),
                    4 => cpu.fpu.setSt(i, cpu.fpu.st(i) - cpu.fpu.st(0)),
                    5 => cpu.fpu.setSt(i, cpu.fpu.st(0) - cpu.fpu.st(i)),
                    // Masked x87: division by zero yields +/-inf (ZE flag), not a skipped op.
                    6 => cpu.fpu.setSt(i, cpu.fpu.st(i) / cpu.fpu.st(0)),
                    7 => cpu.fpu.setSt(i, cpu.fpu.st(0) / cpu.fpu.st(i)),
                    else => {},
                }
            }
        },
        0xDD => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    switch (reg) {
                        0 => {
                            const lo = cpu.memory.read32(addr);
                            const hi = cpu.memory.read32(addr +% 4);
                            cpu.fpu.push(@bitCast(@as(u64, hi) << 32 | lo));
                        }, // FLD m64
                        2 => {
                            const b: u64 = @bitCast(cpu.fpu.st(0));
                            cpu.memory.write32(addr, @truncate(b));
                            cpu.memory.write32(addr +% 4, @truncate(b >> 32));
                        }, // FST
                        3 => {
                            const b: u64 = @bitCast(cpu.fpu.st(0));
                            cpu.memory.write32(addr, @truncate(b));
                            cpu.memory.write32(addr +% 4, @truncate(b >> 32));
                            _ = cpu.fpu.pop();
                        }, // FSTP
                        7 => cpu.memory.write16(addr, cpu.fpu.getStatusWord()), // FNSTSW [mem]
                        else => {},
                    }
                }
            } else {
                const i: u3 = insn.op0_reg;
                switch (reg) {
                    0 => cpu.fpu.setSt(i, 0), // FFREE
                    2 => cpu.fpu.setSt(i, cpu.fpu.st(0)), // FST ST(i)
                    3 => {
                        cpu.fpu.setSt(i, cpu.fpu.st(0));
                        _ = cpu.fpu.pop();
                    }, // FSTP ST(i)
                    else => {},
                }
            }
        },
        0xDE => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    const ival: f64 = @floatFromInt(@as(i16, @bitCast(cpu.memory.read16(addr))));
                    switch (reg) {
                        0 => cpu.fpu.setSt(0, cpu.fpu.st(0) + ival),
                        1 => cpu.fpu.setSt(0, cpu.fpu.st(0) * ival),
                        4 => cpu.fpu.setSt(0, cpu.fpu.st(0) - ival),
                        5 => cpu.fpu.setSt(0, ival - cpu.fpu.st(0)),
                        // Masked x87: division by zero yields +/-inf (ZE flag), not a skipped op.
                        6 => cpu.fpu.setSt(0, cpu.fpu.st(0) / ival),
                        7 => cpu.fpu.setSt(0, ival / cpu.fpu.st(0)),
                        else => {},
                    }
                }
            } else {
                const i: u3 = insn.op0_reg;
                switch (reg) {
                    0 => {
                        cpu.fpu.setSt(i, cpu.fpu.st(i) + cpu.fpu.st(0));
                        _ = cpu.fpu.pop();
                    },
                    1 => {
                        cpu.fpu.setSt(i, cpu.fpu.st(i) * cpu.fpu.st(0));
                        _ = cpu.fpu.pop();
                    },
                    4 => {
                        // DE /4 = FSUBRP ST(i), ST(0): ST(i) <- ST(0) - ST(i)
                        cpu.fpu.setSt(i, cpu.fpu.st(0) - cpu.fpu.st(i));
                        _ = cpu.fpu.pop();
                    },
                    5 => {
                        // DE /5 = FSUBP ST(i), ST(0): ST(i) <- ST(i) - ST(0)
                        cpu.fpu.setSt(i, cpu.fpu.st(i) - cpu.fpu.st(0));
                        _ = cpu.fpu.pop();
                    },
                    6 => {
                        // DE /6 = FDIVRP ST(i), ST(0): ST(i) <- ST(0) / ST(i)
                        cpu.fpu.setSt(i, cpu.fpu.st(0) / cpu.fpu.st(i));
                        _ = cpu.fpu.pop();
                    },
                    7 => {
                        // DE /7 = FDIVP ST(i), ST(0): ST(i) <- ST(i) / ST(0)
                        cpu.fpu.setSt(i, cpu.fpu.st(i) / cpu.fpu.st(0));
                        _ = cpu.fpu.pop();
                    },
                    else => {},
                }
            }
        },
        0xDF => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    switch (reg) {
                        0 => cpu.fpu.push(@floatFromInt(@as(i16, @bitCast(cpu.memory.read16(addr))))), // FILD m16
                        2 => cpu.memory.write16(addr, @bitCast(fistToInt(i16, cpu.fpu.control_word, cpu.fpu.st(0)))), // FIST m16
                        3 => {
                            cpu.memory.write16(addr, @bitCast(fistToInt(i16, cpu.fpu.control_word, cpu.fpu.st(0))));
                            _ = cpu.fpu.pop();
                        }, // FISTP
                        5 => { // FILD m64
                            const lo = cpu.memory.read32(addr);
                            const hi = cpu.memory.read32(addr +% 4);
                            cpu.fpu.push(@floatFromInt(@as(i64, @bitCast(@as(u64, hi) << 32 | lo))));
                        },
                        7 => { // FISTP m64
                            const bits: u64 = @bitCast(fistToInt(i64, cpu.fpu.control_word, cpu.fpu.st(0)));
                            cpu.memory.write32(addr, @truncate(bits));
                            cpu.memory.write32(addr +% 4, @truncate(bits >> 32));
                            _ = cpu.fpu.pop();
                        },
                        else => {},
                    }
                }
            } else {
                if (reg == 4 and insn.op0_reg == 0) { // FNSTSW AX (DF E0)
                    cpu.eax = (cpu.eax & 0xFFFF0000) | cpu.fpu.getStatusWord();
                }
            }
        },
        else => {},
    }
}

/// Safe float-to-int conversion with masked-x87 semantics: truncate toward
/// zero; NaN and out-of-range inputs produce the integer indefinite value
/// (most-negative), matching real FISTP/_ftol instead of saturating.
pub fn safeFloatToInt(comptime T: type, val: f64) T {
    comptime std.debug.assert(@typeInfo(T).int.signedness == .signed);
    if (!std.math.isFinite(val)) return std.math.minInt(T);
    const t = @trunc(val);
    const min_f: f64 = @floatFromInt(std.math.minInt(T));
    // Exact power-of-two upper bound above maxInt avoids f64 rounding
    // ambiguity near maxInt for wide types.
    const max_excl: f64 = @floatFromInt(@as(u64, 1) << (@bitSizeOf(T) - 1));
    if (t < min_f or t >= max_excl) return std.math.minInt(T);
    return @intFromFloat(t);
}

/// FIST/FISTP conversion: honors the rounding-control field, then applies
/// the same NaN/out-of-range integer-indefinite rule as real hardware.
pub fn fistToInt(comptime T: type, control_word: u16, val: f64) T {
    const rc: u2 = @truncate(control_word >> 10);
    return safeFloatToInt(T, fpu.roundPerRc(rc, val));
}

/// Helper: set x87 condition codes for comparison (C3,C0).
fn fpuCompare(cpu: anytype, a: f64, b: f64) void {
    cpu.fpu.status_word &= 0xB8FF; // clear C3,C2,C0
    if (a != a or b != b) {
        // NaN: set C3, C2, C0 (unordered)
        cpu.fpu.status_word |= 0x4500;
    } else if (a < b) {
        cpu.fpu.status_word |= 0x0100; // C0
    } else if (a == b) {
        cpu.fpu.status_word |= 0x4000; // C3
    }
    // else: a > b — all clear
}

/// FADD/FSUB/FMUL/FDIV memory forms (opcodes D8/DC): apply `op` to ST(0)
/// according to the instruction's reg field.
fn fpuArithMemOp(cpu: anytype, reg: u8, op: f64) void {
    switch (reg) {
        0 => cpu.fpu.setSt(0, cpu.fpu.st(0) + op),
        1 => cpu.fpu.setSt(0, cpu.fpu.st(0) * op),
        2, 3 => {
            fpuCompare(cpu, cpu.fpu.st(0), op);
            if (reg == 3) _ = cpu.fpu.pop();
        },
        4 => cpu.fpu.setSt(0, cpu.fpu.st(0) - op),
        5 => cpu.fpu.setSt(0, op - cpu.fpu.st(0)),
        // Masked x87: division by zero yields +/-inf (ZE flag), not a skipped op.
        6 => cpu.fpu.setSt(0, cpu.fpu.st(0) / op),
        7 => cpu.fpu.setSt(0, op / cpu.fpu.st(0)),
        else => {},
    }
}

/// Apply a relative jump to EIP from the instruction's rel operand.
inline fn applyRel(cpu: *Cpu, insn: *const Instruction) void {
    if (insn.op0_kind == .rel) {
        cpu.eip = cpu.eip +% insn.imm;
    }
}

/// Dispatch and execute a single decoded instruction.
fn executeInsn(cpu: *Cpu, insn: *const Instruction, eip: u32) void {
    switch (insn.opcode) {
        // NOP
        0x90 => {},

        0xF4 => cpu.halted = true,

        0xCC => {},

        0xCD => {
            if (insn.imm == 0xFE) {
                // Thunk trap — dispatch to Win32 stub
                thunks.dispatch(cpu);
            } else {
                log.warn("x86: INT 0x{X} at 0x{X}, eax={X} ebx={X} ecx={X} edx={X} esi={X} edi={X} ebp={X} esp={X}", .{ insn.imm, eip, cpu.eax, cpu.ebx, cpu.ecx, cpu.edx, cpu.esi, cpu.edi, cpu.ebp, cpu.esp });
            }
        },

        // --- MOV reg, imm (B0-B7 byte, B8-BF dword) ---
        0xB0...0xB7 => {
            const reg: u3 = @truncate(insn.opcode);
            cpu.setReg8(reg, @truncate(insn.imm));
        },
        0xB8...0xBF => {
            const reg: u3 = @truncate(insn.opcode);
            if (insn.op_size == .word) {
                cpu.setReg16(reg, @truncate(insn.imm));
            } else {
                cpu.setReg(@enumFromInt(reg), insn.imm);
            }
        },

        // --- PUSH reg (50-57) ---
        0x50...0x57 => {
            const reg: u3 = @truncate(insn.opcode);
            if (insn.op_size == .word) {
                cpu.push16(cpu.getReg16(reg));
            } else {
                cpu.push32(cpu.getReg(@enumFromInt(reg)));
            }
        },
        // --- POP reg (58-5F) ---
        0x58...0x5F => {
            const reg: u3 = @truncate(insn.opcode);
            if (insn.op_size == .word) {
                cpu.setReg16(reg, cpu.pop16());
            } else {
                cpu.setReg(@enumFromInt(reg), cpu.pop32());
            }
        },

        // POP r/m32 (0x8F /0) — e.g. POP DWORD PTR FS:[0] for SEH epilogue
        0x8F => {
            const val = cpu.pop32();
            writeOperand(cpu, insn, 0, val);
        },

        // PUSH imm32/16 (0x68) and PUSH imm8 sign-extended (0x6A)
        0x68 => {
            if (insn.op_size == .word) {
                cpu.push16(@truncate(insn.imm));
            } else {
                cpu.push32(insn.imm);
            }
        },
        0x6A => cpu.push32(insn.imm),

        // --- ALU r/m, reg (direction bit 1 = reg is dest) ---
        // ADD (00-05), OR (08-0D), ADC (10-15), SBB (18-1D),
        // AND (20-25), SUB (28-2D), XOR (30-35), CMP (38-3D)
        0x00...0x05,
        0x08...0x0D,
        0x10...0x15,
        0x18...0x1D,
        0x20...0x25,
        0x28...0x2D,
        0x30...0x35,
        0x38...0x3D,
        => {
            execAlu(cpu, insn);
        },

        // --- INC reg (40-47) ---
        0x40...0x47 => {
            const reg: cpu_mod.RegIndex = @enumFromInt(@as(u3, @truncate(insn.opcode)));
            const val = cpu.getReg(reg);
            const result = val +% 1;
            cpu.setReg(reg, result);
            cpu.flags.update(.inc, .dword, result, val, 1);
        },
        // --- DEC reg (48-4F) ---
        0x48...0x4F => {
            const reg: cpu_mod.RegIndex = @enumFromInt(@as(u3, @truncate(insn.opcode)));
            const val = cpu.getReg(reg);
            const result = val -% 1;
            cpu.setReg(reg, result);
            cpu.flags.update(.dec, .dword, result, val, 1);
        },

        // --- Group 1: ALU r/m, imm (80, 81, 83) ---
        0x80, 0x81, 0x83 => {
            execGroup1(cpu, insn);
        },

        // TEST r/m, reg (84=8bit, 85=32bit)
        0x84, 0x85 => {
            const a = readOperand(cpu, insn, 0);
            const b = readOperand(cpu, insn, 1);
            const result = a & b;
            cpu.flags.update(.logic, insn.op_size, result, a, b);
        },

        // XCHG r/m, reg (86=8bit, 87=32bit)
        0x86 => {
            const a = readOperand(cpu, insn, 0);
            const b = readOperand(cpu, insn, 1);
            writeOperand8(cpu, insn, 0, @truncate(b));
            writeOperand8(cpu, insn, 1, @truncate(a));
        },
        0x87 => {
            const a = readOperand(cpu, insn, 0);
            const b = readOperand(cpu, insn, 1);
            writeOperand(cpu, insn, 0, b);
            writeOperand(cpu, insn, 1, a);
        },

        // --- MOV r/m, reg and reg, r/m (88-8B) ---
        // Decoder resolves operand direction; executor always writes operand 0.
        0x88, 0x8A => writeOperand8(cpu, insn, 0, @truncate(readOperand(cpu, insn, 1))),
        0x89, 0x8B => writeOperand(cpu, insn, 0, readOperand(cpu, insn, 1)),

        // MOV r/m16, Sreg (8C)
        0x8C => {
            if (insn.has_modrm) {
                const sreg_val: u32 = switch (@as(Segment, @enumFromInt(insn.modrm_reg))) {
                    .es => cpu.es,
                    .cs => cpu.cs,
                    .ss => cpu.ss,
                    .ds => cpu.ds,
                    .fs => cpu.fs,
                    .gs => cpu.gs,
                };
                writeOperand(cpu, insn, 0, sreg_val);
            }
        },

        // LEA reg, [mem]
        0x8D => {
            if (insn.op1_kind == .mem) {
                const addr = computeEffectiveAddress(cpu, insn);
                if (insn.op_size == .word) {
                    cpu.setReg16(insn.modrm_reg, @truncate(addr));
                } else {
                    cpu.setReg(@enumFromInt(insn.modrm_reg), addr);
                }
            }
        },

        // MOV Sreg, r/m16 (8E)
        0x8E => {
            if (insn.has_modrm) {
                const val: u16 = @truncate(readOperand(cpu, insn, 1));
                switch (@as(Segment, @enumFromInt(insn.modrm_reg))) {
                    .es => cpu.es = val,
                    .cs => cpu.cs = val,
                    .ss => cpu.ss = val,
                    .ds => cpu.ds = val,
                    .fs => cpu.fs = val,
                    .gs => cpu.gs = val,
                }
            }
        },

        // XCHG EAX, reg (91-97)
        0x91...0x97 => {
            const reg: cpu_mod.RegIndex = @enumFromInt(@as(u3, @truncate(insn.opcode)));
            const tmp = cpu.eax;
            cpu.eax = cpu.getReg(reg);
            cpu.setReg(reg, tmp);
        },

        // CBW/CWDE (98)
        0x98 => {
            if (insn.op_size == .word) {
                // CBW: sign-extend AL into AX
                cpu.setReg16(0, cpu_mod.signExtend8to16(cpu.getReg8(0)));
            } else {
                // CWDE: sign-extend AX into EAX
                cpu.eax = cpu_mod.signExtend16to32(@truncate(cpu.eax));
            }
        },
        // CDQ (99)
        0x99 => {
            if (insn.op_size == .word) {
                // CWD: sign-extend AX into DX:AX
                cpu.edx = if ((cpu.eax & 0x8000) != 0) 0xFFFF else 0;
            } else {
                // CDQ: sign-extend EAX into EDX:EAX
                cpu.edx = if ((cpu.eax & 0x80000000) != 0) 0xFFFFFFFF else 0;
            }
        },

        // PUSHFD (9C)
        0x9C => cpu.push32(cpu.flags.toEflags()),
        // POPFD (9D)
        0x9D => cpu.flags.fromEflags(cpu.pop32()),

        // SAHF (9E) — loads SF, ZF, AF, PF, CF from AH
        0x9E => {
            var ef = cpu.flags.toEflags();
            const ah: u32 = cpu.getReg8(4); // AH
            ef = (ef & 0xFFFFFF00) | (ah & 0xD5) | 0x02;
            cpu.flags.fromEflags(ef);
        },
        // LAHF (9F) — loads AH from flags
        0x9F => cpu.setReg8(4, @truncate(cpu.flags.toEflags())),

        // MOV AL/EAX, moffs (A0-A1) and moffs, AL/EAX (A2-A3)
        0xA0 => {
            const addr = readMemAddr(cpu, insn, 0);
            cpu.setReg8(0, cpu.memory.read8(addr));
        },
        0xA1 => {
            const addr = readMemAddr(cpu, insn, 0);
            if (insn.op_size == .word) {
                cpu.setReg16(0, cpu.memory.read16(addr));
            } else {
                cpu.eax = cpu.memory.read32(addr);
            }
        },
        0xA2 => {
            const addr = readMemAddr(cpu, insn, 1);
            cpu.memory.write8(addr, cpu.getReg8(0));
        },
        0xA3 => {
            const addr = readMemAddr(cpu, insn, 1);
            if (insn.op_size == .word) {
                cpu.memory.write16(addr, cpu.getReg16(0));
            } else {
                cpu.memory.write32(addr, cpu.eax);
            }
        },

        // TEST AL, imm8 (A8) / TEST EAX, imm32 (A9)
        0xA8 => {
            const result = cpu.getReg8(0) & @as(u8, @truncate(insn.imm));
            cpu.flags.update(.logic, .byte, result, 0, 0);
        },
        0xA9 => {
            const result = cpu.eax & insn.imm;
            cpu.flags.update(.logic, insn.op_size, result, 0, 0);
        },

        // String ops (A4-AF) — basic single-step implementation
        0xA4 => execMovsb(cpu, insn),
        0xA5 => execMovsd(cpu, insn),
        0xAA => execStosb(cpu, insn),
        0xAB => execStosd(cpu, insn),
        0xAC => { // LODSB
            cpu.setReg8(0, cpu.memory.read8(cpu.esi));
            if (cpu.flags.getDF()) cpu.esi -%= 1 else cpu.esi +%= 1;
        },
        0xAD => { // LODSD
            cpu.eax = cpu.memory.read32(cpu.esi);
            if (cpu.flags.getDF()) cpu.esi -%= 4 else cpu.esi +%= 4;
        },
        0xA6, 0xA7 => { // CMPSB/CMPSD
            const sz: u32 = if (insn.opcode == 0xA6) 1 else 4;
            const os: OpSize = if (sz == 1) .byte else .dword;
            const df = cpu.flags.getDF();
            if (insn.rep or insn.repne) {
                // REPZ CMPS: loop while ECX > 0 AND ZF=1 (bytes equal)
                // REPNZ CMPS: loop while ECX > 0 AND ZF=0 (bytes not equal)
                const stop_on_zf = insn.repne; // REPNZ stops when ZF=1
                while (cpu.ecx > 0) {
                    const a = if (sz == 1) @as(u32, cpu.memory.read8(cpu.esi)) else cpu.memory.read32(cpu.esi);
                    const b = if (sz == 1) @as(u32, cpu.memory.read8(cpu.edi)) else cpu.memory.read32(cpu.edi);
                    cpu.flags.update(.sub, os, a -% b, a, b);
                    cpu.ecx -= 1;
                    if (df) {
                        cpu.esi -%= sz;
                        cpu.edi -%= sz;
                    } else {
                        cpu.esi +%= sz;
                        cpu.edi +%= sz;
                    }
                    const zf = cpu.flags.getZF();
                    if (stop_on_zf and zf) break; // REPNZ: stop when equal
                    if (!stop_on_zf and !zf) break; // REPZ: stop when not equal
                }
            } else {
                const a = if (sz == 1) @as(u32, cpu.memory.read8(cpu.esi)) else cpu.memory.read32(cpu.esi);
                const b = if (sz == 1) @as(u32, cpu.memory.read8(cpu.edi)) else cpu.memory.read32(cpu.edi);
                cpu.flags.update(.sub, os, a -% b, a, b);
                if (df) {
                    cpu.esi -%= sz;
                    cpu.edi -%= sz;
                } else {
                    cpu.esi +%= sz;
                    cpu.edi +%= sz;
                }
            }
        },
        0xAE, 0xAF => { // SCASB / SCASD
            const sz: u32 = if (insn.opcode == 0xAE) 1 else 4;
            const os: OpSize = if (sz == 1) .byte else .dword;
            const df = cpu.flags.getDF();
            if (insn.rep or insn.repne) {
                // REPNZ SCAS: scan until AL/EAX matches [EDI] or ECX=0
                // REPZ SCAS: scan until AL/EAX differs from [EDI] or ECX=0
                const stop_on_zf = insn.repne; // REPNZ stops when ZF=1
                while (cpu.ecx > 0) {
                    const a = if (sz == 1) @as(u32, cpu.getReg8(0)) else cpu.eax;
                    const b = if (sz == 1) @as(u32, cpu.memory.read8(cpu.edi)) else cpu.memory.read32(cpu.edi);
                    cpu.flags.update(.sub, os, a -% b, a, b);
                    cpu.ecx -= 1;
                    if (df) cpu.edi -%= sz else cpu.edi +%= sz;
                    const zf = cpu.flags.getZF();
                    if (stop_on_zf and zf) break; // REPNZ: found match
                    if (!stop_on_zf and !zf) break; // REPZ: found mismatch
                }
            } else {
                const a = if (sz == 1) @as(u32, cpu.getReg8(0)) else cpu.eax;
                const b = if (sz == 1) @as(u32, cpu.memory.read8(cpu.edi)) else cpu.memory.read32(cpu.edi);
                cpu.flags.update(.sub, os, a -% b, a, b);
                if (df) cpu.edi -%= sz else cpu.edi +%= sz;
            }
        },

        // RET (C3)
        0xC3 => cpu.eip = cpu.pop32(),
        // RET imm16 (C2)
        0xC2 => {
            cpu.eip = cpu.pop32();
            cpu.esp +%= insn.imm;
        },

        // MOV r/m8, imm8 (C6 /0)
        0xC6 => writeOperandSized(cpu, insn, 0, insn.imm, .byte),
        // MOV r/m32, imm32 (C7 /0)
        0xC7 => writeOperandSized(cpu, insn, 0, insn.imm, insn.op_size),

        // LEAVE (C9)
        0xC9 => {
            cpu.esp = cpu.ebp;
            cpu.ebp = cpu.pop32();
        },

        // Shift/Rotate Group 2 (C0,C1,D0-D3)
        0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3 => execShift(cpu, insn),

        // CALL rel32 (E8)
        0xE8 => {
            cpu.push32(cpu.eip);
            applyRel(cpu, insn);
        },

        // JMP rel32 (E9) / JMP rel8 (EB)
        0xE9, 0xEB => applyRel(cpu, insn),

        // Jcc short (70-7F)
        0x70...0x7F => {
            const cc: u4 = @truncate(insn.opcode);
            if (cpu.flags.evaluateCC(cc)) applyRel(cpu, insn);
        },

        // LOOP/LOOPcc/JECXZ (E0-E3)
        0xE0 => { // LOOPNE
            cpu.ecx -%= 1;
            if (cpu.ecx != 0 and !cpu.flags.getZF()) applyRel(cpu, insn);
        },
        0xE1 => { // LOOPE
            cpu.ecx -%= 1;
            if (cpu.ecx != 0 and cpu.flags.getZF()) applyRel(cpu, insn);
        },
        0xE2 => { // LOOP
            cpu.ecx -%= 1;
            if (cpu.ecx != 0) applyRel(cpu, insn);
        },
        0xE3 => { // JECXZ
            if (cpu.ecx == 0) applyRel(cpu, insn);
        },

        // Group 3: F6 (8-bit), F7 (32-bit)
        0xF6, 0xF7 => execGroup3(cpu, insn),

        // Group 5: FF
        0xFF => execGroup5(cpu, insn, eip),
        // Group 4: FE (INC/DEC r/m8)
        0xFE => {
            if (insn.has_modrm) {
                const val = readOperand(cpu, insn, 0);
                if (insn.modrm_reg == 0) { // INC
                    const result = val +% 1;
                    writeOperand8(cpu, insn, 0, @truncate(result));
                    cpu.flags.update(.inc, .byte, result, val, 1);
                } else if (insn.modrm_reg == 1) { // DEC
                    const result = val -% 1;
                    writeOperand8(cpu, insn, 0, @truncate(result));
                    cpu.flags.update(.dec, .byte, result, val, 1);
                }
            }
        },

        // CLC, STC, CLI, STI, CLD, STD
        0xF8 => cpu.flags.clearFlag(flags_mod.FLAG_CF),
        0xF9 => cpu.flags.setFlag(flags_mod.FLAG_CF),
        0xFA => cpu.flags.clearFlag(flags_mod.FLAG_IF),
        0xFB => cpu.flags.setFlag(flags_mod.FLAG_IF),
        0xFC => cpu.flags.clearFlag(flags_mod.FLAG_DF),
        0xFD => cpu.flags.setFlag(flags_mod.FLAG_DF),

        // --- Two-byte opcodes (0x0Fxx) ---

        // Jcc near (0F 80 - 0F 8F)
        0x0F80...0x0F8F => {
            const cc: u4 = @truncate(insn.opcode);
            if (cpu.flags.evaluateCC(cc)) applyRel(cpu, insn);
        },

        // SETcc (0F 90-9F)
        0x0F90...0x0F9F => {
            const cc: u4 = @truncate(insn.opcode);
            const val: u8 = if (cpu.flags.evaluateCC(cc)) 1 else 0;
            writeOperand8(cpu, insn, 0, val);
        },

        // MOVZX r32, r/m8 (0F B6)
        0x0FB6 => {
            const val: u32 = readOperand(cpu, insn, 1) & 0xFF;
            cpu.setReg(@enumFromInt(insn.modrm_reg), val);
        },
        // MOVZX r32, r/m16 (0F B7)
        0x0FB7 => {
            const val: u32 = readOperand(cpu, insn, 1) & 0xFFFF;
            cpu.setReg(@enumFromInt(insn.modrm_reg), val);
        },
        // MOVSX r32, r/m8 (0F BE)
        0x0FBE => {
            const val: u8 = @truncate(readOperand(cpu, insn, 1));
            cpu.setReg(@enumFromInt(insn.modrm_reg), cpu_mod.signExtend8to32(val));
        },
        // MOVSX r32, r/m16 (0F BF)
        0x0FBF => {
            const val: u16 = @truncate(readOperand(cpu, insn, 1));
            cpu.setReg(@enumFromInt(insn.modrm_reg), cpu_mod.signExtend16to32(val));
        },

        0x0FAF => {
            const a: i32 = @bitCast(cpu.getReg(@enumFromInt(insn.modrm_reg)));
            const b: i32 = @bitCast(readOperand(cpu, insn, 1));
            const result: i64 = @as(i64, a) * @as(i64, b);
            const r32: u32 = @truncate(@as(u64, @bitCast(result)));
            cpu.setReg(@enumFromInt(insn.modrm_reg), r32);
            var ef = cpu.flags.toEflags();
            const sext: i64 = @as(i32, @bitCast(r32));
            if (result != sext) {
                ef |= flags_mod.FLAG_CF | flags_mod.FLAG_OF;
            } else {
                ef &= ~(flags_mod.FLAG_CF | flags_mod.FLAG_OF);
            }
            cpu.flags.fromEflags(ef);
        },

        // CMOVcc (0F 40-4F)
        0x0F40...0x0F4F => {
            const cc: u4 = @truncate(insn.opcode);
            if (cpu.flags.evaluateCC(cc)) {
                const val = readOperand(cpu, insn, 1);
                cpu.setReg(@enumFromInt(insn.modrm_reg), val);
            }
        },

        // RDTSC (0F 31) — read timestamp counter
        0x0F31 => {
            // A real TSC is monotonic; guests diff consecutive readings, so
            // feed the monotonic clock instead of the steppable wall clock.
            const tsc: u64 = @intCast(@as(i128, runtime.monoNanoTimestamp()));
            cpu.eax = @truncate(tsc);
            cpu.edx = @truncate(tsc >> 32);
        },

        // PUSH FS (0F A0) / POP FS (0F A1)
        0x0FA0 => cpu.push32(cpu.fs),
        0x0FA1 => cpu.fs = @truncate(cpu.pop32()),
        // CPUID (0F A2)
        0x0FA2 => {
            const leaf = cpu.eax;
            switch (leaf) {
                0 => {
                    // Max basic CPUID leaf + vendor "GenuineIntel"
                    cpu.eax = 2; // max supported leaf
                    cpu.ebx = 0x756E6547; // "Genu"
                    cpu.edx = 0x49656E69; // "ineI"
                    cpu.ecx = 0x6C65746E; // "ntel"
                },
                1 => {
                    // Processor info: Family 6, Model 3, Stepping 3 (Pentium II-ish)
                    cpu.eax = 0x00000633;
                    cpu.ebx = 0x00010800; // CLFLUSH=8, LogicalProcessors=1
                    cpu.ecx = 0; // no SSE3/etc
                    // Feature flags: FPU, TSC, MSR, CX8, SEP, CMOV, MMX, FXSR, SSE, SSE2
                    cpu.edx = (1 << 0) | // FPU
                        (1 << 4) | // TSC
                        (1 << 5) | // MSR
                        (1 << 8) | // CX8
                        (1 << 11) | // SEP
                        (1 << 15) | // CMOV
                        (1 << 23) | // MMX
                        (1 << 24) | // FXSR
                        (1 << 25) | // SSE
                        (1 << 26); // SSE2
                },
                2 => {
                    // Cache descriptors - minimal
                    cpu.eax = 0x00000001; // 1 call needed
                    cpu.ebx = 0;
                    cpu.ecx = 0;
                    cpu.edx = 0;
                },
                0x80000000 => {
                    // Max extended CPUID leaf
                    cpu.eax = 0x80000004;
                    cpu.ebx = 0;
                    cpu.ecx = 0;
                    cpu.edx = 0;
                },
                0x80000001 => {
                    cpu.eax = 0;
                    cpu.ebx = 0;
                    cpu.ecx = 0;
                    cpu.edx = 0;
                },
                // Processor brand string "Intel Pentium II"
                0x80000002 => {
                    cpu.eax = 0x65746E49; // "Inte"
                    cpu.ebx = 0x6E65206C; // "l en"
                    cpu.ecx = 0x756C6174; // "talu"
                    cpu.edx = 0x4950206D; // "m PI"
                },
                0x80000003 => {
                    cpu.eax = 0x00000000;
                    cpu.ebx = 0x00000000;
                    cpu.ecx = 0x00000000;
                    cpu.edx = 0x00000000;
                },
                0x80000004 => {
                    cpu.eax = 0x00000000;
                    cpu.ebx = 0x00000000;
                    cpu.ecx = 0x00000000;
                    cpu.edx = 0x00000000;
                },
                else => {
                    // Unknown leaf — return zeros
                    cpu.eax = 0;
                    cpu.ebx = 0;
                    cpu.ecx = 0;
                    cpu.edx = 0;
                },
            }
        },
        0x0FA8 => cpu.push32(cpu.gs),
        0x0FA9 => cpu.gs = @truncate(cpu.pop32()),

        // BSF (0F BC)
        0x0FBC => {
            const val = readOperand(cpu, insn, 1);
            if (val == 0) {
                cpu.flags.update(.logic, .dword, 0, 0, 0); // sets ZF
            } else {
                const bit: u32 = @ctz(val);
                cpu.setReg(@enumFromInt(insn.modrm_reg), bit);
                cpu.flags.update(.logic, .dword, 1, 0, 0); // clears ZF
            }
        },
        // BSR (0F BD)
        0x0FBD => {
            const val = readOperand(cpu, insn, 1);
            if (val == 0) {
                cpu.flags.update(.logic, .dword, 0, 0, 0);
            } else {
                const bit: u32 = 31 - @as(u32, @clz(val));
                cpu.setReg(@enumFromInt(insn.modrm_reg), bit);
                cpu.flags.update(.logic, .dword, 1, 0, 0);
            }
        },

        // BT/BTS/BTR/BTC (0F A3/AB/B3/BB)
        0x0FA3, 0x0FAB, 0x0FB3, 0x0FBB => {
            if (insn.op0_kind == .mem) {
                // If base is memory and index is a register, indexing spans arbitrary bytes!
                const orig_addr = computeEffectiveAddress(cpu, insn);
                const bit_index_raw = readOperand(cpu, insn, 1);
                // Index is a signed offset for memory bit ops
                const bit_index: i32 = if (insn.op_size == .word)
                    @as(i32, @bitCast(cpu_mod.signExtend16to32(@truncate(bit_index_raw))))
                else
                    @as(i32, @bitCast(bit_index_raw));

                const byte_offset: i32 = @divFloor(bit_index, 8);
                const bit_in_byte: u3 = @intCast(@mod(bit_index, 8));

                const target_addr = orig_addr +% @as(u32, @bitCast(byte_offset));
                const val = cpu.memory.read8(target_addr);

                var ef = cpu.flags.toEflags();
                if ((val >> bit_in_byte) & 1 != 0) ef |= flags_mod.FLAG_CF else ef &= ~flags_mod.FLAG_CF;
                cpu.flags.fromEflags(ef);

                const new_val: u8 = switch (insn.opcode) {
                    0x0FA3 => val,
                    0x0FAB => val | (@as(u8, 1) << bit_in_byte),
                    0x0FB3 => val & ~(@as(u8, 1) << bit_in_byte),
                    0x0FBB => val ^ (@as(u8, 1) << bit_in_byte),
                    else => unreachable,
                };
                if (insn.opcode != 0x0FA3) cpu.memory.write8(target_addr, new_val);
            } else {
                const val = readOperand(cpu, insn, 0);
                const raw_bit = readOperand(cpu, insn, 1);
                // For register base, index is wrapped to operand size
                const bit: u5 = if (insn.op_size == .word) @truncate(raw_bit & 15) else @truncate(raw_bit);
                var ef = cpu.flags.toEflags();
                if ((val >> bit) & 1 != 0) ef |= flags_mod.FLAG_CF else ef &= ~flags_mod.FLAG_CF;
                cpu.flags.fromEflags(ef);

                const new_val: u32 = switch (insn.opcode) {
                    0x0FA3 => val, // BT — test only
                    0x0FAB => val | (@as(u32, 1) << bit), // BTS
                    0x0FB3 => val & ~(@as(u32, 1) << bit), // BTR
                    0x0FBB => val ^ (@as(u32, 1) << bit), // BTC
                    else => unreachable,
                };
                if (insn.opcode != 0x0FA3) writeOperand(cpu, insn, 0, new_val);
            }
        },

        // BSWAP (0F C8-CF)
        0x0FC8...0x0FCF => {
            const reg: cpu_mod.RegIndex = @enumFromInt(@as(u3, @truncate(insn.opcode)));
            const val = cpu.getReg(reg);
            cpu.setReg(reg, @byteSwap(val));
        },

        // SHLD imm8 (0F A4) / SHLD CL (0F A5)
        0x0FA4, 0x0FA5 => {
            const dst = readOperand(cpu, insn, 0);
            const src = readOperand(cpu, insn, 1);
            const count: u5 = if (insn.opcode == 0x0FA4) @truncate(insn.imm) else @truncate(cpu.ecx);
            if (count != 0) {
                const wide: u64 = (@as(u64, dst) << 32) | @as(u64, src);
                const shifted = wide << count;
                const result: u32 = @truncate(shifted >> 32);
                writeOperand(cpu, insn, 0, result);
                cpu.flags.update(.shl, insn.op_size, result, dst, @as(u32, count));
            }
        },
        // SHRD imm8 (0F AC) / SHRD CL (0F AD)
        0x0FAC, 0x0FAD => {
            const dst = readOperand(cpu, insn, 0);
            const src = readOperand(cpu, insn, 1);
            const count: u5 = if (insn.opcode == 0x0FAC) @truncate(insn.imm) else @truncate(cpu.ecx);
            if (count != 0) {
                const wide: u64 = (@as(u64, src) << 32) | @as(u64, dst);
                const shifted = wide >> count;
                const result: u32 = @truncate(shifted);
                writeOperand(cpu, insn, 0, result);
                cpu.flags.update(.shr, insn.op_size, result, dst, @as(u32, count));
            }
        },

        // IMUL r, r/m, imm32 (69) / IMUL r, r/m, imm8 (6B)
        0x69, 0x6B => {
            const src: i32 = @bitCast(readOperand(cpu, insn, 1));
            const imm: i32 = @bitCast(insn.imm);
            const result: i64 = @as(i64, src) * @as(i64, imm);
            const r32: u32 = @truncate(@as(u64, @bitCast(result)));
            cpu.setReg(@enumFromInt(insn.modrm_reg), r32);
            var ef = cpu.flags.toEflags();
            const sext: i64 = @as(i32, @bitCast(r32));
            if (result != sext) {
                ef |= flags_mod.FLAG_CF | flags_mod.FLAG_OF;
            } else {
                ef &= ~(flags_mod.FLAG_CF | flags_mod.FLAG_OF);
            }
            cpu.flags.fromEflags(ef);
        },

        // --- Legacy segment PUSH/POP ---
        0x06 => cpu.push32(cpu.es), // PUSH ES
        0x07 => cpu.es = @truncate(cpu.pop32()), // POP ES
        0x0E => cpu.push32(cpu.cs), // PUSH CS
        0x16 => cpu.push32(cpu.ss), // PUSH SS
        0x17 => cpu.ss = @truncate(cpu.pop32()), // POP SS
        0x1E => cpu.push32(cpu.ds), // PUSH DS
        0x1F => cpu.ds = @truncate(cpu.pop32()), // POP DS

        // --- BCD adjust (stub — just update flags minimally) ---
        0x27, 0x2F, 0x37, 0x3F => {
            // DAA/DAS/AAA/AAS — rarely used, stub as no-op
            log.warn("x86: BCD adjust 0x{X:0>2} stubbed at 0x{X}", .{ insn.opcode, eip });
        },

        // PUSHAD (0x60)
        0x60 => {
            const tmp = cpu.esp;
            cpu.push32(cpu.eax);
            cpu.push32(cpu.ecx);
            cpu.push32(cpu.edx);
            cpu.push32(cpu.ebx);
            cpu.push32(tmp);
            cpu.push32(cpu.ebp);
            cpu.push32(cpu.esi);
            cpu.push32(cpu.edi);
        },
        // POPAD (0x61)
        0x61 => {
            cpu.edi = cpu.pop32();
            cpu.esi = cpu.pop32();
            cpu.ebp = cpu.pop32();
            _ = cpu.pop32();
            cpu.ebx = cpu.pop32();
            cpu.edx = cpu.pop32();
            cpu.ecx = cpu.pop32();
            cpu.eax = cpu.pop32();
        },

        // BOUND (0x62) — just skip, no-op in user mode
        0x62 => {},

        // INS/OUTS — I/O port opcodes, no-op in emulation
        0x6C, 0x6D, 0x6E, 0x6F => {
            log.warn("x86: I/O port instruction 0x{X:0>2} stubbed at 0x{X}", .{ insn.opcode, eip });
        },

        // 0x82 — alias for Group 1 byte (same as 0x80)
        0x82 => execGroup1(cpu, insn),

        // --- FPU instructions (D8-DF) ---
        0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF => {
            executeFpu(cpu, insn);
        },

        // ENTER imm16, imm8 (C8)
        0xC8 => {
            const frame_size: u16 = @truncate(insn.imm);
            // nesting level is the 3rd byte, but we only handle level 0
            cpu.push32(cpu.ebp);
            cpu.ebp = cpu.esp;
            cpu.esp -%= frame_size;
        },

        // LES/LDS (C4/C5) — rarely used, stub
        0xC4, 0xC5 => {
            log.warn("x86: LES/LDS stubbed at 0x{X}", .{eip});
        },

        // IN/OUT (E4-E7, EC-EF) — I/O port, stub
        0xE4, 0xE5, 0xE6, 0xE7, 0xEC, 0xED, 0xEE, 0xEF => {
            log.warn("x86: I/O port instruction 0x{X:0>2} stubbed at 0x{X}", .{ insn.opcode, eip });
        },

        // CMC (F5)
        0xF5 => cpu.flags.toggleFlag(flags_mod.FLAG_CF),
        // WAIT/FWAIT (9B) — no-op
        0x9B => {},
        // INT1/ICEBP (F1) — treat like NOP
        0xF1 => {},

        // XLAT (D7)
        0xD7 => {
            const addr = cpu.ebx +% @as(u32, cpu.getReg8(0));
            cpu.setReg8(0, cpu.memory.read8(addr));
        },

        // AAM/AAD (D4/D5) — stub
        0xD4, 0xD5 => {
            log.warn("x86: AAM/AAD stubbed at 0x{X}", .{eip});
        },

        // Multi-byte NOP (0F 1F and 0F 18-1E)
        0x0F18, 0x0F19, 0x0F1A, 0x0F1B, 0x0F1C, 0x0F1D, 0x0F1E, 0x0F1F => {},

        // XADD (0F C0/C1)
        0x0FC0, 0x0FC1 => {
            const a = readOperand(cpu, insn, 0);
            const b = readOperand(cpu, insn, 1);
            const result = a +% b;
            if (insn.opcode == 0x0FC0) {
                writeOperand8(cpu, insn, 1, @truncate(a));
                writeOperand8(cpu, insn, 0, @truncate(result));
            } else {
                writeOperand(cpu, insn, 1, a);
                writeOperand(cpu, insn, 0, result);
            }
            cpu.flags.update(.add, insn.op_size, result, a, b);
        },

        // CMPXCHG (0F B0/B1)
        0x0FB0 => {
            const dst = readOperand(cpu, insn, 0);
            const al: u32 = cpu.getReg8(0);
            if (al == (dst & 0xFF)) {
                writeOperand8(cpu, insn, 0, @truncate(readOperand(cpu, insn, 1)));
            } else {
                cpu.setReg8(0, @truncate(dst));
            }
            cpu.flags.update(.sub, .byte, al -% dst, al, dst);
        },
        0x0FB1 => {
            const dst = readOperand(cpu, insn, 0);
            if (cpu.eax == dst) {
                writeOperand(cpu, insn, 0, readOperand(cpu, insn, 1));
            } else {
                cpu.eax = dst;
            }
            cpu.flags.update(.sub, insn.op_size, cpu.eax -% dst, cpu.eax, dst);
        },

        // BT/BTS/BTR/BTC imm8 (0F BA)
        0x0FBA => {
            if (insn.has_modrm) {
                const val = readOperand(cpu, insn, 0);
                const bit: u5 = @truncate(insn.imm);
                var ef = cpu.flags.toEflags();
                if ((val >> bit) & 1 != 0) ef |= flags_mod.FLAG_CF else ef &= ~flags_mod.FLAG_CF;
                cpu.flags.fromEflags(ef);
                switch (insn.modrm_reg) {
                    5 => writeOperand(cpu, insn, 0, val | (@as(u32, 1) << bit)), // BTS
                    6 => writeOperand(cpu, insn, 0, val & ~(@as(u32, 1) << bit)), // BTR
                    7 => writeOperand(cpu, insn, 0, val ^ (@as(u32, 1) << bit)), // BTC
                    else => {}, // BT (4) — just test, don't modify
                }
            }
        },

        // LSL/LAR (0F 02/03) — stub
        0x0F02, 0x0F03 => {
            log.warn("x86: LSL/LAR stubbed at 0x{X}", .{eip});
        },

        // ============================================================
        // SSE / SSE2 / MMX — dispatch to sse.zig
        // ============================================================
        0x0F10,
        0x0F11,
        0x0F12,
        0x0F13,
        0x0F14,
        0x0F15,
        0x0F16,
        0x0F17, // MOV* / UNPCK*
        0x0F28,
        0x0F29,
        0x0F2A,
        0x0F2B,
        0x0F2C,
        0x0F2D,
        0x0F2E,
        0x0F2F, // MOV* / CVT* / UCOMI*
        0x0F50,
        0x0F51,
        0x0F52,
        0x0F53,
        0x0F54,
        0x0F55,
        0x0F56,
        0x0F57, // MOVMSK / SQRT / AND / OR / XOR
        0x0F58,
        0x0F59,
        0x0F5A,
        0x0F5B,
        0x0F5C,
        0x0F5D,
        0x0F5E,
        0x0F5F, // ADD / MUL / CVT / SUB / MIN / DIV / MAX
        0x0F60,
        0x0F61,
        0x0F62,
        0x0F63,
        0x0F64,
        0x0F65,
        0x0F66,
        0x0F67, // PUNPCK / PACK / PCMPGT
        0x0F68,
        0x0F69,
        0x0F6A,
        0x0F6B,
        0x0F6C,
        0x0F6D,
        0x0F6E,
        0x0F6F, // PUNPCK / PACK / MOVD / MOVQ
        0x0F70,
        0x0F71,
        0x0F72,
        0x0F73,
        0x0F74,
        0x0F75,
        0x0F76,
        0x0F77, // PSHUF / PSxx / PCMPEQ / EMMS
        0x0F7E,
        0x0F7F, // MOVD/MOVQ store / MOVDQA/MOVDQU store
        0x0FC2,
        0x0FC3,
        0x0FC4,
        0x0FC5,
        0x0FC6, // CMP* / MOVNTI / PINSRW / PEXTRW / SHUF*
        0x0FD0,
        0x0FD1,
        0x0FD2,
        0x0FD3,
        0x0FD4,
        0x0FD5,
        0x0FD6,
        0x0FD7, // PSRL / PADDQ / PMULL / MOVQ / PMOVMSKB
        0x0FD8,
        0x0FD9,
        0x0FDA,
        0x0FDB,
        0x0FDC,
        0x0FDD,
        0x0FDE,
        0x0FDF, // PSUBUS / PMIN / PAND / PADDUS / PMAX / PANDN
        0x0FE0,
        0x0FE1,
        0x0FE2,
        0x0FE3,
        0x0FE4,
        0x0FE5,
        0x0FE6,
        0x0FE7, // PAVG / PSRA / PMULH / CVT / MOVNTDQ
        0x0FE8,
        0x0FE9,
        0x0FEA,
        0x0FEB,
        0x0FEC,
        0x0FED,
        0x0FEE,
        0x0FEF, // PSUBS / PMIN / POR / PADDS / PMAX / PXOR
        0x0FF0,
        0x0FF1,
        0x0FF2,
        0x0FF3,
        0x0FF4,
        0x0FF5,
        0x0FF6,
        0x0FF7, // PSLL / PMULUDQ / PMADDWD / PSADBW
        0x0FF8,
        0x0FF9,
        0x0FFA,
        0x0FFB,
        0x0FFC,
        0x0FFD,
        0x0FFE, // PSUB / PADD
        0x0FAE, // LDMXCSR / STMXCSR / LFENCE / MFENCE / SFENCE
        => @import("sse.zig").execute(cpu, insn, eip),

        else => {
            // Check if guest has an SEH handler — if so, this is likely a deliberate
            // CPU feature probe (e.g., cpuidsdk uses 0F 3F to trigger #UD and catch
            // it via SEH). Dispatch the exception to SEH so the handler runs properly.
            const teb_mod = @import("../win32/teb.zig");
            var seh_head: u32 = 0;
            if (teb_mod.teb_base_addr != 0) {
                seh_head = @as(*const u32, @ptrFromInt(teb_mod.teb_base_addr)).*;
            }
            if (seh_head != 0 and seh_head != 0xFFFFFFFF) {
                log.info("x86: unimplemented opcode 0x{X:0>2} at 0x{X}, dispatching to SEH", .{ insn.opcode, eip });
                // Build EXCEPTION_RECORD and CONTEXT from interpreter CPU state
                var record = std.mem.zeroes(teb_mod.EXCEPTION_RECORD);
                record.ExceptionCode = 0xC000001D; // EXCEPTION_ILLEGAL_INSTRUCTION
                record.ExceptionAddress = eip;
                var context = std.mem.zeroes(teb_mod.CONTEXT);
                context.ContextFlags = 0x10007; // CONTEXT_FULL
                context.Eax = cpu.eax;
                context.Ecx = cpu.ecx;
                context.Edx = cpu.edx;
                context.Ebx = cpu.ebx;
                context.Esi = cpu.esi;
                context.Edi = cpu.edi;
                context.Ebp = cpu.ebp;
                context.Esp = cpu.esp;
                context.Eip = eip; // faulting instruction address
                // Walk SEH chain — on x86-linux, handler code is native x86
                var node = seh_head;
                while (node != 0 and node != 0xFFFFFFFF) {
                    const handler_addr = @as(*const u32, @ptrFromInt(@as(usize, node) + 4)).*;
                    if (handler_addr != 0) {
                        const HandlerFn = *const fn (*teb_mod.EXCEPTION_RECORD, u32, *teb_mod.CONTEXT, u32) callconv(.c) u32;
                        const handler_fn = @as(HandlerFn, @ptrFromInt(@as(usize, handler_addr)));
                        const disp = handler_fn(&record, node, &context, 0);
                        if (disp == 0) { // ExceptionContinueExecution
                            cpu.eax = context.Eax;
                            cpu.ecx = context.Ecx;
                            cpu.edx = context.Edx;
                            cpu.ebx = context.Ebx;
                            cpu.esi = context.Esi;
                            cpu.edi = context.Edi;
                            cpu.ebp = context.Ebp;
                            cpu.esp = context.Esp;
                            cpu.eip = context.Eip;
                            if (trace.enable_tracing) {
                                trace.print("x86: SEH handler ContinueExecution, EIP=0x{X}\n", .{cpu.eip});
                            }
                            return;
                        }
                    }
                    node = @as(*const u32, @ptrFromInt(@as(usize, node))).*;
                }
                // No handler handled it
                log.err("x86: unimplemented opcode 0x{X:0>2} at 0x{X}, SEH chain exhausted", .{ insn.opcode, eip });
                cpu.halted = true;
            } else {
                log.err("x86: unimplemented opcode 0x{X:0>2} at 0x{X} (byte: 0x{X:0>2})", .{ insn.opcode, eip, if (insn.length > 0) cpu.memory.read8(eip) else 0 });
                cpu.halted = true;
            }
        },
    }
}

// -----------------------------------------------------------------------
// Operand read/write helpers
// -----------------------------------------------------------------------

inline fn readOperand(cpu: *Cpu, insn: *const Instruction, idx: u1) u32 {
    const kind = if (idx == 0) insn.op0_kind else insn.op1_kind;
    const reg = if (idx == 0) insn.op0_reg else insn.op1_reg;
    return switch (kind) {
        .none => 0,
        .reg => if (insn.op_size == .byte) @as(u32, cpu.getReg8(reg)) else cpu.getReg(@enumFromInt(reg)),
        .mem => blk: {
            const addr = computeEffectiveAddress(cpu, insn);
            break :blk switch (insn.op_size) {
                .byte => @as(u32, cpu.memory.read8(addr)),
                .word => @as(u32, cpu.memory.read16(addr)),
                .dword => cpu.memory.read32(addr),
            };
        },
        .imm, .rel => insn.imm,
    };
}

inline fn writeOperand(cpu: *Cpu, insn: *const Instruction, idx: u1, val: u32) void {
    const kind = if (idx == 0) insn.op0_kind else insn.op1_kind;
    const reg = if (idx == 0) insn.op0_reg else insn.op1_reg;
    switch (kind) {
        .reg => {
            if (insn.op_size == .word) {
                cpu.setReg16(reg, @truncate(val));
            } else {
                cpu.setReg(@enumFromInt(reg), val);
            }
        },
        .mem => {
            const addr = computeEffectiveAddress(cpu, insn);
            switch (insn.op_size) {
                .byte => cpu.memory.write8(addr, @truncate(val)),
                .word => cpu.memory.write16(addr, @truncate(val)),
                .dword => cpu.memory.write32(addr, val),
            }
        },
        else => {},
    }
}

inline fn writeOperand8(cpu: *Cpu, insn: *const Instruction, idx: u1, val: u8) void {
    const kind = if (idx == 0) insn.op0_kind else insn.op1_kind;
    const reg = if (idx == 0) insn.op0_reg else insn.op1_reg;
    switch (kind) {
        .reg => cpu.setReg8(reg, val),
        .mem => {
            const addr = computeEffectiveAddress(cpu, insn);
            cpu.memory.write8(addr, val);
        },
        else => {},
    }
}

inline fn writeOperandSized(cpu: *Cpu, insn: *const Instruction, idx: u1, val: u32, size: OpSize) void {
    const kind = if (idx == 0) insn.op0_kind else insn.op1_kind;
    const reg = if (idx == 0) insn.op0_reg else insn.op1_reg;
    switch (kind) {
        .reg => {
            switch (size) {
                .byte => cpu.setReg8(reg, @truncate(val)),
                .word => cpu.setReg16(reg, @truncate(val)),
                .dword => cpu.setReg(@enumFromInt(reg), val),
            }
        },
        .mem => {
            const addr = computeEffectiveAddress(cpu, insn);
            switch (size) {
                .byte => cpu.memory.write8(addr, @truncate(val)),
                .word => cpu.memory.write16(addr, @truncate(val)),
                .dword => cpu.memory.write32(addr, val),
            }
        },
        else => {},
    }
}

inline fn readMemAddr(cpu: *const Cpu, insn: *const Instruction, idx: u1) u32 {
    const kind = if (idx == 0) insn.op0_kind else insn.op1_kind;
    return if (kind == .mem) computeEffectiveAddress(cpu, insn) else 0;
}

pub inline fn computeEffectiveAddress(cpu: *const Cpu, insn: *const Instruction) u32 {
    var addr: u32 = 0;
    if (insn.mem_base != 0xF) addr +%= cpu.getReg(@enumFromInt(@as(u3, @truncate(insn.mem_base))));
    if (insn.mem_index != 0xF) {
        const idx_val = cpu.getReg(@enumFromInt(@as(u3, @truncate(insn.mem_index))));
        addr +%= idx_val << insn.mem_scale;
    }
    addr +%= @bitCast(insn.mem_disp);
    return cpu.resolveSegmentAddress(insn.mem_seg, addr);
}

// -----------------------------------------------------------------------
// ALU execution
// -----------------------------------------------------------------------

/// Executes a generic ALU instruction (ADD, OR, ADC, SBB, AND, SUB, XOR, CMP).
/// Updates flags based on the operation and operand size.
fn execAlu(cpu: *Cpu, insn: *const Instruction) void {
    // Decode which ALU operation from the opcode
    // Opcodes are grouped: 00-05=ADD, 08-0D=OR, 10-15=ADC, 18-1D=SBB,
    //                      20-25=AND, 28-2D=SUB, 30-35=XOR, 38-3D=CMP
    const group: u3 = @truncate(insn.opcode >> 3);
    const a = readOperand(cpu, insn, 0);
    const b = readOperand(cpu, insn, 1);
    const cf: u32 = if (cpu.flags.getCF()) 1 else 0;

    const result: u32 = switch (group) {
        0 => a +% b, // ADD
        1 => a | b, // OR
        2 => a +% b +% cf, // ADC
        3 => a -% b -% cf, // SBB
        4 => a & b, // AND
        5 => a -% b, // SUB
        6 => a ^ b, // XOR
        7 => a -% b, // CMP (same as SUB but don't store)
    };

    if (group == 2) {
        cpu.flags.updateCarry(.adc, insn.op_size, result, a, b, cf);
    } else if (group == 3) {
        cpu.flags.updateCarry(.sbb, insn.op_size, result, a, b, cf);
    } else {
        const flag_op: FlagOp = switch (group) {
            0 => .add,
            1, 4, 6 => .logic,
            5, 7 => .sub,
            else => unreachable,
        };
        cpu.flags.update(flag_op, insn.op_size, result, a, b);
    }

    // Don't store result for CMP (group 7)
    if (group != 7) {
        if (insn.op_size == .byte) {
            writeOperand8(cpu, insn, 0, @truncate(result));
        } else {
            writeOperand(cpu, insn, 0, result);
        }
    }
}

/// Executes Group 1 ALU instructions with immediate operands (80, 81, 83).
fn execGroup1(cpu: *Cpu, insn: *const Instruction) void {
    if (!insn.has_modrm) return;
    const sub_op = insn.modrm_reg;
    const val = readOperand(cpu, insn, 0);
    const imm = insn.imm;
    const cf: u32 = if (cpu.flags.getCF()) 1 else 0;

    const result: u32 = switch (sub_op) {
        0 => val +% imm, // ADD
        1 => val | imm, // OR
        2 => val +% imm +% cf, // ADC
        3 => val -% imm -% cf, // SBB
        4 => val & imm, // AND
        5 => val -% imm, // SUB
        6 => val ^ imm, // XOR
        7 => val -% imm, // CMP
    };

    if (sub_op == 2) {
        cpu.flags.updateCarry(.adc, insn.op_size, result, val, imm, cf);
    } else if (sub_op == 3) {
        cpu.flags.updateCarry(.sbb, insn.op_size, result, val, imm, cf);
    } else {
        const flag_op: FlagOp = switch (sub_op) {
            0 => .add,
            1, 4, 6 => .logic,
            5, 7 => .sub,
            else => unreachable,
        };
        cpu.flags.update(flag_op, insn.op_size, result, val, imm);
    }

    if (sub_op != 7) { // Don't store for CMP
        if (insn.op_size == .byte) {
            writeOperand8(cpu, insn, 0, @truncate(result));
        } else {
            writeOperand(cpu, insn, 0, result);
        }
    }
}

/// Executes Group 3 unary/arithmetic instructions (F6, F7).
/// Handles TEST, NOT, NEG, MUL, IMUL, DIV, IDIV.
fn execGroup3(cpu: *Cpu, insn: *const Instruction) void {
    if (!insn.has_modrm) return;
    const sub_op = insn.modrm_reg;
    const val = readOperand(cpu, insn, 0);
    const is_byte = insn.opcode == 0xF6;
    const os: OpSize = if (is_byte) .byte else insn.op_size;

    switch (sub_op) {
        0, 1 => { // TEST r/m, imm
            const result = val & insn.imm;
            cpu.flags.update(.logic, os, result, val, insn.imm);
        },
        2 => { // NOT
            const result = ~val;
            if (is_byte) writeOperand8(cpu, insn, 0, @truncate(result)) else writeOperand(cpu, insn, 0, result);
        },
        3 => { // NEG
            const result = 0 -% val;
            if (is_byte) writeOperand8(cpu, insn, 0, @truncate(result)) else writeOperand(cpu, insn, 0, result);
            cpu.flags.update(.neg, os, result, 0, val);
        },
        4 => { // MUL
            if (is_byte) {
                const result: u16 = @as(u16, @truncate(cpu.eax & 0xFF)) * @as(u16, @truncate(val));
                cpu.eax = (cpu.eax & 0xFFFF0000) | result;
                var ef = cpu.flags.toEflags();
                if ((result & 0xFF00) != 0) {
                    ef |= flags_mod.FLAG_CF | flags_mod.FLAG_OF;
                } else {
                    ef &= ~(flags_mod.FLAG_CF | flags_mod.FLAG_OF);
                }
                cpu.flags.fromEflags(ef);
            } else {
                const result: u64 = @as(u64, cpu.eax) * @as(u64, val);
                cpu.eax = @truncate(result);
                cpu.edx = @truncate(result >> 32);
                var ef = cpu.flags.toEflags();
                if ((result >> 32) != 0) {
                    ef |= flags_mod.FLAG_CF | flags_mod.FLAG_OF;
                } else {
                    ef &= ~(flags_mod.FLAG_CF | flags_mod.FLAG_OF);
                }
                cpu.flags.fromEflags(ef);
            }
        },
        5 => { // IMUL (one-operand form)
            if (is_byte) {
                const a: i16 = @as(i8, @bitCast(@as(u8, @truncate(cpu.eax))));
                const b: i16 = @as(i8, @bitCast(@as(u8, @truncate(val))));
                const result: u16 = @bitCast(a * b);
                cpu.eax = (cpu.eax & 0xFFFF0000) | result;
                var ef = cpu.flags.toEflags();
                const sext: i16 = @as(i8, @bitCast(@as(u8, @truncate(result))));
                if (result != @as(u16, @bitCast(sext))) {
                    ef |= flags_mod.FLAG_CF | flags_mod.FLAG_OF;
                } else {
                    ef &= ~(flags_mod.FLAG_CF | flags_mod.FLAG_OF);
                }
                cpu.flags.fromEflags(ef);
            } else {
                const a: i64 = @as(i32, @bitCast(cpu.eax));
                const b: i64 = @as(i32, @bitCast(val));
                const result: u64 = @bitCast(a * b);
                cpu.eax = @truncate(result);
                cpu.edx = @truncate(result >> 32);
                var ef = cpu.flags.toEflags();
                const sext: i64 = @as(i32, @bitCast(@as(u32, @truncate(result))));
                if (result != @as(u64, @bitCast(sext))) {
                    ef |= flags_mod.FLAG_CF | flags_mod.FLAG_OF;
                } else {
                    ef &= ~(flags_mod.FLAG_CF | flags_mod.FLAG_OF);
                }
                cpu.flags.fromEflags(ef);
            }
        },
        6 => { // DIV
            if (is_byte) {
                const dividend: u16 = @truncate(cpu.eax);
                if (val == 0) {
                    cpu.halted = true;
                    return;
                }
                const v16: u16 = @truncate(val);
                cpu.setReg8(0, @truncate(dividend / v16));
                cpu.setReg8(4, @truncate(dividend % v16));
            } else {
                const dividend: u64 = (@as(u64, cpu.edx) << 32) | cpu.eax;
                if (val == 0) {
                    cpu.halted = true;
                    return;
                }
                cpu.eax = @truncate(dividend / val);
                cpu.edx = @truncate(dividend % val);
            }
        },
        7 => { // IDIV
            if (is_byte) {
                const dividend: i16 = @bitCast(@as(u16, @truncate(cpu.eax)));
                const divisor: i8 = @bitCast(@as(u8, @truncate(val)));
                if (divisor == 0) {
                    cpu.halted = true;
                    return;
                }
                cpu.setReg8(0, @bitCast(@as(i8, @truncate(@divTrunc(dividend, divisor)))));
                cpu.setReg8(4, @bitCast(@as(i8, @truncate(@rem(dividend, divisor)))));
            } else {
                const dividend: i64 = @bitCast((@as(u64, cpu.edx) << 32) | cpu.eax);
                const divisor: i32 = @bitCast(val);
                if (divisor == 0) {
                    cpu.halted = true;
                    return;
                }
                const quot = @divTrunc(dividend, divisor);
                const rem_val = @rem(dividend, divisor);
                cpu.eax = @bitCast(@as(i32, @truncate(quot)));
                cpu.edx = @bitCast(@as(i32, @truncate(rem_val)));
            }
        },
    }
}

/// Executes Group 5 indirect control flow and arithmetic (FF).
/// Handles INC, DEC, CALL, JMP, PUSH.
fn execGroup5(cpu: *Cpu, insn: *const Instruction, eip: u32) void {
    _ = eip;
    if (!insn.has_modrm) return;
    const sub_op = insn.modrm_reg;
    switch (sub_op) {
        0 => { // INC r/m32
            const val = readOperand(cpu, insn, 0);
            const result = val +% 1;
            writeOperand(cpu, insn, 0, result);
            cpu.flags.update(.inc, insn.op_size, result, val, 1);
        },
        1 => { // DEC r/m32
            const val = readOperand(cpu, insn, 0);
            const result = val -% 1;
            writeOperand(cpu, insn, 0, result);
            cpu.flags.update(.dec, insn.op_size, result, val, 1);
        },
        2 => { // CALL r/m32 (indirect)
            const target = readOperand(cpu, insn, 0);
            cpu.push32(cpu.eip);
            cpu.eip = target;
        },
        4 => { // JMP r/m32 (indirect)
            cpu.eip = readOperand(cpu, insn, 0);
        },
        6 => { // PUSH r/m32
            cpu.push32(readOperand(cpu, insn, 0));
        },
        else => {
            log.err("x86: unimplemented Group 5 sub-op {d} at EIP", .{sub_op});
            cpu.halted = true;
        },
    }
}

/// Executes Group 2 shift and rotate instructions (C0, C1, D0-D3).
fn execShift(cpu: *Cpu, insn: *const Instruction) void {
    if (!insn.has_modrm) return;
    const sub_op = insn.modrm_reg;
    var val = readOperand(cpu, insn, 0);
    const count: u5 = switch (insn.opcode) {
        0xD0, 0xD1 => 1,
        0xD2, 0xD3 => @truncate(cpu.ecx),
        0xC0, 0xC1 => @truncate(insn.imm),
        else => 0,
    };
    if (count == 0) return;

    const result: u32 = switch (sub_op) {
        0 => (val << count) | (val >> (@as(u5, @truncate(@as(u32, 32) -% @as(u32, count))))), // ROL
        1 => (val >> count) | (val << (@as(u5, @truncate(@as(u32, 32) -% @as(u32, count))))), // ROR
        4 => val << count, // SHL
        5 => val >> count, // SHR
        7 => @bitCast(@as(i32, @bitCast(val)) >> count), // SAR
        else => val,
    };

    val = result;
    if (insn.op_size == .byte) writeOperand8(cpu, insn, 0, @truncate(result)) else writeOperand(cpu, insn, 0, result);

    const fop: FlagOp = switch (sub_op) {
        4 => .shl,
        5 => .shr,
        7 => .sar,
        else => .logic,
    };
    cpu.flags.update(fop, insn.op_size, result, val, @as(u32, count));
}

/// Executes the MOVSB string instruction (copy byte from ESI to EDI).
fn execMovsb(cpu: *Cpu, insn: *const Instruction) void {
    const df = cpu.flags.getDF();
    if (insn.rep) {
        // Bulk path: forward REP MOVSB is a byte copy; when the whole range
        // is in-bounds and writable, one memcpy replaces ECX checked bytes.
        // copyForwards preserves the forward-copy overlap semantics.
        if (!df and cpu.memory.readRangeInBounds(cpu.esi, cpu.ecx) and
            cpu.memory.writeRangeAllowed(cpu.edi, cpu.ecx))
        {
            const dst = cpu.memory.mutRange(cpu.edi, @intCast(cpu.ecx));
            const src = cpu.memory.range(cpu.esi, @intCast(cpu.ecx));
            std.mem.copyForwards(u8, dst, src);
            cpu.esi +%= cpu.ecx;
            cpu.edi +%= cpu.ecx;
            cpu.ecx = 0;
            return;
        }
        while (cpu.ecx > 0) : (cpu.ecx -= 1) {
            cpu.memory.write8(cpu.edi, cpu.memory.read8(cpu.esi));
            if (df) {
                cpu.esi -%= 1;
                cpu.edi -%= 1;
            } else {
                cpu.esi +%= 1;
                cpu.edi +%= 1;
            }
        }
    } else {
        cpu.memory.write8(cpu.edi, cpu.memory.read8(cpu.esi));
        if (df) {
            cpu.esi -%= 1;
            cpu.edi -%= 1;
        } else {
            cpu.esi +%= 1;
            cpu.edi +%= 1;
        }
    }
}

/// Executes the MOVSD string instruction (copy dword from ESI to EDI).
fn execMovsd(cpu: *Cpu, insn: *const Instruction) void {
    const df = cpu.flags.getDF();
    if (insn.rep) {
        // Bulk path for the common forward case (see execMovsb).
        if (!df) {
            const total: u64 = @as(u64, cpu.ecx) * 4;
            if (cpu.memory.readRangeInBounds(cpu.esi, total) and
                cpu.memory.writeRangeAllowed(cpu.edi, total))
            {
                const dst = cpu.memory.mutRange(cpu.edi, @intCast(total));
                const src = cpu.memory.range(cpu.esi, @intCast(total));
                std.mem.copyForwards(u8, dst, src);
                cpu.esi +%= @as(u32, @truncate(total));
                cpu.edi +%= @as(u32, @truncate(total));
                cpu.ecx = 0;
                return;
            }
        }
        while (cpu.ecx > 0) : (cpu.ecx -= 1) {
            cpu.memory.write32(cpu.edi, cpu.memory.read32(cpu.esi));
            if (df) {
                cpu.esi -%= 4;
                cpu.edi -%= 4;
            } else {
                cpu.esi +%= 4;
                cpu.edi +%= 4;
            }
        }
    } else {
        cpu.memory.write32(cpu.edi, cpu.memory.read32(cpu.esi));
        if (df) {
            cpu.esi -%= 4;
            cpu.edi -%= 4;
        } else {
            cpu.esi +%= 4;
            cpu.edi +%= 4;
        }
    }
}

/// Executes the STOSB string instruction (store AL at EDI).
fn execStosb(cpu: *Cpu, insn: *const Instruction) void {
    const df = cpu.flags.getDF();
    const val = cpu.getReg8(0);
    if (insn.rep) {
        // Bulk path: forward REP STOSB is a memset.
        if (!df and cpu.memory.writeRangeAllowed(cpu.edi, cpu.ecx)) {
            @memset(cpu.memory.mutRange(cpu.edi, @intCast(cpu.ecx)), val);
            cpu.edi +%= cpu.ecx;
            cpu.ecx = 0;
            return;
        }
        while (cpu.ecx > 0) : (cpu.ecx -= 1) {
            cpu.memory.write8(cpu.edi, val);
            if (df) cpu.edi -%= 1 else cpu.edi +%= 1;
        }
    } else {
        cpu.memory.write8(cpu.edi, val);
        if (df) cpu.edi -%= 1 else cpu.edi +%= 1;
    }
}

/// Executes the STOSD string instruction (store EAX at EDI).
fn execStosd(cpu: *Cpu, insn: *const Instruction) void {
    const df = cpu.flags.getDF();
    if (insn.rep) {
        // Bulk path: forward REP STOSD fills with the repeated EAX pattern.
        if (!df) {
            const total: u64 = @as(u64, cpu.ecx) * 4;
            if (total > 0 and cpu.memory.writeRangeAllowed(cpu.edi, total)) {
                const buf = cpu.memory.mutRange(cpu.edi, @intCast(total));
                std.mem.writeInt(u32, buf[0..4], cpu.eax, .little);
                var off: usize = 4;
                // Double the known prefix; copy it forward for the remainder.
                while (off < buf.len) {
                    const chunk = @min(off, buf.len - off);
                    @memcpy(buf[off..][0..chunk], buf[0..chunk]);
                    off += chunk;
                }
                cpu.edi +%= @as(u32, @truncate(total));
                cpu.ecx = 0;
                return;
            }
        }
        while (cpu.ecx > 0) : (cpu.ecx -= 1) {
            cpu.memory.write32(cpu.edi, cpu.eax);
            if (df) cpu.edi -%= 4 else cpu.edi +%= 4;
        }
    } else {
        cpu.memory.write32(cpu.edi, cpu.eax);
        if (df) cpu.edi -%= 4 else cpu.edi +%= 4;
    }
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;
const GuestMemory = cpu_mod.GuestMemory;

test "fistToInt: honors control-word rounding field" {
    const cw_default: u16 = 0x037F; // RC=00 nearest-even
    const cw_down: u16 = 0x077F; // RC=01 down
    const cw_up: u16 = 0x0B7F; // RC=10 up
    const cw_trunc: u16 = 0x0F7F; // RC=11 toward zero

    try testing.expectEqual(@as(i32, 2), fistToInt(i32, cw_default, 1.5));
    try testing.expectEqual(@as(i32, 2), fistToInt(i32, cw_default, 2.5)); // tie → even
    try testing.expectEqual(@as(i32, 1), fistToInt(i32, cw_down, 1.9));
    try testing.expectEqual(@as(i32, 2), fistToInt(i32, cw_up, 1.1));
    try testing.expectEqual(@as(i32, 1), fistToInt(i32, cw_trunc, 1.9));
    try testing.expectEqual(@as(i32, -1), fistToInt(i32, cw_trunc, -1.9));
}

test "fistToInt: NaN and out-of-range yield integer indefinite" {
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), fistToInt(i32, 0x037F, std.math.nan(f64)));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), fistToInt(i64, 0x037F, 1e19));
    try testing.expectEqual(@as(i16, std.math.minInt(i16)), fistToInt(i16, 0x037F, 40000.0));
}

fn makeCpu(mem: []u8) Cpu {
    return Cpu{ .memory = GuestMemory{ .base = mem } };
}

test "execute: MOV EAX, 0x12345678 + NOP + HLT" {
    // B8 78 56 34 12 = MOV EAX, 0x12345678
    // 90             = NOP
    // F4             = HLT
    var mem: [256]u8 = .{0} ** 256;
    mem[0] = 0xB8;
    mem[1] = 0x78;
    mem[2] = 0x56;
    mem[3] = 0x34;
    mem[4] = 0x12;
    mem[5] = 0x90;
    mem[6] = 0xF4;

    var cpu = makeCpu(&mem);
    cpu.esp = 200;
    run(&cpu);

    try testing.expectEqual(@as(u32, 0x12345678), cpu.eax);
    try testing.expect(cpu.halted);
}

test "execute: PUSH/POP" {
    var mem: [256]u8 = .{0} ** 256;
    mem[0] = 0x50;
    mem[1] = 0x5B;
    mem[2] = 0xF4;

    var cpu = makeCpu(&mem);
    cpu.eax = 0xDEAD;
    cpu.esp = 200;
    run(&cpu);

    try testing.expectEqual(@as(u32, 0xDEAD), cpu.ebx);
}

test "execute: ADD and flags" {
    var mem: [256]u8 = .{0} ** 256;
    // ADD EAX, 5:   05 05 00 00 00
    // CMP EAX, 7:   3D 07 00 00 00
    // HLT:          F4
    mem[0] = 0x05;
    mem[1] = 0x05;
    mem[2] = 0x00;
    mem[3] = 0x00;
    mem[4] = 0x00;
    mem[5] = 0x3D;
    mem[6] = 0x07;
    mem[7] = 0x00;
    mem[8] = 0x00;
    mem[9] = 0x00;
    mem[10] = 0xF4;

    var cpu = makeCpu(&mem);
    cpu.eax = 2;
    cpu.esp = 200;
    run(&cpu);

    try testing.expectEqual(@as(u32, 7), cpu.eax); // 2 + 5
    try testing.expect(cpu.flags.getZF()); // CMP 7, 7 -> ZF=1
}

test "execute: CALL and RET" {
    var mem: [256]u8 = .{0} ** 256;
    // 0x00: CALL +5 (E8 05 00 00 00) — target = 0x00 + 5 + 5 = 0x0A
    mem[0] = 0xE8;
    mem[1] = 0x05;
    mem[2] = 0x00;
    mem[3] = 0x00;
    mem[4] = 0x00;
    // 0x05: HLT (this is where we return to)
    mem[5] = 0xF4;
    // 0x0A: MOV EAX, 42 (B8 2A 00 00 00)
    mem[10] = 0xB8;
    mem[11] = 0x2A;
    mem[12] = 0x00;
    mem[13] = 0x00;
    mem[14] = 0x00;
    // 0x0F: RET (C3)
    mem[15] = 0xC3;

    var cpu = makeCpu(&mem);
    cpu.esp = 200;
    run(&cpu);

    try testing.expectEqual(@as(u32, 42), cpu.eax);
    try testing.expectEqual(@as(u32, 6), cpu.eip); // stopped at HLT (0x05), eip advanced to 0x06
}

test "execute: conditional jump" {
    var mem: [256]u8 = .{0} ** 256;
    // 0x00: CMP EAX, EAX (39 C0) — sets ZF=1
    mem[0] = 0x39;
    mem[1] = 0xC0;
    // 0x02: JE +2 (74 02) — jump to 0x06
    mem[2] = 0x74;
    mem[3] = 0x02;
    // 0x04: MOV EAX, 1 (skip this)
    mem[4] = 0xB8;
    mem[5] = 0x01;
    // 0x06: HLT
    mem[6] = 0xF4;

    var cpu = makeCpu(&mem);
    cpu.eax = 42;
    cpu.esp = 200;
    run(&cpu);

    // Should have jumped over MOV, so EAX should still be 42
    try testing.expectEqual(@as(u32, 42), cpu.eax);
}

test "execute: LEA" {
    var mem: [256]u8 = .{0} ** 256;
    // LEA EAX, [EBX+ECX*4+0x10]  =>  8D 44 8B 10
    mem[0] = 0x8D;
    mem[1] = 0x44;
    mem[2] = 0x8B;
    mem[3] = 0x10;
    mem[4] = 0xF4;

    var cpu = makeCpu(&mem);
    cpu.ebx = 0x100;
    cpu.ecx = 0x08;
    cpu.esp = 200;
    run(&cpu);

    // Expected: 0x100 + 0x08*4 + 0x10 = 0x100 + 0x20 + 0x10 = 0x130
    try testing.expectEqual(@as(u32, 0x130), cpu.eax);
}
