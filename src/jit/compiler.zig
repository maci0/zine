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

/// Sentinel for an unused block-cache slot. 0xFFFFFFFF is not a valid
/// guest EIP (the guest address space ends at 0xFFFFFFFF inclusive only as an
/// unmapped probe), so it can never collide with a real key.
pub const EMPTY_KEY: u32 = 0xFFFFFFFF;

/// Number of slots in the direct-mapped block caches.
pub const BLOCK_CACHE_SLOTS: u32 = 4096;
pub const BLOCK_CACHE_MASK: u32 = BLOCK_CACHE_SLOTS - 1;

/// Largest x86 block the JIT scans and compiles (runner.scanBlock window).
pub const MAX_JIT_BLOCK_BYTES: usize = 256;

/// Direct-mapped guest EIP → compiled block index that revalidates the x86
/// bytes the block was compiled from on every hit.
///
/// A cached block is only reusable while the guest bytes at its EIP are
/// unchanged: a guest that patches its own code, or a memory region that is
/// unmapped and remapped at the same address, would otherwise execute the
/// previously compiled translation of bytes that no longer exist. The check
/// mirrors x86/decode_cache.zig, which validates the full decode input.
///
/// A hit therefore means "these exact bytes were compiled into block id N",
/// not merely "something was compiled for this EIP once".
pub const BlockIndex = struct {
    allocator: std.mem.Allocator,
    keys: []u32,
    vals: []u32,
    /// Bytes compiled per slot, BLOCK_CACHE_SLOTS * MAX_JIT_BLOCK_BYTES long.
    code: []u8,
    /// Compiled length per slot, 0 for an empty slot.
    code_len: []u8,

    pub fn init(allocator: std.mem.Allocator) !BlockIndex {
        const slot_count: usize = BLOCK_CACHE_SLOTS;
        const keys = try allocator.alloc(u32, slot_count);
        errdefer allocator.free(keys);
        const vals = try allocator.alloc(u32, slot_count);
        errdefer allocator.free(vals);
        const code = try allocator.alloc(u8, slot_count * MAX_JIT_BLOCK_BYTES);
        errdefer allocator.free(code);
        const code_len = try allocator.alloc(u8, slot_count);
        errdefer allocator.free(code_len);

        @memset(keys, EMPTY_KEY);
        @memset(code_len, 0);
        return .{
            .allocator = allocator,
            .keys = keys,
            .vals = vals,
            .code = code,
            .code_len = code_len,
        };
    }

    pub fn deinit(self: *BlockIndex) void {
        self.allocator.free(self.keys);
        self.allocator.free(self.vals);
        self.allocator.free(self.code);
        self.allocator.free(self.code_len);
        self.* = undefined;
    }

    /// Look up the block compiled from `current` (the bytes now at `eip`).
    /// Returns null when the slot is empty, holds another EIP, or the guest
    /// bytes changed since the block was compiled.
    pub fn lookup(self: *const BlockIndex, eip: u32, current: []const u8) ?u32 {
        const idx = eip & BLOCK_CACHE_MASK;
        if (self.keys[idx] != eip) return null;
        const len = self.code_len[idx];
        if (len == 0 or len > current.len or len > MAX_JIT_BLOCK_BYTES) return null;
        const base = @as(usize, idx) * MAX_JIT_BLOCK_BYTES;
        if (!std.mem.eql(u8, self.code[base .. base + len], current[0..len])) return null;
        return self.vals[idx];
    }

    /// Record that `block_id` was compiled from the first `code.len` bytes
    /// now at `eip`. Blocks longer than the scan window are not indexable.
    pub fn store(self: *BlockIndex, eip: u32, code: []const u8, block_id: u32) void {
        const idx = eip & BLOCK_CACHE_MASK;
        self.keys[idx] = eip;
        self.vals[idx] = block_id;
        self.code_len[idx] = 0;
        if (code.len == 0 or code.len > MAX_JIT_BLOCK_BYTES) return;
        const base = @as(usize, idx) * MAX_JIT_BLOCK_BYTES;
        @memcpy(self.code[base .. base + code.len], code);
        self.code_len[idx] = @intCast(code.len);
    }

    /// Drop the slot for `eip`. Used when the surrounding cache is flushed.
    pub fn invalidateEip(self: *BlockIndex, eip: u32) void {
        const idx = eip & BLOCK_CACHE_MASK;
        if (self.keys[idx] == eip) self.keys[idx] = EMPTY_KEY;
    }

    /// Guest EIP held by `slot`, or EMPTY_KEY when the slot is empty. Used by
    /// the hot-block report, which counts per slot rather than per EIP.
    pub fn keyAt(self: *const BlockIndex, slot: u32) u32 {
        return self.keys[slot];
    }

    /// Drop every entry.
    pub fn invalidateAll(self: *BlockIndex) void {
        @memset(self.keys, EMPTY_KEY);
        @memset(self.code_len, 0);
    }
};

