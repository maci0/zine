//! JIT instruction translation helpers.
//! Factored out of compiler.zig to keep individual files manageable.

const std = @import("std");
const wasm = @import("wasm.zig");
const emitter = @import("emitter.zig");
const decoder = @import("../x86/decoder.zig");
const cpu_mod = @import("../x86/cpu.zig");

const Body = emitter.Buffer;

/// Carry Flag (CF) local variable index.
pub const LOCAL_CF: u32 = 8;
/// Zero Flag (ZF) local variable index.
pub const LOCAL_ZF: u32 = 9;
/// Sign Flag (SF) local variable index.
pub const LOCAL_SF: u32 = 10;
/// Overflow Flag (OF) local variable index.
pub const LOCAL_OF: u32 = 11;
/// Scratch local variable index.
pub const LOCAL_SCRATCH: u32 = 12;
/// Direction Flag (DF) local variable index.
pub const LOCAL_DF: u32 = 13;
/// Parity Flag (PF) local variable index.
pub const LOCAL_PF: u32 = 14;
/// Memory base local variable index.
pub const LOCAL_MEM_BASE: u32 = 15;
/// FS segment base local variable index.
pub const LOCAL_FS_BASE: u32 = 16;
/// Scratch local 2 (ALU operand A for CF/OF computation).
pub const LOCAL_SCRATCH2: u32 = 17;
/// Scratch local 3 (ALU operand B for CF/OF computation).
pub const LOCAL_SCRATCH3: u32 = 18;
/// Total number of local variables.
pub const LOCAL_COUNT: u32 = 19;

/// EAX register index.
pub const REG_EAX: u32 = 0;
/// ECX register index.
pub const REG_ECX: u32 = 1;
/// EDX register index.
pub const REG_EDX: u32 = 2;
/// ESP register index.
pub const REG_ESP: u32 = 4;
/// EBP register index.
pub const REG_EBP: u32 = 5;
/// ESI register index.
pub const REG_ESI: u32 = 6;
/// EDI register index.
pub const REG_EDI: u32 = 7;

/// Emit code to push the effective address of a memory operand onto the Wasm stack.
pub fn emitEffectiveAddress(body: *Body, insn: *const decoder.Instruction, idx: u1) !void {
    const kind = if (idx == 0) insn.op0_kind else insn.op1_kind;
    if (kind == .mem) {
        var has_value = false;
        if (insn.mem_base != 0xF) {
            try body.appendOpcode(.local_get);
            try body.appendUleb128(@as(u3, @truncate(insn.mem_base)));
            has_value = true;
        }
        if (insn.mem_index != 0xF) {
            try body.appendOpcode(.local_get);
            try body.appendUleb128(@as(u3, @truncate(insn.mem_index)));
            if (insn.mem_scale > 0) {
                try body.appendOpcode(.i32_const);
                try body.appendUleb128(@as(u32, 1) << insn.mem_scale);
                try body.appendOpcode(.i32_mul);
            }
            if (has_value) {
                try body.appendOpcode(.i32_add);
            } else {
                has_value = true;
            }
        }
        if (insn.mem_disp != 0) {
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(insn.mem_disp);
            if (has_value) {
                try body.appendOpcode(.i32_add);
            } else {
                has_value = true;
            }
        }
        if (!has_value) {
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0);
        }
    } else {
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(0);
    }
}

/// Masks the value on top of the Wasm stack down to the operand size, so a
/// byte or word operand never sees the 32 bits above it (`or al, al` looks at
/// AL alone). A dword operand already holds the full 32 bits.
pub fn emitTruncateToSize(body: *Body, op_size: cpu_mod.OpSize) !void {
    switch (op_size) {
        .byte => {
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0xFF);
            try body.appendOpcode(.i32_and);
        },
        .word => {
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0xFFFF);
            try body.appendOpcode(.i32_and);
        },
        .dword => {},
    }
}

