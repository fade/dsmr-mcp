---
name: worker
description: "Rebuild a worker (sister) agent's repo-local context, announce to the leader in one line, revalidate the leader/worker contract, PRE-CLEAR every permission the assigned work needs so a denial never blocks mid-task, and arm a watch on each joined bus while proving it is the right one. Takes an optional fleet tag. Use when you are a sister agent starting or resuming a session, after a fleet restart, or whenever the operator types /worker."
---

# /worker

You are a **worker**: one repo, one sister agent, reporting to the leader (valis). This skill puts
you back in command of your own repo and under contract in one pass — and clears your permissions
*before* they can block you.

Read `~/.claude/CLAUDE.md` § *Fleet discipline* — message budget and never-block-silently govern
everything below.

---

## Step 0 — Arm your watch NOW, before anything else in this file

⛔ **Go to Step 7, arm one watcher per joined bus, prove it with the controls, and come back here.
Do not read Step 1 first.**

Arming needs two things you already have: the bus name and your own name. It needs no repo record,
no plan, no permission preflight, no memory store. Everything else in this file is slower than it
is, and some of it is much slower.

⚠ **Until you have armed, you cannot be reached, and nothing says so.** A sister working through the
steps below looks identical from outside to a sister that is listening: the tab is open, the process
is running, the identity is right. Measured 2026-08-15: a sister reached its assigned work without
arming, ran for eleven minutes, and fell forty messages behind. Nothing reported it. It was found
because a person happened to look.

⇒ **The ordering is the protection.** If the first thing you do is become reachable, there is no
window in which you can be handed work while deaf. If arming is last, every step before it is that
window — and the permission preflight in Step 3 can occupy a whole turn on its own.

⇒ **If a task arrives before you have finished this file, arm first and answer second.** A dispatch
you can hear is worth more than a preflight you have completed.

```bash
cat .planning/PARK.md
git rev-parse HEAD; git branch --show-current
git status --porcelain --untracked-files=no | wc -l
```

Check out `PARK.md`'s `branch`; confirm live HEAD equals its `sha`.
⛔ **Mismatch ⇒ STOP. Report it and do no work.** That check is the only thing separating a correct
resume from a silent divergence.

⚠ **DIAGNOSE THE FIELD BEFORE COMPARING IT.** `git rev-parse HEAD` returns 40 characters. A parked
`sha` of any other length can never match, so a comparison alone reports a **FALSE DIVERGENCE** and
halts a repo that parked perfectly cleanly, inverting the one signal this protocol exists to provide.

```bash
parked=$(awk '/^sha:/{print $2}' .planning/PARK.md)
case "$parked" in
  [0-9a-f]*) [ ${#parked} -eq 40 ] || echo "FORMAT DEFECT: sha is ${#parked} chars, not 40" ;;
  *)         echo "FORMAT DEFECT: sha unreadable" ;;
esac
```

⇒ **A short sha is a FORMAT DEFECT, not a divergence.** Say which one you found; they call for
opposite responses. Repair the field from `git rev-parse HEAD` and continue.

**Writing it, so there is nothing to remember:** derive the field with `git rev-parse HEAD` and read
it back from the file afterwards to confirm what landed. ⛔ Never expand or retype a short sha you
have seen quoted, and never copy one out of a merge confirmation. ⚠ **This has happened to an agent
whose park was otherwise exemplary** -- content-verified guard, cold gate with a proven red, archive
with a fired control. **Care did not prevent it and more emphasis here will not either**, which is
why the check above exists rather than another sentence telling you to be careful.

No `PARK.md`? Say so plainly — do not reconstruct one from memory and present it as state.

### ⛔ FIRST, CHECK ANY PR YOUR RECORD CALLS OPEN. Before you trust the rest of the file.

If `PARK.md` records an open PR, **query its real state now**, before believing anything else in the
file. If it merged or closed while you were down, `sha`, `branch` and `open_prs` are all false and so
is every sentence making a claim about them.

