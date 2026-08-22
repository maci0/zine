# Zine — Implementation Status

Current implementation + verification status for the Zine Win32 PE interpreter
(x86 software CPU + PE loader + Win32 API compatibility layer, native FLTK and
web-based GUI backends). Companion docs: [`ARCHITECTURE.md`](ARCHITECTURE.md),
[`TODO.md`](TODO.md) (remaining work), [`CLI_STATUS.md`](CLI_STATUS.md) (MSVC
CLI toolchain), and `handover.md` at the repo root (per-slice implementation
notes and lessons).

*Last verified: 2026-08-08 (native 158/0, native64 158/0, wasmtime 128/0, FLTK smoke 20/0)*

## Verification state

| Suite | Result | Command |
|---|---|---|
| Native x86 (interpreter, web backend) | **158 PASS / 0 FAIL** | `SKIP_BUILD=1 ./tests/test_msvc_cli.sh --native` |
| Native x86_64 (compat mode) | **158 PASS / 0 FAIL** | `SKIP_BUILD=1 ./tests/test_msvc_cli.sh --native64` |
| WASM32 (wasmtime) | **128 PASS / 0 FAIL** | `SKIP_BUILD=1 ./tests/test_msvc_cli.sh --wasmtime` |
| FLTK (x86_64, Xvfb) | **20 PASS / 0 FAIL** | `SKIP_BUILD=1 ./tests/fltk_smoke.sh` |

Builds (Zig 0.16 — do **not** pass `--` between `zig build` and `-D` flags):

```
zig build -Darch=x86        # native 32-bit interpreter, web backend → zine.x86
zig build -Darch=x86_64 -Dfltk   # native 64-bit compat + FLTK backend → zine.x86_64
zig build -Darch=wasm32     # WASM build → zine.wasm32.wasm (no JIT imports; used by wasmtime/wasmer suites)
zig build -Darch=wasm32 -Djit_host=true   # WASM build with JIT host imports → zine.wasm32.wasm (for zine-host --jit)
zig build -Dhost=true       # zine-host: native wasmer wrapper (WASI + JIT imports)
```

⚠ The two wasm32 builds write the same `zig-out/bin/zine.wasm32.wasm` — rebuild
plain (`zig build -Darch=wasm32`) before running the wasmtime/wasmer suites,
and rebuild with `-Djit_host=true` before testing the JIT path via zine-host.

## JIT x86→WASM execution (via zine-host)

The WASM build can JIT-compile x86 basic blocks to WASM and execute them
through a host runtime instead of the interpreter:

- `zine-host zine.wasm32.wasm -- --jit ./app.exe` runs the app with JIT
  execution; the interpreter handles control-flow instructions and any
  untranslated opcodes, so JIT and interpreter interleave per basic block.
- Blocks are compiled on first encounter, cached in a 4096-entry ring, and
  re-executed on subsequent visits (loops become hot blocks).
- Block-entry detection uses the interpreter's linear continuation: a branch
  target that differs from `eip + insn_len` is a block entry.
- State transfers through `JitCpuState` in WASM linear memory (GPRs, EIP,
  EFLAGS, FS base, mem_base).
