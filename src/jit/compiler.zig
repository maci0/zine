//! x86 to WebAssembly JIT compiler.
//!
//! This module provides the `JitCompiler` struct, which translates x86 machine
//! code basic blocks into standalone WebAssembly modules. It leverages
//! `emitter.zig` for WASM generation and `translate.zig` for x86 instruction
//! mapping.

const std = @import("std");
const wasm = @import("wasm.zig");
const emitter = @import("emitter.zig");
const decoder = @import("../x86/decoder.zig");
const t = @import("translate.zig");
const host = @import("host.zig");

const Body = emitter.Buffer;

/// JIT compiler instance for translating x86 basic blocks to WASM.
pub const JitCompiler = struct {
    allocator: std.mem.Allocator,
    module: emitter.WasmModule,
    block_cache: std.AutoHashMap(u32, u32),
    /// WASM linear memory address of the JitCpuState struct.
    state_addr: u32,

    /// Initializes a new JIT compiler instance.
    pub fn init(allocator: std.mem.Allocator, state_addr: u32) JitCompiler {
        return .{
            .allocator = allocator,
            .module = emitter.WasmModule.init(allocator),
            .block_cache = std.AutoHashMap(u32, u32).init(allocator),
            .state_addr = state_addr,
        };
    }

    /// Frees all resources associated with the JIT compiler.
    pub fn deinit(self: *JitCompiler) void {
        self.block_cache.deinit();
        self.module.deinit();
    }

    /// Compiles a basic block of x86 code starting at `guest_eip` into a WASM binary.
    /// The resulting binary is a standalone WASM module that:
    ///   - Imports shared memory from "env" "memory"
    ///   - Exports a "run" function (void -> void)
    ///   - On entry: loads CPU state from JitCpuState at state_addr
    ///   - Translates straight-line x86 instructions (stops at control flow)
    ///   - On exit: stores CPU state back, sets EIP + status
    pub fn compile(self: *JitCompiler, guest_eip: u32, x86_code: []const u8) ![]u8 {
        var offset: usize = 0;
        try self.block_cache.put(guest_eip, @intCast(self.module.func_section.bytes.items.len));

        // Type section: 1 function type (void -> void)
        try self.module.type_section.appendUleb128(1);
        try self.module.type_section.append(0x60);
        try self.module.type_section.appendUleb128(0);
        try self.module.type_section.appendUleb128(0);

        // Import section: import memory from "env" "memory"
        try self.module.import_section.appendUleb128(1); // 1 import
        try self.module.import_section.appendUleb128(3); // module name length
        try self.module.import_section.appendSlice("env");
        try self.module.import_section.appendUleb128(6); // field name length
        try self.module.import_section.appendSlice("memory");
        try self.module.import_section.append(0x02); // import kind: memory
        try self.module.import_section.append(0x00); // limits: no max
        try self.module.import_section.appendUleb128(1); // initial: 1 page

        // Func section: 1 function of type 0
        try self.module.func_section.appendUleb128(1);
        try self.module.func_section.appendUleb128(0);

        // Export section: export function 0 as "run"
        try self.module.export_section.appendUleb128(1); // 1 export
        try self.module.export_section.appendUleb128(3); // name length
        try self.module.export_section.appendSlice("run");
        try self.module.export_section.append(@intFromEnum(wasm.ExportType.func));
        try self.module.export_section.appendUleb128(0); // function index 0

        // Code section: 1 function body
        var body = Body.init(self.allocator);
        defer body.deinit();

        // Locals: LOCAL_COUNT i32 variables
        try body.appendUleb128(1); // 1 local entry
        try body.appendUleb128(t.LOCAL_COUNT);
        try body.append(@intFromEnum(wasm.ValType.i32));

        // === PROLOGUE: load CPU state from shared memory ===
        try emitPrologue(&body, self.state_addr);

        // === BODY: translate non-control-flow instructions ===
        while (offset < x86_code.len) {
            const insn = decoder.decode(x86_code[offset..]);
            if (insn.length == 0) break;
            if (isControlFlow(&insn)) break;
            try self.translateInstruction(&body, &insn);
            offset += insn.length;
        }

        // === EPILOGUE: store CPU state back to shared memory ===
        const final_eip = guest_eip +% @as(u32, @intCast(offset));
        try emitEpilogue(&body, self.state_addr, final_eip);

        try body.appendOpcode(.end);

        try self.module.code_section.appendUleb128(1);
        try self.module.code_section.appendUleb128(@as(u32, @intCast(body.bytes.items.len)));
        try self.module.code_section.appendSlice(body.bytes.items);

        return self.module.finish();
    }

    /// Returns true if the instruction is control flow (the JIT stops before it,
    /// letting the interpreter handle branches/calls/returns).
    fn isControlFlow(insn: *const decoder.Instruction) bool {
        return switch (insn.opcode) {
            0xE9, 0xEB => true, // JMP rel32, JMP rel8
            0x70...0x7F => true, // Jcc short
            0xE8 => true, // CALL rel32
            0xC3, 0xC2, 0xCB, 0xCA => true, // RET variants
            0xE0...0xE3 => true, // LOOP, LOOPE, LOOPNE, JECXZ
            0xF4, 0xCC, 0xCD => true, // HLT, INT3, INT
            0x0F80...0x0F8F => true, // Jcc near (two-byte)
            0xFF => if (insn.has_modrm) (insn.modrm_reg == 2 or insn.modrm_reg == 4) else false, // CALL/JMP indirect
            else => false,
        };
    }

    /// Emit prologue: load all CPU registers and flags from the state struct.
    fn emitPrologue(body: *Body, state_addr: u32) !void {
        // Load mem_base first (needed for all subsequent memory accesses)
        try body.appendOpcode(.i32_const);
        try body.appendUleb128(state_addr);
        try body.appendOpcode(.i32_load);
        try body.appendUleb128(2); // align=4
        try body.appendUleb128(host.JitCpuState.OFF_MEM_BASE);
        try body.appendOpcode(.local_set);
        try body.appendUleb128(t.LOCAL_MEM_BASE);

        // Load 8 general purpose registers (EAX..EDI at offsets 0..28)
        inline for (0..8) |i| {
            try body.appendOpcode(.i32_const);
            try body.appendUleb128(state_addr);
            try body.appendOpcode(.i32_load);
            try body.appendUleb128(2);
            try body.appendUleb128(@as(u32, i) * 4);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(@as(u32, i));
        }

        // Load EFLAGS and unpack into individual flag locals
        try body.appendOpcode(.i32_const);
        try body.appendUleb128(state_addr);
        try body.appendOpcode(.i32_load);
        try body.appendUleb128(2);
        try body.appendUleb128(host.JitCpuState.OFF_EFLAGS);
        try body.appendOpcode(.local_set);
        try body.appendUleb128(t.LOCAL_SCRATCH);

        // CF = (eflags >> 0) & 1
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(1);
        try body.appendOpcode(.i32_and);
        try body.appendOpcode(.local_set);
        try body.appendUleb128(t.LOCAL_CF);

        // PF = (eflags >> 2) & 1
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(2);
        try body.appendOpcode(.i32_shr_u);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(1);
        try body.appendOpcode(.i32_and);
        try body.appendOpcode(.local_set);
        try body.appendUleb128(t.LOCAL_PF);

        // ZF = (eflags >> 6) & 1
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(6);
        try body.appendOpcode(.i32_shr_u);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(1);
        try body.appendOpcode(.i32_and);
        try body.appendOpcode(.local_set);
        try body.appendUleb128(t.LOCAL_ZF);

        // SF = (eflags >> 7) & 1
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(7);
        try body.appendOpcode(.i32_shr_u);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(1);
        try body.appendOpcode(.i32_and);
        try body.appendOpcode(.local_set);
        try body.appendUleb128(t.LOCAL_SF);

        // DF = (eflags >> 10) & 1
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(10);
        try body.appendOpcode(.i32_shr_u);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(1);
        try body.appendOpcode(.i32_and);
        try body.appendOpcode(.local_set);
        try body.appendUleb128(t.LOCAL_DF);

        // OF = (eflags >> 11) & 1
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(11);
        try body.appendOpcode(.i32_shr_u);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(1);
        try body.appendOpcode(.i32_and);
        try body.appendOpcode(.local_set);
        try body.appendUleb128(t.LOCAL_OF);
    }

    /// Emit epilogue: store all CPU registers and flags back to the state struct.
    fn emitEpilogue(body: *Body, state_addr: u32, final_eip: u32) !void {
        // Store 8 general purpose registers
        inline for (0..8) |i| {
            try body.appendOpcode(.i32_const);
            try body.appendUleb128(state_addr);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(@as(u32, i));
            try body.appendOpcode(.i32_store);
            try body.appendUleb128(2);
            try body.appendUleb128(@as(u32, i) * 4);
        }

        // Pack flag locals back into EFLAGS and store
        try body.appendOpcode(.i32_const);
        try body.appendUleb128(state_addr);

        try body.appendOpcode(.i32_const);
        try body.appendIleb128(0x202); // reserved + IF
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_CF);
        try body.appendOpcode(.i32_or); // CF at bit 0
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_PF);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(2);
        try body.appendOpcode(.i32_shl);
        try body.appendOpcode(.i32_or); // PF at bit 2
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_ZF);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(6);
        try body.appendOpcode(.i32_shl);
        try body.appendOpcode(.i32_or); // ZF at bit 6
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SF);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(7);
        try body.appendOpcode(.i32_shl);
        try body.appendOpcode(.i32_or); // SF at bit 7
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_DF);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(10);
        try body.appendOpcode(.i32_shl);
        try body.appendOpcode(.i32_or); // DF at bit 10
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_OF);
        try body.appendOpcode(.i32_const);
        try body.appendIleb128(11);
        try body.appendOpcode(.i32_shl);
        try body.appendOpcode(.i32_or); // OF at bit 11

        try body.appendOpcode(.i32_store);
        try body.appendUleb128(2);
        try body.appendUleb128(host.JitCpuState.OFF_EFLAGS);

        // Store EIP = address of the first unhandled instruction
        try body.appendOpcode(.i32_const);
        try body.appendUleb128(state_addr);
        try body.appendOpcode(.i32_const);
        try body.appendUleb128(final_eip);
        try body.appendOpcode(.i32_store);
        try body.appendUleb128(2);
        try body.appendUleb128(host.JitCpuState.OFF_EIP);

        // Store status = EXIT_TO_INTERP
        try body.appendOpcode(.i32_const);
        try body.appendUleb128(state_addr);
        try body.appendOpcode(.i32_const);
        try body.appendUleb128(host.JitCpuState.STATUS_EXIT_TO_INTERP);
        try body.appendOpcode(.i32_store);
        try body.appendUleb128(2);
        try body.appendUleb128(host.JitCpuState.OFF_STATUS);
    }

    fn translateInstruction(self: *JitCompiler, body: *Body, insn: *const decoder.Instruction) !void {
        _ = self;
        switch (insn.opcode) {
            // ===== NOP =====
            0x90 => try body.appendOpcode(.nop),

            // ===== MOV reg, imm (B0-B7: 8-bit, B8-BF: 32-bit) =====
            0xB0...0xB7, 0xB8...0xBF => {
                const reg: u3 = @truncate(insn.opcode);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
                try body.appendOpcode(.local_set);
                try body.appendUleb128(reg);
            },

            // ===== PUSH reg (50-57) =====
            0x50...0x57 => {
                const reg: u3 = @truncate(insn.opcode);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(reg);
                try t.emitPush32(body);
            },

            // ===== POP reg (58-5F) =====
            0x58...0x5F => {
                const reg: u3 = @truncate(insn.opcode);
                try t.emitPop32(body);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(reg);
            },

            // ===== PUSH imm32 (68) =====
            0x68 => {
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
                try t.emitPush32(body);
            },

            // ===== PUSH imm8 sign-extended (6A) =====
            0x6A => {
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
                try t.emitPush32(body);
            },

            // ===== ALU r/m, reg (8-bit: 00,08,10,18,20,28,30,38) =====
            // ===== ALU r/m, reg (32-bit: 01,09,11,19,21,29,31,39) =====
            // ===== ALU reg, r/m (8-bit: 02,0A,12,1A,22,2A,32,3A) =====
            // ===== ALU reg, r/m (32-bit: 03,0B,13,1B,23,2B,33,3B) =====
            // ===== ALU AL, imm8 (04,0C,14,1C,24,2C,34,3C) =====
            // ===== ALU EAX, imm32 (05,0D,15,1D,25,2D,35,3D) =====
            0x00...0x05, 0x08...0x0D, 0x10...0x15, 0x18...0x1D,
            0x20...0x25, 0x28...0x2D, 0x30...0x35, 0x38...0x3D,
            => {
                try translateAlu(body, insn);
            },

            // ===== INC reg (40-47) =====
            0x40...0x47 => {
                const reg: u3 = @truncate(insn.opcode);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(reg);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_add);
                try body.appendOpcode(.local_tee);
                try body.appendUleb128(reg);
                try t.emitUpdateZfSf(body);
            },

            // ===== DEC reg (48-4F) =====
            0x48...0x4F => {
                const reg: u3 = @truncate(insn.opcode);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(reg);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_sub);
                try body.appendOpcode(.local_tee);
                try body.appendUleb128(reg);
                try t.emitUpdateZfSf(body);
            },

            // ===== Group 1: ALU r/m, imm (80, 81, 83) =====
            0x80, 0x81, 0x82, 0x83 => {
                try translateGroup1(body, insn);
            },

            // ===== TEST r/m, reg (84=8bit, 85=32bit) =====
            0x84, 0x85 => {
                try t.emitLoadOperand(body, insn, 0);
                try t.emitLoadOperand(body, insn, 1);
                try body.appendOpcode(.i32_and);
                try t.emitUpdateZfSf(body);
                try t.emitClearCfOf(body);
            },

            // ===== XCHG r/m, reg (86, 87) =====
            0x86, 0x87 => {
                if (insn.has_modrm) {
                    if (insn.op0_kind == .reg and insn.op1_kind == .reg) {
                        // reg-reg exchange via scratch
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(insn.op0_reg);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(t.LOCAL_SCRATCH);
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(insn.op1_reg);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(insn.op0_reg);
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(t.LOCAL_SCRATCH);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(insn.op1_reg);
                    }
                }
            },

            // ===== MOV r/m, reg (88=8bit, 89=32bit) =====
            0x88, 0x89 => {
                try t.emitLoadOperand(body, insn, 1);
                try t.emitStoreOperand(body, insn, 0);
            },

            // ===== MOV reg, r/m (8A=8bit, 8B=32bit) =====
            0x8A, 0x8B => {
                try t.emitLoadOperand(body, insn, 1);
                try t.emitStoreOperand(body, insn, 0);
            },

            // ===== LEA reg, [mem] (8D) =====
            0x8D => {
                if (insn.has_modrm) {
                    try t.emitEffectiveAddress(body, insn, 1);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                }
            },

            // ===== MOV Sreg (8C, 8E) — stub as nop =====
            0x8C, 0x8E => {},

            // ===== XCHG EAX, reg (91-97) =====
            0x91...0x97 => {
                const reg: u3 = @truncate(insn.opcode);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_EAX);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(reg);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.REG_EAX);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(reg);
            },

            // ===== CBW/CWDE (98) =====
            0x98 => {
                // Sign-extend AX/AL into EAX (simplified: sign-extend low 16 to 32)
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_EAX);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(16);
                try body.appendOpcode(.i32_shl);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(16);
                try body.appendOpcode(.i32_shr_s);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.REG_EAX);
            },

            // ===== CDQ (99) =====
            0x99 => {
                // EDX = (EAX < 0) ? 0xFFFFFFFF : 0
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_EAX);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(31);
                try body.appendOpcode(.i32_shr_s); // arithmetic shift: fills with sign bit
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.REG_EDX);
            },

            // ===== PUSHFD (9C) =====
            0x9C => {
                // Synthesize EFLAGS from flag locals and push
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(0x202); // Reserved + IF
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_CF);
                try body.appendOpcode(.i32_or); // CF at bit 0
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_ZF);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(6);
                try body.appendOpcode(.i32_shl);
                try body.appendOpcode(.i32_or); // ZF at bit 6
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SF);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(7);
                try body.appendOpcode(.i32_shl);
                try body.appendOpcode(.i32_or); // SF at bit 7
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_OF);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(11);
                try body.appendOpcode(.i32_shl);
                try body.appendOpcode(.i32_or); // OF at bit 11
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_DF);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(10);
                try body.appendOpcode(.i32_shl);
                try body.appendOpcode(.i32_or); // DF at bit 10
                try t.emitPush32(body);
            },

            // ===== POPFD (9D) =====
            0x9D => {
                try t.emitPop32(body);
                try body.appendOpcode(.local_tee);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                // Extract CF (bit 0)
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_CF);
                // ZF (bit 6)
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(6);
                try body.appendOpcode(.i32_shr_u);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_ZF);
                // SF (bit 7)
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(7);
                try body.appendOpcode(.i32_shr_u);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_SF);
                // OF (bit 11)
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(11);
                try body.appendOpcode(.i32_shr_u);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_OF);
                // DF (bit 10)
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(10);
                try body.appendOpcode(.i32_shr_u);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_DF);
            },

            // ===== SAHF (9E) / LAHF (9F) — stub =====
            0x9E, 0x9F => {},

            // ===== MOV AL/EAX, moffs (A0, A1) =====
            0xA0, 0xA1 => {
                try t.emitLoadOperand(body, insn, 0);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.REG_EAX);
            },

            // ===== MOV moffs, AL/EAX (A2, A3) =====
            0xA2, 0xA3 => {
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_EAX);
                try t.emitStoreOperand(body, insn, 1);
            },

            // ===== TEST AL/EAX, imm (A8, A9) =====
            0xA8, 0xA9 => {
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_EAX);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
                try body.appendOpcode(.i32_and);
                try t.emitUpdateZfSf(body);
                try t.emitClearCfOf(body);
            },

            // ===== String ops (A4-AF) — nop stubs =====
            0xA4, 0xA5, 0xA6, 0xA7, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF => {},

            // ===== RET (C3) =====
            0xC3 => {
                try t.emitPop32(body);
                try body.appendOpcode(.drop);
                try body.appendOpcode(.return_);
            },

            // ===== RET imm16 (C2) =====
            0xC2 => {
                try t.emitPop32(body);
                try body.appendOpcode(.drop);
                // ESP += imm
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_ESP);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
                try body.appendOpcode(.i32_add);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.REG_ESP);
                try body.appendOpcode(.return_);
            },

            // ===== MOV r/m8, imm8 (C6) =====
            0xC6 => {
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
                try t.emitStoreOperand(body, insn, 0);
            },

            // ===== MOV r/m32, imm32 (C7) =====
            0xC7 => {
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
                try t.emitStoreOperand(body, insn, 0);
            },

            // ===== LEAVE (C9) =====
            0xC9 => {
                // ESP = EBP
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_EBP);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.REG_ESP);
                // POP EBP
                try t.emitPop32(body);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.REG_EBP);
            },

            // ===== Shift/Rotate (C0, C1, D0, D1, D2, D3) =====
            0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3 => {
                try translateShift(body, insn);
            },

            // ===== CALL rel32 (E8) =====
            0xE8 => {
                // Push return address (placeholder 0)
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_ESP);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(4);
                try body.appendOpcode(.i32_sub);
                try body.appendOpcode(.local_tee);
                try body.appendUleb128(t.REG_ESP);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(0); // Placeholder EIP
                try body.appendOpcode(.i32_store);
                try body.appendUleb128(2);
                try body.appendUleb128(0);
                try body.appendOpcode(.br);
                try body.appendUleb128(0);
            },

            // ===== JMP rel32 (E9) / JMP rel8 (EB) =====
            0xE9, 0xEB => {
                try body.appendOpcode(.br);
                try body.appendUleb128(0);
            },

            // ===== Jcc short (70-7F) =====
            0x70...0x7F => {
                const cc: u4 = @truncate(insn.opcode);
                try t.emitConditionCode(body, cc);
                try body.appendOpcode(.br_if);
                try body.appendUleb128(0);
            },

            // ===== LOOP/LOOPcc/JECXZ (E0-E3) =====
            0xE0 => { // LOOPNE: ECX-=1, jump if ECX!=0 && ZF=0
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_ECX);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_sub);
                try body.appendOpcode(.local_tee);
                try body.appendUleb128(t.REG_ECX);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_ZF);
                try body.appendOpcode(.i32_eqz);
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.br_if);
                try body.appendUleb128(0);
            },
            0xE1 => { // LOOPE: ECX-=1, jump if ECX!=0 && ZF=1
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_ECX);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_sub);
                try body.appendOpcode(.local_tee);
                try body.appendUleb128(t.REG_ECX);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_ZF);
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.br_if);
                try body.appendUleb128(0);
            },
            0xE2 => { // LOOP: ECX-=1, jump if ECX!=0
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_ECX);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_sub);
                try body.appendOpcode(.local_tee);
                try body.appendUleb128(t.REG_ECX);
                try body.appendOpcode(.br_if);
                try body.appendUleb128(0);
            },
            0xE3 => { // JECXZ: jump if ECX==0
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_ECX);
                try body.appendOpcode(.i32_eqz);
                try body.appendOpcode(.br_if);
                try body.appendUleb128(0);
            },

            // ===== Group 3: TEST/NOT/NEG/MUL/IMUL/DIV/IDIV (F6, F7) =====
            0xF6, 0xF7 => {
                try translateGroup3(body, insn);
            },

            // ===== Group 5: INC/DEC/CALL/JMP/PUSH r/m (FF) =====
            0xFF => {
                try translateGroup5(body, insn);
            },

            // ===== Group 4: INC/DEC r/m8 (FE) =====
            0xFE => {
                if (insn.has_modrm) {
                    try t.emitLoadOperand(body, insn, 0);
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(if (insn.modrm_reg == 0) @as(i32, 1) else @as(i32, -1));
                    try body.appendOpcode(.i32_add);
                    try body.appendOpcode(.local_tee);
                    try body.appendUleb128(t.LOCAL_SCRATCH);
                    try t.emitStoreOperand(body, insn, 0);
                    try body.appendOpcode(.local_get);
                    try body.appendUleb128(t.LOCAL_SCRATCH);
                    try t.emitUpdateZfSf(body);
                }
            },

            // ===== Flag manipulation =====
            0xF8 => { try body.appendOpcode(.i32_const); try body.appendIleb128(0); try body.appendOpcode(.local_set); try body.appendUleb128(t.LOCAL_CF); }, // CLC
            0xF9 => { try body.appendOpcode(.i32_const); try body.appendIleb128(1); try body.appendOpcode(.local_set); try body.appendUleb128(t.LOCAL_CF); }, // STC
            0xFC => { try body.appendOpcode(.i32_const); try body.appendIleb128(0); try body.appendOpcode(.local_set); try body.appendUleb128(t.LOCAL_DF); }, // CLD
            0xFD => { try body.appendOpcode(.i32_const); try body.appendIleb128(1); try body.appendOpcode(.local_set); try body.appendUleb128(t.LOCAL_DF); }, // STD
            0xFA, 0xFB => {}, // CLI/STI — nop in usermode
            0xF5 => { // CMC: toggle CF
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_CF);
                try body.appendOpcode(.i32_eqz);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_CF);
            },

            // ===== Two-byte: Jcc near (0F 80-8F) =====
            0x0F80...0x0F8F => {
                const cc: u4 = @truncate(insn.opcode);
                try t.emitConditionCode(body, cc);
                try body.appendOpcode(.br_if);
                try body.appendUleb128(0);
            },

            // ===== SETcc (0F 90-9F) =====
            0x0F90...0x0F9F => {
                const cc: u4 = @truncate(insn.opcode);
                try t.emitConditionCode(body, cc);
                try t.emitStoreOperand(body, insn, 0);
            },

            // ===== MOVZX r32, r/m8 (0F B6) =====
            0x0FB6 => {
                if (insn.has_modrm) {
                    try t.emitLoadOperand(body, insn, 1);
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(0xFF);
                    try body.appendOpcode(.i32_and);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                }
            },
            // ===== MOVZX r32, r/m16 (0F B7) =====
            0x0FB7 => {
                if (insn.has_modrm) {
                    try t.emitLoadOperand(body, insn, 1);
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(@as(i32, 0xFFFF));
                    try body.appendOpcode(.i32_and);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                }
            },
            // ===== MOVSX r32, r/m8 (0F BE) =====
            0x0FBE => {
                if (insn.has_modrm) {
                    try t.emitLoadOperand(body, insn, 1);
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(24);
                    try body.appendOpcode(.i32_shl);
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(24);
                    try body.appendOpcode(.i32_shr_s);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                }
            },
            // ===== MOVSX r32, r/m16 (0F BF) =====
            0x0FBF => {
                if (insn.has_modrm) {
                    try t.emitLoadOperand(body, insn, 1);
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(16);
                    try body.appendOpcode(.i32_shl);
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(16);
                    try body.appendOpcode(.i32_shr_s);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                }
            },

            // ===== IMUL r32, r/m32 (0F AF) =====
            0x0FAF => {
                if (insn.has_modrm) {
                    try body.appendOpcode(.local_get);
                    try body.appendUleb128(insn.modrm_reg);
                    try t.emitLoadOperand(body, insn, 1);
                    try body.appendOpcode(.i32_mul);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                }
            },

            // ===== CMOVcc (0F 40-4F) =====
            0x0F40...0x0F4F => {
                if (insn.has_modrm) {
                    const cc: u4 = @truncate(insn.opcode);
                    try t.emitConditionCode(body, cc);
                    try body.appendOpcode(.if_);
                    try body.append(@intFromEnum(wasm.BlockType.void));
                    try t.emitLoadOperand(body, insn, 1);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                    try body.appendOpcode(.end);
                }
            },

            // ===== BSWAP (0F C8-CF) =====
            0x0FC8...0x0FCF => {
                const reg: u3 = @truncate(insn.opcode);
                // val = get reg; byte-swap via shifts
                try body.appendOpcode(.local_get);
                try body.appendUleb128(reg);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                // result = ((v>>24)&0xFF) | ((v>>8)&0xFF00) | ((v<<8)&0xFF0000) | ((v<<24)&0xFF000000)
                // Simplified: use 4 extractions
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(24);
                try body.appendOpcode(.i32_shr_u);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(8);
                try body.appendOpcode(.i32_shr_u);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(@as(u32, 0xFF00))));
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.i32_or);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(8);
                try body.appendOpcode(.i32_shl);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(@as(u32, 0xFF0000))));
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.i32_or);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(24);
                try body.appendOpcode(.i32_shl);
                try body.appendOpcode(.i32_or);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(reg);
            },

            // ===== BSF (0F BC) =====
            0x0FBC => {
                if (insn.has_modrm) {
                    try t.emitLoadOperand(body, insn, 1);
                    try body.appendOpcode(.i32_ctz);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                }
            },

            // ===== BSR (0F BD) =====
            0x0FBD => {
                if (insn.has_modrm) {
                    // BSR = 31 - CLZ
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(31);
                    try t.emitLoadOperand(body, insn, 1);
                    try body.appendOpcode(.i32_clz);
                    try body.appendOpcode(.i32_sub);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                }
            },

            // ===== IMUL r, r/m, imm32 (69) / IMUL r, r/m, imm8 (6B) =====
            0x69, 0x6B => {
                if (insn.has_modrm) {
                    try t.emitLoadOperand(body, insn, 1);
                    try body.appendOpcode(.i32_const);
                    try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
                    try body.appendOpcode(.i32_mul);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                }
            },

            // ===== PUSHAD (60) =====
            0x60 => {
                // Push EAX,ECX,EDX,EBX,orig_ESP,EBP,ESI,EDI
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_ESP);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                inline for ([_]u32{ 0, 1, 2, 3 }) |r| {
                    try body.appendOpcode(.local_get);
                    try body.appendUleb128(r);
                    try t.emitPush32(body);
                }
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                try t.emitPush32(body);
                inline for ([_]u32{ 5, 6, 7 }) |r| {
                    try body.appendOpcode(.local_get);
                    try body.appendUleb128(r);
                    try t.emitPush32(body);
                }
            },

            // ===== POPAD (61) =====
            0x61 => {
                inline for ([_]u32{ 7, 6, 5 }) |r| {
                    try t.emitPop32(body);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(r);
                }
                try t.emitPop32(body);
                try body.appendOpcode(.drop);
                inline for ([_]u32{ 3, 2, 1, 0 }) |r| {
                    try t.emitPop32(body);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(r);
                }
            },

            // ===== Stubs for rarely-used instructions =====
            0xCC, 0xCD, 0xF4 => {}, // INT3, INT, HLT
            0x06, 0x07, 0x0E, 0x16, 0x17, 0x1E, 0x1F => {}, // segment push/pop
            0x27, 0x2F, 0x37, 0x3F => {}, // BCD adjust
            0x62 => {}, // BOUND
            0x6C, 0x6D, 0x6E, 0x6F => {}, // INS/OUTS
            0xC8 => {}, // ENTER
            0xC4, 0xC5 => {}, // LES/LDS
            0xD4, 0xD5 => {}, // AAM/AAD
            0xD7 => {}, // XLAT
            0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF => {}, // FPU
            0xE4, 0xE5, 0xE6, 0xE7, 0xEC, 0xED, 0xEE, 0xEF => {}, // IN/OUT
            0x9B, 0xF1 => {}, // FWAIT, INT1
            0x0F18, 0x0F19, 0x0F1A, 0x0F1B, 0x0F1C, 0x0F1D, 0x0F1E, 0x0F1F => {}, // NOP hints
            0x0FA0, 0x0FA1, 0x0FA8, 0x0FA9 => {}, // PUSH/POP FS/GS
            0x0FA3, 0x0FAB, 0x0FB3, 0x0FBB, 0x0FBA => {}, // BT family
            0x0FA4, 0x0FA5, 0x0FAC, 0x0FAD => {}, // SHLD/SHRD
            0x0FC0, 0x0FC1 => {}, // XADD
            0x0FB0, 0x0FB1 => {}, // CMPXCHG
            0x0F02, 0x0F03 => {}, // LAR/LSL

            // Default: ignore unimplemented
            else => {},
        }
    }
};

