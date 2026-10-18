#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Behaviour cases for the wake client (src/bus/wake/dsmr-bus-watch.c): what
# the front end hands to the Lisp program, the checks the client makes
# without the service, the replies it prints, and how it rides through a
# missing, busy or restarted service.
#
# usage: cases.sh CLIENT
#   RUNNER=PREFIX        run the client under PREFIX (a valgrind line, say)
#   WAKE_CASES_STATIC=1  also run the process-fact cases, which only make
#                        sense for the static build run directly
#
# Prints `PASS <case>` or `FAIL <case>: <detail>` per case and a summary
# line; exits 1 when any case fails.

set -u
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
lib_init "$@"

ID=(--agent a --namespace /n/)
NOID=$'dsmr-bus-watch: --wake needs a resolved identity (pass --agent with --namespace, or --agent-id); the detached log is keyed on it.\n'
HOOK_IDLE1=$'idle wake-seconds=1\ndsmr-bus-watch: no mail arrived in 1 seconds; this wake only renews the listener and there is nothing to drain. '"$ADVICE"$'\n'

# ---------------------------------------------------------------- front end

setup_case front-end-passes-check-live-to-the-lisp-program
run_client 5 --check-live --agent a
expect_rc 7
expect_out "argv0=$BIN"$'\n--check-live\n--agent\na\n'
expect_err ''
end_case

setup_case front-end-passes-a-fleet-log-wake-to-the-lisp-program
run_client 5 --wake --fleet-log --agent a
expect_rc 7
expect_out "argv0=$BIN"$'\n--wake\n--fleet-log\n--agent\na\n'
end_case

setup_case front-end-passes-a-wake-with-help-to-the-lisp-program
run_client 5 --wake -h
expect_rc 7
expect_out "argv0=$BIN"$'\n--wake\n-h\n'
end_case

setup_case front-end-passes-an-argv-without-wake-to-the-lisp-program
run_client 5 --agent a --bus b
expect_rc 7
expect_out "argv0=$BIN"$'\n--agent\na\n--bus\nb\n'
end_case

setup_case front-end-passes-no-arguments-to-the-lisp-program
run_client 5
expect_rc 7
expect_out "argv0=$BIN"$'\n'
end_case

setup_case front-end-keeps-argv0-through-a-symlink
ln -s dsmr-bus-watch "$CD/bin/link-name"
BIN=$CD/bin/link-name
run_client 5 --check-live
expect_rc 7
expect_out "argv0=$CD/bin/link-name"$'\n--check-live\n'
end_case

setup_case a-value-after-a-value-flag-is-never-a-mode
run_client 1 --wake --agent --help --namespace /n/ --wake-seconds 1
expect_rc 0
expect_out $'idle wake-seconds=1\n'
expect_err ''
end_case

# --------------------------------------------------------------- local rules

setup_case no-identity-exits-2-with-the-reason
run_client 5 --wake
expect_rc 2
expect_out ''
expect_err "$NOID"
end_case

setup_case no-identity-in-a-hook-exits-0-silently
run_client 5 --wake --hook
expect_rc 0
expect_out ''
expect_err ''
end_case

setup_case an-empty-agent-with-no-environment-is-no-identity
run_client 5 --wake --agent ''
expect_rc 2
expect_err "$NOID"
end_case

setup_case the-environment-agent-gives-an-identity
CENV+=(DSMR_BUS_AGENT=e)
run_client 1 --wake --agent '' --namespace /n/ --wake-seconds 1
expect_rc 0
expect_out $'idle wake-seconds=1\n'
expect_err ''
end_case

setup_case an-agent-id-alone-needs-no-namespace
run_client 1 --wake --agent-id ns/x --wake-seconds 1
expect_rc 0
expect_out $'idle wake-seconds=1\n'
expect_err ''
end_case

setup_case warnings-come-in-argv-order
run_client 1 --wake "${ID[@]}" --wake-seconds 1 'q"u\o' --after x --poll-ms -3 \
    --deaf-seconds 1.5 --namespace