/// Load operand value onto Wasm stack.
pub fn emitLoadOperand(body: *Body, insn: *const decoder.Instruction, idx: u1) !void {
    const kind = if (idx == 0) insn.op0_kind else insn.op1_kind;
    const reg = if (idx == 0) insn.op0_reg else insn.op1_reg;
    switch (kind) {
        .reg => {
            if (insn.op_size == .byte and reg >= 4) {
                // AH/CH/DH/BH: byte at offset 8 of the base register local
                const base = reg - 4;
                try body.appendOpcode(.local_get);
                try body.appendUleb128(base);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(8);
                try body.appendOpcode(.i32_shr_u);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(0xFF);
                try body.appendOpcode(.i32_and);
            } else {
                try body.appendOpcode(.local_get);
                try body.appendUleb128(reg);
                // Byte/word register operands read only the low 8/16 bits
                // (e.g. `cmp al, [mem]` must not see the full EAX).
                try emitTruncateToSize(body, insn.op_size);
            }
        },
        .mem => {
            try emitEffectiveAddress(body, insn, idx);
            // FS-relative operand: add guest FS base (TEB) to the address.
            // Other segments are flat (base 0) in this emulator.
            if (insn.mem_seg == .fs) {
                try body.appendOpcode(.local_get);
                try body.appendUleb128(LOCAL_FS_BASE);
                try body.appendOpcode(.i32_add);
            }
            // Translate guest VA to WASM linear memory address
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_MEM_BASE);
            try body.appendOpcode(.i32_add);
            switch (insn.op_size) {
                .byte => {
                    try body.appendOpcode(.i32_load8_u);
                    try body.appendUleb128(0);
                    try body.appendUleb128(0);
                },
                .word => {
                    try body.appendOpcode(.i32_load16_u);
                    try body.appendUleb128(1);
                    try body.appendUleb128(0);
                },
                .dword => {
                    try body.appendOpcode(.i32_load);
                    try body.appendUleb128(2);
                    try body.appendUleb128(0);
                },
            }
        },
        .imm, .rel => {
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
        },
        .none => {
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0);
        },
    }
}

/// Store value from Wasm stack to operand destination.
pub fn emitStoreOperand(body: *Body, insn: *const decoder.Instruction, idx: u1) !void {
    const kind = if (idx == 0) insn.op0_kind else insn.op1_kind;
    const reg = if (idx == 0) insn.op0_reg else insn.op1_reg;
    switch (kind) {
        .reg => {
            // Byte/word register stores must preserve the untouched upper
            // bits (x86: `mov al, x` leaves AH/upper EAX intact). Merge the
            // low 8/16 bits into the 32-bit register local.
            switch (insn.op_size) {
                .byte => {
                    // Mask value to 8 bits first
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(0xFF);
                    try body.appendOpcode(.i32_and);
                    if (reg < 4) {
                        // AL/CL/DL/BL: replace low byte
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(reg);
                        try body.appendOpcode(.i32_const);
                        try body.appendIleb128(@as(i32, @bitCast(@as(u32, 0xFFFFFF00))));
                        try body.appendOpcode(.i32_and);
                        try body.appendOpcode(.i32_or);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(reg);
                    } else {
                        // AH/CH/DH/BH: replace byte at offset 8 of base reg
                        const base = reg - 4;
                        try body.appendOpcode(.i32_const);
                        try body.appendIleb128(8);
                        try body.appendOpcode(.i32_shl);
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(base);
                        try body.appendOpcode(.i32_const);
                        try body.appendIleb128(@as(i32, @bitCast(@as(u32, 0xFFFF00FF))));
                        try body.appendOpcode(.i32_and);
                        try body.appendOpcode(.i32_or);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(base);
                    }
                },
                .word => {
                    // Mask value to 16 bits, merge low 16, preserve upper 16
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(0xFFFF);
                    try body.appendOpcode(.i32_and);
                    try body.appendOpcode(.local_get);
                    try body.appendUleb128(reg);
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(@as(i32, @bitCast(@as(u32, 0xFFFF0000))));
                    try body.appendOpcode(.i32_and);
                    try body.appendOpcode(.i32_or);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(reg);
                },
                .dword => {
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(reg);
                },
            }
        },
        .mem => {
            // Value is on stack. We need address below it.
            // Save value to scratch, push addr + mem_base, push value back, store.
            try body.appendOpcode(.local_set);
            try body.appendUleb128(LOCAL_SCRATCH);
            try emitEffectiveAddress(body, insn, idx);
            // FS-relative operand: add guest FS base (TEB) to the address.
            if (insn.mem_seg == .fs) {
                try body.appendOpcode(.local_get);
                try body.appendUleb128(LOCAL_FS_BASE);
                try body.appendOpcode(.i32_add);
            }
            // Translate guest VA to WASM linear memory address
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_MEM_BASE);
            try body.appendOpcode(.i32_add);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SCRATCH);
            switch (insn.op_size) {
                .byte => {
                    try body.appendOpcode(.i32_store8);
                    try body.appendUleb128(0);
                    try body.appendUleb128(0);
                },
                .word => {
                    try body.appendOpcode(.i32_store16);
                    try body.appendUleb128(1);
                    try body.appendUleb128(0);
                },
                .dword => {
                    try body.appendOpcode(.i32_store);
                    try body.appendUleb128(2);
                    try body.appendUleb128(0);
                },
            }
        },
        else => {},
    }
}

