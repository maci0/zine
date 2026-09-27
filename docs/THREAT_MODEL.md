# Threat model

Scope: the `zine` host process and its bundled build artifacts. The subject is a
compatibility layer that loads an untrusted Win32 PE, runs its code inside the
host process, and serves a local Web UI for GUI guests. Companion reviews own
point vulnerabilities (sec-review), endpoint authorization (authz-review), the
CVE inventory (deps-review), and PII mapping (privacy-review); this document
models the surface so those passes can be aimed at it.

Last reviewed: 2026-09-27, against `06fe00c`.
Owner: unset. Review cadence: unset.

## Risk-ranked summary

| # | Threat | Boundary | Control today |
|---|---|---|---|
| 1 | Guest PE reads and writes any host file | guest → host filesystem | none; `Z:` maps to the host root and absolute POSIX paths pass through (`src/path_utils.zig:391`, `src/path_utils.zig:412`) |
| 2 | Any local process drives the guest through the Web UI | local process → Web UI | `Origin` check that non-browser clients bypass, and no credential of any kind (`src/gui/web_ui.zig:437`, `src/gui/web_ui.zig:471`, `src/config.zig:91`) |
| 3 | Guest code faults the host process with host signals | guest → host process | in-process signal dispatch, no containment (`src/main.zig:288`, `src/platform/native.zig:648`, `src/x86/compat_thunks.zig:123`) |
| 4 | Guest opens arbitrary network connections | guest → host network | host `socket`/`connect` syscalls are exposed to the guest (`src/win32/ws2_32/winsock.zig:37`, `src/win32/ws2_32/winsock.zig:52`) |
| 5 | Guest loads further PE images from disk, and `-Dexternal-stubs` loads stub DLLs from the binary's own directory | guest → host loader; build → runtime | `LoadLibraryA` anchors through `toHostPath`, so `..` is clamped inside `drive_c/`; external stubs are read from `<exe dir>/dll` with no integrity check (`src/win32/kernel32/process.zig:128`, `src/runner.zig:73`, `src/runner.zig:79`) |
| 6 | Guest spawns host processes | guest → host process tree | child path anchored in `drive_c/`; table capped at 16 (`src/win32/kernel32/process.zig:880`, `src/win32/kernel32/process.zig:718`) |
| 7 | A non-loopback `ZINE_WEB_HOST` publishes an unauthenticated UI to the network | operator config → network | warning only; the UI is still credential-free (`src/main.zig:87`, `src/config.zig:198`) |
| 8 | An unauthenticated Web UI client writes into the guest's clipboard and edit-control buffers | local process → guest state | length cap of 64 KiB, no origin or identity check (`src/gui/web_ui.zig:336`, `src/gui/web_ui.zig:808`, `src/gui/web_ui.zig:819`) |
| 9 | Static assets are served out of the working directory, behind a substring denylist | client → host filesystem | `..`, `%2e`, `%2E`, `%00`, and NUL rejected as substrings; the leading-`/` requirement and the fixed `src/gui` prefix are what actually contain it (`src/gui/web_ui.zig:553`, `src/gui/web_ui.zig:564`, `src/gui/web_ui.zig:569`) |
| 10 | A hostile guest names a host path that then lands in the trace log, and can probe which names exist | guest → logs | `--trace`/`ZINE_TRACE` must be on; home paths are redacted; file contents no longer reach the trace (`src/main.zig:479`, `src/trace.zig:30`, `src/log.zig:243`) |

Rank reflects exploitability times impact for a user who opens a hostile
executable or visits a hostile page. Items 1, 2, 4, 5, 6, and 8 need only a
`.exe` or a local connection; no privilege is required. Item 7 needs an operator
to set the variable, and item 10 needs tracing on.

## 1. Attack surface inventory

### Network

- HTTP + WebSocket server bound to `ZINE_WEB_HOST` (default `127.0.0.1`,
  `src/config.zig:18`) on `ZINE_WEB_PORT` (default 1995, `src/config.zig:19`).
  Both are operator-configurable (`src/config.zig:198`, `src/config.zig:203`).
  The listen call is `src/gui/web_ui.zig:185`, inside the server loop
  (`src/gui/web_ui.zig:178`).
- One WebSocket route, `/ws`, behind the `Origin` check
  (`src/gui/web_ui.zig:471`). Everything else is static: a digest-named asset
  resolves from the build's embedded assets (`src/gui/web_ui.zig:542`), and any
  other asset path is read from `src/gui/` relative to the working directory
  (`src/gui/web_ui.zig:569`).
- A non-loopback bind logs one warning and keeps serving
  (`src/main.zig:87`); nothing else changes, though the origin allowlist
  narrows to the configured address (`src/config.zig:98`).
- Guest sockets through `ws2_32`/`wsock32`, which reach host `socket`, `connect`,
  `send`, `recv`, `bind`, `listen`, and `accept` through raw Linux syscalls
  (`src/win32/ws2_32/winsock.zig:37`, `src/win32/ws2_32/winsock.zig:52`). The
  guest is a network client on the host's network, with the host's name
  resolution and firewall position. `connect` accepts any AF_INET address, and
  nothing bounds the number of open sockets.
