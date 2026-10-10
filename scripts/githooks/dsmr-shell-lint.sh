#!/usr/bin/env bash
# Run shellcheck over the shell scripts a commit is about to record.
#
# The work-product lint runs this on every staged check, so any pre-commit
# that calls run_lint gets it. It is on by default in every repository the
# hooks are installed into, because a shell script that quietly masks an exit
# status or word-splits a path fails in production, not at review. Where a
# repository carries scripts you do not own, turn it off:
#   git config --bool dsmr.shellcheck.enabled false
#
# It checks the STAGED content, not the working tree, so what passes is what
# lands. A script counts when its name ends in .sh or its first line runs sh,
# bash, dash or ksh. zsh scripts are skipped: shellcheck does not parse zsh,
# and a false alarm on every zsh commit teaches the reader to ignore the real
# ones.
#
# SC1091 (a sourced file it was not given) is excluded: a staged blob has no
# neighbours on disk to follow, so it would fire on every script that sources
# another.
#
# A missing shellcheck is reported on stderr and the commit goes through. A
# host without the linter must not make a tree uncommittable.

shell_lint_wanted() {
  [ "$(git config --bool --get dsmr.shellcheck.enabled 2>/dev/null)" != "false" ]
}

# Succeeds when the staged blob at path $1 is a script shellcheck can read.
shell_lint_is_script() {
  local path="$1" first
  first=$(git show ":$path" 2>/dev/null | head -n 1)
  case "$first" in
    '#!'*zsh*) return 1 ;;
  esac
  case "$path" in
    *.sh) return 0 ;;
  esac
  printf '%s\n' "$first" \
    | grep -qE '^#!.*[/ ](env +)?(sh|bash|dash|ksh)([[:space:]]|$)'
}

run_shell_lint() {
  shell_lint_wanted || return 0
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "pre-commit: shellcheck is not installed; shell lint skipped." >&2
    return 0
  fi

  local path found=0 failed=0 out
  while IFS= read -r -d '' path; do
    shell_lint_is_script "$path" || continue
    found=1
    if ! out=$(git show ":$path" | shellcheck --exclude=SC1091 -f gcc - 2>&1); then
      failed=1
      printf '%s\n' "$out" \
        | awk -v p="$path" 'substr($0, 1, 2) == "-:" { $0 = p substr($0, 2) } { print }'
    fi
  done < <(git diff --cached --name-only --diff-filter=ACMR -z)

  if [ "$found" = 1 ] && [ "$failed" = 1 ]; then
    echo "✗ shell lint: shellcheck found problems in the staged scripts above."
    echo "    Fix them, or put '# shellcheck disable=SCnnnn  # <reason>' on the line"
    echo "    above the finding, so the next reader knows the warning was weighed."
    return 1
  fi
  return 0
}
