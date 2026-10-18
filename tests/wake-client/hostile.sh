#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Hostile-service cases for the wake client (src/bus/wake/dsmr-bus-watch.c):
# a service that truncates, floods, stalls, garbles or lies. Each case gives
# the client a 3 s deadline and an outage grace of 60 s unless it says
# otherwise. A reply outside the grammar must print nothing: the only output
# allowed is the client's own idle or outage text.
#
# usage: hostile.sh CLIENT
#   RUNNER=PREFIX  run the client under PREFIX (a valgrind line, say)
#
# Prints `PASS <case>` or `FAIL <case>: <detail>` per case and a summary
# line; exits 1 when any case fails.

set -u
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
lib_init "$@"

ID=(--agent a --namespace /n/)
VALID='reply=EXIT 0 event bus%3A5%0A -\n'
OUTAGE3=$'dsmr-bus-watch: the host bus service has not answered for 3 seconds, so no mail can wake you; check it with systemctl --user status dsmr-bus-host, then wake again\n'
OUTAGE2=$'dsmr-bus-watch: the host bus service has not answered for 2 seconds, so no mail can wake you; check it with systemctl --user status dsmr-bus-host, then wake again\n'

# The client idled at its 3 s deadline and printed nothing else.
expect_idle3() {
    expect_rc 0
    expect_out $'idle wake-seconds=3\n'
    expect_err ''
    expect_ms 2800 4500
}

# malformed NAME ACTION: every connection gets ACTION; the client must idle,
# having reconnected with its backoff (more than one request, at most 15).
malformed() {
    setup_case "$1"
    start_fake "$2"
    run_client 3 --wake "${ID[@]}" --wake-seconds 3
    expect_idle3
    local n
    n=$(requests)
    if [ "$n" -lt 2 ] || [ "$n" -gt 15 ]; then
        note "service saw $n requests, want 2-15"
    fi
    end_case
}

# then_valid NAME ACTION: ACTION first, then a valid reply, which must print.
then_valid() {
    setup_case "$1"
    start_fake "$2" "$VALID"
    run_client 3 --wake "${ID[@]}" --wake-seconds 3
    expect_rc 0
    expect_out $'bus:5\n'
    expect_err ''
    expect_requests 2
    end_case
}

# printed NAME ACTION OUT [ERR [STATUS]]: the reply is valid and prints.
printed() {
    setup_case "$1"
    start_fake "$2"
    run_client 3 --wake "${ID[@]}" --wake-seconds 3
    expect_rc "${5:-0}"
    expect_out "$3"
    expect_err "${4:-}"
    expect_requests 1
    end_case
}

A4096=$(printf 'a%.0s' $(seq 4096))
A32769=$(printf 'a%.0s' $(seq 32769))
E4096=$(printf '%%41%.0s' $(seq 4096))

# ------------------------------------------------------- framing and length

malformed truncated-reply-then-close-idles 'reply=EXIT 0 event bus%3A5'
then_valid truncated-reply-then-a-valid-reply-prints 'reply=EXIT 0 ev'
malformed a-line-of-32769-bytes-with-no-line-feed-idles "reply=$A32769"
then_valid an-over-long-line-then-a-valid-reply-prints "reply=$A32769"
malformed an-over-long-line-ending-in-a-line-feed-idles "reply=EXIT 0 event $A32769 -\\n"

setup_case a-flood-idles-and-the-client-stays-small
start_fake flood
start_client 3 --wake "${ID[@]}" --wake-seconds 3
MAX_RSS=0
RSS_CHECKED=0
if client_pid; then
    sleep 0.5
    if [ -z "$RUNNER" ] && ! grep -q 'ld-linux' "/proc/$CPID/maps" 2>/dev/null; then
        RSS_CHECKED=1
        for _ in 1 2 3 4; do
            RSS=$(awk '/^VmRSS:/ {print $2}' "/proc/$CPID/status" 2>/dev/null)
            if [ -n "$RSS" ] && [ "$RSS" -gt "$MAX_RSS" ]; then MAX_RSS=$RSS; fi
            sleep 0.4
        done
    fi
fi
wait_client
expect_idle3
if [ "$RSS_CHECKED" = 1 ]; then
    if [ "$MAX_RSS" -eq 0 ] || [ "$MAX_RSS" -ge 1024 ]; then
        note "VmRSS while flooded peaked at $MAX_RSS kB, want under 1024"
    fi
    echo "NOTE flooded client VmRSS peak $MAX_RSS kB"
