# Executing Windows Applications Natively from a 64-bit Zine Process

> **Status: Part 1 (32-bit PEs on x86_64) is implemented and green** via
> signal-based `INT 0xFE` dispatch, checked 2026-09-27. See "Implementation
> Status" below and [`STATUS.md`](STATUS.md) (`--native64` suite 158/0). The
> earlier sections
> describe the original problem analysis and are kept for reference; items they
> call "Missing" are done unless the checklist says otherwise. Part 2 (64-bit
> PEs) remains unimplemented.

Zine is currently designed to run 32-bit Windows executables. When Zine is compiled as a 64-bit application (`x86_64`), running PE files presents two distinct challenges depending on the target PE architecture:
1. Running a **32-bit** Windows executable natively.
2. Running a **64-bit** Windows executable natively.

This document outlines the architecture, requirements, and missing pieces needed to support native execution for both scenarios.

## Part 1: Executing 32-bit x86 Applications on x86_64 Zine

Currently, compiling `zine` for the `x86_64` target and attempting to directly execute a 32-bit PE natively will result in a crash. Wait, why? Because a 64-bit process runs in "Long Mode" (64-bit submode), where the CPU fetches and decodes instructions under 64-bit rules. Meanwhile, the loaded PE contains 32-bit machine code.

### The Problem: CS segment and Mode Switch
An x86_64 CPU is perfectly capable of executing 32-bit x86 instructions natively via its **Compatibility Mode**.
To engage compatibility mode, the code must be executing from a Code Segment (CS) where the `L` (Long) bit is `0`, and the `D` (Default operation size) bit is `1`.
On Linux, the standard 32-bit user-space code segment is `0x23` (Index 4, RPL 3), while the 64-bit code segment is `0x33` (Index 6, RPL 3).

On an `x86` build, `src/main.zig` does:
```zig
const entry_point = @as(EntryPointFn, @ptrFromInt(ep));
entry_point(); // 64-bit call
```
On an `x86_64` build this fails because `CS` remains `0x33`. The x86_64 branch
now calls `compat_thunks.enterCompatMode` instead, which switches `CS` to `0x23`
before jumping to the PE's entry point and back to `0x33` when the guest calls a
Zine's Win32 API stub (see "Implementation Status" below).

## What is Missing in the Zine Codebase?

### 1. 32-bit Addressable Memory (`mmap`)
All allocations for the guest (the PE image, its heap, its stack) *must* reside in the lower 4GB of the address space so that 32-bit pointers can reference them.
- **Current State**: `mmap` uses `MAP_FIXED_NOREPLACE`, which attempts to map the PE at its preferred address (e.g., `0x00400000`), which often succeeds. It also sets `MAP_32BIT` on x86_64 Linux for every non-fixed allocation, so anonymous guest maps land in the low 4GB; fixed-address mappings skip the flag because the address is already known.
- **Missing**: Nothing for the low-4GB requirement itself. The remaining work is auditing call sites that still assume 32-bit host pointers.

### 2. A 32-bit Compatible Stack
The native 64-bit Zine host stack is allocated by Linux in high memory (e.g., `0x7FFFFFF...`). A 32-bit program's `ESP` cannot point there.
- **Current State**: `main.zig` maps a 16MB guest stack with `MAP_FIXED` at `0x05000000` and pushes an exit stub as the return address before entering 32-bit mode.
- **Missing**: Nothing. See "Bootstrapping & Mode Transition" below.

### 3. The 64 → 32 Context Switch Trampoline
We cannot just `call` the entry point. We must use a far jump, far return (`lret`), or `iretq` to load the 32-bit `CS` register.
- **Missing**: Nothing. `compat_thunks.enterCompatMode` builds this frame and executes `iretq`; the sequence below is the conceptual shape.

```asm
// Conceptual 64 -> 32 transition
pushq $0x2B         // 32-bit SS
pushq %rcx          // Guest 32-bit ESP
pushq $0x202        // RFLAGS (interrupts enabled)
pushq $0x23         // 32-bit CS
pushq %rax          // Guest 32-bit EIP (entry point)
iretq               // Pops the above, switches to 32-bit mode
```

