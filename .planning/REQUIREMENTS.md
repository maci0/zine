# Requirements — v1: Win32 Compatibility Milestone

## v1 Requirements

### Threading
- [ ] **THREAD-01**: Guest can create Win32 threads via CreateThread with isolated x86 CPU state per thread
- [ ] **THREAD-02**: Guest can use critical sections (InitializeCriticalSection, Enter, Leave, Delete)
- [ ] **THREAD-03**: Guest can create and signal events (CreateEvent, SetEvent, ResetEvent, WaitForSingleObject)
- [ ] **THREAD-04**: Guest can create and release mutexes (CreateMutex, ReleaseMutex)
- [ ] **THREAD-05**: Guest can wait on multiple handles (WaitForMultipleObjects)
- [ ] **THREAD-06**: MSVCRT _beginthread and _beginthreadex map to CreateThread
- [ ] **THREAD-07**: Thread local storage (TlsAlloc, TlsGetValue, TlsSetValue, TlsFree) works per-thread

### Direct3D 7
- [ ] **D3D7-01**: IDirect3D7::CreateDevice creates a software rendering device
- [ ] **D3D7-02**: SetTransform handles WORLD, VIEW, PROJECTION matrices with correct T&L pipeline
- [ ] **D3D7-03**: DrawPrimitive and DrawIndexedPrimitive render triangle lists, strips, and fans
- [ ] **D3D7-04**: SetTexture and SetTextureStageState apply textures with correct blending
- [ ] **D3D7-05**: SetRenderState handles alpha blending, z-buffer, fog, and culling modes
- [ ] **D3D7-06**: BeginScene/EndScene/Present frame cycle works correctly
- [ ] **D3D7-07**: D3D7 renders to DirectDraw surfaces shared with existing framebuffer
- [ ] **D3D7-08**: Clear clears framebuffer and z-buffer with specified color/depth
- [ ] **D3D7-09**: SetViewport configures rendering viewport dimensions
- [ ] **D3D7-10**: Europa 1400 Gold renders gameplay scenes without major visual glitches

### GDI Fonts
- [ ] **FONT-01**: CreateFont/CreateFontIndirect creates a logical font from LOGFONT struct
- [ ] **FONT-02**: SelectObject selects font into DC; GetTextMetrics returns font metrics
- [ ] **FONT-03**: TextOut and ExtTextOut render text to a DC surface
- [ ] **FONT-04**: DrawText renders text with alignment and word wrap options
- [ ] **FONT-05**: GetTextExtentPoint32 measures text width/height accurately
- [ ] **FONT-06**: Europa 1400 Gold displays in-game text and menu fonts correctly

### DirectSound
- [ ] **DSND-01**: Multiple secondary buffers mix correctly with primary buffer
- [ ] **DSND-02**: SetVolume and SetPan work on individual buffers

### JIT Execution
- [ ] **JIT-01**: Compiled x86→WASM blocks execute via WASM runtime instead of interpreter
- [ ] **JIT-02**: JIT-executed blocks produce identical results to interpreter execution
- [ ] **JIT-03**: Interpreter and JIT can be toggled at runtime

### MSVC Toolchain (WASM)
- [ ] **WASM-01**: MSVC cl.exe test suite passes on wasm32 target
- [ ] **WASM-02**: MSVC cl.exe test suite passes on wasm64 target
- [ ] **WASM-03**: MSVC link.exe test suite passes on WASM targets

### Europa 1400 Integration
- [ ] **EU14-01**: Europa 1400 Gold progresses past main menu into gameplay
- [ ] **EU14-02**: Europa 1400 Gold displays fonts and UI text correctly
- [ ] **EU14-03**: Europa 1400 Gold plays sounds during gameplay

## v2 Requirements (Deferred)
- [ ] Advanced GDI drawing (paths, regions, complex clipping)
- [ ] DirectInput joystick support
- [ ] TTF font loading from drive_c/Windows/Fonts/
- [ ] 3D positional audio (IDirectSound3DBuffer)
- [ ] WASM threading via SharedArrayBuffer

## Out of Scope
- Direct3D 8/9 rendering — Europa 1400 uses D3D7
- Winsock networking — not needed for single-player gameplay
- COM/OLE automation — not needed for game compatibility
- Windows Installer / MSI — not needed
- Printing / WINSPOOL — not needed
- macOS/Windows host support — Linux only this milestone

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| THREAD-01 | Phase 1: Thread Manager Core | ✅ |
| THREAD-06 | Phase 1: Thread Manager Core | ✅ |
| THREAD-07 | Phase 1: Thread Manager Core | ✅ |
| THREAD-02 | Phase 2: Sync Primitives | ✅ |
| THREAD-03 | Phase 2: Sync Primitives | ✅ |
| THREAD-04 | Phase 2: Sync Primitives | ✅ |
| THREAD-05 | Phase 2: Sync Primitives | ✅ |
| FONT-01 | Phase 3: GDI Font Subsystem | ✅ |
| FONT-02 | Phase 3: GDI Font Subsystem | ✅ |
| FONT-05 | Phase 3: GDI Font Subsystem | ✅ |
| FONT-03 | Phase 4: GDI Text Rendering | ✅ |
| FONT-04 | Phase 4: GDI Text Rendering | ✅ |
| FONT-06 | Phase 4: GDI Text Rendering | ✅ |
| D3D7-01 | Phase 5: D3D7 Device & Pipeline | ✅ |
| D3D7-02 | Phase 5: D3D7 Device & Pipeline | ✅ |
| D3D7-09 | Phase 5: D3D7 Device & Pipeline | ✅ |
| D3D7-03 | Phase 6: D3D7 Rasterizer | ✅ |
| D3D7-04 | Phase 6: D3D7 Rasterizer | ✅ |
| D3D7-08 | Phase 6: D3D7 Rasterizer | ✅ |
| D3D7-05 | Phase 7: D3D7 Render States | ✅ |
| D3D7-06 | Phase 7: D3D7 Render States | ✅ |
| D3D7-07 | Phase 7: D3D7 Render States | ✅ |
| D3D7-10 | Phase 13: Europa 1400 Debugging | ⚠️ needs retest |
| DSND-01 | Phase 12: DirectSound Gap Closure | ✅ |
| DSND-02 | Phase 12: DirectSound Gap Closure | ✅ |
| JIT-01 | Phase 9: JIT Execution | ⚠️ |
| JIT-02 | Phase 14: JIT Equivalence Tests | ⚠️ tech debt |
| JIT-03 | Phase 9: JIT Execution | ✅ |
| WASM-01 | Phase 15: WASM Test Verification | ⚠️ build passes, runtime untested |
| WASM-02 | Phase 15: WASM Test Verification | ⚠️ build passes, runtime untested |
| WASM-03 | Phase 15: WASM Test Verification | ⚠️ build passes, runtime untested |
| EU14-01 | Phase 13: Europa 1400 Debugging | ⚠️ SEH fix applied, needs retest |
| EU14-02 | Phase 13: Europa 1400 Debugging | ⚠️ needs retest |
| EU14-03 | Phase 13: Europa 1400 Debugging | ⚠️ needs retest |
