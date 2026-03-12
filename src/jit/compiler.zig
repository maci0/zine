const std = @import("std");
const wasm = @import("wasm.zig");
const emitter = @import("emitter.zig");
const decoder = @import("../x86/decoder.zig");

pub const JitCompiler = struct {
    allocator: std.mem.Allocator,
    module: emitter.WasmModule,
    
    // Dynarec Phase 6: EIP -> Wasm Function Index map
    block_cache: std.AutoHashMap(u32, u32),

    pub fn init(allocator: std.mem.Allocator) JitCompiler {
        return .{
            .allocator = allocator,
            .module = emitter.WasmModule.init(allocator),
            .block_cache = std.AutoHashMap(u32, u32).init(allocator),
        };
    }

    pub fn deinit(self: *JitCompiler) void {
        self.block_cache.deinit();
        self.module.deinit();
    }

    /// Translates a block of x86 code into a WebAssembly module.
    /// In a full Dynarec, this will take the starting EIP and register the block in the cache.
    pub fn compile(self: *JitCompiler, guest_eip: u32, x86_code: []const u8) ![]u8 {
        var offset: usize = 0;
        
        // Register block
        try self.block_cache.put(guest_eip, @intCast(self.module.func_section.bytes.items.len));

        // Build a type section: 1 function type (void -> void)
        try self.module.type_section.appendUleb128(1); // 1 type
        try self.module.type_section.append(0x60); // func form
        try self.module.type_section.appendUleb128(0); // 0 params
        try self.module.type_section.appendUleb128(0); // 0 returns

        // Build a func section: 1 function of type 0
        try self.module.func_section.appendUleb128(1); // 1 function
        try self.module.func_section.appendUleb128(0); // type index 0

        // Build a code section: 1 function body
        var body = emitter.Buffer.init(self.allocator);
        defer body.deinit();

        // 13 local variables of type i32:
        // 0-7: EAX..EDI
        // 8:  CF (Carry)
        // 9:  ZF (Zero)
        // 10: SF (Sign)
        // 11: OF (Overflow)
        // 12: Scratch space
        try body.appendUleb128(1); // 1 local entry
        try body.appendUleb128(13); // count of 13
        try body.append(@intFromEnum(wasm.ValType.i32));

        while (offset < x86_code.len) {
            const insn = decoder.decode(x86_code[offset..]);
            if (insn.length == 0) {
                // Invalid instruction or end of stream
                break;
            }

            try self.translateInstruction(&body, &insn);

            offset += insn.length;
        }

        try body.appendOpcode(.end);

        // Calculate body size and write to code section
        try self.module.code_section.appendUleb128(1); // 1 function body
        try self.module.code_section.appendUleb128(@as(u32, @intCast(body.bytes.items.len)));
        try self.module.code_section.appendSlice(body.bytes.items);
        
        return self.module.finish();
    }

    fn translateInstruction(self: *JitCompiler, body: *emitter.Buffer, insn: *const decoder.Instruction) !void {
        _ = self;
        switch (insn.opcode) {
            0x90 => try body.appendOpcode(.nop),
            
            // MOV reg, imm32 (B8-BF)
            0xB8...0xBF => {
                const reg: u3 = @truncate(insn.opcode);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(@as(i32, @bitCast(insn.imm)));
                try body.appendOpcode(.local_set);
                try body.appendUleb128(reg);
            },
            
            // ALU r/m32, reg32 (01, 09, 11, 19, 21, 29, 31)
            0x01, 0x09, 0x11, 0x19, 0x21, 0x29, 0x31 => {
                if (insn.modrm) |modrm| {
                    if (modrm.mod == 3) { // register to register
                        const dest_reg = modrm.rm;
                        const src_reg = modrm.reg;
                        
                        // Push dest
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(dest_reg);
                        
                        // Push src
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(src_reg);
                        
                        // Perform operation
                        switch (insn.opcode) {
                            0x01 => try body.appendOpcode(.i32_add),
                            0x09 => try body.appendOpcode(.i32_or),
                            0x11 => {}, // ADC unsupported without flags yet
                            0x19 => {}, // SBB unsupported without flags yet
                            0x21 => try body.appendOpcode(.i32_and),
                            0x29 => try body.appendOpcode(.i32_sub),
                            0x31 => try body.appendOpcode(.i32_xor),
                            else => unreachable,
                        }

                        // Duplicate the operation result so we can test it for flags
                        // WASM lacks `dup`, so we store it to dest_reg, then load it back immediately
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(dest_reg);
                        
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(dest_reg);

                        // Calculate and store ZF (Zero Flag: result == 0)
                        try body.appendOpcode(.i32_eqz);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(9); // ZF local

                        // We need the result back on stack for SF
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(dest_reg);

                        // Calculate and store SF (Sign Flag: result < 0)
                        try body.appendOpcode(.i32_const);
                        try body.appendIleb128(0);
                        try body.appendOpcode(.i32_lt_s);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(10); // SF local

                        // Carry (CF) and Overflow (OF) are skipped for now due to complexity
                        // of calculating them strictly post-add vs post-sub.
                    }
                }
            },
            
            // MOV r/m32, reg32 (89)
            0x89 => {
                if (insn.modrm) |modrm| {
                    if (modrm.mod == 3) {
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(modrm.reg); // src
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(modrm.rm);  // dest
                    } else {
                        // Memory Store
                        // Calculate Address (Base Register)
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(modrm.rm);
                        
                        // Add displacement if any (oversimplified for standalone test)
                        
                        // Push Source Value
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(modrm.reg);
                        
                        // Store it
                        try body.appendOpcode(.i32_store);
                        try body.appendUleb128(2); // align 32-bit
                        try body.appendUleb128(0); // offset 0
                    }
                }
            },
            
            // MOV reg32, r/m32 (8B)
            0x8B => {
                if (insn.modrm) |modrm| {
                    if (modrm.mod == 3) {
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(modrm.rm);  // src
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(modrm.reg); // dest
                    } else {
                        // Memory Load
                        // Calculate Address
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(modrm.rm); // Base Register
                        
                        // Load it
                        try body.appendOpcode(.i32_load);
                        try body.appendUleb128(2); // align 32-bit
                        try body.appendUleb128(0); // offset 0
                        
                        // Save to dest reg
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(modrm.reg);
                    }
                }
            },
            
            // CMP r/m32, reg32 (39)
            0x39 => {
                if (insn.modrm) |modrm| {
                    if (modrm.mod == 3) {
                        const dest_reg = modrm.rm;
                        const src_reg = modrm.reg;

                        // Push dest
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(dest_reg);
                        
                        // Push src
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(src_reg);

                        // Perform subtraction
                        try body.appendOpcode(.i32_sub);

                        // Calculate ZF
                        // We must duplicate the result without tearing it down. But we can't save it to dest_reg for CMP!
                        // So we save it to a scratch local or we just calculate ZF / SF directly and drop.
                        // For simplicity let's use a designated "Scratch" local 12 or we re-calculate directly on stack.
                        
                        // Actually WebAssembly has `local.tee`! We can tee to a scratch variable.
                        // Let's use local index 12 as a generic scratch register since we declared 12. Oh wait we only declared 12 total (0-11).
                        // Let's set local count to 13 earlier and use index 12 as scratch.
                        try body.appendOpcode(.local_tee);
                        try body.appendUleb128(12);

                        // Calculate ZF
                        try body.appendOpcode(.i32_eqz);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(9);

                        // Load Scratch back
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(12);

                        // Calculate SF
                        try body.appendOpcode(.i32_const);
                        try body.appendIleb128(0);
                        try body.appendOpcode(.i32_lt_s);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(10);
                    }
                }
            },

            // TEST r/m32, reg32 (85)
            0x85 => {
                if (insn.modrm) |modrm| {
                    if (modrm.mod == 3) {
                        const dest_reg = modrm.rm;
                        const src_reg = modrm.reg;

                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(dest_reg);
                        
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(src_reg);

                        try body.appendOpcode(.i32_and);

                        // `local.tee` to scratch
                        try body.appendOpcode(.local_tee);
                        try body.appendUleb128(12);

                        // ZF
                        try body.appendOpcode(.i32_eqz);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(9);

                        // SF
                        try body.appendOpcode(.local_get);
                        try body.appendUleb128(12);
                        try body.appendOpcode(.i32_const);
                        try body.appendIleb128(0);
                        try body.appendOpcode(.i32_lt_s);
                        try body.appendOpcode(.local_set);
                        try body.appendUleb128(10);
                    }
                }
            },
            
            // JMP rel32 (E9)
            0xE9 => {
                // Unconditional jump. 
                // In purely structural WASM, we break to an appropriate block depth.
                // For this standalone test phase, we'll just emit a `br 0` indicating a break from current block.
                try body.appendOpcode(.br);
                try body.appendUleb128(0); // break depth 0 label mapping
            },
            
            // JMP rel8 (EB)
            0xEB => {
                try body.appendOpcode(.br);
                try body.appendUleb128(0);
            },
            
            // Jcc short (70-7F)
            0x70...0x7F => {
                // Conditional jump based on flags.
                const cc: u4 = @truncate(insn.opcode);
                
                // For simplicity, let's map JZ (Jump if Zero, 0x74) which checks ZF.
                if (cc == 0x4) {
                    try body.appendOpcode(.local_get);
                    try body.appendUleb128(9); // ZF
                    try body.appendOpcode(.br_if);
                    try body.appendUleb128(0);
                } else {
                    // Other CC evaluation logic skipping for structural template
                }
            },

            // CALL rel32 (E8)
            0xE8 => {
                // CALL pushes EIP to the x86 stack and jumps.
                // x86 stack operates via ESP mapped to memory.
                
                // 1. Load ESP (Local 4)
                try body.appendOpcode(.local_get);
                try body.appendUleb128(4);
                
                // 2. Subtract 4 from ESP
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(4);
                try body.appendOpcode(.i32_sub);
                
                // 3. Save new ESP
                try body.appendOpcode(.local_tee);
                try body.appendUleb128(4);
                
                // 4. Memory Store (EIP + length) at new ESP
                // WebAssembly: i32.store (align=2, offset=0) [Address] [Value]
                try body.appendOpcode(.i32_const);
                // Placeholder EIP push
                try body.appendIleb128(0); 
                try body.appendOpcode(.i32_store);
                try body.appendUleb128(2); // align 32bit
                try body.appendUleb128(0); // offset 0
                
                // 5. Jump (break)
                try body.appendOpcode(.br);
                try body.appendUleb128(0);
            },
            
            // RET (C3)
            0xC3 => {
                // RET pops EIP from the x86 stack and jumps.
                
                // 1. Load from ESP (Local 4)
                try body.appendOpcode(.local_get);
                try body.appendUleb128(4);
                try body.appendOpcode(.i32_load);
                try body.appendUleb128(2); // align 32bit
                try body.appendUleb128(0); // offset 0
                
                // 2. Drop popped value (In a real dynarec, we'd use this for a dynamic jump)
                try body.appendOpcode(.drop);
                
                // 3. Add 4 to ESP
                try body.appendOpcode(.local_get);
                try body.appendUleb128(4);
                try body.appendOpcode(.i32_const);
                try body.appendIleb128(4);
                try body.appendOpcode(.i32_add);
                try body.appendOpcode(.local_set);
                try body.appendUleb128(4);
                
                // 4. End Function Return break
                try body.appendOpcode(.return_);
            },
            
            else => {
                // Ignore unimplemented for now
            },
        }
    }
};

test "jit compiler basic structure" {
    var compiler = JitCompiler.init(std.testing.allocator);
    defer compiler.deinit();

    // Setup some simple test instructions:
    // MOV EAX, 1
    // MOV ECX, 2
    // ADD EAX, ECX
    const x86_test_code = [_]u8{
        0xB8, 0x01, 0x00, 0x00, 0x00, // MOV EAX, 1
        0xB9, 0x02, 0x00, 0x00, 0x00, // MOV ECX, 2
        0x01, 0xC8,                   // ADD EAX, ECX
    };
    
    const wasm_bin = try compiler.compile(0x1000, &x86_test_code);
    defer std.testing.allocator.free(wasm_bin);

    // Should contain magic + version + empty section headers + a single end opcode or something similar
    // depending on the exact implementation in finish().
    try std.testing.expect(wasm_bin.len >= 8); // At least magic and version
}