else
    echo "NOTE flood RSS not sampled (dynamic build or RUNNER set)"
fi
end_case

# ----------------------------------------------------------- bytes on the wire

malformed a-raw-nul-inside-the-line-is-malformed 'reply=EXIT 0 event bus%3A5\x00x -\n'
then_valid a-raw-nul-then-a-valid-reply-prints 'reply=EXIT 0 event bus%3A5\x00 -\n'
malformed an-escaped-nul-in-a-text-is-malformed 'reply=EXIT 0 event bus%3A5%00%0A ok%0A\n'
malformed an-escape-character-in-the-stdout-text-is-malformed 'reply=EXIT 0 event bus%3A5%1B%5B2J%0A ok%0A\n'
malformed an-escape-character-in-the-stderr-text-is-malformed 'reply=EXIT 2 event ok%0A bus%3A5%1B%5B2J%0A\n'
malformed a-carriage-return-in-a-text-is-malformed 'reply=EXIT 0 event bus%3A5%0D%0A ok%0A\n'
malformed a-delete-in-a-text-is-malformed 'reply=EXIT 0 event bus%3A5%7F%0A ok%0A\n'
printed a-tab-and-a-line-feed-in-a-text-print 'reply=EXIT 0 event a%09b%0Ac%0A -\n' $'a\tb\nc\n'
malformed a-lowercase-escape-is-malformed 'reply=EXIT 0 event bus%3a5%0A ok%0A\n'
malformed a-lowercase-line-feed-escape-is-malformed 'reply=EXIT 0 event bus%3A5%0a ok%0A\n'
malformed a-non-hex-escape-is-malformed 'reply=EXIT 0 event bus%G15%0A ok%0A\n'
malformed a-truncated-escape-at-the-end-of-a-text-is-malformed 'reply=EXIT 0 event ok%0A ab%4\n'
malformed a-percent-at-the-end-of-a-text-is-malformed 'reply=EXIT 0 event ok%0A ab%\n'
malformed a-raw-space-inside-a-text-makes-six-tokens 'reply=EXIT 0 event bus:5 x%0A -\n'
malformed a-raw-byte-above-0x7e-is-malformed 'reply=EXIT 0 event caf\xc3\xa9%0A -\n'
malformed a-raw-delete-in-the-line-is-malformed 'reply=EXIT 0 event ok\x7f%0A -\n'
malformed a-raw-tab-in-the-line-is-malformed 'reply=EXIT 0 event ok\t%0A -\n'
malformed a-carriage-return-before-the-line-feed-is-malformed 'reply=EXIT 0 event ok%0A -\x0d\n'
malformed a-raw-character-outside-the-text-set-is-malformed 'reply=EXIT 0 event ok:5%0A -\n'
malformed a-dash-inside-a-text-is-malformed 'reply=EXIT 0 event a-b%0A -\n'

# ------------------------------------------------------------- text bounds

malformed a-decoded-text-of-4097-octets-is-malformed "reply=EXIT 0 event ${A4096}a -\\n"
printed a-decoded-text-of-4096-octets-prints "reply=EXIT 0 event $A4096 -\\n" "$A4096"
malformed a-text-of-4097-escapes-is-malformed "reply=EXIT 0 event $E4096%41 -\\n"
printed a-text-of-4096-escapes-prints "reply=EXIT 0 event $E4096 -\\n" "${A4096//a/A}"
printed invalid-utf-8-octets-print-as-raw-bytes 'reply=EXIT 0 event %FF%FE%0A -\n' $'\xff\xfe\n'

# ------------------------------------------------------- statuses and tokens

