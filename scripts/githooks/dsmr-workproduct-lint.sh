#!/usr/bin/env bash
# Outward-facing work-product lint (shared by pre-commit and commit-msg).
#
# Blocks a commit whose staged content or message carries language that must
# never reach a reader of the repository: AI-authorship attribution, pointers
# to out-of-repo planning state, and internal planning/coordination indices.
# The vocabulary is fine in planning state and coordination channels; it is
# banned only at the work-product boundary (shipped files, commit messages).
#
# Two tiers:
#   universal — always enforced; these are never legitimate work product.
#   strict    - planning/coordination indices; on by default, disable per repo
#               with:  git config --bool dsmr.workproductlint.strict false
#
# It also checks the ATTRIBUTION GLYPH on a commit message. I am the attributed
# author of every work product here, so the footer always names me; what changes
# is the mark, and it follows the LICENCE rather than the repository. Work I
# start under the dsmr umbrella is AGPL-3.0-or-later and takes the copyleft
# mark. A project adopted into the workspace by the fork-upstream then
# clone-our-fork route keeps the licence it came with, so an inherited MIT
# project takes the ordinary copyright sign. We do not restate other people's
# licences in our own terms, and the mark in a trailer should not claim we did.
#
# This exists because nothing enforced it: a repository inherited as MIT
# accumulated 23 commits carrying the copyleft mark, supplied by a rule that
# keyed on whose repository it was instead of on the licence. A record saying
# otherwise sat beside them the whole time and changed nothing, because a record
# is not a control.
#
# Checks ADDED lines only (git diff --cached), so pre-existing debt in a repo
# does not block unrelated commits — you fix what you touch.

set -u

# grep -E alternations. Case-insensitive matching is applied at call time.
UNIVERSAL='co-authored-by:[[:space:]]*(claude|codex|chatgpt|gpt-|copilot|gemini|anthropic)|generated (with|by)[^\n]*(claude|codex|copilot|gpt)|🤖|(^|[^[:alnum:]])\.planning/'

# High-precision only: hyphenated planning identifiers, constellation
# requirement indices, and coordination phrases that have no legitimate use in
# shipped text. Deliberately NOT here (too ambiguous for a hard block — left to
# the grounded instruction layer + review): bare "phase N"/"wave N" (Noise
# handshake phases, etc.), "A.1"/"B.4"/"§A.1" (RFC sections, figures, appendices),
# generic "option-N".
STRICT='(^|[^[:alnum:]])(phase|wave|plan|task|milestone)-[0-9]|(^|[^[:alnum:]])(RSLV|SERV|FACT|ZXFR|COH)-[0-9]|joint kickoff|co-owned|frozen seam|held for operator (merge|tag)'

# The style tier: long dashes and stock phrases.
#
# I added this tier because machine-written cliches go stale fast. A phrase that
# reads as fresh in one season reads as gauche the next, and a reader who spots
# one starts discounting everything around it. "load-bearing" was the first word
# banned and the worst offender; these lists carry the rest of the catalogue that
# a pattern can express. The full catalogue, with when each pattern is
# legitimate, is skills/copy-editor/stock-patterns.md in dsmr-mcp.
#
# Non-ASCII characters are built from escapes so this file never carries the
# characters it rejects.
EM_DASH=$(printf '\xe2\x80\x94'); EN_DASH=$(printf '\xe2\x80\x93')
CURLY=$(printf '\xe2\x80\x9c|\xe2\x80\x9d|\xe2\x80\x98|\xe2\x80\x99')
ARROWS=$(printf '\xe2\x86\x92|\xe2\x87\x92|\xe2\x86\x90')
STYLE_DASH="$EM_DASH|$EN_DASH"

# Blocked in prose files and commit messages: no legitimate use in this
# project's technical writing.
STYLE_BLOCK="load[- ]bearing|\\<delv(e|es|ed|ing)\\>|\\<tapestry\\>|(it'?s|it is) worth noting|worth noting that|it bears mentioning|\\<in conclusion\\>|\\<to sum up\\>|here'?s the (thing|kicker|catch)|let'?s (dive|delve|unpack|break (this|it) down)|game[- ]changer|\\<seamless(ly)?\\>|ever[- ]evolving"