⚠ **This is nobody's lapse and you cannot prevent it from your side.** A PR is frequently merged
**from outside your session**, by a leader or by the operator, and nothing in your repo can know. The
rule that the mover updates the record in the same act is correct and does not apply, because the
mover is not you. Reconcile, then continue.

## Step 2 — Load the plan you are working under

Read `.planning/STATE.md`. It is the entry point, and it does one of two things — **both are valid**:

- **A.** carries real, current GSD state → know your phase number before you touch anything; or
- **B.** says plainly there is no milestone in flight and **names where state actually lives**
  (e.g. `CURRENT-CONTEXT.md`, per-workstream dirs).

⛔ **Not every repo needs a ROADMAP.** A pure library with no phases is correctly served by (B); a
four-line STATE.md pointing at the real record is a complete answer, not a gap to be filled.

⛔ **If STATE.md is MISSING, say so and stop — do not reconstruct one from memory.** An invented
roadmap is worse than an absent one.

⚠ **If it is PRESENT but STALE, that is the more dangerous case and it is on you to notice:** absence
is visible, misleading presence is not. A record that reads as current state will sequence work onto
a closed milestone and nothing will error. **Check it against the repo — a version trail that stops
short, a "completed" count exceeding "total", a milestone the git log passed weeks ago.** Report it
in one line; add a dated header naming what it omits and pointing at the real source. **Never rewrite
it, never reconstruct the history it lost.**

⛔ **ONE header, never a stack.** If a dated staleness header is ALREADY there, **replace it** — do
not add a second one beneath it. Headers accumulate one per instance, and four restarts in, the file
opens with a pile of mutually superseding warnings that a reader has to adjudicate before doing any
work. That pile is not a record of diligence; it is the defect, and each instance that adds to it
believes it is being careful.

⚠ **A header is a flag, not a fix, and you are not the one who fixes it.** Repairing the record
(frontmatter that parses true, one banner, the position block corrected) is the **leader's** job
because it needs the whole-fleet picture. So when you replace a header, **tell the leader in your one
line that the record needs reconciling** — otherwise the flag is raised forever and nobody is
obliged to act on it. Say `STALE-RECORD <repo>: <one sentence>`, and carry on with your work; this
is a report, never a block.

Then cold-verify the image (project root, `load-system`).

## Step 3 — Permission preflight ← *the step that protects the operator's day*

The operator has two days a week. A worker that discovers a permission denial mid-task turns him
into an errand boy paging between every terminal in the fleet. **Find every grant you need NOW, in one batch.**

1. **Enumerate** the commands your assigned phase actually requires — from the scripts and Makefiles
   you will run, not from memory.
2. **Read the real invocation out of the source.** ⚠ A rule written from a *reconstructed* command
   will not match the real one: a driver that builds `ssh -o … user@$(cat ip)` is never matched by a
   rule naming `ssh user@1.2.3.4`, and an address read from a DHCP file rots silently on the next
   rebuild. **Copy the literal string; never reconstruct it.**
3. **Probe each with a NO-OP payload** — the invocation form, not the effect:
   `nix develop <path> -c env FOO=bar /usr/bin/true`, `--help`, `--dry-run`, `-n`.
   This proves the *form* is accepted without performing the act.
4. ⛔ **A denial is final. Never retry it, never reformulate it, never route around it.** Record it.
5. Prefer the **narrowest** grant that does the job. Scope to a script and a subcommand, not a tool.
   Say plainly when a modest-looking rule is broad in substance — a shell that carries `tofu` and
   `libvirt` authorises VM destruction whatever the rule is called.

Write every denial into `.planning/BLOCKED.md`, one block each, ≤5 lines:

```
BLOCKED: <what you cannot do>
NEEDS:   <the exact literal grant, copied from the real invocation>
WHY:     <the phase/task it gates>
SCOPE:   <what this grant does and does NOT authorise>
```

