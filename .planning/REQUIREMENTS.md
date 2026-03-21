# v2: Full Test Coverage — Requirements

## Goal
Every test in `tests/test_msvc_cli.sh` passes across **all** execution permutations.

## Execution Permutation Matrix

### Native Linux (x86 binary)

| ID | Execution | Stubs | Flag |
|----|-----------|-------|------|
| P01 | Direct | Embedded | `--native` |
| P02 | Interpreted | Embedded | `--interpret` |
| P03 | JIT | Embedded | `--jit` |
| P04 | Direct | External DLL | `--external` |

### Native Linux (x86_64 binary)

| ID | Execution | Stubs | Flag |
|----|-----------|-------|------|
| P05 | Direct (compat) | Embedded | `--native64` |
| P06 | Interpreted | Embedded | `--interpret64` (new) |
| P07 | Direct | External DLL | `--external64` (new) |

### WASM32 (via external runtime)

| ID | Execution | Runtime | Flag |
|----|-----------|---------|------|
| P08 | Interpreted | wasmtime | `--wasmtime` |
| P09 | Interpreted | wasmer | `--wasmer` |
| P10 | JIT | wasmtime | `--jit-wasmtime` (new) |
| P11 | JIT | wasmer | `--jit-wasmer` (new) |

### WASM64 (via external runtime)

| ID | Execution | Runtime | Flag |
|----|-----------|---------|------|
| P12 | Interpreted | wasmtime | `--wasm64-wasmtime` (new) |
| P13 | Interpreted | wasmer | `--wasm64-wasmer` (new) |
| P14 | JIT | wasmtime | `--jit-wasm64-wasmtime` (new) |
| P15 | JIT | wasmer | `--jit-wasm64-wasmer` (new) |

### zine-host (wasmer embedded host)

| ID | Host arch | WASM target | Flag |
|----|-----------|-------------|------|
| P16 | x86 | wasm32 | `--zine-host` (new) |
| P17 | x86 | wasm64 | `--zine-host-wasm64` (new) |
| P18 | x86_64 | wasm32 | `--zine-host64` (new) |
| P19 | x86_64 | wasm64 | `--zine-host64-wasm64` (new) |

**Total: 19 permutations**

## Test Sections (~25 tests)

| Section | Tests | Description |
|---------|-------|-------------|
| Startup | 20 | Tool help/usage output and exit codes |
| CL compile | 1 | Compile C to .obj |
| CL preprocess | 1 | /EP macro expansion |
| CL link | 1 | Compile + link to .exe |
| CL syntax | 1 | Error reporting on bad code |
| CL multi | 1 | Multi-file compile+link |
| LINK | 1 | Link .obj to .exe |
| DUMPBIN | 4 | Headers, exports, disasm, symbols |
| LIB | 2 | Create .lib, list members |
| RC | 1 | Compile .rc to .res |
| CVTRES | 1 | Convert .res to .coff |
| UNDNAME | 1 | C++ name demangling |
| UUIDGEN | 1 | UUID generation |
| E2E | 5 | Full pipeline: compile→link→dump→run |

## Requirements

### Baseline (fix native x86 failures first)

- **TEST-01**: RC.EXE produces .res in native mode
- **TEST-02**: CVTRES.EXE converts .res to .coff in native mode
- **TEST-03**: E2E CL /c works with include paths in native mode
- **TEST-04**: All 20 startup tests pass in native mode

### Per-Permutation Green (19 permutations)

- **TEST-P01** through **TEST-P19**: All tests pass in each permutation

### Infrastructure

- **TEST-INF-01**: `--all` flag includes all 19 permutations
- **TEST-INF-02**: CI-friendly output (machine-parseable pass/fail summary)
- **TEST-INF-03**: Test script returns 0 only when ALL tests pass

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| TEST-01 | TBD | 🔲 |
| TEST-02 | TBD | 🔲 |
| TEST-03 | TBD | 🔲 |
| TEST-04 | TBD | 🔲 |
| TEST-P01 | TBD | 🔲 |
| TEST-P02 | TBD | 🔲 |
| TEST-P03 | TBD | 🔲 |
| TEST-P04 | TBD | 🔲 |
| TEST-P05 | TBD | 🔲 |
| TEST-P06 | TBD | 🔲 |
| TEST-P07 | TBD | 🔲 |
| TEST-P08 | TBD | 🔲 |
| TEST-P09 | TBD | 🔲 |
| TEST-P10 | TBD | 🔲 |
| TEST-P11 | TBD | 🔲 |
| TEST-P12 | TBD | 🔲 |
| TEST-P13 | TBD | 🔲 |
| TEST-P14 | TBD | 🔲 |
| TEST-P15 | TBD | 🔲 |
| TEST-P16 | TBD | 🔲 |
| TEST-P17 | TBD | 🔲 |
| TEST-P18 | TBD | 🔲 |
| TEST-P19 | TBD | 🔲 |
| TEST-INF-01 | TBD | 🔲 |
| TEST-INF-02 | TBD | 🔲 |
| TEST-INF-03 | TBD | 🔲 |