# Warned everywhere: words that are sometimes the right technical term, so one
# instance is prose and several are the defect. A commit message with that
# many lines carrying them (dsmr.workproductlint.styledensity, default 3) is
# blocked.
STYLE_WARN="\\<robust(ly|ness)?\\>|\\<leverag(e|es|ed|ing)\\>|\\<landscape\\>|\\<paradigm|\\<synerg|\\<quietly\\>|\\<fundamentally\\>|\\<remarkably\\>|\\<arguably\\>|\\<(serves|stands) as\\>|\\<(importantly|interestingly|notably),|\\<in summary\\>|think of it (as|like)|imagine a world|\\<streamlin|\\<utiliz|\\<harness(es|ed|ing)\\>|\\<humans?\\>|$CURLY|$ARROWS"

# Warned: code given a mind. A verb of perception or judgment after a code
# subject is the author's decision or the mechanism's effect misassigned.
STYLE_MIND="\\<(server|gate|hook|check|worker|watcher|broker|daemon|service|image|core|function|parser|code|program|script|lint|tool|launcher|listener|probe)s? (never |always |now |still |also )?(knows|sees|wants|decides|believes|agrees|trusts|notices|remembers|insists|claims|admits|promises|cares|thinks)\\>"

# Which attribution mark belongs in this repository's commit trailers.
#
# Derived from the licence on disk so it cannot drift from the thing it
# describes, with an explicit override for a repository the derivation reads
# wrongly. Three questions in order: has someone set the answer explicitly, does
# a licence file say AGPL, and failing both, did this project arrive here from
# somewhere else. Only a tree that answers no to all three is treated as ours
# and unreleased.
#
# Override:  git config dsmr.attribution.glyph copyleft|copyright
attribution_glyph() {
  local v root f
  v=$(git config --get dsmr.attribution.glyph 2>/dev/null)
  case "$v" in copyleft|copyright) printf '%s' "$v"; return 0 ;; esac
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { printf 'copyleft'; return 0; }
  for f in LICENSE LICENCE COPYING LICENSE.txt LICENSE.md COPYING.txt; do
    if [ -f "$root/$f" ]; then
      if grep -qiE 'affero general public license|AGPL' "$root/$f"; then
        printf 'copyleft'
      else
        printf 'copyright'
      fi
      return 0
    fi
  done
  # No licence file, but a system definition may declare one. That is a positive
  # statement by the project about itself, so it outranks the inference below it.
  # Without this tier a project with an AGPL .asd and no LICENSE lands on the
  # default and is right by accident, which reads identical to being right on
  # purpose until the day the default changes or the project is adopted.
  # find rather than a glob: an unmatched *.asd is an ERROR under zsh, not an
  # empty list, and it aborts this function mid-way so it returns no mark at all.
  # A caller then compares against an empty string and every message looks
  # correct. Measured on a repository that carries no system definition.
  local decl
  decl=$(find "$root" -maxdepth 1 -name '*.asd' -exec grep -ihm1 ':license' {} + 2>/dev/null | head -1)
  if [ -n "$decl" ]; then
    if printf '%s' "$decl" | grep -qiE 'agpl|affero'; then
      printf 'copyleft'
    else
      printf 'copyright'
    fi
    return 0
  fi

  # Still nothing said outright. Before treating the tree as ours, ask whether we adopted it:
  # the fork-upstream then clone-our-fork procedure leaves a second remote behind,
  # and a project that arrived that way keeps the licence it came with whether or
  # not this checkout carries the file. Getting this wrong is not cosmetic; it
  # stamps a copyleft mark on somebody else's MIT work. Measured on a real
  # checkout that has an upstream remote and no LICENSE at all.
  if git -C "$root" remote 2>/dev/null \
       | grep -qiE '^(upstream|github-archived|.*-fork)$'; then
    printf 'copyright'
    return 0
  fi
  printf 'copyleft'
}

