# Zine

A Win32 PE interpreter that runs 32-bit Windows executables on Linux and in the browser. Software x86 CPU, PE loader, Win32 API compatibility layer, and GUI backends (native FLTK + browser via WASM). Targets Win98/Win2K era applications and games.

No Windows installation, no Wine.

## What works

- Full MSVC 6.0 toolchain: CL.EXE, LINK.EXE, RC.EXE, NMAKE.EXE, and 8 more utilities run to completion
- 288 unit tests pass (2 skipped) on the host with `zig build test`; the gate in
  `tests/check.sh` adds the CLI suites on native x86 and x86_64
- 158/128 integration checks on native/WASM, 20 FLTK smoke tests (these need guest
  binaries and are not part of `tests/check.sh`)
- x86 interpreter with SSE/SSE2, x87 FPU, SEH, TLS
- PE loader with import resolution, relocations, resource parsing (dialogs, menus, icons, string tables)
- 37 Win32 DLL stub modules: kernel32, user32, gdi32, advapi32, shell32, ws2_32, comctl32, ole32, msvcrt, and more
- x86-to-WASM JIT compiler (basic block level, interleaves with interpreter)
- Web GUI with Win2K-style desktop, or native FLTK window
- Virtual filesystem rooted at `drive_c/` (guest `Z:\` and absolute POSIX paths still reach the host filesystem; see `docs/THREAT_MODEL.md`)

## Releases and upgrades

The `v1` tag (2026-03-22) names the **Win32 Compatibility Milestone**, not
SemVer 1.0.0. Package version **0.2.0** is the first SemVer release after that
milestone. `v1` stays a historical name; do not treat it as 1.0.0. No `v0.2.0`
tag exists in this repository yet, so identify 0.2.0 by the version in
`build.zig.zon` and the notes below. There is no documented deprecation,
support-window, or security-backport policy. Pin a commit when reproducing a
build.

Changes after the last tag are listed under **Unreleased** below. The package
version, `--version`, and `build.zig.zon` stay at the last released number until
a release moves all three together; a released version is never edited
retroactively.

### Unreleased

#### Breaking and migration

- Guest ANSI strings are decoded as CP1252, the Windows default code page,
  instead of being passed through as UTF-8. Window titles, dialog and menu text,
  and PE string-table resources with non-ASCII bytes now render as on Win98,
  which changes text that previously displayed as raw UTF-8 or mojibake.
  Guests that store UTF-8 in an ANSI field still need to convert it themselves.
- Web UI commands that name a guest file must send a relative path with no
  drive letter, backslash, NUL, or `.`/`..` component. Anything else, and any
  path with more than 128 components, is refused instead of being resolved:
  upload and launch answer `Invalid path`, and a directory listing comes back
  empty. Frontends that sent absolute or drive-qualified paths must send paths
  relative to the virtual C: root.
- `ZINE_WEB_HOST` and `ZINE_WEB_PORT` (native) and `ZINE_CWD` (WASI) are read
  and validated at startup. An empty or malformed value exits with status 2
  before the guest loads, matching how `ZINE_LOG_LEVEL` already behaved. Unset
  the variable, or give it a valid value, in launch scripts and runtime
  environment configuration. The resolved web address is printed at startup.
- A non-loopback `ZINE_WEB_HOST` exposes the emulator screen and accepts
  synthetic input from the network. It logs a warning and restricts accepted
  WebSocket origins to that address, so a browser reaching the UI through
  another hostname is refused with HTTP 403.

#### Security fixes

- The host home directory is redacted from every diagnostic before it reaches
  stderr, so a trace pasted into a bug report no longer carries the local
  account name. A run whose environment has neither `HOME` nor `USERPROFILE`
  records paths unchanged.
- Web UI file uploads resolve strictly inside `drive_c/` rather than through
  prefix matching, so a crafted directory or file name cannot retarget the
  write.

#### Added

- `ZINE_WEB_HOST` (default `127.0.0.1`) and `ZINE_WEB_PORT` (default `1995`)
  for the native web UI, and `ZINE_CWD` for the WASI guest working directory.
- `tests/check.sh` and `CONTRIBUTING.md` describing the single pre-PR gate.
- `docs/THREAT_MODEL.md`, a risk ranking of the host process.
- A transfer budget for the four precompressed web UI assets, checked by
  `zig build test`, so the bytes a visitor downloads cannot grow unnoticed.

#### Fixed

- Web UI `error` frames are parseable again. A rejection that names a field
  (`resize`, `color_selected`, a missing `type`) embedded its quotes unescaped,
  so the browser dropped the frame and the reason never reached the status bar.
- A web UI request for a path that names a directory answers 404 with the usual
  plain-text body instead of closing the connection with no response.
- `localtime64` fills a real `struct tm` instead of returning zeroes, reads its
  argument as a 64-bit `time_t`, and clamps negative input to the epoch.
- `select` timeouts and `poll` convert a guest `timeval` to whole milliseconds
  or nanoseconds by rounding up, so a sub-millisecond wait no longer becomes a
  non-blocking wait.
- Web desktop Start button, common dialogs, and modal dismissal behave
  consistently across the desktop, the taskbar, and Escape.
- The web UI serves the document, stylesheet, and both scripts over one
  keep-alive connection instead of closing the socket after every asset.
- A web UI script that fails to load reports it in the status bar instead of
  leaving the page on "Connecting..." with no working interface.
- Guest input no longer aborts the runtime through arithmetic traps: `sscanf`
  clamps digit runs that overrun the target type, D3D triangle rasterization
  drops triangles with non-finite screen coordinates instead of failing to
  convert them, `GetLocaleInfoA`/`W` fail on a negative buffer size, and
  `Ellipse`, `ExtTextOutA`, `time`, and `_ftime` compute in a wide enough type
  to cover extreme rectangles, a pre-1970 clock, and dates past 2038.
- `GetSystemMetrics` answers the real `SM_CXMINTRACK` through `SM_CYCURSOR`
  indices, so a scrollbar or icon sized from them is not half-scale.
- `IsCharLowerA`/`W`, `IsCharUpperA`/`W`, `IsCharAlphaA`/`W` and
  `IsCharAlphaNumericA`/`W` each test their own class, and `IsCharUpperA` and
  `IsCharAlphaW` resolve instead of failing to import.
- `GetPixel` reports `CLR_INVALID` outside the surface, `SelectObject` returns
  the previous object (NULL when there was none), and `SetDIBitsToDevice` with
  `cLines == 0` copies the whole bitmap and returns the lines transferred.
- `GetVersionExA`/`W` fail with `ERROR_INVALID_PARAMETER` instead of writing
  past a caller-supplied struct that is too small.
- `_snprintf`/`_vsnprintf` report truncation with -1, and `_snwprintf`/
  `_vsnwprintf` format into a wide buffer instead of the narrow one.
- The synthetic export table no longer overlaps each jump thunk's target with
  the next thunk, and its `SizeOfImage` lands at the optional-header offset a
  guest reads.
- A PE section whose `VirtualAddress + VirtualSize` wraps, or a resource
  directory whose entry counts overflow or run past the image, is rejected
  instead of producing a reversed slice or an out-of-bounds read.

### 0.2.0 (2026-09-18)

#### Breaking build and runtime requirements and migration

- Zig **0.16.0** replaces **0.15.2** as the minimum toolchain. Upgrade Zig before
  rebuilding; the source now uses the 0.16 process and I/O APIs.
- Empty or unknown `ZINE_LOG_LEVEL` values now stop native and WASI startup
  with status 2, including `--help` and `--version`. At `v1`, native builds
  silently ignored invalid values and WASI ignored the variable entirely.
  Unset it to retain the default, or use `fatal`, `error` (alias `err`), `warn`,
  `info`, or `trace`. Replace empty assignments and unsupported values such as
  `debug` in launch scripts and runtime environment settings. WASI now honors
  valid levels too; unset the variable to retain its previous unfiltered logs.
- For the native FLTK GUI, use `zig build -Darch=x86_64 -Dfltk` instead of the
  old x86 `zig build -Dfltk` recipe, then run `zig-out/bin/zine.x86_64 --fltk`.
  Guest executables remain 32-bit Windows PEs.
- WASI guest heap reservations increase from 32 MiB to 512 MiB for the main
  executable and from 16 MiB to 128 MiB for each spawned child. Hosts with
  memory limits sized for `v1` can now fail to load the same guest. Raise the
  runtime's memory allowance to cover these reservations plus PE images,
  stacks, and runtime overhead; the module's 2 GiB maximum is unchanged.

#### Security fixes and migration

- Guest file operations, library loading, and child-process launching now
  normalize C-drive parent-directory components within `drive_c/` instead of
  passing them through to the host filesystem. Relative paths resolve against
  the virtual working directory. Move required guest files under `drive_c/`
  and update guest paths rather than relying on traversal above the drive root.
  This is path normalization, not a guest sandbox: host-path access remains
  available through other mappings.
- The native web UI now rejects WebSocket requests with foreign `Origin`
  headers with HTTP 403. Previously, any browser origin could connect. Open
  the UI at `http://127.0.0.1:1995`, `http://localhost:1995`, or
  `http://[::1]:1995`; browser frontends on another hostname, scheme, or port
  are no longer accepted. Non-browser clients without an Origin header remain
  accepted; the origin check is not authentication.

#### Added

- Native x86_64 FLTK support and expanded Win32 controls and common dialogs.
- Per-application `registry.toml` overrides with `app:<MODULE>:<KEY>` sections.
  Existing global sections remain usable; overrides take precedence for the
  matching executable basename.
- `GetDateFormatA` and `GetTimeFormatA`, with DateTimePicker controls seeded
  from the clock.
- Folder selection in open and save dialogs.
- Precompressed Web UI assets and ETag revalidation for unchanged files.

#### Fixed

- `--help`/`-h` and `--version`/`-v` once again write to stdout on WASI and
  `zine-host`, preserving shell capture and piping after the Zig migration.
  Native informational commands no longer attempt guest memory setup or emit
  null-page mapping warnings. Invalid options still return status 2 on stderr.
  Failed writes to stdout now return status 1 instead of silently succeeding;
  scripts must handle output errors when redirecting these commands.
- `zine-host` now returns status 1 for unrecognized traps escaping WASM `_start`
  and propagates recognized WASI `proc_exit` codes in the range 0–255. At `v1`,
  both traps and nonzero guest exits could return host status 0. Scripts using
  `set -e` or `&&` now stop on these failures; handle the nonzero status and
  check stderr rather than treating incomplete guest output as success.
- Win32 `MulDiv` rounds to nearest instead of truncating, and `lstrcmpiW`
  preserves non-ASCII UTF-16 units rather than truncating them to bytes.
- TLS allocation and thread-value access are serialized.
- x86 shift instructions preserve carry flags.
- Decode cache entries are matched against the full instruction bytes.
- Pre-1970 file timestamps are preserved.
- Non-ASCII UTF-16 registry names and menu labels are no longer truncated to
  ASCII bytes.
- `FlushFileBuffers` reports host sync failures instead of returning success.

See [implementation status](docs/STATUS.md) for subsystem coverage and remaining
limitations, and [CONTRIBUTING.md](CONTRIBUTING.md) for the contributor setup,
command table, and pull-request expectations.

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/). Builds are ReleaseSafe by
default; add `-Doptimize=Debug` for a debugging loop. Every build except
`-Doptimize=Debug` strips debug info: unstripped DWARF records the checkout
directory and the toolchain's lib path, so the same source would produce a
different binary on every machine.

