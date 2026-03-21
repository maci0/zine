# Roadmap — v1: Win32 Compatibility Milestone

## Overview

| # | Phase | Goal | Requirements | Success Criteria |
|---|-------|------|--------------|------------------|
| 1 | Thread Manager Core | Win32 threads with isolated CPU state | THREAD-01, THREAD-06, THREAD-07 | 3 |
| 2 | Sync Primitives | Critical sections, events, mutexes | THREAD-02, THREAD-03, THREAD-04, THREAD-05 | 4 |
| 3 | GDI Font Subsystem | Font creation, selection, and metrics | FONT-01, FONT-02, FONT-05 | 3 |
| 4 | GDI Text Rendering | TextOut, DrawText rendering to DC | FONT-03, FONT-04, FONT-06 | 3 |
| 5 | D3D7 Device & Pipeline | Device creation, transforms, viewport | D3D7-01, D3D7-02, D3D7-09 | 3 |
| 6 | D3D7 Rasterizer | Triangle rendering with textures | D3D7-03, D3D7-04, D3D7-08 | 3 |
| 7 | D3D7 Render States | Alpha blend, z-buffer, fog, culling | D3D7-05, D3D7-06, D3D7-07 | 3 |
| 8 | DirectSound Mixing | Multi-buffer mixing with volume/pan | DSND-01, DSND-02 | 2 |
| 9 | JIT Execution | Execute compiled WASM blocks | JIT-01, JIT-02, JIT-03 | 3 |
| 10 | MSVC WASM Fixes | All MSVC tests passing on WASM | WASM-01, WASM-02, WASM-03 | 3 |
| 11 | Europa 1400 Integration | Full gameplay validation | EU14-01, EU14-02, EU14-03 | 3 |

**11 phases** | **28 requirements mapped** | All v1 requirements covered ✓

---

## Phase Details

### Phase 1: Thread Manager Core
**Goal:** Create the threading infrastructure: per-thread CPU state, stack allocation, and CreateThread implementation.

**Requirements:** THREAD-01, THREAD-06, THREAD-07

**Success Criteria:**
1. Guest can call CreateThread and a new host thread runs with its own x86 CPU state
2. _beginthread/_beginthreadex from MSVCRT correctly map to CreateThread
3. TLS (TlsAlloc/Get/Set/Free) works correctly across multiple guest threads

---

### Phase 2: Sync Primitives
**Goal:** Implement critical sections, events, and mutexes for guest thread synchronization.

**Requirements:** THREAD-02, THREAD-03, THREAD-04, THREAD-05

**Success Criteria:**
1. Guest threads can enter/leave critical sections without data races
2. Guest threads can create events and wait on them (auto-reset and manual-reset)
3. Guest threads can create mutexes and wait on them
4. WaitForMultipleObjects waits on a mix of events and mutexes

---

### Phase 3: GDI Font Subsystem
**Goal:** Implement font creation, selection, and metric querying so applications can measure and layout text.

**Requirements:** FONT-01, FONT-02, FONT-05

**Success Criteria:**
1. CreateFont/CreateFontIndirect returns a valid HFONT from LOGFONT descriptor
2. SelectObject selects font into DC; GetTextMetrics returns correct height/width/ascent values
3. GetTextExtentPoint32 returns accurate pixel dimensions for a given string

---

### Phase 4: GDI Text Rendering
**Goal:** Render text to device context surfaces using bitmap font fallback.

**Requirements:** FONT-03, FONT-04, FONT-06

**Success Criteria:**
1. TextOut/ExtTextOut draws readable text at specified coordinates on DC surface
2. DrawText renders text with alignment, word wrapping within a rect
3. Europa 1400 displays menu text, dialog text, and in-game HUD text

---

### Phase 5: D3D7 Device & Pipeline
**Goal:** Create D3D7 device with transform and lighting pipeline.

**Requirements:** D3D7-01, D3D7-02, D3D7-09

**Success Criteria:**
1. IDirect3D7::CreateDevice returns a functional software device
2. SetTransform correctly applies WORLD/VIEW/PROJECTION matrix chain
3. SetViewport configures rendering region dimensions

---

### Phase 6: D3D7 Rasterizer
**Goal:** Implement triangle rasterization with texture mapping.

**Requirements:** D3D7-03, D3D7-04, D3D7-08

**Success Criteria:**
1. DrawPrimitive/DrawIndexedPrimitive rasterizes triangle lists/strips/fans
2. Textures apply correctly via SetTexture/SetTextureStageState
3. Clear clears framebuffer and z-buffer to specified values

---

### Phase 7: D3D7 Render States
**Goal:** Implement render state management and frame lifecycle for correct visual output.

**Requirements:** D3D7-05, D3D7-06, D3D7-07

**Success Criteria:**
1. Alpha blending, z-testing, fog, and culling modes produce correct visuals
2. BeginScene/EndScene/Present frame cycle works without tearing or corruption
3. D3D7 output correctly shares framebuffer with existing DirectDraw surfaces

---

### Phase 8: DirectSound Mixing
**Goal:** Support multiple simultaneous sound buffers with volume/pan control.

**Requirements:** DSND-01, DSND-02

**Success Criteria:**
1. Multiple secondary buffers mix into primary buffer output
2. Per-buffer SetVolume and SetPan adjust audio output correctly

---

### Phase 9: JIT Execution
**Goal:** Execute compiled x86→WASM blocks for real speedup instead of validation-only.

**Requirements:** JIT-01, JIT-02, JIT-03

**Success Criteria:**
1. Compiled WASM blocks execute via runtime instead of interpreting
2. JIT execution produces identical register/memory state as interpreter
3. Runtime flag allows switching between JIT and interpreter modes

---

### Phase 10: MSVC WASM Fixes
**Goal:** Fix MSVC toolchain test failures on WASM32/WASM64 targets.

**Requirements:** WASM-01, WASM-02, WASM-03

**Success Criteria:**
1. Full cl.exe test suite passes on wasm32
2. Full cl.exe test suite passes on wasm64
3. Full link.exe test suite passes on WASM targets

---

### Phase 11: Europa 1400 Integration
**Goal:** Validate all work by running Europa 1400 Gold through gameplay.

**Requirements:** EU14-01, EU14-02, EU14-03

**Success Criteria:**
1. Europa 1400 Gold progresses past main menu into city gameplay
2. In-game fonts display correctly (menus, dialogs, HUD)
3. Game audio plays during gameplay sessions
