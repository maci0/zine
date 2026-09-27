# Threat model

Scope: the `zine` host process and its bundled build artifacts. The subject is a
compatibility layer that loads an untrusted Win32 PE, runs its code inside the
host process, and serves a local Web UI for GUI guests. Companion reviews own
point vulnerabilities (sec-review), endpoint authorization (authz-review), the
CVE inventory (deps-review), and PII mapping (privacy-review); this document
models the surface so those passes can be aimed at it.

Last reviewed: 2026-09-27, against `d62d5ce`.
Owner: unset. Review cadence: unset.

## Risk-ranked summary

| # | Threat | Boundary | Control today |
|---|---|---|---|
| 1 | Guest PE reads and writes any host file | guest → host filesystem | none; `Z:` maps to the host root and absolute POSIX paths pass through (`src/path_utils.zig:345`, `src/path_utils.zig:366`) |
| 2 | Any local process drives the guest through the Web UI | local process → Web UI | `Origin` check that non-browser clients bypass, and no credential of any kind (`src/gui/web_ui.zig:342`, `src/gui/web_ui.zig:383`) |
| 3 | Guest code faults the host process with host signals | guest → host process | in-process signal dispatch, no containment (`src/x86/compat_thunks.zig:117`, `src/x86/execute.zig:1746`) |
| 4 | Guest opens arbitrary network connections | guest → host network | host `socket`/`connect` syscalls are exposed to the guest (`src/win32/ws2_32/winsock.zig:33`) |
| 5 | Unbounded host read from a guest-controlled NUL-terminated string | host → guest loader | import name is `std.mem.span`'d over mapped memory with no bound (`src/loader/loader.zig:431`) |
| 6 | Guest spawns host processes | guest → host process tree | child path anchored in `drive_c/`; table capped at 16 (`src/win32/kernel32/process.zig:711`, `src/win32/kernel32/process.zig:851`) |
| 7 | A non-loopback `ZINE_WEB_HOST` publishes an unauthenticated UI to the network | operator config → network | warning only; the UI is still credential-free (`src/main.zig:99`, `src/config.zig:86`) |
| 8 | Guest command lines and CLI arguments dump named files into the trace log | guest/CLI → logs | `--trace`/`ZINE_TRACE` must be on; home paths are redacted (`src/win32/msvcrt/process.zig:535`, `src/main.zig:480`, `src/log.zig:137`) |
| 9 | Configuration from the working directory changes guest behavior | config file → runtime | per-app `registry.toml` overrides, no integrity check (`src/win32/advapi32/registry_config.zig`) |

Rank reflects exploitability times impact for a user who opens a hostile
executable or visits a hostile page. Items 1, 2, 4, 5, and 6 need only a `.exe`
or a local connection; no privilege is required. Item 7 needs an operator to
set the variable.

Previously ranked as a top-three threat, malformed-PE host memory corruption
(module mapping, relocation application, import walks) is no longer in this
table: those paths carry explicit bounds checks, recorded under section 5.
Residual loader risk is item 5 and the parsers that lack fuzz harnesses.

## 1. Attack surface inventory

### Network

- HTTP + WebSocket server bound to `ZINE_WEB_HOST` (default `127.0.0.1`,
  configurable, `src/config.zig:14`, `src/config.zig:145`) on `ZINE_WEB_PORT`
  (default 1995, `src/config.zig:150`). The listen call is
  `src/gui/web_ui.zig:183`.
- One route: `/ws` (`src/gui/web_ui.zig:382`). Everything else is embedded
  static assets served from the binary (`src/gui/web_ui.zig:865`).
- A non-loopback bind logs one warning and keeps serving
  (`src/main.zig:99`); nothing else changes.
- Guest sockets through `ws2_32`/`wsock32`, which call host `socket`,
  `connect`, `send`, `recv`, `bind`, `listen` directly
  (`src/win32/ws2_32/winsock.zig:33`). The guest is a network client on the
  host's network, with the host's name resolution and firewall position.

### Message and file input

- WebSocket JSON commands, parsed per message (`src/gui/web_ui.zig:419`).
  Commands: `command` (`src/gui/web_ui.zig:442`), `open_file`
  (`src/gui/web_ui.zig:452`), `browse_directory`
  (`src/gui/web_ui.zig:474`), `launch` (`src/gui/web_ui.zig:483`), `resize`,
  `close`, `font_chosen`, `print_chosen`, `page_setup_chosen`. Unknown types
  fall through silently.
- HTTP request paths for static assets, checked by a substring denylist
  (`src/gui/web_ui.zig:745`) before the embedded-asset lookup.
