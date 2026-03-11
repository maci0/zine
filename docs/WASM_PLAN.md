# WASM Target: Running Win32 PE Binaries in the Browser

## Goal

Run unmodified 32-bit Windows PE executables entirely in the browser by combining:
- The existing Win32 API stub layer (no hardware/kernel emulation needed)
- A new x86 interpreter (Tier 0) compiled to WASM via Zig's wasm32 target
- An optional x86-to-WASM JIT (Tier 1) for hot code paths

This approach outperforms v86, qemu-wasm, and Boxedwine for our use case because
we skip both hardware emulation and kernel emulation — we stub at the Win32 API
level, which is what CheerpX does with Linux syscalls but one layer higher.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  Browser                                            │
│  ┌───────────────────────────────────────────────┐  │
│  │  JavaScript Host                              │  │
│  │  - WebAssembly.Module instantiation           │  │
│  │  - Canvas/WebGL for rendering                 │  │
│  │  - Keyboard/mouse event forwarding            │  │
│  │  - File system (IndexedDB / virtual FS)       │  │
│  │  - JIT module compiler (Tier 1)               │  │
│  └──────────────┬────────────────────────────────┘  │
│                 │ WASM imports/exports               │
│  ┌──────────────▼────────────────────────────────┐  │
│  │  winloader.wasm (Zig → wasm32-freestanding)   │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │  PE Loader (module.zig, loader.zig)     │  │  │
│  │  │  - Parse PE headers                     │  │  │
│  │  │  - Map sections into linear memory      │  │  │
│  │  │  - Apply base relocations               │  │  │
│  │  │  - Resolve imports → stub table         │  │  │
│  │  └──────────────┬──────────────────────────┘  │  │
│  │  ┌──────────────▼──────────────────────────┐  │  │
│  │  │  x86 CPU Emulator                       │  │  │
│  │  │  ┌──────────┐    ┌──────────────────┐   │  │  │
│  │  │  │ Tier 0   │    │ Tier 1           │   │  │  │
│  │  │  │ Interp.  │───>│ x86→WASM JIT     │   │  │  │
│  │  │  │ (all     │    │ (hot blocks only, │   │  │  │
│  │  │  │  code)   │    │  via JS interop)  │   │  │  │
│  │  │  └──────────┘    └──────────────────┘   │  │  │
│  │  └──────────────┬──────────────────────────┘  │  │
│  │  ┌──────────────▼──────────────────────────┐  │  │
│  │  │  Win32 API Stubs (existing)             │  │  │
│  │  │  kernel32, user32, gdi32, msvcrt, ...   │  │  │
│  │  │  (adapted for WASM: no POSIX, use JS)   │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

---

## Tier 0: x86 Interpreter

### What it is

A software x86 CPU that decodes and executes instructions one at a time inside
the WASM linear memory. Written in Zig, compiled to wasm32-freestanding. This is
the minimum viable path to running PE binaries in the browser.

### CPU State

```zig
const Cpu = struct {
    // General purpose registers
    eax: u32, ebx: u32, ecx: u32, edx: u32,
    esi: u32, edi: u32, ebp: u32, esp: u32,

    // Instruction pointer
    eip: u32,

    // Segment registers (mostly flat model, but need FS for TEB)
    cs: u16, ds: u16, es: u16, fs: u16, gs: u16, ss: u16,

    // EFLAGS - use lazy evaluation (store last op + operands, compute on read)
    flags: LazyFlags,

    // FPU state (x87 stack + SSE)
    fpu: FpuState,

    // Memory - index into WASM linear memory
    memory_base: u32,  // base offset of the 4GB guest address space
    memory_size: u32,  // allocated size

    // Execution state
    halted: bool,
    pending_interrupt: ?u8,
};
```

### Lazy Flags (critical optimization)

x86 sets FLAGS on almost every ALU instruction but they're rarely read. Computing
all 6 status flags (CF, PF, AF, ZF, SF, OF) on every instruction is ~30% overhead.

