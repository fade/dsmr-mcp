#!/usr/bin/env bash
# Status line for every Claude Code session on this host.
#
# It answers, at a glance, the question that is expensive to get wrong: WHICH
# session am I typing into. A session that does not say whether it leads or
# works is how a message meant for one agent reaches another.
#
# The role is DERIVED, never hardcoded. An earlier version of this file lived
# inside one repository and asserted LEADER unconditionally, so it was both
# unreachable from any other repository and wrong if it ever got there.
#
# Order matters: the role tag and the context meter sit left of the repo and
# branch, because narrow terminals truncate the right-hand end and those two
# are what needs to be readable at a glance.

input=$(cat)

cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // "."')
repo=$(basename "$cwd")

branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
[ -z "$branch" ] && branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
[ -z "$branch" ] && branch="no-branch"

model=$(printf '%s' "$input" | jq -r '.model.display_name // "?"')

# ---------------------------------------------------------------------------
# Role. The coordination bus records which agent leads each bus, as an id of
# the form <project-root>/<agent-name>. The directory part of that id is the
# leading repository, so comparing it against this session's directory settles
# the role without needing anything configured per repository.
#
# An indeterminate answer is shown as its own state rather than defaulting to
# WORKER: silently labelling an unknown session is the failure this exists to
# prevent, and a wrong label is worse than an honest blank.
# ---------------------------------------------------------------------------
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp/bus"
selector="${DSMR_BUS_SELECTOR:-}"

roster=""
if [ -n "$selector" ] && [ -f "$state_root/$selector/roster.state" ]; then
  roster="$state_root/$selector/roster.state"
elif [ -f "$state_root/roster.state" ]; then
  roster="$state_root/roster.state"
fi

role="unknown"
if [ -n "$roster" ]; then
  # :LEADER "<project-root>/<agent>" -- take the quoted value after :LEADER.
  leader_id=$(sed -n 's/.*:LEADER[[:space:]]*"\([^"]*\)".*/\1/p' "$roster" 2>/dev/null)
  if [ -n "$leader_id" ]; then
    leader_dir="${leader_id%/*}"
    # Compare with trailing slashes normalised, so a stored root ending in a
    # separator matches a cwd that does not, and vice versa.
    if [ "${leader_dir%/}" = "${cwd%/}" ]; then role="leader"; else role="worker"; fi
  fi
fi

case "$role" in
  leader) tag=$(printf '\033[1;97;41m \xe2\x9a\x91 LEADER \033[0m') ;;
  worker) tag=$(printf '\033[1;97;44m \xe2\x9a\x91 WORKER \033[0m') ;;
  *)      tag=$(printf '\033[1;97;100m \xe2\x9a\x91 AGENT  \033[0m') ;;
esac

# ---------------------------------------------------------------------------
# Context usage. The pre-computed percentage is authoritative when present, but
# it is null early in a session and after /compact, so fall back to summing the
# usage fields before giving up.
# ---------------------------------------------------------------------------
used=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' | cut -d. -f1)

if [ -z "$used" ]; then
  win=$(printf '%s' "$input" | jq -r '.context_window.context_window_size // empty')
  tin=$(printf '%s' "$input" | jq -r '
        (.context_window.current_usage.input_tokens // 0)
      + (.context_window.current_usage.cache_creation_input_tokens // 0)
      + (.context_window.current_usage.cache_read_input_tokens // 0)' 2>/dev/null)
  if [ -n "$win" ] && [ "$win" -gt 0 ] 2>/dev/null && [ -n "$tin" ] && [ "$tin" -gt 0 ] 2>/dev/null; then
    used=$(( tin * 100 / win ))
  fi
fi

if [ -n "$used" ] && [ "$used" -ge 0 ] 2>/dev/null; then
  [ "$used" -gt 100 ] && used=100

  # Glyph escalates with pressure. A number alone is easy to skim past; the
  # skull is the one that makes an operator look.
  if   [ "$used" -ge 85 ]; then glyph='💀'; colour='\033[1;31m'
  elif [ "$used" -ge 70 ]; then glyph='⚠';  colour='\033[1;33m'
  else                          glyph='◆';  colour='\033[1;32m'
  fi

  width=10
  filled=$(( used * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  empty=$(( width - filled ))

  bar=""
  i=0; while [ "$i" -lt "$filled" ]; do bar="${bar}█"; i=$((i+1)); done
  i=0; while [ "$i" -lt "$empty" ];  do bar="${bar}░"; i=$((i+1)); done

  meter=$(printf '%s %b%s\033[0m %s%%' "$glyph" "$colour" "$bar" "$used")
else
  # No reading yet rather than a fake zero: an empty meter that reads as 0%
  # would say "plenty of room" at exactly the moment nothing is known.
  meter=$(printf '\033[2m◇ ░░░░░░░░░░  --%%\033[0m')
fi

printf '%b \033[1m%s\033[0m %b \033[1;36m%s\033[0m \033[2m/\033[0m \033[33m%s\033[0m\n' \
  "$tag" "$model" "$meter" "$repo" "$branch"