/// JIT compiler instance for translating x86 basic blocks to WASM.
pub const JitCompiler = struct {
    allocator: std.mem.Allocator,
    module: emitter.WasmModule,
    block_cache_keys: [BLOCK_CACHE_SLOTS]u32,
    block_cache_vals: [BLOCK_CACHE_SLOTS]u32,
    /// WASM linear memory address of the JitCpuState struct.
    state_addr: u32,

    /// Initializes a new JIT compiler instance.
    pub fn init(allocator: std.mem.Allocator, state_addr: u32) JitCompiler {
        return .{
            .allocator = allocator,
            .module = emitter.WasmModule.init(allocator),
            .block_cache_keys = [_]u32{EMPTY_KEY} ** BLOCK_CACHE_SLOTS,
            .block_cache_vals = [_]u32{0} ** BLOCK_CACHE_SLOTS,
            .state_addr = state_addr,
        };
    }

    /// Frees all resources associated with the JIT compiler.
    pub fn deinit(self: *JitCompiler) void {
        // Map properties bound statically.
        self.module.deinit();
    }

    pub fn isCached(self: *JitCompiler, eip: u32) bool {
        const idx = eip & BLOCK_CACHE_MASK;
        return self.block_cache_keys[idx] == eip;
    }

    pub fn markCached(self: *JitCompiler, eip: u32, func_idx: u32) void {
        const idx = eip & BLOCK_CACHE_MASK;
        self.block_cache_keys[idx] = eip;
        self.block_cache_vals[idx] = func_idx;
    }

    /// Drop the "already compiled" mark for `eip` so the next visit
    /// recompiles. Callers that rewrote or unmapped guest code use this so
    /// the mark cannot suppress a recompile of changed bytes.
    pub fn invalidateEip(self: *JitCompiler, eip: u32) void {
        const idx = eip & BLOCK_CACHE_MASK;
        if (self.block_cache_keys[idx] == eip) self.block_cache_keys[idx] = EMPTY_KEY;
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
        self.markCached(guest_eip, @intCast(self.module.func_section.bytes.items.len));
        // isCached() is what gates a compile attempt, so a mark left behind by
        // a failed compile would silence this EIP for the rest of the run. The
        // mark belongs to a block that exists only once the module is finished.
        errdefer self.invalidateEip(guest_eip);

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
            try translateInstruction(&body, &insn);
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

        // Load FS segment base (TEB address) for FS-relative memory ops
        try body.appendOpcode(.i32_const);
        try body.appendUleb128(state_addr);
        try body.appendOpcode(.i32_load);
        try body.appendUleb128(2); // align=4
        try body.appendUleb128(host.JitCpuState.OFF_FS_BASE);
        try body.appendOpcode(.local_set);
        try body.appendUleb128(t.LOCAL_FS_BASE);

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
        try emitFlagFromEflags(body, t.LOCAL_CF, 0);

        // PF = (eflags >> 2) & 1
        try emitFlagFromEflags(body, t.LOCAL_PF, 2);

        // ZF = (eflags >> 6) & 1
        try emitFlagFromEflags(body, t.LOCAL_ZF, 6);

        // SF = (eflags >> 7) & 1
        try emitFlagFromEflags(body, t.LOCAL_SF, 7);

        // DF = (eflags >> 10) & 1
        try emitFlagFromEflags(body, t.LOCAL_DF, 10);

        // OF = (eflags >> 11) & 1
        try emitFlagFromEflags(body, t.LOCAL_OF, 11);
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
        try emitFlagIntoEflags(body, t.LOCAL_CF, 0);
        try emitFlagIntoEflags(body, t.LOCAL_PF, 2);
        try emitFlagIntoEflags(body, t.LOCAL_ZF, 6);
        try emitFlagIntoEflags(body, t.LOCAL_SF, 7);
        try emitFlagIntoEflags(body, t.LOCAL_DF, 10);
        try emitFlagIntoEflags(body, t.LOCAL_OF, 11);

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

    /// Translates a single non-control-flow x86 instruction into equivalent WASM operations.
    /// It appends the resulting WASM bytecode to the execution `body`.
    fn translateInstruction(body: *Body, insn: *const decoder.Instruction) !void {
        switch (insn.opcode) {
            // ===== NOP =====
            0x90 => try body.appendOpcode(.nop),

            // ===== MOV reg, imm (B0-B7: 8-bit, B8-BF: 32-bit) =====
            0xB0...0xB7, 0xB8...0xBF => {
                const reg: u3 = @truncate(insn.opcode);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
                // Byte MOV (B0-B7) must merge into the register preserving
                // untouched upper bits and handle AH/CH/DH/BH (offset 8).
                if (insn.op_size == .byte) {
                    try t.emitStoreOperand(body, insn, 0);
                } else {
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(reg);
                }
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
            0x00...0x05,
            0x08...0x0D,
            0x10...0x15,
            0x18...0x1D,
            0x20...0x25,
            0x28...0x2D,
            0x30...0x35,
            0x38...0x3D,
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
                try t.emitUpdateZfSf(body, insn.op_size);
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
                try t.emitUpdateZfSf(body, insn.op_size);
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
                try t.emitUpdateZfSf(body, insn.op_size);
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

            // ===== MOV Sreg (8C, 8E) — not translatable; fail the block =====
            0x8C, 0x8E => return error.UnsupportedOpcode,

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
                try emitSignExtendFrom(body, 16);
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
                try emitFlagIntoEflags(body, t.LOCAL_CF, 0);
                try emitFlagIntoEflags(body, t.LOCAL_ZF, 6);
                try emitFlagIntoEflags(body, t.LOCAL_SF, 7);
                try emitFlagIntoEflags(body, t.LOCAL_OF, 11);
                try emitFlagIntoEflags(body, t.LOCAL_DF, 10);
                try t.emitPush32(body);
            },

            // ===== POPFD (9D) =====
            0x9D => {
                try t.emitPop32(body);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_SCRATCH);
                // Extract CF (bit 0)
                try emitFlagFromEflags(body, t.LOCAL_CF, 0);
                // ZF (bit 6)
                try emitFlagFromEflags(body, t.LOCAL_ZF, 6);
                // SF (bit 7)
                try emitFlagFromEflags(body, t.LOCAL_SF, 7);
                // OF (bit 11)
                try emitFlagFromEflags(body, t.LOCAL_OF, 11);
                // DF (bit 10)
                try emitFlagFromEflags(body, t.LOCAL_DF, 10);
            },

            // ===== SAHF (9E) / LAHF (9F) — not translatable; fail the block =====
            0x9E, 0x9F => return error.UnsupportedOpcode,

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
                try t.emitUpdateZfSf(body, insn.op_size);
                try t.emitClearCfOf(body);
            },

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
            0xE0, 0xE1 => { // LOOPNE/LOOPE: ECX-=1, jump if ECX!=0 && ZF matches
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_ECX);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.i32_sub);
                try body.appendOpcode(.local_tee);
                try body.appendUleb128(t.REG_ECX);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.LOCAL_ZF);
                if (insn.opcode == 0xE0) try body.appendOpcode(.i32_eqz);
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
                    try t.emitUpdateZfSf(body, insn.op_size);
                }
            },

            // ===== Flag manipulation =====
            0xF8 => {
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(0);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_CF);
            }, // CLC
            0xF9 => {
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_CF);
            }, // STC
            0xFC => {
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(0);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_DF);
            }, // CLD
            0xFD => {
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(1);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(t.LOCAL_DF);
            }, // STD
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
                    try emitSignExtendFrom(body, 24);
                    try body.appendOpcode(.local_set);
                    try body.appendUleb128(insn.modrm_reg);
                }
            },
            // ===== MOVSX r32, r/m16 (0F BF) =====
            0x0FBF => {
                if (insn.has_modrm) {
                    try t.emitLoadOperand(body, insn, 1);
                    try emitSignExtendFrom(body, 16);
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

            // ===== INT3/INT/HLT — control flow, never reached (isControlFlow) =====
            0xCC, 0xCD, 0xF4 => {},

            // ===== FWAIT / NOP hints — genuinely side-effect-free, safe to drop =====
            0x9B => {},
            0x0F18, 0x0F19, 0x0F1A, 0x0F1B, 0x0F1C, 0x0F1D, 0x0F1E, 0x0F1F => {},

            // ===== String ops (A4-AF) — MOVS/CMPS/STOS/LODS/SCAS with REP =====
            0xA4, 0xA5, 0xA6, 0xA7, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF => {
                try translateStringOp(body, insn);
            },

            // ===== Untranslatable opcodes — MUST fail the block compile =====
            // Silently skipping these corrupts guest state (e.g. a dropped
            // STOSB inside the statically-linked CRT printf leaves "%s" raw).
            // The caller falls back to the interpreter, which is always correct.
            0x06, 0x07, 0x0E, 0x16, 0x17, 0x1E, 0x1F => return error.UnsupportedOpcode, // segment push/pop
            0x27, 0x2F, 0x37, 0x3F => return error.UnsupportedOpcode, // BCD adjust
            0x62 => return error.UnsupportedOpcode, // BOUND
            0x6C, 0x6D, 0x6E, 0x6F => return error.UnsupportedOpcode, // INS/OUTS
            0xC8 => return error.UnsupportedOpcode, // ENTER
            0xC4, 0xC5 => return error.UnsupportedOpcode, // LES/LDS
            0xD4, 0xD5 => return error.UnsupportedOpcode, // AAM/AAD
            0xD7 => return error.UnsupportedOpcode, // XLAT
            0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF => return error.UnsupportedOpcode, // FPU
            0xE4, 0xE5, 0xE6, 0xE7, 0xEC, 0xED, 0xEE, 0xEF => return error.UnsupportedOpcode, // IN/OUT
            0xF1 => return error.UnsupportedOpcode, // INT1
            0x0F02, 0x0F03 => return error.UnsupportedOpcode, // LAR/LSL
            0x0FA0, 0x0FA1, 0x0FA8, 0x0FA9 => return error.UnsupportedOpcode, // PUSH/POP FS/GS
            0x0FA3, 0x0FAB, 0x0FB3, 0x0FBB, 0x0FBA => return error.UnsupportedOpcode, // BT family
            0x0FA4, 0x0FA5, 0x0FAC, 0x0FAD => return error.UnsupportedOpcode, // SHLD/SHRD
            0x0FB0, 0x0FB1 => return error.UnsupportedOpcode, // CMPXCHG
            0x0FC0, 0x0FC1 => return error.UnsupportedOpcode, // XADD

            // Default: unimplemented opcode — refuse to compile the block
            else => return error.UnsupportedOpcode,
        }
    }
};

