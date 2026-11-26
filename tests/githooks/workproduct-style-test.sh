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
ATTR="Gener""ated with Cla""ude Code"
IDX="pha""se-3"
PLAN=".plan""ning/STATE.md"   # split so this file does not hold the string it tests
expect "agent definition exempt"     accepted agents/x.md "Write to ${PLAN} ${EM} then stop."
expect "agents README not exempt"    refused  agents/README.md "Agents ${EM} here."
# expect_blocked NAME PATH CONTENT: refused by any tier.
expect_blocked() {
  local name="$1" path="$2" content="$3"
  mkdir -p "$(dirname "$repo/$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add -- "$path"
  if git -C "$repo" commit -q -m "add a file" >"$scratch/out" 2>&1; then
    fail=$((fail + 1)); echo "FAIL  $name: accepted"
  else
    pass=$((pass + 1)); echo "ok    $name (refused)"
  fi
  git -C "$repo" reset -q --hard HEAD
}
expect_blocked "planning reference outside agents/"   docs/planref.md "See ${PLAN}."
expect_blocked "attribution in an agent definition"   agents/x.md "${ATTR}, and see ${PLAN}."
expect_blocked "planning index in an agent definition" agents/x.md "Run ${IDX} first."
expect_blocked "planning reference two levels down"   agents/sub/x.md "See ${PLAN}."
expect "agents subdirectory README linted" refused agents/sub/README.md "Agents ${EM} here."
expect_blocked "skill file still refuses a planning reference" skills/x/SKILL.md "See ${PLAN}."
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

# The attribution trailer is a mark-and-name line, not the name anywhere.
TRAILER=$(printf '\xf0\x9f\x84\xaf Brian O'"'"'Reilly <fade@deepsky.com>, 2026')
printf 'docs: tidy\n\nAuthor: Brian O'"'"'Reilly wrote this.\n' > "$scratch/notrailer.txt"
if (cd "$repo" && bash .git/hooks/dsmr-workproduct-lint.sh --check-file "$scratch/notrailer.txt") 2>&1 \
     | grep -q 'no attribution trailer'; then
  pass=$((pass + 1)); echo "ok    name in the body does not count as a trailer"
else
  fail=$((fail + 1)); echo "FAIL  name in the body hid a missing trailer"
fi
printf 'docs: tidy\n\nPlain body.\n\n%s\n' "$TRAILER" > "$scratch/trailer.txt"
if (cd "$repo" && bash .git/hooks/dsmr-workproduct-lint.sh --check-file "$scratch/trailer.txt") 2>&1 \
     | grep -q 'no attribution trailer'; then
  fail=$((fail + 1)); echo "FAIL  a real trailer was reported missing"
else
  pass=$((pass + 1)); echo "ok    a real trailer is recognized"
fi

# The dsmr.attribution.glyph override, including none for a repository that takes no trailer.
TRAILER_C=$(printf '\xc2\xa9 Brian O'"'"'Reilly <fade@deepsky.com>, 2026')
SIGN_C=$(printf '\xc2\xa9')
# The unknown-value cases rely on the derivation yielding copyright.
if [ ! -f "$repo/LICENSE" ] || grep -qiE 'affero|AGPL' "$repo/LICENSE"; then
  fail=$((fail + 1)); echo "FAIL  glyph cases: fixture: no non-AGPL LICENSE, so the derivation would not yield copyright"
