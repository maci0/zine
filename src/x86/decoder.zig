//! x86 instruction decoder for the software interpreter.
//!
//! This module decodes variable-length x86 instructions from a byte stream
//! into a compact, flat Instruction struct (~28 bytes). It correctly handles:
//! - Instruction prefixes (segment overrides, size overrides, repeats)
//! - ModR/M and SIB addressing byte fields
//! - Displacements and immediate operands
//! - Relative offsets for branch instructions
//!
//! The Instruction struct uses a flat layout (OpKind enum + register/memory
//! fields) instead of tagged unions, inspired by Blink's packed RDE format.
//! This halves the struct size vs. the previous design, improving decode
//! cache utilization.
//!
//! The decoder is designed as a standalone component used by the x86
//! execution engine (`execute.zig`) and cached by `decode_cache.zig`.

const cpu_mod = @import("cpu.zig");
const Segment = cpu_mod.Segment;

/// Operand kind tag — eliminates tagged-union overhead.
pub const OpKind = enum(u3) {
    none = 0,
    reg = 1,
    mem = 2,
    imm = 3,
    rel = 4,
};

/// Compact decoded instruction (~28 bytes instead of ~52).
pub const Instruction = struct {
    opcode: u16 = 0,
    length: u8 = 0,
    op_size: cpu_mod.OpSize = .dword,

    // Operand layout (flat, eliminates tagged union overhead)
    op0_kind: OpKind = .none,
    op1_kind: OpKind = .none,
    op0_reg: u3 = 0,
    op1_reg: u3 = 0,

    // ModRM sub-opcode
    modrm_reg: u3 = 0,
    has_modrm: bool = false,

    // Prefix flags (inline, no separate struct)
    seg_override: ?Segment = null,
    operand_size_override: bool = false,
    rep: bool = false,
    repne: bool = false,
    lock: bool = false,

    // Immediate / relative value
    imm: u32 = 0,

    // Memory operand (at most one per x86 instruction)
    mem_seg: Segment = .ds,
    mem_base: u4 = 0xF, // 0-7 = register, 0xF = none
    mem_index: u4 = 0xF, // 0-7 = register, 0xF = none
    mem_scale: u2 = 0,
    mem_disp: i32 = 0,
};

/// ModR/M byte fields (private — used only in decodeModRM).
const ModRM = struct {
    mod: u2,
    reg: u3,
    rm: u3,
};

/// SIB byte fields (private — used only in decodeModRM).
const SIB = struct {
    scale: u2,
    index: u3,
    base: u3,
};

