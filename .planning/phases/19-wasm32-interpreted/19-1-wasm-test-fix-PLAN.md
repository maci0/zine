---
phase: 19-wasm32-interpreted
plan: 19-1-wasm-test-fix
subsystem: interpreter
tags: [wasm32, host-pointer, msvc-cli]
---

# Phase 19-1: Fix WASM32 Interpret Mode MSVC Tests

## Goal
Fix `wasmSpawnHandler` host pointer checks and exit code assertions so all `--wasmtime` and `--wasmer` permutations pass in `test_msvc_cli.sh`.

## Context
During the automated execution of MSVC tests in WASI, `CL.EXE` failed because it spawned `c1` with an empty command name `''`. 

In `wasm_main.zig`, the `wasmSpawnHandler` checks if the translated host pointer `host_argv >= 0x10000` before dereferencing it. On native architectures, host pointers are typically high memory limits. In WebAssembly's 32-bit linear memory, however, WASI `malloc` regularly issues host addresses below `0x10000` (64KB). Because of this strict and incorrect magic number check on the host address, the spawn handler assumes the translated array is a null pointer and completely skips copying both `argv0` and `argv` structures.

The check must appropriately guard against the guest virtual address (`argv_ptr >= 0x10000`) before translating via `trace.addr(argv_ptr)`, thereby safely allowing small host pointer translations. 

## Requirements
1. Remove host pointer `0x10000` limit assertions in `wasm_main.zig` `wasmSpawnHandler`.
2. Clamp `test_msvc_cli.sh` WASM verification exits to `125` to support `wasmtime` bounds.

## Proposed Changes

### `src/wasm_main.zig`
- **[MODIFY]**: `wasmSpawnHandler`
  - Change `if (host_argv >= 0x10000)` to `if (argv_ptr >= 0x10000)` when accessing `argv[0]`.
  - Change `if (host_argv_addr >= 0x10000)` to `if (argv_ptr >= 0x10000)` when iterating `argv` strings.

### `tests/test_msvc_cli.sh`
- **[MODIFY]**: `fail()` / `pass()` asserts
  - If `$IS_WASM` is true, ensure expected failure codes like `128` or `130` are clamped correctly against `$WASM_EXIT_MAX`. Wait, the tests currently expect explicit numbers (e.g. `99` for `REBASE.EXE`). `wasmtime` preserves up to `125`. If any tests expect exit codes > `125`, wrap them to `1` or dynamically assert based on `$WASM_RUNTIME`.

## Verification Plan
### Automated Tests
- Run `tests/test_msvc_cli.sh --wasmtime` and ensure it completes 42/42 zero-failures.
- Run `tests/test_msvc_cli.sh --wasmer` and ensure it completes 42/42 zero-failures.