```sh
# Default 32-bit x86 interpreter
zig build

# 64-bit with native GUI
zig build -Darch=x86_64 -Dfltk

# WASM target
zig build -Darch=wasm32

# All targets
zig build -Dall
```

`-Dfltk` links the system FLTK 1.3 libraries from `/usr/lib/fltk1.3`, so it
needs them installed first (Debian/Ubuntu):

```sh
sudo apt install libfltk1.3-dev libx11-dev libxext-dev libxft-dev \
    libfontconfig1-dev libxinerama-dev libxcursor-dev libxrender-dev \
    libxfixes-dev
```

`-Dhost` (the `zine-host` JIT wrapper) needs the Wasmer C API headers and
library plus a system `cc` on `PATH`.

## Usage

```sh
# Run a Windows executable
./zig-out/bin/zine.x86 path/to/app.exe

# Place files under drive_c/ to populate the virtual C: drive
mkdir -p drive_c/myapp
cp app.exe drive_c/myapp/
./zig-out/bin/zine.x86 drive_c/myapp/app.exe
```

## Runtime diagnostics

Native and WASI executables configure diagnostics through environment variables;
no rebuild is needed. Log level, tracing, and profiling are read at startup;
color detection is cached on the first diagnostic. Pass WASI variables through
the runtime's environment options, for example
`wasmtime run --env ZINE_LOG_LEVEL=warn zig-out/bin/zine.wasm32.wasm --version`.

