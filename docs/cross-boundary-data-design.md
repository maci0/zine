# Cross-Boundary Data Handling: Arguments, Paths, Environment, and Memory Addresses

## Problem Statement

The Win32 PE loader runs PE executables across five execution contexts: **native x86**, **interpret**, **WASM**, **JIT**, and — in the future — **real Windows DLL** (where our stubs compile into actual .dll files that Windows loads natively). Each context has a different relationship between the x86 guest code's address space and the host's.

Currently, DLL stub functions contain ad-hoc workarounds (`trace.addr()`, `trace.c_span()`, `shared.guest_memory` checks, comptime platform guards). This leads to ~90 known bugs, inconsistent behavior across modes, and makes adding new stubs error-prone.

This document proposes a principled architecture where **DLL stub functions are plain functions with no loader dependencies** — they work identically whether called from the interpreter, a WASM thunk, or a real Windows process.

---

## Design Constraint: Real Windows DLL Target

The stubs MUST be compilable as standalone Windows .dll files (drop-in replacements for MSVCRT.dll, KERNEL32.dll, etc.) with zero loader infrastructure. This means:

- **No `trace.addr()`** — doesn't exist on real Windows
- **No `shared.guest_memory`** — doesn't exist on real Windows
- **No `GuestMemory`** — doesn't exist on real Windows
- **No comptime `platform.is_wasm` guards** — the same code runs everywhere
- **No `@import("../../loader/...")`** — stubs can't depend on the loader

Parameters arrive as raw pointers. `@ptrFromInt(param)` just works. Return values are raw pointers. `malloc` returns a host pointer. The stubs are just regular C-callable functions.

**This is the north star: if it wouldn't work as a real Windows DLL, the design is wrong.**

---

## Full Execution Context Matrix

The loader supports (or will support) these execution contexts. Each has a different relationship between the 32-bit guest PE's address space and the host.

### Contexts Where Guest VA == Host Address (stubs receive raw pointers)

| Context | Host | PE | How stubs are called | Notes |
|---------|------|-----|---------------------|-------|
| **Native x86** | x86 Linux | 32-bit | Direct CPU call via IAT | PE mapped at preferred base. Everything just works. |
| **Native x86_64 compat** | x86_64 Linux | 32-bit | 32->64 thunk (see X86_64_NATIVE_EXECUTION.md) | PE + stack + heap in low 4GB via `MAP_32BIT`. Stub receives zero-extended 32-bit ptrs. `@ptrFromInt(u32_param)` works. |
| **Native x86_64** | x86_64 Linux | 64-bit | Direct CPU call (Win64 CC) | Full 64-bit address space. Stubs use `callconv(.Win64)`. |
| **Interpret** | any x86/x64 | 32-bit | `dispatchNativeCall` | `native_linear=true` — guest memory is mmapped at guest VA. `@ptrFromInt(va)` works. |
| **JIT** | any | 32-bit | Compiled blocks call stubs | Same address space as host mode. |
| **Real Windows DLL** | Windows | 32/64-bit | Windows loader + CPU | Same process. Normal DLL. No translation. |

### Contexts Where Guest VA != Host Address (translation required)

| Context | Host | PE | How stubs are called | Translation |
|---------|------|-----|---------------------|-------------|
| **WASM32 + PE32** | wasm32 | 32-bit | INT 0xFE thunk → comptime handler | `combined_buf` at arbitrary WASM linear memory offset. `base_addr` differs from `@intFromPtr(base.ptr)`. Thunk handler translates 32-bit guest VA → 32-bit host ptr via `translateGuestAddr`. |
| **WASM32 + PE64** | wasm32 | 64-bit | INT 0xFE thunk (64-bit IAT) | Guest uses 64-bit VAs but WASM linear memory is 32-bit. The entire guest VA space must fit in 4GB. `translateGuestAddr` truncates 64-bit guest VA to 32-bit offset. Stubs must use `callconv(.Win64)` semantics even though host is wasm32. |
| **WASM64 + PE32** | wasm64 | 32-bit | INT 0xFE thunk → comptime handler | Same as WASM32+PE32 but host pointers are 64-bit. Guest VAs are still 32-bit. `translateGuestAddr` produces a 64-bit host pointer from a 32-bit guest VA. |
| **WASM64 + PE64** | wasm64 | 64-bit | INT 0xFE thunk (64-bit IAT) | Both guest and host are 64-bit. `translateGuestAddr` takes 64-bit guest VA, produces 64-bit host ptr. Large address space available. Most natural WASM pairing for PE64. |
| **Browser** | wasm32/64 | 32/64-bit | Same as WASM | WASM in browser sandbox. Same translation logic. I/O goes through browser APIs instead of WASI. |

### The Pattern

**7 out of 9 contexts pass raw, host-dereferenceable pointers to stubs. Only WASM32/WASM64/Browser differ.** In all three WASM cases, the comptime thunk handler performs the translation BEFORE calling the stub. The stub itself always receives host-accessible pointers.

The translation burden belongs in the **thunk handler** (`castArg` in `env.zig`), not in the stubs.

### Pointer Width Considerations

| Context | Guest ptr width | Host ptr width | `usize` | Thunk reads from guest stack | Stub receives |
|---------|----------------|----------------|---------|------------------------------|---------------|
| Native x86 + PE32 | 32-bit | 32-bit | 32 | N/A (direct call) | 32-bit ptrs |
| Native x86_64 + PE32 | 32-bit | 64-bit | 64 | 32-bit values, zero-extended to 64 | 64-bit ptrs (low 4GB) |
| Native x86_64 + PE64 | 64-bit | 64-bit | 64 | N/A (direct call, Win64 CC) | 64-bit ptrs |
| Interpret + PE32 | 32-bit | 32/64 | 32/64 | u32 from guest stack | host ptr |
| WASM32 + PE32 | 32-bit | 32-bit | 32 | u32, translated via offset | 32-bit host ptr |
| WASM32 + PE64 | 64-bit | 32-bit | 32 | u64 from guest stack, truncated to 32-bit offset | 32-bit host ptr (PE64 must fit in 4GB) |
| WASM64 + PE32 | 32-bit | 64-bit | 64 | u32, translated to 64-bit host ptr | 64-bit host ptr |
| WASM64 + PE64 | 64-bit | 64-bit | 64 | u64, translated via offset | 64-bit host ptr |
| Real Windows DLL | 32 or 64 | Same | Same | N/A (OS loader) | Native ptrs |