```zig
const LazyFlags = struct {
    // Instead of computing flags immediately, store the operation context
    op: FlagOp,        // what operation produced these flags
    result: u32,       // result value
    operand1: u32,     // first operand (for CF/OF computation)
    operand2: u32,     // second operand
    size: OpSize,      // byte/word/dword

    // Only compute when actually read
    fn getZF(self: *const LazyFlags) bool { return self.result == 0; }
    fn getSF(self: *const LazyFlags) bool { return (self.result >> self.size.bits() - 1) & 1 != 0; }
    fn getCF(self: *const LazyFlags) bool {
        return switch (self.op) {
            .add => self.result < self.operand1,
            .sub => self.operand1 < self.operand2,
            .shl => // carry from shifted-out bit
            // ...
        };
    }
};
```

### Instruction Decoding

x86 is a variable-length CISC ISA. The decoder must handle:

1. **Prefixes** (0-4 bytes): LOCK, REP/REPNE, segment override, operand/address size
2. **Opcode** (1-3 bytes): single byte, 0x0F + byte, or 0x0F 0x38/0x3A + byte
3. **ModR/M** (0-1 byte): mod, reg, r/m fields → register/memory operand encoding
4. **SIB** (0-1 byte): scale, index, base → complex addressing modes
5. **Displacement** (0/1/2/4 bytes): memory offset
6. **Immediate** (0/1/2/4 bytes): constant operand

```zig
const Instruction = struct {
    prefixes: Prefixes,
    opcode: u16,          // extended opcodes use 0x0Fxx
    modrm: ?ModRM,
    sib: ?SIB,
    displacement: i32,
    immediate: u32,
    length: u8,           // total instruction length for EIP advancement
};
```

### Decode-and-dispatch loop

```zig
pub fn run(cpu: *Cpu) void {
    while (!cpu.halted) {
        const insn = decode(cpu.mem(cpu.eip));
        execute(cpu, insn);
        cpu.eip += insn.length;
    }
}
```

For better performance, decode into basic blocks (sequences ending at
branches) and cache the decoded blocks keyed by address. Invalidate on
writes to code pages.

### Block caching

```zig
const DecodedBlock = struct {
    start_eip: u32,
    instructions: []Instruction,
    terminal: Terminal, // jmp, call, ret, conditional branch, etc.
};

// Cache: eip → DecodedBlock
// Invalidation: mark code pages; on write to a code page, flush blocks
// on that page. Use a simple page bitmap (1 bit per 4KB page).
var block_cache: std.AutoHashMap(u32, *DecodedBlock) = undefined;
var code_page_bitmap: [1024 * 1024 / 32]u32 = undefined; // 4GB / 4KB / 32
```

### Memory model

The guest x86 address space lives inside WASM linear memory. WASM gives us a
flat byte-addressable memory, which maps well to x86's flat model.

```
WASM Linear Memory Layout:
┌────────────────────────┐ 0x00000000
│  winloader code/data   │ (Zig runtime, interpreter, stubs)
├────────────────────────┤ GUEST_BASE (e.g., 0x01000000)
│  Guest x86 address     │
│  space (up to ~3GB)    │
│  - PE sections mapped  │
│  - Stack               │
│  - Heap                │
│  - TEB/PEB             │
├────────────────────────┤
│  Block cache, tables   │
└────────────────────────┘
```

Guest memory reads/writes: `wasm_memory[GUEST_BASE + guest_addr]`

Must bounds-check to prevent guest code from corrupting interpreter state.
Use `@intCast` and Zig's bounds checking, or a dedicated
`guest_read(addr, size)` / `guest_write(addr, val, size)` that validates
the range.

### Import thunking (x86 → stub calls)

When the PE's IAT is patched during import resolution, we can't point at
real function addresses (those are WASM functions, not x86 code). Instead:

1. Allocate a **thunk table** in guest memory — a page of x86 `INT 0xFE`
   instructions (or similar trap), one per imported function
