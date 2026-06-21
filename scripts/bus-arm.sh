#!/bin/sh
# bus-arm.sh — thin launch wrapper for the dsmr-mcp bus wakeup watcher.
#
# Called two ways:
#   * at session start by the Claude Code SessionStart hook (bootstrap mode,
#     the default) — fires the first watch so a fresh agent has a watcher
#     running before turn one;
#   * from within an agent turn after a publish+catch-up receive (re-arm mode,
#     --rearm) — runs the watcher with stdout kept so the turn observes the
#     wake signal, then records whether it fired or idled.
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
# Guard against a non-integer state file.
case "$IDLE" in
    ''|*[!0-9]*) IDLE=0 ;;
esac

# Adaptive cadence bands (idle count -> poll-ms / recycle-seconds):
#   0    HOT     500ms / 60s   — just fired or fresh; match a live interaction.
#   1-2  WARM   1000ms / 120s
#   3-5  COOLING 1000ms / 300s
#   6+   IDLE   1000ms / 600s  — the watcher's own default recovery latency.
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
SIGNAL=$(dsmr-bus-watch --poll-ms "$POLL_MS" --recycle-seconds "$RECYCLE_S" \
    </dev/null 2>/dev/null | head -n 1)
case "$SIGNAL" in
    bus:*)
        echo 0 >"$STATE_FILE"
        ;;
    recycle:*)
        echo $((IDLE + 1)) >"$STATE_FILE"
        ;;
esac
printf '%s\n' "$SIGNAL"
