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
# The make-config cases build a config directory from the live install on this
# host (agents, skills, hooks, gsd-core and its installer manifest) and prove it
# against that manifest, so they need the live gsd-core 1.19.0 install. The
# run-arm model cases put a stand-in `claude` on PATH that records its arguments
# and copies the recorded tracer session into the config directory; they check
# the model argument and the sessions.tsv column, not any output of claude.
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

# A session killed mid-write leaves a torn last line. The recorded execute-phase
# session, copied with one torn assistant record appended to its orchestrator
# transcript and another to a subagent's, must still total and trip the cap.
TORN=$WORK/torn
mkdir -p "$TORN"
cp "$EXEC_PARENT" "$TORN/"
cp -a "${EXEC_PARENT%.jsonl}" "$TORN/"
TORN_PARENT=$TORN/${EXEC_PARENT##*/}
TORN_SUBS=("${TORN_PARENT%.jsonl}"/subagents/agent-*.jsonl)
TORN_SUB=${TORN_SUBS[0]}
torn_line='{"type":"assistant","message":{"id":"msg_torn","model":"claude-opus-5-5","usage":{"cache_read_input_tokens":9'
printf '%s' "$torn_line" >> "$TORN_PARENT"
printf '%s' "$torn_line" >> "$TORN_SUB"
out=$(probe cap-check "$TORN_PARENT" 2>/dev/null); rc=$?
if [ "$rc" -eq 3 ] && [ "$out" = $'8307533\t5000000\tover' ]; then ok cap-torn-line-still-trips; else bad cap-torn-line-still-trips "rc=$rc: $out"; fi

# A transcript that cannot be read at all is over the cap, never under it.
chmod 000 "$TORN_SUB"
out=$(probe cap-check "$TORN_PARENT" 2>&1); rc=$?
chmod 600 "$TORN_SUB"
if [ "$rc" -eq 3 ] && ! grep -q under <<<"$out" && grep -q 'cannot read' <<<"$out"; then
    ok cap-unreadable-is-over
else
    bad cap-unreadable-is-over "rc=$rc: $out"
fi

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

printf '\nmake-config\n'

LIVE=$(realpath -m "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
CFG=$WORK/config
probe make-config "$CFG" > "$WORK/make-config.out" 2>&1; mc_rc=$?

if [ "$mc_rc" -eq 0 ] && [ ! -e "$CFG/.credentials.json" ] && [ "$(stat -c %a "$CFG")" = 700 ] \
        && [ -e "$LIVE/.credentials.json" ]; then
    ok config-no-credentials
else
    bad config-no-credentials "rc=$mc_rc: $(tail -n 3 "$WORK/make-config.out")"
fi

# Control: the live settings do carry a bus hook, so an empty result means removal.
bus_cmds='[.. | .command? // empty | strings | select(contains("dsmr-bus-watch"))] | length'
live_n=$(jq "$bus_cmds" "$LIVE/settings.json")
cfg_n=$(jq "$bus_cmds" "$CFG/settings.json" 2>/dev/null)
if [ "$live_n" -gt 0 ] && [ "$cfg_n" = 0 ]; then ok config-no-bus-hook; else bad config-no-bus-hook "live $live_n, config $cfg_n"; fi

# shellcheck disable=SC2016 # $live is a jq variable
paths='[.. | strings | select(contains($live))] | length'
live_p=$(jq --arg live "$LIVE" "$paths" "$LIVE/settings.json")
cfg_p=$(jq --arg live "$LIVE" "$paths" "$CFG/settings.json" 2>/dev/null)
# shellcheck disable=SC2016 # $c is a jq variable
cfg_q=$(jq --arg c "$CFG/" '[.. | strings | select(contains($c))] | length' "$CFG/settings.json" 2>/dev/null)
if [ "$live_p" -gt 0 ] && [ "$cfg_p" = 0 ] && [ "$cfg_q" -gt 0 ]; then
    ok config-paths-rewritten
else
    bad config-paths-rewritten "live $live_p, config $cfg_p, rewritten $cfg_q"
fi

if grep -q 'live gsd-core identical before and after' "$WORK/make-config.out" \
        && grep -q 'live gate: five present' "$WORK/make-config.out"; then
    ok config-live-unchanged
else
    bad config-live-unchanged "$(tail -n 4 "$WORK/make-config.out")"
fi

out=$(probe check-config "$CFG" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'pristine check passed' <<<"$out" && [ "$(grep -c '^missing ' <<<"$out")" -eq 5 ]; then
    ok config-pristine
else
    bad config-pristine "rc=$rc: $(tail -n 3 <<<"$out")"
fi

# Control: one appended byte in one workflow must fail the same check, by name.
printf 'x' >> "$CFG/gsd-core/workflows/quick.md"
out=$(probe check-config "$CFG" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q '^mismatch gsd-core/workflows/quick.md$' <<<"$out"; then
    ok config-tamper
else
    bad config-tamper "rc=$rc: $(tail -n 3 <<<"$out")"
fi

# A target inside the live config directory is refused and nothing is created there.
out=$(probe make-config "$LIVE/dsmr-make-config-must-not-exist" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$LIVE/dsmr-make-config-must-not-exist" ] && grep -q 'inside the live config' <<<"$out"; then
    ok config-refuses-live
else
    bad config-refuses-live "rc=$rc: $out"
fi

printf '\ntree-hash\n'

mkdir -p "$WORK/tree/sub"
printf 'a' > "$WORK/tree/sub/b"; printf 'c' > "$WORK/tree/a"
h1=$(probe tree-hash "$WORK/tree")
printf 'd' >> "$WORK/tree/a"
h2=$(probe tree-hash "$WORK/tree")
if [ "$(wc -l <<<"$h1")" -eq 2 ] && [ "$h1" != "$h2" ]; then
    ok tree-hash-sensitive
else
    bad tree-hash-sensitive "$h1"
fi

printf '\nrun-arm orchestrator model\n'

# mk_stubs DIR SESSION: stand-ins on a PATH directory. The bus watcher refuses
# for want of an identity, as the real one does; claude records its arguments,
# then plays back the recorded SESSION transcript and its subagents.
mk_stubs() {
    local dir=$1 session=$2
    mkdir -p "$dir"
    printf '#!/bin/sh\nexit 2\n' > "$dir/dsmr-bus-watch"
    cat > "$dir/claude" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/claude-args.txt"
while [ \$# -gt 0 ]; do
    case "\$1" in --session-id) sid=\$2; shift 2 ;; *) shift ;; esac
done
mkdir -p "\$CLAUDE_CONFIG_DIR/projects/-stub"
cp "$session" "\$CLAUDE_CONFIG_DIR/projects/-stub/\$sid.jsonl"
cp -a "${session%.jsonl}" "\$CLAUDE_CONFIG_DIR/projects/-stub/\$sid"
STUB
    chmod +x "$dir/dsmr-bus-watch" "$dir/claude"
}
STUBS=$WORK/stubs
mk_stubs "$STUBS" "$PARENT"

run_arm() {
    local name=$1; shift
    rm -f "$WORK/claude-args.txt"
    PATH=${ARM_STUBS:-$STUBS}:$PATH XDG_CACHE_HOME=$WORK/cache-$name CLAUDE_CONFIG_DIR=$WORK/stub-live \
        probe run-arm "$name" --gsd-core global --evidence "$WORK/ev-$name" \
        --config-dir "$WORK/cfg-$name" --plugin-dir none --only quick:shell "$@" > "$WORK/arm-$name.out" 2>&1
}

run_arm orch --orchestrator-model claude-sonnet-5-5; rc=$?
last=$(awk -F'\t' 'END { print $NF }' "$WORK/ev-orch/sessions.tsv" 2>/dev/null)
if [ "$rc" -eq 0 ] && grep -q -- '--model claude-sonnet-5-5 ' "$WORK/claude-args.txt" && [ "$last" = claude-sonnet-5-5 ]; then
    ok run-arm-orchestrator-model
else
    bad run-arm-orchestrator-model "rc=$rc, model column '$last': $(tail -n 3 "$WORK/arm-orch.out")"
fi

# Control: without the option the default orchestrator model is used and recorded.
run_arm dflt; rc=$?
last=$(awk -F'\t' 'END { print $NF }' "$WORK/ev-dflt/sessions.tsv" 2>/dev/null)
if [ "$rc" -eq 0 ] && grep -q -- '--model claude-opus-5-5 ' "$WORK/claude-args.txt" && [ "$last" = claude-opus-5-5 ]; then
    ok run-arm-default-model
else
    bad run-arm-default-model "rc=$rc, model column '$last': $(tail -n 3 "$WORK/arm-dflt.out")"
fi

# A cell that plays back the torn execute-phase session stops the arm on the cap.
mk_stubs "$WORK/stubs-torn" "$TORN_PARENT"
ARM_STUBS=$WORK/stubs-torn run_arm torn; rc=$?
if [ "$rc" -eq 3 ] && grep -q 'read 8307533 cached tokens, over the 5000000 cap; arm stopped' "$WORK/arm-torn.out"; then
    ok run-arm-torn-session-stops
else
    bad run-arm-torn-session-stops "rc=$rc: $(tail -n 3 "$WORK/arm-torn.out")"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
