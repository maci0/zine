# Threat model

Scope: the `zine` host process and its bundled build artifacts. The subject is a
compatibility layer that loads an untrusted Win32 PE, runs its code inside the
host process, and serves a local Web UI for GUI guests. Companion reviews own
point vulnerabilities (sec-review), endpoint authorization (authz-review), the
CVE inventory (deps-review), and PII mapping (privacy-review); this document
models the surface so those passes can be aimed at it.

Last reviewed: 2026-09-27, against `42c8b63`.
Owner: unset. Review cadence: unset.

## Risk-ranked summary

| # | Threat | Boundary | Control today |
|---|---|---|---|
| 1 | Guest PE reads and writes any host file | guest → host filesystem | none; `Z:` maps to the host root and absolute POSIX paths pass through (`src/path_utils.zig:346`, `src/path_utils.zig:368`) |
| 2 | Any local process drives the guest through the Web UI | local process → Web UI | `Origin` check that non-browser clients bypass, and no credential of any kind (`src/gui/web_ui.zig:383`, `src/gui/web_ui.zig:390`, `src/gui/web_ui.zig:424`) |
| 3 | Guest code faults the host process with host signals | guest → host process | in-process signal dispatch, no containment (`src/platform/native.zig:1342`, `src/x86/compat_thunks.zig:117`, `src/platform/native.zig:750`) |
| 4 | Guest opens arbitrary network connections | guest → host network | host `socket`/`connect` syscalls are exposed to the guest (`src/win32/ws2_32/winsock.zig:33`) |
| 5 | Guest loads further PE images from disk, and `-Dexternal-stubs` loads stub DLLs from the binary's own directory | guest → host loader; build → runtime | `LoadLibraryA` anchors through `toHostPath`, so `..` is clamped inside `drive_c/`; external stubs are read from `<exe dir>/dll` with no integrity check (`src/win32/kernel32/process.zig:127`, `src/runner.zig:73`, `src/runner.zig:79`) |
| 6 | Guest spawns host processes | guest → host process tree | child path anchored in `drive_c/`; table capped at 16 (`src/win32/kernel32/process.zig:877`, `src/win32/kernel32/process.zig:715`) |
| 7 | A non-loopback `ZINE_WEB_HOST` publishes an unauthenticated UI to the network | operator config → network | warning only; the UI is still credential-free (`src/main.zig:99`, `src/config.zig:145`) |
| 8 | An unauthenticated Web UI client writes into the guest's clipboard and edit-control buffers | local process → guest state | length cap of 64 KiB, no origin or identity check (`src/gui/web_ui.zig:752`, `src/gui/web_ui.zig:763`, `src/gui/web_ui.zig:336`) |
| 9 | Guest command lines and CLI arguments dump named files into the trace log | guest/CLI → logs | `--trace`/`ZINE_TRACE` must be on; home paths are redacted (`src/win32/msvcrt/process.zig:536`, `src/main.zig:493`, `src/log.zig:137`) |
| 10 | Configuration from the working directory changes guest behavior | config file → runtime | per-app `registry.toml` overrides, no integrity check (`src/win32/advapi32/registry_config.zig`) |

Rank reflects exploitability times impact for a user who opens a hostile
executable or visits a hostile page. Items 1, 2, 4, 5, 6, and 8 need only a
`.exe` or a local connection; no privilege is required. Item 7 needs an operator
to set the variable.

## 1. Attack surface inventory

### Network

- HTTP + WebSocket server bound to `ZINE_WEB_HOST` (default `127.0.0.1`,
  `src/config.zig:14`) on `ZINE_WEB_PORT` (default 1995, `src/config.zig:15`).
  Both are operator-configurable (`src/config.zig:145`, `src/config.zig:150`).
  The listen call is `src/gui/web_ui.zig:185`, inside the server loop
  (`src/gui/web_ui.zig:178`).
- One WebSocket route, `/ws`, behind the `Origin` check
  (`src/gui/web_ui.zig:423`, `src/gui/web_ui.zig:424`). Everything else is
  static: `/index.html` is served from the build's embedded assets
  (`src/gui/web_ui.zig:487`), and other asset paths are read from `src/gui/`
  relative to the working directory (`src/gui/web_ui.zig:510`).
