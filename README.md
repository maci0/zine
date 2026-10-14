# Zine

A Win32 PE interpreter that runs 32-bit Windows executables on Linux and in the browser. Software x86 CPU, PE loader, Win32 API compatibility layer, and GUI backends (native FLTK, and a web UI served by the
native process). Targets Win98/Win2K era applications and games.

No Windows installation, no Wine.

## What works

- Full MSVC 6.0 toolchain: CL.EXE, LINK.EXE, RC.EXE, NMAKE.EXE, and 17 more utilities run to completion
- 516 unit tests pass (1 skipped, 517 total) on the host with `zig build test`; the gate in
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

Changes after the latest release are listed under **Unreleased** below. The
package version, `--version`, and `build.zig.zon` stay at the last released
number until a release moves all three together, and a release is finished
with a `v<version>` tag on that commit, so every later release has one. A
released version is never edited retroactively. `0.x` has no compatibility
promise between versions, so a breaking change takes the next minor.

### Unreleased

### 0.6.0 (2026-10-14)

### 0.5.0 (2026-09-29)

#### Added

- Every `--help` now ends with the exit-status contract, so a script knows what
  a status means without reading the source: 0 the guest reported success, 1 the
  target could not be run or the guest exited with that status, 2 a usage error.
  The same three statuses were already used by `zine`, `zine-host`, and the
  WASI entry point; only the wording was missing.
- `--argv0=<name>` is listed in the help of every build, beside
  `--argv0 <name>`. Every parser accepted both spellings, but only the WASI
  `--help` said so, and only for `--jit-max-eip`.

#### Fixed
- `CharToOemA` and `OemToCharA` copied the whole source string into `lpszDst`,
  which Win32 gives one byte, so a guest holding the character on its own stack
  frame had its frame overwritten past the character. Both convert one
  character now and return it, as Win32 specifies.
  `CharToOemBuffA` and `OemToCharBuffA` filled the caller's whole destination
  with `cchDstLength` bytes, reading past the end of a shorter source string;
  they stop at the source terminator or the destination size, whichever comes
  first, and return the number of characters converted.
- `GetFullPathNameA` returned the length of the *input* name from its sizing
  call, so a guest following the two-call pattern sized a buffer for `foo.txt`
  and never got the resolved `C:\...` path. It measures the resolved path, and
  a buffer too small now returns the required size rather than copying the
  unresolved name back as a success. `GetFullPathNameW` resolves like its `A`
  twin instead of echoing a relative name, `GetLongPathNameW` reports the size
  needed when given no destination and fails on a short one, and
  `SetCurrentDirectoryW`/`GetLongPathNameW` translate their input guest
  address, which the `W` path stubs elsewhere already did.
- `GetTempPathA` demanded one byte more than the path it writes, so the exact
  3-byte buffer was rejected and a caller that retried on the returned size
  never got a result.
- `FindClose` returned TRUE for a handle that named no search, hiding a double
  close behind a success the guest could not check. It returns FALSE and sets
  `ERROR_INVALID_HANDLE`, as `CloseHandle` already did.
- `RegEnumKeyExA` wrote its two-byte subkey name without checking
  `lpcchName`, storing a NUL past the end of a one-character buffer and
  reporting `ERROR_SUCCESS`. A buffer that short now returns
  `ERROR_MORE_DATA`.
- `GetDiskFreeSpaceA`, `GetFileSizeEx`, `GetFileSize` and `GetClassNameA`
  dereferenced their `usize` out-pointers without translating the guest
  address, so on the WASM builds they wrote to the wrong place. They go
  through `trace.addr` like the sibling stubs.
- The WASI `--help` said `--` stops option processing. A leading `--` is the
  separator wasmtime forwards, so it deliberately does not; the help now says
  so.
- A guest whose `SizeOfImage` was large enough to wrap the WASM build's
  combined image+stack+heap buffer got a much smaller allocation than the
  image needs, and the buffer was then written at the untruncated offsets. The
  size is computed in u64 and an image with no 32-bit address is refused.
- A base-relocation block declaring a `VirtualAddress` near the top of the
  address space, or an import thunk table near it, wrapped the u32 sum that
  located the patch target and the IAT range. Both are now computed in u64, so
  the entry is dropped rather than patching a word the block never named.
- A `.rsrc` section whose `VirtualSize` wrapped left the rest of the image
  outside the write-protected window. The section bounds are now checked
  against the image before the carve-outs are built.
- The web UI served any readable file under `src/gui/`, which holds the
  server's own source and the FLTK bridge, to any request that named it. The
  request path is now a lookup in the embedded-asset list.
- In the web UI, Escape dismissed the Find and Replace dialog with the modal
  `cancel_dialog` instead of the `find_action` close its Cancel button sends,
  so the guest kept the dialog registered. Both now dismiss through the
  dialog's own handler. A window dragged past the edge of the page also took
  its titlebar, the only handle that moves it, out of reach; dragging and
  resizing now keep it on screen. Host errors are shown in the words the host
  wrote for the person at the keyboard, without an "API Error:" label in
  front of them.
- `zig build -Darch=x86_64` no longer fails to compile: two `log.err` calls in
  the compat-mode thunk path passed no argument tuple, and a module's entry
  point was annotated `?u32` while the field it initializes is `?usize`, which
  only compiled where `usize` is 32 bits.
- `RegisterWindowMessageW`, `RegisterClipboardFormatA` and
  `RegisterClipboardFormatW` minted a fresh id on every call and kept no name,
  so a guest that registers the same string twice never got the same id back
  and every `==` on the result failed. All four entry points now share one name
  table and one id space, as Win32 specifies, and `RegisterClipboardFormatW`
  decodes its UTF-16 name instead of reading it as ANSI. A name longer than the
  table entry keeps its id for that call rather than aliasing every other name
  sharing the prefix.
