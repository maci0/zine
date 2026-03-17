# General TODOs

This document tracks unimplemented features and tasks for Zine.

## x86_64 Native Execution (Phase 5 — Implemented)
- [x] Signal-based INT 0xFE dispatch via SIGSEGV handler
- [x] 256KB compat thunk pool with MAP_32BIT
- [x] iretq trampoline (CS=0x23 compat mode entry)
- [x] IAT patching with compat thunk addresses
- [x] TEB allocation in low 4GB
- [ ] CS=0x23 check for non-thunk faults (SEH dispatch in compat mode)
- [ ] Full 32-bit CONTEXT extraction from 64-bit ucontext
- [ ] Performance: upgrade to direct lcall/lret trampolines (avoid signal overhead)

## WASM Compatibility (17/42 tests passing)
- [ ] Fix child PE argv passing — DUMPBIN/LIB/EDITBIN spawn LINK.EXE but child's CRT `__getmainargs` uses stale cached argv
- [ ] Fix CL.EXE child process execution — C1.DLL/C2.DLL spawned code hits EIP out of bounds
- [ ] Fix NMAKE exit code (exits 0 instead of 2 when no makefile found)
- [ ] Fix RC.EXE — needs native DLL dispatch for RCDLL.DLL on WASM
- [ ] Fix zine-host WASI filesystem preopening (guest can't open files via wasmer C API)
- [ ] Implement zine-host JIT block execution end-to-end test

## JIT Pipeline
- [ ] Implement zine-host wasmtime/wasmer C API JIT block execution
- [ ] Browser JS JIT glue (`WebAssembly.instantiate` for compiled blocks)
- [ ] Hot block detection and execution counting
- [ ] JIT invalidation on code page writes

## x86 Interpreter
- [ ] Basic block decoding and caching (major perf bottleneck)
- [ ] Complete x87 FPU instruction execution (currently: decode-only for most ops)
- [ ] Threaded dispatch optimization

## Win32 API Stubs
- [ ] Implement mouse message posting (`src/win32/user32.zig`)

## Registry & Configuration
- [x] ~~Move hardcoded registry settings to external config~~ → `src/win32/advapi32/registry.toml` (TOML, embedded at compile time via `@embedFile`, parsed by sam701/zig-toml)
- [ ] Add per-application registry overrides (e.g., game-specific keys)

## Browser Frontend
- [ ] JS host (`index.html` + `host.js`) with `WebAssembly.instantiate`
- [ ] Canvas/WebGL rendering for GUI apps
- [ ] Virtual filesystem (IndexedDB or preloaded archives)
- [ ] Web Audio API bridge for DirectSound/WinMM
- [ ] `performance.now()` for timestamp support