// =======================================================================
// Sub-translators (factored out to keep the main switch readable)
// =======================================================================

fn translateAlu(body: *Body, insn: *const decoder.Instruction) !void {
    const group: u3 = @truncate(insn.opcode >> 3);
    const wasm_op = t.aluGroupToWasmOp(group) orelse return;

    // Load destination and source
    try t.emitLoadOperand(body, insn, 0);
    try t.emitLoadOperand(body, insn, 1);

    // Perform operation
    try body.appendOpcode(wasm_op);

    // CMP/TEST don't store — just update flags
    if (group == 7) {
        // CMP: result on stack, compute ZF/SF, don't store
        try t.emitUpdateZfSf(body);
    } else {
        // Store result to destination, then update flags from the stored value
        try body.appendOpcode(.local_tee);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try t.emitStoreOperand(body, insn, 0);
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try t.emitUpdateZfSf(body);
    }

    // Logic ops clear CF/OF
    if (group == 1 or group == 4 or group == 6) {
        try t.emitClearCfOf(body);
    }
}

fn translateGroup1(body: *Body, insn: *const decoder.Instruction) !void {
    if (!insn.has_modrm) return;
    const sub_op = insn.modrm_reg;
    const wasm_op = t.aluGroupToWasmOp(sub_op) orelse return;

    try t.emitLoadOperand(body, insn, 0);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
    try body.appendOpcode(wasm_op);

    if (sub_op == 7) { // CMP
        try t.emitUpdateZfSf(body);
    } else {
        try body.appendOpcode(.local_tee);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try t.emitStoreOperand(body, insn, 0);
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try t.emitUpdateZfSf(body);
    }

    if (sub_op == 1 or sub_op == 4 or sub_op == 6) {
        try t.emitClearCfOf(body);
    }
}

