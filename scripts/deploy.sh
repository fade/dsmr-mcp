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
#   DEPLOY_WORKER_TIMEOUT  seconds verify-worker waits for the worker's
#              handshake; default 30
#   HOST_LINKS 0 skips every step that writes outside the home: the bus binary
#              links in BINDIR and the copies into SKILLDIR, AGENTDIR and
#              SUBAGENTDIR
#   FORCE      1 replaces deployed files that were edited in place
#   BINDIR     where the bus binary links go; default $HOME/.local/bin
#   SKILLDIR, AGENTDIR, SUBAGENTDIR  the host's skill, agent configuration and
#              agent definition directories; defaults $HOME/.claude/skills,
#              $HOME/.claude and $AGENTDIR/agents
#
# Gates, before anything is created under the home: a home other than the
# default does not write to the host's own BINDIR, SKILLDIR, AGENTDIR or
# SUBAGENTDIR unless HOST_LINKS is 0, the home is not inside a git work tree,
# REPO has no uncommitted change to a tracked file, and REF is reachable from a
# branch on origin. A refusal changes nothing.
#
# One flock on <home>/deploy.lock covers a whole deploy or rollback;
# <home>/deploy.holder names the process that holds it.
#
# Stages, each logged on stderr as `deploy: <stage>: ...`:
#   export        git archive of the commit into <home>/releases/<sha>/
#   dependencies  qlot install and qlot bundle into <release>/deps
#   build-server  the sealed release-server core, built by plain SBCL
#   build-worker  the release-worker core, <release>/core/dsmr.core.worker,
#                 built the same way with HOME kept so the host Quicklisp is found
#   build-bus     <release>/bin/dsmr-bus-watch and dsmr-bus-host, built by the
#                 release's own Makefile against the release's bundle
#   manifest      <release>/MANIFEST, written once the build succeeded
#   verify-initialize  the release's own launcher answers initialize and
#                 tools/list, and serverInfo.version carries the full commit
#   verify-worker the worker core passes scripts/verify-core-worker.lisp from the
#                 inside, then boots as the pool boots a worker and prints a
#                 handshake, kept as <release>/verify-worker.json
#   verify-bus    each bus binary answers --help with exit 0 and some output
#   check-copies  no destination of a copy below was edited in place since the
#                 last deploy (see check_copies); FORCE=1 overrides. Skipped
#                 when HOST_LINKS=0
#   flip          <home>/current names the release, by one rename
#   links         $BINDIR/dsmr-bus-watch and dsmr-bus-host become links to
#                 <home>/current/bin/<name>; a regular file there is kept as
#                 <name>.pre-release-<UTC stamp> first. Skipped when HOST_LINKS=0
#   copies        the release's skills, agent definitions and harness files are
#                 copied, never linked, into SKILLDIR, SUBAGENTDIR and AGENTDIR.
#                 Skipped when HOST_LINKS=0
#
# A failure in any stage before the flip prints `deploy: <stage> failed: ...;
# current is unchanged` and exits 1. A failure after it names the release now
# current and the redeploy that finishes the host steps.
#
# A release directory is built at its final path and never renamed: an SBCL
# image records absolute source paths. A release with a MANIFEST is complete
# and is verified again without rebuilding; one without is an earlier attempt
# that stopped and is removed. A failed verify removes the MANIFEST and leaves
# current and previous untouched. A verified release is made read-only.
#
# The releases current and previous name are never removed or changed. A deploy
# of the commit current names runs no build, verify or flip: only check-copies,
# links and copies, with the release previous names as the base, so it is the
# redeploy that finishes the host steps after a failure. A deploy of the commit
# previous names verifies it again and, on a failure, keeps its MANIFEST. A
# current or previous release with no MANIFEST is refused, not removed.
#
# rollback runs check-copies with the release it leaves as the base, swaps
# current and previous with two renames, then runs the links and copies
# stages. It runs no git, qlot, sbcl or make.
set -euo pipefail

