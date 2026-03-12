# Zine x86-to-WASM JIT Architecture

Zine includes an experimental Just-In-Time (JIT) compiler designed to translate 32-bit x86 instructions into WebAssembly (WASM) bytecode at runtime.

The JIT compiler is designed to be fully self-contained in the `src/jit` directory, operating without impacting the main interpreter loop.

## Architecture and Components

The JIT pipeline consists of three main components:

### 1. WebAssembly Definitions (`wasm.zig`)
Contains constants and enums defining the binary structure of WASM.
- **Section IDs**: Custom, Type, Import, Func, Table, Memory, Global, Export, Start, Element, Code, Data, DataCount
- **ValTypes**: `i32`, `i64`, `f32`, `f64`
- **Opcodes**: A subset of common WASM bytecode instructions (e.g. `i32.add`, `local.get`, `br_if`).

### 2. Bytecode Emitter (`emitter.zig`)
Provides binary serialization utilities required for generating a standard `.wasm` module.
- **`Buffer`**: A wrapper around `std.ArrayListUnmanaged(u8)` to accumulate bytecode reliably.
- **LEB128 Encoders**: Functions to encode unsigned (`appendUleb128`) and signed (`appendIleb128`) integers, which WebAssembly uses for most immediate values.
- **`WasmModule`**: Manages the construction of the final WASM binary by tracking distinct sections (Type, Func, Export, Code) and writing them out with proper sizes.

### 3. JIT Compiler (`compiler.zig`)
The core orchestrator that bridges the x86 decoder and the WASM emitter.

The `JitCompiler` currently acts as a template for translating blocks of x86 code.
- **Register Mapping**: Maps x86 general-purpose registers (EAX...EDI) to contiguous WebAssembly local variables (`i32`).
- **Translation Loop**: Decodes x86 instructions sequentially using `decoder.zig` and delegates them to the translation logic until it encounters an unsupported opcode or the block terminates.
- **Instruction Support**: Currently translates basic `MOV` and `ALU` operations (`ADD`, `SUB`, `AND`, `OR`, `XOR`).

## Translation Concepts

### Register Management
WebAssembly executes on a stack machine, but standard blocks and functions declare local variables that can be loaded to / popped from the stack. The JIT leverages these locals to store the x86 register state across an execution block. Local index `0` represents EAX, index `1` represents ECX, etc., mapping identically to their x86 encoding indices.

### Control Flow
Currently, the JIT emits a single global WASM function representing a basic block. This single block is built completely linearly. Future designs will implement `br` and `br_if` constructs internally, or lift them back to the host execution environment for cross-block dispatching.

## Caching

A crucial component of any dynamic recompiler is avoiding re-translating the same blocks of code.

### Block Caching Strategy
1. **Instruction Pointer Mapping:** The generated WebAssembly functions will be cached centrally. The cache will map the starting x86 Guest `EIP` (Instruction Pointer) directly to the compiled WebAssembly function reference.
2. **Cache Invalidation:** Because x86 allows Self-Modifying Code (SMC), we must implement page-protection mechanisms tracking which x86 memory bounds correspond to cached WASM blocks. If the guest writes to these memory regions, the associated JIT cache entries must be evicted.
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

### Phase 3: Condition Codes & Flags (Partial)
x86 heavily relies on a central status register (EFLAGS). Unlike x86 instructions which natively update flags contextually, WebAssembly mathematics do not magically compute carry/overflow flags.
- [x] **Abstract Status Flag Representation**: Determine whether to map CPU flags into discrete `i32` WebAssembly locals or into a singular packed EFLAGS-simulating local.
- [ ] **Synthetic Flag Calculation**: Emit WebAssembly opcode sequences (e.g., bitwise parity, sign bit checks, and explicit carry evaluations) *immediately following* translated `ALU` operations to keep the synthetic flags accurate. *(Currently only ZF and SF are computed; CF and OF are skipped.)*
- [ ] **Comparisons**: Implement specific x86 `CMP` and `TEST` translations optimized uniquely for flag generation without storing results.

### Phase 4: Control Flow (Partial)
Translating branching logic is critical because WebAssembly operates as a strictly-structured language, whereas x86 assembly supports arbitrary cross-module jumping.
- [ ] **Conditionals**: Map `JMP` and conditional `Jcc` (Jump if Carry, Jump if Zero) into structured WebAssembly `block` logic utilizing `br` and `br_if` breaks. *(Currently only JZ is implemented; other conditionals are skipped.)*
- [ ] **Basic Flow Analysis**: WebAssembly doesn't support wild `goto` instructions. The JIT must pre-analyze x86 execution bounds to construct valid `loop` and `block` hierarchies dynamically.
- [ ] **Subroutines**: Implement `CALL` and `RET` mechanisms, mapping the x86 guest stack pointers explicitly by translating implicit memory pushes/pops into literal `i32.store` and `i32.load` operations. *(CALL currently pushes a placeholder 0 as return EIP.)*

### Phase 5: Memory Accesses (Partial)
Operating outside of local registers requires translating hardware pointers into WebAssembly linear `memory` addressing.
- [ ] **Dereferencing**: Support indirect `MOV [mem], reg` and `MOV reg, [mem]` translations by compiling the x86 ModR/M effective-address structures (Base + Index * Scale + Displacement). *(Currently only basic register-based ModRM; no displacement support.)*
- [ ] **Memory Segments**: Validate legacy Segment mappings (`CS`, `DS`, `SS`) during WASM pointer calculation, especially for Windows 32-bit TEB (Thread Environment Block) pointer accesses via the `FS` register.
- [ ] **Linkage**: Connect standard WebAssembly `memory` exports securely to the primary `zine` x86 4GB virtual address space.

### Phase 6: Advanced Recompilation (Dynarec Integration) (Not Started)
The final phase lifts the JIT from compiling one-off instruction structures into a cohesive, high-speed emulation engine.
- [ ] **Block Caching**: Hook the translation map directly into the core `cpu.zig` loop, mapped securely to guest Instruction Pointers (`EIP`). *(A HashMap struct field exists but has no implementation.)*
- [ ] **Page Protection**: Implement MMU-level page protection memory interception algorithms to guarantee Cache Invalidation correctly catches SMC (Self-Modifying Code) writes instantly.
- [ ] **Trace Linking**: Implement direct WebAssembly-to-WebAssembly block trampolines, allowing the engine to traverse "hot" code loops without costly context-switches back into the host Zig interpreter.

## Usage
*Note: The JIT compiler is a standalone framework and is not yet hooked up into `zine`'s main execution loop. Code currently tests structurally through the standard `zig test` routines.*

## References & Further Reading
- [WebAssembly Core Specification (Opcodes & Binary Format)](https://webassembly.github.io/spec/core/binary/index.html)
- [Intel 64 and IA-32 Architectures Software Developer Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
- [Dolphin Emulator Dynarec Architecture](https://dolphin-emu.org/docs/guides/overview-dolphin-architecture/) - Excellent primer on handling CPU flags and register caching in dynamic recompilers.
- [V8 Ignition & TurboFan](https://v8.dev/docs/ignition) - Deep dive into modern WebAssembly and JavaScript compilation tiers.
