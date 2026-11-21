#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/deploy.sh: build a release of one commit and make it current.
#
# Usage: scripts/deploy.sh deploy
#
# Reads from the environment (the Makefile's deploy target passes them):
#   REPO       the git repository to export from (required)
#   REF        the commit to deploy, any form git rev-parse accepts (required)
#   DSMR_HOME  the deploy home; default ${XDG_DATA_HOME:-$HOME/.local/share}/dsmr-mcp
#   QLOT       the qlot executable (required)
#   SBCL       the SBCL to build with; default sbcl
#
# Stages, each logged on stderr as `deploy: <stage>: ...`:
#   export        git archive of the commit into <home>/releases/<sha>/
#   dependencies  qlot install and qlot bundle into <release>/deps
#   build-server  the sealed release-server core, built by plain SBCL
#   manifest      <release>/MANIFEST, written once the build succeeded
#   verify        the release's own launcher answers initialize and tools/list
#   flip          <home>/current names the release, by one rename
#
# A release directory is built at its final path and never renamed: an SBCL
# image records absolute source paths. A release with a MANIFEST is complete
# and is verified again without rebuilding; one without is an earlier attempt
# that stopped and is removed. A failed verify removes the MANIFEST and leaves
# current and previous untouched.
set -euo pipefail

die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }
say() { printf 'deploy: %s\n' "$*" >&2; }

# Print the last 30 lines of log file $1 on stderr, then its path.
show_log_tail() {
  tail -n 30 "$1" >&2 || true
  printf 'deploy: full log: %s\n' "$1" >&2
}

# The `-u NAME` arguments for env that remove every DSMR_ variable and the two
# ASDF variables a caller might export.
scrub_args() {
  local name
  for name in $(env | sed -n 's/^\(DSMR_[A-Za-z0-9_]*\)=.*/\1/p'); do
    printf -- '-u\n%s\n' "$name"
  done
  printf -- '-u\nCL_SOURCE_REGISTRY\n-u\nASDF_OUTPUT_TRANSLATIONS\n'
}

