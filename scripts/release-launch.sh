#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/release-launch.sh: launcher for the dsmr-mcp stdio MCP server of a
# deployed release. `make deploy` installs it into each release as
# bin/dsmr-mcp-launch.
#
# Boots the release's own server core, <root>/core/dsmr.core, where <root> is
# the physical directory above the directory of this script's invoked path. The
# root is resolved again before every boot, so a relaunch follows a moved
# `current`. It builds nothing, runs no build tool, loads no source and derives
# nothing from a development checkout.
#
# Before each boot it refuses, with exit 78 and one line on stderr naming the
# reason and the remedy, when:
#   - HOME is unset or empty;
#   - the launcher's physical path or the release root is inside a git work
#     tree;
#   - the deploy home, releases/, the root, scripts/ or
#     scripts/release-paths.sh is not owned by the running user or is group or
#     world writable (checked before anything from the release is sourced);
#   - bin/, the launcher, core/, the core or its manifest is not owned by the
#     running user or is group or world writable;
#   - the core, its manifest or MANIFEST is missing;
#   - the core manifest's sbcl-version is not the running SBCL's;
#   - the core does not boot.
# The checks after the source are release_refusal in
# <root>/scripts/release-paths.sh, which `make register` shares; the launcher
# alone runs the ones before it, since nothing from the release can be sourced
# until they pass.
#
# Exports, always from the release and never from the caller:
#   DSMR_RELEASE_ROOT   the release root
#   DSMR_BROKER_CORE    the server core
#   DSMR_LAUNCHER_PATH  this launcher's physical path
#   DSMR_WORKER_CORE    <root>/core/dsmr.core.worker when it and its manifest
#                       exist, are owned by the running user and are not group
#                       or world writable, and the running SBCL built it; unset
#                       otherwise,
#                       and hermetic workers then refuse to spawn
# DSMR_ALLOW_SOURCE_WORKERS is always unset.
#
# Exit codes: 78 refused; 75 from the server asks for a relaunch; any other
# status is the server's own and ends the launcher with it.
#
# stdout carries only JSON-RPC. Every diagnostic goes to stderr and to
# ${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp/launcher.log.
set -u

SBCL="${SBCL:-sbcl}"
export SBCL
INVOKED="$0"

# Exit code for a refused start.
REFUSE_EXIT_CODE=78

LOG_FILE=""
if [ -n "${XDG_STATE_HOME:-}" ] || [ -n "${HOME:-}" ]; then
  LOG_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}/dsmr-mcp"
  mkdir -p "$LOG_DIR" 2>/dev/null && LOG_FILE="$LOG_DIR/launcher.log"
fi

log() {
  local line
  line="$(date -Is) [dsmr-launch] $*"
  printf '%s\n' "$line" >&2
  if [ -n "$LOG_FILE" ]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
}

# refuse REASON
# Log `cannot start: REASON` and return 78.
refuse() {
  log "cannot start: $*"
  return "$REFUSE_EXIT_CODE"
}

# release_root
# Print the physical path of the directory above the directory holding the
# invoked script. Resolved on every call, never cached.
release_root() {
  local bindir
  bindir="$(cd -P "$(dirname "$INVOKED")" 2>/dev/null && pwd -P)" || return 1
  (cd -P "$bindir/.." 2>/dev/null && pwd -P)
}

# Exit code the server uses to ask the launcher for a relaunch (rung 3 of the
# recovery ladder). 75 = EX_TEMPFAIL (sysexits.h), unused by SBCL for anything
# else, so it cannot collide with an ordinary error exit. Override for testing.
RESTART_EXIT_CODE="${DSMR_RESTART_EXIT_CODE:-75}"

# The server runs as a subprocess, not by `exec`, so the shell survives to read
# its exit status and relaunch.
#
# setsid puts the server in its own session with no controlling terminal. SBCL
# opens /dev/tty when one exists, on a descriptor of its own that no stream
# rebinding reaches, so a library writing to the terminal rather than to a
# stream lands in the operator's session and overwrites whatever is there.
# Redirecting stdout and stderr does not close that route; removing the
# terminal does. `-w` waits for the server and returns its exit status.
#
# --non-interactive ends SBCL when the server returns, so no REPL prompt
# reaches stdout after the client closes stdin.
SETSID="$(command -v setsid || true)"

