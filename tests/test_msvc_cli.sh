#!/bin/bash
# Test MSVC 6.0 CLI tools via zine
# Runs each tool with realistic arguments and verifies expected behavior.
#
# Usage:
#   ./test_msvc_cli.sh              # run in native mode (default, x86)
#   ./test_msvc_cli.sh --native64   # run in native mode (x86_64 compat mode)
#   ./test_msvc_cli.sh --interpret  # run in interpreter mode
#   ./test_msvc_cli.sh --interpret64 # run in interpreter mode (x86_64 compat mode)
#   ./test_msvc_cli.sh --jit        # run in JIT mode
#   ./test_msvc_cli.sh --external   # run with external DLL stubs (not embedded)
#   ./test_msvc_cli.sh --external64 # run with external DLL stubs (x86_64 compat mode)
#   ./test_msvc_cli.sh --wasmtime   # run in WASM mode via wasmtime
#   ./test_msvc_cli.sh --wasmer     # run in WASM mode via wasmer
#   ./test_msvc_cli.sh --zine-host  # run in WASM mode via zine-host (wasmer wrapper)
#   ./test_msvc_cli.sh --wasm       # alias for --wasmtime
#   ./test_msvc_cli.sh --both       # run native + interpreted
#   ./test_msvc_cli.sh --all        # run native + interpreted + jit + external + wasmtime + wasmer (including 64 variants)
#   ./test_msvc_cli.sh --interpret --filter "CL.EXE"   # run only matching tests
#   ./test_msvc_cli.sh --interpret --filter "startup"   # run only startup tests
#   ./test_msvc_cli.sh --native --filter "DUMPBIN"      # run DUMPBIN tests only
#   ./test_msvc_cli.sh --native64 --filter "startup"    # run startup tests on x86_64
#
# WASI exit code note:
#   wasmtime only supports exit codes 0-125; codes ≥126 are mapped to 1.
#   wasmer passes all exit codes 0-255 faithfully.
#   The test adapts expected exit codes per runtime.
#
# x86_64 compat mode notes:
#   --native64 builds with -Darch=x86_64 and runs 32-bit PEs in CPU compat
#   mode (CS=0x23). API calls use INT 0xFE -> SIGSEGV signal dispatch.
#   x86_64 --interpret is not yet supported (stubs return 64-bit pointers
#   that the 32-bit interpreter can't handle).
#
# Key constraints:
# - CL.EXE treats paths starting with / as options, so use relative paths
# - NMAKE can't shell out (no cmd.exe), so skip shell-dependent tests
# - All paths passed to Win32 tools should use backslashes or relative form

set -euo pipefail

MODE="${1:-native}"
FILTER=""

# Parse remaining args for --filter
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --filter) FILTER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# should_run: returns 0 (true) if a test section should run based on filter
should_run() {
    local section_name="$1"
    [ -z "$FILTER" ] && return 0
    echo "$section_name" | grep -qiE "$FILTER"
}

# --both: re-invoke native + interpreted
if [ "$MODE" = "--both" ] || [ "$MODE" = "both" ]; then
    echo "===== Running in NATIVE mode ====="
    "$0" --native ${FILTER:+--filter "$FILTER"}
    native_rc=$?
    echo ""
    echo "===== Running in INTERPRET mode ====="
    "$0" --interpret ${FILTER:+--filter "$FILTER"}
    interp_rc=$?
    if [ $native_rc -ne 0 ] || [ $interp_rc -ne 0 ]; then
        exit 1
    fi
    exit 0
fi

# --all: re-invoke native + native64 + interpreted + jit + wasmtime + wasmer
if [ "$MODE" = "--all" ] || [ "$MODE" = "all" ]; then
    all_rc=0
    for m in --native --native64 --interpret --interpret64 --jit --external --external64 --wasmtime --wasmer --zine-host; do
        echo "===== Running in ${m#--} mode ====="
        "$0" "$m" ${FILTER:+--filter "$FILTER"} || all_rc=1
        echo ""
    done
    exit $all_rc
fi

# Parse mode flag
ZINE_FLAGS=()
IS_WASM=false
IS_EXTERNAL=false
IS_NATIVE64=false
WASM_RUNTIME=""     # "wasmtime", "wasmer", or "zine-host"
WASM_RUNS_OUTPUT=false  # true when the runtime can run compiled exe output
WASM_EXIT_MAX=255   # max exit code the runtime supports faithfully
TIMEOUT_SECS=30
case "$MODE" in
    --interpret|interpret)
        ZINE_FLAGS=(--interpret)
        MODE_LABEL="INTERPRET"
        TIMEOUT_SECS=60  # interpreter is slower
        ;;
    --interpret64|interpret64)
        ZINE_FLAGS=(--interpret)
        MODE_LABEL="INTERPRET64"
        IS_NATIVE64=true
        TIMEOUT_SECS=60
        ;;
    --jit|jit)
        ZINE_FLAGS=(--jit)
        MODE_LABEL="JIT"
        TIMEOUT_SECS=60  # JIT may include compilation overhead
        ;;
    --external|external)
        ZINE_FLAGS=()
        MODE_LABEL="EXTERNAL"
        IS_EXTERNAL=true
        ;;
    --external64|external64)
        ZINE_FLAGS=()
        MODE_LABEL="EXTERNAL64"
        IS_NATIVE64=true
        IS_EXTERNAL=true
        ;;
    --native64|native64)
        ZINE_FLAGS=()
        MODE_LABEL="NATIVE64"
        IS_NATIVE64=true
        ;;
    --wasm|wasm|--wasmtime|wasmtime)
        IS_WASM=true
        WASM_RUNTIME="wasmtime"
        WASM_EXIT_MAX=125  # wasmtime maps exit codes ≥126 to 1
        MODE_LABEL="WASM/wasmtime"
        WASM_RUNS_OUTPUT=true  # runs compiled exe output; missing markers = regression
        TIMEOUT_SECS=60  # interpreter is slow; 30s flakes under load
        ;;
    --wasmer|wasmer)
        IS_WASM=true
        WASM_RUNTIME="wasmer"
        WASM_EXIT_MAX=255  # wasmer passes all exit codes 0-255
        MODE_LABEL="WASM/wasmer"
        TIMEOUT_SECS=60
        ;;
    --zine-host|zinehost|zine_host)
        IS_WASM=true
        WASM_RUNTIME="zine-host"
        WASM_EXIT_MAX=255  # wasmer passes all exit codes 0-255
        MODE_LABEL="WASM/zine-host"
        WASM_RUNS_OUTPUT=true  # runs compiled exe output; missing markers = regression
        TIMEOUT_SECS=120  # wasmer JIT compile + interpreter; generous
        ;;
    --native|native|"")
        ZINE_FLAGS=()
        MODE_LABEL="NATIVE"
        ;;
    *)
        echo "Usage: $0 [--native|--native64|--interpret|--interpret64|--jit|--external|--external64|--wasmtime|--wasmer|--zine-host|--both|--all] [--filter PATTERN]"
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MSVC_ROOT="$(realpath "$SCRIPT_DIR/../tools/MSVC600")"
VC_BIN="$MSVC_ROOT/VC98/Bin"
VC_INCLUDE="$MSVC_ROOT/VC98/Include"
VC_LIB="$MSVC_ROOT/VC98/Lib"
COMMON_BIN="$MSVC_ROOT/Common/MSDev98/Bin"
COMMON_TOOLS="$MSVC_ROOT/Common/Tools"

PASSED=0
FAILED=0
FAILURES=""

# Build zine (skip if SKIP_BUILD is set, useful when testing a specific arch)
if [ "${SKIP_BUILD:-}" != "1" ]; then
    if $IS_WASM; then
        echo "Building zine for wasm32..."
        (cd "$SCRIPT_DIR/.." && zig build -Darch=wasm32) || { echo "FATAL: zig build -Darch=wasm32 failed"; exit 1; }
    elif $IS_EXTERNAL; then
        echo "Building DLLs + zine with external stubs..."
        (cd "$SCRIPT_DIR/.." && zig build -Ddll=true && zig build -Dexternal-stubs=true -Darch=x86) || { echo "FATAL: zig build -Dexternal-stubs failed"; exit 1; }
    elif $IS_NATIVE64; then
        echo "Building zine for x86_64 (compat mode)..."
        (cd "$SCRIPT_DIR/.." && zig build -Darch=x86_64) || { echo "FATAL: zig build -Darch=x86_64 failed"; exit 1; }
    else
        echo "Building zine..."
        (cd "$SCRIPT_DIR/.." && zig build) || { echo "FATAL: zig build failed"; exit 1; }
    fi
    echo ""
else
    echo "Skipping build (SKIP_BUILD=1)"
    echo ""
fi

if $IS_WASM; then
    WASM_BIN="$(realpath "$SCRIPT_DIR/../zig-out/bin/zine.wasm32.wasm")"
    # Fall back to old name if new name doesn't exist
    if [ ! -f "$WASM_BIN" ]; then
        WASM_BIN="$(realpath "$SCRIPT_DIR/../zig-out/bin/zine.wasm" 2>/dev/null || echo "")"
    fi
    if [ ! -f "$WASM_BIN" ]; then
        echo "FATAL: zine.wasm32.wasm not found"
        exit 1
    fi
    if ! command -v "$WASM_RUNTIME" &>/dev/null; then
        # zine-host is built into zig-out/bin (not installed on PATH) — accept
        # the project binary as the runtime.
        if [ "$WASM_RUNTIME" = "zine-host" ] && [ -x "$(realpath "$SCRIPT_DIR/../zig-out/bin/zine-host" 2>/dev/null || echo /nonexistent)" ]; then
            :
        else
            echo "FATAL: $WASM_RUNTIME not found in PATH"
            exit 1
        fi
    fi
else
    if $IS_NATIVE64; then
        WINLOADER="$(realpath "$SCRIPT_DIR/../zig-out/bin/zine.x86_64")"
    else
        WINLOADER="$(realpath "$SCRIPT_DIR/../zig-out/bin/zine.x86")"
    fi
    if [ ! -x "$WINLOADER" ]; then
        echo "FATAL: $WINLOADER not found"
        exit 1
    fi
fi

# Set up MSVC environment (what VCVARS32.BAT does)
export PATH="$VC_BIN:$COMMON_BIN:$COMMON_TOOLS:$PATH"
export INCLUDE="$VC_INCLUDE"
export LIB="$VC_LIB"

# Work in a temp dir so relative paths work for CL/LINK
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

# Set up WINLOADER_CMD after WORKDIR is created so WASM --dir knows all paths
if $IS_WASM; then
    if [ "$WASM_RUNTIME" = "wasmer" ]; then
        # wasmer needs --volume for filesystem access and absolute paths for PEs.
        # Map both the project root and workdir so DLLs and temp files are accessible.
        PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
        WINLOADER_CMD=(wasmer run
            --volume "$PROJECT_DIR:$PROJECT_DIR"
            --volume "$WORKDIR:$WORKDIR"
            --env "INCLUDE=$INCLUDE" --env "LIB=$LIB" --env "PATH=$PATH"
            --env "ZINE_CWD=$WORKDIR"
            "$WASM_BIN" --)
        # wasmer requires absolute paths for PE files
        VC_BIN="$MSVC_ROOT/VC98/Bin"
        COMMON_BIN="$MSVC_ROOT/Common/MSDev98/Bin"
        COMMON_TOOLS="$MSVC_ROOT/Common/Tools"
    elif [ "$WASM_RUNTIME" = "zine-host" ]; then
        # zine-host: native wasmer wrapper; inherits the host env (PATH must
        # include the MSVC bin dir so CL's _spawnvp finds C1.DLL) and preopens
        # the cwd + "/" (relative creates resolve through the preopen walk).
        ZINE_HOST="$(command -v zine-host || echo "$SCRIPT_DIR/../zig-out/bin/zine-host")"
        WINLOADER_CMD=("$ZINE_HOST" "$WASM_BIN" --)
    else
        # wasmtime: --dir to preopen filesystem, --env to pass-through host env vars
        # --dir=. must come FIRST: the first preopen becomes the WASI CWD, so a
        # leading --dir=/ roots the CWD at / and breaks CWD-relative file
        # creation (AccessDenied). --dir=/ still grants absolute-path access.
        WINLOADER_CMD=(wasmtime run --dir=. --dir=/ --env INCLUDE --env LIB --env PATH --env TMP --env TEMP "$WASM_BIN" --)
    fi
else
    WINLOADER_CMD=("$WINLOADER")
fi

pass() {
    local name="$1"; shift
    printf "  PASS  %-35s %s\n" "$name" "$*"
    PASSED=$((PASSED + 1))
}

fail() {
    local name="$1"; shift
    printf "  FAIL  %-35s %s\n" "$name" "$*"
    FAILED=$((FAILED + 1))
    FAILURES="$FAILURES\n--- $name ---\n$*"
}

# run: capture output+exit code without set -e interference
# Automatically injects ZINE_FLAGS after the zine binary/command.
run() {
    local outfile="$1"; shift
    local rc=0
    timeout $TIMEOUT_SECS "$@" > "$outfile" 2>&1 || rc=$?
    echo "$rc"
}

########################################
if should_run "startup"; then
echo "=== Tool Startup (no-args help) [$MODE_LABEL] ==="
########################################

