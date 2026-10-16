#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/dsmr-mcp-launch.sh: lifecycle-managed launcher for the dsmr-mcp stdio
# MCP server.
#
# Booting the server by compiling from source takes ~65s cold, which exceeds the
# MCP client's ~30s startup window. A prebuilt SBCL core (`make core`) cuts that
# to ~0.1s, but a frozen image goes stale when SBCL is upgraded or a dependency
# changes. This wrapper keeps the speed without ever serving stale code. It
# looks after two images:
#
#   dsmr.core         the server itself.
#     fresh         -> run the server from the image (fast path)
#     stale/absent  -> source-load the server now (current code), and rebuild
#                      both images in the background (`make core`).
#
#   dsmr.core.worker  the image hermetic workers boot from.
#     fresh         -> export DSMR_WORKER_CORE=<its path> to the server
#     stale/absent  -> unset DSMR_WORKER_CORE, so workers source-load, and
#                      rebuild just this image in the background
#                      (`make core-worker`) unless the server rebuild above is
#                      already doing it.
#
# The two are judged independently, by the same rule, so either can be used
# while the other is being rebuilt. DSMR_WORKER_CORE is always set or unset
# here, never inherited: a path from the caller's environment is not trusted.
#
# Staleness is decided with plain shell tools and the manifest each build writes
# (dsmr.core.manifest, dsmr.core.worker.manifest), deliberately NOT with SBCL,
# so an SBCL upgrade (which makes an image unloadable) cannot also break the
# check. stdout carries only JSON-RPC; every diagnostic goes to stderr or the
# rebuild log.
set -u

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CORE="$REPO/dsmr.core"
MANIFEST="$CORE.manifest"
WORKER_CORE="$REPO/dsmr.core.worker"
LOG="$REPO/.dsmr-core-rebuild.log"
LOCK="$REPO/.dsmr-core-rebuild.lock"
SBCL="${SBCL:-sbcl}"

log() { printf '%s [dsmr-launch] %s\n' "$(date -Is)" "$*" >&2; }

# core_is_fresh <core> <manifest>
# Return 0 when the image can be trusted, non-zero (with a reason naming the
# image logged) otherwise.
core_is_fresh() {
  local core="$1" manifest="$2"
  [ -f "$core" ]     || { log "core missing ($core)"; return 1; }
  [ -f "$manifest" ] || { log "manifest missing ($manifest)"; return 1; }

  # SBCL identity: the core is build-specific and SBCL refuses a mismatched core
  # outright, so a version change must force a rebuild.
  local recorded current
  recorded="$(awk '/^sbcl-version /{ $1=""; sub(/^ /,""); print; exit }' "$manifest")"
  current="$("$SBCL" --version 2>/dev/null | awk '{print $2}')"
  if [ -n "$recorded" ] && [ "$recorded" != "$current" ]; then
    log "stale: $core: sbcl drift (core=$recorded current=$current)"; return 1
  fi

  # Any recorded source root with a file newer than the core => project edit,
  # patched workspace dep, or a Quicklisp dist update. Prune VCS dirs so repo
  # bookkeeping doesn't read as a source change.
  local roots=()
  while IFS= read -r r; do [ -n "$r" ] && roots+=("$r"); done \
    < <(awk '/^root /{ $1=""; sub(/^ /,""); print }' "$manifest")
  if [ "${#roots[@]}" -gt 0 ]; then
    local newer
    newer="$(find "${roots[@]}" \( -name .git -o -name .svn \) -prune -o \
                  -type f -newer "$core" -print -quit 2>/dev/null)"
    if [ -n "$newer" ]; then log "stale: $core: source newer than core ($newer)"; return 1; fi
  fi
  return 0
}