# shellcheck source=release-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/release-paths.sh"


# Suffix fail() appends; set once the gates have passed and a stage can run.
FAIL_NOTE=""

# The bus binaries a release builds and the host reaches through links.
BUS_BINARIES="dsmr-bus-watch dsmr-bus-host"

# The word say() starts each line with; rollback sets it to rollback.
LOG_PREFIX=deploy

die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }
say() { printf '%s: %s\n' "$LOG_PREFIX" "$*" >&2; }

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

# host_default <VAR>
# Print the host's own directory for BINDIR, SKILLDIR, AGENTDIR or SUBAGENTDIR.
host_default() {
  case "$1" in
    BINDIR) printf '%s\n' "${HOME:-}/.local/bin" ;;
    SKILLDIR) printf '%s\n' "${HOME:-}/.claude/skills" ;;
    AGENTDIR) printf '%s\n' "${HOME:-}/.claude" ;;
    SUBAGENTDIR) printf '%s\n' "${HOME:-}/.claude/agents" ;;
  esac
}

# Fill each host destination left empty with its default.
BINDIR="${BINDIR:-$(host_default BINDIR)}"
SKILLDIR="${SKILLDIR:-$(host_default SKILLDIR)}"
AGENTDIR="${AGENTDIR:-$(host_default AGENTDIR)}"
SUBAGENTDIR="${SUBAGENTDIR:-$AGENTDIR/agents}"

# host_problem <home>
# Print a refusal and return 1 when <home> is a scratch home (host_home_p),
# HOST_LINKS is not 0, and one of BINDIR, SKILLDIR, AGENTDIR or SUBAGENTDIR
# still names the host's own directory. Paths are compared resolved, so another
# spelling of a host directory is caught too.
host_problem() {
  local home="$1" var
  [ "${HOST_LINKS:-}" = "0" ] && return 0
  host_home_p "$home" && return 0
  for var in BINDIR SKILLDIR AGENTDIR SUBAGENTDIR; do
    if [ "$(realpath -m -- "${!var}")" = "$(realpath -m -- "$(host_default "$var")")" ]; then
      printf 'deploy home %s is a scratch home but %s is the host'"'"'s %s; set HOST_LINKS=0 or point BINDIR, SKILLDIR, AGENTDIR and SUBAGENTDIR at scratch directories\n' \
        "$home" "$var" "${!var}"
      return 1
    fi
  done
}

# link_bus_binaries <home>
# Make $BINDIR/<name> a symbolic link to <home>/current/bin/<name> for each bus
# binary, so the host's fixed paths follow current. A regular file in the way is
# kept as <name>.pre-release-<UTC stamp> (a hard link when the file system
# allows one, else a copy) before the link is renamed over it. Skipped when
# HOST_LINKS=0. Return 1 with LINK_PROBLEM set on a failure.
LINK_PROBLEM=""
link_bus_binaries() {
  local home="$1" name dest target stamp tmp
  if [ "${HOST_LINKS:-}" = "0" ]; then
    say "links: skipped (HOST_LINKS=0)"
    return 0
  fi
  mkdir -p "$BINDIR" || { LINK_PROBLEM="cannot create $BINDIR"; return 1; }
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  for name in $BUS_BINARIES; do
    dest="$BINDIR/$name"
    target="$home/current/bin/$name"
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$target" ]; then
      say "links: $dest -> $target"
      continue
    fi
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      if [ ! -f "$dest" ]; then
        LINK_PROBLEM="$dest is neither a regular file nor a link; move it away"
        return 1
      fi
      ln "$dest" "$dest.pre-release-$stamp" 2>/dev/null \
        || cp -p "$dest" "$dest.pre-release-$stamp" \
        || { LINK_PROBLEM="cannot keep $dest as $dest.pre-release-$stamp"; return 1; }
      say "links: kept $dest as $dest.pre-release-$stamp"
    fi
    tmp="$BINDIR/.$name.link.$$"
    if ! { ln -sfn "$target" "$tmp" && mv -Tf "$tmp" "$dest"; }; then
      rm -f "$tmp"
      LINK_PROBLEM="cannot link $dest to $target"
      return 1
    fi
    say "links: $dest -> $target"
  done
  say "links: a running dsmr-bus-host keeps its image until systemctl --user restart dsmr-bus-host, which is a deliberate act; a running watcher keeps its image until it is re-armed"
}

