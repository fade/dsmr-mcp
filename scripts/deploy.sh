#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/deploy.sh: build a release of one commit and make it current.
#
# Usage: scripts/deploy.sh deploy
#        scripts/deploy.sh rollback
#        scripts/deploy.sh check-qlot
#
# Reads from the environment (the Makefile's deploy target passes them):
#   REPO       the git repository to export from (required)
#   REF        the commit to deploy, any form git rev-parse accepts (required)
#   DSMR_HOME  the deploy home; default ${XDG_DATA_HOME:-$HOME/.local/share}/dsmr-mcp
#   QLOT       the qlot executable (required)
#   QLOT_COMMIT  the commit the qlot checkout holding QLOT must have checked
#              out with no tracked change; empty skips that check
#   SBCL       the SBCL to build with; default sbcl
#   ALLOW_UNPUBLISHED  1 skips the check that REF is on an origin branch and
#              records `unpublished-ref-allowed yes` in the MANIFEST
#   DEPLOY_VERIFY_TIMEOUT  seconds the verify stage may run; default 120
#
# Gates, before anything is created under the home: the home is not inside a
# git work tree, REPO has no uncommitted change to a tracked file, and REF is
# reachable from a branch on origin. A refusal changes nothing.
#
# One flock on <home>/deploy.lock covers a whole deploy or rollback;
# <home>/deploy.holder names the process that holds it.
#
# Stages, each logged on stderr as `deploy: <stage>: ...`:
#   export        git archive of the commit into <home>/releases/<sha>/
#   dependencies  qlot install and qlot bundle into <release>/deps
#   build-server  the sealed release-server core, built by plain SBCL
#   manifest      <release>/MANIFEST, written once the build succeeded
#   verify-initialize  the release's own launcher answers initialize and tools/list
#   flip          <home>/current names the release, by one rename
#
# A failure in any stage prints `deploy: <stage> failed: ...; current is
# unchanged` and exits 1.
#
# A release directory is built at its final path and never renamed: an SBCL
# image records absolute source paths. A release with a MANIFEST is complete
# and is verified again without rebuilding; one without is an earlier attempt
# that stopped and is removed. A failed verify removes the MANIFEST and leaves
# current and previous untouched. A verified release is made read-only.
#
# rollback swaps current and previous with two renames. It runs no git, qlot,
# sbcl or make.
set -euo pipefail

# shellcheck source=release-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/release-paths.sh"


# Suffix fail() appends; set once the gates have passed and a stage can run.
FAIL_NOTE=""

die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }
say() { printf 'deploy: %s\n' "$*" >&2; }

# fail <stage> <reason>
# Exit 1 naming the stage that failed.
fail() {
  local stage="$1"
  shift
  die "$stage failed: $*$FAIL_NOTE"
}

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

# check_qlot <qlot> <commit>
# Exit 1 unless <qlot> is executable and, when <commit> is not empty, the git
# checkout one level above <qlot>'s directory has <commit> checked out with no
# tracked change. qlot reads a git source's dependencies, so a different qlot
# can resolve a different dependency set from the same lock.
check_qlot() {
  local qlot="$1" want="$2" dir have
  [ -x "$qlot" ] || fail dependencies "QLOT $qlot is not executable; provision qlot in \$LISP_WORKSPACE/qlot (run its scripts/setup.sh) or pass QLOT=<path>"
  [ -n "$want" ] || return 0
  dir="$(cd "$(dirname "$qlot")/.." && pwd)"
  have="$(git -C "$dir" rev-parse --verify --quiet HEAD)" \
    || fail dependencies "$dir is not a git checkout; QLOT_COMMIT needs QLOT inside a qlot checkout, or pass QLOT_COMMIT= to skip the check"
  [ "$have" = "$want" ] \
    || fail dependencies "qlot checkout $dir is at $have, not QLOT_COMMIT $want; check out $want there"
  git -C "$dir" diff --quiet HEAD \
    || fail dependencies "qlot checkout $dir has tracked changes; QLOT_COMMIT $want must be checked out clean"
}

# home_in_work_tree <home>
# Return 0 when <home>, or its nearest existing ancestor when it does not exist
# yet, is physically inside a git work tree.
home_in_work_tree() {
  local dir="$1" phys
  while [ ! -d "$dir" ]; do
    dir="$(dirname "$dir")"
  done
  phys="$(physical_dir "$dir")" || return 1
  inside_work_tree "$phys"
}

