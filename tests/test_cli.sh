#!/usr/bin/env bash
set -euo pipefail

# Every ZINE_* setting is startup configuration, so an inherited one would
# decide what these runs see: a log level from the developer's shell fills
# stderr, and a rejected ZINE_CWD fails --version. A run starts from an
# environment the operator configured on purpose, and the cases below set
# the variable they are about.
while read -r name; do
    unset "$name"
done < <(compgen -A variable | command grep '^ZINE_')

expected_version=$1
shift
# Under the gitignored .scratch/ rather than TMPDIR, which on many hosts is a
# tmpfs: a suite that writes its captures to RAM adds to the memory the
# emulator under test is short of. The root comes from the script's own
# location so a hand-run from another directory lands in the same place.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/.scratch"
workdir=$(mktemp -d "$root/.scratch/test-cli.XXXXXX")
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
    timeout 60 "$@" --help >"$workdir/stdout" 2>"$workdir/stderr"
    # Every setting the build validates is named in its --help, since a
    # rejected value sends the operator there for the accepted values. A
    # setting the build does not read is left out: listing it would promise a
    # knob the run ignores.
    for name in ZINE_LOG_LEVEL ZINE_TRACE ZINE_TRACE_INSN ZINE_PROFILE ZINE_CWD ZINE_VIRTUAL_CLOCK_NS ZINE_CLOCK_STEP_NS; do
        if ! grep --quiet -- "$name" "$workdir/stdout"; then
            printf '%s --help must document %s\n' "$expected_version" "$name" >&2
            exit 1
        fi
    done
    if grep --quiet -- 'ZINE_WEB_' "$workdir/stdout"; then
        if [[ "$1" == wasmtime ]]; then
            printf '%s --help must not list a web setting: this build has no web server\n' "$expected_version" >&2
            exit 1
        fi
        for name in ZINE_WEB_HOST ZINE_WEB_PORT; do
            if ! grep --quiet -- "$name" "$workdir/stdout"; then
                printf '%s --help must document %s\n' "$expected_version" "$name" >&2
                exit 1
            fi
        done
    fi
    if grep --quiet -- '--jit-max-eip=' "$workdir/stdout"; then
        for value in '' invalid 0x 0x100000000 4294967296 -1 ' 42' '42 '; do
            status=0
            timeout 60 "$@" "--jit-max-eip=$value" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
            if [[ "$status" != 2 || -s "$workdir/stdout" ]]; then
                printf 'Invalid --jit-max-eip value <%s> must exit with status 2 and no stdout (got %s)\n' "$value" "$status" >&2
                exit 1
            fi
            grep --quiet -- 'Error: --jit-max-eip requires' "$workdir/stderr"
            grep --quiet -- "Try 'zine --help'" "$workdir/stderr"
        done
        for value in 0 42 0x00400000 4294967295 0xFFFFFFFF; do
            timeout 60 "$@" "--jit-max-eip=$value" --version >"$workdir/stdout" 2>"$workdir/stderr"
            [[ ! -s "$workdir/stderr" ]]
            printf '%s\n' "$expected_version" >"$workdir/expected"
            cmp "$workdir/expected" "$workdir/stdout"
        done
        # The value may also stand as its own argument, like --argv0.
        for value in 0 42 0x00400000 4294967295 0xFFFFFFFF; do
            timeout 60 "$@" --jit-max-eip "$value" --version >"$workdir/stdout" 2>"$workdir/stderr"
            [[ ! -s "$workdir/stderr" ]]
            printf '%s\n' "$expected_version" >"$workdir/expected"
            cmp "$workdir/expected" "$workdir/stdout"
        done
        for value in invalid 0x -1 ''; do
            status=0
            timeout 60 "$@" --jit-max-eip "$value" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
            if [[ "$status" != 2 || -s "$workdir/stdout" ]]; then
                printf 'Invalid --jit-max-eip <%s> must exit with status 2 and no stdout (got %s)\n' "$value" "$status" >&2
                exit 1
            fi
            grep --quiet -- 'Error: --jit-max-eip requires' "$workdir/stderr"
        done
        # A flag where the value belongs is consumed as the value, so the
        # diagnostic names the offending text instead of printing a version.
        status=0
        timeout 60 "$@" --jit-max-eip --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
        if [[ "$status" != 2 || -s "$workdir/stdout" ]]; then
            printf '--jit-max-eip with no value must exit with status 2 and no stdout (got %s)\n' "$status" >&2
            exit 1
        fi
        grep --quiet -- 'Error: --jit-max-eip requires a u32 value' "$workdir/stderr"
    fi
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
                grep -q "Try 'zine --help'" "$workdir/stderr"
                ;;
        esac
    done

    # The web UI bind address is native-only: WASI builds have no web server.
    if [[ "$1" != wasmtime ]]; then
        # A misspelled setting is the one misconfiguration the run cannot
        # detect by misbehaving, so it is named on stderr.
        status=0
        timeout 60 env 'ZINE_WEB_PRT=3000' "$@" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
        if [[ "$status" != 0 || ! -s "$workdir/stdout" ]]; then
            printf 'ZINE_WEB_PRT must not change the run (got %s)\n' "$status" >&2
            cat "$workdir/stderr" >&2
            exit 1
        fi
        grep -q 'ignoring ZINE_WEB_PRT' "$workdir/stderr"

        for host in '' localhost 999.1.1.1 127.0.0.1:1995; do
            status=0
            timeout 60 env "ZINE_WEB_HOST=$host" "$@" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
            if [[ "$status" != 2 || -s "$workdir/stdout" ]]; then
                printf 'ZINE_WEB_HOST=<%s> must exit with status 2 and no stdout (got %s)\n' "$host" "$status" >&2
                exit 1
            fi
            grep -q 'Error: ZINE_WEB_HOST must be' "$workdir/stderr"
        done
        for port in '' 0 -1 http 65536 '1995 '; do
            status=0
            timeout 60 env "ZINE_WEB_PORT=$port" "$@" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
            if [[ "$status" != 2 || -s "$workdir/stdout" ]]; then
                printf 'ZINE_WEB_PORT=<%s> must exit with status 2 and no stdout (got %s)\n' "$port" "$status" >&2
                exit 1
            fi
            grep -q 'Error: ZINE_WEB_PORT must be' "$workdir/stderr"
        done
        for value in 'ZINE_WEB_HOST=127.0.0.1' 'ZINE_WEB_PORT=3000' 'ZINE_WEB_HOST=::1'; do
            status=0
            timeout 60 env "$value" "$@" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
            if [[ "$status" != 0 || -s "$workdir/stderr" ]]; then
                printf '%s must be accepted (got %s)\n' "$value" "$status" >&2
                cat "$workdir/stderr" >&2
                exit 1
            fi
        done
        # The virtual guest clock is validated below, on every build.
    else
        # ZINE_CWD is the WASI-only guest working directory. It is validated at
        # startup like the other ZINE_* settings, so --version reports it.
        for cwd in '' relative/path 'dir/'; do
            status=0
            timeout 60 "$1" "$2" --env "ZINE_CWD=$cwd" "${@:3}" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
            if [[ "$status" != 2 || -s "$workdir/stdout" ]]; then
                printf 'ZINE_CWD=<%s> must exit with status 2 and no stdout (got %s)\n' "$cwd" "$status" >&2
                cat "$workdir/stderr" >&2
                exit 1
            fi
            grep -q 'Error: ZINE_CWD must be an absolute POSIX path' "$workdir/stderr"
            grep -q "Try 'zine --help'" "$workdir/stderr"
        done
        for cwd in / /tmp '/tmp/zine cwd'; do
            status=0
            timeout 60 "$1" "$2" --env "ZINE_CWD=$cwd" "${@:3}" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
            if [[ "$status" != 0 || -s "$workdir/stderr" ]]; then
                printf 'ZINE_CWD=<%s> must be accepted (got %s)\n' "$cwd" "$status" >&2
                cat "$workdir/stderr" >&2
                exit 1
            fi
        done
        # A web setting is a known name this build never reads, so the
        # misspelling pass stays quiet about it. The run reports it itself, or
        # an operator who exported it for a native run gets no web UI and no
        # explanation for it.
        for name in ZINE_WEB_HOST ZINE_WEB_PORT; do
            status=0
            timeout 60 "$1" "$2" --env "$name=127.0.0.1" "${@:3}" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
            if [[ "$status" != 0 || ! -s "$workdir/stdout" ]]; then
                printf '%s must not change the run (got %s)\n' "$name" "$status" >&2
                cat "$workdir/stderr" >&2
                exit 1
            fi
            grep -q "ignoring $name: this build has no web server" "$workdir/stderr"
        done
        # The runtime's own `--` separator reaches the guest as the first
        # argument; options behind it must still parse.
        for flag in --version --help; do
            status=0
            timeout 60 "$1" "$2" "${@:3}" -- "$flag" >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
            if [[ "$status" != 0 || ! -s "$workdir/stdout" || -s "$workdir/stderr" ]]; then
                printf '%s after a -- separator must write to stdout and exit 0 (got %s)\n' "$flag" "$status" >&2
                cat "$workdir/stderr" >&2
                exit 1
            fi
        done
    fi

    # The virtual guest clock is validated on every build: both entry points
    # read the same settings, and each --help lists them. A run on the virtual
    # clock says so at startup, so an accepted start has that diagnostic line.
    # wasmtime passes an environment only with an --env per setting, so the
    # command is built per case rather than wrapped in `env`.
    clock_cmd=()
    for value in '' -1 1e9 '1000ns'; do
        if [[ "$1" == wasmtime ]]; then
            clock_cmd=("$1" "$2" --env "ZINE_VIRTUAL_CLOCK_NS=$value" "${@:3}")
        else
            clock_cmd=(env "ZINE_VIRTUAL_CLOCK_NS=$value" "$@")
        fi
        status=0
        timeout 60 "${clock_cmd[@]}" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
        if [[ "$status" != 2 || -s "$workdir/stdout" ]]; then
            printf 'ZINE_VIRTUAL_CLOCK_NS=<%s> must exit with status 2 and no stdout (got %s)\n' "$value" "$status" >&2
            exit 1
        fi
        grep -q 'Error: ZINE_VIRTUAL_CLOCK_NS must be' "$workdir/stderr"
        grep -q "Try 'zine --help'" "$workdir/stderr"
    done
    if [[ "$1" == wasmtime ]]; then
        clock_cmd=("$1" "$2" --env ZINE_CLOCK_STEP_NS=1000 "${@:3}")
    else
        clock_cmd=(env ZINE_CLOCK_STEP_NS=1000 "$@")
    fi
    status=0
    timeout 60 "${clock_cmd[@]}" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
    if [[ "$status" != 2 || -s "$workdir/stdout" ]]; then
        printf 'ZINE_CLOCK_STEP_NS without ZINE_VIRTUAL_CLOCK_NS must exit with status 2 (got %s)\n' "$status" >&2
        exit 1
    fi
    grep -q 'Error: ZINE_CLOCK_STEP_NS must be' "$workdir/stderr"
    for value in -1 1e9; do
        if [[ "$1" == wasmtime ]]; then
            clock_cmd=("$1" "$2" --env ZINE_VIRTUAL_CLOCK_NS=1700000000000000000 --env "ZINE_CLOCK_STEP_NS=$value" "${@:3}")
        else
            clock_cmd=(env ZINE_VIRTUAL_CLOCK_NS=1700000000000000000 "ZINE_CLOCK_STEP_NS=$value" "$@")
        fi
        status=0
        timeout 60 "${clock_cmd[@]}" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
        if [[ "$status" != 2 || -s "$workdir/stdout" ]]; then
            printf 'ZINE_CLOCK_STEP_NS=<%s> must exit with status 2 and no stdout (got %s)\n' "$value" "$status" >&2
            exit 1
        fi
        grep -q 'Error: ZINE_CLOCK_STEP_NS must be' "$workdir/stderr"
    done
    if [[ "$1" == wasmtime ]]; then
        clock_cmd=("$1" "$2" --env ZINE_VIRTUAL_CLOCK_NS=1700000000000000000 "${@:3}")
    else
        clock_cmd=(env ZINE_VIRTUAL_CLOCK_NS=1700000000000000000 "$@")
    fi
    status=0
    timeout 60 "${clock_cmd[@]}" --version >"$workdir/stdout" 2>"$workdir/stderr" || status=$?
    printf '%s\n' "$expected_version" >"$workdir/expected"
    if [[ "$status" != 0 ]]; then
        printf 'ZINE_VIRTUAL_CLOCK_NS must be accepted (got %s)\n' "$status" >&2
        cat "$workdir/stderr" >&2
        exit 1
    fi
    cmp "$workdir/expected" "$workdir/stdout"
    grep -q 'virtual clock: first read 1700000000000000000 ns' "$workdir/stderr"
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