| Variable | Values and default |
|---|---|
| `ZINE_LOG_LEVEL` | `fatal`, `error` (alias `err`), `warn`, `info`, `trace`; default `trace` |
| `ZINE_TRACE` | Any value, including empty, enables API tracing; unset disables it |
| `ZINE_TRACE_INSN` | Any value, including empty, enables instruction tracing; unset disables it |
| `ZINE_PROFILE` | Any value, including empty, enables profiling; unset disables it |
| `ZINE_WEB_HOST` | IPv4 or IPv6 literal the native web UI binds; default `127.0.0.1` |
| `ZINE_WEB_PORT` | Native web UI port, 1-65535; default `1995` |
| `ZINE_CWD` | WASI builds only: absolute POSIX path used as the guest working directory; unset uses `.` |
| `NO_COLOR` | Any value disables native diagnostic colors; WASI never emits colors |

`ZINE_LOG_LEVEL` filters structured diagnostics on stderr. The default does not
itself enable API or instruction tracing. Values are case-sensitive; empty or
unknown log levels exit with status 2 and list the accepted values before guest
loading. `ZINE_LOG_LEVEL=warn ./zig-out/bin/zine.x86 --version` checks startup
validation without running a guest. `zine --quiet` (also `-q`) raises the level
to `warn` for the rest of the run and wins over `ZINE_LOG_LEVEL`, so a script can
quiet a noisy environment without rewriting it.

