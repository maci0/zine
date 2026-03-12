# WASM Target: Running Win32 PE Binaries in the Browser

## Goal

Run unmodified 32-bit Windows PE executables entirely in the browser by combining:
- The existing Win32 API stub layer (no hardware/kernel emulation needed)
- An x86 software interpreter compiled to WASM via Zig's wasm32-wasi target
- An optional x86-to-WASM JIT (Tier 1) for hot code paths (future work)

This approach outperforms v86, qemu-wasm, and Boxedwine for our use case because
we skip both hardware emulation and kernel emulation — we stub at the Win32 API
level, which is what CheerpX does with Linux syscalls but one layer higher.

---

## Current Status

| Component | Status |
|-----------|--------|
| Platform abstraction (`platform/`) | ✅ Complete |
| WASM entry point (`wasm_main.zig`) | ✅ Complete |
| x86 interpreter core (`x86/`) | ✅ Complete (3799 lines) |
| PE loader + import thunking for WASM | ✅ Complete |
| TEB/PEB initialization for WASM | ✅ Complete |
| Win32 stub registration for WASM | ✅ Complete (31 DLLs) |
| Basic block caching | ❌ Not implemented |
| x87 FPU instructions | ⚠️ Partial (FNINIT, FNSTCW, FLDCW only) |
| SSE/SSE2 instructions | ❌ Not implemented |
| Browser JS host frontend | ❌ Not implemented (CLI via wasmtime only) |
| x86-to-WASM JIT (Tier 1) | ❌ Not implemented |

---

## Architecture Overview

### Current: WASI CLI (wasmtime)

```
┌─────────────────────────────────────────────────────┐
│  WASI Runtime (wasmtime)                            │
│  ┌───────────────────────────────────────────────┐  │
│  │  zine.wasm (Zig → wasm32-wasi)                │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │  PE Loader (module.zig, loader.zig)     │  │  │
│  │  │  - Parse PE headers                     │  │  │
│  │  │  - Map sections into combined buffer    │  │  │
│  │  │  - Apply base relocations               │  │  │
│  │  │  - Resolve imports → INT 0xFE thunks    │  │  │
│  │  └──────────────┬──────────────────────────┘  │  │
│  │  ┌──────────────▼──────────────────────────┐  │  │
│  │  │  x86 Software Interpreter               │  │  │
│  │  │  - Decode-and-dispatch loop             │  │  │
│  │  │  - Lazy EFLAGS                          │  │  │
│  │  │  - INT 0xFE thunk dispatch              │  │  │
│  │  └──────────────┬──────────────────────────┘  │  │
│  │  ┌──────────────▼──────────────────────────┐  │  │
│  │  │  Win32 API Stubs (31 DLLs)              │  │  │
│  │  │  kernel32, user32, gdi32, msvcrt, ...   │  │  │
│  │  │  (platform-agnostic via platform layer) │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### Target: Browser-Hosted (not yet implemented)

```
┌─────────────────────────────────────────────────────┐
│  Browser                                            │
│  ┌───────────────────────────────────────────────┐  │
│  │  JavaScript Host                              │  │
│  │  - WebAssembly.Module instantiation           │  │
│  │  - Canvas/WebGL for rendering                 │  │
│  │  - Keyboard/mouse event forwarding            │  │
│  │  - File system (IndexedDB / virtual FS)       │  │
│  │  - Audio (Web Audio API)                      │  │
│  │  - JIT module compiler (Tier 1, future)       │  │
│  └──────────────┬────────────────────────────────┘  │
│                 │ WASM imports/exports               │
│  ┌──────────────▼────────────────────────────────┐  │
│  │  zine.wasm (Zig → wasm32-wasi)                │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │  PE Loader + x86 Interpreter            │  │  │
│  │  │  (same core as WASI CLI mode)           │  │  │
│  │  └──────────────┬──────────────────────────┘  │  │
│  │  ┌──────────────▼──────────────────────────┐  │  │
│  │  │  Win32 API Stubs                        │  │  │
│  │  │  (file I/O → JS virtual FS)             │  │  │
│  │  │  (GUI → Canvas/DOM via JS imports)      │  │  │
│  │  │  (audio → Web Audio API via JS imports) │  │  │
│  │  │  (time → performance.now() via JS)      │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

