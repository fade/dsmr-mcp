#!/usr/bin/env bash
# scripts/lint-lisp.sh: run the mallet linter over this project's Lisp sources.
#
# Usage: ./scripts/lint-lisp.sh [file ...]
#   With no arguments, lints every .lisp file under src/ and tests/.
#
# The linter is invoked by absolute path deliberately. A binary named 'mallet'
# on PATH belongs to an unrelated Java toolkit that happens to share the name,
# and reaching it instead would either fail in a confusing way or appear to
# succeed having linted nothing. Set MALLET to override the location.

set -euo pipefail

MALLET="${MALLET:-$HOME/.local/share/mallet/mallet}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -x "$MALLET" ]; then
  echo "lint-lisp: no linter at $MALLET" >&2
  echo "lint-lisp: install it there, or set MALLET to its location." >&2
  exit 127
fi

cd "$PROJECT_ROOT"

if [ "$#" -gt 0 ]; then
  exec "$MALLET" "$@"
fi

SOURCES=()
while IFS= read -r file; do
  SOURCES+=("$file")
done < <(find src tests -type f -name '*.lisp' 2>/dev/null | sort)

if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "lint-lisp: no .lisp files under src/ or tests/; nothing to lint." >&2
  exit 0
fi

exec "$MALLET" "${SOURCES[@]}"
