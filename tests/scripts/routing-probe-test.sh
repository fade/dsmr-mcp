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
# A third real session, the unpatched-arm control (session
# 62d89842-08dc-46bd-9cf6-8ab0d8c6303a, run through `routing-probe.sh run-arm`
# in a throwaway config directory), is copied unchanged under DIR/control-inherit.
# Its orchestrator Read the live, patched gsd-core/workflows/quick.md under the
# recording host's ~/.claude because the copied skill named ~/.claude literally;
# the reads-outside cases replay it with its paths moved under a stand-in home.
#
# The make-config cases build a config directory from the live install on this
# host (agents, skills, hooks, gsd-core and its installer manifest) and prove it
# against that manifest, so they need the live gsd-core 1.19.0 install. The
# run-arm model cases put a stand-in `claude` on PATH that records its arguments
# and copies the recorded tracer session into the config directory; they check
# the model argument and the sessions.tsv column, not any output of claude.
#
# The planning-directory cases run real code from the live install, copied
# unchanged under a stand-in home: the identity script, the git-exclusion script
# and the session-start planning hook. Every run case uses the stand-in claude;
# no Claude Code session starts anywhere.
#
# Usage: ROUTING_PROBE_RECORDED=DIR tests/scripts/routing-probe-test.sh
#   DIR holds the recorded sessions under DIR/tracer, DIR/execute-phase and
#   DIR/control-inherit.

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROBE=${ROUTING_PROBE_SCRIPT:-$REPO_ROOT/scripts/routing-probe.sh}

if [ -z "${ROUTING_PROBE_RECORDED:-}" ] || [ ! -d "$ROUTING_PROBE_RECORDED/tracer" ] \
        || [ ! -d "$ROUTING_PROBE_RECORDED/execute-phase" ] || [ ! -d "$ROUTING_PROBE_RECORDED/control-inherit" ]; then
    echo "usage: ROUTING_PROBE_RECORDED=DIR $0" >&2
    echo "  DIR must hold the recorded sessions under DIR/tracer, DIR/execute-phase and DIR/control-inherit; no recorded transcripts, no test" >&2
    exit 64
fi