- Accept-failure backoff: twelve consecutive failures with doubling delay
  capped at 60 ms (`src/gui/web_ui.zig:231`, `src/gui/web_ui.zig:238`,
  `src/gui/web_ui.zig:243`). This bounds a connect flood against the listener,
  not against connected clients.

### Message and file input

- WebSocket JSON commands, parsed per message in `handleSocketMessage`
  (`src/gui/web_ui.zig:624`). Handlers, in dispatch order: `command`
  (`src/gui/web_ui.zig:648`), `open_file` (`src/gui/web_ui.zig:658`),
  `browse_directory` (`src/gui/web_ui.zig:680`), `launch`
  (`src/gui/web_ui.zig:689`), `resize` (`src/gui/web_ui.zig:704`), `close`
  (`src/gui/web_ui.zig:735`), `font_chosen` (`src/gui/web_ui.zig:737`),
  `print_chosen` (`src/gui/web_ui.zig:753`), `page_setup_chosen`
  (`src/gui/web_ui.zig:761`), `cancel_dialog` (`src/gui/web_ui.zig:779`),
  `find_action` (`src/gui/web_ui.zig:781`), `text_sync`
  (`src/gui/web_ui.zig:801`), `clipboard_sync` (`src/gui/web_ui.zig:812`),
  `color_selected` (`src/gui/web_ui.zig:823`), `listbox_select`
  (`src/gui/web_ui.zig:836`), `context_menu_select`
  (`src/gui/web_ui.zig:860`), `set_volume` (`src/gui/web_ui.zig:873`),
  `keydown`/`keyup` on one branch (`src/gui/web_ui.zig:880`), `wheel`
  (`src/gui/web_ui.zig:893`), and the mouse events
  (`src/gui/web_ui.zig:903`). An unrecognized type is answered with an error
  frame (`src/gui/web_ui.zig:931`). Malformed JSON, a frame that is not a JSON
  object, and a missing or non-string `type` are all rejected before dispatch
  (`src/gui/web_ui.zig:625`, `src/gui/web_ui.zig:636`, `src/gui/web_ui.zig:640`,
  `src/gui/web_ui.zig:644`).
- HTTP request paths for static assets, checked by a substring denylist for
  `..`, `%2e`, `%2E`, `%00`, and NUL (`src/gui/web_ui.zig:553`), then by method
  (`static_allowed_methods`, `src/gui/web_ui.zig:281`). The denylist is a
  substring test, not a component check, so the second control on this branch is
  the leading-`/` requirement (`src/gui/web_ui.zig:564`) and the fixed `src/gui`
  prefix (`src/gui/web_ui.zig:569`).
- Guest PE file: headers, sections, relocations, imports, and resources are all
  parsed from the file (`src/pe.zig:315`, `src/loader/module.zig:192`,
  `src/loader/loader.zig:414`). Resource parsers are separate: menus, dialogs,
  icons (`src/loader/menu_parser.zig:21`, `src/loader/dialog_parser.zig:80`,
  `src/loader/icon_parser.zig:53`). The string-table walk behind
  `LoadStringA`/`LoadStringW` is bounded to the mapped image
  (`src/win32/user32/resource.zig:231`).
- Guest-controlled DLL names reaching the loader through `LoadLibraryA`
  (`src/win32/kernel32/process.zig:116`).
- Guest-controlled file and path strings reaching host filesystem calls via
  `host_io.open` (`src/win32/host_io.zig:30`), `host_io.access`
  (`src/win32/host_io.zig:182`), `host_io.deleteFile`
  (`src/win32/host_io.zig:196`), and `SearchPathA`
  (`src/win32/kernel32/file.zig:683`).
- A batch script named on the command line, interpreted from the filesystem
  with a 10 MiB read cap (`src/bat.zig:147`, `src/bat.zig:158`), reached at
  `src/main.zig:307`.

### CLI, environment, IPC

- CLI options parsed in the loop at `src/main.zig:118`: `--trace`/`-t`
  (`src/main.zig:123`), `--trace-api` (`src/main.zig:128`), `--trace-insn`
  (`src/main.zig:132`), `--interpret`/`-i` (`src/main.zig:136`), `--jit`
  (`src/main.zig:140`), `--profile` (`src/main.zig:144`), `--quiet`/`-q`
  (`src/main.zig:148`), `--fltk` (`src/main.zig:154`), `--no-gui`
  (`src/main.zig:162`), `--argv0` (`src/main.zig:215`), `--help`/`-h`
  (`src/main.zig:166`), `--version`/`-v` (`src/main.zig:211`), and `--`
  (`src/main.zig:119`), which ends option processing.
