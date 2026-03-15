// x86 instruction execution dispatch for the software interpreter.
//
// Implements the decode-and-dispatch loop and execution handlers for
// all supported x86 instructions.

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decoder = @import("decoder.zig");
const flags_mod = @import("flags.zig");
const thunks = @import("thunks.zig");
const trace = @import("../trace.zig");
const log = @import("../log.zig");
const profiler = @import("../profiler.zig");


const Cpu = cpu_mod.Cpu;
const Instruction = decoder.Instruction;
const Operand = decoder.Operand;
const MemOperand = decoder.MemOperand;
const OpSize = flags_mod.OpSize;
const FlagOp = flags_mod.FlagOp;
const Segment = cpu_mod.Segment;

// -----------------------------------------------------------------------
// Entry point
// -----------------------------------------------------------------------

/// Run the decode-and-dispatch loop until the CPU halts.
pub fn run(cpu: *Cpu) void {
    while (!cpu.halted) {
        step(cpu);
    }
}

/// Execute one instruction.
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

    const code = cpu.memory.readSlice(eip, 16) orelse {
        log.err("x86: EIP 0x{X} out of bounds", .{eip});
        cpu.halted = true;
        return;
    };

    const insn = decoder.decode(code);

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
        cpu.eip = cpu.pop32(); // return address
        cpu.eax = 0;
        return;
    }

    // The return address was pushed by the CALL instruction
    const ret_addr = cpu.pop32(); trace.print("GUEST STACK POPPED {X}.\n", .{ret_addr});

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
                    if (cpu.memory.readSlice(thunk_addr, 6)) |thunk_bytes| {
                        if (thunk_bytes[0] == 0xFF and thunk_bytes[1] == 0x25) {
                            iat_slot = @as(*align(1) const u32, @ptrCast(thunk_bytes[2..6])).*;
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
    const is_cdecl = thunks.isTargetCdecl(target_addr);
    var result: u32 = 0;

    if (is_cdecl) {
        result = thunks.callNativeCdecl(target_addr, args);
    } else {
        const param_bytes = thunks.getParamBytes(target_addr);
        result = thunks.callNativeByArity(target_addr, param_bytes, args);
    }

    cpu.eax = result;
    cpu.eip = ret_addr;

    // Adjust guest ESP for stdcall cleanup — the PE code expects the
    // callee to have popped parameter bytes, but our cdecl call didn't.
    const cleanup = thunks.getStdcallCleanup(target_addr);

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
            trace.print("x86_execute: Native call to {X:0>8} [{s}] (cleanup={d} is_cdecl={}) ret={X}\n", .{ target_addr, name, cleanup, is_cdecl, result });
        } else {
            trace.print("x86_execute: Native call to {X:0>8} (cleanup={d} is_cdecl={}) ret={X}\n", .{ target_addr, cleanup, is_cdecl, result });
        }
    }

    // For cdecl functions, the caller cleans up — the guest code will
    // do `add esp, N` itself. We should NOT adjust ESP here.
    // For stdcall, the callee cleans up — we must simulate that.
    if (!is_cdecl) {
        cpu.esp +%= cleanup;
    }

    // On WASM, check if _initterm enqueued any guest init functions.
    // If so, build an x86 trampoline in guest memory to execute them.
    if (comptime !@import("../platform.zig").is_native) {
        const sc = @import("../win32/stub_common.zig");
        if (sc.pending_initterm_count > 0) {
            buildInittermTrampoline(cpu);
        }
    }
}

