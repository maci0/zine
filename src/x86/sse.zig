//! SSE/SSE2/MMX instruction execution for the x86 interpreter.
//!
//! Handles all SIMD instructions dispatched from execute.zig.
//! Prefix determines variant:
//!   - No prefix: PS (packed single) or MMX
//!   - 66 prefix: PD (packed double) or XMM integer
//!   - F3 prefix: SS (scalar single)
//!   - F2 prefix: SD (scalar double)

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decoder = @import("decoder.zig");
const flags_mod = @import("flags.zig");
const log = @import("../log.zig");

const Cpu = cpu_mod.Cpu;
const Instruction = decoder.Instruction;
const Operand = decoder.Operand;
const MemOperand = decoder.MemOperand;
const Segment = cpu_mod.Segment;

// -----------------------------------------------------------------------
// Address computation (duplicated from execute.zig since it's private)
// -----------------------------------------------------------------------

fn computeAddr(cpu: *const Cpu, m: *const MemOperand) u32 {
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
// Source operand readers
// -----------------------------------------------------------------------

fn readXmm128(cpu: *const Cpu, insn: *const Instruction, op_idx: u1) u128 {
    const op = insn.operands[op_idx];
    return switch (op) {
        .reg => |r| cpu.xmm[r],
        .mem => |m| cpu.memory.read128(computeAddr(cpu, &m)),
        else => 0,
    };
}

fn readXmm64(cpu: *const Cpu, insn: *const Instruction, op_idx: u1) u64 {
    const op = insn.operands[op_idx];
    return switch (op) {
        .reg => |r| @truncate(cpu.xmm[r]),
        .mem => |m| cpu.memory.read64(computeAddr(cpu, &m)),
        else => 0,
    };
}

fn readXmm32(cpu: *const Cpu, insn: *const Instruction, op_idx: u1) u32 {
    const op = insn.operands[op_idx];
    return switch (op) {
        .reg => |r| @truncate(cpu.xmm[r]),
        .mem => |m| cpu.memory.read32(computeAddr(cpu, &m)),
        else => 0,
    };
}

fn writeXmm128(cpu: *Cpu, insn: *const Instruction, op_idx: u1, val: u128) void {
    const op = insn.operands[op_idx];
    switch (op) {
        .reg => |r| cpu.xmm[r] = val,
        .mem => |m| cpu.memory.write128(computeAddr(cpu, &m), val),
        else => {},
    }
}

fn writeXmm64(cpu: *Cpu, insn: *const Instruction, op_idx: u1, val: u64) void {
    const op = insn.operands[op_idx];
    switch (op) {
        .reg => |r| cpu.xmm[r] = val,
        .mem => |m| cpu.memory.write64(computeAddr(cpu, &m), val),
        else => {},
    }
}

fn writeXmm32(cpu: *Cpu, insn: *const Instruction, op_idx: u1, val: u32) void {
    const op = insn.operands[op_idx];
    switch (op) {
        .reg => |r| cpu.xmm[r] = (cpu.xmm[r] & ~@as(u128, 0xFFFFFFFF)) | val,
        .mem => |m| cpu.memory.write32(computeAddr(cpu, &m), val),
        else => {},
    }
}

fn getRegIdx(insn: *const Instruction, op_idx: u1) u3 {
    return switch (insn.operands[op_idx]) {
        .reg => |r| r,
        else => 0,
    };
}

fn getMemAddr(cpu: *const Cpu, insn: *const Instruction, op_idx: u1) u32 {
    return switch (insn.operands[op_idx]) {
        .mem => |m| computeAddr(cpu, &m),
        else => 0,
    };
}

fn isMem(insn: *const Instruction, op_idx: u1) bool {
    return insn.operands[op_idx] == .mem;
}

// -----------------------------------------------------------------------
// Prefix helpers
// -----------------------------------------------------------------------

const SsePrefix = enum { none, p66, pF3, pF2 };

fn getPrefix(insn: *const Instruction) SsePrefix {
    if (insn.prefixes.repne) return .pF2;
    if (insn.prefixes.rep) return .pF3;
    if (insn.prefixes.operand_size_override) return .p66;
    return .none;
}

// -----------------------------------------------------------------------
// Float comparison helpers
// -----------------------------------------------------------------------

fn cmpFloat(comptime T: type, a: T, b: T, pred: u3) bool {
    return switch (pred) {
        0 => a == b, // EQ
        1 => a < b, // LT
        2 => a <= b, // LE
        3 => std.math.isNan(a) or std.math.isNan(b), // UNORD
        4 => a != b, // NEQ
        5 => !(a < b), // NLT
        6 => !(a <= b), // NLE
        7 => !std.math.isNan(a) and !std.math.isNan(b), // ORD
    };
}

fn ucomiFlags(comptime T: type, a: T, b: T) u32 {
    // Set ZF, PF, CF in EFLAGS based on unordered compare
    var ef: u32 = 0;
    if (std.math.isNan(a) or std.math.isNan(b)) {
        ef |= flags_mod.FLAG_ZF | flags_mod.FLAG_PF | flags_mod.FLAG_CF;
    } else if (a == b) {
        ef |= flags_mod.FLAG_ZF;
    } else if (a < b) {
        ef |= flags_mod.FLAG_CF;
    }
    // else a > b: all clear
    return ef;
}

// -----------------------------------------------------------------------
// Main dispatch
// -----------------------------------------------------------------------

pub fn execute(cpu: *Cpu, insn: *const Instruction, eip: u32) void {
    _ = eip;
    const pfx = getPrefix(insn);

    switch (insn.opcode) {
        // =============================================================
        // Data Movement (0F 10-17, 28-2F)
        // =============================================================

        0x0F10 => switch (pfx) { // MOVUPS/MOVUPD/MOVSS/MOVSD
            .none, .p66 => { // MOVUPS / MOVUPD
                const dst = getRegIdx(insn, 0);
                cpu.xmm[dst] = readXmm128(cpu, insn, 1);
            },
            .pF3 => { // MOVSS
                const dst = getRegIdx(insn, 0);
                const src: u32 = readXmm32(cpu, insn, 1);
                if (isMem(insn, 1)) {
                    cpu.xmm[dst] = src; // zero upper bits from memory
                } else {
                    cpu.xmm[dst] = (cpu.xmm[dst] & ~@as(u128, 0xFFFFFFFF)) | src;
                }
            },
            .pF2 => { // MOVSD
                const dst = getRegIdx(insn, 0);
                const src: u64 = readXmm64(cpu, insn, 1);
                if (isMem(insn, 1)) {
                    cpu.xmm[dst] = src;
                } else {
                    cpu.xmm[dst] = (cpu.xmm[dst] & ~@as(u128, 0xFFFFFFFFFFFFFFFF)) | src;
                }
            },
        },
        0x0F11 => switch (pfx) { // MOVUPS/MOVUPD/MOVSS/MOVSD store
            .none, .p66 => writeXmm128(cpu, insn, 0, cpu.xmm[getRegIdx(insn, 1)]),
            .pF3 => writeXmm32(cpu, insn, 0, @truncate(cpu.xmm[getRegIdx(insn, 1)])),
            .pF2 => writeXmm64(cpu, insn, 0, @truncate(cpu.xmm[getRegIdx(insn, 1)])),
        },

        0x0F12 => { // MOVLPS/MOVHLPS/MOVSLDUP/MOVDDUP
            const dst = getRegIdx(insn, 0);
            if (pfx == .none) {
                if (isMem(insn, 1)) { // MOVLPS xmm, m64
                    const lo = readXmm64(cpu, insn, 1);
                    cpu.xmm[dst] = (cpu.xmm[dst] & (@as(u128, 0xFFFFFFFFFFFFFFFF) << 64)) | lo;
                } else { // MOVHLPS xmm, xmm
                    const src = getRegIdx(insn, 1);
                    const hi: u64 = @truncate(cpu.xmm[src] >> 64);
                    cpu.xmm[dst] = (cpu.xmm[dst] & (@as(u128, 0xFFFFFFFFFFFFFFFF) << 64)) | hi;
                }
            } else if (pfx == .p66) { // MOVLPD xmm, m64
                const lo = readXmm64(cpu, insn, 1);
                cpu.xmm[dst] = (cpu.xmm[dst] & (@as(u128, 0xFFFFFFFFFFFFFFFF) << 64)) | lo;
            } else { // MOVSLDUP/MOVDDUP — just move
                cpu.xmm[dst] = readXmm128(cpu, insn, 1);
            }
        },
        0x0F13 => { // MOVLPS/MOVLPD store (m64, xmm)
            writeXmm64(cpu, insn, 0, @truncate(cpu.xmm[getRegIdx(insn, 1)]));
        },
        0x0F14 => { // UNPCKLPS/UNPCKLPD
            const dst = getRegIdx(insn, 0);
            const a: [4]u32 = @bitCast(cpu.xmm[dst]);
            const b: [4]u32 = @bitCast(readXmm128(cpu, insn, 1));
            if (pfx == .p66) { // UNPCKLPD: interleave low qwords
                cpu.xmm[dst] = @bitCast([2]u64{ @bitCast([2]u32{ a[0], a[1] }), @bitCast([2]u32{ b[0], b[1] }) });
            } else { // UNPCKLPS: interleave low dwords
                cpu.xmm[dst] = @bitCast([4]u32{ a[0], b[0], a[1], b[1] });
            }
        },
        0x0F15 => { // UNPCKHPS/UNPCKHPD
            const dst = getRegIdx(insn, 0);
            const a: [4]u32 = @bitCast(cpu.xmm[dst]);
            const b: [4]u32 = @bitCast(readXmm128(cpu, insn, 1));
            if (pfx == .p66) { // UNPCKHPD
                cpu.xmm[dst] = @bitCast([2]u64{ @bitCast([2]u32{ a[2], a[3] }), @bitCast([2]u32{ b[2], b[3] }) });
            } else { // UNPCKHPS
                cpu.xmm[dst] = @bitCast([4]u32{ a[2], b[2], a[3], b[3] });
            }
        },
        0x0F16 => { // MOVHPS/MOVLHPS/MOVHPD/MOVSHDUP
            const dst = getRegIdx(insn, 0);
            if (pfx == .none or pfx == .p66) {
                if (isMem(insn, 1)) { // MOVHPS/MOVHPD xmm, m64
                    const hi: u128 = readXmm64(cpu, insn, 1);
                    cpu.xmm[dst] = (cpu.xmm[dst] & 0xFFFFFFFFFFFFFFFF) | (hi << 64);
                } else { // MOVLHPS xmm, xmm
                    const src = getRegIdx(insn, 1);
                    const lo: u128 = @as(u128, @as(u64, @truncate(cpu.xmm[src])));
                    cpu.xmm[dst] = (cpu.xmm[dst] & 0xFFFFFFFFFFFFFFFF) | (lo << 64);
                }
            } else {
                cpu.xmm[dst] = readXmm128(cpu, insn, 1);
            }
        },
        0x0F17 => { // MOVHPS/MOVHPD store (m64, xmm)
            const src = getRegIdx(insn, 1);
            const hi: u64 = @truncate(cpu.xmm[src] >> 64);
            writeXmm64(cpu, insn, 0, hi);
        },

        0x0F28 => { // MOVAPS/MOVAPD
            const dst = getRegIdx(insn, 0);
            cpu.xmm[dst] = readXmm128(cpu, insn, 1);
        },
        0x0F29 => { // MOVAPS/MOVAPD store
            writeXmm128(cpu, insn, 0, cpu.xmm[getRegIdx(insn, 1)]);
        },

        0x0F2A => switch (pfx) { // CVTPI2PS/CVTSI2SS/CVTSI2SD
            .pF3 => { // CVTSI2SS
                const dst = getRegIdx(insn, 0);
                const src: i32 = @bitCast(readXmm32(cpu, insn, 1));
                var fs = cpu.getXmmF32(dst);
                fs[0] = @floatFromInt(src);
                cpu.setXmmF32(dst, fs);
            },
            .pF2 => { // CVTSI2SD
                const dst = getRegIdx(insn, 0);
                const src: i32 = @bitCast(readXmm32(cpu, insn, 1));
                var fs = cpu.getXmmF64(dst);
                fs[0] = @floatFromInt(src);
                cpu.setXmmF64(dst, fs);
            },
            else => {}, // CVTPI2PS — rare, skip for now
        },

        0x0F2B => { // MOVNTPS/MOVNTPD — non-temporal store = normal store
            writeXmm128(cpu, insn, 0, cpu.xmm[getRegIdx(insn, 1)]);
        },

        0x0F2C => switch (pfx) { // CVTTSS2SI/CVTTSD2SI (truncate)
            .pF3 => { // CVTTSS2SI
                const dst = getRegIdx(insn, 0);
                const src_bits = readXmm32(cpu, insn, 1);
                const f: f32 = @bitCast(src_bits);
                cpu.setReg(@enumFromInt(dst), floatToI32(f32, f));
            },
            .pF2 => { // CVTTSD2SI
                const dst = getRegIdx(insn, 0);
                const src_bits = readXmm64(cpu, insn, 1);
                const f: f64 = @bitCast(src_bits);
                cpu.setReg(@enumFromInt(dst), floatToI32(f64, f));
            },
            else => {},
        },

        0x0F2D => switch (pfx) { // CVTSS2SI/CVTSD2SI (round)
            .pF3 => {
                const dst = getRegIdx(insn, 0);
                const f: f32 = @bitCast(readXmm32(cpu, insn, 1));
                cpu.setReg(@enumFromInt(dst), floatToI32(f32, f));
            },
            .pF2 => {
                const dst = getRegIdx(insn, 0);
                const f: f64 = @bitCast(readXmm64(cpu, insn, 1));
                cpu.setReg(@enumFromInt(dst), floatToI32(f64, f));
            },
            else => {},
        },

        0x0F2E, 0x0F2F => { // UCOMISS/UCOMISD, COMISS/COMISD
            var ef: u32 = cpu.flags.toEflags() & ~@as(u32, flags_mod.FLAG_ZF | flags_mod.FLAG_PF | flags_mod.FLAG_CF | flags_mod.FLAG_OF | flags_mod.FLAG_SF | flags_mod.FLAG_AF);
            if (pfx == .p66 or pfx == .pF2) { // *SD
                const a: f64 = @bitCast(readXmm64(cpu, insn, 0));
                const b: f64 = @bitCast(readXmm64(cpu, insn, 1));
                ef |= ucomiFlags(f64, a, b);
            } else { // *SS
                const a: f32 = @bitCast(readXmm32(cpu, insn, 0));
                const b: f32 = @bitCast(readXmm32(cpu, insn, 1));
                ef |= ucomiFlags(f32, a, b);
            }
            cpu.flags.fromEflags(ef);
        },

        // =============================================================
        // Arithmetic & Logic (0F 50-5F)
        // =============================================================

        0x0F50 => { // MOVMSKPS/MOVMSKPD
            const dst = getRegIdx(insn, 0);
            const src = getRegIdx(insn, 1);
            if (pfx == .p66) { // MOVMSKPD
                const bytes: [16]u8 = @bitCast(cpu.xmm[src]);
                const mask: u32 = (@as(u32, bytes[7] >> 7)) | (@as(u32, bytes[15] >> 7) << 1);
                cpu.setReg(@enumFromInt(dst), mask);
            } else { // MOVMSKPS
                const dw: [4]u32 = @bitCast(cpu.xmm[src]);
                const mask: u32 = (dw[0] >> 31) | ((dw[1] >> 31) << 1) | ((dw[2] >> 31) << 2) | ((dw[3] >> 31) << 3);
                cpu.setReg(@enumFromInt(dst), mask);
            }
        },

        0x0F51 => execUnaryFloat(cpu, insn, pfx, .sqrt),
        0x0F52 => execUnaryFloat(cpu, insn, pfx, .rsqrt),
        0x0F53 => execUnaryFloat(cpu, insn, pfx, .rcp),
        0x0F54 => execBitwise128(cpu, insn, .@"and"),  // ANDPS/ANDPD
        0x0F55 => execBitwise128(cpu, insn, .andn),     // ANDNPS/ANDNPD
        0x0F56 => execBitwise128(cpu, insn, .@"or"),   // ORPS/ORPD
        0x0F57 => execBitwise128(cpu, insn, .xor),      // XORPS/XORPD
        0x0F58 => execBinFloat(cpu, insn, pfx, .add),
        0x0F59 => execBinFloat(cpu, insn, pfx, .mul),
        0x0F5A => execConvertFloat(cpu, insn, pfx),     // CVT*2*
        0x0F5B => execConvertDqPs(cpu, insn, pfx),      // CVTDQ2PS/CVTPS2DQ/CVTTPS2DQ
        0x0F5C => execBinFloat(cpu, insn, pfx, .sub),
        0x0F5D => execBinFloat(cpu, insn, pfx, .min),
        0x0F5E => execBinFloat(cpu, insn, pfx, .div),
        0x0F5F => execBinFloat(cpu, insn, pfx, .max),

        // =============================================================
        // Integer SIMD (0F 60-6F, 70-7F, D0-FF)
        // =============================================================

        0x0F60 => execPunpckl(cpu, insn, pfx, 1), // PUNPCKLBW
        0x0F61 => execPunpckl(cpu, insn, pfx, 2), // PUNPCKLWD
        0x0F62 => execPunpckl(cpu, insn, pfx, 4), // PUNPCKLDQ
        0x0F63 => execPackSS(cpu, insn, pfx, .wb), // PACKSSWB
        0x0F64 => execPcmp(cpu, insn, pfx, 1, .gt), // PCMPGTB
        0x0F65 => execPcmp(cpu, insn, pfx, 2, .gt), // PCMPGTW
        0x0F66 => execPcmp(cpu, insn, pfx, 4, .gt), // PCMPGTD
        0x0F67 => execPackUS(cpu, insn, pfx), // PACKUSWB
        0x0F68 => execPunpckh(cpu, insn, pfx, 1), // PUNPCKHBW
        0x0F69 => execPunpckh(cpu, insn, pfx, 2), // PUNPCKHWD
        0x0F6A => execPunpckh(cpu, insn, pfx, 4), // PUNPCKHDQ
        0x0F6B => execPackSS(cpu, insn, pfx, .dw), // PACKSSDW
        0x0F6C => execPunpckl(cpu, insn, pfx, 8), // PUNPCKLQDQ
        0x0F6D => execPunpckh(cpu, insn, pfx, 8), // PUNPCKHQDQ

        0x0F6E => { // MOVD xmm/mm, r/m32
            const dst = getRegIdx(insn, 0);
            const val = readXmm32(cpu, insn, 1);
            if (pfx == .p66) {
                cpu.xmm[dst] = val; // zero extend to 128
            } else {
                cpu.setMmx(dst, val);
            }
        },
        0x0F6F => { // MOVQ mm/MOVDQA/MOVDQU
            const dst = getRegIdx(insn, 0);
            if (pfx == .p66 or pfx == .pF3) {
                cpu.xmm[dst] = readXmm128(cpu, insn, 1); // MOVDQA/MOVDQU
            } else {
                cpu.setMmx(dst, readXmm64(cpu, insn, 1)); // MOVQ mm
            }
        },

        0x0F70 => { // PSHUFD/PSHUFLW/PSHUFHW
            const dst = getRegIdx(insn, 0);
            const imm: u8 = @truncate(insn.imm);
            if (pfx == .p66) { // PSHUFD
                const src: [4]u32 = @bitCast(readXmm128(cpu, insn, 1));
                cpu.xmm[dst] = @bitCast([4]u32{
                    src[imm & 3],
                    src[(imm >> 2) & 3],
                    src[(imm >> 4) & 3],
                    src[(imm >> 6) & 3],
                });
            } else if (pfx == .pF3) { // PSHUFLW
                const src: [8]u16 = @bitCast(readXmm128(cpu, insn, 1));
                var result: [8]u16 = src;
                result[0] = src[imm & 3];
                result[1] = src[(imm >> 2) & 3];
                result[2] = src[(imm >> 4) & 3];
                result[3] = src[(imm >> 6) & 3];
                cpu.xmm[dst] = @bitCast(result);
            } else if (pfx == .pF2) { // PSHUFHW
                const src: [8]u16 = @bitCast(readXmm128(cpu, insn, 1));
                var result: [8]u16 = src;
                result[4] = src[4 + (imm & 3)];
                result[5] = src[4 + ((imm >> 2) & 3)];
                result[6] = src[4 + ((imm >> 4) & 3)];
                result[7] = src[4 + ((imm >> 6) & 3)];
                cpu.xmm[dst] = @bitCast(result);
            } else { // PSHUFW mm
                const src: u64 = readXmm64(cpu, insn, 1);
                const w: [4]u16 = @bitCast(src);
                cpu.setMmx(dst, @bitCast([4]u16{
                    w[imm & 3],
                    w[(imm >> 2) & 3],
                    w[(imm >> 4) & 3],
                    w[(imm >> 6) & 3],
                }));
            }
        },

        0x0F71 => execGroupShift(cpu, insn, pfx, 2), // PSxxW imm8
        0x0F72 => execGroupShift(cpu, insn, pfx, 4), // PSxxD imm8
        0x0F73 => execGroupShift(cpu, insn, pfx, 8), // PSxxQ imm8

        0x0F74 => execPcmp(cpu, insn, pfx, 1, .eq), // PCMPEQB
        0x0F75 => execPcmp(cpu, insn, pfx, 2, .eq), // PCMPEQW
        0x0F76 => execPcmp(cpu, insn, pfx, 4, .eq), // PCMPEQD

        0x0F77 => { // EMMS
            cpu.fpu.tag_word = 0xFFFF;
        },

        0x0F7E => { // MOVD/MOVQ store
            if (pfx == .p66) { // MOVD r/m32, xmm
                writeXmm32(cpu, insn, 0, @truncate(cpu.xmm[getRegIdx(insn, 1)]));
            } else if (pfx == .pF3) { // MOVQ xmm, xmm/m64
                const dst = getRegIdx(insn, 0);
                cpu.xmm[dst] = readXmm64(cpu, insn, 1);
            } else { // MOVD r/m32, mm
                writeXmm32(cpu, insn, 0, @truncate(cpu.getMmx(getRegIdx(insn, 1))));
            }
        },
        0x0F7F => { // MOVQ/MOVDQA/MOVDQU store
            if (pfx == .p66 or pfx == .pF3) {
                writeXmm128(cpu, insn, 0, cpu.xmm[getRegIdx(insn, 1)]);
            } else {
                writeXmm64(cpu, insn, 0, cpu.getMmx(getRegIdx(insn, 1)));
            }
        },

        // --- Compare + misc (0F C2-C6) ---
        0x0FC2 => execCmpFloat(cpu, insn, pfx),
        0x0FC3 => { // MOVNTI m32, r32 — normal store
            if (insn.operands[0] == .mem) {
                const addr = getMemAddr(cpu, insn, 0);
                cpu.memory.write32(addr, cpu.getReg(@enumFromInt(getRegIdx(insn, 1))));
            }
        },
        0x0FC4 => { // PINSRW
            const dst = getRegIdx(insn, 0);
            const val: u16 = @truncate(readXmm32(cpu, insn, 1));
            const sel: u3 = @truncate(insn.imm);
            if (pfx == .p66) {
                var words: [8]u16 = @bitCast(cpu.xmm[dst]);
                words[sel] = val;
                cpu.xmm[dst] = @bitCast(words);
            } else {
                var mmval = cpu.getMmx(dst);
                const shift: u6 = @as(u6, sel & 3) * 16;
                mmval = (mmval & ~(@as(u64, 0xFFFF) << shift)) | (@as(u64, val) << shift);
                cpu.setMmx(dst, mmval);
            }
        },
        0x0FC5 => { // PEXTRW
            const dst = getRegIdx(insn, 0);
            const src = getRegIdx(insn, 1);
            const sel: u3 = @truncate(insn.imm);
            if (pfx == .p66) {
                const words: [8]u16 = @bitCast(cpu.xmm[src]);
                cpu.setReg(@enumFromInt(dst), words[sel]);
            } else {
                const shift: u6 = @as(u6, sel & 3) * 16;
                cpu.setReg(@enumFromInt(dst), @truncate(cpu.getMmx(src) >> shift));
            }
        },
        0x0FC6 => { // SHUFPS/SHUFPD
            const dst = getRegIdx(insn, 0);
            const imm: u8 = @truncate(insn.imm);
            const src = readXmm128(cpu, insn, 1);
            if (pfx == .p66) { // SHUFPD
                const a: [2]u64 = @bitCast(cpu.xmm[dst]);
                const b: [2]u64 = @bitCast(src);
                cpu.xmm[dst] = @bitCast([2]u64{ a[imm & 1], b[(imm >> 1) & 1] });
            } else { // SHUFPS
                const a: [4]u32 = @bitCast(cpu.xmm[dst]);
                const b: [4]u32 = @bitCast(src);
                cpu.xmm[dst] = @bitCast([4]u32{ a[imm & 3], a[(imm >> 2) & 3], b[(imm >> 4) & 3], b[(imm >> 6) & 3] });
            }
        },

        // --- Integer SIMD ops (0F D0-FF) ---
        0x0FD1 => execShiftReg(cpu, insn, pfx, 2, .srl), // PSRLW
        0x0FD2 => execShiftReg(cpu, insn, pfx, 4, .srl), // PSRLD
        0x0FD3 => execShiftReg(cpu, insn, pfx, 8, .srl), // PSRLQ
        0x0FD4 => execIntBin(cpu, insn, pfx, 8, .add),    // PADDQ
        0x0FD5 => execIntBin(cpu, insn, pfx, 2, .mullo),  // PMULLW
        0x0FD6 => { // MOVQ store (66 prefix: xmm/m64, xmm)
            writeXmm64(cpu, insn, 0, @truncate(cpu.xmm[getRegIdx(insn, 1)]));
        },
        0x0FD7 => { // PMOVMSKB
            const dst = getRegIdx(insn, 0);
            const src = getRegIdx(insn, 1);
            if (pfx == .p66) {
                const b: [16]u8 = @bitCast(cpu.xmm[src]);
                var mask: u32 = 0;
                inline for (0..16) |i| mask |= @as(u32, b[i] >> 7) << i;
                cpu.setReg(@enumFromInt(dst), mask);
            } else {
                const b: [8]u8 = @bitCast(cpu.getMmx(src));
                var mask: u32 = 0;
                inline for (0..8) |i| mask |= @as(u32, b[i] >> 7) << i;
                cpu.setReg(@enumFromInt(dst), mask);
            }
        },
        0x0FD8 => execIntBin(cpu, insn, pfx, 1, .subus),  // PSUBUSB
        0x0FD9 => execIntBin(cpu, insn, pfx, 2, .subus),  // PSUBUSW
        0x0FDA => execIntBin(cpu, insn, pfx, 1, .minu),    // PMINUB
        0x0FDB => execBitwise128(cpu, insn, .@"and"),       // PAND
        0x0FDC => execIntBin(cpu, insn, pfx, 1, .addus),   // PADDUSB
        0x0FDD => execIntBin(cpu, insn, pfx, 2, .addus),   // PADDUSW
        0x0FDE => execIntBin(cpu, insn, pfx, 1, .maxu),    // PMAXUB
        0x0FDF => execBitwise128(cpu, insn, .andn),         // PANDN
        0x0FE0 => execIntBin(cpu, insn, pfx, 1, .avg),     // PAVGB
        0x0FE1 => execShiftReg(cpu, insn, pfx, 2, .sra),   // PSRAW
        0x0FE2 => execShiftReg(cpu, insn, pfx, 4, .sra),   // PSRAD
        0x0FE3 => execIntBin(cpu, insn, pfx, 2, .avg),     // PAVGW
        0x0FE4 => execIntBin(cpu, insn, pfx, 2, .mulhu),   // PMULHUW
        0x0FE5 => execIntBin(cpu, insn, pfx, 2, .mulhi),   // PMULHW
        0x0FE6 => execConvertE6(cpu, insn, pfx),            // CVT*
        0x0FE7 => { // MOVNTDQ/MOVNTQ — non-temporal store
            if (pfx == .p66) writeXmm128(cpu, insn, 0, cpu.xmm[getRegIdx(insn, 1)])
            else writeXmm64(cpu, insn, 0, cpu.getMmx(getRegIdx(insn, 1)));
        },
        0x0FE8 => execIntBin(cpu, insn, pfx, 1, .subs),    // PSUBSB
        0x0FE9 => execIntBin(cpu, insn, pfx, 2, .subs),    // PSUBSW
        0x0FEA => execIntBin(cpu, insn, pfx, 2, .mins),    // PMINSW
        0x0FEB => execBitwise128(cpu, insn, .@"or"),        // POR
        0x0FEC => execIntBin(cpu, insn, pfx, 1, .adds),    // PADDSB
        0x0FED => execIntBin(cpu, insn, pfx, 2, .adds),    // PADDSW
        0x0FEE => execIntBin(cpu, insn, pfx, 2, .maxs),    // PMAXSW
        0x0FEF => execBitwise128(cpu, insn, .xor),          // PXOR
        0x0FF1 => execShiftReg(cpu, insn, pfx, 2, .sll),   // PSLLW
        0x0FF2 => execShiftReg(cpu, insn, pfx, 4, .sll),   // PSLLD
        0x0FF3 => execShiftReg(cpu, insn, pfx, 8, .sll),   // PSLLQ
        0x0FF4 => execPmuludq(cpu, insn, pfx),              // PMULUDQ
        0x0FF5 => execPmaddwd(cpu, insn, pfx),              // PMADDWD
        0x0FF6 => execPsadbw(cpu, insn, pfx),               // PSADBW
        0x0FF7 => {}, // MASKMOVDQU — NOP for now
        0x0FF8 => execIntBin(cpu, insn, pfx, 1, .sub),     // PSUBB
        0x0FF9 => execIntBin(cpu, insn, pfx, 2, .sub),     // PSUBW
        0x0FFA => execIntBin(cpu, insn, pfx, 4, .sub),     // PSUBD
        0x0FFB => execIntBin(cpu, insn, pfx, 8, .sub),     // PSUBQ
        0x0FFC => execIntBin(cpu, insn, pfx, 1, .add),     // PADDB
        0x0FFD => execIntBin(cpu, insn, pfx, 2, .add),     // PADDW
        0x0FFE => execIntBin(cpu, insn, pfx, 4, .add),     // PADDD

        // --- Group 15: LDMXCSR/STMXCSR/LFENCE/MFENCE/SFENCE ---
        0x0FAE => {
            const sub = if (insn.modrm) |m| m.reg else 0;
            switch (sub) {
                2 => { // LDMXCSR
                    if (insn.operands[0] == .mem)
                        cpu.mxcsr = cpu.memory.read32(getMemAddr(cpu, insn, 0));
                },
                3 => { // STMXCSR
                    if (insn.operands[0] == .mem)
                        cpu.memory.write32(getMemAddr(cpu, insn, 0), cpu.mxcsr);
                },
                5, 6, 7 => {}, // LFENCE/MFENCE/SFENCE — NOP in interpreter
                else => {},
            }
        },

        // --- SSE NOP/stub opcodes ---
        0x0FD0, 0x0FF0 => {}, // ADDSUBPD/LDDQU — SSE3 stubs

        else => {
            log.warn("sse: unhandled opcode 0x{X:0>4} (pfx={s})", .{ insn.opcode, @tagName(pfx) });
        },
    }
}

// -----------------------------------------------------------------------
// Float helpers
// -----------------------------------------------------------------------

fn floatToI32(comptime T: type, f: T) u32 {
    if (std.math.isNan(f)) return 0x80000000;
    const min_val: T = -2147483648.0;
    const max_val: T = 2147483647.0;
    if (f <= min_val) return 0x80000000;
    if (f >= max_val) return 0x7FFFFFFF;
    const i: i32 = @intFromFloat(f);
    return @bitCast(i);
}

const UnaryOp = enum { sqrt, rsqrt, rcp };

fn execUnaryFloat(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix, op: UnaryOp) void {
    const dst = getRegIdx(insn, 0);
    switch (pfx) {
        .pF3 => { // SS
            const f: f32 = @bitCast(readXmm32(cpu, insn, 1));
            var r = cpu.getXmmF32(dst);
            r[0] = switch (op) {
                .sqrt => @sqrt(f),
                .rsqrt => if (f != 0) 1.0 / @sqrt(f) else 0,
                .rcp => if (f != 0) 1.0 / f else 0,
            };
            cpu.setXmmF32(dst, r);
        },
        .pF2 => { // SD
            const f: f64 = @bitCast(readXmm64(cpu, insn, 1));
            var r = cpu.getXmmF64(dst);
            r[0] = switch (op) {
                .sqrt => @sqrt(f),
                .rsqrt => if (f != 0) 1.0 / @sqrt(f) else 0,
                .rcp => if (f != 0) 1.0 / f else 0,
            };
            cpu.setXmmF64(dst, r);
        },
        .p66 => { // PD
            const src = cpu.getXmmF64(getRegIdx(insn, 1));
            var r: [2]f64 = undefined;
            for (0..2) |i| r[i] = switch (op) {
                .sqrt => @sqrt(src[i]),
                .rsqrt => if (src[i] != 0) 1.0 / @sqrt(src[i]) else 0,
                .rcp => if (src[i] != 0) 1.0 / src[i] else 0,
            };
            cpu.setXmmF64(dst, r);
        },
        .none => { // PS
            const src: [4]f32 = @bitCast(readXmm128(cpu, insn, 1));
            var r: [4]f32 = undefined;
            for (0..4) |i| r[i] = switch (op) {
                .sqrt => @sqrt(src[i]),
                .rsqrt => if (src[i] != 0) 1.0 / @sqrt(src[i]) else 0,
                .rcp => if (src[i] != 0) 1.0 / src[i] else 0,
            };
            cpu.setXmmF32(dst, r);
        },
    }
}

const BinOp = enum { add, sub, mul, div, min, max };

fn execBinFloat(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix, op: BinOp) void {
    const dst = getRegIdx(insn, 0);
    switch (pfx) {
        .pF3 => { // SS
            const a: f32 = @bitCast(@as(u32, @truncate(cpu.xmm[dst])));
            const b: f32 = @bitCast(readXmm32(cpu, insn, 1));
            var r = cpu.getXmmF32(dst);
            r[0] = applyBinOp(f32, a, b, op);
            cpu.setXmmF32(dst, r);
        },
        .pF2 => { // SD
            const a: f64 = @bitCast(@as(u64, @truncate(cpu.xmm[dst])));
            const b: f64 = @bitCast(readXmm64(cpu, insn, 1));
            var r = cpu.getXmmF64(dst);
            r[0] = applyBinOp(f64, a, b, op);
            cpu.setXmmF64(dst, r);
        },
        .p66 => { // PD
            const a = cpu.getXmmF64(dst);
            const b: [2]f64 = @bitCast(readXmm128(cpu, insn, 1));
            cpu.setXmmF64(dst, .{ applyBinOp(f64, a[0], b[0], op), applyBinOp(f64, a[1], b[1], op) });
        },
        .none => { // PS
            const a = cpu.getXmmF32(dst);
            const b: [4]f32 = @bitCast(readXmm128(cpu, insn, 1));
            cpu.setXmmF32(dst, .{ applyBinOp(f32, a[0], b[0], op), applyBinOp(f32, a[1], b[1], op), applyBinOp(f32, a[2], b[2], op), applyBinOp(f32, a[3], b[3], op) });
        },
    }
}

fn applyBinOp(comptime T: type, a: T, b: T, op: BinOp) T {
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => if (b != 0) a / b else 0,
        .min => @min(a, b),
        .max => @max(a, b),
    };
}