- Environment: `ZINE_LOG_LEVEL` (`src/log.zig:285`), `ZINE_WEB_HOST`,
  `ZINE_WEB_PORT`, `ZINE_VIRTUAL_CLOCK_NS`, `ZINE_CLOCK_STEP_NS`, `ZINE_CWD`
  (`src/config.zig:198`, `src/config.zig:203`, `src/config.zig:292`,
  `src/config.zig:298`, `src/config.zig:275`), `ZINE_TRACE`, `ZINE_TRACE_INSN`,
  `ZINE_PROFILE` (`src/main.zig:107`, `src/main.zig:110`, `src/main.zig:113`),
  `NO_COLOR` (`src/log.zig:41`), and `ZINE_FUZZ_SEED` for the fuzz harnesses
  only (`src/fuzz/seed.zig:20`). Every runtime one is read at startup, a bad
  value exits 2 (`src/main.zig:73`, `src/main.zig:87`, `src/main.zig:91`), and a
  `ZINE_*` name that matches none of them is reported rather than ignored
  (`src/config.zig:243`). `initFromEnv` leaves the previous configuration
  untouched on a rejected value, so a failed startup does not run on a
  half-applied configuration (`src/config.zig:195`).
- The host environment map is handed to the guest as `envp`
  (`src/main.zig:503`), and the spawner copies it into every child guest. The
  argv and envp block the guest receives is bounded to 128 and 4096 entries
  (`src/win32/msvcrt/process.zig:249`).
- No Unix sockets, no named pipes, and no scheduled jobs anywhere in the tree.
- Build-time surface: `-Ddll` builds the stub DLLs under `src/dll/`;
  `-Dexternal-stubs` switches the host to reading PE stub DLLs from
  `<exe dir>/dll` at runtime (`src/runner.zig:73`, `src/runner.zig:79`).
  Whoever can write that directory chooses which stub code the host maps. The
  `sbom` step ships a CycloneDX inventory of the pinned `toml` package and the
  vendored `van.min.js` into the install prefix (`build.zig:289`,
  `build.zig:412`).

## 2. Trust boundaries and data flow

| Boundary | Data crossing | Named validation or authentication point |
|---|---|---|
| User → CLI | target path, options, environment | option parsing only (`src/main.zig:118`); the target path is not restricted |
| Operator environment → runtime | `ZINE_WEB_HOST` and the rest | IP-literal and length checks (`src/config.zig:311`, `src/config.zig:52`, `src/main.zig:87`) |
| Browser page → Web UI | WebSocket frames, `Origin` header | `originAllowed` (`src/gui/web_ui.zig:430`, `src/config.zig:91`), applied to `/ws` only (`src/gui/web_ui.zig:471`) |
| Local process → Web UI | same protocol, no `Origin` | none; absence of the header is treated as allowed (`src/gui/web_ui.zig:437`) |
| Host filesystem → guest loader | PE bytes | PE parser plus bounds checks at every mapped-slice walk (`src/pe.zig:315`, `src/loader/module.zig:220`, `src/loader/module.zig:276`) |
| Guest → host filesystem | path strings from Win32 stubs | `toHostPath` anchoring for `C:` and relative paths (`src/path_utils.zig:408`, `src/path_utils.zig:428`) |
| Guest → host loader | DLL name from `LoadLibraryA` | `toHostPath` anchoring, so `..` cannot leave `drive_c/` (`src/win32/kernel32/process.zig:128`) |
| Web UI client → guest filesystem | virtual paths from `open_file`, `browse_directory`, `launch` | `virtualPathToDriveC` (`src/path_utils.zig:282`) at `src/gui/web_ui.zig:671`, `src/gui/web_ui.zig:693`, and `src/gui/renderer.zig:963` |
| Web UI client → guest state | clipboard and edit-control text, synthetic input, dialog answers | length cap and per-command type checks only; no identity check (`src/gui/web_ui.zig:336`, `src/gui/web_ui.zig:344`, `src/gui/web_ui.zig:341`) |
| Client → host filesystem (HTTP) | static asset paths | substring denylist plus the `src/gui` prefix (`src/gui/web_ui.zig:553`, `src/gui/web_ui.zig:569`) |
| Guest → host network | socket calls | none |
| Guest → host process tree | `CreateProcessA` command line | path through `toHostPath`; the rest of the guest command line is passed through (`src/win32/kernel32/process.zig:880`) |
| Host environment → guest | `envp` | none; every host variable is visible to the guest (`src/main.zig:503`) |
| Guest handle → module | image handle used to index a mapping | `Registry.moduleForHandle` returns null for a handle that names no mapping (`src/loader/registry.zig:502`) |
| Build → runtime | stub DLLs read from `<exe dir>/dll` in external-stub builds | directory chosen by the builder; contents read at runtime with no signature or hash check (`src/runner.zig:79`) |

Privilege transitions to record: the guest begins as untrusted file content and,
once `CreateProcessA`, `LoadLibraryA`, or `socket` runs, causes host-level
process, code-mapping, and network actions under the invoking user's
credentials. There is no privilege drop between guest and host anywhere in the
tree. The second transition is operator to network: setting `ZINE_WEB_HOST`
moves an unauthenticated UI off loopback, and the only response is one log line.
The third is operator to code: choosing `-Dexternal-stubs` makes the host map
PEs from a directory beside the binary.

There is no runtime configuration file. The registry overrides the guest reads
are `@embedFile`'d into the binary at build time
(`src/win32/advapi32/registry_config.zig:34`), so the only thing a user can
change at runtime is which PE and batch script they point the host at, and what
the working directory's `src/gui` tree contains.

