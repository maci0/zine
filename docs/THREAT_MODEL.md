# Threat model

Last reviewed: 2026-11-12, against commit `97150cd`. Owner and review cadence
are organizational and are not recorded here.

This is the host process that loads and runs an untrusted 32-bit Windows PE.
The guest is the attacker. Anyone who can reach the native web UI, and anyone
who can influence the host process's environment or the files the guest reads,
is also one. There is no account system, no tenant boundary, and no network
service other than the optional web UI.

## Risk-ranked summary

| Rank | Risk | Why it is this high | State |
|---|---|---|---|
| 1 | Guest code runs with the host's privileges and can read and write the host filesystem | `Z:\` and absolute POSIX paths map to the host root (`src/path_utils.zig:425`, `src/path_utils.zig:447`); Winsock opens real sockets (`src/win32/ws2_32/winsock.zig:136`) | by design, documented, not a sandbox |
| 2 | Native web UI is unauthenticated and can launch a guest, read files, and set the clipboard | every browser client on the bind address is trusted (`src/gui/web_ui.zig:584`); the default bind is loopback (`src/config.zig:15`) | mitigated only by the bind address and an `Origin` check |
| 3 | A guest can read an arbitrary host file through a response-file argument | `src/win32/msvcrt/process.zig:582` opens `@path` and records that it did | no path restriction |
| 4 | Guest-controlled input reaches executable mappings with no size cap | `src/loader/module.zig:177` allocates `file_size` bytes and maps `SizeOfImage` | bounds checks exist; no quota |
| 5 | Shared host state is mutated from the guest and from web clients without a registry lock | `src/loader/registry.zig:223` holds the module table in an unlocked hashmap | open |

## 1. Attack surface inventory

Entry points that accept data from outside the process:

- **The guest PE.** `src/main.zig:266` takes the positional path, and
  `src/loader/module.zig:162` reads the whole file into memory. The bytes are
  untrusted: headers, import names, resources, and the code itself.
- **Batch scripts.** `src/bat.zig:159` reads a `.bat` up to 10 MiB and
  `src/bat.zig:194` interprets it into an argv the emulator then executes.
- **Host CLI and environment.** `src/main.zig:117` walks argv before any guest
  runs. `src/config.zig:184` reads `ZINE_WEB_HOST`, `ZINE_WEB_PORT`,
  `ZINE_VIRTUAL_CLOCK_NS`, `ZINE_CLOCK_STEP_NS`, and `ZINE_CWD`;
  `src/config.zig:260` warns on a name it does not recognize rather than
  honoring it. `src/log.zig:304` reads `ZINE_LOG_LEVEL`. `src/fuzz/seed.zig:20`
  reads `ZINE_FUZZ_SEED` from the fuzz harnesses only.
- **The native web UI.** `src/gui/web_ui.zig:160` binds from
  `config.web_server`, which defaults to `127.0.0.1:1995`
  (`src/config.zig:19`). One connection serves static assets and the `/ws`
  upgrade (`src/gui/web_ui.zig:584`). The message types a client may send are
  `open_file`, `browse_directory`, `launch`, `resize`, `close`,
  `font_chosen`, `print_chosen`, `page_setup_chosen`, `cancel_dialog`,
  `find_action`, `text_sync`, `clipboard_sync`, `color_selected`,
  `listbox_select`, `context_menu_select`, `set_volume`, `keydown`, `keyup`,
  `wheel`, and the mouse events (`src/gui/web_ui.zig:819` onward).
- **Guest filesystem calls.** `src/win32/host_io.zig:30` and
  `src/win32/msvcrt/posix_fs.zig:322` turn a guest path into a host `open`.
  `src/win32/kernel32/profile.zig:74` reads an INI the guest names, capped at
  the 16 KiB scratch buffer (`src/win32/kernel32/profile.zig:12`).
- **Guest process and library loading.** `src/win32/kernel32/process.zig:128`
  loads a DLL from a guest path. `src/win32/kernel32/process.zig:876` spawns a
  child `zine` for `CreateProcessA`, capped at 16 live children
  (`src/win32/kernel32/process.zig:763`).
- **Guest networking.** `src/win32/ws2_32/winsock.zig:293` exposes `socket`,
  `bind`, `listen`, `accept`, and `connect` as raw host syscalls
  (`src/win32/ws2_32/winsock.zig:136`). No allowlist, no egress policy.
- **The WASI host.** On wasm the same entry points exist, but sockets and
  process spawning are stubs and filesystem reach is bounded by the host's
  preopens (`src/path_utils.zig:71`).

Inputs the code treats as trusted that arrive from outside:

- **Request headers.** `Origin` is checked (`src/gui/web_ui.zig:544`); a request
  that omits it is accepted (`src/gui/web_ui.zig:551`). No other header is
  authenticated. `Accept-Encoding` only selects a precompressed body.