fn translateShift(body: *Body, insn: *const decoder.Instruction) !void {
    if (!insn.has_modrm) return;
    const sub_op = insn.modrm_reg;

    try t.emitLoadOperand(body, insn, 0);

    // Get shift count
    switch (insn.opcode) {
        0xD0, 0xD1 => {
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(1);
        },
        0xD2, 0xD3 => {
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.REG_ECX);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(31);
            try body.appendOpcode(.i32_and);
        },
        0xC0, 0xC1 => {
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(@as(i32, @bitCast(insn.imm & 31)));
        },
        else => return,
    }

    switch (sub_op) {
        0 => try body.appendOpcode(.i32_rotl), // ROL
        1 => try body.appendOpcode(.i32_rotr), // ROR
        4 => try body.appendOpcode(.i32_shl), // SHL
        5 => try body.appendOpcode(.i32_shr_u), // SHR
        7 => try body.appendOpcode(.i32_shr_s), // SAR
        else => {
            try body.appendOpcode(.drop);
            return;
        },
    }

    try body.appendOpcode(.local_tee);
    try body.appendUleb128(t.LOCAL_SCRATCH);
    try t.emitStoreOperand(body, insn, 0);
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_SCRATCH);
    try t.emitUpdateZfSf(body);
}

fn translateGroup3(body: *Body, insn: *const decoder.Instruction) !void {
    if (!insn.has_modrm) return;
    switch (insn.modrm_reg) {
        0, 1 => { // TEST r/m, imm
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
            try body.appendOpcode(.i32_and);
            try t.emitUpdateZfSf(body);
            try t.emitClearCfOf(body);
        },
        2 => { // NOT
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(-1);
            try body.appendOpcode(.i32_xor);
            try t.emitStoreOperand(body, insn, 0);
        },
        3 => { // NEG
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0);
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_sub);
            try body.appendOpcode(.local_tee);
            try body.appendUleb128(t.LOCAL_SCRATCH);
            try t.emitStoreOperand(body, insn, 0);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.LOCAL_SCRATCH);
            try t.emitUpdateZfSf(body);
        },
        4 => { // MUL (unsigned): EDX:EAX = EAX * r/m
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.REG_EAX);
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_mul);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.REG_EAX);
            // EDX = 0 (simplified — 32x32->32 only)
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.REG_EDX);
        },
        5 => { // IMUL (signed)
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.REG_EAX);
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_mul);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.REG_EAX);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.REG_EDX);
        },
        6 => { // DIV (unsigned)
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.REG_EAX);
            try body.appendOpcode(.local_tee);
            try body.appendUleb128(t.LOCAL_SCRATCH);
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_div_u);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.REG_EAX);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.LOCAL_SCRATCH);
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_rem_u);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.REG_EDX);
        },
        7 => { // IDIV (signed)
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.REG_EAX);
            try body.appendOpcode(.local_tee);
            try body.appendUleb128(t.LOCAL_SCRATCH);
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_div_s);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.REG_EAX);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.LOCAL_SCRATCH);
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_rem_s);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.REG_EDX);
        },
    }
}