fn execConvertFloat(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix) void {
    const dst = getRegIdx(insn, 0);
    switch (pfx) {
        .pF3 => { // CVTSS2SD
            const f: f32 = @bitCast(readXmm32(cpu, insn, 1));
            var d = cpu.getXmmF64(dst);
            d[0] = f;
            cpu.setXmmF64(dst, d);
        },
        .pF2 => { // CVTSD2SS
            const d: f64 = @bitCast(readXmm64(cpu, insn, 1));
            var f = cpu.getXmmF32(dst);
            f[0] = @floatCast(d);
            cpu.setXmmF32(dst, f);
        },
        .p66 => { // CVTPD2PS
            const d: [2]f64 = @bitCast(readXmm128(cpu, insn, 1));
            cpu.xmm[dst] = @bitCast([4]f32{ @floatCast(d[0]), @floatCast(d[1]), 0, 0 });
        },
        .none => { // CVTPS2PD
            const f: [4]f32 = @bitCast(readXmm128(cpu, insn, 1));
            cpu.xmm[dst] = @bitCast([2]f64{ f[0], f[1] });
        },
    }
}

fn execConvertDqPs(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix) void {
    const dst = getRegIdx(insn, 0);
    const src = readXmm128(cpu, insn, 1);
    switch (pfx) {
        .none => { // CVTDQ2PS
            const ints: [4]i32 = @bitCast(src);
            cpu.xmm[dst] = @bitCast([4]f32{ @floatFromInt(ints[0]), @floatFromInt(ints[1]), @floatFromInt(ints[2]), @floatFromInt(ints[3]) });
        },
        .p66 => { // CVTPS2DQ (round)
            const fs: [4]f32 = @bitCast(src);
            var r: [4]i32 = undefined;
            for (0..4) |i| r[i] = @bitCast(floatToI32(f32, fs[i]));
            cpu.xmm[dst] = @bitCast(r);
        },
        .pF3 => { // CVTTPS2DQ (truncate)
            const fs: [4]f32 = @bitCast(src);
            var r: [4]i32 = undefined;
            for (0..4) |i| r[i] = @bitCast(floatToI32(f32, fs[i]));
            cpu.xmm[dst] = @bitCast(r);
        },
        else => {},
    }
}

