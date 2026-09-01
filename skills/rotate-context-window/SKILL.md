---
name: rotate-context-window
description: "Snapshot in-flight state to a handoff file so the next instance picks up cleanly without re-prompting."
allowed-tools:
  - Read
  - Write
  - Bash
  - Edit
---

<objective>
The operator is about to restart Claude. Before the current instance is
torn down, capture every load-bearing piece of in-flight state into a
single handoff file. The next instance reads that one file as its first
move and is fully oriented — no recurring "where were we" dance.

This skill is silent. Gather state, write the file, print one short
incantation the operator can paste into the fresh instance.
</objective>

<process>

## 1. Determine where the handoff file goes

In priority order:

- If `<repo-root>/.planning/` exists (GSD project), write to
  `<repo-root>/.planning/CURRENT-CONTEXT.md`. Most GSD setups symlink
  `.planning/` out of the repo, so the file is automatically untracked.
- Else if inside a git repo, write to `<repo-root>/CONTEXT-HANDOFF.md`
  and ensure `CONTEXT-HANDOFF.md` is in `.git/info/exclude`.
- Else write to `~/.claude/handoffs/<basename-of-cwd>.md` (mkdir -p).

Determine repo root via `git rev-parse --show-toplevel`. If not a repo,
use `pwd`.

## 2. Gather state

Run these probes in parallel (one Bash call per cheap group is fine):

**Git / branch state**
- `git status --short` (filter out permission-denied lines)
- `git branch --show-current`
- `git log --oneline -10`
- `git log --oneline origin/main..HEAD 2>/dev/null` if a remote exists
- `git stash list 2>/dev/null` (active stashes)

**Project state**
- `ls .planning/` if present
- `head -80 .planning/STATE.md` then `tail -30 .planning/STATE.md` if present
- `ls .planning/todos/pending/ 2>/dev/null` in FULL, and its count.
  ⛔ Never `head` this listing. It is the mechanism for not losing notes,
  so a silent truncation defeats the only thing it is for.
- `ls .planning/phases/ 2>/dev/null | tail -5` to identify the active phase
- If `<active-phase>/README.md` exists, `head -40` of it

**Pending operator review**
- Look at `~/tmp/<repo-name>-commits/` for staged commit messages and PR bodies
  not yet acted on. Match the pattern of "files modified in the last hour"
  rather than every file.

**Cross-repo coordinator state**
- `news-from-sister.md`, `sister-handoff.md`, `coordinator-notes.md`,
  `coordinator.md` — if any are at repo root or under
  `.planning/phases/<phase>/`, note their existence and the last-modified
  time. Read the tail of the most recent one only.

**Untracked scratch files at repo root**
- `git status --short | awk '/^\?\? / && !/\//{print $2}'`
- For each, infer one-line purpose from the filename (overnight-X,
  sde-reimport-Y, refresh-heap-investigation, etc.). Don't read them.

**Live-image state (Common Lisp projects)**
- If `.mcp.json` exists and references slynk-attach, note the port.
- Try `mcp__cl-mcp__repl-eval` with a trivial probe like
  `(list :impl (lisp-implementation-version))`. If it returns, the live
  image is up; record any system the user mentioned having loaded. If
  it errors (slynk drop, attach unavailable, package missing), record
  the failure mode — the new instance needs to know whether to cold-boot
  or attach.
- Do NOT try to enumerate every loaded package or hold state across.

**Background processes the harness is tracking**
- Anything launched with `run_in_background` is owned by the dying
  instance and will not survive. Note them by name and what they were
  waiting on so the new instance can re-spawn if needed.

**Durable IPC bus (dsmr-mcp) — if cross-repo coordination is live**
Detect: a `bus-status` / `bus-receive` / `bus-publish` MCP tool is
available, or a `dsmr-bus-watch` process is among the background
processes, or `.planning/` shows active bus coordination. If none of
these, skip — there is no bus to rejoin.
- Run `bus-status` and record: the agent's **stable bus identity**, its
  namespace, and the pending count. The cursor is server-side and
  **persists across a client restart** — messages posted during the
  downtime are NOT lost; the returning instance drains them.
- Note the `dsmr-bus-watch` wakeup watch as the one background process
  that MUST be re-armed on the other side (it dies with this instance).
  Record the exact arm flags in use (e.g. `--poll-ms 250
  --recycle-seconds 600`) so cadence carries over.
- Drain the cursor now (`bus-receive` until empty) so the handoff is
  written from a known-clean bus state, and note the active coordination
  thread (who leads, who is mid-task, what gates the next step).

## 3. Synthesize the handoff file