/// Emit ZF and SF computation from the value currently on the Wasm stack.
/// Consumes the value (drops it after computing flags).
/// The value is truncated to `op_size` here (byte/word masked with
/// `and 0xFF` / `and 0xFFFF`) so ZF/SF reflect the truncated result —
/// e.g. `cmp bl, imm` sets SF from bit 7, not from the zero-extended
/// 32-bit value (`0xAD` is +173 as u32 but bit 7 set => SF=1).
pub fn emitUpdateZfSf(body: *Body, op_size: cpu_mod.OpSize) !void {
    // tee to scratch for reuse
    try body.appendOpcode(.local_tee);
    try body.appendUleb128(LOCAL_SCRATCH);
    // Truncate to the operand size (dword is already full 32-bit).
    try emitTruncateToSize(body, op_size);
    // Store the truncated result back so SF reads the masked value.
    try body.appendOpcode(.local_set);
    try body.appendUleb128(LOCAL_SCRATCH);
    // ZF = (result == 0)
    try body.appendOpcode(.local_get);
    try body.appendUleb128(LOCAL_SCRATCH);
    try body.appendOpcode(.i32_eqz);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(LOCAL_ZF);
    // SF = sign bit of the truncated result
    //   byte:  bit 7  -> value > 0x7F
    //   word:  bit 15 -> value > 0x7FFF
    //   dword: bit 31 -> value < 0 (signed)
    switch (op_size) {
        .byte => {
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SCRATCH);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0x7F);
            try body.appendOpcode(.i32_gt_u);
        },
        .word => {
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SCRATCH);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0x7FFF);
            try body.appendOpcode(.i32_gt_u);
        },
        .dword => {
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SCRATCH);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0);
            try body.appendOpcode(.i32_lt_s);
        },
    }
    try body.appendOpcode(.local_set);
    try body.appendUleb128(LOCAL_SF);
}

/// Emit CF=0, OF=0 (for logic ops like AND, OR, XOR, TEST).
pub fn emitClearCfOf(body: *Body) !void {
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(0);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(LOCAL_CF);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(0);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(LOCAL_OF);
}

/// Emit the sign bit (0 or 1) of a local, masked to the instruction's operand size.
fn emitSignOfLocal(body: *Body, insn: *const decoder.Instruction, local: u32) !void {
    try body.appendOpcode(.local_get);
    try body.appendUleb128(local);
    const bits: u6 = switch (insn.op_size) {
        .byte => 8,
        .word => 16,
        .dword => 32,
    };
    if (bits == 8) {
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(0xFF);
        try body.appendOpcode(.i32_and);
    } else if (bits == 16) {
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(0xFFFF);
        try body.appendOpcode(.i32_and);
    }
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(@as(i32, @intCast(bits - 1)));
    try body.appendOpcode(.i32_shr_u);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(1);
    try body.appendOpcode(.i32_and);
}