- A non-loopback bind logs one warning and keeps serving
  (`src/main.zig:99`); nothing else changes.
- Guest sockets through `ws2_32`/`wsock32`, which call host `socket`,
  `connect`, `send`, `recv`, `bind`, `listen` directly
  (`src/win32/ws2_32/winsock.zig:33`). The guest is a network client on the
  host's network, with the host's name resolution and firewall position.
- Accept-failure backoff: twelve consecutive failures with doubling delay
  capped at 60 ms (`src/gui/web_ui.zig:231`, `src/gui/web_ui.zig:243`). This
  bounds a connect flood against the listener, not against connected clients.

### Message and file input

- WebSocket JSON commands, parsed per message in `handleSocketMessage`
  (`src/gui/web_ui.zig:565`, `src/gui/web_ui.zig:566`). Handlers, in dispatch
  order: `command` (`src/gui/web_ui.zig:589`), `open_file`
  (`src/gui/web_ui.zig:599`), `browse_directory` (`src/gui/web_ui.zig:621`),
  `launch` (`src/gui/web_ui.zig:630`), `resize` (`src/gui/web_ui.zig:645`),
  `close` (`src/gui/web_ui.zig:676`), `font_chosen`
  (`src/gui/web_ui.zig:678`), `print_chosen` (`src/gui/web_ui.zig:694`),
  `page_setup_chosen` (`src/gui/web_ui.zig:712`), `cancel_dialog`
  (`src/gui/web_ui.zig:730`), `find_action` (`src/gui/web_ui.zig:732`),
  `text_sync` (`src/gui/web_ui.zig:752`), `clipboard_sync`
  (`src/gui/web_ui.zig:763`), `color_selected` (`src/gui/web_ui.zig:774`),
  `listbox_select` (`src/gui/web_ui.zig:787`), `context_menu_select`
  (`src/gui/web_ui.zig:811`), `set_volume` (`src/gui/web_ui.zig:821`),
  `keydown`/`keyup` (`src/gui/web_ui.zig:828`), `wheel`
  (`src/gui/web_ui.zig:841`), and the mouse events
  (`src/gui/web_ui.zig:851`). An unrecognized type is answered with an error
  frame (`src/gui/web_ui.zig:879`). A frame that is not a JSON object, or whose
  `type` is missing or not a string, is rejected before dispatch
  (`src/gui/web_ui.zig:577`, `src/gui/web_ui.zig:581`, `src/gui/web_ui.zig:585`).
- HTTP request paths for static assets, checked by a substring denylist for
  `..`, `%2e`, `%2E`, `%00`, and NUL (`src/gui/web_ui.zig:493`), then by method
  (`static_allowed_methods`, `src/gui/web_ui.zig:281`). The denylist is a
  substring test, not a component check, so the second control on this branch is
  the fixed `src/gui` prefix (`src/gui/web_ui.zig:510`).
- Guest PE file: headers, sections, relocations, imports, and resources are all
  parsed from the file (`src/pe.zig:315`, `src/loader/module.zig:192`,
  `src/loader/loader.zig:425`). Resource parsers are separate: menus, dialogs,
  icons (`src/loader/menu_parser.zig`, `src/loader/dialog_parser.zig`,
  `src/loader/icon_parser.zig`).
- Guest-controlled DLL names reaching the loader through `LoadLibraryA`
  (`src/win32/kernel32/process.zig:115`).
- Guest-controlled file and path strings reaching host filesystem calls via
  `host_io.open` (`src/win32/host_io.zig:30`), `host_io.deleteFile`
  (`src/win32/host_io.zig:196`), and `SearchPathA`
  (`src/win32/kernel32/file.zig:683`).
- `registry.toml` in the working directory, keyed by executable basename,
  overrides registry values the guest reads
  (`src/win32/advapi32/registry_config.zig`).

### CLI, environment, IPC

