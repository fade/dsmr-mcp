#!/usr/bin/env python3
"""Triage STATE.md before handing over. Exits non-zero if anything needs a look."""
import re, sys, yaml

if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
    print(__doc__.strip())
    print("\nusage: triage-state.py [PATH]   (default: .planning/STATE.md)")
    print("exit: 0 clean or not applicable, 1 needs attention, 2 could not run")
    sys.exit(0)

path = sys.argv[1] if len(sys.argv) > 1 else ".planning/STATE.md"
try:
    text = open(path).read()
except OSError as e:
    print(f"cannot read {path}: {e.strerror}")
    sys.exit(2)
problems = []

# Control first: if this does not fire, the truncation check below proves nothing.
if yaml.safe_load("x: a PR #40 (thing)")["x"] != "a PR":
    print("CONTROL FAILED - this yaml does not truncate; check 2 is not meaningful")
    sys.exit(2)
print("control      ok (unquoted ' #' truncates, so check 2 can fire)")

# Frontmatter is delimited by a bare '---' on line 1 and the next bare '---'.
# Splitting on the SUBSTRING instead matches a '---' inside prose, which both
# crashes on files that have fewer than two and, far worse, hands a slab of
# prose to the parser and reports 'parses ok' for a file with no frontmatter
# at all. A green that means nothing is the failure this check exists to catch.
_lines = text.split("\n")
_end = next((i for i in range(1, len(_lines))
             if _lines[i].strip() == "---"), None) if _lines[:1] == ["---"] else None
if _end is None:
    print("frontmatter  NONE - this STATE.md carries no frontmatter block.")
    print("             That is a VALID form: a repo with no milestone in flight is")
    print("             correctly served by a prose file naming where state lives.")
    print("             Checks 1-3 do not apply; nothing to triage.")
    sys.exit(0)
raw_fm, body = "\n".join(_lines[1:_end]), "\n".join(_lines[_end + 1:])

# 1. Does it parse at all?
try:
    fm = yaml.safe_load(raw_fm)
except Exception as e:
    print(f"parses       FAIL {type(e).__name__}: {e}")
    sys.exit(1)

# Parsing is not enough: the result must be a MAPPING. A delimited block holding
# a slab of prose parses fine as a plain string, and then every field test below
# degrades silently, because `key not in some_string` is a SUBSTRING test rather
# than a lookup. Each check passes, and the file reports clean while nothing was
# actually inspected. That is the same false green the delimiter check above
# exists to prevent, one level further down. An empty block is a different case
# and is legitimate: there is simply nothing to test.
if fm is None:
    fm = {}
    print("parses       ok (frontmatter block is empty; nothing to inspect)")
elif not isinstance(fm, dict):
    print(f"parses       FAIL frontmatter is a {type(fm).__name__}, not a mapping "
          f"- checks 2 and 3 cannot inspect it")
    sys.exit(1)
else:
    print("parses       ok")

# 2. Silent truncation: an unquoted scalar carrying ' #' loses everything after
#    it, because YAML reads that as a comment. The value still parses, and still
#    reads correctly on the page, which is what makes it worth a check.
#
#    Do NOT implement this by comparing a parsed value against the physical line
#    that starts it. That instrument is wrong in both directions and both were
#    reproduced: a healthy plain scalar continued over an indented line parses
#    LONGER than its first line and gets flagged as loss, while a truncation on
#    an INDENTED or nested key is never examined at all and reports clean. It
#    cries wolf on good files and stays silent on the real thing.
#
#    Key on the precondition instead, at any depth: an unquoted scalar whose
#    source carries ' #'. Then confirm the loss is real by checking whether the
#    discarded tail survives anywhere in the parsed tree, so a ' #' inside a
#    QUOTED value stays inert and is not reported. That makes ' #' a candidate
#    filter and the survival check the finding.
def _strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from _strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from _strings(v)

_kept = list(_strings(fm))
for n, line in enumerate(raw_fm.splitlines(), 1):
    scalar = re.sub(r"^\s*[A-Za-z_][\w-]*:\s*", "", line)   # strip a key at ANY indent
    if scalar.lstrip()[:1] in ('"', "'", "|", ">", "#", ""):
        continue                      # quoted, block, comment-only or empty: inert
    if " #" not in scalar:
        continue
    tail = scalar.split(" #", 1)[1].strip()
    if tail and not any(tail in k for k in _kept):
        problems.append(
            f"line {n}: ' #{tail[:60]}' is DISCARDED as a YAML comment "
            f"and survives nowhere in the parsed frontmatter - QUOTE THE VALUE")
print(f"truncation   {'ok' if not problems else 'FAIL'}")

# 3. Machine-interface body lines. Losing one deletes its frontmatter field
#    on the next SDK phase operation.
#    Only demand a body line when the frontmatter actually carries the field it
#    feeds. Not every repo uses this schema: some carry a nested 'position:'
#    mapping instead, and demanding these lines there reports five failures
#    against a healthy file. Derive the requirement from the frontmatter in
#    hand rather than assuming one repo's shape is the fleet's.
for field, key in (("Last activity", "last_activity"), ("Phase", "phase"),
                   ("Plan", "plan"), ("Status", "status"), ("Stopped at", "stopped_at")):
    if key not in fm:
        continue
    if not re.search(rf"^{re.escape(field)}:[ \t]*(.+)", body, re.I | re.M):
        problems.append(f"body line '{field}:' MISSING - regenerating field will be dropped")
print(f"body lines   {'ok' if not any('MISSING' in p for p in problems) else 'FAIL'}")

# 4. Banner count and length, both advisory.
#    Count ONLY the head region, everything before the first '##' section. The
#    defect is a file that OPENS with stacked superseding warnings. A warning
#    inside a section is usually a real qualification, and flagging those pushes
#    a tired instance to delete correct content, so a false positive here costs
#    more than a miss.
#    Count BLOCKS, not quoted lines. One banner is a single blockquote many
#    lines long, so counting '^>' lines reports a healthy file as 77 banners and
#    sends the reader to collapse the very section worth keeping.
head = body.split("\n## ")[0]
blocks, in_block = 0, False
for line in head.splitlines():
    if line.startswith(">"):
        if not in_block:
            blocks += 1
        in_block = True
    else:
        in_block = False          # a bare blank line ends a blockquote in markdown
banners = blocks + len(re.findall(r"^⚠ \*\*", head, re.M))
lines = len(text.splitlines())
print(f"head banners {banners}{'  <- collapse to one' if banners > 1 else ''}")
print(f"length       {lines} lines{'  <- over 200, retire oldest closed material' if lines > 200 else ''}")

if problems:
    print("\nNEEDS ATTENTION:")
    for p in problems:
        print(f"  - {p}")
    sys.exit(1)
print("\nclean")