- Menu item state was keyed by the packed value `(hMenu << 16) | uId`, so a
  menu handle above `0xFFFF` collided with a lower handle's ids. The key is now
  the pair. A full table also rewrote the last live entry, reporting one item's
  flags as another's; the state is now simply absent, which reads back as no
  flags set. The same overflow aliasing is gone from listbox state, where the
  17th listbox was handed the first one's items and cursor.
- `FindFirstFileW` and `FindNextFileW` reported `cFileName` one UTF-16 unit per
  byte, so enumerating a directory holding `café.txt` handed the guest `cafÃ©`
  and a name it could not reopen. Both now widen the host name from UTF-8.
- Listbox items, tooltip text, popup menu item text, and recorded window class
  names were cut at a byte boundary, which can land inside a UTF-8 sequence and
  store undecodable text. They cut on a character boundary now, and a class
  name too long for the table is dropped rather than truncated into a different
  name that would answer for another control.
- `zine-host --help` enumerated four of the `ZINE_*` settings the module reads
  and presented the list as the whole set. It now names none of them, because
  the module's own `--help` is what lists them.
- `--quiet` silences the GUI backends. The web UI and the FLTK backend printed
  their startup banner with a raw write to stderr, so a run promised to report
  "only warnings and errors" still announced itself, and the web UI repeated
  the URL the startup line already carries. The banner is gone; the URL is in
  the startup line, which honors the log level. The same raw writes on the
  failure paths (a bind that fails, a client request that errors) now go
  through the log, so they carry its level, its timestamp, and its color
  policy.
- A number in an `.rc` script longer than its field could reach, a coordinate
  or a `#define` value of 4294967296 bytes, aborted the resource compiler
  with an integer overflow. Numbers now saturate at the field's maximum, and a
  coordinate or point size that does not fit the format it is written into
  clamps to that field's range.
- The native `--help` listed no `ZINE_CWD` while the native build validated it
  and pointed a rejected value at `--help` for the accepted values. It is
  listed now, with the note that only the WASI build consults it.
- `ZINE_WEB_HOST` and `ZINE_WEB_PORT` under a WASI run were read by no code
  path, and the misspelling check stayed quiet because the names are known. A
  WASI run that finds either set logs `ignoring <name>: this build has no web
  server`, so exporting it for a native run no longer leaves a run with no web
  UI and no explanation.
- The startup line reports the active log level and guest working directory
  alongside the version, mode, and web address, on both the native and the
  WASI build, so the resolved configuration is readable from the run itself.
- `GetStockObject` ignored a failed registration and returned a handle no
  lookup resolves. It reports the failure the way every other object creator
  does now.
- The build failed to compile the unit tests, the x86_64 executable, and the
  `zine-host` help: an ignored `registerDc` result, a `@TypeOf` of a struct
  field, and a `log.err` call with no argument tuple.

### 0.4.0 (2026-09-28)

### 0.3.0 (2026-09-27)

#### Breaking and migration

- `zig build test -Dtest-filter=<substring>` now fails at configure time when
  the filter matches no test. The compiler reported a filter matching nothing
  as `run test success` with no test count, so a mistyped filter was a green
  build that ran nothing after a full compile. The filter matches the
  qualified test name, which spells the source path with dots and without the
  extension, so `x86.decoder` selects the tests in `src/x86/decoder.zig` while
  `x86/decoder` and `log.zig` select none and are now refused by name.
- The unit suite runs with diagnostics at their quietest level. The loader,
  stub and parser tests drive the deliberate failure paths, and the suite
  emitted around 1400 lines of expected warnings and errors that buried a real
  failure among them. `ZINE_LOG_LEVEL` raises the level as before.
- The build now fails when `src/gui/van.min.js` does not hash to the digest
  recorded as `sbom_vanjs_sha256` in `build.zig`. The vendored VanJS copy is a
  re-wrap, so no upstream release names it, and nothing checked its bytes; the
  digest is now recorded, checked on every configure, and written into the
  shipped SBOM. Re-wrapping or hand-editing the file means restating
  `sha256sum src/gui/van.min.js` in the same edit.
- The build now requires exactly the Zig version pinned in `build.zig.zon`
  (`.minimum_zig_version`), where a newer patch release used to pass the
  version check. The shipped binaries are produced by that compiler, and a
  patch release is free to change codegen, so builds on a newer Zig were not
  comparable with CI or with a release. Bump the field in `build.zig.zon` to
  move the project forward.
- `zig build -Ddll=<name>` now fails and lists the valid names when `<name>`
  matches no stub. It used to build only the default executable, install
  nothing extra and report success, so a typo in a DLL name could reach a
  release cut unnoticed.
- Guest ANSI strings are decoded as CP1252, the Windows default code page,
  instead of being passed through as UTF-8. Window titles, dialog and menu text,
  and PE string-table resources with non-ASCII bytes now render as on Win98,
  which changes text that previously displayed as raw UTF-8 or mojibake.
  Guests that store UTF-8 in an ANSI field still need to convert it themselves.
- Web UI dialog answers are validated before they reach the guest.
  `font_chosen` refuses a point size below 1, and `page_setup_chosen` refuses
  an integer too large for the field instead of answering with the default
  margin or paper size. Both answer with the existing `{"type":"error"}`
  envelope naming the field.
- Web UI commands that name a guest file must send a relative path with no
  drive letter, backslash, NUL, or `.`/`..` component. Anything else, and any
  path with more than 128 components, is refused instead of being resolved:
  upload and launch answer `Invalid path`, and a directory listing comes back
  empty. Frontends that sent absolute or drive-qualified paths must send paths
  relative to the virtual C: root.
- `UnmapViewOfFile` now releases the view even when the writeback fails. It
  still reports `ERROR_WRITE_FAULT` and leaves the file unchanged, but a guest
  that hit a permanent flush failure used to strand the view, and once 64 of
  them were stranded `MapViewOfFile` failed for the rest of the session.
