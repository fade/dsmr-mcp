#!/usr/bin/env bash
#
# Exercises the install sequence in `make core` against a scratch image path.
#
# The sequence replaces the image every running server has mapped, so its
# failure behaviour matters more than its success behaviour: a build that goes
# wrong must leave the working core in place rather than half-replacing it.
# That is the property this checks.
#
# A real core is ~200 MB and takes minutes to build, which is too slow to test
# every failure mode against and needs a machine nobody is depending on. The
# build and the image check are stubbed instead, so the shell logic that does
# the installing is what actually runs here. CORE points at a scratch path
# throughout, so the installed image is never touched.
#
# Usage: tests/build/core-install-test.sh

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-install-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
ok()   { printf '  ok    %s\n' "$1"; PASSED=$((PASSED + 1)); return 0; }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAILED=$((FAILED + 1)); return 0; }
note() { printf '\n%s\n' "$1"; }

# Report one check, given its label, the detail to show if it fails, and the
# command that decides it. Written as if/else rather than `cond && ok || bad`,
# because that form also runs the failure branch whenever the success branch
# returns non-zero, which would report a single check as both passed and
# failed. A suite whose only value is being believed cannot afford that.
try() {
    local label=$1 detail=$2
    shift 2
    if "$@"; then ok "$label"; else bad "$label" "$detail"; fi
}

# A stand-in for SBCL covering both invocations the core target makes: the
# build, which writes the staged image, and core-verify, which boots it. Its
# behaviour is set per case through the environment so each failure mode can be
# reached without a real build.
cat > "$WORK/stub-sbcl" <<'STUB'
#!/bin/sh
case "$*" in
  *build-core.lisp*)
      case "${STUB_BUILD:-ok}" in
        none)       exit 0 ;;                       # build produces nothing
        empty)      : > "$DSMR_CORE_OUTPUT" ;;      # zero-byte image
        nomanifest) echo "${STUB_TAG:-new}" > "$DSMR_CORE_OUTPUT" ;;
        *)          echo "${STUB_TAG:-new}" > "$DSMR_CORE_OUTPUT"
                    echo "manifest ${STUB_TAG:-new}" > "$DSMR_CORE_OUTPUT.manifest" ;;
      esac
      exit 0 ;;
  *verify-core.lisp*)
      exit "${STUB_VERIFY_EXIT:-0}" ;;
esac
exit 0
STUB
chmod +x "$WORK/stub-sbcl"

# Run the real core target with the stub standing in for SBCL and CORE pointed
# at a scratch path. Echoes make's exit status.
run_core() {
    local core_path=$1; shift
    ( cd "$REPO_ROOT" && env "$@" make --no-print-directory core \
        SBCL="$WORK/stub-sbcl" CORE="$core_path" >"$WORK/out" 2>&1 )
    echo $?
}

seed_existing_core() {
    echo "old" > "$1"
    echo "manifest old" > "$1.manifest"
}

note "install sequence, through the real core target"

# 1. Nothing installed yet.
CORE1="$WORK/fresh.core"
rc=$(run_core "$CORE1" STUB_TAG=first)
try "first build succeeds" "exit=$rc" test "$rc" = 0
try "first build installs the image" "got $(cat "$CORE1" 2>/dev/null)" \
    test "$(cat "$CORE1" 2>/dev/null)" = "first"
try "first build installs the manifest" "got $(cat "$CORE1.manifest" 2>/dev/null)" \
    test "$(cat "$CORE1.manifest" 2>/dev/null)" = "manifest first"

# 2. Replacing an installed image. The outgoing image must survive as .prev,
#    and it must be the SAME inode, which is what proves it was linked aside
#    rather than moved: a move leaves the path empty until the new one lands.
CORE2="$WORK/replace.core"
seed_existing_core "$CORE2"
old_inode=$(stat -c %i "$CORE2")
rc=$(run_core "$CORE2" STUB_TAG=second)
try "rebuild succeeds" "exit=$rc" test "$rc" = 0
try "rebuild installs the new image" "got $(cat "$CORE2" 2>/dev/null)" \
    test "$(cat "$CORE2" 2>/dev/null)" = "second"
