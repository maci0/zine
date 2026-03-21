# Stack Research

## Current Stack (Validated)
- **Language:** Zig 0.15.2
- **Build:** Native Zig build system
- **Targets:** x86-linux, x86_64-linux, wasm32-wasi, wasm64-wasi
- **Dependencies:** zig-toml (config), FLTK 1.3 (optional GUI), wasmer (WASM host)

## Additions Needed for This Milestone

### Direct3D 7 Software Rasterizer
- **Approach:** Software rasterizer implementing IDirect3D7/IDirect3DDevice7 interfaces
- **Key interfaces:** IDirect3D7, IDirect3DDevice7, IDirect3DVertexBuffer7
- **Operations:** SetRenderState, SetTransform, DrawPrimitive, SetTexture, SetTextureStageState
- **Confidence:** High — D3D7 fixed-function pipeline is well-documented, Wine/WineD3D has reference implementations

### GDI Font Rendering
- **Approach:** Bitmap font rasterizer using embedded font data or stb_truetype-style approach
- **Key APIs:** CreateFont, CreateFontIndirect, SelectObject, TextOut, DrawText, GetTextMetrics, GetTextExtentPoint32
- **Font sources:** System fonts from `drive_c/Windows/Fonts/` or embedded fallback bitmap font
- **Confidence:** Medium — GDI font mapping is complex; can start with fixed-size bitmap fonts

### Win32 Threading
- **Approach:** Map Win32 threads to host pthreads (or Zig std.Thread)
- **Key APIs:** CreateThread, ExitThread, WaitForSingleObject, WaitForMultipleObjects
- **Sync primitives:** InitializeCriticalSection/EnterCriticalSection/LeaveCriticalSection, CreateEvent/SetEvent/ResetEvent, CreateMutex
- **Challenge for interpreter:** Each guest thread needs its own x86 CPU state
- **On WASM:** SharedArrayBuffer + Atomics or cooperative scheduling
- **Confidence:** Medium — threading in an interpreter requires careful CPU state isolation

### JIT Execution
- **Approach:** Execute compiled WASM blocks via wasmer runtime or browser WASM engine
- **Current state:** Compiler produces valid WASM but blocks aren't executed
- **Key change:** After compiling, instantiate WASM module and call compiled function
- **Confidence:** Medium — compilation works, execution plumbing is the gap