Secrets: the project stores none. Credentials enter only through the host
environment or files under `drive_c/`, are readable by the guest, and are
forwarded to child guests through `envp` (`src/main.zig:503`). No rotation point
exists because nothing is persisted.

## 3. Assets and impact

- Host filesystem contents reachable through `Z:` or absolute POSIX paths
  (`src/path_utils.zig:391`, `src/path_utils.zig:412`): source trees, `~/.ssh`,
  browser profiles, tokens in dotfiles. Destruction or overwriting of a user
  file is the worst case here.
- Host process integrity. Guest code runs in the host address space and faults
  are serviced by a host SIGSEGV handler installed at startup
  (`src/main.zig:288`, `src/platform/native.zig:1247`), so a guest defect can end
  as a host crash with a partial file write behind it.
- Host code-loading surface. `LoadLibraryA` maps whatever the guest names inside
  `drive_c/` (`src/win32/kernel32/process.zig:116`), and in external-stub builds
  the host maps PEs from beside its own binary (`src/runner.zig:79`).
- Host network position. Guest socket calls borrow the host's connections
  (`src/win32/ws2_32/winsock.zig:37`): data exfiltration and abuse of the
  user's egress identity.
- Local GUI session. Screen frames, key and mouse input, and the guest's file
  picker contents flow to any Web UI client that connects
  (`src/gui/web_ui.zig:42`, `src/gui/web_ui.zig:64`). In the other direction, an
  unauthenticated client can write guest clipboard and edit-control text
  (`src/gui/web_ui.zig:812`).
- Build and CI logs. Trace output records the names of every Win32 call a guest
  makes, its path arguments, and its window titles, and home paths are rewritten
  to `~` (`src/log.zig:137`, `src/log.zig:243`). A hostile guest chooses the
  names that land there, so a CI log can accumulate a directory map of the
  machine that built it.
- Availability: the Web UI server and guest children are unbounded in wall
  clock, and the connected-client list is unbounded
  (`src/gui/web_ui.zig:11`); the child table is capped at 16
  (`src/win32/kernel32/process.zig:718`).

## 4. Threats per boundary

### Host → guest loader (untrusted PE)

- Denial of service: file size drives one allocation of the whole file
  (`src/loader/module.zig:177`), and `SizeOfImage` drives the mapping
  (`src/loader/module.zig:207`). A large PE costs the host that memory before
  the guest runs a single instruction.
- Information disclosure and denial of service: name reads are bounded.
  `Module.stringAt` checks the RVA against the mapped length and requires a
  terminator inside the image (`src/loader/module.zig:360`); the loader stops
  the import walk on a null result (`src/loader/loader.zig:432`,
  `src/loader/loader.zig:476`). The descriptor and thunk walks bound their own
  reads (`src/loader/loader.zig:426`, `src/loader/loader.zig:467`).
- Tampering: the resource parsers are the least exercised loader surface even
  with harnesses. They are covered by mutation fuzzing
  (`src/fuzz/menu.zig`, `src/fuzz/dialog.zig`, `src/fuzz/icon.zig`,
  `src/fuzz/loadstring.zig`, `src/fuzz/bat.zig`) replayed from the seed corpus
  in `zig build test` (`src/fuzz/replay.zig`, `src/test_root.zig:31`), but a
  harness only reaches what its driver constructs.
- Repudiation: a guest can delete or overwrite its own file, and the host
  records no provenance of what it loaded.

### Guest → host loader (`LoadLibraryA`)

- Elevation of privilege: the guest maps and runs further PE images without an
  exploit (`src/win32/kernel32/process.zig:116`). `toHostPath` keeps the path
  inside `drive_c/` (`src/win32/kernel32/process.zig:128`), but a `.dll` a user
  placed there, or one a previous guest wrote, becomes host-executed code.
  `LoadLibraryW` and `LoadLibraryExA` reach the same path
  (`src/win32/kernel32/process.zig:1548`, `src/win32/kernel32/process.zig:1606`).
- Tampering: the same path reaches the same loader the initial PE went through,
  so loader bugs are reachable a second time from inside a running guest.

### Guest → host process (native execution)

- Denial of service: any invalid guest access reaches the host signal
  dispatcher, which is installed process-wide at startup
  (`src/main.zig:288`, `src/platform/native.zig:648`,
  `src/x86/compat_thunks.zig:123`). The x86 target deliberately disables SIMD to
  keep 4-byte stack alignment, so stack-sensitive host paths remain reachable.
- Elevation of privilege: the guest does not need an exploit to reach host
  syscalls; the stubs are the interface.

### Guest → host filesystem

- Tampering and information disclosure: `Z:\...` maps to the host root
  (`src/path_utils.zig:391`) and absolute POSIX paths pass through unchanged
  (`src/path_utils.zig:412`). Read, write, and delete are all available
  (`src/win32/host_io.zig:30`, `src/win32/host_io.zig:196`), as are
  `access` (`src/win32/host_io.zig:182`) and `stat`
  (`src/win32/host_io.zig:189`).