fi
# Without shellcheck on PATH the shell-lint companion writes a notice to stderr
# on every commit, and the silent cases assert empty stderr.
git -C "$repo" config --bool dsmr.shellcheck.enabled false
# expect_attr NAME accepted|refused NEEDLE MESSAGE: commits a fresh file with
# MESSAGE. Empty NEEDLE: the commit stderr must be empty (git runs commit-msg
# with its stdout on stderr). Otherwise the output must name NEEDLE.
expect_attr() {
  local name="$1" want="$2" needle="$3" msg="$4" got why=""
  mkdir -p "$repo/docs"
  printf '%s\n' "$name" > "$repo/docs/glyph.md"
  git -C "$repo" add docs/glyph.md
  printf '%s\n' "$msg" > "$scratch/attr-msg.txt"
  if git -C "$repo" commit -q -F "$scratch/attr-msg.txt" >"$scratch/attr.out" 2>"$scratch/attr.err"; then
    got=accepted
  else
    got=refused
  fi
  if [ "$got" != "$want" ]; then
    why="wanted $want, got $got"
  elif [ -z "$needle" ] && [ -s "$scratch/attr.err" ]; then
    why="commit wrote to stderr"
  elif [ -n "$needle" ] && ! cat "$scratch/attr.out" "$scratch/attr.err" | grep -aqF -- "$needle"; then
    why="output does not name '$needle'"
  fi
  if [ -z "$why" ]; then
    pass=$((pass + 1)); echo "ok    $name ($want)"
  else
    fail=$((fail + 1)); echo "FAIL  $name: $why"
    cat -v "$scratch/attr.out" | sed 's/^/        out: /'
    cat -v "$scratch/attr.err" | sed 's/^/        err: /'
  fi
  git -C "$repo" reset -q --hard HEAD
}
git -C "$repo" config dsmr.attribution.glyph none
expect_attr "glyph none: no trailer, no warning" accepted "" \
  "$(printf 'docs: tidy\n\nPlain body.')"
expect_attr "glyph none: copyleft trailer refused" refused "takes no attribution trailer" \
  "$(printf 'docs: tidy\n\nPlain body.\n\n%s' "$TRAILER")"
expect_attr "glyph none: copyright trailer refused" refused "takes no attribution trailer" \
  "$(printf 'docs: tidy\n\nPlain body.\n\n%s' "$TRAILER_C")"
expect_attr "glyph none: copyright sign in prose is not a trailer" accepted "" \
  "$(printf 'docs: note the %s year in the notice\n\nPlain body.' "$SIGN_C")"
# The derivation here yields copyright, so the copyleft mark is the wrong one:
# with none, the wrong-mark check must not run at all.
expect_attr "glyph none: copyleft mark in prose is not a trailer" accepted "" \
  "$(printf 'docs: note the %s mark\n\nPlain body.' "$(printf '\xf0\x9f\x84\xaf')")"
if cat "$scratch/attr.out" "$scratch/attr.err" | grep -aqF -- 'wrong attribution mark'; then
  fail=$((fail + 1)); echo "FAIL  glyph none: the wrong-mark check ran"
else
  pass=$((pass + 1)); echo "ok    glyph none: the wrong-mark check does not run"
fi
expect_attr "glyph none: mark and name mid-line is not a trailer" accepted "" \
  "$(printf 'docs: tidy\n\nThe old notice read %s Brian O'"'"'Reilly 2019.' "$SIGN_C")"
git -C "$repo" config dsmr.attribution.glyph bogus
expect_attr "unknown glyph value: missing trailer still warns" accepted "no attribution trailer found" \
  "$(printf 'docs: tidy\n\nPlain body.')"
expect_attr "unknown glyph value: copyleft trailer refused as the wrong mark" refused "wrong attribution mark" \
  "$(printf 'docs: tidy\n\nPlain body.\n\n%s' "$TRAILER")"
if cat "$scratch/attr.out" "$scratch/attr.err" | grep -aqF -- 'glyph copyleft|copyright|none'; then
  pass=$((pass + 1)); echo "ok    wrong-mark remedy names the none value"
else
  fail=$((fail + 1)); echo "FAIL  wrong-mark remedy names the none value"
fi
expect_attr "unknown glyph value: copyright trailer accepted" accepted "" \
  "$(printf 'docs: tidy\n\nPlain body.\n\n%s' "$TRAILER_C")"
git -C "$repo" config --unset dsmr.attribution.glyph
git -C "$repo" config --unset dsmr.shellcheck.enabled

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

