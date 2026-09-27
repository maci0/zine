#!/usr/bin/env bash
# Full pre-pull-request gate: the checks CI runs on .github/workflows/ci.yml
# (static-analysis job), in the same order, stopping at the first failure.
#
# Usage:
#   bash tests/check.sh                 # the whole gate, in order
#   bash tests/check.sh --list          # the step names
#   bash tests/check.sh <step> [step..] # only the named steps, still in order
#
# The named steps are the ones in the step_names list below; `bash
# tests/check.sh` with no argument runs all of them. CI calls this script for
# the two helper steps (check_shell, check_c) so the commands and the file
# lists live here once. A command added to one belongs in the other.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

required=(zig shellcheck git timeout cmp grep sed)
missing=()
for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if ((${#missing[@]} > 0)); then
    printf 'missing required tool(s): %s\n' "${missing[*]}" >&2
    printf 'install them, then re-run: bash tests/check.sh\n' >&2
    exit 1
fi

# check_shell and check_c enumerate sources with `git ls-files`, which needs a
# work tree. A source archive (GitHub's "Download ZIP") has none, and without
# this the first tracked-file step dies with git's own exit 128 and a name the
# contributor has to decode.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'this directory is not a git work tree; the tracked-file checks need one\n' >&2
    printf 'clone with git (not a source archive), then re-run: bash tests/check.sh\n' >&2
    exit 1
fi

minimum_zig=$(sed -n 's/^ *\.minimum_zig_version = "\(.*\)",*$/\1/p' build.zig.zon)
if [[ -z "$minimum_zig" ]]; then
    printf 'cannot read .minimum_zig_version from build.zig.zon\n' >&2
    exit 1
fi
have_zig=$(zig version)
if [[ "$have_zig" != "$minimum_zig"* ]]; then
    printf 'zig %s is installed, this project requires %s (see build.zig.zon)\n' "$have_zig" "$minimum_zig" >&2
    printf 'install it from https://ziglang.org/download/\n' >&2
    exit 1
fi

# Build targets run sequentially rather than via -Dall: the CI gate does the
# same to keep peak memory at one wasm compile. Each name is the handle a
# caller passes to run that step alone; the order below is the gate's order.
step_names=(
    fmt
    check_shell
    check_c
    build
    build-x86_64
    build-wasm32
    build-wasm64
    # The external-stub DLLs are a shipped target with its own root sources
    # (src/dll/, src/win32_dll_api.zig); without this they are never compiled
    # and a break in them merges unnoticed.
    dll
    # Embedding stubs is the default; external-stubs is the other half of
    # that switch and compiles src/dll/ through a different path.
    external-stubs
    test
    test-cli
    test-cli-x86_64
    fuzz
)
step_commands=(
    'zig fmt --check src build.zig build.zig.zon'
    'check_shell'
    'check_c'
    'zig build --summary all'
    'zig build -Darch=x86_64 --summary all'
    'zig build -Darch=wasm32 --summary all'
    'zig build -Darch=wasm64 --summary all'
    'zig build -Ddll=all --summary all'
    'zig build -Dexternal-stubs --summary all'
    'zig build test --summary all'
    'zig build test-cli --summary all'
    'zig build test-cli -Darch=x86_64 --summary all'
    # Short budget locally; the untrusted-input parsers otherwise never run
    # outside a hand-run `zig build fuzz`.
    'zig build fuzz -Dfuzz-seconds=10 --summary all'
)

# Every tracked script, wherever it lives, must stay shellcheck-clean. This
# matches the CI command so a script outside tests/ cannot slip through locally.
# The NUL-delimited read keeps paths with spaces intact, and the array keeps
# the argument list off xargs, whose -r is a GNU extension BSD xargs rejects.
check_shell() {
    local scripts=() script
    while IFS= read -r -d '' script; do
        scripts+=("$script")
    done < <(git ls-files -z '*.sh')
    ((${#scripts[@]} == 0)) || shellcheck -x "${scripts[@]}"
}

# Nothing else in the gate analyzes the tracked C sources: the Zig build never
# sees them. `zig cc` is already a required tool and is pinned to the same
# version CI installs, so it is the analyzer, and the warnings it would print
# are errors here. Only compilation runs, so the objects land in the gitignored
# .scratch/ instead of the repo root.
#
# src/gui/fltk_bridge.cpp is deliberately absent: it needs the FLTK headers
# from libfltk1.3-dev, which the gate does not install. It is built by
# `zig build -Darch=x86_64 -Dfltk` (see README.md).
check_c() {
    local objdir=".scratch/c-check"
    mkdir -p "$objdir"
    local src
    while IFS= read -r src; do
        zig cc -c -o "$objdir/$(basename "$src").o" -std=c99 -Wall -Wextra -Wpedantic -Werror "$src"
    done < <(git ls-files 'tests/*.c' ':!tests/cpubench_win32.c')
    zig cc -c -o "$objdir/cpubench_win32.o" -target x86-windows-gnu -std=c99 \
        -Wall -Wextra -Wpedantic -Werror tests/cpubench_win32.c
}

# No argument means the whole gate. Named steps always run in gate order, so
# `check.sh test build` runs the same two steps as `check.sh build test`.
# `--list` prints the step names and runs nothing.
if (($# == 1)) && [[ "$1" == --list ]]; then
    printf '%s\n' "${step_names[@]}"
    exit 0
fi

selected=("$@")
if (($# == 0)); then
    selected=("${step_names[@]}")
fi

run_indices=()
for i in "${!step_names[@]}"; do
    for name in "${selected[@]}"; do
        if [[ "${step_names[$i]}" == "$name" ]]; then
            run_indices+=("$i")
            break
        fi
    done
done
if ((${#run_indices[@]} != ${#selected[@]})); then
    printf 'unknown step; known steps: %s\n' "${step_names[*]}" >&2
    exit 2
fi

for i in "${run_indices[@]}"; do
    printf '\n== %s: %s\n' "${step_names[$i]}" "${step_commands[$i]}"
    # Word splitting is what runs each step; the list is a literal, not input.
    # shellcheck disable=SC2086
    if ! ${step_commands[$i]}; then
        printf 'FAILED: %s: %s\n' "${step_names[$i]}" "${step_commands[$i]}" >&2
        exit 1
    fi
done

if (($# == 0)); then
    printf '\nall checks passed\n'
else
    printf '\nall selected steps passed: %s\n' "${selected[*]}"
fi
