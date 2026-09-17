#!/usr/bin/env bash
set -euo pipefail

expected_version=$1
shift
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

for flag in --version -v --help -h; do
    status=0
    timeout 60 "$@" "$flag" >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
    if [[ "$status" != 0 ]]; then
        printf '%s exited with status %s\n' "$flag" "$status" >&2
        cat "$workdir/stderr" >&2
        exit 1
    fi
    if [[ ! -s "$workdir/stdout" || -s "$workdir/stderr" ]]; then
        printf '%s must write to stdout only\n' "$flag" >&2
        exit 1
    fi
    if [[ "$flag" == --version || "$flag" == -v ]]; then
        printf '%s\n' "$expected_version" >"$workdir/expected"
        cmp "$workdir/expected" "$workdir/stdout"
    else
        grep -q '^Usage: ' "$workdir/stdout"
    fi
    status=0
    timeout 60 "$@" "$flag" >/dev/full 2>"$workdir/stderr" || status=$?
    if [[ "$status" != 1 || ! -s "$workdir/stderr" ]]; then
        printf '%s must report stdout write failure with status 1 (got %s)\n' "$flag" "$status" >&2
        exit 1
    fi
done

status=0
timeout 60 "$@" --invalid-option >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
[[ "$status" == 2 && ! -s "$workdir/stdout" && -s "$workdir/stderr" ]]
grep -q 'unknown option' "$workdir/stderr"

if [[ "$expected_version" == zine\ * ]]; then
    for level in fatal error err warn info trace '' debug INFO ' warn' 'trace '; do
        config_cmd=(env "ZINE_LOG_LEVEL=$level" "$@")
        if [[ "$1" == wasmtime ]]; then
            config_cmd=("$1" "$2" --env "ZINE_LOG_LEVEL=$level" "${@:3}")
        fi
        status=0
        timeout 60 "${config_cmd[@]}" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
        case "$level" in
            fatal|error|err|warn|info|trace)
                [[ "$status" == 0 && ! -s "$workdir/stderr" ]]
                printf '%s\n' "$expected_version" >"$workdir/expected"
                cmp "$workdir/expected" "$workdir/stdout"
                ;;
            *)
                [[ "$status" == 2 && ! -s "$workdir/stdout" ]]
                grep -q 'Error: ZINE_LOG_LEVEL must be one of: fatal, error, err, warn, info, trace.' "$workdir/stderr"
                ;;
        esac
    done
fi

if [[ "$expected_version" == zine-host\ * ]]; then
    for behavior in return trap exit-zero exit-nonzero; do
        case "$behavior" in
            return) code='\x0a\x05\x01\x03\x00\x01\x0b'; expected_status=0 ;;
            trap) code='\x0a\x05\x01\x03\x00\x00\x0b'; expected_status=1 ;;
            exit-zero) code='\x0a\x08\x01\x06\x00\x41\x00\x10\x00\x0b'; expected_status=0 ;;
            exit-nonzero) code='\x0a\x08\x01\x06\x00\x41\x2a\x10\x00\x0b'; expected_status=42 ;;
            *) exit 1 ;;
        esac
        printf '%b' \
            '\x00\x61\x73\x6d\x01\x00\x00\x00' \
            '\x01\x08\x02\x60\x00\x00\x60\x01\x7f\x00' \
            '\x02\x24\x01\x16wasi_snapshot_preview1\x09proc_exit\x00\x01' \
            '\x03\x02\x01\x00' \
            '\x05\x03\x01\x00\x01' \
            '\x07\x13\x02\x06memory\x02\x00\x06_start\x00\x01' \
            "$code" >"$workdir/start.wasm"
        status=0
        timeout 60 "$@" "$workdir/start.wasm" >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
        if [[ "$status" != "$expected_status" || -s "$workdir/stdout" ]]; then
            printf 'WASM %s must exit with status %s and no stdout (got %s)\n' "$behavior" "$expected_status" "$status" >&2
            cat "$workdir/stderr" >&2
            exit 1
        fi
        if [[ "$behavior" == trap ]]; then
            grep --quiet 'Error: WASM trap:' "$workdir/stderr"
        elif [[ -s "$workdir/stderr" ]]; then
            printf 'WASM %s must not emit diagnostics\n' "$behavior" >&2
            cat "$workdir/stderr" >&2
            exit 1
        fi
    done
fi
