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

Run `bash tests/check.sh` from the repository root before a pull request. It first requires the listed tools and a Zig version matching `build.zig.zon`, then runs the CI gate in the same order (formatting, shell lint, the warning-free C compile, all four architecture builds, the external-stub DLL and `-Dexternal-stubs` builds, unit tests, both native `test-cli` runs, and a 10-second fuzz run) and stops at the first failure. Each gate step has a name, so one of them runs on its own with `bash tests/check.sh <name>`; `--list` prints the names. Single steps, when bisecting:

- Unit tests: `zig build test` (also checks formatting). Tests run on the host; `-Darch` does not change the test target.
- Native CLI tests: `zig build test-cli`, then `zig build test-cli -Darch=x86_64`; no guest binaries required.
- Formatting: `zig fmt --check src build.zig build.zig.zon`.
- Compile/typecheck each target, sequentially to limit peak memory: `zig build`, `zig build -Darch=x86_64`, `zig build -Darch=wasm32`, `zig build -Darch=wasm64`. These build ReleaseSafe, the default of the `-Doptimize` option; pass `-Doptimize=Debug` for a debugging loop and expect that to change build time.
- Stub DLLs: `zig build -Ddll=all` compiles `src/dll/` and `src/win32_dll_api.zig` for x86-windows. `zig build -Dexternal-stubs` covers the other half of the embed/external stub switch.

Formatting also gates the install and test steps inside `build.zig`. A new gate belongs in `tests/check.sh` and `.github/workflows/ci.yml` together; fix failing code rather than weakening checks or dropping targets. `bash tests/check.sh <step>` runs one named step of the gate (`fmt`, `check_shell`, `check_c`, `build`, `build-x86_64`, `build-wasm32`, `build-wasm64`, `dll`, `external-stubs`, `test`, `test-cli`, `test-cli-x86_64`, `fuzz`); CI calls the script for the helper steps, so their commands and file lists are defined there alone.

See `README.md` for optional FLTK/Wasmer builds, run commands, and integration suites, and `CONTRIBUTING.md` for the gate and commit conventions. Integration tests require guest binaries and runtime dependencies beyond the unit-test setup.

## Working conventions

- Use gitignored `.scratch/` for experiments; keep ad-hoc files out of `src/` and the root.
- A new file with `test` blocks needs a `_ = @import("...")` line in `src/test_root.zig`, or its tests never run.
- Preserve Win32 API names. Match surrounding Zig naming and error-handling conventions.
- Trace stub calls with `trace.print(fmt, args)`; it honors `trace.enable_tracing`.
- Document implementation status (`Fully implemented`, `Partially implemented`, `Stub`) in function doc comments; explain ABI constraints and magic numbers rather than restating code.
- Native `--jit` validates compilation while the interpreter executes. Executing compiled WASM blocks requires `-Djit_host=true` and a runtime providing `jit_compile`/`jit_call`; do not treat native validation as JIT execution coverage.
- The PE header, menu, dialog, and icon parsers have fuzz harnesses under `src/fuzz/`; each asserts its output contract (the resource parsers the JSON of the message they render, the PE one its header invariants), so a bad output is a failure rather than a crash. Run the harnesses with `zig build fuzz`; failing inputs land in `zig-out/fuzz/` and belong in the seed corpus once minimized. New parsers get a harness asserting their output contract, and `zig build test` replays the seeds. A parser that only reaches its input through a `Module` takes the raw resource bytes in a `parse*Data` entry point, with the module lookup left as a thin wrapper, so the harness can feed it bytes directly.
- Record a guest- or operator-visible change under the README's `### Unreleased` release notes, and never edit the notes of a published version. A release bumps `build.zig.zon` and `src/version.zig` together; `CONTRIBUTING.md` has the procedure.

For subsystem layout, see `docs/ARCHITECTURE.md`; build options and dependencies live in `build.zig` and `build.zig.zon`.