- CLI options parsed in the loop at `src/main.zig:132`: `--trace`/`-t`
  (`src/main.zig:136`), `--trace-api` (`src/main.zig:141`), `--trace-insn`
  (`src/main.zig:145`), `--interpret`/`-i` (`src/main.zig:149`), `--jit`
  (`src/main.zig:153`), `--profile` (`src/main.zig:157`), `--quiet`/`-q`
  (`src/main.zig:161`), `--fltk` (`src/main.zig:167`), `--no-gui`
  (`src/main.zig:175`), `--argv0` (`src/main.zig:228`), `--help`/`-h`
  (`src/main.zig:179`), `--version`/`-v` (`src/main.zig:224`), and `--`
  (`src/main.zig:132`), which ends option processing.
- Environment: `ZINE_LOG_LEVEL` (`src/main.zig:73`), `ZINE_WEB_HOST`,
  `ZINE_WEB_PORT`, `ZINE_VIRTUAL_CLOCK_NS`, `ZINE_CLOCK_STEP_NS`
  (`src/config.zig:145`, `src/config.zig:150`, `src/main.zig:76`),
  `ZINE_TRACE`, `ZINE_TRACE_INSN` (`src/main.zig:120`, `src/main.zig:123`),
  `ZINE_PROFILE`, `NO_COLOR` (`src/log.zig:41`), and `ZINE_CWD` on WASI
  (`src/wasm_main.zig:81`). Every one is validated at startup and a bad value
  exits 2 (`src/main.zig:73`, `src/main.zig:76`). `initFromEnv` leaves the
  previous configuration untouched on a rejected value, so a failed startup does
  not run on a half-applied configuration (`src/config.zig:141`).
- The host environment map is handed to the guest as `envp`
  (`src/main.zig:520`), and the spawner copies it into every child guest.
- No Unix sockets, no named pipes, and no scheduled jobs anywhere in the tree.
- Build-time surface: `-Ddll` builds the stub DLLs under `src/dll/`;
  `-Dexternal-stubs` switches the host to reading PE stub DLLs from
  `<exe dir>/dll` at runtime (`src/runner.zig:73`, `src/runner.zig:79`).
  Whoever can write that directory chooses which stub code the host maps.

## 2. Trust boundaries and data flow

| Boundary | Data crossing | Named validation or authentication point |
|---|---|---|
| User → CLI | target path, options, environment | option parsing only (`src/main.zig:132`); the target path is not restricted |
| Operator environment → runtime | `ZINE_WEB_HOST` and the rest | IP-literal and range checks (`src/config.zig:188`, `src/config.zig:47`, `src/main.zig:76`) |
| Browser page → Web UI | WebSocket frames, `Origin` header | `originAllowed` (`src/gui/web_ui.zig:383`, `src/config.zig:86`), applied to `/ws` only (`src/gui/web_ui.zig:424`) |
| Local process → Web UI | same protocol, no `Origin` | none; absence of the header is treated as allowed (`src/gui/web_ui.zig:390`) |
| Host filesystem → guest loader | PE bytes | PE parser plus bounds checks at every mapped-slice walk (`src/pe.zig:315`, `src/loader/module.zig:220`, `src/loader/module.zig:275`) |
| Guest → host filesystem | path strings from Win32 stubs | `toHostPath` anchoring for `C:` and relative paths (`src/path_utils.zig:323`, `src/path_utils.zig:364`) |
| Guest → host loader | DLL name from `LoadLibraryA` | `toHostPath` anchoring, so `..` cannot leave `drive_c/` (`src/win32/kernel32/process.zig:127`) |
| Web UI client → guest filesystem | virtual paths from `open_file`, `browse_directory`, `launch` | `virtualPathToDriveC` (`src/path_utils.zig:237`) at `src/gui/web_ui.zig:612`, `src/gui/web_ui.zig:634`, and `src/gui/renderer.zig:953` |
| Web UI client → guest state | clipboard and edit-control text, synthetic input, dialog answers | length cap and per-command type checks only; no identity check (`src/gui/web_ui.zig:336`, `src/gui/web_ui.zig:344`, `src/gui/web_ui.zig:341`) |
| Guest → host network | socket calls | none |
| Guest → host process tree | `CreateProcessA` command line | path through `toHostPath`; the rest of the guest command line is passed through (`src/win32/kernel32/process.zig:877`) |
| Host environment → guest | `envp` | none; every host variable is visible to the guest (`src/main.zig:520`) |
| Config file → runtime | `registry.toml` | none beyond TOML parse |
| Build → runtime | stub DLLs read from `<exe dir>/dll` in external-stub builds | directory chosen by the builder; contents read at runtime with no signature or hash check (`src/runner.zig:79`) |