The browser version reuses the same WASM binary but replaces WASI filesystem
access with JS-provided virtual FS, routes GUI output to Canvas/DOM, and
provides time/audio/input via JS host imports.

### Memory Layout (WASM Combined Buffer)

```
preferred_base (from PE OptionalHeader.ImageBase)
     │
     ▼
     ┌──────────────────────┐
     │ PE image (SizeOfImage)│ ← Copied from loaded PE; all sections preserved
     │ .text, .data, .rdata │
     │ Import Address Table │ ← Patched with thunk addresses (not host pointers)
     ├──────────────────────┤
     │ Stack (64 KB)        │ ← ESP starts near the top of this region
     ├──────────────────────┤
     │ Thunks (32 KB)       │ ← INT 0xFE stubs (CD FE + 4-byte ID)
     └──────────────────────┘
```

The `GuestMemory.base_addr` is set to the PE's preferred `ImageBase` so all
absolute addresses in guest x86 code resolve correctly. Thunks are placed
*beyond* the PE's `SizeOfImage` to avoid overwriting import tables or data
sections — an earlier design placed them inside `SizeOfImage`, which corrupted
the IAT with `0xCC` (INT3) bytes and caused out-of-bounds crashes.

---

## Implemented: x86 Interpreter (Tier 0)

### Overview

A software x86 CPU that decodes and executes instructions one at a time.
Written in Zig, compiled to wasm32-wasi. Total: **3799 lines** across 7 modules.

```
src/x86/
  cpu.zig          # CPU state struct (246 lines)
  decoder.zig      # Instruction decoder (1075 lines)
  execute.zig      # Instruction execution dispatch (1521 lines)
  flags.zig        # Lazy EFLAGS (292 lines)
  fpu.zig          # x87 FPU state (86 lines, stub only)
  memory.zig       # Guest memory access (137 lines)
  thunks.zig       # Import thunk table and dispatch (442 lines)
```

### CPU State

The `Cpu` struct holds: 8 GPRs (EAX-EDI), EIP, 6 segment registers (CS, DS,
ES, FS, GS, SS), lazy EFLAGS, FPU state placeholder, guest memory reference,
`fs_base` for TEB access, and a halt flag.

### Lazy Flags

Instead of computing all 6 status flags (CF, PF, AF, ZF, SF, OF) after every
ALU instruction (~30% overhead), the interpreter records the operation type,
result, and operands. Individual flags are computed on demand only when read.

### Implemented x86 Instructions

