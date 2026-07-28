#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/bus-inspect.sh - read the on-disk state of a coordination bus.
#
# Every question this answers can be answered by hand, and answering them by hand
# is how the roster's duplicate-id defect was created: a namespace already ends in
# a separator, so composing an id by hand tended to leave two. One separator is
# the correct form. This composes it for you and decodes the percent-encoded
# filenames rather than asking you to read them.
#
# Read-only. It never writes, publishes, enrolls or deletes.
set -u

BUSROOT_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/dsmr-mcp/bus"

usage() {
  cat >&2 <<'EOF'
Usage:
  bus-inspect.sh [BUS]              inspect a bus (omit BUS for the shared one)
  bus-inspect.sh --id PATH NAME     print the canonical agent id for a repo
  bus-inspect.sh --list             list every bus on this host

Examples:
  bus-inspect.sh scratch1
  bus-inspect.sh --id /home/fade/SourceCode/lisp/parachute parachute
EOF
  exit 2
}

# Percent-decode a bus filename back to the id it encodes.
decode() { printf '%b' "${1//%/\\x}"; }

# The canonical id: namespace WITH its trailing slash, then a separator, then the
# name. The doubled slash is correct and is the part people get wrong by hand.
compose_id() {
  local root="$1" name="$2" ns
  ns="$(cd "$root" 2>/dev/null && pwd -P)" || { echo "no such directory: $root" >&2; exit 1; }
  printf '%s//%s\n' "$ns" "$name"
}

list_buses() {
  echo "shared (unnamed)  $BUSROOT_BASE"
  local d
  for d in "$BUSROOT_BASE"/*/; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      cursors|watch|roster) continue ;;   # bus-owned subdirectories, not buses
    esac
    printf '%-17s %s\n' "$(basename "$d")" "$d"
  done
}

inspect() {
  local bus="${1:-}" root
  if [ -n "$bus" ]; then root="$BUSROOT_BASE/$bus"; else root="$BUSROOT_BASE"; fi
  [ -d "$root" ] || { echo "no such bus: ${bus:-<shared>} ($root)" >&2; exit 1; }

  echo "bus:  ${bus:-default (shared, unnamed)}"
  echo "root: $root"
  echo

  echo "== broker =="
  if [ -e "$root/broker.lock" ] && command -v fuser >/dev/null 2>&1; then
    local holder
    holder="$(fuser "$root/broker.lock" 2>/dev/null | tr -d ' ')"
    if [ -n "$holder" ]; then echo "  serving, pid $holder"; else echo "  lock present, NOT held (no broker running)"; fi
  else
    echo "  no broker.lock"
  fi
  if [ -f "$root/bus.wal" ]; then
    echo "  wal: $(wc -c < "$root/bus.wal") bytes"
  else
    echo "  wal: absent (created on first publish, not at election)"
  fi
  echo

  echo "== roster =="
  if [ -d "$root/roster" ]; then
    local f id status n=0
    for f in "$root/roster"/*.member; do
      [ -e "$f" ] || continue
      n=$((n+1))
      id="$(decode "$(basename "$f" .member)")"
      status="$(grep -aoE ':ENROLLED|:DEPARTED' "$f" | head -1)"
      printf '  %-9s %s\n' "${status:-:UNKNOWN}" "$id"
      case "$id" in
        *//*) echo "           ^ DOUBLED separator: predates the id fix, cannot match this agent's own id" ;;
        *) : ;;
      esac
    done
    [ "$n" -eq 0 ] && echo "  (empty)"
  else
    echo "  (no roster directory)"
  fi
  echo

  echo "== cursors =="
  if [ -d "$root/cursors" ]; then
    local c total=0
    for c in "$root/cursors"/*; do
      [ -e "$c" ] || continue
      total=$((total+1))
      printf '  %-6s %s\n' "$(cat "$c" 2>/dev/null || echo '?')" "$(decode "$(basename "$c")")"
    done
    [ "$total" -eq 0 ] && echo "  (none)"
  else
    echo "  (no cursors directory)"
  fi
  echo

  echo "== armed watches (heartbeats) =="
  if [ -d "$root/watch" ]; then
    local b found=0
    for b in "$root/watch"/*.beat; do
      [ -e "$b" ] || continue
      found=1
      printf '  %s  (beat %ss old)\n' \
        "$(decode "$(basename "$b" .beat)")" \
        "$(( $(date +%s) - $(stat -c %Y "$b") ))"
    done
    [ "$found" -eq 0 ] && echo "  (none armed; a clean exit removes the beat)"
  else
    echo "  (no watch directory; nothing has ever armed here)"
  fi
  echo

  echo "== durable-state hygiene =="
  local bad
  bad="$(grep -alF '#A(' "$root"/roster.state "$root"/roster/*.member 2>/dev/null | wc -l)"
  if [ "$bad" -gt 0 ]; then
    echo "  $bad file(s) persist base-string array literals (#A(...)). Should be plain strings."
  else
    echo "  ok: no base-string array literals in durable state"
  fi
}

case "${1:-}" in
  -h|--help) usage ;;
  --list)    list_buses ;;
  --id)      [ $# -eq 3 ] || usage; compose_id "$2" "$3" ;;
  *)         inspect "${1:-}" ;;
esac