The host home directory is redacted from every diagnostic before it reaches
stderr, so a trace pasted into a bug report does not carry the local account
name. Only that prefix changes: `CreateFileA('/home/jane/notes.txt')` is
recorded as `CreateFileA('/~/notes.txt')`, and the `Z:\home\jane\...` form the
guest sees is redacted the same way. A run whose environment has neither `HOME`
nor `USERPROFILE` records paths unchanged.

`ZINE_WEB_HOST` and `ZINE_WEB_PORT` are read and validated at startup, before
the guest loads, and the startup log line and banner print the resolved URL.
An empty or malformed value exits with status 2 instead of falling back to the
default; two concurrent runs therefore need distinct ports:

```sh
ZINE_WEB_PORT=3000 ./zig-out/bin/zine.x86_64 drive_c/myapp/app.exe
```

The default binds loopback only. A non-loopback `ZINE_WEB_HOST` exposes the
emulator's screen and accepts synthetic input from the network, so it logs a
warning and restricts the accepted WebSocket origins to that address.

`ZINE_CWD` is how a WASI runtime tells the build where the guest should run,
since WASI has no `realpath`. It must be an absolute POSIX path; a relative or
empty value exits with status 2 instead of silently running the guest in `.`.

## Build options

| Flag | Purpose |
|---|---|
| `-Darch=x86\|x86_64\|wasm32\|wasm64` | Target architecture (default: x86) |
| `-Dfltk` | Enable native FLTK GUI backend (x86_64 only) |
| `-Djit_host` | Enable JIT host imports for WASM builds |
| `-Dexternal-stubs` | Load Win32 stubs from DLLs instead of embedding |
| `-Ddll=<name>\|all` | Build Windows DLL stubs as shared libraries |
| `-Dhost` | Build zine-host (wasmer-based WASM runner) |

## Testing

The unit suite runs with Zig alone. The optional MSVC integration suite requires
an existing MSVC 6.0 installation at `tools/MSVC600/`, including `VC98/Bin`,
`VC98/Include`, `VC98/Lib`, and `Common/`. These proprietary fixtures are not
included in a clone. The script builds the selected interpreter automatically;
WASM execution also requires the selected runtime on `PATH`. WebSocket tests
require Python 3 and the dependencies in `tests/requirements.txt`.

```sh
# Unit tests (no Windows binaries or GUI dependencies needed)
zig build test

# Focus on one module or test-name substring
zig build test -Dtest-filter=x86.decoder --summary all

# CLI output and exit status (no Windows binaries needed)
zig build test-cli
zig build test-cli -Darch=x86_64
zig build test-cli -Darch=wasm32  # requires wasmtime
zig build test-cli -Dhost       # also checks zine-host; requires Wasmer headers/libs

# Optional integration suite (requires MSVC fixtures described above)
./tests/test_msvc_cli.sh --native
./tests/test_msvc_cli.sh --native64
./tests/test_msvc_cli.sh --wasmtime

# FLTK smoke tests (requires Xvfb)
./tests/fltk_smoke.sh
```