/// Decode one x86 instruction starting at `bytes`.
/// Returns the decoded instruction with its length.
pub fn decode(bytes: []const u8) Instruction {
    var insn = Instruction{};
    var pos: usize = 0;

    // --- Phase 1: Prefixes ---
    while (pos < bytes.len) {
        switch (bytes[pos]) {
            0xF0 => insn.lock = true,
            0xF2 => insn.repne = true,
            0xF3 => insn.rep = true,
            0x26 => insn.seg_override = .es,
            0x2E => insn.seg_override = .cs,
            0x36 => insn.seg_override = .ss,
            0x3E => insn.seg_override = .ds,
            0x64 => insn.seg_override = .fs,
            0x65 => insn.seg_override = .gs,
            0x66 => insn.operand_size_override = true,
            0x67 => {}, // address size override — tracked but not stored
            else => break,
        }
        pos += 1;
    }

    if (pos >= bytes.len) {
        insn.length = @intCast(pos);
        return insn;
    }

    // Effective operand size
    insn.op_size = if (insn.operand_size_override) .word else .dword;

    // --- Phase 2: Opcode ---
    var opcode_byte = bytes[pos];
    pos += 1;

    if (opcode_byte == 0x0F) {
        // Two-byte opcode
        if (pos >= bytes.len) {
            insn.length = @intCast(pos);
            return insn;
        }
        opcode_byte = bytes[pos];
        pos += 1;
        insn.opcode = 0x0F00 | @as(u16, opcode_byte);
    } else {
        insn.opcode = opcode_byte;
    }

    // --- Phase 3: Decode based on opcode ---
    // Many opcodes require ModR/M; decode it when needed.
    switch (insn.opcode) {
        // NOP
        0x90 => {},

        // INT 3
        0xCC => {},

        // INT imm8
        0xCD => {
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },

        // HLT
        0xF4 => {},

        // --- MOV reg, imm (B0-B7: 8-bit, B8-BF: 32/16-bit) ---
        0xB0...0xB7 => {
            const reg: u3 = @truncate(insn.opcode);
            insn.op0_kind = .reg;
            insn.op0_reg = reg;
            insn.op_size = .byte;
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                insn.op1_kind = .imm;
                pos += 1;
            }
        },
        0xB8...0xBF => {
            const reg: u3 = @truncate(insn.opcode);
            insn.op0_kind = .reg;
            insn.op0_reg = reg;
            pos = readImmOperand(bytes, pos, insn.op_size, &insn);
        },

        // POP r/m32 (8F /0) — e.g. POP DWORD PTR FS:[0] for SEH
        0x8F => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
        },

        // --- PUSH/POP reg (50-5F) ---
        0x50...0x57 => {
            insn.op0_kind = .reg;
            insn.op0_reg = @truncate(insn.opcode);
        },
        0x58...0x5F => {
            insn.op0_kind = .reg;
            insn.op0_reg = @truncate(insn.opcode);
        },

        // PUSH imm32/16
        0x68 => {
            pos = readImmOperand(bytes, pos, insn.op_size, &insn);
        },
        // PUSH imm8 (sign-extended)
        0x6A => {
            if (pos < bytes.len) {
                insn.imm = cpu_mod.signExtend8to32(bytes[pos]);
                insn.op0_kind = .imm;
                pos += 1;
            }
        },

        // --- ALU r/m, reg (8-bit) ---
        0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },
        // --- ALU r/m, reg (32/16-bit) ---
        0x01, 0x09, 0x11, 0x19, 0x21, 0x29, 0x31, 0x39 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },
        // --- ALU reg, r/m (8-bit) ---
        0x02, 0x0A, 0x12, 0x1A, 0x22, 0x2A, 0x32, 0x3A => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },
        // --- ALU reg, r/m (32/16-bit) ---
        0x03, 0x0B, 0x13, 0x1B, 0x23, 0x2B, 0x33, 0x3B => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },
        // --- ALU AL, imm8 ---
        0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C => {
            insn.op_size = .byte;
            insn.op0_kind = .reg;
            insn.op0_reg = 0; // AL
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                insn.op1_kind = .imm;
                pos += 1;
            }
        },
        // --- ALU EAX, imm32/16 ---
        0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D => {
            insn.op0_kind = .reg;
            insn.op0_reg = 0; // EAX
            pos = readImmOperand(bytes, pos, insn.op_size, &insn);
        },

        // --- INC/DEC reg (40-4F) ---
        0x40...0x4F => {
            insn.op0_kind = .reg;
            insn.op0_reg = @truncate(insn.opcode);
        },

        // --- Group 1: ALU r/m, imm (80-83) ---
        0x80 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        0x81 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            pos = readImmDirect(bytes, pos, insn.op_size, &insn);
        },
        0x83 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            if (pos < bytes.len) {
                insn.imm = cpu_mod.signExtend8to32(bytes[pos]);
                pos += 1;
            }
        },

        // TEST r/m8, reg8
        0x84 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },
        // TEST r/m32, reg32
        0x85 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },

        // XCHG r/m8, reg8
        0x86 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },
        // XCHG r/m32, reg32
        0x87 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },

        // --- MOV r/m, reg (88-8B) ---
        0x88 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },
        0x89 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },
        0x8A => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },
        0x8B => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // MOV r/m16, Sreg (8C) — segment register to r/m
        0x8C => {
            insn.op_size = .word;
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },

        // LEA reg, [mem]
        0x8D => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // MOV Sreg, r/m16 (8E) — r/m to segment register
        0x8E => {
            insn.op_size = .word;
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // XCHG EAX, reg (91-97)
        0x91...0x97 => {
            insn.op0_kind = .reg;
            insn.op0_reg = @truncate(insn.opcode);
        },

        // CBW/CWDE
        0x98 => {},
        // CDQ
        0x99 => {},

        // PUSHFD
        0x9C => {},
        // POPFD
        0x9D => {},

        // MOV AL, moffs8
        0xA0 => {
            insn.op_size = .byte;
            insn.op0_kind = .reg;
            insn.op0_reg = 0; // AL
            pos = readMoffs(bytes, pos, &insn);
        },
        // MOV EAX, moffs32
        0xA1 => {
            insn.op0_kind = .reg;
            insn.op0_reg = 0; // EAX
            pos = readMoffs(bytes, pos, &insn);
        },
        // MOV moffs8, AL
        0xA2 => {
            insn.op_size = .byte;
            pos = readMoffs(bytes, pos, &insn);
            // readMoffs set op0 to mem; swap: op1=mem, op0=AL
            insn.op1_kind = insn.op0_kind;
            insn.op1_reg = insn.op0_reg;
            insn.op0_kind = .reg;
            insn.op0_reg = 0; // AL (source for the store)
        },
        // MOV moffs32, EAX
        0xA3 => {
            pos = readMoffs(bytes, pos, &insn);
            // readMoffs set op0 to mem; swap: op1=mem, op0=EAX
            insn.op1_kind = insn.op0_kind;
            insn.op1_reg = insn.op0_reg;
            insn.op0_kind = .reg;
            insn.op0_reg = 0; // EAX
        },

        // TEST AL, imm8
        0xA8 => {
            insn.op_size = .byte;
            insn.op0_kind = .reg;
            insn.op0_reg = 0; // AL
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                insn.op1_kind = .imm;
                pos += 1;
            }
        },
        // TEST EAX, imm32
        0xA9 => {
            insn.op0_kind = .reg;
            insn.op0_reg = 0; // EAX
            pos = readImmOperand(bytes, pos, insn.op_size, &insn);
        },

        // RET
        0xC3 => {},
        // RET imm16
        0xC2 => {
            if (pos + 1 < bytes.len) {
                insn.imm = @as(u16, bytes[pos]) | (@as(u16, bytes[pos + 1]) << 8);
                pos += 2;
            }
        },

        // MOV r/m8, imm8 (C6 /0)
        0xC6 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        // MOV r/m32, imm32 (C7 /0)
        0xC7 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            pos = readImmDirect(bytes, pos, insn.op_size, &insn);
        },

        // LEAVE
        0xC9 => {},

        // --- Shift/Rotate Group 2 (D0-D3) ---
        // D0: r/m8, 1
        0xD0 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            insn.imm = 1;
        },
        // D1: r/m32, 1
        0xD1 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            insn.imm = 1;
        },
        // D2: r/m8, CL
        0xD2 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
        },
        // D3: r/m32, CL
        0xD3 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
        },

        // --- Shift/Rotate Group 2 (C0-C1): r/m, imm8 ---
        0xC0 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        0xC1 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },

        // CALL rel32/16
        0xE8 => {
            pos = readRelOperand(bytes, pos, insn.op_size, &insn);
        },
        // JMP rel32/16
        0xE9 => {
            pos = readRelOperand(bytes, pos, insn.op_size, &insn);
        },
        // JMP rel8
        0xEB => {
            if (pos < bytes.len) {
                const rel: i32 = @as(i32, @as(i8, @bitCast(bytes[pos])));
                insn.op0_kind = .rel;
                insn.imm = @bitCast(rel);
                pos += 1;
            }
        },

        // Jcc short (70-7F)
        0x70...0x7F => {
            if (pos < bytes.len) {
                const rel: i32 = @as(i32, @as(i8, @bitCast(bytes[pos])));
                insn.op0_kind = .rel;
                insn.imm = @bitCast(rel);
                pos += 1;
            }
        },

        // LOOP/LOOPcc/JECXZ (E0-E3)
        0xE0...0xE3 => {
            if (pos < bytes.len) {
                const rel: i32 = @as(i32, @as(i8, @bitCast(bytes[pos])));
                insn.op0_kind = .rel;
                insn.imm = @bitCast(rel);
                pos += 1;
            }
        },

        // Group 3: TEST/NOT/NEG/MUL/IMUL/DIV/IDIV (F6=8bit, F7=32bit)
        0xF6 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            // reg field determines the sub-operation
            if (insn.has_modrm) {
                if (insn.modrm_reg == 0 or insn.modrm_reg == 1) {
                    // TEST r/m8, imm8
                    if (pos < bytes.len) {
                        insn.imm = bytes[pos];
                        pos += 1;
                    }
                }
            }
        },
        0xF7 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            if (insn.has_modrm) {
                if (insn.modrm_reg == 0 or insn.modrm_reg == 1) {
                    // TEST r/m32, imm32
                    pos = readImmDirect(bytes, pos, insn.op_size, &insn);
                }
            }
        },

        // Group 5: INC/DEC/CALL/JMP/PUSH r/m (FF)
        0xFF => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
        },
        // Group 4: INC/DEC r/m8 (FE)
        0xFE => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
        },

        // CLC, STC, CLI, STI, CLD, STD
        0xF8 => {}, // CLC
        0xF9 => {}, // STC
        0xFA => {}, // CLI
        0xFB => {}, // STI
        0xFC => {}, // CLD
        0xFD => {}, // STD

        // --- Two-byte opcodes (0x0Fxx) ---

        // Jcc near (0F 80 - 0F 8F)
        0x0F80...0x0F8F => {
            pos = readRelOperand(bytes, pos, insn.op_size, &insn);
        },

        // SETcc (0F 90 - 0F 9F)
        0x0F90...0x0F9F => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
        },

        // MOVZX r32, r/m8 (0F B6)
        0x0FB6 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            insn.op_size = .byte; // source is byte
        },
        // MOVZX r32, r/m16 (0F B7)
        0x0FB7 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            insn.op_size = .word; // source is word
        },
        // MOVSX r32, r/m8 (0F BE)
        0x0FBE => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            insn.op_size = .byte;
        },
        // MOVSX r32, r/m16 (0F BF)
        0x0FBF => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            insn.op_size = .word;
        },

        // IMUL r32, r/m32 (0F AF)
        0x0FAF => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // CMOVcc (0F 40 - 0F 4F)
        0x0F40...0x0F4F => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // RDTSC (0F 31) — no operands
        0x0F31 => {},

        // PUSH FS (0F A0) / POP FS (0F A1)
        0x0FA0 => {},
        0x0FA1 => {},
        // CPUID (0F A2) — no operands
        0x0FA2 => {},
        // PUSH GS (0F A8) / POP GS (0F A9)
        0x0FA8 => {},
        0x0FA9 => {},

        // BSF (0F BC), BSR (0F BD)
        0x0FBC, 0x0FBD => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // BT (0F A3), BTS (0F AB), BTR (0F B3), BTC (0F BB)
        0x0FA3, 0x0FAB, 0x0FB3, 0x0FBB => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },

        // BSWAP (0F C8 - 0F CF)
        0x0FC8...0x0FCF => {
            insn.op0_kind = .reg;
            insn.op0_reg = @truncate(insn.opcode);
        },

        // SHLD r/m32, r32, imm8 (0F A4)
        0x0FA4 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        // SHLD r/m32, r32, CL (0F A5)
        0x0FA5 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },
        // SHRD r/m32, r32, imm8 (0F AC)
        0x0FAC => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        // SHRD r/m32, r32, CL (0F AD)
        0x0FAD => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },

        // IMUL r32, r/m32, imm32 (69)
        0x69 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            pos = readImmDirect(bytes, pos, insn.op_size, &insn);
        },
        // IMUL r32, r/m32, imm8 (6B)
        0x6B => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            if (pos < bytes.len) {
                insn.imm = cpu_mod.signExtend8to32(bytes[pos]);
                pos += 1;
            }
        },

        // XCHG EAX, EAX (already 0x90 = NOP above)

        // SAHF (9E) / LAHF (9F)
        0x9E => {},
        0x9F => {},

        // REP string ops and other string instructions
        // MOVSB/MOVSD (A4/A5), STOSB/STOSD (AA/AB), etc.
        0xA4, 0xA5, 0xA6, 0xA7, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF => {},

        // --- Legacy segment PUSH/POP (single-byte, no operands) ---
        0x06 => {}, // PUSH ES
        0x07 => {}, // POP ES
        0x0E => {}, // PUSH CS
        0x16 => {}, // PUSH SS
        0x17 => {}, // POP SS
        0x1E => {}, // PUSH DS
        0x1F => {}, // POP DS

        // --- BCD adjust (single-byte, no operands) ---
        0x27 => {}, // DAA
        0x2F => {}, // DAS
        0x37 => {}, // AAA
        0x3F => {}, // AAS

        // --- PUSHA/POPA (single-byte) ---
        0x60 => {}, // PUSHAD
        0x61 => {}, // POPAD

        // BOUND r32, m32&32 (has ModR/M)
        0x62 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // INS/OUTS string I/O (single-byte)
        0x6C => {}, // INSB
        0x6D => {}, // INSD
        0x6E => {}, // OUTSB
        0x6F => {}, // OUTSD

        // 0x82 — alias for 0x80 on x86 (ALU r/m8, imm8)
        0x82 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },

        // --- FPU instructions (D8-DF): all have ModR/M ---
        0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
        },

        // ENTER imm16, imm8 (C8)
        0xC8 => {
            if (pos + 2 < bytes.len) {
                insn.imm = @as(u32, bytes[pos]) | (@as(u32, bytes[pos + 1]) << 8);
                pos += 3; // imm16 + imm8
            }
        },

        // LES (C4) / LDS (C5) — have ModR/M
        0xC4 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },
        0xC5 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // IN/OUT (E4-E7): imm8 port
        0xE4 => {
            insn.op_size = .byte;
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        0xE5 => {
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        0xE6 => {
            insn.op_size = .byte;
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        0xE7 => {
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        // IN/OUT DX (EC-EF): single-byte
        0xEC, 0xED, 0xEE, 0xEF => {},

        // CMC (F5), WAIT/FWAIT (9B), INT1/ICEBP (F1)
        0xF5 => {},
        0x9B => {},
        0xF1 => {},

        // XLAT (D7)
        0xD7 => {},

        // AAM (D4 ib) / AAD (D5 ib)
        0xD4, 0xD5 => {
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },

        // --- Two-byte opcodes that appear in real binaries ---

        // NOP r/m32 (0F 1F — multi-byte NOP, has ModR/M)
        0x0F1F => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
        },
        // 0F 18-1E are also hint NOPs with ModR/M
        0x0F18, 0x0F19, 0x0F1A, 0x0F1B, 0x0F1C, 0x0F1D, 0x0F1E => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
        },

        // XADD (0F C0/C1)
        0x0FC0 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },
        0x0FC1 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },

        // CMPXCHG (0F B0/B1)
        0x0FB0 => {
            insn.op_size = .byte;
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },
        0x0FB1 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        },

        // BT/BTS/BTR/BTC imm8 form (0F BA /4..7)
        0x0FBA => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },

        // 0F 03 (LSL), 0F 02 (LAR) — have ModR/M
        0x0F02, 0x0F03 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // ============================================================
        // SSE / SSE2 / MMX opcodes
        // ============================================================

        // --- SSE/SSE2 data movement (0F 10-17) --- ModR/M reg_rm
        0x0F10 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // MOVUPS/MOVUPD/MOVSS/MOVSD
        0x0F11 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        }, // MOVUPS/MOVUPD/MOVSS/MOVSD store
        0x0F12 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // MOVLPS/MOVHLPS/MOVSLDUP/MOVDDUP
        0x0F13 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        }, // MOVLPS store
        0x0F14 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // UNPCKLPS/UNPCKLPD
        0x0F15 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // UNPCKHPS/UNPCKHPD
        0x0F16 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // MOVHPS/MOVLHPS/MOVSHDUP
        0x0F17 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        }, // MOVHPS store

        // --- SSE/SSE2 data movement (0F 28-2F) ---
        0x0F28 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // MOVAPS/MOVAPD
        0x0F29 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        }, // MOVAPS/MOVAPD store
        0x0F2A => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // CVTPI2PS/CVTSI2SS/CVTSI2SD
        0x0F2B => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        }, // MOVNTPS/MOVNTPD
        0x0F2C => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // CVTTPS2PI/CVTTSS2SI/CVTTSD2SI
        0x0F2D => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // CVTPS2PI/CVTSS2SI/CVTSD2SI
        0x0F2E => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // UCOMISS/UCOMISD
        0x0F2F => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // COMISS/COMISD

        // --- SSE/SSE2 arithmetic + logic (0F 50-6F) ---
        0x0F50 => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        }, // MOVMSKPS/MOVMSKPD
        0x0F51,
        0x0F52,
        0x0F53, // SQRTPS/SS/PD/SD, RSQRTPS/SS, RCPPS/SS
        0x0F54,
        0x0F55,
        0x0F56,
        0x0F57, // ANDPS/PD, ANDNPS/PD, ORPS/PD, XORPS/PD
        0x0F58,
        0x0F59,
        0x0F5A,
        0x0F5B, // ADDPS/SS/PD/SD, MULPS/SS/PD/SD, CVT...
        0x0F5C,
        0x0F5D,
        0x0F5E,
        0x0F5F, // SUBPS/SS/PD/SD, MINPS/SS/PD/SD, DIVPS/SS/PD/SD, MAXPS/SS/PD/SD
        => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // --- SSE/SSE2 integer SIMD (0F 60-6F) ---
        0x0F60,
        0x0F61,
        0x0F62,
        0x0F63, // PUNPCKLBW/WD/DQ, PACKSSWB
        0x0F64,
        0x0F65,
        0x0F66,
        0x0F67, // PCMPGTB/W/D, PACKUSWB
        0x0F68,
        0x0F69,
        0x0F6A,
        0x0F6B, // PUNPCKHBW/WD/DQ, PACKSSDW
        0x0F6C,
        0x0F6D, // PUNPCKLQDQ, PUNPCKHQDQ
        0x0F6E,
        0x0F6F, // MOVD, MOVQ/MOVDQA/MOVDQU
        => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // --- SSE/SSE2 integer SIMD + more (0F 70-7F) ---
        0x0F70 => { // PSHUFD/PSHUF[LH]W — ModR/M + imm8
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        0x0F71, 0x0F72, 0x0F73 => { // Group shifts (PSxxW/D/Q imm8) — ModR/M rm_only + imm8
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        0x0F74, 0x0F75, 0x0F76 => { // PCMPEQB/W/D — ModR/M reg_rm
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },
        0x0F77 => {}, // EMMS — no operands
        0x0F7E => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        }, // MOVD/MOVQ store
        0x0F7F => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        }, // MOVQ/MOVDQA/MOVDQU store

        // --- SSE/SSE2 compare + misc (0F C2-C6) ---
        0x0FC2 => { // CMPPS/SS/PD/SD — ModR/M reg_rm + imm8
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        0x0FC3 => {
            pos = decodeModRM(bytes, pos, &insn, .rm_reg);
        }, // MOVNTI
        0x0FC4 => { // PINSRW — ModR/M reg_rm + imm8
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        0x0FC5 => { // PEXTRW — ModR/M reg_rm + imm8
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        0x0FC6 => { // SHUFPS/SHUFPD — ModR/M reg_rm + imm8
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },

        // --- SSE/SSE2 integer ops (0F D0-FF) ---
        0x0FD0, // ADDSUBPD/ADDSUBPS (SSE3 stub)
        0x0FD1,
        0x0FD2,
        0x0FD3,
        0x0FD4,
        0x0FD5, // PSRLW, PSRLD, PSRLQ, PADDQ, PMULLW
        0x0FD6, // MOVQ store (66 prefix)
        0x0FD7, // PMOVMSKB
        0x0FD8,
        0x0FD9,
        0x0FDA,
        0x0FDB, // PSUBUSB/W, PMINUB, PAND
        0x0FDC,
        0x0FDD,
        0x0FDE,
        0x0FDF, // PADDUSB/W, PMAXUB, PANDN
        0x0FE0,
        0x0FE1,
        0x0FE2,
        0x0FE3, // PAVGB, PSRAW, PSRAD, PAVGW
        0x0FE4,
        0x0FE5,
        0x0FE6,
        0x0FE7, // PMULHUW, PMULHW, CVT..., MOVNTDQ
        0x0FE8,
        0x0FE9,
        0x0FEA,
        0x0FEB, // PSUBSB/W, PMINSW, POR
        0x0FEC,
        0x0FED,
        0x0FEE,
        0x0FEF, // PADDSB/W, PMAXSW, PXOR
        0x0FF0, // LDDQU (SSE3 stub)
        0x0FF1,
        0x0FF2,
        0x0FF3,
        0x0FF4,
        0x0FF5,
        0x0FF6,
        0x0FF7, // PSLLW-MASKMOVDQU
        0x0FF8,
        0x0FF9,
        0x0FFA,
        0x0FFB, // PSUBB/W/D/Q
        0x0FFC,
        0x0FFD,
        0x0FFE, // PADDB/W/D
        => {
            pos = decodeModRM(bytes, pos, &insn, .reg_rm);
        },

        // --- Group 15 (0F AE) — LDMXCSR, STMXCSR, LFENCE, MFENCE, SFENCE ---
        0x0FAE => {
            pos = decodeModRM(bytes, pos, &insn, .rm_only);
        },

        // Catch-all for unrecognized opcodes — we still record the length
        else => {},
    }

    insn.length = @intCast(pos);
    return insn;
}

// -----------------------------------------------------------------------
// Internal helpers
// -----------------------------------------------------------------------

/// Direction for ModRM decoding: which operand is reg, which is r/m.
const ModRMDir = enum {
    reg_rm, // op0=reg, op1=r/m
    rm_reg, // op0=r/m, op1=reg
    rm_only, // only op0=r/m, reg field is opcode extension
};

/// Decode ModR/M (and optionally SIB + displacement) from `bytes[pos..]`.
/// Populates insn flat fields.  Returns new position.
fn decodeModRM(bytes: []const u8, start_pos: usize, insn: *Instruction, dir: ModRMDir) usize {
    var pos = start_pos;
    if (pos >= bytes.len) return pos;

    const modrm_byte = bytes[pos];
    pos += 1;

    const modrm = ModRM{
        .mod = @truncate(modrm_byte >> 6),
        .reg = @truncate(modrm_byte >> 3),
        .rm = @truncate(modrm_byte),
    };
    insn.has_modrm = true;
    insn.modrm_reg = modrm.reg;

    // Default segment
    var seg = insn.seg_override orelse .ds;

    if (modrm.mod == 3) {
        // Register-register
        switch (dir) {
            .reg_rm => {
                insn.op0_kind = .reg;
                insn.op0_reg = modrm.reg;
                insn.op1_kind = .reg;
                insn.op1_reg = modrm.rm;
            },
            .rm_reg => {
                insn.op0_kind = .reg;
                insn.op0_reg = modrm.rm;
                insn.op1_kind = .reg;
                insn.op1_reg = modrm.reg;
            },
            .rm_only => {
                insn.op0_kind = .reg;
                insn.op0_reg = modrm.rm;
            },
        }
        return pos;
    }

    // Memory operand — store into insn.mem_* fields
    insn.mem_base = 0xF;
    insn.mem_index = 0xF;
    insn.mem_scale = 0;
    insn.mem_disp = 0;

    if (modrm.rm == 4) {
        // SIB byte follows
        if (pos >= bytes.len) return pos;
        const sib_byte = bytes[pos];
        pos += 1;

        const sib = SIB{
            .scale = @truncate(sib_byte >> 6),
            .index = @truncate(sib_byte >> 3),
            .base = @truncate(sib_byte),
        };

        if (sib.index != 4) {
            insn.mem_index = sib.index;
            insn.mem_scale = sib.scale;
        }

        if (modrm.mod == 0 and sib.base == 5) {
            // [disp32 + index*scale]
            pos = readDisp32(bytes, pos, &insn.mem_disp);
        } else {
            insn.mem_base = sib.base;
            // Use SS for ESP/EBP-based addressing
            if (sib.base == 4 or sib.base == 5) {
                if (insn.seg_override == null) seg = .ss;
            }
        }
    } else if (modrm.mod == 0 and modrm.rm == 5) {
        // [disp32]
        pos = readDisp32(bytes, pos, &insn.mem_disp);
    } else {
        insn.mem_base = modrm.rm;
        // Use SS for EBP/ESP-based addressing
        if (modrm.rm == 4 or modrm.rm == 5) {
            if (insn.seg_override == null) seg = .ss;
        }
    }

    // Displacement
    if (modrm.mod == 1) {
        // disp8 (sign-extended)
        if (pos < bytes.len) {
            insn.mem_disp = @as(i32, @as(i8, @bitCast(bytes[pos])));
            pos += 1;
        }
    } else if (modrm.mod == 2) {
        // disp32
        pos = readDisp32(bytes, pos, &insn.mem_disp);
    }

    insn.mem_seg = seg;

    switch (dir) {
        .reg_rm => {
            insn.op0_kind = .reg;
            insn.op0_reg = modrm.reg;
            insn.op1_kind = .mem;
        },
        .rm_reg => {
            insn.op0_kind = .mem;
            insn.op1_kind = .reg;
            insn.op1_reg = modrm.reg;
        },
        .rm_only => {
            insn.op0_kind = .mem;
        },
    }

    return pos;
}

/// Read a 32-bit displacement into disp.
fn readDisp32(bytes: []const u8, start_pos: usize, disp: *i32) usize {
    var pos = start_pos;
    if (pos + 3 < bytes.len) {
        const d: u32 = @as(u32, bytes[pos]) |
            (@as(u32, bytes[pos + 1]) << 8) |
            (@as(u32, bytes[pos + 2]) << 16) |
            (@as(u32, bytes[pos + 3]) << 24);
        disp.* = @bitCast(d);
        pos += 4;
    }
    return pos;
}

/// Read an immediate value and store in insn.imm; set insn.op1_kind = .imm.
fn readImmOperand(bytes: []const u8, start_pos: usize, op_size: cpu_mod.OpSize, insn: *Instruction) usize {
    var pos = start_pos;
    switch (op_size) {
        .byte => {
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                insn.op1_kind = .imm;
                pos += 1;
            }
        },
        .word => {
            if (pos + 1 < bytes.len) {
                insn.imm = @as(u32, bytes[pos]) | (@as(u32, bytes[pos + 1]) << 8);
                insn.op1_kind = .imm;
                pos += 2;
            }
        },
        .dword => {
            if (pos + 3 < bytes.len) {
                insn.imm = @as(u32, bytes[pos]) |
                    (@as(u32, bytes[pos + 1]) << 8) |
                    (@as(u32, bytes[pos + 2]) << 16) |
                    (@as(u32, bytes[pos + 3]) << 24);
                insn.op1_kind = .imm;
                pos += 4;
            }
        },
    }
    return pos;
}

