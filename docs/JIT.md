# Zine x86-to-WASM JIT Architecture

Zine includes an experimental Just-In-Time (JIT) compiler designed to translate 32-bit x86 instructions into WebAssembly (WASM) bytecode at runtime.

The JIT compiler is designed to be fully self-contained in the `src/jit` directory, operating without impacting the main interpreter loop.

## Architecture and Components

The JIT pipeline consists of four main components:

### 1. WebAssembly Definitions (`wasm.zig`)
Contains constants and enums defining the binary structure of WASM.
- **Section IDs**: Custom, Type, Import, Func, Table, Memory, Global, Export, Start, Element, Code, Data, DataCount
- **ValTypes**: `i32`, `i64`, `f32`, `f64`
- **Opcodes**: WASM bytecode instructions covering i32 arithmetic, comparisons, loads/stores (including 8/16-bit variants), control flow (`block`, `if`, `br_if`), and i32↔i64 conversions.
- **BlockType**: Enum for structured control flow block signatures (`void`, `i32`, etc.).

### 2. Bytecode Emitter (`emitter.zig`)
Provides binary serialization utilities required for generating a standard `.wasm` module.
- **`Buffer`**: A wrapper around `std.ArrayListUnmanaged(u8)` to accumulate bytecode reliably.
- **LEB128 Encoders**: Functions to encode unsigned (`appendUleb128`) and signed (`appendIleb128`) integers, which WebAssembly uses for most immediate values.
- **`WasmModule`**: Manages the construction of the final WASM binary by tracking distinct sections (Type, Func, Export, Code) and writing them out with proper sizes.

### 3. Translation Helpers (`translate.zig`)
Factored-out primitives used by the compiler for instruction translation:
- **`emitEffectiveAddress`**: Computes x86 memory operand addresses using the compact Instruction struct's flat `mem_base`/`mem_index`/`mem_scale`/`mem_disp` fields (full SIB support: base + index×scale + displacement).
- **`emitLoadOperand` / `emitStoreOperand`**: Handles register, memory (with proper 8/16/32-bit load/store sizing), immediate, and relative operands. Uses the `OpKind` enum and `op0_reg`/`op1_reg` fields from the compact Instruction format.
- **`emitConditionCode`**: Emits Wasm code to evaluate any of the 16 x86 condition codes (JO/JNO/JB/JNB/JZ/JNZ/JBE/JA/JS/JNS/JP/JNP/JL/JGE/JLE/JG).
- **`emitUpdateZfSf` / `emitClearCfOf`**: Flag computation helpers.
- **`emitPush32` / `emitPop32`**: ESP manipulation + memory store/load for stack operations.

### 4. JIT Compiler (`compiler.zig`)
The core orchestrator that bridges the x86 decoder and the WASM emitter.

- **Register Mapping**: Maps x86 general-purpose registers (EAX...EDI) to contiguous WebAssembly local variables (`i32`).
- **Translation Loop**: Decodes x86 instructions sequentially using `decoder.zig` (producing compact `Instruction` structs with flat `OpKind` operand encoding) and delegates them to the translation logic until it encounters an unsupported opcode or the block terminates. Uses `insn.has_modrm` and `insn.modrm_reg` for group instruction sub-opcode dispatch, and `insn.op0_kind`/`insn.op1_kind` for operand type dispatch.
- **Instruction Support**: Translates all instruction categories handled by the interpreter — data movement, ALU, multiply/divide, shifts/rotates, control flow, flag manipulation, and more. Rarely-used instructions (FPU, I/O, BCD, segment ops) are stubbed as no-ops.

## Translation Concepts

### Register Management
WebAssembly executes on a stack machine, but standard blocks and functions declare local variables that can be loaded to / popped from the stack. The JIT leverages these locals to store the x86 register state across an execution block.

| Local | Purpose |
|-------|-------------|
| 0–7 | EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI |
| 8 | CF (Carry Flag) |
| 9 | ZF (Zero Flag) |
| 10 | SF (Sign Flag) |
| 11 | OF (Overflow Flag) |
| 12 | Scratch register |
| 13 | DF (Direction Flag) |
| 14 | PF (Parity Flag) |
| 15 | mem_base (memory base address for guest loads/stores) |

### Control Flow
The JIT emits `br` and `br_if` for unconditional and conditional jumps respectively, with condition code evaluation covering all 16 x86 CCs. `CALL` pushes a return address to the guest stack via `i32.store` and branches; `RET` pops via `i32.load` and returns. `CMOVcc` uses `if`/`end` blocks. Future designs will implement cross-block dispatching via trace linking.

## Caching

A crucial component of any dynamic recompiler is avoiding re-translating the same blocks of code.

