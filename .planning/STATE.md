# Zine — State

## Project Status

See: .planning/PROJECT.md (updated 2026-03-22)

**Core value:** Run Win98/Win2K era Windows applications and games faithfully on Linux and in the browser
**Current focus:** Phase 16 — Baseline Fix (native mode test failures)

## Current Milestone

**v2: Full Test Coverage**
- 8 phases (16-23) | 16 requirements
- Status: Starting — baseline analysis needed

## Phase Progress

| # | Phase | Status |
|---|-------|--------|
| 16 | Baseline Fix | 🔲 Not started |
| 17 | Interpreter Mode Green | 🔲 Not started |
| 18 | Native64 Mode Green | 🔲 Not started |
| 19 | JIT Mode Green | 🔲 Not started |
| 20 | External Stubs Green | 🔲 Not started |
| 21 | WASM32 Green | 🔲 Not started |
| 22 | WASM64 Support | 🔲 Not started |
| 23 | Test Infra Polish | 🔲 Not started |

## Key Decisions Log

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Phase numbering continues from v1 (16+) | Maintains continuity across milestones | — |
| Fix native first, then expand | Establishes baseline before tackling harder modes | — |
| 9 permutations (incl. wasm64) | User wants ALL possible execution paths covered | — |