/// Build an x86 trampoline in guest memory to execute pending _initterm callbacks.
/// Each callback is a CALL rel32 to a guest function address, followed by a final RET.
/// The current EIP (CRT return address) is pushed onto the guest stack so the
/// trampoline's RET returns control to the CRT startup code.
pub fn buildInittermTrampoline(cpu: *Cpu) void {
    const stub_common = @import("../win32/stub_common.zig");
    const count = stub_common.pending_initterm_count;
    if (count == 0) return;

    // Find a location in guest memory for the trampoline.
    // Use guestAlloc from the heap to get guest-addressable memory.
    const gmem = stub_common.guest_memory orelse return;

    // Each CALL rel32 = 5 bytes, final RET = 1 byte
    const trampoline_size: u32 = @intCast(count * 5 + 1);
    const trampoline_va = gmem.guestAlloc(trampoline_size);
    if (trampoline_va == 0) return;

    // Write the trampoline x86 code
    var offset: u32 = 0;
    for (0..count) |i| {
        const func_va = stub_common.pending_initterm_callbacks[i];
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
    stub_common.pending_initterm_count = 0;

    // Push the current return address (where CRT code resumes)
    // and redirect EIP to the trampoline
    cpu.push32(cpu.eip);
    cpu.eip = trampoline_va;

    if (trace.enable_tracing) {
        trace.print("_initterm trampoline: {d} funcs at {x}, return to {x}\n", .{ count, trampoline_va, cpu.memory.read32(cpu.esp) });
    }
}

/// Execute an x87 FPU instruction.
fn executeFpu(cpu: anytype, insn: anytype) void {
    const modrm = insn.modrm orelse return;
    const reg: u8 = modrm.reg;
    const mem_addr: ?u32 = switch (insn.operands[0]) {
        .mem => |m| computeEffectiveAddress(cpu, &m),
        else => null,
    };
    const is_mem = (modrm.mod != 3);

    switch (insn.opcode) {
        0xD8 => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    const fval: f64 = @floatCast(@as(f32, @bitCast(cpu.memory.read32(addr))));
                    switch (reg) {
                        0 => cpu.fpu.setSt(0, cpu.fpu.st(0) + fval),
                        1 => cpu.fpu.setSt(0, cpu.fpu.st(0) * fval),
                        2, 3 => { fpuCompare(cpu, cpu.fpu.st(0), fval); if (reg == 3) _ = cpu.fpu.pop(); },
                        4 => cpu.fpu.setSt(0, cpu.fpu.st(0) - fval),
                        5 => cpu.fpu.setSt(0, fval - cpu.fpu.st(0)),
                        6 => if (fval != 0) { cpu.fpu.setSt(0, cpu.fpu.st(0) / fval); },
                        7 => if (cpu.fpu.st(0) != 0) { cpu.fpu.setSt(0, fval / cpu.fpu.st(0)); },
                        else => {},
                    }
                }
            } else {
                const sti = cpu.fpu.st(@truncate(modrm.rm));
                switch (reg) {
                    0 => cpu.fpu.setSt(0, cpu.fpu.st(0) + sti),
                    1 => cpu.fpu.setSt(0, cpu.fpu.st(0) * sti),
                    2, 3 => { fpuCompare(cpu, cpu.fpu.st(0), sti); if (reg == 3) _ = cpu.fpu.pop(); },
                    4 => cpu.fpu.setSt(0, cpu.fpu.st(0) - sti),
                    5 => cpu.fpu.setSt(0, sti - cpu.fpu.st(0)),
                    6 => if (sti != 0) { cpu.fpu.setSt(0, cpu.fpu.st(0) / sti); },
                    7 => if (cpu.fpu.st(0) != 0) { cpu.fpu.setSt(0, sti / cpu.fpu.st(0)); },
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
                        3 => { cpu.memory.write32(addr, @bitCast(@as(f32, @floatCast(cpu.fpu.st(0))))); _ = cpu.fpu.pop(); }, // FSTP
                        5 => cpu.fpu.control_word = cpu.memory.read16(addr), // FLDCW
                        7 => cpu.memory.write16(addr, cpu.fpu.control_word), // FNSTCW
                        else => {},
                    }
                }
            } else {
                const rm3: u3 = @truncate(modrm.rm);
                switch (reg) {
                    0 => cpu.fpu.push(cpu.fpu.st(rm3)), // FLD ST(i)
                    1 => { const t = cpu.fpu.st(0); cpu.fpu.setSt(0, cpu.fpu.st(rm3)); cpu.fpu.setSt(rm3, t); }, // FXCH
                    4 => switch (modrm.rm) { 0 => cpu.fpu.setSt(0, -cpu.fpu.st(0)), 1 => cpu.fpu.setSt(0, @abs(cpu.fpu.st(0))), else => {} }, // FCHS/FABS
                    5 => switch (modrm.rm) { 6 => cpu.fpu.push(0.0), 0 => cpu.fpu.push(1.0), else => {} }, // FLDZ/FLD1
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
                        2, 3 => { fpuCompare(cpu, cpu.fpu.st(0), ival); if (reg == 3) _ = cpu.fpu.pop(); },
                        4 => cpu.fpu.setSt(0, cpu.fpu.st(0) - ival),
                        5 => cpu.fpu.setSt(0, ival - cpu.fpu.st(0)),
                        6 => if (ival != 0) { cpu.fpu.setSt(0, cpu.fpu.st(0) / ival); },
                        7 => if (cpu.fpu.st(0) != 0) { cpu.fpu.setSt(0, ival / cpu.fpu.st(0)); },
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
                        2 => cpu.memory.write32(addr, @bitCast(safeFloatToInt(i32, cpu.fpu.st(0)))), // FIST m32
                        3 => { cpu.memory.write32(addr, @bitCast(safeFloatToInt(i32, cpu.fpu.st(0)))); _ = cpu.fpu.pop(); }, // FISTP
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
                if (reg == 4 and modrm.rm == 3) cpu.fpu.init(); // FNINIT (DB E3)
            }
        },
        0xDC => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    const lo = cpu.memory.read32(addr);
                    const hi = cpu.memory.read32(addr +% 4);
                    const fval: f64 = @bitCast(@as(u64, hi) << 32 | lo);
                    switch (reg) {
                        0 => cpu.fpu.setSt(0, cpu.fpu.st(0) + fval),
                        1 => cpu.fpu.setSt(0, cpu.fpu.st(0) * fval),
                        2, 3 => { fpuCompare(cpu, cpu.fpu.st(0), fval); if (reg == 3) _ = cpu.fpu.pop(); },
                        4 => cpu.fpu.setSt(0, cpu.fpu.st(0) - fval),
                        5 => cpu.fpu.setSt(0, fval - cpu.fpu.st(0)),
                        6 => if (fval != 0) { cpu.fpu.setSt(0, cpu.fpu.st(0) / fval); },
                        7 => if (cpu.fpu.st(0) != 0) { cpu.fpu.setSt(0, fval / cpu.fpu.st(0)); },
                        else => {},
                    }
                }
            } else {
                const i: u3 = @truncate(modrm.rm);
                switch (reg) {
                    0 => cpu.fpu.setSt(i, cpu.fpu.st(i) + cpu.fpu.st(0)),
                    1 => cpu.fpu.setSt(i, cpu.fpu.st(i) * cpu.fpu.st(0)),
                    4 => cpu.fpu.setSt(i, cpu.fpu.st(i) - cpu.fpu.st(0)),
                    5 => cpu.fpu.setSt(i, cpu.fpu.st(0) - cpu.fpu.st(i)),
                    6 => { const s = cpu.fpu.st(0); if (s != 0) cpu.fpu.setSt(i, cpu.fpu.st(i) / s); },
                    7 => { const s = cpu.fpu.st(i); if (s != 0) cpu.fpu.setSt(i, cpu.fpu.st(0) / s); },
                    else => {},
                }
            }
        },
        0xDD => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    switch (reg) {
                        0 => { const lo = cpu.memory.read32(addr); const hi = cpu.memory.read32(addr +% 4); cpu.fpu.push(@bitCast(@as(u64, hi) << 32 | lo)); }, // FLD m64
                        2 => { const b: u64 = @bitCast(cpu.fpu.st(0)); cpu.memory.write32(addr, @truncate(b)); cpu.memory.write32(addr +% 4, @truncate(b >> 32)); }, // FST
                        3 => { const b: u64 = @bitCast(cpu.fpu.st(0)); cpu.memory.write32(addr, @truncate(b)); cpu.memory.write32(addr +% 4, @truncate(b >> 32)); _ = cpu.fpu.pop(); }, // FSTP
                        7 => cpu.memory.write16(addr, cpu.fpu.getStatusWord()), // FNSTSW [mem]
                        else => {},
                    }
                }
            } else {
                const i: u3 = @truncate(modrm.rm);
                switch (reg) {
                    0 => cpu.fpu.setSt(i, 0), // FFREE
                    2 => cpu.fpu.setSt(i, cpu.fpu.st(0)), // FST ST(i)
                    3 => { cpu.fpu.setSt(i, cpu.fpu.st(0)); _ = cpu.fpu.pop(); }, // FSTP ST(i)
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
                        6 => if (ival != 0) { cpu.fpu.setSt(0, cpu.fpu.st(0) / ival); },
                        7 => if (cpu.fpu.st(0) != 0) { cpu.fpu.setSt(0, ival / cpu.fpu.st(0)); },
                        else => {},
                    }
                }
            } else {
                const i: u3 = @truncate(modrm.rm);
                switch (reg) {
                    0 => { cpu.fpu.setSt(i, cpu.fpu.st(i) + cpu.fpu.st(0)); _ = cpu.fpu.pop(); },
                    1 => { cpu.fpu.setSt(i, cpu.fpu.st(i) * cpu.fpu.st(0)); _ = cpu.fpu.pop(); },
                    4 => { cpu.fpu.setSt(i, cpu.fpu.st(i) - cpu.fpu.st(0)); _ = cpu.fpu.pop(); },
                    5 => { cpu.fpu.setSt(i, cpu.fpu.st(0) - cpu.fpu.st(i)); _ = cpu.fpu.pop(); },
                    6 => { const s = cpu.fpu.st(0); if (s != 0) cpu.fpu.setSt(i, cpu.fpu.st(i) / s); _ = cpu.fpu.pop(); },
                    7 => { const s = cpu.fpu.st(i); if (s != 0) cpu.fpu.setSt(i, cpu.fpu.st(0) / s); _ = cpu.fpu.pop(); },
                    else => {},
                }
            }
        },
        0xDF => {
            if (is_mem) {
                if (mem_addr) |addr| {
                    switch (reg) {
                        0 => cpu.fpu.push(@floatFromInt(@as(i16, @bitCast(cpu.memory.read16(addr))))), // FILD m16
                        2 => cpu.memory.write16(addr, @bitCast(safeFloatToInt(i16, cpu.fpu.st(0)))), // FIST m16
                        3 => { cpu.memory.write16(addr, @bitCast(safeFloatToInt(i16, cpu.fpu.st(0)))); _ = cpu.fpu.pop(); }, // FISTP
                        5 => { // FILD m64
                            const lo = cpu.memory.read32(addr);
                            const hi = cpu.memory.read32(addr +% 4);
                            cpu.fpu.push(@floatFromInt(@as(i64, @bitCast(@as(u64, hi) << 32 | lo))));
                        },
                        7 => { // FISTP m64
                            const bits: u64 = @bitCast(safeFloatToInt(i64, cpu.fpu.st(0)));
                            cpu.memory.write32(addr, @truncate(bits));
                            cpu.memory.write32(addr +% 4, @truncate(bits >> 32));
                            _ = cpu.fpu.pop();
                        },
                        else => {},
                    }
                }
            } else {
                if (reg == 4 and modrm.rm == 0) { // FNSTSW AX (DF E0)
                    cpu.eax = (cpu.eax & 0xFFFF0000) | cpu.fpu.getStatusWord();
                }
            }
        },
        else => {},
    }
}