# copy_plan <release>
# Print one line per file the copies stage deploys from <release>, as
# <path in release> TAB <destination> TAB <mode>, where mode x marks the copy
# executable and p keeps the source's executable bit. The selection matches the
# Makefile's check targets: files at depth two or more under skills/, outside
# __pycache__, into SKILLDIR; agents/*.md except README.md into SUBAGENTDIR;
# every file under harness/ into AGENTDIR.
copy_plan() {
  local rel="$1" f
  if [ -d "$rel/skills" ]; then
    (cd "$rel/skills" && find . -mindepth 2 -type f ! -path '*__pycache__*' | sed 's|^\./||' | sort) \
      | while IFS= read -r f; do printf 'skills/%s\t%s/%s\tp\n' "$f" "$SKILLDIR" "$f"; done
  fi
  if [ -d "$rel/agents" ]; then
    (cd "$rel/agents" && find . -maxdepth 1 -type f -name '*.md' ! -name README.md | sed 's|^\./||' | sort) \
      | while IFS= read -r f; do printf 'agents/%s\t%s/%s\tp\n' "$f" "$SUBAGENTDIR" "$f"; done
  fi
  if [ -d "$rel/harness" ]; then
    (cd "$rel/harness" && find . -type f | sed 's|^\./||' | sort) \
      | while IFS= read -r f; do printf 'harness/%s\t%s/%s\tx\n' "$f" "$AGENTDIR" "$f"; done
  fi
}

# check_copies <new release> <base release or empty>
# Return 0 when every destination in copy_plan <new release> is absent, equal
# to the new release's copy, or equal to the base release's copy: the base is
# the release current named before this change, so a destination equal to it
# is the one the last deploy wrote. Any other destination was edited in place
# and is listed on stderr. With no base, any destination that differs from the
# new copy counts as edited. FORCE=1 lists them and returns 0. Otherwise set
# COPY_PROBLEM and return 1. Skipped when HOST_LINKS=0.
COPY_PROBLEM=""
check_copies() {
  local new="$1" base="$2" src dest mode edited=0
  if [ "${HOST_LINKS:-}" = "0" ]; then
    say "check-copies: skipped (HOST_LINKS=0)"
    return 0
  fi
  while IFS=$'\t' read -r src dest mode; do
    [ -e "$dest" ] || [ -L "$dest" ] || continue
    cmp -s "$new/$src" "$dest" && continue
    if [ -n "$base" ] && [ -f "$base/$src" ] && cmp -s "$base/$src" "$dest"; then
      continue
    fi
    say "copies: $dest was edited in place since the last deploy; port the edit into the tree, or pass FORCE=1 to replace it"
    edited=$((edited + 1))
  done < <(copy_plan "$new")
  [ "$edited" -eq 0 ] && return 0
  if [ "${FORCE:-}" = "1" ]; then
    say "check-copies: FORCE=1: replacing $edited file(s) edited in place"
    return 0
  fi
  COPY_PROBLEM="$edited deployed file(s) listed above were edited in place since the last deploy; port each edit into the tree, or pass FORCE=1 to replace them"
  return 1
}