- `SetEnvironmentVariableA` and `_putenv` reuse the entry a delete emptied, so
  a guest cycling one variable's value no longer adds an entry to the override
  list per cycle. A name that is deleted and then set again still resolves to
  the new value.
- `_spawnvp` and `_spawnl` no longer leak the argv and environment strings they
  build for the child; they are released once the child has been reaped.
- `ZINE_WEB_HOST`, `ZINE_WEB_PORT`, and `ZINE_CWD` are validated at startup
  on every build. An empty or malformed address, port, or working directory
  exits with status 2 before the guest loads, matching how `ZINE_LOG_LEVEL`
  already behaved. Unset the variable, or give it a valid value, in launch
  scripts and runtime environment configuration. The resolved web address is
  printed at startup. Only the WASI build uses an accepted `ZINE_CWD`.
  `ZINE_TRACE`, `ZINE_TRACE_INSN`, and `ZINE_PROFILE` are read the same way
  on every build: any value, including empty, enables the toggle.
- A `ZINE_*` environment variable that names no setting now logs a warning and
  is otherwise ignored. A misspelled knob is the one misconfiguration a run
  cannot detect on its own: the value is never read, so the default holds and
  nothing else misbehaves. The valid names are the table under
  [Runtime diagnostics](#runtime-diagnostics).
- A non-loopback `ZINE_WEB_HOST` exposes the emulator screen and accepts
  synthetic input from the network. It logs a warning and restricts accepted
  WebSocket origins to that address, so a browser reaching the UI through
  another hostname is refused with HTTP 403.
- `zig build` builds **ReleaseSafe**. At 0.2.0 it used Zig's Debug default, so
  the installed binaries are faster and carry no DWARF. Pass
  `zig build -Doptimize=Debug` for a debugging loop and debugger symbols;
  `--release=fast` and `--release=small` still select their own modes.
- `-Dfltk` requires `-Darch=x86_64`, as the 0.2.0 notes already say, and is now
  rejected during configuration with that requirement named, instead of failing
  later in the C compiler or linker. The bridge still looks for FLTK only in the
  Debian and Ubuntu 1.3 layout and names the packages when they are missing.
- The web UI's static paths answer `405` with `Allow: GET, HEAD` for any method
  other than `GET` or `HEAD`, and `/ws` answers `405` with `Allow: GET` for
  anything else, so a frontend that posts to an asset path gets a refusal
  instead of the file. Every non-file response is
  `text/plain; charset=utf-8` carrying the reason; the JSON `error` frame stays
  on the WebSocket side. Routes and message types are specified in
  [`docs/WEB_UI_PROTOCOL.md`](docs/WEB_UI_PROTOCOL.md).
- A Web UI `print_chosen` message whose `from`, `to`, or `copies` is below 1,
  and a `context_menu_select` whose `id` does not fit the guest's u32 result,
  are answered with an `error` frame and ignored. Pages are 1-based and a copy
  count below 1 is not a request; the menu id used to be truncated, so a large
  id selected a different item than the client asked for. A `command` or
  `listbox_select` id outside its range was already refused this way.
  `page_setup_chosen` also refuses a `paperW` or `paperH` below 1 and an
  `orientation` other than 0 or 1.
- A web UI mouse message with `button` 1 (middle click) is dropped instead of
  being delivered as a primary-button press, which used to click wherever the
  user scrolled. Only `button` 0 and 2 reach the guest. A frontend that needs
  the middle button has to keep it to itself until the guest window uses one.
- A web UI `wheel` message may carry `x` and `y`; both default to 0, so an
  older frontend keeps working, and a `WM_MOUSEWHEEL` now lands under the
  pointer the user scrolled at instead of at the window origin.
- `zig build -Darch=wasm32` and `-Darch=wasm64` compile again. The JIT host
  loop registered the SMC flush hook against a host instance that no longer
  existed, so the WASI targets failed to build.
- Wide (`W`) API strings convert as whole code points instead of one truncated
  byte per UTF-16 unit. Text set through `SetDlgItemTextW`, `MessageBoxW`,
  `AppendMenuW`, the status bar, or a window title keeps its characters when a
  string is longer than the stub's buffer (the cut now lands on a character
  boundary), an unpaired surrogate becomes U+FFFD rather than blanking the whole
  string, and a filename passed to a `W` file or module API is encoded per code
  point rather than losing everything above U+00FF.
- Case-insensitive path fallback folds case per code point, so a guest opening
  `CAFÉ.TXT` finds `café.txt` on disk. Names that are not valid UTF-8 keep the
  previous byte comparison, since the host filesystem accepts arbitrary bytes.
- `LCMapStringW`, `LCMapStringEx` and `CompareStringW` honor the locale they
  are given for the letter I, which Turkish and Azerbaijani case differently:
  `I` lowercases to dotless `ı` and `i` uppercases to dotted `İ`. They
  previously discarded the locale and used the Unicode default mapping, so
  Turkish text was folded and sorted as if it were English, and `İ` and `ı`
  never compared equal under `NORM_IGNORECASE`. `LCMapStringEx` now reads its
  `lpLocaleName` (`tr-TR`, `tr_TR`, `tr`); a null or unrecognized name uses
  the emulated default locale, as before. The ANSI (`A`) entry points are
  unchanged, because CP1252 encodes neither `İ` nor `ı`.
- Bitmap and pixel-buffer sizes are computed in 64 bits and rejected past a
  documented cap, so `CreateCompatibleBitmap` or `CreateDIBSection` with a
  guest-supplied dimension whose `width * height * bpp` passes 4 GB returns
  failure instead of aborting the emulator on an overflow. `CreateDIBSection`
  also negates a negative `biHeight` in 64 bits, so `biHeight = INT32_MIN` no
  longer traps. A DIB created with `biBitCount` below 32 is read and written
  within its own allocation: the pixel slice is bounded by the recorded buffer
  length, where it was previously taken as four bytes per pixel regardless of
  the guest's bit count.