fn translateGroup5(body: *Body, insn: *const decoder.Instruction) !void {
    if (!insn.has_modrm) return;
    switch (insn.modrm_reg) {
        0 => { // INC r/m32
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(1);
            try body.appendOpcode(.i32_add);
            try body.appendOpcode(.local_tee);
            try body.appendUleb128(t.LOCAL_SCRATCH);
            try t.emitStoreOperand(body, insn, 0);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.LOCAL_SCRATCH);
            try t.emitUpdateZfSf(body);
        },
        1 => { // DEC r/m32
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(1);
            try body.appendOpcode(.i32_sub);
            try body.appendOpcode(.local_tee);
            try body.appendUleb128(t.LOCAL_SCRATCH);
            try t.emitStoreOperand(body, insn, 0);
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.LOCAL_SCRATCH);
            try t.emitUpdateZfSf(body);
        },
        2 => { // CALL r/m32 (indirect)
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.drop);
            try body.appendOpcode(.br);
            try body.appendUleb128(0);
        },
        4 => { // JMP r/m32 (indirect)
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.drop);
            try body.appendOpcode(.br);
            try body.appendUleb128(0);
        },
        6 => { // PUSH r/m32
            try t.emitLoadOperand(body, insn, 0);
            try t.emitPush32(body);
        },
        else => {},
    }
}

