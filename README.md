# Zine

A Win32 PE interpreter that runs 32-bit Windows executables on Linux and in the browser. Software x86 CPU, PE loader, Win32 API compatibility layer, and GUI backends (native FLTK + browser via WASM). Targets Win98/Win2K era applications and games.

No Windows installation, no Wine.

## What works

- Full MSVC 6.0 toolchain: CL.EXE, LINK.EXE, RC.EXE, NMAKE.EXE, and 8 more utilities run to completion
- 158 tests passing on native x86 and x86_64, 128 on WASM (wasmtime), 20 FLTK smoke tests
- x86 interpreter with SSE/SSE2, x87 FPU, SEH, TLS
- PE loader with import resolution, relocations, resource parsing (dialogs, menus, icons, string tables)
- 35+ Win32 DLL stubs: kernel32, user32, gdi32, advapi32, shell32, ws2_32, comctl32, ole32, msvcrt, and more
- x86-to-WASM JIT compiler (basic block level, interleaves with interpreter)
- Web GUI with Win2K-style desktop, or native FLTK window
- Virtual filesystem rooted at `drive_c/`

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
# Default 32-bit x86 interpreter
zig build

# 64-bit with native GUI
zig build -Darch=x86_64 -Dfltk

# WASM target
zig build -Darch=wasm32

# All targets
zig build -Dall
```

## Usage

```sh
# Run a Windows executable
./zig-out/bin/zine.x86 path/to/app.exe

# Place files under drive_c/ to populate the virtual C: drive
mkdir -p drive_c/myapp
cp app.exe drive_c/myapp/
./zig-out/bin/zine.x86 drive_c/myapp/app.exe
```

## Build options

| Flag | Purpose |
|---|---|
| `-Darch=x86\|x86_64\|wasm32\|wasm64` | Target architecture (default: x86) |
| `-Dfltk` | Enable native FLTK GUI backend (x86_64 only) |
| `-Djit_host` | Enable JIT host imports for WASM builds |
| `-Dexternal-stubs` | Load Win32 stubs from DLLs instead of embedding |
| `-Ddll=<name>\|all` | Build Windows DLL stubs as shared libraries |
| `-Dhost` | Build zine-host (wasmer-based WASM runner) |

## Testing

The unit suite runs with Zig alone. The optional MSVC integration suite requires
an existing MSVC 6.0 installation at `tools/MSVC600/`, including `VC98/Bin`,
`VC98/Include`, `VC98/Lib`, and `Common/`. These proprietary fixtures are not
included in a clone. The script builds the selected interpreter automatically;
WASM execution also requires the selected runtime on `PATH`. WebSocket tests
require Python 3 and the dependencies in `tests/requirements.txt`.

```sh
# Unit tests (no Windows binaries or GUI dependencies needed)
zig build test

# Focus on one module or test-name substring
zig build test -Dtest-filter=x86.decoder --summary all

# Optional integration suite (requires MSVC fixtures described above)
./tests/test_msvc_cli.sh --native
./tests/test_msvc_cli.sh --native64
./tests/test_msvc_cli.sh --wasmtime

# FLTK smoke tests (requires Xvfb)
./tests/fltk_smoke.sh
```

## Architecture

```
src/
  x86/         x86 interpreter (decoder, executor, FPU, SSE, thunks)
  loader/      PE loader, import resolution, resource parsers
  win32/       Win32 API stubs (100+ files across 35+ DLLs)
  jit/         x86-to-WASM basic block JIT compiler
  gui/         Web UI (HTTP server + JS frontend) and FLTK native backend
  platform/    Linux/WASM platform abstraction
  main.zig     Native CLI entry point
  wasm_main.zig  WASM entry point
```

~65K lines of Zig.

See `docs/` for detailed design notes on memory layout, JIT strategy, native execution, and Win32 API coverage.