| Category | Instructions | Status |
|----------|-------------|--------|
| **Data movement** | MOV (all ModR/M variants, segment regs), LEA, MOVZX, MOVSX, XCHG, BSWAP, CBW/CWDE, CDQ/CWD | ✅ |
| **Stack** | PUSH/POP (reg, imm, mem, segment regs), PUSHFD/POPFD, LEAVE, SAHF/LAHF | ✅ |
| **Arithmetic** | ADD, SUB, ADC, SBB, INC, DEC, NEG, NOT, CMP, TEST | ✅ |
| **Multiply/Divide** | IMUL (2-operand, 3-operand), MUL, IDIV, DIV (via Group 3) | ✅ |
| **Logic** | AND, OR, XOR | ✅ |
| **Shifts/Rotates** | SHL, SHR, SAR, ROL, ROR, RCL, RCR (imm, CL, 1) | ✅ |
| **Bit operations** | BT, BTS, BTR, BTC, BSF, BSR | ✅ |
| **Control flow** | CALL (direct, indirect), RET, RET imm16, JMP (direct, indirect) | ✅ |
| **Branches** | Jcc (all 16 conditions), LOOP/LOOPE/LOOPNE, JECXZ | ✅ |
| **Conditional** | SETcc (all 16 conditions), CMOVcc (all 16 conditions) | ✅ |
| **String ops** | MOVSB/MOVSD, STOSB/STOSD, LODSB/LODSD, CMPSB/CMPSD, SCASB/SCASD | ✅ |
| **REP prefixes** | REP MOVSB/MOVSD, REP STOSB/STOSD, REPNE SCASB/SCASD, REPE CMPS | ✅ |
| **Flags** | CLC, STC, CLI, STI, CLD, STD | ✅ |
| **Misc** | NOP, INT 3, INT 0xFE (thunk trap), HLT | ✅ |
| **IMUL 3-operand** | IMUL r32, r/m32, imm (0x69, 0x6B) | ✅ |
| **FPU (x87)** | FLD, FST, FADD, FSUB, FMUL, FDIV, FCOM, FNSTSW, etc. | ⚠️ Partial (FNINIT, FNSTCW, FLDCW; others decoded but not executed) |
| **SSE/SSE2** | MOVSS, ADDSS, MULSS, CVTSI2SS, etc. | ❌ Not implemented |

### Import Thunking (INT 0xFE)

When the PE's IAT is resolved on WASM, each imported function gets a 6-byte
thunk in guest memory: `CD FE` (INT 0xFE) + 4-byte thunk ID. The interpreter's
INT 0xFE handler reads the thunk ID, dispatches to the registered Zig stub,
passes arguments from the guest stack, and adjusts ESP for stdcall cleanup.

On native targets (x86/x86_64), the interpreter uses a different mechanism:
it detects when EIP points to a host function address (outside guest memory)
and calls it directly with the correct calling convention and up to 16
arguments read from the guest stack.

### Segment Handling

Most Win32 code uses flat memory (CS=DS=ES=SS all base 0). FS points to the
TEB. The interpreter resolves FS-relative accesses by adding `cpu.fs_base`:

```zig
pub fn resolveSegmentAddress(self: *const Cpu, seg: Segment, offset: u32) u32 {
    return switch (seg) {
        .fs => self.fs_base +% offset,
        else => offset,
    };
}
```

---

## Implemented: Platform Abstraction

```
src/platform/
  interface.zig    # Comptime backend selection (wasm32 → wasm, else → native)
  native.zig       # Linux backend (POSIX mmap, signals, FS asm, /proc/self/maps)
  wasm.zig         # WASM backend (page_allocator, no-op stubs)
```

| API | Native | WASM |
|-----|--------|------|
| `mmap`/`munmap` | Linux syscalls | Zig page_allocator |
| `setupFS` | `arch_prctl` / `set_thread_area` | No-op (interpreter uses `cpu.fs_base`) |
| `spawnThread` | `std.Thread.spawn` | Stub (single-threaded) |
| `installSegfaultHandler` | `sigaction(SIGSEGV, SIGFPE)` | No-op |
| `mapNullPage` | `mmap` at address 0 | No-op |
| `exitProcess` | `std.process.exit` | `@trap()` |
| `timestamp` | `std.time.timestamp` | Returns 0 |

---

## Implemented: Build Target

```zig
// build.zig — WASM target (wasm32-wasi)
const wasm_lib = b.addExecutable(.{ ... });
wasm_lib.initial_memory = 256 * 1024 * 1024; // 256 MB initial
wasm_lib.max_memory = 2 * 1024 * 1024 * 1024; // 2 GB max
```

Usage with wasmtime:
```bash
wasmtime --dir=. zig-out/bin/zine.wasm -- path/to/program.exe
```

---

## Known Limitations

### Architecture Limitations

