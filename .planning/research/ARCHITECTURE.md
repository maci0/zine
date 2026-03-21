# Architecture Research

## Component Dependencies for This Milestone

```
Europa 1400 Gold
├── Direct3D 7 (rendering)
│   ├── IDirect3D7 (device enumeration)
│   ├── IDirect3DDevice7 (draw calls, state)
│   ├── IDirectDrawSurface7 (texture/framebuffers)  ← already exists partially
│   └── Software Rasterizer (NEW)
│       ├── Transform & Lighting pipeline
│       ├── Triangle setup + rasterization
│       ├── Texture sampling
│       └── Framebuffer output → existing renderer
├── GDI32 (fonts, menus, UI text)
│   ├── Font subsystem (NEW)
│   │   ├── Font loading (TTF from drive_c/Windows/Fonts/)
│   │   ├── LOGFONT mapper
│   │   └── Glyph rasterizer
│   └── Text drawing (TextOut, DrawText)
├── KERNEL32 (threading)
│   ├── Thread manager (NEW)
│   │   ├── Per-thread CPU state
│   │   ├── Thread scheduling
│   │   └── Stack allocation per thread
│   └── Sync primitives (NEW)
│       ├── Critical sections
│       ├── Events
│       └── Mutexes
├── DirectSound (audio)
│   └── Buffer mixing (improvement)
└── MSVCRT (CRT)
    └── _beginthread / _beginthreadex (maps to CreateThread)
```

## Build Order (Dependencies)
1. **Threading first** — many other features depend on multi-threading
2. **GDI fonts** — independent, can parallel with threading
3. **D3D7 rendering fixes** — depends on threading (render thread)
4. **DirectSound improvements** — after threading (audio thread)
5. **JIT execution** — independent, can be done anytime
6. **MSVC WASM fixes** — independent

## Data Flow: D3D7 Software Rasterizer
```
Guest D3D7 calls → Zine D3D7 COM vtable stubs
  → Transform vertices (world × view × projection)
  → Clip to viewport
  → Rasterize triangles (scan-line or half-space)
  → Sample textures (point/bilinear filter)
  → Apply render states (alpha blend, z-test)
  → Write to framebuffer
  → Present → existing renderer.zig → display
```

## Data Flow: Threading
```
Guest CreateThread call → Zine thread manager
  → Allocate new x86 CPU state (registers, flags, EIP)
  → Allocate guest stack (16KB–1MB)
  → Spawn host thread (std.Thread or pthread)
  → Host thread runs interpreter loop with its own CPU
  → Sync via shared guest memory + sync primitive stubs
```
