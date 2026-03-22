# Phase 19: WASM32 Interpreted - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Resolve MSVC CLI toolkit tests natively inside WASI runtimes like `wasmtime` and `wasmer`. Ensure paths and exit codes translate properly across the execution boundary.

</domain>

<decisions>
## Implementation Decisions

### WASM CLI File Paths & Exit Codes
- **Transparent Pass-through** — Rely on existing Zine `CreateFileA` translation which turns `C:\` into `drive_c/` and lets everything else be native absolute paths.
- **Clamp bounds in shell** — `wasmtime` caps exit codes at 125, while `wasmer` allows 255. The `test_msvc_cli.sh` should clamp assertions to 125 in WASM mode.

### WASM Guest Memory Sandbox
- **No** — Reuse the `guest_memory.zig` mmap stubs (which are already backed by WASI libc `mmap`/`malloc`) but enforce strict boundary checks since we share a 4GB address space with the guest PE.
- **Increase WASM Max Memory** — Compile `zine.wasm32` with `--max-memory=2147483648` flag so the WASI libc allocator has room to satisfy `VirtualAlloc` requests without hitting sandbox limits, resolving C1076 errors.

### the agent's Discretion
Any unmapped flags or string allocations are at the agent's discretion.

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `src/platform/wasm.zig` — existing WASM platform abstraction layer.
- `src/win32/host_io.zig` — existing path translation logic.

### Established Patterns
- `test_msvc_cli.sh` uses conditional variable filtering based on `$IS_WASM` and `$WASM_RUNTIME`.

### Integration Points
- `src/wasm_main.zig` — main entry point for the WASI executable.
- `build.zig` — where `--max-memory` is passed for WASM32 targets.

</code_context>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