### Interpreter Decode Cache (Implemented)
The interpreter uses a 1024-entry hash-indexed **instruction decode cache** (`decode_cache.zig`) that maps guest EIP addresses to previously decoded `Instruction` structs. Each entry is validated by both the EIP tag and the first 4 bytes of the instruction stream, which provides basic self-modifying code detection — if code is modified, the tag will mismatch on the next lookup, causing a cache miss and re-decode from the modified bytes.

### JIT Block Caching Strategy (Planned)
1. **Instruction Pointer Mapping:** The generated WebAssembly functions will be cached centrally. The cache will map the starting x86 Guest `EIP` (Instruction Pointer) directly to the compiled WebAssembly function reference.
2. **Cache Invalidation:** Because x86 allows Self-Modifying Code (SMC), we must implement page-protection mechanisms tracking which x86 memory bounds correspond to cached WASM blocks. If the guest writes to these memory regions, the associated JIT cache entries must be evicted. The interpreter's decode cache tag validation provides a basic level of SMC detection; for JIT blocks, mprotect-based detection (à la Blink) would provide zero-cost detection in the common case.
3. **Trace Linking:** Frequently executed blocks (hot paths) that jump sequentially to other known blocks can be "linked," allowing WebAssembly to jump directly to the next translated block without exiting to the main interpreter loop.

## Handling Self-Modifying Code (SMC)

Self-Modifying Code is historically the hardest problem for x86 recompilers (especially for games and legacy DRM which use it heavily). When guest code overwrites an instruction that has already been compiled to WebAssembly, the JIT must guarantee that the stale WASM block is never executed again. 

Zine handles this with **Page Protection and Memory Watchers**:
1. **Marking Translated Pages:** When the JIT translates a block of memory, it marks the underlying guest memory page (usually 4KB) as "Translated" in the MMU (Memory Management Unit).
2. **Write Intercepts:** The MMU enforces soft "Read-Only" permissions on these Translated pages.
3. **Cache Eviction:** If a guest `MOV` or `STOSD` instruction attempts to write to a Translated page, the MMU intercepts the trap. The JIT looks up which cached WebAssembly blocks overlap with the modified bytes, invalidates those specific function references from the cache map, and allows the write to proceed.
4. **Re-Translation:** The next time `EIP` lands on the modified block, it will fall back to the interpreter or trigger a fresh JIT compilation of the mutated code.

## Optimizations

While the initial goal is 1:1 behavioral translation, several optimizations exist to bridge the performance gap:
- **Flag Elision:** x86 ALU operations aggressively update the status flags (Carry, Zero, Sign, Overflow). However, most CPU flags are completely ignored by the subsequent instructions. A basic dead-store elimination pass can avoid emitting WASM bytecode that computes flags if the next instruction overwrites them or never checks them.
- **Constant Folding & Propagation:** If the JIT observes `MOV EAX, 1` followed immediately by `ADD EAX, 2`, the translation can statically evaluate this and emit `MOV EAX, 3`.
- **Register Allocation Smoothing:** By looking ahead, sequences of operations pushing to memory and popping back to registers can be kept purely in WebAssembly locals until an absolute memory synchronization point is required.

## Implementation Phases

The JIT is being rolled out incrementally to ensure memory stability and testing isolation. Below is the detailed feature rollout roadmap.

### Phase 1: JIT Bones (Complete)
The initial phase establishes the WebAssembly output infrastructure.
- [x] Define WebAssembly constants (Types, Sections, Opcodes)
- [x] Create the WebAssembly serialization emitter (`Buffer`, `WasmModule` utilizing LEB128 encoding)
- [x] Implement the foundational compiler struct and hook it into the `zine` x86 decoder logic

### Phase 2: Linear Arithmetic (Complete)
The second phase establishes the capability to compute standalone x86 math flows.
- [x] Map generic x86 registers (`EAX`..`EDI`) to local WebAssembly `i32` variables to preserve state efficiently.
- [x] Implement memory-safe `MOV reg, imm` and `MOV reg, reg` bytecode generation.
- [x] Implement translation for baseline `ALU` block operations (`ADD`, `SUB`, `AND`, `OR`, `XOR`).

### Phase 3: Condition Codes & Flags (Complete)
x86 heavily relies on a central status register (EFLAGS). Unlike x86 instructions which natively update flags contextually, WebAssembly mathematics do not magically compute carry/overflow flags.
- [x] **Abstract Status Flag Representation**: CPU flags mapped to discrete `i32` WebAssembly locals (CF, ZF, SF, OF, DF, PF — locals 8–14).
- [x] **Synthetic Flag Calculation**: ZF and SF computed inline after all ALU/shift/INC/DEC operations. CF/OF cleared for logic ops. Dedicated helpers for ADD carry and SUB borrow.
- [x] **Comparisons**: `CMP` and `TEST` translations emit flag updates without storing results.
- [x] **PUSHFD/POPFD**: Synthesize/decompose packed EFLAGS from/to individual flag locals.
- [x] **Flag manipulation**: CLC, STC, CLD, STD, CMC translated to direct local set/toggle.