fn execConvertE6(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix) void {
    const dst = getRegIdx(insn, 0);
    const src = readXmm128(cpu, insn, 1);
    switch (pfx) {
        .p66 => { // CVTTPD2DQ
            const d: [2]f64 = @bitCast(src);
            cpu.xmm[dst] = @bitCast([4]i32{ @bitCast(floatToI32(f64, d[0])), @bitCast(floatToI32(f64, d[1])), 0, 0 });
        },
        .pF2 => { // CVTPD2DQ
            const d: [2]f64 = @bitCast(src);
            cpu.xmm[dst] = @bitCast([4]i32{ @bitCast(floatToI32(f64, d[0])), @bitCast(floatToI32(f64, d[1])), 0, 0 });
        },
        .pF3 => { // CVTDQ2PD
            const ints: [4]i32 = @bitCast(src);
            cpu.xmm[dst] = @bitCast([2]f64{ @floatFromInt(ints[0]), @floatFromInt(ints[1]) });
        },
        else => {},
    }
}

fn execCmpFloat(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix) void {
    const dst = getRegIdx(insn, 0);
    const pred: u3 = @truncate(insn.imm);
    switch (pfx) {
        .pF3 => { // CMPSS
            const a: f32 = @bitCast(@as(u32, @truncate(cpu.xmm[dst])));
            const b: f32 = @bitCast(readXmm32(cpu, insn, 1));
            var r = cpu.getXmmU32(dst);
            r[0] = if (cmpFloat(f32, a, b, pred)) 0xFFFFFFFF else 0;
            cpu.setXmmU32(dst, r);
        },
        .pF2 => { // CMPSD
            const a: f64 = @bitCast(@as(u64, @truncate(cpu.xmm[dst])));
            const b: f64 = @bitCast(readXmm64(cpu, insn, 1));
            var r = cpu.getXmmU64(dst);
            r[0] = if (cmpFloat(f64, a, b, pred)) 0xFFFFFFFFFFFFFFFF else 0;
            cpu.setXmmU64(dst, r);
        },
        .p66 => { // CMPPD
            const a = cpu.getXmmF64(dst);
            const b: [2]f64 = @bitCast(readXmm128(cpu, insn, 1));
            cpu.setXmmU64(dst, .{
                if (cmpFloat(f64, a[0], b[0], pred)) 0xFFFFFFFFFFFFFFFF else 0,
                if (cmpFloat(f64, a[1], b[1], pred)) 0xFFFFFFFFFFFFFFFF else 0,
            });
        },
        .none => { // CMPPS
            const a = cpu.getXmmF32(dst);
            const b: [4]f32 = @bitCast(readXmm128(cpu, insn, 1));
            cpu.setXmmU32(dst, .{
                if (cmpFloat(f32, a[0], b[0], pred)) 0xFFFFFFFF else 0,
                if (cmpFloat(f32, a[1], b[1], pred)) 0xFFFFFFFF else 0,
                if (cmpFloat(f32, a[2], b[2], pred)) 0xFFFFFFFF else 0,
                if (cmpFloat(f32, a[3], b[3], pred)) 0xFFFFFFFF else 0,
            });
        },
    }
}

