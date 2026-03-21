# Code Conventions

## Language Style
- **Zig 0.15.2** — Uses latest Zig idioms (comptime, error unions, tagged unions)
- Standard `camelCase` for functions and variables, `PascalCase` for types
- Win32 API functions use their original names (e.g., `CreateWindowExA`, `GetModuleHandleA`)

## Naming: `stub_` Prefix
- Unimplemented Win32 functions use a `stub_` prefix (e.g., `stub_CreateFileMapping`)
- When a function is properly implemented, the `stub_` prefix is removed
- Export registrations in `kernel32.zig` etc. must be updated to match

## Win32 Stub Patterns

### Registration Pattern
Each DLL module follows the same pattern:
```zig
pub fn register(environment: *env.Environment) !void {
    const m = "KERNEL32.dll";
    try environment.addBuiltinExportComptime(m, "FunctionName", functionImpl);
}
```

### Stub Generation
Generic no-op stubs use comptime-generated functions from `src/win32/shared.zig`:
```zig
// Generates a function with N usize args that returns 0
const stub_ret0_5 = stub_common.stub_args(5);
```

### Calling Convention
- Win32 stubs use `callconv(w32cc.WINAPI)` (stdcall on x86, C on other platforms)
- Stub functions receive raw `usize` parameters (guest pointers)
- `trace.addr()` translates guest addresses to host addresses

### Address Translation
- Guest addresses are raw 32-bit values stored as `usize`
- `trace.addr(guest_addr)` converts guest VA → host pointer
- String parameters: `@as([*:0]const u8, @ptrFromInt(trace.addr(ptr)))`

## Error Handling
- Win32 stubs **never** propagate Zig errors — they return Win32 error codes (0, -1, INVALID_HANDLE_VALUE)
- `path_utils` calls use `catch return 0` pattern instead of `try`
- Internal Zig errors use `!void` or `!usize` return types with `try`

## Documentation
- Module-level doc comments (`//!`) describe the file's purpose
- Function doc comments (`///`) include implementation status: `Fully implemented`, `Partially implemented`, `Stub`
- Inline comments explain Win32 ABI details and magic numbers

## Tracing
- Conditional tracing via `trace.enable_tracing` boolean
- `trace.print(fmt, args)` for debug output
- All Win32 stub calls are traceable with function names and arguments
