#!/usr/bin/env bash
# Drives harness/hooks/lisp-edit-guard.sh with recorded PreToolUse input
# (tests/harness/fixtures/pretooluse, provenance in SOURCE).
#
# Each deny case also runs against a guard that allows everything and must
# fail there; each allow case runs against a guard that denies everything and
# must fail there. A case that passes both ways proves nothing.
set -eu -o pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
guard="$root/harness/hooks/lisp-edit-guard.sh"
fx="$root/tests/harness/fixtures/pretooluse"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/allow-all.sh" <<'STUB'
#!/bin/sh
cat >/dev/null
STUB
cat >"$tmp/deny-all.sh" <<'STUB'
#!/bin/sh
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub"}}'
STUB

pass=0 fail=0 controls=0

# decision GUARD INPUT: prints deny or allow.
decision() {
  local out
  out=$(sh "$1" <"$2")
  if [ -z "$out" ]; then echo allow
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
}

# variant NAME JQ-FILTER FIXTURE: writes a changed copy of a fixture to $tmp/NAME.json.
variant() { jq "$2" "$fx/$3" >"$tmp/$1.json"; }

# Recorded input.
expect "recorded Write new.lisp" deny "$fx/Write-new.lisp.json"
expect "recorded Edit existing.lisp" deny "$fx/Edit-existing.lisp.json"
expect "recorded Write relative work/rel.asd" deny "$fx/Write-rel.asd.json"
expect "recorded Write out.txt" allow "$fx/Write-out.txt.json"

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
for p in /p/a.asd /p/a.lsp /p/a.cl /p/A.LISP /p/dir.lisp/inner.txt-not /p/notes.lisp.bak /p/lisp /p/a.lispx; do
  variant ext ".tool_input.file_path = \"$p\"" Write-new.lisp.json
  case "$p" in
    /p/a.asd | /p/a.lsp | /p/a.cl | /p/A.LISP) want=deny ;;
    *) want=allow ;;
  esac
  expect "extension $p" "$want" "$tmp/ext.json"
done

# Tools with no capture: derived from a recorded Write (named in SOURCE).
variant multiedit '.tool_name = "MultiEdit"' Write-new.lisp.json
expect "derived MultiEdit on .lisp" deny "$tmp/multiedit.json"
variant notebook '.tool_name = "NotebookEdit" | .tool_input = {notebook_path: "/p/x.lisp", new_source: "x"}' Write-new.lisp.json
expect "derived NotebookEdit on .lisp" deny "$tmp/notebook.json"
variant bash '.tool_name = "Bash" | .tool_input = {command: "echo > /p/a.lisp"}' Write-new.lisp.json
expect "derived Bash is not this guard's" allow "$tmp/bash.json"

# Fail open: input the guard cannot use allows.
printf 'not json' >"$tmp/garbage.json"
: >"$tmp/empty.json"
printf '{"tool_name":"Write"}' >"$tmp/nopath.json"
for g in garbage empty nopath; do
  if [ "$(decision "$guard" "$tmp/$g.json")" = allow ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL fail-open $g" >&2; fi
done

# The reason names the cause and the one action.
reason=$(sh "$guard" <"$fx/Write-new.lisp.json" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case "$reason" in
  *"lisp-developer"*"lisp-edit-form"*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); echo "FAIL reason text: $reason" >&2 ;;
esac

echo "lisp-edit-guard: $pass passed, $fail failed, $controls red controls"
[ "$fail" -eq 0 ]