// =======================================================================
// Tests
// =======================================================================

test "jit compiler basic structure" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    const x86_test_code = [_]u8{
        0xB8, 0x01, 0x00, 0x00, 0x00, // MOV EAX, 1
        0xB9, 0x02, 0x00, 0x00, 0x00, // MOV ECX, 2
        0x01, 0xC8, // ADD EAX, ECX
    };

    const wasm_bin = try compiler.compile(0x1000, &x86_test_code);
    defer std.testing.allocator.free(wasm_bin);

    // Valid WASM binary: starts with magic \0asm
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d }, wasm_bin[0..4]);
    // 3 x86 instructions should produce substantial WASM output
    try std.testing.expect(wasm_bin.len > 40);
}

test "jit compiler push/pop" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    const code = [_]u8{
        0x50, // PUSH EAX
        0x5B, // POP EBX
    };

    const wasm_bin = try compiler.compile(0x2000, &code);
    defer std.testing.allocator.free(wasm_bin);

    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d }, wasm_bin[0..4]);
    try std.testing.expect(wasm_bin.len > 40);
}

test "jit compiler group1 sub imm" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    const code = [_]u8{
        0x83, 0xE8, 0x05, // SUB EAX, 5 (83 /5 ib)
    };

    const wasm_bin = try compiler.compile(0x3000, &code);
    defer std.testing.allocator.free(wasm_bin);

    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d }, wasm_bin[0..4]);
    try std.testing.expect(wasm_bin.len > 40);
}