# source_chain_problem ROOT
# Print `<reason>; <remedy>` and return 0 when a path that
# ROOT/scripts/release-paths.sh could be replaced through is missing, owned by
# another user, or group or world writable: the deploy home and releases/ above
# ROOT, ROOT, ROOT/scripts and the file itself. Return 1 when all are sound.
# Runs before release-paths.sh is sourced, so it uses nothing from the release;
# the full list, shared with preflight, is release_path_problem in that file.
source_chain_problem() {
  local root="$1" path
  for path in "$(dirname "$(dirname "$root")")" "$(dirname "$root")" "$root" \
              "$root/scripts" "$root/scripts/release-paths.sh"; do
    if [ ! -O "$path" ]; then
      printf '%s is not owned by %s; restore ownership and permissions of %s\n' \
             "$path" "$(id -un)" "$path"
      return 0
    fi
    if [ -n "$(find "$path" -maxdepth 0 -perm /022 2>/dev/null)" ]; then
      printf '%s is group or world writable; restore ownership and permissions of %s\n' \
             "$path" "$path"
      return 0
    fi
  done
  return 1
}

# run_server
# Check the release `current` names now, export its paths and boot its server
# core. Return 78 on a refusal, else the server's exit status.
run_server() {
  if [ -z "${HOME:-}" ]; then
    refuse "HOME is unset or empty; start the server with HOME set"
    return
  fi
  local root launcher path
  if ! root="$(release_root)"; then
    refuse "no release directory above $INVOKED; run make deploy REF=<sha>"
    return
  fi

  # Checked before anything from the release is sourced, so code inside a
  # checkout never runs.
  launcher="$(readlink -f "$INVOKED")"
  for path in "$(dirname "$launcher")" "$root"; do
    if [ "$(git -C "$path" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
      refuse "$path is inside a git work tree; run make deploy REF=<sha> and make register"
      return
    fi
  done

  if [ ! -f "$root/scripts/release-paths.sh" ]; then
    refuse "no $root/scripts/release-paths.sh; run make deploy REF=<sha>"
    return
  fi
  local problem
  if problem="$(source_chain_problem "$root")"; then
    refuse "$problem"
    return
  fi
  # shellcheck source=release-paths.sh
  . "$root/scripts/release-paths.sh"

  if ! declare -F release_refusal >/dev/null; then
    refuse "$root/scripts/release-paths.sh does not define release_refusal; run make deploy REF=<sha>"
    return
  fi
  if ! problem="$(release_refusal "$root" "$launcher")"; then
    refuse "$problem"
    return
  fi

  local core="$root/core/dsmr.core"
  export DSMR_RELEASE_ROOT="$root"
  export DSMR_BROKER_CORE="$core"
  export DSMR_LAUNCHER_PATH="$launcher"
  unset DSMR_ALLOW_SOURCE_WORKERS
  # Offered only on status 1, the check's answer for "may be offered". Any
  # other status withholds, and a missing function leaves wstatus at 0.
  local reason wstatus=0
  if declare -F worker_core_withheld >/dev/null; then
    reason="$(worker_core_withheld "$root")" || wstatus=$?
  else
    reason="$root/scripts/release-paths.sh does not define worker_core_withheld"
  fi
  if [ "$wstatus" -ne 1 ]; then
    unset DSMR_WORKER_CORE
    log "worker core withheld: ${reason:-the worker core check failed}; hermetic workers will refuse to spawn"
  else
    export DSMR_WORKER_CORE="$root/core/dsmr.core.worker"
  fi

  log "booting release $(awk '$1 == "commit" { print $2; exit }' "$root/MANIFEST") from $root"
  ${SETSID:+"$SETSID" -w} "$SBCL" --core "$core" --noinform --disable-debugger \
       --no-sysinit --no-userinit --non-interactive \
       --eval '(dsmr-mcp:run :transport :stdio)'
}

# Supervise loop: relaunch the server only when it exits with the restart
# sentinel; any other status ends the launcher with that status.
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