/// Emit CF and OF for an add-style op (ADD, ADC).
/// Operand A in dest_local, operand B in src_local; result in LOCAL_SCRATCH.
/// CF = carry out; OF = (signA == signB) && (signR != signA).
pub fn emitAddCfOf(body: *Body, insn: *const decoder.Instruction, dest_local: u32, src_local: u32) !void {
    // CF: for dword, carry out = (result < A) unsigned. For byte/word the
    // zero-extended operands make the wasm add exact, so CF = result > max.
    switch (insn.op_size) {
        .byte => {
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SCRATCH);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0xFF);
            try body.appendOpcode(.i32_gt_u);
        },
        .word => {
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SCRATCH);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0xFFFF);
            try body.appendOpcode(.i32_gt_u);
        },
        .dword => {
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SCRATCH);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(dest_local);
            try body.appendOpcode(.i32_lt_u);
        },
    }
    try body.appendOpcode(.local_set);
    try body.appendUleb128(LOCAL_CF);

    // OF = (signA == signB) && (signR != signA)
    try emitSignOfLocal(body, insn, dest_local);
    try emitSignOfLocal(body, insn, src_local);
    try body.appendOpcode(.i32_eq);
    try emitSignOfLocal(body, insn, LOCAL_SCRATCH);
    try emitSignOfLocal(body, insn, dest_local);
    try body.appendOpcode(.i32_ne);
    try body.appendOpcode(.i32_and);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(LOCAL_OF);
}

/// Emit CF and OF for a subtract-style op (SUB, SBB, CMP).
/// Operand A in dest_local, operand B in src_local; result in LOCAL_SCRATCH.
/// CF = borrow (A < B unsigned); OF = (signA != signB) && (signR != signA).
pub fn emitSubCfOf(body: *Body, insn: *const decoder.Instruction, dest_local: u32, src_local: u32) !void {
    // CF = A < B (unsigned borrow)
    try body.appendOpcode(.local_get);
    try body.appendUleb128(dest_local);
    try body.appendOpcode(.local_get);
    try body.appendUleb128(src_local);
    try body.appendOpcode(.i32_lt_u);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(LOCAL_CF);

    // OF = (signA != signB) && (signR != signA)
    try emitSignOfLocal(body, insn, dest_local);
    try emitSignOfLocal(body, insn, src_local);
    try body.appendOpcode(.i32_ne);
    try emitSignOfLocal(body, insn, LOCAL_SCRATCH);
    try emitSignOfLocal(body, insn, dest_local);
    try body.appendOpcode(.i32_ne);
    try body.appendOpcode(.i32_and);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(LOCAL_OF);
}

/// Emit a Jcc condition check. Pushes 0 or 1 onto the Wasm stack.
pub fn emitConditionCode(body: *Body, cc: u4) !void {
    switch (cc) {
        0x0 => { // JO: OF=1
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_OF);
        },
        0x1 => { // JNO: OF=0
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_OF);
            try body.appendOpcode(.i32_eqz);
        },
        0x2 => { // JB: CF=1
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_CF);
        },
        0x3 => { // JNB: CF=0
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_CF);
            try body.appendOpcode(.i32_eqz);
        },
        0x4 => { // JZ: ZF=1
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_ZF);
        },
        0x5 => { // JNZ: ZF=0
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_ZF);
            try body.appendOpcode(.i32_eqz);
        },
        0x6 => { // JBE: CF=1 OR ZF=1
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_CF);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_ZF);
            try body.appendOpcode(.i32_or);
        },
        0x7 => { // JA: CF=0 AND ZF=0
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_CF);
            try body.appendOpcode(.i32_eqz);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_ZF);
            try body.appendOpcode(.i32_eqz);
            try body.appendOpcode(.i32_and);
        },
        0x8 => { // JS: SF=1
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SF);
        },
        0x9 => { // JNS: SF=0
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SF);
            try body.appendOpcode(.i32_eqz);
        },
        0xA => { // JP: PF=1
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_PF);
        },
        0xB => { // JNP: PF=0
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_PF);
            try body.appendOpcode(.i32_eqz);
        },
        0xC => { // JL: SF!=OF
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SF);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_OF);
            try body.appendOpcode(.i32_ne);
        },
        0xD => { // JGE: SF==OF
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SF);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_OF);
            try body.appendOpcode(.i32_eq);
        },
        0xE => { // JLE: ZF=1 OR SF!=OF
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_ZF);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SF);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_OF);
            try body.appendOpcode(.i32_ne);
            try body.appendOpcode(.i32_or);
        },
        0xF => { // JG: ZF=0 AND SF==OF
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_ZF);
            try body.appendOpcode(.i32_eqz);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_SF);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(LOCAL_OF);
            try body.appendOpcode(.i32_eq);
            try body.appendOpcode(.i32_and);
        },
    }
}