### ⚠ THE PREFLIGHT CANNOT COVER THE AUTO-MODE CLASSIFIER

The steps above clear the gates that are **configured**. The classifier is a second gate that is not:
a per-call model judgment refusing the call before the MCP server sees it.

⛔ **Not deterministic, cannot be enumerated in advance.** The same call is allowed one session and
refused the next with no version or config change (2026-08-02: three long-working calls refused,
binary and both settings files provably untouched for a week). ⇒ **"It worked last session" is not
evidence of a regression, and there is nothing to hunt for.**

Two shapes trip it reliably: a call reading as **self-granted elevation** (a project root outside the
configured tree carrying a self-asserted `human_approved: true`), and a message reading as **coaching
another agent past a denial**, however benign.

⇒ **Record it and stop.** ⛔ Never reformulate it, and never reach for a shell redirect, heredoc or
interpreter to the same effect: a denial is final whichever tool carries it. **An agent cannot grant
itself permissions**, so this bootstrap is the operator's, not a puzzle for you. Name the exact verb
in `NEEDS:`; the fix is a `permissions.allow` entry, which bypasses the classifier deterministically.

### ⛔ WHEN YOU CANNOT WRITE YOUR OWN `BLOCKED.md`

The planning-state protection can refuse your edit. Then the report goes on the bus and nowhere else:

```
BLOCKED <repo>: <one sentence>. Cannot update my own BLOCKED.md, it is STALE as of this message.
```

Say what your file now states wrongly, so the leader carries the accurate state. ⇒ **A stale record
you have DISCLOSED is safe; one you wrote around a gate is not.** Then park.

### ⛔ OPENING A PR: RECORD IT, THEN WATCH ITS FATE

A sister whose record silently goes false **decays into irrelevant senility** (operator, 2026-08-02).
Your park record is how you stay useful across your own amnesia, and one that reads as maintained
while being false is worse than none.

**The precondition, which is part of the rule:** open a PR only AFTER the commit hooks and lint pass
and the copy-editor gate has returned a verdict you have acted on. The watch is the last step of
opening a PR properly, never a substitute for an earlier one.

1. **Record the open PR in `PARK.md` immediately.** ⛔ This matters more than the watch and is not
   optional.
2. **Arm a watch on the PR's fate.**
3. **On merge:** check out your default branch, fast-forward, delete the merged branch with
   `git branch -d` (⛔ never `-D`; the refusal IS the safety), then reconcile `PARK.md` in ONE act:
   `sha`, `branch`, `open_prs`, **and every sentence that makes a claim ABOUT those fields.**

⚠ **That last clause is the one that rots.** A record whose `sha` field is updated while a sentence
asserting "HEAD is X and the sha field reads that too" is not, asserts something false about itself
while looking maintained. It has rotted that way twice.

**Three ways the watch goes wrong:**

- ⛔ **Watch every terminal state, not just merged.** A PR can be closed unmerged. A watch firing
  only on `MERGED` stays armed forever on a closed PR, waiting for something that will never happen.
  Emit on merged AND closed, then exit.
- ⛔ **The watch dies with your session**, which is why step 1 is not optional and why the bring-up
  check in Step 1 exists. **The watch is the fast path; the record plus the bring-up check is what
  actually holds.**
- ⚠ **Poll at 30s or slower.** GitHub rate-limits, and a PR's fate is not urgent to the second.

### Worktree re-roots are already permitted. Do not ask.

`$HOME/SourceCode/lisp-scratch` is covered by `DSMR_RELATED_PROJECTS` (`~/.zshenv`), so
`fs-set-project-root` at any worktree beneath it needs no approval, and you must **never** self-assert
`human_approved`.

⛔ **A running server keeps its startup environment.** A refusal there usually means a server
predating the setting, so the fix is the operator's reconnect, not a retry. Confirm from
`/proc/<pid>/environ` on your own `dsmr.core`, never from a fresh shell, which sees the value the
server does not.