REC=$(cd "$ROUTING_PROBE_RECORDED/tracer" && pwd)
SID=2e3819fe-8005-4816-8db0-c1d9671529bd
PARENT=$REC/projects/-tracer/$SID.jsonl
SUBDIR=$REC/projects/-tracer/$SID/subagents
EXECUTOR_LOG=$SUBDIR/agent-ab638530750441bc9.jsonl
CTRL=$(cd "$ROUTING_PROBE_RECORDED/control-inherit" && pwd)
CTRL_PARENT=$CTRL/projects/-ctl/62d89842-08dc-46bd-9cf6-8ab0d8c6303a.jsonl
EXEC=$(cd "$ROUTING_PROBE_RECORDED/execute-phase" && pwd)
EXEC_PARENT=$(echo "$EXEC"/projects/*/1e4c2fc2-cfeb-477c-ac00-3bde132f04f6.jsonl)
for f in "$CTRL_PARENT" "$EXEC_PARENT" "$EXEC/evidence/expected.tsv" "$PARENT" "$EXECUTOR_LOG" "$REC/expected-report.tsv" "$REC/logs/subagent-routing/$SID.jsonl"; do
    [ -f "$f" ] || { echo "recorded fixture missing: $f" >&2; exit 64; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/routing-probe-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# The recorded dispatch names its plan under the directory the probe ran in.
REC_CWD=$(jq -rn 'first(inputs | select(.cwd != null) | .cwd)' "$PARENT")
export ROUTING_PROBE_PATH_MAP="$REC_CWD=$REC/repo"

# A literal tilde, for patterns that name a home-relative path.
TILDE='~'

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

# A transcript that cannot be read at all is over the cap, never under it. The
# tracer session reads under the cap, so only a total that fails closed trips it.
UNR=$WORK/unreadable
mkdir -p "$UNR"
cp "$PARENT" "$UNR/"
cp -a "${PARENT%.jsonl}" "$UNR/"
UNR_SUBS=("$UNR/$SID"/subagents/agent-*.jsonl)
UNR_SUB=${UNR_SUBS[0]}
chmod 000 "$UNR_SUB"
out=$(probe cap-check "$UNR/$SID.jsonl" 2>"$WORK/unreadable.err"); rc=$?
chmod 600 "$UNR_SUB"
if [ "$rc" -eq 3 ] && [ "$out" = $'unknown\t5000000\tover' ] && grep -q 'cannot read' "$WORK/unreadable.err"; then
    ok cap-unreadable-is-over
else
    bad cap-unreadable-is-over "rc=$rc: $out $(cat "$WORK/unreadable.err")"
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

# A target inside the live config directory is refused and nothing is created
# there. The live tree here is a stand-in under a stand-in home.
FAKE_HOME=$WORK/fake-home
mkdir -p "$FAKE_HOME/.claude/agents"
printf 'Read %s/.claude/x\n' "$TILDE" > "$FAKE_HOME/.claude/agents/a.md"
printf 'built\n' > "$FAKE_HOME/.claude/.routing-probe-config"
fake_before=$(probe tree-hash "$FAKE_HOME/.claude")
out=$(HOME=$FAKE_HOME probe make-config "$FAKE_HOME/.claude/dsmr-make-config-must-not-exist" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$FAKE_HOME/.claude/dsmr-make-config-must-not-exist" ] && grep -q 'inside the live config' <<<"$out" \
        && [ "$(probe tree-hash "$FAKE_HOME/.claude")" = "$fake_before" ]; then
    ok config-refuses-live
else
    bad config-refuses-live "rc=$rc: $out"
fi

if [ -f "$CFG/.routing-probe-config" ]; then ok config-marker-written; else bad config-marker-written "no marker in $CFG"; fi

# Control for the refusals below: a directory make-config built is rebuilt in place.
out=$(probe make-config "$CFG" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'config directory ready' <<<"$out"; then ok config-reuses-own; else bad config-reuses-own "rc=$rc: $(tail -n 3 <<<"$out")"; fi

# A directory make-config did not build is refused before anything in it changes.
FOREIGN=$WORK/foreign
mkdir -p "$FOREIGN/agents"
printf 'keep\n' > "$FOREIGN/agents/keep.md"
chmod 755 "$FOREIGN"
out=$(probe make-config "$FOREIGN" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ -f "$FOREIGN/agents/keep.md" ] && [ "$(stat -c %a "$FOREIGN")" = 755 ] \
        && [ ! -e "$FOREIGN/settings.json" ] && grep -q 'make-config did not build it' <<<"$out"; then
    ok config-refuses-foreign
else
    bad config-refuses-foreign "rc=$rc: $(tail -n 3 <<<"$out")"
fi

# A directory make-config did not build and cannot list is refused too, and
# nothing in it changes.
SEALED=$WORK/sealed
mkdir -p "$SEALED/agents"
printf 'keep\n' > "$SEALED/agents/keep.md"
chmod 300 "$SEALED"
out=$(probe make-config "$SEALED" 2>&1); rc=$?
sealed_mode=$(stat -c %a "$SEALED")
chmod 755 "$SEALED"
if [ "$rc" -ne 0 ] && [ -f "$SEALED/agents/keep.md" ] && [ "$sealed_mode" = 300 ] \
        && [ ! -e "$SEALED/settings.json" ] && grep -q 'cannot be listed' <<<"$out"; then
    ok config-refuses-unlistable
else
    bad config-refuses-unlistable "rc=$rc mode=$sealed_mode: $(tail -n 3 <<<"$out")"
fi

# A directory that holds the repository is refused. The script is copied under
# a stand-in repository so the directory under test is a scratch one.
OUTER=$WORK/outer
mkdir -p "$OUTER/repo/scripts" "$OUTER/repo/harness"
cp "$PROBE" "$OUTER/repo/scripts/routing-probe.sh"
cp -a "$REPO_ROOT/harness/scripts" "$OUTER/repo/harness/scripts"
out=$(bash "$OUTER/repo/scripts/routing-probe.sh" make-config "$OUTER" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$OUTER/settings.json" ] && grep -q 'contains the repository' <<<"$out"; then
    ok config-refuses-repo-parent
else
    bad config-refuses-repo-parent "rc=$rc: $(tail -n 3 <<<"$out")"
fi

printf '\nconfig root rewrite\n'

# The copied skill names the config root; in the live install it is ~/.claude.
SKILL_REL=skills/gsd-quick/SKILL.md
CFG_REL=$(realpath -m --relative-to="$HOME" "$CFG")
if [ -f "$LIVE/$SKILL_REL" ] && grep -qF "$TILDE/.claude/gsd-core/workflows/quick.md" "$LIVE/$SKILL_REL" \
        && grep -qF "$TILDE/$CFG_REL/gsd-core/workflows/quick.md" "$CFG/$SKILL_REL" \
        && ! grep -qF "$TILDE/.claude/" "$CFG/$SKILL_REL"; then
    ok config-skill-names-itself
else
    bad config-skill-names-itself "$(grep -n 'workflows/quick.md' "$CFG/$SKILL_REL" | head -n 2)"
fi

# No markdown, and no file the installer did not write, names the live root;
# the installer's scripts keep their bytes (config-installer-code-untouched).
installer_code=$(jq -r '.files | keys[] | select(endswith(".md") | not)' "$CFG/gsd-file-manifest.json")
# shellcheck disable=SC2016 # $HOME is a grep pattern, not an expansion
leaks=$(grep -rIlE -e '(~|\$HOME)/\.claude([^[:alnum:]_-]|$)' "$CFG/agents" "$CFG/skills" "$CFG/hooks" "$CFG/gsd-core" "$CFG/CLAUDE.md" 2>/dev/null \
    | sed "s|^$CFG/||" | grep -vxF -f <(printf '%s\n' "$installer_code") | head -n 3)
if [ -z "$leaks" ]; then ok config-no-live-references; else bad config-no-live-references "$leaks"; fi

# A fresh make-config leaves check-config passing, now with the isolation check.
rm -f "$CFG/gsd-core/workflows/quick.md.tamper"
probe make-config "$CFG" > "$WORK/make-config2.out" 2>&1
out=$(probe check-config "$CFG" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'isolation check passed' <<<"$out" && grep -q 'pristine check passed' <<<"$out"; then
    ok config-isolated
else
    bad config-isolated "rc=$rc: $(tail -n 3 <<<"$out")"
fi

# The installer's own scripts join the home directory with .claude at run
# time; check-config lists them and still passes.
if grep -q '^runtime home join gsd-core/bin/lib/' <<<"$out" && grep -q "^installer code names the home config root " <<<"$out"; then
    ok config-lists-runtime-home-joins
else
    bad config-lists-runtime-home-joins "$(grep -c '' <<<"$out") lines"
fi

# Each spelling of the live root the rewrite does not produce, planted in a
# copied file, fails check-config by name. The spellings are written out here,
# not taken from the script.
cp -p "$CFG/CLAUDE.md" "$WORK/claude-md.saved"
# shellcheck disable=SC2016 # each spelling is literal text
for spelling in 'cat "${HOME}/.claude/gsd-core/workflows/quick.md"' 'cat "$HOME"/.claude/x' \
        "cat $TILDE/\".claude\"/y" "{\"p\": \"${LIVE//\//\\/}/x\"}" 'node -e "x" $HOME/.claude.json'; do
    cp -p "$WORK/claude-md.saved" "$CFG/CLAUDE.md"
    printf '\n%s\n' "$spelling" >> "$CFG/CLAUDE.md"
    out=$(probe check-config "$CFG" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && grep -qxF 'live-root reference CLAUDE.md' <<<"$out"; then
        ok "config-spelling-flagged: $spelling"
    else
        bad "config-spelling-flagged: $spelling" "rc=$rc: $(tail -n 3 <<<"$out")"
    fi
done
cp -p "$WORK/claude-md.saved" "$CFG/CLAUDE.md"

# A copied file the check cannot read, or a binary one naming the live root,
# fails check-config and repoint by name instead of being passed over.
printf 'x %s/.claude/x\0' "$TILDE" > "$CFG/agents/blob.bin"
out=$(probe check-config "$CFG" 2>&1); rc=$?
rout=$(probe repoint "$CFG" 2>&1); rrc=$?
rm -f "$CFG/agents/blob.bin"
if [ "$rc" -ne 0 ] && grep -qxF 'binary file names the live root agents/blob.bin' <<<"$out" \
        && [ "$rrc" -ne 0 ] && grep -qF 'agents/blob.bin' <<<"$rout"; then
    ok config-binary-reported
else
    bad config-binary-reported "rc=$rc rrc=$rrc: $(tail -n 2 <<<"$out") / $(tail -n 2 <<<"$rout")"
fi
# Python bytecode embeds its source's path and is rebuilt on use: repoint drops it.
mkdir -p "$CFG/skills/x/__pycache__"
printf 'x %s/skills/x/s.py\0' "$LIVE" > "$CFG/skills/x/__pycache__/s.pyc"
rout=$(probe repoint "$CFG" 2>&1); rrc=$?
if [ "$rrc" -eq 0 ] && [ ! -e "$CFG/skills/x/__pycache__" ] && grep -qxF 'removed bytecode cache skills/x/__pycache__' <<<"$rout"; then
    ok repoint-drops-bytecode-cache
else
    bad repoint-drops-bytecode-cache "rrc=$rrc: $rout"
fi
rm -rf "$CFG/skills/x"
printf 'unread\n' > "$CFG/agents/sealed.md"
chmod 000 "$CFG/agents/sealed.md"
out=$(probe check-config "$CFG" 2>&1); rc=$?
rout=$(probe repoint "$CFG" 2>&1); rrc=$?
rm -f "$CFG/agents/sealed.md"
if [ "$rc" -ne 0 ] && grep -qxF 'unreadable agents/sealed.md' <<<"$out" \
        && [ "$rrc" -ne 0 ] && grep -qF 'agents/sealed.md' <<<"$rout"; then
    ok config-unreadable-reported
else
    bad config-unreadable-reported "rc=$rc rrc=$rrc: $(tail -n 2 <<<"$out") / $(tail -n 2 <<<"$rout")"
fi

# A link from a copied subtree into the live tree is read through by a
# session; check-config fails on it by name, for a linked file and a linked
# directory alike.
ln -s "$LIVE/agents/shell-developer.md" "$CFG/agents/linked.md"
ln -s "$LIVE/skills/gsd-quick" "$CFG/skills/linked"
out=$(probe check-config "$CFG" 2>&1); rc=$?
rm -f "$CFG/agents/linked.md" "$CFG/skills/linked"
if [ "$rc" -ne 0 ] && grep -qxF "link out of the config directory agents/linked.md -> $LIVE/agents/shell-developer.md" <<<"$out" \
        && grep -qxF "link out of the config directory skills/linked -> $LIVE/skills/gsd-quick" <<<"$out"; then
    ok config-link-into-live-flagged
else
    bad config-link-into-live-flagged "rc=$rc: $(tail -n 3 <<<"$out")"
fi

# Settings and Claude Code's state file in DIR are read, never edited: a hook
# or MCP server that runs from the live root fails check-config, named by its
# JSON path; an environment value is never printed.
cp -p "$CFG/settings.json" "$WORK/settings.saved"
cp -p "$CFG/.claude.json" "$WORK/claude-json.saved"
jq --arg c "bash $TILDE/.claude/hooks/x.sh" '.statusLine = {type: "command", command: $c} | .env.PROBE_SECRET_PATH = "/x/.claude-not" | .env.PROBE_LIVE = "$HOME/.claude/y"' \
    "$WORK/settings.saved" > "$CFG/settings.json"
jq --arg a "$LIVE/tools/server.js" '.mcpServers.planted = {command: "node", args: [$a]}' "$WORK/claude-json.saved" > "$CFG/.claude.json"
s_before=$(sha256sum "$CFG/settings.json" "$CFG/.claude.json")
out=$(probe check-config "$CFG" 2>&1); rc=$?
s_after=$(sha256sum "$CFG/settings.json" "$CFG/.claude.json")
cp -p "$WORK/settings.saved" "$CFG/settings.json"
cp -p "$WORK/claude-json.saved" "$CFG/.claude.json"
if [ "$rc" -ne 0 ] && [ "$s_before" = "$s_after" ] \
        && grep -qxF 'settings reference settings.json .statusLine.command' <<<"$out" \
        && grep -qxF 'settings reference .claude.json .mcpServers.planted.args[0]' <<<"$out" \
        && grep -qxF 'settings reference settings.json .env' <<<"$out" \
        && ! grep -q 'PROBE_LIVE\|/y' <<<"$out"; then
    ok config-settings-reference-flagged
else
    bad config-settings-reference-flagged "rc=$rc: $(grep -i settings <<<"$out" | head -n 4)"
fi

# make-config builds the state file's MCP servers to name DIR, as it does the
# settings' hooks. Control: the live state file names the live root.
LIVE_JSON=$HOME/.claude.json
# shellcheck disable=SC2016 # $l is a jq variable
names_live='[.mcpServers // {} | .. | strings | select(contains($l))] | length'
if [ "$(jq --arg l "$LIVE/" "$names_live" "$LIVE_JSON")" -gt 0 ] && [ "$(jq --arg l "$LIVE/" "$names_live" "$CFG/.claude.json")" -eq 0 ] \
        && [ "$(jq --arg l "$(realpath -m "$CFG")/" "$names_live" "$CFG/.claude.json")" -gt 0 ]; then
    ok config-mcp-servers-name-dir
else
    bad config-mcp-servers-name-dir "$(jq -c '.mcpServers | map_values(.args)' "$CFG/.claude.json")"
fi

# Control: a copied file that names the live root again fails check-config by
# name. CLAUDE.md is not the installer's, so the pristine proof does not see it.
printf '\nRead %s/.claude/gsd-core/workflows/quick.md\n' "$TILDE" >> "$CFG/CLAUDE.md"
out=$(probe check-config "$CFG" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q "^live-root reference CLAUDE.md\$" <<<"$out"; then
    ok config-planted-live-reference
else
    bad config-planted-live-reference "rc=$rc: $(tail -n 3 <<<"$out")"
fi
probe repoint "$CFG" > /dev/null 2>&1
out=$(probe check-config "$CFG" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'isolation check passed' <<<"$out"; then ok config-repoint-heals-reference; else bad config-repoint-heals-reference "rc=$rc: $(tail -n 3 <<<"$out")"; fi

# The live quick.md is the patched one, not the installer's: planted in the
# throwaway copy, repointed as the dir's own files are, it must fail.
if ! cmp -s "$LIVE/gsd-core/workflows/quick.md" "$CFG/gsd-core/workflows/quick.md"; then
    cp "$LIVE/gsd-core/workflows/quick.md" "$CFG/gsd-core/workflows/quick.md"
    probe repoint "$CFG" > /dev/null 2>&1
    out=$(probe check-config "$CFG" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && grep -q '^mismatch gsd-core/workflows/quick.md$' <<<"$out"; then
        ok config-planted-patched-workflow
    else
        bad config-planted-patched-workflow "rc=$rc: $(tail -n 3 <<<"$out")"
    fi
else
    bad config-planted-patched-workflow "live quick.md equals the installer copy; nothing to plant"
fi
probe make-config "$CFG" > "$WORK/make-config3.out" 2>&1

# The installer rewrites the config root in markdown only; its scripts reach
# the root at run time. Every installer file that is not markdown is copied
# byte for byte.
# shellcheck disable=SC2016 # jq program
changed=$(jq -r '.files | to_entries[] | select(.key | endswith(".md") | not) | [.key, .value] | @tsv' "$CFG/gsd-file-manifest.json" \
    | while IFS=$'\t' read -r rel want; do
          [ -f "$CFG/$rel" ] || continue
          [ "$(sha256sum < "$CFG/$rel" | cut -d' ' -f1)" = "$want" ] || printf '%s\n' "$rel"
      done)
named=$(grep -lF "$TILDE/.claude/" "$LIVE/gsd-core/bin/lib/"*.cjs | head -n 1)
if [ -z "$changed" ] && [ -n "$named" ]; then ok config-installer-code-untouched; else bad config-installer-code-untouched "rewritten: $(head -n 3 <<<"$changed") named: $named"; fi

# Code that is not the installer's is rewritten, and listed. The planning hook
# names scripts under the live root by absolute path.
HOOK_REL=hooks/gsd-planning-symlinks.js
if [ -f "$LIVE/$HOOK_REL" ] && grep -qF "$LIVE/scripts/" "$LIVE/$HOOK_REL" && ! grep -qF "$LIVE/" "$CFG/$HOOK_REL" \
        && grep -qF "$HOOK_REL" "$WORK/make-config3.out"; then
    ok config-other-code-rewritten-and-listed
else
    bad config-other-code-rewritten-and-listed "$(grep -n 'rewrote' "$WORK/make-config3.out" | head -n 3)"
fi

# A hook copied from the live tree requires scripts beside it by absolute
# path; each one it names is copied too, so the rewritten require resolves.
reqs=$(grep -oE "require\('[^']+'\)" "$CFG/$HOOK_REL" | sed "s/^require('//; s/')\$//" | grep '^/')
missing=""
for r in $reqs; do [ -f "$r" ] || missing+=" $r"; done
if grep -qF "require('$LIVE/scripts/" "$LIVE/$HOOK_REL" && [ -n "$reqs" ] && [ -z "$missing" ] \
        && ! grep -qvF "$(realpath -m "$CFG")/" <<<"$reqs"; then
    ok config-hook-scripts-copied
else
    bad config-hook-scripts-copied "requires: $reqs; missing:$missing"
fi

# Control: an installer script carrying the rewrite fails the proof by name,
# and repoint puts the installer's bytes back.
LIB_REL=${named#"$LIVE"/}
CFG_REL=$(realpath -m --relative-to="$HOME" "$CFG")
perl -pe "s{~/\\.claude(?![\\w-])}{~/$CFG_REL}g; s{\\\$HOME/\\.claude(?![\\w-])}{\\\$HOME/$CFG_REL}g" "$LIVE/$LIB_REL" > "$CFG/$LIB_REL"
out=$(probe check-config "$CFG" 2>&1); rc=$?
if ! cmp -s "$LIVE/$LIB_REL" "$CFG/$LIB_REL" && [ "$rc" -ne 0 ] && grep -qxF "mismatch $LIB_REL" <<<"$out"; then
    ok config-rewritten-installer-code-fails
else
    bad config-rewritten-installer-code-fails "rc=$rc: $(tail -n 3 <<<"$out")"
fi
out=$(probe repoint "$CFG" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$LIVE/$LIB_REL" "$CFG/$LIB_REL" && grep -qF "restored $LIB_REL" <<<"$out"; then
    ok repoint-restores-installer-code
else
    bad repoint-restores-installer-code "rc=$rc: $out"
fi

# The proof covers the installer's agents, skills and hooks: one appended byte
# in each fails it by name.
for rel in agents/gsd-executor.md skills/gsd-quick/SKILL.md hooks/gsd-path-export.js; do
    cp -p "$CFG/$rel" "$WORK/saved"
    printf 'x' >> "$CFG/$rel"
    out=$(probe check-config "$CFG" 2>&1); rc=$?
    cp -p "$WORK/saved" "$CFG/$rel"
    if [ "$rc" -ne 0 ] && grep -qxF "mismatch $rel" <<<"$out"; then
        ok "config-tamper-${rel%%/*}"
    else
        bad "config-tamper-${rel%%/*}" "rc=$rc: $(tail -n 3 <<<"$out")"
    fi
done

# ~/.claude.json is Claude Code's own state file, not a path under the config
# root; a sentence ending in ~/.claude. still names the root.
OLDJ=$WORK/old-json
mkdir -p "$OLDJ/agents"
printf 'built\n' > "$OLDJ/.routing-probe-config"
printf 'State lives in %s/.claude.json; agents live in %s/.claude.\n' "$TILDE" "$TILDE" > "$OLDJ/agents/a.md"
probe repoint "$OLDJ" > /dev/null 2>&1
OLDJ_REL=$(realpath -m --relative-to="$HOME" "$OLDJ")
if grep -qxF "State lives in $TILDE/.claude.json; agents live in $TILDE/$OLDJ_REL." "$OLDJ/agents/a.md"; then
    ok repoint-leaves-claude-json
else
    bad repoint-leaves-claude-json "$(cat "$OLDJ/agents/a.md")"
fi

# repoint on a directory built the old way: real copied files that name ~/.claude,
# beside stand-ins for the files it must never touch.
OLD=$WORK/old-config
mkdir -p "$OLD/skills/gsd-quick" "$OLD/agents" "$OLD/projects/p" "$OLD/logs"
cp "$LIVE/$SKILL_REL" "$OLD/$SKILL_REL"
cp "$LIVE/agents/shell-developer.md" "$OLD/agents/shell-developer.md"
printf 'built\n' > "$OLD/.routing-probe-config"
for keep in .credentials.json settings.json settings.local.json projects/p/s.jsonl logs/l.log; do
    printf 'sentinel %s %s/.claude/x %s/y\n' "$keep" "$TILDE" "$LIVE" > "$OLD/$keep"
done
chmod 600 "$OLD/.credentials.json"
keep_before=$(cd "$OLD" && sha256sum .credentials.json settings.json settings.local.json projects/p/s.jsonl logs/l.log)
out=$(probe repoint "$OLD" 2>&1); rc=$?
OLD_REL=$(realpath -m --relative-to="$HOME" "$OLD")
keep_after=$(cd "$OLD" && sha256sum .credentials.json settings.json settings.local.json projects/p/s.jsonl logs/l.log)
if [ "$rc" -eq 0 ] && grep -qF "$TILDE/$OLD_REL/gsd-core/workflows/quick.md" "$OLD/$SKILL_REL" \
        && ! grep -qF "$TILDE/.claude/" "$OLD/$SKILL_REL" "$OLD/agents/shell-developer.md"; then
    ok repoint-rewrites-artifacts
else
    bad repoint-rewrites-artifacts "rc=$rc: $out"
fi
if [ "$keep_before" = "$keep_after" ] && [ "$(stat -c %a "$OLD/.credentials.json")" = 600 ]; then
    ok repoint-leaves-credentials-and-state
else
    bad repoint-leaves-credentials-and-state "$(diff <(printf '%s\n' "$keep_before") <(printf '%s\n' "$keep_after"))"
fi
h1=$(probe tree-hash "$OLD" 2>&1)
probe repoint "$OLD" > /dev/null 2>&1
h2=$(probe tree-hash "$OLD" 2>&1)
if [ -n "$h1" ] && [ "$h1" = "$h2" ] && ! grep -q 'unknown subcommand' <<<"$h1"; then ok repoint-idempotent; else bad repoint-idempotent "second run changed the tree"; fi

# A link already standing at a temporary name beside a file repoint rewrites
# is never written through.
printf 'Read %s/.claude/gsd-core/workflows/quick.md\n' "$TILDE" > "$OLD/agents/fresh.md"
printf 'victim\n' > "$WORK/victim"
ln -s "$WORK/victim" "$OLD/agents/fresh.md.repoint.tmp"
out=$(probe repoint "$OLD" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$WORK/victim")" = victim ] && [ -L "$OLD/agents/fresh.md.repoint.tmp" ] \
        && grep -qF "$TILDE/$OLD_REL/gsd-core/workflows/quick.md" "$OLD/agents/fresh.md"; then
    ok repoint-never-writes-through-a-link
else
    bad repoint-never-writes-through-a-link "rc=$rc victim=$(cat "$WORK/victim"): $out"
fi
rm -f "$OLD/agents/fresh.md" "$OLD/agents/fresh.md.repoint.tmp"

mkdir -p "$WORK/notmine"
out=$(probe repoint "$WORK/notmine" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'make-config did not build it' <<<"$out"; then ok repoint-refuses-foreign; else bad repoint-refuses-foreign "rc=$rc: $out"; fi
# The stand-in live tree carries the marker and a file naming ~/.claude, so
# only the refusal keeps repoint from rewriting it.
out=$(HOME=$FAKE_HOME probe repoint "$FAKE_HOME/.claude" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'inside the live config' <<<"$out" \
        && [ "$(probe tree-hash "$FAKE_HOME/.claude")" = "$fake_before" ]; then
    ok repoint-refuses-live
else
    bad repoint-refuses-live "rc=$rc: $out"
fi

printf '\nreads-outside\n'

# The recorded control session, moved under a stand-in home: its paths under
# the recording host's throwaway config, live config root and home become the
# same paths under RO_HOME, so no case depends on this host's directories.
RO_HOME=$WORK/ro-home
RO_LIVE=$RO_HOME/.claude
RO_CFG=$RO_HOME/.cache/dsmr-routing-probes/config
mkdir -p "$RO_LIVE" "$RO_CFG"
RO_T=$WORK/ro/${CTRL_PARENT##*/}
mkdir -p "$WORK/ro"
# The recording host's home is the part of the session's cwd before /.cache/.
CTRL_CWD=$(jq -rn 'first(inputs | select(.cwd != null) | .cwd)' "$CTRL_PARENT")
REC_HOME=${CTRL_CWD%%/.cache/*}
REC_HOME=$REC_HOME RO_CFG=$RO_CFG RO_LIVE=$RO_LIVE RO_HOME=$RO_HOME perl -pe '
    s{\Q$ENV{REC_HOME}\E/\.cache/dsmr-routing-probes/config}{$ENV{RO_CFG}}g;
    s{\Q$ENV{REC_HOME}\E/\.claude}{$ENV{RO_LIVE}}g;
    s{\Q$ENV{REC_HOME}\E}{$ENV{RO_HOME}}g' "$CTRL_PARENT" > "$RO_T"

ro_probe() { HOME=$RO_HOME probe reads-outside "$@"; }

out=$(ro_probe "$RO_CFG" "$RO_T" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -qxF "$(printf 'Read\t%s/gsd-core/workflows/quick.md' "$RO_LIVE")" <<<"$out"; then
    ok reads-outside-flags-live-read
else
    bad reads-outside-flags-live-read "rc=$rc: $(head -n 5 <<<"$out")"
fi

# Claude Code loaded the live CLAUDE.md of an ancestor directory; the
# recording carries it as an instructions attachment.
if grep -qF "$(printf 'attachment:instructions\t%s/CLAUDE.md' "$RO_LIVE")" <<<"$out"; then
    ok reads-outside-flags-loaded-instructions
else
    bad reads-outside-flags-loaded-instructions "$(head -n 5 <<<"$out")"
fi

# The recorded Bash call listed the live quick.md by its ~ name.
if grep -qF "$(printf 'Bash\t')" <<<"$out" && grep -F "$(printf 'Bash\t')" <<<"$out" | grep -qF "$TILDE/.claude/gsd-core/workflows/quick.md"; then
    ok reads-outside-flags-bash-command
else
    bad reads-outside-flags-bash-command "$(head -n 5 <<<"$out")"
fi

# The caller's CLAUDE_CONFIG_DIR does not move the live root.
out=$(CLAUDE_CONFIG_DIR=$RO_CFG ro_probe "$RO_CFG" "$RO_T" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -qxF "$(printf 'Read\t%s/gsd-core/workflows/quick.md' "$RO_LIVE")" <<<"$out"; then
    ok reads-outside-ignores-caller-config-dir
else
    bad reads-outside-ignores-caller-config-dir "rc=$rc: $(head -n 5 <<<"$out")"
fi

# A session whose working directory holds the live root still has its live reads flagged.
RO_CWD=$WORK/ro-cwd/${CTRL_PARENT##*/}
mkdir -p "$WORK/ro-cwd"
jq -c --arg h "$RO_HOME" 'if .cwd != null then .cwd = $h else . end' "$RO_T" > "$RO_CWD"
out=$(ro_probe "$RO_CFG" "$RO_CWD" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -qxF "$(printf 'Read\t%s/gsd-core/workflows/quick.md' "$RO_LIVE")" <<<"$out"; then
    ok reads-outside-cwd-does-not-hide
else
    bad reads-outside-cwd-does-not-hide "rc=$rc: $(head -n 5 <<<"$out")"
fi

out=$(ro_probe "$RO_LIVE" "$RO_T" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'refusing' <<<"$out"; then ok reads-outside-refuses-live-dir; else bad reads-outside-refuses-live-dir "rc=$rc: $out"; fi

# The clean base for the planted cases: the recording with every record that
# names the stand-in home's config root removed, except the skill listing,
# whose built-in keybindings entry names ~/.claude in prose.
CLEAN_DIR=$WORK/ro-clean
mkdir -p "$CLEAN_DIR"
CLEAN_T=$CLEAN_DIR/${CTRL_PARENT##*/}
jq -c --arg l "$RO_LIVE" 'select((.attachment.type // "") == "skill_listing"
        or ((tostring | contains($l) or contains("~/.claude") or contains("$HOME/.claude")) | not))' "$RO_T" > "$CLEAN_T"
out=$(ro_probe "$RO_CFG" "$CLEAN_T" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -qF "$RO_LIVE" <<<"$out" && grep -q '"skill_listing"' "$CLEAN_T" \
        && grep -qF "$TILDE/.claude/keybindings.json" "$CLEAN_T"; then
    ok reads-outside-clean-control
else
    bad reads-outside-clean-control "rc=$rc: $(head -n 5 <<<"$out")"
fi

# Each planted case appends one record to a copy of the clean base, built from
# the recording's first Bash call or first tool result.
BASH_REC=$(jq -c 'select(.type == "assistant" and any(.message.content[]?; .type == "tool_use" and .name == "Bash"))' "$CLEAN_T" | head -n 1)
RESULT_REC=$(jq -c 'select(.type == "user" and any(.message.content[]?; .type == "tool_result"))' "$CLEAN_T" | head -n 1)
n=0

# shellcheck disable=SC2016 # each spelling is literal text in a command
for spelling in 'cat ~/.claude/gsd-core/workflows/quick.md' 'cat ${HOME}/.claude/gsd-core/workflows/quick.md' \
        'cat "$HOME"/.claude/gsd-core/workflows/quick.md' 'cat ~/".claude"/gsd-core/workflows/quick.md' \
        'node LIVE/gsd-core/bin/gsd-tools.cjs x' 'printf %s JSONLIVE/x'; do
    n=$((n + 1))
    cmd=${spelling//JSONLIVE/${RO_LIVE//\//\\/}}
    cmd=${cmd//LIVE/$RO_LIVE}
    mkdir -p "$WORK/plant-bash$n"
    cp "$CLEAN_T" "$WORK/plant-bash$n/"
    jq -c --arg c "$cmd" '.message.content |= map(if .type == "tool_use" then .input.command = $c else . end)' <<<"$BASH_REC" \
        >> "$WORK/plant-bash$n/${CLEAN_T##*/}"
    out=$(ro_probe "$RO_CFG" "$WORK/plant-bash$n/${CLEAN_T##*/}" 2>&1); rc=$?
    if [ "$rc" -eq 1 ] && grep -q "^Bash" <<<"$out"; then
        ok "reads-outside-bash-spelling-$n"
    else
        bad "reads-outside-bash-spelling-$n" "$cmd: rc=$rc: $out"
    fi
done

mkdir -p "$WORK/plant-write"
cp "$CLEAN_T" "$WORK/plant-write/"
jq -c --arg p "$RO_LIVE/settings.json" '.message.content |= map(if .type == "tool_use" then .name = "Write" | .input = {file_path: $p, content: "{}"} else . end)' <<<"$BASH_REC" \
    >> "$WORK/plant-write/${CLEAN_T##*/}"
out=$(ro_probe "$RO_CFG" "$WORK/plant-write/${CLEAN_T##*/}" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -qxF "$(printf 'Write\t%s/settings.json' "$RO_LIVE")" <<<"$out"; then
    ok reads-outside-flags-write
else
    bad reads-outside-flags-write "rc=$rc: $out"
fi

mkdir -p "$WORK/plant-result"
cp "$CLEAN_T" "$WORK/plant-result/"
jq -c --arg t "-rw-r--r-- 1 fade fade 45621 Oct 28 05:47 $RO_LIVE/gsd-core/workflows/quick.md" \
    '.message.content |= map(if .type == "tool_result" then .content = $t else . end)' <<<"$RESULT_REC" \
    >> "$WORK/plant-result/${CLEAN_T##*/}"
out=$(ro_probe "$RO_CFG" "$WORK/plant-result/${CLEAN_T##*/}" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q '^result' <<<"$out"; then ok reads-outside-flags-tool-result; else bad reads-outside-flags-tool-result "rc=$rc: $out"; fi

# A torn line, before a live read in the same transcript or in a subagent's,
# makes the check fail; it never passes on what it could not parse.
READ_REC=$(jq -c --arg p "$RO_LIVE/gsd-core/workflows/quick.md" '.message.content |= map(if .type == "tool_use" then .name = "Read" | .input = {file_path: $p} else . end)' <<<"$BASH_REC")
mkdir -p "$WORK/plant-torn"
cp "$CLEAN_T" "$WORK/plant-torn/"
printf '%s\n%s\n' '{"type":"assistant","message":{"content":[' "$READ_REC" >> "$WORK/plant-torn/${CLEAN_T##*/}"
out=$(ro_probe "$RO_CFG" "$WORK/plant-torn/${CLEAN_T##*/}" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'cannot parse' <<<"$out"; then ok reads-outside-torn-fails-closed; else bad reads-outside-torn-fails-closed "rc=$rc: $out"; fi

SUB_T=$WORK/plant-sub/${CLEAN_T##*/}
mkdir -p "${SUB_T%.jsonl}/subagents"
cp "$CLEAN_T" "$SUB_T"
printf '%s\n' "$READ_REC" > "${SUB_T%.jsonl}/subagents/agent-a.jsonl"
out=$(ro_probe "$RO_CFG" "$SUB_T" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -qxF "$(printf 'Read\t%s/gsd-core/workflows/quick.md' "$RO_LIVE")" <<<"$out"; then
    ok reads-outside-reads-subagents
else
    bad reads-outside-reads-subagents "rc=$rc: $out"
fi
printf 'garbage{\n' >> "$SUB_T"
out=$(ro_probe "$RO_CFG" "$SUB_T" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'cannot parse' <<<"$out"; then ok reads-outside-torn-parent-fails-closed; else bad reads-outside-torn-parent-fails-closed "rc=$rc: $out"; fi

EMPTY_T=$WORK/plant-empty/${CLEAN_T##*/}
mkdir -p "${EMPTY_T%.jsonl}/subagents"
cp "$CLEAN_T" "$EMPTY_T"
out=$(ro_probe "$RO_CFG" "$EMPTY_T" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'no subagent transcripts' <<<"$out"; then ok reads-outside-empty-subagents-fails; else bad reads-outside-empty-subagents-fails "rc=$rc: $out"; fi

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

printf '\nrun isolation\n'

# A stand-in caller home. Its live config root holds a gsd-core bin directory
# that sits on PATH directly, through a linked directory, and through a shim
# directory holding a link into it. The probe repository lies outside it.
RH=$WORK/run-home
RCFG=$RH/.cache/dsmr-routing-probes/config
RREPO=$WORK/run-scratch/quick/repo
RSTUB=$WORK/run-stub
mkdir -p "$RH/.claude/gsd-core/bin" "$RH/.local/bin" "$RCFG/gsd-core/bin" "$RREPO" "$RSTUB"
: > "$RH/.claude/gsd-core/bin/gsd-tools"
ln -s ../../.claude/gsd-core/bin/gsd-tools "$RH/.local/bin/gsd-tools"
ln -s "$RH/.claude/gsd-core/bin" "$RH/bin-link"
printf 'reached\n' > "$RCFG/marker"
git -C "$RREPO" init -q
git -C "$RREPO" config user.name 'Probe Author'
git -C "$RREPO" config user.email probe@example.invalid
# The stand-in claude records what it was given and writes a transcript where
# run looks for one. With PROBE_TRIP set it reaches for $HOME/.claude; with
# PROBE_HOOK set it runs the config directory's session-start planning hook;
# with PROBE_MKDIR set it creates that directory.
cat > "$RSTUB/claude" <<STUB
#!/bin/bash
env > "$WORK/run-env.txt"
if [ -e "\$HOME/.claude" ]; then echo present; else echo absent; fi > "$WORK/run-tripwire.txt"
cat "\$HOME/.cache/dsmr-routing-probes/config/marker" > "$WORK/run-marker.txt" 2>&1
git config --global user.name > "$WORK/run-git.txt" 2>&1
[ -z "\${PROBE_TRIP:-}" ] || { mkdir -p "\$HOME/.claude"; : > "\$HOME/.claude/touched"; }
[ -z "\${PROBE_HOOK:-}" ] || node "\$CLAUDE_CONFIG_DIR/hooks/gsd-planning-symlinks.js" > "$WORK/run-hook.txt" 2>&1
[ -z "\${PROBE_MKDIR:-}" ] || mkdir -p "\$PROBE_MKDIR"
while [ \$# -gt 0 ]; do case "\$1" in --session-id) sid=\$2; shift 2 ;; *) shift ;; esac; done
cfg=\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}
mkdir -p "\$cfg/projects/-r"
printf '{}\n' > "\$cfg/projects/-r/\$sid.jsonl"
STUB
chmod +x "$RSTUB/claude"
RPATH=$RSTUB:$RH/.claude/gsd-core/bin:$RH/bin-link:$RH/.local/bin:/usr/bin:/bin
run_probe() {
    local sid=$1 repo=$2
    shift 2
    HOME=$RH PATH=$RPATH XDG_CONFIG_HOME=$RH/.config probe run "$repo" --session-id "$sid" --config-dir "$RCFG" \
        --debug-file "$WORK/run-debug-$sid.log" "$@" -- hi
}

RSID=11111111-2222-4333-8444-555555555555
out=$(run_probe "$RSID" "$RREPO" 2>&1); rc=$?
child_home=$(sed -n 's/^HOME=//p' "$WORK/run-env.txt")
child_path=$(sed -n 's/^PATH=//p' "$WORK/run-env.txt")
if [ "$rc" -eq 0 ] && [ "$child_home" = "$WORK/run-scratch/quick/home/$RSID" ] \
        && [ "$(cat "$WORK/run-tripwire.txt")" = absent ] && ! grep -q '^XDG_CONFIG_HOME=' "$WORK/run-env.txt" \
        && grep -qxF "probe HOME: $child_home" <<<"$out"; then
    ok run-hermetic-home
else
    bad run-hermetic-home "rc=$rc home=$child_home: $(tail -n 3 <<<"$out")"
fi

if [ -n "$child_path" ] && [[ ":$child_path:" != *":$RH/.claude/"* && ":$child_path:" != *":$RH/bin-link:"* \
        && ":$child_path:" != *":$RH/.local/bin:"* && ":$child_path:" == *":$RSTUB:"* ]] \
        && [ "${child_path%%:*}" = "$RCFG/gsd-core/bin" ] && grep -qxF "probe PATH: $child_path" <<<"$out"; then
    ok run-path-strips-live
else
    bad run-path-strips-live "path=$child_path"
fi

# The config directory's home-relative names, as repoint writes them, still
# resolve under the hermetic home.
if [ "$(cat "$WORK/run-marker.txt")" = reached ]; then ok run-config-dir-resolves-from-home; else bad run-config-dir-resolves-from-home "$(cat "$WORK/run-marker.txt")"; fi

if [ "$(cat "$WORK/run-git.txt")" = 'Probe Author' ]; then ok run-git-identity; else bad run-git-identity "$(cat "$WORK/run-git.txt")"; fi

out=$(PROBE_TRIP=1 run_probe 22222222-2222-4333-8444-555555555555 "$RREPO" 2>&1); rc=$?
if [ "$rc" -eq 5 ] && grep -q '^tripwire: ' <<<"$out" && grep -qF '.claude/touched' <<<"$out"; then
    ok run-tripwire-trips
else
    bad run-tripwire-trips "rc=$rc: $(tail -n 3 <<<"$out")"
fi

# Claude Code reads CLAUDE.md under .claude in every directory above the
# session; a repository under a home whose .claude is the live root is refused.
mkdir -p "$RH/probe/repo"
out=$(run_probe 33333333-2222-4333-8444-555555555555 "$RH/probe/repo" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q "lies under $RH, whose .claude is the live config root" <<<"$out" \
        && [ ! -e "$RH/probe/home" ]; then
    ok run-refuses-repo-under-live-home
else
    bad run-refuses-repo-under-live-home "rc=$rc: $out"
fi

# With a config directory, a mod loaded from the live root is refused.
mkdir -p "$RH/.claude/mods/m"
out=$(run_probe 44444444-2222-4333-8444-555555555555 "$RREPO" --plugin-dir "$RH/.claude/mods/m" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'refusing --plugin-dir' <<<"$out"; then ok run-refuses-live-plugin-dir; else bad run-refuses-live-plugin-dir "rc=$rc: $out"; fi

printf '\nplanning directory\n'

# Real code from the live install, read only and moved under the stand-in home
# RH (whose live root is RH/.claude): the identity script, the git-exclusion
# script, and the session-start planning hook with the live root's name
# replaced by RH/.claude. The cases run the hook as SessionStart would. No
# Claude Code session starts; the stand-in claude plays every run.
for rel in scripts/project-identity.js scripts/git-exclusion.js hooks/gsd-planning-symlinks.js; do
    [ -f "$LIVE/$rel" ] || bad planning-fixture "the live install lacks $rel"
done
mkdir -p "$RH/.claude/scripts" "$RH/.claude/projects"
cp "$LIVE/scripts/project-identity.js" "$LIVE/scripts/git-exclusion.js" "$RH/.claude/scripts/"
PL_HOOK=hooks/gsd-planning-symlinks.js
PCFG=$RH/.cache/dsmr-routing-probes/hookcfg
mkdir -p "$PCFG/hooks"
printf 'built\n' > "$PCFG/.routing-probe-config"
FROM_ROOT=$LIVE TO_ROOT=$RH/.claude perl -pe 's{\Q$ENV{FROM_ROOT}\E}{$ENV{TO_ROOT}}g' "$LIVE/$PL_HOOK" > "$PCFG/$PL_HOOK"

# Each case runs with HOME at the stand-in, no XDG_CACHE_HOME and no
# CLAUDE_CONFIG_DIR, so none can reach the caller's real cache.
PL_ROOT=$WORK/plan-scratch
mkdir -p "$PL_ROOT"
PL_ROOT=$(cd "$PL_ROOT" && pwd -P)
pl_env() {
    env -u CLAUDE_CONFIG_DIR -u XDG_CACHE_HOME HOME="$RH" PATH="$RPATH" XDG_CONFIG_HOME="$RH/.config" \
        GIT_AUTHOR_NAME='Probe Author' GIT_AUTHOR_EMAIL=probe@example.invalid \
        GIT_COMMITTER_NAME='Probe Author' GIT_COMMITTER_EMAIL=probe@example.invalid "$@"
}
pl_probe() { pl_env bash "$PROBE" "$@"; }
pl_run() {
    local repo=$1 sid=$2
    shift 2
    pl_probe run "$repo" --session-id "$sid" --debug-file "$WORK/run-debug-$sid.log" "$@" -- hi
}
# pl_planning_dir REPO: the planning directory the live identity script
# computes for REPO under the stand-in home with no XDG_CACHE_HOME.
pl_planning_dir() {
    pl_env node -e '
        const id = require(process.argv[1]).resolveProjectIdentity(process.argv[2]);
        process.stdout.write(id.planningDir);' "$RH/.claude/scripts/project-identity.js" "$1"
}

# A config directory whose hook requires scripts under itself, as an earlier
# repoint left the real one, with none of them present.
PCFG2=$RH/.cache/dsmr-routing-probes/hookcfg2
mkdir -p "$PCFG2/hooks"
printf 'built\n' > "$PCFG2/.routing-probe-config"
FROM_ROOT=$RH/.claude/scripts/ TO_ROOT=$PCFG2/scripts/ perl -pe 's{\Q$ENV{FROM_ROOT}\E}{$ENV{TO_ROOT}}g' "$PCFG/$PL_HOOK" > "$PCFG2/$PL_HOOK"
out=$(pl_probe check-config "$PCFG2" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -qxF 'hook requires a missing script scripts/project-identity.js' <<<"$out" \
        && grep -qxF 'hook requires a missing script scripts/git-exclusion.js' <<<"$out"; then
    ok check-config-flags-missing-hook-script
else
    bad check-config-flags-missing-hook-script "rc=$rc: $(tail -n 4 <<<"$out")"
fi

out=$(pl_probe repoint "$PCFG" 2>&1); rc=$?
out2=$(pl_probe repoint "$PCFG" 2>&1)
reqs=$(grep -oE "require\('[^']+'\)" "$PCFG/$PL_HOOK" | sed "s/^require('//; s/')\$//" | grep '^/')
missing=""
for r in $reqs; do [ -f "$r" ] || missing+=" $r"; done
if [ "$rc" -eq 0 ] && [ -n "$reqs" ] && [ -z "$missing" ] && ! grep -qvF "$PCFG/scripts/" <<<"$reqs" \
        && grep -qxF 'copied scripts/project-identity.js (a copied hook requires it)' <<<"$out" \
        && grep -qxF 'copied scripts/git-exclusion.js (a copied hook requires it)' <<<"$out" \
        && ! grep -q '^copied ' <<<"$out2"; then
    ok repoint-copies-hook-scripts
else
    bad repoint-copies-hook-scripts "rc=$rc missing:$missing: $(tail -n 4 <<<"$out")"
fi

# A repository made under the stand-in home keeps its planning directory
# beside it, and nothing appears in the stand-in home's cache.
PREPO=$PL_ROOT/repo
out=$(pl_probe make-repo "$PREPO" --gsd-core global --shapes shell 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -L "$PREPO/.planning" ] \
        && [[ "$(readlink "$PREPO/.planning")" == "$PREPO.cache/opencode/projects/"*"/planning" ]] \
        && grep -qF "planning directory linked to $PREPO.cache/opencode/projects/" <<<"$out" \
        && [ ! -e "$RH/.cache/opencode" ]; then
    ok make-repo-planning-in-scratch
else
    bad make-repo-planning-in-scratch "rc=$rc link=$(readlink "$PREPO/.planning"): $(tail -n 3 <<<"$out")"
fi

# The session's hook computes the planning directory make-repo linked, so it
# reports it already linked instead of relinking .planning to an empty bucket.
PSID=aaaaaaaa-2222-4333-8444-555555555555
rm -f "$WORK/run-env.txt" "$WORK/run-hook.txt"
out=$(pl_run "$PREPO" "$PSID" --config-dir "$PCFG" --env PROBE_HOOK=1 2>&1); rc=$?
action=$(jq -r '.hookSpecificOutput.planningSymlinks.action // "-"' "$WORK/run-hook.txt" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$action" = already_linked ] \
        && [ "$(sed -n 's/^XDG_CACHE_HOME=//p' "$WORK/run-env.txt")" = "$PREPO.cache" ] \
        && [[ "$(realpath -m "$PREPO/.planning")" == "$PREPO.cache/"* ]] \
        && [ ! -e "$RH/.cache/opencode" ] && [ ! -e "$PL_ROOT/home/$PSID/.cache/opencode" ]; then
    ok run-planning-bucket-in-scratch
else
    bad run-planning-bucket-in-scratch "rc=$rc action=$action cache=$(sed -n 's/^XDG_CACHE_HOME=//p' "$WORK/run-env.txt"): $(tail -n 3 <<<"$out")"
fi

rm -f "$WORK/run-env.txt"
out=$(pl_run "$PREPO" bbbbbbbb-2222-4333-8444-555555555555 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(sed -n 's/^XDG_CACHE_HOME=//p' "$WORK/run-env.txt")" = "$PREPO.cache" ] \
        && [ ! -e "$RH/.cache/opencode" ]; then
    ok run-live-planning-in-scratch
else
    bad run-live-planning-in-scratch "rc=$rc cache=$(sed -n 's/^XDG_CACHE_HOME=//p' "$WORK/run-env.txt"): $(tail -n 3 <<<"$out")"
fi

# A repository whose .planning links into the caller's cache, as make-repo
# built it before, is refused before a home exists or claude starts.
OREPO=$PL_ROOT/outside/repo
mkdir -p "$OREPO"
git -C "$OREPO" init -q
ocache_plan=$(pl_planning_dir "$OREPO")
mkdir -p "$ocache_plan"
ln -s "$ocache_plan" "$OREPO/.planning"
rm -f "$WORK/run-env.txt"
out=$(pl_run "$OREPO" cccccccc-2222-4333-8444-555555555555 --config-dir "$PCFG" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'make-repo' <<<"$out" && [ ! -e "$WORK/run-env.txt" ] && [ ! -e "$PL_ROOT/outside/home" ]; then
    ok run-refuses-planning-outside-scratch
else
    bad run-refuses-planning-outside-scratch "rc=$rc env=$([ -e "$WORK/run-env.txt" ] && echo ran || echo absent): $(tail -n 3 <<<"$out")"
fi

# A session that creates the caller-cache bucket for its repository trips the wire.
caller_bucket=$(dirname "$(pl_planning_dir "$PREPO")")
out=$(pl_run "$PREPO" dddddddd-2222-4333-8444-555555555555 --config-dir "$PCFG" --env "PROBE_MKDIR=$caller_bucket" 2>&1); rc=$?
if [ "$rc" -eq 5 ] && grep '^tripwire: ' <<<"$out" | grep -qF "$caller_bucket"; then
    ok run-planning-tripwire-trips
else
    bad run-planning-tripwire-trips "rc=$rc: $(tail -n 3 <<<"$out")"
fi

printf '\nlinks on the path\n'

# repoint restores an installer file through nothing but a plain path: a
# directory link inside the config directory leads outside it, and the file
# behind the link keeps its bytes. The file is the live installer's own, with
# the config-root rewrite an earlier repoint applied.
LNK_LIB=$(grep -lF "$TILDE/.claude/" "$LIVE/gsd-core/bin/lib/"*.cjs | head -n 1)
LNK_LIB_REL=${LNK_LIB#"$LIVE"/}
LNK=$WORK/link-config
LNK_OUT=$WORK/link-outside/lib
mkdir -p "$LNK/gsd-core/bin" "$LNK_OUT"
printf 'built\n' > "$LNK/.routing-probe-config"
jq -n --arg k "$LNK_LIB_REL" --arg h "$(jq -r --arg k "$LNK_LIB_REL" '.files[$k]' "$LIVE/gsd-file-manifest.json")" \
    '{version: "recorded", files: {($k): $h}}' > "$LNK/gsd-file-manifest.json"
ln -s "$LNK_OUT" "$LNK/gsd-core/bin/lib"
LNK_REL=$(realpath -m --relative-to="$HOME" "$LNK")
perl -pe "s{~/\\.claude(?![\\w-])}{~/$LNK_REL}g; s{\\\$HOME/\\.claude(?![\\w-])}{\\\$HOME/$LNK_REL}g" "$LNK_LIB" > "$LNK_OUT/${LNK_LIB##*/}"
behind_before=$(sha256sum < "$LNK_OUT/${LNK_LIB##*/}")
out=$(probe repoint "$LNK" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -qF 'gsd-core/bin/lib' <<<"$out" && ! grep -q '^restored ' <<<"$out" \
        && [ "$(sha256sum < "$LNK_OUT/${LNK_LIB##*/}")" = "$behind_before" ] && ! cmp -s "$LNK_LIB" "$LNK_OUT/${LNK_LIB##*/}"; then
    ok repoint-refuses-linked-directory
else
    bad repoint-refuses-linked-directory "rc=$rc: $(tail -n 3 <<<"$out")"
fi

# Claude Code walks the physical ancestors of its working directory, so a
# repository reached through a link under the live home is refused, with no
# home created behind the link.
mkdir -p "$RH/under/repo"
git -C "$RH/under/repo" init -q
ln -s "$RH/under" "$WORK/under-link"
rm -f "$WORK/run-env.txt"
out=$(run_probe 55555555-2222-4333-8444-555555555555 "$WORK/under-link/repo" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -q "lies under $RH, whose .claude is the live config root" <<<"$out" \
        && [ ! -e "$RH/under/home" ] && [ ! -e "$WORK/run-env.txt" ]; then
    ok run-refuses-repo-linked-under-live-home
else
    bad run-refuses-repo-linked-under-live-home "rc=$rc env=$([ -e "$WORK/run-env.txt" ] && echo ran || echo absent): $(tail -n 3 <<<"$out")"
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

# --scratch moves the arm's repositories and session homes; each session with a
# config directory runs under its own home there.
run_arm scr --scratch "$WORK/scr"; rc=$?
if [ "$rc" -eq 0 ] && [ -d "$WORK/scr/scr/quick/repo" ] && [ ! -e "$WORK/cache-scr/dsmr-routing-probes/scr" ] \
        && grep -q "^probe HOME: $WORK/scr/scr/home/[0-9a-f-]*\$" "$WORK/ev-scr/probe-quick-shell.err"; then
    ok run-arm-scratch-and-session-home
else
    bad run-arm-scratch-and-session-home "rc=$rc: $(tail -n 3 "$WORK/arm-scr.out")"
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