Privilege transitions to record: the guest begins as untrusted file content and,
once `CreateProcessA`, `LoadLibraryA`, or `socket` runs, causes host-level
process, code-mapping, and network actions under the invoking user's
credentials. There is no privilege drop between guest and host anywhere in the
tree. The second transition is operator to network: setting `ZINE_WEB_HOST`
moves an unauthenticated UI off loopback, and the only response is one log line.
The third is operator to code: choosing `-Dexternal-stubs` makes the host map
PEs from a directory beside the binary.

Secrets: the project stores none. Credentials enter only through the host
environment or files under `drive_c/`, are readable by the guest, and are
forwarded to child guests through `envp` (`src/main.zig:520`). No rotation point
exists because nothing is persisted.

## 3. Assets and impact

- Host filesystem contents reachable through `Z:` or absolute POSIX paths
  (`src/path_utils.zig:346`, `src/path_utils.zig:368`): source trees, `~/.ssh`,
  browser profiles, tokens in dotfiles. Destruction or overwriting of a user
  file is the worst case here.
- Host process integrity. Guest code runs in the host address space and faults
  are serviced by a host SIGSEGV handler installed at startup
  (`src/platform/native.zig:1342`), so a guest defect can end as a host crash
  with a partial file write behind it.
- Host code-loading surface. `LoadLibraryA` maps whatever the guest names inside
  `drive_c/` (`src/win32/kernel32/process.zig:115`), and in external-stub builds
  the host maps PEs from beside its own binary (`src/runner.zig:79`).
- Host network position. Guest socket calls borrow the host's connections
  (`src/win32/ws2_32/winsock.zig:33`): data exfiltration and abuse of the
  user's egress identity.
- Local GUI session. Screen frames, key and mouse input, and the guest's file
  picker contents flow to any Web UI client that connects
  (`src/gui/web_ui.zig:42`, `src/gui/web_ui.zig:62`). In the other direction, an
  unauthenticated client can write guest clipboard and edit-control text
  (`src/gui/web_ui.zig:763`).
- Availability: the Web UI server and guest children are unbounded in wall
  clock, and the connected-client list is unbounded
  (`src/gui/web_ui.zig:11`); the child table is capped at 16
  (`src/win32/kernel32/process.zig:715`).

## 4. Threats per boundary

### Host → guest loader (untrusted PE)

- Denial of service: file size drives one allocation of the whole file
  (`src/loader/module.zig:177`), and `SizeOfImage` drives the mapping
  (`src/loader/module.zig:207`). A large PE costs the host that memory before
  the guest runs a single instruction.
- Information disclosure and denial of service: name reads are bounded.
  `Module.stringAt` checks the RVA against the mapped length and requires a
  terminator inside the image (`src/loader/module.zig:359`); the loader stops
  the import walk on a null result (`src/loader/loader.zig:438`,
  `src/loader/loader.zig:506`). The descriptor and thunk walks bound their own
  reads (`src/loader/loader.zig:427`, `src/loader/loader.zig:466`).
- Tampering: the resource parsers are the least exercised loader surface even
  with harnesses. They are covered by mutation fuzzing
  (`src/fuzz/menu.zig`, `src/fuzz/dialog.zig`, `src/fuzz/icon.zig`) replayed
  from the seed corpus in `zig build test` (`src/fuzz/replay.zig`,
  `src/test_root.zig:31`), but a harness only reaches what its driver
  constructs.
- Repudiation: a guest can delete or overwrite its own file, and the host
  records no provenance of what it loaded.

### Guest → host loader (`LoadLibraryA`)