# trigger_rebuild [target]
# Regenerate an image in a detached, single-flighted job: `make core` (the
# default) rebuilds both images, `make core-worker` only the worker image. One
# flock covers every target, so overlapping rebuilds never run when several
# starts race; redirection keeps the build's output off the MCP stdio pipe
# entirely.
trigger_rebuild() {
  local target="${1:-core}"
  (
    flock -n 9 || { log "rebuild already in progress; skipping make $target"; exit 0; }
    log "regenerating in background (make $target)"
    cd "$REPO" && make "$target"
    log "make $target finished (rc=$?)"
  ) 9>"$LOCK" >>"$LOG" 2>&1 </dev/null &
  disown 2>/dev/null || true
}

# Exit code the server uses to ask the launcher for a relaunch (rung 3 of the
# recovery ladder). 75 = EX_TEMPFAIL (sysexits.h), unused by SBCL for anything
# else, so it cannot collide with an ordinary error exit. Override for testing.
RESTART_EXIT_CODE="${DSMR_RESTART_EXIT_CODE:-75}"

# Launch the server as a SUBPROCESS (no `exec`) so the shell survives to inspect
# the exit status and decide whether to relaunch. Freshness is re-checked on
# every call, for both images, so a core rebuilt while the previous instance ran
# is picked up on the next relaunch.
#
# setsid puts the server in its own session with no controlling terminal. SBCL
# opens /dev/tty when one exists, on a descriptor of its own that no stream
# rebinding reaches, so a library writing to the terminal rather than to a
# stream lands in the operator's session and overwrites whatever is there.
# Redirecting stdout and stderr does not close that route; removing the
# terminal does. `-w` waits for the server and returns its exit status, which
# the relaunch loop below reads.
SETSID="$(command -v setsid || true)"
run_server() {
  local server_fresh=0
  core_is_fresh "$CORE" "$MANIFEST" && server_fresh=1

  # Decide the worker image before either branch, so both hand the server the
  # same answer. A stale server core already triggers `make core`, which
  # rebuilds the worker image too, so only a fresh server core asks for the
  # worker rebuild on its own.
  if core_is_fresh "$WORKER_CORE" "$WORKER_CORE.manifest"; then
    export DSMR_WORKER_CORE="$WORKER_CORE"
    log "worker core fresh; workers boot from image"
  else
    unset DSMR_WORKER_CORE
    log "worker core stale or absent; workers source-load, regenerating in background"
    if [ "$server_fresh" -eq 1 ]; then trigger_rebuild core-worker; fi
  fi

  if [ "$server_fresh" -eq 1 ]; then
    log "core fresh; booting from image"
    ${SETSID:+"$SETSID" -w} "$SBCL" --core "$CORE" --noinform --disable-debugger --no-userinit \
         --eval '(dsmr-mcp:run :transport :stdio)'
  else
    log "core stale/absent; source-loading now, regenerating in background"
    trigger_rebuild
    # Fallback: compile from source with stdout kept clean (matches the
    # installer's hardened launcher — *debug-io*/*trace-output* carry the
    # SLYNK loader banner).
    ${SETSID:+"$SETSID" -w} "$SBCL" --noinform --disable-debugger --no-userinit \
         --eval '(require :asdf)' \
         --eval '(let ((s (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))) (when (probe-file s) (let ((*standard-output* *error-output*)) (load s))))' \
         --eval '(push (or (let ((w (uiop:getenv "LISP_WORKSPACE"))) (when (and w (not (uiop:string-prefix-p "~" w))) w)) (namestring (merge-pathnames #P"SourceCode/lisp/" (user-homedir-pathname)))) asdf:*central-registry*)' \
         --eval '(let ((*standard-output* *error-output*) (*trace-output* *error-output*) (*debug-io* (make-two-way-stream *standard-input* *error-output*))) (asdf:load-system :dsmr-mcp))' \
         --eval '(dsmr-mcp:run :transport :stdio)'
  fi
}

# Supervise loop: relaunch the server ONLY when it exits with the restart
# sentinel; any other exit code is a real shutdown and exits the launcher with
# that same code. Dropping `exec` above is what makes this loop reachable — an
# exec'd shell is replaced and could never relaunch.
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