# Binary and non-UTF-8 staged content leaves stderr empty, and every check still reads the text.
skip=0
# An earlier case commits a non-AGPL LICENSE; pin the mark TRAILER carries.
git -C "$repo" config dsmr.attribution.glyph copyleft
# Only the NUL case exercises shell lint; the rest run without shellcheck.
git -C "$repo" config --bool dsmr.shellcheck.enabled false
# A non-UTF-8 byte is binary to grep only under a UTF-8 LC_CTYPE, so the cases
# below run under one whatever the caller's locale is. The hooks under test set
# LC_ALL=C per command.
utf8=$(locale -a 2>/dev/null | grep -aiE '^(C|en_US|en_CA)\.utf-?8$' | head -1)
if [ -n "$utf8" ]; then export LC_ALL="$utf8"; fi
# Live only when a bare grep really reports the byte as binary.
locale_live=no
if printf 'a\377\n' | grep a 2>&1 | grep -q 'binary file matches'; then locale_live=yes; fi

# expect_quiet NAME refused|accepted [HEADER [SUBJECT]]: files are already staged
# in $repo. SUBJECT replaces the commit subject. Passes when all of these hold:
#   - the outcome is WANT
#   - the pre-commit stderr is empty
#   - accepted: the commit stderr is empty
#   - refused: the pre-commit stdout or the commit output names HEADER
# Skips when no UTF-8 locale is live, or when shell lint is on and shellcheck is
# missing (its notice goes to stderr).
expect_quiet() {
  local name="$1" want="$2" header="${3:-}" subject="${4:-chore: add a fixture}" got why=""
  if [ "$locale_live" != yes ]; then
    skip=$((skip + 1))
    echo "SKIP  $name: no UTF-8 locale is installed, so grep would not read the byte as binary"
    git -C "$repo" reset -q --hard HEAD
    return
  fi
  if [ "$(git -C "$repo" config --bool --get dsmr.shellcheck.enabled)" != false ] \
     && ! command -v shellcheck >/dev/null 2>&1; then
    skip=$((skip + 1))
    echo "SKIP  $name: shellcheck is not on PATH; the shell-lint companion reports that on stderr"
    git -C "$repo" reset -q --hard HEAD
    return
  fi
  (cd "$repo" && bash .git/hooks/pre-commit) >"$scratch/pc.out" 2>"$scratch/pc.err"
  if printf '%s\n\n%s\n' "$subject" "$TRAILER" \
       | git -C "$repo" commit -q -F - >"$scratch/cm.out" 2>"$scratch/cm.err"; then
    got=accepted
  else
    got=refused
  fi
  if [ "$got" != "$want" ]; then
    why="wanted $want, got $got"
  elif [ -s "$scratch/pc.err" ]; then
    why="pre-commit wrote to stderr"
  elif [ "$want" = accepted ] && [ -s "$scratch/cm.err" ]; then
    why="commit wrote to stderr"
  elif [ "$want" = refused ] \
       && ! cat "$scratch/pc.out" "$scratch/cm.out" "$scratch/cm.err" | grep -aqF -- "$header"; then
    why="the refusal does not name '$header'"
  fi
  if [ -z "$why" ]; then
    pass=$((pass + 1)); echo "ok    $name ($want, stderr empty)"
  else
    fail=$((fail + 1)); echo "FAIL  $name: $why"
    cat -v "$scratch/pc.err" | sed 's/^/        pre-commit: /'
    cat -v "$scratch/cm.err" | sed 's/^/        commit: /'
  fi
  git -C "$repo" reset -q --hard HEAD
}

# fixture_fail NAME REASON: count the case as failed when its fixture is not the
# intended one, so a control cannot pass vacuously.
fixture_fail() {
  fail=$((fail + 1)); echo "FAIL  $1: fixture: $2"
  git -C "$repo" reset -q --hard HEAD
}

