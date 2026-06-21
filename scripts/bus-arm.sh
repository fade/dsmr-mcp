#!/bin/sh
# bus-arm.sh — thin launch wrapper for the dsmr-mcp bus wakeup watcher.
#
# Called two ways:
#   * at session start by the Claude Code SessionStart hook (bootstrap mode,
#     the default) — fires the FIRST watch so the loop is primed before turn
#     one. This is a one-shot priming arm, not a persistent watcher: the
#     watcher runs in exit-on-event mode (no --stream), so it exits the moment
#     the first foreign message lands or after one recycle window, and its
#     output is discarded (the session cannot observe it anyway). What keeps a
#     watcher armed thereafter is the in-turn re-arm path below, driven from
#     within the agent's turns — the bootstrap only gets the loop started.
#   * from within an agent turn after a publish+catch-up receive (re-arm mode,
#     --rearm) — runs the watcher with stdout kept so the turn observes the
#     wake signal, then records whether it fired or idled, and re-arms again
#     on the next turn.
#
# Adaptive cadence: the watcher polls fast and recycles quickly while the bus
# is hot, relaxing toward slow polling and long recycles after consecutive
# idle recycles, so it recovers promptly when busy and costs little when quiet.
# The bands below are tunable here without rebuilding the Lisp binary.
#
# Bootstrap mode detaches every file descriptor (</dev/null >/dev/null 2>&1 &):
# a background process that keeps the session's stdio open hangs Claude Code at
# startup, so the detach is mandatory, not cosmetic.

set -eu

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp/bus"
STATE_FILE="$STATE_DIR/watch-arm.state"

# Consecutive idle-recycle count (0 when the state file is absent/unreadable).
IDLE=0
if [ -f "$STATE_FILE" ]; then
    IDLE=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi
# Guard against a non-integer state file (empty, multi-line, or non-digit), then
# normalize to base-10. The guard rejects anything with a non-digit; the
# arithmetic re-evaluation with the 10# radix prefix forces base-10 so a value
# with leading zeros (e.g. 08) is never misread as octal by the integer tests
# below — which under set -e would abort the whole arm ("value too great for
# base 8") and leave no watcher primed.
case "$IDLE" in
    ''|*[!0-9]*) IDLE=0 ;;
esac
IDLE=$((10#$IDLE))

# Adaptive cadence bands (idle count -> poll-ms / recycle-seconds):
#   0    HOT     500ms / 60s   — just fired or fresh; match a live interaction.
#   1-2  WARM   1000ms / 120s
#   3-5  COOLING 1000ms / 300s
#   6+   IDLE   1000ms / 600s  — the 600s intentionally MIRRORS the watcher
#                                binary's own default recovery latency, but is
#                                passed explicitly below so the two stay in step
#                                even if the binary default later changes (the
#                                script never relies on the binary's default).
if [ "$IDLE" -eq 0 ]; then
    POLL_MS=500
    RECYCLE_S=60
elif [ "$IDLE" -le 2 ]; then
    POLL_MS=1000
    RECYCLE_S=120
elif [ "$IDLE" -le 5 ]; then
    POLL_MS=1000
    RECYCLE_S=300
else
    POLL_MS=1000
    RECYCLE_S=600
fi

# Mode select: --rearm picks re-arm; anything else (incl. no arg) is bootstrap.
MODE="bootstrap"
if [ "${1:-}" = "--rearm" ]; then
    MODE="rearm"
fi

if [ "$MODE" = "bootstrap" ]; then
    # Detach all fds so the SessionStart hook does not hang; arm and exit.
    nohup dsmr-bus-watch --poll-ms "$POLL_MS" --recycle-seconds "$RECYCLE_S" \
        </dev/null >/dev/null 2>&1 &
    exit 0
fi

# Re-arm: keep stdout so the turn observes the watcher's first signal line, and
# update the idle counter — reset to 0 on a fire (bus:), increment on idle
# (recycle:).
mkdir -p "$STATE_DIR"

# The arm script is the operator's only feedback channel for "is the watcher
# even installed?", so a missing binary must be a distinguishable, visible
# signal rather than a silently-swallowed empty line repeated turn after turn.
if ! command -v dsmr-bus-watch >/dev/null 2>&1; then
    echo "bus-arm: dsmr-bus-watch not found on PATH (run the installer or 'make bus-watch')" >&2
    printf 'error:watcher-missing\n'
    exit 0
fi

# Capture the watcher's diagnostics rather than discarding them, so a crash or
# a non-zero exit is not muted. head -n 1 takes the single signal line that
# exit-on-event mode emits: this re-arm path depends on the watcher running
# WITHOUT --stream (one line, then exit). A future --stream caller would emit
# many lines and head would close the pipe (SIGPIPE) — a latent coupling, so
# any later --stream change must revisit this pipeline. We do not rely on the
# pipeline exit status (head masks the watcher's, and pipefail is not portable
# in /bin/sh); the SIGNAL shape below is what distinguishes fire/idle/failure.
WATCH_ERR=$(mktemp "${TMPDIR:-/tmp}/bus-arm-err.XXXXXX")
SIGNAL=$(dsmr-bus-watch --poll-ms "$POLL_MS" --recycle-seconds "$RECYCLE_S" \
    </dev/null 2>"$WATCH_ERR" | head -n 1)
case "$SIGNAL" in
    bus:*)
        echo 0 >"$STATE_FILE"
        printf '%s\n' "$SIGNAL"
        ;;
    recycle:*)
        echo $((IDLE + 1)) >"$STATE_FILE"
        printf '%s\n' "$SIGNAL"
        ;;
    *)
        # Empty or unrecognized signal: the watcher failed before emitting a
        # signal line. Surface its stderr and a distinguishable marker so the
        # turn can tell "watcher failed" from "watcher idled" — do NOT touch the
        # idle counter (a crash is not an idle recycle).
        [ -s "$WATCH_ERR" ] && cat "$WATCH_ERR" >&2
        printf 'error:watcher-failed\n'
        ;;
esac
rm -f "$WATCH_ERR"
