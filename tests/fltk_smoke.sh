#!/usr/bin/env bash
# tests/fltk_smoke.sh — FLTK backend verification under Xvfb.
#
# Compiles and runs the self-exiting GUI apps from test_msvc_cli.sh under the
# x86_64 FLTK build (zine.x86_64 --fltk), checking each app's -check/-done
# output. The WS-driven apps (CC/CF/PD/FT/PS) are excluded: their host
# dialogs are modal and can't be driven by the WebSocket client.
#
# Usage:
#   ./fltk_smoke.sh            # build + run all apps under DISPLAY=:1
#   ./fltk_smoke.sh --skip-build
#   DISPLAY_NO=:2 ./fltk_smoke.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(realpath "$SCRIPT_DIR/..")"
MSVC_ROOT="$ROOT/tools/MSVC600"
# Same fixtures test_msvc_cli.sh needs: proprietary, absent from a clone.
# Checked before the build so a missing prerequisite is not reported as a
# build error.
if [ ! -d "$MSVC_ROOT" ]; then
    echo "FATAL: MSVC 6.0 fixtures missing at $MSVC_ROOT" >&2
    echo "see README.md (Testing) for the directories to place there" >&2
    exit 1
fi
MSVC_ROOT="$(realpath "$MSVC_ROOT")"
VC_BIN="$MSVC_ROOT/VC98/Bin"
VC_INCLUDE="$MSVC_ROOT/VC98/Include"
VC_LIB="$MSVC_ROOT/VC98/Lib"
SUITE="$SCRIPT_DIR/test_msvc_cli.sh"
X86="$ROOT/zig-out/bin/zine.x86"
FLTK="$ROOT/zig-out/bin/zine.x86_64"
DISPLAY_NO="${DISPLAY_NO:-:1}"

SKIP_BUILD="${SKIP_BUILD:-}"
[ "${1:-}" = "--skip-build" ] && SKIP_BUILD=1

if [ "$SKIP_BUILD" != "1" ]; then
    echo "== Building x86 + x86_64 FLTK =="
    (cd "$ROOT" && zig build -Darch=x86 && zig build -Darch=x86_64 -Dfltk) || { echo "FATAL: build failed"; exit 1; }
fi
[ -x "$X86" ]  || { echo "FATAL: $X86 missing (build with zig build -Darch=x86)"; exit 1; }
[ -x "$FLTK" ] || { echo "FATAL: $FLTK missing (build with zig build -Darch=x86_64 -Dfltk)"; exit 1; }
if ! xdpyinfo -display "$DISPLAY_NO" >/dev/null 2>&1; then
    echo "FATAL: no X server on $DISPLAY_NO (start Xvfb $DISPLAY_NO)"
    exit 1
fi

# Under the gitignored .scratch/ rather than TMPDIR, which on many hosts is a
# tmpfs; the suite's captures are disk artifacts, not scratch memory.
mkdir -p "$ROOT/.scratch"
WORKDIR=$(mktemp -d "$ROOT/.scratch/fltk-smoke.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR" || exit 1

PASS=0
FAIL=0

# extract_src <marker> <base> — pull `cat > <base>.c <<'<marker>_EOF' ... <marker>_EOF`
# out of the suite script.
extract_src() {
    local marker="$1" base="$2"
    sed -n "/^cat > $base.c <<'${marker}_EOF'/,/^${marker}_EOF/p" "$SUITE" | sed '1d;$d' > "$base.c"
    [ -s "$base.c" ]
}

# run_app <marker> <base> <libs> <expected>
run_app() {
    local marker="$1" base="$2" libs="$3" expected="$4"
    if ! extract_src "$marker" "$base"; then
        echo "FAIL  $base: source extraction"
        FAIL=$((FAIL + 1))
        return
    fi
    if ! "$X86" "$VC_BIN/CL.EXE" /nologo /c /I"$VC_INCLUDE" "/Fo$base.obj" "$base.c" > cl.txt 2>&1; then
        echo "FAIL  $base: CL ($(tail -2 cl.txt | tr '\n' ' '))"
        FAIL=$((FAIL + 1))
        return
    fi
    # shellcheck disable=SC2086  # libs is an intentional space-separated list of .lib args
    if ! "$X86" "$VC_BIN/LINK.EXE" /NOLOGO "/OUT:$base.exe" /LIBPATH:"$VC_LIB" "$base.obj" $libs > link.txt 2>&1; then
        echo "FAIL  $base: LINK ($(tail -2 link.txt | tr '\n' ' '))"
        FAIL=$((FAIL + 1))
        return
    fi
    ( DISPLAY="$DISPLAY_NO" timeout 25 "$FLTK" --fltk "./$base.exe" > out.txt 2>&1 )
    if grep -q "$expected" out.txt 2>/dev/null; then
        echo "PASS  $base ($expected)"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $base: missing '$expected' ($(tail -2 out.txt | tr '\n' ' '))"
        FAIL=$((FAIL + 1))
    fi
}

run_app SZ    sz_app    "user32.lib"                  "sz-check: ok"
run_app CHAR  char_gui  "user32.lib"                  "char-check: ok"
run_app TIMER timer_gui "user32.lib"                  "timer-check: ok"
run_app EDIT  edit_gui  "user32.lib"                  "edit-check: ok"
run_app MBX   mbx_app   "user32.lib"                  "mbx-check: ok"
run_app CCTL  cctl_app  "user32.lib gdi32.lib comctl32.lib" "cctl-check: ok"
run_app DLGT  dlgt_app  "user32.lib"                  "dlgt-check: ok"
run_app CHK   chk_gui   "user32.lib"                  "chk-check: ok"
run_app RADGRP radgrp_gui "user32.lib"                "radgrp-check: ok"
run_app LST   lst_gui   "user32.lib"                  "lst-check: ok"
run_app COMBO combo_gui "user32.lib"                  "combo-check: ok"
run_app TAB   tab_gui   "comctl32.lib user32.lib"     "tab-check: ok"
run_app CLR   clr_gui   "user32.lib gdi32.lib"        "clr-check: ok"
run_app LV    lv_gui    "comctl32.lib user32.lib"     "lv-check: ok"
run_app TREE  tree_gui  "comctl32.lib user32.lib"     "tree-check: ok"
run_app HDR   hdr_gui   "comctl32.lib user32.lib"     "hdr-check: ok"
run_app RICH  rich_gui  "user32.lib gdi32.lib"        "rich-check: ok"
run_app GWT   gwt_gui   "user32.lib gdi32.lib"        "gwt-check: ok"
run_app UDT   udt_gui   "comctl32.lib user32.lib"     "udt-check: ok"
run_app MTA   mta_gui   "comctl32.lib user32.lib"     "mta-check: ok"

echo ""
echo "==============================="
echo "FLTK smoke: PASSED: $PASS  FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
