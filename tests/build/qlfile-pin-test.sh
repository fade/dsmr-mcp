#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Checks that the release's dependency pins hold: every git or github source
# in qlfile and qlfile.lock names a full 40-hex commit, the lock's version
# carries that same commit, and ASDF is 3.3.7.4 in both files.
#
# UNPINNED lists the sources allowed to go without a commit, by name. It is
# empty: any unpinned source fails, and adding one here is the only way to
# admit it.
#
# Before reading the real files, the checker runs against planted copies (an
# unpinned source, a short ref, a lock whose version names another commit, a
# different ASDF) and must reject each, so a checker that accepts everything
# cannot pass.
#
# Usage: tests/build/qlfile-pin-test.sh

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
QLFILE="$REPO_ROOT/qlfile"
LOCK="$REPO_ROOT/qlfile.lock"
ASDF_VERSION="3.3.7.4"
UNPINNED=()

WORK=$(mktemp -d "${TMPDIR:-/tmp}/qlfile-pin-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
ok()  { printf '  ok    %s\n' "$1"; PASSED=$((PASSED + 1)); return 0; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAILED=$((FAILED + 1)); return 0; }

# check_qlfile <qlfile>: print one line per problem; fail when there is one.
check_qlfile() {
    awk -v asdf="$ASDF_VERSION" -v allowed=" ${UNPINNED[*]} " '
        /^[[:space:]]*#/ || NF == 0 { next }
        $1 == "git" || $1 == "github" {
            name = $2
            if ($1 == "github") { sub(/.*\//, "", name) }
            ref = ""
            for (i = 3; i < NF; i++) if ($i == ":ref") ref = $(i + 1)
            if (ref !~ /^[0-9a-f]{40}$/ && index(allowed, " " name " ") == 0) {
                printf "qlfile: %s has no 40-hex :ref (%s)\n", name, (ref == "" ? "none" : ref)
                bad = 1
            }
            next
        }
        $1 == "asdf" {
            seen = 1
            if ($2 != asdf) { printf "qlfile: asdf is %s, not %s\n", $2, asdf; bad = 1 }
        }
        END {
            if (!seen) { printf "qlfile: no asdf line\n"; bad = 1 }
            exit bad
        }' "$1"
}

# check_lock <lock>: print one line per problem; fail when there is one.
check_lock() {
    awk -v asdf="$ASDF_VERSION" -v allowed=" ${UNPINNED[*]} " '
        function finish() {
            if (name == "") return
            if (class ~ /source-git$|source-github$/) {
                if (ref !~ /^[0-9a-f]{40}$/) {
                    if (index(allowed, " " name " ") == 0) {
                        printf "lock: %s has no 40-hex :ref (%s)\n", name, (ref == "" ? "none" : ref)
                        bad = 1
                    }
                } else if (version !~ ("-" ref "$")) {
                    printf "lock: %s version %s does not carry its ref %s\n", name, version, ref
                    bad = 1
                }
            } else if (class ~ /source-asdf$/) {
                seen = 1
                if (version != asdf) { printf "lock: asdf is %s, not %s\n", version, asdf; bad = 1 }
            }
            name = class = ref = version = ""
        }
        /^\("/ {
            finish()
            name = $0; sub(/^\("/, "", name); sub(/".*/, "", name)
            next
        }
        /:class / { class = $0; sub(/.*:class /, "", class); sub(/[[:space:]].*/, "", class) }
        /:ref "/  { ref = $0; sub(/.*:ref "/, "", ref); sub(/".*/, "", ref) }
        /^[[:space:]]*:version "/ { version = $0; sub(/.*:version "/, "", version); sub(/".*/, "", version) }
        END {
            finish()
            if (!seen) { printf "lock: no asdf entry\n"; bad = 1 }
            exit bad
        }' "$1"
}

# expect_reject <label> <checker> <file> <fixed string>: the checker must fail
# on the planted file and name the problem.
expect_reject() {
    local label=$1 checker=$2 file=$3 want=$4 out
    if out=$("$checker" "$file"); then
        bad "$label" "the checker accepted the planted file"
    elif [ -z "${out##*"$want"*}" ]; then
        ok "$label"
    else
        bad "$label" "the checker failed without naming '$want': $out"
    fi
}

for f in "$QLFILE" "$LOCK"; do
    if [ ! -s "$f" ]; then
        echo "qlfile-pin-test: $f is missing or empty" >&2
        exit 2
    fi
done

printf '\nplanted copies are rejected\n'

sed 's/^\(git log4cl [^ ]*\) :ref [0-9a-f]*/\1/' "$QLFILE" > "$WORK/qlfile.unpinned"
expect_reject "qlfile: a git source without :ref" check_qlfile "$WORK/qlfile.unpinned" "log4cl has no 40-hex :ref (none)"

sed 's/^\(git usocket [^ ]*\) :ref \([0-9a-f]\{7\}\)[0-9a-f]*/\1 :ref \2/' "$QLFILE" > "$WORK/qlfile.short"
expect_reject "qlfile: a short :ref" check_qlfile "$WORK/qlfile.short" "usocket has no 40-hex :ref"

sed 's/^\(github fade\/slynk-client\) :ref [0-9a-f]*/\1 :ref master/' "$QLFILE" > "$WORK/qlfile.branch"
expect_reject "qlfile: a github source on a branch" check_qlfile "$WORK/qlfile.branch" "slynk-client has no 40-hex :ref (master)"

sed "s/^asdf .*/asdf 3.3.6/" "$QLFILE" > "$WORK/qlfile.asdf"
expect_reject "qlfile: a different asdf" check_qlfile "$WORK/qlfile.asdf" "asdf is 3.3.6, not $ASDF_VERSION"

awk '/^\("bordeaux-threads"/ { inbt = 1 } inbt && /:ref "/ { sub(/ :ref "[0-9a-f]*"/, "") } /^\("usocket"/ { inbt = 0 } { print }' "$LOCK" > "$WORK/lock.unpinned"
expect_reject "lock: bordeaux-threads without :ref" check_lock "$WORK/lock.unpinned" "bordeaux-threads has no 40-hex :ref (none)"

sed '/:initargs (:remote-url "https:\/\/github.com\/edicl\/cl-ppcre.git"/s/:ref "[0-9a-f]*"/:ref "a2ea581"/' "$LOCK" > "$WORK/lock.short"
expect_reject "lock: a short :ref" check_lock "$WORK/lock.short" "cl-ppcre has no 40-hex :ref (a2ea581)"

sed 's/:version "git-fe3da517147d023029782ced7cd989ba24f1e62d"/:version "git-0000000000000000000000000000000000000000"/' "$LOCK" > "$WORK/lock.version"
expect_reject "lock: a version naming another commit" check_lock "$WORK/lock.version" "log4cl version git-0000000000000000000000000000000000000000 does not carry its ref"

sed 's/:version "3.3.7.4"/:version "3.3.6"/' "$LOCK" > "$WORK/lock.asdf"
expect_reject "lock: a different asdf" check_lock "$WORK/lock.asdf" "asdf is 3.3.6, not $ASDF_VERSION"

printf '\nthe real pins\n'

if out=$(check_qlfile "$QLFILE"); then
    ok "qlfile: every git source names a 40-hex :ref; asdf $ASDF_VERSION"
else
    bad "qlfile: pins" "$out"
fi
if out=$(check_lock "$LOCK"); then
    ok "lock: every git source names a 40-hex :ref its version carries; asdf $ASDF_VERSION"
else
    bad "lock: pins" "$out"
fi

git_sources=$(grep -cE '^(git|github) ' "$QLFILE")
lock_sources=$(grep -cE ':class qlot/source/(git|github):' "$LOCK")
if [ "$git_sources" -eq "$lock_sources" ] && [ "$git_sources" -gt 0 ]; then
    ok "qlfile and lock hold the same number of git sources ($git_sources)"
else
    bad "qlfile and lock hold the same number of git sources" "qlfile $git_sources, lock $lock_sources"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
