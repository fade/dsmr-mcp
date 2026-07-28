#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/bus-assign.sh - put repositories on a named coordination bus.
#
# Assigning a repo to a fleet means setting DSMR_BUS_SELECTOR in its .envrc. The
# server can work out that a repo needs that line, but it can only ASK for
# permission to write it through an MCP elicitation, and a client that does not
# declare elicitation capability never shows the prompt. There is no fallback, so
# without this the line arrives by hand, once per repository.
#
# Idempotent: run it twice and the second run reports "already correct".
# Every file is backed up before it is touched. Nothing is written without a diff
# unless you pass --yes.
set -u

TAG=""
APPLY=0
ASSUME_YES=0
REPOS=()

usage() {
  cat >&2 <<'EOF'
Usage:
  bus-assign.sh --tag NAME [--apply] [--yes] REPO [REPO ...]
  bus-assign.sh --clear     [--apply] [--yes] REPO [REPO ...]

  --tag NAME   set DSMR_BUS_SELECTOR to NAME
  --clear      set it back to empty (repo returns to the shared host-wide bus)
  --apply      actually write. Without it you get a dry run and a diff
  --yes        do not pause for confirmation before each write

Examples:
  bus-assign.sh --tag valis ~/SourceCode/lisp/DeepSkyV2/valis ~/SourceCode/lisp/parachute
  bus-assign.sh --tag valis --apply --yes ~/SourceCode/lisp/*/
  bus-assign.sh --clear --apply ~/SourceCode/lisp/parachute
EOF
  exit 2
}

# A bus name becomes one directory segment and one socket path component.
validate_tag() {
  local t="$1"
  [ -n "$t" ] || { echo "empty tag" >&2; return 1; }
  [ "${#t}" -le 32 ] || { echo "tag '$t' is ${#t} chars; the limit is 32" >&2; return 1; }
  case "$t" in
    *[!A-Za-z0-9._-]*) echo "tag '$t' has a character outside alphanumerics, hyphen, underscore, period" >&2; return 1 ;;
  esac
  case "$t" in
    default|cursors|watch|roster|members|bus.wal|broker.lock|submit.ipc|pub.ipc|.|..)
      echo "tag '$t' is reserved by the bus state directory" >&2; return 1 ;;
  esac
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)   [ $# -ge 2 ] || usage; TAG="$2"; shift 2 ;;
    --clear) TAG=""; CLEAR=1; shift ;;
    --apply) APPLY=1; shift ;;
    --yes)   ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown flag: $1" >&2; usage ;;
    *) REPOS+=("$1"); shift ;;
  esac
done

CLEAR="${CLEAR:-0}"
[ "${#REPOS[@]}" -gt 0 ] || usage
if [ "$CLEAR" -eq 0 ]; then
  [ -n "$TAG" ] || { echo "give --tag NAME or --clear" >&2; usage; }
  validate_tag "$TAG" || exit 1
fi

LINE="export DSMR_BUS_SELECTOR=\"\${DSMR_BUS_SELECTOR:-${TAG}}\""

changed=0; skipped=0; already=0; missing=0

for repo in "${REPOS[@]}"; do
  repo="${repo%/}"
  name="$(basename "$repo")"
  envrc="$repo/.envrc"

  if [ ! -d "$repo" ]; then
    printf '%-22s SKIP   no such directory\n' "$name"; missing=$((missing+1)); continue
  fi
  if [ ! -f "$envrc" ]; then
    printf '%-22s SKIP   no .envrc (this script edits, it does not scaffold)\n' "$name"
    missing=$((missing+1)); continue
  fi

  current="$(grep -n '^[[:space:]]*export[[:space:]]\+DSMR_BUS_SELECTOR=' "$envrc" || true)"
  count="$(printf '%s' "$current" | grep -c . || true)"

  if [ "$count" -gt 1 ]; then
    printf '%-22s SKIP   %s DSMR_BUS_SELECTOR lines; fix by hand\n' "$name" "$count"
    skipped=$((skipped+1)); continue
  fi

  tmp="$(mktemp)"
  if [ "$count" -eq 1 ]; then
    if grep -qxF "$LINE" "$envrc"; then
      printf '%-22s ok     already %s\n' "$name" "${TAG:-<shared>}"; already=$((already+1)); rm -f "$tmp"; continue
    fi
    # Replace the existing declaration, leaving everything else byte for byte.
    awk -v new="$LINE" '
      /^[[:space:]]*export[[:space:]]+DSMR_BUS_SELECTOR=/ { print new; next } { print }
    ' "$envrc" > "$tmp"
    action="update"
  else
    # Insert after the last DSMR_ export so it lands with its siblings, not at EOF.
    anchor="$(grep -n '^[[:space:]]*export[[:space:]]\+DSMR_' "$envrc" | tail -1 | cut -d: -f1)"
    if [ -n "$anchor" ]; then
      awk -v n="$anchor" -v new="$LINE" 'NR==n { print; print new; next } { print }' "$envrc" > "$tmp"
    else
      cp "$envrc" "$tmp"; printf '\n%s\n' "$LINE" >> "$tmp"
    fi
    action="insert"
  fi

  # Refuse to write anything that would leave more or fewer than one declaration.
  after="$(grep -c '^[[:space:]]*export[[:space:]]\+DSMR_BUS_SELECTOR=' "$tmp" || true)"
  if [ "$after" -ne 1 ]; then
    printf '%-22s SKIP   result would hold %s declarations, refusing\n' "$name" "$after"
    rm -f "$tmp"; skipped=$((skipped+1)); continue
  fi

  printf '%-22s %s\n' "$name" "$action"
  diff -u "$envrc" "$tmp" | sed -n '3,$p' | sed 's/^/    /'

  if [ "$APPLY" -eq 0 ]; then rm -f "$tmp"; changed=$((changed+1)); continue; fi

  if [ "$ASSUME_YES" -eq 0 ]; then
    printf '    write %s? [y/N] ' "$envrc" >&2
    read -r reply </dev/tty || reply=n
    case "$reply" in y|Y) : ;; *) echo "    skipped" >&2; rm -f "$tmp"; skipped=$((skipped+1)); continue ;; esac
  fi

  cp -p "$envrc" "$envrc.bak.$(date +%Y%m%d%H%M%S)"
  cat "$tmp" > "$envrc"          # preserve inode, ownership and mode
  rm -f "$tmp"
  changed=$((changed+1))

  if command -v direnv >/dev/null 2>&1; then
    (cd "$repo" && direnv allow . >/dev/null 2>&1) && echo "    direnv allow ok" || echo "    direnv allow FAILED, run it yourself"
  fi
done

echo
if [ "$APPLY" -eq 0 ]; then
  echo "dry run: $changed would change, $already already correct, $skipped skipped, $missing without .envrc"
  echo "re-run with --apply to write. Add --yes to skip the per-file prompt."
else
  echo "changed $changed, already correct $already, skipped $skipped, no .envrc $missing"
  echo
  echo "⛔ A running session keeps the environment it launched with. Every repo you"
  echo "   changed needs its Claude session EXITED and started fresh from a shell in"
  echo "   that directory. A /mcp reconnect is not enough."
fi
