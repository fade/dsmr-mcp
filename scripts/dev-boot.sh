#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/dev-boot.sh
#
# Bring up a dsmr-mcp development image with a live Slynk listener:
#   - SBCL with quicklisp + LISP_WORKSPACE source-registry
#   - :dsmr-mcp loaded
#   - slynk listening on 127.0.0.1:4006        (M-x sly-connect, or attach)
#
# This is the image Claude Code's dsmr-mcp MCP server attaches to. The server
# runs in :attached mode (its default) and is configured (via DSMR_SLYNK_ATTACH
# in ~/.claude.json mcpServers.dsmr-mcp) to point at the listener this script
# starts. With the image up, dsmr-mcp's repl-eval / run-tests / inspect-* /
# attached code-find route through this live SBCL instead of a hermetic worker
# — so Claude Code drives the same image the operator has loaded, seeing the
# same definitions and state. Dogfooding dsmr-mcp on itself.
#
# If Claude Code was already attached when this script ran, run /mcp reload (or
# restart) so it picks up DSMR_SLYNK_ATTACH.
#
# Run from any directory. Foreground (default) execs SBCL and idles the main
# thread; pass --background to detach for headless use (logs to
# /tmp/dsmr-mcp-dev.log, PID to /tmp/dsmr-mcp-dev.pid).
#
# Stop with:
#   touch /tmp/dsmr-mcp-dev-stop          (graceful)
#   kill $(cat /tmp/dsmr-mcp-dev.pid)     (hard, --background only)
#
# Env (all optional):
#   SLYNK_PORT       slynk listen port      (default 4006)
#   SLYNK_HOST       slynk listen address   (default 127.0.0.1)
#   LISP_WORKSPACE   local-projects tree    (default ~/SourceCode/lisp/)
#   QUICKLISP_SETUP  quicklisp setup.lisp   (default ~/quicklisp/setup.lisp)
#   DSMR_LOG_LEVEL   debug|info|warn|error  (default debug — this is dev mode)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLYNK_PORT="${SLYNK_PORT:-4006}"
SLYNK_HOST="${SLYNK_HOST:-127.0.0.1}"
LISP_WORKSPACE="${LISP_WORKSPACE:-${HOME}/SourceCode/lisp}"
QUICKLISP_SETUP="${QUICKLISP_SETUP:-${HOME}/quicklisp/setup.lisp}"
# Dev mode defaults to debug-level logging; override by exporting DSMR_LOG_LEVEL.
DSMR_LOG_LEVEL="${DSMR_LOG_LEVEL:-debug}"
BACKGROUND=0

# Defensive tilde expansion. Some shell rc files set these to a literal
# '~/...' string (no expansion at assignment time); an unexpanded tilde
# survives [ -d ] as a non-directory and confuses asdf's source-registry.
LISP_WORKSPACE="${LISP_WORKSPACE/#\~/$HOME}"
QUICKLISP_SETUP="${QUICKLISP_SETUP/#\~/$HOME}"
LISP_WORKSPACE="${LISP_WORKSPACE%/}"

for arg in "$@"; do
  case "$arg" in
    --background|-b) BACKGROUND=1 ;;
    --help|-h)
      sed -n '4,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

# --- Pre-flight checks ------------------------------------------------------

if [ ! -f "$QUICKLISP_SETUP" ]; then
  echo "ERROR: quicklisp setup.lisp not found at $QUICKLISP_SETUP" >&2
  echo "       (set QUICKLISP_SETUP env var to override)" >&2
  exit 1
fi

if [ ! -d "$LISP_WORKSPACE" ]; then
  echo "ERROR: LISP_WORKSPACE=$LISP_WORKSPACE does not exist — refusing to boot" >&2
  exit 1
fi

if [ ! -f "$PROJECT_ROOT/dsmr-mcp.asd" ]; then
  echo "ERROR: dsmr-mcp.asd not found at $PROJECT_ROOT — is this the project root?" >&2
  exit 1
fi

if [ ! -f "$PROJECT_ROOT/scripts/dev-boot.lisp" ]; then
  echo "ERROR: scripts/dev-boot.lisp missing — refusing to start" >&2
  exit 1
fi

# Slynk port collision check — surface a bound port clearly; slynk would
# otherwise fail to bind several seconds into the boot.
if command -v ss >/dev/null 2>&1; then
  occupant=$(ss -tlnp 2>/dev/null \
             | awk -v port=":$SLYNK_PORT" '$4 ~ port {print $0; exit}')
  if [ -n "$occupant" ]; then
    echo "WARN: something is already listening on $SLYNK_HOST:$SLYNK_PORT" >&2
    echo "      $occupant" >&2
    echo "      slynk will fail to bind; kill the occupant or set SLYNK_PORT." >&2
  fi
fi

# Clear a stale stop sentinel so a previous graceful exit doesn't immediately
# stop the new image.
rm -f /tmp/dsmr-mcp-dev-stop

# --- Boot -------------------------------------------------------------------

cd "$PROJECT_ROOT"

# Inherited by scripts/dev-boot.lisp via uiop:getenv.
export SLYNK_PORT SLYNK_HOST LISP_WORKSPACE DSMR_LOG_LEVEL

SBCL_ARGS=(
  --noinform
  --disable-debugger
  --load "$QUICKLISP_SETUP"
  --load "$PROJECT_ROOT/scripts/dev-boot.lisp"
)

if [ "$BACKGROUND" -eq 1 ]; then
  LOG=/tmp/dsmr-mcp-dev.log
  PIDFILE=/tmp/dsmr-mcp-dev.pid
  echo "[dev-boot] starting in background — log: $LOG  pidfile: $PIDFILE"
  : > "$LOG"
  setsid sbcl "${SBCL_ARGS[@]}" >"$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDFILE"
  disown
  echo "[dev-boot] pid $(cat "$PIDFILE") — slynk will come up on $SLYNK_HOST:$SLYNK_PORT"
  echo "[dev-boot] tail -f $LOG to watch the boot banner"
else
  echo "[dev-boot] starting in foreground — Ctrl-C to stop"
  echo "[dev-boot] slynk will come up on $SLYNK_HOST:$SLYNK_PORT"
  exec sbcl "${SBCL_ARGS[@]}"
fi