// =======================================================================
// Sub-translators (factored out to keep the main switch readable)
// =======================================================================

/// Shifts a flag local into place and ORs it into the EFLAGS value on the
/// wasm stack. The caller must have pushed the EFLAGS base value first.
fn emitFlagIntoEflags(body: *Body, flag_local: u32, bit: u8) !void {
    try body.appendOpcode(.local_get);
    try body.appendUleb128(flag_local);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(bit);
    try body.appendOpcode(.i32_shl);
    try body.appendOpcode(.i32_or);
}

/// Extracts bit `bit` of the EFLAGS value in LOCAL_SCRATCH into a flag local.
fn emitFlagFromEflags(body: *Body, flag_local: u32, bit: u8) !void {
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_SCRATCH);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(bit);
    try body.appendOpcode(.i32_shr_u);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(1);
    try body.appendOpcode(.i32_and);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(flag_local);
}

/// Sign-extends the low `bits` of the value on the Wasm stack to 32 bits, by
/// shifting the sign bit up to the top and back down arithmetically.
fn emitSignExtendFrom(body: *Body, bits: u8) !void {
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(bits);
    try body.appendOpcode(.i32_shl);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(bits);
    try body.appendOpcode(.i32_shr_s);
}

/// Translates basic arithmetic and logic instructions (ADD, OR, ADC, SBB, AND, SUB, XOR, CMP)
/// covering the 8/32-bit reg/mem to reg/mem variants, as well as AL/EAX immediate forms.
fn translateAlu(body: *Body, insn: *const decoder.Instruction) !void {
    const group: u3 = @truncate(insn.opcode >> 3);
    const wasm_op = t.aluGroupToWasmOp(group) orelse return;

    // Load destination and source, saving operands for CF/OF computation
    try t.emitLoadOperand(body, insn, 0);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(t.LOCAL_SCRATCH2); // operand A
    try t.emitLoadOperand(body, insn, 1);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(t.LOCAL_SCRATCH3); // operand B

    // Perform operation
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_SCRATCH2);
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_SCRATCH3);
    try body.appendOpcode(wasm_op);

    // Mask the result to the operand size — byte/word ALU flags must be
    // computed from the truncated result (e.g. `or al,al` sees only AL).
    try t.emitTruncateToSize(body, insn.op_size);

    // CMP/TEST don't store — just update flags
    if (group == 7) {
        // CMP: result on stack, compute ZF/SF, don't store
        try t.emitUpdateZfSf(body, insn.op_size);
        // CF = borrow, OF = signed overflow (A - B)
        try t.emitSubCfOf(body, insn, t.LOCAL_SCRATCH2, t.LOCAL_SCRATCH3);
    } else {
        // Store result to destination, then update flags from the stored value
        try body.appendOpcode(.local_tee);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try t.emitStoreOperand(body, insn, 0);
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try t.emitUpdateZfSf(body, insn.op_size);

        // CF/OF per group
        switch (group) {
            0, 2 => try t.emitAddCfOf(body, insn, t.LOCAL_SCRATCH2, t.LOCAL_SCRATCH3), // ADD, ADC
            3, 5 => try t.emitSubCfOf(body, insn, t.LOCAL_SCRATCH2, t.LOCAL_SCRATCH3), // SBB, SUB
            1, 4, 6 => try t.emitClearCfOf(body), // OR, AND, XOR
            else => {},
        }
    }
}