# 400 bytes, byte i = (i*167 mod 255) + 1: no NUL, two 0xFF, one newline.
make_blob() {
  LC_ALL=C awk 'BEGIN { for (i = 0; i < 400; i++) printf "%c", (i * 167 % 255) + 1 }' > "$1"
}
numstat_text() {
  git -C "$repo" diff --cached --numstat -- "$1" | grep -qE '^[0-9]+[[:space:]]+[0-9]+[[:space:]]'
}

n="binary blob stays quiet"
make_blob "$repo/blob.bin"
git -C "$repo" add blob.bin
size=$(wc -c < "$repo/blob.bin")
nuls=$(LC_ALL=C tr -cd '\000' < "$repo/blob.bin" | wc -c)
ffs=$(LC_ALL=C tr -cd '\377' < "$repo/blob.bin" | wc -c)
if [ "$size" -ne 400 ]; then fixture_fail "$n" "size is $size, not 400"
elif [ "$nuls" -ne 0 ]; then fixture_fail "$n" "holds a NUL"
elif [ "$ffs" -lt 1 ]; then fixture_fail "$n" "holds no 0xFF byte"
elif ! numstat_text blob.bin; then fixture_fail "$n" "git treats the blob as binary"
else expect_quiet "$n" accepted
fi

n="long dash in prose beside a binary blob"
mkdir -p "$repo/docs" "$repo/bin"
printf 'The server reads the core %s at start.\n' "$EM" > "$repo/docs/dash-beside-blob.md"
make_blob "$repo/bin/beside.bin"
git -C "$repo" add docs/dash-beside-blob.md bin/beside.bin
expect_quiet "$n" refused "long dash in prose"

n="attribution on a line with a non-UTF-8 byte"
mkdir -p "$repo/docs"
{ printf 'ok\n'; printf '%s \377\n' "$ATTR"; } > "$repo/docs/latin1.md"
git -C "$repo" add docs/latin1.md
expect_quiet "$n" refused "AI-attribution"

n="long dash on a prose line with a non-UTF-8 byte"
mkdir -p "$repo/docs"
printf 'a %s b \351\n' "$EM" > "$repo/docs/latin1-dash.md"
git -C "$repo" add docs/latin1-dash.md
expect_quiet "$n" refused "long dash in prose"

n="attribution after a late NUL byte"
mkdir -p "$repo/notes"
{ head -c 8200 /dev/zero | LC_ALL=C tr '\000' 'a'; printf '\nxx\000yy\n%s\n' "$ATTR"; } > "$repo/notes/late-nul.txt"
git -C "$repo" add notes/late-nul.txt
if [ "$(LC_ALL=C tr -cd '\000' < "$repo/notes/late-nul.txt" | wc -c)" -ne 1 ]; then fixture_fail "$n" "holds no NUL"
elif ! numstat_text notes/late-nul.txt; then fixture_fail "$n" "git treats the file as binary"
else expect_quiet "$n" refused "AI-attribution"
fi

n="long dash on a commit message line with a non-UTF-8 byte"
mkdir -p "$repo/docs"
printf 'Plain.\n' > "$repo/docs/msg-case.md"
git -C "$repo" add docs/msg-case.md
expect_quiet "$n" refused "long dash in the message" "$(printf 'docs: a %s b \377' "$EM")"

# Real gzip output: byte 0x00 sits in the header's first line.
git -C "$repo" config --unset dsmr.shellcheck.enabled
n="NUL in the first line of a staged blob"
printf 'seed\n' | gzip -n > "$repo/seed.txt.gz"
git -C "$repo" add seed.txt.gz
if [ "$(LC_ALL=C tr -cd '\000' < "$repo/seed.txt.gz" | wc -c)" -lt 1 ]; then fixture_fail "$n" "holds no NUL"
elif ! git -C "$repo" diff --cached --numstat -- seed.txt.gz | grep -qE '^-[[:space:]]+-[[:space:]]'; then
  fixture_fail "$n" "git treats the blob as text"
else expect_quiet "$n" accepted
fi

echo "style lint: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
