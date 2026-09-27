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
| Debug build | `zig build -Doptimize=Debug` |
| Unit tests | `zig build test` |
| One test or module | `zig build test -Dtest-filter=<substring> --summary all` |
| CLI output and exit status | `zig build test-cli` (add `-Darch=x86_64` or `-Darch=wasm32`) |
| Fix formatting | `zig fmt src build.zig build.zig.zon` |
| Lint shell scripts | `bash tests/check.sh check_shell` |
| Check C sources | `bash tests/check.sh check_c` |
| One gate step by name | `bash tests/check.sh <step>` (see below) |
| Full gate, same as CI | `bash tests/check.sh` |
| List build steps and options | `zig build --help` |

The filter is a substring of the test name, and it applies to the whole
suite, so `zig build test -Dtest-filter=x86.decoder` runs the decoder tests
across files. `-Darch` does not change the target of the unit tests: they
always run on the host. Only `test-cli` varies by architecture.

`-Doptimize` defaults to ReleaseSafe so the installed artifacts are the
optimized ones and stay free of the absolute build path that a Debug binary
embeds. Pass `-Doptimize=Debug` when stepping through code.

`tests/check.sh` is the single pre-pull-request gate. It runs the same checks,
in the same order, as the `static-analysis` job in `.github/workflows/ci.yml`:
`zig fmt --check`, shellcheck over every tracked script, a warning-free
`zig cc` compile of every tracked C source, all four architecture builds, the
unit tests, and both native `test-cli` runs. If you add a check,
add it in both places or local runs stop predicting CI.

Each check is a named step, and `bash tests/check.sh <step> [step...]` runs
just those, still in gate order: `fmt`, `check_shell`, `check_c`, `build`,
`build-x86_64`, `build-wasm32`, `build-wasm64`, `dll`, `external-stubs`,
`test`, `test-cli`, `test-cli-x86_64`. The two helper steps (shellcheck and
the C compile) are the ones CI calls this script for, so the commands and the
`git ls-files` lists live in one place. An unknown name fails with the list of
known steps.

The job takes its Zig version from `build.zig.zon` and restores `.zig-cache/`
and `zig-pkg/` from a cache keyed on `build.zig.zon`, which pins the toolchain
and the dependency set. Both paths are content addressed, so a restored entry
that no longer matches is recompiled rather than reused; a run that misses the
cache pays the full build.

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

## Releases

A release is three things changed together: `.version` in `build.zig.zon`,
`pub const string` in `src/version.zig` (which `--version` prints on native,
WASI, and `zine-host`), and the release notes in the README's "Releases and
upgrades" section. The `comptime` check in `build.zig` fails the build when the
first two disagree, so a half-applied bump cannot ship.

Until then, user-facing changes accumulate under the README's `### Unreleased`
heading, grouped by impact: breaking changes with the migration step first,
then security fixes, added, and fixed. A commit that changes behavior a guest or
a host operator can observe belongs in one of those groups, however small.
When the version is cut, rename that heading to `### <version> (<date>)` and
start a fresh empty `### Unreleased` above it. Never edit the notes of a version
that has already been published.

`0.x` means no compatibility promise between versions: the guest ABI, the CLI
flags, the environment variables, and the virtual filesystem behavior can all
change in any release. A change that would break a consumer gets a minor bump
and a migration line, not a patch.

`AGENTS.md` holds the project rules that apply to any change: the 0.16.0
toolchain, image base `0x70000000` for native executables, `w32cc.WINAPI` for
Win32 stubs, guest pointers translated in the thunk layer rather than in stubs,
and the rule that stubs return the documented failure value and set last error
instead of propagating Zig errors. Read it before editing `src/win32/`,
`src/x86/`, or `src/loader/`.