| Limitation | Impact | Workaround |
|-----------|--------|------------|
| **Partial x87 FPU** | Only FNINIT, FNSTCW, and FLDCW are executed; other FPU instructions are decoded (correct length skipping) but not executed. Floating-point math (`float`/`double`) will produce incorrect results. This blocks most games and scientific applications. | Implement FLD/FST/FADD/FSUB/FMUL/FDIV/FCOM/FNSTSW — the ~15 instructions that cover 95% of MSVC6 FPU usage. |
| **No SSE/SSE2** | Modern MSVC builds using SSE intrinsics or `/arch:SSE2` will fail. Not a problem for MSVC6 targets since SSE is disabled in the build. | Implement basic SSE scalar ops: MOVSS, ADDSS, SUBSS, MULSS, DIVSS, CVTSI2SS, CVTTSS2SI. |
| **64 KB stack** | The WASM combined buffer allocates only 64 KB for the guest stack. Deeply recursive programs or programs with large stack frames will overflow silently. | Increase `STACK_SIZE` in `wasm_main.zig` (at the cost of increased memory usage). |
| **32 KB thunk space** | Limited to ~5461 imported functions (6 bytes per thunk). Sufficient for current stub count but could be exceeded by applications importing many DLLs. | Increase `THUNK_RESERVE` in `wasm_main.zig`. |
| **No block caching** | The interpreter decodes every instruction from raw bytes on every execution. Hot loops re-decode the same instructions thousands of times. | Implement basic block cache keyed by EIP — the plan's `DecodedBlock` cache. |

### Platform Limitations

| Limitation | Impact | Workaround |
|-----------|--------|------------|
| **Single-threaded** | `CreateThread` and other threading APIs are stubs. Multi-threaded applications will run on a single thread. | Could use Web Workers + SharedArrayBuffer in a browser host (significant complexity). |
| **No GUI rendering** | The native web UI (WebSocket server on port 1995) doesn't work under WASM. GUI applications will load but not display. | Implement direct DOM/Canvas rendering via JS imports for a browser-hosted frontend. |
| **No file system persistence** | Files are read from the WASI preopened directories. No virtual filesystem or IndexedDB persistence. | For browser deployment, implement a virtual FS backed by IndexedDB or preloaded archives. |
| **Timestamp always 0** | `platform.timestamp()` returns 0 on WASM. Time-dependent code will behave incorrectly. | Import `performance.now()` via a WASI extension or JS host function. |
| **No networking** | Winsock stubs (`wsock32`, `ws2_32`) are minimal. No real network I/O. | Could proxy via WebSocket to a backend relay, but adds significant complexity. |
| **No audio** | DirectSound and WinMM stubs don't produce audio on WASM. | Implement Web Audio API bridge in the browser host. |
| **Memory ceiling: 2 GB** | WASM linear memory max is set to 2 GB. The PE image, stack, thunks, Zig runtime, and heap must all fit. Large applications may run out of memory. | WASM specification supports up to 4 GB; increase `max_memory` if needed (may cause issues on 32-bit browsers). |

### Interpreter Performance

| Concern | Details |
|---------|---------|
| **Speed** | Tier 0 interpreter is estimated ~50-100x slower than native. Usable for short-lived tools (compilers, CLI utilities) but too slow for real-time applications (games). |
| **No JIT** | Without Tier 1 JIT compilation, hot loops cannot be accelerated. A JIT would bring performance to ~5-20x slower than native. |
| **Decode overhead** | Without block caching, every instruction is decoded from raw bytes every time. This is the single largest performance bottleneck. |

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

**Tasks:**
- [x] Inventory all POSIX syscalls (mmap, munmap, sigaction, arch_prctl, getpid, /proc/self/maps)
- [x] Inventory all inline asm (FS segment setup in teb.zig, kernel32/misc.zig)
- [x] Create `Platform` interface with methods for: memory, threading, process, stack bounds, TEB, signals
- [x] Move current implementations into `platform/native.zig`
- [x] Create `platform/wasm.zig` with stubs (JS extern imports deferred to Phase 4)
- [x] Switch stubs to use `Platform` instead of direct std.posix calls
- [x] Verify `build.zig` builds all three targets (x86, x86_64, wasm32)