deploy() {
  local repo="${REPO:-}" ref="${REF:-}" qlot="${QLOT:-}" sbcl="${SBCL:-sbcl}"
  [ -n "$ref" ] || die "REF is empty; run make deploy REF=<sha>"
  [ -n "$repo" ] || die "REPO is empty; run deploy through make deploy"

  local sha
  sha="$(git -C "$repo" rev-parse --verify --quiet "$ref^{commit}")" \
    || die "REF $ref names no commit in $repo; check the sha or branch name"

  local home="${DSMR_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/dsmr-mcp}"
  case "$home" in
    /*) ;;
    *) die "DSMR_HOME $home is relative; give an absolute path" ;;
  esac
  mkdir -p "$home/releases"

  exec 9>"$home/deploy.lock"
  flock -n 9 || die "another deploy holds $home/deploy.lock; wait for it to finish"

  local rel="$home/releases/$sha"
  local t0
  say "deploy $sha into $home"

  if [ -d "$rel" ] && [ ! -f "$rel/MANIFEST" ]; then
    say "export: removing incomplete earlier attempt $rel"
    chmod -R u+w "$rel"
    rm -rf "$rel"
  fi

  if [ -f "$rel/MANIFEST" ]; then
    say "export: $rel is complete; verifying it again without a rebuild"
  else
    say "export: git archive $sha"
    mkdir -p "$rel"
    git -C "$repo" archive --format=tar "$sha" | tar -x -C "$rel"

    [ -x "$qlot" ] || die "dependencies: QLOT $qlot is not executable; provision qlot in \$LISP_WORKSPACE/qlot (run its scripts/setup.sh) or pass QLOT=<path>"
    # qlot runs with the cache it was set up with, not the XDG_CACHE_HOME the
    # Makefile exports for the checkout's tests. Nothing from that cache
    # reaches the release; the bundle holds copies.
    t0=$SECONDS
    say "dependencies: qlot install and qlot bundle (log $rel/dependencies.log)"
    if ! (cd "$rel" \
            && env -u CL_SOURCE_REGISTRY -u ASDF_OUTPUT_TRANSLATIONS -u XDG_CACHE_HOME \
                   LISP=sbcl "$qlot" install \
            && env -u CL_SOURCE_REGISTRY -u ASDF_OUTPUT_TRANSLATIONS -u XDG_CACHE_HOME \
                   LISP=sbcl "$qlot" bundle --output deps) \
          >"$rel/dependencies.log" 2>&1; then
      show_log_tail "$rel/dependencies.log"
      die "dependencies: qlot failed; current is unchanged"
    fi
    rm -rf "$rel/.qlot"
    say "dependencies: done in $((SECONDS - t0))s"

    t0=$SECONDS
    say "build-server: sealed release-server core (log $rel/build.log)"
    mkdir -p "$rel/core" "$rel/cache"
    local scrub=()
    mapfile -t scrub < <(scrub_args)
    if ! env "${scrub[@]}" \
           XDG_CACHE_HOME="$rel/cache" \
           DSMR_CORE_KIND=release-server \
           DSMR_CORE_OUTPUT="$rel/core/dsmr.core" \
           DSMR_RELEASE_ROOT="$rel/" \
           DSMR_RELEASE_COMMIT="$sha" \
           "$sbcl" --noinform --no-sysinit --no-userinit --disable-debugger --non-interactive \
           --load "$rel/deps/setup.lisp" \
           --load "$rel/scripts/build-core.lisp" \
           >"$rel/build.log" 2>&1; then
      show_log_tail "$rel/build.log"
      die "build-server: the core build failed; current is unchanged"
    fi
    [ -s "$rel/core/dsmr.core" ] || die "build-server: no core at $rel/core/dsmr.core; read $rel/build.log"
    [ -s "$rel/core/dsmr.core.manifest" ] || die "build-server: no core manifest at $rel/core/dsmr.core.manifest; read $rel/build.log"
    mkdir -p "$rel/bin"
    install -m 0755 "$rel/scripts/release-launch.sh" "$rel/bin/dsmr-mcp-launch"
    say "build-server: done in $((SECONDS - t0))s, core $(stat -c %s "$rel/core/dsmr.core") bytes"

    local sbcl_version
    sbcl_version="$(awk '/^sbcl-version /{ $1=""; sub(/^ /,""); print; exit }' "$rel/core/dsmr.core.manifest")"
    {
      printf 'commit %s\n' "$sha"
      printf 'ref %s\n' "$ref"
      printf 'dirty false\n'
      printf 'sbcl-version %s\n' "$sbcl_version"
      printf 'build-host %s\n' "$(hostname)"
      printf 'build-time %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$rel/MANIFEST.tmp"
    mv -f "$rel/MANIFEST.tmp" "$rel/MANIFEST"
    say "manifest: $rel/MANIFEST"
  fi

  verify_initialize "$rel" "$sbcl" || {
    rm -f "$rel/MANIFEST"
    die "verify-initialize failed: $VERIFY_PROBLEM; current is unchanged"
  }

  local current="$home/current"
  if [ -L "$current" ]; then
    local old
    old="$(readlink "$current")"
    if [ "$old" != "releases/$sha" ]; then
      ln -sfn "$old" "$home/previous.new"
      mv -Tf "$home/previous.new" "$home/previous"
      say "flip: previous -> $old"
    fi
  fi
  ln -sfn "releases/$sha" "$home/current.new"
  mv -Tf "$home/current.new" "$current"
  say "flip: current -> releases/$sha"
}

# verify_initialize <release> <sbcl>
# Run the release's own launcher with a scrubbed environment and feed it an
# initialize, the initialized notification and tools/list. Return 0 when the
# launcher exits 0, id 1 names the server dsmr-mcp and id 2 lists at least one
# tool. Otherwise set VERIFY_PROBLEM and return 1. stdout is kept in
# <release>/verify-initialize.jsonl, stderr in <release>/verify-initialize.log.
VERIFY_PROBLEM=""
verify_initialize() {
  local rel="$1" sbcl="$2" scratch status t0
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/dsmr-deploy-verify.XXXXXX")"
  t0=$SECONDS
  say "verify-initialize: $rel/bin/dsmr-mcp-launch"
  set +e
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dsmr-deploy-verify","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | env -i HOME="$HOME" PATH="$PATH" SBCL="$sbcl" DSMR_MODE=hermetic \
          XDG_STATE_HOME="$scratch/state" XDG_CACHE_HOME="$scratch/cache" \
          timeout 120 "$rel/bin/dsmr-mcp-launch" \
          >"$rel/verify-initialize.jsonl" 2>"$rel/verify-initialize.log"
  status=$?
  set -e
  rm -rf "$scratch"
  if [ "$status" -ne 0 ]; then
    VERIFY_PROBLEM="the launcher exited $status (log $rel/verify-initialize.log)"
    return 1
  fi
  if ! jq -s -e 'any(.[]; .id == 1 and .result.serverInfo.name == "dsmr-mcp")' \
         "$rel/verify-initialize.jsonl" >/dev/null 2>&1; then
    VERIFY_PROBLEM="no initialize reply naming dsmr-mcp in $rel/verify-initialize.jsonl"
    return 1
  fi
  if ! jq -s -e 'any(.[]; .id == 2 and ((.result.tools // []) | length) > 0)' \
         "$rel/verify-initialize.jsonl" >/dev/null 2>&1; then
    VERIFY_PROBLEM="no tools/list reply with tools in $rel/verify-initialize.jsonl"
    return 1
  fi
  say "verify-initialize: passed in $((SECONDS - t0))s"
}

case "${1:-}" in
  deploy) deploy ;;
  *) die "usage: scripts/deploy.sh deploy (REPO, REF, DSMR_HOME, QLOT and SBCL from the environment)" ;;
esac