// -----------------------------------------------------------------------
// Bitwise 128-bit ops
// -----------------------------------------------------------------------

const BitwiseOp = enum { @"and", @"or", xor, andn };

fn execBitwise128(cpu: *Cpu, insn: *const Instruction, op: BitwiseOp) void {
    const dst = getRegIdx(insn, 0);
    const pfx = getPrefix(insn);
    if (pfx == .p66 or pfx == .none) {
        const a = cpu.xmm[dst];
        const b = readXmm128(cpu, insn, 1);
        cpu.xmm[dst] = switch (op) {
            .@"and" => a & b,
            .@"or" => a | b,
            .xor => a ^ b,
            .andn => (~a) & b,
        };
    } else { // MMX
        const a = cpu.getMmx(dst);
        const b = readXmm64(cpu, insn, 1);
        cpu.setMmx(dst, switch (op) {
            .@"and" => a & b,
            .@"or" => a | b,
            .xor => a ^ b,
            .andn => (~a) & b,
        });
    }
}

// -----------------------------------------------------------------------
// Integer SIMD binary operations
// -----------------------------------------------------------------------

const IntOp = enum { add, sub, mullo, mulhi, mulhu, adds, subs, addus, subus, minu, maxu, mins, maxs, avg };

fn execIntBin(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix, comptime elem_size: comptime_int, op: IntOp) void {
    const dst = getRegIdx(insn, 0);
    if (pfx == .p66) {
        const a: [16]u8 = @bitCast(cpu.xmm[dst]);
        const b: [16]u8 = @bitCast(readXmm128(cpu, insn, 1));
        cpu.xmm[dst] = @bitCast(intBinOp(16, elem_size, a, b, op));
    } else {
        const a: [8]u8 = @bitCast(cpu.getMmx(dst));
        const b: [8]u8 = @bitCast(readXmm64(cpu, insn, 1));
        cpu.setMmx(dst, @bitCast(intBinOp(8, elem_size, a, b, op)));
    }
}

