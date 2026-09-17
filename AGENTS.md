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

Run from the repository root:

- Unit tests: `zig build test` (also checks formatting). Tests run on the host; `-Darch` does not change the test target.
- Native CLI tests: `zig build test-cli`, then `zig build test-cli -Darch=x86_64`; no guest binaries required.
- Formatting: `zig fmt --check src build.zig build.zig.zon`.
- Compile/typecheck each target, sequentially to limit peak memory: `zig build`, `zig build -Darch=x86_64`, `zig build -Darch=wasm32`, `zig build -Darch=wasm64`.
- Shell lint: `shellcheck -x tests/*.sh`.
- Keep the formatting, shell lint, and cross-target gates in `build.zig` and `.github/workflows/ci.yml`; fix failing code rather than weakening checks or dropping targets.

See `README.md` for optional FLTK/Wasmer builds, run commands, and integration suites. Integration tests require guest binaries and runtime dependencies beyond the unit-test setup.

## Working conventions

- Use gitignored `.scratch/` for experiments; keep ad-hoc files out of `src/` and the root.
- Preserve Win32 API names. Match surrounding Zig naming and error-handling conventions.
- Trace stub calls with `trace.print(fmt, args)`; it honors `trace.enable_tracing`.
- Document implementation status (`Fully implemented`, `Partially implemented`, `Stub`) in function doc comments; explain ABI constraints and magic numbers rather than restating code.
- Native `--jit` validates compilation while the interpreter executes. Executing compiled WASM blocks requires `-Djit_host=true` and a runtime providing `jit_compile`/`jit_call`; do not treat native validation as JIT execution coverage.

For subsystem layout, see `docs/ARCHITECTURE.md`; build options and dependencies live in `build.zig` and `build.zig.zon`.