- Spoofing: `SearchPathA` probes path entries with `access()`
  (`src/win32/kernel32/file.zig:701`); a guest can name a directory it should
  not know about and learn whether it exists.

### Web UI client → guest filesystem

- Tampering: `virtualPathToDriveC` is the control here, and it is a real
  component check, not a substring denylist: NUL, backslash, leading `/`, drive
  letter, and `.`/`..` components are each refused, and input with more
  components than `normalizePath`'s stack capacity is refused rather than
  silently truncated (`src/path_utils.zig:282`, `src/path_utils.zig:291`,
  `src/path_utils.zig:296`, `src/path_utils.zig:310`). Directory listing goes
  through the same function and treats a zero-length result as an empty listing
  rather than falling back to the raw string (`src/gui/renderer.zig:963`).

### Web UI client → host filesystem (HTTP)

- Information disclosure: the traversal control on the static branch is a
  substring denylist over five spellings (`src/gui/web_ui.zig:553`). It does not
  decode percent-encoding generally, so the containment rests on the
  leading-`/` requirement (`src/gui/web_ui.zig:564`) and the fixed `src/gui`
  prefix (`src/gui/web_ui.zig:569`).
- Tampering: assets other than the embedded index and the digest-named set are
  read from `src/gui/` under the working directory
  (`src/gui/web_ui.zig:569`). Whoever writes that tree changes what a Web UI
  client is served, and the tree is not part of the shipped binary.

### Web UI client → guest state

- Tampering: `text_sync` and `clipboard_sync` write client text straight into
  the guest's edit-control and clipboard buffers, bounded at 64 KiB but
  otherwise unvalidated (`src/gui/web_ui.zig:801`, `src/gui/web_ui.zig:808`,
  `src/gui/web_ui.zig:819`). A local process can put text into a guest's hands
  at a keypress, which is a paste-and-execute path for any guest that pastes.
  The clipboard write additionally truncates through a 4096-byte escape buffer
  (`src/gui/renderer.zig:673`).
- Spoofing and elevation of privilege: dialog answers (`color_selected`,
  `listbox_select`, `context_menu_select`, `print_chosen`) are answered by
  whoever connects. `find_action` is the one with an allowlist, because an
  unlisted value would otherwise be treated as find-next
  (`src/gui/web_ui.zig:344`); the others take integers with range checks
  (`src/gui/web_ui.zig:339`).
- Repudiation: nothing attributes a command to a client, so a drive-by answer to
  a guest dialog is indistinguishable from the user's.

### Guest → host process tree

- Elevation of privilege: `CreateProcessA` re-executes the host binary with a
  guest-controlled path and arguments (`src/win32/kernel32/process.zig:811`,
  `src/win32/kernel32/process.zig:880`).
- Information disclosure: an argument beginning with `@` makes the spawner open
  that name relative to the working directory (`src/win32/msvcrt/process.zig:573`).
  The file's contents no longer reach the trace: `trace.responseFile` prints
  only the path and a byte count (`src/trace.zig:30`). The residual is that the
  name is still printed, and the spawner's success or failure is an existence
  and size oracle for any path the guest can name, on both the guest path
  (`src/win32/msvcrt/process.zig:588`) and the host CLI's own
  (`src/main.zig:479`).
- Denial of service: 16 concurrent children, then refusals
  (`src/win32/kernel32/process.zig:718`, `src/win32/kernel32/process.zig:959`);
  each child is another full guest with its own allocator and stack. The argv and
  envp block handed to a child is bounded, so a hostile environment cannot walk
  past it (`src/win32/msvcrt/process.zig:249`).

### Guest → host network

- Information disclosure and spoofing: raw socket operations, no egress policy,
  no rate limit, and the guest chooses the destination. The guest's `fd_set` is
  clamped to `FD_SETSIZE` so it cannot read past the caller's buffer
  (`src/win32/ws2_32/winsock.zig:17`), and null or non-positive lengths are
  refused, but neither bounds the number of connections.
- Denial of service: a guest can hold connections open; nothing bounds them.

### Local process → Web UI

- Spoofing and elevation of privilege: no credential of any kind. Any local
  process can attach, read screen frames, inject input, list the guest
  filesystem through `browse_directory`, and launch files
  (`src/gui/web_ui.zig:680`, `src/gui/web_ui.zig:689`). The path check confines
  those two commands to `drive_c/`, so the reach here is the guest sandbox, not
  the host root.
- Denial of service: connected clients accumulate without a cap
  (`src/gui/web_ui.zig:11`), each connection gets its own thread
  (`src/gui/web_ui.zig:219`), and each client receives a full framebuffer push
  (`src/gui/web_ui.zig:64`).

### Browser page → Web UI

- Spoofing: cross-site WebSocket hijacking. The `Origin` allowlist blocks a
  foreign browser origin (`src/config.zig:91`), but a non-browser client omits
  the header entirely and is allowed (`src/gui/web_ui.zig:437`).
- The check is not authentication; the README states this correctly
  (README.md:424, 0.2.0 security notes).

### Operator configuration