- `BitBlt` refuses a source DIB below 8 bits per pixel rather than dividing by
  a zero bytes-per-pixel, and `LineTo`/`Rectangle` and `Polygon` carry their
  line-walk and scanline interpolation in 64-bit arithmetic, so a line across
  the full coordinate range and a polygon edge spanning a wide x range no
  longer overflow. `Ellipse` fills its boundary pixels instead of stopping one
  column short of the outline it draws. A font `lfHeight` of `INT32_MIN` or a
  value past 16M clamps to a height the text metrics can be derived from.
- `fread` refuses a `size * count` product that does not fit the host's address
  space (reachable on the 32-bit build with two 64K arguments) and reports it
  through the stream error indicator, like `fwrite` already did.
- `SizeofResource` bounds its resource-directory walk by the mapped image
  length and does the end-offset sum in 64 bits, so a data directory pointing
  past the module's own mapping is rejected instead of read. A malformed
  import descriptor whose name RVA wraps the 32-bit add is skipped rather than
  resolved from offset 0 of the image.
- A DirectSound format with a zero `nBlockAlign` or `nAvgBytesPerSec` now gets
  the values the sample rate and bit depth imply, so the play cursor advances
  instead of freezing for the life of the buffer.
- A UTF-16 string in a dialog resource keeps the character that follows an
  unpaired high surrogate, which was consumed and dropped.
- `printf` `%e`, `%E`, `%g`, and `%G` print the exponent form C specifies
  (`%e` of 12345 is `1.234500e+04`, not `12345.000000`) with `%g` choosing
  between the two styles and dropping trailing fractional zeros, and the
  floating-point conversions honour the field width like the integer ones.
  `nan` and `inf` are unchanged.

#### Security fixes

- Guest-controlled lengths and counts stay inside the buffers they name.
  `FormatMessageA` with `FORMAT_MESSAGE_ALLOCATE_BUFFER` allocates the length of
  the message it is formatting instead of a fixed 256 bytes, so a long source
  string no longer overruns the allocation. GDI32 blits are bounded by the
  DIB's own allocation rather than by `width * height * 4`, which a DIB narrower
  than 32 bits per pixel overstates, and `CreateDIBSection` and
  `SetDIBitsToDevice` compute their geometry in 64-bit, so a `biHeight` of
  `INT32_MIN` or a wrapping width fails the call instead of trapping or
  advertising a bitmap larger than its buffer. DirectDraw clips `Blt`, `BltFast`
  and `Flip` to the surface buffer, so a source rectangle or a surface
  declaration larger than the viewport no longer copies, reads or publishes
  memory past the surface.
- The `.res` writer sizes its output from the resource counts the parser can
  hold. A `.rc` file with many long strings, dialogs, menus or icons wrote past
  the fixed stack buffers instead of producing a resource file.
- `SizeofResource` stops its resource-directory scan at the end of the mapped
  image, and the export-directory bounds in the module loader and the import
  name lookup are checked in 64-bit. A module whose directory sizes or RVAs wrap
  the 32-bit addition no longer reads past its own mapping.

- The linked native executables are checked for a static link and a
  non-executable stack, in a `hardening` gate step and in CI. The other usual
  controls are absent by design and stay absent: the images load at a fixed
  `0x70000000` so the low addresses stay free for guest PEs, which rules out
  PIE; a static binary has no dynamic relocations for RELRO or `BIND_NOW`; and
  Zig's stack protector needs libc, whose dynamic loader would give up the
  self-contained artifact. ReleaseSafe bounds checks carry the rest.
- `LoadStringA`/`LoadStringW` read the PE string table only inside the mapped
  image and inside the block's declared size. A module whose resource
  directory or string lengths point past its own mapping returns an empty
  string instead of reading host memory beyond it. A module handle that names
  no loaded module now yields an empty string as well, where the lookup
  previously read whatever the address held.
- The host home directory is redacted from every diagnostic before it reaches
  stderr, so a trace pasted into a bug report no longer carries the local
  account name. A run whose environment has neither `HOME` nor `USERPROFILE`
  records paths unchanged.
- An environment variable whose value is the operator's identity (`USER`,
  `USERNAME`, `LOGNAME`, `EMAIL`) is traced as `<redacted>`, so a guest that
  reads `USER` does not write the account name into the trace. Every other
  variable, including `HOME` and the path variables, is recorded unchanged.
- `SetClipboardData` traces the size of a CF_TEXT transfer, not the text. The
  clipboard carries whatever the user last copied, which is rarely what a bug
  report needs.
- A response file (`@file`) is traced by name and size, not by content. The
  arguments it expands are traced individually, and the file itself holds
  whatever the caller's toolchain put in it, absolute paths naming the local
  account among them.
- `GetPrivateProfileStringA` traces the size of the value it returns, not the
  value. An INI file holds the user's own settings, and `GetPrivateProfileSectionA`
  already recorded only a byte count.
- Web UI file uploads resolve strictly inside `drive_c/` rather than through
  prefix matching, so a crafted directory or file name cannot retarget the
  write.
- Every web UI asset response carries `Referrer-Policy: no-referrer`, and the
  content security policy adds `object-src 'none'; base-uri 'none';
  frame-ancestors 'none'`. A `304 Not Modified` repeats
  `X-Content-Type-Options`, `X-Frame-Options`, and `Referrer-Policy` alongside
  the `ETag`, but not `Content-Security-Policy`. A cache that treats a
  revalidated response as a full header replacement can therefore end up
  serving the asset without the policy. Proxies or frontends that rewrite
  these headers still need to keep them.

#### Added

- `ZINE_WEB_HOST` (default `127.0.0.1`) and `ZINE_WEB_PORT` (default `1995`)
  for the native web UI, and `ZINE_CWD` for the WASI guest working directory.