2. Patch each IAT entry to point at the corresponding thunk slot
3. When the interpreter hits `INT 0xFE`, look up the thunk index and
   dispatch to the Zig stub implementation
4. The stub reads arguments from the guest stack (stdcall convention:
   args pushed right-to-left, callee cleans), executes, and writes
   the return value to guest EAX

```zig
// Thunk table: each entry is 2 bytes (CD FE = INT 0xFE)
// followed by 4 bytes thunk ID, so 6 bytes per entry
fn createThunk(thunk_id: u32) [6]u8 {
    return .{ 0xCD, 0xFE } ++ @bitCast([4]u8, thunk_id);
}

fn handleThunk(cpu: *Cpu, thunk_id: u32) void {
    const stub_fn = thunk_table[thunk_id];
    // Read args from guest stack per stdcall convention
    // Call the Zig stub
    // Put return value in cpu.eax
    // Adjust cpu.esp (callee-pops for stdcall)
}
```

### x86 instruction subset to prioritize

Based on typical Win32 PE compiler output (MSVC), prioritize in this order:

**Phase 1 — Enough to enter main():**
- MOV (reg/mem/imm variants, all ModR/M modes)
- PUSH/POP (reg, imm, mem)
- CALL (direct, indirect via register, indirect via memory)
- RET / RET imm16
- JMP (direct, indirect)
- Jcc (all conditional jumps: JE, JNE, JB, JAE, JL, JGE, etc.)
- CMP, TEST
- ADD, SUB, AND, OR, XOR
- LEA
- NOP, INT 3 (breakpoint → ignore), INT 0xFE (thunk trap)
- MOVZX, MOVSX (zero/sign extend)

**Phase 2 — String and memory operations:**
- REP MOVSB/MOVSD (memcpy)
- REP STOSB/STOSD (memset)
- REPNE SCASB (strlen-like)
- CMPSB/CMPSD

**Phase 3 — Arithmetic and bit manipulation:**
- IMUL, MUL, IDIV, DIV
- SHL, SHR, SAR, ROL, ROR
- NEG, NOT, INC, DEC
- CDQ, CBW, CWDE
- XCHG, BSWAP
- BT, BTS, BTR, BSF, BSR
- SETcc (conditional set)
- CMOVcc (conditional move)

**Phase 4 — FPU (x87):**
- FLD, FST, FSTP (load/store)
- FADD, FSUB, FMUL, FDIV
- FCOM, FCOMP (compare)
- FNSTSW, FNSTCW, FLDCW (status/control words)
- Most Win32 apps use only basic FP; SSE can be deferred

**Phase 5 — SSE/SSE2 (if needed):**
- MOVSS, MOVSD, MOVAPS, MOVUPS
- ADDSS/SD, SUBSS/SD, MULSS/SD, DIVSS/SD
- CVTSI2SS, CVTTSS2SI (int↔float conversion)

### Segment handling

Most Win32 code uses flat memory (CS=DS=ES=SS all base 0). The exception
is FS, which points to the TEB. In the interpreter, handle this by
maintaining a `fs_base` offset:

```zig
fn resolveSegmentAddress(cpu: *Cpu, seg: Segment, offset: u32) u32 {
    return switch (seg) {
        .fs => cpu.fs_base + offset,
        else => offset, // flat model, base = 0
    };
}
```

### Stub adaptation for WASM

The existing stubs use POSIX syscalls (open, read, write, mmap, etc.) and
inline asm (FS segment setup). For WASM, these need a backend swap:

| Native backend | WASM backend |
|---|---|
| POSIX open/read/write | JS File API / virtual FS in memory |
| POSIX mmap | Bump allocator in WASM linear memory |
| stdout/stderr (fd 1, 2) | JS console.log / DOM element |
| sigaction (SIGSEGV handler) | Not needed; interpreter catches faults |
| arch_prctl (FS segment) | cpu.fs_base in interpreter state |
| fork/execve | Not supported (or spawn Web Worker) |
| clock_gettime | performance.now() via JS import |
| WebSocket server (web_ui) | Direct DOM manipulation via JS imports |