try "outgoing image is kept as .prev" "got $(cat "$CORE2.prev" 2>/dev/null)" \
    test "$(cat "$CORE2.prev" 2>/dev/null)" = "old"
try ".prev is the outgoing inode, so the path was never emptied" \
    "prev=$(stat -c %i "$CORE2.prev" 2>/dev/null) old=$old_inode" \
    test "$(stat -c %i "$CORE2.prev" 2>/dev/null)" = "$old_inode"
try "installed path now names a different inode" "still $old_inode" \
    test "$(stat -c %i "$CORE2")" != "$old_inode"

note "a build that goes wrong leaves the working core alone"

for case_name in none empty nomanifest verifyfail; do
    CORE3="$WORK/guard-$case_name.core"
    seed_existing_core "$CORE3"
    echo "older" > "$CORE3.prev"
    if [ "$case_name" = verifyfail ]; then
        rc=$(run_core "$CORE3" STUB_TAG=bad STUB_VERIFY_EXIT=1)
        label="a staged image that fails verification"
    else
        rc=$(run_core "$CORE3" STUB_TAG=bad STUB_BUILD="$case_name")
        case $case_name in
            none)       label="a build that produces no image" ;;
            empty)      label="a build that produces an empty image" ;;
            nomanifest) label="a build that produces no manifest" ;;
        esac
    fi
    try "$label fails the build" "exit was $rc" test "$rc" != 0
    try "$label leaves the installed image untouched" "got $(cat "$CORE3" 2>/dev/null)" \
        test "$(cat "$CORE3" 2>/dev/null)" = "old"
    try "$label leaves the installed manifest untouched" "got $(cat "$CORE3.manifest" 2>/dev/null)" \
        test "$(cat "$CORE3.manifest" 2>/dev/null)" = "manifest old"
    try "$label leaves the existing rollback intact" "got $(cat "$CORE3.prev" 2>/dev/null)" \
        test "$(cat "$CORE3.prev" 2>/dev/null)" = "older"
done

# The two orderings run directly, with the manifest install forced to fail, to
# show this suite can tell them apart. Without this the checks above pass
# against either version and prove nothing about the change. These are
# transcriptions of the sequence shapes, not of the Makefile text.
note "control: the same injected failure under both orderings"

ordering_old() {  # displaces the installed image, then does fallible work
    local c=$1
    mv -f "$c" "$c.prev"
    mv -f "$c.manifest" "$c.manifest.prev"
    mv -f "$c.tmp.manifest" "$c.manifest" || return 1
    mv -f "$c.tmp" "$c"
}

ordering_new() {  # links the outgoing image aside, then swaps in one rename
    local c=$1
    rm -f "$c.prev" "$c.manifest.prev"
    ln "$c" "$c.prev" 2>/dev/null || cp -p "$c" "$c.prev"
    ln "$c.manifest" "$c.manifest.prev" 2>/dev/null || cp -p "$c.manifest" "$c.manifest.prev"
    mv -f "$c.tmp" "$c"
    mv -f "$c.tmp.manifest" "$c.manifest" || return 1
}

for shape in old new; do
    C="$WORK/control-$shape.core"
    seed_existing_core "$C"
    echo "staged" > "$C.tmp"
    # The staged manifest is absent, so installing it fails. Everything else
    # about the two sequences is identical.
    rm -f "$C.tmp.manifest"
    "ordering_$shape" "$C" 2>/dev/null
    if [ "$shape" = old ]; then
        try "old ordering loses the installed image (the defect, reproduced)" \
            "core still present: $(cat "$C" 2>/dev/null)" test ! -e "$C"
    else
        try "new ordering keeps an image installed throughout" \
            "core missing or empty" test -s "$C"
    fi
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