⚠ `lisp-scratch` is **outside** the ASDF registry deliberately. ⛔ Never move worktrees into the
scanned tree, and never add it to the registry: duplicate system names resolve by scan order and
signal nothing, producing a successful build of the WRONG source. Assert
`(asdf:system-source-directory :<system>)` names your worktree before believing any run.

## Step 4 — Verify your memory store

Your auto-memory store is **created for you** at `~/.claude/projects/<cwd-with-/-and-.-as->/memory/`
— one per repo, isolated by working directory. ⛔ It is **not** in the repo and must never be moved
there: it is AI coordination state, and the path setting is ignored in a checked-in
`.claude/settings.json` by design.

Nothing creates itself *correctly*, though. Run this; it takes seconds:

```bash
M=~/.claude/projects/$(pwd | tr '/.' '--')/memory
idx=$(grep -oE '\]\([a-z0-9-]+\.md\)' "$M/MEMORY.md" | tr -d '](.)' | sed 's/md$//' | sort -u)
fil=$(ls -1 "$M"/*.md | xargs -n1 basename | grep -v '^MEMORY.md$' | sed 's/\.md$//' | sort -u)
comm -13 <(echo "$idx") <(echo "$fil")    # ORPHANS — files with no index line
comm -23 <(echo "$idx") <(echo "$fil")    # DANGLING — index lines with no file
grep -oE '\]\([a-z0-9-]+\.md\)' "$M/MEMORY.md" | sort | uniq -d   # DUPLICATE index lines
wc -c "$M/MEMORY.md"                      # must stay under 25600
awk 'length>=150' "$M/MEMORY.md"          # entries carrying content that belongs in the file
```

⚠ **Both lists must be `sort -u`'d before `comm`** — as written above they are. `comm` on
non-deduped input reports a duplicated index line as *dangling* even when its target exists; that
is a false positive, and it hides nothing, but it wastes a runner's time. Duplicates are their own
defect, hence the third check.

⚠ **Measure in CHARACTERS.** GNU awk's `length()` counts characters under a UTF-8 locale and bytes
under `LC_ALL=C`; bytes are always ≥ characters, so a byte count over-flags rather than under-flags.
The threshold is `>=150`, not `>150` — an entry sitting exactly at 150 is over the line.

- **Orphans** — add the index line. `MEMORY.md` is what loads every session; a file missing from it
  loses its guaranteed visibility and only surfaces if a relevance pass happens to pick it.
- **Dangling** — remove the line. It points at nothing and reads as a real memory.
- **Over 150 chars** — shorten the hook. ⚠ **First check the detail exists in the topic file.**
  Index lines routinely carry facts recorded nowhere else; shortening blind deletes them. Move the
  detail down, then cut.
- **Contradictions** — two memories asserting different things, or one contradicting the current
  code. Fix at the source and say which to believe. A reassuring memory is not the true one by
  virtue of being reassuring.

⛔ Never delete a memory whose content is preserved nowhere else. Retiring closed history is fine;
losing the one live fact buried in it is not.

⚠ **Prove the checkers can fire before trusting a clean result.** Seed a scratch COPY of the store
(never the real one) with an unindexed file, a dangling index line, and an over-long entry, and
confirm each flags. A checker that cannot go red reports the same "clean" whether the store is
healthy or the check itself is broken — so an unproven 0/0/0 is not evidence.

### Then check the frontmatter, which none of the above reads

⛔ **Every check above is an INDEX check, and not one of them parses YAML.** A store passes all
five while carrying frontmatter that is unreadable, or that parses true and has silently thrown
away part of itself. Reporting "store clean" on the index checks alone overstates what was
measured. Run:

```bash
python3 ~/.claude/skills/worker/check-store.py     # derives the store path from $PWD
```