- Guest PE file: headers, sections, relocations, imports, and resources are all
  parsed from the file (`src/pe.zig:317`, `src/loader/module.zig:188`,
  `src/loader/loader.zig:409`). Resource parsers are separate: menus, dialogs,
  icons (`src/loader/menu_parser.zig`, `src/loader/dialog_parser.zig`,
  `src/loader/icon_parser.zig`).
- Guest-controlled file and path strings reaching host filesystem calls via
  `host_io.open` (`src/win32/host_io.zig:30`), `host_io.deleteFile`
  (`src/win32/host_io.zig:196`), and `SearchPathA`
  (`src/win32/kernel32/file.zig:676`).
- `registry.toml` in the working directory, keyed by executable basename,
  overrides registry values the guest reads
  (`src/win32/advapi32/registry_config.zig`).

### CLI, environment, IPC

- CLI options parsed in `src/main.zig:130`: `--trace`/`-t`, `--trace-api`,
  `--trace-insn`, `--profile`, `--interpret`/`-i`, `--jit`, `--quiet`/`-q`,
  `--fltk`, `--no-gui`, `--argv0`, `--help`/`-h`, `--version`/`-v`, and `--`,
  which ends option processing.
- Environment: `ZINE_LOG_LEVEL` (`src/main.zig:73`), `ZINE_WEB_HOST`,
  `ZINE_WEB_PORT`, `ZINE_VIRTUAL_CLOCK_NS`, `ZINE_CLOCK_STEP_NS`
  (`src/config.zig:142`, `src/main.zig:76`), `ZINE_TRACE`, `ZINE_TRACE_INSN`,
  `ZINE_PROFILE` (`src/main.zig:120`), `NO_COLOR` (`src/log.zig:41`), and
  `ZINE_CWD` on WASI (`src/wasm_main.zig:81`). Every one is validated at
  startup and a bad value exits 2 (`src/main.zig:76`). The full host
  environment is handed to the guest as `envp` (`src/main.zig:504`).
- No Unix sockets, no named pipes, no scheduled jobs, and no `dlopen` call
  anywhere in the tree.
- Build-time surface: `-Dexternal-stubs` loads Win32 stubs from shared objects
  and `-Ddll` builds them; those artifacts are chosen by the builder, not at
  runtime.

## 2. Trust boundaries and data flow

| Boundary | Data crossing | Named validation or authentication point |
|---|---|---|
| User → CLI | target path, options, environment | option parsing only (`src/main.zig:130`); the target path is not restricted |
| Operator environment → runtime | `ZINE_WEB_HOST` and the rest | IP-literal and range checks (`src/config.zig:187`, `src/main.zig:76`) |
| Browser page → Web UI | WebSocket frames, `Origin` header | `originAllowed` (`src/gui/web_ui.zig:342`, `src/config.zig:86`), applied to `/ws` only (`src/gui/web_ui.zig:383`) |
| Local process → Web UI | same protocol, no `Origin` | none; absence of the header is treated as allowed (`src/config.zig:86`) |
| Host filesystem → guest loader | PE bytes | PE parser plus bounds checks at every mapped-slice walk (`src/pe.zig:317`, `src/loader/module.zig:215`) |
| Guest → host filesystem | path strings from Win32 stubs | `toHostPath` anchoring for `C:` and relative paths (`src/path_utils.zig:320`) |
| Web UI client → guest filesystem | virtual paths from `open_file`, `browse_directory`, `launch` | `virtualPathToDriveC` (`src/path_utils.zig:236`) called at `src/gui/web_ui.zig:465`, `src/gui/web_ui.zig:487`, `src/gui/renderer.zig:948` |
| Guest → host network | socket calls | none |
| Guest → host process tree | `CreateProcessA` command line | path through `toHostPath`; the rest of the guest command line is passed through (`src/win32/kernel32/process.zig:851`) |
| Host environment → guest | `envp` | none; every host variable is visible to the guest (`src/main.zig:504`) |
| Config file → runtime | `registry.toml` | none beyond TOML parse |
| Build → runtime | assets embedded at build time | none; contents ship with the binary |

Privilege transitions to record: the guest begins as untrusted file content and,
once `CreateProcessA` runs or `socket` succeeds, causes host-level process and
network actions under the invoking user's credentials. There is no privilege
drop between guest and host anywhere in the tree. The second transition is
operator to network: setting `ZINE_WEB_HOST` moves an unauthenticated UI off
loopback, and the only response is one log line.

