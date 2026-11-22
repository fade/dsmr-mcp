#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Exercises scripts/deploy.sh against a temporary origin and clone, with a stub
# qlot and a stub SBCL, so every gate, the lock, each verify failure, reuse,
# the read-only finish and rollback run in seconds and build nothing real.
#
# The stub SBCL answers the verify stage by replaying
# tests/build/fixtures/release-initialize.jsonl, an initialize and tools/list
# exchange recorded from a real release (provenance in
# release-initialize.txt), with one change to the recorded bytes: the commit
# in the first line's serverInfo.version becomes the commit of the release it
# was booted from. Stub mode stale-version replays the recording unchanged. Started with the worker entry, it prints
# tests/build/fixtures/worker-handshake.json, a handshake recorded from a real
# release worker core (provenance in worker-handshake.txt), and waits for
# SIGTERM. Its behaviour is set per case through the file $WORK/stub-mode,
# because the verify stages scrub the environment. A stub make, first on PATH
# for every deploy, stands in for the release's bus binary build: it writes two
# stub binaries into <release>/bin that answer --help.
#
# Every deploy and rollback runs with HOME at $WORK/fakehome, so the host
# defaults for BINDIR, SKILLDIR, AGENTDIR and SUBAGENTDIR name directories
# inside the temporary tree even when a case leaves them unset.
#
# The release build's ASDF check runs scripts/build-core.lisp with the real
# SBCL against a stub bundle whose asdf.lisp only sets the version string.
#
# Everything lives under one mktemp directory; TMPDIR points into it so the
# verify stage's scratch directories are removed with it.
#
# Usage: tests/build/deploy-test.sh

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FIXTURE="$REPO_ROOT/tests/build/fixtures/release-initialize.jsonl"
HANDSHAKE="$REPO_ROOT/tests/build/fixtures/worker-handshake.json"
DEPLOY="$REPO_ROOT/scripts/deploy.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/deploy-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

PASSED=0
FAILED=0
ok()   { printf '  ok    %s\n' "$1"; PASSED=$((PASSED + 1)); return 0; }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAILED=$((FAILED + 1)); return 0; }
note() { printf '\n%s\n' "$1"; }

# try <label> <detail shown on failure> <command...>
# if/else rather than `cond && ok || bad`, which would report one check as
# both passed and failed.
try() {
    local label=$1 detail=$2
    shift 2
    if "$@"; then ok "$label"; else bad "$label" "$detail"; fi
}

# has <text> <fixed string>: succeed when the text contains the string.
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# lacks <text> <fixed string>
lacks() { ! has "$1" "$2"; }

if [ ! -s "$FIXTURE" ]; then
    echo "deploy-test: missing recorded fixture $FIXTURE; record it with a scratch make deploy (see release-initialize.txt)" >&2
    exit 2
fi
if ! head -n 1 "$FIXTURE" | jq -e '.id == 1 and (.result.serverInfo.version | test("\\+[0-9a-f]{40}$"))' >/dev/null; then
    echo "deploy-test: the first line of $FIXTURE is not the id 1 reply with a 0.1.0+<commit> version; re-record it (see release-initialize.txt)" >&2
    exit 2
fi
if [ ! -s "$HANDSHAKE" ]; then
    echo "deploy-test: missing recorded fixture $HANDSHAKE; record it with a scratch make deploy (see worker-handshake.txt)" >&2
    exit 2
fi

# ---- stubs --------------------------------------------------------------

mkdir -p "$WORK/bin" "$WORK/guard" "$WORK/fakehome"
echo ok > "$WORK/stub-mode"

# Stub make: `make -C <release> ... bus-watch bus-host BUS_DEPS_SETUP=...`
# writes <release>/bin/dsmr-bus-watch and dsmr-bus-host. Each answers --help
# unless the stub mode is bus-help-fails, or prints nothing in mode
# bus-help-silent. The watcher stub prints its usage on stderr and the host
# stub on stdout, as the real binaries do.
cat > "$WORK/bin/make" <<STUB
#!/bin/sh
echo "\$*" >> "$WORK/make.log"
dir=.
while [ \$# -gt 0 ]; do
  case "\$1" in -C) dir=\$2; shift ;; esac
  shift
done
mkdir -p "\$dir/bin"
for name in dsmr-bus-watch dsmr-bus-host; do
  cat > "\$dir/bin/\$name" <<'BIN'
#!/bin/sh
case "\$(cat "$WORK/stub-mode")" in
  bus-help-fails) echo "stub: broken" >&2; exit 2 ;;
  bus-help-silent) exit 0 ;;
esac
case "\$0" in
  *dsmr-bus-watch) echo "usage: stub bus binary" >&2 ;;
  *) echo "usage: stub bus binary" ;;
esac
BIN
  chmod +x "\$dir/bin/\$name"
done
STUB

cat > "$WORK/bin/qlot" <<STUB
#!/bin/sh
echo "\$*" >> "$WORK/qlot.log"
case "\$1" in
  install) mkdir -p .qlot ;;
  bundle)  mkdir -p deps/local-projects/dir-git/.git deps/local-projects/file-git
           : > deps/setup.lisp
           : > deps/local-projects/dir-git/.git/HEAD
           : > deps/local-projects/dir-git/dir-git.asd
           echo "gitdir: /nowhere" > deps/local-projects/file-git/.git ;;
esac
STUB

