# Directory Structure

## Top-Level Layout
```
zine/
├── build.zig              # Build configuration (multi-target)
├── build.zig.zon          # Package metadata & dependencies
├── AGENTS.md              # Agent coding guidelines
├── src/                   # All source code
├── tests/                 # Test binaries and scripts
├── tools/                 # Development utilities
├── docs/                  # Documentation
├── drive_c/               # Virtual Windows C: drive root
└── .planning/             # GSD planning documents
```

## Source Tree (`src/`)
```
src/
├── main.zig               # Native CLI entry point (29K)
├── wasm_main.zig          # WASM entry point (39K)
├── host_main.zig          # Wasmer host entry (16K)
├── runner.zig             # Shared execution pipeline (17K)
├── pe.zig                 # PE format definitions (14K)
├── pe_resources.zig       # PE resource section parser
├── path_utils.zig         # Win32 ↔ POSIX path translation (25K)
├── platform.zig           # Platform abstraction selector
├── trace.zig              # Debug tracing utilities
├── log.zig                # Logging system
├── profiler.zig           # Performance profiling
├── version.zig            # Version info
├── test_root.zig          # Unified test entry point
├── win32_dll_api.zig      # Shared module for DLL build targets
│
├── x86/                   # x86 interpreter core (10 files, ~270K)
│   ├── cpu.zig            # CPU state structure
│   ├── decoder.zig        # Instruction decoder
│   ├── execute.zig        # Instruction execution (89K, largest)
│   ├── sse.zig            # SSE/SSE2 emulation (50K)
│   ├── memory.zig         # Guest memory management
│   ├── flags.zig          # EFLAGS computation
│   ├── fpu.zig            # x87 FPU
│   ├── thunks.zig         # Native↔guest calling bridges
│   ├── compat_thunks.zig  # x86_64↔x86 ABI compatibility
│   └── decode_cache.zig   # Instruction decode cache
│
├── loader/                # PE loading subsystem (7 files)
│   ├── loader.zig         # PE loading & import resolution
│   ├── module.zig         # Module representation
│   ├── env.zig            # Environment & export registry (37K)
│   ├── registry.zig       # Module registry & search paths
│   ├── dialog_parser.zig  # Win32 dialog resource parser
│   ├── menu_parser.zig    # Win32 menu resource parser
│   └── icon_parser.zig    # Win32 icon resource parser
│
├── win32/                 # Win32 API stubs (43 files + 18 subdirs)
│   ├── shared.zig         # Common stubs, comptime stub_args(N)
│   ├── kernel32.zig       # KERNEL32 registration (40K)
│   ├── user32.zig         # USER32 registration (58K, largest stub)
│   ├── gdi32.zig          # GDI32 registration
│   ├── msvcrt.zig         # MSVCRT registration (29K)
│   ├── kernel32/          # KERNEL32 implementation files
│   ├── user32/            # USER32 implementation files
│   ├── msvcrt/            # MSVCRT implementation files
│   ├── ddraw/             # DirectDraw implementation
│   ├── dsound/            # DirectSound implementation
│   ├── dinput/            # DirectInput implementation
│   └── ...                # 30+ other DLL modules
│
├── jit/                   # x86→WASM JIT compiler (6 files)
│   ├── compiler.zig       # JIT compiler core (60K)
│   ├── translate.zig      # x86→WASM instruction mapping
│   ├── emitter.zig        # WASM module emitter
│   └── ...
│
├── gui/                   # GUI rendering backends
│   ├── renderer.zig       # Shared renderer state (45K)
│   ├── web_ui.zig         # Web UI with HTTP server (27K)
│   ├── fltk_ui.zig        # FLTK native window
│   ├── fltk_bridge.cpp    # FLTK C++ bridge
│   ├── app.js             # Browser frontend (78K)
│   ├── index.html         # Browser UI page
│   └── win2k.css          # Windows 2000 theme CSS (82K)
│
├── platform/              # Platform-specific code
│   ├── native.zig         # Linux: mmap, signals, threads (45K)
│   └── wasm.zig           # WASM: host imports
│
└── dll/                   # DLL build sources (37 files)
    ├── dll_common.zig     # Shared DLL utilities
    ├── msvcrt_dll.zig     # MSVCRT.dll exports
    ├── kernel32_dll.zig   # KERNEL32.dll exports
    └── ...                # 34 other DLL source files
```

## Naming Conventions
- **DLL modules:** `src/win32/{dllname}.zig` for registration, `src/win32/{dllname}/` for implementation
- **DLL build sources:** `src/dll/{dllname}_dll.zig`
- **Platform code:** `src/platform/{platform}.zig`
- **Test files:** `src/test_root.zig` aggregates all tests; `tests/` has external test scripts