### 4. The 32 → 64 Thunk Mechanism (Win32 API Stubs)
When the 32-bit application wants to call a Win32 API (e.g., `kernel32.dll!GetVersion`), it cannot directly call a 64-bit Zine stub function pointer.
- **Current State**: On the native `x86` build, the IAT is patched with direct pointers to the Zine `.winapi` host functions. On `wasm32`, `INT 0xFE` thunks are used which are trapped by the software interpreter.
- **Missing**: Nothing. The steps below are the original sketch; what shipped is the `INT 0xFE` + signal-handler variant of step 2, described under "Implementation Status" below.
  1. Patch the IAT with pointers to trampolines placed in low memory.
  2. The trampoline executes a transition instruction to get back to 64-bit mode (e.g., a far call to `0x33:ThunkHandler_64`, or a software interrupt mapped via a custom signal handler, or `syscall`).
  3. A 64-bit marshalling function reads the 32-bit arguments from the 32-bit guest stack.
  4. The 64-bit Zine zig function is called.
  5. The return value is placed in `EAX`, and we mode-switch back to 32-bit mode to resume execution.

### 5. FS Segment Setup (TEB)
- **Current State**: `platform.setupFS` correctly uses `arch_prctl(ARCH_SET_FS)` on x86_64, which sets the hidden base of the `FS` segment register.
- **Status**: This actually works perfectly for both 64-bit and 32-bit code under an x86_64 host! The TEB memory just needs to be allocated in the lower 4GB.

### 6. Signal Handling (SIGSEGV/SIGFPE)
- **Current State**: `sigsegvHandler` sees 64-bit registers on an x86_64 build. It detects `CD FE` at the faulting IP and dispatches to `compat_thunks`, and a `CS == 0x23` fault that is not a thunk falls through to SEH dispatch.
- **Missing**: Reconstructing the `teb.CONTEXT` structure with 32-bit semantics from the 64-bit `ucontext_t`.

## Implementation Status

### Phase 5 — Signal-Based INT 0xFE Dispatch (Implemented)

The original plan outlined phases 1–4 with `lcall`/`lret` far-call trampolines. The actual
implementation uses a simpler signal-based approach that reuses the existing `INT 0xFE + thunk_id`
mechanism from the WASM/interpreter path. This avoids complex GDT manipulation and far calls.

**How it works:**
1. On x86_64, `INT 0xFE` in 32-bit compatibility mode (CS=0x23) raises SIGSEGV.
2. The signal handler detects `CD FE` at the faulting IP and reads the 4-byte thunk ID.
3. `compat_thunks.dispatchFromSignal()` reads 32-bit args from the guest stack (via RSP in ucontext),
   calls the 64-bit Zig stub, writes the result to RAX, adjusts RSP for stdcall, and sets RIP to the
   return address. The signal handler returns, resuming the guest in 32-bit compat mode.
4. Each API call costs one kernel signal entry/exit (~2-5µs), acceptable for I/O-bound CLI tools.

**Key files:**
| File | Change |
|------|--------|
| `src/x86/compat_thunks.zig` | **NEW** — 256KB thunk pool (MAP_32BIT), signal dispatcher, iretq entry trampoline |
| `src/platform/native.zig` | INT 0xFE detection at top of SIGSEGV handler |
| `src/loader/loader.zig` | `patchImport` x86_64 branch — allocates INT 0xFE stubs in compat pool |
| `src/x86/thunks.zig` | `ThunkEntry.native_addr` widened to `usize`, added `getEntry()` |
| `src/main.zig` | Initializes compat pool, allocates a 16MB guest stack, uses `iretq` to enter PE |
| `src/win32/teb.zig` | TEB allocated via `platform.mmap` (MAP_32BIT) on x86_64 |

### Checklist

