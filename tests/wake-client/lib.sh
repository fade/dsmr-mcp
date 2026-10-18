# shellcheck shell=bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Helpers sourced by the wake client's case scripts (cases.sh, hostile.sh).
#
# A script sources this file, calls `lib_init "$@"` with the client binary
# as its one argument, runs its cases, and ends with `summary`. Each case:
#
#   setup_case NAME [keep]   fresh state home and bin dir (keep: reuse the last)
#   CENV+=(VAR=value)        extra environment for the client
#   start_fake ACTION...     fake service on the case's socket (optional)
#   run_client SECONDS ARGS  run the client, SECONDS being its own deadline
#   expect_rc / expect_out / expect_err / expect_ms / expect_eq ...
#   end_case                 prints PASS or FAIL
#
# RUNNER, when set, is a command prefix for the client (a valgrind line, for
# example). Requirements: bash, coreutils, util-linux or coreutils timeout,
# python3 and a C compiler (CC, default cc).

set -u

unset DSMR_BUS_SELECTOR DSMR_BUS_AGENT DSMR_WAKE_OUTAGE_GRACE_SECONDS

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER=${RUNNER:-}
PASSED=0
FAILED=0
CASE_NO=0
ALL_PIDS=()

# Extra milliseconds allowed on timing bounds when a RUNNER slows start-up.
if [ -n "$RUNNER" ]; then SLACK_MS=2500; else SLACK_MS=0; fi

# shellcheck disable=SC2034  # read by the scripts that source this file
ADVICE='This hook arms the next listener itself when your turn ends; do not start one.'

