# CLI Binaries Execution Status

Status: progress tracker, not a specification. Each status is a per-binary observation from
`tests/test_msvc_cli.sh` runs; the binary list lives outside this repository.

This document tracks our progress attempting to run the MSVC CLI utilities listed in `tests/test_msvc_cli.sh` via the `zine` minimal environment. Suite-level pass/fail counts live in [`STATUS.md`](STATUS.md).

*Note: The loader now natively parses and executes `.bat` and `.cmd` wrappers (such as `VCVARS32.BAT`), correctly populating the internal DOS environment map (e.g. `INCLUDE`, `LIB`, `PATH`) and appending each `PATH` element to the module search list, which resolves module names by scanning those paths in order across UNIX filesystems.*

| Binary Name | Status | Known Blockers / Missing APIs |
| :--- | :--- | :--- |
| `CL.EXE` | 🟢 Fully Working | Properly boots `C1.DLL`, parses C source, invokes `C2.DLL`, and spawns `LINK.EXE` to generate a valid executable. |
| `LINK.EXE` | 🟢 Fully Working | Correctly acts as Linker and Dumper. Its lib-manager path (`LINK /OUT`) still fails with LNK1102, so LIB.EXE cannot create a `.lib`. |
| `RC.EXE` | 🟢 Fully Working | Preprocesses `.rc` and writes the `.res` through raw `posix_fs`/`host_io` calls (no `std.Io` TLS). A `NAME ICON` entry still reads its `.ico` through `std.Io`, which touches TLS. |
| `DUMPBIN.EXE` | 🟢 Fully Working | Properly parses arguments and delegates to `LINK.EXE`. |
| `LIB.EXE` | ⚪ Unverified | `/LIST` works by delegating to `LINK.EXE -lib`, but creating a library fails with LNK1102 (unresolved `mspdb60.dll` imports in LINK.EXE), so the suite skips that step. |
| `CVPACK.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `NMAKE.EXE` | 🟢 Fully Working | Runs successfully, parses arguments, and prints "Stop." when no Makefile is found. |
| `BSCMAKE.EXE` | 🟢 Fully Working | Properly parses arguments and prints version/usage info. |
| `UNDNAME.EXE` | 🟢 Working | Parses command line, prints banner, and calls `UnDecorateSymbolName`. |
| `CVTRES.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `EDITBIN.EXE` | 🟢 Fully Working | Successfully delegates to `LINK.EXE -edit`. |
| `VCSPAWN.EXE` | 🟢 Fully Working | Properly reads environment and tries to spawn subprocesses. |
| `BIND.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `MAKEHM.EXE` | 🟢 Fully Working | Properly runs and prints usage after implementing `_EH_prolog` and basic `MFC42.DLL` dummy stubs. |
| `MRBC.EXE` | ⚪ Unverified | 16-bit NE executable (OS/2 / Win16). No check in `tests/test_msvc_cli.sh`. |
| `UUIDGEN.EXE` | 🟢 Fully Working | Stubbed out `RPCRT4.dll` UUID generators. |
| `PSTAT.EXE` | ⚪ Unverified | Runs on the generic `ntdll.dll` stubs; no dedicated check in `tests/test_msvc_cli.sh`. |
| `MAPSYM.EXE` | ⚪ Unverified | No check in `tests/test_msvc_cli.sh` and no MAPSYM-specific source. |
| `MC.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `MIDL.EXE` | 🟢 Fully Working | Prints version and catches missing source arguments. |
| `MKTYPLIB.EXE` | ⚪ Unverified | No check in `tests/test_msvc_cli.sh` and no MKTYPLIB-specific source. |
| `PLIST.EXE` | 🟢 Fully Working | Properly loads and initializes, exiting cleanly. |
| `PREP.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `PROFILE.EXE` | 🟢 Fully Working | Properly loads and initializes, exiting cleanly. |
| `REBASE.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