fn intBinOp(comptime total: comptime_int, comptime elem: comptime_int, a_bytes: [total]u8, b_bytes: [total]u8, op: IntOp) [total]u8 {
    const lanes = total / elem;
    const UType = std.meta.Int(.unsigned, elem * 8);
    const SType = std.meta.Int(.signed, elem * 8);
    const WideU = std.meta.Int(.unsigned, elem * 16);
    const WideS = std.meta.Int(.signed, elem * 16);

    var a_elems: [lanes]UType = undefined;
    var b_elems: [lanes]UType = undefined;
    for (0..lanes) |i| {
        a_elems[i] = std.mem.readInt(UType, a_bytes[i * elem ..][0..elem], .little);
        b_elems[i] = std.mem.readInt(UType, b_bytes[i * elem ..][0..elem], .little);
    }

    var r: [lanes]UType = undefined;
    for (0..lanes) |i| {
        const a = a_elems[i];
        const b = b_elems[i];
        r[i] = switch (op) {
            .add => a +% b,
            .sub => a -% b,
            .mullo => @truncate(@as(WideU, a) *% @as(WideU, b)),
            .mulhi => @truncate(@as(WideU, @bitCast(@as(WideS, @as(SType, @bitCast(a))) *% @as(WideS, @as(SType, @bitCast(b))))) >> (elem * 8)),
            .mulhu => @truncate((@as(WideU, a) *% @as(WideU, b)) >> (elem * 8)),
            .adds => @bitCast(@as(SType, @bitCast(a)) +| @as(SType, @bitCast(b))),
            .subs => @bitCast(@as(SType, @bitCast(a)) -| @as(SType, @bitCast(b))),
            .addus => a +| b,
            .subus => a -| b,
            .minu => @min(a, b),
            .maxu => @max(a, b),
            .mins => @bitCast(@min(@as(SType, @bitCast(a)), @as(SType, @bitCast(b)))),
            .maxs => @bitCast(@max(@as(SType, @bitCast(a)), @as(SType, @bitCast(b)))),
            .avg => @truncate((@as(WideU, a) + @as(WideU, b) + 1) >> 1),
        };
    }

    var result: [total]u8 = undefined;
    for (0..lanes) |i| {
        std.mem.writeInt(UType, result[i * elem ..][0..elem], r[i], .little);
    }
    return result;
}