expect_rc 0
expect_out $'idle wake-seconds=1\n'
expect_err 'dsmr-bus-watch: unknown argument "q\"u\\o" ignored; continuing on defaults
dsmr-bus-watch: --after expects a non-negative integer, got "x"; keeping the default
dsmr-bus-watch: --poll-ms expects a non-negative integer, got "-3"; keeping the default
dsmr-bus-watch: --deaf-seconds expects a non-negative integer, got "1.5"; keeping the default
dsmr-bus-watch: --namespace requires a value but none followed; ignoring it
'
end_case

setup_case numbers-take-blanks-a-sign-and-leading-zeros
run_client 1 --wake "${ID[@]}" --poll-ms ' -0 ' --after +12 --wake-seconds +01
expect_rc 0
expect_out $'idle wake-seconds=1\n'
expect_err ''
end_case

setup_case a-subagent-hook-exits-0-silently
CIN=$CD/hook-input
printf '{\n  "session_id": "s",\n  "agent_id"\n  :\t"sub-1",\n  "x": 1\n}\n' >"$CIN"
run_client 5 --wake --hook "${ID[@]}" --wake-seconds 5
expect_rc 0
expect_out ''
expect_err ''
expect_ms 0 4000
end_case

setup_case an-empty-agent-id-value-is-not-a-subagent
CIN=$CD/hook-input
printf '{"agent_id": ""}\n' >"$CIN"
run_client 1 --wake --hook "${ID[@]}" --wake-seconds 1
expect_rc 2
expect_out ''
expect_err "$HOOK_IDLE1"
end_case

setup_case a-bad-bus-name-runs-the-lisp-program
run_client 5 --wake --bus 'bad name' "${ID[@]}"
expect_rc 7
expect_out "argv0=$BIN"$'\n--wake\n--bus\nbad name\n--agent\na\n--namespace\n/n/\n'
expect_err ''
end_case

setup_case a-reserved-bus-from-the-environment-runs-the-lisp-program
CENV+=(DSMR_BUS_SELECTOR=Broker.Log)
run_client 5 --wake "${ID[@]}"
expect_rc 7
expect_out "argv0=$BIN"$'\n--wake\n--agent\na\n--namespace\n/n/\n'
end_case

setup_case a-bus-of-33-characters-runs-the-lisp-program
run_client 5 --wake --bus abcdefghijklmnopqrstuvwxyz0123456 "${ID[@]}"
expect_rc 7
expect_out "argv0=$BIN"$'\n--wake\n--bus\nabcdefghijklmnopqrstuvwxyz0123456\n--agent\na\n--namespace\n/n/\n'
end_case

setup_case a-bus-of-32-characters-is-accepted
run_client 1 --wake --bus abcdefghijklmnopqrstuvwxyz012345 "${ID[@]}" --wake-seconds 1
expect_rc 0
expect_out $'idle wake-seconds=1\n'
expect_err ''
end_case

setup_case the-namespace-warning-names-the-working-directory
run_client 1 --wake --agent a --wake-seconds 1
expect_rc 0
expect_out $'idle wake-seconds=1\n'
expect_err "dsmr-bus-watch: no --namespace given; inferring \"$WD/\" from the working directory. It must match the project root the MCP session uses, or this watcher reads the wrong cursor."$'\n'
end_case

setup_case no-state-home-exits-64
CENV=(-u HOME -u XDG_STATE_HOME)
if [ -n "$RUNNER" ]; then
    # valgrind looks for its debuginfo cache under HOME; give it one.
    CENV+=("DEBUGINFOD_CACHE_PATH=$CD/debuginfod")
fi
run_client 5 --wake "${ID[@]}"
expect_rc 64
expect_out ''
expect_err $'dsmr-bus-watch: neither XDG_STATE_HOME nor HOME is set; cannot find the host bus service\n'
end_case

setup_case a-missing-lisp-program-exits-127
rm -f "$CD/bin/dsmr-bus-watch-lisp"
run_client 5 --check-live
expect_rc 127
expect_out ''
expect_err "dsmr-bus-watch: cannot run $CD/bin/dsmr-bus-watch-lisp: No such file or directory"$'\n'
end_case

setup_case an-unexecutable-lisp-program-says-permission-denied
chmod 644 "$CD/bin/dsmr-bus-watch-lisp"
run_client 5 --check-live
expect_rc 127
expect_err "dsmr-bus-watch: cannot run $CD/bin/dsmr-bus-watch-lisp: Permission denied"$'\n'
end_case

# ------------------------------------------------------------------ replies