/// Translates Group 1 instructions (ADD, OR, ADC, SBB, AND, SUB, XOR, CMP) where
/// the destination is a register/memory operand and the source is an immediate value.
fn translateGroup1(body: *Body, insn: *const decoder.Instruction) !void {
    if (!insn.has_modrm) return;
    const sub_op = insn.modrm_reg;
    const wasm_op = t.aluGroupToWasmOp(sub_op) orelse return;

    // Load destination into SCRATCH2, immediate into SCRATCH3
    try t.emitLoadOperand(body, insn, 0);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(t.LOCAL_SCRATCH2);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
    try body.appendOpcode(.local_set);
    try body.appendUleb128(t.LOCAL_SCRATCH3);

    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_SCRATCH2);
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_SCRATCH3);
    try body.appendOpcode(wasm_op);

    // Mask the result to the operand size (byte/word ALU flags).
    try t.emitTruncateToSize(body, insn.op_size);

    if (sub_op == 7) { // CMP
        try t.emitUpdateZfSf(body, insn.op_size);
        try t.emitSubCfOf(body, insn, t.LOCAL_SCRATCH2, t.LOCAL_SCRATCH3);
    } else {
        try body.appendOpcode(.local_tee);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try t.emitStoreOperand(body, insn, 0);
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_SCRATCH);
        try t.emitUpdateZfSf(body, insn.op_size);

        switch (sub_op) {
            0, 2 => try t.emitAddCfOf(body, insn, t.LOCAL_SCRATCH2, t.LOCAL_SCRATCH3),
            3, 5 => try t.emitSubCfOf(body, insn, t.LOCAL_SCRATCH2, t.LOCAL_SCRATCH3),
            1, 4, 6 => try t.emitClearCfOf(body),
            else => {},
        }
    }
}

/// Translates Group 2 shift/rotate instructions (ROL, ROR, RCL, RCR, SHL, SHR, SAR)
/// matching opcode C0/C1 (imm8 shift) and D0-D3 (1 or CL shift).
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
    try t.emitUpdateZfSf(body, insn.op_size);
}