/// Read an immediate value directly (without setting op1_kind).
fn readImmDirect(bytes: []const u8, start_pos: usize, op_size: cpu_mod.OpSize, insn: *Instruction) usize {
    var pos = start_pos;
    switch (op_size) {
        .byte => {
            if (pos < bytes.len) {
                insn.imm = bytes[pos];
                pos += 1;
            }
        },
        .word => {
            if (pos + 1 < bytes.len) {
                insn.imm = @as(u32, bytes[pos]) | (@as(u32, bytes[pos + 1]) << 8);
                pos += 2;
            }
        },
        .dword => {
            if (pos + 3 < bytes.len) {
                insn.imm = @as(u32, bytes[pos]) |
                    (@as(u32, bytes[pos + 1]) << 8) |
                    (@as(u32, bytes[pos + 2]) << 16) |
                    (@as(u32, bytes[pos + 3]) << 24);
                pos += 4;
            }
        },
    }
    return pos;
}

/// Read a relative offset (for CALL/JMP).
fn readRelOperand(bytes: []const u8, start_pos: usize, op_size: cpu_mod.OpSize, insn: *Instruction) usize {
    var pos = start_pos;
    switch (op_size) {
        .byte => {
            if (pos < bytes.len) {
                const rel: i32 = @as(i32, @as(i8, @bitCast(bytes[pos])));
                insn.op0_kind = .rel;
                insn.imm = @bitCast(rel);
                pos += 1;
            }
        },
        .word => {
            if (pos + 1 < bytes.len) {
                const raw: u16 = @as(u16, bytes[pos]) | (@as(u16, bytes[pos + 1]) << 8);
                const rel: i32 = @as(i32, @as(i16, @bitCast(raw)));
                insn.op0_kind = .rel;
                insn.imm = @bitCast(rel);
                pos += 2;
            }
        },
        .dword => {
            if (pos + 3 < bytes.len) {
                const raw: u32 = @as(u32, bytes[pos]) |
                    (@as(u32, bytes[pos + 1]) << 8) |
                    (@as(u32, bytes[pos + 2]) << 16) |
                    (@as(u32, bytes[pos + 3]) << 24);
                insn.op0_kind = .rel;
                insn.imm = raw;
                pos += 4;
            }
        },
    }
    return pos;
}

