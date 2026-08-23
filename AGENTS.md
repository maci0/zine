## Project

**Zine**

Zine is a Win32 PE binary interpreter that runs 32-bit Windows executables on Linux and in the browser (via WASM). It provides a software x86 CPU, PE loader, Win32 API compatibility layer, and both native (FLTK) and web-based GUI backends, targeting Win98/Win2K era applications and games.

**Core Value:** Run Win98/Win2K era Windows applications and games faithfully on Linux and in the browser without requiring Windows or Wine.

### Constraints

- **Architecture**: x86 interpreter runs on x86/x86_64 Linux and WASM, must maintain all three targets
- **ABI**: Win32 stubs use C calling convention with raw usize parameters, new APIs must follow this pattern
- **Memory model**: Guest binaries live in a 32-bit address space with host address translation via `trace.addr()`
- **Zig version**: Must compile with Zig 0.16.0

## Technology Stack

### Language & Runtime
- **Primary Language:** Zig 0.16.0 (minimum version)
- **Build System:** Native Zig build system (`build.zig`)
- **Target Architectures:** x86 (default), x86_64, wasm32, wasm64

### Core Dependencies
| Dependency | Source | Purpose |
|---|---|---|
| `zig-toml` | GitHub (sam701/zig-toml v0.3.0) | TOML config parsing |
| VanJS (`van.min.js`) | Vendored in src/gui (MIT) | Browser UI reactivity (`van.state`/`van.tags`) |
| FLTK 1.3 | System library (optional) | Native GUI backend (requires x86_64 build) |
| wasmer C API | System library (optional) | WASM JIT host runtime |

### Build Targets
- `zine.x86` -- Default 32-bit x86-linux interpreter (image base: 0x70000000)
- `zine.x86_64` -- 64-bit x86_64-linux interpreter
- `zine-host` -- Wasmer-based host for running zine.wasm with JIT
- `zine.wasm32` -- WASI target (256MB initial memory, 2GB max)
- `zine.wasm64` -- WASI 64-bit target
- 35+ Windows DLLs compilable as x86-windows shared libraries (`-Ddll=all`)

### Build Options
| Flag | Default | Purpose |
|---|---|---|
| `-Darch=` | x86 | Target architecture |
| `-Dall` | false | Build all targets |
| `-Dfltk` | false | Enable FLTK native GUI |
| `-Dexternal-stubs` | false | Load Win32 stubs from DLLs instead of embedding |
| `-Djit_host` | false | Enable JIT host imports for WASM |
| `-Ddll=` | -- | Build Windows DLLs |
| `-Dhost` | false | Build zine-host (wasmer wrapper) |

### Configuration
- `build.zig.zon` -- Package metadata and dependency declarations
- TOML config files loaded at runtime for game/application configuration
- `drive_c/` directory -- Virtual Windows C: drive root for guest executables

## Conventions

### Scratch / Temp Files
Use `.scratch/` (project root) for all temporary, experimental, and bisect files. Never litter `src/` or the project root with ad-hoc temp files. `.scratch/` is gitignored.

### Stub Functions
Stub functions are plain C-callable functions. They receive host-accessible pointers. They return host-accessible pointers. They never translate addresses. They never check what platform they're on. The thunk/boundary layer handles ALL translation, width conversion, and address space mapping.

### Language Style
- **Zig 0.16.0** -- Uses latest Zig idioms (comptime, error unions, tagged unions)
- Standard `camelCase` for functions and variables, `PascalCase` for types
- Win32 API functions use their original names (e.g., `CreateWindowExA`, `GetModuleHandleA`)

### Win32 Stub Patterns
- Win32 stubs use `callconv(w32cc.WINAPI)` (stdcall on x86, C on other platforms)
- Stub functions receive raw `usize` parameters (guest pointers)
- `trace.addr()` translates guest addresses to host addresses
- String parameters: `@as([*:0]const u8, @ptrFromInt(trace.addr(ptr)))`

### Address Translation
- Guest addresses are raw 32-bit values stored as `usize`
- `trace.addr(guest_addr)` converts guest VA to host pointer

