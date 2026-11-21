#!/usr/bin/env bash
# Drives harness/hooks/lisp-edit-guard.sh with recorded PreToolUse input
# (tests/harness/fixtures/pretooluse, provenance in SOURCE).
#
# Every case checks the guard's output and its exit status, which must be 0.
# Each deny case also runs against a guard that allows everything and must
# fail there; each allow case runs against a guard that denies everything and
# must fail there. Guards that exit 2, or print deny and then exit 1, must
# fail every case. A case that passes both ways proves nothing.
set -eu -o pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
guard="$root/harness/hooks/lisp-edit-guard.sh"
fx="$root/tests/harness/fixtures/pretooluse"
# The scratchpad exemption follows the temp root; start from none set.
unset TMPDIR TMP TEMP CLAUDE_CODE_TMPDIR
tmp=$(mktemp -d)
# With no temp variable set, the root is /tmp.
claude_tmp=$(mktemp -d /tmp/claude-guardtest.XXXXXX)
trap 'rm -rf "$tmp" "$claude_tmp"' EXIT

cat >"$tmp/allow-all.sh" <<'STUB'
#!/bin/sh
cat >/dev/null
STUB
cat >"$tmp/deny-all.sh" <<'STUB'
#!/bin/sh
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub"}}'
STUB

cat >"$tmp/exit2.sh" <<'STUB'
#!/bin/sh
cat >/dev/null
exit 2
STUB
cat >"$tmp/deny-exit1.sh" <<'STUB'
#!/bin/sh
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub"}}'
exit 1
STUB

pass=0 fail=0 controls=0

# decision GUARD INPUT: prints deny or allow, or "exit N" when the guard exits non-zero.
decision() {
  local out rc=0
  out=$(sh "$1" <"$2") || rc=$?
  if [ "$rc" -ne 0 ]; then echo "exit $rc"
  elif [ -z "$out" ]; then echo allow
  else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}

# expect NAME WANT INPUT: the guard answers WANT, and the opposite stub does not.
expect() {
  local name=$1 want=$2 input=$3 got stub
  got=$(decision "$guard" "$input")
  if [ "$want" = deny ]; then stub=$tmp/allow-all.sh; else stub=$tmp/deny-all.sh; fi
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL $name: want $want, got $got" >&2; fi
  if [ "$(decision "$stub" "$input")" != "$want" ]; then controls=$((controls + 1)); else
    fail=$((fail + 1)); echo "FAIL $name: control also answered $want" >&2; fi
  for stub in "$tmp/exit2.sh" "$tmp/deny-exit1.sh"; do
    if [ "$(decision "$stub" "$input")" != "$want" ]; then controls=$((controls + 1)); else
      fail=$((fail + 1)); echo "FAIL $name: $(basename "$stub") control still answered $want" >&2; fi
  done
}

