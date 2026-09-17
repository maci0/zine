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