/// Read a memory offset operand (for MOV AL/EAX, moffs).
fn readMoffs(bytes: []const u8, start_pos: usize, insn: *Instruction) usize {
    var pos = start_pos;
    if (pos + 3 < bytes.len) {
        const addr: u32 = @as(u32, bytes[pos]) |
            (@as(u32, bytes[pos + 1]) << 8) |
            (@as(u32, bytes[pos + 2]) << 16) |
            (@as(u32, bytes[pos + 3]) << 24);
        insn.op0_kind = .mem;
        insn.mem_seg = insn.seg_override orelse .ds;
        insn.mem_base = 0xF;
        insn.mem_index = 0xF;
        insn.mem_scale = 0;
        insn.mem_disp = @bitCast(addr);
        pos += 4;
    }
    return pos;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = @import("std").testing;

test "decode: NOP (0x90)" {
    const insn = decode(&.{0x90});
    try testing.expectEqual(@as(u16, 0x90), insn.opcode);
    try testing.expectEqual(@as(u8, 1), insn.length);
}

test "decode: truncated instruction streams decode defensively" {
    // The decoder must never read past the slice or panic: it consumes what
    // is present, reports that as `length`, and leaves missing operands at
    // their defaults.
    const empty = decode(&.{});
    try testing.expectEqual(@as(u8, 0), empty.length);

    // Prefix byte with nothing after it.
    const prefix_only = decode(&.{0x66});
    try testing.expectEqual(@as(u8, 1), prefix_only.length);

    // 0x0F escape with no second opcode byte.
    const lone_escape = decode(&.{0x0F});
    try testing.expectEqual(@as(u8, 1), lone_escape.length);

    // MOV EAX, imm32 truncated mid-immediate: no immediate consumed.
    const trunc_imm = decode(&.{ 0xB8, 0x78, 0x56 });
    try testing.expectEqual(@as(u16, 0xB8), trunc_imm.opcode);
    try testing.expectEqual(@as(u32, 0), trunc_imm.imm);
    try testing.expectEqual(@as(u8, 1), trunc_imm.length);

    // Opcode that needs a ModR/M byte with none present.
    const no_modrm = decode(&.{0x83});
    try testing.expectEqual(@as(u16, 0x83), no_modrm.opcode);
    try testing.expectEqual(@as(u8, 1), no_modrm.length);
}

test "decode: MOV EAX, imm32 (B8 + dword)" {
    const insn = decode(&.{ 0xB8, 0x78, 0x56, 0x34, 0x12 });
    try testing.expectEqual(@as(u16, 0xB8), insn.opcode);
    try testing.expectEqual(@as(u32, 0x12345678), insn.imm);
    try testing.expectEqual(@as(u8, 5), insn.length);
}

test "decode: PUSH EBP (0x55)" {
    const insn = decode(&.{0x55});
    try testing.expectEqual(@as(u16, 0x55), insn.opcode);
    try testing.expectEqual(@as(u8, 1), insn.length);
    try testing.expectEqual(OpKind.reg, insn.op0_kind);
    try testing.expectEqual(@as(u3, 5), insn.op0_reg);
}

test "decode: MOV EBP, ESP (89 E5 = mov r/m32, reg32)" {
    const insn = decode(&.{ 0x89, 0xE5 });
    try testing.expectEqual(@as(u16, 0x89), insn.opcode);
    try testing.expectEqual(@as(u8, 2), insn.length);
    // mod=11, reg=esp(4), rm=ebp(5)
    try testing.expectEqual(OpKind.reg, insn.op0_kind);
    try testing.expectEqual(@as(u3, 5), insn.op0_reg); // destination = EBP
    try testing.expectEqual(OpKind.reg, insn.op1_kind);
    try testing.expectEqual(@as(u3, 4), insn.op1_reg); // source = ESP
}

test "decode: SUB ESP, 0x10 (83 EC 10)" {
    const insn = decode(&.{ 0x83, 0xEC, 0x10 });
    try testing.expectEqual(@as(u16, 0x83), insn.opcode);
    try testing.expectEqual(@as(u8, 3), insn.length);
    try testing.expectEqual(OpKind.reg, insn.op0_kind);
    try testing.expectEqual(@as(u3, 4), insn.op0_reg); // ESP
    try testing.expectEqual(cpu_mod.signExtend8to32(0x10), insn.imm);
}

test "decode: CALL rel32 (E8 xx xx xx xx)" {
    const insn = decode(&.{ 0xE8, 0x10, 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(u16, 0xE8), insn.opcode);
    try testing.expectEqual(@as(u8, 5), insn.length);
    try testing.expectEqual(OpKind.rel, insn.op0_kind);
    try testing.expectEqual(@as(u32, 0x10), insn.imm);
}

test "decode: JE rel8 (74 xx)" {
    const insn = decode(&.{ 0x74, 0xFE }); // JE -2
    try testing.expectEqual(@as(u16, 0x74), insn.opcode);
    try testing.expectEqual(@as(u8, 2), insn.length);
    try testing.expectEqual(OpKind.rel, insn.op0_kind);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -2))), insn.imm);
}