/// Translates Group 3 unary instructions (TEST imm, NOT, NEG, MUL, IMUL, DIV, IDIV)
/// matching opcode F6 (8-bit) and F7 (32-bit).
fn translateGroup3(body: *Body, insn: *const decoder.Instruction) !void {
    if (!insn.has_modrm) return;
    switch (insn.modrm_reg) {
        0, 1 => { // TEST r/m, imm
            try t.emitLoadOperand(body, insn, 0);
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
            try body.appendOpcode(.i32_and);
            try t.emitUpdateZfSf(body, insn.op_size);
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
            try t.emitUpdateZfSf(body, insn.op_size);
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

/// Translates Group 5 unary instructions (INC, DEC, CALL, CALLF, JMP, JMPF, PUSH)
/// targeting a general register or memory operand (opcode FF).
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
            try t.emitUpdateZfSf(body, insn.op_size);
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
            try t.emitUpdateZfSf(body, insn.op_size);
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

/// Operand size (bytes) of a string instruction, matching the interpreter's
/// single-step implementation exactly: the byte forms (A4/A6/AA/AC/AE) are
/// always 1, the dword forms (A5/A7/AB/AD/AF) are always 4 (the interpreter
/// ignores the 0x66 operand-size override for string ops).
fn stringOpSize(insn: *const decoder.Instruction) u32 {
    return switch (insn.opcode) {
        0xA4, 0xA6, 0xAA, 0xAC, 0xAE => 1,
        else => 4,
    };
}

/// Emit `reg += (DF ? -size : +size)` — direction-flag-aware pointer adjust.
fn emitStringAdjust(body: *Body, reg_local: u32, size: u32) !void {
    try body.appendOpcode(.local_get);
    try body.appendUleb128(reg_local);
    // val1 = -size (picked when DF==1), val2 = +size, cond = DF
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(-@as(i32, @intCast(size)));
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(@as(i32, @intCast(size)));
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_DF);
    try body.appendOpcode(.select);
    try body.appendOpcode(.i32_add);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(reg_local);
}

/// Emit a memory load of `size` bytes from guest VA in `reg_local`.
/// Result (zero-extended into i32) is left on the Wasm stack.
fn emitStringMemLoad(body: *Body, reg_local: u32, size: u32) !void {
    try body.appendOpcode(.local_get);
    try body.appendUleb128(reg_local);
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_MEM_BASE);
    try body.appendOpcode(.i32_add);
    switch (size) {
        1 => {
            try body.appendOpcode(.i32_load8_u);
            try body.appendUleb128(0);
            try body.appendUleb128(0);
        },
        2 => {
            try body.appendOpcode(.i32_load16_u);
            try body.appendUleb128(1);
            try body.appendUleb128(0);
        },
        else => {
            try body.appendOpcode(.i32_load);
            try body.appendUleb128(2);
            try body.appendUleb128(0);
        },
    }
}

/// Emit a memory store of `size` bytes to guest VA in `reg_local`.
/// Value must already be on the Wasm stack below the address (addr on top).
fn emitStringMemStore(body: *Body, reg_local: u32, size: u32) !void {
    try body.appendOpcode(.local_get);
    try body.appendUleb128(reg_local);
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_MEM_BASE);
    try body.appendOpcode(.i32_add);
    switch (size) {
        1 => {
            try body.appendOpcode(.i32_store8);
            try body.appendUleb128(0);
            try body.appendUleb128(0);
        },
        2 => {
            try body.appendOpcode(.i32_store16);
            try body.appendUleb128(1);
            try body.appendUleb128(0);
        },
        else => {
            try body.appendOpcode(.i32_store);
            try body.appendUleb128(2);
            try body.appendUleb128(0);
        },
    }
}

/// Mask the value on the Wasm stack to a string element of `size` bytes.
fn emitStringMaskSize(body: *Body, size: u32) !void {
    switch (size) {
        1 => {
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0xFF);
            try body.appendOpcode(.i32_and);
        },
        2 => {
            try body.appendOpcode(.i32_const);
            try body.appendIleb128(0xFFFF);
            try body.appendOpcode(.i32_and);
        },
        else => {},
    }
}

/// Emit CMPS/SCAS flag updates: SCRATCH2 - SCRATCH3 on the Wasm stack,
/// then ZF/SF from the result and CF from the unsigned comparison.
fn emitStringCmpFlags(body: *Body, insn: *const decoder.Instruction, size: u32) !void {
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_SCRATCH2);
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.LOCAL_SCRATCH3);
    try body.appendOpcode(.i32_sub);
    try emitStringMaskSize(body, size);
    try t.emitUpdateZfSf(body, if (size == 1) .byte else if (size == 2) .word else .dword);
    try t.emitSubCfOf(body, insn, t.LOCAL_SCRATCH2, t.LOCAL_SCRATCH3);
}