- Verified: `sehtest` (SEH caught inside JIT'd code), `sehnest` (nested SEH),
  `regapp` (registry read) all green with `--jit`.
- Hot-block detection: per-block execution counters, live-logged at 10/100/
  1000/… milestones and summarized at run end (when the app returns normally).

JIT correctness fixes in this slice (all were silent mis-execution bugs):
- **CF/OF never computed** for ADD/SUB/CMP in `translateAlu`/`translateGroup1`
  — conditional branches on carry/overflow (`jae`/`jb`/`jo`…) took wrong
  paths (e.g. skipped a table-init loop, corrupting pioinfo).
- **FS-relative memory ops** ignored the segment base — `mov fs:[0],esp` (SEH
  frame install) wrote to VA 0. `JitCpuState` now carries `fs_base`.
- **Byte/word register operands** loaded the full 32-bit register — `cmp al,
  [mem]` compared the whole EAX. Register loads/stores now mask to 8/16 bits
  and preserve untouched upper bits (AH/CH/DH/BH via offset 8).

The suite runs the MSVC CLI toolchain end-to-end (CL/LINK/RC/CVTRES/DUMPBIN/
LIB/NMAKE/…) plus the GUI app sections below. GUI apps are driven against the
**web backend**; the **FLTK backend** is verified by `tests/fltk_smoke.sh`
(compiles + runs the 20 self-exiting GUI apps under Xvfb with `zine.x86_64
--fltk`, checking each app's `-check`/`-done` output — 20/0 green). The
interactive dialogs (ChooseColor/ChooseFont/Print/PageSetup/Find) and the
context menu are FLTK-verified manually under Xvfb.

## Implemented Windows GUI surface (web + FLTK backends)

Both backends share one command/replay protocol (`src/gui/renderer.zig` +
`gui/app.js` for web, `gui/fltk_ui.zig` + `gui/fltk_bridge.{h,cpp}` for FLTK);
each Win32 message/control op is implemented once and rendered by both.

- **Window & framebuffer** — CreateWindowExA/SetWindowPos/MoveWindow,
  client-area derivation, title bar (SetWindowTextA), Win2K frame metrics.
- **GetWindowText control-ization** — GetWindowTextA / WM_GETTEXT read back
  control text uniformly: per-hwnd text store (initial CreateWindowEx label +
  SetWindowTextA updates) for Button/Static children, dialog control texts,
  and ListBox/ComboBox selected-item text.
- **Menus** — PE menu resources parsed, Win2K-styled dropdowns, accelerator
  underlines, `TrackPopupMenu` context menus (web popup / `Fl_Menu_Button`).
- **Dialogs** — DialogBoxParamA from PE dialog templates (DLU→pixel scaling),
  modal dialogs on FLTK, `WM_INITDIALOG`, control inventory + item text.
- **Common controls** — Button/Static, status bar (`msctls_statusbar32`),
  progress bar (`msctls_progress32`, min/max/value), edit controls.
- **Clipboard** — OpenClipboard/EmptyClipboard/GlobalAlloc/SetClipboardData
  (`CF_TEXT`) → `renderer.setClipboard` end-to-end (web UI and FLTK
  `Fl::copy` both receive real guest clipboard writes).
- **Window icon** — RT_ICON + RT_GROUP_ICON extraction (`loader/icon_parser.zig`),
  base64-encoded, shown in titlebar/taskbar/favicon.
- **File dialogs** — GetOpenFileNameA (web file upload via WS / FLTK native
  `Fl_Native_File_Chooser`), populates OPENFILENAMEA fields.
- **Keyboard** — TranslateMessage → WM_CHAR (US layout, Shift handled),
  GetKeyboardState/GetKeyState from renderer state.
- **Mouse** — clicks, moves, capture, and `WM_MOUSEWHEEL`.
- **Timers** — SetTimer/KillTimer with a real WM_TIMER dispatch thread
  (WASI builds are single-threaded; timer thread is native-only).
- **Edit controls** — WM_CHAR insertion into the control buffer, WM_GETTEXT /
  GetWindowText read-back (edit + main-window title), EM_SETSEL/EM_GETSEL/
  EM_REPLACESEL/EM_LIMITTEXT/EM_SETREADONLY + WM_COPY.
- **RichEdit** — `RichEdit20A`/`RICHEDIT`/`RichEdit` class detection (shares
  the EDIT text machinery, as real RichEdit is an EDIT superset) plus the
  RichEdit 2.0 EM_* messages: EM_EXGETSEL/EM_EXSETSEL (CHARRANGE),
  EM_GETSELTEXT, EM_GETTEXTRANGE (TEXTRANGE), EM_GETCHARFORMAT (CHARFORMAT),
  EM_SETCHARFORMAT, EM_SETBKGNDCOLOR, EM_SETTEXTMODE/EM_GETTEXTMODE,
  EM_GETTEXTEX (GETTEXTEX), EM_GETTEXTLENGTHEX (GTL_NUMCHARS/NUMBYTES).
  MSVC6 richedit.h message numbers (WM_USER + n) verified against the SDK.
- **Dialog keyboard navigation** — IsDialogMessageA: Tab/Shift+Tab between
  WS_TABSTOP children, Enter → default button (BS_DEFPUSHBUTTON),
  Esc → IDCANCEL, initial focus = first tabstop.
- **Focus routing** — SetFocus/GetFocus track the focused hwnd; keyboard is
  delivered to the focused control.
- **Button activation** — Space/Enter on a focused button → WM_COMMAND
  (BN_CLICKED).
- **Checkboxes / radio buttons** — BM_* get/set-check, auto-toggle on click,
  WS_GROUP radio-group mutual exclusion.
- **ListBox** — LB_* messages (add/count/get text/selection/delete) → shared
  item-list ops; web renders `.win2k-listbox`, FLTK uses `Fl_...` list widget.
- **ComboBox** — CB_* messages; web renders dropdown + list; FLTK `Fl_Choice`.
- **TabControl** — TCM_* messages. ⚠ MSVC6 SDK uses `0x1307`/`0x130C`
  (TCIF_PARAM-era) numbers that differ from newer SDKs — handled explicitly.
- **ListView** — LVM_* messages (columns/items/selection) → web table rows /
  FLTK browser.
- **TreeView** — TVM_* messages (TVM_INSERTITEMA at 0x1100 with
  TVINSERTSTRUCT, TVM_GETITEMA with the TVITEM layout: index in `hItem` +4,
  output buffer `pszText` +16). Web renders `.win2k-treeview`, FLTK uses
  `Fl_Hold_Browser` (items rendered flat).
- **Header control** — HDM_* messages (HDM_INSERTITEMA pszText at +8); web
  `.win2k-header` bar.
- **UpDown / Trackbar / DateTimePicker** — msctls_updown32 (UDM_SETRANGE32/
  GETRANGE32/SETPOS/GETPOS, negative ranges handled), msctls_trackbar32
  (TBM_SETRANGE/GETRANGEMIN/MAX/SETPOS/GETPOS), SysDateTimePick32
  (DTM_SETSYSTEMTIME/GETSYSTEMTIME with a SYSTEMTIME mirror; ⚠ MSVC6
  GDT_VALID = 0, unlike modern SDKs). Web: range input / value box / date
  text; FLTK: Fl_Slider / Fl_Spinner / box.
- **MonthCal / Tooltip / Animation** — SysMonthCal32 (MCM_GETCURSEL/
  SETCURSEL/GETTODAY/SETTODAY with SYSTEMTIME), tooltips_class32
  (TTM_ADDTOOLA captures the tip text; TTM_ACTIVATE/DELTOOL/SETMAXTIPWIDTH),
  SysAnimate32 (ACM_OPEN/PLAY/STOP).
- **WM_CTLCOLOR** — brush color mapping (system colors + CreateSolidBrush) and
  renderer application for both backends.
- **ChooseColor** — ChooseColorA with a host color chooser
  (FLTK `Fl_Color_Chooser` / web color-picker overlay), blocking call + replay
  of the dialog JSON to reconnecting WS clients.
- **ChooseFont** — ChooseFontA/W with a host font chooser (web font picker /
  FLTK modal with font list + size + bold/italic + preview), writing LOGFONT
  (lfFaceName/lfHeight/lfWeight/lfItalic), iPointSize and nFontType back on
  OK, honoring CF_INITTOLOGFONTSTRUCT + CF_LIMITSIZE.
- **PrintDlg** — PrintDlgA/W with a host print dialog (web page-range/copies
  form / FLTK modal), writing back nFromPage/nToPage/nCopies, returning a
  dummy printer DC on PD_RETURNDC, and short-circuiting on
  PD_RETURNDEFAULT (no UI).
- **FindText/ReplaceText** — modeless Find/Replace dialogs (FindTextA/
  ReplaceTextA return a dialog hwnd; the app keeps pumping). Host actions
  (find_next / replace / replace_all / close) fill the caller's FINDREPLACEA
  (lpstrFindWhat/lpstrReplaceWith/Flags incl. FR_FINDNEXT/FR_DOWN/
  FR_MATCHCASE/FR_REPLACE*) and post the registered FINDMSGSTRING
  ("commdlg_FindReplace") to the owner. RegisterWindowMessageA dedups by
  name so the app's and the stub's registrations agree.
- **PageSetupDlg** — PageSetupDlgA/W with a host page-setup dialog (web
  margin/orientation form / FLTK modal), writing back rtMargin + ptPaperSize
  in the caller's units (thousandths of an inch / 1-100 mm per PSD_ units
  flags) and setting PSD_MARGINS; PSD_RETURNDEFAULT short-circuits with no
  UI.

Suite GUI sections (all compile via CL, link, and run cleanly):
`GUI` (smoke), `GDI`, `DLG`, `MENU`, `MBX`, `CCTL`, `DLGT`, `CXT`, `SZ`, `CHAR`,
`TIMER`, `EDIT`, `DLGKB`, `FOCKEY`, `BTNKEY`, `CHK`, `RADGRP`, `LST`, `COMBO`,
`TAB`, `CLR`, `LV`, `TREE`, `HDR`, `CC`, `CF`, `RICH`, `GWT`, `PD`, `FT`,
`PS`, `UDT`, `MTA` (the `CC` color-chooser, `CF` font-chooser, `PD`
print-chooser, `FT` find-dialog and `PS` page-setup checks are driven by
Python WebSocket clients: `ws_cc.py` / `ws_cf.py` / `ws_pd.py` / `ws_ft.py` /
`ws_ps.py`).

## Native x86_64 compat chain (native64 mode)

Full-chain fixes so real x86_64 binaries run with the 32-bit guest ABI:
posix_fs / host_io / loader / msvcrt / kernel32 bare syscalls, spawn
fork/exec, 32-bit `MSG` layout, `pthread_create` FS-base switching
(`saveHostFsBase`/`useHostFs`/`restoreFs`), and the `callWndProcSafe` EAX
preservation fix. **Fully green as of 2026-08-08**: `--native64` passes the
whole CLI suite (158/0), including LINK.EXE (ReadSymbolTable) and LIB.EXE
(spawns link.exe). Two root causes fixed this slice:
- `callComparator` (qsort/bsearch) called 32-bit guest comparators as 64-bit
  function pointers on native64 — misdecoding the 32-bit machine code in
  long mode (LINK "Internal error during ReadSymbolTable"). Now routes via
  `callCompat32_4`. Same latent pattern fixed in EnumSystemLocalesA/W and
  DirectDraw EnumDisplayModes callbacks.
- RCDLL's std.Io openFile/close hit TLS (`%fs:0x308`) inside the compat
  dispatch context; switched to raw `host_io` syscalls (RC.EXE works).

## Other implemented subsystems (summary)

- **Per-app registry overrides** — `app:<MODULE>:<KEY>` sections in
  `registry.toml` are served only when the launched executable (basename)
  queries the key, shadowing the global value (verified: REGAPP.EXE reads its
  override on all three modes).
- **WASM SEH dispatch** — `RaiseException` walks the guest's FS:[0] chain
  (guest memory via the TEB, recorded as `teb.teb_base_addr`), runs guest
  `_except_handler3` handlers/filters through a nested x86-interpreter run on
  the app's own stack, and redirects the suspended interpreter into the
  `__except` block on accept. Verified with `__try/__except` accept + nested
  decline/walk-continuation tests — including under the JIT.
- **MSVCRT stdio** — `fflush`/`_flushall`/`setvbuf`/`_fcloseall`/`freopen`
  implemented with real return codes (writes are unbuffered direct-fd, so
  flush is a success-reporting no-op; `_fcloseall` closes dynamic streams;
  `freopen` closes + reopens).
- **Win32 API layers** — KERNEL32, MSVCRT, USER32, GDI32, NTDLL, COMDLG32,
  ADVAPI32 (registry via `registry.toml`), SHELL32, COMCTL32, SHLWAPI,
  DDRAW/D3D7, D3D8, DSOUND, DINPUT(8), WINMM, WS2_32/WSOCK32, OLEAUT32, MSS32,
  MFC42 (dummy), IMAGEHLP, RPCRT4, and ~40 other DLLs (stub or implemented).
  Detailed per-API table history was folded into `handover.md`; see
  `ARCHITECTURE.md` for the module map.
- **MSVC CLI toolchain** — CL, LINK, RC (incl. `NAME ICON "file.ico"` →
  RT_ICON + RT_GROUP_ICON), CVTRES, DUMPBIN, LIB, NMAKE, UNDNAME, EDITBIN,
  PSTAT, MIDL, MC, and more; `.bat`/`.cmd` wrappers (VCVARS32.BAT) parsed
  natively. See `CLI_STATUS.md`.
- **PE loading** — imports/relocations, resource trees (dialogs, menus, icons,
  string tables, version), delayed loads, DLL mode (35+ stub DLLs as real
  Windows DLLs).
- **x86 core** — interpreter with decode cache, SSE/SSE2, x87 FPU, JIT
  x86→WASM compiler with end-to-end host execution (see the JIT section
  above).

## Known remaining / deferred

These are the open items; see [`TODO.md`](TODO.md) for the prioritized list.

- **WASM JIT coverage** — the JIT executes straight-line blocks end-to-end
  (sehtest SEH, sehnest nested SEH, regapp registry all green under
  `zine-host --jit`), but blocks with instructions the translator doesn't yet
  handle fall back to the interpreter. Expanding instruction coverage and
  hot-block pre-warming are the main remaining JIT slices.
- **WASI single-threaded timers** — WM_TIMER only fires on native builds (the
  timer thread is native-only); WASI builds are single-threaded.
- **wasmtime text-mode stdio** — msvcrt `fopen("r")` + buffered read returns
  empty on wasmtime (the CRT text-mode loop reads past the ReadFile byte
  count); kernel32 file I/O used by the CLI tools works, so the suite is
  unaffected.
- **zine-host CLI toolchain** — CL.EXE reaches the C1.DLL spawn under
  zine-host but the child spawn fails (pre-existing zine-host spawn/file gap,
  unrelated to JIT).