- Elevation of privilege: the guest maps and runs further PE images without an
  exploit (`src/win32/kernel32/process.zig:115`). `toHostPath` keeps the path
  inside `drive_c/` (`src/win32/kernel32/process.zig:127`), but a `.dll` a user
  placed there, or one a previous guest wrote, becomes host-executed code.
  `LoadLibraryW` and `LoadLibraryExA` reach the same path
  (`src/win32/kernel32/process.zig:1471`, `src/win32/kernel32/process.zig:1529`).
- Tampering: the same path reaches the same loader the initial PE went through,
  so loader bugs are reachable a second time from inside a running guest.

### Guest → host process (native execution)

- Denial of service: any invalid guest access reaches the host signal
  dispatcher, which is installed process-wide at startup
  (`src/platform/native.zig:1342`, `src/platform/native.zig:750`,
  `src/x86/compat_thunks.zig:117`). The x86 target deliberately disables SIMD to
  keep 4-byte stack alignment, so stack-sensitive host paths remain reachable.
- Elevation of privilege: the guest does not need an exploit to reach host
  syscalls; the stubs are the interface.

### Guest → host filesystem

- Tampering and information disclosure: `Z:\...` maps to the host root
  (`src/path_utils.zig:346`) and absolute POSIX paths pass through unchanged
  (`src/path_utils.zig:368`). Read, write, and delete are all available
  (`src/win32/host_io.zig:30`, `src/win32/host_io.zig:196`).
- Spoofing: `SearchPathA` probes path entries with `access()`
  (`src/win32/kernel32/file.zig:683`, `src/win32/kernel32/file.zig:701`); a
  guest can name a directory it should not know about and learn whether it
  exists.

### Web UI client → guest filesystem

- Tampering: `virtualPathToDriveC` is the control here, and it is a real
  component check, not a substring denylist: NUL, backslash, leading `/`,
  drive letter, and `.`/`..` components are each refused, and input with more
  components than `normalizePath`'s stack capacity is refused rather than
  silently truncated (`src/path_utils.zig:237`, `src/path_utils.zig:245`,
  `src/path_utils.zig:212`). Directory listing goes through the same function
  and treats a zero-length result as an empty listing rather than falling back
  to the raw string (`src/gui/renderer.zig:953`).

### Web UI client → guest state

- Tampering: `text_sync` and `clipboard_sync` write client text straight into
  the guest's edit-control and clipboard buffers, bounded at 64 KiB but
  otherwise unvalidated (`src/gui/web_ui.zig:752`, `src/gui/web_ui.zig:763`).
  A local process can put text into a guest's hands at a keypress, which is a
  paste-and-execute path for any guest that pastes.
- Spoofing and elevation of privilege: dialog answers (`color_selected`,
  `listbox_select`, `context_menu_select`, `find_action`) are answered by
  whoever connects. `find_action` is the one with an allowlist, because an
  unlisted value would otherwise be treated as find-next
  (`src/gui/web_ui.zig:344`); the others take integers with range checks
  (`src/gui/web_ui.zig:774`, `src/gui/web_ui.zig:787`,
  `src/gui/web_ui.zig:341`).
- Repudiation: nothing attributes a command to a client, so a drive-by answer to
  a guest dialog is indistinguishable from the user's.

### Guest → host process tree

- Elevation of privilege: `CreateProcessA` re-executes the host binary with a
  guest-controlled path and arguments (`src/win32/kernel32/process.zig:808`,
  `src/win32/kernel32/process.zig:877`).
- Information disclosure: an argument beginning with `@` makes the spawner open
  that name relative to the working directory and copy up to 4096 bytes into
  the trace output (`src/win32/msvcrt/process.zig:536`). The same applies to
  the host's own arguments (`src/main.zig:493`).
- Denial of service: 16 concurrent children, then refusals
  (`src/win32/kernel32/process.zig:715`, `src/win32/kernel32/process.zig:957`);
  each child is another full guest with its own allocator and stack.

### Guest → host network

- Information disclosure and spoofing: raw socket operations, no egress policy,
  no rate limit, and the guest chooses the destination.
- Denial of service: a guest can hold connections open; nothing bounds them.

### Local process → Web UI

