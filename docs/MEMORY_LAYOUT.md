# Zine Memory Layout (WASM)

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
- **Size**: Default is 64 KB (can be adjusted).
- **Purpose**: The guest x86 stack. `ESP` is initialized to the top of this region.

### 3. Thunks
- **Location**: Follows the stack.
- **Size**: Default is 32 KB.
- **Purpose**: Contains generated x86 code snippets (e.g., `INT 0xFE` followed by a thunk ID) used to bridge guest x86 calls to host WASM functions (Win32 API stubs).

### 4. Heap
- **Location**: Follows the thunks.
- **Size**: Default is 512 MB (`HEAP_RESERVE` in `wasm_main.zig`; raised from an earlier 32 MB because MSVC `c1.dll` requests ~50 MB+ compiler arenas).
- **Purpose**: The guest heap, used by `HeapAlloc`, `malloc`, and other guest memory allocation functions.

## Address Translation

The `GuestMemory` structure uses a `base` pointer (to the host buffer) and a `base_addr` (the preferred guest virtual address).

- `Host Address = Buffer Base + (Guest Virtual Address - ImageBase)`
- `Guest Virtual Address = ImageBase + (Host Address - Buffer Base)`

This allows the x86 interpreter to dereference 32-bit pointers by translating them to indices within the WASM linear memory buffer.
