# Threat model

Scope: the `zine` host process and its bundled build artifacts. The subject is a
compatibility layer that loads an untrusted Win32 PE, runs its code inside the
host process, and serves a local Web UI for GUI guests. Companion reviews own
point vulnerabilities (sec-review), endpoint authorization (authz-review), the
CVE inventory (deps-review), and PII mapping (privacy-review); this document
models the surface so those passes can be aimed at it.

Last reviewed: 2026-09-27, against `v0.2.0` plus `5022105`.
Owner: unset. Review cadence: unset.

## Risk-ranked summary

| # | Threat | Boundary | Control today |
|---|---|---|---|
| 1 | Guest PE reads and writes any host file | guest → host filesystem | none; `drive_c` anchoring is bypassable (`src/path_utils.zig:310`, `src/path_utils.zig:332`) |
| 2 | Any local process drives the guest through the Web UI | local process → Web UI | loopback bind plus an `Origin` check that non-browser clients bypass (`src/gui/web_ui.zig:125`, `src/gui/web_ui.zig:184`) |
| 3 | Malformed guest PE corrupts host memory | host → guest loader | Zig allocator for file data; guest image and interpreter share the host address space (`src/loader/module.zig:167`, `src/loader/module.zig:621`) |
| 4 | Guest code faults the host process with host signals | guest → host process | in-process signal dispatch, no containment (`src/x86/compat_thunks.zig:117`) |
| 5 | Guest opens arbitrary network connections | guest → host network | host `socket`/`connect` syscalls are exposed to the guest (`src/win32/ws2_32/winsock.zig:33`) |
| 6 | Guest spawns host processes | guest → host process tree | child path anchored in `drive_c`; table capped at 16 (`src/win32/kernel32/process.zig:697`, `src/win32/kernel32/process.zig:838`) |
| 7 | Web UI path handling uses substring denylists | Web UI → guest filesystem | `..` and NUL rejected as substrings, not normalized (`src/gui/web_ui.zig:289`, `src/gui/web_ui.zig:313`, `src/gui/web_ui.zig:328`) |
| 8 | Host environment and file contents leak into guest-visible logs | host → guest, host → logs | trace output goes to stderr only (`src/main.zig:442`) |
| 9 | Configuration from the working directory changes guest behavior | config file → runtime | per-app `registry.toml` overrides (`src/win32/advapi32/registry_config.zig`) |

Rank reflects exploitability times impact for a user who opens a hostile
executable or a hostile page. Items 1, 2, and 5 are reachable by anyone who can
supply a `.exe` or connect to loopback; no privilege is required.

## 1. Attack surface inventory

### Network

- HTTP + WebSocket server, loopback only, fixed port 1995
  (`src/gui/web_ui.zig:125`). One route: `/ws` (`src/gui/web_ui.zig:211`).
  Everything else is embedded static assets served from the binary
  (`src/gui/web_ui.zig:705`).
- Guest sockets through `ws2_32`/`wsock32`, which call host `socket`,
  `connect`, `send`, `recv`, `bind`, `listen` directly
  (`src/win32/ws2_32/winsock.zig:33` for the syscall wrappers). The guest is a network client
  on the host's network, with the host's name resolution and firewall
  position.

### Message and file input

- WebSocket JSON commands, parsed per message
  (`src/gui/web_ui.zig:263`). Commands: `command`, `open_file`,
  `browse_directory`, `launch`, `resize`, `close`, `font_chosen`,
  `print_chosen`, `page_setup_chosen`, and the remaining keys of
  `src/gui/web_ui.zig:270` onward. Unknown types fall through silently.
- Guest PE file: headers, sections, relocations, imports, and resources are
  all parsed from the file (`src/pe.zig:317`, `src/loader/module.zig:197`).
  Resource parsers are separate: menus, dialogs, icons
  (`src/loader/menu_parser.zig`, `src/loader/dialog_parser.zig`,
  `src/loader/icon_parser.zig`).
- Guest-controlled file and path strings reaching host filesystem calls via
  `host_io.open` (`src/win32/host_io.zig:30`),
  `host_io.deleteFile` (`src/win32/host_io.zig:196`), and
  `host_io.searchPath` (`src/win32/host_io.zig:331`).