/// Emit the body of one string instruction (no REP wrapper).
/// `size` is the element size in bytes.
fn emitStringBody(body: *Body, insn: *const decoder.Instruction, size: u32) !void {
    switch (insn.opcode) {
        0xA4, 0xA5 => { // MOVS: [EDI] = [ESI]
            try emitStringMemLoad(body, t.REG_ESI, size);
            try emitStringMemStore(body, t.REG_EDI, size);
            try emitStringAdjust(body, t.REG_ESI, size);
            try emitStringAdjust(body, t.REG_EDI, size);
        },
        0xAA, 0xAB => { // STOS: [EDI] = AL/EAX
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.REG_EAX);
            try emitStringMemStore(body, t.REG_EDI, size);
            try emitStringAdjust(body, t.REG_EDI, size);
        },
        0xAC, 0xAD => { // LODS: AL/EAX = [ESI]
            try emitStringMemLoad(body, t.REG_ESI, size);
            if (size == 1) {
                // Merge low byte into EAX preserving upper bits.
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(0xFF);
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.local_get);
                try body.appendUleb128(t.REG_EAX);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(@as(u32, 0xFFFFFF00))));
                try body.appendOpcode(.i32_and);
                try body.appendOpcode(.i32_or);
            }
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.REG_EAX);
            try emitStringAdjust(body, t.REG_ESI, size);
        },
        0xA6, 0xA7 => { // CMPS: compare [ESI] vs [EDI], set flags
            try emitStringMemLoad(body, t.REG_ESI, size);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.LOCAL_SCRATCH2);
            try emitStringMemLoad(body, t.REG_EDI, size);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.LOCAL_SCRATCH3);
            try emitStringCmpFlags(body, insn, size);
            try emitStringAdjust(body, t.REG_ESI, size);
            try emitStringAdjust(body, t.REG_EDI, size);
        },
        0xAE, 0xAF => { // SCAS: compare AL/EAX vs [EDI], set flags
            try body.appendOpcode(.local_get);
            try body.appendUleb128(t.REG_EAX);
            // Byte SCAS compares AL only — mask A to the element size so
            // CF (A < B unsigned) matches the interpreter's byte compare.
            if (size == 1) {
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(0xFF);
                try body.appendOpcode(.i32_and);
            }
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.LOCAL_SCRATCH2);
            try emitStringMemLoad(body, t.REG_EDI, size);
            try body.appendOpcode(.local_set);
            try body.appendUleb128(t.LOCAL_SCRATCH3);
            try emitStringCmpFlags(body, insn, size);
            try emitStringAdjust(body, t.REG_EDI, size);
        },
        else => {},
    }
}

/// Translate a string instruction (A4-AF), including the REP/REPE/REPNE
/// loop wrapper. REP semantics match the interpreter: `while (ECX != 0)`.
/// REPE (rep) on CMPS/SCAS also stops when ZF==0; REPNE when ZF==1.
fn translateStringOp(body: *Body, insn: *const decoder.Instruction) !void {
    const size = stringOpSize(insn);

    if (!insn.rep and !insn.repne) {
        try emitStringBody(body, insn, size);
        return;
    }

    // block $exit (depth 1 from inside the loop)
    //   loop $top (depth 0)
    //     ECX == 0 ? br 1 (exit)
    //     body
    //     ECX -= 1
    //     REPE/REPNE ZF early-exit check
    //     br 0 (continue)
    //   end
    // end
    try body.appendOpcode(.block);
    try body.append(@intFromEnum(wasm.BlockType.void));
    try body.appendOpcode(.loop);
    try body.append(@intFromEnum(wasm.BlockType.void));

    // ECX == 0 → exit
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.REG_ECX);
    try body.appendOpcode(.i32_eqz);
    try body.appendOpcode(.br_if);
    try body.appendUleb128(1);

    try emitStringBody(body, insn, size);

    // ECX -= 1
    try body.appendOpcode(.local_get);
    try body.appendUleb128(t.REG_ECX);
    try body.appendOpcode(.i32_const);
    try body.appendIleb128(1);
    try body.appendOpcode(.i32_sub);
    try body.appendOpcode(.local_set);
    try body.appendUleb128(t.REG_ECX);

    // REPE (insn.rep) on CMPS/SCAS: exit when ZF==0
    // REPNE (insn.repne): exit when ZF==1
    if (insn.rep and (insn.opcode == 0xA6 or insn.opcode == 0xA7 or insn.opcode == 0xAE or insn.opcode == 0xAF)) {
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_ZF);
        try body.appendOpcode(.i32_eqz);
        try body.appendOpcode(.br_if);
        try body.appendUleb128(1);
    } else if (insn.repne) {
        try body.appendOpcode(.local_get);
        try body.appendUleb128(t.LOCAL_ZF);
        try body.appendOpcode(.br_if);
        try body.appendUleb128(1);
    }

    try body.appendOpcode(.br);
    try body.appendUleb128(0); // continue loop
    try body.appendOpcode(.end); // loop
    try body.appendOpcode(.end); // block
}

// =======================================================================
// Tests
// =======================================================================

const testing = std.testing;

/// Return the payload of the section with the given ID, or null if absent.
/// A section payload is `id: u8` followed by a ULEB128 length and the bytes.
fn findSection(wasm_bin: []const u8, id: u8) ?[]const u8 {
    var pos: usize = 8; // skip magic + version
    while (pos < wasm_bin.len) {
        const section_id = wasm_bin[pos];
        pos += 1;
        var section_len: u32 = 0;
        var shift: u5 = 0;
        while (pos < wasm_bin.len) {
            const b = wasm_bin[pos];
            pos += 1;
            section_len |= @as(u32, b & 0x7F) << shift;
            if (b & 0x80 == 0) break;
            shift +%= 7;
        }
        const payload = wasm_bin[pos..@min(pos + section_len, wasm_bin.len)];
        pos += section_len;
        if (section_id == id) return payload;
    }
    return null;
}