EVENT_LINE=$'bus:7 from=x,y to=a\n'
HOOK_EVENT=$'bus:7\ndsmr-bus-watch: mail has arrived for you on bus b1. Drain the bus now with bus-receive and act on what it holds. '"$ADVICE"$'\n'
NW_OUT=$'nowatcher bus=default\n'
NW_ERR=$'dsmr-bus-watch: no detached watcher is running for ns/a b on bus default; start one with --detach, then wake again\n'
NW_HOOK=$'nowatcher bus=*\ndsmr-bus-watch: no detached watcher is running for ns/a on bus *, so no mail can wake you. Start one with dsmr-bus-watch --detach and your usual --bus and identity flags. '"$ADVICE"$'\n'

setup_case an-event-reply-prints-its-line-on-stdout
start_fake "$(exit_reply 0 event "$EVENT_LINE" '')"
run_client 5 --wake "${ID[@]}" --wake-seconds 5
expect_rc 0
expect_out "$EVENT_LINE"
expect_err ''
expect_requests 1
end_case

setup_case a-hook-event-reply-prints-its-text-on-stderr
start_fake "$(exit_reply 2 event '' "$HOOK_EVENT")"
run_client 5 --wake --hook "${ID[@]}" --bus b1 --wake-seconds 5
expect_rc 2
expect_out ''
expect_err "$HOOK_EVENT"
end_case

setup_case a-nowatcher-reply-prints-both-texts
start_fake "$(exit_reply 1 nowatcher "$NW_OUT" "$NW_ERR")"
run_client 5 --wake "${ID[@]}" --wake-seconds 5
expect_rc 1
expect_out "$NW_OUT"
expect_err "$NW_ERR"
end_case

setup_case a-hook-nowatcher-reply-prints-its-notice
start_fake "$(exit_reply 2 nowatcher '' "$NW_HOOK")"
run_client 5 --wake --hook --all-buses "${ID[@]}" --wake-seconds 5
expect_rc 2
expect_out ''
expect_err "$NW_HOOK"
end_case

setup_case a-silent-nowatcher-reply-prints-nothing
start_fake 'reply=EXIT 0 nowatcher - -\n'
run_client 5 --wake --hook "${ID[@]}" --wake-seconds 5
expect_rc 0
expect_out ''
expect_err ''
expect_ms 0 2500
end_case

setup_case a-superseded-reply-prints-nothing
start_fake 'reply=EXIT 0 superseded - -\n'
run_client 5 --wake --hook "${ID[@]}" --wake-seconds 5
expect_rc 0
expect_out ''
expect_err ''
expect_ms 0 2500
end_case

setup_case a-reply-text-keeps-utf-8-tabs-and-line-feeds
start_fake 'reply=EXIT 0 event caf%C3%A9%09x%0Asecond%20line%0A -\n'
run_client 5 --wake "${ID[@]}" --wake-seconds 5
expect_rc 0
expect_out $'caf\xc3\xa9\tx\nsecond line\n'
expect_err ''
end_case

setup_case a-reply-text-of-4096-octets-prints-whole
TEXT4096=$(printf 'a%.0s' $(seq 4095))$'\n'
start_fake "reply=EXIT 0 event $(printf 'a%.0s' $(seq 4095))%0A -\\n"
run_client 5 --wake "${ID[@]}" --wake-seconds 5
expect_rc 0
expect_out "$TEXT4096"
expect_eq "stdout octets" "$(wc -c <"$OUT" | tr -d ' ')" 4096
end_case

setup_case a-reply-writes-stderr-before-stdout
start_fake 'reply=EXIT 1 nowatcher out%0A err%0A\n'
# shellcheck disable=SC2034  # read by run_client in lib.sh
CMERGE=1
run_client 5 --wake "${ID[@]}" --wake-seconds 5
expect_rc 1
expect_out $'err\nout\n'
end_case

setup_case a-reply-after-a-held-connection-prints
start_fake "after=1500:$(exit_reply 0 event "$EVENT_LINE" '' | sed 's/^reply=//')"
run_client 5 --wake "${ID[@]}" --wake-seconds 5
expect_rc 0
expect_out "$EVENT_LINE"
expect_err ''
expect_ms 1400 4000
end_case

