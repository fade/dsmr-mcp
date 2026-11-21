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
# release-initialize.txt). Its behaviour is set per case through the file
# $WORK/stub-mode, because the verify stage scrubs the environment.
#
# Everything lives under one mktemp directory; TMPDIR points into it so the
# verify stage's scratch directories are removed with it.
#
# Usage: tests/build/deploy-test.sh

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FIXTURE="$REPO_ROOT/tests/build/fixtures/release-initialize.jsonl"
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

# ---- stubs --------------------------------------------------------------

mkdir -p "$WORK/bin" "$WORK/guard"
echo ok > "$WORK/stub-mode"

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
  *--core*)
      cat > /dev/null
      case "\$(cat "$WORK/stub-mode")" in
        crash)      exit 3 ;;
        silent)     exit 0 ;;
        wrong-name) sed 's/"dsmr-mcp"/"other-server"/' "$FIXTURE" ;;
        *)          cat "$FIXTURE" ;;
      esac
      exit 0 ;;
  *build-core.lisp*)
      echo stubcore > "\$DSMR_CORE_OUTPUT"
      echo "sbcl-version 9.9.stub" > "\$DSMR_CORE_OUTPUT.manifest"
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
cp "$REPO_ROOT/scripts/release-launch.sh" "$REPO_ROOT/scripts/release-paths.sh" "$REPO/scripts/"
echo ';; placeholder' > "$REPO/scripts/build-core.lisp"

# commit_to <tag> <push|local>: add a commit; print its sha.
commit_to() {
    echo "$1" > "$REPO/marker"
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
    OUT=$(env -u ALLOW_UNPUBLISHED REPO="$REPO" REF="$ref" DSMR_HOME="$home" \
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
for mode in wrong-name crash silent; do
    echo "$mode" > "$WORK/stub-mode"
    deploy "$HV" "$C3"
    try "$mode: deploy fails" "rc=$RC" test "$RC" -eq 1
    try "$mode: failing stage is named" "$OUT" has "$OUT" "deploy: verify-initialize failed:"
    try "$mode: current is reported unchanged" "$OUT" has "$OUT" "current is unchanged"
    try "$mode: current unchanged" "now $(link "$HV/current")" test "$(link "$HV/current")" = "$cur0"
    try "$mode: previous unchanged" "now $(link "$HV/previous")" test "$(link "$HV/previous")" = "$prev0"
    try "$mode: release has no MANIFEST" "MANIFEST present" test ! -e "$HV/releases/$C3/MANIFEST"
done
echo ok > "$WORK/stub-mode"

# ---- reuse --------------------------------------------------------------

note "reuse"
HR="$WORK/home-reuse"
deploy "$HR" "$C1"
q0=$(count_lines "$WORK/qlot.log")
b0=$(grep -c 'build-core.lisp' "$WORK/sbcl.log")
v0=$(grep -c -e '--core' "$WORK/sbcl.log")
deploy "$HR" "$C1"
try "redeploy of a complete release succeeds" "rc=$RC: $OUT" test "$RC" -eq 0
try "redeploy runs no qlot" "qlot lines $q0 -> $(count_lines "$WORK/qlot.log")" test "$(count_lines "$WORK/qlot.log")" -eq "$q0"
try "redeploy runs no build" "builds $b0 -> $(grep -c 'build-core.lisp' "$WORK/sbcl.log")" test "$(grep -c 'build-core.lisp' "$WORK/sbcl.log")" -eq "$b0"
try "redeploy verifies again" "boots $v0 -> $(grep -c -e '--core' "$WORK/sbcl.log")" test "$(grep -c -e '--core' "$WORK/sbcl.log")" -gt "$v0"
chmod -R u+w "$HR/releases/$C1"
rm -f "$HR/releases/$C1/MANIFEST"
deploy "$HR" "$C1"
try "release without a MANIFEST is rebuilt" "rc=$RC: $OUT" test "$RC" -eq 0
try "rebuild ran qlot again" "qlot lines stayed $q0" test "$(count_lines "$WORK/qlot.log")" -gt "$q0"
try "rebuild wrote a MANIFEST" "no MANIFEST" test -f "$HR/releases/$C1/MANIFEST"

# ---- rollback -----------------------------------------------------------

note "rollback"
HB="$WORK/home-rollback"
deploy "$HB" "$C1"; deploy "$HB" "$C2"
rm -f "$WORK/guard.hit"
rollback() {
    OUT=$(env PATH="$WORK/guard:$PATH" DSMR_HOME="$1" bash "$DEPLOY" rollback 2>&1)
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

printf '\ndeploy-test: %s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