- Spoofing and elevation of privilege: no credential of any kind. Any local
  process can attach, read screen frames, inject input, list the guest
  filesystem through `browse_directory`, and launch files
  (`src/gui/web_ui.zig:621`, `src/gui/web_ui.zig:630`). The path check confines
  those two commands to `drive_c/`, so the reach here is the guest sandbox, not
  the host root.
- Denial of service: connected clients accumulate without a cap
  (`src/gui/web_ui.zig:11`), and each one receives a full framebuffer push
  (`src/gui/web_ui.zig:62`).

### Browser page → Web UI

- Spoofing: cross-site WebSocket hijacking. The `Origin` allowlist blocks a
  foreign browser origin (`src/config.zig:86`), but a non-browser client omits
  the header entirely and is allowed (`src/gui/web_ui.zig:390`).
- The check is not authentication; the README states this correctly
  (README, 0.2.0 security notes).

### Operator configuration

- Information disclosure and spoofing: a non-loopback `ZINE_WEB_HOST` makes the
  screen, injected input, and `drive_c/` browsing reachable from the network
  with no credential (`src/main.zig:99`). The `Origin` allowlist narrows to the
  configured host (`src/config.zig:86`, `src/config.zig:93`) but does not
  authenticate, and a non-browser client still needs to send no `Origin` at all.
- Tampering: `-Dexternal-stubs` moves stub loading to a runtime directory read
  beside the binary (`src/runner.zig:79`). Whoever writes `<exe dir>/dll`
  controls the code the host maps.

### Configuration and build

- Tampering: `drive_c/` contents and `registry.toml` come from the working
  directory. Whoever writes them changes what the guest sees. The static asset
  branch has the same shape: a non-`/index.html` request is served from
  `src/gui/` under the working directory (`src/gui/web_ui.zig:510`), so whoever
  writes that tree changes what a Web UI client is served.
- Information disclosure: that branch's only traversal control is a substring
  denylist (`src/gui/web_ui.zig:493`), so the effective containment is the
  fixed `src/gui` prefix plus the leading-`/` requirement
  (`src/gui/web_ui.zig:505`), not component resolution.
- Supply chain: the only build-time external dependency is the pinned `toml`
  package in `build.zig.zon`, fetched by Zig on first build. The MSVC 6.0
  fixtures used by the integration suite are proprietary and are not in the
  repository.

### Recurring classes from history

The history shows the classes that come back: input validation at the loader
and path layers (`39ac62b`, `636b72c`, `43d005c`, `3f3ddba`), and truncation
and aliasing on UTF-16 to UTF-8 conversion (`70d22e5`, `8b51a23`). Any new fix
in those areas should be checked against the whole table below, not just the
reported site. The bounds checks added to the loader (`src/loader/module.zig:220`,
`src/loader/module.zig:275`, `src/loader/loader.zig:427`) are the same class of
fix and the same standard applies to every remaining name read, including
`src/loader/loader.zig:506`.

## 5. Mitigations mapping