# copy_files <release>
# Copy each file in copy_plan <release> to a temporary name beside its
# destination and rename it into place, mode 0755 when marked x or executable
# in the release, else 0644. A destination already equal to the release's copy
# is left alone. Never makes a link. Skipped when HOST_LINKS=0. Return 1 with
# COPY_PROBLEM set on a failure.
copy_files() {
  local rel="$1" src dest mode dir tmp perm copied=0 same=0
  if [ "${HOST_LINKS:-}" = "0" ]; then
    say "copies: skipped (HOST_LINKS=0)"
    return 0
  fi
  while IFS=$'\t' read -r src dest mode; do
    if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$rel/$src" "$dest"; then
      same=$((same + 1))
      continue
    fi
    dir="$(dirname "$dest")"
    tmp="$dir/.$(basename "$dest").copy.$$"
    perm=0644
    if [ "$mode" = x ] || [ -x "$rel/$src" ]; then perm=0755; fi
    if ! { mkdir -p "$dir" && cp "$rel/$src" "$tmp" && chmod "$perm" "$tmp" && mv -Tf "$tmp" "$dest"; }; then
      rm -f "$tmp"
      COPY_PROBLEM="cannot copy $rel/$src to $dest"
      return 1
    fi
    copied=$((copied + 1))
  done < <(copy_plan "$rel")
  say "copies: $copied copied, $same already equal, into $SKILLDIR, $SUBAGENTDIR and $AGENTDIR"
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
  local problem
  if ! problem="$(host_problem "$home")"; then
    die "$problem"
  fi
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
  local t0 role
  say "deploy $sha into $home"
  role="$(live_role "$rel" "$home")"

  if [ -n "$role" ] && [ ! -f "$rel/MANIFEST" ]; then
    if [ "$role" = current ]; then
      fail export "$rel is the release current names but has no MANIFEST; it was left as it is, so run make rollback or deploy another commit"
    fi
    fail export "$rel is the release previous names but has no MANIFEST; it was left as it is, so deploy another commit first, which moves previous off it"
  fi

  if [ "$role" = current ]; then
    say "export: $rel is current; only the host steps run"
    local prev_rel=""
    if [ -L "$home/previous" ]; then
      prev_rel="$home/$(readlink "$home/previous")"
    fi
    check_copies "$rel" "$prev_rel" || fail check-copies "$COPY_PROBLEM"
    say "flip: current already names releases/$sha"
    FAIL_NOTE="; current is releases/$sha; fix the cause and run make deploy REF=$sha again, which repeats only the host steps"
    link_bus_binaries "$home" || fail links "$LINK_PROBLEM"
    copy_files "$rel" || fail copies "$COPY_PROBLEM"
    return 0
  fi

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

    t0=$SECONDS
    say "build-worker: release-worker core (log $rel/build-worker.log)"
    if ! env "${scrub[@]}" \
           XDG_CACHE_HOME="$rel/cache" \
           DSMR_CORE_KIND=release-worker \
           DSMR_CORE_OUTPUT="$rel/core/dsmr.core.worker" \
           DSMR_RELEASE_ROOT="$rel/" \
           DSMR_RELEASE_COMMIT="$sha" \
           "$sbcl" --noinform --no-sysinit --no-userinit --disable-debugger --non-interactive \
           --load "$rel/deps/setup.lisp" \
           --load "$rel/scripts/build-core.lisp" \
           >"$rel/build-worker.log" 2>&1; then
      show_log_tail "$rel/build-worker.log"
      fail build-worker "the worker core build exited non-zero; read $rel/build-worker.log"
    fi
    [ -s "$rel/core/dsmr.core.worker" ] || fail build-worker "no worker core at $rel/core/dsmr.core.worker; read $rel/build-worker.log"
    grep -qx 'kind release-worker' "$rel/core/dsmr.core.worker.manifest" 2>/dev/null \
      || fail build-worker "$rel/core/dsmr.core.worker.manifest does not say kind release-worker; read $rel/build-worker.log"
    say "build-worker: done in $((SECONDS - t0))s, core $(stat -c %s "$rel/core/dsmr.core.worker") bytes"

    t0=$SECONDS
    say "build-bus: $BUS_BINARIES (log $rel/build-bus.log)"
    if ! env "${scrub[@]}" -u MAKEFLAGS -u MFLAGS -u MAKELEVEL \
           XDG_CACHE_HOME="$rel/cache" \
           make -C "$rel" --no-print-directory bus-watch bus-host \
           BUS_DEPS_SETUP="$rel/deps/setup.lisp" SBCL="$sbcl" \
           >"$rel/build-bus.log" 2>&1; then
      show_log_tail "$rel/build-bus.log"
      fail build-bus "the bus binary build exited non-zero; read $rel/build-bus.log"
    fi
    local name
    for name in $BUS_BINARIES; do
      [ -f "$rel/bin/$name" ] && [ -x "$rel/bin/$name" ] \
        || fail build-bus "no executable $rel/bin/$name; read $rel/build-bus.log"
    done
    say "build-bus: done in $((SECONDS - t0))s"

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
  if ! verify_initialize "$rel" "$sbcl" "$vscratch" "$sha"; then
    reject_release verify-initialize "$VERIFY_PROBLEM (output kept in $vscratch)" "$rel" "$role"
  fi
  if ! verify_worker "$rel" "$sbcl" "$vscratch"; then
    reject_release verify-worker "$VERIFY_PROBLEM (output kept in $vscratch)" "$rel" "$role"
  fi
  if ! verify_bus "$rel" "$vscratch"; then
    reject_release verify-bus "$VERIFY_PROBLEM (output kept in $vscratch)" "$rel" "$role"
  fi
  if [ ! -f "$rel/verify-initialize.jsonl" ]; then
    cp "$vscratch/verify-initialize.jsonl" "$vscratch/verify-initialize.log" "$rel/"
  fi
  if [ ! -f "$rel/verify-worker.json" ]; then
    cp "$vscratch/verify-worker.json" "$rel/"
  fi
  rm -rf "$vscratch"
  chmod -R a-w "$rel"

  local current="$home/current" base=""
  if [ -L "$current" ]; then
    base="$home/$(readlink "$current")"
  fi
  check_copies "$rel" "$base" || fail check-copies "$COPY_PROBLEM"

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
  FAIL_NOTE="; current is releases/$sha; fix the cause and run make deploy REF=$sha again, which repeats only the host steps"

  link_bus_binaries "$home" || fail links "$LINK_PROBLEM"
  copy_files "$rel" || fail copies "$COPY_PROBLEM"
}