### Phase 4: Control Flow (Complete)
Translating branching logic is critical because WebAssembly operates as a strictly-structured language, whereas x86 assembly supports arbitrary cross-module jumping.
- [x] **Conditionals**: All 16 x86 Jcc conditions (JO/JNO/JB/JNB/JZ/JNZ/JBE/JA/JS/JNS/JP/JNP/JL/JGE/JLE/JG) mapped to `br_if` with condition evaluation via `translate.emitConditionCode`.
- [x] **SETcc/CMOVcc**: All 16 conditions supported. CMOVcc uses Wasm `if`/`end` blocks.
- [x] **LOOP/LOOPcc/JECXZ**: ECX decrement + conditional branch.
- [ ] **Basic Flow Analysis**: WebAssembly doesn't support wild `goto` instructions. The JIT must pre-analyze x86 execution bounds to construct valid `loop` and `block` hierarchies dynamically.
- [x] **Subroutines**: `CALL` pushes return address to guest stack via `i32.store`; `RET`/`RET imm16` pops via `i32.load`. `LEAVE` implemented.

### Phase 5: Memory Accesses (Complete)
Operating outside of local registers requires translating hardware pointers into WebAssembly linear `memory` addressing.
- [x] **Dereferencing**: Full ModR/M effective-address support (Base + Index × Scale + Displacement) via `translate.emitEffectiveAddress`. Supports `i32.load`, `i32.load8_u`, `i32.load16_u`, `i32.store`, `i32.store8`, `i32.store16`.
- [x] **Operand Abstraction**: Unified `emitLoadOperand`/`emitStoreOperand` handles reg, memory, immediate, and relative operands with correct sizing.
- [ ] **Memory Segments**: Validate legacy Segment mappings (`CS`, `DS`, `SS`) during WASM pointer calculation, especially for Windows 32-bit TEB (Thread Environment Block) pointer accesses via the `FS` register.
- [ ] **Linkage**: Connect standard WebAssembly `memory` exports securely to the primary `zine` x86 4GB virtual address space.

### Phase 6: Advanced Recompilation (Dynarec Integration) (Not Started)
The final phase lifts the JIT from compiling one-off instruction structures into a cohesive, high-speed emulation engine.
- [x] **Block Caching**: Translation map hooked into the execution loop in `runner.zig` (`runWithJit`) and `wasm_main.zig` (`runWithJitHost`), using a HashMap keyed by guest EIP to avoid re-translating previously compiled blocks.
- [ ] **Page Protection**: Implement MMU-level page protection memory interception algorithms to guarantee Cache Invalidation correctly catches SMC (Self-Modifying Code) writes instantly.
- [ ] **Trace Linking**: Implement direct WebAssembly-to-WebAssembly block trampolines, allowing the engine to traverse "hot" code loops without costly context-switches back into the host Zig interpreter.

### 5. JIT Host Interface (`host.zig` / `host_wasm.zig`)
Manages CPU state transfer between the interpreter and JIT-compiled blocks:
- **`JitCpuState`**: A 64-byte struct in linear memory containing all 8 GPRs, EIP, and flags — used to pass state between the host and compiled WASM modules.
- **`host.zig`**: Defines the `JitCpuState` struct and state transfer functions (`cpuToJitState` / `jitStateToCpu`).
- **`host_wasm.zig`**: WASM-side imports for `jit_compile` and `jit_call` that communicate with the host runtime (wasmer/wasmtime) to compile and execute JIT blocks.

## Usage

The JIT compiler is integrated into both the native and WASM execution paths:
- **Native** (`--jit`): `runner.runWithJit()` runs a compile-only JIT loop that validates x86→WASM translation but falls back to the interpreter for execution.
- **WASM** (`--jit`): `wasm_main.runWithJitHost()` compiles x86 blocks to WASM, sends them to the host runtime for compilation, and executes them via CPU state transfer through a shared `JitCpuState` struct in linear memory. Falls back to interpreter for uncached blocks.

Unit tests are run via `zig build test`.

## References & Further Reading
- [WebAssembly Core Specification (Opcodes & Binary Format)](https://webassembly.github.io/spec/core/binary/index.html)
- [Intel 64 and IA-32 Architectures Software Developer Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
- [Dolphin Emulator Dynarec Architecture](https://dolphin-emu.org/docs/guides/overview-dolphin-architecture/) - Excellent primer on handling CPU flags and register caching in dynamic recompilers.
- [V8 Ignition & TurboFan](https://v8.dev/docs/ignition) - Deep dive into modern WebAssembly and JavaScript compilation tiers.