/// Safe float-to-int conversion: saturates on overflow, returns 0 for NaN.
fn safeFloatToInt(comptime T: type, val: f64) T {
    const info = @typeInfo(T).int;
    if (val != val) return 0; // NaN
    if (info.signedness == .signed) {
        const min_f: f64 = @floatFromInt(std.math.minInt(T));
        const max_f: f64 = @floatFromInt(std.math.maxInt(T));
        if (val <= min_f) return std.math.minInt(T);
        if (val >= max_f) return std.math.maxInt(T);
    } else {
        if (val < 0) return 0;
        const max_f: f64 = @floatFromInt(std.math.maxInt(T));
        if (val >= max_f) return std.math.maxInt(T);
    }
    return @intFromFloat(val);
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

/// Apply a relative jump to EIP if the operand is .rel.
inline fn applyRel(cpu: *Cpu, operand: Operand) void {
    switch (operand) {
        .rel => |r| cpu.eip = cpu.eip +% @as(u32, @bitCast(r)),
        else => {},
    }
}

/// Dispatch and execute a single decoded instruction.
fn executeInsn(cpu: *Cpu, insn: *const Instruction, eip: u32) void {
    switch (insn.opcode) {
        // NOP
        0x90 => {},

        // HLT
        0xF4 => cpu.halted = true,

        // INT 3 (breakpoint — ignore)
        0xCC => {},

        // INT imm8
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
        0x88 => writeOperand8(cpu, insn, 0, @truncate(readOperand(cpu, insn, 1))),
        0x89 => writeOperand(cpu, insn, 0, readOperand(cpu, insn, 1)),
        0x8A => writeOperand8(cpu, insn, 0, @truncate(readOperand(cpu, insn, 1))),
        0x8B => writeOperand(cpu, insn, 0, readOperand(cpu, insn, 1)),

        // MOV r/m16, Sreg (8C)
        0x8C => {
            if (insn.modrm) |modrm| {
                const sreg_val: u32 = switch (@as(Segment, @enumFromInt(@as(u3, modrm.reg)))) {
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
            switch (insn.operands[1]) {
                .mem => |m| {
                    const addr = computeEffectiveAddress(cpu, &m);
                    if (insn.op_size == .word) {
                        cpu.setReg16(insn.modrm.?.reg, @truncate(addr));
                    } else {
                        cpu.setReg(@enumFromInt(insn.modrm.?.reg), addr);
                    }
                },
                else => {},
            }
        },

        // MOV Sreg, r/m16 (8E)
        0x8E => {
            if (insn.modrm) |modrm| {
                const val: u16 = @truncate(readOperand(cpu, insn, 1));
                switch (@as(Segment, @enumFromInt(@as(u3, modrm.reg)))) {
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
            const addr = readMemAddr(cpu, insn.operands[0]);
            cpu.setReg8(0, cpu.memory.read8(addr));
        },
        0xA1 => {
            const addr = readMemAddr(cpu, insn.operands[0]);
            if (insn.op_size == .word) {
                cpu.setReg16(0, cpu.memory.read16(addr));
            } else {
                cpu.eax = cpu.memory.read32(addr);
            }
        },
        0xA2 => {
            const addr = readMemAddr(cpu, insn.operands[1]);
            cpu.memory.write8(addr, cpu.getReg8(0));
        },
        0xA3 => {
            const addr = readMemAddr(cpu, insn.operands[1]);
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
            if (cpu.flags.toEflags() & flags_mod.FLAG_DF != 0) cpu.esi -%= 1 else cpu.esi +%= 1;
        },
        0xAD => { // LODSD
            cpu.eax = cpu.memory.read32(cpu.esi);
            if (cpu.flags.toEflags() & flags_mod.FLAG_DF != 0) cpu.esi -%= 4 else cpu.esi +%= 4;
        },
        0xA6, 0xA7 => { // CMPSB/CMPSD
            const sz: u32 = if (insn.opcode == 0xA6) 1 else 4;
            const os: OpSize = if (sz == 1) .byte else .dword;
            const df = cpu.flags.toEflags() & flags_mod.FLAG_DF != 0;
            if (insn.prefixes.rep or insn.prefixes.repne) {
                // REPZ CMPS: loop while ECX > 0 AND ZF=1 (bytes equal)
                // REPNZ CMPS: loop while ECX > 0 AND ZF=0 (bytes not equal)
                const stop_on_zf = insn.prefixes.repne; // REPNZ stops when ZF=1
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
                    const zf = cpu.flags.toEflags() & flags_mod.FLAG_ZF != 0;
                    if (stop_on_zf and zf) break;  // REPNZ: stop when equal
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
            const df = cpu.flags.toEflags() & flags_mod.FLAG_DF != 0;
            if (insn.prefixes.rep or insn.prefixes.repne) {
                // REPNZ SCAS: scan until AL/EAX matches [EDI] or ECX=0
                // REPZ SCAS: scan until AL/EAX differs from [EDI] or ECX=0
                const stop_on_zf = insn.prefixes.repne; // REPNZ stops when ZF=1
                while (cpu.ecx > 0) {
                    const a = if (sz == 1) @as(u32, cpu.getReg8(0)) else cpu.eax;
                    const b = if (sz == 1) @as(u32, cpu.memory.read8(cpu.edi)) else cpu.memory.read32(cpu.edi);
                    cpu.flags.update(.sub, os, a -% b, a, b);
                    cpu.ecx -= 1;
                    if (df) cpu.edi -%= sz else cpu.edi +%= sz;
                    const zf = cpu.flags.toEflags() & flags_mod.FLAG_ZF != 0;
                    if (stop_on_zf and zf) break;  // REPNZ: found match
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
            applyRel(cpu, insn.operands[0]);
        },

        // JMP rel32 (E9) / JMP rel8 (EB)
        0xE9, 0xEB => applyRel(cpu, insn.operands[0]),

        // Jcc short (70-7F)
        0x70...0x7F => {
            const cc: u4 = @truncate(insn.opcode);
            if (cpu.flags.evaluateCC(cc)) applyRel(cpu, insn.operands[0]);
        },

        // LOOP/LOOPcc/JECXZ (E0-E3)
        0xE0 => { // LOOPNE
            cpu.ecx -%= 1;
            if (cpu.ecx != 0 and !cpu.flags.getZF()) applyRel(cpu, insn.operands[0]);
        },
        0xE1 => { // LOOPE
            cpu.ecx -%= 1;
            if (cpu.ecx != 0 and cpu.flags.getZF()) applyRel(cpu, insn.operands[0]);
        },
        0xE2 => { // LOOP
            cpu.ecx -%= 1;
            if (cpu.ecx != 0) applyRel(cpu, insn.operands[0]);
        },
        0xE3 => { // JECXZ
            if (cpu.ecx == 0) applyRel(cpu, insn.operands[0]);
        },

        // Group 3: F6 (8-bit), F7 (32-bit)
        0xF6, 0xF7 => execGroup3(cpu, insn),

        // Group 5: FF
        0xFF => execGroup5(cpu, insn, eip),
        // Group 4: FE (INC/DEC r/m8)
        0xFE => {
            if (insn.modrm) |modrm| {
                const val = readOperand(cpu, insn, 0);
                if (modrm.reg == 0) { // INC
                    const result = val +% 1;
                    writeOperand8(cpu, insn, 0, @truncate(result));
                    cpu.flags.update(.inc, .byte, result, val, 1);
                } else if (modrm.reg == 1) { // DEC
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
            if (cpu.flags.evaluateCC(cc)) applyRel(cpu, insn.operands[0]);
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
            cpu.setReg(@enumFromInt(insn.modrm.?.reg), val);
        },
        // MOVZX r32, r/m16 (0F B7)
        0x0FB7 => {
            const val: u32 = readOperand(cpu, insn, 1) & 0xFFFF;
            cpu.setReg(@enumFromInt(insn.modrm.?.reg), val);
        },
        // MOVSX r32, r/m8 (0F BE)
        0x0FBE => {
            const val: u8 = @truncate(readOperand(cpu, insn, 1));
            cpu.setReg(@enumFromInt(insn.modrm.?.reg), cpu_mod.signExtend8to32(val));
        },
        // MOVSX r32, r/m16 (0F BF)
        0x0FBF => {
            const val: u16 = @truncate(readOperand(cpu, insn, 1));
            cpu.setReg(@enumFromInt(insn.modrm.?.reg), cpu_mod.signExtend16to32(val));
        },

        0x0FAF => {
            const a: i32 = @bitCast(cpu.getReg(@enumFromInt(insn.modrm.?.reg)));
            const b: i32 = @bitCast(readOperand(cpu, insn, 1));
            const result: i64 = @as(i64, a) * @as(i64, b);
            const r32: u32 = @truncate(@as(u64, @bitCast(result)));
            cpu.setReg(@enumFromInt(insn.modrm.?.reg), r32);
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
                cpu.setReg(@enumFromInt(insn.modrm.?.reg), val);
            }
        },

        // PUSH FS (0F A0) / POP FS (0F A1)
        0x0FA0 => cpu.push32(cpu.fs),
        0x0FA1 => cpu.fs = @truncate(cpu.pop32()),
        0x0FA8 => cpu.push32(cpu.gs),
        0x0FA9 => cpu.gs = @truncate(cpu.pop32()),

        // BSF (0F BC)
        0x0FBC => {
            const val = readOperand(cpu, insn, 1);
            if (val == 0) {
                cpu.flags.update(.logic, .dword, 0, 0, 0); // sets ZF
            } else {
                const bit: u32 = @ctz(val);
                cpu.setReg(@enumFromInt(insn.modrm.?.reg), bit);
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
                cpu.setReg(@enumFromInt(insn.modrm.?.reg), bit);
                cpu.flags.update(.logic, .dword, 1, 0, 0);
            }
        },

        // BT/BTS/BTR/BTC (0F A3/AB/B3/BB)
        0x0FA3, 0x0FAB, 0x0FB3, 0x0FBB => {
            if (insn.operands[0] == .mem) {
                // If base is memory and index is a register, indexing spans arbitrary bytes!
                const orig_addr = computeEffectiveAddress(cpu, &insn.operands[0].mem);
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
            cpu.setReg(@enumFromInt(insn.modrm.?.reg), r32);
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
            _ = cpu.pop32(); // skip ESP
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
            if (insn.modrm) |modrm| {
                const val = readOperand(cpu, insn, 0);
                const bit: u5 = @truncate(insn.imm);
                var ef = cpu.flags.toEflags();
                if ((val >> bit) & 1 != 0) ef |= flags_mod.FLAG_CF else ef &= ~flags_mod.FLAG_CF;
                cpu.flags.fromEflags(ef);
                switch (modrm.reg) {
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

        else => {
            log.err("x86: unimplemented opcode 0x{X:0>2} at 0x{X} (byte: 0x{X:0>2})", .{ insn.opcode, eip, if (insn.length > 0) cpu.memory.read8(eip) else 0 });
            cpu.halted = true;
        },
    }
}

// -----------------------------------------------------------------------
// Operand read/write helpers
// -----------------------------------------------------------------------

fn readOperand(cpu: *Cpu, insn: *const Instruction, idx: u1) u32 {
    const op = insn.operands[idx];
    return switch (op) {
        .reg => |r| if (insn.op_size == .byte) @as(u32, cpu.getReg8(r)) else cpu.getReg(@enumFromInt(r)),
        .mem => |m| blk: {
            const addr = computeEffectiveAddress(cpu, &m);
            break :blk switch (insn.op_size) {
                .byte => @as(u32, cpu.memory.read8(addr)),
                .word => @as(u32, cpu.memory.read16(addr)),
                .dword => cpu.memory.read32(addr),
            };
        },
        .imm => |v| v,
        .rel => |r| @bitCast(r),
        .none => 0,
    };
}

fn writeOperand(cpu: *Cpu, insn: *const Instruction, idx: u1, val: u32) void {
    const op = insn.operands[idx];
    switch (op) {
        .reg => |r| {
            if (insn.op_size == .word) {
                cpu.setReg16(r, @truncate(val));
            } else {
                cpu.setReg(@enumFromInt(r), val);
            }
        },
        .mem => |m| {
            const addr = computeEffectiveAddress(cpu, &m);
            switch (insn.op_size) {
                .byte => cpu.memory.write8(addr, @truncate(val)),
                .word => cpu.memory.write16(addr, @truncate(val)),
                .dword => cpu.memory.write32(addr, val),
            }
        },
        else => {},
    }
}

fn writeOperand8(cpu: *Cpu, insn: *const Instruction, idx: u1, val: u8) void {
    const op = insn.operands[idx];
    switch (op) {
        .reg => |r| cpu.setReg8(r, val),
        .mem => |m| {
            const addr = computeEffectiveAddress(cpu, &m);
            cpu.memory.write8(addr, val);
        },
        else => {},
    }
}

fn writeOperandSized(cpu: *Cpu, insn: *const Instruction, idx: u1, val: u32, size: OpSize) void {
    const op = insn.operands[idx];
    switch (op) {
        .reg => |r| {
            switch (size) {
                .byte => cpu.setReg8(r, @truncate(val)),
                .word => cpu.setReg16(r, @truncate(val)),
                .dword => cpu.setReg(@enumFromInt(r), val),
            }
        },
        .mem => |m| {
            const addr = computeEffectiveAddress(cpu, &m);
            switch (size) {
                .byte => cpu.memory.write8(addr, @truncate(val)),
                .word => cpu.memory.write16(addr, @truncate(val)),
                .dword => cpu.memory.write32(addr, val),
            }
        },
        else => {},
    }
}

fn readMemAddr(cpu: *const Cpu, op: Operand) u32 {
    return switch (op) {
        .mem => |m| computeEffectiveAddress(cpu, &m),
        else => 0,
    };
}

fn computeEffectiveAddress(cpu: *const Cpu, m: *const MemOperand) u32 {
    var addr: u32 = 0;
    if (m.base) |base| addr +%= cpu.getReg(@enumFromInt(base));
    if (m.index) |index| {
        const idx_val = cpu.getReg(@enumFromInt(index));
        addr +%= idx_val << m.scale;
    }
    addr +%= @bitCast(m.displacement);
    return cpu.resolveSegmentAddress(m.segment, addr);
}

// -----------------------------------------------------------------------
// ALU execution
// -----------------------------------------------------------------------

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

fn execGroup1(cpu: *Cpu, insn: *const Instruction) void {
    if (insn.modrm == null) return;
    const sub_op = insn.modrm.?.reg;
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

fn execGroup3(cpu: *Cpu, insn: *const Instruction) void {
    if (insn.modrm == null) return;
    const sub_op = insn.modrm.?.reg;
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
                cpu.setReg8(0, @truncate(dividend / v16)); // AL = quotient
                cpu.setReg8(4, @truncate(dividend % v16)); // AH = remainder
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

fn execGroup5(cpu: *Cpu, insn: *const Instruction, eip: u32) void {
    _ = eip;
    if (insn.modrm == null) return;
    const sub_op = insn.modrm.?.reg;
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

fn execShift(cpu: *Cpu, insn: *const Instruction) void {
    if (insn.modrm == null) return;
    const sub_op = insn.modrm.?.reg;
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

// String operations
fn execMovsb(cpu: *Cpu, insn: *const Instruction) void {
    const df = cpu.flags.toEflags() & flags_mod.FLAG_DF != 0;
    if (insn.prefixes.rep) {
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

fn execMovsd(cpu: *Cpu, insn: *const Instruction) void {
    const df = cpu.flags.toEflags() & flags_mod.FLAG_DF != 0;
    if (insn.prefixes.rep) {
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

fn execStosb(cpu: *Cpu, insn: *const Instruction) void {
    const df = cpu.flags.toEflags() & flags_mod.FLAG_DF != 0;
    const val = cpu.getReg8(0);
    if (insn.prefixes.rep) {
        while (cpu.ecx > 0) : (cpu.ecx -= 1) {
            cpu.memory.write8(cpu.edi, val);
            if (df) cpu.edi -%= 1 else cpu.edi +%= 1;
        }
    } else {
        cpu.memory.write8(cpu.edi, val);
        if (df) cpu.edi -%= 1 else cpu.edi +%= 1;
    }
}

fn execStosd(cpu: *Cpu, insn: *const Instruction) void {
    const df = cpu.flags.toEflags() & flags_mod.FLAG_DF != 0;
    if (insn.prefixes.rep) {
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
    mem[0] = 0x50; // PUSH EAX
    mem[1] = 0x5B; // POP EBX
    mem[2] = 0xF4; // HLT

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