### Build target

```zig
// build.zig addition for WASM target
const wasm_target = b.resolveTargetQuery(.{
    .cpu_arch = .wasm32,
    .os_tag = .freestanding,
});

const wasm_exe = b.addExecutable(.{
    .name = "winloader",
    .root_source_file = b.path("src/wasm_main.zig"),
    .target = wasm_target,
    .optimize = .ReleaseFast,
});
wasm_exe.export_memory = true;
wasm_exe.initial_memory = 256 * 1024 * 1024; // 256MB initial
wasm_exe.max_memory = 2 * 1024 * 1024 * 1024; // 2GB max (WASM limit ~4GB)
```

### Estimated instruction count

A typical MSVC-compiled Win32 binary uses ~150-200 distinct x86 opcode
patterns. The interpreter needs ~2000-3000 lines of Zig for the decoder
and ~3000-5000 lines for execute handlers. Total: ~5000-8000 lines for a
working Tier 0.

---

## Tier 1: x86-to-WASM JIT

### When to JIT

Profile during interpretation. Track execution count per basic block.
When a block exceeds a threshold (e.g., 1000 executions), compile it to
a WASM module.

```zig
const JIT_THRESHOLD = 1000;

fn maybeJit(block: *DecodedBlock) void {
    block.exec_count += 1;
    if (block.exec_count >= JIT_THRESHOLD and !block.is_jitted) {
        const wasm_bytes = emitWasmModule(block);
        // Call out to JS to compile: WebAssembly.Module(wasm_bytes)
        js_compile_module(wasm_bytes.ptr, wasm_bytes.len, block.start_eip);
        block.is_jitted = true;
    }
}
```

### How it works

1. Take a decoded basic block (or a connected region of blocks)
2. Emit WASM bytecode that performs the equivalent operations
3. The WASM module imports the CPU state (registers as globals or a
   shared memory region) and the guest memory
4. Hand the bytes to JS via an exported function
5. JS calls `new WebAssembly.Module(bytes)` + `new WebAssembly.Instance(...)`
6. Store the resulting callable function, keyed by EIP
7. On subsequent hits to that EIP, call the JIT'd function instead of
   interpreting

### WASM module structure (per compiled region)

```wasm
(module
  ;; Import guest memory (shared with interpreter)
  (import "env" "memory" (memory 1))

  ;; Import CPU state accessors
  (import "env" "get_eax" (func $get_eax (result i32)))
  (import "env" "set_eax" (func $set_eax (param i32)))
  ;; ... etc for all registers

  ;; Import helper functions for complex ops
  (import "env" "call_thunk" (func $call_thunk (param i32)))
  (import "env" "handle_fault" (func $handle_fault (param i32 i32)))

  ;; The compiled basic block
  (func $block_0x00401000 (export "run") (result i32)
    ;; Returns new EIP (branch target) so interpreter knows where to resume

    ;; Example: mov eax, [ebp+8]
    call $get_ebp
    i32.const 8
    i32.add
    i32.load          ;; load from guest memory
    call $set_eax

    ;; Example: add eax, ecx
    call $get_eax
    call $get_ecx
    i32.add
    call $set_eax
    ;; (lazy flags: store op=ADD, result, operands)

    ;; Example: jne target
    ;; compute ZF from lazy flags
    call $get_zf
    if (result i32)
      i32.const 0x00401020  ;; fall-through EIP
    else
      i32.const 0x00401050  ;; branch target EIP
    end
  )
)
```

### Alternative: registers in shared memory (faster)

Instead of import/export functions per register, store CPU state in a
known offset of WASM linear memory. The JIT'd module shares the same
memory and reads/writes registers directly:

```wasm
;; CPU state at offset 0 in shared memory
;; EAX = offset 0, ECX = offset 4, EDX = offset 8, ...
;; This avoids call overhead for every register access

;; mov eax, [ebp+8]  →
i32.const 20        ;; offset of EBP in CPU state
i32.load            ;; load EBP value
i32.const 8
i32.add             ;; EBP+8
i32.load            ;; load from guest memory (need base adjustment)
i32.const 0         ;; offset of EAX in CPU state
i32.store           ;; store to EAX
```

### Structured control flow challenge

WASM has no `goto`. x86 has arbitrary jumps. Solutions:

**For intra-block control flow (within a compiled region):**
Use `block`/`loop`/`br_table` to implement a dispatch loop:

```wasm
(func $region (export "run") (result i32)
  (local $pc i32)
  (local.set $pc (i32.const 0))  ;; block index

  (block $exit
    (loop $dispatch
      (block $b2
        (block $b1
          (block $b0
            (br_table $b0 $b1 $b2 $exit (local.get $pc))
          )  ;; $b0: first basic block
          ;; ... instructions ...
          ;; conditional branch:
          (local.set $pc (i32.const 1))  ;; or 2
          (br $dispatch)
        )  ;; $b1: second basic block
        ;; ...
        (br $dispatch)
      )  ;; $b2: third basic block
      ;; ...
    )
  )

  ;; return new EIP for interpreter to resume at
  (local.get $next_eip)
)
```

**For inter-region jumps (target outside compiled region):**
Return the target EIP and let the interpreter dispatch — either to another
JIT'd region or back to interpretation.

### WASM bytecode emission in Zig

Need a WASM binary encoder. The format is well-specified and simple:

```zig
const WasmBuilder = struct {
    buffer: std.ArrayList(u8),

    fn emitHeader(self: *WasmBuilder) void {
        self.buffer.appendSlice(&.{ 0x00, 0x61, 0x73, 0x6D }); // magic
        self.buffer.appendSlice(&.{ 0x01, 0x00, 0x00, 0x00 }); // version
    }

    fn emitSection(self: *WasmBuilder, id: u8, content: []const u8) void {
        self.buffer.append(id);
        self.emitLEB128(content.len);
        self.buffer.appendSlice(content);
    }

    // Instruction emitters
    fn emitI32Const(self: *WasmBuilder, val: i32) void { ... }
    fn emitI32Load(self: *WasmBuilder, align: u32, offset: u32) void { ... }
    fn emitI32Store(self: *WasmBuilder, align: u32, offset: u32) void { ... }
    fn emitI32Add(self: *WasmBuilder) void { self.buffer.append(0x6A); }
    fn emitI32Sub(self: *WasmBuilder) void { self.buffer.append(0x6B); }
    fn emitI32And(self: *WasmBuilder) void { self.buffer.append(0x71); }
    fn emitI32Or(self: *WasmBuilder) void { self.buffer.append(0x72); }
    fn emitI32Shl(self: *WasmBuilder) void { self.buffer.append(0x74); }
    fn emitI32ShrU(self: *WasmBuilder) void { self.buffer.append(0x76); }
    fn emitI32ShrS(self: *WasmBuilder) void { self.buffer.append(0x75); }
    fn emitBrTable(self: *WasmBuilder, targets: []u32, default: u32) void { ... }
    // ... ~50 emitter functions total
};
```

Reference: v86's `src/rust/wasmgen/wasm_builder.rs` (~800 lines) is a
clean implementation of exactly this.

### JIT invalidation

Self-modifying code (rare in Win32 apps, but possible): track which guest
memory pages have JIT'd blocks. On write to a JIT'd page, discard the
compiled module for that page and fall back to interpretation.

```zig
var jit_page_map: std.AutoHashMap(u32, *JitModule) = undefined;

fn guestWrite(addr: u32, val: u32) void {
    const page = addr >> 12;
    if (jit_page_map.get(page)) |module| {
        module.invalidate();
        jit_page_map.remove(page);
    }
    // perform the actual write
}
```

### Performance expectations

Based on v86 and CheerpX data:
- Tier 0 interpreter: ~50-100x slower than native (but usable for
  short-lived tools like compilers)