test "decode: FS segment override (64 A1 xx)" {
    const insn = decode(&.{ 0x64, 0xA1, 0x00, 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(u16, 0xA1), insn.opcode);
    try testing.expectEqual(Segment.fs, insn.seg_override.?);
    try testing.expectEqual(@as(u8, 6), insn.length);
}

test "decode: MOV [EBP-4], EAX (89 45 FC)" {
    const insn = decode(&.{ 0x89, 0x45, 0xFC });
    try testing.expectEqual(@as(u16, 0x89), insn.opcode);
    try testing.expectEqual(@as(u8, 3), insn.length);
    // operands[0] = mem [EBP-4], operands[1] = reg EAX(0)
    // 0x89 is rm_reg: op0 = r/m (mem), op1 = reg
    // modrm = 0x45 = mod=01, reg=000(EAX), rm=101(EBP)
    try testing.expectEqual(OpKind.mem, insn.op0_kind);
    try testing.expectEqual(@as(u4, 5), insn.mem_base); // EBP
    try testing.expectEqual(@as(i32, -4), insn.mem_disp);
    try testing.expectEqual(OpKind.reg, insn.op1_kind);
    try testing.expectEqual(@as(u3, 0), insn.op1_reg); // EAX
}

test "decode: SIB addressing [EAX + ECX*4 + 0x10]" {
    // MOV EAX, [EAX + ECX*4 + 0x10]  =>  8B 44 88 10
    // 8B = MOV reg, r/m32 (reg_rm)
    // modrm = 0x44 = mod=01, reg=000(EAX), rm=100(SIB)
    // SIB = 0x88 = scale=10(4), index=001(ECX), base=000(EAX)
    // disp8 = 0x10
    const insn = decode(&.{ 0x8B, 0x44, 0x88, 0x10 });
    try testing.expectEqual(@as(u16, 0x8B), insn.opcode);
    try testing.expectEqual(@as(u8, 4), insn.length);
    try testing.expectEqual(OpKind.reg, insn.op0_kind);
    try testing.expectEqual(@as(u3, 0), insn.op0_reg); // dest = EAX
    try testing.expectEqual(OpKind.mem, insn.op1_kind);
    try testing.expectEqual(@as(u4, 0), insn.mem_base); // EAX
    try testing.expectEqual(@as(u4, 1), insn.mem_index); // ECX
    try testing.expectEqual(@as(u2, 2), insn.mem_scale); // *4
    try testing.expectEqual(@as(i32, 0x10), insn.mem_disp);
}

test "decode: MOVZX (0F B6)" {
    const insn = decode(&.{ 0x0F, 0xB6, 0xC1 }); // MOVZX EAX, CL
    try testing.expectEqual(@as(u16, 0x0FB6), insn.opcode);
    try testing.expectEqual(@as(u8, 3), insn.length);
    try testing.expectEqual(OpKind.reg, insn.op0_kind);
    try testing.expectEqual(@as(u3, 0), insn.op0_reg); // EAX
    try testing.expectEqual(OpKind.reg, insn.op1_kind);
    try testing.expectEqual(@as(u3, 1), insn.op1_reg); // CL (reg index)
}