#### Sub-4GB Memory Management
- [x] `platform.mmap` uses `MAP_32BIT` on x86_64 — every non-fixed guest mmap lands in the low 4GB (`src/platform/native.zig:142`; fixed mappings skip the flag)
- [x] `teb.zig` allocates TEB via `platform.mmap` on x86_64 (ensures < 4GB)
- [x] PEB/ProcessParameters allocated via `win32/shared.zig:raw_alloc` (uses platform.mmap)

#### Thunking & Stubs
- [x] `compat_thunks.zig` — 256KB executable pool in low 4GB for `INT 0xFE` stubs
- [x] `allocThunk(thunk_id)` — writes `CD FE + u32` and returns 32-bit address for IAT
- [x] `allocData(src, size)` — copies data exports into pool for 32-bit guest access
- [x] `loader.zig:patchImport` — x86_64 branch registers native thunks and allocates compat stubs
- [x] `thunks.zig` — `ThunkEntry.native_addr` widened to `usize`, `registerNativeThunk` takes `usize`

#### Bootstrapping & Mode Transition
- [x] 16MB guest stack allocated via `platform.mmap` (MAP_FIXED at `0x05000000`)
- [x] Exit stub pushed as return address on guest stack
- [x] `iretq` trampoline switches CS=0x23, SS=0x2B to enter 32-bit compat mode
- [x] `main.zig` — entry point and `_InvokeCompilerPass@12` both use compat mode on x86_64

#### Signal Handling
- [x] `sigsegvHandler` detects `CD FE` at faulting IP and dispatches to `compat_thunks`
- [x] `dispatchFromSignal` reads 32-bit guest stack, calls 64-bit stub, writes EAX/ESP/EIP in ucontext
- [x] CS=0x23 check for non-thunk faults: compat-mode guest faults fall through to SEH dispatch instead of exiting
- [ ] Full 32-bit CONTEXT extraction from 64-bit ucontext — future work

---

## Part 2: Executing 64-bit x86_64 Applications on x86_64 Zine

If we want to extend Zine to execute 64-bit Windows applications natively on a 64-bit Linux host, the problems are different. We no longer have the 32-bit to 64-bit mode switch problem, but we introduce several other significant challenges:

### 1. 64-bit PE Parsing and Definition
- **Current State**: Zine's `pe.zig` only defines `IMAGE_NT_HEADERS32` and 32-bit specific structures.
- **Missing**: We need to implement `IMAGE_NT_HEADERS64` and support for the `PE32+` format (Magic = `0x020B`). The structures for `IMAGE_OPTIONAL_HEADER64` have slightly different field layouts, particularly with 64-bit pointers (e.g., `ImageBase` is `u64`).

### 2. Calling Convention Mismatches
The most significant hurdle is the difference between the **Windows x64 calling convention** and the **System V AMD64 ABI** (used by Linux and Zig natively).
- **Windows x64**: Arguments in `RCX`, `RDX`, `R8`, `R9`. Float arguments in `XMM0-XMM3`. Caller-allocated 32-byte shadow space on the stack. Registers `RBX`, `RBP`, `RDI`, `RSI`, `R12-R15` are non-volatile (callee-saved).
- **System V**: Arguments in `RDI`, `RSI`, `RDX`, `RCX`, `R8`, `R9`. No default shadow space. Registers `RBX`, `RBP`, `R12-R15` are non-volatile.
- **Missing**: Zine's stubs already declare `callconv(w32cc.WINAPI)`, which `src/win32/calling_convention.zig` maps to `.winapi` (= Win64) on x86_64, so the convention itself is handled. What remains is auditing `loader/env.zig`'s function-pointer typedefs and every stub for hardcoded 32-bit types, and ensuring Zig allocates the 32-byte shadow space when a Win64 stub calls back into native code (callbacks in the GUI and event loops).

### 3. SEH Exception Handling (64-bit)
On 32-bit Windows, SEH uses a dynamic linked list stored in `FS:0`. On 64-bit Windows, SEH is fundamentally different.
- **Current State**: `sigsegvHandler` and exception dispatching in `teb.zig` rely entirely on the 32-bit `FS:0` linked list.
- **Missing**: 64-bit Windows uses **table-based SEH**. The exceptions are resolved by looking up the faulting instruction pointer in the `IMAGE_DIRECTORY_ENTRY_EXCEPTION` table (`.pdata` section), looking at the unwind codes in `.rdata`. Zine must implement a full stack unwinder to parse these tables and invoke the appropriate handlers. We cannot just read `FS:0`.

