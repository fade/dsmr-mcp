#!/usr/bin/env bash
# Out of band test for the style tier of the work-product commit lint.
#
# Drives real commits through this tree's hooks in a scratch repository: only a
# commit attempt shows whether the lint stops it. Each blocking rule has a case
# that must be refused and one that must be accepted, so a lint that refuses
# everything fails here, as does one that refuses nothing. Warn-only rules are
# checked for the warning they print.
#
# Usage: bash tests/githooks/workproduct-style-test.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

pass=0; fail=0
EM=$(printf '\xe2\x80\x94')

repo="$scratch/repo"
git init -q "$repo"
git -C "$repo" config user.name "Hook Test"
git -C "$repo" config user.email "hook-test@example.invalid"
git -C "$repo" config commit.gpgsign false
for f in dsmr-workproduct-lint.sh dsmr-shell-lint.sh commit-msg pre-commit; do
  cp "$here/scripts/githooks/$f" "$repo/.git/hooks/$f"
  chmod 755 "$repo/.git/hooks/$f"
done
printf 'seed\n' > "$repo/seed.txt"
git -C "$repo" add seed.txt
git -C "$repo" commit -q --no-verify -m "seed"

# expect NAME refused|accepted PATH CONTENT [MESSAGE]
expect() {
  local name="$1" want="$2" path="$3" content="$4" msg="${5:-add a file}"
  mkdir -p "$(dirname "$repo/$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add -- "$path"
  if git -C "$repo" commit -q -m "$msg" >"$scratch/out" 2>&1; then got=accepted; else got=refused; fi
  if [ "$got" = "$want" ] && [ "$want" = refused ] && ! grep -q 'style:' "$scratch/out"; then
    fail=$((fail + 1)); echo "FAIL  $name: refused, but not by the style tier"; sed 's/^/        /' "$scratch/out"
  elif [ "$got" = "$want" ]; then
    pass=$((pass + 1)); echo "ok    $name ($got)"
  else
    fail=$((fail + 1)); echo "FAIL  $name: wanted $want, got $got"; sed 's/^/        /' "$scratch/out"
  fi
  git -C "$repo" reset -q --hard HEAD
}

# Prose files take the block tier.
expect "clean prose"                 accepted docs/a.md  "The server reads the core at start."
expect "long dash in prose"          refused  docs/b.md  "The server reads the core ${EM} at start."
expect "load-bearing in prose"       refused  docs/c.org "This check is load-bearing."
expect "delve in prose"              refused  README.md  "Let us delve into the details."
expect "worth noting in prose"       refused  docs/d.md  "It's worth noting that the core is rebuilt."
expect "one warn word in prose"      accepted docs/e.md  "The parser is robust against truncated input."

# Source files only warn, and the warning must be printed.
expect "long dash in source"         accepted src/a.lisp "(defun f () \"a ${EM} b\")"
if grep -q 'long dash or stock phrase in source' "$scratch/out"; then
  pass=$((pass + 1)); echo "ok    source warning printed"
else
  fail=$((fail + 1)); echo "FAIL  source warning not printed"
fi

# Exemptions.
expect "skill file exempt"           accepted skills/x/SKILL.md "Delve ${EM} load-bearing."
expect "licence file exempt"         accepted LICENSE "Copyright ${EM} all rights."
expect "style guide exempt"          accepted docs/writing-style.org "Never write load-bearing or delve."
git -C "$repo" config --add dsmr.workproductlint.styleexempt 'fixtures/*'
expect "configured exemption"        accepted fixtures/f.md "A ${EM} fixture."
git -C "$repo" config --unset-all dsmr.workproductlint.styleexempt

# Commit messages.
expect "clean message"               accepted docs/m1.md "Plain." "docs: describe the core rebuild"
expect "dash in message"             refused  docs/m2.md "Plain." "docs: describe the core ${EM} rebuild"
expect "stock phrase in message"     refused  docs/m3.md "Plain." "$(printf 'docs: tidy\n\nIn conclusion, this is better.')"
expect "one warn word in message"    accepted docs/m4.md "Plain." "$(printf 'docs: tidy\n\nThe parser is robust now.')"
expect "dense warn words in message" refused  docs/m5.md "Plain." "$(printf 'docs: tidy\n\nA robust fix.\nIt serves as a base.\nWe leverage it fully.')"
expect "code with a mind warns only" accepted docs/m6.md "Plain." "$(printf 'docs: tidy\n\nThe server sees the variable.')"
if grep -q 'code described as having a mind' "$scratch/out"; then
  pass=$((pass + 1)); echo "ok    code-with-a-mind warning printed"
else
  fail=$((fail + 1)); echo "FAIL  code-with-a-mind warning not printed"
fi

# The tier can be switched off per repository.
git -C "$repo" config --bool dsmr.workproductlint.style false
expect "style tier disabled"         accepted docs/off.md "A ${EM} dash."
git -C "$repo" config --unset dsmr.workproductlint.style

# Checking a file directly, as for a pull request body.
printf 'In conclusion, it works.\n' > "$scratch/body.md"
if bash "$repo/.git/hooks/dsmr-workproduct-lint.sh" --check-file "$scratch/body.md" >/dev/null 2>&1; then
  fail=$((fail + 1)); echo "FAIL  --check-file accepted a stock phrase"
else
  pass=$((pass + 1)); echo "ok    --check-file refuses a stock phrase"
fi
printf 'The server reads the core.\n' > "$scratch/body2.md"
if (cd "$repo" && bash .git/hooks/dsmr-workproduct-lint.sh --check-file "$scratch/body2.md") >/dev/null 2>&1; then
  pass=$((pass + 1)); echo "ok    --check-file accepts plain text"
else
  fail=$((fail + 1)); echo "FAIL  --check-file refused plain text"
fi
printf '## In conclusion\n\nThe server reads the core.\n' > "$scratch/body3.md"
if (cd "$repo" && bash .git/hooks/dsmr-workproduct-lint.sh --check-file "$scratch/body3.md") >/dev/null 2>&1; then
  fail=$((fail + 1)); echo "FAIL  --check-file skipped a Markdown heading"
else
  pass=$((pass + 1)); echo "ok    --check-file reads Markdown headings"
fi

echo "style lint: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