Use this section order. Keep sections terse — the new instance reads
this in one pass, not as reference documentation.

```markdown
# Context Rotation — <ISO timestamp UTC>

## Snapshot
- **Project:** <repo basename> at <absolute repo root>
- **Branch:** <current branch> (<N commits ahead of origin/main, M behind>)
- **Reason:** <operator's stated reason, or "context-window pressure">

## FIRST MOVE — rejoin the durable bus (only if a bus is in use)
Include this section only when a durable IPC bus was detected; drop it
entirely otherwise. When present, it goes FIRST — the next instance
rejoins before anything else, because its identity is reachable the
moment it does and siblings may be waiting.
- Identity `<agent>` is a **stable named bus identity**; its cursor is
  server-side and **persisted across the restart** — nothing posted
  during the gap was lost.
- Sequence: `bus-receive` (drain everything that landed during the
  downtime — read it) → then **re-arm the wakeup watch LAST**:
  `dsmr-bus-watch <arm flags from probe>` (run_in_background; **omit
  `--after`**; do a catch-up `bus-receive` immediately before arming;
  arm strictly after any publish).
- Steady-state loop thereafter: drain → act → publish → catch-up drain →
  re-arm. A bare `recycle:` heartbeat wake = **re-arm silently** (no
  operator-facing output); only surface on a real `bus:<SEQ>` message.
- **Process restart:** restart the Claude **client** for context but keep
  the bus MCP server (dsmr-mcp) UP to preserve the live bus + cursors.
  The bus WAL is durable, so even an MCP restart recovers — but only
  restart it if it is actually wedged; a clean context rotation is not a
  wedge.

## The active thread (read this first)
What the operator most recently asked for, in their own words if
possible. What state that work is in right now. If a slash command or
workflow is mid-execution, name it and the step within it.

## What just happened (last 3–5 moves)
Single-line entries, newest first. Decision + outcome, not narration.

## Pending operator review
Staged commit messages / PR bodies in `~/tmp/<repo>-commits/` the
operator has not yet greenlit. Path + one-line subject for each.

## Live image
- **Dev-boot:** up | down | unknown
- **Slynk channel:** <port> | none
- **cl-mcp:** attached | hermetic | unavailable
- **Loaded systems of note:** <list if known; "trust dev-boot" otherwise>
- **Cold-boot needed?** yes | no | only-if-X

## Cross-repo state
Sister-handoff / news-from-sister / coordinator files present. Sibling
agent status (running / done / unknown). Most recent log entry's gist.
Skip the section entirely if none present.

## Working tree
**Modified (tracked):**
- file:line — one-line shape

**Untracked scratch at repo root:**
- filename — one-line purpose

**Stashes:** list or "none".

## Open follow-ups: write them to todos/pending NOW, then list them

⛔ **This is a conversion step, not a holding pen.** Anything flagged in
conversation that has not reached `.planning/todos/pending/` gets written
there as a file BEFORE this handoff is finished. Then list the filenames
below, one line each: `filename - what it is`.

⚠ **Prose in a handoff is volatile by construction.** A note left here as
prose survives only if the next rotation re-types it, and the one after
that, and every one after that. It reads as recorded for the whole time it
is decaying, which is why nobody notices until it is gone.

⇒ **The test: if this instance vanished mid-sentence, would the note still
exist as a file?** If not, it is not recorded, however carefully it is
written here.

## Failed paths / dead-ends from this session
What I tried that didn't work, so the new instance doesn't repeat the
loop. Be specific: command, error class, why it failed, what worked
instead.

## Pre-read order for the new instance
Exact paths in the order to read them. Limit to 5; the new instance
should be oriented after this list, not after fishing.

1. `.planning/STATE.md` (head 80 + tail 30)
2. `.planning/todos/pending/` in full. STANDING ENTRY, not a slot to spend:
   these are the notes this session was asked to keep, and a note nobody
   reads was never kept.
3. `<active phase>/README.md` if applicable
4. <coordinator file if present>
5. <staged commit/PR body if applicable>

## First action for the new instance
Concrete. "Run /gsd-resume-work" or "Continue the active thread by
doing X". One line.
```

If a section has no content, drop it. Brevity matters more than
completeness — the file should be readable in under two minutes.

## 3.5 Repair the record before you hand it over (GSD projects)

**Skip only if there is no `.planning/STATE.md`.**

⚠ **Rotation is the single most likely moment to corrupt GSD state**, and the
reason is structural: you are updating `STATE.md` at the exact moment your
context is most exhausted, when *adding* is easier than *collapsing*. The
observed failure is not carelessness, it is a rotating instance appending a
correct new banner above a stale one and considering the job done. Do the six
checks below before writing the handoff; the last one is mechanical and runs the
others' blind spots.