- Tier 1 JIT: ~5-20x slower than native (competitive with v86, possibly
  faster due to no hardware emulation overhead)
- For game-like workloads (tight loops, simple math): closer to 5x
- For compiler workloads (lots of string/memory ops): closer to 20x

---

## Implementation Plan

### Phase 1: Refactor for portability ✅ COMPLETE

Abstract platform-specific code behind a backend interface so the same
stub logic works on both native Linux and WASM.

```
src/
  platform/
    native.zig      # Linux backend (POSIX mmap, signals, FS asm, /proc/self/maps)
    wasm.zig         # WASM backend (page_allocator, no-op stubs)
    interface.zig    # Comptime backend selection (wasm32 → wasm, else → native)
```

**Completed:**
- [x] Inventory all POSIX syscalls (mmap, munmap, sigaction, arch_prctl, getpid, /proc/self/maps)
- [x] Inventory all inline asm (FS segment setup in teb.zig, kernel32/misc.zig)
- [x] Create `Platform` interface with methods for: memory, threading, process, stack bounds, TEB, signals
- [x] Move current implementations into `platform/native.zig`
- [x] Create `platform/wasm.zig` with stubs (JS extern imports deferred to Phase 3)
- [x] Switch stubs to use `Platform` instead of direct std.posix calls
- [x] Verify `build.zig` builds all three targets (x86, x86_64, wasm32)

### Phase 2: x86 interpreter core (2-3 weeks)

```
src/
  x86/
    cpu.zig          # CPU state struct
    decoder.zig      # Instruction decoder (prefixes, ModR/M, SIB)
    execute.zig      # Instruction execution (dispatch table)
    flags.zig        # Lazy flags implementation
    memory.zig       # Guest memory access (bounds-checked)
    fpu.zig          # x87 FPU state and basic operations
    thunks.zig       # Import thunk table and dispatch
```

**Completed:**
- [ ] Define CPU state struct with all registers
- [ ] Implement x86 instruction decoder (ModR/M, SIB, prefixes, all
      addressing modes)
- [ ] Implement Phase 1 instructions (MOV, PUSH, POP, CALL, RET, JMP,
      Jcc, CMP, TEST, ADD, SUB, AND, OR, XOR, LEA, NOP)
- [ ] Implement lazy flags
- [ ] Implement guest memory model (base offset into WASM linear memory,
      bounds checking)
- [ ] Implement thunk mechanism for import calls (INT 0xFE trap)
- [ ] Implement basic block decoding and caching
- [ ] Wire up PE loader to use interpreter instead of native execution
      when targeting WASM

**Testing strategy:**
- Unit test individual instructions against known x86 behavior
- Use a small hand-written x86 binary (assemble with nasm) as an
  integration test
- Compare interpreter output vs native execution for existing test
  binaries in `test_binaries/`

### Phase 3: Stub backend for WASM (1-2 weeks)

**Completed:**
- [ ] Implement `platform/wasm.zig`:
  - File I/O → JS virtual filesystem (files pre-loaded into memory or
    fetched via HTTP)
  - Memory allocation → bump allocator in WASM linear memory
  - Console output → JS `console.log` / DOM text node
  - Time → `performance.now()` via JS import
  - Environment variables → JS-provided map
- [ ] Implement JS host (`index.html` + `host.js`):
  - Load winloader.wasm
  - Provide imported functions (file read, console write, time)
  - Load PE binary (via fetch or file input)
  - Pass PE bytes into WASM, trigger execution
  - Render console output in a terminal element (xterm.js)
- [ ] Wire up GUI stubs to Canvas/DOM instead of WebSocket server

### Phase 4: Testing and hardening (1-2 weeks)

**Completed:**
- [ ] Run MSVC CLI tools (CL.EXE, LINK.EXE) through the interpreter
- [ ] Profile hot spots — which instructions dominate execution time
- [ ] Fix instruction decode/execute bugs found by real binaries
- [ ] Add Phase 2-4 instructions as needed (string ops, multiply/divide,
      shifts, FPU basics)