/// Get the Wasm ALU opcode for an x86 ALU group.
pub fn aluGroupToWasmOp(group: u3) ?wasm.Opcode {
    return switch (group) {
        0 => .i32_add, // ADD
        1 => .i32_or, // OR
        2 => .i32_add, // ADC (add, carry handled separately)
        3 => .i32_sub, // SBB (sub, carry handled separately)
        4 => .i32_and, // AND
        5 => .i32_sub, // SUB
        6 => .i32_xor, // XOR
        7 => .i32_sub, // CMP (sub, don't store)
    };
}

/// Emit PUSH: decrement ESP, store value at [ESP + mem_base].
/// Value must already be on the Wasm stack.
pub fn emitPush32(body: *Body) !void {
    try body.appendOpcode(.local_set);
    try body.appendUleb128(LOCAL_SCRATCH);
    // ESP -= 4
    try body.appendOpcode(.local_get);
    try body.appendUleb128(REG_ESP);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(4);
    try body.appendOpcode(.i32_sub);
    try body.appendOpcode(.local_tee);
    try body.appendUleb128(REG_ESP);
    // Translate guest VA to WASM linear memory address
    try body.appendOpcode(.local_get);
    try body.appendUleb128(LOCAL_MEM_BASE);
    try body.appendOpcode(.i32_add);
    // store [ESP + mem_base] = value
    try body.appendOpcode(.local_get);
    try body.appendUleb128(LOCAL_SCRATCH);
    try body.appendOpcode(.i32_store);
    try body.appendUleb128(2);
    try body.appendUleb128(0);
}

/// Emit POP: load from [ESP + mem_base], increment ESP. Result on Wasm stack.
pub fn emitPop32(body: *Body) !void {
    try body.appendOpcode(.local_get);
    try body.appendUleb128(REG_ESP);
    // Translate guest VA to WASM linear memory address
    try body.appendOpcode(.local_get);
    try body.appendUleb128(LOCAL_MEM_BASE);
    try body.appendOpcode(.i32_add);
    try body.appendOpcode(.i32_load);
    try body.appendUleb128(2);
    try body.appendUleb128(0);
    // ESP += 4
    try body.appendOpcode(.local_get);
    try body.appendUleb128(REG_ESP);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(4);
    try body.appendOpcode(.i32_add);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(REG_ESP);
}

// --- tests ---
//
// These assert the exact instruction stream each helper emits, not merely
// that some plausible opcode is present: a substring search over a function
// body also matches immediates and local indices, so it cannot tell
// `i32_sub` the operation from `i32_sub` the byte 0x6B in a displacement.

const Token = struct {
    op: u8,
    /// Local index following a `local.get`/`local.set`/`local.tee` opcode.
    arg: ?u8 = null,
};

fn token(op: wasm.Opcode) Token {
    return .{ .op = @intFromEnum(op) };
}

fn localToken(op: wasm.Opcode, index: u32) Token {
    return .{ .op = @intFromEnum(op), .arg = @intCast(index) };
}

