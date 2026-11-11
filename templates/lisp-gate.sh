#!/usr/bin/env bash
# lisp-gate: report the Lisp linter findings inside the top-level forms that
# the staged change touches.
#
# Scope: staged .lisp and .asd files only, and of their findings only those on
# a line inside a top-level form the staged diff touches. Findings in forms and
# files the commit leaves alone are not reported. The linter runs over the
# staged content, copied into a temporary directory under the same relative
# paths, so its line numbers agree with the diff even when the working tree
# holds unstaged edits. The linter config is the staged .mallet.lisp, or the
# default preset when none is staged.
#
# Modes, fixed when this file is rendered:
#   informational  report the findings; exit 0 on every path.
#   blocking       exit 1 when a reported finding is an error or a warning,
#                  when the linter cannot run, or when a staged file cannot be
#                  linted; exit 0 otherwise.
#
# Bound: a top-level form starts at a line whose first character is an open
# parenthesis. Such a line inside a multi-line string or a block comment reads
# as a form start and narrows the region around it.
#
# Record: every finding shown is appended, one tab-separated row per finding
# per run, to lisp-gate/findings.tsv under the git common directory, so every
# worktree of the repository shares one record and none of it is tracked.
# Columns: recorded_at, mode, worktree, branch, class, category, severity,
# rule, path, line, column, message. The worktree is the absolute root of the
# worktree the commit is made in, and the branch is its checked-out branch, or
# "detached". The category is the linter's own rule category, read from a
# second run in JSON format, whatever order its keys come in; the class comes
# from FINDING_CLASSES below. A category that cannot be read is recorded as
# unknown, class unclassified. Severity does not decide the class: the linter
# reports trailing whitespace and real defects at the same severity. Runs in
# several worktrees append under a lock: flock(1) on the record where it is
# installed, otherwise a lock directory beside it, so the header is written
# once and rows never interleave. The record never changes the exit status; a
# record that cannot be written or locked is one notice line.
#
# MALLET overrides the linter location; without it, DSMR_LINTER does, as it
# does for the debt scan.
#
# Bypass a single commit with:
#   git commit --no-verify
#{{spdx-line}}
set -u

GATE_MODE='{{gate-mode}}'
MALLET="${MALLET:-${DSMR_LINTER:-$HOME/.local/share/mallet/mallet}}"
BYPASS='Bypass a single commit with: git commit --no-verify'

# Linter rule category to finding class, as category=class pairs. The
# categories are defined in mallet's docs/rule-classification.md: correctness
# is objectively wrong, suspicious is most likely a bug, practice works but
# uses a discouraged pattern, cleanliness is dead code, and style, format, and
# metrics concern presentation. A category not listed is unclassified.
FINDING_CLASSES='correctness=functional suspicious=functional practice=functional cleanliness=style style=style format=style metrics=style'

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

# The linter always gets a config at the root of the copy: the staged
# .mallet.lisp, or the default preset. Without one it would search upward from
# the copy and could take a config from any directory above TMPDIR.
CONFIG="$TMP/.mallet.lisp"
if git cat-file -e ':.mallet.lisp' 2>/dev/null; then
  git cat-file blob ':.mallet.lisp' >"$CONFIG" ||
    cannot_run 'cannot read the staged linter config'
else
  printf '(:mallet-config\n (:extends :default))\n' >"$CONFIG" ||
    cannot_run 'cannot write the linter config'
fi
LINT_ARGS=(--format line --no-color --config "$CONFIG")
JSON_ARGS=(--format json --no-color --config "$CONFIG")