# live_role <release dir> <home>
# Print current or previous when that link under <home> names <release dir>,
# current first; print nothing otherwise.
live_role() {
  local rel="$1" home="$2" l
  [ -e "$rel" ] || return 0
  for l in current previous; do
    if [ -L "$home/$l" ] && [ "$home/$l" -ef "$rel" ]; then
      printf '%s\n' "$l"
      return 0
    fi
  done
}

# reject_release <stage> <problem> <release dir> <role>
# Exit 1 naming the failed verify stage. A release no link names loses its
# MANIFEST, so the next deploy of its commit rebuilds it; one that <role>
# (current or previous) names is left as it is.
reject_release() {
  local stage="$1" problem="$2" rel="$3" role="$4"
  if [ -n "$role" ]; then
    fail "$stage" "$problem; $rel is the release $role names, so it was left as it is"
  fi
  chmod -R u+w "$rel"
  rm -f "$rel/MANIFEST"
  fail "$stage" "$problem"
}

# manifest_commit <release dir>
# Print the commit a release's MANIFEST records.
manifest_commit() {
  awk '$1 == "commit" { print $2; exit }' "$1/MANIFEST"
}

# rdie <message>: print a rollback refusal on stderr and exit 1.
rdie() { printf 'rollback: %s\n' "$*" >&2; exit 1; }

