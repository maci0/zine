# Zine documentation

| Document | What it covers |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Subsystem layout, execution contexts, build options, directory tree |
| [STATUS.md](STATUS.md) | Current implementation state and dated suite results |
| [TODO.md](TODO.md) | Open work, prioritized |
| [CLI_STATUS.md](CLI_STATUS.md) | Per-binary MSVC CLI toolchain tracker |
| [cross-boundary-data-design.md](cross-boundary-data-design.md) | Guest/host pointer and data marshalling design, in progress |
| [JIT.md](JIT.md) | JIT compiler architecture and roadmap |
| [WASM_PLAN.md](WASM_PLAN.md) | WASM port plan and in-process child PE execution |
| [MEMORY_LAYOUT.md](MEMORY_LAYOUT.md) | Guest address space layout and region sizes |
| [X86_64_NATIVE_EXECUTION.md](X86_64_NATIVE_EXECUTION.md) | 32-bit guests on x86_64 hosts via compat mode |
| [FLTK_PLAN.md](FLTK_PLAN.md) | FLTK native GUI backend |
| [WEB_UI_PROTOCOL.md](WEB_UI_PROTOCOL.md) | Web UI HTTP routes and WebSocket message types |
| [WEBGPU_TRANSLATION.md](WEBGPU_TRANSLATION.md) | DirectDraw/D3D to WebGPU translation guide |
| [DX_VTABLES.md](DX_VTABLES.md) | DirectX COM vtable layouts |
| [THREAT_MODEL.md](THREAT_MODEL.md) | Attack surface, trust boundaries, risks |
| [phase0-audit-results.md](phase0-audit-results.md) | Historical phase 0 codebase audit (dated, not current) |

Plan documents (`FLTK_PLAN.md`, `WASM_PLAN.md`, `cross-boundary-data-design.md`,
`JIT.md`) mix shipped work with remaining work. Read their status lines and
checkboxes as of the date each carries, not as current state; [`STATUS.md`](STATUS.md)
is the canonical record of what is implemented.
