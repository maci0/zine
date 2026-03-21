# Testing

## Test Framework
- **Zig built-in test runner** (`zig build test`)
- Unified test root: `src/test_root.zig` imports all test modules

## Test Structure
```
src/test_root.zig       # Aggregates all unit tests
tests/
├── test_msvc_cli.sh    # End-to-end shell tests (24K) — native + interpreted modes
├── benchmark.sh        # Performance benchmarks
├── bench.c / bench.exe # C benchmark source + compiled binary
├── cpubench_int.c      # CPU benchmark (interpreter)
├── cpubench_win32.c    # CPU benchmark (Win32)
├── test_sse2.c/.exe    # SSE2 instruction tests
├── whetstone.c         # FPU benchmark
├── dummy.gb            # Test ROM file
└── pokemon.*           # Game test ROMs
```

## Test Types

### Unit Tests
- Embedded in source files using Zig's `test` blocks
- Run via `zig build test` (host architecture)
- Cover x86 instruction decoding, path translation, format parsing

### Integration Tests
- `tests/test_msvc_cli.sh` — Runs compiled Win32 binaries through the interpreter
- Supports `--native`, `--interpret`, `--both` modes
- Tests MSVC CLI tools (compiler, linker, etc.) under emulation

### Benchmarks
- `tests/benchmark.sh` — Automated performance measurement
- `tests/bench.exe` — Pre-compiled Win32 benchmark binary
- `tests/whetstone.c` — FPU performance testing

## Running Tests
```bash
# Unit tests
zig build test

# End-to-end MSVC CLI tests (interpreted mode)
bash tests/test_msvc_cli.sh --interpret

# Build all targets to verify compilation
zig build -Dall
```

## Coverage
- x86 decoder and executor have the most test coverage
- Path translation (`path_utils.zig`) has inline tests
- Win32 stubs are primarily tested via integration (running real Win32 binaries)
- No automated coverage reporting tool configured
