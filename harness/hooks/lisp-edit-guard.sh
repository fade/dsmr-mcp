#!/bin/sh
# PreToolUse hook: deny Edit, Write, MultiEdit, and NotebookEdit on Lisp source.
#
# Lisp source (*.lisp, *.asd, *.lsp, *.cl) is edited through the dsmr-mcp
# structure tools, which lisp-developer drives. Reads the hook input from stdin
# and checks the spelled path and the path with symlinks resolved. Denies with
# exit 0 and a permissionDecision JSON on stdout; allows with no output.
# Fails open: input that is not JSON, a missing jq, or an absent path allows.
#
# Install: copy to ~/.claude/hooks/ (make install-harness), then add to the
# PreToolUse list in ~/.claude/settings.json:
#   {"matcher": "Write|Edit|MultiEdit|NotebookEdit",
#    "hooks": [{"type": "command", "command": "sh ~/.claude/hooks/lisp-edit-guard.sh"}]}
set -eu

command -v jq >/dev/null 2>&1 || exit 0

in=$(cat) || exit 0
fields=$(printf '%s' "$in" | jq -r '[.tool_name // "", .tool_input.file_path // .tool_input.notebook_path // "", .cwd // ""] | @tsv' 2>/dev/null) || exit 0
[ -n "$fields" ] || exit 0

tool=$(printf '%s' "$fields" | cut -f1)
path=$(printf '%s' "$fields" | cut -f2)
cwd=$(printf '%s' "$fields" | cut -f3)

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
    *.lisp | *.asd | *.lsp | *.cl) return 0 ;;
  esac
  return 1
}

# realpath -m resolves symlinks in the existing part and keeps a missing tail.
real=$(realpath -m -- "$path" 2>/dev/null) || real=$path

if is_lisp "$path" || is_lisp "$real"; then
  reason="Plain $tool of Lisp source is refused: $real. Spawn lisp-developer to make this change with the dsmr-mcp structure tools (lisp-edit-form, lisp-patch-form, fs-write-file for a new file). Do not route around this with Bash, sed, or a redirect."
  jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
fi
exit 0