# rollback
# Check the copies against the release being left, swap current and previous
# with two renames, then repair the bus binary links and copy the restored
# release's skills, agent definitions and harness files. Runs no git, qlot, sbcl
# or make.
rollback() {
  local home cur prev
  LOG_PREFIX=rollback
  home="$(dsmr_home)" || exit 1
  local problem
  if ! problem="$(host_problem "$home")"; then
    rdie "$problem"
  fi
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
  check_copies "$home/$prev" "$home/$cur" \
    || rdie "check-copies failed: $COPY_PROBLEM; current is unchanged"

  ln -sfn "$prev" "$home/current.new"
  ln -sfn "$cur" "$home/previous.new"
  mv -Tf "$home/current.new" "$home/current"
  mv -Tf "$home/previous.new" "$home/previous"
  printf 'current -> %s (commit %s)\n' "$prev" "$(manifest_commit "$home/$prev")"
  link_bus_binaries "$home" \
    || rdie "links failed: $LINK_PROBLEM; current is $prev; fix the cause and run make deploy REF=$(manifest_commit "$home/$prev") to finish the host steps (it repeats only those, since that commit is current), not a second rollback, which swaps back"
  copy_files "$home/$prev" \
    || rdie "copies failed: $COPY_PROBLEM; current is $prev; fix the cause and run make deploy REF=$(manifest_commit "$home/$prev") to finish the host steps (it repeats only those, since that commit is current), not a second rollback, which swaps back"
}

# verify_initialize <release> <sbcl> <scratch> <commit>
# Run the release's own launcher with a scrubbed environment and feed it an
# initialize, the initialized notification and tools/list. Return 0 when the
# launcher exits 0, id 1 names the server dsmr-mcp with a serverInfo.version
# that contains <commit>, and id 2 lists at least one tool. Otherwise set VERIFY_PROBLEM and return 1. stdout is kept in
# <scratch>/verify-initialize.jsonl, stderr in <scratch>/verify-initialize.log;
# the release is not written, because it is read-only once verified.
VERIFY_PROBLEM=""
verify_initialize() {
  local rel="$1" sbcl="$2" scratch="$3" commit="$4" status t0
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
  if ! jq -s -e --arg commit "$commit" \
         'any(.[]; .id == 1 and ((.result.serverInfo.version // "") | type == "string" and contains($commit)))' \
         "$out" >/dev/null 2>&1; then
    VERIFY_PROBLEM="serverInfo.version in $out does not carry $commit, so the launcher is not running this release"
    return 1
  fi
  if ! jq -s -e 'any(.[]; .id == 2 and ((.result.tools // []) | length) > 0)' \
         "$out" >/dev/null 2>&1; then
    VERIFY_PROBLEM="no tools/list reply with tools in $out"
    return 1
  fi
  say "verify-initialize: passed in $((SECONDS - t0))s"
}