- `ZINE_VIRTUAL_CLOCK_NS` and `ZINE_CLOCK_STEP_NS` drive the guest clock from a
  fixed start instead of the host clocks, so two runs of the same guest that
  issue the same calls in the same order see the same time values.
- `tests/check.sh` and `CONTRIBUTING.md` describing the single pre-PR gate.
- A `reproducible` step in that gate: it builds both native executables twice,
  the second time from a copy of the sources at a different path, and requires
  every installed file to be byte-identical. CI runs it after the four
  architecture builds, so a build that starts recording the checkout
  directory, the host or the clock in the artifact fails the gate instead of
  shipping two different binaries from one commit.
- `docs/THREAT_MODEL.md`, a risk ranking of the host process.
- A transfer budget for the four precompressed web UI assets, checked by
  `zig build test`, so the bytes a visitor downloads cannot grow unnoticed.
- A CycloneDX 1.5 SBOM of every third-party component behind a shipped
  artifact, installed to `share/zine/sbom/zine.cdx.json` by `zig build` and
  writable on its own with `zig build sbom`. It is generated from the pinned
  manifests, and the build fails if the inventory no longer matches the
  `zig-toml` pin, so a dependency bump cannot ship a stale list. Its
  `metadata.tools` also names the Zig version that compiled the artifact, read
  from the compiler rather than from `build.zig.zon`, so the installed files
  say whether the toolchain needed to reproduce them is the one in use.
- Named gate steps in `tests/check.sh`: `bash tests/check.sh --list` prints
  them and `bash tests/check.sh <name>` runs one, so a single check no longer
  means running the whole gate.
- A `check_web` step in that gate: every tracked JavaScript file is parsed
  before a merge. `src/gui/app.js` is embedded into the wasm artifact and
  served to a browser, and nothing else in the gate read it, so a syntax error
  there shipped and surfaced only as a page that does not run.
- `zine --quiet` (`-q`) raises the log level to `warn` for one run, on native and
  WASI, so a chatty environment can be quieted without rewriting
  `ZINE_LOG_LEVEL`.
- `--jit-max-eip` on the WASI build takes its value as a separate argument,
  like `--argv0`, in addition to `--jit-max-eip=<u32>`. The separate-argument
  spelling reported "requires a value" and exited 2 even when a value followed.

#### Fixed

- The web UI's content-addressed assets are served again, and the icons join
  them. The document named each asset by its digest (`/win2k-<digest>.css`),
  and the server looked that name up to the compressed bytes, whose digest is
  not the one the URL carries, so every digested request answered 404 and the
  page loaded unstyled and inert. A digested name now resolves to the content
  it names, checked against the digest in the URL. The nine icons in
  `src/gui/assets/` are embedded and digested like the scripts, so they are
  served `immutable` and cost a reload no request and no round trip, instead of
  a revalidation each on a URL that cannot change. The one list of what is
  embedded, and which of it is precompressed, is
  `src/gui/web_asset_paths.zig`, read by the build and the server alike.
- `ZINE_VIRTUAL_CLOCK_NS` and `ZINE_CLOCK_STEP_NS` are read by the WASI build
  as well as the native one. The WASI `--help` listed both, and the README
  listed both without a build qualifier, but only the native entry point parsed
  them, so a WASI run on a simulated clock silently used the host clocks. A
  rejected value on either build now names the setting, the values it accepts,
  and `zine --help`, like every other usage error; before, the startup
  diagnostics were the only ones without that hint.
- The `check_c` step of that gate reported success on a C source that does not
  compile. It runs inside `if ! ...`, which suspends `errexit`, so a failing
  compile in the loop over the sources did not stop it and the step exited on
  the status of the last compile. It now returns the collected status, and the
  same guard covers the new `check_web` step.
- The guest argv/envp block can no longer be written past. `__getmainargs`
  copied the host command line and environment into a fixed 256 KB guest block
  with no capacity check, so a long command line or a large environment wrote
  into whatever the guest heap placed after it. Arguments and environment
  entries that do not fit are now dropped, the first argument that does not fit
  ends the list, and both losses are logged.
- A block the JIT cannot compile is no longer marked as compiled for the rest
  of the run. `compile` took the "already compiled" mark before the work that
  can fail, and that mark is what gates a compile attempt, so one failed
  translation silenced the block permanently on `zine --jit`.
- Closing a dialog no longer strands the JSON the web UI replays to
  reconnecting clients. The cached copy was dropped without being freed, and
  the next dialog had nothing left to free, so a guest that cycled dialogs
  leaked one string per cycle.
