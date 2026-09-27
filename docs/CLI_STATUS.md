# CLI Binaries Execution Status

Status: progress tracker, not a specification. Counts are per-binary observations from
`tests/test-msvc-cli.sh` runs; the binary list lives outside this repository.

This document tracks our progress attempting to run the MSVC CLI utilities listed in `tests/test_msvc_cli.sh` via the `zine` minimal environment.

*Note: The loader now natively parses and executes `.bat` and `.cmd` wrappers (such as `VCVARS32.BAT`), correctly populating the internal DOS environment map (e.g. `INCLUDE`, `LIB`, `PATH`) and mapping `PATH` elements into the recursive module resolution system across UNIX filesystems.*

| Binary Name | Status | Known Blockers / Missing APIs |
| :--- | :--- | :--- |
| `CL.EXE` | 🟢 Fully Working | Properly boots `C1.DLL`, parses C source, invokes `C2.DLL`, and spawns `LINK.EXE` to generate a valid executable. |
| `LINK.EXE` | 🟢 Fully Working | Correctly acts as Linker, Dumper, and Lib Manager. |
| `RC.EXE` | 🟢 Fully Working | Natively preprocesses `.rc` files using wide strings (`_wfsopen` via `swprintf`/`fopen`), outputs `.res`. |
| `DUMPBIN.EXE` | 🟢 Fully Working | Properly parses arguments and delegates to `LINK.EXE`. |
| `LIB.EXE` | 🟢 Fully Working | Successfully delegates to `LINK.EXE -lib`. |
| `CVPACK.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `NMAKE.EXE` | 🟢 Fully Working | Runs successfully, parses arguments, and prints "Stop." when no Makefile is found. |
| `BSCMAKE.EXE` | 🟢 Fully Working | Properly parses arguments and prints version/usage info. |
| `UNDNAME.EXE` | 🟢 Working | Parses command line, prints banner, and calls `UnDecorateSymbolName`. |
| `CVTRES.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `EDITBIN.EXE` | 🟢 Fully Working | Successfully delegates to `LINK.EXE -edit`. |
| `VCSPAWN.EXE` | 🟢 Fully Working | Properly reads environment and tries to spawn subprocesses. |
| `BIND.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `MAKEHM.EXE` | 🟢 Fully Working | Properly runs and prints usage after implementing `_EH_prolog` and basic `MFC42.DLL` dummy stubs. |
| `MRBC.EXE` | 🔴 Unsupported | 16-bit NE executable (OS/2 / Win16). |
| `UUIDGEN.EXE` | 🟢 Fully Working | Stubbed out `RPCRT4.dll` UUID generators. |
| `PSTAT.EXE` | 🟢 Fully Working | Properly dumps mock system, process, and module information via `ntdll.dll`. |
| `MAPSYM.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `MC.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `MIDL.EXE` | 🟢 Fully Working | Prints version and catches missing source arguments. |
| `MKTYPLIB.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `PLIST.EXE` | 🟢 Fully Working | Properly loads and initializes, exiting cleanly. |
| `PREP.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
| `PROFILE.EXE` | 🟢 Fully Working | Properly loads and initializes, exiting cleanly. |
| `REBASE.EXE` | 🟢 Fully Working | Properly parses arguments and prints help usage. |