# verify_worker <release> <sbcl> <scratch>
# Check the release's worker core in two steps. First boot it with
# scripts/verify-core-worker.lisp under the DSMR-WORKER prefix and the release
# root, which checks it from the inside. Then start it as the pool starts a
# worker, with a random secret, the deploy's pid as parent and scratch state and
# cache directories, and require its first JSON line on stdout within
# DEPLOY_WORKER_TIMEOUT seconds (default 30) to carry a numeric tcp_port, a
# numeric pid and a protocol_version. The worker is stopped with SIGTERM either
# way. Return 0 and keep the line in <scratch>/verify-worker.json on success;
# otherwise set VERIFY_PROBLEM and return 1.
verify_worker() {
  local rel="$1" sbcl="$2" scratch="$3" t0 status
  local wcore="$rel/core/dsmr.core.worker"
  local inside="$scratch/verify-worker-inside.log"
  local out="$scratch/verify-worker.out" err="$scratch/verify-worker.err"
  local limit="${DEPLOY_WORKER_TIMEOUT:-30}"
  t0=$SECONDS
  say "verify-worker: $wcore"
  if [ ! -s "$wcore" ]; then
    VERIFY_PROBLEM="no worker core at $wcore; deploy the commit again to rebuild the release"
    return 1
  fi
  set +e
  env -i HOME="$HOME" PATH="$PATH" \
      DSMR_VERIFY_WORKER_PREFIX=DSMR-WORKER DSMR_RELEASE_ROOT="$rel/" \
      XDG_STATE_HOME="$scratch/state" XDG_CACHE_HOME="$scratch/cache" \
      "$sbcl" --core "$wcore" --noinform --disable-debugger --non-interactive \
      --no-sysinit --no-userinit --load "$rel/scripts/verify-core-worker.lisp" \
      </dev/null >"$inside" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    VERIFY_PROBLEM="the worker core failed its inside check, exit $status (log $inside)"
    return 1
  fi

  local secret pid line="" waited=0
  secret="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  env -i HOME="$HOME" PATH="$PATH" \
      DSMR_WORKER_SECRET="$secret" DSMR_WORKER_ID=deploy-verify \
      DSMR_PARENT_PID="$$" DSMR_NO_WORKER_POOL=1 \
      XDG_STATE_HOME="$scratch/worker-state" XDG_CACHE_HOME="$scratch/worker-cache" \
      "$sbcl" --core "$wcore" --noinform --disable-debugger --no-sysinit --no-userinit \
      --eval '(asdf:clear-source-registry)' --eval '(cl-user::dsmr-worker-entry)' \
      </dev/null >"$out" 2>"$err" &
  pid=$!
  while [ "$waited" -lt $((limit * 10)) ]; do
    line="$(grep -m 1 '^{' "$out" 2>/dev/null || true)"
    [ -n "$line" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -n "$line" ] || line="$(grep -m 1 '^{' "$out" 2>/dev/null || true)"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [ -z "$line" ]; then
    VERIFY_PROBLEM="the worker core printed no handshake within ${limit}s (stdout $out, stderr $err)"
    return 1
  fi
  if ! printf '%s\n' "$line" | jq -e '(.tcp_port|type)=="number" and (.pid|type)=="number" and has("protocol_version")' >/dev/null 2>&1; then
    VERIFY_PROBLEM="the worker's first line is not a handshake with a numeric tcp_port and pid and a protocol_version: $line"
    return 1
  fi
  printf '%s\n' "$line" >"$scratch/verify-worker.json"
  say "verify-worker: passed in $((SECONDS - t0))s"
}

# verify_bus <release> <scratch>
# Run each bus binary with --help under scratch state and cache directories.
# Return 0 when every one exits 0 within DEPLOY_VERIFY_TIMEOUT seconds and
# prints something; otherwise set VERIFY_PROBLEM and return 1. The watcher
# prints its usage on stderr, since its stdout carries only signal lines.
verify_bus() {
  local rel="$1" scratch="$2" name bin out status t0
  t0=$SECONDS
  say "verify-bus: $BUS_BINARIES --help"
  for name in $BUS_BINARIES; do
    bin="$rel/bin/$name"
    out="$scratch/verify-bus-$name"
    if [ ! -f "$bin" ] || [ ! -x "$bin" ]; then
      VERIFY_PROBLEM="no executable $bin; deploy the commit again to rebuild the release"
      return 1
    fi
    set +e
    env -i HOME="$HOME" PATH="$PATH" \
        XDG_STATE_HOME="$scratch/bus-state" XDG_CACHE_HOME="$scratch/bus-cache" \
        timeout "${DEPLOY_VERIFY_TIMEOUT:-120}" "$bin" --help \
        </dev/null >"$out.out" 2>"$out.err"
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      VERIFY_PROBLEM="$name --help exited $status (stderr $out.err)"
      return 1
    fi
    if [ ! -s "$out.out" ] && [ ! -s "$out.err" ]; then
      VERIFY_PROBLEM="$name --help printed nothing (stdout $out.out, stderr $out.err)"
      return 1
    fi
  done
  say "verify-bus: passed in $((SECONDS - t0))s"
}

case "${1:-}" in
  deploy) deploy ;;
  rollback) rollback ;;
  check-qlot) check_qlot "${QLOT:-}" "${QLOT_COMMIT:-}" ;;
  *) die "usage: scripts/deploy.sh deploy|rollback|check-qlot (REPO, REF, DSMR_HOME, QLOT, QLOT_COMMIT and SBCL from the environment)" ;;
esac
