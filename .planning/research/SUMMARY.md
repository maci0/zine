# Research Summary

## Stack
- Zig 0.15.2 with multi-target build system — no changes needed
- D3D7 requires a **software rasterizer** implementing the fixed-function T&L pipeline
- GDI fonts need a **glyph rasterizer** (bitmap fallback first, then TTF)
- Threading maps Win32 threads to **host pthreads/std.Thread** with per-thread CPU state
- JIT execution needs **WASM module instantiation** after compilation

## Table Stakes for Europa 1400
1. D3D7 rendering (DrawPrimitive, SetRenderState, textures, T&L)
2. GDI font rendering (CreateFont, TextOut, GetTextMetrics)
3. Win32 threading (CreateThread, critical sections, events)
4. DirectSound buffer mixing improvements

## Watch Out For
1. **COM vtable ABI** — must use 4-byte u32 pointers, not usize (already hit with DirectSound)
2. **Thread safety in GuestMemory** — shared memory between guest threads needs host-level synchronization
3. **WASM threading** — no native threads; needs cooperative scheduling or SharedArrayBuffer
4. **D3D7 ↔ DirectDraw surface sharing** — D3D7 renders to DDraw surfaces, must share framebuffer
5. **Font mapping** — Windows LOGFONT matching is complex; start with bitmap fallback

## Recommended Build Order
1. Threading (CreateThread + sync primitives) — dependency for everything else
2. GDI fonts (parallel with threading)
3. D3D7 software rasterizer
4. DirectSound improvements
5. JIT execution
6. MSVC WASM test fixes