test "jit compiler stops at control flow" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    // Jcc is control flow — the compiler stops before it.
    // Block: MOV EAX,1 + JE → only MOV is translated.
    const code_with_jcc = [_]u8{
        0xB8, 0x01, 0x00, 0x00, 0x00, // MOV EAX, 1
        0x74, 0x00, // JE +0 (control flow — compiler stops here)
        0xB9, 0x02, 0x00, 0x00, 0x00, // MOV ECX, 2 (not reached)
    };

    const wasm_jcc = try compiler.compile(0x4000, &code_with_jcc);
    defer std.testing.allocator.free(wasm_jcc);

    // Compile same first instruction without control flow
    compiler.module.deinit();
    compiler.module = @import("emitter.zig").WasmModule.init(std.testing.allocator);
    const code_no_jcc = [_]u8{
        0xB8, 0x01, 0x00, 0x00, 0x00, // MOV EAX, 1
        0xB9, 0x02, 0x00, 0x00, 0x00, // MOV ECX, 2
    };
    const wasm_no_jcc = try compiler.compile(0x5000, &code_no_jcc);
    defer std.testing.allocator.free(wasm_no_jcc);

    // With JE present, only 1 instruction translated → smaller output than 2 instructions
    try std.testing.expect(wasm_jcc.len < wasm_no_jcc.len);
}