strict_on() {
  local v
  v=$(git config --bool --get dsmr.workproductlint.strict 2>/dev/null)
  [ "$v" = "false" ] && return 1
  return 0
}

style_on() {
  local v
  v=$(git config --bool --get dsmr.workproductlint.style 2>/dev/null)
  [ "$v" = "false" ] && return 1
  return 0
}

style_density() {
  local v
  v=$(git config --int --get dsmr.workproductlint.styledensity 2>/dev/null)
  printf '%s' "${v:-3}"
}

# Which style treatment a staged path gets: "prose" takes the block tier, "source"
# only warns (a string literal or a test fixture can legitimately hold any of
# these), "exempt" is skipped. Licence texts are not ours to restyle, and skill
# files are agent-facing instructions written for the agent that reads them
# (skills/ is where this site keeps them, in any repository). The hook's own
# directory is skipped because its patterns spell every phrase it rejects.
style_class() {
  local f="$1" g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254  # the configured value is a glob on purpose
    case "$f" in $g) printf 'exempt'; return 0 ;; esac
  done < <(git config --get-all dsmr.workproductlint.styleexempt 2>/dev/null)
  case "$f" in
    LICENSE*|LICENCE*|COPYING*|*/LICENSE*|*/LICENCE*|*/COPYING*) printf 'exempt' ;;
    skills/*|scripts/githooks/*) printf 'exempt' ;;
    *.md|*.markdown|*.org|*.txt|*.rst|*.adoc|README*|*/README*|NEWS*|CHANGELOG*) printf 'prose' ;;
    *) printf 'source' ;;
  esac
}

# Prints "LINE: text" for each added line of one staged path, numbered as in
# the new file so a reader can jump straight to it.
added_lines_numbered() {
  git diff --cached --no-color -U0 -- "$1" 2>/dev/null | awk '
    /^@@/ { split($3, a, ","); n = substr(a[1], 2) + 0; next }
    /^\+\+\+/ { next }
    /^\+/ { print n ": " substr($0, 2); n++ }'
}

# Sets STYLE_BLOCKED=1 when anything blocks; prints every finding.
STYLE_BLOCKED=0
style_report() {
  local label="$1" pattern="$2" text="$3" where="$4" hits
  hits=$(printf '%s\n' "$text" | LC_ALL=C grep -Ei -- "$pattern" 2>/dev/null) || true
  [ -n "$hits" ] || return 1
  echo "$label"
  printf '%s\n' "$hits" | sed "s|^|    ${where}|"
  return 0
}

run_style_staged() {
  local f cls text
  while IFS= read -r -d '' f; do
    cls=$(style_class "$f")
    [ "$cls" = "exempt" ] && continue
    text=$(added_lines_numbered "$f")
    [ -n "$text" ] || continue
    if [ "$cls" = "prose" ]; then
      style_report "✗ style: long dash in prose (use a hyphen, comma, colon, or full stop):" \
        "$STYLE_DASH" "$text" "$f:" && STYLE_BLOCKED=1
      style_report "✗ style: stock phrase (say it plainly):" \
        "$STYLE_BLOCK" "$text" "$f:" && STYLE_BLOCKED=1
    else
      style_report "⚠ style: long dash or stock phrase in source (not blocking; check comments and docstrings):" \
        "$STYLE_DASH|$STYLE_BLOCK" "$text" "$f:"
    fi
    style_report "⚠ style: word that is often filler or a cliche (not blocking alone):" \
      "$STYLE_WARN" "$text" "$f:"
    style_report "⚠ style: code described as having a mind (give the decision to the author):" \
      "$STYLE_MIND" "$text" "$f:"
  done < <(git diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null)
  return 0
}

