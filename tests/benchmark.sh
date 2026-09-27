#!/usr/bin/env bash
# benchmark.sh — Run CPU benchmark across all available execution modes
#
# Modes tested:
#   1. Linux native 64-bit
#   2. Linux native 32-bit
#   3. Wine 32-bit
#   4. Zine native (Win32 PE on x86-linux)
#   5. Zine interpreted (x86 software interpreter)
#   6. Zine WASM via wasmtime
#   7. Zine WASM via wasmer
#   8. Zine WASM via zine-host (JIT enabled)
#
# Environment:
#   ZINE_BENCH_DIR       scratch directory for the built binaries
#                        (default .scratch/benchmark)
#   ZINE_BENCH_WIN32     path of the Win32 PE built from tests/cpubench_win32.c
#   ZINE_BENCH_WIN32_SLOW  path of the short-budget PE the interpreters run
#   ZINE_BENCH_MS        guest ms per test for the near-native modes
#   ZINE_BENCH_BATCH     loop iterations between clock reads, same modes
#   ZINE_BENCH_MS_SLOW   guest ms per test for the interpreter modes
#   ZINE_BENCH_BATCH_SLOW  loop iterations between clock reads, interpreter modes
#   ZINE_BENCH_LINUX64   path of the host 64-bit benchmark binary
#   ZINE_BENCH_LINUX32   path of the host 32-bit benchmark binary
#   ZINE_BENCH_KEEP      set to keep those files instead of deleting them
#
# Every mode the run cannot build is reported SKIPPED, and the numbers printed
# are the ones the binaries this run produced.

set -euo pipefail
cd "$(dirname "$0")/.."

BENCH_SRC="tests/cpubench_int.c"
BENCH_WIN_SRC="tests/cpubench_win32.c"

# Every artifact this script produces lands under the gitignored .scratch/ tree
# and is removed on exit, so a run leaves nothing in the work tree and nothing
# in a shared system temp directory. The three paths are environment
# overridable for a run that wants to keep the binaries for a profiler.
SCRATCH="${ZINE_BENCH_DIR:-.scratch/benchmark}"
mkdir -p "$SCRATCH"
BENCH_WIN32="${ZINE_BENCH_WIN32:-$SCRATCH/cpubench.exe}"
BENCH_WIN32_SLOW="${ZINE_BENCH_WIN32_SLOW:-$SCRATCH/cpubench_slow.exe}"
BENCH_LINUX64="${ZINE_BENCH_LINUX64:-$SCRATCH/cpubench_linux64}"
BENCH_LINUX32="${ZINE_BENCH_LINUX32:-$SCRATCH/cpubench_linux32}"
KEEP="${ZINE_BENCH_KEEP:-}"