- `registry.toml` in the working directory, keyed by executable basename,
  overrides registry values the guest reads
  (`src/win32/advapi32/registry_config.zig`).

### CLI, environment, IPC

- CLI options parsed in `src/main.zig:106`; `--` ends options, `--argv0`
  overrides the guest program name, `--trace`/`--trace-insn`/`--profile`
  change diagnostics, `--fltk`/`--no-gui` select the backend.
- Environment: `ZINE_LOG_LEVEL` (validated, unknown values exit 2,
  `src/main.zig:74`, `src/log.zig:170`), `ZINE_TRACE`, `ZINE_TRACE_INSN`,
  `ZINE_PROFILE` (`src/main.zig:95`), `NO_COLOR` (`src/log.zig:41`). The full
  host environment is handed to the guest as `envp` (`src/main.zig:462`).
- No Unix sockets, no named pipes, no scheduled jobs, no plugin loading
  through `dlopen` (there is no `dlopen` call in the tree).
- Build-time surface: `-Dexternal-stubs` loads Win32 stubs from shared objects
  and `-Ddll` builds them; those artifacts are chosen by the builder, not at
  runtime.

## 2. Trust boundaries and data flow

| Boundary | Data crossing | Named validation or authentication point |
|---|---|---|
| User → CLI | target path, options, environment | option parsing only (`src/main.zig:106`); the target path is not restricted |
| Browser page → Web UI | WebSocket frames, `Origin` header | `originAllowed` (`src/gui/web_ui.zig:169`), applies to `/ws` only (`src/gui/web_ui.zig:212`) |
| Local process → Web UI | same protocol, no `Origin` | none; absence of the header is treated as allowed (`src/gui/web_ui.zig:184`) |
| Host filesystem → guest loader | PE bytes | PE parser and Zig allocator (`src/pe.zig:317`, `src/loader/module.zig:182`) |
| Guest → host filesystem | path strings from Win32 stubs | `toHostPath` anchoring for `C:` and relative paths (`src/path_utils.zig:287`) |
| Guest → host network | socket calls | none |
| Guest → host process tree | `CreateProcessA` command line | path through `toHostPath`; the rest of the guest command line is passed through (`src/win32/kernel32/process.zig:836`) |
| Host environment → guest | `envp` | none; every host variable is visible to the guest (`src/main.zig:462`) |
| Config file → runtime | `registry.toml` | none beyond TOML parse |
| Build → runtime | assets embedded at build time | none; contents ship with the binary |

Privilege transitions to record: the guest begins as untrusted file content and,
once `CreateProcessA` runs or `socket` succeeds, causes host-level process and
network actions under the invoking user's credentials. There is no privilege
drop between guest and host anywhere in the tree.

Secrets: the project stores none. Credentials enter only through the host
environment or files under `drive_c/`, are readable by the guest, and are
forwarded to child guests through `envp` (`src/main.zig:462`). No rotation
point exists because nothing is persisted.

## 3. Assets and impact

