#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/release-launch.sh: launcher for the dsmr-mcp stdio MCP server of a
# deployed release. `make deploy` installs it into each release as
# bin/dsmr-mcp-launch.
#
# Boots the release's own server core, <root>/core/dsmr.core, where <root> is
# the release directory above this script's invoked path. It builds nothing,
# loads no source, and reads nothing from a development checkout.
#
# Exit codes:
#   78  refused: the release has no core or no MANIFEST. One line on stderr
#       names the reason and `make deploy`.
#   75  the server asks for a relaunch; the launcher boots again. The release
#       root is resolved again first, so a relaunch follows a moved `current`.
#   any other status is the server's own and ends the launcher with it.
#
# DSMR_RELEASE_ROOT and DSMR_BROKER_CORE are always set from the release, never
# taken from the caller. DSMR_WORKER_CORE is unset. stdout carries only
# JSON-RPC; every diagnostic goes to stderr and to
# ${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp/launcher.log.
set -u

SBCL="${SBCL:-sbcl}"
INVOKED="$0"

# Exit code for a refused start.
REFUSE_EXIT_CODE=78

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp"
LOG_FILE="$LOG_DIR/launcher.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
  local line
  line="$(date -Is) [dsmr-launch] $*"
  printf '%s\n' "$line" >&2
  printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

# release_root
# Print the physical path of the directory above the directory holding the
# invoked script. Resolved on every call, never cached, so a relaunch after a
# flip of `current` boots the release `current` names at that moment.
release_root() {
  local bindir
  bindir="$(cd -P "$(dirname "$INVOKED")" 2>/dev/null && pwd -P)" || return 1
  (cd -P "$bindir/.." 2>/dev/null && pwd -P)
}

# Exit code the server uses to ask the launcher for a relaunch (rung 3 of the
# recovery ladder). 75 = EX_TEMPFAIL (sysexits.h), unused by SBCL for anything
# else, so it cannot collide with an ordinary error exit. Override for testing.
RESTART_EXIT_CODE="${DSMR_RESTART_EXIT_CODE:-75}"

# Launch the server as a SUBPROCESS (no `exec`) so the shell survives to inspect
# the exit status and decide whether to relaunch.
#
# setsid puts the server in its own session with no controlling terminal. SBCL
# opens /dev/tty when one exists, on a descriptor of its own that no stream
# rebinding reaches, so a library writing to the terminal rather than to a
# stream lands in the operator's session and overwrites whatever is there.
# Redirecting stdout and stderr does not close that route; removing the
# terminal does. `-w` waits for the server and returns its exit status, which
# the relaunch loop below reads.
#
# --non-interactive ends SBCL when the server returns, so no REPL prompt
# reaches stdout after the client closes stdin.
SETSID="$(command -v setsid || true)"
run_server() {
  local root
  if ! root="$(release_root)"; then
    log "cannot start: no release directory above $INVOKED; run 'make deploy REF=<sha>'"
    return "$REFUSE_EXIT_CODE"
  fi
  local core="$root/core/dsmr.core"
  if [ ! -f "$core" ]; then
    log "cannot start: no core at $core; run 'make deploy REF=<sha>'"
    return "$REFUSE_EXIT_CODE"
  fi
  if [ ! -f "$root/MANIFEST" ]; then
    log "cannot start: no MANIFEST at $root/MANIFEST; run 'make deploy REF=<sha>'"
    return "$REFUSE_EXIT_CODE"
  fi

  export DSMR_RELEASE_ROOT="$root"
  export DSMR_BROKER_CORE="$core"
  unset DSMR_WORKER_CORE

  log "booting release $root"
  ${SETSID:+"$SETSID" -w} "$SBCL" --core "$core" --noinform --disable-debugger \
       --no-sysinit --no-userinit --non-interactive \
       --eval '(dsmr-mcp:run :transport :stdio)'
}

# Supervise loop: relaunch the server ONLY when it exits with the restart
# sentinel; any other exit code is a real shutdown and exits the launcher with
# that same code.
while true; do
  run_server
  status=$?
  if [ "$status" -eq "$RESTART_EXIT_CODE" ]; then
    log "restart requested (rc=$status); relaunching"
    continue
  else
    log "server exited with rc=$status; exiting launcher"
    exit "$status"
  fi
done
