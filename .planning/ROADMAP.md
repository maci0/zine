# Zine — Roadmap

## ✅ v1: Win32 Compatibility (shipped 2026-03-22)

15 phases | 35 requirements | 25 satisfied, 10 tech debt
See [milestones/v1-ROADMAP.md](milestones/v1-ROADMAP.md) for full details.

---

## v2: Full Test Coverage

**Goal:** Every test in `test_msvc_cli.sh` passes in all **19** execution permutations.

**Permutation axes:** Arch (x86, x86_64, wasm32, wasm64) × Execution (direct, interpreted, JIT) × Runtime (Linux, wasmtime, wasmer, zine-host) × Stubs (embedded, external DLL)

| # | Phase | Goal | Requirements |
|---|-------|------|--------------|
| 16 | Baseline Fix | Fix native x86 failures (RC, CVTRES, E2E) | TEST-01..04, P01 |
| 17 | Native x86 Modes | Interpreted + JIT + external all green | P02, P03, P04 |
| 18 | Native x86_64 Modes | Direct + interpreted + external all green | P05, P06, P07 |
| 19 | WASM32 Interpreted | wasmtime + wasmer green | P08, P09 |
| 20 | WASM32 JIT | Add flags, wasmtime + wasmer green | P10, P11 |
| 21 | WASM64 Interpreted | Add wasm64 build + flags, both runtimes green | P12, P13 |
| 22 | WASM64 JIT | Add flags, both runtimes green | P14, P15 |
| 23 | zine-host Modes | All 4 zine-host combos (host arch × wasm arch) green | P16, P17, P18, P19 |
| 24 | Test Infra Polish | `--all` = 19 modes, CI output | INF-01..03 |

**9 phases** | **26 requirements** | Numbering continues from v1

---

### Phase 16: Baseline Fix
**Goal:** Fix all native x86 test failures — RC.EXE, CVTRES, E2E.

**Requirements:** TEST-01, TEST-02, TEST-03, TEST-04, TEST-P01

**Success:** `test_msvc_cli.sh --native` → 0 failures

---

### Phase 17: Native x86 Modes
**Goal:** Interpreted, JIT, and external stubs all pass on x86.

**Requirements:** TEST-P02, TEST-P03, TEST-P04

**Success:** `--interpret`, `--jit`, `--external` → 0 failures each

---

### Phase 18: Native x86_64 Modes
**Goal:** Direct compat, interpreted, and external stubs all pass on x86_64.

**Requirements:** TEST-P05, TEST-P06, TEST-P07

**Notes:** `--interpret64` requires fixing 64-bit pointer handling in the interpreter.

**Success:** `--native64`, `--interpret64`, `--external64` → 0 failures each

---

### Phase 19: WASM32 Interpreted
**Goal:** All tests pass on WASM32 with both wasmtime and wasmer.

**Requirements:** TEST-P08, TEST-P09

**Success:** `--wasmtime`, `--wasmer` → 0 failures each

---

### Phase 20: WASM32 JIT
**Goal:** Add `--jit-wasmtime`/`--jit-wasmer` flags. All tests pass.

**Requirements:** TEST-P10, TEST-P11

**Success:** Both modes → 0 failures each

---

### Phase 21: WASM64 Interpreted
**Goal:** Add wasm64 build + `--wasm64-wasmtime`/`--wasm64-wasmer` flags. All pass.

**Requirements:** TEST-P12, TEST-P13

**Success:** `zig build -Darch=wasm64` succeeds, both modes → 0 failures

---

### Phase 22: WASM64 JIT
**Goal:** Add `--jit-wasm64-wasmtime`/`--jit-wasm64-wasmer` flags. All pass.

**Requirements:** TEST-P14, TEST-P15

**Success:** Both modes → 0 failures

---

### Phase 23: zine-host Modes
**Goal:** Add `--zine-host`, `--zine-host-wasm64`, `--zine-host64`, `--zine-host64-wasm64` flags. Build zine-host for x86 + x86_64. All pass.

**Requirements:** TEST-P16, TEST-P17, TEST-P18, TEST-P19

**Success:** All 4 zine-host modes → 0 failures each

---

### Phase 24: Test Infra Polish
**Goal:** `--all` covers all 19 permutations, CI-friendly summary output.

**Requirements:** TEST-INF-01, TEST-INF-02, TEST-INF-03

**Success:** `test_msvc_cli.sh --all` runs 19 modes, outputs `TOTAL: N/N passed`, exits 0
