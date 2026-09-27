# Zine Memory Layout (WASM)

> **Status: current.** The region sizes below were checked against the constants
> in `src/wasm_main.zig` on 2026-09-27. This file is the canonical description of
> the WASM combined buffer; other documents link here rather than restating it.

This document describes how guest x86 memory is laid out within the WebAssembly linear memory when running in WASM mode.

## Overview

In WASM mode, Zine allocates a single large buffer (combined buffer) to represent the entire 32-bit address space (or a significant portion of it) that the x86 guest expects. This buffer is then mapped into a `GuestMemory` structure which handles address translation.

## Memory Regions

The combined buffer is typically laid out as follows:

```
[PE Image] [Stack] [Thunks] [Heap]
```

### 1. PE Image
- **Location**: Starts at the preferred `ImageBase` of the main executable.
- **Size**: Determined by the `SizeOfImage` field in the PE header.
- **Purpose**: Contains the loaded sections of the main PE executable (.text, .data, .rsrc, etc.).

### 2. Stack
- **Location**: Immediately follows the PE image.
- **Size**: 64 KB (`STACK_SIZE` in `wasm_main.zig`).
- **Purpose**: The guest x86 stack. `ESP` is initialized to the top of this region.

### 3. Thunks
- **Location**: Follows the stack.
- **Size**: 32 KB (`THUNK_RESERVE` in `wasm_main.zig`), pre-filled with `0xCC`.
- **Purpose**: Contains generated x86 code snippets (`CD FE`, `INT 0xFE`, followed by a 4-byte little-endian thunk ID) used to bridge guest x86 calls to host WASM functions (Win32 API stubs).

### 4. Heap
- **Location**: Follows the thunks.
- **Size**: 512 MB (`HEAP_RESERVE` in `wasm_main.zig`; raised from an earlier 32 MB because MSVC `c1.dll` requests ~50 MB+ compiler arenas). An in-process child PE spawned by `_spawnvp` gets its own buffer laid out the same way, with a 128 MB heap and a 64 KB stack (`CHILD_HEAP`, `CHILD_STACK`, `CHILD_THUNK`).
- **Purpose**: The guest heap, used by `HeapAlloc`, `malloc`, and other guest memory allocation functions.

## Address Translation

The `GuestMemory` structure uses a `base` pointer (to the host buffer) and a `base_addr`, the guest virtual address that maps to `base[0]`. In WASM mode `base_addr` is the PE's preferred `ImageBase`, so:

- `Host Address = Buffer Base + (Guest Virtual Address - base_addr)`
- `Guest Virtual Address = base_addr + (Host Address - Buffer Base)`

This allows the x86 interpreter to dereference 32-bit pointers by translating them to indices within the WASM linear memory buffer.