cat > "$WORK/bin/sbcl" <<STUB
#!/bin/sh
echo "\$*" >> "$WORK/sbcl.log"
case "\$*" in
  --version) echo "SBCL 9.9.stub"; exit 0 ;;
  *verify-core-worker.lisp*)
      case "\$(cat "$WORK/stub-mode")" in
        worker-rejected) echo "[verify-core-worker] 0 passed, 1 FAILED - image rejected"; exit 1 ;;
      esac
      exit 0 ;;
  *dsmr-worker-entry*)
      case "\$(cat "$WORK/stub-mode")" in
        no-handshake) exit 0 ;;
      esac
      cat "$HANDSHAKE"
      trap 'exit 0' TERM
      while :; do sleep 0.1; done ;;
  *--core*)
      cat > /dev/null
      sha=\$(printf '%s\n' "\$*" | sed -n 's|.*releases/\([0-9a-f]\{40\}\)/core/.*|\1|p')
      # The single change to the recorded bytes: the commit in id 1's
      # serverInfo.version becomes the commit of the release booted.
      replay() {
        head -n 1 "$FIXTURE" | jq -c --arg sha "\$sha" '.result.serverInfo.version |= sub("[0-9a-f]{40}\$"; \$sha)'
        tail -n +2 "$FIXTURE"
      }
      case "\$(cat "$WORK/stub-mode")" in
        crash)         exit 3 ;;
        silent)        exit 0 ;;
        wrong-name)    replay | sed 's/"dsmr-mcp"/"other-server"/' ;;
        stale-version) cat "$FIXTURE" ;;
        *)             replay ;;
      esac
      exit 0 ;;
  *build-core.lisp*)
      echo stubcore > "\$DSMR_CORE_OUTPUT"
      printf 'sbcl-version 9.9.stub\nkind %s\n' "\$DSMR_CORE_KIND" > "\$DSMR_CORE_OUTPUT.manifest"
      exit 0 ;;
esac
exit 0
STUB

# Programs the rollback must not run; any call is recorded and fails.
for prog in make git qlot sbcl; do
    cat > "$WORK/guard/$prog" <<STUB
#!/bin/sh
echo "$prog \$*" >> "$WORK/guard.hit"
exit 99
STUB
done
chmod +x "$WORK/bin/"* "$WORK/guard/"*

# ---- origin and clone ---------------------------------------------------

ORIGIN="$WORK/origin.git"
REPO="$WORK/repo"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" checkout -q -b main 2>/dev/null || true
mkdir -p "$REPO/scripts"
cp "$REPO_ROOT/qlfile" "$REPO_ROOT/qlfile.lock" "$REPO/"
# Files the copies stage selects (5) and files it must leave out.
mkdir -p "$REPO/skills/alpha/scripts" "$REPO/skills/alpha/__pycache__" "$REPO/agents" \
         "$REPO/harness/mods/m"
echo "skills index" > "$REPO/skills/README.md"
printf '#!/bin/sh\necho run\n' > "$REPO/skills/alpha/scripts/run.sh"
chmod +x "$REPO/skills/alpha/scripts/run.sh"
echo "cache" > "$REPO/skills/alpha/__pycache__/x.pyc"
echo "agents index" > "$REPO/agents/README.md"
echo "helper agent" > "$REPO/agents/helper.md"
echo "status line" > "$REPO/harness/statusline.sh"
echo "hook" > "$REPO/harness/mods/m/hook.ts"
cp "$REPO_ROOT/scripts/release-launch.sh" "$REPO_ROOT/scripts/release-paths.sh" "$REPO/scripts/"
echo ';; placeholder' > "$REPO/scripts/build-core.lisp"

# commit_to <tag> <push|local>: add a commit; print its sha.
commit_to() {
    echo "$1" > "$REPO/marker"
    echo "skill $1" > "$REPO/skills/alpha/SKILL.md"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "$1"
    if [ "$2" = push ]; then git -C "$REPO" push -q origin main 2>/dev/null; fi
    git -C "$REPO" rev-parse HEAD
}

C1=$(commit_to one push)
C2=$(commit_to two push)
C3=$(commit_to three push)

# deploy <home> <ref> [VAR=value...]: run deploy.sh deploy; output in OUT, status in RC.
OUT=""; RC=0
deploy() {
    local home=$1 ref=$2
    shift 2
    OUT=$(env -u ALLOW_UNPUBLISHED -u BINDIR -u SKILLDIR -u AGENTDIR -u SUBAGENTDIR -u XDG_DATA_HOME \
              HOME="$WORK/fakehome" PATH="$WORK/bin:$PATH" HOST_LINKS=0 \
              REPO="$REPO" REF="$ref" DSMR_HOME="$home" \
              QLOT="$WORK/bin/qlot" SBCL="$WORK/bin/sbcl" DEPLOY_VERIFY_TIMEOUT=5 \
              "$@" bash "$DEPLOY" deploy 2>&1)
    RC=$?
}

link() { readlink "$1" 2>/dev/null || true; }
count_lines() { if [ -f "$1" ]; then wc -l < "$1"; else echo 0; fi; }

# ---- export and flip ----------------------------------------------------

note "export"
H="$WORK/home-flip"
echo untracked > "$REPO/untracked.txt"
deploy "$H" "$C1"
try "first deploy succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
try "untracked file is not exported" "found untracked.txt in release" test ! -e "$H/releases/$C1/untracked.txt"
try "release holds no .git" "found .git in release" test ! -e "$H/releases/$C1/.git"
try "tracked file is exported" "marker missing" test -f "$H/releases/$C1/marker"
vcs=$(find "$H/releases/$C1/deps" -name .git 2>/dev/null | head -3)
try "bundled dependencies hold no .git" "found: $vcs" test -z "$vcs"
try "bundled dependency sources are kept" "dir-git.asd missing" test -f "$H/releases/$C1/deps/local-projects/dir-git/dir-git.asd"
try "release holds a worker core" "no core/dsmr.core.worker" test -s "$H/releases/$C1/core/dsmr.core.worker"
try "worker core was built as a release-worker" "manifest: $(cat "$H/releases/$C1/core/dsmr.core.worker.manifest" 2>/dev/null)" grep -qx 'kind release-worker' "$H/releases/$C1/core/dsmr.core.worker.manifest"
try "release keeps the worker handshake" "verify-worker.json differs" cmp -s "$HANDSHAKE" "$H/releases/$C1/verify-worker.json"
for name in dsmr-bus-watch dsmr-bus-host; do
    try "release holds $name" "no executable bin/$name" test -x "$H/releases/$C1/bin/$name"