/// Verify a compiled WASM binary has correct header and required sections.
fn expectValidWasmModule(wasm_bin: []const u8) !void {
    // Valid WASM binary: magic \0asm + version 1
    try std.testing.expect(wasm_bin.len >= 8);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d }, wasm_bin[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x00, 0x00 }, wasm_bin[4..8]);

    // Walk sections and verify expected section IDs are present
    try testing.expect(findSection(wasm_bin, 1) != null); // type
    try testing.expect(findSection(wasm_bin, 2) != null); // import
    try testing.expect(findSection(wasm_bin, 3) != null); // func
    try testing.expect(findSection(wasm_bin, 10) != null); // code

    const export_section = findSection(wasm_bin, 7) orelse return error.TestUnexpectedResult;
    // The module must export the "run" entry point.
    try testing.expect(std.mem.indexOf(u8, export_section, "run") != null);
}

/// Assert the code section contains each of the given WASM opcode bytes,
/// i.e. the translated x86 instruction actually produced the expected
/// operation instead of an empty or unrelated body.
fn expectCodeSectionContains(wasm_bin: []const u8, opcodes: []const u8) !void {
    const code = findSection(wasm_bin, 10) orelse return error.TestUnexpectedResult;
    for (opcodes) |op| {
        try testing.expect(std.mem.indexOfScalar(u8, code, op) != null);
    }
}

/// Assert the second module's code section is strictly larger than the first's.
/// A body that translated to nothing, or a translator that stopped at the
/// first instruction, leaves the two equal, so a byte scan of the code section
/// (which the prologue and epilogue already fill) cannot stand in for this.
fn expectCodeSectionGrows(base: []const u8, longer: []const u8) !void {
    const base_code = findSection(base, 10) orelse return error.TestUnexpectedResult;
    const longer_code = findSection(longer, 10) orelse return error.TestUnexpectedResult;
    try testing.expect(longer_code.len > base_code.len);
}

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

    try expectValidWasmModule(wasm_bin);

    // The body has to hold the three instructions, not just a valid prologue
    // and epilogue. Compiling the first instruction alone and comparing code
    // section sizes catches a translator that returns early on the second
    // instruction or on the register-register form.
    compiler.module.deinit();
    compiler.module = @import("emitter.zig").WasmModule.init(std.testing.allocator);
    const first_only = [_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00 };
    const wasm_first = try compiler.compile(0x1000, &first_only);
    defer std.testing.allocator.free(wasm_first);
    try expectCodeSectionGrows(wasm_first, wasm_bin);
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

    try expectValidWasmModule(wasm_bin);
    // PUSH stores through the stack pointer; POP loads back.
    try expectCodeSectionContains(wasm_bin, &.{ @intFromEnum(wasm.Opcode.i32_store), @intFromEnum(wasm.Opcode.i32_load) });

    // The prologue and epilogue emit i32_store and i32_load themselves, so the
    // byte scan above holds even if PUSH and POP translate to nothing. Each
    // instruction has to grow the body past the one that precedes it.
    compiler.module.deinit();
    compiler.module = @import("emitter.zig").WasmModule.init(std.testing.allocator);
    const push_only = [_]u8{0x50};
    const wasm_push = try compiler.compile(0x2000, &push_only);
    defer std.testing.allocator.free(wasm_push);
    try expectCodeSectionGrows(wasm_push, wasm_bin);
}

test "jit compiler group1 sub imm" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    const code = [_]u8{
        0x83, 0xE8, 0x05, // SUB EAX, 5 (83 /5 ib)
    };

    const wasm_bin = try compiler.compile(0x3000, &code);
    defer std.testing.allocator.free(wasm_bin);

    try expectValidWasmModule(wasm_bin);
    // SUB must lower to the WASM i32.sub operation.
    try expectCodeSectionContains(wasm_bin, &.{@intFromEnum(wasm.Opcode.i32_sub)});
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
    try expectValidWasmModule(wasm_jcc);

    // Compile the same first instruction on its own, from the same base
    // address, so the only variable is the trailing bytes the compiler must
    // not reach.
    compiler.module.deinit();
    compiler.module = @import("emitter.zig").WasmModule.init(std.testing.allocator);
    const code_mov_only = [_]u8{
        0xB8, 0x01, 0x00, 0x00, 0x00, // MOV EAX, 1
    };
    const wasm_mov_only = try compiler.compile(0x4000, &code_mov_only);
    defer std.testing.allocator.free(wasm_mov_only);
    try expectValidWasmModule(wasm_mov_only);

    // The Jcc and the MOV ECX past it must contribute nothing. A size
    // comparison would pass on any delta, including a truncated MOV EAX.
    try std.testing.expectEqualSlices(u8, wasm_mov_only, wasm_jcc);
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

    try expectValidWasmModule(wasm_bin);
    // SHL / SHR / SAR must map to the corresponding WASM shift operations.
    try expectCodeSectionContains(wasm_bin, &.{
        @intFromEnum(wasm.Opcode.i32_shl),
        @intFromEnum(wasm.Opcode.i32_shr_u),
        @intFromEnum(wasm.Opcode.i32_shr_s),
    });
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

    try expectValidWasmModule(wasm_bin);
    // MOVZX masks to 8 bits; MOVSX sign-extends via shift left + arithmetic
    // shift right.
    try expectCodeSectionContains(wasm_bin, &.{ @intFromEnum(wasm.Opcode.i32_and), @intFromEnum(wasm.Opcode.i32_shr_s) });
}