- **Filenames.** A guest path is translated, not authorized. `toHostPath` sends
  `Z:` to `/` and passes an absolute POSIX path through unchanged
  (`src/path_utils.zig:425`, `src/path_utils.zig:447`).
- **Child arguments.** `CreateProcessA` forwards the guest's command line tail
  to the child verbatim (`src/win32/kernel32/process.zig:991`).

Surface added by build and deployment:

- `-Dexternal-stubs` makes the loader search `<exe>/dll` for stub DLLs
  (`src/runner.zig:79`). A stub planted there runs as the host.
- `-Dfltk` links a native GUI. It adds no network listener; its event queue is
  `src/gui/fltk_ui.zig`.
- `zig build sbom` emits a CycloneDX inventory (`build.zig:500`). It is a
  record of what shipped, not a control.

## 2. Trust boundaries and data flow

**Operator to process.** The operator chooses the PE, the argv, and the
environment. `src/config.zig:184` validates shape (an address literal, a
non-zero port, a numeric clock) and rejects an unknown `ZINE_*` name. Nothing
here authorizes the operator against anyone else; the operator is the trust
root.

**Guest to host.** The transition where authority grows. Guest code executes
inside the host address space, and a stub call runs with the host's uid, file
descriptors, and network. `src/loader/env.zig:332` keeps guest-pointer
translation in the thunk layer so a stub sees a host pointer; that is a
correctness boundary, not a privilege boundary. There is no seccomp, no
namespace, and no drop of credentials. `src/platform/native.zig:1252` sets
`PR_SET_NO_NEW_PRIVS` on x86_64 Linux, which stops a later privilege gain; it
does not reduce the privileges the process already holds.

**Browser to web UI.** `src/gui/web_ui.zig:544` is the only check, and it
compares `Origin` against the bound host and port
(`src/config.zig:92`). It is absent for non-browser clients. A web client that
passes it can do everything the message list above allows, including `launch`.

**Web UI to guest.** `open_file`, `browse_directory`, and `launch` go through
`virtualPathToDriveC` (`src/gui/web_ui.zig:832`, `src/gui/web_ui.zig:854`,
`src/gui/renderer.zig:988`), which confines those three
commands to `drive_c/`. The other message types write shared renderer state
that the guest later reads.

**Guest to host filesystem.** `toHostPath` (`src/path_utils.zig:402`) is the
single translation point. `C:` is anchored inside `drive_c/` so `..` cannot
escape it (`src/path_utils.zig:442`); `Z:` is anchored at `/`
(`src/path_utils.zig:433`), which confines it to the host root and no further.
An absolute POSIX path skips normalization entirely
(`src/path_utils.zig:447`).

**Guest to host network.** `src/win32/ws2_32/winsock.zig:136` issues the host
syscall with the guest's arguments. No translation, no policy.

**Build to runtime.** `build.zig:394` hashes the vendored `src/gui/van.min.js`
and refuses to build on drift against `sbom_vanjs_sha256` (`build.zig:357`).
The zig-toml pin is checked the same way (`build.zig:381`). The web assets are
compiled into the binary with their content hashes
(`src/gui/web_ui.zig:1161`), so a client fetches what the build embedded.

**Secrets.** The process reads no credential and stores none. The host
environment is inherited by a spawned child
(`src/win32/kernel32/process.zig:1035` passes argv only, so the child
inherits the host environment). The log
redacts the operator's home directory (`src/log.zig:149`) and the values of
`USER`, `USERNAME`, `LOGNAME`, and `EMAIL` (`src/log.zig:212`). A response file
is logged by name and size only (`src/trace.zig:30`).

There is no database boundary, no service-to-service boundary, and no tenant
boundary.

## 3. Assets and impact