lib_init() {
    SCRIPT_NAME=$(basename "$0")
    if [ $# -ne 1 ] || [ -d "$1" ] || [ ! -x "$1" ]; then
        echo "usage: $SCRIPT_NAME CLIENT" >&2
        exit 2
    fi
    CLIENT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
    RUN_DIR=$(mktemp -d /tmp/wc.XXXXXX)
    trap lib_cleanup EXIT
    trap 'exit 130' INT TERM
    if ! ${CC:-cc} -std=c11 -O2 -o "$RUN_DIR/lisp-stub" "$LIB_DIR/lisp-stub.c"; then
        echo "$SCRIPT_NAME: cannot build lisp-stub.c" >&2
        exit 2
    fi
}

lib_cleanup() {
    local p
    for p in "${ALL_PIDS[@]}"; do kill -KILL "$p" 2>/dev/null; done
    wait 2>/dev/null
    rm -rf "$RUN_DIR"
}

# Start a case: its own state home (short, so the socket path stays far
# under 107 bytes), a bin dir holding a copy of the client and the Lisp
# stand-in, and a working directory. With `keep`, reuse the last case's.
setup_case() {
    CASE=$1
    CASE_NOTES=()
    CASE_PIDS=()
    if [ "${2:-}" != keep ]; then
        CASE_NO=$((CASE_NO + 1))
        CD=$RUN_DIR/$CASE_NO
        mkdir -p "$CD/bin" "$CD/wd" "$CD/s/dsmr-mcp/host"
        chmod 700 "$CD/s" "$CD/s/dsmr-mcp" "$CD/s/dsmr-mcp/host"
        cp "$CLIENT" "$CD/bin/dsmr-bus-watch"
        cp "$RUN_DIR/lisp-stub" "$CD/bin/dsmr-bus-watch-lisp"
        : > "$CD/requests.log"
    fi
    BIN=$CD/bin/dsmr-bus-watch
    SOCK=$CD/s/dsmr-mcp/host/wake.sock
    LOG=$CD/requests.log
    OUT=$CD/out
    ERR=$CD/err
    WD=$CD/wd
    CENV=("XDG_STATE_HOME=$CD/s")
    CIN=/dev/null
    CMERGE=0
    RC=
    ELAPSED=
}

note() { CASE_NOTES+=("$1"); }

# A short printable rendering of $1 for a FAIL line.
shown() {
    local s
    s=$(printf '%q' "$1")
    if [ ${#s} -gt 240 ]; then s="${s:0:240}..."; fi
    printf '%s' "$s"
}

now_ns() { date +%s%N; }

# Record the status of a finished client run; a kill by the cap fails it.
finish_run() {
    local limit=$1 t1
    t1=$(now_ns)
    ELAPSED=$(((t1 - T0) / 1000000))
    if [ "$RC" -eq 137 ]; then
        note "killed after $((limit + 10)) s (hang)"
    fi
}

# run_client SECONDS ARGS...: run the client in the working directory with
# CENV and CIN, capturing stdout in OUT and stderr in ERR (both in OUT when
# CMERGE=1), its status in RC and its run time in ELAPSED (ms). SECONDS is
# the case's deadline; the run is killed 10 s after it.
run_client() {
    local limit=$1
    shift
    T0=$(now_ns)
    if [ "$CMERGE" = 1 ]; then
        # shellcheck disable=SC2086  # RUNNER is a command prefix, split on purpose
        (cd "$WD" && exec timeout -s KILL "$((limit + 10))" env "${CENV[@]}" $RUNNER "$BIN" "$@") \
            <"$CIN" >"$OUT" 2>&1
    else
        # shellcheck disable=SC2086  # RUNNER is a command prefix, split on purpose
        (cd "$WD" && exec timeout -s KILL "$((limit + 10))" env "${CENV[@]}" $RUNNER "$BIN" "$@") \
            <"$CIN" >"$OUT" 2>"$ERR"
    fi
    RC=$?
    finish_run "$limit"
}

# start_client SECONDS ARGS...: as run_client, in the background. The cap
# process is TPID; client_pid finds the client itself; wait_client ends it.
start_client() {
    BG_LIMIT=$1
    shift
    T0=$(now_ns)
    # shellcheck disable=SC2086  # RUNNER is a command prefix, split on purpose
    (cd "$WD" && exec timeout -s KILL "$((BG_LIMIT + 10))" env "${CENV[@]}" $RUNNER "$BIN" "$@") \
        <"$CIN" >"$OUT" 2>"$ERR" &
    TPID=$!
    CASE_PIDS+=("$TPID")
    ALL_PIDS+=("$TPID")
    CPID=
}

# Set CPID to the process the cap runs (the client, or the RUNNER).
client_pid() {
    for _ in $(seq 50); do
        CPID=
        if [ -r "/proc/$TPID/task/$TPID/children" ]; then
            read -r CPID _ <"/proc/$TPID/task/$TPID/children" || true
        fi
        if [ -n "$CPID" ]; then return 0; fi
        sleep 0.1
    done
    note "client process not found"
    return 1
}

wait_client() {
    wait "$TPID"
    RC=$?
    finish_run "$BG_LIMIT"
}

# start_fake ACTION...: a fake service on SOCK logging to LOG.
start_fake() {
    python3 -I "$LIB_DIR/fake-service.py" "$SOCK" "$LOG" "$@" &
    FAKE_PID=$!
    CASE_PIDS+=("$FAKE_PID")
    ALL_PIDS+=("$FAKE_PID")
    for _ in $(seq 100); do
        if [ -S "$SOCK" ]; then return 0; fi
        sleep 0.05
    done
    note "fake service did not start"
    return 1
}

stop_fake() {
    kill -TERM "$FAKE_PID" 2>/dev/null
    wait "$FAKE_PID" 2>/dev/null
    return 0
}

requests() { wc -l <"$LOG" | tr -d ' '; }

# Wait up to SECONDS (default 10) for at least N logged requests.
wait_requests() {
    local n=$1 limit=${2:-10}
    for _ in $(seq $((limit * 20))); do
        if [ "$(requests)" -ge "$n" ]; then return 0; fi
        sleep 0.05
    done
    note "service saw $(requests) requests, waited for $n"
    return 1
}

expect_eq() {
    if [ "$2" != "$3" ]; then
        note "$1: got $(shown "$2"), want $(shown "$3")"
    fi
}

expect_rc() { expect_eq status "$RC" "$1"; }

# expect_file WHAT FILE BYTES: FILE holds exactly BYTES.
expect_file() {
    printf '%s' "$3" >"$CD/want"
    if ! cmp -s "$2" "$CD/want"; then
        note "$1: got $(shown "$(head -c 400 "$2"; printf x)"), want $(shown "$3x")"
    fi
}

expect_out() { expect_file stdout "$OUT" "$1"; }
expect_err() { expect_file stderr "$ERR" "$1"; }

# expect_ms LO HI: the run took between LO and HI ms (HI gets SLACK_MS).
expect_ms() {
    local hi=$(($2 + SLACK_MS))
    if [ "$ELAPSED" -lt "$1" ] || [ "$ELAPSED" -gt "$hi" ]; then
        note "took $ELAPSED ms, want $1-$hi"
    fi
}

expect_requests() { expect_eq requests "$(requests)" "$1"; }

pass() {
    PASSED=$((PASSED + 1))
    echo "PASS $CASE"
}

fail() {
    FAILED=$((FAILED + 1))
    echo "FAIL $CASE: $1"
}

end_case() {
    local p detail=
    for p in "${CASE_PIDS[@]}"; do kill -KILL "$p" 2>/dev/null; done
    for p in "${CASE_PIDS[@]}"; do wait "$p" 2>/dev/null; done
    rm -f "$SOCK"
    if [ ${#CASE_NOTES[@]} -eq 0 ]; then
        pass
        return
    fi
    for p in "${CASE_NOTES[@]}"; do
        detail+="${detail:+; }$p"
    done
    fail "$detail"
}

summary() {
    echo "$SCRIPT_NAME: $PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

# Percent-encode $1 as the service does: each octet outside [A-Za-z0-9._~/]
# written %XX in uppercase hex; an empty text is `-`.
pct() {
    local out='' b ch
    for b in $(printf '%s' "$1" | od -An -v -tx1); do
        case $b in
            3[0-9] | 4[1-9a-f] | 5[0-9a] | 6[1-9a-f] | 7[0-9a] | 2e | 5f | 7e | 2f)
                printf -v ch '%b' "\\x$b"
                out+=$ch
                ;;
            *) out+="%${b^^}" ;;
        esac
    done
    printf '%s' "${out:--}"
}

# The fake service's reply action for an EXIT reply: STATUS KIND OUT ERR,
# OUT and ERR being the texts to print.
exit_reply() {
    printf 'reply=EXIT %s %s %s %s\\n' "$1" "$2" "$(pct "$3")" "$(pct "$4")"
}