setup_case with-no-deadline-a-late-reply-still-prints
start_fake 'after=1200:EXIT 0 event bus%3A4%0A -\n'
run_client 3 --wake "${ID[@]}" --wake-seconds 0
expect_rc 0
expect_out $'bus:4\n'
expect_err ''
end_case

# --------------------------------------------------------- service behaviour

setup_case busy-then-a-reply-prints-after-two-requests
start_fake 'reply=ERR busy too%20many\n' 'reply=EXIT 0 event bus%3A1%0A -\n'
run_client 5 --wake "${ID[@]}" --wake-seconds 5
expect_rc 0
expect_out $'bus:1\n'
expect_err ''
expect_requests 2
end_case

setup_case version-then-a-reply-prints
start_fake 'reply=ERR version unknown\n' 'reply=EXIT 0 event bus%3A1%0A -\n'
run_client 5 --wake "${ID[@]}" --wake-seconds 5
expect_rc 0
expect_out $'bus:1\n'
expect_err ''
expect_requests 2
end_case

setup_case bad-request-then-a-reply-prints
start_fake 'reply=ERR bad-request no\n' 'reply=EXIT 0 event bus%3A1%0A -\n'
run_client 5 --wake "${ID[@]}" --wake-seconds 5
expect_rc 0
expect_out $'bus:1\n'
expect_err ''
expect_requests 2
end_case

setup_case a-bad-bus-reply-runs-the-lisp-program-with-the-original-argv
start_fake 'reply=ERR bad-bus x\n'
run_client 5 --wake "${ID[@]}" --bus nb --wake-seconds 5
expect_rc 7
expect_out "argv0=$BIN"$'\n--wake\n--agent\na\n--namespace\n/n/\n--bus\nnb\n--wake-seconds\n5\n'
expect_err ''
end_case

setup_case a-service-started-late-is-reached-and-its-reply-printed
start_client 6 --wake "${ID[@]}" --wake-seconds 6
sleep 1
start_fake 'reply=EXIT 0 event bus%3A2%0A -\n'
wait_client
expect_rc 0
expect_out $'bus:2\n'
expect_err ''
expect_ms 900 4000
end_case

setup_case a-restarted-service-is-reached-and-its-reply-printed
start_fake hold
start_client 10 --wake "${ID[@]}" --wake-seconds 10
wait_requests 1
stop_fake
sleep 0.3
start_fake 'reply=EXIT 0 event bus%3A3%0A -\n'
wait_client
expect_rc 0
expect_out $'bus:3\n'
expect_err ''
expect_requests 2
end_case

setup_case idle-at-the-deadline-without-a-service
run_client 2 --wake "${ID[@]}" --wake-seconds 2
expect_rc 0
expect_out $'idle wake-seconds=2\n'
expect_err ''
expect_ms 1800 3500
end_case

setup_case hook-idle-at-the-deadline-without-a-service
run_client 2 --wake --hook "${ID[@]}" --wake-seconds 2
expect_rc 2
expect_out ''
expect_err $'idle wake-seconds=2\ndsmr-bus-watch: no mail arrived in 2 seconds; this wake only renews the listener and there is nothing to drain. '"$ADVICE"$'\n'
expect_ms 1800 3500
end_case

setup_case idle-at-the-deadline-while-the-service-holds
start_fake hold
run_client 2 --wake "${ID[@]}" --wake-seconds 2
expect_rc 0
expect_out $'idle wake-seconds=2\n'
expect_err ''
expect_ms 1800 3500
expect_requests 1
end_case

OUTAGE_ERR=$'dsmr-bus-watch: the host bus service has not answered for 2 seconds, so no mail can wake you; check it with systemctl --user status dsmr-bus-host, then wake again\n'

setup_case an-outage-past-the-grace-says-nowatcher
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=2)
run_client 30 --wake "${ID[@]}" --wake-seconds 30
expect_rc 1
expect_out $'nowatcher bus=default\n'
expect_err "$OUTAGE_ERR"
expect_ms 1800 3500
end_case

setup_case an-outage-with-all-buses-says-nowatcher-for-every-bus
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=2)
run_client 30 --wake --all-buses "${ID[@]}" --wake-seconds 30
expect_rc 1
expect_out $'nowatcher bus=*\n'
expect_err "$OUTAGE_ERR"
expect_ms 1800 3500
end_case

