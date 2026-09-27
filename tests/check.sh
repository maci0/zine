#!/usr/bin/env bash
# Full pre-pull-request gate: the checks CI runs on .github/workflows/ci.yml
# (static-analysis job), in the same order, stopping at the first failure.
# Keep both in step; a command added to one belongs in the other.
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
# same to keep peak memory at one wasm compile.
steps=(
    'zig fmt --check src build.zig build.zig.zon'
    'check_shell'
    'check_c'
    'zig build --summary all'
    'zig build -Darch=x86_64 --summary all'
    'zig build -Darch=wasm32 --summary all'
    'zig build -Darch=wasm64 --summary all'
    # The external-stub DLLs are a shipped target with their own root sources
    # (src/dll/, src/win32_dll_api.zig); without this they are never compiled
    # and a break in them merges unnoticed.
    'zig build -Ddll=all --summary all'
    # Embedding stubs is the default; -Dexternal-stubs is the other half of
    # that switch and compiles src/dll/ through a different path.
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
check_shell() {
    git ls-files '*.sh' | xargs -r shellcheck -x
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

for step in "${steps[@]}"; do
    printf '\n== %s\n' "$step"
    # Word splitting is what runs each step; the list is a literal, not input.
    # shellcheck disable=SC2086
    if ! $step; then
        printf 'FAILED: %s\n' "$step" >&2
        exit 1
    fi
done

printf '\nall checks passed\n'