- Information disclosure and spoofing: a non-loopback `ZINE_WEB_HOST` makes the
  screen, injected input, and `drive_c/` browsing reachable from the network
  with no credential (`src/main.zig:87`). The `Origin` allowlist narrows to the
  configured host (`src/config.zig:98`) but does not authenticate, and a
  non-browser client still needs to send no `Origin` at all.
- Tampering: `-Dexternal-stubs` moves stub loading to a runtime directory read
  beside the binary (`src/runner.zig:79`). Whoever writes `<exe dir>/dll`
  controls the code the host maps.

### Configuration and build

- Tampering: `drive_c/` contents come from the working directory. Whoever writes
  them changes what the guest sees. There is no runtime config file to poison;
  `registry.toml` is embedded at build time
  (`src/win32/advapi32/registry_config.zig:34`), so changing guest behavior this
  way means changing the binary.
- Supply chain: the only build-time external dependency is the pinned `toml`
  package in `build.zig.zon`, and the vendored `van.min.js` is checked against a
  pinned SHA-256 on every configure, so the build refuses to proceed on drift
  (`build.zig:310`). `zig build sbom` writes the CycloneDX inventory of both to
  the install prefix and fails when it no longer matches the manifest
  (`build.zig:289`). The MSVC 6.0 fixtures used by the integration suite are
  proprietary and are not in the repository.

### Recurring classes from history

The history shows the classes that come back: input validation at the loader
and path layers (`39ac62b`, `636b72c`, `43d005c`, `3f3ddba`), and truncation
and aliasing on UTF-16 to UTF-8 conversion (`70d22e5`, `8b51a23`). Any new fix
in those areas should be checked against the whole table below, not just the
reported site. The bounds checks added to the loader (`src/loader/module.zig:220`,
`src/loader/module.zig:264`, `src/loader/loader.zig:502`) are the same class of
fix and the same standard applies to every remaining name read, including
`src/loader/loader.zig:506`.

## 5. Mitigations mapping

| Control | Implementation | Threats it covers | What it does not cover |
|---|---|---|---|
| Loopback bind by default | `src/config.zig:18`, `src/gui/web_ui.zig:185` | remote network attackers under default configuration | an operator who sets `ZINE_WEB_HOST`; no credential exists behind the bind |
| Startup env validation | `src/main.zig:73`, `src/main.zig:87`, `src/config.zig:195`, `src/config.zig:311` | misconfigured host, port, clock, and log level reaching a subsystem | anything after startup; validation is shape, not authorization |
| `Origin` allowlist on `/ws` | `src/gui/web_ui.zig:430`, `src/gui/web_ui.zig:471`, `src/config.zig:91` | cross-site WebSocket hijacking from a browser | non-browser clients, requests with no `Origin` |
| `virtualPathToDriveC` | `src/path_utils.zig:282` | Web UI path traversal for `open_file`, `browse_directory`, `launch`, and listing | the HTTP static branch, which does not use it |
| Client-controlled paths escaped before broadcast | `src/gui/renderer.zig:940` | a client-supplied path corrupting the JSON broadcast to every client | nothing else; this is a serialization control |
| `find_action` allowlist | `src/gui/web_ui.zig:344` | an unrecognized dialog action reaching the guest as find-next | the other dialog answers, which take range-checked integers |
| Web UI payload caps | `src/gui/web_ui.zig:336`, `src/gui/web_ui.zig:260`, `src/gui/web_ui.zig:937` | unbounded client strings in `text_sync`, `clipboard_sync`, and error frames; oversized static assets and error envelopes | total bytes per connection, and the client count |
| HTTP method allowlists | `src/gui/web_ui.zig:281`, `src/gui/web_ui.zig:287` | write methods on the static branch, non-`GET` upgrades on `/ws` | the WebSocket body stream itself |
| Static asset denylist | `src/gui/web_ui.zig:553` | naive traversal in HTTP asset requests | encoded spellings it does not list; the Web UI's own commands, which use `virtualPathToDriveC` instead |
| Static response security headers | `src/gui/web_ui.zig:1079`, `src/gui/web_ui.zig:1055` | content sniffing, framing, referrer leakage, and script injection from a served asset into the browser that runs the UI | a non-browser client, which ignores all of them; `Content-Security-Policy` is sent on the `200` but not repeated on the `304` |
| Digest-pinned asset cache | `src/gui/web_ui.zig:998`, `src/gui/web_ui.zig:1032` | a stale or substituted asset name pinning different bytes under an immutable cache entry | a first-request fetch of a name the server already agrees to serve |
| Accept-failure backoff | `src/gui/web_ui.zig:231`, `src/gui/web_ui.zig:243` | a connect flood spinning the accept loop | a flood of completed connections |
| `drive_c` anchoring with `..` clamping | `src/path_utils.zig:408`, `src/path_utils.zig:428`, `src/path_utils.zig:330` | traversal from `C:` and relative guest paths, including `LoadLibraryA` and `CreateProcessA` | `Z:` mapping (`:391`), absolute POSIX passthrough (`:412`) |
| Home path redaction | `src/log.zig:137`, `src/log.zig:243` | the account name and home-relative paths reaching stderr and CI logs | file contents, and any path outside the home directory |
| Identity env redaction | `src/log.zig:208` | `USER`, `USERNAME`, `LOGNAME`, and `EMAIL` values reaching a log record | any other variable in the environment, all of which reach the guest as `envp` |
| Control-character neutralization | `src/log.zig:243` | a guest-supplied name forging log lines or terminal escapes | the name itself, which is still printed |
| Contents-free trace records | `src/trace.zig:30`, `src/win32/kernel32/profile.zig:74` | response-file and INI contents reaching a log or CI artifact | the response-file name, and the existence and size oracle the open itself provides |
| Child table cap | `src/win32/kernel32/process.zig:718`, `src/win32/kernel32/process.zig:959` | unbounded child spawning | the actions of the 16 children that do spawn |
| Guest argv and envp bounds | `src/win32/msvcrt/process.zig:249` | a hostile host environment walking past the child's argument block | the number of children, which the table cap covers separately |
| `select` `fd_set` clamp | `src/win32/ws2_32/winsock.zig:17` | a guest `fd_count` above `FD_SETSIZE` reading past the caller's `fd_set` | the number of open sockets, which nothing bounds |
| Loader bounds checks | `src/loader/module.zig:220`, `src/loader/module.zig:264`, `src/loader/module.zig:276`, `src/loader/loader.zig:426`, `src/loader/loader.zig:467`, `src/loader/module.zig:360` | host memory corruption and unbounded reads from crafted sections, BSS ranges, relocations, import descriptors, names, and thunks | the resource parsers' output contract, which rests on fuzzing rather than validation |
| Module handles resolved before indexing | `src/loader/registry.zig:502` | a guest handle naming no mapping being treated as a readable image | handles that do name a mapping, which is the point |
| Bounded string-table load | `src/win32/user32/resource.zig:231` | an RVA outside the mapped image being read through `LoadStringA`/`LoadStringW` | other resource walks, which are covered by the loader bounds checks above |
| Fuzz harnesses for the untrusted parsers | `src/fuzz/pe.zig`, `src/fuzz/menu.zig`, `src/fuzz/dialog.zig`, `src/fuzz/icon.zig`, `src/fuzz/loadstring.zig`, `src/fuzz/bat.zig`, `src/fuzz/mutation.zig`, `src/fuzz/replay.zig`, `build.zig:762` | host crashes on malformed PE headers, resources, string tables, and batch scripts | logic defects that parse correctly but mean the wrong thing |
| Build-time pin and digest gate | `build.zig:289`, `build.zig:310` | a substituted `toml` package or vendored `van.min.js` reaching a build | anything the repository itself ships |
| Typed stub signatures | `src/loader/env.zig:244`, `src/loader/env.zig:404` | pointer-width confusion at the call boundary | legacy stubs still taking guest pointers as integers |

