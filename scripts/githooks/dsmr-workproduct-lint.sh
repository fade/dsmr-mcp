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

# Returns 0 = clean, 1 = blocked. Prints a report on block.
run_lint() {
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
      text=$(cat "$2" 2>/dev/null | grep -v '^#')
      ;;
  esac
  [ -z "$text" ] && return 0

  local blocked=0 vocab_blocked=0 uni str
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
  if [ "$mode" = "msg" ]; then
    local want; want=$(attribution_glyph)
    local wrong_mark wrong_name
    if [ "$want" = "copyright" ]; then
      wrong_mark='\xf0\x9f\x84\xaf'; wrong_name='copyleft mark'
    else
      wrong_mark='\xc2\xa9'; wrong_name='copyright sign'
    fi
    if printf '%s\n' "$text" | grep -q "$(printf "$wrong_mark")"; then
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
    cat <<'EOF'
  Bypass (rare, deliberate):   git commit --no-verify
  Disable strict tier here:    git config --bool dsmr.workproductlint.strict false
EOF
    return 1
  fi
  return 0
}