| Control | Implementation | Threats it covers | What it does not cover |
|---|---|---|---|
| Loopback bind by default | `src/config.zig:14`, `src/gui/web_ui.zig:185` | remote network attackers under default configuration | an operator who sets `ZINE_WEB_HOST`; no credential exists behind the bind |
| Startup env validation | `src/main.zig:73`, `src/main.zig:76`, `src/config.zig:141`, `src/config.zig:188` | misconfigured host, port, clock, and log level reaching a subsystem | anything after startup; validation is shape, not authorization |
| `Origin` allowlist on `/ws` | `src/gui/web_ui.zig:383`, `src/gui/web_ui.zig:424`, `src/config.zig:86` | cross-site WebSocket hijacking from a browser | non-browser clients, requests with no `Origin` |
| `virtualPathToDriveC` | `src/path_utils.zig:237` | Web UI path traversal for `open_file`, `browse_directory`, `launch`, and listing | nothing in this scope; it is the whole control for that boundary |
| Client-controlled paths escaped before broadcast | `src/gui/renderer.zig:930` | a client-supplied path corrupting the JSON broadcast to every client | nothing else; this is a serialization control |
| `find_action` allowlist | `src/gui/web_ui.zig:344` | an unrecognized dialog action reaching the guest as find-next | the other dialog answers, which take range-checked integers |
| Web UI payload caps | `src/gui/web_ui.zig:336`, `src/gui/web_ui.zig:260`, `src/gui/web_ui.zig:541`, `src/gui/web_ui.zig:885` | unbounded client strings in `text_sync`, `clipboard_sync`, and error frames; oversized static assets and error envelopes | total bytes per connection, and the client count |
| HTTP method allowlists | `src/gui/web_ui.zig:281`, `src/gui/web_ui.zig:283`, `src/gui/web_ui.zig:428`, `src/gui/web_ui.zig:475` | write methods on the static branch, non-`GET` upgrades on `/ws` | the WebSocket body stream itself |
| Static asset denylist | `src/gui/web_ui.zig:493` | naive traversal in HTTP asset requests | the Web UI's own commands, which use `virtualPathToDriveC` instead |
| Static response security headers | `src/gui/web_ui.zig:1003`, `src/gui/web_ui.zig:1021`, `src/gui/web_ui.zig:1026` | content sniffing, framing, and referrer leakage from a served asset into the browser that runs the UI | a non-browser client, which ignores all of them |
| Digest-pinned asset cache | `src/gui/web_ui.zig:946`, `src/gui/web_ui.zig:979` | a stale or substituted asset name pinning different bytes under an immutable cache entry | a first-request fetch of a name the server already agrees to serve |
| Accept-failure backoff | `src/gui/web_ui.zig:231`, `src/gui/web_ui.zig:243` | a connect flood spinning the accept loop | a flood of completed connections |
| `drive_c` anchoring with `..` clamping | `src/path_utils.zig:323`, `src/path_utils.zig:364`, `src/path_utils.zig:264` | traversal from `C:` and relative guest paths, including `LoadLibraryA` and `CreateProcessA` | `Z:` mapping (`:346`), absolute POSIX passthrough (`:368`) |
| Home path redaction | `src/log.zig:103`, `src/log.zig:137` | the account name and home-relative paths reaching stderr and CI logs | file contents, and any path outside the home directory |
| Child table cap | `src/win32/kernel32/process.zig:715`, `src/win32/kernel32/process.zig:957` | unbounded child spawning | the actions of the 16 children that do spawn |
| Loader bounds checks | `src/loader/module.zig:220`, `src/loader/module.zig:275`, `src/loader/loader.zig:427`, `src/loader/loader.zig:438`, `src/loader/loader.zig:466`, `src/loader/module.zig:359` | host memory corruption and unbounded reads from crafted sections, BSS ranges, relocations, import descriptors, names, and thunks | the resource parsers' output contract, which rests on fuzzing rather than validation |
| Fuzz harnesses for the untrusted parsers | `src/fuzz/pe.zig`, `src/fuzz/menu.zig`, `src/fuzz/dialog.zig`, `src/fuzz/icon.zig`, `src/fuzz/loadstring.zig`, `src/fuzz/mutation.zig`, `src/fuzz/replay.zig`, `build.zig:588` | host crashes on malformed PE headers, resources, and string tables | logic defects that parse correctly but mean the wrong thing |
| Typed stub signatures | `src/loader/env.zig` | pointer-width confusion at the call boundary | legacy stubs still taking guest pointers as integers |

Unmitigated, ranked: host filesystem reach from the guest (1), unauthenticated
local Web UI (2), host signal dispatch (3), guest egress (4), guest-driven code
loading (5). These are recorded here for sec-review; this document does not fix
them.

README claims checked and left in place: the non-loopback `ZINE_WEB_HOST`
warning, the HTTP 403 for foreign `Origin` headers, the security headers on
every asset response with the `304` repeating them, and the statement that the
`Origin` check is not authentication all match the code (`src/main.zig:99`,
`src/gui/web_ui.zig:424`, `src/gui/web_ui.zig:390`, `src/gui/web_ui.zig:1003`,
`src/gui/web_ui.zig:1021`; README "What works" and the 0.2.0 security notes).

