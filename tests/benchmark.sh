#!/bin/bash
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

set -e
cd "$(dirname "$0")/.."

BENCH_SRC="tests/cpubench_int.c"
BENCH_WIN_SRC="tests/cpubench_win32.c"
BENCH_WIN32="drive_c/Desktop/cpubench.exe"
BENCH_LINUX64="/tmp/cpubench_linux64"
BENCH_LINUX32="/tmp/cpubench_linux32"
ZINE="./zig-out/bin/zine"
ZINE_WASM="./zig-out/bin/zine.wasm"
ZINE_HOST="./zig-out/bin/zine-host"
TIMEOUT=30        # seconds per mode
TIMEOUT_INTERP=30 # interpreter
TIMEOUT_WASM=30   # WASM interpreted

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }
skip()   { echo -e "${YELLOW}  SKIPPED: $1${NC}"; }
fail()   { echo -e "${RED}  FAILED: $1${NC}"; }

# Ensure benchmark source exists
if [ ! -f "$BENCH_SRC" ]; then
    echo "Error: benchmark source not found at $BENCH_SRC"
    exit 1
fi

echo -e "${BOLD}CPU Benchmark Suite${NC}"
echo "Compiling benchmarks..."

# Compile Linux benchmarks
if command -v zig &>/dev/null; then
    zig cc -target x86_64-linux-musl -O2 -w -std=c99 -static -o "$BENCH_LINUX64" "$BENCH_SRC" 2>/dev/null || \
        cc -O2 -w -std=c99 -static -o "$BENCH_LINUX64" "$BENCH_SRC" 2>/dev/null || true
    zig cc -target x86-linux-musl -O2 -w -std=c99 -static -o "$BENCH_LINUX32" "$BENCH_SRC" 2>/dev/null || true
    # Win32 benchmark: no CRT, only KERNEL32.dll — works in all modes (native, interpret, WASM)
    if [ -f "$BENCH_WIN_SRC" ]; then
        zig cc -target x86-windows-gnu -O2 -w -nostdlib -lkernel32 -e mainCRTStartup \
            -o "$BENCH_WIN32" "$BENCH_WIN_SRC" 2>/dev/null || true
    fi
else
    cc -O2 -w -std=c99 -static -o "$BENCH_LINUX64" "$BENCH_SRC" 2>/dev/null || true
    cc -m32 -O2 -w -std=c99 -static -o "$BENCH_LINUX32" "$BENCH_SRC" 2>/dev/null || true
fi

# Build zine (ReleaseFast for fair comparison)
if command -v zig &>/dev/null; then
    echo "Building zine (ReleaseFast)..."
    zig build -Doptimize=ReleaseFast 2>/dev/null || zig build 2>/dev/null
    echo "Building zine.wasm (ReleaseFast)..."
    zig build -Darch=wasm32 -Doptimize=ReleaseFast 2>/dev/null || true
    echo "Building zine-host..."
    zig build -Dhost -Doptimize=ReleaseFast 2>/dev/null || true
fi

echo -e "Done.\n"
echo "================================================================"
echo "  Each test runs for 3 seconds. 4 tests per mode."
echo "================================================================"

# --- 1. Linux native 64-bit ---
header "1. Linux Native (64-bit, -O2)"
if [ -x "$BENCH_LINUX64" ]; then
    timeout $TIMEOUT "$BENCH_LINUX64" 2>/dev/null || fail "crashed or timed out"
else
    skip "could not compile 64-bit binary"
fi

# --- 2. Linux native 32-bit ---
header "2. Linux Native (32-bit, -O2)"
if [ -x "$BENCH_LINUX32" ]; then
    timeout $TIMEOUT "$BENCH_LINUX32" 2>/dev/null || fail "crashed or timed out"
else
    skip "could not compile 32-bit binary"
fi

# --- 3. Wine ---
header "3. Wine (Win32 PE)"
if command -v wine &>/dev/null && [ -f "$BENCH_WIN32" ]; then
    timeout $TIMEOUT wine "$BENCH_WIN32" 2>/dev/null || fail "crashed or timed out"
else
    skip "wine not installed or Win32 binary missing"
fi

# --- 4. Zine native ---
header "4. Zine Native (Win32 PE on x86-linux)"
if [ -x "$ZINE" ] && [ -f "$BENCH_WIN32" ]; then
    timeout $TIMEOUT "$ZINE" "$BENCH_WIN32" 2>/dev/null || fail "crashed or timed out"
else
    skip "zine or Win32 binary missing"
fi

# --- 5. Zine interpreted ---
header "5. Zine Interpreted (x86 software interpreter)"
if [ -x "$ZINE" ] && [ -f "$BENCH_WIN32" ]; then
    timeout $TIMEOUT_INTERP "$ZINE" --interpret "$BENCH_WIN32" 2>/dev/null || fail "crashed or timed out"
else
    skip "zine or Win32 binary missing"
fi

# --- 6. Zine WASM via wasmtime ---
header "6. Zine WASM (wasmtime)"
if command -v wasmtime &>/dev/null && [ -f "$ZINE_WASM" ] && [ -f "$BENCH_WIN32" ]; then
    timeout $TIMEOUT_WASM wasmtime --dir=. "$ZINE_WASM" -- "$BENCH_WIN32" 2>/dev/null \
        || fail "crashed or timed out"
else
    skip "wasmtime not installed or WASM binary missing"
fi

# --- 7. Zine WASM via wasmer ---
header "7. Zine WASM (wasmer)"
if command -v wasmer &>/dev/null && [ -f "$ZINE_WASM" ] && [ -f "$BENCH_WIN32" ]; then
    PROJECT_DIR="$(pwd)"
    timeout $TIMEOUT_WASM wasmer run --volume "$PROJECT_DIR:$PROJECT_DIR" --volume . \
        "$ZINE_WASM" -- "$PROJECT_DIR/$BENCH_WIN32" 2>/dev/null \
        || fail "crashed or timed out"
else
    skip "wasmer not installed or WASM binary missing"
fi

# --- 8. Zine WASM via zine-host (JIT enabled) ---
header "8. Zine WASM + JIT (zine-host)"
if [ -x "$ZINE_HOST" ] && [ -f "$ZINE_WASM" ] && [ -f "$BENCH_WIN32" ]; then
    timeout $TIMEOUT_WASM "$ZINE_HOST" "$ZINE_WASM" -- --jit "$BENCH_WIN32" 2>/dev/null \
        || fail "crashed or timed out"
else
    skip "zine-host or WASM binary missing (build with -Dhost)"
fi

echo ""
echo "================================================================"
echo -e "${BOLD}Benchmark complete.${NC}"
echo "================================================================"