# take_lock <home> <what>
# Take the deploy lock on descriptor 9 without waiting, record the holder, and
# remove the record on exit. Exit 1 naming the holder when the lock is taken.
take_lock() {
  local home="$1" what="$2" holder="unknown holder"
  exec 9>>"$home/deploy.lock"
  if ! flock -n 9; then
    if [ -s "$home/deploy.holder" ]; then
      holder="$(head -n 1 "$home/deploy.holder")"
    fi
    die "another deploy holds $home/deploy.lock ($holder); wait for it to finish"
  fi
  printf 'pid %s %s started %s\n' "$$" "$what" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$home/deploy.holder"
  # shellcheck disable=SC2064 # expand $home now: it is out of scope when the trap runs
  trap "rm -f '$home/deploy.holder'" EXIT
  trap 'exit 130' HUP INT TERM
}

# lock_dependencies <qlfile.lock>
# Print one `dependency <name> <version>` line per entry of the lock, where
# version is the entry's :version value.
lock_dependencies() {
  awk '
    /^\("/ { name = $0; sub(/^\("/, "", name); sub(/".*$/, "", name) }
    name != "" && match($0, /:version "[^"]*"/) {
      v = substr($0, RSTART + 10, RLENGTH - 11)
      printf "dependency %s %s\n", name, v
      name = ""
    }
  ' "$1"
}

