# Zine

Run Win98/Win2K-era 32-bit Windows executables on Linux and in the browser without Windows or Wine.

## Constraints

- Use Zig 0.16.0. Preserve x86 and x86_64 Linux, wasm32 and wasm64 WASI builds; host pointer width does not change the guest's 32-bit address space.
- Keep native executables at image base `0x70000000` to leave low addresses free for guest PEs. The x86 target disables SIMD for legacy 4-byte stack alignment; do not enable it as a host optimization.
- Use `callconv(w32cc.WINAPI)` for Win32 API stubs: stdcall on x86, Win64 on x86_64, C elsewhere. Preserve cdecl (`.c`) for APIs that require it, including MSVCRT.
- New and migrated stubs use typed host-accessible pointer parameters and returns. Keep guest address translation, pointer-width conversion, and platform-specific mapping in the thunk/platform layer, not in stubs.
- Legacy stubs may still accept guest pointers as `usize` and call `trace.addr()`. Inspect their registration and thunk before changing signatures; never translate an already-translated pointer. `src/loader/env.zig` handles typed pointers and legacy integers differently, including a separate variadic path. `docs/cross-boundary-data-design.md` describes the migration design, not a completed implementation.
- Win32 stubs return the API's documented failure value and set last error where required; never propagate Zig errors across the ABI. Do not substitute a blanket `catch return 0` for APIs with other failure sentinels.

## Verification

Run `bash tests/check.sh` from the repository root before a pull request. It first requires the listed tools, a git work tree (a source archive has none), and exactly the Zig version pinned in `build.zig.zon`, then runs the CI gate in order and stops at the first failure. `bash tests/check.sh --list` prints the step names, and that is the gate order; one step runs on its own with `bash tests/check.sh <name>`. The gate also runs `check_shell` (every tracked script through shellcheck), `check_c` (the tracked C sources through `zig cc`, warning-free), and `reproducible` (two install trees of the native targets, compared byte for byte). Single steps, when bisecting:

- Unit tests: `zig build test` (also checks formatting). Tests run on the host; `-Darch` does not change the test target.
- Native CLI tests: `zig build test-cli`, then `zig build test-cli -Darch=x86_64`; no guest binaries required.
- Formatting: `zig fmt --check src build.zig build.zig.zon`.
- Compile/typecheck each target, sequentially to limit peak memory: `zig build`, `zig build -Darch=x86_64`, `zig build -Darch=wasm32`, `zig build -Darch=wasm64`. These build ReleaseSafe, the default of the `-Doptimize` option; pass `-Doptimize=Debug` for a debugging loop and expect that to change build time.
- Linked-artifact hardening: `bash tests/check.sh hardening` reads the program headers of `zig-out/bin/zine.x86` and `zine.x86_64` and requires a static link and a non-executable stack. It rebuilds both targets first, so it stands alone. PIE, RELRO, BIND_NOW and Zig's stack protector are deliberately absent (fixed image base, static link, no libc); do not add one without removing its exclusion.
- Web assets: `bash tests/check.sh check_web` parses every tracked JavaScript file with `node --check`. The Zig build only embeds those bytes, so nothing else in the gate reads them.
- Stub DLLs: `zig build -Ddll=all` compiles `src/dll/` and `src/win32_dll_api.zig` for x86-windows. `zig build -Dexternal-stubs` covers the other half of the embed/external stub switch.
- The FLTK bridge: `zig build check-cxx` compiles `src/gui/fltk_bridge.cpp` alone, with the flags and include paths `zig build -Darch=x86_64 -Dfltk` gives it, and links nothing. It needs the FLTK development headers (`libfltk1.3-dev`); the FLTK executable additionally needs the X11 runtime, which the gate does not install.

Formatting also gates the install and test steps inside `build.zig`. A new gate belongs in `tests/check.sh` and `.github/workflows/ci.yml` together; the `check_ci` step compares the two step lists and fails when one has a step the other does not. Fix failing code rather than weakening checks or dropping targets. CI calls the script for the helper steps, so their commands and file lists are defined there alone. `ZINE_FUZZ_SECONDS` overrides the seconds each fuzz target runs; CI sets it to 60.

See `README.md` for optional FLTK/Wasmer builds, run commands, and integration suites, and `CONTRIBUTING.md` for the gate and commit conventions. Integration tests require guest binaries and runtime dependencies beyond the unit-test setup.

## Working conventions

- Use gitignored `.scratch/` for experiments; keep ad-hoc files out of `src/` and the root.
- A new file with `test` blocks needs a `_ = @import("...")` line in `src/test_root.zig`, or its tests never run.
- Preserve Win32 API names. Match surrounding Zig naming and error-handling conventions.
- Trace stub calls with `trace.print(fmt, args)`; it honors `trace.enable_tracing`.
- Document implementation status (`Fully implemented`, `Partially implemented`, `Stub`) in function doc comments; explain ABI constraints and magic numbers rather than restating code.
- Native `--jit` validates compilation while the interpreter executes. Executing compiled WASM blocks requires `-Djit_host=true` and a runtime providing `jit_compile`/`jit_call`; do not treat native validation as JIT execution coverage.
- The PE header, menu, dialog, and icon parsers, the PE string-table walk behind `LoadStringA`/`LoadStringW`, the resource-directory and export-directory walks in `src/loader/module.zig`, the batch interpreter in `src/bat.zig`, and the `.rc` resource compiler in `src/win32/rcdll.zig` have fuzz harnesses under `src/fuzz/`. Each asserts its output contract (the resource parsers the JSON of the message they render, the PE one its header invariants, the string-table one the terminator and the agreement between the narrow and wide walks, the module ones that a resolved slice or RVA lies inside the mapped image and that a repeated lookup answers the same, the batch one an argv that is well formed and reproducible, the `.rc` one that every record of the emitted `.res` image fits and that the same script compiles the same way twice), so a bad output is a failure rather than a crash. Run the harnesses with `zig build fuzz`; failing inputs land in `zig-out/fuzz/` and belong in the seed corpus once minimized.
- A parser that only reaches its input through a file takes the raw bytes in a `parse*`-style entry point, leaving the file read as a thin wrapper. `buildResImage` in `src/win32/rcdll.zig` is the model: the whole parse and emit path runs from the script text, and the caller supplies the buffer.
- A new parser gets a harness asserting its output contract, and `zig build test` replays the seeds.
- Give the harness a path to raw input. A parser that only reaches its input through a `Module` takes the resource bytes in a `parse*Data` entry point, leaving the module lookup as a thin wrapper; a parser that only reaches its input through the filesystem takes them in a `runScript`-style entry point.
- A stub that walks a module's image from a guest handle resolves that handle through `Registry.moduleForHandle` first: an address that names no mapping has no length, so nothing inside it can be read within bounds.
- Record a guest- or operator-visible change under the README's `### Unreleased` release notes, and never edit the notes of a published version. A release bumps `build.zig.zon` and `src/version.zig` together; `CONTRIBUTING.md` has the procedure.

For subsystem layout, see `docs/ARCHITECTURE.md`; build options and dependencies live in `build.zig` and `build.zig.zon`.