setup_case an-outage-names-the-bus-it-waits-on
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=2)
run_client 30 --wake --bus nb "${ID[@]}" --wake-seconds 30
expect_rc 1
expect_out $'nowatcher bus=nb\n'
expect_err "$OUTAGE_ERR"
end_case

STAMP=wake-outage-73dacbc6.stamp

setup_case a-hook-outage-wakes-the-session-and-writes-its-stamp
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=2)
run_client 30 --wake --hook "${ID[@]}" --wake-seconds 30
expect_rc 2
expect_out ''
expect_err $'nowatcher bus=default\ndsmr-bus-watch: the host bus service has not answered for 2 seconds, so no mail can wake you. Check it with systemctl --user status dsmr-bus-host. '"$ADVICE"$'\n'
expect_eq stamps "$(cd "$CD/s/dsmr-mcp/host" && printf '%s ' *.stamp)" "$STAMP "
end_case

setup_case a-second-hook-outage-within-the-hour-is-silent keep
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=2)
run_client 30 --wake --hook "${ID[@]}" --wake-seconds 30
expect_rc 0
expect_out ''
expect_err ''
expect_ms 1800 3500
end_case

setup_case sigterm-while-waiting-exits-143
start_fake hold
start_client 30 --wake "${ID[@]}" --wake-seconds 30
wait_requests 1
client_pid && kill -TERM "$CPID"
wait_client
expect_rc 143
expect_out ''
expect_err ''
end_case

setup_case the-request-line-percent-encodes-every-field
WD=$CD/'w d-x=é'
mkdir -p "$WD"
CENV+=(DSMR_BUS_AGENT=ag=nt DSMR_BUS_SELECTOR=b.1)
start_fake hold
run_client 1 --wake --agent 'a b' --namespace 'ns/é -x' --bus b_2 --wake-seconds 1
expect_rc 0
expect_out $'idle wake-seconds=1\n'
LINE=$(head -n 1 "$LOG")
WANT="WAKE 1 hook=0 allbuses=0 agent=a%20b ns=ns/%C3%A9%20%2Dx agentid=- envagent=ag%3Dnt bus=b_2 envbus=b.1 cwd=$CD/w%20d%2Dx%3D%C3%A9 pid="
expect_eq "request prefix" "${LINE%pid=*}pid=" "$WANT"
case ${LINE##*pid=} in
    '' | *[!0-9]*) note "request pid not decimal: $(shown "$LINE")" ;;
esac
end_case

setup_case the-request-line-marks-a-hook-for-every-bus
start_fake hold
run_client 1 --wake --hook --all-buses --agent-id x --wake-seconds 1
expect_rc 2
LINE=$(head -n 1 "$LOG")
expect_eq "request prefix" "${LINE%cwd=*}" "WAKE 1 hook=1 allbuses=1 agent=- ns=- agentid=x envagent=- bus=- envbus=- "
end_case

# ------------------------------------------------------------ process facts

if [ "${WAKE_CASES_STATIC:-}" = 1 ]; then
    setup_case a-waiting-client-is-one-small-thread-with-one-socket
    start_fake hold
    start_client 30 --wake "${ID[@]}" --wake-seconds 30
    wait_requests 1
    sleep 0.3
    if client_pid; then
        RSS=$(awk '/^VmRSS:/ {print $2}' "/proc/$CPID/status")
        THREADS=$(awk '/^Threads:/ {print $2}' "/proc/$CPID/status")
        FDS=
        SOCKETS=0
        for f in /proc/"$CPID"/fd/*; do
            FDS+="${f##*/} "
            case $(readlink "$f") in socket:*) SOCKETS=$((SOCKETS + 1)) ;; esac
        done
        if [ "$RSS" -ge 1024 ]; then note "VmRSS $RSS kB, want under 1024"; fi
        expect_eq threads "$THREADS" 1
        expect_eq descriptors "$FDS" "0 1 2 3 "
        expect_eq sockets "$SOCKETS" 1
        echo "NOTE waiting client: VmRSS $RSS kB, Threads $THREADS, fds $FDS"
        kill -TERM "$CPID"
    fi
    wait_client
    end_case
else
    echo "NOTE process-fact cases not run (set WAKE_CASES_STATIC=1 for the static build)"
fi

summary