- A `.bat`/`.cmd` target runs on the WASI builds. Resolving `%~dp0` asked for
  `realpath`, which WASI has no call for, so every batch file there exited with
  `cannot open batch file`. The path is now used as spelled when the host
  cannot canonicalize it, and a relative one expands to the drive-relative
  `C:\` form rather than `C:name`.
- A preopened WASI directory no longer claims a path that merely starts with its
  name: with `/home/user` preopened, `Z:\home\username\file.txt` was read as
  `name/file.txt` inside `/home/user`. The match ends on a component boundary
  and the longest matching preopen wins.
- The web UI's content-addressed stylesheet and scripts are served again. The
  document names each asset by its digest (`/win2k-<digest>.css`), and those
  names exist only inside the build, so the server answered the document's own
  requests for them with 404 and the page loaded unstyled and inert. A digested
  URL now resolves to the bytes this build embedded, and one no build produced
  stays a 404.
- The batch interpreter treats a NUL byte in a `.bat`/`.cmd` file as the end
  of that line, the way the C string the line becomes would, and a line whose
  first token is an empty quoted string runs nothing instead of handing an
  empty program name to the launcher. A fuzz harness covers both
  (`src/fuzz/bat.zig`).
- `ctime` prints the day of month space-padded to two columns and the clock
  fields without a sign, so the epoch reads `Thu Jan  1 00:00:00 1970` instead
  of `Thu Jan +1 +0:+0:+0 1970`.
- A `SetDIBitsToDevice` destination rectangle that starts at or past the surface
  edge is clipped to an empty span instead of trapping the emulator on a
  negative span width, and the `SetDIBitsToDevice` line count saturates rather
  than overflowing its `int` return.
- `wcstol` and `_wtoi` saturate on a digit run that overflows `int`, matching
  the narrow `strtoul` and `atoi`, and `wcstol` falls back to base 10 for a
  radix outside 2..36 instead of trapping the conversion.
- The web UI's font dialog applies the chosen face, size, and style again. The
  OK button ran its handler instead of registering it, so the dialog never
  closed and the guest never saw the selection.
- Enter in any web UI dialog now runs that dialog's action button, as it does
  on Windows. Typing a name in the Open or Save dialog and pressing Enter opens
  it, and the Print, Page Setup, Font, color, and Find dialogs submit the same
  way as clicking their button.
- An empty file name in the web UI's Open and Save dialog is reported in the
  dialog instead of leaving the button with nothing to do.
- The web UI's Open and Save dialog shows a pending state while a folder is
  being listed, instead of leaving the folder just left on screen under the new
  name, where opening an entry would have read it from the wrong directory.
- A new web UI session clears the window and taskbar icons. The reset looked for
  an element that does not exist, so the previous guest's icon stayed in the
  titlebar and the taskbar.
- A web UI status message that goes away on a timer no longer takes down a
  newer message with it. A disconnect or a failed asset load now stays on
  screen instead of disappearing a few seconds later.
- A module already loaded from one file is no longer served for a request that
  resolves to a different file with the same name. Loading a second `foo.dll`
  from another directory now fails with `ModuleAlreadyLoaded` instead of
  handing the guest the first image under the second's name.
- A `resize` `sizeType` and a `listbox_select` `id`/`index` outside the range
  the callbacks take are refused with an error frame instead of being narrowed,
  which on a 32-bit host (wasm32) trapped and took the emulator down. Frontends
  send values inside those ranges.
- `IDirectDrawSurface::Release` and `IDirectSoundBuffer::Release` now return
  the surface pixel buffer and sound buffer to the emulator, and the freed
  slots are reused. A guest that creates and releases surfaces or sound
  buffers in a loop no longer strands one buffer per surface or runs the
  fixed pools dry.
- `DestroyWindow` releases the per-window listbox, progress bar, up-down, and
  date-time picker state, and each of those tables is now bounds-checked. A
  guest that creates more controls than fit no longer writes past the end of
  the table.
- On WASI, `_spawnvp` no longer strands the child process environment and its
  128 MB child address space after each child exits. A guest that spawns
  helpers repeatedly no longer exhausts module memory.
- A WASI spawn whose child path does not fit next to the main executable's
  directory fails with a logged error instead of being joined past the end of
  the destination buffer.
- `strtoul` and `atoi` report a bare `0` (or `00`) as a complete conversion.
  With radix `0` the leading octal digit was consumed but not counted as parsed,
  so `end` stayed at the start of the string. Callers that loop on `*end` to
  advance past a parsed number now advance past the digit.
- A dialog control whose class name holds a quote, a backslash, or a control
  character is escaped like the other dialog strings, so the frontend parses the
  dialog instead of dropping the whole resource. Parsed class names are also
  released, which a malformed resource used to leak on every parse.
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
- `WaitForSingleObject` honors a finite timeout when the handle is a mutex
  instead of blocking until the mutex is released, and a host sleep covers its
  full interval when a signal cuts it short, so a guest `Sleep` no longer
  returns early.
- Web desktop Start button, common dialogs, and modal dismissal behave
  consistently across the desktop, the taskbar, and Escape.
- A top-level menu caption in the web UI opens its dropdown on a tap as well as
  on a hover, and the dropdown a tap opened closes on a click elsewhere, so the
  guest menu bar is usable on a touch screen.
- Activating a desktop icon or a Start menu entry with nothing able to start
  the program reports it in the status bar instead of leaving the click with no
  visible result.
- The web UI serves the document, stylesheet, and both scripts over one
  keep-alive connection instead of closing the socket after every asset.
  A revalidated asset answers `304` on that same connection.
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
- A target file that is not a usable PE reports a plain-language cause and a
  hint instead of the loader's internal error name.
- The native and WASI `--help` option lists lost a stray blank line, and the
  WASI-only `--jit-max-eip` is documented as the u32 it accepts (decimal or 0x
  hex).
- The web Open and Save dialog filters the file list by the guest's
  "Files of type" patterns, and says "This folder is empty." or "No files
  match the selected type." when there is nothing to list.
- The web Print dialog reports a page range that ends before it starts instead
  of handing that range to the guest.
- The web Font dialog applies a style typed into its style box, as its font and
  size boxes already did.
- Web dialogs are clamped to the viewport, so a narrow window no longer forces
  the page to scroll sideways.
- The web window's maximize button switches to a restore glyph and label once
  the window is maximized.
- The web Start menu waits briefly for the desktop listing, then names an empty
  Desktop the way the rest of the interface names it.
- The x86 shift overflow flag is defined for a count of 1 (`shl`: the top bit of
  the result XOR CF, `shr`: the sign bit the shift moved out) and pinned to 0 for
  any other count, so a guest that branches on `OF` after a shift reads a
  defined value.
- A PE image that needs more writable-section entries than the protection table
  holds is rejected at load with `PE write-protection table overflow`, instead
  of dropping a section and silently discarding the guest's writes to it.
- File and stream I/O failures report the error instead of reading as success or
  EOF: `CopyFileA`/`CopyFileW` return FALSE with `ERROR_WRITE_FAULT` on every
  host failure, including the open and create steps and on the non-Linux
  branch, a host read error in a file mapping sets `ERROR_READ_FAULT` rather
  than zero-filling, and MSVCRT sets the stream error indicator that `ferror`
  reports. `ReadFile`, `WriteFile`, `WriteConsoleA`/`W`, and `ReadConsoleW` now
  set `ERROR_READ_FAULT`/`ERROR_WRITE_FAULT` and report a byte count of zero on
  failure instead of leaving the caller's count untouched, `SetEndOfFile` says
  which of its two host steps failed, and a `fwrite` over the 256 MB limit sets
  the stream error rather than reading as a short write. `fputc`, `putchar`,
  `fprintf`, `fwprintf`, and `fputs` log a dropped write, `freopen` abandons the
  reopen when the old stream cannot be closed, and `RC` reports a truncated
  `.res` instead of leaving a partial file for the next build step to link.
- A Winsock failure names itself. `WSAGetLastError`/`WSASetLastError` were
  stubs that always returned or discarded 0, so a refused connection, an
  unreachable host, and a bad argument were the same `SOCKET_ERROR` to the
  guest. Every failing socket call now records the Winsock code its host errno
  maps to, `send` on a target without real sockets reports failure instead of
  claiming the bytes went out, and a loadable module that is shorter than its
  own size table is rejected at load rather than parsed from an uninitialized
  buffer.
- The guest argv array is read as 32-bit pointers on a 64-bit host (x86_64 and
  wasm64) rather than as host-width values, which on wasm64 straddled the array
  elements and gave the guest a wrong command line. The host stack range is read
  from a streamed `/proc/self/maps`, so it no longer depends on the `[stack]`
  mapping fitting in one read.
- A JIT block cache entry is reused only while the guest bytes at its entry EIP
  are the bytes it was compiled from, so a guest that patches its own code, or a
  region that is unmapped and remapped at the same address, no longer runs a
  stale translation. A module already mapped is reused when a later
  `LoadLibrary` names it as a path (`bin/GAME.DLL` finds `game.dll`), so one
  file no longer gets two module bases with separate writable data.
- Keyboard state, pointer deltas, the timer table, and the web UI's socket sends
  are taken under their locks, so a second GUI thread or a web command cannot
  read a half-rewritten keyboard map, lose a mouse delta, or race the cached
  dialog JSON.
- The Win32 thread registry, the sync-object table, the `GetProcAddress` cache,
  the command line, and the child-process table are read and written under
  their own locks, and a child slot stays reserved across the host `spawn` that
  the mutex cannot cover. A guest with two threads calling `CreateProcess`,
  `GetProcAddress`, `GetCommandLineA`, or waiting on a synchronization object
  no longer has two calls claim the same slot, read a half-published thread or
  object entry, or receive a command line pointer that a racing thread has
  already freed.

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

Requires [Zig 0.16.0](https://ziglang.org/download/); the gate requires that
exact version. Builds are ReleaseSafe by
default; add `-Doptimize=Debug` for a debugging loop. Every build except
`-Doptimize=Debug` strips debug info: unstripped DWARF records the checkout
directory and the toolchain's lib path, so the same source would produce a
different binary on every machine. The remaining output is path-independent:
the `reproducible` gate step builds both native executables twice from copies
of the tree at different paths and requires the installed files to match byte
for byte.

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

### Third-party code

Three things come from outside this repository, and each is pinned where it
can be:

| Component | Version | How it arrives |
|---|---|---|
| `zig-toml` (the only Zig package dependency, MIT) | commit `a73c94`, package `0.3.0` | `build.zig.zon` names a commit-pinned archive URL with a Zig content hash |
| VanJS (MIT), embedded in the web UI | repackaged, no upstream release named; SHA-256 pinned | vendored at `src/gui/van.min.js`, shipped as `share/licenses/zine/van.LICENSE` |
| `websocket-client`, MSVC integration tests only | `1.9.0` | `tests/requirements.txt`, exact pin with two sha256 hashes |

`zig build sbom` writes a CycloneDX 1.5 inventory of these (plus zine itself)
to `zig-out/share/zine/sbom/zine.cdx.json`, and every install ships it. The
build re-checks the `zig-toml` commit and version in the inventory against
`build.zig.zon` and fails if they have drifted, so the list cannot describe a
dependency the build no longer uses. It also hashes the vendored `van.min.js`
and fails if the digest is not the one recorded in `build.zig`, so the copy
that ships is the one that was reviewed. Upgrading a component is a deliberate
edit of its pin and of the inventory together.

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
| `ZINE_VIRTUAL_CLOCK_NS` | Nanoseconds since the Unix epoch that the first guest clock read returns; unset uses the host clock |
| `ZINE_CLOCK_STEP_NS` | Nanoseconds the virtual clock advances per read, default `1000000`; requires `ZINE_VIRTUAL_CLOCK_NS` |
| `ZINE_CWD` | Absolute POSIX path used as the guest working directory by the WASI builds, at most 1021 bytes; unset uses `.` |
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

Environment lookups add a second rule: `USER`, `USERNAME`, `LOGNAME`, and
`EMAIL` record `<redacted>` in place of the value, because those carry the
account name bare rather than inside a path. `getenv('PATH')` and every other
variable still record their value, so the trace stays useful for module
resolution.

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

`ZINE_VIRTUAL_CLOCK_NS` replaces the host clock the guest reads through
`GetTickCount`, `GetSystemTime`, `QueryPerformanceCounter`, `time`, and the
rest, with a cursor that starts at the given number of nanoseconds since the
Unix epoch and advances by `ZINE_CLOCK_STEP_NS` on every read. A guest wait
(`Sleep`, `SleepEx`, `WaitForSingleObject`, `select`, a Win32 timer) advances
that cursor by the duration it asked for instead of blocking the host, as does
a host-waiting poll (the empty `GetMessage` queue, a modal dialog or file
dialog awaiting the frontend, the context menu, frame pacing), so a replay
reaches the same clock values without spending the run's worth of real time in
sleeps:

```sh
ZINE_VIRTUAL_CLOCK_NS=1700000000000000000 ./zig-out/bin/zine.x86_64 drive_c/myapp/app.exe
```

Emulator instrumentation (log timestamps, the profiler) always reads the host
clock, so simulated time never distorts the measurements of the run itself.
The identifiers the guest reads are emulated too: `GetCurrentProcessId` and
`GetCurrentThreadId` report a fixed process id and a per-thread id taken from
the thread registry in creation order, never the host's pid or pthread ids,
which differ on every run and on every backend. `ZINE_CLOCK_STEP_NS` without
`ZINE_VIRTUAL_CLOCK_NS` exits with status 2, as does a negative or malformed
value for either variable. The clock covers time only: file contents, network
results, and OS thread interleaving still come from the host, so a replay is
byte-for-byte reproducible only for a guest whose behavior does not depend on
them.

`ZINE_CWD` is how a WASI runtime tells the build where the guest should run,
since WASI has no `realpath`. It must be an absolute POSIX path; a relative or
empty value exits with status 2 instead of silently running the guest in `.`.
Both builds validate it at startup, so a rejected value is reported by the
native binary too, and only the WASI build reads the accepted one.

## Build options

| Flag | Purpose |
|---|---|
| `-Darch=x86\|x86_64\|wasm32\|wasm64` | Target architecture (default: x86) |
| `-Dall` | Build all four architectures |
| `-Doptimize=Debug\|ReleaseSafe\|ReleaseFast\|ReleaseSmall` | Optimization mode (default: ReleaseSafe) |
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
require Python 3 and the dependencies in `tests/requirements.txt`, installed
with `uv pip install -r tests/requirements.txt --require-hashes` so the
sha256 pins in that file are actually enforced.

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

`zig build fuzz` mutates the seed corpora of the menu, dialog, icon, and PE
header parsers, the string-table, resource-directory, and export-directory
walks, the batch script interpreter, and the `.rc` resource compiler, and
feeds every input to the parser under Zig's safety checks.
A failing input is written to `zig-out/fuzz/<target>-<n>.bin`; minimize it, fix
the cause, and add its bytes to the `seeds` array of that target's harness in
`src/fuzz/`.

```sh
zig build fuzz -Dfuzz-seconds=30            # per target
zig build fuzz -Dfuzz-seconds=30 -- menu.bin pe.exe   # also replay captured files
```

The harnesses assert the parser's output contract, not just absence of
crashes: a menu that parses must render as a valid JSON menu object, a
successful `PEParser.parse` must place its headers inside the file, and a
resource or export lookup that resolves must hand back bytes the mapped image
actually holds, the same way twice.
A compiled `.rc` script must emit a `.res` image whose records all fit, and
must emit the same one twice, since the `#define` table lives in the process.
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
Besides Zig 0.16.0, the CI checks require Bash, Git, ShellCheck, `node` (for
`check_web`), `sed`, `awk`, `cmp`, `readelf`, `grep`, `diff`, and GNU coreutils
(including `timeout`, `find` and `sort`). Zig fetches the pinned TOML
dependency on the first build; no
Windows fixtures or WASM runtime are needed for these checks. One system
package is: the `check_cxx` step compiles `src/gui/fltk_bridge.cpp`, so the
FLTK 1.3 development headers have to be installed (`libfltk1.3-dev` on
Debian/Ubuntu). The headers alone are enough, because that step links nothing
and never reaches an X11 runtime. The gate exports
`LC_ALL=C` and `TZ=UTC` so its own output, and the sort order inside it, do
not follow the developer's locale.

