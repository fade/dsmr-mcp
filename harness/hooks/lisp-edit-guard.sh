#!/bin/sh
# PreToolUse hook: deny Edit, Write, MultiEdit, and NotebookEdit on Lisp source.
#
# Lisp source (*.lisp, *.asd) is edited through the dsmr-mcp structure tools,
# which lisp-developer drives. Reads the hook input from stdin and checks the
# spelled path and the path with symlinks resolved. Denies with exit 0 and a
# permissionDecision JSON on stdout; allows with no output. A file under a
# `scratchpad` directory of <temp root>/claude-*/ (the session scratchpad,
# resolved) is allowed. The temp root is CLAUDE_CODE_TMPDIR, else TMPDIR, TMP,
# or TEMP, else /tmp, the order Claude Code and Node's os.tmpdir() use. Fails open: when the input is not JSON, jq is missing,
# or the input names no path, the call is allowed.
#
# Install: copy to ~/.claude/hooks/ (make install-harness), then add to the
# PreToolUse list in ~/.claude/settings.json:
#   {"matcher": "Write|Edit|MultiEdit|NotebookEdit",
#    "hooks": [{"type": "command", "command": "sh ~/.claude/hooks/lisp-edit-guard.sh"}]}
set -eu

command -v jq >/dev/null 2>&1 || exit 0

in=$(cat) || exit 0
# Separate jq calls: $(...) drops trailing newlines, so a path ending in a
# newline is checked without it and still matches its extension.
tool=$(printf '%s' "$in" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
path=$(printf '%s' "$in" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || exit 0
cwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null) || exit 0

case "$tool" in
  Edit | Write | MultiEdit | NotebookEdit) ;;
  *) exit 0 ;;
esac
[ -n "$path" ] || exit 0

case "$path" in
  /*) ;;
  *) path="${cwd:-.}/$path" ;;
esac

is_lisp() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *.lisp | *.asd) return 0 ;;
  esac
  return 1
}

# realpath -m resolves symlinks in the existing part and keeps a missing tail.
real=$(realpath -m -- "$path" 2>/dev/null) || real=$path

root=${CLAUDE_CODE_TMPDIR:-${TMPDIR:-${TMP:-${TEMP:-/tmp}}}}
root=$(realpath -m -- "$root" 2>/dev/null) || root=
case "$real" in
  */.. | */../*) ;; # unresolved: realpath failed, so no exemption
  *)
    if [ -n "$root" ] && [ "$root" != / ]; then
      case "$real" in
        "$root"/claude-*/scratchpad/*) exit 0 ;;
      esac
    fi
    ;;
esac

if is_lisp "$path" || is_lisp "$real"; then
  reason="Plain $tool of Lisp source is refused: $real. Retry with the dsmr-mcp tools lisp-edit-form, lisp-patch-form, or fs-write-file (a new file); a session without them spawns lisp-developer."
  jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
fi
exit 0
