# External Integrations

## Win32 API Surface
Zine implements a comprehensive Win32 API compatibility layer across 35+ DLL modules. All implementations are in `src/win32/`.

### Fully/Partially Implemented DLLs
| DLL | Key APIs | Status |
|---|---|---|
| MSVCRT | printf, sscanf, malloc, string ops, CRT init | Partial |
| KERNEL32 | File I/O, memory, process, thread, sync | Partial |
| USER32 | Window management, messages, input, menus | Partial |
| GDI32 | Device contexts, bitmaps, fonts, drawing | Partial |
| ADVAPI32 | Registry (stubbed), security tokens | Partial |
| SHELL32 | SHGetFolderPath, ShellExecute | Stub |
| OLE32/OLEAUT32 | CoInitialize, COM basics | Stub |
| DDRAW | DirectDraw 7 surfaces, primary/backbuffer | Partial |
| DSOUND | DirectSound buffer management | Partial |
| DINPUT/DINPUT8 | DirectInput keyboard/mouse | Partial |
| D3D8 | Direct3D 8 basics | Stub |
| WINMM | timeGetTime, waveOut audio | Partial |
| WS2_32/WSOCK32 | Winsock networking | Stub |
| SHLWAPI | Path manipulation (W variants) | Partial |

## Host System Integrations
- **File System:** POSIX ↔ Win32 path translation via `src/path_utils.zig` (C: → `drive_c/`, Z: → `/`)
- **Host I/O:** `src/win32/host_io.zig` bridges guest file operations to host filesystem
- **Renderer:** `src/gui/renderer.zig` provides framebuffer rendering (SDL-like abstraction)

## GUI Backends
1. **FLTK (native):** `src/gui/fltk_bridge.cpp` + `src/gui/fltk_ui.zig` — X11 desktop window
2. **Web UI:** `src/gui/web_ui.zig` + `src/gui/app.js` + `src/gui/index.html` — Browser-based with Win2K CSS theme

## WASM Runtime
- `src/wasm_main.zig` — WASI entry point, exports memory and functions for browser host
- `src/host_main.zig` — Native wasmer-based host for running WASM builds with JIT

## No External Services
- No databases, auth providers, or external API calls
- All operations are local: file system, rendering, and audio output
