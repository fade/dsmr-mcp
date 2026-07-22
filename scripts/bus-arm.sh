#!/bin/sh
# bus-arm.sh — SessionStart bootstrap prime for the dsmr-mcp bus watcher.
#
# Called by the Claude Code SessionStart hook to prime a one-shot watcher before
# turn one, so a watcher and its heartbeat exist the moment a session comes up.
# It runs the watcher in exit-on-event mode, detached from the session's stdio,
# and discards its signal: a detached process cannot wake the session, and it is
# not meant to. The STANDING listener is a persistent Monitor the agent arms at
# bring-up (see the bus-watch skill) — each streamed message becomes a live
# notification there. This bootstrap only makes sure something is watching, and a
# heartbeat is present for --check-live, from t=0 until the agent arms the Monitor.
#
# Detaching every file descriptor (</dev/null >/dev/null 2>>log &) is mandatory,
# not cosmetic: a SessionStart hook that keeps the session's stdio open hangs
# Claude Code at startup.
#
# There is deliberately no re-arm mode and no adaptive-cadence machinery here.
# The per-turn re-arm dance and the idle-counter cadence bands were compensations
# for running the STANDING watch as a background task that woke the agent only on
# process exit. The persistent Monitor removes that whole class of problem — it
# wakes per streamed line — so this script is now just the one-shot prime it was
# always meant to be.

set -eu

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp/bus"
ARM_LOG="$STATE_DIR/watch-arm.log"

# Fixed cadence for the prime. Poll fast so a message arriving in the window
# before the agent arms its Monitor is seen promptly; a modest recycle so a quiet
# prime self-exits rather than lingering beside the standing watch. Reaction
# latency is governed by --poll-ms, never by --recycle-seconds.
POLL_MS=250
RECYCLE_S=120

# Identity, passed explicitly rather than inferred. The watcher reads the cursor
# named by the full <namespace>/<name> id; the namespace is the project root the
# MCP session uses, which the hook exports as CLAUDE_PROJECT_DIR. The trailing
# separator is load-bearing: the id is matched by encoded bytes, so a root without
# it names a cursor that never exists.
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$PROJECT_ROOT" in
    */) : ;;
    *)  PROJECT_ROOT="$PROJECT_ROOT/" ;;
esac

# Build identity args as positional parameters so a root containing spaces
# survives intact. Neither flag is required: with only DSMR_BUS_AGENT set, or with
# nothing, the watcher degrades to firing on everything and says so on stderr — a
# no-migration default for every sister repo.
set -- --namespace "$PROJECT_ROOT"
if [ -n "${DSMR_BUS_AGENT:-}" ]; then
    set -- "$@" --agent "$DSMR_BUS_AGENT"
fi

mkdir -p "$STATE_DIR"

# Detach stdin/stdout so the SessionStart hook does not hang; stderr goes to the
# arm log rather than /dev/null, because this path cannot report to a session that
# has not begun and the log is the only place a wrong namespace or an unreadable
# cursor can be found afterward.
nohup dsmr-bus-watch --poll-ms "$POLL_MS" --recycle-seconds "$RECYCLE_S" "$@" \
    </dev/null >/dev/null 2>>"$ARM_LOG" &
exit 0
