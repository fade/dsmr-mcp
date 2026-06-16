#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/dsmr-mcp-launch.sh — lifecycle-managed launcher for the dsmr-mcp stdio
# MCP server.
#
# Booting the server by compiling from source takes ~65s cold, which exceeds the
# MCP client's ~30s startup window. A prebuilt SBCL core (`make core`) cuts that
# to ~0.1s — but a frozen image goes stale when SBCL is upgraded or a dependency
# changes. This wrapper keeps the speed without ever serving stale code:
#
#   fresh core  -> exec the core (fast path)
#   stale/absent core -> exec the source-load launcher now (current code), and
#                        regenerate the core in the background for next time.
#
# Staleness is decided with plain shell tools and the manifest `make core` writes
# (dsmr.core.manifest) — deliberately NOT with SBCL, so an SBCL upgrade (which
# makes the core unloadable) cannot also break the check. stdout carries only
# JSON-RPC; every diagnostic goes to stderr or the rebuild log.
set -u

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CORE="$REPO/dsmr.core"
MANIFEST="$CORE.manifest"
LOG="$REPO/.dsmr-core-rebuild.log"
LOCK="$REPO/.dsmr-core-rebuild.lock"
SBCL="${SBCL:-sbcl}"

log() { printf '%s [dsmr-launch] %s\n' "$(date -Is)" "$*" >&2; }

# Return 0 when the core can be trusted, non-zero (with a reason logged) otherwise.
core_is_fresh() {
  [ -f "$CORE" ]     || { log "core missing ($CORE)"; return 1; }
  [ -f "$MANIFEST" ] || { log "manifest missing ($MANIFEST)"; return 1; }

  # SBCL identity: the core is build-specific and SBCL refuses a mismatched core
  # outright, so a version change must force a rebuild.
  local recorded current
  recorded="$(awk '/^sbcl-version /{ $1=""; sub(/^ /,""); print; exit }' "$MANIFEST")"
  current="$("$SBCL" --version 2>/dev/null | awk '{print $2}')"
  if [ -n "$recorded" ] && [ "$recorded" != "$current" ]; then
    log "stale: sbcl drift (core=$recorded current=$current)"; return 1
  fi

  # Any recorded source root with a file newer than the core => project edit,
  # patched workspace dep, or a Quicklisp dist update. Prune VCS dirs so repo
  # bookkeeping doesn't read as a source change.
  local roots=()
  while IFS= read -r r; do [ -n "$r" ] && roots+=("$r"); done \
    < <(awk '/^root /{ $1=""; sub(/^ /,""); print }' "$MANIFEST")
  if [ "${#roots[@]}" -gt 0 ]; then
    local newer
    newer="$(find "${roots[@]}" \( -name .git -o -name .svn \) -prune -o \
                  -type f -newer "$CORE" -print -quit 2>/dev/null)"
    if [ -n "$newer" ]; then log "stale: source newer than core ($newer)"; return 1; fi
  fi
  return 0
}

# Regenerate the core in a detached, single-flighted job. flock prevents
# overlapping rebuilds when several starts race; redirection keeps the build's
# output off the MCP stdio pipe entirely.
trigger_rebuild() {
  (
    flock -n 9 || { log "rebuild already in progress; skipping"; exit 0; }
    log "regenerating core in background (make core) …"
    cd "$REPO" && make core
    log "core regenerated (rc=$?)"
  ) 9>"$LOCK" >>"$LOG" 2>&1 </dev/null &
  disown 2>/dev/null || true
}

exec_core() {
  exec "$SBCL" --core "$CORE" --noinform --disable-debugger --no-userinit \
       --eval '(dsmr-mcp:run :transport :stdio)'
}

# Fallback: compile from source with stdout kept clean (matches the installer's
# hardened launcher — *debug-io*/*trace-output* carry the SLYNK loader banner).
exec_source_load() {
  exec "$SBCL" --noinform --disable-debugger --no-userinit \
       --eval '(require :asdf)' \
       --eval '(let ((s (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))) (when (probe-file s) (let ((*standard-output* *error-output*)) (load s))))' \
       --eval '(push (or (let ((w (uiop:getenv "LISP_WORKSPACE"))) (when (and w (not (uiop:string-prefix-p "~" w))) w)) (namestring (merge-pathnames #P"SourceCode/lisp/" (user-homedir-pathname)))) asdf:*central-registry*)' \
       --eval '(let ((*standard-output* *error-output*) (*trace-output* *error-output*) (*debug-io* (make-two-way-stream *standard-input* *error-output*))) (asdf:load-system :dsmr-mcp))' \
       --eval '(dsmr-mcp:run :transport :stdio)'
}

if core_is_fresh; then
  log "core fresh; booting from image"
  exec_core
else
  log "core stale/absent; source-loading now, regenerating in background"
  trigger_rebuild
  exec_source_load
fi