### Phase 2: x86 interpreter core ✅ COMPLETE

```
src/
  x86/
    cpu.zig          # CPU state struct
    decoder.zig      # Instruction decoder (prefixes, ModR/M, SIB)
    execute.zig      # Instruction execution (dispatch table)
    flags.zig        # Lazy flags implementation
    memory.zig       # Guest memory access (bounds-checked)
    fpu.zig          # x87 FPU state (stub — execution handlers not yet implemented)
    thunks.zig       # Import thunk table and dispatch
```

**Tasks:**
- [x] Define CPU state struct with all registers
- [x] Implement x86 instruction decoder (ModR/M, SIB, prefixes, all
      addressing modes)
- [x] Implement Phase 1 instructions (MOV, PUSH, POP, CALL, RET, JMP,
      Jcc, CMP, TEST, ADD, SUB, AND, OR, XOR, LEA, NOP)
- [x] Implement lazy flags
- [x] Implement guest memory model (base offset into WASM linear memory,
      bounds checking)
- [x] Implement thunk mechanism for import calls (INT 0xFE trap)
- [ ] Implement basic block decoding and caching
- [x] Wire up PE loader to use interpreter instead of native execution
      when targeting WASM
- [x] Implement Phase 2 string ops (MOVSB/MOVSD, STOSB/STOSD, LODSB/LODSD,
      CMPSB/CMPSD, SCASB/SCASD with REP/REPNE prefixes)
- [x] Implement Phase 3 arithmetic (IMUL, MUL, IDIV, DIV, SHL, SHR, SAR,
      ROL, ROR, NEG, NOT, INC, DEC, CDQ, CBW, CWDE, XCHG, BSWAP,
      BT, BTS, BTR, BTC, BSF, BSR, SETcc, CMOVcc)
- [x] Implement WASM-specific combined buffer memory layout
      (`[PE image] [stack 64KB] [thunks 32KB]`)
- [x] Implement native call dispatch for `--interpret` mode on x86/x86_64

**Testing:**
- Unit tests exist for `flags.zig`, `memory.zig`, `fpu.zig`, `cpu.zig`,
  `decoder.zig`, `execute.zig`, `thunks.zig` (run via `zig build test`)
- Integration testing via `test_msvc_cli.sh` running MSVC tools under wasmtime

### Phase 3: x87 FPU instructions ⚠️ PARTIAL

The `fpu.zig` module defines the FPU state struct (ST(0)–ST(7) register
stack, control/status words). FNINIT, FNSTCW, and FLDCW are implemented;
other FPU opcodes are decoded for correct length skipping but not executed.

**Tasks:**
- [x] Implement FNINIT (reset FPU state)
- [x] Implement FNSTCW (store FPU control word to memory)
- [x] Implement FLDCW (load FPU control word from memory)
- [x] Decode x87 opcodes in `execute.zig` (D8-DF opcode group — correct length skipping)
- [ ] Implement FLD, FST, FSTP (load/store from/to memory and ST registers)
- [ ] Implement FADD, FSUB, FMUL, FDIV (arithmetic on ST stack)
- [ ] Implement FCOM, FCOMP, FCOMPP (compare, set FPU status word)
- [ ] Implement FNSTSW AX (store FPU status word to AX — used with SAHF
      for float comparisons)
- [ ] Implement FNSTCW, FLDCW (control word save/restore — rounding mode,
      precision)
