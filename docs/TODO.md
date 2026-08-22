# Zine — TODO / Remaining Work

Open items, prioritized. Current state and what is already implemented:
see [`STATUS.md`](STATUS.md). Detailed per-slice notes: `handover.md` (repo root).

Verified baseline (2026-08-08): native **158/0**, native64 **158/0**,
wasmtime **128/0**, FLTK smoke **20/0** — all suites green.

## GUI (web + FLTK backends)

No remaining items — the common-dialog set (Open/Save, Color, Font, Print,
Page Setup, Find/Replace), the standard + common controls (Button, Static,
Edit, RichEdit, ListBox, ComboBox, Tab, ListView, TreeView, Header, StatusBar,
Progress, UpDown, Trackbar, DateTimePicker), menus, dialogs, clipboard,
icons, timers, input, focus and window-text APIs are all implemented in both
backends and covered by the suite (`--native` 158/0, `--wasmtime` 128/0) plus
`tests/fltk_smoke.sh` (FLTK 20/0 under Xvfb).

## native64 (x86_64 compat)

Fully green (158/0) — LINK.EXE ReadSymbolTable and the LIB spawn-path TLS
crash were fixed in the 2026-08-08 slice (callComparator compat routing +
RCDLL raw-syscall file IO).

## WASM

- [ ] **WASI single-threaded timers** — the timer thread is native-only; WASI
      builds (wasmtime/wasmer/zine-host) don't fire WM_TIMER (single-threaded
      runtime). The timer suite section is skipped on WASM for this reason.
- [ ] **JIT instruction coverage** — the JIT executes straight-line blocks
      end-to-end via zine-host, but blocks containing untranslated opcodes
      fall back to the interpreter. Broaden the translator (SSE, x87, string
      ops, etc.) so fewer blocks degrade; plus hot-block pre-warming (compile
      the hottest blocks on startup instead of on first encounter).
- [ ] **zine-host CLI toolchain** — CL.EXE gets to the C1.DLL spawn under
      zine-host but the child spawn (C1.EXE) fails — a pre-existing
      spawn/file gap in zine-host, unrelated to JIT (the wasmtime suite is
      unaffected). Would let the full MSVC toolchain run under
      `zine-host --jit`.

## MSVCRT / stdio

`fflush`/`_flushall`/`setvbuf`/`_fcloseall`/`freopen` are implemented
(2026-08-08 slice). The remaining stdio gap is the pre-existing wasmtime
text-mode `fgets`/`fread` read-back issue: kernel32 file I/O (used by the CLI
tools) works, but msvcrt `fopen("r")` + buffered read returns empty on
wasmtime (the CRT's text-mode loop reads past the ReadFile byte count into
garbage/zeros). Not covered by the suite (tests use append-write).

## Long-term / infra (not GUI-blocking)

- [x] JIT x86→WASM block execution end-to-end (2026-08-08 slice) — blocks
      compile, execute via zine-host/wasmer, and re-run as hot blocks
      (sehtest/sehnest/regapp green under `--jit`). See WASM section above
      for the remaining coverage/pre-warming items.
- [ ] Browser JS JIT glue (`WebAssembly.instantiate` for compiled blocks) —
      the JIT host imports (`jit.jit_compile`/`jit.jit_call`) are ready; a
      browser runtime would provide them instead of zine-host.
- [ ] Threaded dispatch optimization for the interpreter.