// -----------------------------------------------------------------------
// Integer compare
// -----------------------------------------------------------------------

const CmpKind = enum { eq, gt };

fn execPcmp(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix, comptime elem: comptime_int, kind: CmpKind) void {
    const dst = getRegIdx(insn, 0);
    if (pfx == .p66) {
        const a: [16]u8 = @bitCast(cpu.xmm[dst]);
        const b: [16]u8 = @bitCast(readXmm128(cpu, insn, 1));
        cpu.xmm[dst] = @bitCast(intCmpOp(16, elem, a, b, kind));
    } else {
        const a: [8]u8 = @bitCast(cpu.getMmx(dst));
        const b: [8]u8 = @bitCast(readXmm64(cpu, insn, 1));
        cpu.setMmx(dst, @bitCast(intCmpOp(8, elem, a, b, kind)));
    }
}

fn intCmpOp(comptime total: comptime_int, comptime elem: comptime_int, a_bytes: [total]u8, b_bytes: [total]u8, kind: CmpKind) [total]u8 {
    const lanes = total / elem;
    const SType = std.meta.Int(.signed, elem * 8);
    const UType = std.meta.Int(.unsigned, elem * 8);
    var result: [total]u8 = undefined;
    for (0..lanes) |i| {
        const a: SType = @bitCast(std.mem.readInt(UType, a_bytes[i * elem ..][0..elem], .little));
        const b: SType = @bitCast(std.mem.readInt(UType, b_bytes[i * elem ..][0..elem], .little));
        const mask: UType = switch (kind) {
            .eq => if (a == b) @as(UType, @bitCast(@as(SType, -1))) else 0,
            .gt => if (a > b) @as(UType, @bitCast(@as(SType, -1))) else 0,
        };
        std.mem.writeInt(UType, result[i * elem ..][0..elem], mask, .little);
    }
    return result;
}

