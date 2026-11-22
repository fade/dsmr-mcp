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
# the installing is what actually runs here. CORE, WORKER_CORE and
# TEST_CORE_DIR point at scratch paths throughout, so neither the test core
# under .ci-cache nor a deployed release is ever touched.
#
# The later sections cover the test core: it is rebuilt when the SBCL changes
# and when a source is edited while it is being built, two builds of one image
# run one after the other, and no development target writes under DSMR_HOME.
#
# Usage: tests/build/core-install-test.sh

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-install-test.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

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

# A stand-in for SBCL covering every invocation the core targets make: the
# version query, the source listing (DSMR_CORE_SOURCES set), the build, which
# writes the staged image, and the verification, which boots it. Its behaviour
# is set per case through the environment so each failure mode can be reached
# without a real build.
#
#   STUB_SBCL_VERSION    the version `--version` reports and a build records
#   STUB_SOURCES         the files the listing names as the core's sources
#   STUB_TOUCH           a file the build touches before it writes the image
#   STUB_SLOW            seconds the build pauses between two image halves
cat > "$WORK/stub-sbcl" <<'STUB'
#!/bin/sh
case "$*" in
  --version)
      echo "SBCL ${STUB_SBCL_VERSION:-0.0.stub}"
      exit 0 ;;
  *build-core.lisp*)
      if [ -n "${DSMR_CORE_SOURCES:-}" ]; then
          : > "$DSMR_CORE_SOURCES"
          for f in ${STUB_SOURCES:-}; do
              echo "$DSMR_CORE_OUTPUT: $f" >> "$DSMR_CORE_SOURCES"
          done
          exit 0
      fi
      if [ -n "${STUB_TOUCH:-}" ]; then touch "$STUB_TOUCH"; fi
      case "${STUB_BUILD:-ok}" in
        none)       exit 0 ;;                       # build produces nothing
        empty)      : > "$DSMR_CORE_OUTPUT" ;;      # zero-byte image
        nomanifest) echo "${STUB_TAG:-new}" > "$DSMR_CORE_OUTPUT" ;;
        split)      echo "${STUB_TAG:-new}-head" > "$DSMR_CORE_OUTPUT"
                    sleep "${STUB_SLOW:-1}"
                    echo "${STUB_TAG:-new}-tail" >> "$DSMR_CORE_OUTPUT"
                    echo "manifest ${STUB_TAG:-new}" > "$DSMR_CORE_OUTPUT.manifest" ;;
        versioned)  echo "${STUB_TAG:-new}" > "$DSMR_CORE_OUTPUT"
                    echo "sbcl-version ${STUB_SBCL_VERSION:-0.0.stub}" > "$DSMR_CORE_OUTPUT.manifest" ;;
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

# Run the real core target with the stub standing in for SBCL, and CORE and
# WORKER_CORE pointed at scratch paths. Echoes make's exit status.
run_core() {
    local core_path=$1; shift
    ( cd "$REPO_ROOT" && env "$@" make --no-print-directory core \
        SBCL="$WORK/stub-sbcl" CORE="$core_path" WORKER_CORE="$core_path.worker" \
        >"$WORK/out" 2>&1 )
    echo $?
}