```sh
bash tests/check.sh
```

One command runs the whole gate: it names any missing tool or wrong Zig
version before starting, then runs the CI checks in order and stops at the
first failure. Build targets run sequentially to limit peak memory rather than
via `-Dall`, matching CI. Each step has a name, so you can run one on its own
while working; `bash tests/check.sh --list` prints them:

```sh
bash tests/check.sh fmt
bash tests/check.sh check_shell    # every tracked script, not just tests/
bash tests/check.sh check_c        # warning-free compile of every tracked C source
bash tests/check.sh check_cxx      # the FLTK bridge, compiled without linking it
bash tests/check.sh build build-x86_64 build-wasm32 build-wasm64
bash tests/check.sh hardening       # static link and non-executable stack, read from the binaries
bash tests/check.sh check_web       # every tracked JavaScript file parses under node --check
bash tests/check.sh dll external-stubs
bash tests/check.sh reproducible  # two builds of one source tree, byte-identical
bash tests/check.sh test
bash tests/check.sh test-cli test-cli-x86_64
bash tests/check.sh fuzz
bash tests/check.sh check_ci       # the gate step list and ci.yml agree
```

Named steps run in gate order, whatever order you pass them in. The
`static-analysis` job in `.github/workflows/ci.yml` runs each of them through
this script, and the script is where each one's command lives; a step added
there reaches CI without a second copy. `ZINE_FUZZ_SECONDS` sets the seconds
each fuzz target runs (10 locally, 60 in CI). `ZINE_FUZZ_SEED` selects the
mutation stream's seed, which the driver also prints on startup and on every
failure together with the case index, so a failing input can be regenerated;
a malformed value exits rather than running a different stream. The unit tests
replay the mutation sweep from the same default seed, so an input the driver
blames is one the test gate re-derives.

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

~70K lines of Zig.

See [`docs/`](docs/README.md) for the documentation index: memory layout, JIT strategy, native execution, and Win32 API coverage. `docs/THREAT_MODEL.md` records the attack surface, trust boundaries, and known gaps. The web UI's HTTP routes and WebSocket message types are specified in [`docs/WEB_UI_PROTOCOL.md`](docs/WEB_UI_PROTOCOL.md).
