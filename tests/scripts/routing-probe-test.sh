#!/usr/bin/env bash
#
# Out of band test of the report, check, bus-silent and ledger-row readers in
# scripts/routing-probe.sh, run by `make test-routing-probe`. No session is
# started and the live bus is never read.
#
# Fixtures come from one real probe session, copied unchanged from the config
# directory of the run that produced it (the first routing probe, session
# 2e3819fe-8005-4816-8db0-c1d9671529bd, run through `routing-probe.sh run`):
#   projects/<dir>/<session>.jsonl and its subagents directory
#   logs/subagent-routing/<session>.jsonl (the mod's own log)
#   a copy of the plan file the executor dispatch named, under repo/
# The session holds a planner that ran as requested and an executor rewritten
# to another agent type. Each planted failure below is an edit of this
# recording. States with no recording (a plan hint that differs from the
# planner's intent, quick-batch, audit-fix) have no case here.
#
# A second real session, the patched-mod execute-phase cell (session
# 1e4c2fc2-cfeb-477c-ac00-3bde132f04f6, run through `routing-probe.sh run-arm`
# with the mod loaded), is copied the same way under DIR/execute-phase, with
# the arm's report-execute-phase.tsv, sessions.tsv and expected.tsv under
# evidence/. It reads 8307533 cache-read tokens over its orchestrator and
# subagents, the tracer 2409799.
#
# Usage: ROUTING_PROBE_RECORDED=DIR tests/scripts/routing-probe-test.sh
#   DIR holds the recorded sessions under DIR/tracer and DIR/execute-phase.

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROBE=${ROUTING_PROBE_SCRIPT:-$REPO_ROOT/scripts/routing-probe.sh}

if [ -z "${ROUTING_PROBE_RECORDED:-}" ] || [ ! -d "$ROUTING_PROBE_RECORDED/tracer" ] \
        || [ ! -d "$ROUTING_PROBE_RECORDED/execute-phase" ]; then
    echo "usage: ROUTING_PROBE_RECORDED=DIR $0" >&2
    echo "  DIR must hold the recorded sessions under DIR/tracer and DIR/execute-phase; no recorded transcripts, no test" >&2
    exit 64
fi