/// Split an emitted body into one token per opcode, dropping the immediates of
/// `i32.const` and the local index of the local.* opcodes so a constant or a
/// local number cannot be mistaken for an operation.
fn decodeTokens(bytes: []const u8, out: *std.ArrayListUnmanaged(Token)) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const op = bytes[i];
        i += 1;
        if (op == @intFromEnum(wasm.Opcode.i32_const)) {
            // Skip the ILEB128 immediate: a byte whose bit 6 is set is the
            // last one, because bit 6 is the sign bit.
            while (true) {
                if (i >= bytes.len) return error.TestUnexpectedResult;
                const byte = bytes[i];
                i += 1;
                if (byte & 0x80 == 0 or byte & 0x40 != 0) break;
            }
            try out.append(std.testing.allocator, .{ .op = op });
        } else if (op == @intFromEnum(wasm.Opcode.i32_load) or
            op == @intFromEnum(wasm.Opcode.i32_store) or
            op == @intFromEnum(wasm.Opcode.i32_load8_u) or
            op == @intFromEnum(wasm.Opcode.i32_load16_u))
        {
            // Skip the two ULEB128 alignment and offset immediates.
            if (i + 1 >= bytes.len) return error.TestUnexpectedResult;
            if (bytes[i] > 0x7F or bytes[i + 1] > 0x7F) return error.TestUnexpectedResult;
            i += 2;
            try out.append(std.testing.allocator, .{ .op = op });
        } else if (op == @intFromEnum(wasm.Opcode.local_get) or
            op == @intFromEnum(wasm.Opcode.local_set) or
            op == @intFromEnum(wasm.Opcode.local_tee))
        {
            if (i >= bytes.len or bytes[i] > 0x7F) return error.TestUnexpectedResult;
            try out.append(std.testing.allocator, .{ .op = op, .arg = bytes[i] });
            i += 1;
        } else {
            try out.append(std.testing.allocator, .{ .op = op });
        }
    }
}

fn expectTokens(expected: []const Token, bytes: []const u8) !void {
    var actual: std.ArrayListUnmanaged(Token) = .empty;
    defer actual.deinit(std.testing.allocator);
    try decodeTokens(bytes, &actual);
    try std.testing.expectEqualSlices(Token, expected, actual.items);
}

test "every ALU group maps to the x86 operation it stands for" {
    const table = [_]struct { group: u3, op: wasm.Opcode }{
        .{ .group = 0, .op = .i32_add }, // ADD
        .{ .group = 1, .op = .i32_or }, // OR
        .{ .group = 2, .op = .i32_add }, // ADC (carry in added separately)
        .{ .group = 3, .op = .i32_sub }, // SBB (borrow in subtracted separately)
        .{ .group = 4, .op = .i32_and }, // AND
        .{ .group = 5, .op = .i32_sub }, // SUB
        .{ .group = 6, .op = .i32_xor }, // XOR
        .{ .group = 7, .op = .i32_sub }, // CMP (result discarded)
    };
    for (table) |entry| {
        try std.testing.expectEqual(entry.op, aluGroupToWasmOp(entry.group).?);
    }
    // u3 is fully covered by the table, so no group may return null.
    for (0..8) |group| {
        _ = aluGroupToWasmOp(@intCast(group)) orelse return error.TestUnexpectedResult;
    }
}