Secrets: the project stores none. Credentials enter only through the host
environment or files under `drive_c/`, are readable by the guest, and are
forwarded to child guests through `envp` (`src/main.zig:504`). No rotation
point exists because nothing is persisted.

## 3. Assets and impact

- Host filesystem contents reachable through `Z:` or absolute POSIX paths
  (`src/path_utils.zig:345`): source trees, `~/.ssh`, browser profiles, tokens
  in dotfiles. Destruction or overwriting of a user file is the worst case
  here.
- Host process integrity. Guest code runs in the host address space and faults
  are serviced by a host SIGSEGV handler
  (`src/x86/compat_thunks.zig:117`), so a guest defect can end as a host crash
  with a partial file write behind it.
- Host network position. Guest socket calls borrow the host's connections
  (`src/win32/ws2_32/winsock.zig:33`): data exfiltration and abuse of the
  user's egress identity.
- Local GUI session. Screen frames, key and mouse input, and the guest's file
  picker contents flow to any Web UI client that connects
  (`src/gui/web_ui.zig:62`).
- Availability: the Web UI server and guest children are unbounded in wall
  clock; the child table is capped at 16
  (`src/win32/kernel32/process.zig:711`).
- Reputation: the host printing the guest's dialogs and windows to a browser
  page the user trusts, and printing host paths to a captured CI log.

## 4. Threats per boundary

### Host → guest loader (untrusted PE)

- Denial of service: file size drives one allocation of the whole image
  (`src/loader/module.zig:173`); a large PE costs the host that memory before
  the guest runs a single instruction.
- Information disclosure and denial of service: import DLL names are read with
  `std.mem.span` over mapped memory (`src/loader/loader.zig:431`), which scans
  to the first NUL with no length bound. A descriptor whose name field has no
  terminator in the mapping walks off the end of the image in the host
  process. Recorded for sec-review; the neighbouring descriptor and thunk
  walks do bound their reads (`src/loader/loader.zig:420`,
  `src/loader/loader.zig:460`).
- Tampering: the menu, dialog, and icon parsers have no fuzz harness
  (AGENTS.md records this), so the host-parsed resource surface is the least
  exercised part of the loader.
- Repudiation: a guest can delete or overwrite its own file, and the host
  records no provenance of what it loaded.

### Guest → host process (native execution)

- Denial of service: any invalid guest access reaches the host signal
  dispatcher (`src/x86/execute.zig:1746`, `src/x86/compat_thunks.zig:117`).
  The x86 target deliberately disables SIMD to keep 4-byte stack alignment, so
  stack-sensitive host paths remain reachable.
- Elevation of privilege: the guest does not need an exploit to reach host
  syscalls; the stubs are the interface.

### Guest → host filesystem

- Tampering and information disclosure: `Z:\...` maps to the host root
  (`src/path_utils.zig:345`) and absolute POSIX paths pass through unchanged
  (`src/path_utils.zig:366`). Read, write, and delete are all available
  (`src/win32/host_io.zig:30`, `src/win32/host_io.zig:196`).
- Spoofing: `SearchPathA` ignores the caller's search path and probes the
  guest's `PATH` entries with `access()` (`src/win32/kernel32/file.zig:676`,
  `src/win32/kernel32/file.zig:727`); a guest can name a directory it should
  not know about and learn whether it exists.

### Web UI client → guest filesystem

- Tampering: `virtualPathToDriveC` is the control here, and it is a real
  component check, not a substring denylist: NUL, backslash, leading `/`,
  drive letter, and `.`/`..` components are each refused, and input longer
  than `normalizePath`'s 128-component capacity is refused rather than
  silently truncated (`src/path_utils.zig:236`, `src/path_utils.zig:245`).
  Directory listing goes through the same function
  (`src/gui/renderer.zig:948`).

### Guest → host process tree

- Elevation of privilege: `CreateProcessA` re-executes the host binary with a
  guest-controlled path and arguments (`src/win32/kernel32/process.zig:854`,
  `src/win32/kernel32/process.zig:919`).
- Information disclosure: an argument beginning with `@` makes the spawner
  open that name relative to the working directory and copy up to 4096 bytes
  into the trace output (`src/win32/msvcrt/process.zig:535`).
- Denial of service: 16 concurrent children, then refusals; each child is
  another full guest with its own allocator and stack.

### Guest → host network

- Information disclosure and spoofing: raw socket operations, no egress
  policy, no rate limit, and the guest chooses the destination.
- Denial of service: a guest can hold connections open; nothing bounds them.

### Local process → Web UI

