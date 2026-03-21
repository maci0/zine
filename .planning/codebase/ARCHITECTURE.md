# Architecture

## System Overview
Zine is a **Win32 PE binary interpreter** — it loads and executes 32-bit Windows executables on Linux and in the browser (via WASM) by providing a software x86 CPU, PE loader, and Win32 API compatibility layer.

## Architectural Pattern
**Layered emulation stack** with clear separation between:
1. **CPU Layer** — x86 instruction decode + execute
2. **Memory Layer** — Guest address space management
3. **OS Layer** — Win32 API stubs and PE loading
4. **Presentation Layer** — GUI rendering backends

## Data Flow
```
Guest .exe (PE binary)
    ↓
PE Loader (parse headers, resolve imports, relocate)
    ↓
x86 Interpreter (fetch → decode → execute loop)
    ↓ (Win32 API calls via IAT thunks)
Win32 Stub Layer (KERNEL32, USER32, GDI32, etc.)
    ↓ (host operations)
Host Platform (file I/O, rendering, audio)
```

## Core Layers

### x86 Interpreter (`src/x86/`)
- `cpu.zig` — CPU state (registers, flags, EIP, segments)
- `decoder.zig` — x86 instruction decoder (41K)
- `execute.zig` — Instruction execution engine (89K — largest file)
- `flags.zig` — EFLAGS computation
- `memory.zig` — Guest memory with address translation
- `sse.zig` — SSE/SSE2 instruction support (50K)
- `fpu.zig` — x87 FPU emulation
- `thunks.zig` — Native ↔ guest calling convention bridges
- `compat_thunks.zig` — x86_64 ↔ x86 ABI compatibility layer
- `decode_cache.zig` — Decoded instruction caching

### PE Loader (`src/loader/`)
- `loader.zig` — PE loading, import resolution, relocation
- `module.zig` — Module (DLL/EXE) representation
- `env.zig` — Environment: export registry, module management
- `registry.zig` — DLL search path and module registry
- `dialog_parser.zig`, `menu_parser.zig`, `icon_parser.zig` — Win32 resource parsers

### Win32 API Stubs (`src/win32/`)
- 43 top-level `.zig` files + 18 subdirectories
- Each DLL module has a `register()` function called from `src/runner.zig`
- `shared.zig` — Common stub generation (`stub_args(N)` comptime helper), memory allocator
- `calling_convention.zig` — WINAPI/stdcall ABI definition
- `constants.zig` — Win32 constant definitions
- `host_io.zig` — Bridge between guest file operations and host filesystem

### JIT Compiler (`src/jit/`)
- `compiler.zig` — x86 → WASM basic block compiler (60K)
- `translate.zig` — x86 instruction → WASM opcode mapping
- `emitter.zig` — WASM binary module emitter
- `wasm.zig` — WASM format definitions
- Currently validation-only (interprets all code, compiles WASM for verification)

### GUI & Rendering (`src/gui/`)
- `renderer.zig` — Shared rendering state, framebuffer management (45K)
- `web_ui.zig` — Web-based UI with HTTP server for browser rendering
- `fltk_ui.zig` / `fltk_bridge.cpp` — Native FLTK desktop window
- `app.js` + `index.html` + `win2k.css` — Browser frontend (Win2K aesthetic)

### Platform Abstraction (`src/platform/`)
- `native.zig` — Linux-specific: mmap, mprotect, signals, host threading (45K)
- `wasm.zig` — WASM-specific: host imports, memory stubs
- `src/platform.zig` — Compile-time platform selection

## Entry Points
- `src/main.zig` — Native entry: CLI parsing, PE loading, interpreter loop
- `src/wasm_main.zig` — WASM entry: exported functions for browser host
- `src/host_main.zig` — Wasmer-based host for WASM execution with JIT
- `src/runner.zig` — Shared pipeline: DLL registration, import resolution, JIT

## Key Abstractions
- **Environment** (`src/loader/env.zig`) — Central registry of loaded modules and exported functions
- **GuestMemory** (`src/x86/memory.zig`) — Address-translated access to the guest's 32-bit address space
- **Cpu** (`src/x86/cpu.zig`) — x86 processor state with register file and control flags
- **Module** (`src/loader/module.zig`) — Loaded PE module with sections, exports, imports