- Host filesystem contents reachable through `Z:\` or absolute POSIX paths
  (`src/path_utils.zig:310`, `src/path_utils.zig:332`): source trees, SSH
  agent sockets' parent directories, browser profiles, tokens in dotfiles.
  Destruction or overwriting of a user file is the worst case here.
- Host process integrity. On the x86 native path, guest code runs in the host
  address space and faults are serviced by a host SIGSEGV handler
  (`src/x86/compat_thunks.zig:117`), so a guest defect can end as a host
  crash with a partial file write behind it.
- Host network position. Guest socket calls borrow the host's connections
  (`src/win32/ws2_32/winsock.zig:33`): data exfiltration and abuse of the
  user's egress identity.
- Local GUI session. Screen frames, key and mouse input, and the guest's file
  picker contents flow to any Web UI client that connects
  (`src/gui/web_ui.zig:50`).
- Availability: the Web UI server and guest children are unbounded in wall
  clock; the child table is capped at 16 (`src/win32/kernel32/process.zig:697`).
- Reputation: the host printing the guest's dialogs and windows to a browser
  page the user trusts.

## 4. Threats per boundary

### Host → guest loader (untrusted PE)

- Tampering, elevation of privilege: crafted section sizes, relocation blocks,
  and import descriptors drive raw pointer arithmetic over mapped file bytes
  (`src/loader/module.zig:282`). A parsing error here is host memory
  corruption, not a guest crash.
- Denial of service: file size drives one allocation of the whole image
  (`src/loader/module.zig:182`); a large PE costs the host that memory
  before the guest runs a single instruction.
- Repudiation: a guest can delete or overwrite its own file, and the host
  records no provenance of what it loaded.

### Guest → host process (native execution)

- Denial of service: any invalid guest access reaches the host signal
  dispatcher (`src/x86/execute.zig:1742` (SEH chain inside the host signal handler)). The x86 target deliberately
  disables SIMD to keep 4-byte stack alignment, so stack-sensitive host paths
  remain reachable.
- Elevation of privilege: the guest does not need an exploit to reach host
  syscalls; the stubs are the interface.

### Guest → host filesystem

- Tampering and information disclosure: `Z:\...` maps to the host root
  (`src/path_utils.zig:310`) and absolute POSIX paths pass through unchanged
  (`src/path_utils.zig:332`). Read, write, and delete are all available
  (`src/win32/host_io.zig:30`, `src/win32/host_io.zig:196`).
- Spoofing: `searchPath` trusts a semicolon-separated guest string and probes
  the host for matches (`src/win32/host_io.zig:331`); a guest can name a
  directory it should not know about and learn whether it exists.

### Guest → host process tree

- Elevation of privilege: `CreateProcessA` re-executes the host binary with a
  guest-controlled path and arguments (`src/win32/kernel32/process.zig:923`).
- Denial of service: 16 concurrent children, then refusals; each child is
  another full guest with its own allocator and stack.

### Guest → host network

- Information disclosure and spoofing: raw socket operations, no egress
  policy, no rate limit, and the guest chooses the destination.
- Denial of service: a guest can hold connections open; nothing bounds them.

### Local process → Web UI

- Spoofing and elevation of privilege: no credential of any kind. Any local
  process can attach, read screen frames, inject input, browse the guest
  filesystem through `browse_directory`, and launch files (`src/gui/web_ui.zig:307`,
  `src/gui/web_ui.zig:322`).
- Repudiation: commands arriving over the socket are not attributed to a
  client identity, so a drive-by action is indistinguishable from the user's.

### Browser page → Web UI

- Spoofing: cross-site WebSocket hijacking. The `Origin` allowlist blocks a
  foreign browser origin (`src/gui/web_ui.zig:173`), but a non-browser client
  omits the header entirely and is allowed (`src/gui/web_ui.zig:184`).
- The check is not authentication; the README states this correctly.

### Configuration and build

- Tampering: `drive_c/` contents and `registry.toml` come from the working
  directory. Whoever writes them changes what the guest sees, and for
  `-Dexternal-stubs` also which stub code runs.
- Supply chain: the only build-time external dependency is the pinned
  `toml` package in `build.zig.zon`, fetched by Zig on first build. The MSVC
  6.0 fixtures used by the integration suite are proprietary and are not in
  the repository.

### Recurring classes from history

The history shows the classes that come back: input validation at the loader
and path layers (`39ac62b`, `636b72c`, `43d005c`, `3f3ddba`), and truncation
and aliasing on UTF-16 to UTF-8 conversion (`70d22e5`, `8b51a23`, `8b5100c`).
Any new fix in those areas should be checked against the whole table below,
not just the reported site.

## 5. Mitigations mapping

| Control | Implementation | Threats it covers | What it does not cover |
|---|---|---|---|
| Loopback bind | `src/gui/web_ui.zig:125` | remote network attackers | other local users or processes, containers sharing the netns |
| `Origin` allowlist on `/ws` | `src/gui/web_ui.zig:169` | cross-site WebSocket hijacking from a browser | non-browser clients, requests with no `Origin` |
| `..` and NUL substring rejection | `src/gui/web_ui.zig:289`, `:313`, `:328` | naive traversal in Web UI paths | absolute paths, alternate separators, `drive_c/`-relative shapes the denylist does not model |
| `drive_c` anchoring with `..` clamping | `src/path_utils.zig:229`, `:327` | traversal from `C:` and relative guest paths | `Z:` mapping (`:310`), absolute POSIX passthrough (`:332`) |
| Log-level validation | `src/main.zig:74`, `src/log.zig:170` | startup misconfiguration | everything after startup |
| Child table cap | `src/win32/kernel32/process.zig:697` | unbounded child spawning | the actions of the 16 children that do spawn |
| Typed stub signatures | `src/loader/env.zig` | pointer-width confusion at the call boundary | legacy stubs still taking guest pointers as integers |
| Zig safe allocator for PE file data | `src/loader/module.zig:182` | overflow in host-side copies | unaligned casts over mapped file bytes (`src/loader/module.zig:283`) |

Unmitigated, ranked: host filesystem reach from the guest (1), unauthenticated
local Web UI (2), host memory safety under malformed PE (3), host signal
dispatch (4), guest egress (5). These are recorded here for sec-review; this
document does not fix them.

Claims in the documentation that the code does not back:

- README "What works" lists a "Virtual filesystem rooted at `drive_c/`". The
  0.2.0 security notes qualify it, but the bullet alone overstates the
  boundary. The qualifier now sits next to the bullet.

Single points of failure: the `Origin` check is the only control between a
browser and the guest, and `toHostPath` is the only path control for the
whole stub layer; a defect in either exposes everything it fronts.

## 6. Abuse cases

- Drive-by guest control: a page the user visits opens
  `ws://127.0.0.1:1995/ws`. The `Origin` check stops that browser case
  (`src/gui/web_ui.zig:173`), but any local script, a browser extension, or a
  `curl` client is accepted, and then `browse_directory` plus `launch` are
  enough to read and start files under `drive_c/`
  (`src/gui/web_ui.zig:307`, `src/gui/web_ui.zig:322`).