- Spoofing and elevation of privilege: no credential of any kind. Any local
  process can attach, read screen frames, inject input, list the guest
  filesystem through `browse_directory`, and launch files
  (`src/gui/web_ui.zig:474`, `src/gui/web_ui.zig:483`). The path check
  confines those two commands to `drive_c/`, so the reach here is the guest
  sandbox, not the host root.
- Repudiation: commands arriving over the socket are not attributed to a client
  identity, so a drive-by action is indistinguishable from the user's.

### Browser page → Web UI

- Spoofing: cross-site WebSocket hijacking. The `Origin` allowlist blocks a
  foreign browser origin (`src/config.zig:86`), but a non-browser client omits
  the header entirely and is allowed.
- The check is not authentication; the README states this correctly
  (README, 0.2.0 security notes).

### Operator configuration

- Information disclosure and spoofing: a non-loopback `ZINE_WEB_HOST` makes the
  screen, injected input, and `drive_c/` browsing reachable from the network
  with no credential (`src/main.zig:99`). The `Origin` allowlist narrows to
  the configured host (`src/config.zig:93`) but does not authenticate, and a
  non-browser client still needs to send no `Origin` at all.

### Configuration and build

- Tampering: `drive_c/` contents and `registry.toml` come from the working
  directory. Whoever writes them changes what the guest sees, and for
  `-Dexternal-stubs` also which stub code runs.
- Supply chain: the only build-time external dependency is the pinned `toml`
  package in `build.zig.zon`, fetched by Zig on first build. The MSVC 6.0
  fixtures used by the integration suite are proprietary and are not in the
  repository.

### Recurring classes from history

The history shows the classes that come back: input validation at the loader
and path layers (`39ac62b`, `636b72c`, `43d005c`, `3f3ddba`), and truncation
and aliasing on UTF-16 to UTF-8 conversion (`70d22e5`, `8b51a23`, `8b5100c`).
Any new fix in those areas should be checked against the whole table below,
not just the reported site. The bounds checks added to the loader since
(`src/loader/module.zig:215`, `src/loader/module.zig:270`,
`src/loader/loader.zig:420`) are the same class of fix and the same standard
should apply to `src/loader/loader.zig:431`.

## 5. Mitigations mapping

| Control | Implementation | Threats it covers | What it does not cover |
|---|---|---|---|
| Loopback bind by default | `src/config.zig:14`, `src/gui/web_ui.zig:183` | remote network attackers under default configuration | an operator who sets `ZINE_WEB_HOST`; no credential exists behind the bind |
| Startup env validation | `src/main.zig:73`, `src/main.zig:76`, `src/config.zig:142` | misconfigured host, port, clock, and log level reaching a subsystem | anything after startup; validation is shape, not authorization |
| `Origin` allowlist on `/ws` | `src/gui/web_ui.zig:342`, `src/config.zig:86` | cross-site WebSocket hijacking from a browser | non-browser clients, requests with no `Origin` |
| `virtualPathToDriveC` | `src/path_utils.zig:236` | Web UI path traversal for `open_file`, `browse_directory`, `launch`, and listing | nothing in this scope; it is the whole control for that boundary |
| Static asset denylist | `src/gui/web_ui.zig:745` | naive traversal in HTTP asset requests | the Web UI's own commands, which use `virtualPathToDriveC` instead |
| `drive_c` anchoring with `..` clamping | `src/path_utils.zig:320`, `src/path_utils.zig:264` | traversal from `C:` and relative guest paths | `Z:` mapping (`:345`), absolute POSIX passthrough (`:366`) |
| Home path redaction | `src/log.zig:101`, `src/log.zig:137` | the account name and home-relative paths reaching stderr and CI logs | file contents, and any path outside the home directory |
| Child table cap | `src/win32/kernel32/process.zig:711` | unbounded child spawning | the actions of the 16 children that do spawn |
| Loader bounds checks | `src/loader/module.zig:215`, `src/loader/module.zig:270`, `src/loader/loader.zig:420`, `src/loader/loader.zig:460` | host memory corruption from crafted sections, BSS ranges, relocations, import descriptors, and thunks | unbounded NUL scans in name reads (`src/loader/loader.zig:431`); resource parsers without a fuzz harness |
| Typed stub signatures | `src/loader/env.zig` | pointer-width confusion at the call boundary | legacy stubs still taking guest pointers as integers |

Unmitigated, ranked: host filesystem reach from the guest (1), unauthenticated
local Web UI (2), host signal dispatch (3), guest egress (4), unbounded name
scan in the loader (5). These are recorded here for sec-review; this document
does not fix them.