deploy() {
  local repo="${REPO:-}" ref="${REF:-}" qlot="${QLOT:-}" sbcl="${SBCL:-sbcl}"
  [ -n "$ref" ] || die "REF is empty; run make deploy REF=<sha>"
  [ -n "$repo" ] || die "REPO is empty; run deploy through make deploy"

  local sha
  sha="$(git -C "$repo" rev-parse --verify --quiet "$ref^{commit}")" \
    || die "REF $ref names no commit in $repo; check the sha or branch name"

  local home
  home="$(dsmr_home)" || exit 1

  # Gates: nothing is created under the home until all have passed.
  if home_in_work_tree "$home"; then
    die "DSMR_HOME $home is inside a git work tree; point DSMR_HOME at a directory outside every checkout"
  fi
  if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
    die "the working tree has uncommitted changes to tracked files; commit or stash them, then re-run"
  fi
  if [ "${ALLOW_UNPUBLISHED:-}" != "1" ]; then
    git -C "$repo" fetch --quiet origin \
      || die "cannot reach origin to prove $sha is published; fix the remote or set ALLOW_UNPUBLISHED=1"
    if [ -z "$(git -C "$repo" for-each-ref --contains "$sha" refs/remotes/origin)" ]; then
      die "$sha is on no origin branch; push it, then re-run"
    fi
  fi

  mkdir -p "$home"
  take_lock "$home" "sha $sha"
  FAIL_NOTE="; current is unchanged"
  mkdir -p "$home/releases"

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
    git -C "$repo" archive --format=tar "$sha" | tar -x -C "$rel" \
      || fail export "git archive of $sha failed; check $repo"

    check_qlot "$qlot" "${QLOT_COMMIT:-}"
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
      fail dependencies "qlot exited non-zero; read $rel/dependencies.log"
    fi
    rm -rf "$rel/.qlot"
    # A release carries no VCS metadata. qlot leaves .git entries in bundled
    # git sources, and the release guard counts any .git entry as a checkout tie.
    find "$rel/deps" -name .git -prune -exec rm -rf {} + \
      || fail dependencies "cannot remove .git entries under $rel/deps; check its permissions"
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
      fail build-server "the core build exited non-zero; read $rel/build.log"
    fi
    [ -s "$rel/core/dsmr.core" ] || fail build-server "no core at $rel/core/dsmr.core; read $rel/build.log"
    [ -s "$rel/core/dsmr.core.manifest" ] || fail build-server "no core manifest at $rel/core/dsmr.core.manifest; read $rel/build.log"
    mkdir -p "$rel/bin"
    install -m 0755 "$rel/scripts/release-launch.sh" "$rel/bin/dsmr-mcp-launch"
    say "build-server: done in $((SECONDS - t0))s, core $(stat -c %s "$rel/core/dsmr.core") bytes"

    [ -f "$rel/qlfile.lock" ] || fail manifest "no qlfile.lock in $rel; commit qlfile.lock"
    local sbcl_version
    sbcl_version="$(awk '/^sbcl-version /{ $1=""; sub(/^ /,""); print; exit }' "$rel/core/dsmr.core.manifest")"
    {
      printf 'commit %s\n' "$sha"
      printf 'ref %s\n' "$ref"
      printf 'dirty false\n'
      printf 'sbcl-version %s\n' "$sbcl_version"
      printf 'build-host %s\n' "$(hostname)"
      printf 'build-time %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if [ "${ALLOW_UNPUBLISHED:-}" = "1" ]; then
        printf 'unpublished-ref-allowed yes\n'
      fi
      printf 'qlfile-lock-sha256 %s\n' "$(sha256sum "$rel/qlfile.lock" | awk '{print $1}')"
      lock_dependencies "$rel/qlfile.lock"
    } >"$rel/MANIFEST.tmp" || fail manifest "cannot write $rel/MANIFEST.tmp"
    mv -f "$rel/MANIFEST.tmp" "$rel/MANIFEST"
    say "manifest: $rel/MANIFEST"
  fi

  local vscratch
  vscratch="$(mktemp -d "${TMPDIR:-/tmp}/dsmr-deploy-verify.XXXXXX")"
  if ! verify_initialize "$rel" "$sbcl" "$vscratch"; then
    chmod -R u+w "$rel"
    rm -f "$rel/MANIFEST"
    fail verify-initialize "$VERIFY_PROBLEM (output kept in $vscratch)"
  fi
  if [ ! -f "$rel/verify-initialize.jsonl" ]; then
    cp "$vscratch/verify-initialize.jsonl" "$vscratch/verify-initialize.log" "$rel/"
  fi
  rm -rf "$vscratch"
  chmod -R a-w "$rel"

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

# manifest_commit <release dir>
# Print the commit a release's MANIFEST records.
manifest_commit() {
  awk '$1 == "commit" { print $2; exit }' "$1/MANIFEST"
}

# rdie <message>: print a rollback refusal on stderr and exit 1.
rdie() { printf 'rollback: %s\n' "$*" >&2; exit 1; }

# rollback
# Swap current and previous with two renames. Runs no git, qlot, sbcl or make.
rollback() {
  local home cur prev
  home="$(dsmr_home)" || exit 1
  [ -d "$home" ] || rdie "no deploy home at $home; nothing to roll back to"
  take_lock "$home" "rollback"

  [ -L "$home/previous" ] \
    || rdie "no previous release at $home/previous; nothing to roll back to"
  [ -L "$home/current" ] \
    || rdie "no current release at $home/current; run make deploy REF=<sha>"
  prev="$(readlink "$home/previous")"
  cur="$(readlink "$home/current")"
  [ -f "$home/$prev/MANIFEST" ] \
    || rdie "$home/$prev has no MANIFEST; it is not a complete release, so deploy a known commit instead"

  ln -sfn "$prev" "$home/current.new"
  ln -sfn "$cur" "$home/previous.new"
  mv -Tf "$home/current.new" "$home/current"
  mv -Tf "$home/previous.new" "$home/previous"
  printf 'current -> %s (commit %s)\n' "$prev" "$(manifest_commit "$home/$prev")"
}

# verify_initialize <release> <sbcl> <scratch>
# Run the release's own launcher with a scrubbed environment and feed it an
# initialize, the initialized notification and tools/list. Return 0 when the
# launcher exits 0, id 1 names the server dsmr-mcp and id 2 lists at least one
# tool. Otherwise set VERIFY_PROBLEM and return 1. stdout is kept in
# <scratch>/verify-initialize.jsonl, stderr in <scratch>/verify-initialize.log;
# the release is not written, because it is read-only once verified.
VERIFY_PROBLEM=""
verify_initialize() {
  local rel="$1" sbcl="$2" scratch="$3" status t0
  local out="$scratch/verify-initialize.jsonl" err="$scratch/verify-initialize.log"
  t0=$SECONDS
  say "verify-initialize: $rel/bin/dsmr-mcp-launch"
  set +e
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"dsmr-deploy-verify","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | env -i HOME="$HOME" PATH="$PATH" SBCL="$sbcl" DSMR_MODE=hermetic \
          XDG_STATE_HOME="$scratch/state" XDG_CACHE_HOME="$scratch/cache" \
          timeout "${DEPLOY_VERIFY_TIMEOUT:-120}" "$rel/bin/dsmr-mcp-launch" \
          >"$out" 2>"$err"
  status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    VERIFY_PROBLEM="the launcher gave no answer within ${DEPLOY_VERIFY_TIMEOUT:-120}s (log $err); raise DEPLOY_VERIFY_TIMEOUT if the host is slow"
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    VERIFY_PROBLEM="the launcher exited $status (log $err)"
    return 1
  fi
  if ! jq -s -e 'any(.[]; .id == 1 and .result.serverInfo.name == "dsmr-mcp")' \
         "$out" >/dev/null 2>&1; then
    VERIFY_PROBLEM="no initialize reply naming dsmr-mcp in $out"
    return 1
  fi
  if ! jq -s -e 'any(.[]; .id == 2 and ((.result.tools // []) | length) > 0)' \
         "$out" >/dev/null 2>&1; then
    VERIFY_PROBLEM="no tools/list reply with tools in $out"
    return 1
  fi
  say "verify-initialize: passed in $((SECONDS - t0))s"
}

case "${1:-}" in
  deploy) deploy ;;
  rollback) rollback ;;
  check-qlot) check_qlot "${QLOT:-}" "${QLOT_COMMIT:-}" ;;
  *) die "usage: scripts/deploy.sh deploy|rollback|check-qlot (REPO, REF, DSMR_HOME, QLOT, QLOT_COMMIT and SBCL from the environment)" ;;
esac
