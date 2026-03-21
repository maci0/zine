# Zine — State

## Project Status

See: .planning/PROJECT.md (updated 2026-03-22)

**Core value:** Run Win98/Win2K era Windows applications and games faithfully on Linux and in the browser
**Current focus:** Phase 18 — Native x86_64 Modes

## Current Milestone

**v2: Full Test Coverage**
- 9 phases (16-24) | 26 requirements
- Status: In progress — 3 modes green

## Phase Progress

| # | Phase | Status |
|---|-------|--------|
| 16 | Baseline Fix | ✅ Complete (42/42) |
| 17 | Native x86 Modes | ✅ Interpret 42/42, JIT 42/42 — external 0/42 (UCRT) |
| 18 | Native x86_64 Modes | 🔲 26/42 (CL compile C1063) |
| 19 | WASM32 Interpreted | 🔲 24/42 (CL arg parsing) |
| 20 | WASM32 JIT | 🔲 Not tested |
| 21 | WASM64 Interpreted | 🔲 Not tested |
| 22 | WASM64 JIT | 🔲 Not tested |
| 23 | zine-host Modes | 🔲 Not tested |
| 24 | Test Infra Polish | 🔲 Not started |

## Key Decisions Log

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Phase numbering continues from v1 (16+) | Maintains continuity across milestones | — |
| Fix native first, then expand | Establishes baseline before tackling harder modes | Phase 16 fixes cascaded into interpret+JIT |
| External stubs blocked on UCRT | DLLs built by Zig link against api-ms-win-crt-runtime which emulator lacks | Needs build config fix |
