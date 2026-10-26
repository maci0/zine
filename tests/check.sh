#!/usr/bin/env bash
# Full pre-pull-request gate: the checks CI runs on .github/workflows/ci.yml
# (static-analysis job), in the same order, stopping at the first failure.
#
# Usage:
#   bash tests/check.sh                 # the whole gate, in order
#   bash tests/check.sh --list          # the step names
#   bash tests/check.sh <step> [step..] # only the named steps, still in order
#
# Environment:
#   ZINE_FUZZ_SECONDS  seconds each fuzz target runs (default 10; CI raises it)
#
# The named steps are the ones in the step_names list below; `bash
# tests/check.sh` with no argument runs all of them. Every CI step calls this
# script by name, so the commands and the file lists live here once: a step
# added to the lists below reaches CI without a second copy.
set -euo pipefail

# Sort order, formatted numbers and the tool's own diagnostics follow the
# ambient locale, and dates follow the ambient timezone, so a gate that runs
# under a developer's locale can disagree with CI about which step failed.
export LC_ALL=C TZ=UTC

cd "$(dirname "${BASH_SOURCE[0]}")/.."

required=(zig shellcheck node git timeout cmp diff grep sed awk readelf mktemp find sort cp basename)
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
# An exact match, not a prefix: the shipped artifacts are compiled by the
# exact toolchain CI installs, and a patch release is free to change codegen,
# so a newer zig that passes a `0.17.0*` test can produce bytes and diagnostics
# the maintainers never see. Bumping the field in build.zig.zon is what moves
# the project forward; zig enforces the same version as its own floor.
have_zig=$(zig version)
if [[ "$have_zig" != "$minimum_zig" ]]; then
    printf 'zig %s is installed, this project builds with exactly %s (see build.zig.zon)\n' "$have_zig" "$minimum_zig" >&2
    printf 'install it from https://ziglang.org/download/\n' >&2
    exit 1
fi

# Build targets run sequentially rather than via -Dall: the CI gate does the
# same to keep peak memory at one wasm compile. Each name is the handle a
# caller passes to run that step alone; the order below is the gate's order.
step_names=(
    check_ci
    fmt
    check_shell
    check_c
    check_cxx
    check_web
    build
    build-x86_64
    hardening
    build-wasm32
    build-wasm64
    # The external-stub DLLs are a shipped target with its own root sources
    # (src/dll/, src/win32_dll_api.zig); without this they are never compiled
    # and a break in them merges unnoticed.
    dll
    # Embedding stubs is the default; external-stubs is the other half of
    # that switch and compiles src/dll/ through a different path.
    external-stubs
    reproducible
    test
    test-cli
    test-cli-x86_64
    fuzz
)
step_commands=(
    'check_ci'
    'zig fmt --check src build.zig build.zig.zon'
    'check_shell'
    'check_c'
    'check_cxx'
    'check_web'
    'zig build --summary all'
    'zig build -Darch=x86_64 --summary all'
    'hardening'
    'zig build -Darch=wasm32 --summary all'
    'zig build -Darch=wasm64 --summary all'
    'zig build -Ddll=all --summary all'
    'zig build -Dexternal-stubs --summary all'
    'reproducible'
    'zig build test --summary all'
    'zig build test-cli --summary all'
    'zig build test-cli -Darch=x86_64 --summary all'
    # Short budget locally; the untrusted-input parsers otherwise never run
    # outside a hand-run `zig build fuzz`. CI raises it through
    # ZINE_FUZZ_SECONDS, which the function below reads, so the command stays
    # in this file.
    'fuzz'
)