**Key insight**: The thunk handler's job is to produce a **host-native pointer** from a **guest-width value**. This involves two operations:
1. **Width conversion**: Guest u32 → host usize (zero-extend if host is 64-bit)
2. **Address translation**: Guest VA → host address (offset arithmetic, only on WASM)

On native (all variants), only step 1 applies (and it's a no-op when widths match).
On WASM, both steps apply.

**WASM32 + PE64 constraint**: A 64-bit PE has 64-bit pointers, but WASM32 linear memory is limited to 4GB. The PE's entire address space must fit within 4GB. This is a hard limit — PE64 executables with `ImageBase` above 4GB cannot run on WASM32. WASM64 has no such limit.

**x86_64 compat mode**: Structurally identical to WASM64+PE32 in terms of width mismatch (32-bit guest, 64-bit host) but WITHOUT address translation (guest VAs are real host addresses in low 4GB).

---

## The Architecture: Translation at the Boundary, Not in the Stubs

### Layer 1: Stub Functions (DLL implementations)

Stub functions are **pure, platform-independent C-callable functions**. They receive host-accessible pointers. They call standard library functions. They return host pointers. They know nothing about guest VAs, interpreters, or WASM.

```zig
// src/win32/msvcrt/path.zig
// This function works identically on all platforms, including as a real Windows DLL.

pub fn splitpath(path: [*:0]const u8, drive: ?[*]u8, dir: ?[*]u8, fname: ?[*]u8, ext: ?[*]u8) callconv(.c) void {
    const s = std.mem.span(path);
    // ... parse drive, dir, fname, ext ...
    // Write directly to output pointers — they're host-accessible.
    if (drive) |d| { @memcpy(d[0..drive_len], s[0..drive_len]); d[drive_len] = 0; }
    // ...
}
```

**Rules for stub functions:**
1. Parameters that are pointers use pointer types (`[*]u8`, `*const T`, `?*anyopaque`)
2. Parameters that are integers use integer types (`i32`, `u32`, `usize`)
3. NO `trace.addr()`. NO `@import("shared.zig")`. NO comptime platform checks.
4. For memory allocation, call a provided allocator or standard `malloc`/`free`
5. For file I/O, call through a file abstraction (see Layer 2)

### Layer 2: Platform Abstraction (file I/O, memory, paths)

Stubs that need to interact with the host (file system, memory allocation, console) go through thin abstraction functions. These abstractions handle Win32-to-POSIX path conversion on non-Windows hosts.

```zig
// src/win32/host_io.zig
// Platform-neutral file operations. On real Windows, these are pass-through.
// On Linux/WASM, they convert Win32 paths to POSIX.

pub fn openFile(win32_path: [*:0]const u8, flags: u32) i32 {
    if (comptime builtin.os.tag == .windows) {
        return windows.CreateFileA(win32_path, ...);
    } else {
        var posix_buf: [1024]u8 = undefined;
        const len = path_utils.win32ToPosix(std.mem.span(win32_path), &posix_buf);
        posix_buf[len] = 0;
        return posix_open(@ptrCast(&posix_buf), flags);
    }
}
```

On **real Windows**, this compiles to a direct `CreateFileA` call (zero cost).
On **Linux/WASM**, it converts the path first.

### Layer 3: Thunk Handler (WASM-only address translation)

The thunk handler in `env.zig` is responsible for translating ALL pointer parameters from guest VAs to host addresses BEFORE calling the stub function. The stub never sees guest VAs.

```zig
// src/loader/env.zig — comptime thunk handler (WASM and x86_64 compat)
// `GuestWord` is u32 for PE32, u64 for PE64.
fn castArg(comptime T: type, val: GuestWord, cpu: *Cpu) T {
    return switch (@typeInfo(T)) {
        // Pointers: translate guest VA → host address
        .pointer => @ptrFromInt(translateGuestAddr(val, cpu)),
        .optional => |opt| if (@typeInfo(opt.child) == .pointer)
            (if (val == 0) null else @ptrFromInt(translateGuestAddr(val, cpu)))
        else
            @bitCast(val),
        // Integers: pass through (not pointers)
        .int => @truncate(val),
        else => @bitCast(val),
    };
}

fn translateGuestAddr(val: GuestWord, cpu: *Cpu) usize {
    if (val == 0) return 0;
    if (comptime platform.is_native) return val;  // Native: identity
    // WASM: offset translation
    const offset = @as(usize, val) -% @as(usize, cpu.memory.base_addr);
    if (offset >= cpu.memory.base.len) return val;  // Out of range passthrough
    return @intFromPtr(cpu.memory.base.ptr) + offset;
}
```

This generalizes to PE64: `GuestWord` becomes `u64`, `base_addr` becomes `u64`, and the offset arithmetic uses 64-bit values. On WASM32+PE64, the result is truncated to 32-bit (must fit in 4GB). On WASM64+PE64, no truncation.

**The key insight**: Because stub functions use **pointer types** (not `usize`) for pointer parameters, `castArg` can distinguish pointers from integers at comptime and translate only pointers. There's no ambiguity. No double-translation. No manual `trace.addr()`.

### Layer 4: Registration (connecting stubs to the loader)

```zig
// src/win32/msvcrt.zig
pub fn register(environment: *Environment) !void {
    const m = "MSVCRT.dll";
    // The function signature tells the thunk handler which params are pointers:
    try env.addBuiltinExportComptime(m, "_splitpath", path.splitpath);
    //                                                  ^^^^^^^^^^^^^^^^^
    //  fn([*:0]const u8, ?[*]u8, ?[*]u8, ?[*]u8, ?[*]u8) — all pointer types
    //  The thunk handler auto-translates all of them on WASM. Zero manual work.
}
```

---

## What Changes in Stub Signatures

The core change: **stop using `usize` for pointer parameters**. Use actual pointer types.

### Before (current, broken on WASM without workarounds):
```zig
pub fn splitpath(path_ptr: usize, drive: usize, dir: usize, fname: usize, ext: usize) callconv(.c) void {
    const path = trace.c_span(path_ptr);                    // manual translation
    @memcpy(@as([*]u8, @ptrFromInt(trace.addr(drive)))...); // manual translation
    @memcpy(@as([*]u8, @ptrFromInt(trace.addr(dir)))...);   // manual translation
    // ... 5 trace.addr() calls, each one could be forgotten
}
```

### After (works everywhere, including as a real Windows DLL):
```zig
pub fn splitpath(path: [*:0]const u8, drive: ?[*]u8, dir: ?[*]u8, fname: ?[*]u8, ext: ?[*]u8) callconv(.c) void {
    const s = std.mem.span(path);           // just works — pointer is already host-accessible
    if (drive) |d| { @memcpy(d[0..n], s[0..n]); d[n] = 0; }  // just works
    if (dir)   |d| { @memcpy(d[0..n], s[0..n]); d[n] = 0; }  // just works
    // No trace.addr(). No platform checks. No loader dependencies.
}
```

The comptime thunk handler in `castArg` sees `[*:0]const u8` and automatically calls `translateGuestAddr`. On native, `translateGuestAddr` is a no-op (returns the value unchanged). On real Windows, there's no thunk handler at all — the CPU passes real pointers.

---

## The Four Data Categories Under This Architecture

### 1. Memory Addresses

| Context | Who translates? | Stub sees? |
|---------|----------------|------------|
| Native x86 | Nobody (identity) | Host pointer (32-bit) |
| Native x86_64 compat | 32→64 thunk (zero-extends) | Host pointer (64-bit, low 4GB) |
| Native x86_64 (PE64) | Nobody (identity) | Host pointer (64-bit) |
| Interpret | Nobody (native_linear) | Host pointer |
| WASM32 | Thunk handler (`castArg`) | Host pointer (32-bit) |
| WASM64 | Thunk handler (`castArg`) | Host pointer (64-bit) |
| JIT | Nobody (same address space) | Host pointer |
| Real Windows DLL | Nobody (same process) | Host pointer |
| Browser | Thunk handler (`castArg`) | Host pointer |

**Stubs never translate.** The thunk handler (or architecture-specific thunk) is the single point of translation.

### 2. Paths

All stub functions operate on **Win32 paths**. They receive `C:\foo\bar` from the guest and pass it through to Layer 2 (`host_io`) which converts to POSIX on non-Windows hosts.

On **real Windows**, `host_io` is a pass-through — Win32 paths are native.

| Function | Receives | Passes to host_io | host_io does |
|----------|----------|-------------------|--------------|
| `_access` | `C:\foo\bar` | `C:\foo\bar` | `win32ToPosix` on Linux, pass-through on Windows |
| `fopen` | `C:\foo\bar` | `C:\foo\bar` | Same |
| `CreateFileA` | `C:\foo\bar` | `C:\foo\bar` | Same |
| `_getcwd` | N/A (output) | Reads host CWD | `posixToWin32` on Linux, pass-through on Windows |

### 3. Arguments (argv, envp)

On real Windows, the CRT handles argv/envp natively. On our loader, we set up `global_argv` from host args (with POSIX-to-Win32 conversion) and mirror them to guest memory via `ensureGuestArgs`.

**Stubs don't care about this.** `__getmainargs` receives pointer params, writes to them, done. The thunk handler translates the pointers on WASM. On native/Windows, the pointers are direct.

### 4. Environment

`getenv(name)` receives a `[*:0]const u8` name, searches the environment, returns a `[*:0]u8` value. The return value must be a host-accessible pointer.

On WASM, the return pointer needs to be in guest memory. This is handled by `raw_alloc` which allocates from guest heap on WASM. The return type `?[*:0]u8` ensures the thunk handler converts it back to a guest VA via `toU32`.

---

## Static Data Returns (the `_errno` / `localtime` problem)

Functions like `_errno()` return `*i32` — a pointer to a static variable. On real Windows, this is a host pointer and the caller dereferences it directly. On WASM, the x86 code can't dereference host pointers.

### Solution: Pre-allocated Guest Slots

During CRT initialization (in `ensureGuestGlobals`), allocate guest memory slots for all static return values. The `_errno` stub returns a pointer to the guest slot. On native/Windows, the guest slot IS a host variable (same address space). On WASM, it's in the `combined_buf`.

```zig
// This works on all platforms including real Windows DLL:
var errno_val: i32 = 0;
pub fn errno() callconv(.c) *i32 {
    return &errno_val;
}
```

On WASM, the thunk handler's `toU32` converts `*i32` return to a 32-bit guest VA. But `&errno_val` is a host address, not a guest VA. The thunk handler needs to handle this: either allocate `errno_val` in guest memory, or intercept the return and convert.

**Best approach for WASM**: The guest globals block (from `ensureGuestGlobals`) contains a slot for errno. The `_errno` registration uses a WASM-specific wrapper that returns the guest slot address. The stub itself remains pure:

```zig
// Pure stub (works as Windows DLL):
pub fn errno() callconv(.c) *i32 {
    return &errno_val;
}

// Registration:
if (comptime platform.is_wasm) {
    // WASM: register a wrapper that returns the guest errno slot
    try env.addBuiltinExportComptime(m, "_errno", wasm_errno_wrapper);
} else {
    // Native/Windows: register the pure function directly
    try env.addBuiltinExportComptime(m, "_errno", errno);
}
```

This keeps the stub pure while handling the WASM special case at the registration layer.

---

## API Boundaries

### Boundary 1: Host CLI -> Loader Setup

| Data | Format In | Conversion | Format Out |
|------|-----------|------------|------------|
| exe path | POSIX (`/home/.../CL.EXE`) | `posixToWin32` | Win32 (`Z:\home\...\CL.EXE`) |
| app args | POSIX paths | `posixToWin32` where needed | Win32 paths |
| env PATH | POSIX (`:` separated) | Split on `:`, convert each, join with `;` | Win32 (`;` separated) |
| exe dir | POSIX dirname | `posixToWin32` | Win32 (`Z:\...\Bin\`) |
| CWD | POSIX (`/home/user/work`) | `posixToWin32` | Win32 (`Z:\home\user\work`) |

**Owner**: `main.zig` / `wasm_main.zig` at startup. Done once.

### Boundary 2: Loader -> Guest Memory (WASM only)

| Data | Source (host) | Destination (guest) |
|------|---------------|---------------------|
| argv strings | `global_argv[i]` (host ptrs) | `combined_buf` (guest VAs) |
| envp strings | `global_envp[i]` (host ptrs) | `combined_buf` (guest VAs) |
| CRT data (_iob, etc.) | Host statics | `combined_buf` (guest VAs) |

**Owner**: `ensureGuestArgs()`, `relocateDataExports()`. Irrelevant on real Windows.

### Boundary 3: Guest x86 -> Stub Function (Thunk Boundary)

| Direction | Data type | Native | WASM | Real Windows |
|-----------|-----------|--------|------|-------------|
| In: pointer param | `[*]u8`, `*T` | Pass through | `translateGuestAddr` | Pass through |
| In: integer param | `i32`, `u32` | Pass through | Pass through | Pass through |
| Out: pointer return | `*T`, `?[*]u8` | Pass through | `toU32` (truncate) | Pass through |
| Out: integer return | `i32`, `u32` | In EAX | `cpu.eax =` | In EAX |

**Owner**: Thunk handler in `env.zig` (WASM), CPU calling convention (native/Windows).

### Boundary 4: Stub -> Host File System

| Data | Source (stub) | Conversion | Destination (host) |
|------|---------------|------------|--------------------|
| File path | Win32 (`C:\foo`) | `host_io.openFile` | POSIX on Linux, native on Windows |
| CWD query | N/A | `host_io.getCwd` | POSIX -> Win32 on Linux, native on Windows |
| Path search | Win32 path list (`;` sep) | Each component via `host_io` | POSIX on Linux |

**Owner**: `host_io.zig` (new module) or `posix_fs.zig`. The only place path conversion happens.

### Boundary 5: Parent PE -> Child PE (Spawn)

| Data | Source | Owner | Destination |
|------|--------|-------|-------------|
| cmdname | Parent guest string | `_spawnvp` reads from guest | Spawn handler |
| argv | Parent guest VA array | Spawn handler reads + translates | Child `global_argv` |
| env | `global_envp` (host ptrs) | Inherited directly | Child `global_envp` |
| Child argv | Host strings | `ensureGuestArgs` | Child guest VAs |

**Owner**: `wasmSpawnHandler` (WASM), `std.process.Child` (native).

---

## Caveats

### 1. The `usize` Ambiguity

Some existing stubs use `usize` for pointer parameters because Win32 APIs use `DWORD_PTR` or `LPARAM`. When migrating to pointer types, these need case-by-case analysis:
- `LPARAM` (window message data): sometimes a pointer, sometimes an integer — needs a wrapper
- `HANDLE` (opaque values): not real pointers, use `usize` (no translation needed)
- `HMODULE`: same as HANDLE
- `FARPROC` (function pointer returned by GetProcAddress): guest code address, NOT a host function pointer on WASM

### 2. COM/DirectX VTables

COM objects have vtables of function pointers. On WASM, these must be guest thunk VAs. This requires special handling at the registration layer (not in the stubs). The stubs themselves return `*ISomeInterface` (host pointer); the WASM wrapper converts the vtable.

### 3. Callback Functions

Some APIs take callback function pointers (e.g., `EnumWindows(callback, lparam)`). On WASM, the callback is a guest x86 address. The stub can't call it directly. The WASM registration layer must wrap the stub to intercept callbacks and route them through the interpreter. On x86_64 compat mode, callbacks are 32-bit code addresses that need a 64→32 re-entry trampoline.

### 4. Memory-Mapped Files

`MapViewOfFileEx` returns a pointer to mapped data. On WASM, this must be in guest memory. On x86_64 compat mode, the mapping must be in the low 4GB (via `MAP_32BIT`). Handle at the registration/wrapper layer, not in the stub.

### 5. Pointer Width Mismatches (x86_64 compat mode)

When running a 32-bit PE on a 64-bit host:
- Guest code uses 32-bit pointers (`ESP`, `EBP`, all registers are 32-bit)
- Stubs are compiled as 64-bit code with 64-bit `usize`
- The 32→64 thunk must zero-extend 32-bit guest pointers to 64-bit
- Return values must be truncated back to 32-bit for `EAX`
- This is structurally identical to WASM64 (32-bit guest, 64-bit host) but without address translation — just width extension

### 6. WASM64 Guest VA Range

On WASM64, `usize` is 64-bit but guest VAs are 32-bit. The `translateGuestAddr` function takes a `u32` and returns a `usize` (64-bit). The `toU32` function truncates the 64-bit return value back to 32-bit for `cpu.eax`. This works correctly as long as:
- All guest VAs fit in 32 bits (they do — the PE is 32-bit)
- All return pointers to guest code are 32-bit guest VAs (not 64-bit host pointers)
- `raw_alloc` on WASM64 returns addresses within the 32-bit guest VA range

### 7. Real Windows DLL Calling Convention

When compiled as a real Windows DLL:
- 32-bit DLLs use `callconv(.Stdcall)` / `callconv(.C)` — matches our `w32cc.WINAPI`
- 64-bit DLLs use `callconv(.Win64)` — we need to switch `WINAPI` definition
- The `calling_convention.zig` already handles this: `WINAPI = if (arch == .x86 or .x86_64) .winapi else .c`
- For real Windows, `.winapi` resolves to `.Stdcall` (32-bit) or `.Win64` (64-bit) automatically

---

## Related Documents

- **[X86_64_NATIVE_EXECUTION.md](X86_64_NATIVE_EXECUTION.md)** — Details on the 32→64 mode switching, thunk mechanism, and MAP_32BIT memory allocation needed for running 32-bit PEs on x86_64 hosts. The thunk design described there is structurally similar to the WASM thunk (both read 32-bit args and call 64-bit stubs), which reinforces the "translate at boundary, not in stubs" principle.

## Detailed Implementation Plan

### Phase 0: Preparation (no behavioral changes)

- [ ] **Audit all stub signatures**: List every stub function across all `src/win32/**/*.zig` files that uses `usize` for a parameter that is semantically a pointer. Output: spreadsheet/list mapping `file:line → param_name → should_be_type`.
- [ ] **Audit all `trace.addr()` call sites**: List every `trace.addr()` call in stub functions (not in loader/thunk code). These will ALL be removed in Phase 2.
- [ ] **Audit all `@intFromPtr(&static)` returns**: List every stub that returns a host address to a static variable. These need WASM wrappers.
- [ ] **Create `src/win32/host_io.zig`**: Empty module with the future API surface defined as function signatures (no implementations yet).
- [ ] **Write regression test list**: Document current test results for native (42/42), interpret (42/42), WASM (22/38) as the baseline.

### Phase 1: Create the host I/O abstraction layer [DONE]

Goal: All file/path operations go through `host_io.zig`. Stubs stop calling `path_utils` or `std.fs` directly.

- [x] Implement `host_io.openFile(win32_path: [*:0]const u8, flags: u32, mode: u32) i32`
  - On Windows: pass-through to `CreateFileA` / `_open`
  - On Linux/WASM: `win32ToPosix()` then `posix_open()`
  - Includes case-insensitive filename retry
- [ ] Implement `host_io.accessFile(win32_path: [*:0]const u8, mode: i32) i32`
  - Same conversion pattern
- [ ] Implement `host_io.getCwd(buf: [*]u8, max: usize) usize`
  - On Windows: pass-through to `GetCurrentDirectoryA`
  - On Linux/WASM: `std.process.getCwd()` then `posixToWin32()`
  - Always returns Win32 format with drive letter
- [ ] Implement `host_io.getFullPath(rel: [*:0]const u8, buf: [*]u8, max: usize) usize`
  - Actually resolves relative paths against CWD
  - Returns Win32 format
- [ ] Implement `host_io.statFile(win32_path: [*:0]const u8) ?StatResult`
- [ ] Implement `host_io.deleteFile(win32_path: [*:0]const u8) bool`
- [ ] Implement `host_io.findFirst(win32_pattern: [*:0]const u8) FindHandle`
- [ ] Implement `host_io.findNext(handle: FindHandle) ?FindData`
- [ ] Migrate `_access` to use `host_io.accessFile` — verify native tests still pass
- [ ] Migrate `fopen` to use `host_io.openFile` — verify
- [ ] Migrate `CreateFileA` to use `host_io.openFile` — verify
- [ ] Migrate `_getcwd` to use `host_io.getCwd` — verify
- [ ] Migrate `_fullpath` to use `host_io.getFullPath` — verify
- [ ] Migrate `_stat` to use `host_io.statFile` — verify
- [ ] Migrate `_searchenv` to use `host_io.accessFile` for probing — verify
- [ ] Migrate `_findfirst`/`_findnext` to use `host_io.findFirst`/`findNext` — verify
- [ ] Run full test suite: native 42/42, interpret 42/42, WASM >= 22

### Phase 2: Convert stub signatures from `usize` to pointer types [DONE]

Goal: Stubs use `[*]u8`, `*T`, `?[*:0]const u8` instead of `usize`. The comptime thunk handler auto-translates pointer types. All `trace.addr()` calls removed from stubs.

**Sub-phase 2a: Re-enable `usize` auto-translation in `castArg`**
- [ ] In `src/loader/env.zig` `castArg`, re-add `usize` translation: `if (T == usize and comptime !platform.is_native) break :blk translateGuestAddr(val, cpu);`
- [ ] This makes both mechanisms active temporarily (stubs still have `trace.addr()`)
- [ ] Run tests — may have double-translation issues. Note which tests break.

**Sub-phase 2b: Convert MSVCRT stubs (highest impact)**
- [ ] `msvcrt/path.zig`: `splitpath`, `makepath`, `fullpath`, `searchenv`, `getcwd`, `tempnam`, `mktemp`
  - Change `path_ptr: usize` → `path: [*:0]const u8`
  - Change `drive: usize` → `drive: ?[*]u8`
  - Remove all `trace.addr()` and `trace.c_span()` calls
  - Use `std.mem.span(path)` instead of `trace.c_span(path_ptr)`
- [ ] `msvcrt/file.zig`: `access`, `sopen`, `read`, `write`, `stat`, `fstat`, `fileno`
  - Same pattern
- [ ] `msvcrt/string.zig`: `strcpy`, `strncpy`, `strcmp`, `strlen`, etc.
  - All `s1_ptr: usize` → `s1: [*:0]const u8`
- [ ] `msvcrt/fmt.zig`: `printf`, `sprintf`, `sscanf`, etc.
  - Format string: `fmt_ptr: usize` → `fmt: [*:0]const u8`
  - Buffer: `buf_ptr: usize` → `buf: [*]u8`
- [ ] `msvcrt/mem.zig`: `memcpy`, `memset`, `memmove`
  - `dest_ptr: usize` → `dest: [*]u8`
- [ ] `msvcrt/io.zig`: `fopen`, `fclose`, `fread`, `fwrite`, `fgets`, `fprintf`
  - File pointers, buffers: pointer types
- [ ] `msvcrt/time.zig`: `time`, `localtime`, `ctime`, `ftime`, `mktime`
  - Output pointers: `*i32`, `*Tm`, etc.
- [ ] `msvcrt/process.zig`: `getmainargs`, `getenv`, `putenv`, `spawnvp`
  - String params: `[*:0]const u8`
  - Output pointer params: `*i32`, `*u32`
- [ ] `msvcrt/misc.zig`: `errno`, `setlocale`, `qsort`, etc.
- [ ] Run test suite after each file. Fix any regressions immediately.

**Sub-phase 2c: Convert KERNEL32 stubs**
- [ ] `kernel32/file.zig`: `CreateFileA`, `ReadFile`, `WriteFile`, `GetFileSize`, `SetFilePointer`, `MapViewOfFileEx`, `GetDiskFreeSpaceA`
- [ ] `kernel32/process.zig`: `LoadLibraryA`, `GetProcAddress`, `GetModuleHandleA`, `GetModuleFileNameA`, `GetStartupInfoA`, `GetEnvironmentVariableA`, `CreateProcessA`
- [ ] `kernel32/mem.zig`: `VirtualAlloc`, `HeapAlloc`, `LocalAlloc`
- [ ] `kernel32/console.zig`: `GetConsoleScreenBufferInfo`, `ReadConsoleW`, `WriteConsoleA`
- [ ] `kernel32/sync.zig`: `InterlockedIncrement`, `InterlockedExchange`, `InitializeCriticalSection`
- [ ] `kernel32/sysinfo.zig`: `GetSystemInfo`, `GlobalMemoryStatusEx`
- [ ] `kernel32/path.zig`: `GetCurrentDirectoryA`, `GetWindowsDirectoryA`, `GetFullPathNameA`
- [ ] `kernel32/process.zig`: `GetModuleFileNameA`

**Sub-phase 2d: Convert remaining DLL stubs**
- [x] `advapi32/registry.zig`, `advapi32/security.zig`, `advapi32/services.zig`
- [x] `user32/window.zig`, `user32/message.zig`, `user32/resource.zig`
- [x] `gdi32/drawing.zig`, `gdi32/object.zig`
- [x] `rpcrt4.zig`, `shell32.zig`, `ole32/*.zig`, `comdlg32/*.zig`
- [x] All remaining DLL stubs

**Sub-phase 2e: Remove `usize` auto-translation**
- [ ] In `castArg`, remove the `usize` → `translateGuestAddr` code added in 2a
- [ ] Now ONLY pointer types are translated (the intended final state)
- [ ] `usize` params that are truly integer values pass through unchanged
- [ ] `usize` params that are HANDLE values pass through unchanged (correct — HANDLEs are opaque, not dereferenceable)
- [ ] Run full test suite: verify native 42/42, interpret 42/42, WASM >= 22

### Phase 3: Fix static data returns for WASM [DONE]
(COM/DirectX vtable guest allocation deferred to future feature — not needed for CLI tests)

Goal: Functions that return `&host_static` work on WASM by pre-allocating guest memory.

- [ ] Create `src/win32/guest_statics.zig`: module that pre-allocates guest memory slots for all static return values during CRT init
- [ ] Slots needed:
  - `errno_slot`: 4 bytes (i32)
  - `doserrno_slot`: 4 bytes (u32)
  - `pgmptr_slot`: 4 bytes (pointer to string)
  - `argc_slot`: 4 bytes (i32)
  - `argv_slot`: 4 bytes (pointer to argv array)
  - `environ_slot`: 4 bytes (pointer to envp array)
  - `fmode_slot`: 4 bytes (u32)
  - `commode_slot`: 4 bytes (u16, padded)
  - `localtime_slot`: sizeof(struct tm) bytes
  - `ctime_slot`: 26 bytes
  - `asctime_slot`: 26 bytes
  - `setlocale_slot`: 256 bytes
- [ ] On WASM: allocate from guest heap during `ensureGuestGlobals`
- [ ] On native: use host static variables (zero-cost)
- [ ] Register WASM wrappers for these functions at the registration layer
- [ ] Pure stubs (`errno`, `localtime`, etc.) remain unchanged — they return `&host_static`
- [ ] WASM wrappers sync host static → guest slot and return guest VA
- [ ] Run tests

### Phase 4: PE64 support [PARTIALLY BLOCKED]

Goal: Support running 64-bit Windows PE executables (PE32+ format).

**Status**: PARTIALLY BLOCKED.
- **Native x86_64**: Feasible — host CPU runs code directly. Only needs PE32+ parser,
  Win64 calling convention thunks, 64-bit IAT patching. No interpreter needed.
- **Interpret/WASM**: BLOCKED — requires x86_64 instruction decoder, 64-bit CPU registers,
  64-bit GuestMemory. Multi-month effort.

**Prerequisites for native PE64:**
- [ ] PE32+ parser — IMAGE_NT_HEADERS64, IMAGE_OPTIONAL_HEADER64, 64-bit relocations
- [ ] Win64 calling convention — RCX/RDX/R8/R9 parameter passing, 32-byte shadow space
- [ ] 64-bit IAT patching — IMAGE_THUNK_DATA64 (8-byte entries)

**Additional prerequisites for interpret/WASM PE64 (BLOCKED):**
- [ ] x86_64 instruction decoder — REX prefixes, 64-bit operand sizes, RIP-relative addressing
- [ ] 64-bit CPU registers — RAX/RBX/.../R15 as u64, RIP/RSP as u64
- [ ] 64-bit GuestMemory — u64 base_addr, 64-bit read/write operations

**Phase 4 thunk handler changes (after prerequisites):**
- [ ] Define `GuestWord` type: `u32` for PE32, `u64` for PE64
- [ ] Update `thunkHandler` to read `GuestWord`-sized values from guest stack
- [ ] Update `toU32` → `toGuestWord`: return value sized to guest pointer width
- [ ] Update IAT patching for 64-bit IAT entries (`IMAGE_THUNK_DATA64`)
- [ ] Test with a simple PE64 executable

**Design note**: The stub function signatures from Phases 1-3 already use proper
pointer types (`[*:0]const u8`, `*T`, etc.) which naturally scale to 64-bit.
The `castArg`/`translateGuestAddr` infrastructure works with `usize` return values
which are 64-bit on 64-bit hosts. No stub changes needed — only the thunk handler
and interpreter need PE64 awareness.

See also: [X86_64_NATIVE_EXECUTION.md](X86_64_NATIVE_EXECUTION.md) for native x86_64 execution design.

### Phase 5: x86_64 compat mode thunks [TODO]

Goal: Run 32-bit PEs natively on x86_64 Linux hosts using CPU compatibility mode
(CS segment switching between 32-bit and 64-bit mode).

**Status**: TODO. Requires implementing the mode-switching trampolines described
in [X86_64_NATIVE_EXECUTION.md](X86_64_NATIVE_EXECUTION.md). This is independent
of PE64 support — it runs 32-bit PEs on a 64-bit host.

**Design note**: The stub functions from Phases 1-3 already work for this case.
The 32→64 thunk reads 32-bit args from the guest stack and zero-extends them to
64-bit. Since stubs use pointer types (not usize), `@ptrFromInt` on zero-extended
32-bit values works correctly (addresses are in low 4GB via MAP_32BIT).

- [ ] Implement `x86/native_thunks_64.zig` — trampoline pool in low 4GB memory
- [ ] 32→64 mode switch via `lcall $0x33, $ThunkDispatcher_64`
- [ ] ThunkDispatcher reads 32-bit args, calls 64-bit Zig stubs
- [ ] Return value truncated to 32-bit for EAX
- [ ] 64→32 mode switch back via `lret` to resume guest code
- [ ] Allocate guest stack/heap with MAP_32BIT
- [ ] Test with a 32-bit PE on x86_64 Linux

### Phase 6: Real Windows DLL compilation [DONE]

Goal: ALL stubs compile as standalone Windows DLLs.

**Status**: DONE. 36 DLLs cross-compile into `zig-out/bin/dll/`.

**Build commands**:
- `zig build -Ddll=true` — build all 36 DLLs
- `zig build -Ddll=msvcrt` — build a single DLL
- `zig build -Dexternal-stubs=true` — slim binary (4.8 MB vs 10.5 MB) that loads DLLs from disk

**What was done**:
- [x] DLL sources in `src/dll/`, using `@import("win32")` named module from `src/win32_dll_api.zig`
- [x] `src/dll/dll_common.zig` — shared DllMain entry point
- [x] All 36 stub modules build as Windows PE DLLs (x86-windows target)
- [x] Embedded/external compilation modes via `-Dexternal-stubs` build option
- [x] `--external` mode in test matrix (`tests/test_msvc_cli.sh`)
- [x] Renderer/GUI imports guarded with `comptime os.tag != .windows` for DLL builds
- [x] `host_io.fileFromFd()` for Windows HANDLE compatibility

**DLLs**: msvcrt, kernel32, advapi32, user32, gdi32, shell32, ole32, oleaut32,
comctl32, comdlg32, winmm, ntdll, shlwapi, version, imagehlp, imm32, setupapi,
winspool, mss32, rpcrt4, ws2_32, wsock32, d3d8, ddraw, dinput, dinput8, dsound,
mspdb60, msvcp60, rcdll, mfc42, cards, icmp, nddeapi, vdmdbg, mag_hook
- These need `host_io.zig` to abstract the HANDLE/fd difference

**Future**: Add more DLLs as their stubs are made platform-independent. Test with Wine.

---

## Appendix: Source File Audit

Results of auditing every `src/win32/` file for code that violates the "stubs must be pure" principle.

### A. Files with `trace.addr()` calls (233 total — all must be removed in Phase 2)

| File | Count | Functions affected |
|------|-------|--------------------|
| `msvcrt/string.zig` | 36 | strcpy, strncpy, strcmp, strcat, strncmp, stricmp, strpbrk, strtoul, strtol, itoa, wcslen, wcscpy, wcscat, wcscmp, wcstol, mbccpy, etc. |
| `advapi32/registry.zig` | 35 | RegOpenKeyExA, RegQueryValueExA, writeRegString, writeRegDword, RegCreateKeyExA, RegEnumKeyExA, RegQueryInfoKeyA, RegOpenKeyExW, writeRegStringW, RegCreateKeyExW, etc. |
| `msvcrt/fmt.zig` | 23 | x86_vsnprintf, printf_impl, vprintf, vfprintf, vsnprintf, snprintf_impl, swprintf_impl, sprintf_impl, puts, fputs, sscanf_impl |
| `gdi32/object.zig` | 18 | CreateDIBSection, GetObjectA, CreateBrushIndirect, CreatePenIndirect |
| `kernel32/file.zig` | 15 | GetFileInformationByHandle, SetFilePointer, ReadFile, WriteFile, CreateFileA, MapViewOfFileEx, GetDiskFreeSpaceA, GetFileSize |
| `msvcrt/path.zig` | 13 | splitpath, makepath, fullpath, searchenv, getcwd |
| `advapi32/security.zig` | 12 | OpenProcessToken, GetTokenInformation, EqualSid, GetLengthSid, GetSecurityDescriptorOwner, AllocateAndInitializeSid |
| `user32/message.zig` | 9 | PeekMessageA, DispatchMessageA, GetMessageA (all MSG pointer access) |
| `msvcrt/file.zig` | 9 | read, fileno, stat, fstat |
| `kernel32/console.zig` | 8 | GetConsoleMode, GetConsoleScreenBufferInfo, ReadConsoleW, WriteConsoleW, WriteConsoleA |
| `advapi32/services.zig` | 8 | GetUserNameA, AccessCheck, ControlService, QueryServiceStatus |
| `gdi32/drawing.zig` | 7 | blitDIBToBufferAt, SetDIBitsToDevice, MoveToEx, Polygon, Polyline |
| `msvcrt/time.zig` | 6 | time, localtime, ctime, ftime, mktime, time64 |
| `msvcrt/io.zig` | 6 | fgets, fwprintf, fprintf_impl |
| `msvcrt/mem.zig` | 4 | memset, memcpy |
| `kernel32/sysinfo.zig` | 4 | GetProcessAffinityMask, GetSystemInfo, GlobalMemoryStatusEx |
| `kernel32/process.zig` | 4 | GetStartupInfoA, GetEnvironmentVariableA, GetModuleFileNameA |
| `user32/window.zig` | 3 | RegisterClassA, SystemParametersInfoA |
| `msvcrt/process.zig` | 3 | getmainargs output ptrs |
| `msvcrt/misc.zig` | 3 | errno (guest memory allocation) |

### B. Files with `trace.c_span()` calls (159 total — most become `std.mem.span()`)

| File | Count | Notes |
|------|-------|-------|
| `msvcrt/string.zig` | 21 | All string comparison/search functions |
| `kernel32/process.zig` | 19 | LoadLibraryA, GetProcAddress, GetModuleHandleA, etc. |
| `kernel32/locale.zig` | 15 | LCMapStringA, FormatMessageA, etc. |
| `kernel32/file.zig` | 13 | CreateFileA, FindFirstFileA, etc. |
| `kernel32/profile.zig` | 12 | GetProfileStringA, WriteProfileStringA |
| `msvcrt/process.zig` | 10 | getenv, putenv, spawnvp |
| `msvcrt/path.zig` | 10 | splitpath, searchenv, makepath |
| `user32/window.zig` | 6 | RegisterClassA, CreateWindowExA |
| `advapi32/registry.zig` | 6 | RegOpenKeyExA, RegQueryValueExA |

### C. Functions returning `@intFromPtr(&static)` (18 total — need WASM wrappers)

| File | Function | Static variable | Guest slot needed |
|------|----------|-----------------|-------------------|
| `msvcrt/misc.zig:115` | `errno()` | `msvcrt_errno_val` | 4 bytes (i32) |
| `msvcrt/misc.zig:131` | `setlocale()` | `setlocale_buf` | 256 bytes |
| `msvcrt/process.zig:67` | `p_argc()` | `global_argc` | 4 bytes (i32) |
| `msvcrt/process.zig:80` | `p_argv()` | `global_argv` | 4 bytes (ptr) |
| `msvcrt/process.zig:526` | `p_pgmptr()` | `msvcrt_pgmptr` | 4 bytes (ptr) |
| `msvcrt/process.zig:615` | `p_fmode()` | `msvcrt_fmode` | 4 bytes (u32) |
| `msvcrt/process.zig:623` | `p_commode()` | `msvcrt_commode` | 4 bytes (u16) |
| `msvcrt/time.zig:198` | `asctime()` | `asctime_buf` | 32 bytes |
| `msvcrt/time.zig:216` | `localtime64()` | `tm_buf` | 64 bytes |
| `msvcrt/file.zig:276` | `acrt_iob_func()` | `msvcrt_iob[i]` | 96 bytes (3 FILEs) |
| `msvcrt/io.zig:155` | `p_iob()` | `msvcrt_iob` | Already handled |
| `kernel32/process.zig:1038` | `GetCommandLineW()` | `cmdline_w_buf` | 4096 bytes |
| `ws2_32/winsock.zig:628` | `inet_ntoa()` | `inet_ntoa_buf` | 16 bytes |
| `ws2_32/winsock.zig:668` | `gethostbyname()` | `hostent_buf` | 256 bytes |
| `d3d8/d3d8.zig:1006` | `Direct3DCreate8()` | `global_d3d8` | vtable struct |
| `mss32/miles.zig:14` | `AIL_last_error()` | `no_error_str` | 16 bytes |

### D. Files referencing `shared.guest_memory` (9 sites — loader dependency to remove)

| File:Line | Function | What it does | Fix |
|-----------|----------|-------------|-----|
| `kernel32/mem.zig:13` | `getGuestMemory()` | Returns guest_memory for VirtualAlloc | Move to registration wrapper |
| `kernel32/file.zig:236` | `MapViewOfFileEx` | Allocates from guest heap | Move to registration wrapper |
| `kernel32/process.zig:107` | `loadDllIntoGuest` | Copies DLL to guest memory | Already wrapper-only code |
| `msvcrt/misc.zig:103` | `errno()` | Allocates guest errno slot | Move to guest_statics init |
| `msvcrt/process.zig:29` | `ensureGuestGlobals` | Allocates guest globals | Keep in loader-level code |
| `msvcrt/process.zig:55` | `updateGuestGlobals` | Syncs guest globals | Keep in loader-level code |
| `msvcrt/process.zig:126` | `ensureGuestArgs` | Builds guest argv/envp | Keep in loader-level code |
| `msvcrt/process.zig:513` | `p_pgmptr` | Reads guest argv for pgmptr | Move to registration wrapper |
| `rpcrt4.zig:38` | `UuidToStringA` | Allocates UUID string in guest | Move to registration wrapper |

### E. `usize` parameters that should become pointer types (sampled)

| File | Function | Parameter | Should be |
|------|----------|-----------|-----------|
| `msvcrt/path.zig` | `splitpath` | `path_ptr: usize` | `path: [*:0]const u8` |
| `msvcrt/path.zig` | `splitpath` | `drive: usize` | `drive: ?[*]u8` |
| `msvcrt/file.zig` | `read` | `buffer_ptr: usize` | `buffer: [*]u8` |
| `msvcrt/file.zig` | `stat` | `path_ptr: usize` | `path: [*:0]const u8` |
| `msvcrt/file.zig` | `stat` | `stat_ptr: usize` | `stat_buf: *StatBuf` |
| `msvcrt/string.zig` | `strcpy` | `dest_ptr: usize` | `dest: [*]u8` |
| `msvcrt/string.zig` | `strcpy` | `src_ptr: usize` | `src: [*:0]const u8` |
| `msvcrt/fmt.zig` | `printf_impl` | `fmt_ptr: usize` | `fmt: [*:0]const u8` |
| `kernel32/file.zig` | `CreateFileA` | `lpFileName_ptr: usize` | `lpFileName: [*:0]const u8` |
| `kernel32/file.zig` | `ReadFile` | `lpBuffer: usize` | `lpBuffer: [*]u8` |
| `kernel32/process.zig` | `LoadLibraryA` | `lpFileName_ptr: usize` | `lpFileName: [*:0]const u8` |
| `kernel32/console.zig` | `WriteConsoleA` | `lpBuffer: usize` | `lpBuffer: [*]const u8` |
| ... and ~200 more across all DLL stubs | | | |

---

## Summary: The One Rule

**Stub functions are plain C-callable functions. They receive host-accessible pointers. They return host-accessible pointers. They never translate addresses. They never check what platform they're on. The thunk/boundary layer handles ALL translation, width conversion, and address space mapping. If a stub has `trace.addr()`, `platform.is_wasm`, or `shared.guest_memory` in it, the design is wrong.**

---

## File Reference

| File | Current Role | Future Role |
|------|-------------|-------------|
| `src/win32/msvcrt/*.zig` | Stubs with `trace.addr()` workarounds | Pure C-callable stubs, no loader deps |
| `src/win32/kernel32/*.zig` | Same | Same |
| `src/win32/host_io.zig` | Does not exist | Path conversion + file I/O abstraction |
| `src/loader/env.zig` | Thunk handler with `castArg` | Thunk handler translates ALL pointer params |
| `src/trace.zig` | `addr()`, `c_span()` for manual translation | Deprecated for stubs; used only by loader internals |
| `src/path_utils.zig` | Win32 <-> POSIX conversion | Called only from `host_io.zig` |
| `src/win32/shared.zig` | `guest_memory`, `raw_alloc` | Loader-internal only; stubs don't import it |