**1. ONE banner, and it must be internally CONSISTENT.** If `STATE.md` opens with
a stack of mutually-superseding warnings, a reader has to adjudicate between them
before doing any work. That stack is not a record of diligence; it is the defect.
Collapse it into one banner carrying the current position, the single next action,
and only those facts that are true and easy to misread.

⚠ **A count of one is necessary and NOT sufficient — this is the trap's second
form.** A single banner piles up contradictions just as readily, and it is harder
to see because nothing looks structurally wrong. One observed banner asserted a
phase complete, repeated that fact in different words, then flatly denied it forty
lines lower, while also carrying a stale `main` sha and a superseded phase count.
Every one of those was added by an instance that correctly refused to stack a
second banner. ⇒ **Read the banner end to end and reconcile it against itself**,
then delete the superseded sentences rather than appending a corrective one. If it
no longer fits in one screen, that is the signal it has stopped being a banner.

**2. The body lies too.** Fixing the banner while leaving a *Current Position*
section naming a finished phase just relocates the contradiction. Grep for the
prior position's claims (`awaiting`, `pending`, `next is`, the old phase number)
and fix every one, or you have moved the problem rather than solved it.

**3. The frontmatter must parse TRUE — and much of it is GENERATED FROM THE BODY,
so fixing the frontmatter alone is silently undone.** ⚠ **If the project uses
`gsd-sdk`, its phase operations STRIP the frontmatter and REBUILD it from the
body** rather than merging into it. Fields outside its schema are dropped, not
preserved-and-ignored.

⛔ **"PARSES TRUE" IS NECESSARY AND NOT SUFFICIENT, and the exception is a
hand-edit hazard that rotation walks straight into.** An unquoted YAML scalar
containing a space followed by `#` **terminates there and parses TRUE**, silently
discarding the rest of the line. Observed during a fleet park, in a freshly
written `last_activity`:

```
last_activity: 2026-07-26, merged PR #40 (fid revocation)
```

stores `'2026-07-26, merged PR'`. Run the control before trusting any sweep — one
line, and it is the only thing that shows the class exists at all:

```
python3 -c "import yaml; print(repr(yaml.safe_load('x: a PR #40 (thing)')['x']))"
# -> 'a PR'
```

⚠ **This sits INSIDE the passing set.** It is not the colon-space or
nested-quote class, which THROW and which a `safe_load` sweep therefore catches.
A repo that passed such a sweep is **not thereby clear of this**, and the value
reads correctly on the page — nothing looks wrong at any point, which is why it
survives review.

⇒ **The check that discriminates is comparing each parsed value against its raw
source text, not merely that the document loads.** Quote any scalar containing
`#` or `:`.

⚠ **Why this lands on rotation specifically:** the SDK's own writer quotes
strings containing `#` or `:`, so tool-written frontmatter is safe. **The hazard
is hand-edited frontmatter** — exactly what a rotating instance produces, at
exactly the moment it is least able to notice. Ticket numbers, PR numbers and
issue references are the usual carriers, and they are natural things to reach for
when writing what just happened.

⛔ **`STATE.md` contains MACHINE-INTERFACE LINES that look exactly like prose, and
they sit hundreds of lines apart.** Established by observation, not inference:

| Body line | Section it hides in | Regenerates |
|---|---|---|
| `Last activity:` | `## Current Position` | frontmatter `last_activity` |
| `Stopped at:` | `## Session Continuity` | frontmatter `stopped_at` |
| `Phase:` `Plan:` `Status:` | `## Current Position` | position fields |

The writer sources these from the body with **no frontmatter fallback**, while the
reader prefers frontmatter. The SDK therefore reads values it will not preserve.
Two consequences, both observed:

- **Rewording or reformatting one of those lines DELETES its frontmatter field** on
  the next phase operation. The damage is invisible when caused and lands on a
  later instance. Leave a standing warning beside them — the next person to tidy
  that section will otherwise read them as ordinary prose.
- **A stale one regenerates forever.** `Stopped at: context exhaustion at 75%` sat
  in `## Session Continuity` and repopulated the frontmatter for **three days**
  after the condition passed, surviving direct frontmatter edits. ⇒ **Fix the BODY
  line.** A stale `stopped_at` makes a cleanly parked repo read as one that died
  mid-task.

`progress:` is the genuine exception: the SDK owns it and recomputes it from disk.
Correct it if it is wrong at rest, expect it back, and state the true figure in the
banner along with where it comes from — **computed from ROADMAP checkboxes, never
asserted**.