test "jit compiler shifts" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    const code = [_]u8{
        0xC1, 0xE0, 0x04, // SHL EAX, 4
        0xC1, 0xE8, 0x02, // SHR EAX, 2
        0xC1, 0xF8, 0x01, // SAR EAX, 1
    };

    const wasm_bin = try compiler.compile(0x5000, &code);
    defer std.testing.allocator.free(wasm_bin);

    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d }, wasm_bin[0..4]);
    // 3 shift instructions should produce more output than 1 instruction
    try std.testing.expect(wasm_bin.len > 60);
}

test "jit compiler movzx/movsx" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    const code = [_]u8{
        0x0F, 0xB6, 0xC1, // MOVZX EAX, CL
        0x0F, 0xBE, 0xC1, // MOVSX EAX, CL
    };

    const wasm_bin = try compiler.compile(0x6000, &code);
    defer std.testing.allocator.free(wasm_bin);

    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d }, wasm_bin[0..4]);
    try std.testing.expect(wasm_bin.len > 40);
}

test "jit compiler lea" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    const code = [_]u8{
        0x8D, 0x44, 0x8B, 0x10, // LEA EAX, [EBX+ECX*4+0x10]
    };

    const wasm_bin = try compiler.compile(0x7000, &code);
    defer std.testing.allocator.free(wasm_bin);

    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d }, wasm_bin[0..4]);
    // LEA with SIB addressing should produce substantial WASM code
    try std.testing.expect(wasm_bin.len > 40);
}