# The gate and CI have to run the same steps. .github/workflows/ci.yml names
# them one per CI step so a failure names the target that broke, which is a
# second list to keep: a step added to step_names below reaches neither a pull
# request nor a push to main until the workflow names it, and every other step
# still passes, so the check silently stops existing. This compares the two
# lists and fails on any step the workflow never invokes. AGENTS.md asks for a
# new gate to land in both files; this is what makes that ask enforceable
# rather than a rule a reviewer has to remember.
check_ci() {
    local workflow=.github/workflows/ci.yml name missing=()
    if [[ ! -f "$workflow" ]]; then
        printf 'check_ci: %s is missing, so the gate cannot be matched against CI\n' "$workflow" >&2
        return 1
    fi
    for name in "${step_names[@]}"; do
        # Anchored at the end of the line: a step named by prefix, or named in
        # a comment, does not run it.
        grep -qE "^ *run: bash tests/check\.sh $name\$" "$workflow" || missing+=("$name")
    done
    if ((${#missing[@]} > 0)); then
        printf 'check_ci: the gate runs these steps and CI never invokes them: %s\n' "${missing[*]}" >&2
        printf 'add one "run: bash tests/check.sh <step>" line per step to %s\n' "$workflow" >&2
        return 1
    fi
    printf 'check_ci: CI invokes all %d gate steps\n' "${#step_names[@]}"
}

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
# src/gui/fltk_bridge.cpp is deliberately absent: it is C++ and needs the
# FLTK headers from libfltk1.3-dev, so check_cxx below covers it instead.
check_c() {
    local objdir=".scratch/c-check"
    mkdir -p "$objdir"
    # -Wall stops short of the width, signedness, shadowing, format-argument
    # and declaration rules below. Every tracked source compiles clean under
    # them, so they are part of the gate from here on: a warning they name is a
    # defect class -Wall would have merged without comment.
    local flags=(
        -std=c99
        -Wall -Wextra -Wpedantic -Werror
        -Wconversion -Wsign-conversion -Wshadow -Wcast-qual -Wundef
        -Wformat=2 -Wwrite-strings -Wvla -Wdouble-promotion
        -Wstrict-prototypes -Wmissing-prototypes -Wold-style-definition
    )
    # The gate runs each step inside `if ! ...`, which suspends errexit for the
    # whole body, so a compile that fails does not stop the loop. The status is
    # collected and returned here: without it a warning in the first source is
    # printed and then forgotten, and the step reports success on a C file that
    # does not compile.
    local src status=0
    while IFS= read -r src; do
        zig cc -c -o "$objdir/$(basename "$src").o" "${flags[@]}" "$src" || status=1
    done < <(git ls-files 'tests/*.c' ':!tests/cpubench_win32.c')
    zig cc -c -o "$objdir/cpubench_win32.o" -target x86-windows-gnu \
        "${flags[@]}" tests/cpubench_win32.c || status=1
    return "$status"
}

# src/gui/fltk_bridge.cpp is the one tracked C++ source, and the Zig build
# only reaches it under `zig build -Darch=x86_64 -Dfltk`, so without a step
# here nothing in the gate analyzes it: a warning, or a syntax error, merges
# unseen and surfaces only in someone's FLTK build. `zig build check-cxx`
# compiles the file alone with the flags build.zig gives the -Dfltk
# executable, so the include paths and the warning set stay defined once, in
# build.zig. It links nothing: the FLTK executable also needs X11, Xft and
# fontconfig, and the gate has no business requiring a display stack to
# check one file's warnings. The FLTK development headers are the only
# requirement, and CI installs them.
check_cxx() {
    local include_dir=/usr/include/fltk1.3
    if [[ ! -d "$include_dir/FL" ]]; then
        printf 'the FLTK headers are missing from %s, which src/gui/fltk_bridge.cpp includes\n' "$include_dir" >&2
        printf 'install the FLTK 1.3 development headers (Debian/Ubuntu: libfltk1.3-dev),\n' >&2
        printf 'then re-run: bash tests/check.sh check_cxx\n' >&2
        exit 1
    fi
    zig build check-cxx --summary all
}

# src/gui/app.js is embedded into the wasm artifact and served to a browser,
# so a syntax error in it ships and surfaces only as a page that does not run.
# Nothing else in the gate reads it: the Zig build only carries the bytes, and
# the CLI suites drive the emulator, not the Web UI. `node --check` parses the
# file and stops, so a construct a browser would accept is not the gate's
# business. node is preinstalled on the CI image, and the vendored VanJS
# bundle is checked with the rest: it is a local repackaging, not an upstream
# artifact, and a browser parses it the same way.
check_web() {
    # The gate runs each step inside `if ! ...`, which suspends errexit for the
    # whole body, so a failing command in the loop below does not abort it.
    # The status is collected and returned here instead, or the step would
    # report success on a script that does not parse.
    local script status=0
    while IFS= read -r script; do
        node --check "$script" || status=1
    done < <(git ls-files '*.js')
    ((status == 0)) || return 1
    printf 'check_web: every tracked script parses\n'
}

# The link properties the shipped native executables are only able to carry,
# read out of the linked artifact rather than assumed from build.zig. The rest of
# the usual hardening set is unavailable here and each exclusion is deliberate:
# the images load at a fixed 0x70000000 so the low addresses stay free for guest
# PEs, which rules out PIE; a static binary has no dynamic relocations, so RELRO
# and BIND_NOW have nothing to protect; and Zig's stack protector requires libc,
# whose dynamic loader would give up the self-contained static artifact. What
# survives is a non-executable stack, and a static link, so an INTERP segment
# here means the link changed rather than that the check got stricter.
#
# Both native targets are built first so the step stands alone; in the gate the
# two build steps above already produced them and this is a cache hit.
#
# The gate runs a step inside `if ! ...`, which suspends errexit for the whole
# body, so a build that fails here would be followed by a check of whatever the
# previous step left in zig-out: the stale binaries carry the same headers the
# step looks for, it prints its pass line, and the gate reports success on a
# build that never happened. The status is collected here instead, the way
# check_c and check_web do, and the function returns before it reads a file.
hardening() {
    local status=0
    zig build --summary all || status=1
    zig build -Darch=x86_64 --summary all || status=1
    if ((status != 0)); then
        printf 'hardening: a build failed, so the linked artifacts were not checked\n' >&2
        return 1
    fi
    local binary headers stack_flags
    for binary in zig-out/bin/zine.x86 zig-out/bin/zine.x86_64; do
        # A missing file is its own failure: readelf's error is not the
        # diagnosis, and running the checks on its empty output reports the
        # artifact as having unstated stack permissions.
        if [[ ! -f "$binary" ]]; then
            printf '%s was not installed, so the link was not checked\n' "$binary" >&2
            return 1
        fi
        headers=$(readelf -lW "$binary")
        if grep -q ' INTERP ' <<<"$headers"; then
            printf '%s requests a dynamic loader; the shipped image must stay static\n' "$binary" >&2
            return 1
        fi
        stack_flags=$(awk '$1 == "GNU_STACK" { print $7 }' <<<"$headers")
        if [[ -z "$stack_flags" ]]; then
            printf '%s has no GNU_STACK header, so its stack permissions are unstated\n' "$binary" >&2
            return 1
        fi
        if [[ "$stack_flags" == *E* ]]; then
            printf '%s has an executable stack (GNU_STACK %s)\n' "$binary" "$stack_flags" >&2
            return 1
        fi
    done
    printf 'hardening: both native executables are static with a non-executable stack\n'
}

# The untrusted-input parsers. A function rather than a literal command, so
# the budget expands here: 10 seconds keeps the local gate short, and CI
# raises it with ZINE_FUZZ_SECONDS.
fuzz() {
    zig build fuzz -Dfuzz-seconds="${ZINE_FUZZ_SECONDS:-10}" --summary all
}

# Two install trees of the same target must be identical. A file one build
# emits and the other does not is as much a difference as a differing byte, so
# the file lists are compared first and then each file's bytes, with cmp, which
# stops at the first difference and names the file.
compare_installs() {
    local a=$1 b=$2 scratch=$3 label=$4 rel
    if [[ ! -d "$a" || ! -d "$b" ]]; then
        printf 'not reproducible (%s): %s or %s was never installed\n' "$label" "$a" "$b" >&2
        return 1
    fi
    (cd "$a" && find . -type f | sort) >"$scratch/list-a"
    (cd "$b" && find . -type f | sort) >"$scratch/list-b"
    if ! cmp -s "$scratch/list-a" "$scratch/list-b"; then
        printf 'not reproducible (%s): the two installs hold different files\n' "$label" >&2
        diff "$scratch/list-a" "$scratch/list-b" >&2 || true
        return 1
    fi
    while IFS= read -r rel; do
        if ! cmp -s "$a/$rel" "$b/$rel"; then
            printf 'not reproducible (%s): %s differs between two builds of one source tree\n' "$label" "$rel" >&2
            return 1
        fi
    done <"$scratch/list-a"
    printf 'reproducible (%s): every installed file is byte-identical across builds\n' "$label"
}

# Byte-for-byte reproducibility of a shipped artifact. Both native executables
# are built twice into two install prefixes, the second run starting from a copy
# of the tree at a different path, so anything the compiler records about the
# checkout directory or the toolchain's own lib path shows up as a byte
# difference rather than as a report the maintainers have to take on trust.
# The two native targets are the shipped ELF artifacts; the wasm ones carry no
# DWARF, so there is nothing left in them for a path to leak into.
#
# The second build also runs under a different locale and timezone, which is
# what makes the two runs independent of the ambient environment rather than
# merely of the path. A sort order, a formatted date or a number format that
# reached an artifact would agree under the pinned LC_ALL/TZ both runs
# otherwise share, so the variation is what proves the toolchain ignores them.
#
# The second build is cold: the copy carries only what reaches the compiler, so
# it has no .zig-cache of its own and recompiles from scratch. That is the point,
# not the cost. A warm cache would prove only that Zig's cache is stable, not
# that the artifacts are. The source copy is made under the gitignored
# .scratch/ directory and removed on the way out, so the step writes inside the
# project and not into whatever TMPDIR happens to be (on many hosts that is a
# tmpfs, and two full install trees plus a cold cache do not belong in RAM).
reproducible() {
    local scratch a b status=0
    mkdir -p .scratch
    # Absolute: the copy below builds from inside the copied tree, and a
    # relative prefix would name a directory that does not exist there.
    scratch="$PWD/$(mktemp -d .scratch/reproducible.XXXXXX)"
    # shellcheck disable=SC2064  # expand $scratch now, not at trap time
    trap "rm -rf '$scratch'" EXIT
    a="$scratch/out-a"
    b="$scratch/out-b"
    zig build -p "$a" --summary all || status=1
    zig build -Darch=x86_64 -p "$a-64" --summary all || status=1
    mkdir -p "$scratch/tree"
    # -a keeps the copy's timestamps, and only src/ plus the two build files
    # reach the compiler; the rest of the checkout is not an input. zig-pkg
    # comes along when it exists so the copied tree resolves the pinned TOML
    # dependency from disk rather than over the network.
    cp -a src build.zig build.zig.zon "$scratch/tree/" || status=1
    if [[ -d zig-pkg ]]; then cp -a zig-pkg "$scratch/tree/" || status=1; fi
    # C.UTF-8 and C differ in collation and character classification, and the
    # POSIX TZ form is honoured without a tzdata entry, so neither depends on
    # what the host installed. The subshell keeps the variation off the first
    # build and off the rest of the gate.
    (cd "$scratch/tree" && LC_ALL=C.UTF-8 TZ=JST-9 zig build -p "$b" --summary all) || status=1
    (cd "$scratch/tree" && LC_ALL=C.UTF-8 TZ=JST-9 zig build -Darch=x86_64 -p "$b-64" --summary all) || status=1
    if ((status != 0)); then
        printf 'reproducible: a build failed, so there is nothing to compare (see above)\n' >&2
        return 1
    fi
    # Both targets are compared even when the first one fails: a report of what
    # the gate is about to reject is worth more than the first difference, and
    # either result failing the step is the point.
    compare_installs "$a" "$b" "$scratch" x86 || status=1
    compare_installs "$a-64" "$b-64" "$scratch" x86_64 || status=1
    return "$status"
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
    # The `if !` suspends errexit for the whole command, including the body of
    # a step function it calls and including a `set -e` in that body, so a step
    # made of more than one command has to collect its own status: without that,
    # the last command decides the result and an earlier failure is printed and
    # then forgotten. A step that needs errexit has to return the status of the
    # command that failed rather than the status of the last one it ran.
    #
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