Unmitigated, ranked: host filesystem reach from the guest (1), unauthenticated
local Web UI (2), host signal dispatch (3), guest egress (4), guest-driven code
loading (5), and the working-directory static asset branch (9). These are
recorded here for sec-review; this document does not fix them. The missing
`Content-Security-Policy` on the `304` response is likewise recorded, not fixed:
the README now describes it accurately instead of claiming the header is
repeated.

README claims checked and left in place: the non-loopback `ZINE_WEB_HOST`
warning, the HTTP 403 for foreign `Origin` headers, the statement that the
`Origin` check is not authentication, the honest note that path normalization
is not a guest sandbox, and the home and identity redaction all match the code
(`src/main.zig:87`, `src/gui/web_ui.zig:471`, `src/gui/web_ui.zig:437`,
`src/log.zig:137`, `src/log.zig:208`; README.md:424, README.md:417,
README.md:585). One README claim was corrected in this pass: the `304` repeats
`X-Content-Type-Options`, `X-Frame-Options`, and `Referrer-Policy` but not
`Content-Security-Policy` (`src/gui/web_ui.zig:1055`, `src/gui/web_ui.zig:1079`).

Single points of failure: `toHostPath` is the only path control for the whole
stub layer, and the `Origin` check is the only thing between a browser and the
guest; a defect in either exposes everything it fronts. The Web UI's
`virtualPathToDriveC` is the only control between a local process and the guest
sandbox, and it is a single function called from three sites. `log.emit` is the
single point every diagnostic passes through, so a defect in redaction there
exposes every path and identity the host ever logs.

## 6. Abuse cases

- Drive-by guest control: a page the user visits opens
  `ws://127.0.0.1:1995/ws`. The `Origin` check stops that browser case
  (`src/config.zig:91`), but any local script, a browser extension, or a `curl`
  client is accepted, and then `browse_directory` plus `launch` are enough to
  enumerate and start anything under `drive_c/`
  (`src/gui/web_ui.zig:680`, `src/gui/web_ui.zig:689`).
- Clipboard injection: a local client sends `clipboard_sync` with a crafted
  string, and the guest pastes whatever the user later presses Ctrl-V
  (`src/gui/web_ui.zig:819`). The guest's own defenses are the only thing
  between that string and execution.