// -----------------------------------------------------------------------
// Pack operations
// -----------------------------------------------------------------------

const PackWidth = enum { wb, dw };

fn execPackSS(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix, width: PackWidth) void {
    const dst = getRegIdx(insn, 0);
    if (pfx == .p66) {
        const a: [16]u8 = @bitCast(cpu.xmm[dst]);
        const b: [16]u8 = @bitCast(readXmm128(cpu, insn, 1));
        cpu.xmm[dst] = @bitCast(packSSImpl(16, a, b, width));
    } else {
        const a: [8]u8 = @bitCast(cpu.getMmx(dst));
        const b: [8]u8 = @bitCast(readXmm64(cpu, insn, 1));
        cpu.setMmx(dst, @bitCast(packSSImpl(8, a, b, width)));
    }
}

fn packSSImpl(comptime total: comptime_int, a: [total]u8, b: [total]u8, width: PackWidth) [total]u8 {
    var result: [total]u8 = undefined;
    if (width == .wb) {
        const lanes = total / 2;
        for (0..lanes) |i| {
            const va: i16 = @bitCast(std.mem.readInt(u16, a[i * 2 ..][0..2], .little));
            const vb: i16 = @bitCast(std.mem.readInt(u16, b[i * 2 ..][0..2], .little));
            result[i] = @bitCast(std.math.clamp(@as(i8, @intCast(std.math.clamp(va, -128, 127))), -128, 127));
            result[lanes + i] = @bitCast(std.math.clamp(@as(i8, @intCast(std.math.clamp(vb, -128, 127))), -128, 127));
        }
    } else {
        const lanes = total / 4;
        for (0..lanes) |i| {
            const va: i32 = @bitCast(std.mem.readInt(u32, a[i * 4 ..][0..4], .little));
            const vb: i32 = @bitCast(std.mem.readInt(u32, b[i * 4 ..][0..4], .little));
            std.mem.writeInt(i16, result[i * 2 ..][0..2], @intCast(std.math.clamp(va, -32768, 32767)), .little);
            std.mem.writeInt(i16, result[lanes * 2 + i * 2 ..][0..2], @intCast(std.math.clamp(vb, -32768, 32767)), .little);
        }
    }
    return result;
}

fn execPackUS(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix) void {
    const dst = getRegIdx(insn, 0);
    if (pfx == .p66) {
        const a: [8]i16 = @bitCast(cpu.xmm[dst]);
        const b: [8]i16 = @bitCast(readXmm128(cpu, insn, 1));
        var r: [16]u8 = undefined;
        for (0..8) |i| r[i] = @intCast(@as(u16, @bitCast(std.math.clamp(a[i], 0, 255))));
        for (0..8) |i| r[8 + i] = @intCast(@as(u16, @bitCast(std.math.clamp(b[i], 0, 255))));
        cpu.xmm[dst] = @bitCast(r);
    } else {
        const a: [4]i16 = @bitCast(cpu.getMmx(dst));
        const b: [4]i16 = @bitCast(readXmm64(cpu, insn, 1));
        var r: [8]u8 = undefined;
        for (0..4) |i| r[i] = @intCast(@as(u16, @bitCast(std.math.clamp(a[i], 0, 255))));
        for (0..4) |i| r[4 + i] = @intCast(@as(u16, @bitCast(std.math.clamp(b[i], 0, 255))));
        cpu.setMmx(dst, @bitCast(r));
    }
}

// -----------------------------------------------------------------------
// Unpack/Interleave
// -----------------------------------------------------------------------

fn execPunpckl(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix, comptime elem: comptime_int) void {
    const dst = getRegIdx(insn, 0);
    if (pfx == .p66) {
        const a: [16]u8 = @bitCast(cpu.xmm[dst]);
        const b: [16]u8 = @bitCast(readXmm128(cpu, insn, 1));
        cpu.xmm[dst] = @bitCast(interleave(16, elem, a, b, false));
    } else {
        const a: [8]u8 = @bitCast(cpu.getMmx(dst));
        const b: [8]u8 = @bitCast(readXmm64(cpu, insn, 1));
        cpu.setMmx(dst, @bitCast(interleave(8, elem, a, b, false)));
    }
}