test "effective address emits base, scaled index, and displacement" {
    const insn: decoder.Instruction = .{
        .op0_kind = .mem,
        .mem_base = REG_EAX + 1, // EBX
        .mem_index = REG_EAX, // EAX
        .mem_scale = 2, // *4
        .mem_disp = 0x10,
    };
    var body: Body = .init(std.testing.allocator);
    defer body.deinit();
    try emitEffectiveAddress(&body, &insn, 0);
    try expectTokens(&.{
        localToken(.local_get, REG_EAX + 1),
        localToken(.local_get, REG_EAX),
        token(.i32_const),
        token(.i32_mul),
        token(.i32_add),
        token(.i32_const),
        token(.i32_add),
    }, body.bytes.items);
    // The scale constant and the displacement, not just their opcodes.
    try expectConstAt(body.bytes.items, 0, &.{4});
    try expectConstAt(body.bytes.items, 1, &.{0x10});
}
test "effective address with no base, index, or displacement is address 0" {
    const insn: decoder.Instruction = .{ .op0_kind = .mem };
    var body: Body = .init(std.testing.allocator);
    defer body.deinit();
    try emitEffectiveAddress(&body, &insn, 0);
    try expectTokens(&.{token(.i32_const)}, body.bytes.items);
    try expectOnlyConst(body.bytes.items, 0);

    // Displacement alone is a constant offset, not base+disp. The negative
    // sign must survive the ILEB128 encoding, so the body carries 0x78 (-8)
    // and not 0x08.
    const disp_only: decoder.Instruction = .{ .op0_kind = .mem, .mem_disp = -8 };
    var disp_body: Body = .init(std.testing.allocator);
    defer disp_body.deinit();
    try emitEffectiveAddress(&disp_body, &disp_only, 0);
    try expectTokens(&.{token(.i32_const)}, disp_body.bytes.items);
    try expectOnlyConst(disp_body.bytes.items, 0x78);
}

test "effective address of a non-memory operand ignores the memory fields" {
    const insn: decoder.Instruction = .{
        .op0_kind = .reg,
        .op0_reg = REG_ESP,
        // Deliberate garbage: operand 0 is a register, so no addressing mode
        // fields apply and none of these may reach the output.
        .mem_base = REG_EBP,
        .mem_index = REG_ESI,
        .mem_scale = 3,
        .mem_disp = 0x40,
    };
    var body: Body = .init(std.testing.allocator);
    defer body.deinit();
    try emitEffectiveAddress(&body, &insn, 0);
    try expectTokens(&.{token(.i32_const)}, body.bytes.items);
}

/// Assert the `n`-th `i32.const` in an emitted body carries `expected` as its
/// immediate, comparing the encoded bytes rather than a decoded value.
fn expectConstAt(bytes: []const u8, n: usize, expected: []const u8) !void {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != @intFromEnum(wasm.Opcode.i32_const)) continue;
        if (seen == n) {
            try std.testing.expectEqualSlices(u8, expected, bytes[i + 1 .. i + 1 + expected.len]);
            return;
        }
        seen += 1;
    }
    return error.TestUnexpectedResult;
}

/// The whole body is a single `i32.const <v>`.
fn expectOnlyConst(bytes: []const u8, v: u8) !void {
    try std.testing.expectEqualSlices(u8, &.{ @intFromEnum(wasm.Opcode.i32_const), v }, bytes);
}