### 4. PEB and TEB Structures
- **Current State**: `teb.zig` defines `TEB` and `PEB` as 32-bit structures with 32-bit pointers. They are accessed via the `FS` register.
- **Missing**: We need 64-bit definitions for `TEB64` and `PEB64`. Additionally, on 64-bit Windows, the TEB is accessed via the **GS** segment register (`GS:0x30` for PEB), not `FS`. We must use `arch_prctl(ARCH_SET_GS)` on Linux to setup the base address.

### 5. Memory Allocation
- **Current State**: Zine implicitly expects the entire memory space limits of 32-bit.
- **Missing**: Ensure all pointers throughout Zine's loading layers seamlessly support 64-bit addresses, which should naturally follow from using standard Zig `usize` pointer types, but requires careful audits of anywhere hardcoded 32-bit assumptions were made. Lengthy 64-bit addresses now apply to stack limits, image bases, and allocations.

## Implementation Plan & Checklist for 64-bit Applications

### Phase 1: PE32+ Parsing and Loading
- [ ] Define `IMAGE_NT_HEADERS64`, `IMAGE_OPTIONAL_HEADER64`, and 64-bit relocation types in `src/pe.zig`.
- [ ] Refactor `loader/module.zig` to dynamically detect `PE32` vs `PE32+` via the Magic value (`0x10B` vs `0x20B`), parsing the respective optional header.
- [ ] Implement 64-bit Import Address Table (IAT) patching. 64-bit thunk entries are 8 bytes (`IMAGE_THUNK_DATA64`).
- [ ] Ensure image loading correctly applies 64-bit base relocations if the preferred base is unavailable.

### Phase 2: Calling Convention & API Stubs
- [x] `src/win32/calling_convention.zig` already defines `WINAPI` as `.winapi`, which is Win64 on x86_64.
- [ ] Audit `loader/env.zig` to ensure function pointers for unresolved stubs match the `.Win64` calling convention.
- [ ] Review all 36 Win32 stub modules (the DLL source list in `build.zig`) to ensure no hardcoded 32-bit types are used where pointers or handle-sized integers should scale to 64-bit.
- [ ] Ensure Zig correctly allocates 32-byte shadow space when Zine's `.Win64` functions call back into native Windows code (e.g., callbacks in GUI/Event loops).

### Phase 3: TEB, PEB, and GS Segment
- [ ] Define `TEB64` and `PEB64` structures (with 64-bit pointers and correct padding) in `src/win32/teb.zig`.
- [ ] Update `platform/native.zig` to implement `setupGS()` using `arch_prctl(ARCH_SET_GS)`.
- [ ] Modify the Zine bootstrapper to allocate and initialize the 64-bit PEB/TEB and bind it to the `GS` register for 64-bit apps.

### Phase 4: Table-Based SEH Exception Handling
- [ ] Define `IMAGE_RUNTIME_FUNCTION_ENTRY` and UWOP (Unwind Operation) structures from the `.pdata` and `.rdata` specifications.
- [ ] Write a stack unwinder (`unwind64.zig`) capable of walking the 64-bit stack frame by frame, interpreting UWOP codes (push nonvol, alloc stack, save xmm).
- [ ] Update `sigsegvHandler` to use the stack unwinder when a trap occurs in 64-bit guest code.
- [ ] Dispatch to Language Specific Handlers (LSH) by calling the exception routines specified in the `.pdata` table.

### Phase 5: Testing & Finalization
- [ ] Write a "Hello World" 64-bit Win32 console app using MSVC and verify execution.
- [ ] Write a simple 64-bit Win32 MessageBox app and verify Windows x64 register passing.
- [ ] Trigger an intentional exception/crash and verify the `.pdata` unwinder successfully produces a stack trace.