# variant NAME JQ-FILTER FIXTURE (a fixture name or an absolute path): writes a changed copy of a fixture to $tmp/NAME.json.
variant() { case "$3" in /*) jq "$2" "$3" ;; *) jq "$2" "$fx/$3" ;; esac >"$tmp/$1.json"; }

# Recorded input. The recordings were made in a session scratchpad, which the
# guard allows, so the deny cases move the recorded path to a project directory
# and keep every other recorded field.
moved() { variant "$1" '.tool_input.file_path |= "/home/x/proj/" + (split("/") | last) | .cwd = "/home/x/proj"' "$2"; }
moved m-new Write-new.lisp.json
moved m-edit Edit-existing.lisp.json
moved m-asd Write-rel.asd.json
moved m-txt Write-out.txt.json
expect "recorded Write new.lisp, in a project" deny "$tmp/m-new.json"
expect "recorded Edit existing.lisp, in a project" deny "$tmp/m-edit.json"
expect "recorded Write rel.asd, in a project" deny "$tmp/m-asd.json"
expect "recorded Write out.txt, in a project" allow "$tmp/m-txt.json"
expect "recorded Write new.lisp, in the session scratchpad" allow "$fx/Write-new.lisp.json"
expect "recorded Edit existing.lisp, in the session scratchpad" allow "$fx/Edit-existing.lisp.json"
variant relative '.tool_input.file_path = "work/rel.asd" | .cwd = "/home/x/proj"' Write-rel.asd.json
expect "derived relative path resolved against cwd" deny "$tmp/relative.json"

# The recorded symlink case needs its link to exist: point the recorded
# tool_input at a link made here, keeping the rest of the recorded input.
echo '(defun f () 1)' >"$tmp/target.lisp"
ln -s target.lisp "$tmp/alias.txt"
variant symlink ".tool_input.file_path = \"$tmp/alias.txt\"" Write-alias.txt.json
expect "Write through a symlink to .lisp" deny "$tmp/symlink.json"
echo plain >"$tmp/plain.txt"
ln -s plain.txt "$tmp/alias.lisp"
variant lispname ".tool_input.file_path = \"$tmp/alias.lisp\"" Write-alias.txt.json
expect "Write to a .lisp name that links to text" deny "$tmp/lispname.json"

# Extensions, derived from the recorded Write by changing the path.
for p in /p/a.asd /p/A.LISP /p/a.lsp /p/a.cl /p/dir.lisp/inner.txt-not /p/notes.lisp.bak /p/lisp /p/a.lispx; do
  variant ext ".tool_input.file_path = \"$p\"" Write-new.lisp.json
  case "$p" in
    /p/a.asd | /p/A.LISP) want=deny ;;
    *) want=allow ;;
  esac
  expect "extension $p" "$want" "$tmp/ext.json"
done

# Session scratchpad: allowed, while a project file beside it is still denied.
mkdir -p "$claude_tmp/s1/scratchpad" "$claude_tmp/s1/project"
variant scratch ".tool_input.file_path = \"$claude_tmp/s1/scratchpad/probe.lisp\"" Write-new.lisp.json
expect "scratchpad .lisp allowed" allow "$tmp/scratch.json"
variant project ".tool_input.file_path = \"$claude_tmp/s1/project/probe.lisp\"" Write-new.lisp.json
expect "project .lisp beside the scratchpad denied" deny "$tmp/project.json"
ln -s ../project/probe.lisp "$claude_tmp/s1/scratchpad/link.lisp"
variant scratchlink ".tool_input.file_path = \"$claude_tmp/s1/scratchpad/link.lisp\"" Write-new.lisp.json
expect "scratchpad link to project .lisp denied" deny "$tmp/scratchlink.json"
variant dotdot ".tool_input.file_path = \"$claude_tmp/s1/scratchpad/../project/probe.lisp\"" Write-new.lisp.json
expect "scratchpad path leaving by .. denied" deny "$tmp/dotdot.json"
# A temp root named by TMPDIR (then CLAUDE_CODE_TMPDIR, which wins) moves the exemption.
mkdir -p "$tmp/root/claude-1000/s/scratchpad" "$tmp/root2/claude-1000/s/scratchpad"
variant intmp ".tool_input.file_path = \"$tmp/root/claude-1000/s/scratchpad/probe.lisp\"" "$tmp/m-new.json"
variant inroot2 ".tool_input.file_path = \"$tmp/root2/claude-1000/s/scratchpad/probe.lisp\"" "$tmp/m-new.json"
expect "TMPDIR unset: a scratchpad under another root denied" deny "$tmp/intmp.json"
export TMPDIR="$tmp/root"
expect "TMPDIR set: its scratchpad allowed" allow "$tmp/intmp.json"
expect "TMPDIR set: the /tmp scratchpad shape denied" deny "$tmp/scratch.json"
expect "TMPDIR set: a project .lisp still denied" deny "$tmp/project.json"
export CLAUDE_CODE_TMPDIR="$tmp/root2"
expect "CLAUDE_CODE_TMPDIR wins: its scratchpad allowed" allow "$tmp/inroot2.json"
expect "CLAUDE_CODE_TMPDIR wins: the TMPDIR scratchpad denied" deny "$tmp/intmp.json"
unset TMPDIR CLAUDE_CODE_TMPDIR
expect "temp variables unset again: the /tmp scratchpad allowed" allow "$tmp/scratch.json"

variant notmp '.tool_input.file_path = "/home/x/scratchpad/probe.lisp"' Write-new.lisp.json
expect "scratchpad outside any temp root denied" deny "$tmp/notmp.json"

# A path ending in a newline still matches its extension.
variant newline '.tool_input.file_path = "/p/a.lisp\n"' Write-new.lisp.json
expect "path ending in a newline denied" deny "$tmp/newline.json"

# Tools with no capture: derived from a recorded Write (named in SOURCE).
variant multiedit '.tool_name = "MultiEdit"' "$tmp/m-new.json"
expect "derived MultiEdit on .lisp" deny "$tmp/multiedit.json"
variant notebook '.tool_name = "NotebookEdit" | .tool_input = {notebook_path: "/p/x.lisp", new_source: "x"}' "$tmp/m-new.json"
expect "derived NotebookEdit on .lisp" deny "$tmp/notebook.json"
variant bash '.tool_name = "Bash" | .tool_input = {command: "echo > /p/a.lisp"}' "$tmp/m-new.json"
expect "derived Bash is not this guard's" allow "$tmp/bash.json"

# Fail open: input the guard cannot use allows.
printf 'not json' >"$tmp/garbage.json"
: >"$tmp/empty.json"
printf '{"tool_name":"Write"}' >"$tmp/nopath.json"
for g in garbage empty nopath; do
  got=$(decision "$guard" "$tmp/$g.json")
  if [ "$got" = allow ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL fail-open $g: want allow, got $got" >&2; fi
done

# The reason names the cause and the one action.
reason=$(sh "$guard" <"$tmp/m-new.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason" in
  *"lisp-edit-form"*"lisp-patch-form"*"fs-write-file"*"lisp-developer"*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); echo "FAIL reason text: $reason" >&2 ;;
esac

echo "lisp-edit-guard: $pass passed, $fail failed, $controls red controls"
[ "$fail" -eq 0 ]