# Run one make target with the stub SBCL and the test core directory at
# scratch directory DIR. Output goes to OUT. Echoes make's exit status.
run_target() {
    local target=$1 dir=$2 out=$3; shift 3
    ( cd "$REPO_ROOT" && env "$@" make --no-print-directory "$target" \
        SBCL="$WORK/stub-sbcl" TEST_CORE_DIR="$dir" >"$out" 2>&1 )
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

core_is() { test "$(cat "$1" 2>/dev/null)" = "$2"; }

note "the test core is rebuilt when the SBCL changes"

DIR_A="$WORK/sbcl-change"
SRC_A="$WORK/sbcl-change.lisp"
touch -d '-1 hour' "$SRC_A"
rc=$(run_target test-core "$DIR_A" "$WORK/a1.out" STUB_BUILD=versioned \
     STUB_SBCL_VERSION=1.0 STUB_TAG=one STUB_SOURCES="$SRC_A")
try "test-core builds an absent core" "exit=$rc, core $(cat "$DIR_A/dsmr.core" 2>/dev/null)" \
    core_is "$DIR_A/dsmr.core" one
rc=$(run_target test-core "$DIR_A" "$WORK/a2.out" STUB_BUILD=versioned \
     STUB_SBCL_VERSION=2.0 STUB_TAG=two STUB_SOURCES="$SRC_A")
try "a core built by another SBCL is rebuilt" "exit=$rc, core $(cat "$DIR_A/dsmr.core" 2>/dev/null)" \
    core_is "$DIR_A/dsmr.core" two
try "the rebuild names both SBCL versions" "$(cat "$WORK/a2.out")" \
    grep -q "rebuilding: built by SBCL 1.0, running 2.0" "$WORK/a2.out"
rc=$(run_target test-core "$DIR_A" "$WORK/a3.out" STUB_BUILD=versioned \
     STUB_SBCL_VERSION=2.0 STUB_TAG=three STUB_SOURCES="$SRC_A")
try "a core built by the running SBCL is left alone" "exit=$rc, core $(cat "$DIR_A/dsmr.core" 2>/dev/null)" \
    core_is "$DIR_A/dsmr.core" two

note "a source edited while the test core builds rebuilds it next time"

DIR_B="$WORK/mid-edit"
SRC_B="$WORK/mid-edit.lisp"
touch -d '-1 hour' "$SRC_B"
rc=$(run_target test-core "$DIR_B" "$WORK/b1.out" STUB_BUILD=versioned STUB_TAG=first \
     STUB_SOURCES="$SRC_B" STUB_TOUCH="$SRC_B")
try "the build that saw the edit succeeds" "exit=$rc" core_is "$DIR_B/dsmr.core" first
rc=$(run_target test-core "$DIR_B" "$WORK/b2.out" STUB_BUILD=versioned STUB_TAG=second STUB_SOURCES="$SRC_B")
try "the next test-core rebuilds the core" "exit=$rc, $(cat "$WORK/b2.out")" \
    core_is "$DIR_B/dsmr.core" second
try "and names the edited source" "$(cat "$WORK/b2.out")" \
    grep -q "rebuilding: older than $SRC_B" "$WORK/b2.out"

note "two builds of one image run one after the other"

CORE_C="$WORK/concurrent.core"
build_c() {
    ( cd "$REPO_ROOT" && env STUB_BUILD=split STUB_SLOW=2 STUB_TAG="$1" \
        make --no-print-directory core-server SBCL="$WORK/stub-sbcl" CORE="$CORE_C" \
        >"$WORK/c-$1.out" 2>&1; echo $? >"$WORK/c-$1.rc" )
}
build_c a &
sleep 0.5
build_c b &
wait
try "the first concurrent build succeeds" "$(cat "$WORK/c-a.out")" test "$(cat "$WORK/c-a.rc")" = 0
try "the second concurrent build succeeds" "$(cat "$WORK/c-b.out")" test "$(cat "$WORK/c-b.rc")" = 0
installed=$(cat "$CORE_C" 2>/dev/null | tr '\n' ' ')
one_whole_build() { [ "$installed" = "a-head a-tail " ] || [ "$installed" = "b-head b-tail " ]; }
try "the installed image is one build's whole output" "got: $installed" one_whole_build
tag=${installed%%-head*}
try "the installed manifest is from the same build" "got $(cat "$CORE_C.manifest" 2>/dev/null)" \
    core_is "$CORE_C.manifest" "manifest $tag"
staged=$(find "$WORK" -maxdepth 1 -name 'concurrent.core.tmp*')
try "no staged file is left behind" "$staged" test -z "$staged"

note "no development target writes under DSMR_HOME"

HOME_D="$WORK/deploy-home"
mkdir -p "$HOME_D"
touch "$WORK/home-marker"
chmod a-w "$HOME_D"
for target in core core-worker test-core; do
    rc=$(run_target "$target" "$WORK/home-cores" "$WORK/d-$target.out" DSMR_HOME="$HOME_D")
    try "make $target succeeds with DSMR_HOME read-only" "exit=$rc, $(tail -3 "$WORK/d-$target.out")" \
        test "$rc" = 0
done
try "nothing under DSMR_HOME changed" "$(find "$HOME_D" -newer "$WORK/home-marker")" \
    test -z "$(find "$HOME_D" -newer "$WORK/home-marker")"
# Control: a build aimed into the read-only home fails, so the cases above
# would have failed had any of them written there.
rc=$( ( cd "$REPO_ROOT" && make --no-print-directory core-server SBCL="$WORK/stub-sbcl" \
        CORE="$HOME_D/dsmr.core" >"$WORK/d-control.out" 2>&1 ); echo $? )
try "control: a build into the read-only home fails" "exit=$rc" test "$rc" != 0
chmod u+w "$HOME_D"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