- [ ] Optimize the interpreter hot loop (minimize branch mispredictions,
      consider threaded dispatch)
- [ ] Create a demo page that compiles a .c file using CL.EXE in-browser

### Phase 5: JIT compiler (2-4 weeks, optional)

**Completed:**
- [ ] Implement `WasmBuilder` — WASM binary format encoder in Zig
- [ ] Implement basic block → WASM translation for common instructions
- [ ] Add execution counting and hot-block detection
- [ ] JS-side: accept WASM bytes, compile module, register entry point
- [ ] Implement dispatch: check JIT cache before interpreting
- [ ] Implement JIT invalidation on code page writes
- [ ] Profile and optimize: which blocks benefit most from JIT
- [ ] Implement region compilation (multiple connected blocks in one
      WASM module) to reduce inter-block transition overhead

### Phase 6: Optimization (ongoing)

- [ ] Lazy flag elision — if next instruction overwrites flags, skip
      storing them entirely
- [ ] Constant propagation in JIT'd blocks
- [ ] Register pinning — use WASM locals for frequently-accessed x86
      registers within a JIT'd block
- [ ] Memory access batching — combine adjacent loads/stores
- [ ] Async JIT compilation (compile in Web Worker, don't block
      interpreter)
- [ ] Page-level code/data separation for more efficient JIT
      invalidation

---

## File Structure (new files)

```
winloader/
  src/
    x86/
      cpu.zig              # CPU state, register accessors
      decoder.zig          # x86 instruction decoder
      execute.zig          # Instruction execution dispatch
      flags.zig            # Lazy EFLAGS
      memory.zig           # Guest address space management
      fpu.zig              # x87 FPU (basic ops)
      thunks.zig           # Win32 API thunk table
      block_cache.zig      # Decoded block cache + code page tracking
    jit/
      wasm_builder.zig     # WASM binary format encoder
      codegen.zig          # x86 block → WASM translation
      jit.zig              # JIT controller (profiling, compilation, cache)
    platform/
      interface.zig        # Platform abstraction (comptime selected)
      native.zig           # Linux/POSIX backend
      wasm.zig             # WASM/JS backend (extern imports)
    wasm_main.zig          # WASM entry point (exports for JS)
  web/
    index.html             # Browser frontend
    host.js                # JS host: WASM loader, file system, JIT bridge
    terminal.js            # Console output rendering (xterm.js)
    canvas.js              # GUI rendering (for windowed apps)
  build.zig                # Updated with wasm32 target
```

---

## Open Questions

1. **Memory size**: WASM linear memory is limited to ~4GB. The interpreter
   code + guest address space + block cache + JIT metadata must all fit.
   Need to decide how much guest address space to expose (2GB? 3GB?).

2. **Threading**: Web Workers + SharedArrayBuffer could enable multi-threaded
   guest execution, but adds huge complexity. Defer to later — most Win32
   apps we target are single-threaded.

3. **File system**: How to provide the PE binary and its dependencies to
   the WASM environment? Options:
   - Pre-bundle into the .wasm data section (simplest, largest download)
   - Fetch via HTTP on demand (lazy loading, needs async)
   - IndexedDB persistent cache (for repeated runs)
   - Virtual FS with drag-and-drop upload

4. **x86-64 support**: The interpreter could support 64-bit mode (REX
   prefixes, extended registers, RIP-relative addressing). This would be
   a significant extension but follows the same architecture. Defer for now.

5. **JIT tail calls**: WASM tail call proposal is now supported in Chrome
   and Firefox. Using `return_call` for inter-block jumps within a JIT'd
   region would eliminate the br_table overhead. Monitor browser support.

6. **Benchmarking target**: What is the "good enough" performance bar?
   For CLI tools (CL.EXE compiling a small file): <5 seconds in-browser.
   For games: 30fps minimum. These require different optimization
   priorities.