It reports two classes. **THROW** is frontmatter that raises, or that parses to something other
than a mapping — the quiet half, because a delimited block holding prose parses fine as a string
and every field test then degrades to a substring test and passes. **HIDE** is frontmatter that
parses TRUE while dropping content: an unquoted scalar containing `' #'` opens a YAML comment and
the tail is discarded. The file still reads correctly on the page. This class has destroyed sha
pins that existed nowhere else.

On a finding: **quote the scalar, never trim it.** ⛔ Before editing, confirm the discarded tail
exists in the body — recovering it afterwards is not possible, and the tail is exactly where
uniquely-recorded detail hides.

⚠ **Do not hand-roll this check, and do not "improve" it into a line-scoped detector.** Six repos
wrote their own and five shipped a different broken predicate: comparing a parsed value against
the physical line that starts it (wrong in both directions), resolving keys against the top-level
mapping only (nested values never compared), and one written *inside a correction* that tested
continuation lines for being unindented, which cannot fire, so its zero meant nothing. The script
keys on the precondition at any depth instead, carries a control for every class including that
last one, and **exits 2 rather than reporting** if any control fails to fire. A correction needs
its own controls; inheriting them from the claim being corrected is how a broken predicate ships
looking rigorous.

## Step 5 — Announce, in one line

⛔ **Do not announce until your watch is armed and its controls have answered dead.** The
announcement is what tells the leader you are reachable, so sending it while deaf makes the leader's
roster wrong in the one direction that costs it something: it will believe a dispatch to you
arrived. If Step 0 was skipped, arm now, before this line goes out.

```
RESUMED <repo> @<short-sha>
```
Add, only if applicable: `BLOCKED <repo>: <n> — see .planning/BLOCKED.md`

⛔ **That is the entire announcement.** No summary of last session, no findings, no state-of-the-repo,
no lessons learned. Anything a successor needs is already in your files. If it is not in a file it is
not state.

## Step 6 — Revalidate the contract, then go silent

You hold: **your repo, your local context, your measurements.**
The leader holds: **the architecture, the plan, and cross-repo sequencing.**

- Speak only when **dispatched by name**, **blocked**, or **a claim is complete**.
- **≤15 lines**: claim, evidence, bound. No preamble.
- Every claim carries its bound — what you verified, what you did not, what would refute it.
- Distinguish *read* from *ran*. "I read the code" and "I ran it" are different claims.

⛔ **Forbidden, without exception:**
- Worker→worker messages. All traffic goes through the leader.
- Corroborating another worker's finding, relaying a third party's correction, or re-verifying work
  you were not asked to verify. Convergence is not evidence — it is usually one claim echoing.
- Commentary on the tooling. **Do not marvel at the harness.** It is established and working;
  rediscovering it each session burns the operator's week.
- Executing another repo's work because you can see it. Report it to the leader instead.

Then confirm the watch you armed in Step 0 is still on the right bus, as below, and
**go silent** until dispatched.

## Step 7 - Arm per bus, and prove it is the RIGHT bus

⚠ **You should have done this at Step 0, before anything else in this file.** It is written out here
because this is where the detail belongs, not because this is when to do it. If you are reading it
for the first time at this point in the run, you have been unreachable for everything above.

### Which bus are you on?

- **A tag passed to `/worker` wins.** `/worker <tag>` names your bus outright.
- **Otherwise `DSMR_BUS_SELECTOR` from the inherited environment**, declared in
  this repo's `.envrc` and set by whoever assembled the fleet. This mirrors how
  your agent name already resolves from `DSMR_BUS_AGENT`.
- **Empty or unset means the shared host-wide bus.** The declaration ships to
  every repo with an empty value, so having the line is not the same as having
  been assigned to a fleet.

⚠ **If the shell has a tag your MCP server did not have when it started, you are
split**: the session speaks on one bus and your watch on another. `direnv allow`
plus an MCP restart or a `/mcp` reconnect is the fix. Do not paper over it by
passing the tag to one side only.