- Host file theft by a "harmless" app: the guest calls `CreateFileA("Z:\\home\\user\\.ssh\\id_rsa")`,
  which `toHostPath` maps to the host root (`src/path_utils.zig:310`), then
  uploads the bytes over a guest socket.
- Persistent configuration poisoning: dropping a `registry.toml` beside the
  guest changes its registry view without touching the guest
  (`src/win32/advapi32/registry_config.zig`).
- Log-based disclosure: an argument beginning with `@` makes tracing dump the
  named file into the trace output (`src/main.zig:442`), so enabling
  `ZINE_TRACE` and running a hostile guest writes host file contents to the
  terminal or captured CI log.
- Resource exhaustion: a guest that never exits, plus children up to the
  table cap, holds host memory and process slots indefinitely; nothing in the
  tree imposes a timeout.

Client-side trust: the frontend's own idea of what paths are valid is not a
control. Every path decision in `src/gui/app.js` is advisory; the server-side
checks in `src/gui/web_ui.zig` are the only ones, and they are denylists.

## 7. Document status

- `SECURITY.md`: absent. There is no disclosure contact and no supported
  version list in the repository. README 0.2.0 records that no deprecation,
  support-window, or security-backport policy exists, which matches the tree;
  that statement stays in README and is not extended here.
- No owner and no review cadence are recorded for this model; both are unset
  rather than guessed.
- Claims to re-verify on the next pass: every `file:line` above, the README
  "What works" bullet, and the `Origin` allowlist in
  `src/gui/web_ui.zig:173`.

## 8. Response readiness

Note only; no infrastructure is proposed here.

- Diagnostics available for an investigation: `log.warn`/`log.err` to stderr
  (`src/log.zig`), API and instruction tracing via `ZINE_TRACE` and
  `ZINE_TRACE_INSN` (`src/main.zig:95`), per-process profiling via
  `ZINE_PROFILE`. There is no audit log of Web UI clients, no per-command
  attribution, and no record of which PE path a child was launched from
  beyond one `log.info` line (`src/win32/kernel32/process.zig:938`).
- Documented path from a reported vulnerability to a shipped fix: none. No
  file in the repository describes reporting, triage, or disclosure. The
  release notes carry security items under "Security fixes and migration"
  (README 0.2.0), which is a record of past fixes, not a process.
