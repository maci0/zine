# Concerns & Technical Debt

## Large Files
Several files are extremely large and may benefit from modular decomposition:
| File | Size | Comment |
|---|---|---|
| `src/x86/execute.zig` | 89K | Instruction execution — inherently large but could split by opcode group |
| `src/gui/app.js` | 78K | Browser frontend — single monolith JS file |
| `src/gui/win2k.css` | 82K | Win2K theme CSS — very large stylesheet |
| `src/jit/compiler.zig` | 60K | JIT compiler — growing with new instruction support |
| `src/x86/sse.zig` | 50K | SSE emulation — could split SSE1 vs SSE2 |
| `src/win32/user32.zig` | 58K | USER32 registration — hundreds of exports |
| `src/gui/renderer.zig` | 45K | Shared renderer state |
| `src/platform/native.zig` | 45K | Linux platform code |

## Stub Coverage Gaps
- Many Win32 APIs are registered as no-op stubs (`stub_args(N)`) — they return 0 but don't implement behavior
- Missing implementations may cause silent failures in guest applications
- Key gaps: COM/OLE, networking (WS2_32), printing (WINSPOOL), advanced GDI drawing

## JIT Status
- JIT compiler (`src/jit/`) is **validation-only** — compiles x86→WASM but doesn't execute compiled code
- All execution goes through the software interpreter, so JIT adds overhead without speedup currently
- JIT basic block cache uses a simple 4096-entry direct-mapped hash, which will have collision issues

## Error Handling in Win32 Layer
- Win32 stubs previously used `try` to propagate Zig errors from `path_utils` — recently fixed to use `catch return`
- Some stubs may still have incorrect error return values (should return INVALID_HANDLE_VALUE vs 0 vs FALSE)

## Guest Memory Safety
- `src/x86/memory.zig` provides bounds checking but relies on host address arithmetic
- `.rsrc` section protection is implemented, but `.rdata`/`.text` must remain writable for CRT startup compatibility
- No ASLR or guard pages for guest allocations

## Platform Portability
- `src/platform/native.zig` (45K) is Linux-specific with raw `mmap`/`mprotect`/`sigaction` calls
- Windows host support would require significant platform layer work
- macOS support would need Mach VM API equivalents

## Code Duplication (Recently Addressed)
- ✅ `stub_args0`..`stub_args10` consolidated into comptime `stub_args(N)` generator
- ✅ `sscanf_impl` refactored from hardcoded format checks to iterative parser
- Remaining: some Win32 API implementations may have duplicated patterns across A/W variants

## Missing Documentation
- No README or getting-started guide at project root
- In-code documentation is inconsistent — some modules have good doc comments, others have none
- No API documentation generation configured
