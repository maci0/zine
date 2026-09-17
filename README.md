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

## Releases and upgrades

The `v1` tag (2026-03-22) names the **Win32 Compatibility Milestone**, not
SemVer 1.0.0. Its package version and the current version are both `0.1.0`.
History therefore indicates milestone tagging during 0.x development, not a
stable 1.x compatibility promise. There is no documented SemVer bump,
deprecation, support-window, or security-backport policy. Pin a commit when
reproducing a build; `--version` alone does not distinguish post-milestone changes.

### Unreleased changes since v1

#### Breaking build requirements and migration

- Zig **0.16.0** replaces **0.15.2** as the minimum toolchain. Upgrade Zig before
  rebuilding; the source now uses the 0.16 process and I/O APIs.
- For the native FLTK GUI, use `zig build -Darch=x86_64 -Dfltk` instead of the
  old x86 `zig build -Dfltk` recipe, then run `zig-out/bin/zine.x86_64 --fltk`.
  Guest executables remain 32-bit Windows PEs.

#### Added

- Native x86_64 FLTK support and expanded Win32 controls and common dialogs.
- Per-application `registry.toml` overrides with `app:<MODULE>:<KEY>` sections.
  Existing global sections remain usable; overrides take precedence for the
  matching executable basename.

#### Fixed

- `--help`/`-h` and `--version`/`-v` once again write to stdout on WASI and
  `zine-host`, preserving shell capture and piping after the Zig migration.
  Native informational commands no longer attempt guest memory setup or emit
  null-page mapping warnings. Invalid options still return status 2 on stderr.
- Win32 `MulDiv` rounds to nearest instead of truncating, and `lstrcmpiW`
  preserves non-ASCII UTF-16 units rather than truncating them to bytes.

See [implementation status](docs/STATUS.md) for subsystem coverage and remaining
limitations. These notes do not designate a new release or retag `v1`.

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

# CLI output and exit status (no Windows binaries needed)
zig build test-cli
zig build test-cli -Darch=x86_64
zig build test-cli -Darch=wasm32  # requires wasmtime
zig build test-cli -Dhost       # also checks zine-host; requires Wasmer headers/libs

# Optional integration suite (requires MSVC fixtures described above)
./tests/test_msvc_cli.sh --native
./tests/test_msvc_cli.sh --native64
./tests/test_msvc_cli.sh --wasmtime

# FLTK smoke tests (requires Xvfb)
./tests/fltk_smoke.sh
```

The CLI gate checks the built executable's version against `build.zig.zon`,
stdout/stderr separation, help aliases, and invalid-option status. Every build
also rejects disagreement between the manifest and `src/version.zig`.
`test-cli` supports native and plain wasm32 builds; wasm64's 64-bit WASI imports
and `-Djit_host` builds require a custom runtime and are not executed by this gate.

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