done
try "bus binaries are built against the release bundle" "$(tail -n 1 "$WORK/make.log" 2>/dev/null)" \
    grep -q "BUS_DEPS_SETUP=$H/releases/$C1/deps/setup.lisp" "$WORK/make.log"
try "deploy with HOST_LINKS=0 makes no link" "fakehome bin: $(ls "$WORK/fakehome/.local/bin" 2>&1)" \
    test ! -e "$WORK/fakehome/.local/bin"
try "deploy with HOST_LINKS=0 copies nothing" "fakehome .claude: $(ls -R "$WORK/fakehome/.claude" 2>&1)" \
    test ! -e "$WORK/fakehome/.claude"
rm -f "$REPO/untracked.txt"

note "flip"
deploy "$H" "$C2"
try "second deploy succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
try "current names the second commit" "current=$(link "$H/current")" test "$(link "$H/current")" = "releases/$C2"
try "previous names the first commit" "previous=$(link "$H/previous")" test "$(link "$H/previous")" = "releases/$C1"
case "$(link "$H/current")$(link "$H/previous")" in
  /*) bad "links are relative" "$(link "$H/current") $(link "$H/previous")" ;;
  *releases/*releases/*) ok "links are relative" ;;
  *) bad "links are relative" "$(link "$H/current") $(link "$H/previous")" ;;
esac

note "manifest"
M="$H/releases/$C2/MANIFEST"
want=$(grep -c '^("' "$REPO/qlfile.lock")
try "one dependency line per lock entry" "want $want, got $(grep -c '^dependency ' "$M")" test "$(grep -c '^dependency ' "$M")" -eq "$want"
try "manifest records the lock sha256" "no qlfile-lock-sha256" grep -q '^qlfile-lock-sha256 [0-9a-f]\{64\}$' "$M"
try "manifest records dirty false" "no dirty false" grep -q '^dirty false$' "$M"
try "manifest has no unpublished override" "override present" test "$(grep -c '^unpublished-ref-allowed' "$M")" -eq 0
try "dependency lines carry versions" "no github- version line" grep -q '^dependency slynk-client github-' "$M"

note "read-only"
leftover=$(find "$H/releases/$C2" ! -type l -perm -u+w 2>/dev/null | head -3)
try "a finished release has nothing writable" "writable: $leftover" test -z "$leftover"

# ---- gates --------------------------------------------------------------

note "dirty tree"
HD="$WORK/home-dirty-new"
echo edit >> "$REPO/marker"
deploy "$HD" "$C3"
try "tracked edit is refused" "rc=$RC" test "$RC" -eq 1
try "refusal names the remedy" "$OUT" has "$OUT" "commit or stash them, then re-run"
try "refusal creates no home" "home exists" test ! -e "$HD"
touch "$WORK/marker-time"; sleep 1
deploy "$H" "$C3"
try "refusal with an existing home" "rc=$RC" test "$RC" -eq 1
changed=$(find "$H" -newer "$WORK/marker-time" 2>/dev/null | head -3)
try "refusal changes nothing under home" "changed: $changed" test -z "$changed"
git -C "$REPO" checkout -q -- marker

note "unpublished ref"
C4=$(commit_to four local)
HU="$WORK/home-unpublished"
deploy "$HU" "$C4"
try "unpushed commit is refused" "rc=$RC" test "$RC" -eq 1
try "refusal names the push remedy" "$OUT" has "$OUT" "is on no origin branch; push it, then re-run"
try "refusal creates no home" "home exists" test ! -e "$HU"
deploy "$HU" "$C4" ALLOW_UNPUBLISHED=1
try "ALLOW_UNPUBLISHED=1 deploys it" "rc=$RC: $OUT" test "$RC" -eq 0
try "override is recorded in the manifest" "no override line" grep -q '^unpublished-ref-allowed yes$' "$HU/releases/$C4/MANIFEST"
git -C "$REPO" push -q origin main 2>/dev/null

note "home inside a work tree"
HW="$REPO/inside-home"
deploy "$HW" "$C3"
try "home inside a checkout is refused" "rc=$RC: $OUT" test "$RC" -eq 1
try "refusal names the work tree" "$OUT" has "$OUT" "inside a git work tree"
try "refusal creates no home" "home exists" test ! -e "$HW"

note "deploy home permissions"
HP="$WORK/home-perms"
saved_umask=$(umask)
umask 0002
deploy "$HP" "$C1"
umask "$saved_umask"
try "a deploy under umask 0002 succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
try "it creates the home as 0755" "mode $(stat -c %a "$HP" 2>/dev/null)" test "$(stat -c %a "$HP" 2>/dev/null)" = 755
try "it creates releases/ as 0755" "mode $(stat -c %a "$HP/releases" 2>/dev/null)" \
    test "$(stat -c %a "$HP/releases" 2>/dev/null)" = 755
HQ="$WORK/home-perms-open"
mkdir -p "$HQ"
chmod 0775 "$HQ"
deploy "$HQ" "$C1"
try "a group-writable home is refused" "rc=$RC: $OUT" test "$RC" -eq 1
try "refusal names the home and the remedy" "$OUT" has "$OUT" "deploy home $HQ is group or world writable; restore ownership and permissions of $HQ"
try "refusal creates nothing in it" "found: $(ls -A "$HQ")" test -z "$(ls -A "$HQ")"
chmod 0755 "$HQ"
mkdir -p "$HQ/releases"
chmod 0777 "$HQ/releases"
deploy "$HQ" "$C1"
try "a world-writable releases/ is refused" "rc=$RC: $OUT" test "$RC" -eq 1
try "refusal names releases/" "$OUT" has "$OUT" "$HQ/releases is group or world writable"
try "that refusal builds no release" "found: $(ls -A "$HQ/releases")" test -z "$(ls -A "$HQ/releases")"
chmod 0755 "$HQ/releases"

# ---- lock ---------------------------------------------------------------

note "lock"
HL="$WORK/home-lock"
mkdir -p "$HL"
echo "pid 4242 sha deadbeef started 2026-01-01T00:00:00Z" > "$HL/deploy.holder"
flock "$HL/deploy.lock" sleep 3 &
LOCKPID=$!
sleep 0.5
deploy "$HL" "$C1"
try "second deploy is refused" "rc=$RC" test "$RC" -eq 1
try "refusal names the holder" "$OUT" has "$OUT" "pid 4242 sha deadbeef"
try "refusal leaves the holder record" "holder record gone" test -s "$HL/deploy.holder"
try "refused deploy built no release" "releases dir exists" test ! -e "$HL/releases"
wait "$LOCKPID" 2>/dev/null
deploy "$HL" "$C1"
try "deploy runs once the lock is free" "rc=$RC: $OUT" test "$RC" -eq 0
try "holder record is removed on exit" "holder record remains" test ! -e "$HL/deploy.holder"

# ---- verify failures ----------------------------------------------------

note "verify failures"
HV="$WORK/home-verify"
deploy "$HV" "$C1"; deploy "$HV" "$C2"
cur0=$(link "$HV/current"); prev0=$(link "$HV/previous")
for case_ in wrong-name:verify-initialize crash:verify-initialize silent:verify-initialize \
             stale-version:verify-initialize no-handshake:verify-worker worker-rejected:verify-worker \
             bus-help-fails:verify-bus bus-help-silent:verify-bus; do
    mode=${case_%%:*} stage=${case_#*:}
    echo "$mode" > "$WORK/stub-mode"
    deploy "$HV" "$C3" DEPLOY_WORKER_TIMEOUT=3
    try "$mode: deploy fails" "rc=$RC" test "$RC" -eq 1
    try "$mode: failing stage is named" "$OUT" has "$OUT" "deploy: $stage failed:"
    try "$mode: current is reported unchanged" "$OUT" has "$OUT" "current is unchanged"
    try "$mode: current unchanged" "now $(link "$HV/current")" test "$(link "$HV/current")" = "$cur0"
    try "$mode: previous unchanged" "now $(link "$HV/previous")" test "$(link "$HV/previous")" = "$prev0"
    try "$mode: release has no MANIFEST" "MANIFEST present" test ! -e "$HV/releases/$C3/MANIFEST"
    if [ "$mode" = stale-version ]; then
        try "stale-version: the reason names the commit" "$OUT" has "$OUT" "does not carry $C3"
    fi
done
echo ok > "$WORK/stub-mode"

# ---- reuse --------------------------------------------------------------

note "reuse"
HR="$WORK/home-reuse"
# Neither current nor previous names the first release after the third deploy.
deploy "$HR" "$C1"; deploy "$HR" "$C2"; deploy "$HR" "$C3"
q0=$(count_lines "$WORK/qlot.log")
b0=$(grep -c 'build-core.lisp' "$WORK/sbcl.log")
v0=$(grep -c -e '--core' "$WORK/sbcl.log")
deploy "$HR" "$C1"
try "redeploy of a complete release succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
try "redeploy runs no qlot" "qlot lines $q0 -> $(count_lines "$WORK/qlot.log")" test "$(count_lines "$WORK/qlot.log")" -eq "$q0"
try "redeploy runs no build" "builds $b0 -> $(grep -c 'build-core.lisp' "$WORK/sbcl.log")" test "$(grep -c 'build-core.lisp' "$WORK/sbcl.log")" -eq "$b0"
try "redeploy verifies again" "boots $v0 -> $(grep -c -e '--core' "$WORK/sbcl.log")" test "$(grep -c -e '--core' "$WORK/sbcl.log")" -gt "$v0"
chmod -R u+w "$HR/releases/$C2"
rm -f "$HR/releases/$C2/MANIFEST"
deploy "$HR" "$C2"
try "release without a MANIFEST is rebuilt" "rc=$RC: $OUT" test "$RC" -eq 0
try "rebuild ran qlot again" "qlot lines stayed $q0" test "$(count_lines "$WORK/qlot.log")" -gt "$q0"
try "rebuild wrote a MANIFEST" "no MANIFEST" test -f "$HR/releases/$C2/MANIFEST"

# ---- rollback -----------------------------------------------------------

note "rollback"
HB="$WORK/home-rollback"
deploy "$HB" "$C1"; deploy "$HB" "$C2"
rm -f "$WORK/guard.hit"
rollback() {
    local home=$1
    shift
    OUT=$(env -u BINDIR -u SKILLDIR -u AGENTDIR -u SUBAGENTDIR -u XDG_DATA_HOME \
              HOME="$WORK/fakehome" PATH="$WORK/guard:$PATH" HOST_LINKS=0 DSMR_HOME="$home" \
              "$@" bash "$DEPLOY" rollback 2>&1)
    RC=$?
}
rollback "$HB"
try "rollback succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
try "current is the first commit" "current=$(link "$HB/current")" test "$(link "$HB/current")" = "releases/$C1"
try "previous is the second commit" "previous=$(link "$HB/previous")" test "$(link "$HB/previous")" = "releases/$C2"
try "rollback prints the commit now current" "$OUT" has "$OUT" "current -> releases/$C1 (commit $C1)"
try "rollback ran no make, git, qlot or sbcl" "$(cat "$WORK/guard.hit" 2>/dev/null)" test ! -e "$WORK/guard.hit"
rollback "$HB"
try "second rollback swaps back" "current=$(link "$HB/current")" test "$(link "$HB/current")" = "releases/$C2"
HN="$WORK/home-noprev"
deploy "$HN" "$C1"
rollback "$HN"
try "rollback with no previous is refused" "rc=$RC: $OUT" test "$RC" -eq 1
try "refusal says there is nothing to roll back to" "$OUT" has "$OUT" "no previous release at"
try "refused rollback leaves current" "current=$(link "$HN/current")" test "$(link "$HN/current")" = "releases/$C1"

# ---- redeploy the current release ---------------------------------------

note "redeploy the current release"
HX="$WORK/home-live"
deploy "$HX" "$C1"; deploy "$HX" "$C2"
echo crash > "$WORK/stub-mode"
v0=$(grep -c -e '--core' "$WORK/sbcl.log")
q0=$(count_lines "$WORK/qlot.log")
deploy "$HX" "$C2"
try "redeploying current succeeds while a boot would crash" "rc=$RC: $OUT" test "$RC" -eq 0
try "it boots nothing" "boots $v0 -> $(grep -c -e '--core' "$WORK/sbcl.log")" \
    test "$(grep -c -e '--core' "$WORK/sbcl.log")" -eq "$v0"
try "the current release keeps its MANIFEST" "MANIFEST gone" test -f "$HX/releases/$C2/MANIFEST"
try "current still names it" "current=$(link "$HX/current")" test "$(link "$HX/current")" = "releases/$C2"
try "previous is unchanged" "previous=$(link "$HX/previous")" test "$(link "$HX/previous")" = "releases/$C1"
try "it says only the host steps run" "$OUT" has "$OUT" "export: $HX/releases/$C2 is current; only the host steps run"
deploy "$HX" "$C2"
try "a second redeploy of current succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
try "it removes nothing" "$OUT" lacks "$OUT" "removing incomplete earlier attempt"
try "it rebuilds nothing" "qlot lines $q0 -> $(count_lines "$WORK/qlot.log")" test "$(count_lines "$WORK/qlot.log")" -eq "$q0"
try "the current release is still read-only" "writable: $(find "$HX/releases/$C2" ! -type l -perm -u+w | head -3)" \
    test -z "$(find "$HX/releases/$C2" ! -type l -perm -u+w | head -3)"

deploy "$HX" "$C1"
try "a failed verify of the previous release fails the deploy" "rc=$RC: $OUT" test "$RC" -eq 1
try "the failure says the previous release was left as it is" "$OUT" \
    has "$OUT" "$HX/releases/$C1 is the release previous names, so it was left as it is"
try "the previous release keeps its MANIFEST" "MANIFEST gone" test -f "$HX/releases/$C1/MANIFEST"
try "current is unchanged by it" "current=$(link "$HX/current")" test "$(link "$HX/current")" = "releases/$C2"
try "previous is unchanged by it" "previous=$(link "$HX/previous")" test "$(link "$HX/previous")" = "releases/$C1"

HY="$WORK/home-live-broken"
echo ok > "$WORK/stub-mode"
deploy "$HY" "$C1"
chmod -R u+w "$HY/releases/$C1"
rm -f "$HY/releases/$C1/MANIFEST"
deploy "$HY" "$C1"
try "current without a MANIFEST is refused" "rc=$RC: $OUT" test "$RC" -eq 1
try "the refusal names current" "$OUT" has "$OUT" "$HY/releases/$C1 is the release current names but has no MANIFEST"
try "the directory current names is kept" "marker gone" test -f "$HY/releases/$C1/marker"

note "follow the remedy a failed host step prints"
HZ="$WORK/home-remedy"
D="$WORK/dest-remedy"
DESTS=(HOST_LINKS= BINDIR="$D/bin" SKILLDIR="$D/claude/skills" AGENTDIR="$D/claude" SUBAGENTDIR="$D/claude/agents")
deploy "$HZ" "$C1" "${DESTS[@]}"
# A regular file where BINDIR should be stops the links stage after the flip.
rm -rf "${D:?}/bin"
: > "$D/bin"
deploy "$HZ" "$C2" "${DESTS[@]}"
try "a links failure after the flip fails the deploy" "rc=$RC: $OUT" test "$RC" -eq 1
try "it names the redeploy that finishes the host steps" "$OUT" has "$OUT" "run make deploy REF=$C2 again"
rm -f "$D/bin"
echo crash > "$WORK/stub-mode"
deploy "$HZ" "$C2" "${DESTS[@]}"
try "the named redeploy succeeds while a boot would crash" "rc=$RC: $OUT" test "$RC" -eq 0
try "it links the bus binaries" "link=$(link "$D/bin/dsmr-bus-watch")" \
    test "$(link "$D/bin/dsmr-bus-watch")" = "$HZ/current/bin/dsmr-bus-watch"
try "the current release keeps its MANIFEST" "MANIFEST gone" test -f "$HZ/releases/$C2/MANIFEST"
rm -f "$D/bin/dsmr-bus-watch" "$D/bin/dsmr-bus-host"
rmdir "$D/bin"
: > "$D/bin"
rollback "$HZ" "${DESTS[@]}"
try "a links failure after a rollback stops it" "rc=$RC: $OUT" test "$RC" -eq 1
try "it names the redeploy of the restored commit" "$OUT" has "$OUT" "run make deploy REF=$C1 to finish the host steps"
rm -f "$D/bin"
deploy "$HZ" "$C1" "${DESTS[@]}"
try "that redeploy succeeds while a boot would crash" "rc=$RC: $OUT" test "$RC" -eq 0
try "it links the bus binaries to the restored release" "resolves to $(readlink -f "$D/bin/dsmr-bus-watch")" \
    test "$(readlink -f "$D/bin/dsmr-bus-watch")" = "$HZ/releases/$C1/bin/dsmr-bus-watch"
try "the restored release keeps its MANIFEST" "MANIFEST gone" test -f "$HZ/releases/$C1/MANIFEST"
try "the release left keeps its MANIFEST" "MANIFEST gone" test -f "$HZ/releases/$C2/MANIFEST"
echo ok > "$WORK/stub-mode"

# ---- host destinations -------------------------------------------------

note "host-destination guard"
HG="$WORK/home-guard"
touch "$WORK/marker-guard"; sleep 1
deploy "$HG" "$C1" HOST_LINKS=
try "scratch home with host destinations is refused" "rc=$RC: $OUT" test "$RC" -eq 1
try "refusal names the scratch home and the variable" "$OUT" has "$OUT" "deploy home $HG is a scratch home but BINDIR is the host's"
try "refusal names the remedy" "$OUT" has "$OUT" "set HOST_LINKS=0 or point BINDIR, SKILLDIR, AGENTDIR and SUBAGENTDIR at scratch directories"
try "refusal creates no home" "home exists" test ! -e "$HG"
written=$(find "$WORK/fakehome" -newer "$WORK/marker-guard" 2>/dev/null | head -3)
try "refusal writes nothing under the host directories" "written: $written" test -z "$written"
D="$WORK/dest-guard"
deploy "$HG" "$C1" HOST_LINKS= BINDIR="$D/bin" SKILLDIR="$D/claude/skills" AGENTDIR="$D/claude" \
    SUBAGENTDIR="$WORK/fakehome/.claude/agents"
try "one host directory left is still refused" "rc=$RC: $OUT" test "$RC" -eq 1
try "refusal names SUBAGENTDIR" "$OUT" has "$OUT" "but SUBAGENTDIR is the host's"
rollback "$HG" HOST_LINKS=
try "rollback with a scratch home and host destinations is refused" "rc=$RC: $OUT" test "$RC" -eq 1
try "rollback refusal names the scratch home" "$OUT" has "$OUT" "is a scratch home but BINDIR is the host's"

note "host-destination guard, deploy home named by XDG_DATA_HOME"
# DSMR_HOME is empty, so the deploy home is $XDG_DATA_HOME/dsmr-mcp. Only a
# home under HOME is the host's own; any other one is a scratch home.
HXD="$WORK/xdg-scratch"
touch "$WORK/marker-xdg"; sleep 1
deploy "" "$C1" HOST_LINKS= XDG_DATA_HOME="$HXD"
try "a scratch XDG_DATA_HOME with host destinations is refused" "rc=$RC: $OUT" test "$RC" -eq 1
try "refusal names the deploy home and the variable" "$OUT" has "$OUT" "deploy home $HXD/dsmr-mcp is a scratch home but BINDIR is the host's"
try "refusal creates no home under XDG_DATA_HOME" "home exists" test ! -e "$HXD/dsmr-mcp"
written=$(find "$WORK/fakehome" -newer "$WORK/marker-xdg" 2>/dev/null | head -3)
try "refusal writes nothing under the host directories" "written: $written" test -z "$written"
deploy "$HXD/dsmr-mcp" "$C1"; deploy "$HXD/dsmr-mcp" "$C2"
touch "$WORK/marker-xdg"; sleep 1
rollback "" HOST_LINKS= XDG_DATA_HOME="$HXD"
try "rollback in a scratch XDG_DATA_HOME with host destinations is refused" "rc=$RC: $OUT" test "$RC" -eq 1
try "rollback refusal names the deploy home" "$OUT" has "$OUT" "deploy home $HXD/dsmr-mcp is a scratch home but BINDIR is the host's"
try "refused rollback leaves current" "current=$(link "$HXD/dsmr-mcp/current")" \
    test "$(link "$HXD/dsmr-mcp/current")" = "releases/$C2"
written=$(find "$WORK/fakehome" -newer "$WORK/marker-xdg" 2>/dev/null | head -3)
try "refused rollback writes nothing under the host directories" "written: $written" test -z "$written"
ln -s "$HXD" "$WORK/fakehome/xdg-link"
deploy "" "$C1" HOST_LINKS= XDG_DATA_HOME="$WORK/fakehome/xdg-link"
try "an XDG_DATA_HOME under HOME that resolves outside it is refused" "rc=$RC: $OUT" test "$RC" -eq 1
rm -f "$WORK/fakehome/xdg-link"
deploy "" "$C1" HOST_LINKS= XDG_DATA_HOME="$WORK/fakehome/.xdg-data"
try "an XDG_DATA_HOME under HOME is the host's own home" "rc=$RC: $OUT" test "$RC" -eq 0
try "that deploy links the host's bus binaries" "link=$(link "$WORK/fakehome/.local/bin/dsmr-bus-watch")" \
    test "$(link "$WORK/fakehome/.local/bin/dsmr-bus-watch")" = "$WORK/fakehome/.xdg-data/dsmr-mcp/current/bin/dsmr-bus-watch"
rm -rf "${WORK:?}/fakehome/.local/bin" "${WORK:?}/fakehome/.claude"

note "bus binary links"
HK="$WORK/home-links"
D="$WORK/dest-links"
DESTS=(HOST_LINKS= BINDIR="$D/bin" SKILLDIR="$D/claude/skills" AGENTDIR="$D/claude" SUBAGENTDIR="$D/claude/agents")
mkdir -p "$D/bin"
echo "old watcher" > "$D/bin/dsmr-bus-watch"
chmod +x "$D/bin/dsmr-bus-watch"
deploy "$HK" "$C1" "${DESTS[@]}"
try "deploy with scratch destinations succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
for name in dsmr-bus-watch dsmr-bus-host; do
    try "$name link names current" "link=$(link "$D/bin/$name")" test "$(link "$D/bin/$name")" = "$HK/current/bin/$name"
    try "$name resolves to the first release" "resolves to $(readlink -f "$D/bin/$name")" \
        test "$(readlink -f "$D/bin/$name")" = "$HK/releases/$C1/bin/$name"
done
backup=$(find "$D/bin" -name 'dsmr-bus-watch.pre-release-*' | head -1)
try "a regular file is kept as a dated backup" "backups: $(ls "$D/bin")" \
    test -n "$backup"
case "$backup" in
  *.pre-release-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ok "backup name carries a UTC stamp" ;;
  *) bad "backup name carries a UTC stamp" "$backup" ;;
esac
try "the backup keeps the old content" "content: $(cat "$backup" 2>/dev/null)" grep -qx 'old watcher' "$backup"
try "deploy names the service restart" "$OUT" has "$OUT" "systemctl --user restart dsmr-bus-host"
"$D/bin/dsmr-bus-watch" --help > "$WORK/help.out" 2>&1
try "the linked watcher answers --help" "$(cat "$WORK/help.out")" grep -q usage "$WORK/help.out"
deploy "$HK" "$C2" "${DESTS[@]}"
try "second deploy succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
try "second deploy keeps the link through current" "link=$(link "$D/bin/dsmr-bus-watch")" \
    test "$(link "$D/bin/dsmr-bus-watch")" = "$HK/current/bin/dsmr-bus-watch"
try "the link resolves to the second release" "resolves to $(readlink -f "$D/bin/dsmr-bus-watch")" \
    test "$(readlink -f "$D/bin/dsmr-bus-watch")" = "$HK/releases/$C2/bin/dsmr-bus-watch"
try "second deploy makes no second backup" "backups: $(ls "$D/bin")" \
    test "$(find "$D/bin" -name '*.pre-release-*' | wc -l)" -eq 1
rm -f "$WORK/guard.hit"
rm -f "$D/bin/dsmr-bus-host"
rollback "$HK" "${DESTS[@]}"
try "rollback with scratch destinations succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
try "after rollback the watcher resolves to the first release" "resolves to $(readlink -f "$D/bin/dsmr-bus-watch")" \
    test "$(readlink -f "$D/bin/dsmr-bus-watch")" = "$HK/releases/$C1/bin/dsmr-bus-watch"
try "rollback repairs a missing link" "link=$(link "$D/bin/dsmr-bus-host")" \
    test "$(link "$D/bin/dsmr-bus-host")" = "$HK/current/bin/dsmr-bus-host"
try "rollback ran no make, git, qlot or sbcl" "$(cat "$WORK/guard.hit" 2>/dev/null)" test ! -e "$WORK/guard.hit"

# ---- copies --------------------------------------------------------------

note "copies"
HC="$WORK/home-copies"
D="$WORK/dest-copies"
DESTS=(HOST_LINKS= BINDIR="$D/bin" SKILLDIR="$D/claude/skills" AGENTDIR="$D/claude" SUBAGENTDIR="$D/claude/agents")
SKILL="$D/claude/skills/alpha/SKILL.md"
deploy "$HC" "$C1" "${DESTS[@]}"
try "deploy with scratch copy destinations succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
R1="$HC/releases/$C1"
for pair in "skills/alpha/SKILL.md:$D/claude/skills/alpha/SKILL.md" \
            "skills/alpha/scripts/run.sh:$D/claude/skills/alpha/scripts/run.sh" \
            "agents/helper.md:$D/claude/agents/helper.md" \
            "harness/statusline.sh:$D/claude/statusline.sh" \
            "harness/mods/m/hook.ts:$D/claude/mods/m/hook.ts"; do
    src=${pair%%:*} dst=${pair#*:}
    try "$src is copied" "missing or different: $dst" cmp -s "$R1/$src" "$dst"
    try "$src is a regular file, not a link" "$(ls -l "$dst" 2>&1)" test ! -L "$dst"
    try "$src copy is writable" "$(ls -l "$dst" 2>&1)" test -w "$dst"
done
copied=$(find "$D/claude" -type f | wc -l)
try "exactly the five selected files are copied" "found $copied: $(find "$D/claude" -type f)" test "$copied" -eq 5
try "skills/README.md is not copied" "found" test ! -e "$D/claude/skills/README.md"
try "agents/README.md is not copied" "found" test ! -e "$D/claude/agents/README.md"
try "__pycache__ is not copied" "found" test ! -e "$D/claude/skills/alpha/__pycache__"
try "harness files are executable" "$(ls -l "$D/claude/mods/m/hook.ts")" test -x "$D/claude/mods/m/hook.ts"
try "an executable skill file stays executable" "$(ls -l "$D/claude/skills/alpha/scripts/run.sh")" \
    test -x "$D/claude/skills/alpha/scripts/run.sh"
try "a skill document is not executable" "$(ls -l "$SKILL")" test ! -x "$SKILL"

deploy "$HC" "$C2" "${DESTS[@]}"
try "a destination equal to the base copy is replaced" "rc=$RC: $(cat "$SKILL")" grep -qx 'skill two' "$SKILL"

echo "local fix" >> "$SKILL"
cur0=$(link "$HC/current")
deploy "$HC" "$C3" "${DESTS[@]}"
try "an in-place edit stops the deploy" "rc=$RC" test "$RC" -eq 1
try "the stop names check-copies" "$OUT" has "$OUT" "deploy: check-copies failed:"
try "the edited file is listed" "$OUT" has "$OUT" "copies: $SKILL was edited in place since the last deploy; port the edit into the tree, or pass FORCE=1 to replace it"
try "current is unchanged by the stop" "current=$(link "$HC/current")" test "$(link "$HC/current")" = "$cur0"
try "the edit survives the stop" "$(cat "$SKILL")" grep -qx 'local fix' "$SKILL"
deploy "$HC" "$C3" "${DESTS[@]}" FORCE=1
try "FORCE=1 deploys over the edit" "rc=$RC: $OUT" test "$RC" -eq 0
try "FORCE=1 says it replaced the edit" "$OUT" has "$OUT" "FORCE=1: replacing 1 file(s) edited in place"
try "FORCE=1 replaced the edited file" "$(cat "$SKILL")" grep -qx 'skill three' "$SKILL"

rm -f "$WORK/guard.hit"
rollback "$HC" "${DESTS[@]}"
try "rollback with copies succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
try "rollback restores the previous release's copy" "$(cat "$SKILL")" grep -qx 'skill two' "$SKILL"
try "rollback ran no make, git, qlot or sbcl" "$(cat "$WORK/guard.hit" 2>/dev/null)" test ! -e "$WORK/guard.hit"
echo "fix after rollback" >> "$SKILL"
cur0=$(link "$HC/current")
rollback "$HC" "${DESTS[@]}"
try "rollback stops on an in-place edit" "rc=$RC: $OUT" test "$RC" -eq 1
try "rollback lists the edited file" "$OUT" has "$OUT" "rollback: copies: $SKILL was edited in place"
try "rollback stop leaves current" "current=$(link "$HC/current")" test "$(link "$HC/current")" = "$cur0"
try "rollback stop keeps the edit" "$(cat "$SKILL")" grep -qx 'fix after rollback' "$SKILL"

HF="$WORK/home-copies-first"
D="$WORK/dest-first"
mkdir -p "$D/claude/agents"
echo "someone else's helper" > "$D/claude/agents/helper.md"
deploy "$HF" "$C1" HOST_LINKS= BINDIR="$D/bin" SKILLDIR="$D/claude/skills" AGENTDIR="$D/claude" SUBAGENTDIR="$D/claude/agents"
try "with no base release, a differing destination stops the deploy" "rc=$RC: $OUT" test "$RC" -eq 1
try "the first deploy lists it" "$OUT" has "$OUT" "copies: $D/claude/agents/helper.md was edited in place"
try "the first deploy flips nothing" "current=$(link "$HF/current")" test ! -e "$HF/current"

# ---- release build ASDF ------------------------------------------------

# scripts/build-core.lisp, release-server kind, run by the real SBCL against a
# stub release whose bundled build/asdf.lisp only sets ASDF's version string.
# A version other than 3.3.7.4 must stop the build before anything loads; the
# same stub at 3.3.7.4 must pass that check, so the refusal is the version's.
build_core_with_asdf() {
    local version=$1 rel="$WORK/asdf-stub-$1"
    mkdir -p "$rel/deps/local-projects/asdf/build"
    printf '(setf (symbol-value (find-symbol "*ASDF-VERSION*" "ASDF")) "%s")\n' "$version" \
        > "$rel/deps/local-projects/asdf/build/asdf.lisp"
    OUT=$(env -u CL_SOURCE_REGISTRY -u ASDF_OUTPUT_TRANSLATIONS \
              XDG_CACHE_HOME="$WORK/cache" \
              DSMR_CORE_KIND=release-server \
              DSMR_CORE_OUTPUT="$rel/dsmr.core" \
              DSMR_RELEASE_ROOT="$rel/" \
              DSMR_RELEASE_COMMIT=0000000000000000000000000000000000000000 \
              timeout 120 "$REAL_SBCL" --noinform --no-sysinit --no-userinit \
              --disable-debugger --non-interactive \
              --load "$REPO_ROOT/scripts/build-core.lisp" 2>&1)
    RC=$?
}

note "release build ASDF"
REAL_SBCL=$(command -v sbcl || true)
if [ -z "$REAL_SBCL" ]; then
    bad "a release build refuses another ASDF" "no sbcl on PATH"
else
    build_core_with_asdf 3.3.6
    try "a release build with ASDF 3.3.6 exits 1" "rc=$RC: $OUT" test "$RC" -eq 1
    try "it names the version it needs" "$OUT" \
        has "$OUT" "[build-core] ASDF 3.3.6 is loaded; a release build needs 3.3.7.4 from $WORK/asdf-stub-3.3.6/deps/"
    try "it writes no core" "$(ls "$WORK/asdf-stub-3.3.6")" test ! -e "$WORK/asdf-stub-3.3.6/dsmr.core"
    build_core_with_asdf 3.3.7.4
    try "the same stub at 3.3.7.4 passes the version check" "$OUT" \
        has "$OUT" "[build-core] release root: $WORK/asdf-stub-3.3.7.4/ (ASDF 3.3.7.4)"
    try "and is not refused for its ASDF" "$OUT" lacks "$OUT" "a release build needs"
fi

printf '\ndeploy-test: %s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