- **The host filesystem and the host user's credentials.** Reachable through
  `Z:\`, absolute POSIX paths, and the response-file read. Impact is reading or
  modifying anything the host user can, not a contained "data breach".
- **The host network position.** A guest socket connects, listens, and accepts
  as the host user (`src/win32/ws2_32/winsock.zig:10`).
- **Host compute and file descriptors.** One PE is mapped whole
  (`src/loader/module.zig:177`), one web client sends frames up to
  `max_ws_message_len` (`src/gui/web_ui.zig:350`), and the guest can spawn 16
  children (`src/win32/kernel32/process.zig:763`). Exhausting these stalls the
  host process, not a quota bucket.
- **The operator's clipboard and terminal.** `clipboard_sync` writes the shared
  clipboard (`src/gui/web_ui.zig:962`). Guest text in a log record is
  neutralized before it reaches the terminal (`src/log.zig:185`); trace output
  is not, see below.
- **The emulator's own integrity.** Guest code and host stubs share one address
  space. A memory-safety fault in a stub is host code execution.

## 4. Threats per boundary

**Guest to host filesystem**

- Tampering and information disclosure: `Z:\...` and an absolute POSIX path
  reach the host root (`src/path_utils.zig:425`, `src/path_utils.zig:447`).
  `SearchPathA` probes a guest path with `access` and no translation beyond
  separator rewriting (`src/win32/kernel32/file.zig:755`).
- Denial of service: `Module.load` allocates and reads the whole file
  (`src/loader/module.zig:177`) and maps `SizeOfImage`
  (`src/loader/module.zig:222`) with no upper bound.
- Elevation: a DLL the guest names is loaded and its `DllMain` runs in the host
  (`src/win32/kernel32/process.zig:179`).

**Guest to host process**

- Tampering: `CreateProcessA` re-executes the emulator with a guest-chosen path
  and a guest-chosen argument tail (`src/win32/kernel32/process.zig:969`,
  `src/win32/kernel32/process.zig:991`). The path is translated; the arguments
  are not.
- Information disclosure: an argument beginning with `@` makes the spawner open
  that path and read 4096 bytes (`src/win32/msvcrt/process.zig:582`). The bytes
  are discarded; the fact of the read and its size are traced.
- Denial of service: the child table is 16 (`src/win32/kernel32/process.zig:763`)
  and the argv array is 16 (`src/win32/kernel32/process.zig:969`). Both fail
  closed once full.

**Guest to host network**

- Information disclosure and spoofing: raw sockets, no egress policy, so a
  guest reaches anything the host can (`src/win32/ws2_32/winsock.zig:136`).
- Denial of service: no cap on sockets or connection rate.

**Browser to web UI**

- Spoofing: no credential. Anyone who can open a TCP connection to the bind
  address and speak HTTP is a client (`src/gui/web_ui.zig:223`).
- Elevation: `launch` runs a PE the client names, confined to `drive_c/`
  (`src/gui/web_ui.zig:854`).
- Tampering: `clipboard_sync` and `text_sync` overwrite shared state the guest
  reads (`src/gui/web_ui.zig:951`, `src/gui/web_ui.zig:962`).
- Denial of service: one frame is capped at `max_ws_message_len`
  (`src/gui/web_ui.zig:350`), one text payload at 64 KiB
  (`src/gui/web_ui.zig:334`), and `accept` gives up after repeated failures
  (`src/gui/web_ui.zig:183`). Nothing caps the number of concurrent clients or
  the rate of messages.

**Guest to logs**

- Tampering: `log.emit` strips control characters and redacts the home
  directory (`src/log.zig:255`). `trace.print` does neither
  (`src/trace.zig:14`); with `ZINE_TRACE` a guest string reaches the terminal
  raw, which is the log-injection class `neutralizeControlChars` exists to
  stop.

**Build to runtime**

- Tampering: a changed `van.min.js` or zig-toml pin fails the build
  (`build.zig:394`, `build.zig:381`). A stub DLL dropped beside an
  `-Dexternal-stubs` binary is loaded with no hash check (`src/runner.zig:79`).

## 5. Mitigations mapping

| Control | Where | Covers | Does not cover |
|---|---|---|---|
| Loopback bind by default | `src/config.zig:19`; `isLoopback` at `src/config.zig:53` | remote attackers under the default configuration | a non-loopback `ZINE_WEB_HOST`; the bind is not authentication |
| Startup validation | `src/config.zig:184`, `src/config.zig:260` | a malformed host, port, clock, or unknown `ZINE_*` name | anything after startup; shape only |
| `Origin` allowlist | `src/gui/web_ui.zig:544`, `src/config.zig:92` | a browser page on another origin opening `/ws` | a client that sends no `Origin`; a non-loopback bind narrows it to nothing (`src/config.zig:99`) |
| `virtualPathToDriveC` | `src/gui/web_ui.zig:832`, `src/gui/renderer.zig:988` | `open_file`, `browse_directory`, `launch` | every other message type; the static-file branch |
| Declared-asset allowlist | `src/gui/web_ui.zig:701`, `src/gui/web_ui.zig:1161` | a request for a file under `src/gui/` that the build did not list | the disk path is still derived from the request (`src/gui/web_ui.zig:706`); safety is the lookup, not the prefix |
| Content hashing of web assets | `build.zig:310`, `src/gui/web_ui.zig:1161` | a stale or swapped embedded asset | assets served from disk in a dev tree |
| `toHostPath` anchoring | `src/path_utils.zig:433`, `src/path_utils.zig:442` | `..` escaping `drive_c/` or `/` | `Z:` and absolute POSIX paths, which are anchored at the host root |
| Child-process cap | `src/win32/kernel32/process.zig:763` | unbounded `CreateProcessA` | the 16 children that do run |
| WebSocket frame cap | `src/gui/web_ui.zig:350`, `src/gui/web_ui.zig:334` | an oversized `text_sync` | many clients, many frames |
| PE name bounds | `src/loader/module.zig:386`, `src/loader/loader.zig:519` | an import name walking off the mapped image | the allocation of the image itself |
| Resource string bounds | `src/win32/user32/resource.zig:186` | `LoadStringA` reading past a mapped image | other resource walks |
| Log redaction | `src/log.zig:149`, `src/log.zig:185`, `src/log.zig:220`, applied in `src/log.zig:255` | home paths, identity env values, and control characters in log records | `trace.print` (`src/trace.zig:14`) |
| Response-file trace hygiene | `src/trace.zig:30` | the contents of a response file reaching the log | the read itself (`src/win32/msvcrt/process.zig:582`) |
| Vendored-digest gate | `build.zig:357`, `build.zig:394` | a drifted `van.min.js` | stub DLLs under `-Dexternal-stubs` |
| `PR_SET_NO_NEW_PRIVS` | `src/platform/native.zig:1252` | a later privilege gain on x86_64 Linux | the privileges already held |

No control carries the guest-to-host boundary. The loopback bind is the single
control between the web UI and the network, and it is an operator setting.

## 6. Abuse cases

Each is what the code permits. None is demonstrated here.

- **Read the host's files through the guest.** A PE calls `CreateFileA` on
  `Z:\home\user\.ssh\id_rsa`. `toHostPath` maps it to `/home/user/.ssh/id_rsa`
  (`src/path_utils.zig:425`) and `host_io.open` opens it
  (`src/win32/host_io.zig:30`).
- **Read a host file through a response argument.** A guest calls the spawner
  with `@/etc/passwd`. `src/win32/msvcrt/process.zig:582` opens it, reads 4096
  bytes, and traces the name and size.
- **Drive the web UI from another local user.** With the default loopback bind,
  any local process can connect, send `launch`, and run a PE under `drive_c/`
  (`src/gui/web_ui.zig:854`). No `Origin` is required.
- **Expose the web UI.** `ZINE_WEB_HOST=0.0.0.0` binds every interface
  (`src/config.zig:41`). `originAllowed` then rejects every browser origin
  (`src/config.zig:99`), but a client that sends no `Origin` is still accepted
  (`src/gui/web_ui.zig:551`).
- **Overwrite the clipboard.** A client sends `clipboard_sync`
  (`src/gui/web_ui.zig:962`) and the guest reads the result back.
- **Exhaust the host.** A guest maps a PE whose `SizeOfImage` is large
  (`src/loader/module.zig:222`) or opens sockets without limit
  (`src/win32/ws2_32/winsock.zig:293`). Both stop at host resource limits only.
- **Plant a stub DLL.** An `-Dexternal-stubs` build loads whatever is in
  `<exe>/dll` (`src/runner.zig:79`) and runs its entry point in-process.

## 7. Document quality

- `SECURITY.md`: absent from the root, `.github/`, and `docs/`. No disclosure
  contact and no supported-version list exist in the repository. README
  "Security fixes and migration" (README.md:732) records past fixes and states
  the two limits that are real: path normalization is not a sandbox, and the
  `Origin` check is not authentication.
- This file is the only threat model. Every `file:line` above was re-derived
  against `97150cd`. The prior revision cited a static-file denylist and a
  `src/gui` prefix check; the code now serves only declared assets
  (`src/gui/web_ui.zig:701`). It also cited a module-registry mutex; the
  registry holds its tables unlocked (`src/loader/registry.zig:223`).
- Claims to re-check next time: every `file:line` above, the `toHostPath`
  cases, the web UI message list, `originAllowed` on a non-loopback bind, and
  the response-file read.

## 8. Response readiness

Note only. No infrastructure is proposed here.

- Diagnostics for an investigation: `log.warn` and `log.err` on stderr
  (`src/log.zig:282`), API and instruction tracing through `ZINE_TRACE` and
  `ZINE_TRACE_INSN` (`src/main.zig:107`), and profiling through `ZINE_PROFILE`
  and `--profile` (`src/main.zig:112`, `src/main.zig:153`). A web client is not
  logged: peer address, connection count, and duration are absent, and the
  `403` from a rejected `Origin` is silent (`src/gui/web_ui.zig:586`). A
  WebSocket command has no per-command record. A spawned child logs one line
  with a pid and a handle and no path
  (`src/win32/kernel32/process.zig:1053`); the launch path is traced only when
  `ZINE_TRACE` is on.
- Path from a reported vulnerability to a shipped fix: none documented. No
  file describes reporting, triage, or disclosure. `CONTRIBUTING.md` covers the
  release procedure. README "Security fixes and migration" (README.md:732) is a
  record of past fixes, not a process.
