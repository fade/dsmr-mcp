#!/usr/bin/env bash
#
# Fixture test of the memory store name derivation, run by
# `make test-memory-store-path`. Checks store_name in skills/worker/check-store.py
# against fixed cwd values. Runs no session and reads no live store.
#
# Each expected name is a directory Claude Code created under ~/.claude/projects
# on the development host, matched to the recorded cwd of the sessions that
# created it.
#
# Usage: tests/scripts/memory-store-path-test.sh
#   CHECK_STORE  check-store.py to test (default: the one in this tree)

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CHECK_STORE=${CHECK_STORE:-$REPO_ROOT/skills/worker/check-store.py}

PASSED=0
FAILED=0
ok()   { printf '  ok    %s\n' "$1"; PASSED=$((PASSED + 1)); return 0; }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAILED=$((FAILED + 1)); return 0; }

# if/else rather than `cond && ok || bad`, which would also report the failure
# branch whenever the success branch returns non-zero.
try() {
    local label=$1 detail=$2
    shift 2
    if "$@"; then ok "$label"; else bad "$label" "$detail"; fi
}

# Fixtures: label, cwd, expected store name.
FIXTURES=(
    "underscore|/home/fade/system_scripts|-home-fade-system-scripts"
    "dotted|/home/fade/.claude|-home-fade--claude"
    "plain|/home/fade/SourceCode/lisp/DeepSkyV2/valis|-home-fade-SourceCode-lisp-DeepSkyV2-valis"
)

# Load CHECK_STORE as a module and print store_name for each argument, one per line.
LOADER='import importlib.util, sys
spec = importlib.util.spec_from_file_location("check_store", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for cwd in sys.argv[2:]:
    print(mod.store_name(cwd))'

load_out=$(python3 -I -c "$LOADER" "$CHECK_STORE" 2>&1)
load_rc=$?
try "[python] loading as a module prints nothing" "rc=$load_rc out=$load_out" \
    test "$load_rc" = 0 -a -z "$load_out"

for fx in "${FIXTURES[@]}"; do
    IFS='|' read -r label cwd want <<<"$fx"
    got=$(python3 -I -c "$LOADER" "$CHECK_STORE" "$cwd" 2>&1)
    try "[python] $label fixture: $cwd" "got=$got expected=$want" test "$got" = "$want"
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0 && PASSED > 0))
