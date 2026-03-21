# Features Research

## Table Stakes (Must Have for Europa 1400)

### Direct3D 7 Rendering
- **SetRenderState** — alpha blending, z-buffer, fog, lighting control
- **SetTransform** — world/view/projection matrix pipeline
- **DrawPrimitive / DrawIndexedPrimitive** — triangle list/strip/fan rendering
- **SetTexture / SetTextureStageState** — texture mapping with multi-stage blending
- **Clear** — framebuffer/z-buffer clearing
- **BeginScene / EndScene** — frame bracketing
- **Viewport management** — SetViewport2
- Complexity: HIGH — full fixed-function T&L pipeline

### GDI Font Support
- **CreateFont / CreateFontIndirect** — logical font creation
- **SelectObject** — font selection into DC
- **TextOut / DrawText / ExtTextOut** — text rendering to DC surface
- **GetTextMetrics / GetTextExtentPoint32** — text measurement
- **Font mapping** — LOGFONT to physical font resolution
- Complexity: MEDIUM — can start with bitmap font fallback

### Win32 Threading
- **CreateThread / ExitThread** — thread lifecycle
- **Critical sections** — fast intra-process mutex
- **Events** — CreateEvent / Set / Reset / WaitForSingleObject
- **Mutexes** — CreateMutex / ReleaseMutex  
- **WaitForMultipleObjects** — multi-handle wait
- Complexity: HIGH — interpreter needs per-thread CPU state

### DirectSound Improvements
- **Secondary buffer mixing** — Europa uses multiple sound buffers
- **3D sound positioning** (if used) — IDirectSound3DBuffer
- Complexity: MEDIUM

## Differentiators (Nice to Have)
- **JIT execution** — real speedup from compiled WASM blocks
- **MSVC WASM fixes** — full test suite passing on wasm32/64
- Full DirectInput joystick support
- Advanced GDI drawing (paths, regions, complex clipping)

## Anti-Features (Do NOT Build)
- Direct3D 8/9 rendering — not needed for Europa 1400
- Winsock networking — not needed for single-player
- COM/OLE automation — not needed for game
- Windows installer engine — not needed