run_style_msg() {
  local text="$1" warns n
  text=$(printf '%s\n' "$text" | grep -n '')
  style_report "✗ style: long dash in the message (use a hyphen, comma, colon, or full stop):" \
    "$STYLE_DASH" "$text" "line " && STYLE_BLOCKED=1
  style_report "✗ style: stock phrase in the message (say it plainly):" \
    "$STYLE_BLOCK" "$text" "line " && STYLE_BLOCKED=1
  style_report "⚠ style: code described as having a mind (give the decision to the author):" \
    "$STYLE_MIND" "$text" "line "
  warns=$(printf '%s\n' "$text" | LC_ALL=C grep -Eic -- "$STYLE_WARN" 2>/dev/null) || true
  n=$(style_density)
  if [ "${warns:-0}" -ge "$n" ]; then
    style_report "✗ style: $warns lines carry filler or cliche words (refused at $n per message):" \
      "$STYLE_WARN" "$text" "line "
    STYLE_BLOCKED=1
  else
    style_report "⚠ style: word that is often filler or a cliche (not blocking alone):" \
      "$STYLE_WARN" "$text" "line "
  fi
  return 0
}

# Returns 0 = clean, 1 = blocked. Prints a report on block.
run_workproduct_lint() {
  local mode="$1"; local text=""
  case "$mode" in
    staged)
      # Added lines in the staged diff (strip the leading +, skip +++ headers).
      # The hook sources are excluded from their own scan, and this is not a
      # convenience. Once the lint became tracked content, its own pattern
      # definitions became staged lines, and those necessarily SPELL every string
      # it exists to reject. Without this it blocks any commit that touches it,
      # including the one that first tracked it, and the only way past would be
      # --no-verify, which is strictly worse: that turns the whole gate off for
      # the commit rather than excusing one known file.
      #
      # Scoped to the hook directory by exact path, so it silences the tool's own
      # vocabulary and nothing else. A repository without that directory matches
      # nothing here and is unaffected.
      text=$(git diff --cached --no-color -U0 -- . ':(exclude)scripts/githooks/*' 2>/dev/null \
             | grep -E '^\+' | grep -Ev '^\+\+\+' | sed 's/^+//')
      ;;
    msg)
      # Stop at the scissors line: `git commit -v` appends the diff below it,
      # and that diff is the staged content, already checked in staged mode.
      text=$(awk '/^# -+ >8 -+$/ { exit } !/^#/ { print }' "$2" 2>/dev/null)
      ;;
    file)
      # A file checked directly keeps every line: in a Markdown PR body a line
      # opening with # is a heading, not a git comment.
      text=$(cat "$2" 2>/dev/null)
      ;;
  esac
  [ -z "$text" ] && return 0

  local blocked=0 vocab_blocked=0 style_blocked=0 uni str
  if style_on; then
    STYLE_BLOCKED=0
    if [ "$mode" = "staged" ]; then run_style_staged; else run_style_msg "$text"; fi
    if [ "$STYLE_BLOCKED" = 1 ]; then blocked=1; style_blocked=1; fi
  fi
  uni=$(printf '%s\n' "$text" | grep -nEi "$UNIVERSAL" 2>/dev/null) || true
  if [ -n "$uni" ]; then
    echo "✗ work-product lint: AI-attribution or .planning/ reference (never allowed):"
    printf '%s\n' "$uni" | sed 's/^/    /'
    blocked=1; vocab_blocked=1
  fi
  if strict_on; then
    str=$(printf '%s\n' "$text" | grep -nEi "$STRICT" 2>/dev/null) || true
    if [ -n "$str" ]; then
      echo "✗ work-product lint: internal planning/coordination index in shipped text:"
      printf '%s\n' "$str" | sed 's/^/    /'
      blocked=1; vocab_blocked=1
    fi
  fi

  # Attribution mark. Message mode only: a trailer is a property of the commit
  # message, never of the staged diff.
  #
  # The WRONG mark is a hard block, because it is unambiguous and it is the
  # defect actually seen. A MISSING trailer only warns: a merge commit written
  # by the forge carries no body, and making those uncommittable would break
  # landing a pull request to enforce a footer nobody typed.
  if [ "$mode" != "staged" ]; then
    local want; want=$(attribution_glyph)
    local wrong_mark wrong_name
    if [ "$want" = "copyright" ]; then
      wrong_mark='\xf0\x9f\x84\xaf'; wrong_name='copyleft mark'
    else
      wrong_mark='\xc2\xa9'; wrong_name='copyright sign'
    fi
    if printf '%s\n' "$text" | grep -q "$(printf '%b' "$wrong_mark")"; then
      echo "✗ work-product lint: wrong attribution mark for this licence."
      if [ "$want" = "copyright" ]; then
        echo "    This project's licence is inherited and is not AGPL, so its trailer"
        echo "    takes the ordinary copyright sign, not the $wrong_name."
      else
        echo "    This project is AGPL-3.0-or-later, so its trailer takes the copyleft"
        echo "    mark, not the $wrong_name."
      fi
      echo "    Override if the derivation is wrong here:"
      echo "      git config dsmr.attribution.glyph copyleft|copyright"
      blocked=1
    elif ! printf '%s\n' "$text" | grep -qi "o'reilly"; then
      echo "⚠ work-product lint: no attribution trailer found (not blocking)."
      echo "    Expected a line naming Brian O'Reilly with the $( [ "$want" = copyright ] && echo 'copyright sign' || echo 'copyleft mark' )."
    fi
  fi

  if [ "$blocked" = 1 ]; then
    # Print the remedy that matches the failure. An attribution block and a
    # vocabulary block need different things done, and advice for the other one
    # sends the reader to rewrite prose that was never the problem.
    if [ "$vocab_blocked" = 1 ]; then
      cat <<'EOF'