Claims that earlier passes in this document made and the code contradicts,
now corrected:

- The Web UI path handling was described as a substring denylist
  (`..`, NUL) with alternate separators able to slip past. The commands use
  `virtualPathToDriveC`, which rejects those inputs by component
  (`src/path_utils.zig:236`). The substring denylist that remains
  (`src/gui/web_ui.zig:745`) only guards static asset requests.
- Malformed-PE host memory corruption was described as raw pointer
  arithmetic over mapped bytes. Section, BSS, relocation, and import walks all
  carry bounds checks today.
- The server was described as loopback-only on a fixed port. Both the host and
  the port are operator-configurable (`src/config.zig:145`,
  `src/config.zig:150`).
- `SearchPathA` was cited in `src/win32/host_io.zig`; it lives in
  `src/win32/kernel32/file.zig:676`.

README claims checked and left in place: the non-loopback `ZINE_WEB_HOST`
warning and the statement that the `Origin` check is not authentication both
match the code (README, "What works" and the 0.2.0 security notes).

Single points of failure: `toHostPath` is the only path control for the whole
stub layer, and the `Origin` check is the only thing between a browser and the
guest; a defect in either exposes everything it fronts. The Web UI's
`virtualPathToDriveC` is the only control between a local process and the guest
sandbox, and it is a single function called from three sites.

## 6. Abuse cases

- Drive-by guest control: a page the user visits opens
  `ws://127.0.0.1:1995/ws`. The `Origin` check stops that browser case
  (`src/config.zig:86`), but any local script, a browser extension, or a
  `curl` client is accepted, and then `browse_directory` plus `launch` are
  enough to enumerate and start anything under `drive_c/`
  (`src/gui/web_ui.zig:474`, `src/gui/web_ui.zig:483`).
- Host file theft by a "harmless" app: the guest calls
  `CreateFileA("Z:\\home\\user\\.ssh\\id_rsa")`, which `toHostPath` maps to the
  host root (`src/path_utils.zig:345`), then uploads the bytes over a guest
  socket.
- Existence oracle: `SearchPathA` probes `PATH` entries with `access()` and
  returns the match (`src/win32/kernel32/file.zig:676`), so a guest probes
  the host for paths it should not be able to name.
- Response-file disclosure: a guest calls `CreateProcessA` with an argument
  `@secret.txt`, and the spawner copies the first 4096 bytes of that file
  relative to the working directory into the trace output
  (`src/win32/msvcrt/process.zig:535`). The CLI has the same behavior for its
  own arguments (`src/main.zig:480`). Both need tracing on, and both write
  file contents, not just paths, past the home-path redaction.
- Persistent configuration poisoning: dropping a `registry.toml` beside the
  guest changes its registry view without touching the guest
  (`src/win32/advapi32/registry_config.zig`).
- Resource exhaustion: a guest that never exits, plus children up to the
  table cap, holds host memory and process slots indefinitely; nothing in the
  tree imposes a timeout.

Client-side trust: the frontend's own idea of what paths are valid is not a
control. Every path decision in `src/gui/app.js` is advisory; the server-side
check in `src/path_utils.zig:236` is the only one, and it is reached from three
call sites that each have to call it.

## 7. Document status

- `SECURITY.md`: absent. There is no disclosure contact and no supported
  version list in the repository. README 0.2.0 records that no deprecation,
  support-window, or security-backport policy exists, which matches the tree;
  that statement stays in README and is not extended here.
- No owner and no review cadence are recorded for this model; both are unset
  rather than guessed.
- Claims to re-verify on the next pass: every `file:line` above, the
  `virtualPathToDriveC` call sites, the loader bounds checks, and the
  non-loopback `ZINE_WEB_HOST` warning.

## 8. Response readiness

Note only; no infrastructure is proposed here.

- Diagnostics available for an investigation: `log.warn`/`log.err` to stderr
  (`src/log.zig`), API and instruction tracing via `ZINE_TRACE` and
  `ZINE_TRACE_INSN` (`src/main.zig:120`), per-process profiling via
  `ZINE_PROFILE`. There is no audit log of Web UI clients, no per-command
  attribution, and no record of which PE path a child was launched from
  beyond one `log.info` line (`src/win32/kernel32/process.zig:951`).
- Documented path from a reported vulnerability to a shipped fix: none. No
  file in the repository describes reporting, triage, or disclosure. The
  release notes carry security items under "Security fixes and migration"
  (README 0.2.0), which is a record of past fixes, not a process.