- Host file theft by a "harmless" app: the guest calls
  `CreateFileA("Z:\\home\\user\\.ssh\\id_rsa")`, which `toHostPath` maps to the
  host root (`src/path_utils.zig:391`), then uploads the bytes over a guest
  socket.
- Existence oracle: `SearchPathA` probes path entries with `access()` and
  returns the match (`src/win32/kernel32/file.zig:701`), so a guest probes the
  host for paths it should not be able to name. A `@file` argument on
  `CreateProcessA` gives the same answer from the spawner's open, plus the size
  (`src/win32/msvcrt/process.zig:588`).
- Response-file name disclosure: a guest calls `CreateProcessA` with `@secret.txt`.
  The contents no longer reach the trace, but the name does, alongside the byte
  count, and the read still happens (`src/trace.zig:30`). The host CLI does the
  same for its own arguments (`src/main.zig:479`). Both need tracing on, and
  home-relative names are redacted, but a name outside the home directory is
  printed as given.
- Persistent code loading: a guest calls `LoadLibraryA` on a `.dll` it wrote into
  `drive_c/` earlier in the same session
  (`src/win32/kernel32/process.zig:116`), turning its own file write into
  mapped, executed code.
- Resource exhaustion: a guest that never exits, plus children up to the table
  cap, plus an unbounded list of connected Web UI clients each with its own
  thread and framebuffer push, holds host memory, process slots, and threads
  indefinitely (`src/gui/web_ui.zig:11`, `src/gui/web_ui.zig:219`); nothing in
  the tree imposes a timeout.
- Log forging: a hostile guest chooses the path strings and window titles its
  calls are traced with, and every record reaches stderr with control characters
  neutralized but the text intact (`src/log.zig:243`), so it can plant
  attacker-shaped lines in a CI log and pad them to displace a real one.

Client-side trust: the frontend's own idea of what paths are valid is not a
control. Every path decision in `src/gui/app.js` is advisory; the server-side
check in `src/path_utils.zig:282` is the only one, and it is reached from three
call sites that each have to call it. The same holds for the clipboard and
edit-control contents, which the server trusts as text within its length cap.

## 7. Document status

- `SECURITY.md`: absent, in the root, `.github/`, and `docs/`. There is no
  disclosure contact and no supported version list in the repository. README
  records that no deprecation, support-window, or security-backport policy
  exists, which matches the tree; that statement stays in README and is not
  extended here.
- No owner and no review cadence are recorded for this model; both are unset
  rather than guessed.
- What changed since the previous pass, all against `06fe00c`:
  - The response-file and INI trace records now carry a path and a byte count
    instead of file contents (`src/trace.zig:30`,
    `src/win32/kernel32/profile.zig:74`). The former content-disclosure abuse
    case is retired; the residual is a name leak and a size oracle.
  - `registry.toml` is `@embedFile`'d at build time
    (`src/win32/advapi32/registry_config.zig:34`), so the runtime
    configuration-poisoning threat and its boundary row are retired.
  - New controls recorded: identity env redaction (`src/log.zig:208`),
    control-character neutralization (`src/log.zig:243`), guest argv and envp
    bounds (`src/win32/msvcrt/process.zig:249`), the `select` `fd_set` clamp
    (`src/win32/ws2_32/winsock.zig:17`), the bounded string-table load
    (`src/win32/user32/resource.zig:231`), and the vendored VanJS digest gate
    (`build.zig:310`).
  - The SBOM is a shipped artifact, not only an inventory
    (`build.zig:412`).
  - `ZINE_FUZZ_SEED` is a new host environment read, reachable from the fuzz
    harnesses only (`src/fuzz/seed.zig:20`).
  - Every `file:line` reference in the previous revision was re-derived; the
    claims behind them were re-read against the code.
- Claims to re-verify on the next pass: every `file:line` above, the
  `virtualPathToDriveC` call sites, the `Module.stringAt` bound and its callers,
  the Web UI command list, the static branch's denylist and `src/gui` prefix,
  the security header list on both the `200` and the `304`, and the non-loopback
  `ZINE_WEB_HOST` warning.

## 8. Response readiness

Note only; no infrastructure is proposed here.

- Diagnostics available for an investigation: `log.warn`/`log.err` to stderr
  (`src/log.zig:264`), API and instruction tracing via `ZINE_TRACE` and
  `ZINE_TRACE_INSN` (`src/main.zig:107`, `src/main.zig:110`), per-process
  profiling via `ZINE_PROFILE` and `--profile` (`src/main.zig:113`,
  `src/main.zig:144`). There is no audit log of Web UI clients: peer address,
  connection count, and duration are never logged, and a `403` refusal is
  silent (`src/gui/web_ui.zig:471`). There is no per-command attribution for a
  WebSocket command. The always-on record of a spawned child is one line with a
  pid and a handle, and no path (`src/win32/kernel32/process.zig:980`); the
  launch path is traced only when `ZINE_TRACE` is on.
- Documented path from a reported vulnerability to a shipped fix: none. No
  file in the repository describes reporting, triage, or disclosure; the closest
  is the release procedure in `CONTRIBUTING.md:122`. The release notes carry
  security items under "Security fixes and migration" (README.md:115), which is
  a record of past fixes, not a process.
