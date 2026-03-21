# Zine

## What This Is

Zine is a Win32 PE binary interpreter that runs 32-bit Windows executables on Linux and in the browser (via WASM). It provides a software x86 CPU, PE loader, Win32 API compatibility layer, and both native (FLTK) and web-based GUI backends — targeting Win98/Win2K era applications and games.

## Core Value

Run Win98/Win2K era Windows applications and games faithfully on Linux and in the browser without requiring Windows or Wine.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. Inferred from existing codebase. -->

- ✓ x86 instruction interpreter with decode cache — existing
- ✓ PE loader with import resolution and relocation — existing
- ✓ SSE/SSE2 instruction emulation — existing
- ✓ x87 FPU emulation — existing
- ✓ MSVCRT stdlib (printf, sprintf, sscanf, malloc, string ops, CRT init) — existing
- ✓ KERNEL32 (file I/O, memory, process basics, TLS) — existing
- ✓ USER32 (window management, messages, input, menus) — existing
- ✓ GDI32 (device contexts, bitmaps, basic drawing) — existing
- ✓ DirectDraw 7 (surfaces, primary/backbuffer) — existing
- ✓ DirectSound (basic buffer management) — existing
- ✓ DirectInput (keyboard/mouse) — existing
- ✓ SHLWAPI (path manipulation) — existing
- ✓ ADVAPI32 (registry stubs) — existing
- ✓ POSIX ↔ Win32 path translation (C: → drive_c/, Z: → /) — existing
- ✓ Web UI with Win2K CSS theme and HTTP rendering server — existing
- ✓ Native FLTK GUI backend — existing
- ✓ WASM32/WASM64 build targets — existing
- ✓ DLL build mode (35+ stub DLLs as real Windows DLLs) — existing
- ✓ MSVC CLI toolchain running in native/interpret mode — existing
- ✓ Europa 1400 Gold boots to main menu — existing
- ✓ JIT x86→WASM compiler (validation-only) — existing

### Active

<!-- Current scope. Building toward these. -->

- [ ] Europa 1400 Gold runs with full gameplay (past main menu into game world)
- [ ] Direct3D 7 rendering without visual glitches
- [ ] GDI font rendering support (missing fonts in Europa 1400)
- [ ] Win32 threading support (CreateThread, critical sections, events, mutexes)
- [ ] MSVC toolchain all tests passing on WASM32/WASM64 targets
- [ ] Functional JIT execution (compiled x86→WASM blocks actually execute, not just validate)

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- DirectX 8+ / Direct3D 8+ — Europa 1400 uses D3D7, no need for later APIs this milestone
- Win32 networking (Winsock) — not needed for Europa 1400 single-player
- Printing / WINSPOOL — no games need this
- COM/OLE automation — not needed for game compatibility
- Windows XP+ specific APIs — targeting Win98/Win2K era only
- macOS/Windows host support — Linux host only for now
- Audio mixing / advanced DirectSound — basic playback sufficient

## Context

- Europa 1400: The Guild (Gold Edition) is a Win98/Win2K era city simulation/RPG that uses Direct3D 7 for rendering
- The game already boots to the main menu but has rendering glitches (D3D7 issues) and missing fonts (GDI font support gap)
- MSVC CLI toolchain works in native mode but some tests fail when running on WASM32/WASM64 targets
- The x86→WASM JIT compiler currently only validates compiled blocks but doesn't execute them — making it functional would provide real speedup
- The interpreter is single-threaded; Win2K-era games commonly use threads for audio, loading, and game logic
- `.planning/codebase/` contains a full codebase map for reference

## Constraints

- **Architecture**: x86 interpreter runs on x86/x86_64 Linux and WASM — must maintain all three targets
- **ABI**: Win32 stubs use C calling convention with raw usize parameters — new APIs must follow this pattern
- **Memory model**: Guest binaries live in a 32-bit address space with host address translation via `trace.addr()`
- **Zig version**: Must compile with Zig 0.15.2

## Key Decisions

<!-- Decisions that constrain future work. Add throughout project lifecycle. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Target D3D7 not D3D8 for this milestone | Europa 1400 uses D3D7 | — Pending |
| Cooperative threading first | Simpler than preemptive, sufficient for game loops | — Pending |
| JIT execution on WASM only | Native x86 already fast enough via interpreter | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-03-21 after initialization*
