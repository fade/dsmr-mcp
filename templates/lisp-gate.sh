#!/usr/bin/env bash
# lisp-gate: report the Lisp linter findings inside the top-level forms that
# the staged change touches.
#
# Scope: staged .lisp and .asd files only, and of their findings only those on
# a line inside a top-level form the staged diff touches. Findings in forms and
# files the commit leaves alone are not reported. The linter runs over the
# staged content, copied into a temporary directory under the same relative
# paths, so its line numbers agree with the diff even when the working tree
# holds unstaged edits.
#
# Modes, fixed when this file is rendered:
#   informational  report the findings; exit 0 on every path.
#   blocking       exit 1 when a reported finding is an error or a warning, or
#                  when the linter cannot run; exit 0 otherwise.
#
# Bound: a top-level form starts at a line whose first character is an open
# parenthesis. Such a line inside a multi-line string or a block comment reads
# as a form start and narrows the region around it.
#
# MALLET overrides the linter location. Bypass a single commit with:
#   git commit --no-verify
#{{spdx-line}}
set -u

GATE_MODE='{{gate-mode}}'
MALLET="${MALLET:-$HOME/.local/share/mallet/mallet}"
BYPASS='Bypass a single commit with: git commit --no-verify'

blocking() {
  [ "$GATE_MODE" = 'blocking' ]
}

# Print one line for a gate that cannot do its work, then exit: 1 when
# blocking, 0 otherwise.
cannot_run() {
  if blocking; then
    printf 'lisp-gate: %s; commit refused. %s\n' "$1" "$BYPASS"
    exit 1
  fi
  printf 'lisp-gate: %s; the commit proceeds without a lint check.\n' "$1"
  exit 0
}

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  cannot_run 'no git working tree found'
cd -- "$ROOT" || cannot_run "cannot enter $ROOT"

# --no-renames: a renamed or copied file is listed as added under its new name
# and linted whole, instead of being dropped as status R or C.
FILES=()
while IFS= read -r -d '' path; do
  case "$path" in
    *.lisp | *.asd) FILES+=("$path") ;;
  esac
done < <(git diff --cached --name-only -z --no-renames --diff-filter=AM)

[ "${#FILES[@]}" -eq 0 ] && exit 0

[ -x "$MALLET" ] || cannot_run "linter not found at $MALLET"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lisp-gate.XXXXXX")" ||
  cannot_run 'cannot create a temporary directory'
trap 'rm -rf -- "$TMP"' EXIT

LINT_ARGS=(--format line --no-color)
if [ -f "$ROOT/.mallet.lisp" ]; then
  LINT_ARGS+=(--config "$ROOT/.mallet.lisp")
fi

# Print "START END" for each region of the staged file $1 that the staged diff
# touches, widened to whole top-level forms. Line numbers only cross into awk;
# no file name does.
regions() {
  local path="$1" copy="$2"
  {
    grep -n '^(' -- "$copy" | cut -d: -f1 | sed 's/^/S /'
    git diff --cached -U0 --no-color --no-ext-diff -- "$path" |
      sed -n 's/^@@ -[0-9,]* +\([0-9][0-9]*\)\(,\([0-9][0-9]*\)\)\{0,1\} @@.*/H \1 \3/p'
  } | awk '
    $1 == "S" { starts[++n] = $2 + 0; next }
    $1 == "H" {
      first = $2 + 0
      count = ($3 == "") ? 1 : $3 + 0
      if (count == 0) { last = first + 1; if (first < 1) first = 1 }
      else            { last = first + count - 1 }
      lo[++h] = first; hi[h] = last
    }
    END {
      for (i = 1; i <= h; i++) {
        s = 1; e = 2147483647
        for (j = 1; j <= n; j++) {
          if (starts[j] <= lo[i]) s = starts[j]
          if (starts[j] > hi[i] && e == 2147483647) e = starts[j] - 1
        }
        print s, e
      }
    }'
}

KEPT=()
REFUSE=0
for path in "${FILES[@]}"; do
  case "$path" in
    *$'\n'*)
      printf 'lisp-gate: skipped a staged file whose name holds a newline\n'
      continue
      ;;
  esac
  copy="$TMP/$path"
  mkdir -p -- "$(dirname -- "$copy")" ||
    cannot_run 'cannot stage a copy for the linter'
  git cat-file blob ":$path" >"$copy" ||
    cannot_run "cannot read the staged content of $path"

  LO=()
  HI=()
  while read -r s e; do
    LO+=("$s")
    HI+=("$e")
  done < <(regions "$path" "$copy")
  [ "${#LO[@]}" -eq 0 ] && continue

  output="$(cd -- "$TMP" && "$MALLET" "${LINT_ARGS[@]}" "./$path" 2>&1)"
  status=$?
  case "$status" in
    0 | 1) ;;
    *) cannot_run "the linter failed on $path (exit $status)" ;;
  esac

  prefix="$path:"
  found=()
  while IFS= read -r line; do
    [ "${line:0:${#prefix}}" = "$prefix" ] || continue
    rest="${line:${#prefix}}"
    [[ "$rest" =~ ^([0-9]+):[0-9]+:\ (error|warning|info):\  ]] || continue
    n="${BASH_REMATCH[1]}"
    severity="${BASH_REMATCH[2]}"
    for i in "${!LO[@]}"; do
      if [ "$n" -ge "${LO[$i]}" ] && [ "$n" -le "${HI[$i]}" ]; then
        found+=("$rest")
        [ "$severity" = 'info' ] || REFUSE=1
        break
      fi
    done
  done <<<"$output"

  if [ "${#found[@]}" -gt 0 ]; then
    while IFS= read -r rest; do
      KEPT+=("$path:$rest")
    done < <(printf '%s\n' "${found[@]}" | sort -t: -k1,1n -k2,2n)
  fi
done

count="${#KEPT[@]}"
if blocking && [ "$REFUSE" -eq 1 ]; then
  printf 'lisp-gate: %d finding(s) in the forms this commit touches; commit refused on an error or warning (%s). %s\n' \
    "$count" "$GATE_MODE" "$BYPASS"
  status=1
else
  printf 'lisp-gate: %d finding(s) in the forms this commit touches; the commit proceeds (%s).\n' \
    "$count" "$GATE_MODE"
  status=0
fi
if [ "$count" -gt 0 ]; then
  printf '%s\n' "${KEPT[@]}"
fi
exit "$status"