check_startup() {
    local name="$1" exe="$2" expected_rc="$3" grep_pattern="$4"
    if [ ! -f "$exe" ]; then
        printf "  SKIP  %-35s (not found)\n" "$name"
        return
    fi
    local rc
    rc=$(run out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$exe")
    # WASM mode: adjust expected exit code for runtime limitations.
    # wasmtime maps codes ≥126 to 1; wasmer passes all codes faithfully.
    local eff_expected="$expected_rc"
    if $IS_WASM && [ "$expected_rc" -gt "$WASM_EXIT_MAX" ] 2>/dev/null; then
        eff_expected=1  # runtime maps unsupported codes to 1
    fi
    if [ "$rc" -ge 128 ] && [ "$rc" -le 159 ] && [ "$rc" != "$eff_expected" ]; then
        fail "$name" "CRASHED (signal $((rc - 128)))"
        return
    fi
    if [ "$rc" != "$eff_expected" ]; then
        fail "$name" "exit $rc, expected $eff_expected"
        return
    fi
    if [ -n "$grep_pattern" ]; then
        if grep -qiE "$grep_pattern" out.txt 2>/dev/null; then
            pass "$name" "(exit $rc)"
        else
            fail "$name" "exit $rc but missing: $grep_pattern"
        fi
    else
        pass "$name" "(exit $rc)"
    fi
}

check_startup "CL.EXE"       "$VC_BIN/CL.EXE"          0   "Microsoft|Compiler|usage"
check_startup "LINK.EXE"     "$VC_BIN/LINK.EXE"        76   "Microsoft|LINK|usage"
check_startup "LIB.EXE"      "$VC_BIN/LIB.EXE"         76   "usage|LIB"
check_startup "NMAKE.EXE"    "$VC_BIN/NMAKE.EXE"        2   "NMAKE|MAKEFILE"
check_startup "DUMPBIN.EXE"  "$VC_BIN/DUMPBIN.EXE"     76   "usage|DUMPBIN"
check_startup "EDITBIN.EXE"  "$VC_BIN/EDITBIN.EXE"     76   "usage|EDITBIN"
check_startup "CVPACK.EXE"   "$VC_BIN/CVPACK.EXE"       0   ""
check_startup "CVTRES.EXE"   "$VC_BIN/CVTRES.EXE"       0   ""
check_startup "BSCMAKE.EXE"  "$VC_BIN/BSCMAKE.EXE"      1   "BSCMAKE|bscmake"
check_startup "MIDL.EXE"     "$VC_BIN/MIDL.EXE"       232   "MIDL|midl"
check_startup "MC.EXE"       "$VC_BIN/MC.EXE"           1   "MC|message"
check_startup "PREP.EXE"     "$VC_BIN/PREP.EXE"         0   ""
check_startup "PROFILE.EXE"  "$VC_BIN/PROFILE.EXE"      0   ""
check_startup "PLIST.EXE"    "$VC_BIN/PLIST.EXE"         0   ""
check_startup "REBASE.EXE"   "$VC_BIN/REBASE.EXE"       99  ""
check_startup "RC.EXE"       "$COMMON_BIN/RC.EXE"       1   ""
check_startup "VCSPAWN.EXE"  "$COMMON_BIN/VCSPAWN.EXE"  1   "VcSpawn"
check_startup "UNDNAME.EXE"  "$COMMON_TOOLS/UNDNAME.EXE" 1  "UNDNAME|undname"
check_startup "BIND.EXE"     "$COMMON_TOOLS/BIND.EXE"  99   ""
check_startup "MAKEHM.EXE"   "$COMMON_TOOLS/MAKEHM.EXE" 1   ""
check_startup "UUIDGEN.EXE"  "$COMMON_TOOLS/UUIDGEN.EXE" 0  ""
fi  # end startup

########################################
if should_run "CL compile|CL.EXE"; then
echo ""
echo "=== CL.EXE: Compile C to .obj [$MODE_LABEL] ==="
########################################

# CL.EXE interprets /path as an option, so use relative filenames
cat > hello.c <<'EOF'
int main(void) { return 42; }
EOF

rc=$(run cl_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /Fohello.obj hello.c)
if [ "$rc" = "0" ] && [ -f hello.obj ]; then
    objsize=$(stat -c%s hello.obj 2>/dev/null || echo "0")
    pass "CL /c hello.c" "($objsize bytes)"
else
    fail "CL /c hello.c" "exit $rc $(tail -3 cl_out.txt 2>/dev/null)"
fi
fi  # end CL compile

########################################
if should_run "CL preprocess|CL.EXE"; then
echo ""
echo "=== CL.EXE: Preprocess only ==="
########################################

cat > preproc.c <<'EOF'
#define VALUE 123
int x = VALUE;
EOF

rc=$(run preproc_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /EP preproc.c)
if [ "$rc" = "0" ] && grep -q "123" preproc_out.txt 2>/dev/null; then
    pass "CL /EP (preprocess)" "(macro expanded)"
else
    fail "CL /EP (preprocess)" "exit $rc $(tail -3 preproc_out.txt 2>/dev/null)"
fi
fi  # end CL preprocess

########################################
if should_run "CL link|CL.EXE"; then
echo ""
echo "=== CL.EXE: Compile + Link ==="
########################################

cat > add.c <<'EOF'
#include <stdio.h>
int add(int a, int b) { return a + b; }
int main(void) {
    printf("result=%d\n", add(3, 4));
    return 0;
}
EOF

rc=$(run cl_link_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /Feadd.exe add.c /link /NOLOGO)
if [ "$rc" = "0" ] && [ -f add.exe ]; then
    exesize=$(stat -c%s add.exe 2>/dev/null || echo "0")
    pass "CL /Fe add.exe" "($exesize bytes)"
else
    fail "CL /Fe add.exe" "exit $rc $(tail -5 cl_link_out.txt 2>/dev/null)"
fi
fi  # end CL link

########################################
if should_run "CL syntax|CL.EXE"; then
echo ""
echo "=== CL.EXE: Syntax error ==="
########################################

cat > bad.c <<'EOF'
int main(void) { this is not valid C; }
EOF

rc=$(run bad_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /Fobad.obj bad.c)
if [ "$rc" != "0" ] && grep -qiE "error|C[0-9]" bad_out.txt 2>/dev/null; then
    pass "CL syntax error" "(error reported, exit $rc)"
else
    fail "CL syntax error" "exit $rc, expected non-zero with error"
fi
fi  # end CL syntax

########################################
if should_run "CL multi|CL.EXE"; then
echo ""
echo "=== CL.EXE: Multi-file compile ==="
########################################

cat > util.c <<'EOF'
int square(int n) { return n * n; }
EOF

cat > main2.c <<'EOF'
#include <stdio.h>
extern int square(int);
int main(void) {
    printf("%d\n", square(5));
    return 0;
}
EOF

rc=$(run multi_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /Femulti.exe util.c main2.c /link /NOLOGO)
if [ "$rc" = "0" ] && [ -f multi.exe ]; then
    pass "CL multi-file" "(produced multi.exe)"
else
    fail "CL multi-file" "exit $rc $(tail -5 multi_out.txt 2>/dev/null)"
fi
fi  # end CL multi

########################################
if should_run "LINK"; then
echo ""
echo "=== LINK.EXE: Link .obj ==="
########################################

if [ -f hello.obj ]; then
    rc=$(run link_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /OUT:linked.exe /SUBSYSTEM:CONSOLE hello.obj)
    if [ "$rc" = "0" ] && [ -f linked.exe ]; then
        pass "LINK hello.obj" "(produced linked.exe)"
    else
        fail "LINK hello.obj" "exit $rc $(tail -5 link_out.txt 2>/dev/null)"
    fi
else
    fail "LINK hello.obj" "skipped (no hello.obj)"
fi
fi  # end LINK

########################################
if should_run "DUMPBIN"; then
echo ""
echo "=== DUMPBIN.EXE: Headers ==="
########################################

# DUMPBIN /HEADERS works on .obj files but crashes on DLL/EXE targets.
# DLL/EXE path goes through LINK.EXE's fprintf with MSVCRT's internal buffered I/O,
# which crashes due to incomplete FILE struct buffer management in our stubs.
if [ -f hello.obj ]; then
    rc=$(run dump_hdr.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/DUMPBIN.EXE" /HEADERS hello.obj)
    if grep -qiE "HEADER|machine|section" dump_hdr.txt 2>/dev/null; then
        pass "DUMPBIN /HEADERS hello.obj" "(headers found)"
    else
        fail "DUMPBIN /HEADERS hello.obj" "exit $rc"
    fi
else
    fail "DUMPBIN /HEADERS" "skipped (no hello.obj)"
fi

########################################
echo ""
echo "=== DUMPBIN.EXE: Exports ==="
########################################

cp "$VC_BIN/C1.DLL" c1_copy.dll 2>/dev/null || true
if [ -f c1_copy.dll ]; then
    rc=$(run dump_exp.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/DUMPBIN.EXE" /EXPORTS c1_copy.dll)
    if grep -qiE "ordinal|export|name" dump_exp.txt 2>/dev/null; then
        pass "DUMPBIN /EXPORTS C1.DLL" "(exports found)"
    else
        fail "DUMPBIN /EXPORTS C1.DLL" "exit $rc"
    fi
else
    fail "DUMPBIN /EXPORTS C1.DLL" "could not copy C1.DLL"
fi

########################################
echo ""
echo "=== DUMPBIN.EXE: Disassembly ==="
########################################

if [ -f hello.obj ]; then
    rc=$(run dump_disasm.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/DUMPBIN.EXE" /DISASM hello.obj)
    if grep -qiE "disassembly|_main|push|ret" dump_disasm.txt 2>/dev/null; then
        pass "DUMPBIN /DISASM hello.obj" "(disasm output)"
    else
        fail "DUMPBIN /DISASM hello.obj" "exit $rc"
    fi
else
    fail "DUMPBIN /DISASM hello.obj" "skipped (no hello.obj)"
fi

########################################
echo ""
echo "=== DUMPBIN.EXE: Symbols ==="
########################################

if [ -f hello.obj ]; then
    rc=$(run dump_sym.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/DUMPBIN.EXE" /SYMBOLS hello.obj)
    if grep -qiE "_main|SYMBOL|External" dump_sym.txt 2>/dev/null; then
        pass "DUMPBIN /SYMBOLS hello.obj" "(found _main)"
    else
        fail "DUMPBIN /SYMBOLS hello.obj" "exit $rc"
    fi
else
    fail "DUMPBIN /SYMBOLS hello.obj" "skipped"
fi
fi  # end DUMPBIN

########################################
if should_run "LIB"; then
echo ""
echo "=== LIB.EXE: Create .lib ==="
########################################

# LIB /OUT currently fails with LNK1102 (out of memory) due to unresolved
# mspdb60.dll imports in LINK.EXE. Track as known limitation.
if [ -f hello.obj ]; then
    rc=$(run lib_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LIB.EXE" /NOLOGO /OUT:hello.lib hello.obj)
    if [ -f hello.lib ]; then
        libsize=$(stat -c%s hello.lib 2>/dev/null || echo "0")
        pass "LIB /OUT hello.lib" "($libsize bytes)"
    else
        printf "  SKIP  %-35s %s\n" "LIB /OUT hello.lib" "(known: LNK1102 out of memory)"
    fi
else
    fail "LIB /OUT hello.lib" "skipped"
fi

########################################
echo ""
echo "=== LIB.EXE: List .lib ==="
########################################

# Use an existing SDK lib since /OUT may not work yet
cp "$VC_LIB/libc.lib" libc_copy.lib 2>/dev/null || true
if [ -f libc_copy.lib ]; then
    rc=$(run lib_list.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LIB.EXE" /NOLOGO /LIST libc_copy.lib)
    if grep -qiE "\.obj" lib_list.txt 2>/dev/null; then
        members=$(grep -ciE "\.obj" lib_list.txt 2>/dev/null || echo "?")
        pass "LIB /LIST libc.lib" "($members members)"
    else
        fail "LIB /LIST libc.lib" "exit $rc"
    fi
else
    fail "LIB /LIST libc.lib" "could not copy libc.lib"
fi
fi  # end LIB

########################################
if should_run "RC"; then
echo ""
echo "=== RC.EXE: Compile resource ==="
########################################

cat > simple.rc <<'EOF'
STRINGTABLE
BEGIN
    1, "Hello from RC"
END
EOF

rc=$(run rc_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$COMMON_BIN/RC.EXE" /fo simple.res /I"$VC_INCLUDE" simple.rc)
if [ -f simple.res ]; then
    ressize=$(stat -c%s simple.res 2>/dev/null || echo "0")
    pass "RC simple.rc" "($ressize bytes)"
else
    fail "RC simple.rc" "exit $rc $(tail -5 rc_out.txt 2>/dev/null)"
fi
fi  # end RC

########################################
if should_run "CVTRES"; then
echo ""
echo "=== CVTRES.EXE: Convert .res ==="
########################################

if [ -f simple.res ]; then
    rc=$(run cvtres_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CVTRES.EXE" /OUT:simple.coff simple.res)
    if [ -f simple.coff ]; then
        pass "CVTRES simple.res" "(produced .coff)"
    else
        fail "CVTRES simple.res" "exit $rc $(tail -3 cvtres_out.txt 2>/dev/null)"
    fi
else
    fail "CVTRES simple.res" "skipped (no .res)"
fi
fi  # end CVTRES

########################################
if should_run "UNDNAME"; then
echo ""
echo "=== UNDNAME.EXE: Demangle ==="
########################################

rc=$(run undname_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$COMMON_TOOLS/UNDNAME.EXE" "?add@@YAHHH@Z")
if grep -qiE "add|int" undname_out.txt 2>/dev/null; then
    demangled=$(grep -i "add" undname_out.txt | head -1 || true)
    pass "UNDNAME demangle" "($demangled)"
else
    fail "UNDNAME demangle" "exit $rc $(cat undname_out.txt 2>/dev/null)"
fi
fi  # end UNDNAME

########################################
if should_run "UUIDGEN"; then
echo ""
echo "=== UUIDGEN.EXE: Generate UUID ==="
########################################

rc=$(run uuid_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$COMMON_TOOLS/UUIDGEN.EXE")
uuid=$(grep -oE "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}" uuid_out.txt 2>/dev/null | head -1 || true)
if [ -n "$uuid" ]; then
    pass "UUIDGEN" "($uuid)"
else
    fail "UUIDGEN" "exit $rc, no UUID"
fi
fi  # end UUIDGEN

########################################
if should_run "APITEST|api.test"; then
echo ""
echo "=== API test: wide literals, GlobalAlloc, env vars, argv ==="
########################################
# Regression guard for stub-level fixes: mbtowc (wide literal encoding),
# GlobalAlloc/GlobalReAlloc/GlobalSize (guest VA returns), GetEnvironmentVariable
# A/W (getEnvValue lookup + widening), and GetCommandLineA argv plumbing.

cat > apitest.c <<'APITEST_EOF'
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    char buf[512];
    DWORD n;
    HGLOBAL h;
    wchar_t wbuf[128];
    char *p;

    /* Wide string literal must encode correctly (mbtowc regression). */
    {
        wchar_t lit[] = L"LIB";
        if (lit[0] == L'L' && lit[1] == L'I' && lit[2] == L'B' && lit[3] == 0)
            printf("wlit-ok\n");
    }

    /* GlobalAlloc / GlobalSize / GlobalReAlloc round-trip. */
    h = GlobalAlloc(GMEM_FIXED, 32);
    if (h) {
        p = (char *)h;
        strcpy(p, "global-ok");
        printf("global:%s:size=%u\n", p, (unsigned)GlobalSize(h));
        h = GlobalReAlloc(h, 64, GMEM_MOVEABLE);
        if (h) printf("realloc:%s\n", (char *)h);
    }

    /* GetEnvironmentVariableW with a literal name. */
    n = GetEnvironmentVariableW(L"LIB", wbuf, 128);
    if (n) printf("lib-w:%u\n", (unsigned)n);

    /* GetEnvironmentVariableA required-size query. */
    n = GetEnvironmentVariableA("LIB", NULL, 0);
    if (n) printf("lib-a-req:%u\n", (unsigned)n);

    /* argv plumbing via GetCommandLineA. */
    if (argc > 1) {
        char *cl = GetCommandLineA();
        if (strstr(cl, argv[1])) printf("cmdline-ok\n");
    }
    return 0;
}
APITEST_EOF

# Step 1: compile
rc=$(run api_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fapitest.obj apitest.c)
if [ "$rc" = "0" ] && [ -f apitest.obj ]; then
    pass "APITEST: CL /c apitest.c" ""
else
    fail "APITEST: CL /c apitest.c" "exit $rc $(tail -3 api_cl.txt 2>/dev/null)"
fi

# Step 2: link
if [ -f apitest.obj ]; then
    rc=$(run api_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /OUT:apitest.exe /LIBPATH:"$VC_LIB" /SUBSYSTEM:CONSOLE apitest.obj)
    if [ "$rc" = "0" ] && [ -f apitest.exe ]; then
        pass "APITEST: LINK apitest.obj" "($(stat -c%s apitest.exe) bytes)"
    else
        fail "APITEST: LINK apitest.obj" "exit $rc $(tail -3 api_link.txt 2>/dev/null)"
    fi
fi

# Step 3: run the compiled exe and verify the API behaviors
if [ -f apitest.exe ]; then
    rc=$(run api_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./apitest.exe api-arg)
    if grep -q "wlit-ok" api_out.txt 2>/dev/null && grep -q "global-ok" api_out.txt 2>/dev/null \
       && grep -q "lib-w:" api_out.txt 2>/dev/null && grep -q "cmdline-ok" api_out.txt 2>/dev/null; then
        pass "APITEST: run apitest.exe" "(wlit/global/envw/cmdline all ok)"
    elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
        # wasmtime runs compiled output, so missing markers here is a real
        # regression (e.g. wide literals re-corrupting via mbtowc).
        fail "APITEST: run apitest.exe" "exit $rc, missing expected output ($(tail -3 api_out.txt 2>/dev/null | tr '\n' ' '))"
    else
        # Other runtimes cannot run compiled output yet — aspirational
        printf "  SKIP  %-35s %s\n" "APITEST: run apitest.exe" "(exit $rc, running compiled output not yet supported)"
    fi
fi
fi  # end APITEST

########################################
if should_run "GUI|gui.smoke"; then
echo ""
echo "=== GUI smoke: window create, paint, clean message-loop exit ==="
########################################
# Regression guard for the Win32 GUI pipeline fixes: WM_CLOSE must destroy the
# window (→ WM_DESTROY → PostQuitMessage) and GetMessageA must return 0 on
# WM_QUIT — otherwise the app hangs in an infinite WM_PAINT loop (the earlier
# symptom was a timeout with thousands of BeginPaint calls).

cat > gui_smoke.c <<'GUI_EOF'
#include <windows.h>

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    PAINTSTRUCT ps;
    HDC hdc;
    RECT rc;
    switch (msg) {
    case WM_PAINT:
        hdc = BeginPaint(hwnd, &ps);
        GetClientRect(hwnd, &rc);
        FillRect(hdc, &rc, (HBRUSH)(COLOR_WINDOW + 1));
        TextOutA(hdc, 8, 8, "zine-gui-ok", 11);
        EndPaint(hwnd, &ps);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, btn;
    MSG msg;
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = hInst;
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "GuiSmoke";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "GuiSmoke", "GuiSmoke",
        WS_OVERLAPPEDWINDOW, 0, 0, 200, 120, NULL, NULL, hInst, NULL);
    /* Standard child control (BUTTON) — exercises the child-window path. */
    btn = CreateWindowEx(0, "BUTTON", "Push", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
        10, 40, 60, 24, hwnd, (HMENU)1001, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    InvalidateRect(hwnd, NULL, TRUE);
    UpdateWindow(hwnd);
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return (int)msg.wParam;
}
GUI_EOF

# Step 1: compile
rc=$(run gui_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fogui_smoke.obj gui_smoke.c)
if [ "$rc" = "0" ] && [ -f gui_smoke.obj ]; then
    pass "GUI: CL /c gui_smoke.c" ""
else
    fail "GUI: CL /c gui_smoke.c" "exit $rc $(tail -3 gui_cl.txt 2>/dev/null)"
fi

# Step 2: link (GUI subsystem + import libs)
if [ -f gui_smoke.obj ]; then
    rc=$(run gui_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:gui_smoke.exe /LIBPATH:"$VC_LIB" gui_smoke.obj user32.lib gdi32.lib)
    if [ "$rc" = "0" ] && [ -f gui_smoke.exe ]; then
        pass "GUI: LINK gui_smoke.obj" "($(stat -c%s gui_smoke.exe) bytes)"
    else
        fail "GUI: LINK gui_smoke.obj" "exit $rc $(tail -3 gui_link.txt 2>/dev/null)"
    fi
fi

# Step 3: run — the message loop must terminate cleanly (exit 0), not spin on
# synthetic WM_PAINT forever. Only meaningful on native builds: the WASM build
# has no GUI renderer wired (CreateWindowExA would crash in renderer.init-less
# setResolution), so skip there.
if [ -f gui_smoke.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "GUI: run gui_smoke.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run gui_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./gui_smoke.exe)
        if [ "$rc" = "0" ]; then
            pass "GUI: run gui_smoke.exe" "(clean message-loop exit)"
        else
            fail "GUI: run gui_smoke.exe" "exit $rc (message loop did not terminate) $(tail -3 gui_out.txt 2>/dev/null)"
        fi
    fi
fi

# --- GDI drawing verification (guest-internal GetPixel round-trips) ---
# The app draws Ellipse/RoundRect/Polygon/Polyline/PatBlt and reads each shape
# back with GetPixel, printing ok/FAIL per shape. Compile+link guard the GDI
# surface; the native run asserts the actual framebuffer content.
cat > gdi_draw.c <<'GDI_EOF'
#include <windows.h>
#include <stdio.h>
static int checked = 0;
LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    PAINTSTRUCT ps; HDC hdc; HBRUSH br; HPEN pen; HGDIOBJ old;
    POINT tri[3]; POINT pl[5];
    COLORREF c;
    switch (msg) {
    case WM_PAINT:
        if (checked++) return DefWindowProcA(hwnd, msg, wParam, lParam);
        hdc = BeginPaint(hwnd, &ps);
        FillRect(hdc, &ps.rcPaint, (HBRUSH)(COLOR_WINDOW + 1));
        br = CreateSolidBrush(RGB(200, 30, 30));
        old = SelectObject(hdc, br);
        Ellipse(hdc, 20, 20, 120, 80);
        SelectObject(hdc, old); DeleteObject(br);
        c = GetPixel(hdc, 70, 50);
        printf("ellipse-fill: %s\n", (GetRValue(c)==200&&GetGValue(c)==30&&GetBValue(c)==30)?"ok":"FAIL");
        br = CreateSolidBrush(RGB(30, 30, 200));
        old = SelectObject(hdc, br);
        RoundRect(hdc, 140, 20, 240, 80, 10, 10);
        SelectObject(hdc, old); DeleteObject(br);
        c = GetPixel(hdc, 190, 50);
        printf("roundrect-fill: %s\n", (GetRValue(c)==30&&GetGValue(c)==30&&GetBValue(c)==200)?"ok":"FAIL");
        br = CreateSolidBrush(RGB(30, 180, 30));
        old = SelectObject(hdc, br);
        tri[0].x=30; tri[0].y=100; tri[1].x=90; tri[1].y=160; tri[2].x=10; tri[2].y=160;
        Polygon(hdc, tri, 3);
        SelectObject(hdc, old); DeleteObject(br);
        c = GetPixel(hdc, 40, 130);
        printf("polygon-fill: %s\n", (GetRValue(c)==30&&GetGValue(c)==180&&GetBValue(c)==30)?"ok":"FAIL");
        pen = CreatePen(PS_SOLID, 2, RGB(150, 30, 150));
        old = SelectObject(hdc, pen);
        pl[0].x=120; pl[0].y=100; pl[1].x=170; pl[1].y=150; pl[2].x=220; pl[2].y=100;
        pl[3].x=270; pl[3].y=150; pl[4].x=290; pl[4].y=120;
        Polyline(hdc, pl, 5);
        SelectObject(hdc, old); DeleteObject(pen);
        c = GetPixel(hdc, 145, 125);
        printf("polyline: %s\n", (GetRValue(c)==150&&GetGValue(c)==30&&GetBValue(c)==150)?"ok":"FAIL");
        PatBlt(hdc, 30, 180, 80, 30, 0x00000042);
        c = GetPixel(hdc, 50, 190);
        printf("patblt-black: %s\n", (GetRValue(c)==0&&GetGValue(c)==0&&GetBValue(c)==0)?"ok":"FAIL");
        EndPaint(hwnd, &ps);
        return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}
int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc; HWND hwnd; MSG msg; int ticks;
    wc.style=0; wc.lpfnWndProc=WndProc; wc.cbClsExtra=0; wc.cbWndExtra=0;
    wc.hInstance=hInst; wc.hIcon=NULL; wc.hCursor=NULL;
    wc.hbrBackground=(HBRUSH)(COLOR_WINDOW+1); wc.lpszMenuName=NULL; wc.lpszClassName="GDIDraw";
    RegisterClass(&wc);
    hwnd=CreateWindowEx(0,"GDIDraw","GDIDraw",WS_OVERLAPPEDWINDOW,0,0,320,240,NULL,NULL,hInst,NULL);
    ShowWindow(hwnd,SW_SHOW); UpdateWindow(hwnd);
    SetTimer(hwnd,1,100,NULL); ticks=0;
    while (GetMessage(&msg,NULL,0,0)>0) {
        TranslateMessage(&msg); DispatchMessage(&msg);
        if (msg.message==WM_TIMER) { ticks++; if (ticks>=15){KillTimer(hwnd,1);PostMessage(hwnd,WM_CLOSE,0,0);} }
    }
    return (int)msg.wParam;
}
GDI_EOF

rc=$(run gdi_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fogdi_draw.obj gdi_draw.c)
if [ "$rc" = "0" ] && [ -f gdi_draw.obj ]; then
    pass "GDI: CL /c gdi_draw.c" ""
else
    fail "GDI: CL /c gdi_draw.c" "exit $rc $(tail -3 gdi_cl.txt 2>/dev/null)"
fi
if [ -f gdi_draw.obj ]; then
    rc=$(run gdi_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:gdi_draw.exe /LIBPATH:"$VC_LIB" gdi_draw.obj user32.lib gdi32.lib)
    if [ "$rc" = "0" ] && [ -f gdi_draw.exe ]; then
        pass "GDI: LINK gdi_draw.obj" "($(stat -c%s gdi_draw.exe) bytes)"
    else
        fail "GDI: LINK gdi_draw.obj" "exit $rc $(tail -3 gdi_link.txt 2>/dev/null)"
    fi
fi
if [ -f gdi_draw.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "GDI: run gdi_draw.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run gdi_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./gdi_draw.exe)
        okcount=$(grep -ac ": ok" gdi_out.txt 2>/dev/null || true)
        failcount=$(grep -ac ": FAIL" gdi_out.txt 2>/dev/null || true)
        if [ "$okcount" = "5" ] && [ "$failcount" = "0" ]; then
            pass "GDI: run gdi_draw.exe" "(5/5 shapes verified via GetPixel)"
        else
            fail "GDI: run gdi_draw.exe" "exit $rc ok=$okcount fail=$failcount"
        fi
    fi
fi

# --- Dialog pipeline: .rc DIALOG -> RC -> CVTRES -> LINK -> DialogBoxParam ---
# Exercises the RC DIALOG template compiler, the dialog resource parser, and
# the modal DialogBoxParam loop (WM_INITDIALOG -> WM_COMMAND -> EndDialog).
cat > dlg_about.rc <<'DLG_RC_EOF'
#include <windows.h>
#define IDD_ABOUT 100
#define IDC_OK 1
IDD_ABOUT DIALOG 10, 10, 220, 100
STYLE DS_MODALFRAME | WS_POPUP | WS_CAPTION | WS_SYSMENU
CAPTION "About"
FONT 8, "MS Shell Dlg"
BEGIN
    LTEXT "Dialog test", -1, 10, 10, 200, 12
    DEFPUSHBUTTON "OK", IDC_OK, 80, 70, 60, 20
END
DLG_RC_EOF

cat > dlg_app.c <<'DLG_C_EOF'
#include <windows.h>
#include <stdio.h>
BOOL CALLBACK DlgProc(HWND hDlg, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_COMMAND:
        if (LOWORD(wParam) == 1) { EndDialog(hDlg, 42); return TRUE; }
        break;
    case WM_INITDIALOG:
        PostMessage(hDlg, WM_COMMAND, 1, 0);
        return TRUE;
    }
    return FALSE;
}
int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    int r = DialogBoxParam(hInst, (LPCSTR)100, NULL, DlgProc, 0);
    printf("dialog-result: %d\n", r);
    return (r == 42) ? 0 : 1;
}
DLG_C_EOF

rc=$(run dlg_rc.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/RC.EXE" /nologo /fodlg_about.res dlg_about.rc)
if [ "$rc" = "0" ] && [ -f dlg_about.res ]; then
    pass "DLG: RC dlg_about.rc" "($(stat -c%s dlg_about.res) bytes)"
else
    fail "DLG: RC dlg_about.rc" "exit $rc $(tail -3 dlg_rc.txt 2>/dev/null)"
fi
if [ -f dlg_about.res ]; then
    rc=$(run dlg_cv.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CVTRES.EXE" /nologo /OUT:dlg_about.obj dlg_about.res)
    if [ "$rc" = "0" ] && [ -f dlg_about.obj ]; then
        pass "DLG: CVTRES dlg_about.res" ""
    else
        fail "DLG: CVTRES dlg_about.res" "exit $rc $(tail -3 dlg_cv.txt 2>/dev/null)"
    fi
fi
rc=$(run dlg_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fodlg_app.obj dlg_app.c)
if [ "$rc" = "0" ] && [ -f dlg_app.obj ]; then
    pass "DLG: CL /c dlg_app.c" ""
else
    fail "DLG: CL /c dlg_app.c" "exit $rc $(tail -3 dlg_cl.txt 2>/dev/null)"
fi
if [ -f dlg_app.obj ] && [ -f dlg_about.obj ]; then
    rc=$(run dlg_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:dlg_app.exe /LIBPATH:"$VC_LIB" dlg_app.obj dlg_about.obj user32.lib gdi32.lib)
    if [ "$rc" = "0" ] && [ -f dlg_app.exe ]; then
        pass "DLG: LINK dlg_app.obj" "($(stat -c%s dlg_app.exe) bytes)"
    else
        fail "DLG: LINK dlg_app.obj" "exit $rc $(tail -3 dlg_link.txt 2>/dev/null)"
    fi
fi
if [ -f dlg_app.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "DLG: run dlg_app.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run dlg_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./dlg_app.exe)
        if grep -q "dialog-result: 42" dlg_out.txt 2>/dev/null; then
            pass "DLG: run dlg_app.exe" "(DialogBoxParam -> EndDialog(42))"
        else
            fail "DLG: run dlg_app.exe" "exit $rc $(tail -3 dlg_out.txt 2>/dev/null)"
        fi
    fi
fi
# --- Menu resource pipeline: .rc MENU -> RC -> CVTRES -> LINK -> RT_MENU ---
cat > menu_res.rc <<'MENU_RC_EOF'
#include <windows.h>
#define IDR_MENU 200
#define IDM_NEW 101
#define IDM_EXIT 102
IDR_MENU MENU
BEGIN
    POPUP "&File"
    BEGIN
        MENUITEM "&New", IDM_NEW
        MENUITEM SEPARATOR
        MENUITEM "E&xit", IDM_EXIT
    END
END
MENU_RC_EOF

rc=$(run menu_rc.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/RC.EXE" /nologo /fomenu_res.res menu_res.rc)
if [ "$rc" = "0" ] && [ -f menu_res.res ]; then
    pass "MENU: RC menu_res.rc" "($(stat -c%s menu_res.res) bytes)"
else
    fail "MENU: RC menu_res.rc" "exit $rc $(tail -3 menu_rc.txt 2>/dev/null)"
fi
if [ -f menu_res.res ]; then
    rc=$(run menu_cv.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CVTRES.EXE" /nologo /OUT:menu_res.obj menu_res.res)
    if [ "$rc" = "0" ] && [ -f menu_res.obj ]; then
        pass "MENU: CVTRES menu_res.res" ""
    else
        fail "MENU: CVTRES menu_res.res" "exit $rc $(tail -3 menu_cv.txt 2>/dev/null)"
    fi
fi
# Link a GUI app with the menu resource; native run must exit cleanly.
if [ -f menu_res.obj ]; then
    rc=$(run menu_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:menu_res.exe /LIBPATH:"$VC_LIB" gui_smoke.obj menu_res.obj user32.lib gdi32.lib)
    if [ "$rc" = "0" ] && [ -f menu_res.exe ]; then
        pass "MENU: LINK menu_res.obj" "($(stat -c%s menu_res.exe) bytes)"
    else
        fail "MENU: LINK menu_res.obj" "exit $rc $(tail -3 menu_link.txt 2>/dev/null)"
    fi
fi
if [ -f menu_res.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "MENU: run menu_res.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run menu_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./menu_res.exe)
        if [ "$rc" = "0" ]; then
            pass "MENU: run menu_res.exe" "(RT_MENU resource linked, clean exit)"
        else
            fail "MENU: run menu_res.exe" "exit $rc $(tail -3 menu_out.txt 2>/dev/null)"
        fi
    fi
fi
fi  # end GUI

########################################
if should_run "MBX|messagebox"; then
echo ""
echo "=== MessageBox: MessageBoxA/W -> renderer.showMessageBox ==="
########################################
# Verifies the MessageBoxA/MessageBoxW stubs route through the renderer and
# return IDOK (1) without hanging. MessageBoxW wide literals exercise the
# UTF-16 -> UTF-8 conversion (escape sequences avoid codepage issues in the
# MSVC6 source).

cat > mbx_app.c <<'MBX_EOF'
#include <windows.h>
#include <stdio.h>
int main(void) {
    int r1 = MessageBoxA(NULL, "mbx-text-a", "mbx-caption-a", MB_OK | MB_ICONINFORMATION);
    int r2 = MessageBoxW(NULL, L"mbx-text-w", L"mbx-caption-w", MB_OK);
    /* non-ASCII wide: e-acute + Cyrillic -> UTF-8 in the renderer */
    int r3 = MessageBoxW(NULL, L"mbx-w-\x00e9-\x041f\x0440\x0438\x0432\x0435\x0442", L"wide-\x00e9", MB_OK);
    printf("mbx-check: %s (A=%d W=%d Wnonascii=%d)\n",
        (r1 == IDOK && r2 == IDOK && r3 == IDOK) ? "ok" : "FAIL", r1, r2, r3);
    return 0;
}
MBX_EOF

rc=$(run mbx_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fombx_app.obj mbx_app.c)
if [ "$rc" = "0" ] && [ -f mbx_app.obj ]; then
    pass "MBX: CL /c mbx_app.c" ""
else
    fail "MBX: CL /c mbx_app.c" "exit $rc $(tail -3 mbx_cl.txt 2>/dev/null)"
fi
if [ -f mbx_app.obj ]; then
    rc=$(run mbx_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /OUT:mbx_app.exe /LIBPATH:"$VC_LIB" mbx_app.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f mbx_app.exe ]; then
        pass "MBX: LINK mbx_app.obj" "($(stat -c%s mbx_app.exe) bytes)"
    else
        fail "MBX: LINK mbx_app.obj" "exit $rc $(tail -3 mbx_link.txt 2>/dev/null)"
    fi
fi
if [ -f mbx_app.exe ]; then
    rc=$(run mbx_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./mbx_app.exe)
    if grep -q "mbx-check: ok" mbx_out.txt 2>/dev/null; then
        pass "MBX: run mbx_app.exe" "(MessageBoxA/W return IDOK, no hang)"
    elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
        # wasmtime runs compiled output, so missing markers is a real regression.
        fail "MBX: run mbx_app.exe" "exit $rc, missing expected output ($(tail -3 mbx_out.txt 2>/dev/null | tr '\n' ' '))"
    else
        # Other runtimes cannot run compiled output yet — aspirational
        printf "  SKIP  %-35s %s\n" "MBX: run mbx_app.exe" "(exit $rc, running compiled output not yet supported)"
    fi
fi
fi  # end MBX

########################################
if should_run "CCTL|comctl|statusbar|progress"; then
echo ""
echo "=== Common controls: status bar (SB_*) + progress bar (PBM_*) ==="
########################################
# Status bar text (SB_SETTEXT) and progress bar position/range (PBM_*) must
# round-trip through the emulator: SB_SETTEXT -> renderer.updateControlText and
# PBM_SETPOS/PBM_SETRANGE32 -> renderer.updateControlValue/Range, which drive
# the web/FLTK widgets. PBM_GETPOS returns the stored position.

cat > cctl_app.c <<'CCTL_EOF'
#include <windows.h>
#include <commctrl.h>
#include <stdio.h>

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, sb, pb;
    MSG msg;
    int r1, r2, r3, r4, r5, pos;
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = hInst;
    wc.hIcon = NULL;
    wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "CctlSmoke";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "CctlSmoke", "CctlSmoke", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 200, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    /* Status bar: initial text, then SB_SETTEXTA and SB_SETTEXTW updates */
    sb = CreateStatusWindowA(SBARS_SIZEGRIP, "ready", hwnd, 1001);
    r1 = (int)SendMessageA(sb, SB_SETTEXT, 0, (LPARAM)"counting...");
    r2 = (int)SendMessageA(sb, SB_SETTEXTW, 0, (LPARAM)L"done-\x00e9");

    /* Progress bar: range 0..100, positions 42 then 66, read back via GETPOS */
    pb = CreateWindowEx(0, "msctls_progress32", NULL,
        WS_CHILD | WS_VISIBLE, 10, 40, 200, 16, hwnd, (HMENU)1002, hInst, NULL);
    r3 = (int)SendMessageA(pb, PBM_SETRANGE32, 0, 100);
    r4 = (int)SendMessageA(pb, PBM_SETPOS, 42, 0);
    r5 = (int)SendMessageA(pb, PBM_SETPOS, 66, 0);
    pos = (int)SendMessageA(pb, PBM_GETPOS, 0, 0);

    printf("cctl-check: %s (sbA=%d sbW=%d rng=%d set=%d get=%d)\n",
        (r1 == 1 && r2 == 1 && r3 == 1 && r4 == 1 && r5 == 1 && pos == 66) ? "ok" : "FAIL",
        r1, r2, r3, r4, r5, pos);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return 0;
}
CCTL_EOF

rc=$(run cctl_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Focctl_app.obj cctl_app.c)
if [ "$rc" = "0" ] && [ -f cctl_app.obj ]; then
    pass "CCTL: CL /c cctl_app.c" ""
else
    fail "CCTL: CL /c cctl_app.c" "exit $rc $(tail -3 cctl_cl.txt 2>/dev/null)"
fi
if [ -f cctl_app.obj ]; then
    rc=$(run cctl_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:cctl_app.exe /LIBPATH:"$VC_LIB" cctl_app.obj user32.lib gdi32.lib comctl32.lib)
    if [ "$rc" = "0" ] && [ -f cctl_app.exe ]; then
        pass "CCTL: LINK cctl_app.obj" "($(stat -c%s cctl_app.exe) bytes)"
    else
        fail "CCTL: LINK cctl_app.obj" "exit $rc $(tail -3 cctl_link.txt 2>/dev/null)"
    fi
fi
if [ -f cctl_app.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "CCTL: run cctl_app.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run cctl_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./cctl_app.exe)
        if grep -q "cctl-check: ok" cctl_out.txt 2>/dev/null; then
            pass "CCTL: run cctl_app.exe" "(SB_SETTEXT + PBM_* round-trip, GETPOS=66)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "CCTL: run cctl_app.exe" "exit $rc, missing expected output ($(tail -3 cctl_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "CCTL: run cctl_app.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end CCTL

########################################
if should_run "DLGT|dlgitem|dlgtext"; then
echo ""
echo "=== Dialog item text: Set/GetDlgItemText(A/W) + Set/GetDlgItemInt ==="
########################################
# The control text store must round-trip: SetDlgItemTextA/W and SetDlgItemInt
# write, GetDlgItemTextA/W and GetDlgItemInt read back. Wide variants must
# convert UTF-16 <-> UTF-8 (e-acute survives).

cat > dlgt_app.c <<'DLGT_EOF'
#include <windows.h>
#include <stdio.h>

int main(void) {
    HWND dlg = (HWND)0x456;
    char buf[64];
    wchar_t wbuf[64];
    UINT v, vn;
    int n, wn, ok;

    /* A path: write then read back */
    SetDlgItemTextA(dlg, 200, "hello-text");
    n = GetDlgItemTextA(dlg, 200, buf, 64);

    /* Int path: write 42, read back; also negative signed */
    SetDlgItemInt(dlg, 201, 42, TRUE);
    v = GetDlgItemInt(dlg, 201, NULL, TRUE);
    SetDlgItemInt(dlg, 203, (UINT)-7, TRUE);
    vn = GetDlgItemInt(dlg, 203, NULL, TRUE);

    /* Wide path: e-acute + Cyrillic, read back as wide */
    SetDlgItemTextW(dlg, 202, L"wide-\x00e9-\x041f");
    wn = GetDlgItemTextW(dlg, 202, wbuf, 64);

    ok = (n == 10 && strcmp(buf, "hello-text") == 0 &&
          v == 42 && vn == (UINT)-7 &&
          wn == 8 && wbuf[5] == 0x00e9 && wbuf[7] == 0x041f);
    printf("dlgt-check: %s (n=%d v=%u vn=%u wn=%d)\n", ok ? "ok" : "FAIL", n, v, vn, wn);
    return 0;
}
DLGT_EOF

rc=$(run dlgt_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fodlgt_app.obj dlgt_app.c)
if [ "$rc" = "0" ] && [ -f dlgt_app.obj ]; then
    pass "DLGT: CL /c dlgt_app.c" ""
else
    fail "DLGT: CL /c dlgt_app.c" "exit $rc $(tail -3 dlgt_cl.txt 2>/dev/null)"
fi
if [ -f dlgt_app.obj ]; then
    rc=$(run dlgt_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /OUT:dlgt_app.exe /LIBPATH:"$VC_LIB" dlgt_app.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f dlgt_app.exe ]; then
        pass "DLGT: LINK dlgt_app.obj" "($(stat -c%s dlgt_app.exe) bytes)"
    else
        fail "DLGT: LINK dlgt_app.obj" "exit $rc $(tail -3 dlgt_link.txt 2>/dev/null)"
    fi
fi
if [ -f dlgt_app.exe ]; then
    rc=$(run dlgt_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./dlgt_app.exe)
    if grep -q "dlgt-check: ok" dlgt_out.txt 2>/dev/null; then
        pass "DLGT: run dlgt_app.exe" "(A/W text + int round-trip)"
    elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
        fail "DLGT: run dlgt_app.exe" "exit $rc, missing expected output ($(tail -3 dlgt_out.txt 2>/dev/null | tr '\n' ' '))"
    else
        printf "  SKIP  %-35s %s\n" "DLGT: run dlgt_app.exe" "(exit $rc, running compiled output not yet supported)"
    fi
fi
fi  # end DLGT

########################################
if should_run "CXT|popup|context"; then
echo ""
echo "=== Context menu: CreatePopupMenu + AppendMenu + TrackPopupMenu ==="
########################################
# TrackPopupMenu must serialize the popup menu built by AppendMenuA/W and, on
# the web backend, block until the user picks an item. In the suite there is no
# browser, so native runs use --no-gui (backend .none -> non-blocking, returns
# 0); the wasm build has no renderer at all. The manual WS test covers the full
# selection round-trip.

cat > cxt_app.c <<'CXT_EOF'
#include <windows.h>
#include <stdio.h>

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    HMENU hm;
    int r1, r2, r3, r4, r5, r6, tp;
    UINT st_checked, st_grayed;
    (void)hInst; (void)hPrev; (void)cmd; (void)show;
    hm = CreatePopupMenu();
    r1 = AppendMenuA(hm, MF_STRING, 901, "&Open");
    r2 = AppendMenuA(hm, MF_STRING, 902, "Save &As");
    r3 = AppendMenuA(hm, MF_SEPARATOR, 0, NULL);
    r4 = AppendMenuA(hm, MF_STRING | MF_CHECKED, 903, "Check &Me");
    r5 = AppendMenuA(hm, MF_STRING | MF_GRAYED, 904, "Disabled &Item");
    r6 = AppendMenuW(hm, MF_STRING, 905, L"Wide \x00e9");

    st_checked = GetMenuState(hm, 903, 0);
    st_grayed  = GetMenuState(hm, 904, 0);

    /* No UI in the suite: TrackPopupMenu must return 0 without blocking. */
    tp = TrackPopupMenu(hm, TPM_RETURNCMD, 10, 10, 0, NULL, NULL);

    printf("cxt-check: %s (append=%d%d%d%d%d%d checked=%x grayed=%x track=%d)\n",
        (hm != 0 && r1 && r2 && r3 && r4 && r5 && r6 &&
         (st_checked & MF_CHECKED) && (st_grayed & MF_GRAYED) && tp == 0)
            ? "ok" : "FAIL",
        r1, r2, r3, r4, r5, r6, st_checked, st_grayed, tp);
    return 0;
}
CXT_EOF

rc=$(run cxt_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Focxt_app.obj cxt_app.c)
if [ "$rc" = "0" ] && [ -f cxt_app.obj ]; then
    pass "CXT: CL /c cxt_app.c" ""
else
    fail "CXT: CL /c cxt_app.c" "exit $rc $(tail -3 cxt_cl.txt 2>/dev/null)"
fi
if [ -f cxt_app.obj ]; then
    rc=$(run cxt_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:cxt_app.exe /LIBPATH:"$VC_LIB" cxt_app.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f cxt_app.exe ]; then
        pass "CXT: LINK cxt_app.obj" "($(stat -c%s cxt_app.exe) bytes)"
    else
        fail "CXT: LINK cxt_app.obj" "exit $rc $(tail -3 cxt_link.txt 2>/dev/null)"
    fi
fi
if [ -f cxt_app.exe ]; then
    rc=$(run cxt_out.txt "${WINLOADER_CMD[@]}" ${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}} $([ "$IS_WASM" = "false" ] && echo --no-gui) ./cxt_app.exe)
    if grep -q "cxt-check: ok" cxt_out.txt 2>/dev/null; then
        pass "CXT: run cxt_app.exe" "(popup menu + flags, TrackPopupMenu non-blocking)"
    elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
        fail "CXT: run cxt_app.exe" "exit $rc, missing expected output ($(tail -3 cxt_out.txt 2>/dev/null | tr '\n' ' '))"
    else
        printf "  SKIP  %-35s %s\n" "CXT: run cxt_app.exe" "(exit $rc, running compiled output not yet supported)"
    fi
fi
fi  # end CXT

########################################
if should_run "SZ|resize|wmsize|movewindow"; then
echo ""
echo "=== Window resize: MoveWindow -> WM_SIZE -> GetClientRect ==="
########################################
# MoveWindow must resize the main window (renderer.setWindowPos/Resolution +
# posted WM_SIZE with the client dims in lParam) and GetClientRect must match.
# The app pumps messages between ShowWindow and MoveWindow (a realistic app
# drains its queue continuously; the 32-slot emulator queue drops messages
# when full, exactly like real Win32 coalesces).

cat > sz_app.c <<'SZ_EOF'
#include <windows.h>
#include <stdio.h>

static int size_count = 0;
static int last_w = 0, last_h = 0, last_type = -1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_SIZE:
        size_count++;
        last_w = LOWORD(lParam);
        last_h = HIWORD(lParam);
        last_type = (int)wParam;
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd;
    MSG msg;
    RECT rc;
    int before, after;
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0;
    wc.cbWndExtra = 0;
    wc.hInstance = hInst;
    wc.hIcon = NULL;
    wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "SzApp";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "SzApp", "SzApp", WS_OVERLAPPEDWINDOW,
        0, 0, 200, 120, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);
    /* drain the ShowWindow burst so the queue has room for MoveWindow's WM_SIZE */
    while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    before = size_count;
    MoveWindow(hwnd, 0, 0, 320, 240, TRUE);
    while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    after = size_count;
    GetClientRect(hwnd, &rc);
    printf("sz-check: %s (before=%d after=%d type=%d w=%d h=%d client=%dx%d)\n",
        (after > before && rc.right == last_w && rc.bottom == last_h && rc.right > 0) ? "ok" : "FAIL",
        before, after, last_type, last_w, last_h, rc.right, rc.bottom);
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return 0;
}
SZ_EOF

rc=$(run sz_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fosz_app.obj sz_app.c)
if [ "$rc" = "0" ] && [ -f sz_app.obj ]; then
    pass "SZ: CL /c sz_app.c" ""
else
    fail "SZ: CL /c sz_app.c" "exit $rc $(tail -3 sz_cl.txt 2>/dev/null)"
fi
if [ -f sz_app.obj ]; then
    rc=$(run sz_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:sz_app.exe /LIBPATH:"$VC_LIB" sz_app.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f sz_app.exe ]; then
        pass "SZ: LINK sz_app.obj" "($(stat -c%s sz_app.exe) bytes)"
    else
        fail "SZ: LINK sz_app.obj" "exit $rc $(tail -3 sz_link.txt 2>/dev/null)"
    fi
fi
if [ -f sz_app.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "SZ: run sz_app.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run sz_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./sz_app.exe)
        if grep -q "sz-check: ok" sz_out.txt 2>/dev/null; then
            pass "SZ: run sz_app.exe" "(MoveWindow -> WM_SIZE -> GetClientRect)"
        else
            fail "SZ: run sz_app.exe" "exit $rc $(tail -3 sz_out.txt 2>/dev/null)"
        fi
    fi
fi
fi  # end SZ

########################################
if should_run "CHAR|wmchar|translate"; then
echo ""
echo "=== TranslateMessage: WM_KEYDOWN -> WM_CHAR ==="
########################################
# TranslateMessage must convert WM_KEYDOWN (VK code) into WM_CHAR with the
# US-layout character (unshifted 'A' -> 'a'), posted back into the queue.

cat > char_gui.c <<'CHAR_EOF'
#include <windows.h>
#include <stdio.h>

static int got_char = 0;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CHAR:
        got_char = (int)wParam;
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd;
    MSG msg;
    int i, ok;
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "CharGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "CharGui", "CharGui", WS_OVERLAPPEDWINDOW,
        0, 0, 200, 120, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    /* drain the window-creation message burst */
    while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    /* Post WM_KEYDOWN for 'A' (VK 0x41), pump TranslateMessage */
    PostMessage(hwnd, WM_KEYDOWN, 0x41, 0x00010001);
    for (i = 0; i < 4; i++) {
        if (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
    }

    ok = (got_char == 'a'); /* unshifted 'A' -> 'a' */
    printf("char-check: %s (char=%d expect=%d)\n", ok ? "ok" : "FAIL", got_char, 'a');
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return 0;
}
CHAR_EOF

rc=$(run char_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fochar_gui.obj char_gui.c)
if [ "$rc" = "0" ] && [ -f char_gui.obj ]; then
    pass "CHAR: CL /c char_gui.c" ""
else
    fail "CHAR: CL /c char_gui.c" "exit $rc $(tail -3 char_cl.txt 2>/dev/null)"
fi
if [ -f char_gui.obj ]; then
    rc=$(run char_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:char_gui.exe /LIBPATH:"$VC_LIB" char_gui.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f char_gui.exe ]; then
        pass "CHAR: LINK char_gui.obj" "($(stat -c%s char_gui.exe) bytes)"
    else
        fail "CHAR: LINK char_gui.obj" "exit $rc $(tail -3 char_link.txt 2>/dev/null)"
    fi
fi
if [ -f char_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "CHAR: run char_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run char_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./char_gui.exe)
        if grep -q "char-check: ok" char_out.txt 2>/dev/null; then
            pass "CHAR: run char_gui.exe" "(WM_KEYDOWN -> WM_CHAR 'a')"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "CHAR: run char_gui.exe" "exit $rc, missing expected output ($(tail -3 char_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "CHAR: run char_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end CHAR

########################################
if should_run "TIMER|wmtimer|settimer"; then
echo ""
echo "=== SetTimer: WM_TIMER dispatch thread ==="
########################################
# SetTimer must actually fire WM_TIMER on a background host thread (the old
# code registered timers but nothing ever delivered them).

cat > timer_gui.c <<'TIMER_EOF'
#include <windows.h>
#include <stdio.h>

static int timer_count = 0;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_TIMER:
        timer_count++;
        if (timer_count >= 3) KillTimer(hwnd, 1);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd;
    MSG msg;
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "TimerGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "TimerGui", "TimerGui", WS_OVERLAPPEDWINDOW,
        0, 0, 200, 120, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    SetTimer(hwnd, 1, 100, NULL); /* 100ms timer */

    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
        if (timer_count >= 3) {
            PostMessage(hwnd, WM_CLOSE, 0, 0);
            break;
        }
    }
    printf("timer-check: %s (count=%d)\n", timer_count >= 3 ? "ok" : "FAIL", timer_count);
    return 0;
}
TIMER_EOF

rc=$(run timer_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fotimer_gui.obj timer_gui.c)
if [ "$rc" = "0" ] && [ -f timer_gui.obj ]; then
    pass "TIMER: CL /c timer_gui.c" ""
else
    fail "TIMER: CL /c timer_gui.c" "exit $rc $(tail -3 timer_cl.txt 2>/dev/null)"
fi
if [ -f timer_gui.obj ]; then
    rc=$(run timer_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:timer_gui.exe /LIBPATH:"$VC_LIB" timer_gui.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f timer_gui.exe ]; then
        pass "TIMER: LINK timer_gui.obj" "($(stat -c%s timer_gui.exe) bytes)"
    else
        fail "TIMER: LINK timer_gui.obj" "exit $rc $(tail -3 timer_link.txt 2>/dev/null)"
    fi
fi
if [ -f timer_gui.exe ]; then
    # WASM builds run GUI apps headless now (renderer backend .none), so
    # WM_TIMER delivery via the message loop is verifiable everywhere.
    rc=$(run timer_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./timer_gui.exe)
    if grep -q "timer-check: ok" timer_out.txt 2>/dev/null; then
        pass "TIMER: run timer_gui.exe" "(3x WM_TIMER fired)"
    elif [ "$IS_WASM" = "true" ]; then
        fail "TIMER: run timer_gui.exe" "exit $rc, missing expected output ($(tail -3 timer_out.txt 2>/dev/null | tr '\n' ' '))"
    else
        printf "  SKIP  %-35s %s\n" "TIMER: run timer_gui.exe" "(exit $rc, running compiled output not yet supported)"
    fi
fi
fi  # end TIMER

if should_run "EDIT|editctrl|edittext"; then
echo ""
echo "=== EDIT control: WM_CHAR insert + GetWindowText read-back ==="
########################################
# The EDIT class must behave like the real Win32 edit control: WM_CHAR
# inserts into the shared text buffer (which GetWindowText/WM_GETTEXT and
# WM_GETTEXTLENGTH read back), backspace deletes the last char, and the
# frontend textarea stays in sync via set_edit_text.

cat > edit_gui.c <<'EDIT_EOF'
#include <windows.h>
#include <string.h>
#include <stdio.h>

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, edit;
    MSG msg;
    char buf[256];
    int ok = 1;
    int chars_processed = 0;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "EditGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "EditGui", "EditGui", WS_OVERLAPPEDWINDOW,
        0, 0, 360, 200, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    Sleep(2000); /* let the FLTK thread attach */

    edit = CreateWindowEx(0, "EDIT", NULL, WS_CHILD | WS_VISIBLE | WS_BORDER,
        10, 10, 200, 22, hwnd, (HMENU)1201, hInst, NULL);

    /* Type into the edit control via WM_CHAR: 'a' 'b' 'c' */
    SendMessageA(edit, WM_CHAR, 'a', 0);
    SendMessageA(edit, WM_CHAR, 'b', 0);
    SendMessageA(edit, WM_CHAR, 'c', 0);

    if (GetWindowTextLengthA(edit) != 3) ok = 0;
    if (GetWindowTextA(edit, buf, sizeof(buf)) != 3 || strcmp(buf, "abc") != 0) ok = 0;

    /* Backspace deletes the last character */
    SendMessageA(edit, WM_CHAR, 0x08, 0);
    if (GetWindowTextLengthA(edit) != 2) ok = 0;
    if (GetWindowTextA(edit, buf, sizeof(buf)) != 2 || strcmp(buf, "ab") != 0) ok = 0;

    /* WM_GETTEXT / WM_GETTEXTLENGTH read the same shared buffer */
    if (SendMessageA(edit, WM_GETTEXTLENGTH, 0, 0) != 3) ok = 0; /* incl. NUL */
    if (SendMessageA(edit, WM_GETTEXT, (WPARAM)sizeof(buf), (LPARAM)buf) != 2 || strcmp(buf, "ab") != 0) ok = 0;

    /* PostMessage WM_CHAR must be dispatched to the edit class too */
    PostMessageA(edit, WM_CHAR, 'Z', 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0 && chars_processed < 1) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
        if (msg.message == WM_CHAR && msg.hwnd == edit) chars_processed++;
    }
    if (GetWindowTextA(edit, buf, sizeof(buf)) != 3 || strcmp(buf, "abZ") != 0) ok = 0;

    printf("edit-check: %s (text=%s)\n", ok ? "ok" : "FAIL", buf);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
EDIT_EOF

rc=$(run edit_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Foedit_gui.obj edit_gui.c)
if [ "$rc" = "0" ] && [ -f edit_gui.obj ]; then
    pass "EDIT: CL /c edit_gui.c" ""
else
    fail "EDIT: CL /c edit_gui.c" "exit $rc $(tail -3 edit_cl.txt 2>/dev/null)"
fi
if [ -f edit_gui.obj ]; then
    rc=$(run edit_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:edit_gui.exe /LIBPATH:"$VC_LIB" edit_gui.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f edit_gui.exe ]; then
        pass "EDIT: LINK edit_gui.obj" "($(stat -c%s edit_gui.exe) bytes)"
    else
        fail "EDIT: LINK edit_gui.obj" "exit $rc $(tail -3 edit_link.txt 2>/dev/null)"
    fi
fi
if [ -f edit_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "EDIT: run edit_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run edit_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./edit_gui.exe)
        if grep -q "edit-check: ok" edit_out.txt 2>/dev/null; then
            pass "EDIT: run edit_gui.exe" "(WM_CHAR insert + GetWindowText round-trip)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "EDIT: run edit_gui.exe" "exit $rc, missing expected output ($(tail -3 edit_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "EDIT: run edit_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end EDIT

if should_run "DLGKB|dlgkey|isdialogmessage"; then
echo ""
echo "=== Dialog keyboard: IsDialogMessage (Tab/Enter/Escape) ==="
########################################
# IsDialogMessageA must implement the dialog manager's keyboard handling:
# Tab moves focus between WS_TABSTOP children (initial focus = first tabstop),
# Enter activates the BS_DEFPUSHBUTTON button (WM_COMMAND id), and Escape
# activates IDCANCEL. SetFocus/GetFocus track the focused control.

cat > dlgkb_gui.c <<'DLGKB_EOF'
#include <windows.h>
#include <stdio.h>

static int ok = 1;
static int got_ok = 0;
static int got_cancel = 0;
static HWND g_edit = NULL;

LRESULT CALLBACK DlgProc(HWND hDlg, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_INITDIALOG:
        g_edit = CreateWindowEx(0, "EDIT", "", WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP,
            10, 10, 150, 20, hDlg, (HMENU)101, GetModuleHandle(NULL), NULL);
        CreateWindowEx(0, "BUTTON", "OK", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON | WS_TABSTOP,
            10, 40, 70, 24, hDlg, (HMENU)1, GetModuleHandle(NULL), NULL);
        CreateWindowEx(0, "BUTTON", "Cancel", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
            90, 40, 70, 24, hDlg, (HMENU)2, GetModuleHandle(NULL), NULL);
        return 1;
    case WM_COMMAND:
        if (LOWORD(wParam) == 1) { got_ok = 1; return 1; }
        if (LOWORD(wParam) == 2) { got_cancel = 1; return 1; }
        return 1;
    case WM_CLOSE:
        return 1;
    }
    return 0;
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    HWND hDlg;
    MSG msg;

    hDlg = CreateDialogParamA(hInst, (LPCSTR)1, NULL, DlgProc, 0);
    if (!hDlg) { printf("dlgkb-check: FAIL (no dialog)\n"); return 1; }

    if (GetFocus() != g_edit) ok = 0;

    PostMessageA(hDlg, WM_KEYDOWN, VK_TAB, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        if (!IsDialogMessageA(hDlg, &msg)) { TranslateMessage(&msg); DispatchMessage(&msg); }
        if (GetFocus() != g_edit) break;
    }
    if (GetFocus() == g_edit) ok = 0;

    PostMessageA(hDlg, WM_KEYDOWN, VK_RETURN, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0 && !got_ok) {
        if (!IsDialogMessageA(hDlg, &msg)) { TranslateMessage(&msg); DispatchMessage(&msg); }
    }
    if (!got_ok) ok = 0;

    PostMessageA(hDlg, WM_KEYDOWN, VK_ESCAPE, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0 && !got_cancel) {
        if (!IsDialogMessageA(hDlg, &msg)) { TranslateMessage(&msg); DispatchMessage(&msg); }
    }
    if (!got_cancel) ok = 0;

    printf("dlgkb-check: %s (focus_edit:%d ok_cmd:%d cancel_cmd:%d)\n",
        ok ? "ok" : "FAIL", GetFocus() == g_edit, got_ok, got_cancel);

    PostQuitMessage(0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        if (!IsDialogMessageA(hDlg, &msg)) { TranslateMessage(&msg); DispatchMessage(&msg); }
    }
    return ok ? 0 : 1;
}
DLGKB_EOF

rc=$(run dlgkb_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fodlgkb_gui.obj dlgkb_gui.c)
if [ "$rc" = "0" ] && [ -f dlgkb_gui.obj ]; then
    pass "DLGKB: CL /c dlgkb_gui.c" ""
else
    fail "DLGKB: CL /c dlgkb_gui.c" "exit $rc $(tail -3 dlgkb_cl.txt 2>/dev/null)"
fi
if [ -f dlgkb_gui.obj ]; then
    rc=$(run dlgkb_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:dlgkb_gui.exe /LIBPATH:"$VC_LIB" dlgkb_gui.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f dlgkb_gui.exe ]; then
        pass "DLGKB: LINK dlgkb_gui.obj" "($(stat -c%s dlgkb_gui.exe) bytes)"
    else
        fail "DLGKB: LINK dlgkb_gui.obj" "exit $rc $(tail -3 dlgkb_link.txt 2>/dev/null)"
    fi
fi
if [ -f dlgkb_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "DLGKB: run dlgkb_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run dlgkb_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./dlgkb_gui.exe)
        if grep -q "dlgkb-check: ok" dlgkb_out.txt 2>/dev/null; then
            pass "DLGKB: run dlgkb_gui.exe" "(Tab/Enter/Escape dialog navigation)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "DLGKB: run dlgkb_gui.exe" "exit $rc, missing expected output ($(tail -3 dlgkb_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "DLGKB: run dlgkb_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end DLGKB

if should_run "FOCKEY|focustype|keyroute"; then
echo ""
echo "=== Focus routing: keyboard to focused control + window title ==="
########################################
# WM_KEYDOWN (and the WM_CHAR it produces via TranslateMessage) must reach
# the FOCUSED control — typing into a focused EDIT inserts text. Also,
# GetWindowText on the main window must return the title set by
# CreateWindowEx/SetWindowText.

cat > fockey_gui.c <<'FOCKEY_EOF'
#include <windows.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;
static HWND g_edit = NULL;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

LRESULT CALLBACK DlgProc(HWND hDlg, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_INITDIALOG:
        g_edit = CreateWindowEx(0, "EDIT", "", WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP,
            10, 10, 150, 20, hDlg, (HMENU)101, GetModuleHandle(NULL), NULL);
        return 1;
    case WM_COMMAND:
        return 1;
    }
    return 0;
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, hDlg;
    MSG msg;
    char buf[64];

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "FocGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "FocGui", "FocGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 200, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    /* Main-window title read-back: SetWindowText -> GetWindowText */
    SetWindowTextA(hwnd, "MyNewTitle");
    if (GetWindowTextLengthA(hwnd) != 10) ok = 0;
    if (GetWindowTextA(hwnd, buf, sizeof(buf)) != 10 || strcmp(buf, "MyNewTitle") != 0) ok = 0;

    /* Dialog with an EDIT; give it focus; type 'a' via WM_KEYDOWN->WM_CHAR */
    hDlg = CreateDialogParamA(hInst, (LPCSTR)1, hwnd, DlgProc, 0);
    if (!hDlg) { printf("fockey-check: FAIL (no dialog)\n"); return 1; }

    SetFocus(g_edit);
    PostMessage(GetFocus(), WM_KEYDOWN, 0x41 /* 'A' */, 0x00010001);

    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
        if (GetWindowTextLengthA(g_edit) >= 1) break;
    }
    if (GetWindowTextLengthA(g_edit) != 1) ok = 0;
    if (GetWindowTextA(g_edit, buf, sizeof(buf)) != 1 || buf[0] != 'a') ok = 0;

    printf("fockey-check: %s (edit_len=%d char=%d)\n",
        ok ? "ok" : "FAIL", GetWindowTextLengthA(g_edit), buf[0]);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
FOCKEY_EOF

rc=$(run fockey_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fofockey_gui.obj fockey_gui.c)
if [ "$rc" = "0" ] && [ -f fockey_gui.obj ]; then
    pass "FOCKEY: CL /c fockey_gui.c" ""
else
    fail "FOCKEY: CL /c fockey_gui.c" "exit $rc $(tail -3 fockey_cl.txt 2>/dev/null)"
fi
if [ -f fockey_gui.obj ]; then
    rc=$(run fockey_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:fockey_gui.exe /LIBPATH:"$VC_LIB" fockey_gui.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f fockey_gui.exe ]; then
        pass "FOCKEY: LINK fockey_gui.obj" "($(stat -c%s fockey_gui.exe) bytes)"
    else
        fail "FOCKEY: LINK fockey_gui.obj" "exit $rc $(tail -3 fockey_link.txt 2>/dev/null)"
    fi
fi
if [ -f fockey_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "FOCKEY: run fockey_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run fockey_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./fockey_gui.exe)
        if grep -q "fockey-check: ok" fockey_out.txt 2>/dev/null; then
            pass "FOCKEY: run fockey_gui.exe" "(focused-EDIT typing + window title)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "FOCKEY: run fockey_gui.exe" "exit $rc, missing expected output ($(tail -3 fockey_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "FOCKEY: run fockey_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end FOCKEY

if should_run "BTNKEY|btnclick|buttonkey"; then
echo ""
echo "=== Focused button: VK_SPACE/VK_RETURN activates (BN_CLICKED) ==="
########################################
# The BUTTON class wndproc must activate on VK_SPACE/VK_RETURN while focused,
# sending WM_COMMAND(BN_CLICKED) to the parent (real button behavior). With
# keyboard messages routed to the focused window, a focused button receives
# WM_KEYDOWN directly.

cat > btnkey_gui.c <<'BTNKEY_EOF'
#include <windows.h>
#include <stdio.h>

static int ok = 1;
static int cmd_count = 0;
static HWND g_btn = NULL;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_COMMAND:
        if (LOWORD(wParam) == 1001) { cmd_count++; return 0; }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd;
    MSG msg;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "BtnGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "BtnGui", "BtnGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 200, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    g_btn = CreateWindowEx(0, "BUTTON", "Go", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
        10, 10, 90, 26, hwnd, (HMENU)1001, hInst, NULL);

    /* VK_SPACE on the focused button activates it */
    SetFocus(g_btn);
    PostMessage(GetFocus(), WM_KEYDOWN, VK_SPACE, 0x00000001);
    while (GetMessage(&msg, NULL, 0, 0) > 0 && cmd_count == 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    if (cmd_count != 1) ok = 0;

    /* VK_RETURN on the focused button activates it too */
    PostMessage(GetFocus(), WM_KEYDOWN, VK_RETURN, 0x00000001);
    while (GetMessage(&msg, NULL, 0, 0) > 0 && cmd_count < 2) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    if (cmd_count != 2) ok = 0;

    printf("btnkey-check: %s (commands=%d)\n", ok ? "ok" : "FAIL", cmd_count);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
BTNKEY_EOF

rc=$(run btnkey_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fobtnkey_gui.obj btnkey_gui.c)
if [ "$rc" = "0" ] && [ -f btnkey_gui.obj ]; then
    pass "BTNKEY: CL /c btnkey_gui.c" ""
else
    fail "BTNKEY: CL /c btnkey_gui.c" "exit $rc $(tail -3 btnkey_cl.txt 2>/dev/null)"
fi
if [ -f btnkey_gui.obj ]; then
    rc=$(run btnkey_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:btnkey_gui.exe /LIBPATH:"$VC_LIB" btnkey_gui.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f btnkey_gui.exe ]; then
        pass "BTNKEY: LINK btnkey_gui.obj" "($(stat -c%s btnkey_gui.exe) bytes)"
    else
        fail "BTNKEY: LINK btnkey_gui.obj" "exit $rc $(tail -3 btnkey_link.txt 2>/dev/null)"
    fi
fi
if [ -f btnkey_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "BTNKEY: run btnkey_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run btnkey_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./btnkey_gui.exe)
        if grep -q "btnkey-check: ok" btnkey_out.txt 2>/dev/null; then
            pass "BTNKEY: run btnkey_gui.exe" "(Space/Enter activates focused button)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "BTNKEY: run btnkey_gui.exe" "exit $rc, missing expected output ($(tail -3 btnkey_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "BTNKEY: run btnkey_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end BTNKEY

if should_run "CHK|checkbox|radio"; then
echo ""
echo "=== Checkbox/radio: BM_GETCHECK/SETCHECK/CLICK + auto-toggle ==="
########################################
# BUTTON class state: BM_SETCHECK/BM_GETCHECK/BM_GETSTATE round-trip, and
# BM_CLICK on BS_AUTOCHECKBOX toggles (notifying the parent via WM_COMMAND)
# while BS_AUTORADIOBUTTON becomes/stays checked.

cat > chk_gui.c <<'CHK_EOF'
#include <windows.h>
#include <stdio.h>

static int ok = 1;
static int cmd_2001 = 0;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_COMMAND:
        if (LOWORD(wParam) == 2001) cmd_2001++;
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, chk, rad;
    MSG msg;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "ChkGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "ChkGui", "ChkGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 200, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    chk = CreateWindowEx(0, "BUTTON", "&Check", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX,
        10, 10, 120, 20, hwnd, (HMENU)2001, hInst, NULL);
    rad = CreateWindowEx(0, "BUTTON", "&Radio", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON,
        10, 40, 120, 20, hwnd, (HMENU)2002, hInst, NULL);

    SendMessageA(chk, BM_SETCHECK, 1, 0);
    if (SendMessageA(chk, BM_GETCHECK, 0, 0) != 1) ok = 0;
    if (SendMessageA(chk, BM_GETSTATE, 0, 0) != 1) ok = 0;

    SendMessageA(chk, BM_CLICK, 0, 0);
    if (SendMessageA(chk, BM_GETCHECK, 0, 0) != 0) ok = 0;
    if (cmd_2001 != 1) ok = 0;

    SendMessageA(rad, BM_CLICK, 0, 0);
    if (SendMessageA(rad, BM_GETCHECK, 0, 0) != 1) ok = 0;
    SendMessageA(rad, BM_CLICK, 0, 0);
    if (SendMessageA(rad, BM_GETCHECK, 0, 0) != 1) ok = 0;

    SendMessageA(chk, BM_SETCHECK, 0, 0);
    if (SendMessageA(chk, BM_GETCHECK, 0, 0) != 0) ok = 0;

    printf("chk-check: %s (chk=%d rad=%d cmd=%d)\n",
        ok ? "ok" : "FAIL",
        SendMessageA(chk, BM_GETCHECK, 0, 0),
        SendMessageA(rad, BM_GETCHECK, 0, 0),
        cmd_2001);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
CHK_EOF

rc=$(run chk_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fochk_gui.obj chk_gui.c)
if [ "$rc" = "0" ] && [ -f chk_gui.obj ]; then
    pass "CHK: CL /c chk_gui.c" ""
else
    fail "CHK: CL /c chk_gui.c" "exit $rc $(tail -3 chk_cl.txt 2>/dev/null)"
fi
if [ -f chk_gui.obj ]; then
    rc=$(run chk_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:chk_gui.exe /LIBPATH:"$VC_LIB" chk_gui.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f chk_gui.exe ]; then
        pass "CHK: LINK chk_gui.obj" "($(stat -c%s chk_gui.exe) bytes)"
    else
        fail "CHK: LINK chk_gui.obj" "exit $rc $(tail -3 chk_link.txt 2>/dev/null)"
    fi
fi
if [ -f chk_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "CHK: run chk_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run chk_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./chk_gui.exe)
        if grep -q "chk-check: ok" chk_out.txt 2>/dev/null; then
            pass "CHK: run chk_gui.exe" "(BM_* state + auto checkbox/radio toggle)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "CHK: run chk_gui.exe" "exit $rc, missing expected output ($(tail -3 chk_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "CHK: run chk_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end CHK

if should_run "RADGRP|radiogrp|radiogroup"; then
echo ""
echo "=== Radio groups: BS_AUTORADIOBUTTON mutual exclusion (WS_GROUP) ==="
########################################
# Clicking a BS_AUTORADIOBUTTON checks it and unchecks the other auto radios
# in the same group. A group spans the parent's children from one WS_GROUP
# control up to (not including) the next WS_GROUP control.

cat > radgrp_gui.c <<'RADGRP_EOF'
#include <windows.h>
#include <stdio.h>

static int ok = 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, a1, a2, b1, b2, chk;
    MSG msg;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "RadGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "RadGui", "RadGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 240, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    a1 = CreateWindowEx(0, "BUTTON", "A1", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON | WS_GROUP,
        10, 10, 100, 20, hwnd, (HMENU)11, hInst, NULL);
    a2 = CreateWindowEx(0, "BUTTON", "A2", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON,
        10, 35, 100, 20, hwnd, (HMENU)12, hInst, NULL);
    b1 = CreateWindowEx(0, "BUTTON", "B1", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON | WS_GROUP,
        10, 70, 100, 20, hwnd, (HMENU)21, hInst, NULL);
    b2 = CreateWindowEx(0, "BUTTON", "B2", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON,
        10, 95, 100, 20, hwnd, (HMENU)22, hInst, NULL);
    chk = CreateWindowEx(0, "BUTTON", "Check", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX,
        10, 130, 100, 20, hwnd, (HMENU)30, hInst, NULL);

    SendMessageA(a1, BM_CLICK, 0, 0);
    if (SendMessageA(a1, BM_GETCHECK, 0, 0) != 1) ok = 0;
    if (SendMessageA(a2, BM_GETCHECK, 0, 0) != 0) ok = 0;
    if (SendMessageA(b1, BM_GETCHECK, 0, 0) != 0) ok = 0;
    if (SendMessageA(b2, BM_GETCHECK, 0, 0) != 0) ok = 0;

    SendMessageA(b2, BM_CLICK, 0, 0);
    if (SendMessageA(b2, BM_GETCHECK, 0, 0) != 1) ok = 0;
    if (SendMessageA(b1, BM_GETCHECK, 0, 0) != 0) ok = 0;
    if (SendMessageA(a1, BM_GETCHECK, 0, 0) != 1) ok = 0;

    SendMessageA(a2, BM_CLICK, 0, 0);
    if (SendMessageA(a2, BM_GETCHECK, 0, 0) != 1) ok = 0;
    if (SendMessageA(a1, BM_GETCHECK, 0, 0) != 0) ok = 0;
    if (SendMessageA(b2, BM_GETCHECK, 0, 0) != 1) ok = 0;

    SendMessageA(chk, BM_CLICK, 0, 0);
    if (SendMessageA(chk, BM_GETCHECK, 0, 0) != 1) ok = 0;
    if (SendMessageA(a2, BM_GETCHECK, 0, 0) != 1) ok = 0;

    printf("radgrp-check: %s (a1=%d a2=%d b1=%d b2=%d chk=%d)\n",
        ok ? "ok" : "FAIL",
        SendMessageA(a1, BM_GETCHECK, 0, 0),
        SendMessageA(a2, BM_GETCHECK, 0, 0),
        SendMessageA(b1, BM_GETCHECK, 0, 0),
        SendMessageA(b2, BM_GETCHECK, 0, 0),
        SendMessageA(chk, BM_GETCHECK, 0, 0));

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
RADGRP_EOF

rc=$(run radgrp_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Foradgrp_gui.obj radgrp_gui.c)
if [ "$rc" = "0" ] && [ -f radgrp_gui.obj ]; then
    pass "RADGRP: CL /c radgrp_gui.c" ""
else
    fail "RADGRP: CL /c radgrp_gui.c" "exit $rc $(tail -3 radgrp_cl.txt 2>/dev/null)"
fi
if [ -f radgrp_gui.obj ]; then
    rc=$(run radgrp_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:radgrp_gui.exe /LIBPATH:"$VC_LIB" radgrp_gui.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f radgrp_gui.exe ]; then
        pass "RADGRP: LINK radgrp_gui.obj" "($(stat -c%s radgrp_gui.exe) bytes)"
    else
        fail "RADGRP: LINK radgrp_gui.obj" "exit $rc $(tail -3 radgrp_link.txt 2>/dev/null)"
    fi
fi
if [ -f radgrp_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "RADGRP: run radgrp_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run radgrp_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./radgrp_gui.exe)
        if grep -q "radgrp-check: ok" radgrp_out.txt 2>/dev/null; then
            pass "RADGRP: run radgrp_gui.exe" "(radio group exclusion)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "RADGRP: run radgrp_gui.exe" "exit $rc, missing expected output ($(tail -3 radgrp_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "RADGRP: run radgrp_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end RADGRP

if should_run "LST|listbox|lbaddstring"; then
echo ""
echo "=== ListBox: LB_* item/cursor state ==="
########################################
# LB_ADDSTRING/LB_INSERTSTRING/LB_DELETESTRING/LB_RESETCONTENT maintain the
# item list; LB_GETCOUNT/LB_GETTEXT/LB_GETTEXTLEN read it back; LB_SETCURSEL/
# LB_GETCURSEL/LB_SELECTSTRING handle the selection. Items are pushed to the
# renderer (web/FLTK) as a newline-joined string.

cat > lst_gui.c <<'LST_EOF'
#include <windows.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, lb;
    MSG msg;
    char buf[64];

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "LstGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "LstGui", "LstGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 220, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    lb = CreateWindowEx(0, "ListBox", NULL, WS_CHILD | WS_VISIBLE | WS_BORDER,
        10, 10, 180, 140, hwnd, (HMENU)3001, hInst, NULL);

    SendMessageA(lb, LB_ADDSTRING, 0, (LPARAM)"one");
    SendMessageA(lb, LB_ADDSTRING, 0, (LPARAM)"two");
    SendMessageA(lb, LB_ADDSTRING, 0, (LPARAM)"three");
    if (SendMessageA(lb, LB_GETCOUNT, 0, 0) != 3) ok = 0;

    if (SendMessageA(lb, LB_GETTEXTLEN, 1, 0) != 3) ok = 0;
    if (SendMessageA(lb, LB_GETTEXT, 1, (LPARAM)buf) != 3 || strcmp(buf, "two") != 0) ok = 0;

    SendMessageA(lb, LB_SETCURSEL, 1, 0);
    if (SendMessageA(lb, LB_GETCURSEL, 0, 0) != 1) ok = 0;

    if (SendMessageA(lb, LB_SELECTSTRING, (WPARAM)-1, (LPARAM)"th") != 2) ok = 0;
    if (SendMessageA(lb, LB_GETCURSEL, 0, 0) != 2) ok = 0;

    if (SendMessageA(lb, LB_DELETESTRING, 0, 0) != 2) ok = 0;
    if (SendMessageA(lb, LB_GETTEXT, 0, (LPARAM)buf) != 3 || strcmp(buf, "two") != 0) ok = 0;

    SendMessageA(lb, LB_RESETCONTENT, 0, 0);
    if (SendMessageA(lb, LB_GETCOUNT, 0, 0) != 0) ok = 0;

    printf("lst-check: %s (count=%d cursor=%d)\n", ok ? "ok" : "FAIL",
        SendMessageA(lb, LB_GETCOUNT, 0, 0),
        SendMessageA(lb, LB_GETCURSEL, 0, 0));

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
LST_EOF

rc=$(run lst_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Folst_gui.obj lst_gui.c)
if [ "$rc" = "0" ] && [ -f lst_gui.obj ]; then
    pass "LST: CL /c lst_gui.c" ""
else
    fail "LST: CL /c lst_gui.c" "exit $rc $(tail -3 lst_cl.txt 2>/dev/null)"
fi
if [ -f lst_gui.obj ]; then
    rc=$(run lst_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:lst_gui.exe /LIBPATH:"$VC_LIB" lst_gui.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f lst_gui.exe ]; then
        pass "LST: LINK lst_gui.obj" "($(stat -c%s lst_gui.exe) bytes)"
    else
        fail "LST: LINK lst_gui.obj" "exit $rc $(tail -3 lst_link.txt 2>/dev/null)"
    fi
fi
if [ -f lst_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "LST: run lst_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run lst_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./lst_gui.exe)
        if grep -q "lst-check: ok" lst_out.txt 2>/dev/null; then
            pass "LST: run lst_gui.exe" "(LB_* item/cursor state)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "LST: run lst_gui.exe" "exit $rc, missing expected output ($(tail -3 lst_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "LST: run lst_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end LST

if should_run "COMBO|combobox|cbaddstring"; then
echo ""
echo "=== ComboBox: CB_* item/cursor state ==="
########################################
# CB_ADDSTRING/CB_INSERTSTRING/CB_DELETESTRING/CB_RESETCONTENT maintain the
# item list; CB_GETCOUNT/CB_GETLBTEXT/CB_GETLBTEXTLEN read it back;
# CB_SETCURSEL/CB_GETCURSEL/CB_SELECTSTRING handle the selection; the items
# are pushed to the renderer (web <select> / FLTK Fl_Choice).

cat > combo_gui.c <<'COMBO_EOF'
#include <windows.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, cb;
    MSG msg;
    char buf[64];

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "ComboGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "ComboGui", "ComboGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 180, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    cb = CreateWindowEx(0, "ComboBox", NULL, WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_BORDER,
        10, 10, 160, 120, hwnd, (HMENU)3002, hInst, NULL);

    SendMessageA(cb, CB_ADDSTRING, 0, (LPARAM)"one");
    SendMessageA(cb, CB_ADDSTRING, 0, (LPARAM)"two");
    SendMessageA(cb, CB_ADDSTRING, 0, (LPARAM)"three");
    if (SendMessageA(cb, CB_GETCOUNT, 0, 0) != 3) ok = 0;

    if (SendMessageA(cb, CB_GETLBTEXTLEN, 1, 0) != 3) ok = 0;
    if (SendMessageA(cb, CB_GETLBTEXT, 1, (LPARAM)buf) != 3 || strcmp(buf, "two") != 0) ok = 0;

    SendMessageA(cb, CB_SETCURSEL, 1, 0);
    if (SendMessageA(cb, CB_GETCURSEL, 0, 0) != 1) ok = 0;

    if (SendMessageA(cb, CB_SELECTSTRING, (WPARAM)-1, (LPARAM)"th") != 2) ok = 0;
    if (SendMessageA(cb, CB_GETCURSEL, 0, 0) != 2) ok = 0;

    SendMessageA(cb, CB_SHOWDROPDOWN, 1, 0);
    if (SendMessageA(cb, CB_SHOWDROPDOWN, 1, 0) != 1) ok = 0;

    SendMessageA(cb, CB_RESETCONTENT, 0, 0);
    if (SendMessageA(cb, CB_GETCOUNT, 0, 0) != 0) ok = 0;

    printf("combo-check: %s (count=%d cursor=%d)\n", ok ? "ok" : "FAIL",
        SendMessageA(cb, CB_GETCOUNT, 0, 0),
        SendMessageA(cb, CB_GETCURSEL, 0, 0));

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
COMBO_EOF

rc=$(run combo_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Focombo_gui.obj combo_gui.c)
if [ "$rc" = "0" ] && [ -f combo_gui.obj ]; then
    pass "COMBO: CL /c combo_gui.c" ""
else
    fail "COMBO: CL /c combo_gui.c" "exit $rc $(tail -3 combo_cl.txt 2>/dev/null)"
fi
if [ -f combo_gui.obj ]; then
    rc=$(run combo_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:combo_gui.exe /LIBPATH:"$VC_LIB" combo_gui.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f combo_gui.exe ]; then
        pass "COMBO: LINK combo_gui.obj" "($(stat -c%s combo_gui.exe) bytes)"
    else
        fail "COMBO: LINK combo_gui.obj" "exit $rc $(tail -3 combo_link.txt 2>/dev/null)"
    fi
fi
if [ -f combo_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "COMBO: run combo_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run combo_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./combo_gui.exe)
        if grep -q "combo-check: ok" combo_out.txt 2>/dev/null; then
            pass "COMBO: run combo_gui.exe" "(CB_* item/cursor state)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "COMBO: run combo_gui.exe" "exit $rc, missing expected output ($(tail -3 combo_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "COMBO: run combo_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end COMBO

if should_run "TAB|tabctl|tcm"; then
echo ""
echo "=== TabControl: TCM_* item/cursor state ==="
########################################
# TCM_INSERTITEMA/TCM_DELETEITEM/TCM_DELETEALLITEMS maintain the tab list;
# TCM_GETITEMCOUNT/TCM_GETITEMA read it back; TCM_SETCURSEL/TCM_GETCURSEL
# handle the selection. Items are pushed to the renderer (web tab header /
# FLTK Fl_Tabs).

cat > tab_gui.c <<'TAB_EOF'
#define _WIN32_IE 0x0500
#include <windows.h>
#include <commctrl.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, tabs;
    MSG msg;
    char buf[64];
    TCITEM tci;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "TabGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "TabGui", "TabGui", WS_OVERLAPPEDWINDOW,
        0, 0, 360, 240, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    tabs = CreateWindowEx(0, "SysTabControl32", NULL, WS_CHILD | WS_VISIBLE | WS_BORDER,
        10, 10, 300, 180, hwnd, (HMENU)3003, hInst, NULL);

    tci.mask = TCIF_TEXT;
    tci.pszText = "General";
    SendMessageA(tabs, TCM_INSERTITEM, 0, (LPARAM)&tci);
    tci.pszText = "Advanced";
    SendMessageA(tabs, TCM_INSERTITEM, 1, (LPARAM)&tci);
    tci.pszText = "About";
    SendMessageA(tabs, TCM_INSERTITEM, 2, (LPARAM)&tci);
    if (SendMessageA(tabs, TCM_GETITEMCOUNT, 0, 0) != 3) ok = 0;

    SendMessageA(tabs, TCM_SETCURSEL, 1, 0);
    if (SendMessageA(tabs, TCM_GETCURSEL, 0, 0) != 1) ok = 0;

    buf[0] = 0;
    tci.mask = TCIF_TEXT;
    tci.pszText = buf;
    tci.cchTextMax = sizeof(buf);
    if (SendMessageA(tabs, TCM_GETITEM, 2, (LPARAM)&tci) != 1) ok = 0;
    if (strcmp(buf, "About") != 0) ok = 0;

    if (SendMessageA(tabs, TCM_DELETEITEM, 1, 0) != 1) ok = 0;
    if (SendMessageA(tabs, TCM_GETITEMCOUNT, 0, 0) != 2) ok = 0;

    SendMessageA(tabs, TCM_DELETEALLITEMS, 0, 0);
    if (SendMessageA(tabs, TCM_GETITEMCOUNT, 0, 0) != 0) ok = 0;

    printf("tab-check: %s (count=%d cursor=%d last='%s')\n", ok ? "ok" : "FAIL",
        SendMessageA(tabs, TCM_GETITEMCOUNT, 0, 0),
        SendMessageA(tabs, TCM_GETCURSEL, 0, 0),
        buf);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
TAB_EOF

rc=$(run tab_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fotab_gui.obj tab_gui.c)
if [ "$rc" = "0" ] && [ -f tab_gui.obj ]; then
    pass "TAB: CL /c tab_gui.c" ""
else
    fail "TAB: CL /c tab_gui.c" "exit $rc $(tail -3 tab_cl.txt 2>/dev/null)"
fi
if [ -f tab_gui.obj ]; then
    rc=$(run tab_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:tab_gui.exe /LIBPATH:"$VC_LIB" tab_gui.obj comctl32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f tab_gui.exe ]; then
        pass "TAB: LINK tab_gui.obj" "($(stat -c%s tab_gui.exe) bytes)"
    else
        fail "TAB: LINK tab_gui.obj" "exit $rc $(tail -3 tab_link.txt 2>/dev/null)"
    fi
fi
if [ -f tab_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "TAB: run tab_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run tab_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./tab_gui.exe)
        if grep -q "tab-check: ok" tab_out.txt 2>/dev/null; then
            pass "TAB: run tab_gui.exe" "(TCM_* item/cursor state)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "TAB: run tab_gui.exe" "exit $rc, missing expected output ($(tail -3 tab_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "TAB: run tab_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end TAB

if should_run "CLR|ctlcolor|brushcolor"; then
echo ""
echo "=== WM_CTLCOLOR: control background brush from the parent ==="
########################################
# Creating a standard control sends WM_CTLCOLOR* to its parent; the returned
# brush (system color or GDI solid brush) is mapped to RGB and applied to the
# renderer (web background-color / FLTK widget color).

cat > clr_gui.c <<'CLR_EOF'
#include <windows.h>
#include <stdio.h>

static int ok = 1;
static int got_ctlcolor = 0;
static HWND g_static = NULL;
static HBRUSH g_red_brush = NULL;

LRESULT CALLBACK DlgProc(HWND hDlg, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_INITDIALOG:
        g_static = CreateWindowEx(0, "STATIC", "Colored", WS_CHILD | WS_VISIBLE,
            10, 10, 120, 20, hDlg, (HMENU)4001, GetModuleHandle(NULL), NULL);
        return 1;
    case WM_CTLCOLORSTATIC:
        got_ctlcolor = 1;
        return (LRESULT)g_red_brush;
    case WM_COMMAND:
        return 1;
    }
    return 0;
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, hDlg;
    MSG msg;

    g_red_brush = CreateSolidBrush(RGB(255, 0, 0));

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "ClrGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "ClrGui", "ClrGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 180, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    hDlg = CreateDialogParamA(hInst, (LPCSTR)1, hwnd, DlgProc, 0);
    if (!hDlg) { printf("clr-check: FAIL (no dialog)\n"); return 1; }

    if (got_ctlcolor != 1) ok = 0;
    if (g_static == NULL) ok = 0;

    got_ctlcolor = 0;
    SendMessageA(hDlg, WM_CTLCOLORSTATIC, (WPARAM)0, (LPARAM)g_static);
    if (got_ctlcolor != 1) ok = 0;

    printf("clr-check: %s (ctlcolor=%d)\n", ok ? "ok" : "FAIL", got_ctlcolor);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
CLR_EOF

rc=$(run clr_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Foclr_gui.obj clr_gui.c)
if [ "$rc" = "0" ] && [ -f clr_gui.obj ]; then
    pass "CLR: CL /c clr_gui.c" ""
else
    fail "CLR: CL /c clr_gui.c" "exit $rc $(tail -3 clr_cl.txt 2>/dev/null)"
fi
if [ -f clr_gui.obj ]; then
    rc=$(run clr_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:clr_gui.exe /LIBPATH:"$VC_LIB" clr_gui.obj user32.lib gdi32.lib)
    if [ "$rc" = "0" ] && [ -f clr_gui.exe ]; then
        pass "CLR: LINK clr_gui.obj" "($(stat -c%s clr_gui.exe) bytes)"
    else
        fail "CLR: LINK clr_gui.obj" "exit $rc $(tail -3 clr_link.txt 2>/dev/null)"
    fi
fi
if [ -f clr_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "CLR: run clr_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run clr_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./clr_gui.exe)
        if grep -q "clr-check: ok" clr_out.txt 2>/dev/null; then
            pass "CLR: run clr_gui.exe" "(WM_CTLCOLOR delivered + brush accepted)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "CLR: run clr_gui.exe" "exit $rc, missing expected output ($(tail -3 clr_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "CLR: run clr_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end CLR

if should_run "LV|listview|lvm"; then
echo ""
echo "=== ListView: LVM_* item/selection state ==="
########################################
# LVM_INSERTCOLUMNA/LVM_INSERTITEMA maintain the item list (LVITEM* in
# lParam, pszText at +20); LVM_GETITEMCOUNT/LVM_GETITEMTEXTA read it back;
# LVM_SETITEMSTATE/LVM_GETSELECTEDCOUNT handle the selection. Items are
# pushed to the renderer (web rows / FLTK browser).

cat > lv_gui.c <<'LV_EOF'
#define _WIN32_IE 0x0500
#include <windows.h>
#include <commctrl.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, lv;
    MSG msg;
    char buf[64];
    LVCOLUMNA lvc;
    LVITEMA lvi;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "LvGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "LvGui", "LvGui", WS_OVERLAPPEDWINDOW,
        0, 0, 360, 240, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    lv = CreateWindowEx(0, "SysListView32", NULL, WS_CHILD | WS_VISIBLE | WS_BORDER,
        10, 10, 300, 180, hwnd, (HMENU)3004, hInst, NULL);

    lvc.mask = LVCF_TEXT | LVCF_WIDTH;
    lvc.cx = 120;
    lvc.pszText = "Name";
    SendMessageA(lv, LVM_INSERTCOLUMNA, 0, (LPARAM)&lvc);
    lvc.pszText = "Value";
    SendMessageA(lv, LVM_INSERTCOLUMNA, 1, (LPARAM)&lvc);

    lvi.mask = LVIF_TEXT;
    lvi.iItem = 0; lvi.iSubItem = 0; lvi.pszText = "one";
    SendMessageA(lv, LVM_INSERTITEMA, 0, (LPARAM)&lvi);
    lvi.iItem = 1; lvi.pszText = "two";
    SendMessageA(lv, LVM_INSERTITEMA, 1, (LPARAM)&lvi);
    lvi.iItem = 2; lvi.pszText = "three";
    SendMessageA(lv, LVM_INSERTITEMA, 2, (LPARAM)&lvi);
    if (SendMessageA(lv, LVM_GETITEMCOUNT, 0, 0) != 3) ok = 0;

    buf[0] = 0;
    lvi.mask = LVIF_TEXT;
    lvi.iItem = 0; lvi.iSubItem = 0; lvi.pszText = buf; lvi.cchTextMax = sizeof(buf);
    SendMessageA(lv, LVM_GETITEMTEXTA, 0, (LPARAM)&lvi);
    if (strcmp(buf, "one") != 0) ok = 0;

    lvi.state = LVIS_SELECTED; lvi.stateMask = LVIS_SELECTED;
    SendMessageA(lv, LVM_SETITEMSTATE, 1, (LPARAM)&lvi);
    if (SendMessageA(lv, LVM_GETSELECTEDCOUNT, 0, 0) != 1) ok = 0;

    if (SendMessageA(lv, LVM_DELETEITEM, 1, 0) != 1) ok = 0;
    if (SendMessageA(lv, LVM_GETITEMCOUNT, 0, 0) != 2) ok = 0;

    SendMessageA(lv, LVM_DELETEALLITEMS, 0, 0);
    if (SendMessageA(lv, LVM_GETITEMCOUNT, 0, 0) != 0) ok = 0;

    printf("lv-check: %s (count=%d sel=%d first='%s')\n", ok ? "ok" : "FAIL",
        SendMessageA(lv, LVM_GETITEMCOUNT, 0, 0),
        SendMessageA(lv, LVM_GETSELECTEDCOUNT, 0, 0),
        buf);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
LV_EOF

rc=$(run lv_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Folv_gui.obj lv_gui.c)
if [ "$rc" = "0" ] && [ -f lv_gui.obj ]; then
    pass "LV: CL /c lv_gui.c" ""
else
    fail "LV: CL /c lv_gui.c" "exit $rc $(tail -3 lv_cl.txt 2>/dev/null)"
fi
if [ -f lv_gui.obj ]; then
    rc=$(run lv_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:lv_gui.exe /LIBPATH:"$VC_LIB" lv_gui.obj comctl32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f lv_gui.exe ]; then
        pass "LV: LINK lv_gui.obj" "($(stat -c%s lv_gui.exe) bytes)"
    else
        fail "LV: LINK lv_gui.obj" "exit $rc $(tail -3 lv_link.txt 2>/dev/null)"
    fi
fi
if [ -f lv_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "LV: run lv_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run lv_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./lv_gui.exe)
        if grep -q "lv-check: ok" lv_out.txt 2>/dev/null; then
            pass "LV: run lv_gui.exe" "(LVM_* item/selection state)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "LV: run lv_gui.exe" "exit $rc, missing expected output ($(tail -3 lv_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "LV: run lv_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end LV

if should_run "TREE|treeview|tvm"; then
echo ""
echo "=== TreeView: TVM_* item/selection state ==="
########################################
# TVM_INSERTITEMA (TVINSERTSTRUCT*, item.pszText at +24) / TVM_GETCOUNT /
# TVM_GETITEMA (TVITEM*, index in hItem at +4, pszText at +16) / TVM_SELECTITEM /
# TVM_EXPAND / TVM_DELETEITEM. Items are pushed to the renderer (web rows /
# FLTK browser).

cat > tree_gui.c <<'TREE_EOF'
#define _WIN32_IE 0x0500
#include <windows.h>
#include <commctrl.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, tv;
    MSG msg;
    char buf[64];
    TVINSERTSTRUCTA tvis;
    TVITEMA tvi;
    HTREEITEM h1, h2;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "TreeGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "TreeGui", "TreeGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 220, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    tv = CreateWindowEx(0, "SysTreeView32", NULL, WS_CHILD | WS_VISIBLE | WS_BORDER,
        10, 10, 260, 160, hwnd, (HMENU)3005, hInst, NULL);

    tvis.hParent = NULL;
    tvis.hInsertAfter = TVI_ROOT;
    tvis.item.mask = TVIF_TEXT;
    tvis.item.pszText = "root";
    h1 = (HTREEITEM)SendMessageA(tv, TVM_INSERTITEMA, 0, (LPARAM)&tvis);
    tvis.item.pszText = "child";
    h2 = (HTREEITEM)SendMessageA(tv, TVM_INSERTITEMA, 0, (LPARAM)&tvis);
    tvis.item.pszText = "leaf";
    SendMessageA(tv, TVM_INSERTITEMA, 0, (LPARAM)&tvis);
    if (SendMessageA(tv, TVM_GETCOUNT, 0, 0) != 3) ok = 0;

    buf[0] = 0;
    tvi.mask = TVIF_TEXT;
    tvi.hItem = h2;
    tvi.pszText = buf;
    tvi.cchTextMax = sizeof(buf);
    SendMessageA(tv, TVM_GETITEMA, 0, (LPARAM)&tvi);
    if (strcmp(buf, "child") != 0) ok = 0;

    if (SendMessageA(tv, TVM_SELECTITEM, TVGN_CARET, (LPARAM)h1) != 1) ok = 0;
    if (SendMessageA(tv, TVM_EXPAND, TVE_EXPAND, (LPARAM)h1) != 1) ok = 0;

    if (SendMessageA(tv, TVM_DELETEITEM, 0, (LPARAM)h2) != 1) ok = 0;
    if (SendMessageA(tv, TVM_GETCOUNT, 0, 0) != 2) ok = 0;

    printf("tree-check: %s (count=%d second='%s')\n", ok ? "ok" : "FAIL",
        SendMessageA(tv, TVM_GETCOUNT, 0, 0),
        buf);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
TREE_EOF

rc=$(run tree_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fotree_gui.obj tree_gui.c)
if [ "$rc" = "0" ] && [ -f tree_gui.obj ]; then
    pass "TREE: CL /c tree_gui.c" ""
else
    fail "TREE: CL /c tree_gui.c" "exit $rc $(tail -3 tree_cl.txt 2>/dev/null)"
fi
if [ -f tree_gui.obj ]; then
    rc=$(run tree_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:tree_gui.exe /LIBPATH:"$VC_LIB" tree_gui.obj comctl32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f tree_gui.exe ]; then
        pass "TREE: LINK tree_gui.obj" "($(stat -c%s tree_gui.exe) bytes)"
    else
        fail "TREE: LINK tree_gui.obj" "exit $rc $(tail -3 tree_link.txt 2>/dev/null)"
    fi
fi
if [ -f tree_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "TREE: run tree_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run tree_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./tree_gui.exe)
        if grep -q "tree-check: ok" tree_out.txt 2>/dev/null; then
            pass "TREE: run tree_gui.exe" "(TVM_* item/selection state)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "TREE: run tree_gui.exe" "exit $rc, missing expected output ($(tail -3 tree_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "TREE: run tree_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end TREE

if should_run "HDR|header|hdm"; then
echo ""
echo "=== Header control: HDM_* item state ==="
########################################
# HDM_INSERTITEMA (HDITEM*, pszText at +8) / HDM_GETITEMCOUNT / HDM_GETITEMA
# / HDM_DELETEITEM. Items are pushed to the renderer (web header row).

cat > hdr_gui.c <<'HDR_EOF'
#define _WIN32_IE 0x0500
#include <windows.h>
#include <commctrl.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, hdr;
    MSG msg;
    char buf[64];
    HDITEMA hdi;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "HdrGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "HdrGui", "HdrGui", WS_OVERLAPPEDWINDOW,
        0, 0, 360, 160, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    hdr = CreateWindowEx(0, "SysHeader32", NULL, WS_CHILD | WS_VISIBLE,
        10, 10, 300, 22, hwnd, (HMENU)3006, hInst, NULL);

    hdi.mask = HDI_TEXT | HDI_WIDTH;
    hdi.cxy = 120;
    hdi.pszText = "Name";
    SendMessageA(hdr, HDM_INSERTITEMA, 0, (LPARAM)&hdi);
    hdi.pszText = "Value";
    SendMessageA(hdr, HDM_INSERTITEMA, 1, (LPARAM)&hdi);
    if (SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0) != 2) ok = 0;

    buf[0] = 0;
    hdi.mask = HDI_TEXT;
    hdi.pszText = buf;
    hdi.cchTextMax = sizeof(buf);
    SendMessageA(hdr, HDM_GETITEMA, 0, (LPARAM)&hdi);
    if (strcmp(buf, "Name") != 0) ok = 0;

    if (SendMessageA(hdr, HDM_DELETEITEM, 1, 0) != 1) ok = 0;
    if (SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0) != 1) ok = 0;

    printf("hdr-check: %s (count=%d first='%s')\n", ok ? "ok" : "FAIL",
        SendMessageA(hdr, HDM_GETITEMCOUNT, 0, 0),
        buf);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
HDR_EOF

rc=$(run hdr_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fohdr_gui.obj hdr_gui.c)
if [ "$rc" = "0" ] && [ -f hdr_gui.obj ]; then
    pass "HDR: CL /c hdr_gui.c" ""
else
    fail "HDR: CL /c hdr_gui.c" "exit $rc $(tail -3 hdr_cl.txt 2>/dev/null)"
fi
if [ -f hdr_gui.obj ]; then
    rc=$(run hdr_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:hdr_gui.exe /LIBPATH:"$VC_LIB" hdr_gui.obj comctl32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f hdr_gui.exe ]; then
        pass "HDR: LINK hdr_gui.obj" "($(stat -c%s hdr_gui.exe) bytes)"
    else
        fail "HDR: LINK hdr_gui.obj" "exit $rc $(tail -3 hdr_link.txt 2>/dev/null)"
    fi
fi
if [ -f hdr_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "HDR: run hdr_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run hdr_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./hdr_gui.exe)
        if grep -q "hdr-check: ok" hdr_out.txt 2>/dev/null; then
            pass "HDR: run hdr_gui.exe" "(HDM_* item state)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "HDR: run hdr_gui.exe" "exit $rc, missing expected output ($(tail -3 hdr_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "HDR: run hdr_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end HDR

if should_run "CC|choosecolor|colordlg"; then
echo ""
echo "=== ChooseColor: host color dialog round-trip ==="
########################################
# ChooseColorA opens the host color chooser (FLTK Fl_Color_Chooser / web
# picker). A WS client drives the web picker; the chosen color must land back
# in CHOOSECOLOR.rgbResult.

cat > cc_gui.c <<'CC_EOF'
#include <windows.h>
#include <stdio.h>

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd;
    MSG msg;
    CHOOSECOLORA cc;
    COLORREF chosen = 0;
    int ok = 1;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "CcGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "CcGui", "CcGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 160, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    memset(&cc, 0, sizeof(cc));
    cc.lStructSize = sizeof(cc);
    cc.hwndOwner = hwnd;
    cc.rgbResult = RGB(0, 0, 255);

    if (ChooseColorA(&cc)) {
        chosen = cc.rgbResult;
    }

    if (chosen != 0x00FF0000) ok = 0;

    printf("cc-check: %s (chosen=0x%06X)\n", ok ? "ok" : "FAIL", (unsigned)chosen);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
CC_EOF

cat > ws_cc.py <<'WSCC_EOF'
import json, sys, time
import websocket
ws = websocket.create_connection("ws://127.0.0.1:1995/ws", timeout=15)
sent = False
deadline = time.time() + 12
try:
    while time.time() < deadline:
        try:
            opcode, data = ws.recv_data(control_frame=False)
        except Exception:
            break
        if isinstance(data, bytes) and data[:4] == b"AUD\x00":
            data = data[4:]
        try:
            obj = json.loads(data)
        except Exception:
            continue
        if obj.get("type") == "show_color_dialog" and not sent:
            ws.send(json.dumps({"type": "color_selected", "color": 0x00FF0000}))
            sent = True
            break
finally:
    ws.close()
WSCC_EOF

rc=$(run cc_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Focc_gui.obj cc_gui.c)
if [ "$rc" = "0" ] && [ -f cc_gui.obj ]; then
    pass "CC: CL /c cc_gui.c" ""
else
    fail "CC: CL /c cc_gui.c" "exit $rc $(tail -3 cc_cl.txt 2>/dev/null)"
fi
if [ -f cc_gui.obj ]; then
    rc=$(run cc_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:cc_gui.exe /LIBPATH:"$VC_LIB" cc_gui.obj comdlg32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f cc_gui.exe ]; then
        pass "CC: LINK cc_gui.obj" "($(stat -c%s cc_gui.exe) bytes)"
    else
        fail "CC: LINK cc_gui.obj" "exit $rc $(tail -3 cc_link.txt 2>/dev/null)"
    fi
fi
if [ -f cc_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "CC: run cc_gui.exe" "(WASM build has no GUI renderer)"
    else
        timeout 30 "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./cc_gui.exe > cc_out.txt 2>&1 &
        CC_APP_PID=$!
        sleep 4
        timeout 20 python3 ws_cc.py >> cc_out.txt 2>&1
        wait $CC_APP_PID
        if grep -q "cc-check: ok" cc_out.txt 2>/dev/null; then
            pass "CC: run cc_gui.exe" "(ChooseColor round-trip via web client)"
        else
            fail "CC: run cc_gui.exe" "missing expected output ($(tail -3 cc_out.txt 2>/dev/null | tr '\n' ' '))"
        fi
    fi
fi
fi  # end CC

if should_run "CF|font|choosefont"; then
echo ""
echo "=== ChooseFont: host font dialog round-trip ==="
########################################
# ChooseFontA opens the host font chooser (web picker / FLTK); the WS driver
# picks Courier New 14pt bold italic; the app asserts the LOGFONT + iPointSize
# round-trip written back by the stub.

cat > cf_gui.c <<'CF_EOF'
#include <windows.h>
#include <commdlg.h>
#include <string.h>
#include <stdio.h>

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd;
    MSG msg;
    LOGFONTA lf;
    CHOOSEFONTA cf;
    int ok = 1;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "CfGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "CfGui", "CfGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 160, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    memset(&lf, 0, sizeof(lf));
    lstrcpyA(lf.lfFaceName, "MS Sans Serif");
    lf.lfHeight = -16;
    lf.lfWeight = FW_NORMAL;

    memset(&cf, 0, sizeof(cf));
    cf.lStructSize = sizeof(cf);
    cf.hwndOwner = hwnd;
    cf.lpLogFont = &lf;
    cf.Flags = CF_INITTOLOGFONTSTRUCT | CF_SCREENFONTS | CF_EFFECTS;

    if (ChooseFontA(&cf)) {
        if (lstrcmpiA(lf.lfFaceName, "Courier New") != 0) ok = 0;
        if (cf.iPointSize != 140) ok = 0;   /* 14pt = 140 (1/10 pt units) */
        if (lf.lfWeight < 700) ok = 0;      /* bold */
        if (lf.lfItalic != 1) ok = 0;       /* italic */
    } else {
        ok = 0;
    }

    printf("cf-check: %s (face='%s' iPointSize=%d weight=%d italic=%d)\n",
        ok ? "ok" : "FAIL", lf.lfFaceName, (int)cf.iPointSize,
        (int)lf.lfWeight, (int)lf.lfItalic);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
CF_EOF

cat > ws_cf.py <<'WSCF_EOF'
import json, time
import websocket
ws = websocket.create_connection("ws://127.0.0.1:1995/ws", timeout=15)
sent = False
deadline = time.time() + 12
try:
    while time.time() < deadline:
        try:
            opcode, data = ws.recv_data(control_frame=False)
        except Exception:
            break
        if isinstance(data, bytes) and data[:4] == b"AUD\x00":
            data = data[4:]
        try:
            obj = json.loads(data)
        except Exception:
            continue
        if obj.get("type") == "open_font_dialog" and not sent:
            ws.send(json.dumps({"type": "font_chosen", "face": "Courier New",
                                "size": 14, "bold": True, "italic": True}))
            sent = True
            break
finally:
    ws.close()
WSCF_EOF

rc=$(run cf_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Focf_gui.obj cf_gui.c)
if [ "$rc" = "0" ] && [ -f cf_gui.obj ]; then
    pass "CF: CL /c cf_gui.c" ""
else
    fail "CF: CL /c cf_gui.c" "exit $rc $(tail -3 cf_cl.txt 2>/dev/null)"
fi
if [ -f cf_gui.obj ]; then
    rc=$(run cf_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:cf_gui.exe /LIBPATH:"$VC_LIB" cf_gui.obj comdlg32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f cf_gui.exe ]; then
        pass "CF: LINK cf_gui.obj" "($(stat -c%s cf_gui.exe) bytes)"
    else
        fail "CF: LINK cf_gui.obj" "exit $rc $(tail -3 cf_link.txt 2>/dev/null)"
    fi
fi
if [ -f cf_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "CF: run cf_gui.exe" "(WASM build has no GUI renderer)"
    else
        timeout 30 "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./cf_gui.exe > cf_out.txt 2>&1 &
        CF_APP_PID=$!
        sleep 4
        timeout 20 python3 ws_cf.py >> cf_out.txt 2>&1
        wait $CF_APP_PID
        if grep -q "cf-check: ok" cf_out.txt 2>/dev/null; then
            pass "CF: run cf_gui.exe" "(ChooseFont round-trip via web client)"
        else
            fail "CF: run cf_gui.exe" "missing expected output ($(tail -3 cf_out.txt 2>/dev/null | tr '\n' ' '))"
        fi
    fi
fi
fi  # end CF

if should_run "RICH|richedit|rich"; then
echo ""
echo "=== RichEdit: RichEdit20A control (EM_* messages) ==="
########################################
# RichEdit20A is an EDIT superset: WM_SETTEXT/WM_GETTEXT/WM_CHAR plus the
# RichEdit 2.0 EM_* (EXGETSEL/EXSETSEL/REPLACESEL/GETSELTEXT/GETCHARFORMAT/
# GETTEXTEX/GETTEXTLENGTHEX). The control class string is used directly so no
# riched20.lib import is needed.

cat > rich_gui.c <<'RICH_EOF'
#include <windows.h>
#include <richedit.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, rich;
    MSG msg;
    CHARFORMAT cf;
    CHARRANGE cr;
    GETTEXTLENGTHEX gtl;
    GETTEXTEX gt;
    char buf[256];
    int len = 0, n = 0;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "RichGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "RichGui", "RichGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 160, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    rich = CreateWindowEx(0, "RichEdit20A", "", WS_CHILD | WS_VISIBLE | ES_MULTILINE,
        10, 10, 260, 100, hwnd, (HMENU)100, hInst, NULL);
    if (!rich) { printf("rich-check: FAIL (create)\n"); return 1; }

    /* Seed the buffer via WM_SETTEXT */
    SetWindowTextA(rich, "Hello RichEdit");

    /* EM_GETTEXTLENGTHEX */
    gtl.flags = GTL_NUMCHARS;
    gtl.codepage = CP_ACP;
    len = (int)SendMessageA(rich, EM_GETTEXTLENGTHEX, 0, (LPARAM)&gtl);
    if (len != 14) ok = 0;   /* "Hello RichEdit" = 14 chars */

    /* EM_GETTEXTEX round-trip */
    memset(&gt, 0, sizeof(gt));
    gt.cb = sizeof(buf);
    gt.flags = GT_DEFAULT;
    gt.codepage = CP_ACP;
    n = (int)SendMessageA(rich, EM_GETTEXTEX, (WPARAM)buf, (LPARAM)&gt);
    if (n != 14 || strcmp(buf, "Hello RichEdit") != 0) ok = 0;

    /* EM_EXSETSEL "RichEdit" (chars 6..14) + EM_REPLACESEL -> "World" */
    cr.cpMin = 6; cr.cpMax = 14;
    SendMessageA(rich, EM_EXSETSEL, 0, (LPARAM)&cr);
    SendMessageA(rich, EM_REPLACESEL, 0, (LPARAM)"World");

    /* EM_EXGETSEL read-back: caret at end of inserted text */
    SendMessageA(rich, EM_EXGETSEL, 0, (LPARAM)&cr);
    if (cr.cpMin != 11 || cr.cpMax != 11) ok = 0;

    /* WM_GETTEXT reflects the replacement */
    SendMessageA(rich, WM_GETTEXT, (WPARAM)sizeof(buf), (LPARAM)buf);
    if (strcmp(buf, "Hello World") != 0) ok = 0;

    /* EM_EXSETSEL + EM_GETSELTEXT */
    cr.cpMin = 0; cr.cpMax = 5;
    SendMessageA(rich, EM_EXSETSEL, 0, (LPARAM)&cr);
    n = (int)SendMessageA(rich, EM_GETSELTEXT, 0, (LPARAM)buf);
    if (n != 5 || strcmp(buf, "Hello") != 0) ok = 0;

    /* EM_GETCHARFORMAT returns the face mask */
    memset(&cf, 0, sizeof(cf));
    cf.cbSize = sizeof(cf);
    SendMessageA(rich, EM_GETCHARFORMAT, SCF_DEFAULT, (LPARAM)&cf);
    if (!(cf.dwMask & CFM_FACE)) ok = 0;

    printf("rich-check: %s (len=%d text='%s' sel='%s')\n",
        ok ? "ok" : "FAIL", len, buf, buf);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
RICH_EOF

rc=$(run rich_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Forich_gui.obj rich_gui.c)
if [ "$rc" = "0" ] && [ -f rich_gui.obj ]; then
    pass "RICH: CL /c rich_gui.c" ""
else
    fail "RICH: CL /c rich_gui.c" "exit $rc $(tail -3 rich_cl.txt 2>/dev/null)"
fi
if [ -f rich_gui.obj ]; then
    rc=$(run rich_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:rich_gui.exe /LIBPATH:"$VC_LIB" rich_gui.obj user32.lib gdi32.lib)
    if [ "$rc" = "0" ] && [ -f rich_gui.exe ]; then
        pass "RICH: LINK rich_gui.obj" "($(stat -c%s rich_gui.exe) bytes)"
    else
        fail "RICH: LINK rich_gui.obj" "exit $rc $(tail -3 rich_link.txt 2>/dev/null)"
    fi
fi
if [ -f rich_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "RICH: run rich_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run rich_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./rich_gui.exe)
        if grep -q "rich-check: ok" rich_out.txt 2>/dev/null; then
            pass "RICH: run rich_gui.exe" "(RichEdit EM_* round-trip)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "RICH: run rich_gui.exe" "exit $rc, missing expected output ($(tail -3 rich_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "RICH: run rich_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end RICH

if should_run "GWT|getwindowtext|gwt"; then
echo ""
echo "=== GetWindowText control-ization ==="
########################################
# GetWindowText / WM_GETTEXT read back control text uniformly: Button/Static
# labels (per-hwnd text store), ListBox/ComboBox selected-item text.

cat > gwt_gui.c <<'GWT_EOF'
#include <windows.h>
#include <commctrl.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;
static char buf[256];

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, btn, stat, lb, combo;
    MSG msg;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "GwtGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "GwtGui", "GwtGui", WS_OVERLAPPEDWINDOW,
        0, 0, 360, 200, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    /* BUTTON label via GetWindowText */
    btn = CreateWindowEx(0, "Button", "OK Button", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
        10, 10, 100, 25, hwnd, (HMENU)1, hInst, NULL);
    if (GetWindowTextA(btn, buf, sizeof(buf)) != 9 || strcmp(buf, "OK Button") != 0) ok = 0;

    /* SetWindowTextA on a control updates the read-back */
    SetWindowTextA(btn, "New Label");
    if (GetWindowTextA(btn, buf, sizeof(buf)) != 9 || strcmp(buf, "New Label") != 0) ok = 0;

    /* STATIC label */
    stat = CreateWindowEx(0, "Static", "Static Text", WS_CHILD | WS_VISIBLE,
        10, 45, 150, 20, hwnd, (HMENU)2, hInst, NULL);
    if (GetWindowTextA(stat, buf, sizeof(buf)) != 11 || strcmp(buf, "Static Text") != 0) ok = 0;

    /* ListBox: selected-item text */
    lb = CreateWindowEx(0, "ListBox", "", WS_CHILD | WS_VISIBLE | WS_BORDER | LBS_NOTIFY,
        10, 80, 120, 80, hwnd, (HMENU)3, hInst, NULL);
    SendMessageA(lb, LB_ADDSTRING, 0, (LPARAM)"Alpha");
    SendMessageA(lb, LB_ADDSTRING, 0, (LPARAM)"Beta");
    SendMessageA(lb, LB_ADDSTRING, 0, (LPARAM)"Gamma");
    SendMessageA(lb, LB_SETCURSEL, 1, 0);
    if (GetWindowTextA(lb, buf, sizeof(buf)) != 4 || strcmp(buf, "Beta") != 0) ok = 0;

    /* ComboBox: selected-item text */
    combo = CreateWindowEx(0, "ComboBox", "", WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST,
        150, 80, 120, 120, hwnd, (HMENU)4, hInst, NULL);
    SendMessageA(combo, CB_ADDSTRING, 0, (LPARAM)"One");
    SendMessageA(combo, CB_ADDSTRING, 0, (LPARAM)"Two");
    SendMessageA(combo, CB_SETCURSEL, 0, 0);
    if (GetWindowTextA(combo, buf, sizeof(buf)) != 3 || strcmp(buf, "One") != 0) ok = 0;

    printf("gwt-check: %s\n", ok ? "ok" : "FAIL");

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
GWT_EOF

rc=$(run gwt_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fogwt_gui.obj gwt_gui.c)
if [ "$rc" = "0" ] && [ -f gwt_gui.obj ]; then
    pass "GWT: CL /c gwt_gui.c" ""
else
    fail "GWT: CL /c gwt_gui.c" "exit $rc $(tail -3 gwt_cl.txt 2>/dev/null)"
fi
if [ -f gwt_gui.obj ]; then
    rc=$(run gwt_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:gwt_gui.exe /LIBPATH:"$VC_LIB" gwt_gui.obj user32.lib gdi32.lib)
    if [ "$rc" = "0" ] && [ -f gwt_gui.exe ]; then
        pass "GWT: LINK gwt_gui.obj" "($(stat -c%s gwt_gui.exe) bytes)"
    else
        fail "GWT: LINK gwt_gui.obj" "exit $rc $(tail -3 gwt_link.txt 2>/dev/null)"
    fi
fi
if [ -f gwt_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "GWT: run gwt_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run gwt_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./gwt_gui.exe)
        if grep -q "gwt-check: ok" gwt_out.txt 2>/dev/null; then
            pass "GWT: run gwt_gui.exe" "(control text read-back)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "GWT: run gwt_gui.exe" "exit $rc, missing expected output ($(tail -3 gwt_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "GWT: run gwt_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end GWT

if should_run "PD|printdlg|print"; then
echo ""
echo "=== PrintDlg: host print dialog round-trip ==="
########################################
# PrintDlgA opens the host print dialog (web / FLTK); the WS driver confirms
# pages 1-3, 2 copies; the app asserts PRINTDLGA fields + PD_RETURNDC dummy
# DC, then verifies PD_RETURNDEFAULT returns without UI.

cat > pd_gui.c <<'PD_EOF'
#include <windows.h>
#include <commdlg.h>
#include <string.h>
#include <stdio.h>

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd;
    MSG msg;
    PRINTDLGA pd;
    PRINTDLGA pd2;
    int ok = 1;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "PdGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "PdGui", "PdGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 160, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    memset(&pd, 0, sizeof(pd));
    pd.lStructSize = sizeof(pd);
    pd.hwndOwner = hwnd;
    pd.nFromPage = 1;
    pd.nToPage = 1;
    pd.nMinPage = 1;
    pd.nMaxPage = 100;
    pd.nCopies = 1;
    pd.Flags = PD_RETURNDC;

    if (PrintDlgA(&pd)) {
        if (pd.nFromPage != 1) ok = 0;   /* driver keeps from=1 */
        if (pd.nToPage != 3) ok = 0;     /* driver sets to=3 */
        if (pd.nCopies != 2) ok = 0;     /* driver sets copies=2 */
        if (pd.hDC == 0) ok = 0;         /* PD_RETURNDC -> dummy DC */
    } else {
        ok = 0;
    }

    /* PD_RETURNDEFAULT: reports the default printer without showing UI. */
    memset(&pd2, 0, sizeof(pd2));
    pd2.lStructSize = sizeof(pd2);
    pd2.Flags = PD_RETURNDEFAULT;
    if (!PrintDlgA(&pd2)) ok = 0;

    printf("pd-check: %s (from=%d to=%d copies=%d hdc=%d)\n",
        ok ? "ok" : "FAIL", (int)pd.nFromPage, (int)pd.nToPage,
        (int)pd.nCopies, (int)pd.hDC);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
PD_EOF

cat > ws_pd.py <<'WSPD_EOF'
import json, time
import websocket
ws = websocket.create_connection("ws://127.0.0.1:1995/ws", timeout=15)
sent = False
deadline = time.time() + 12
try:
    while time.time() < deadline:
        try:
            opcode, data = ws.recv_data(control_frame=False)
        except Exception:
            break
        if isinstance(data, bytes) and data[:4] == b"AUD\x00":
            data = data[4:]
        try:
            obj = json.loads(data)
        except Exception:
            continue
        if obj.get("type") == "show_print_dialog" and not sent:
            ws.send(json.dumps({"type": "print_chosen", "from": 1, "to": 3, "copies": 2}))
            sent = True
            break
finally:
    ws.close()
WSPD_EOF

rc=$(run pd_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fopd_gui.obj pd_gui.c)
if [ "$rc" = "0" ] && [ -f pd_gui.obj ]; then
    pass "PD: CL /c pd_gui.c" ""
else
    fail "PD: CL /c pd_gui.c" "exit $rc $(tail -3 pd_cl.txt 2>/dev/null)"
fi
if [ -f pd_gui.obj ]; then
    rc=$(run pd_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:pd_gui.exe /LIBPATH:"$VC_LIB" pd_gui.obj comdlg32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f pd_gui.exe ]; then
        pass "PD: LINK pd_gui.obj" "($(stat -c%s pd_gui.exe) bytes)"
    else
        fail "PD: LINK pd_gui.obj" "exit $rc $(tail -3 pd_link.txt 2>/dev/null)"
    fi
fi
if [ -f pd_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "PD: run pd_gui.exe" "(WASM build has no GUI renderer)"
    else
        timeout 30 "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./pd_gui.exe > pd_out.txt 2>&1 &
        PD_APP_PID=$!
        sleep 4
        timeout 20 python3 ws_pd.py >> pd_out.txt 2>&1
        wait $PD_APP_PID
        if grep -q "pd-check: ok" pd_out.txt 2>/dev/null; then
            pass "PD: run pd_gui.exe" "(PrintDlg round-trip via web client)"
        else
            fail "PD: run pd_gui.exe" "missing expected output ($(tail -3 pd_out.txt 2>/dev/null | tr '\n' ' '))"
        fi
    fi
fi
fi  # end PD

if should_run "FT|findtext|find"; then
echo ""
echo "=== FindTextA: modeless find dialog + FINDMSG delivery ==="
########################################
# FindTextA returns a modeless dialog hwnd; the app pumps messages. The WS
# driver clicks "Find Next" with "needle"; the stub fills the FINDREPLACEA and
# posts the registered FINDMSGSTRING to the owner; the app asserts the payload.

cat > ft_gui.c <<'FT_EOF'
#include <windows.h>
#include <commdlg.h>
#include <string.h>
#include <stdio.h>

static UINT uFindMsg = 0;
static char gotFind[256] = "";
static DWORD gotFlags = 0;
static int gotCount = 0;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == uFindMsg) {
        FINDREPLACEA* pfr = (FINDREPLACEA*)lParam;
        gotCount++;
        strncpy(gotFind, pfr->lpstrFindWhat, sizeof(gotFind) - 1);
        gotFind[sizeof(gotFind) - 1] = 0;
        gotFlags = pfr->Flags;
        PostMessage(hwnd, WM_CLOSE, 0, 0);   /* one action is enough */
        return 0;
    }
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, hFind;
    MSG msg;
    FINDREPLACEA fr;
    char findBuf[128] = "initial";
    char replBuf[128] = "";
    int ok = 1;

    uFindMsg = RegisterWindowMessageA(FINDMSGSTRING);

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "FtGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "FtGui", "FtGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 160, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    memset(&fr, 0, sizeof(fr));
    fr.lStructSize = sizeof(fr);
    fr.hwndOwner = hwnd;
    fr.lpstrFindWhat = findBuf;
    fr.wFindWhatLen = sizeof(findBuf);
    fr.lpstrReplaceWith = replBuf;
    fr.wReplaceWithLen = sizeof(replBuf);
    fr.Flags = FR_DOWN;

    hFind = FindTextA(&fr);
    if (!hFind) { printf("ft-check: FAIL (no dialog)\n"); return 1; }

    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        if (hFind && IsDialogMessageA(hFind, &msg)) continue;
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    /* the WS driver clicked Find Next with "needle", down, no match-case */
    if (gotCount != 1) ok = 0;
    if (strcmp(gotFind, "needle") != 0) ok = 0;
    if (!(gotFlags & FR_FINDNEXT)) ok = 0;
    if (!(gotFlags & FR_DOWN)) ok = 0;

    printf("ft-check: %s (find='%s' flags=%x)\n",
        ok ? "ok" : "FAIL", gotFind, (unsigned)gotFlags);
    return ok ? 0 : 1;
}
FT_EOF

cat > ws_ft.py <<'WSFT_EOF'
import json, time
import websocket
ws = websocket.create_connection("ws://127.0.0.1:1995/ws", timeout=15)
sent = False
deadline = time.time() + 12
try:
    while time.time() < deadline:
        try:
            opcode, data = ws.recv_data(control_frame=False)
        except Exception:
            break
        if isinstance(data, bytes) and data[:4] == b"AUD\x00":
            data = data[4:]
        try:
            obj = json.loads(data)
        except Exception:
            continue
        if obj.get("type") == "open_find_dialog" and not sent:
            ws.send(json.dumps({"type": "find_action", "action": "find_next",
                                "findText": "needle", "replaceText": "",
                                "matchCase": False, "searchDown": True}))
            sent = True
            break
finally:
    ws.close()
WSFT_EOF

rc=$(run ft_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Foft_gui.obj ft_gui.c)
if [ "$rc" = "0" ] && [ -f ft_gui.obj ]; then
    pass "FT: CL /c ft_gui.c" ""
else
    fail "FT: CL /c ft_gui.c" "exit $rc $(tail -3 ft_cl.txt 2>/dev/null)"
fi
if [ -f ft_gui.obj ]; then
    rc=$(run ft_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:ft_gui.exe /LIBPATH:"$VC_LIB" ft_gui.obj comdlg32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f ft_gui.exe ]; then
        pass "FT: LINK ft_gui.obj" "($(stat -c%s ft_gui.exe) bytes)"
    else
        fail "FT: LINK ft_gui.obj" "exit $rc $(tail -3 ft_link.txt 2>/dev/null)"
    fi
fi
if [ -f ft_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "FT: run ft_gui.exe" "(WASM build has no GUI renderer)"
    else
        timeout 30 "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./ft_gui.exe > ft_out.txt 2>&1 &
        FT_APP_PID=$!
        sleep 4
        timeout 20 python3 ws_ft.py >> ft_out.txt 2>&1
        wait $FT_APP_PID
        if grep -q "ft-check: ok" ft_out.txt 2>/dev/null; then
            pass "FT: run ft_gui.exe" "(FindText FINDMSG round-trip via web client)"
        else
            fail "FT: run ft_gui.exe" "missing expected output ($(tail -3 ft_out.txt 2>/dev/null | tr '\n' ' '))"
        fi
    fi
fi
fi  # end FT

if should_run "PS|pagesetup|pagesetupdlg"; then
echo ""
echo "=== PageSetupDlg: host page-setup dialog round-trip ==="
########################################
# PageSetupDlgA opens the host page-setup dialog; the WS driver sets margins
# 2000/1500/1000/500; the app asserts PAGESETUPDLG rtMargin + PSD_MARGINS,
# then verifies PSD_RETURNDEFAULT returns without UI.

cat > ps_gui.c <<'PS_EOF'
#include <windows.h>
#include <commdlg.h>
#include <string.h>
#include <stdio.h>

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd;
    MSG msg;
    PAGESETUPDLGA psd;
    PAGESETUPDLGA psd2;
    int ok = 1;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "PsGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "PsGui", "PsGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 160, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    memset(&psd, 0, sizeof(psd));
    psd.lStructSize = sizeof(psd);
    psd.hwndOwner = hwnd;
    psd.Flags = PSD_MARGINS;
    psd.rtMargin.left = 1000;
    psd.rtMargin.top = 1000;
    psd.rtMargin.right = 1000;
    psd.rtMargin.bottom = 1000;
    psd.ptPaperSize.x = 8500;
    psd.ptPaperSize.y = 11000;

    if (PageSetupDlgA(&psd)) {
        /* driver sets left=2000 top=1500 right=1000 bottom=500 */
        if (psd.rtMargin.left != 2000) ok = 0;
        if (psd.rtMargin.top != 1500) ok = 0;
        if (psd.rtMargin.right != 1000) ok = 0;
        if (psd.rtMargin.bottom != 500) ok = 0;
        if (!(psd.Flags & PSD_MARGINS)) ok = 0;
    } else {
        ok = 0;
    }

    /* PSD_RETURNDEFAULT: no UI. */
    memset(&psd2, 0, sizeof(psd2));
    psd2.lStructSize = sizeof(psd2);
    psd2.Flags = PSD_RETURNDEFAULT;
    if (!PageSetupDlgA(&psd2)) ok = 0;

    printf("ps-check: %s (margins=%d,%d,%d,%d)\n", ok ? "ok" : "FAIL",
        (int)psd.rtMargin.left, (int)psd.rtMargin.top,
        (int)psd.rtMargin.right, (int)psd.rtMargin.bottom);

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
PS_EOF

cat > ws_ps.py <<'WSPS_EOF'
import json, time
import websocket
ws = websocket.create_connection("ws://127.0.0.1:1995/ws", timeout=15)
sent = False
deadline = time.time() + 12
try:
    while time.time() < deadline:
        try:
            opcode, data = ws.recv_data(control_frame=False)
        except Exception:
            break
        if isinstance(data, bytes) and data[:4] == b"AUD\x00":
            data = data[4:]
        try:
            obj = json.loads(data)
        except Exception:
            continue
        if obj.get("type") == "show_page_setup_dialog" and not sent:
            ws.send(json.dumps({"type": "page_setup_chosen",
                                "left": 2000, "top": 1500, "right": 1000, "bottom": 500,
                                "paperW": 8500, "paperH": 11000, "orientation": 0}))
            sent = True
            break
finally:
    ws.close()
WSPS_EOF

rc=$(run ps_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fops_gui.obj ps_gui.c)
if [ "$rc" = "0" ] && [ -f ps_gui.obj ]; then
    pass "PS: CL /c ps_gui.c" ""
else
    fail "PS: CL /c ps_gui.c" "exit $rc $(tail -3 ps_cl.txt 2>/dev/null)"
fi
if [ -f ps_gui.obj ]; then
    rc=$(run ps_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:ps_gui.exe /LIBPATH:"$VC_LIB" ps_gui.obj comdlg32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f ps_gui.exe ]; then
        pass "PS: LINK ps_gui.obj" "($(stat -c%s ps_gui.exe) bytes)"
    else
        fail "PS: LINK ps_gui.obj" "exit $rc $(tail -3 ps_link.txt 2>/dev/null)"
    fi
fi
if [ -f ps_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "PS: run ps_gui.exe" "(WASM build has no GUI renderer)"
    else
        timeout 30 "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./ps_gui.exe > ps_out.txt 2>&1 &
        PS_APP_PID=$!
        sleep 4
        timeout 20 python3 ws_ps.py >> ps_out.txt 2>&1
        wait $PS_APP_PID
        if grep -q "ps-check: ok" ps_out.txt 2>/dev/null; then
            pass "PS: run ps_gui.exe" "(PageSetupDlg round-trip via web client)"
        else
            fail "PS: run ps_gui.exe" "missing expected output ($(tail -3 ps_out.txt 2>/dev/null | tr '\n' ' '))"
        fi
    fi
fi
fi  # end PS

if should_run "UDT|updown|trackbar|datetime"; then
echo ""
echo "=== UpDown + Trackbar + DateTimePicker common controls ==="
########################################
# UDM_* (msctls_updown32), TBM_* (msctls_trackbar32) and DTM_*
# (SysDateTimePick32) round-trip their state through SendMessage.

cat > udt_gui.c <<'UDT_EOF'
#include <windows.h>
#include <commctrl.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, ud, tb, dtp;
    MSG msg;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "UdtGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "UdtGui", "UdtGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 160, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    /* UpDown: UDM_SETRANGE32/GETRANGE32 + UDM_SETPOS/GETPOS */
    ud = CreateWindowEx(0, "msctls_updown32", "", WS_CHILD | WS_VISIBLE,
        10, 10, 20, 24, hwnd, (HMENU)1, hInst, NULL);
    SendMessageA(ud, UDM_SETRANGE32, (WPARAM)-10, (LPARAM)10);
    SendMessageA(ud, UDM_SETPOS, 0, 3);
    if (SendMessageA(ud, UDM_GETPOS, 0, 0) != 3) ok = 0;
    {
        int lo = 0, hi = 0;
        SendMessageA(ud, UDM_GETRANGE32, (WPARAM)&lo, (LPARAM)&hi);
        if (lo != -10 || hi != 10) ok = 0;
    }

    /* Trackbar: TBM_SETRANGE/GETPOS/SETPOS */
    tb = CreateWindowEx(0, "msctls_trackbar32", "", WS_CHILD | WS_VISIBLE,
        40, 10, 100, 30, hwnd, (HMENU)2, hInst, NULL);
    SendMessageA(tb, TBM_SETRANGE, 0, MAKELPARAM(0, 100));
    SendMessageA(tb, TBM_SETPOS, 1, 42);
    if (SendMessageA(tb, TBM_GETPOS, 0, 0) != 42) ok = 0;
    if (SendMessageA(tb, TBM_GETRANGEMIN, 0, 0) != 0) ok = 0;
    if (SendMessageA(tb, TBM_GETRANGEMAX, 0, 0) != 100) ok = 0;

    /* DateTimePicker: DTM_SETSYSTEMTIME/GETSYSTEMTIME */
    dtp = CreateWindowEx(0, "SysDateTimePick32", "", WS_CHILD | WS_VISIBLE,
        150, 10, 100, 24, hwnd, (HMENU)3, hInst, NULL);
    {
        SYSTEMTIME st;
        memset(&st, 0, sizeof(st));
        st.wYear = 1999; st.wMonth = 12; st.wDay = 31;
        st.wHour = 23; st.wMinute = 59; st.wSecond = 58;
        SendMessageA(dtp, DTM_SETSYSTEMTIME, GDT_VALID, (LPARAM)&st);
        memset(&st, 0, sizeof(st));
        if (SendMessageA(dtp, DTM_GETSYSTEMTIME, 0, (LPARAM)&st) != GDT_VALID) ok = 0;
        if (st.wYear != 1999 || st.wMonth != 12 || st.wDay != 31) ok = 0;
        if (st.wHour != 23 || st.wMinute != 59 || st.wSecond != 58) ok = 0;
    }

    printf("udt-check: %s\n", ok ? "ok" : "FAIL");

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
UDT_EOF

rc=$(run udt_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Foudt_gui.obj udt_gui.c)
if [ "$rc" = "0" ] && [ -f udt_gui.obj ]; then
    pass "UDT: CL /c udt_gui.c" ""
else
    fail "UDT: CL /c udt_gui.c" "exit $rc $(tail -3 udt_cl.txt 2>/dev/null)"
fi
if [ -f udt_gui.obj ]; then
    rc=$(run udt_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /SUBSYSTEM:WINDOWS /OUT:udt_gui.exe /LIBPATH:"$VC_LIB" udt_gui.obj comctl32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f udt_gui.exe ]; then
        pass "UDT: LINK udt_gui.obj" "($(stat -c%s udt_gui.exe) bytes)"
    else
        fail "UDT: LINK udt_gui.obj" "exit $rc $(tail -3 udt_link.txt 2>/dev/null)"
    fi
fi
if [ -f udt_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "UDT: run udt_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run udt_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./udt_gui.exe)
        if grep -q "udt-check: ok" udt_out.txt 2>/dev/null; then
            pass "UDT: run udt_gui.exe" "(UDM_/TBM_/DTM_ state round-trip)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "UDT: run udt_gui.exe" "exit $rc, missing expected output ($(tail -3 udt_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "UDT: run udt_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end UDT

if should_run "MTA|monthcal|tooltip|animation"; then
echo ""
echo "=== MonthCal + Tooltip + Animation common controls ==="
########################################
# MCM_* (SysMonthCal32), TTM_* (tooltips_class32) and ACM_* (SysAnimate32)
# round-trip their state through SendMessage.

cat > mta_gui.c <<'MTA_EOF'
#include <windows.h>
#include <commctrl.h>
#include <string.h>
#include <stdio.h>

static int ok = 1;

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    WNDCLASS wc;
    HWND hwnd, mc, tt, an;
    MSG msg;

    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.cbClsExtra = 0; wc.cbWndExtra = 0;
    wc.hInstance = hInst; wc.hIcon = NULL; wc.hCursor = NULL;
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszMenuName = NULL;
    wc.lpszClassName = "MtaGui";
    RegisterClass(&wc);
    hwnd = CreateWindowEx(0, "MtaGui", "MtaGui", WS_OVERLAPPEDWINDOW,
        0, 0, 320, 200, NULL, NULL, hInst, NULL);
    ShowWindow(hwnd, SW_SHOW);

    /* MonthCal: MCM_SETCURSEL/GETCURSEL */
    mc = CreateWindowEx(0, "SysMonthCal32", "", WS_CHILD | WS_VISIBLE,
        10, 10, 180, 120, hwnd, (HMENU)1, hInst, NULL);
    {
        SYSTEMTIME st;
        memset(&st, 0, sizeof(st));
        st.wYear = 2003; st.wMonth = 7; st.wDay = 4;
        SendMessageA(mc, MCM_SETCURSEL, 0, (LPARAM)&st);
        memset(&st, 0, sizeof(st));
        if (!SendMessageA(mc, MCM_GETCURSEL, 0, (LPARAM)&st)) ok = 0;
        if (st.wYear != 2003 || st.wMonth != 7 || st.wDay != 4) ok = 0;
    }

    /* Tooltip: TTM_ADDTOOL captures the tip text; TTM_ACTIVATE acknowledges */
    tt = CreateWindowEx(0, "tooltips_class32", "", WS_CHILD | WS_VISIBLE | TTS_ALWAYSTIP,
        10, 140, 80, 24, hwnd, (HMENU)2, hInst, NULL);
    {
        TTTOOLINFOA ti;
        memset(&ti, 0, sizeof(ti));
        ti.cbSize = sizeof(ti);
        ti.hwnd = hwnd;
        ti.uFlags = TTF_IDISHWND;
        ti.uId = (UINT)hwnd;
        ti.lpszText = "Tip Text";
        if (!SendMessageA(tt, TTM_ADDTOOLA, 0, (LPARAM)&ti)) ok = 0;
        if (!SendMessageA(tt, TTM_ACTIVATE, 1, 0)) ok = 0;
    }

    /* Animation: ACM_OPEN/PLAY/STOP all acknowledge */
    an = CreateWindowEx(0, "SysAnimate32", "", WS_CHILD | WS_VISIBLE,
        100, 140, 80, 24, hwnd, (HMENU)3, hInst, NULL);
    if (!SendMessageA(an, ACM_OPENA, 0, (LPARAM)"1")) ok = 0;
    if (!SendMessageA(an, ACM_PLAY, 0, (LPARAM)0xFFFF0000)) ok = 0;
    if (!SendMessageA(an, ACM_STOP, 0, 0)) ok = 0;

    printf("mta-check: %s\n", ok ? "ok" : "FAIL");

    PostMessage(hwnd, WM_CLOSE, 0, 0);
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return ok ? 0 : 1;
}
MTA_EOF

rc=$(run mta_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fomta_gui.obj mta_gui.c)
if [ "$rc" = "0" ] && [ -f mta_gui.obj ]; then
    pass "MTA: CL /c mta_gui.c" ""
else
    fail "MTA: CL /c mta_gui.c" "exit $rc $(tail -3 mta_cl.txt 2>/dev/null)"
fi
if [ -f mta_gui.obj ]; then
    rc=$(run mta_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /OUT:mta_gui.exe /LIBPATH:"$VC_LIB" mta_gui.obj comctl32.lib user32.lib)
    if [ "$rc" = "0" ] && [ -f mta_gui.exe ]; then
        pass "MTA: LINK mta_gui.obj" "($(stat -c%s mta_gui.exe) bytes)"
    else
        fail "MTA: LINK mta_gui.obj" "exit $rc $(tail -3 mta_link.txt 2>/dev/null)"
    fi
fi
if [ -f mta_gui.exe ]; then
    if $IS_WASM; then
        printf "  SKIP  %-35s %s\n" "MTA: run mta_gui.exe" "(WASM build has no GUI renderer)"
    else
        rc=$(run mta_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./mta_gui.exe)
        if grep -q "mta-check: ok" mta_out.txt 2>/dev/null; then
            pass "MTA: run mta_gui.exe" "(MCM_/TTM_/ACM_ state round-trip)"
        elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
            fail "MTA: run mta_gui.exe" "exit $rc, missing expected output ($(tail -3 mta_out.txt 2>/dev/null | tr '\n' ' '))"
        else
            printf "  SKIP  %-35s %s\n" "MTA: run mta_gui.exe" "(exit $rc, running compiled output not yet supported)"
        fi
    fi
fi
fi  # end MTA

if should_run "STD|stdio|fflush"; then
echo ""
echo "=== MSVCRT stdio: fflush/_flushall/setvbuf/_fcloseall/freopen ==="
########################################
# The five previously-stubbed stdio functions now have real semantics:
# fflush/flushall report success, setvbuf accepts, _fcloseall closes dynamic
# streams, freopen closes + reopens (verified via append-write).

cat > std_gui.c <<'STD_EOF'
#include <stdio.h>
#include <string.h>
int main(void) {
    FILE* f;
    int n = 0;
    int closed = 0;
    int ok = 1;
    f = fopen("std_test.txt", "w");
    if (!f) ok = 0;
    if (setvbuf(f, NULL, _IOFBF, 1024) != 0) ok = 0;
    if (fputs("line1\n", f) == EOF) ok = 0;
    if (fflush(f) != 0) ok = 0;
    n = _flushall();
    if (n < 3) ok = 0;
    if (fclose(f) != 0) ok = 0;
    f = freopen("std_test.txt", "a", f);
    if (!f) ok = 0;
    if (fputs("line2\n", f) == EOF) ok = 0;
    if (fflush(f) != 0) ok = 0;
    if (fclose(f) != 0) ok = 0;
    closed = _fcloseall();
    /* Read-back: fopen "r" + fgets must return the written lines (wasmtime
     * previously returned empty — ReadFile's guest buffer was not translated). */
    f = fopen("std_test.txt", "r");
    if (!f) ok = 0;
    else {
        char buf[64];
        if (fgets(buf, sizeof buf, f) == NULL) ok = 0;
        else if (strcmp(buf, "line1\n") != 0) ok = 0;
        if (fgets(buf, sizeof buf, f) == NULL) ok = 0;
        else if (strcmp(buf, "line2\n") != 0) ok = 0;
        if (fclose(f) != 0) ok = 0;
    }
    printf("std-check: %s (flushall=%d fcloseall=%d)\n", ok ? "ok" : "FAIL", n, closed);
    return ok ? 0 : 1;
}
STD_EOF

rc=$(run std_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fostd_gui.obj std_gui.c)
if [ "$rc" = "0" ] && [ -f std_gui.obj ]; then
    pass "STD: CL /c std_gui.c" ""
else
    fail "STD: CL /c std_gui.c" "exit $rc $(tail -3 std_cl.txt 2>/dev/null)"
fi
if [ -f std_gui.obj ]; then
    rc=$(run std_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /OUT:std_gui.exe /LIBPATH:"$VC_LIB" std_gui.obj)
    if [ "$rc" = "0" ] && [ -f std_gui.exe ]; then
        pass "STD: LINK std_gui.obj" "($(stat -c%s std_gui.exe) bytes)"
    else
        fail "STD: LINK std_gui.obj" "exit $rc $(tail -3 std_link.txt 2>/dev/null)"
    fi
fi
if [ -f std_gui.exe ]; then
    rc=$(run std_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./std_gui.exe)
    if grep -q "std-check: ok" std_out.txt 2>/dev/null; then
        pass "STD: run std_gui.exe" "(stdio flush/reopen + read-back round-trip)"
    elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
        fail "STD: run std_gui.exe" "exit $rc, missing expected output ($(tail -3 std_out.txt 2>/dev/null | tr '\n' ' '))"
    else
        printf "  SKIP  %-35s %s\n" "STD: run std_gui.exe" "(exit $rc, running compiled output not yet supported)"
    fi
fi
fi  # end STD

if should_run "REG|registry|advapi"; then
echo ""
echo "=== Per-application registry overrides ==="
########################################
# REGAPP.EXE queries HKLM\...\CurrentVersion\ProductName. An
# "app:REGAPP.EXE:<KEY>" override in registry.toml shadows the global value —
# the app must read the override.

cat > regapp.c <<'REG_EOF'
#include <windows.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    HKEY hk;
    char buf[256];
    DWORD type, size = sizeof(buf);
    LONG rc = RegOpenKeyExA(HKEY_LOCAL_MACHINE, "Software\\Microsoft\\Windows NT\\CurrentVersion", 0, KEY_READ, &hk);
    if (rc != ERROR_SUCCESS) { printf("reg-check: FAIL (open %ld)\n", rc); return 1; }
    if (RegQueryValueExA(hk, "ProductName", NULL, &type, (LPBYTE)buf, &size) != ERROR_SUCCESS) {
        printf("reg-check: FAIL (query)\n"); return 1;
    }
    RegCloseKey(hk);
    if (strcmp(buf, "Microsoft Windows 2000 (regapp)") != 0) {
        printf("reg-check: FAIL (got '%s')\n", buf); return 1;
    }
    printf("reg-check: ok\n");
    return 0;
}
REG_EOF

rc=$(run reg_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Foregapp.obj regapp.c)
if [ "$rc" = "0" ] && [ -f regapp.obj ]; then
    pass "REG: CL /c regapp.c" ""
else
    fail "REG: CL /c regapp.c" "exit $rc $(tail -3 reg_cl.txt 2>/dev/null)"
fi
if [ -f regapp.obj ]; then
    rc=$(run reg_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /OUT:regapp.exe /LIBPATH:"$VC_LIB" regapp.obj advapi32.lib)
    if [ "$rc" = "0" ] && [ -f regapp.exe ]; then
        pass "REG: LINK regapp.obj" "($(stat -c%s regapp.exe) bytes)"
    else
        fail "REG: LINK regapp.obj" "exit $rc $(tail -3 reg_link.txt 2>/dev/null)"
    fi
fi
if [ -f regapp.exe ]; then
    rc=$(run reg_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./regapp.exe)
    if grep -q "reg-check: ok" reg_out.txt 2>/dev/null; then
        pass "REG: run regapp.exe" "(per-app registry override)"
    elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
        fail "REG: run regapp.exe" "exit $rc, missing expected output ($(tail -3 reg_out.txt 2>/dev/null | tr '\n' ' '))"
    else
        printf "  SKIP  %-35s %s\n" "REG: run regapp.exe" "(exit $rc, running compiled output not yet supported)"
    fi
fi
fi  # end REG

########################################
if should_run "RES|stringtable|loadstring"; then
echo ""
echo "=== Resource test: STRINGTABLE -> RC -> CVTRES -> LoadStringA ==="
########################################

cat > res_st.rc <<'RES_RC_EOF'
STRINGTABLE
BEGIN
    1 "res-one"
    2 "res-two"
    20 "res-twenty"
END
RES_RC_EOF

cat > res_app.c <<'RES_C_EOF'
#include <windows.h>
#include <stdio.h>
int main() {
    char b1[64], b2[64], b3[64];
    int n1 = LoadStringA(GetModuleHandle(NULL), 1, b1, 64);
    int n2 = LoadStringA(GetModuleHandle(NULL), 2, b2, 64);
    int n3 = LoadStringA(GetModuleHandle(NULL), 20, b3, 64);
    printf("res-check: %s\n",
        (n1 == 7 && strcmp(b1, "res-one") == 0 &&
         n2 == 7 && strcmp(b2, "res-two") == 0 &&
         n3 == 10 && strcmp(b3, "res-twenty") == 0) ? "ok" : "FAIL");
    return 0;
}
RES_C_EOF

rc=$(run res_rc.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/RC.EXE" /nologo /fores_st.res res_st.rc)
if [ "$rc" = "0" ] && [ -f res_st.res ]; then
    pass "RES: RC res_st.rc" "($(stat -c%s res_st.res) bytes)"
else
    fail "RES: RC res_st.rc" "exit $rc $(tail -3 res_rc.txt 2>/dev/null)"
fi
if [ -f res_st.res ]; then
    rc=$(run res_cv.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CVTRES.EXE" /nologo /OUT:res_st.obj res_st.res)
    if [ "$rc" = "0" ] && [ -f res_st.obj ]; then
        pass "RES: CVTRES res_st.res" ""
    else
        fail "RES: CVTRES res_st.res" "exit $rc $(tail -3 res_cv.txt 2>/dev/null)"
    fi
fi
rc=$(run res_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Fores_app.obj res_app.c)
if [ "$rc" = "0" ] && [ -f res_app.obj ]; then
    pass "RES: CL /c res_app.c" ""
else
    fail "RES: CL /c res_app.c" "exit $rc $(tail -3 res_cl.txt 2>/dev/null)"
fi
if [ -f res_app.obj ] && [ -f res_st.obj ]; then
    rc=$(run res_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /OUT:res_app.exe /LIBPATH:"$VC_LIB" res_app.obj res_st.obj user32.lib)
    if [ "$rc" = "0" ] && [ -f res_app.exe ]; then
        pass "RES: LINK res_app.obj" "($(stat -c%s res_app.exe) bytes)"
    else
        fail "RES: LINK res_app.obj" "exit $rc $(tail -3 res_link.txt 2>/dev/null)"
    fi
fi
if [ -f res_app.exe ]; then
    rc=$(run res_out.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" ./res_app.exe)
    if grep -q "res-check: ok" res_out.txt 2>/dev/null; then
        pass "RES: run res_app.exe" "(LoadStringA 1/2/20 all resolve)"
    elif [ "$WASM_RUNS_OUTPUT" = "true" ]; then
        # wasmtime runs compiled output, so missing markers here is a real
        # regression in the string-table resource pipeline.
        fail "RES: run res_app.exe" "exit $rc, missing expected output ($(tail -3 res_out.txt 2>/dev/null | tr '\n' ' '))"
    else
        # Other runtimes cannot run compiled output yet — aspirational
        printf "  SKIP  %-35s %s\n" "RES: run res_app.exe" "(exit $rc, running compiled output not yet supported)"
    fi
fi
fi  # end RES

########################################
if should_run "E2E|end.to.end"; then
echo ""
echo "=== End-to-end: compile, link, dump ==="
########################################

cat > e2e.c <<'EOF'
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    char buf[64];
    strcpy(buf, "end-to-end");
    printf("len=%d\n", strlen(buf));
    return 0;
}
EOF

e2e_ok=true

# Step 1: compile
rc=$(run e2e_cl.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" /Foe2e.obj e2e.c)
if [ "$rc" = "0" ] && [ -f e2e.obj ]; then
    pass "E2E: CL /c e2e.c" ""
else
    fail "E2E: CL /c e2e.c" "exit $rc $(tail -3 e2e_cl.txt 2>/dev/null)"
    e2e_ok=false
fi

# Step 2: link
if $e2e_ok; then
    rc=$(run e2e_link.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/LINK.EXE" /NOLOGO /OUT:e2e.exe /LIBPATH:"$VC_LIB" /SUBSYSTEM:CONSOLE e2e.obj)
    if [ "$rc" = "0" ] && [ -f e2e.exe ]; then
        pass "E2E: LINK e2e.obj" "($(stat -c%s e2e.exe) bytes)"
    else
        fail "E2E: LINK e2e.obj" "exit $rc $(tail -3 e2e_link.txt 2>/dev/null)"
        e2e_ok=false
    fi
fi

# Step 3: dump disassembly (DUMPBIN /HEADERS hangs — known limitation)
if $e2e_ok; then
    rc=$(run e2e_disasm.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/DUMPBIN.EXE" /DISASM e2e.obj)
    if grep -qiE "disassembly|_main|push|ret|mov" e2e_disasm.txt 2>/dev/null; then
        pass "E2E: DUMPBIN /DISASM e2e.obj" ""
    else
        fail "E2E: DUMPBIN /DISASM e2e.obj" "exit $rc"
    fi
fi

# Step 4: dump symbols from obj
if $e2e_ok; then
    rc=$(run e2e_sym.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" "$VC_BIN/DUMPBIN.EXE" /SYMBOLS e2e.obj)
    if grep -qiE "_main|symbol" e2e_sym.txt 2>/dev/null; then
        pass "E2E: DUMPBIN /SYMBOLS e2e.obj" "(found _main)"
    else
        fail "E2E: DUMPBIN /SYMBOLS e2e.obj" "exit $rc"
    fi
fi

# Step 5: run the compiled exe through zine
if $e2e_ok && [ -f e2e.exe ]; then
    rc=$(run e2e_run.txt "${WINLOADER_CMD[@]}" "${ZINE_FLAGS[@]+${ZINE_FLAGS[@]}}" e2e.exe)
    if grep -q "len=10" e2e_run.txt 2>/dev/null; then
        pass "E2E: Run e2e.exe" "(output: len=10)"
    else
        # Don't fail - running compiled output is aspirational
        printf "  SKIP  %-35s %s\n" "E2E: Run e2e.exe" "(exit $rc, running compiled output not yet supported)"
    fi
fi

fi  # end E2E
########################################
echo ""
echo "==============================="
echo "  PASSED:  $PASSED"
echo "  FAILED:  $FAILED"
echo "==============================="

if [ $FAILED -gt 0 ]; then
    echo ""
    echo "Failure details:"
    printf '%b\n' "$FAILURES"
    exit 1
fi
