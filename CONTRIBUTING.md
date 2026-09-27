# Contributing

## Setup

Zig 0.16.0 and a POSIX shell environment. The pinned minimum lives in
`build.zig.zon` (`.minimum_zig_version`); `tests/check.sh` compares it against
the installed `zig version` and tells you what to install when they differ.
Zig fetches the one TOML dependency on the first build, so that first build
needs network access and later ones do not.

No global installs, no services, no Windows fixtures are needed for the unit
suite or the pre-pull-request gate. Everything below runs from the repository
root.

| Task | Command |
|---|---|
| Build (default 32-bit x86) | `zig build` |
| Unit tests | `zig build test` |
| One test or module | `zig build test -Dtest-filter=<substring> --summary all` |
| CLI output and exit status | `zig build test-cli` (add `-Darch=x86_64` or `-Darch=wasm32`) |
| Fix formatting | `zig fmt src build.zig build.zig.zon` |
| Lint shell scripts | `git ls-files '*.sh' \| xargs -r shellcheck -x` |
| Full gate, same as CI | `bash tests/check.sh` |
| List build steps and options | `zig build --help` |

The filter is a substring of the test name, and it applies to the whole
suite, so `zig build test -Dtest-filter=x86.decoder` runs the decoder tests
across files. `-Darch` does not change the target of the unit tests: they
always run on the host. Only `test-cli` varies by architecture.

`tests/check.sh` is the single pre-pull-request gate. It runs the same checks,
in the same order, as the `static-analysis` job in `.github/workflows/ci.yml`:
`zig fmt --check`, shellcheck over every tracked script, all four architecture
builds, the unit tests, and both native `test-cli` runs. If you add a check,
add it in both places or local runs stop predicting CI.

The job takes its Zig version from `build.zig.zon` and restores `.zig-cache/`
and `zig-pkg/` from a cache keyed on `build.zig`, `build.zig.zon`, and `src/`.
Both paths are content addressed, so a restored entry that no longer matches is
recompiled rather than reused; a run that misses the cache pays the full build.

Tests that need more than Zig are opt-in and say so in the README: the MSVC
integration suite (`tests/test_msvc_cli.sh`, needs MSVC 6.0 fixtures under
`tools/MSVC600/` and a runtime on `PATH` for WASM), the FLTK smoke tests
(`tests/fltk_smoke.sh`, needs Xvfb), and the WebSocket tests (need Python 3 and
`tests/requirements.txt`).

## Adding a test

Unit tests are Zig `test` blocks in the same file as the code they cover.
`src/test_root.zig` imports every file that holds tests, so a new file with
tests needs a `_ = @import("...")` line there, or its tests are silently not
run. Write the failing test first and watch it fail for the reason you expect.

## Pull requests

Run `bash tests/check.sh` and let it pass before pushing. A pull request
describes what changed and how it was tested, in a few lines.

Commit subjects are lowercase `type: subject`, with the type from `fix`,
`feat`, `docs`, `test`, `refactor`, `perf`, `build`, `ci`, or `chore`. A scope
is optional and names the subsystem, as in `fix(wasm)` or `feat(gdi)`. The
subject states the change; a body explains why, when the reason is not obvious
from the diff.

Do not bump the version in `build.zig.zon` or `src/version.zig`. The build fails
if those two disagree, and releases cut both together.

`AGENTS.md` holds the project rules that apply to any change: the 0.16.0
toolchain, image base `0x70000000` for native executables, `w32cc.WINAPI` for
Win32 stubs, guest pointers translated in the thunk layer rather than in stubs,
and the rule that stubs return the documented failure value and set last error
instead of propagating Zig errors. Read it before editing `src/win32/`,
`src/x86/`, or `src/loader/`.