If you were told you also join a second bus, that is a separate bus with its own
everything. Nothing on disk lists your joined buses, so if nobody named a second
one, you have one.

### Arm one watcher per joined bus

Each through the **Monitor tool** with `persistent: true`, each with its own
`--bus`. See the **bus-watch** skill for why a background Bash task is not an arm.

```
while true; do dsmr-bus-watch --stream --poll-ms 250 --recycle-seconds 1800 \
  --bus <tag> --agent "$DSMR_BUS_AGENT" --namespace /absolute/path/to/this/repo/; done \
  | grep --line-buffered -E "^(bus|error):"
```

⛔ **`--namespace` takes the ABSOLUTE PROJECT ROOT, not the repository's name.**
Run `pwd -P` and paste that, with its trailing separator. `c3po/` is a name;
`/home/fade/SourceCode/lisp/DeepSkyV2/c3po/` is a namespace. This has now cost two
agents a silently deaf watch.

⚠ **And the obvious check does not catch it, because it agrees with the mistake.**
The cursor and the heartbeat are both keyed on `<namespace>/<name>`, so a watch
armed under a wrong namespace writes a beat there, and a probe passing the *same*
wrong namespace reads that beat and answers `live`. The error confirms itself.

⇒ **Prove it with a control.** After arming, probe once with a deliberately wrong
namespace and require `dead`:

```
dsmr-bus-watch --check-live --bus <tag> --agent "$DSMR_BUS_AGENT" --namespace /nonexistent/
```

If that answers `live`, you are reading your own misfiled heartbeat and your real
arm is somewhere nobody publishes.

⛔ **Arm the loop, never the bare watcher.** `--stream` exits 0 on its idle
window on purpose: that is the self-heal that re-arms a watch which has gone
silently deaf. Monitor ends a watch when its command exits, so a bare
`dsmr-bus-watch --stream` leaves you deaf at the first idle mark, believing you
are armed, with nothing to notify you. The `while true` loop is what turns that
exit into a re-arm, and the `grep` keeps `recycle:` lines off your context while
letting `bus:` and `error:` through.

One Monitor does not cover two buses. Two joined buses means two Monitors.

### Confirm each one, and read the bus field

```
dsmr-bus-watch --check-live --bus <tag> --agent "$DSMR_BUS_AGENT" --namespace <absolute-project-root>/
```

⛔ **`live` alone is no longer good enough.** The answer now carries `bus=NAME`,
and you must check that it names the bus you meant to arm. A watcher that is live
on the wrong bus has a fresh heartbeat, answers `live`, and never fires: it is deaf
in exactly the way that used to be invisible, which is why the field was added.

- `live ... bus=<your tag>`: you are listening to the right bus. Go silent.
- `live ... bus=<something else>`: **you are deaf.** Re-arm with the right tag.
- `bus=default`: you are on the shared host-wide bus. Correct only if that is
  where you were told to be. No bus can be named `default`, so this label is never
  ambiguous.
- **No `bus=` field at all**: your `~/.local/bin/dsmr-bus-watch` predates named
  buses and silently armed on the shared bus whatever you asked for.
  `make install-bus-watch` from the dsmr-mcp checkout, then re-arm. The binary and
  the MCP core deploy separately, so a current server is no evidence of a current
  watcher.
- `dead` / `stale`: nothing is listening. Re-arm the Monitor.
- exit 64: the bus name itself was refused. Fix the name; nothing was armed.

Going silent on a dead, stale or wrong-bus watch is going deaf. A dispatch by name
will never reach you and nobody learns until the operator notices the wait. Never
park deaf: the right `live`, on every joined bus, and then silence.

⛔ **Do not use the roster as proof you are connected.** Being enrolled is not
being reachable, and being unenrolled does not stop you reaching the bus. The
roster records intent; `--check-live` is the only evidence.