# Clean up temp files on exit
cleanup() {
    if [ -n "$KEEP" ]; then return; fi
    rm -f "$BENCH_LINUX64" "$BENCH_LINUX32" "$BENCH_WIN32" "$BENCH_WIN32_SLOW" "$SCRATCH"/*.pdb "$SCRATCH"/mode.log
    rmdir "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT

# A failed build must skip its mode, not benchmark whatever an earlier run
# left at the same path: the numbers are only comparable if the bytes they
# measure are the ones this run produced.
drop_stale() { rm -f "$1"; }
ZINE="./zig-out/bin/zine.x86"
ZINE_WASM="./zig-out/bin/zine.wasm32.wasm"
ZINE_HOST="./zig-out/bin/zine-host"

# Guest milliseconds each test runs. The two software interpreters execute a
# given guest millisecond one to three orders of magnitude slower than native
# code, so a run that keeps the native 3 s budget spends minutes inside the
# first WASM test and then reports a timeout with no numbers. The interpreted
# modes therefore get a second PE built with a short budget; each PE prints
# its own duration and its rates are per second, so the two stay comparable.
DURATION_MS="${ZINE_BENCH_MS:-3000}"
BATCH="${ZINE_BENCH_BATCH:-10000}"
# One batch of the timed loops is the shortest a test can run, so the batch and
# the duration together decide whether an interpreter finishes one. Measured:
# with the 10000-iteration default the integer test had not returned after
# four minutes under the WASM interpreter, and the short-budget PE finishes
# the whole suite in 0.4 s on the native interpreter, so the short defaults
# are what the interpreter modes need. Under WASM the same PE is still bound
# by the guest's per-iteration clock read rather than by the arithmetic, and
# test 1 does not return within 150 s; the WASM modes report that exit status
# instead of a bare timeout, and ZINE_BENCH_BATCH_SLOW is the knob to turn.
DURATION_MS_SLOW="${ZINE_BENCH_MS_SLOW:-100}"
BATCH_SLOW="${ZINE_BENCH_BATCH_SLOW:-200}"

# Wall-clock seconds a mode may take. Each default is sized for the guest budget
# that mode runs, so a slow interpreter gets room instead of being cut off
# mid-test; every one is overridable.
TIMEOUT="${ZINE_BENCH_TIMEOUT:-30}"                    # native binaries
TIMEOUT_INTERP="${ZINE_BENCH_TIMEOUT_INTERP:-180}"    # zine interpreted
TIMEOUT_WASM="${ZINE_BENCH_TIMEOUT_WASM:-300}"        # zine WASM (interpreter)

RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }
skip()   { echo -e "${YELLOW}  SKIPPED: $1${NC}"; }
fail()   { echo -e "${RED}  FAILED: $1${NC}"; }

# run <timeout> <reason> <command...> — the body of a mode. Output is streamed
# and kept, and a non-zero exit reports the status and the reason instead of
# hiding both behind a "crashed or timed out" line: a mode that ends with no
# numbers has to be able to say what stopped it.
run() {
    local limit=$1 reason=$2
    shift 2
    local log="$SCRATCH/mode.log" status=0
    timeout "$limit" "$@" 2>&1 | tee "$log" || status=$?
    if ((status != 0)); then
        fail "$reason (exit status $status)"
    fi
}

# Ensure benchmark source exists
if [ ! -f "$BENCH_SRC" ]; then
    echo "Error: benchmark source not found at $BENCH_SRC"
    exit 1
fi

echo -e "${BOLD}CPU Benchmark Suite${NC}"
echo "Compiling benchmarks..."

# Compile Linux benchmarks.
# A missing compiler or an unsupported target is tolerated (each mode below
# reports SKIPPED), but the compiler's diagnostics are not discarded and
# warnings are not muted, so "skipped" stays distinguishable from "broken".
if command -v zig &>/dev/null; then
    drop_stale "$BENCH_LINUX64"; drop_stale "$BENCH_LINUX32"; drop_stale "$BENCH_WIN32"
    zig cc -target x86_64-linux-musl -O2 -std=c99 -static -o "$BENCH_LINUX64" "$BENCH_SRC" || \
        cc -O2 -std=c99 -static -o "$BENCH_LINUX64" "$BENCH_SRC" || true
    zig cc -target x86-linux-musl -O2 -std=c99 -static -o "$BENCH_LINUX32" "$BENCH_SRC" || true
    # Win32 benchmark: no CRT, only KERNEL32.dll — works in all modes (native,
    # interpret, WASM). -fno-builtin keeps the source's hand-written string
    # loops from turning into CRT memcpy/memset calls the link cannot resolve.
    if [ -f "$BENCH_WIN_SRC" ]; then
        drop_stale "$BENCH_WIN32"; drop_stale "$BENCH_WIN32_SLOW"
        for spec in "$BENCH_WIN32:$DURATION_MS:$BATCH" "$BENCH_WIN32_SLOW:$DURATION_MS_SLOW:$BATCH_SLOW"; do
            zig cc -target x86-windows-gnu -O2 -nostdlib -fno-builtin -lkernel32 \
                -e mainCRTStartup "-DDURATION_MS=${spec#*:}" "-DBENCH_BATCH=${spec##*:}" \
                -o "${spec%%:*}" "$BENCH_WIN_SRC" || true
        done
    fi
else
    drop_stale "$BENCH_LINUX64"; drop_stale "$BENCH_LINUX32"
    cc -O2 -std=c99 -static -o "$BENCH_LINUX64" "$BENCH_SRC" || true
    cc -m32 -O2 -std=c99 -static -o "$BENCH_LINUX32" "$BENCH_SRC" || true
fi

# Build zine (ReleaseFast for fair comparison)
if command -v zig &>/dev/null; then
    echo "Building zine (ReleaseFast)..."
    # No fallback to a default build: a benchmark labeled ReleaseFast that
    # silently measured ReleaseSafe or Debug numbers a different binary from
    # the one the report names, so a failed build ends the run instead.
    drop_stale "$ZINE"
    zig build -Doptimize=ReleaseFast --summary all
    # The remaining three modes are optional. Each is removed first, so a build
    # that fails reports SKIPPED below rather than running whatever bytes an
    # earlier run left behind.
    echo "Building zine.wasm (ReleaseFast)..."
    drop_stale "$ZINE_WASM"
    zig build -Darch=wasm32 -Doptimize=ReleaseFast --summary all || true
    echo "Building zine-host..."
    drop_stale "$ZINE_HOST"
    zig build -Dhost -Doptimize=ReleaseFast --summary all || true
fi

echo -e "Done.\n"
echo "================================================================"
echo "  4 tests per mode. Guest budget: ${DURATION_MS} ms for the modes that"
echo "  run the PE near natively, ${DURATION_MS_SLOW} ms for the software"
echo "  interpreters. Every rate printed below is per second."
echo "================================================================"

# --- 1. Linux native 64-bit ---
header "1. Linux Native (64-bit, -O2)"
if [ -x "$BENCH_LINUX64" ]; then
    run "$TIMEOUT" "host binary failed" "$BENCH_LINUX64"
else
    skip "could not compile 64-bit binary"
fi

# --- 2. Linux native 32-bit ---
header "2. Linux Native (32-bit, -O2)"
if [ -x "$BENCH_LINUX32" ]; then
    run "$TIMEOUT" "host binary failed" "$BENCH_LINUX32"
else
    skip "could not compile 32-bit binary"
fi

# --- 3. Wine ---
header "3. Wine (Win32 PE)"
if command -v wine &>/dev/null && [ -f "$BENCH_WIN32" ]; then
    run "$TIMEOUT" "wine failed" wine "$BENCH_WIN32"
else
    skip "wine not installed or Win32 binary missing"
fi

# --- 4. Zine native ---
header "4. Zine Native (Win32 PE on x86-linux)"
if [ -x "$ZINE" ] && [ -f "$BENCH_WIN32" ]; then
    run "$TIMEOUT" "zine failed" "$ZINE" "$BENCH_WIN32"
else
    skip "zine or Win32 binary missing"
fi

# --- 5. Zine interpreted ---
header "5. Zine Interpreted (x86 software interpreter)"
if [ -x "$ZINE" ] && [ -f "$BENCH_WIN32" ]; then
    run "$TIMEOUT_INTERP" "zine --interpret failed" "$ZINE" --interpret "$BENCH_WIN32"
else
    skip "zine or Win32 binary missing"
fi

# --- 6. Zine WASM via wasmtime ---
header "6. Zine WASM (wasmtime)"
if command -v wasmtime &>/dev/null && [ -f "$ZINE_WASM" ] && [ -f "$BENCH_WIN32_SLOW" ]; then
    run "$TIMEOUT_WASM" "wasmtime failed" wasmtime --dir=. "$ZINE_WASM" -- "$BENCH_WIN32_SLOW"
else
    skip "wasmtime not installed or WASM binary missing"
fi

# --- 7. Zine WASM via wasmer ---
header "7. Zine WASM (wasmer)"
if command -v wasmer &>/dev/null && [ -f "$ZINE_WASM" ] && [ -f "$BENCH_WIN32_SLOW" ]; then
    PROJECT_DIR="$(pwd)"
    run "$TIMEOUT_WASM" "wasmer failed"         wasmer run --volume "$PROJECT_DIR:$PROJECT_DIR" --volume . \
        "$ZINE_WASM" -- "$PROJECT_DIR/$BENCH_WIN32_SLOW"
else
    skip "wasmer not installed or WASM binary missing"
fi

# --- 8. Zine WASM via zine-host (JIT enabled) ---
header "8. Zine WASM + JIT (zine-host)"
if [ -x "$ZINE_HOST" ] && [ -f "$ZINE_WASM" ] && [ -f "$BENCH_WIN32_SLOW" ]; then
    run "$TIMEOUT_WASM" "zine-host failed" \
        "$ZINE_HOST" "$ZINE_WASM" -- --jit "$BENCH_WIN32_SLOW"
else
    skip "zine-host or WASM binary missing (build with -Dhost)"
fi

echo ""
echo "================================================================"
echo -e "${BOLD}Benchmark complete.${NC}"
echo "================================================================"
