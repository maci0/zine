# WASM Target: Running Win32 PE Binaries in the Browser

## Goal

Run unmodified 32-bit Windows PE executables entirely in the browser by combining:
- The existing Win32 API stub layer (no hardware/kernel emulation needed)
- An x86 software interpreter compiled to WASM via Zig's wasm32-wasi target
- An x86-to-WASM JIT compiler for hot code paths

This approach outperforms v86, qemu-wasm, and Boxedwine for our use case because
we skip both hardware emulation and kernel emulation — we stub at the Win32 API
level, which is what CheerpX does with Linux syscalls but one layer higher.

---

## Current Status

| Component | Status |
|-----------|--------|
| Platform abstraction (`platform/`) | ✅ Complete |
| WASM entry point (`wasm_main.zig`) | ✅ Complete |
| x86 interpreter core (`x86/`) | ✅ Complete |
| PE loader + import thunking for WASM | ✅ Complete |
| BSS zero-initialization | ✅ Complete |
| .rsrc write protection | ✅ Complete |
| In-process child PE execution (`_spawnvp`) | ✅ Complete |
| TEB/PEB initialization for WASM | ✅ Complete |
| Win32 stub registration for WASM | ✅ Complete (36+ DLLs) |
| x87 FPU instructions | ⚠️ Partial |
| SSE/SSE2 instructions | ⚠️ Partial (`src/x86/sse.zig`) |
| x86-to-WASM JIT compiler | ✅ Working (`src/jit/`; blocks execute end-to-end via a host runtime) |
| JIT host execution (zine-host) | ✅ Working (`--jit` via `zine-host`; SEH/nested-SEH/registry tests green) |
| JIT host execution (browser) | ⬚ Not implemented |
| Browser JS host frontend | ⬚ Not implemented |
| Basic block caching | ⚠️ Partial ([`JIT.md`](JIT.md#jit-block-caching-strategy-partial): interpreter decode cache 1024-entry hash-indexed; JIT block caches fixed 4096-entry with no trace linking) |

### Test Results

Current pass/fail counts per mode are tracked in [`STATUS.md`](STATUS.md)
(last verified 2026-08-08: native 158/0, native64 158/0, wasmtime 128/0).
The historical baseline at the time this plan was written:

```
Mode          Pass  Total  Notes
──────────────────────────────────────────────────
native         42    42    Full MSVC 6.0 toolchain
interpret      42    42    x86 software interpreter
wasmtime       23    36    WASI CLI (wasmtime 29+)
wasmer         23    36    WASI CLI (wasmer 7+)
```

Passing WASM tools: LINK, CVPACK, CVTRES, BSCMAKE, MIDL, MC, PREP, PROFILE,
PLIST, REBASE, VCSPAWN, UNDNAME, BIND, MAKEHM, UUIDGEN, UNDNAME-demangle,
DUMPBIN-exports.

---

## Architecture Overview

### WASI CLI (wasmtime / wasmer)

```
┌─────────────────────────────────────────────────────┐
│  WASI Runtime (wasmtime / wasmer)                   │
│  ┌───────────────────────────────────────────────┐  │
│  │  zine.wasm (Zig → wasm32-wasi)                │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │  PE Loader (module.zig, loader.zig)     │  │  │
│  │  │  - Parse PE headers                     │  │  │
│  │  │  - Map sections into combined buffer    │  │  │
│  │  │  - Zero-fill BSS regions                │  │  │
│  │  │  - Apply base relocations               │  │  │
│  │  │  - Resolve imports → INT 0xFE thunks    │  │  │
│  │  │  - Protect .rsrc from buffer overflows  │  │  │
│  │  └──────────────┬──────────────────────────┘  │  │
│  │  ┌──────────────▼──────────────────────────┐  │  │
│  │  │  x86 Software Interpreter               │  │  │
│  │  │  - Decode-and-dispatch loop             │  │  │
│  │  │  - Lazy EFLAGS                          │  │  │
│  │  │  - INT 0xFE thunk dispatch              │  │  │
│  │  │  - _EH_prolog emulation                 │  │  │
│  │  │  - In-process child PE execution        │  │  │
│  │  └──────────────┬──────────────────────────┘  │  │
│  │  ┌──────────────▼──────────────────────────┐  │  │
│  │  │  Win32 API Stubs (36+ DLLs)             │  │  │
│  │  │  kernel32, user32, gdi32, msvcrt, ...   │  │  │
│  │  │  (platform-agnostic via platform layer) │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### JIT Pipeline (executing via zine-host)

```
x86 PE  →  [zine JIT compiler]  →  WASM module bytes
                                         │
           ┌─────────────────────────────▼─────────────────┐
           │  Host Runtime                                  │
           │  browser: WebAssembly.instantiate()            │
           │  zine-host: wasmer C API                       │
           │  ┌──────────────────────────────────────────┐  │
           │  │  Compiled WASM block                     │  │
           │  │  - Imports shared linear memory           │  │
           │  │  - Reads CPU state from JitCpuState       │  │
           │  │  - Executes straight-line x86 ops         │  │
           │  │  - Writes CPU state back                  │  │
           │  │  - Returns to interpreter for branches    │  │
           │  └──────────────────────────────────────────┘  │
           └────────────────────────────────────────────────┘
```

The JIT compiler (`src/jit/`) translates x86 basic blocks into standalone
WASM modules with:
- Memory import from `"env" "memory"` (shared linear memory)
- Exported `"run"` function (void → void)
- State-via-memory prologue/epilogue using `JitCpuState` (64-byte struct)
- `mem_base` local for guest VA → WASM linear address translation

See [JIT usage](JIT.md#usage) for compile-only mode and the
`-Djit_host=true` build option required for host execution.

### Target: Browser-Hosted

```
┌─────────────────────────────────────────────────────┐
│  Browser                                            │
│  ┌───────────────────────────────────────────────┐  │
│  │  JavaScript Host                              │  │
│  │  - WebAssembly.Module instantiation           │  │
│  │  - JIT: compile + instantiate x86→WASM blocks │  │
│  │  - Canvas/WebGL for rendering                 │  │
│  │  - Keyboard/mouse event forwarding            │  │
│  │  - File system (IndexedDB / virtual FS)       │  │
│  │  - Audio (Web Audio API)                      │  │
│  └──────────────┬────────────────────────────────┘  │
│                 │ WASM imports/exports               │
│  ┌──────────────▼────────────────────────────────┐  │
│  │  zine.wasm (same binary as CLI)               │  │
│  │  - PE Loader + x86 Interpreter + JIT          │  │
│  │  - Win32 API Stubs                            │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### Memory Layout (WASM Combined Buffer)

```
base_addr (PE ImageBase or buffer host address for child PEs)
     │
     ▼
     ┌──────────────────────┐
     │ PE image (SizeOfImage)│ ← Sections copied; BSS zeroed; .rsrc write-protected
     │ .text, .data, .rdata │
     │ Import Address Table │ ← Patched with INT 0xFE thunk addresses
     ├──────────────────────┤
     │ Stack (64 KB)        │ ← ESP starts near the top
     ├──────────────────────┤
      │ Thunks (32 KB)       │ ← CD FE + 4-byte thunk ID stubs
      ├──────────────────────┤
      │ Heap (512 MB)        │ ← Guest heap for malloc/VirtualAlloc/HeapAlloc
      └──────────────────────┘
```

Child PEs (loaded by `_spawnvp`) get their own combined buffer. Relocatable PEs
use `base_addr = @intFromPtr(child_buf.ptr)`; fixed-base PEs use the PE's preferred
`ImageBase`, which the interpreter translates.

---

## In-Process Child PE Execution

MSVC tools like DUMPBIN, LIB, and EDITBIN are thin wrappers that call
`_spawnvp("link.exe", argv)`. On native, this spawns a child zine process.
On WASM, `_spawnvp` loads the child PE in-process:

1. Resolve PE path (Win32 → POSIX conversion)
2. Translate parent argv from guest VAs to host strings
3. Allocate a fresh combined buffer for the child
4. Load PE, resolve imports, set up thunks (same as main PE)
5. Copy argv strings into child's guest heap
6. Run interpreter with a new CPU instance
7. `ExitProcess`/`exit()` in child mode sets `cpu.halted` + stores exit code
8. Restore parent state (guest_memory, argv, thunks, command line cache)

This enables DUMPBIN /EXPORTS to work on WASM (spawns LINK.EXE → runs
the `/dump /exports` command → produces output → returns exit code).

---

## WASI Runtime Compatibility

| Runtime | Version | Exit Codes | Filesystem | Status |
|---------|---------|-----------|------------|--------|
| **wasmtime** | 29+ | 0-125 only; ≥126 mapped to 1 | `--dir=/` preopens host FS | Primary test target |
| **wasmer** | 7+ | 0-255 faithfully | `--volume HOST:GUEST` mounts | Fully working |

### Exit Code Behavior

Win32 `ExitProcess(N)` truncates to `u8` (`N & 0xFF`) for WASI `proc_exit`.
Runtimes handle codes ≥126 differently:

```
ExitProcess(1000)  →  1000 & 0xFF = 232
  wasmtime:  proc_exit(232) → ERROR → host sees rc=1
  wasmer:    proc_exit(232) → host sees rc=232
```

The test suite auto-adjusts expected codes per runtime via `WASM_EXIT_MAX`.

### Running

```bash
# Build
zig build -Darch=wasm32

# wasmtime
wasmtime --dir=. zig-out/bin/zine.wasm32.wasm -- path/to/program.exe

# wasmtime with JIT compile-only validation
wasmtime --dir=. zig-out/bin/zine.wasm32.wasm --jit path/to/program.exe

# wasmer
wasmer run --volume "$(pwd):$(pwd)" --volume . zig-out/bin/zine.wasm32.wasm -- \
    "$(pwd)/path/to/program.exe"

# Build with JIT host imports (for zine-host or browser)
zig build -Darch=wasm32 -Djit_host=true

# Build zine-host native wrapper
zig build -Dhost
```

---

## Build Targets

| Command | Output | Notes |
|---------|--------|-------|
| `zig build` | `zig-out/bin/zine.x86` | Native x86 Linux binary |
| `zig build -Darch=wasm32` | `zig-out/bin/zine.wasm32.wasm` | WASI binary, works with wasmtime/wasmer |
| `zig build -Darch=wasm32 -Djit_host=true` | `zig-out/bin/zine.wasm32.wasm` | WASI + JIT host extern imports (same path — rebuild before switching suites) |
| `zig build -Dhost=true` | `zig-out/bin/zine-host` | Native wasmer wrapper (WASI + JIT imports) |
| `zig build test` | — | Unit tests (host architecture) |

The `--jit` runtime flag works with the standard WASM build (compile-only mode).
The `-Djit_host=true` build flag is only needed for actual JIT block execution,
which requires a host providing `jit_compile`/`jit_call` imports (zine-host or
a browser runtime).

---

## Known Limitations

### Architecture

| Limitation | Impact | Status |
|-----------|--------|--------|
| **CL.EXE child process** | CL.EXE spawns C1.DLL/C2.DLL as child processes | ✅ Fixed — CL boots C1.DLL, spawns LINK.EXE (see `CLI_STATUS.md`); only the zine-host wrapper still has a spawn gap |
| **Child PE argv** | DUMPBIN/LIB/EDITBIN spawn LINK.EXE via `_spawnvp`; child needs argv | ✅ Fixed — in-process child execution passes argv; suite green on wasmtime |
| **Partial x87 FPU** | FNINIT/FNSTCW/FLDCW + many ops decoded but not all executed | Blocks float-heavy apps |
| **Partial SSE** | Basic SSE support in `sse.zig` | Sufficient for MSVC6 targets |
| **64 KB stack** | Deeply recursive programs may overflow | Increase `STACK_SIZE` |

(Block caching is implemented — see `decode_cache.zig` and the status table above.)

### Platform

| Limitation | Impact |
|-----------|--------|
| **Single-threaded** | `CreateThread` is a stub |
| **No GUI rendering** | GUI apps load but don't display on WASM |
| **No file persistence** | WASI preopened dirs only |
| **No networking** | Winsock stubs are minimal |
| **No audio** | DirectSound/WinMM stubs don't produce audio |
| **Memory ceiling: 2 GB** | WASM linear memory limit |

### Interpreter Performance

| Metric | Value |
|--------|-------|
| Sieve benchmark (WASM/wasmtime) | ~330 iter/s |
| Sieve benchmark (WASM/wasmer) | ~425 iter/s |
| Sieve benchmark (native interpret) | ~441 iter/s |
| Sieve benchmark (native direct) | ~150K iter/s |
| Estimated overhead | ~300-450x vs native |

---

## Implementation Plan

### Phase 1: Platform abstraction ✅ COMPLETE
### Phase 2: x86 interpreter core ✅ COMPLETE
### Phase 3: x87 FPU instructions ⚠️ PARTIAL
### Phase 4: Browser frontend ⬚ NOT STARTED

### Phase 5: Testing and hardening ⚠️ IN PROGRESS

- [x] Run MSVC CLI tools through interpreter (counts tracked in [`STATUS.md`](STATUS.md))
- [x] Run MSVC CLI tools through WASM (counts tracked in [`STATUS.md`](STATUS.md))
- [x] Fix BSS zero-initialization for WASM
- [x] Fix .rsrc write protection
- [x] Implement in-process _spawnvp for child PE execution
- [x] Fix _EH_prolog emulation in interpreter mode
- [x] Fix DLL search path (host PATH fallback)
- [x] Fix POSIX path heuristic for MSVC option args
- [x] Fix child PE argv passing (CRT __getmainargs cache)
- [x] Fix CL.EXE child process execution (C1.DLL/C2.DLL)
- [x] Profile interpreter hot spots (`--profile` / `ZINE_PROFILE`, `src/profiler.zig`)
- [x] Create browser demo page (`src/gui/index.html` + `app.js`, embedded in native builds and served over HTTP/WebSocket by the zine process)

### Phase 6: JIT compiler ⚠️ IN PROGRESS

- [x] WASM binary emitter (`emitter.zig`)
- [x] x86 instruction translation (`translate.zig`, `compiler.zig`)
- [x] JitCpuState struct (state-via-memory transfer)
- [x] Memory import + function export in generated modules
- [x] Prologue/epilogue (load/store registers + EFLAGS)
- [x] mem_base translation (guest VA → WASM linear address)
- [x] Control flow detection (stop at branches, let interpreter handle)
- [x] JitHost interface + WASM guest implementation
- [x] zine-host skeleton (wasmer C API)
- [x] Benchmark mode 8 (zine-host + JIT)
- [x] Implement zine-host wasmer C API integration (WASI + JIT host in `src/host_main.zig`; end-to-end via `zine-host --jit`)
- [ ] Browser JS JIT glue (WebAssembly.instantiate for compiled blocks)
- [x] Hot block detection and execution counting (per-block counters, 4096-entry ring; live milestone logs + end-of-run top-8 report)
- [x] JIT invalidation on code page writes (SMC hook: `stub_common.smc_invalidate_cache` → `flushJitCache`)

### Phase 7: Optimization ⬚ NOT STARTED