These belong in planning state / coordination channels, never in shipped files
or commit messages. Rewrite to describe the behavior and the why.
EOF
    fi
    if [ "$style_blocked" = 1 ]; then
      cat <<'EOF'

Rewrite with the plain word, or restructure the sentence. A dash becomes a
hyphen, comma, colon, parentheses, or a full stop.
  Exempt a path here:          git config --add dsmr.workproductlint.styleexempt 'tests/fixtures/*'
  Raise the refusal count:     git config --int dsmr.workproductlint.styledensity 5
  Disable style tier here:     git config --bool dsmr.workproductlint.style false
EOF
    fi
    cat <<'EOF'
  Bypass (rare, deliberate):   git commit --no-verify
  Disable strict tier here:    git config --bool dsmr.workproductlint.strict false
EOF
    return 1
  fi
  return 0
}

# The entry point every pre-commit and commit-msg calls. A staged check also
# runs shellcheck over the staged shell scripts when dsmr-shell-lint.sh is
# installed beside this file. It rides on this call because nearly every
# repository runs its own pre-commit, and each of them already calls this one:
# installing this file and dsmr-shell-lint.sh turns shell lint on everywhere
# without replacing anyone's hook.
run_lint() {
  local status=0 here
  run_workproduct_lint "$@" || status=$?
  if [ "$1" = "staged" ]; then
    here=$(dirname "${BASH_SOURCE[0]}")
    if [ -f "$here/dsmr-shell-lint.sh" ]; then
      # shellcheck source=/dev/null  # resolved at run time beside this file
      . "$here/dsmr-shell-lint.sh"
      run_shell_lint || status=1
    fi
  fi
  return "$status"
}

# Run directly to check text that never passes through a commit, such as a pull
# request body: dsmr-workproduct-lint.sh --check-file body.md
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --check-file)
      if [ -z "${2:-}" ] || [ ! -r "$2" ]; then
        echo "usage: $0 --check-file FILE" >&2; exit 2
      fi
      run_workproduct_lint file "$2"; exit $? ;;
    *)
      echo "usage: $0 --check-file FILE   (check a PR body or any message file)" >&2
      exit 2 ;;
  esac
fi