### Error Handling
- Win32 stubs **never** propagate Zig errors, they return Win32 error codes (0, -1, INVALID_HANDLE_VALUE)
- `path_utils` calls use `catch return 0` pattern instead of `try`
- Internal Zig errors use `!void` or `!usize` return types with `try`

### Documentation
- Module-level doc comments (`//!`) describe the file's purpose
- Function doc comments (`///`) include implementation status: `Fully implemented`, `Partially implemented`, `Stub`
- Inline comments explain Win32 ABI details and magic numbers

### Tracing
- Conditional tracing via `trace.enable_tracing` boolean
- `trace.print(fmt, args)` for debug output
- All Win32 stub calls are traceable with function names and arguments

## Architecture

### Core Layers

#### x86 Interpreter (`src/x86/`)
- `cpu.zig` -- CPU state (registers, flags, EIP, segments)
- `decoder.zig` -- x86 instruction decoder (41K)
- `execute.zig` -- Instruction execution engine (89K, largest file)
- `flags.zig` -- EFLAGS computation
- `memory.zig` -- Guest memory with address translation
- `sse.zig` -- SSE/SSE2 instruction support (50K)
- `fpu.zig` -- x87 FPU emulation
- `thunks.zig` -- Native/guest calling convention bridges
- `compat_thunks.zig` -- x86_64/x86 ABI compatibility layer
- `decode_cache.zig` -- Decoded instruction caching

#### PE Loader (`src/loader/`)
- `loader.zig` -- PE loading, import resolution, relocation
- `module.zig` -- Module (DLL/EXE) representation
- `env.zig` -- Environment: export registry, module management
- `registry.zig` -- DLL search path and module registry
- `dialog_parser.zig`, `menu_parser.zig`, `icon_parser.zig` -- Win32 resource parsers

#### Win32 API Stubs (`src/win32/`)
- 43 top-level `.zig` files + 18 subdirectories
- Each DLL module has a `register()` function called from `src/runner.zig`
- `shared.zig` -- Common stub generation (`stub_args(N)` comptime helper), memory allocator
- `calling_convention.zig` -- WINAPI/stdcall ABI definition
- `constants.zig` -- Win32 constant definitions
- `host_io.zig` -- Bridge between guest file operations and host filesystem

#### JIT Compiler (`src/jit/`)
- `compiler.zig` -- x86 to WASM basic block compiler (60K)
- `translate.zig` -- x86 instruction to WASM opcode mapping
- `emitter.zig` -- WASM binary module emitter
- `wasm.zig` -- WASM format definitions
- Currently validation-only (interprets all code, compiles WASM for verification)

#### GUI & Rendering (`src/gui/`)
- `renderer.zig` -- Shared rendering state, framebuffer management (45K)
- `web_ui.zig` -- Web-based UI with HTTP server for browser rendering
- `fltk_ui.zig` / `fltk_bridge.cpp` -- Native FLTK desktop window
- `app.js` + `index.html` + `win2k.css` -- Browser frontend (Win2K aesthetic)

#### Platform Abstraction (`src/platform/`)
- `native.zig` -- Linux-specific: mmap, mprotect, signals, host threading (45K)
- `wasm.zig` -- WASM-specific: host imports, memory stubs
- `src/platform.zig` -- Compile-time platform selection

### Entry Points
- `src/main.zig` -- Native entry: CLI parsing, PE loading, interpreter loop
- `src/wasm_main.zig` -- WASM entry: exported functions for browser host
- `src/host_main.zig` -- Wasmer-based host for WASM execution with JIT
- `src/runner.zig` -- Shared pipeline: DLL registration, import resolution, JIT

### Key Abstractions
- **Environment** (`src/loader/env.zig`) -- Central registry of loaded modules and exported functions
- **GuestMemory** (`src/x86/memory.zig`) -- Address-translated access to the guest's 32-bit address space
- **Cpu** (`src/x86/cpu.zig`) -- x86 processor state with register file and control flags
- **Module** (`src/loader/module.zig`) -- Loaded PE module with sections, exports, imports