### Fuzzing the PE parsers

`zig build fuzz` mutates a seed corpus of menu resources and PE images and
feeds every input to the parser under Zig's safety checks. A failing input is
written to `zig-out/fuzz/<target>-<n>.bin`; minimize it, fix the cause, and
add the minimized input to the seed corpus in `src/fuzz/`.

```sh
zig build fuzz -Dfuzz-seconds=30            # per target
zig build fuzz -Dfuzz-seconds=30 -- menu.bin pe.exe   # also replay captured files
```

The harnesses assert the parser's output contract, not just absence of
crashes: a menu that parses must render as a valid JSON menu object, and a
successful `PEParser.parse` must place its headers inside the file.
`zig build test` replays the same seeds plus a fixed mutation sweep under
`std.testing.allocator`, so a leak or a broken contract fails the normal gate.
libFuzzer or AFL++ can drive the same harnesses by calling `harness` in
`src/fuzz/menu.zig` and `src/fuzz/pe.zig`.

The CLI gate checks the built executable's version against `build.zig.zon`,
stdout/stderr separation, help aliases, and invalid-option status. Every build
also rejects disagreement between the manifest and `src/version.zig`.
`test-cli` supports native and plain wasm32 builds; wasm64's 64-bit WASI imports
and `-Djit_host` builds require a custom runtime and are not executed by this gate.
The CLI tests ignore an inherited `ZINE_LOG_LEVEL` and set their own values when
checking log-level validation.

### Before opening a pull request

Run from the repository root on x86_64 Linux with 32-bit executable support.
Besides Zig 0.16.0, the CI checks require Bash, ShellCheck, GNU coreutils
(including `timeout`), `cmp`, and `grep`. Zig fetches the pinned TOML dependency
on the first build; no Windows fixtures, GUI libraries, or WASM runtime are
needed for these checks.

```sh
bash tests/check.sh
```

One command runs the whole gate: it names any missing tool or wrong Zig
version before starting, then runs the CI checks in order and stops at the
first failure. Build targets run sequentially to limit peak memory rather than
via `-Dall`, matching CI. The individual steps, if you need them on their own:

```sh
zig fmt --check src build.zig build.zig.zon
git ls-files '*.sh' | xargs -r shellcheck -x   # every tracked script, not just tests/
zig build --summary all
zig build -Darch=x86_64 --summary all
zig build -Darch=wasm32 --summary all
zig build -Darch=wasm64 --summary all
zig build -Ddll=all --summary all          # Windows stub DLLs
zig build -Dexternal-stubs --summary all
zig build test --summary all
zig build test-cli --summary all
zig build test-cli -Darch=x86_64 --summary all
zig build fuzz -Dfuzz-seconds=10 --summary all
```

The same list is the `static-analysis` job in `.github/workflows/ci.yml`; a
command added to one belongs in the other.

For the edit-test loop, use `zig build test -Dtest-filter=<substring>` above;
`-Darch` does not change the host target of unit tests. Run
`zig fmt src build.zig build.zig.zon` to fix formatting, and `zig build --help`
to list build steps and options.

## Architecture

```
src/
  x86/         x86 interpreter (decoder, executor, FPU, SSE, thunks)
  loader/      PE loader, import resolution, resource parsers
  win32/       Win32 API stubs (37 DLL modules)
  jit/         x86-to-WASM basic block JIT compiler
  gui/         Web UI (HTTP server + JS frontend) and FLTK native backend
  platform/    Linux/WASM platform abstraction
  main.zig     Native CLI entry point
  wasm_main.zig  WASM entry point
```

~68K lines of Zig.

See [`docs/`](docs/README.md) for the documentation index: memory layout, JIT strategy, native execution, and Win32 API coverage. `docs/THREAT_MODEL.md` records the attack surface, trust boundaries, and known gaps. The web UI's HTTP routes and WebSocket message types are specified in [`docs/WEB_UI_PROTOCOL.md`](docs/WEB_UI_PROTOCOL.md).