⚠ **Verify every edit landed.** Use a method that reports a substitution count
and check it is non-zero. A field that the SDK deleted looks identical to a field
you successfully edited if you never check.

**4. Archive, never delete.** `.planning/` is outside git: no diff, no revert,
and rulings recorded nowhere else routinely live in exactly the text you are
about to replace. Move the superseded head to a dated sibling
(`STATE.md.superseded-head-<date>-<topic>`) and **do not clobber an existing
archive** — check the name is free first.

**5. LENGTH IS ITSELF A DEFECT. Retire before you hand over.** A long `STATE.md`
produces amnesia in the next instance by a concrete mechanism, not vaguely: the
file stops being read whole, so the live position ends up wrapped in history that
is indistinguishable from it, and the machine-interface lines of check 3 end up
hundreds of lines apart where no one meets both.

Observed: 876 lines, of which **54% sat in two sections whose own names admit they
only grow** (`## Accumulated Decisions`, `## Accumulated Context`), the live
position was ~20 useful lines inside 173, the two machine-interface blocks were
**737 lines apart**, and there were two different sections both titled
`## Deferred Items`. It retired to 212 lines with nothing lost.

**The rule: retire at milestone close, and check size at every rotation and every
fleet park. Over ~200 lines, retire the oldest closed-phase material first.**

Keep only what must be read in order to act: frontmatter, the one banner,
`## Current Position`, live deferred items, `## Session Continuity`, next steps.
Move the rest to `.planning/state-archive/<section>-<milestone>.md`.

- ⛔ **Archive, never delete** (see check 4) and **always leave a pointer**, so
  nothing becomes unfindable. Never remove a pointer to make room.
- ⛔ **Never move the machine-interface lines out.** Split a section around them
  rather than archiving it wholesale.
- ⚠ **Move content by line range, do not retype it.** Byte-exact extraction keeps
  rulings intact; paraphrasing while exhausted is how a ruling quietly changes.
- ⚠ Verify afterwards that each machine-interface line survives exactly once, the
  banner count is one, no heading is duplicated, and every pointer resolves.

**6. Run the triage, and run it LAST.** The five checks above are judgement;
this one is mechanical and catches the failures that survive judgement:

```
python3 ~/.claude/skills/rotate-context-window/triage-state.py .planning/STATE.md
```

It runs its own positive control first and refuses to report at all if the
control does not fire, so a clean result cannot come from a check that was never
capable of failing. Then: the frontmatter parses; no scalar was silently
truncated (check 3); every machine-interface body line is present; banner count
and file length are reported as advisories. Exit non-zero means something needs
a look.

⚠ **A pass is not permission to skip checks 1, 2 and 5.** It cannot see a banner
that contradicts itself, a body that names a finished phase, or content that
should have been retired. It sees only what a regex can decide.

Finally, **cross-link `STATE.md` and the handoff file in both directions**. They
are separate entry points and a fresh instance may arrive through either; neither
should be able to orient a reader while leaving them ignorant of the other.

## 4. Write and announce

- Write the file at the path chosen in step 1.
- If the path is in repo root and not in `.git/info/exclude`, append it.
- Print exactly one line to the operator, naming the file and the
  paste-in incantation for the fresh instance:

```
Handoff written: <path>
Paste into the new instance: read <path> and continue.
```

No other output. The operator is about to restart; long replies are
context they will not carry forward.

</process>

<style>
- Imperative voice in the handoff file. "Branch is at X. Operator
  approved Y. Next action is Z."
- No AI-orchestration vocabulary (no "Phase N Wave M", no "subagent
  spawned", no "based on memory X"). The handoff is for a fresh
  instance that will re-discover memory on its own.
- No reference to internal planning indices, requirement IDs, or
  decision tags. The new instance reads STATE.md / phase README and
  picks those up from there.
- The handoff file is operator-grade prose — readable by a human who
  glances at it before pasting the incantation.
- Footer at the bottom of the handoff file matches the project's
  attribution convention if one applies (check `~/.claude/CLAUDE.md`
  and the project's `CLAUDE.md`); skip the footer otherwise.
</style>

<scope>
- This skill writes ONE file. It does not commit, push, or notify.
- It does not preserve background processes (those are owned by the
  dying instance) — it only records what was running so the new
  instance can re-launch them.
- It does not capture full conversation history. The next instance
  has the harness summary plus the handoff file — that is the
  contract.
- If the operator wants the handoff file checked into history, that
  is a separate explicit ask. Default is operator-local.
</scope>