malformed a-status-of-3-is-malformed 'reply=EXIT 3 event ok%0A -\n'
malformed a-status-of-00-is-malformed 'reply=EXIT 00 event ok%0A -\n'
malformed a-status-of-minus-1-is-malformed 'reply=EXIT -1 event ok%0A -\n'
malformed a-status-of-143-is-malformed 'reply=EXIT 143 event ok%0A -\n'
malformed a-capitalised-kind-is-malformed 'reply=EXIT 0 Event ok%0A -\n'
malformed a-kind-of-17-characters-is-malformed 'reply=EXIT 0 abcdefghijklmnopq ok%0A -\n'
printed a-kind-of-16-characters-is-accepted 'reply=EXIT 0 abcdefghijklmnop ok%0A -\n' $'ok\n'
malformed an-empty-token-is-malformed 'reply=EXIT 0  event ok%0A -\n'
malformed a-trailing-space-is-malformed 'reply=EXIT 0 event ok%0A - \n'
malformed four-tokens-are-malformed 'reply=EXIT 0 event ok%0A\n'
malformed six-tokens-are-malformed 'reply=EXIT 0 event ok%0A - -\n'
malformed an-unknown-first-word-is-malformed 'reply=HELLO 0 event ok%0A -\n'
malformed a-readers-answer-is-malformed-for-a-wake 'reply=READERS 1\n'
malformed an-unknown-err-code-is-malformed 'reply=ERR nope x\n'
malformed an-empty-line-is-malformed 'reply=\n'

setup_case a-bad-bus-reply-with-a-malformed-text-runs-nothing
start_fake 'reply=ERR bad-bus a%zz\n'
run_client 3 --wake "${ID[@]}" --wake-seconds 3
expect_idle3
end_case

# ------------------------------------------------- stalls and the outage clock

setup_case a-slow-drip-that-never-ends-the-line-idles
start_fake 'drip=500:EXIT 0 event aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
run_client 3 --wake "${ID[@]}" --wake-seconds 3
expect_idle3
expect_requests 1
end_case

setup_case a-slow-drip-with-a-1-second-grace-still-idles
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=1)
start_fake 'drip=500:EXIT 0 event aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
run_client 3 --wake "${ID[@]}" --wake-seconds 3
expect_idle3
end_case

setup_case malformed-replies-after-a-held-connection-never-reset-the-outage-clock
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=3)
start_fake 'after=1500:garbage\n'
run_client 10 --wake "${ID[@]}" --wake-seconds 10
expect_rc 1
expect_out $'nowatcher bus=default\n'
expect_err "$OUTAGE3"
expect_ms 3000 7000
end_case

setup_case a-held-err-reply-without-text-never-resets-the-outage-clock
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=3)
start_fake 'after=1500:ERR busy\n'
run_client 10 --wake "${ID[@]}" --wake-seconds 10
expect_rc 1
expect_out $'nowatcher bus=default\n'
expect_err "$OUTAGE3"
expect_ms 3000 7000
end_case

setup_case a-held-retry-reply-keeps-the-outage-clock-at-rest
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=3)
start_fake 'after=1500:ERR busy x\n'
run_client 6 --wake "${ID[@]}" --wake-seconds 6
expect_rc 0
expect_out $'idle wake-seconds=6\n'
expect_err ''
expect_ms 5800 7500
end_case

setup_case busy-forever-ends-in-an-outage-and-the-backoff-holds
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=2)
start_fake 'reply=ERR busy x\n'
run_client 30 --wake "${ID[@]}" --wake-seconds 30
expect_rc 1
expect_out $'nowatcher bus=default\n'
expect_err "$OUTAGE2"
expect_ms 1800 3500
if [ "$(requests)" -gt 15 ]; then note "service saw $(requests) requests, want at most 15"; fi
end_case

setup_case an-immediate-close-then-refused-connections-end-in-an-outage
CENV+=(DSMR_WAKE_OUTAGE_GRACE_SECONDS=2)
start_fake close
start_client 30 --wake "${ID[@]}" --wake-seconds 30
sleep 0.3
kill -KILL "$FAKE_PID"
wait "$FAKE_PID" 2>/dev/null
if [ ! -S "$SOCK" ]; then note "socket gone, connections would not be refused"; fi
wait_client
expect_rc 1
expect_out $'nowatcher bus=default\n'
expect_err "$OUTAGE2"
expect_ms 1800 3500
end_case

setup_case an-immediate-close-then-refused-connections-idle-within-the-grace
start_fake close
start_client 3 --wake "${ID[@]}" --wake-seconds 3
sleep 0.3
kill -KILL "$FAKE_PID"
wait "$FAKE_PID" 2>/dev/null
wait_client
expect_idle3
end_case

printed a-valid-reply-sent-one-byte-per-write-prints \
    'drip=5:EXIT 0 event bus%3A6%20one%20byte%0A wait%0A\n' $'bus:6 one byte\n' $'wait\n'

summary