test "jit compiler lea" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    const code = [_]u8{
        0x8D, 0x44, 0x8B, 0x10, // LEA EAX, [EBX+ECX*4+0x10]
    };

    const wasm_bin = try compiler.compile(0x7000, &code);
    defer std.testing.allocator.free(wasm_bin);

    try expectValidWasmModule(wasm_bin);
    // SIB addressing scales the index (mul) and adds base + displacement.
    try expectCodeSectionContains(wasm_bin, &.{ @intFromEnum(wasm.Opcode.i32_mul), @intFromEnum(wasm.Opcode.i32_add) });
}

test "block index: hit only for the bytes that were compiled" {
    var index = try BlockIndex.init(std.testing.allocator);
    defer index.deinit();

    const code = [_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 };
    try std.testing.expect(index.lookup(0x401000, &code) == null);
    index.store(0x401000, &code, 7);
    try std.testing.expectEqual(@as(u32, 7), index.lookup(0x401000, &code).?);
}

test "block index: guest code patched at the same EIP misses" {
    var index = try BlockIndex.init(std.testing.allocator);
    defer index.deinit();

    var code = [_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 };
    index.store(0x401000, &code, 1);
    // Same length, one byte different: the compiled block is stale.
    code[1] = 0x02;
    try std.testing.expect(index.lookup(0x401000, &code) == null);
    // Every byte of the compiled block is validated, not just the first.
    code[1] = 0x01;
    code[5] = 0x90;
    try std.testing.expect(index.lookup(0x401000, &code) == null);
}

test "block index: a shorter fetch than the compiled block misses" {
    var index = try BlockIndex.init(std.testing.allocator);
    defer index.deinit();

    const code = [_]u8{ 0x90, 0x90, 0x90, 0x90 };
    index.store(0x500000, &code, 3);
    try std.testing.expectEqual(@as(u32, 3), index.lookup(0x500000, &code).?);
    try std.testing.expect(index.lookup(0x500000, code[0..2]) == null);
}

test "block index: slot aliasing evicts and never returns another EIP's block" {
    var index = try BlockIndex.init(std.testing.allocator);
    defer index.deinit();

    const eip_a: u32 = 0x401000;
    const eip_b = eip_a + BLOCK_CACHE_SLOTS;
    try std.testing.expectEqual(eip_a & BLOCK_CACHE_MASK, eip_b & BLOCK_CACHE_MASK);

    const code_a = [_]u8{0x90};
    const code_b = [_]u8{0xCC};
    index.store(eip_a, &code_a, 11);
    index.store(eip_b, &code_b, 22);
    // eip_b took the shared slot, so eip_a is gone rather than aliased.
    try std.testing.expect(index.lookup(eip_a, &code_a) == null);
    try std.testing.expectEqual(@as(u32, 22), index.lookup(eip_b, &code_b).?);
}

test "block index: invalidateEip and invalidateAll drop only their targets" {
    var index = try BlockIndex.init(std.testing.allocator);
    defer index.deinit();

    const eip_a: u32 = 0x401000;
    const eip_b: u32 = 0x402000;
    const code = [_]u8{0x90};
    index.store(eip_a, &code, 1);
    index.store(eip_b, &code, 2);

    index.invalidateEip(0x409000); // empty slot, no effect
    index.invalidateEip(eip_a);
    try std.testing.expect(index.lookup(eip_a, &code) == null);
    try std.testing.expectEqual(@as(u32, 2), index.lookup(eip_b, &code).?);

    index.invalidateAll();
    try std.testing.expect(index.lookup(eip_b, &code) == null);
}

test "block index: blocks beyond the scan window are not indexable" {
    var index = try BlockIndex.init(std.testing.allocator);
    defer index.deinit();

    const oversized = [_]u8{0x90} ** (MAX_JIT_BLOCK_BYTES + 1);
    index.store(0x401000, &oversized, 5);
    try std.testing.expect(index.lookup(0x401000, &oversized) == null);
}

test "compiler: invalidateEip clears the compile mark for that EIP only" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    const eip_a: u32 = 0x401000;
    const eip_b: u32 = 0x401004;
    try std.testing.expect(eip_a & BLOCK_CACHE_MASK != eip_b & BLOCK_CACHE_MASK);

    compiler.markCached(eip_a, 0);
    compiler.markCached(eip_b, 0);
    try std.testing.expect(compiler.isCached(eip_a));
    compiler.invalidateEip(eip_a);
    try std.testing.expect(!compiler.isCached(eip_a));
    try std.testing.expect(compiler.isCached(eip_b));
}

test "compiler: a failed compile leaves no mark that would suppress a retry" {
    var compiler = JitCompiler.init(std.testing.allocator, 0);
    defer compiler.deinit();

    const eip: u32 = 0x401000;
    // SAHF is one of the opcodes translateInstruction refuses, so the compile
    // fails after the mark was taken.
    try std.testing.expectError(error.UnsupportedOpcode, compiler.compile(eip, &.{0x9E}));

    // The mark gated the compile attempt, so a surviving one would keep this
    // EIP from ever being compiled again.
    try std.testing.expect(!compiler.isCached(eip));
}
