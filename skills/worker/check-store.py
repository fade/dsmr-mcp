#!/usr/bin/env python3
"""Check a memory store's frontmatter. The index checks in the skill do not parse
YAML, so a store passes all of them while carrying unreadable or silently
truncated frontmatter.

Two classes, and only one of them is loud:

  THROW  frontmatter that raises, or parses to something other than a mapping.
         A plain sweep finds the raiser. The non-mapping case is quieter: a
         delimited block holding prose parses fine as a str, and then every
         field test degrades to a SUBSTRING test and passes.

  HIDE   frontmatter that parses TRUE while dropping content. An unquoted
         scalar containing ' #' opens a YAML comment and the tail is discarded.
         The file reads correctly on the page. This class has destroyed unique
         content that existed nowhere else.

HIDE is decided on a PRECONDITION rather than on a truncation detector: count
' #' at any depth and count plain-scalar continuation lines. With no ' #' in the
block, no comment can open and the class cannot bite, whatever the detector's
sharpness. Detectors written for this repeatedly shipped with a predicate that
could not fire; a precondition has less to get wrong, and its controls below
prove it fires.

Exit: 0 clean, 1 findings, 2 could not run (including a control that failed).
"""
import sys, pathlib, tempfile, yaml


def frontmatter(text):
    """Lines between a bare '---' on line 1 and the next bare '---', or None.

    Splitting on the SUBSTRING '---' instead matches a rule inside prose, which
    hands a slab of body text to the parser and reports it as frontmatter.
    """
    lines = text.split("\n")
    if lines[:1] != ["---"]:
        return None
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    return None if end is None else lines[1:end]


def audit(paths):
    bad, hashes, conts, nofm, ok, seen = [], [], [], [], 0, 0
    for p in paths:
        fm = frontmatter(p.read_text())
        if fm is None:
            nofm.append(p.name)
            continue
        seen += 1
        try:
            parsed = yaml.safe_load("\n".join(fm))
        except Exception as e:
            bad.append((p.name, f"{type(e).__name__}: {str(e).splitlines()[0]}"))
            continue
        if parsed is None:
            bad.append((p.name, "frontmatter block is empty"))
            continue
        if not isinstance(parsed, dict):
            bad.append((p.name, f"parses to {type(parsed).__name__}, not a mapping"))
            continue
        ok += 1
        plain_open = False
        for n, line in enumerate(fm, 1):
            stripped = line.strip()
            indented = line[:1] in (" ", "\t")
            # ' #' at ANY depth: nested values under metadata: truncate too.
            if " #" in line:
                hashes.append((p.name, n, stripped))
            # A continuation line is INDENTED and carries no 'key:'. Writing this
            # as 'unindented' produces a predicate that cannot fire and a zero
            # that means nothing.
            if indented and stripped and ":" not in stripped and plain_open:
                conts.append((p.name, n, stripped))
            if not indented and ":" in line:
                val = line.partition(":")[2].strip()
                plain_open = bool(val) and val[:1] not in ('"', "'")
    return dict(bad=bad, hashes=hashes, conts=conts, nofm=nofm, ok=ok, seen=seen)


def controls():
    """Every class must be shown to fire before any zero below is trusted.

    A correction needs its OWN controls. Inheriting them from the claim being
    corrected is how a broken predicate ships looking rigorous.
    """
    d = pathlib.Path(tempfile.mkdtemp(prefix="store-control-"))
    (d / "throw.md").write_text("---\ndescription: PAIR: precedence\n---\n\nbody\n")
    (d / "slab.md").write_text("---\njust prose, no mapping here\n---\n\nbody\n")
    (d / "empty.md").write_text("---\n---\n\nbody\n")
    (d / "hide.md").write_text("---\ndescription: fixed by PR #40 (tail)\n---\n\nbody\n")
    (d / "nested.md").write_text(
        "---\nname: x\nmetadata:\n  note: nested value with PR #40 (tail)\n---\n\nbody\n")
    (d / "cont.md").write_text(
        "---\ndescription: first line is clean\n"
        "  second line has PR #40 (tail) here\n---\n\nbody\n")
    r = audit(sorted(d.glob("*.md")))
    why = {n: w for n, w in r["bad"]}
    fired = {
        "throw": "throw.md" in why and "Error" in why["throw.md"],
        "non-mapping": "slab.md" in why and "not a mapping" in why["slab.md"],
        "empty": "empty.md" in why,
        "hide": any(n == "hide.md" for n, _, _ in r["hashes"]),
        "nested": any(n == "nested.md" for n, _, _ in r["hashes"]),
        "continuation": any(n == "cont.md" for n, _, _ in r["conts"]),
    }
    # And prove the hide class is real, not merely detected.
    truncated = yaml.safe_load("description: fixed by PR #40 (tail)")["description"]
    fired["hide-is-real"] = truncated == "fixed by PR"
    dead = [k for k, v in fired.items() if not v]
    if dead:
        print(f"CONTROL FAILED: {', '.join(dead)} did not fire. "
              f"Nothing below is evidence.")
        sys.exit(2)
    print(f"control      ok  all {len(fired)} controls fired "
          f"(hide truncates {truncated!r})")


controls()

store = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                     f"~/.claude/projects/{pathlib.Path.cwd().as_posix().replace('/', '-').replace('.', '-')}/memory"
                     ).expanduser()
files = sorted(store.glob("*.md"))
if not files:
    # A scan that reads nothing reports the same clean as a healthy store.
    print(f"REACH CONTROL FAILED: 0 files under {store}")
    sys.exit(2)

r = audit(files)
print(f"reach        ok  {len(files)} files under {store}")
print(f"parse        {r['seen']} with frontmatter / {r['ok']} ok / {len(r['bad'])} BAD"
      f"   ({len(r['nofm'])} without, expected for MEMORY.md)")

unquoted = [(n, ln, s) for n, ln, s in r["hashes"]
            if s.partition(":")[2].strip()[:1] not in ('"', "'")]
print(f"' #' present  {len(r['hashes'])} line(s), {len(unquoted)} UNQUOTED")
print(f"continuations {len(r['conts'])}")

for n, why in r["bad"]:
    print(f"  BAD  {n}: {why}")
for n, ln, s in unquoted:
    print(f"  HIDE {n}:{ln}  {s[:90]}")
for n, ln, s in r["conts"]:
    print(f"  CONT {n}:{ln}  {s[:90]}   <- check the scalar it continues")

if r["bad"] or unquoted or r["conts"]:
    print("\nNEEDS ATTENTION. Quote the scalar; never trim it. ⛔ Before editing, "
          "confirm the discarded tail exists in the body: it has held sha pins "
          "recorded nowhere else.")
    sys.exit(1)
print("\nclean")
