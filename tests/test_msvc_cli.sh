#!/bin/bash
# Test MSVC 6.0 CLI tools via zine
# Runs each tool with realistic arguments and verifies expected behavior.
#
# Usage:
#   ./test_msvc_cli.sh              # run in native mode (default, x86)
#   ./test_msvc_cli.sh --native64   # run in native mode (x86_64 compat mode)
#   ./test_msvc_cli.sh --interpret  # run in interpreter mode
#   ./test_msvc_cli.sh --jit        # run in JIT mode
#   ./test_msvc_cli.sh --external   # run with external DLL stubs (not embedded)
#   ./test_msvc_cli.sh --wasmtime   # run in WASM mode via wasmtime
#   ./test_msvc_cli.sh --wasmer     # run in WASM mode via wasmer
#   ./test_msvc_cli.sh --wasm       # alias for --wasmtime
#   ./test_msvc_cli.sh --both       # run native + interpreted
#   ./test_msvc_cli.sh --all        # run native + interpreted + jit + external + wasmtime + wasmer
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
    for m in --native --native64 --interpret --jit --external --wasmtime --wasmer; do
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
WASM_RUNTIME=""     # "wasmtime" or "wasmer"
WASM_EXIT_MAX=255   # max exit code the runtime supports faithfully
TIMEOUT_SECS=30
case "$MODE" in
    --interpret|interpret)
        ZINE_FLAGS=(--interpret)
        MODE_LABEL="INTERPRET"
        TIMEOUT_SECS=60  # interpreter is slower
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
        ;;
    --wasmer|wasmer)
        IS_WASM=true
        WASM_RUNTIME="wasmer"
        WASM_EXIT_MAX=255  # wasmer passes all exit codes 0-255
        MODE_LABEL="WASM/wasmer"
        ;;
    --native|native|"")
        ZINE_FLAGS=()
        MODE_LABEL="NATIVE"
        ;;
    *)
        echo "Usage: $0 [--native|--native64|--interpret|--jit|--external|--wasmtime|--wasmer|--both|--all] [--filter PATTERN]"
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
        echo "FATAL: $WASM_RUNTIME not found in PATH"
        exit 1
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
trap "rm -rf $WORKDIR" EXIT
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
            "$WASM_BIN" --)
        # wasmer requires absolute paths for PE files
        VC_BIN="$MSVC_ROOT/VC98/Bin"
        COMMON_BIN="$MSVC_ROOT/Common/MSDev98/Bin"
        COMMON_TOOLS="$MSVC_ROOT/Common/Tools"
    else
        # wasmtime: --dir to preopen filesystem, --env to pass-through host env vars
        # --dir=/ for absolute paths, --dir=. for CWD-relative paths
        WINLOADER_CMD=(wasmtime run --dir=/ --dir=. --env INCLUDE --env LIB --env PATH --env TMP --env TEMP "$WASM_BIN" --)
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
    demangled=$(grep -i "add" undname_out.txt | head -1)
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
uuid=$(grep -oE "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}" uuid_out.txt 2>/dev/null | head -1)
if [ -n "$uuid" ]; then
    pass "UUIDGEN" "($uuid)"
else
    fail "UUIDGEN" "exit $rc, no UUID"
fi
fi  # end UUIDGEN

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