Single points of failure: `toHostPath` is the only path control for the whole
stub layer, and the `Origin` check is the only thing between a browser and the
guest; a defect in either exposes everything it fronts. The Web UI's
`virtualPathToDriveC` is the only control between a local process and the guest
sandbox, and it is a single function called from three sites.

## 6. Abuse cases

- Drive-by guest control: a page the user visits opens
  `ws://127.0.0.1:1995/ws`. The `Origin` check stops that browser case
  (`src/config.zig:86`), but any local script, a browser extension, or a `curl`
  client is accepted, and then `browse_directory` plus `launch` are enough to
  enumerate and start anything under `drive_c/`
  (`src/gui/web_ui.zig:621`, `src/gui/web_ui.zig:630`).
- Clipboard injection: a local client sends `clipboard_sync` with a crafted
  string, and the guest pastes whatever the user later presses Ctrl-V
  (`src/gui/web_ui.zig:763`). The guest's own defenses are the only thing
  between that string and execution.
- Host file theft by a "harmless" app: the guest calls
  `CreateFileA("Z:\\home\\user\\.ssh\\id_rsa")`, which `toHostPath` maps to the
  host root (`src/path_utils.zig:346`), then uploads the bytes over a guest
  socket.
- Existence oracle: `SearchPathA` probes path entries with `access()` and
  returns the match (`src/win32/kernel32/file.zig:701`), so a guest probes the
  host for paths it should not be able to name.
- Response-file disclosure: a guest calls `CreateProcessA` with an argument
  `@secret.txt`, and the spawner copies the first 4096 bytes of that file
  relative to the working directory into the trace output
  (`src/win32/msvcrt/process.zig:536`). The CLI has the same behavior for its
  own arguments (`src/main.zig:493`). Both need tracing on, and both write file
  contents, not just paths, past the home-path redaction.
- Persistent code loading: a guest calls `LoadLibraryA` on a `.dll` it wrote into
  `drive_c/` earlier in the same session
  (`src/win32/kernel32/process.zig:115`), turning its own file write into
  mapped, executed code.
- Persistent configuration poisoning: dropping a `registry.toml` beside the
  guest changes its registry view without touching the guest
  (`src/win32/advapi32/registry_config.zig`).
- Resource exhaustion: a guest that never exits, plus children up to the table
  cap, plus an unbounded list of connected Web UI clients, holds host memory,
  process slots, and per-client framebuffer pushes indefinitely
  (`src/gui/web_ui.zig:11`); nothing in the tree imposes a timeout.

Client-side trust: the frontend's own idea of what paths are valid is not a
control. Every path decision in `src/gui/app.js` is advisory; the server-side
check in `src/path_utils.zig:237` is the only one, and it is reached from three
call sites that each have to call it.

## 7. Document status

- `SECURITY.md`: absent. There is no disclosure contact and no supported
  version list in the repository. README records that no deprecation,
  support-window, or security-backport policy exists, which matches the tree;
  that statement stays in README and is not extended here.
- No owner and no review cadence are recorded for this model; both are unset
  rather than guessed.
- Claims to re-verify on the next pass: every `file:line` above, the
  `virtualPathToDriveC` call sites, the `Module.stringAt` bound and its callers,
  the Web UI command list, the security headers on the static branch, and the
  non-loopback `ZINE_WEB_HOST` warning.

## 8. Response readiness

Note only; no infrastructure is proposed here.

- Diagnostics available for an investigation: `log.warn`/`log.err` to stderr
  (`src/log.zig`), API and instruction tracing via `ZINE_TRACE` and
  `ZINE_TRACE_INSN` (`src/main.zig:120`, `src/main.zig:123`), per-process
  profiling via `ZINE_PROFILE`. There is no audit log of Web UI clients, no
  per-command attribution, and no record of which PE path a child was launched
  from beyond one `log.info` line
  (`src/win32/kernel32/process.zig:977`).
- Documented path from a reported vulnerability to a shipped fix: none. No
  file in the repository describes reporting, triage, or disclosure. The release
  notes carry security items under "Security fixes and migration"
  (README 0.2.0), which is a record of past fixes, not a process.