fn execPunpckh(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix, comptime elem: comptime_int) void {
    const dst = getRegIdx(insn, 0);
    if (pfx == .p66) {
        const a: [16]u8 = @bitCast(cpu.xmm[dst]);
        const b: [16]u8 = @bitCast(readXmm128(cpu, insn, 1));
        cpu.xmm[dst] = @bitCast(interleave(16, elem, a, b, true));
    } else {
        const a: [8]u8 = @bitCast(cpu.getMmx(dst));
        const b: [8]u8 = @bitCast(readXmm64(cpu, insn, 1));
        cpu.setMmx(dst, @bitCast(interleave(8, elem, a, b, true)));
    }
}

fn interleave(comptime total: comptime_int, comptime elem: comptime_int, a: [total]u8, b: [total]u8, comptime high: bool) [total]u8 {
    const pairs = total / (elem * 2);
    const offset = if (high) pairs * elem else 0;
    var result: [total]u8 = undefined;
    for (0..pairs) |i| {
        const dst_off = i * elem * 2;
        @memcpy(result[dst_off..][0..elem], a[offset + i * elem ..][0..elem]);
        @memcpy(result[dst_off + elem ..][0..elem], b[offset + i * elem ..][0..elem]);
    }
    return result;
}

// -----------------------------------------------------------------------
// Shift operations
// -----------------------------------------------------------------------

const ShiftKind = enum { sll, srl, sra };

fn execShiftReg(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix, comptime elem: comptime_int, kind: ShiftKind) void {
    const dst = getRegIdx(insn, 0);
    const count: u64 = readXmm64(cpu, insn, 1);
    if (pfx == .p66) {
        cpu.xmm[dst] = @bitCast(shiftImpl(16, elem, @bitCast(cpu.xmm[dst]), count, kind));
    } else {
        cpu.setMmx(dst, @bitCast(shiftImpl(8, elem, @bitCast(cpu.getMmx(dst)), count, kind)));
    }
}

fn execGroupShift(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix, comptime elem: comptime_int) void {
    const sub = if (insn.modrm) |m| m.reg else return;
    const kind: ShiftKind = switch (sub) {
        2 => .srl,
        4 => .sra,
        6 => .sll,
        else => return,
    };
    const count: u64 = insn.imm;
    if (pfx == .p66) {
        const dst = if (insn.operands[0] == .reg) insn.operands[0].reg else return;
        cpu.xmm[dst] = @bitCast(shiftImpl(16, elem, @bitCast(cpu.xmm[dst]), count, kind));
    } else {
        const dst = if (insn.operands[0] == .reg) insn.operands[0].reg else return;
        cpu.setMmx(dst, @bitCast(shiftImpl(8, elem, @bitCast(cpu.getMmx(dst)), count, kind)));
    }
}

fn shiftImpl(comptime total: comptime_int, comptime elem: comptime_int, data: [total]u8, count: u64, kind: ShiftKind) [total]u8 {
    const lanes = total / elem;
    const bits = elem * 8;
    const UType = std.meta.Int(.unsigned, bits);
    const SType = std.meta.Int(.signed, bits);
    const ShiftT = std.meta.Int(.unsigned, std.math.log2(bits));

    var result: [total]u8 = undefined;
    if (count >= bits) {
        // Shift amount >= element width: result is 0 (or sign-extended for SRA)
        for (0..lanes) |i| {
            if (kind == .sra) {
                const v: SType = @bitCast(std.mem.readInt(UType, data[i * elem ..][0..elem], .little));
                std.mem.writeInt(UType, result[i * elem ..][0..elem], @bitCast(v >> @as(ShiftT, @intCast(bits - 1))), .little);
            } else {
                @memset(result[i * elem ..][0..elem], 0);
            }
        }
    } else {
        const sh: ShiftT = @intCast(count);
        for (0..lanes) |i| {
            const v = std.mem.readInt(UType, data[i * elem ..][0..elem], .little);
            const r: UType = switch (kind) {
                .sll => v << sh,
                .srl => v >> sh,
                .sra => @bitCast(@as(SType, @bitCast(v)) >> sh),
            };
            std.mem.writeInt(UType, result[i * elem ..][0..elem], r, .little);
        }
    }
    return result;
}

// -----------------------------------------------------------------------
// Special integer ops
// -----------------------------------------------------------------------

fn execPmuludq(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix) void {
    const dst = getRegIdx(insn, 0);
    if (pfx == .p66) {
        const a: [4]u32 = @bitCast(cpu.xmm[dst]);
        const b: [4]u32 = @bitCast(readXmm128(cpu, insn, 1));
        cpu.xmm[dst] = @bitCast([2]u64{ @as(u64, a[0]) * @as(u64, b[0]), @as(u64, a[2]) * @as(u64, b[2]) });
    } else {
        const a: u32 = @truncate(cpu.getMmx(dst));
        const b: u32 = @truncate(readXmm64(cpu, insn, 1));
        cpu.setMmx(dst, @as(u64, a) * @as(u64, b));
    }
}

fn execPmaddwd(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix) void {
    const dst = getRegIdx(insn, 0);
    if (pfx == .p66) {
        const a: [8]i16 = @bitCast(cpu.xmm[dst]);
        const b: [8]i16 = @bitCast(readXmm128(cpu, insn, 1));
        var r: [4]i32 = undefined;
        for (0..4) |i| r[i] = @as(i32, a[i * 2]) * @as(i32, b[i * 2]) + @as(i32, a[i * 2 + 1]) * @as(i32, b[i * 2 + 1]);
        cpu.xmm[dst] = @bitCast(r);
    } else {
        const a: [4]i16 = @bitCast(cpu.getMmx(dst));
        const b: [4]i16 = @bitCast(readXmm64(cpu, insn, 1));
        var r: [2]i32 = undefined;
        for (0..2) |i| r[i] = @as(i32, a[i * 2]) * @as(i32, b[i * 2]) + @as(i32, a[i * 2 + 1]) * @as(i32, b[i * 2 + 1]);
        cpu.setMmx(dst, @bitCast(r));
    }
}

fn execPsadbw(cpu: *Cpu, insn: *const Instruction, pfx: SsePrefix) void {
    const dst = getRegIdx(insn, 0);
    if (pfx == .p66) {
        const a: [16]u8 = @bitCast(cpu.xmm[dst]);
        const b: [16]u8 = @bitCast(readXmm128(cpu, insn, 1));
        var sum0: u16 = 0;
        var sum1: u16 = 0;
        for (0..8) |i| sum0 += if (a[i] > b[i]) a[i] - b[i] else b[i] - a[i];
        for (8..16) |i| sum1 += if (a[i] > b[i]) a[i] - b[i] else b[i] - a[i];
        cpu.xmm[dst] = @bitCast([4]u32{ sum0, 0, sum1, 0 });
    } else {
        const a: [8]u8 = @bitCast(cpu.getMmx(dst));
        const b: [8]u8 = @bitCast(readXmm64(cpu, insn, 1));
        var sum: u16 = 0;
        for (0..8) |i| sum += if (a[i] > b[i]) a[i] - b[i] else b[i] - a[i];
        cpu.setMmx(dst, sum);
    }
}
