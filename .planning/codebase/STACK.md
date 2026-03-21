# Technology Stack

## Language & Runtime
- **Primary Language:** Zig 0.15.2 (minimum version)
- **Build System:** Native Zig build system (`build.zig`)
- **Target Architectures:** x86 (default), x86_64, wasm32, wasm64

## Core Dependencies
| Dependency | Source | Purpose |
|---|---|---|
| `zig-toml` | GitHub (sam701/zig-toml v0.3.0) | TOML config parsing |
| FLTK 1.3 | System library (optional) | Native GUI backend (x86 only) |
| wasmer C API | System library (optional) | WASM JIT host runtime |

## Build Targets

### Native Executables
- `zine.x86` — Default 32-bit x86-linux interpreter (image base: 0x70000000)
- `zine.x86_64` — 64-bit x86_64-linux interpreter
- `zine-host` — Wasmer-based host for running zine.wasm with JIT

### WASM Executables
- `zine.wasm32` — WASI target (256MB initial memory, 2GB max)
- `zine.wasm64` — WASI 64-bit target

### DLL Stubs
- 35+ Windows DLLs compilable as x86-windows shared libraries (`-Ddll=all`)
- DLLs built against `src/win32_dll_api.zig` shared module

## Build Options
| Flag | Default | Purpose |
|---|---|---|
| `-Darch=` | x86 | Target architecture |
| `-Dall` | false | Build all targets |
| `-Dfltk` | false | Enable FLTK native GUI |
| `-Dexternal-stubs` | false | Load Win32 stubs from DLLs instead of embedding |
| `-Djit_host` | false | Enable JIT host imports for WASM |
| `-Ddll=` | — | Build Windows DLLs |
| `-Dhost` | false | Build zine-host (wasmer wrapper) |

## Configuration
- `build.zig.zon` — Package metadata and dependency declarations
- TOML config files loaded at runtime for game/application configuration
- `drive_c/` directory — Virtual Windows C: drive root for guest executables