test "each Jcc condition reads exactly the flags its x86 encoding defines" {
    const G = struct {
        fn op(comptime o: wasm.Opcode) Token {
            return .{ .op = @intFromEnum(o) };
        }
        fn local(index: u32) Token {
            return .{ .op = @intFromEnum(wasm.Opcode.local_get), .arg = @intCast(index) };
        }
    };
    const table = [_]struct { cc: u4, expected: []const Token }{
        // cc encodes the condition directly: 0x8x tests a single flag, 0x4x
        // and 0xCx pair it with another.
        .{ .cc = 0x0, .expected = &.{G.local(LOCAL_OF)} }, // JO   OF
        .{ .cc = 0x1, .expected = &.{ G.local(LOCAL_OF), G.op(.i32_eqz) } }, // JNO
        .{ .cc = 0x2, .expected = &.{G.local(LOCAL_CF)} }, // JB   CF
        .{ .cc = 0x3, .expected = &.{ G.local(LOCAL_CF), G.op(.i32_eqz) } }, // JNB
        .{ .cc = 0x4, .expected = &.{G.local(LOCAL_ZF)} }, // JZ   ZF
        .{ .cc = 0x5, .expected = &.{ G.local(LOCAL_ZF), G.op(.i32_eqz) } }, // JNZ
        .{ .cc = 0x6, .expected = &.{ G.local(LOCAL_CF), G.local(LOCAL_ZF), G.op(.i32_or) } }, // JBE
        .{ .cc = 0x7, .expected = &.{ G.local(LOCAL_CF), G.op(.i32_eqz), G.local(LOCAL_ZF), G.op(.i32_eqz), G.op(.i32_and) } }, // JA
        .{ .cc = 0x8, .expected = &.{G.local(LOCAL_SF)} }, // JS   SF
        .{ .cc = 0x9, .expected = &.{ G.local(LOCAL_SF), G.op(.i32_eqz) } }, // JNS
        .{ .cc = 0xA, .expected = &.{G.local(LOCAL_PF)} }, // JP   PF
        .{ .cc = 0xB, .expected = &.{ G.local(LOCAL_PF), G.op(.i32_eqz) } }, // JNP
        .{ .cc = 0xC, .expected = &.{ G.local(LOCAL_SF), G.local(LOCAL_OF), G.op(.i32_ne) } }, // JL  SF!=OF
        .{ .cc = 0xD, .expected = &.{ G.local(LOCAL_SF), G.local(LOCAL_OF), G.op(.i32_eq) } }, // JGE SF==OF
        .{ .cc = 0xE, .expected = &.{ G.local(LOCAL_ZF), G.local(LOCAL_SF), G.local(LOCAL_OF), G.op(.i32_ne), G.op(.i32_or) } }, // JLE
        .{ .cc = 0xF, .expected = &.{ G.local(LOCAL_ZF), G.op(.i32_eqz), G.local(LOCAL_SF), G.local(LOCAL_OF), G.op(.i32_eq), G.op(.i32_and) } }, // JG
    };
    for (table) |entry| {
        var body: Body = .init(std.testing.allocator);
        defer body.deinit();
        try emitConditionCode(&body, entry.cc);
        try expectTokens(entry.expected, body.bytes.items);
    }
}

test "PUSH stores at the decremented ESP and POP loads from the old one" {
    var push_body: Body = .init(std.testing.allocator);
    defer push_body.deinit();
    try emitPush32(&push_body);
    // value -> scratch; ESP = ESP-4; address = ESP+mem_base; store
    try expectTokens(&.{
        localToken(.local_set, LOCAL_SCRATCH),
        localToken(.local_get, REG_ESP),
        token(.i32_const),
        token(.i32_sub),
        localToken(.local_tee, REG_ESP),
        localToken(.local_get, LOCAL_MEM_BASE),
        token(.i32_add),
        localToken(.local_get, LOCAL_SCRATCH),
        token(.i32_store),
    }, push_body.bytes.items);
    // The decrement is 4 bytes and the store is 4-byte aligned at offset 0.
    try expectConstAt(push_body.bytes.items, 0, &.{4});
    try std.testing.expectEqualSlices(
        u8,
        &.{ @intFromEnum(wasm.Opcode.i32_store), 2, 0 },
        push_body.bytes.items[push_body.bytes.items.len - 3 ..],
    );

    var pop_body: Body = .init(std.testing.allocator);
    defer pop_body.deinit();
    try emitPop32(&pop_body);
    // load [ESP+mem_base] first, then bump ESP, so the result is the old top.
    try expectTokens(&.{
        localToken(.local_get, REG_ESP),
        localToken(.local_get, LOCAL_MEM_BASE),
        token(.i32_add),
        token(.i32_load),
        localToken(.local_get, REG_ESP),
        token(.i32_const),
        token(.i32_add),
        localToken(.local_set, REG_ESP),
    }, pop_body.bytes.items);
    try expectConstAt(pop_body.bytes.items, 0, &.{4});
}

test "logic ops clear CF and OF to zero" {
    var body: Body = .init(std.testing.allocator);
    defer body.deinit();
    try emitClearCfOf(&body);
    try expectTokens(&.{
        token(.i32_const),
        localToken(.local_set, LOCAL_CF),
        token(.i32_const),
        localToken(.local_set, LOCAL_OF),
    }, body.bytes.items);
    // Both stored values must be literal 0, not "whatever the stack held".
    try expectConstAt(body.bytes.items, 0, &.{0});
    try expectConstAt(body.bytes.items, 1, &.{0});
}