- [ ] Implement FXCH (swap ST registers)
- [ ] Implement FILD, FISTP (integer ↔ float load/store)
- [ ] Implement FCHS, FABS (sign change, absolute value)
- [ ] Implement FLDZ, FLD1, FLDPI (load constants)
- [ ] Implement FINIT/FNINIT (reset FPU state)
- [ ] Decode x87 opcodes in `decoder.zig` (D8-DF opcode group with ModR/M)
- [ ] Add FPU instruction dispatch in `execute.zig`
- [ ] Unit tests for FPU stack operations and arithmetic

### Phase 4: Stub backend for WASM / Browser frontend ⬚ NOT STARTED

**Tasks:**
- [ ] Implement `platform/wasm.zig` JS host bindings:
  - File I/O → JS virtual filesystem (files pre-loaded into memory or
    fetched via HTTP)
  - Memory allocation → bump allocator in WASM linear memory
  - Console output → JS `console.log` / DOM text node
  - Time → `performance.now()` via JS import
  - Environment variables → JS-provided map
- [ ] Implement JS host (`index.html` + `host.js`):
  - Load zine.wasm via `WebAssembly.instantiate()`
  - Provide imported functions (file read, console write, time)
  - Load PE binary (via fetch or file input)
  - Pass PE bytes into WASM, trigger execution
  - Render console output in a terminal element (xterm.js)
- [ ] Wire up GUI stubs to Canvas/DOM instead of WebSocket server

### Phase 5: Testing and hardening ⬚ IN PROGRESS

**Tasks:**
- [x] Run MSVC CLI tools (CL.EXE, LINK.EXE) through the interpreter
- [ ] Profile hot spots — which instructions dominate execution time
- [x] Fix instruction decode/execute bugs found by real binaries
- [x] Add Phase 2-3 instructions as needed (string ops, multiply/divide,
      shifts, bit operations)
- [ ] Optimize the interpreter hot loop (minimize branch mispredictions,
      consider threaded dispatch)
- [ ] Create a demo page that compiles a .c file using CL.EXE in-browser

### Phase 6: JIT compiler (optional) ⚠️ IN PROGRESS

A Tier 1 JIT compiler that translates hot x86 basic blocks into WASM modules
at runtime, achieving ~5-20x native performance instead of ~50-100x.

**Tasks:**
- [ ] Implement `WasmBuilder` — WASM binary format encoder in Zig
- [ ] Implement basic block → WASM translation for common instructions
- [ ] Add execution counting and hot-block detection
- [ ] JS-side: accept WASM bytes, compile module, register entry point
- [ ] Implement dispatch: check JIT cache before interpreting
- [ ] Implement JIT invalidation on code page writes
- [ ] Profile and optimize: which blocks benefit most from JIT
- [ ] Implement region compilation (multiple connected blocks in one
      WASM module) to reduce inter-block transition overhead

### Phase 7: Optimization (ongoing) ⬚ NOT STARTED

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

## Build & Run

```bash
# Build for WASM
zig build -Dtarget=wasm32

# Run with wasmtime (with filesystem access)
wasmtime --dir=. zig-out/bin/zine.wasm -- drive_c/path/to/program.exe

# Build and run natively (for comparison)
zig build
./zig-out/bin/zine drive_c/path/to/program.exe

# Run the interpreter on native (for debugging)
./zig-out/bin/zine --interpret drive_c/path/to/program.exe
```

---

## Open Questions

1. **FPU priority**: Which applications are blocked on FPU support? If only
   games need it, it can be deferred. If MSVC CRT initialization uses FPU
   (e.g. `_fltused`), it's more urgent.

2. **Memory budget**: With 2 GB max WASM memory, how much is available for
   the guest after Zig runtime overhead? Need profiling to determine if
   `max_memory` should be increased.

3. **Threading model**: Web Workers + SharedArrayBuffer is the only path to
   multi-threaded guest execution in the browser. Is this needed for any
   target applications?

4. **File system strategy**: For browser deployment, should files be
   pre-bundled into the WASM binary (simplest), fetched on demand via HTTP
   (lazy), or uploaded via drag-and-drop?