REC=$(cd "$ROUTING_PROBE_RECORDED/tracer" && pwd)
SID=2e3819fe-8005-4816-8db0-c1d9671529bd
PARENT=$REC/projects/-tracer/$SID.jsonl
SUBDIR=$REC/projects/-tracer/$SID/subagents
EXECUTOR_LOG=$SUBDIR/agent-ab638530750441bc9.jsonl
EXEC=$(cd "$ROUTING_PROBE_RECORDED/execute-phase" && pwd)
EXEC_PARENT=$(echo "$EXEC"/projects/*/1e4c2fc2-cfeb-477c-ac00-3bde132f04f6.jsonl)
for f in "$EXEC_PARENT" "$EXEC/evidence/expected.tsv" "$PARENT" "$EXECUTOR_LOG" "$REC/expected-report.tsv" "$REC/logs/subagent-routing/$SID.jsonl"; do
    [ -f "$f" ] || { echo "recorded fixture missing: $f" >&2; exit 64; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/routing-probe-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# The recorded dispatch names its plan under the directory the probe ran in.
export ROUTING_PROBE_PATH_MAP="/home/fade/.cache/dsmr-routing-probes/tracer/repo=$REC/repo"

PASSED=0
FAILED=0
ok()  { printf '  ok [%s]\n' "$1"; PASSED=$((PASSED + 1)); return 0; }
bad() { printf '  FAIL [%s] %s\n' "$1" "${2:-}"; FAILED=$((FAILED + 1)); return 0; }

probe() { bash "$PROBE" "$@"; }

# mk_evidence DIR: an evidence directory holding the recorded session as one
# quick-path cell, with an expected table that is true of the recording.
mk_evidence() {
    local dir=$1
    mkdir -p "$dir"
    probe report "$PARENT" > "$dir/report-quick-shell.tsv"
    printf 'session_id\tpath\ttag\ttranscript\tstart\tend\ttokens\tnotes\n%s\tquick\tquick-shell\t%s\t-\t-\t0\t-\n' \
        "$SID" "$PARENT" > "$dir/sessions.tsv"
    printf 'quick\tscripts/probe.sh\tshell-developer\tshell-developer\tclaude-sonnet\n' > "$dir/expected.tsv"
}

printf '\nreport\n'

probe report "$PARENT" > "$WORK/report.tsv"
if diff <(cut -f1-9 "$WORK/report.tsv") "$REC/expected-report.tsv" > "$WORK/report.diff"; then
    ok report-columns
else
    bad report-columns "$(head -n 6 "$WORK/report.diff")"
fi

got=$(awk -F'\t' '$1 == "toolu_0113WWQWuyEEzAsGWBT8L4wh" { print $10 "|" $11 } $1 == "toolu_011yqFi2dJH3rskZgE74wEtG" { print "planner:" $10 "|" $11 }' "$WORK/report.tsv")
# The planner row comes first in the report.
want=$'planner:-|-\nscripts/probe.sh|shell-developer'
if [ "$got" = "$want" ]; then ok report-target-hint; else bad report-target-hint "got: $got"; fi

printf '\ncheck\n'

E=$WORK/ev-pass
mk_evidence "$E"
out=$(probe check recorded "$E/expected.tsv" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^ok quick scripts/probe.sh' <<<"$out"; then ok check-pass; else bad check-pass "rc=$rc: $out"; fi

E=$WORK/ev-type
mk_evidence "$E"
printf 'quick\tscripts/probe.sh\tshell-developer\tlisp-developer\tclaude-sonnet\n' > "$E/expected.tsv"
out=$(probe check recorded "$E/expected.tsv" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q '^FAIL quick scripts/probe.sh' <<<"$out"; then ok check-planted-type; else bad check-planted-type "rc=$rc: $out"; fi

E=$WORK/ev-missing
mk_evidence "$E"
printf 'quick\tsrc/probe.lisp\t-\tlisp-developer\tclaude-opus\n' >> "$E/expected.tsv"
out=$(probe check recorded "$E/expected.tsv" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q '^FAIL quick src/probe.lisp: no matching executor row' <<<"$out"; then ok check-missing-cell; else bad check-missing-cell "rc=$rc: $out"; fi

E=$WORK/ev-log
mk_evidence "$E"
awk -F'\t' -v OFS='\t' 'NR > 1 && $2 == "gsd-planner" { $9 = "no" } { print }' "$E/report-quick-shell.tsv" > "$E/report.tmp"
mv "$E/report.tmp" "$E/report-quick-shell.tsv"
out=$(probe check recorded "$E/expected.tsv" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q '^FAIL quick toolu_011yqFi2dJH3rskZgE74wEtG: mod logged' <<<"$out"; then ok check-log-disagrees; else bad check-log-disagrees "rc=$rc: $out"; fi

E=$WORK/ev-requested
mk_evidence "$E"
printf 'quick\tscripts/probe.sh\tshell-developer\tshell-developer\tclaude-sonnet\tlisp-developer\n' > "$E/expected.tsv"
out=$(probe check recorded "$E/expected.tsv" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'requested gsd-executor, expected lisp-developer' <<<"$out"; then ok check-requested-mismatch; else bad check-requested-mismatch "rc=$rc: $out"; fi

# The planner's intended hint differs from the plan's real one: the cell is
# judged against the real hint and reported, and does not fail.
E=$WORK/ev-deviation
mk_evidence "$E"
printf 'quick\tscripts/probe.sh\t-\tlisp-developer\tclaude-opus\n' > "$E/expected.tsv"
out=$(probe check recorded "$E/expected.tsv" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^planner-deviation quick scripts/probe.sh' <<<"$out"; then ok check-planner-deviation; else bad check-planner-deviation "rc=$rc: $out"; fi

# Expected cells that did not run: dropped only when the list names their path.
E=$WORK/ev-dropped
mk_evidence "$E"
printf 'quick-batch\tsrc/probe.lisp\t-\tlisp-developer\tclaude-opus\n' >> "$E/expected.tsv"
out=$(probe check recorded "$E/expected.tsv" --dropped quick-batch 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^dropped-by-ruling quick-batch src/probe.lisp' <<<"$out" \
        && ! grep -q '^FAIL' <<<"$out"; then
    ok check-dropped-by-ruling
else
    bad check-dropped-by-ruling "rc=$rc: $out"
fi

out=$(probe check recorded "$E/expected.tsv" --dropped quick 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q '^FAIL quick-batch src/probe.lisp: no matching executor row' <<<"$out"; then
    ok check-dropped-other-cell-fails
else
    bad check-dropped-other-cell-fails "rc=$rc: $out"
fi

# A listed cell that did run is judged, not dropped.
E=$WORK/ev-dropped-ran
mk_evidence "$E"
printf 'quick\tscripts/probe.sh\tshell-developer\tlisp-developer\tclaude-sonnet\n' > "$E/expected.tsv"
out=$(probe check recorded "$E/expected.tsv" --dropped quick 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q '^FAIL quick scripts/probe.sh' <<<"$out"; then
    ok check-dropped-ran-cell-judged
else
    bad check-dropped-ran-cell-judged "rc=$rc: $out"
fi

out=$(probe check patched-mod "$EXEC/evidence/expected.tsv" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c '^ok execute-phase' <<<"$out")" -eq 4 ]; then
    ok check-recorded-execute-phase
else
    bad check-recorded-execute-phase "rc=$rc: $out"
fi

printf '\ncap-check\n'

out=$(probe cap-check "$EXEC_PARENT" 2>&1); rc=$?
if [ "$rc" -eq 3 ] && [ "$out" = $'8307533\t5000000\tover' ]; then ok cap-trips-over; else bad cap-trips-over "rc=$rc: $out"; fi

out=$(probe cap-check "$PARENT" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = $'2409799\t5000000\tunder' ]; then ok cap-quiet-under; else bad cap-quiet-under "rc=$rc: $out"; fi

printf '\nbus-silent\n'

BUS_ROOT=$WORK/probe-cell/repo
mkdir -p "$WORK/state/dsmr-mcp/bus"
printf 'joined cwd %s\n' "$BUS_ROOT" > "$WORK/state/dsmr-mcp/bus/wal.log"
out=$(XDG_STATE_HOME=$WORK/state probe bus-silent "$BUS_ROOT" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'wal.log' <<<"$out"; then ok bus-planted; else bad bus-planted "rc=$rc: $out"; fi

mkdir -p "$WORK/clean/dsmr-mcp/bus"
out=$(XDG_STATE_HOME=$WORK/clean probe bus-silent "$BUS_ROOT" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok bus-clean; else bad bus-clean "rc=$rc: $out"; fi

printf '\nledger-row\n'

# Counted by hand from the executor subagent's records: 5 assistant records
# carry 3 distinct message ids.
want=$'path\tturns\tcache_read\tcache_write\toutput\tmodels\n3\t81526\t43072\t1416\tclaude-sonnet-5-5:3'
got=$(probe ledger-row "$EXECUTOR_LOG" | awk -F'\t' 'NR == 1 { print; next } { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }')
if [ "$got" = "$want" ]; then ok ledger-row-recorded; else bad ledger-row-recorded "got: $got"; fi

# Control: the same transcript with its first assistant record repeated. A sum
# per record gives a different output total, a sum per message does not.
DUP=$WORK/duplicated.jsonl
awk '{ print } !done && /"type":"assistant"/ { print; done = 1 }' "$EXECUTOR_LOG" > "$DUP"
per_record=$(jq -s '[ .[] | select(.type == "assistant") | .message.usage.output_tokens // 0 ] | add' "$DUP")
per_message=$(probe ledger-row "$DUP" | awk -F'\t' 'NR == 2 { print $5 }')
turns=$(probe ledger-row "$DUP" | awk -F'\t' 'NR == 2 { print $2 }')
if [ "$per_record" -gt 1416 ] && [ "$per_message" = 1416 ] && [ "$turns" = 3 ]; then
    ok ledger-row-per-message
else
    bad ledger-row-per-message "per record $per_record, per message $per_message, turns $turns"
fi

rows=$(probe ledger-row "$PARENT" "$EXECUTOR_LOG")
n=$(wc -l <<<"$rows")
if [ "$n" -eq 3 ] && [ "${rows%%$'\n'*}" = $'path\tturns\tcache_read\tcache_write\toutput\tmodels' ]; then
    ok ledger-row-header
else
    bad ledger-row-header "lines: $n"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