# Print "START END" for each region of the staged file $1 that the staged diff
# touches, widened to whole top-level forms. Line numbers only cross into awk;
# no file name does.
regions() {
  local path="$1" copy="$2"
  {
    grep -n '^(' -- "$copy" | cut -d: -f1 | sed 's/^/S /'
    git --literal-pathspecs diff --cached -U0 --no-color --no-ext-diff \
      --no-textconv -- "$path" |
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

# Print one record row for each finding of the staged file $1 read on stdin as
# "LINE:COLUMN: SEVERITY: MESSAGE [RULE]". $2 is the linter's JSON output for
# the file, empty when it could not be read. A finding takes the category of
# the JSON violation with the same line, column, and rule, else unknown. Tab,
# carriage return, and newline in a field become a space.
finding_rows() {
  {
    printf '%s\n' "$2" | sed 's/^/J /'
    sed 's/^/F /'
  } | GATE_PATH="$1" GATE_TIME="$NOW" GATE_MODE="$GATE_MODE" \
    GATE_WORKTREE="$ROOT" GATE_BRANCH="$BRANCH" \
    FINDING_CLASSES="$FINDING_CLASSES" awk '
    function clean(s) { gsub(/[\t\r\n]/, " ", s); return s }
    function value(s) {
      sub(/^[^:]*: /, "", s)
      sub(/,$/, "", s)
      if (s ~ /^".*"$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    BEGIN {
      n = split(ENVIRON["FINDING_CLASSES"], pairs, " ")
      for (i = 1; i <= n; i++) {
        eq = index(pairs[i], "=")
        cls[substr(pairs[i], 1, eq - 1)] = substr(pairs[i], eq + 1)
      }
      path = clean(ENVIRON["GATE_PATH"])
      worktree = clean(ENVIRON["GATE_WORKTREE"])
      branch = clean(ENVIRON["GATE_BRANCH"])
    }
    # JSON: one key per line, in any order. Each object opens a fresh set of
    # fields; a closing brace files the category of an object holding a rule,
    # a line, a column and a category, and drops anything else.
    /^J / {
      s = substr($0, 3)
      if (s ~ /^ *[{]/) { rule = ""; line = ""; col = ""; cat = "" }
      else if (s ~ /^ *"rule": /) rule = value(s)
      else if (s ~ /^ *"line": /) line = value(s) + 0
      else if (s ~ /^ *"column": /) col = value(s) + 0
      else if (s ~ /^ *"category": /) cat = value(s)
      else if (s ~ /^ *[}]/) {
        if (rule != "" && line != "" && col != "" && cat != "") {
          k = line SUBSEP col SUBSEP rule
          if (!(k in category)) category[k] = cat
        }
        rule = ""; line = ""; col = ""; cat = ""
      }
      next
    }
    /^F / {
      s = substr($0, 3)
      if (!match(s, /^[0-9]+:[0-9]+: (error|warning|info): /)) next
      body = substr(s, RLENGTH + 1)
      split(substr(s, 1, RLENGTH), h, ":")
      sev = h[3]
      sub(/^ /, "", sev)
      # The rule is the bracketed text after the last " [" on the line.
      r = ""
      msg = body
      pos = 0
      start = 1
      while ((i = index(substr(body, start), " [")) > 0) {
        pos = start + i - 1
        start = pos + 2
      }
      if (pos > 0 && body ~ /\]$/) {
        r = substr(body, pos + 2, length(body) - pos - 2)
        msg = substr(body, 1, pos - 1)
      }
      k = (h[1] + 0) SUBSEP (h[2] + 0) SUBSEP r
      fc = (k in category) ? category[k] : "unknown"
      c = (fc in cls) ? cls[fc] : "unclassified"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\n",
        ENVIRON["GATE_TIME"], ENVIRON["GATE_MODE"], worktree, branch, c,
        clean(fc), sev, clean(r), path, h[1], h[2], clean(msg)
    }'
}

# Append ROWS to the record file $1, writing the header first when the file is
# empty, while holding the record's lock. Returns non-zero when the lock cannot
# be taken within about ten seconds or the write fails.
append_locked() {
  local file="$1" lock="$1.lock" status tries=0
  local header=$'recorded_at\tmode\tworktree\tbranch\tclass\tcategory\tseverity\trule\tpath\tline\tcolumn\tmessage\n'
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"$file" || return 1
    if ! flock -w 10 9; then
      exec 9>&-
      return 1
    fi
    [ -s "$file" ] && header=''
    printf '%s%s' "$header" "$ROWS" >&9
    status=$?
    exec 9>&-
    return "$status"
  fi
  until mkdir -- "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -ge 10 ] && return 1
    sleep 1
  done
  [ -s "$file" ] && header=''
  printf '%s%s' "$header" "$ROWS" >>"$file"
  status=$?
  rmdir -- "$lock" 2>/dev/null
  return "$status"
}

# Append ROWS to the record under the git common directory, then print one
# line naming it with the count of each class, or one line saying the
# findings were not recorded. Never exits.
record_findings() {
  local common dir file f s u
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
    common=''
  if [ -z "$common" ]; then
    printf 'lisp-gate: findings not recorded: no git directory found\n'
    return
  fi
  dir="$common/lisp-gate"
  file="$dir/findings.tsv"
  if mkdir -p -- "$dir" 2>/dev/null && append_locked "$file" 2>/dev/null; then
    read -r f s u < <(printf '%s' "$ROWS" | awk -F '\t' '
      { n[$5]++ }
      END { print n["functional"] + 0, n["style"] + 0, n["unclassified"] + 0 }')
    printf 'lisp-gate: recorded %d finding(s) in %s (%d functional, %d style, %d unclassified).\n' \
      "$((f + s + u))" "$file" "$f" "$s" "$u"
  else
    printf 'lisp-gate: findings not recorded: cannot write or lock %s\n' "$file"
  fi
}

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BRANCH="$(git symbolic-ref --short -q HEAD 2>/dev/null)" || BRANCH='detached'
ROWS=''
KEPT=()
REFUSE=0
SKIPPED=0
for path in "${FILES[@]}"; do
  # The linter reads * ? [ in an argument as a pattern and prints a name
  # holding them, or a backslash, escaped, so its findings could not be
  # attributed to the file.
  case "$path" in
    *$'\n'*)
      printf 'lisp-gate: skipped a staged file whose name holds a newline\n'
      SKIPPED=$((SKIPPED + 1))
      continue
      ;;
    *'*'* | *'?'* | *'['* | *\\*)
      printf 'lisp-gate: skipped %s: the linter reads its name as a pattern\n' "$path"
      SKIPPED=$((SKIPPED + 1))
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

  output="$(cd -- "$TMP" || exit 125; "$MALLET" "${LINT_ARGS[@]}" "./$path" 2>&1)"
  status=$?
  case "$status" in
    0 | 1) ;;
    *) cannot_run "the linter failed on $path (exit $status)" ;;
  esac

  prefix="$path:"
  found=()
  while IFS= read -r line; do
    if [ "${line:0:${#prefix}}" != "$prefix" ]; then
      # A finding line naming another file means the output was not read as
      # expected; in blocking mode that is a gate that cannot do its work.
      if blocking && [[ "$line" =~ ^[^:]+:[0-9]+:[0-9]+:\ (error|warning|info):\  ]]; then
        cannot_run "the linter reported a finding for $path under another name"
      fi
      continue
    fi
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
    shown=()
    while IFS= read -r rest; do
      shown+=("$rest")
      KEPT+=("$path:$rest")
    done < <(printf '%s\n' "${found[@]}" | sort -t: -k1,1n -k2,2n)
    # Categories come from a second run in JSON format; a failed run leaves
    # every category unread.
    json="$(cd -- "$TMP" || exit 125; "$MALLET" "${JSON_ARGS[@]}" "./$path" 2>/dev/null)"
    case "$?" in
      0 | 1) ;;
      *) json='' ;;
    esac
    rows="$(printf '%s\n' "${shown[@]}" | finding_rows "$path" "$json")"
    [ -n "$rows" ] && ROWS+="$rows"$'\n'
  fi
done

count="${#KEPT[@]}"
if blocking && [ "$SKIPPED" -gt 0 ]; then
  printf 'lisp-gate: %d staged file(s) could not be linted; commit refused (%s). %s\n' \
    "$SKIPPED" "$GATE_MODE" "$BYPASS"
  status=1
elif blocking && [ "$REFUSE" -eq 1 ]; then
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
[ -n "$ROWS" ] && record_findings
exit "$status"
