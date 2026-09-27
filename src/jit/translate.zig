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
                switch (insn.op_size) {
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
