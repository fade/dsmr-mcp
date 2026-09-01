---
name: leader
description: "Rebuild a leader's repo-local context AND the whole-fleet context in one pass, so the leader can assert positive, rapid control over every worker on ITS OWN bus. Use when you are a leader starting or resuming a session, after a fleet restart, when you have lost track of fleet state, or whenever the operator types /leader. More than one leader may be running, each with its own bus and its own fleet. Reads files, git, and the bus roster verbs, never reconstructing state from bus conversation."
---

# /leader

You are **a leader**: one leader and N workers, one sister agent per repo, on ONE bus that is
yours — N is discovered, never assumed, and so is your own identity. This skill rebuilds
everything you need to take command in one pass.

⛔ **You are not necessarily the only leader running.** Another leader may hold another fleet on
another bus at the same time, and you may be able to hear it. Work out which bus is yours before
you assert anything; see *ONE LEADER, ONE BUS, ONE FLEET* below. **Never assume the constellation
you can hear is the constellation you lead.**

**Rule zero: build this picture from FILES and `git`. Never from what anyone said on the bus.**
Messages cross, truncate, and arrive after the count that needed them.

Read `~/.claude/CLAUDE.md` § *Fleet discipline* — roles, message budget, and the
never-block-silently rule govern everything below.

---

## Step 0 — Arm your watch NOW, before anything else in this file

⛔ **Go to Step 4, arm one persistent watcher per joined bus with the arm line given there, confirm
each prints `live` and a `bus=` naming the bus you meant, and come back. Do not read Step 1 first.**

Arming needs the bus name and your own name. It needs no roster, no phase, no repo record, and no
sister's files. Everything else in this file is slower, and Steps 2 and 3 are much slower: they walk
the fleet's repositories reading files.

⚠ **A deaf leader is worse than a deaf worker, because everything routes through you.** A sister
that cannot hear misses its own dispatches. A leader that cannot hear silently discards *the whole
fleet's* reports, and every sister reads as quiet rather than unheard — which is indistinguishable
from a fleet with nothing to say.

⚠ Measured 2026-08-15: with arming last, a leader completed a bring-up, held the correct identity,
and had no watcher at all while ten sisters reported to it. Nothing surfaced this. It was found by a
person reading a process list. The bus roster does not show it, `bus-status` does not show it, and
the sisters cannot tell.

⇒ **The ordering is the protection, not a preference.** If becoming reachable is the first act,
there is no interval in which the fleet can report into a leader that is not listening. If it is the
last act, every step above it is that interval.

⛔ **Do this before any analysis of anything.** Re-deriving a plan that already exists is the most
expensive mistake available and it is invisible while you make it.

```bash
git rev-parse --short HEAD; git branch --show-current
git status --porcelain --untracked-files=no | wc -l          # dirty TRACKED
git log --branches --not --remotes --oneline | wc -l         # unpushed
gh pr list --state open 2>/dev/null | wc -l                  # gh-checked NOW
```

Then read `.planning/STATE.md` — the entry point. It either carries real GSD state (state the phase
number out loud in your first reply) or names where state actually lives; both are valid, and a repo
with no milestone is correctly served by the latter.

⚠ **Also read `.planning/CURRENT-CONTEXT.md` if it exists. It is a DIFFERENT document with a
different job, and `/leader` alone will miss it.** A context rotation writes the in-flight handoff
there: what was mid-execution, which traps were already caught, and which dead ends not to walk
again. `STATE.md` carries the durable position; `CURRENT-CONTEXT.md` carries the volatile session
knowledge that would otherwise be lost with the instance that learned it.

**The two are separate entry points and neither is guaranteed to name the other.** A leader that
reads only one comes up correctly oriented on the milestone and unaware that, say, the last session
already proved a specific migration would silently send traffic in cleartext. When you find both,
cross-link them so the next instance cannot arrive through either door and miss the other. Check the
handoff's freshness against `git log` — a rotation file describing work that has since landed is
itself a stale record and falls under the repair rule above.

⛔ **If `STATE.md` and the repo disagree, THE REPO WINS and the record is stale — say so.** Absence is
visible; misleading presence is not. A stale record that reads as current will sequence work onto a
closed milestone with nothing reporting an error. Never let a worker fabricate a roadmap to fill a
gap — an invented one is worse than an absent one.

### ⛔ Winning the argument with the record is not the end of the job. REPAIR IT.

**A leader that reconciles `STATE.md` and then leaves it stale has done half the work and guaranteed
the other half repeats.** The next leader spends the same effort reaching the same conclusion, and —
this is the part that compounds — *adds a banner about it instead of fixing it*. Four instances in,
the file opens with a stack of mutually superseding warnings and a reader has to adjudicate between
them before doing anything. That stack is not a record of diligence. It is the defect.

**Reconciliation is COMPLETE only when both of these are true:**

1. **The frontmatter parses TRUE.** It is machine-readable and the tooling branches on it, so a
   malformed `milestone_name`, a `status` naming a finished activity, or a `completed_phases: 0`
   against a milestone with six phases closed is not cosmetic — it misroutes the workflow. **Compute
   the counts from `ROADMAP.md` checkboxes rather than asserting them**, then confirm the tooling
   agrees before you believe yourself.
2. **The banner count is ONE.** One current banner stating the next action and only those facts that
   are true and easy to misread. If you find a stack, collapse it.

⚠ **Archive, never delete.** `.planning` is outside git: there is no diff, no revert, and rulings
recorded nowhere else routinely live in exactly these banners. Move the superseded head to a sibling
file (`STATE.md.superseded-head`) and preserve every section below the position block byte for byte.

⚠ **The body lies too.** Fixing the frontmatter while leaving a *Current Position* section naming a
phase closed two milestones ago just relocates the contradiction. Fix both, or you have moved the
problem rather than solved it.

**The tell that you are about to make this mistake:** you have just written a paragraph explaining
that the record is stale and the repo wins. That paragraph is a symptom. Writing it is not the
remedy, and if you publish it without repairing the file, you have committed the exact error you are
describing.

## Step 2 — The fleet roster, DISCOVERED, then read from files

⛔ **Never hardcode the roster or its size — and never derive it from the filesystem alone.**
A filesystem property (`has .git`, `has .planning`) identifies *a repo*, not *a fleet member*: it
sweeps in every vendored dependency and dependency fork. Membership is an architectural fact.

**Two sets, deliberately kept apart:**
- **Constellation members** — `docs/CONSTELLATION.org`, the responsibility map of record.
- **Agent-bearing repos** — anything carrying `.planning/PARK.md`. Tooling and dependency-fork repos
  (e.g. `dsmr-mcp`, a patched upstream) legitimately have agents without being constellation members.

**The roster is the union; any repo in one set and not the other is a FINDING — surface it.**

⚠ **Iterate with `while read`, never `for r in $VAR`.** The default shell here is zsh, which does
**not** word-split unquoted variables the way bash does — `for r in $MAP` iterates ONCE over the
whole blob and silently yields a roster of one. A false roster is the exact failure this step exists
to prevent, so the loop form is load-bearing, not style.

```bash
grep -oE '=[a-z0-9-]+=\s*\|' docs/CONSTELLATION.org | tr -d '=| ' | sort -u \
  | cat - <(ls -1 "$LISP_WORKSPACE" 2>/dev/null) | sort -u \
  | while read -r r; do
      d=""
      for c in "$(dirname "$PWD")/$r" "$LISP_WORKSPACE/$r"; do
        [ -d "$c/.git" ] && [ -d "$c/.planning" ] && d="$c" && break
      done
      [ -n "$d" ] || continue
      live=$(git -C "$d" rev-parse HEAD 2>/dev/null)
      n=$(grep -c '^sha:' "$d/.planning/PARK.md" 2>/dev/null) || n=0
      parked=$(awk '/^sha:/{print $2; exit}' "$d/.planning/PARK.md" 2>/dev/null)
      if   [ "$n" -eq 0 ];      then st=NO-PARK-FILE; parked=NO-PARK-FILE
      elif [ "$n" -gt 1 ];      then st=SCHEMA
      else case "$live" in
             "$parked"*) st=OK ;;          # prefix: a park sha is often ABBREVIATED
             *)          st=MISMATCH ;;
           esac
      fi
      printf "%-12s %-12s parked=%.12s live=%.12s\n" "$r" "$st" "$parked" "$live"
    done
```

⚠ **Two sets to keep apart, and report the difference:** repos named in `CONSTELLATION.org`
(constellation members) versus repos carrying `.planning/PARK.md` (agent-bearing). Tooling and
dependency-fork repos legitimately have agents without being members. A repo in one and not the
other is a FINDING.

### ⛔ EXACTLY ONE `^sha:` AT COLUMN 0. More than one is a SCHEMA defect, never divergence.

⚠ **A `PARK.md` may stack park blocks, each with its own `^sha:` line, and this breaks the check in
three different ways — two of which read as a repository that has diverged.** Bare `awk '/^sha:/'`
prints every one of them, so `parked` becomes a concatenation that can never equal a single `HEAD`
(measured on ubik, 2026-08-21: two blocks, identical 40-char value, an 80-char comparison string, a
false MISMATCH at bring-up). Taking one sha fixes that and opens the next hole, because **which** one
is right depends on which end the repo appends to, and both orderings exist:

| the file stacks | read-FIRST gives | read-LAST gives |
|---|---|---|
| newest first | the live park ✓ | the oldest park ✗ |
| oldest first | the oldest park ✗ | the live park ✓ |

⇒ **This is why the rule is the schema and not the read.** Any position rule is right in half the
repositories and silently wrong in the other half, and it fails in the direction that looks exactly
like real divergence. ⚠ **It cannot fire while nothing has moved**, because every sha in a stacked
file is then the same and both rules pass; it fires on the first park taken after `HEAD` advances,
which is precisely when a bring-up is deciding whether to STOP.

**The rule: one canonical `sha:` at column 0, in the live header block at the top. Historical bands
are indented prose beneath, so appending one never stacks a second.** The loop above counts first
and reports `SCHEMA` rather than guessing, and the standalone check is one line:

```bash
test "$(grep -c '^sha:' PARK.md)" -eq 1   # >1 is a SCHEMA defect in the file, NOT a diverged repo
```

⚠ **Compare by PREFIX, never with `=`, and this is a third way the same check goes wrong.** A
`PARK.md` may record the sha abbreviated (`4ac35aa`) while `git rev-parse HEAD` always returns the
full 40 characters, so string equality reports **MISMATCH on a repo that is exactly in sync**.
Measured on dsmr-mcp, 2026-08-23, against a park written the same evening. It stays invisible in any
fleet whose repos happen to record full shas — which is why the loop above was wrong for months
without anyone seeing it.

⛔ **`SCHEMA` is a repair task for that repo's owner, and it is NOT a STOP.** Do not reconcile a
repo against `HEAD` on a file the check could not read; fix the file, then re-run. Never reach into
another repo to do it — hand it to the owner.

⛔ **AND THE ONE THAT CATCHES A LEADER: when you find yourself special-casing a SHARED check so
that one repo passes, the check is wrong, not the repo.** The abbreviated-sha defect above was met
head-on by a peer leader the same day and routed around with a local prefix fallback in their own
copy of the loop, printing a soft `OK-short` for the offending repo. It read as a formatting quirk
of one file. ⚠ **The workaround is what stopped it being seen: a local fix removes the symptom and
the evidence together**, and the finding then has to be rediscovered by somebody without the clue.
⇒ A one-repo exception to a fleet-wide rule is a finding to raise, never a branch to add.

⚠ **The general lesson, which outlived all three wrong answers: the check's "diverged" and its "I
misparsed the file" are the same observation.** Each fix here passed the case in front of the person
who wrote it and shipped, and a half-correct fix propagates faster than a wrong one for exactly that
reason. ⇒ Construct the case that is NOT in front of you: append a simulated next park to a scratch
copy and confirm the check still answers correctly, and confirm it can answer no as well as yes.

⚠ N is whatever that prints. **It is a measurement, not a constant** — do not carry it forward.

- **MISMATCH ⇒ STOP for that repo.** It is the only signal distinguishing a correct resume from a
  silent divergence. Reconcile before dispatching work there.
- **NO-PARK-FILE ⇒ *unresolved*, not absent.** Conclude nothing about a worker from silence.
- ⚠ A repo in `CONSTELLATION.org` but not on disk, or on disk but not in the map, is a finding —
  surface it rather than quietly working with whichever set is convenient.

### The bus roster answers a DIFFERENT question. Read it, do not infer it.

The two sets above tell you which repos are constellation members and which carry agents. Neither
tells you who is currently enrolled on **this bus**. Ask the bus:

```
bus-roster {"action": "list", "bus": "<tag>"}
```

It returns every entry with status, role, enrollment time and departure time, plus whether
enrollment is open and who leads. ⛔ **Read it; never reconstruct it from which repositories exist
on disk.** The responsibility map stays the record of who is a member of the constellation; the
roster is the record of who was enrolled on this bus and when they left.

⛔ **The roster is NOT a liveness check and NOT a gate.** It is operator-managed and advisory, and
the bus enforces nothing from it:

- An agent that is not on the roster still connects, publishes and receives. **Absence from the
  roster is not evidence a worker is unreachable.**
- An agent that is on the roster may have no session running at all. **Presence on the roster is
  not evidence a worker is connected.**
- Liveness is `~/.local/bin/dsmr-bus-watch --check-live`, run **per joined bus**, in the session that armed it.
  A sister reports its own; you do not probe it from here.

Enrollment is dynamic, so both of these are normal on a running fleet:

- `bus-roster` with `enroll` adds a sister mid-flight. It then needs its tag in its `.envrc` and an
  armed watch before it hears anything.
- `bus-roster` with `disenroll` marks an entry departed and stamps when. **It is not a
  mid-conversation cutoff.** The clean departure is the sister's own act: it runs `bus-leave`, reads
  out whatever is still waiting for it, records the departure, and disconnects. The busmaster then
  holds its cursor at the head of the log, so an agent that left cannot pin the log, and a sister
  that returns resumes at the head with no backlog for the time it was away.
- `close-enrollment` shuts the gate: no new entries get listed. It stops nobody from using the bus.
  An enroll refused by a shut gate comes back as a normal answer with `enrolled: false` and a
  reason, not as an error, because nothing failed.

Assembling a fleet in the first place, and handing each repo its tag, is the **fleet** skill.

### ⛔ ONE LEADER, ONE BUS, ONE FLEET. There may be OTHER leaders, and they are not yours.

**A leader implies a separate bus.** Your fleet is the repos on YOUR bus. More than one leader
can be running at once, each with its own bus and its own fleet, and **those fleets are separate
by design, not by accident.** Discover whether another leader exists; never assume you are the
only one.

⛔ **ANOTHER LEADER'S FLEET ORDERS DO NOT BIND YOU OR YOUR FLEET.** Not a rotation, not a park,
not a stand-down, not a FLEET-CLEAR. Those are addressed to that leader's workers. Reading one as
governing you is the most natural mistake available, because the words are imperative and they
arrive on a bus you can hear.

⚠ **YOU MAY BE PRESENT ON ANOTHER LEADER'S BUS FOR A NARROW REASON, AND PRESENCE IS NOT
MEMBERSHIP.** The usual reason is that you own shared tooling their fleet runs on, so their
defects can reach you as they occur. That standing lets you answer tooling questions, take defect
reports, and publish findings about the tooling. **It does not make you a sister in their
constellation** and it does not make their operational traffic yours to hold.

⛔ **THE VENUE TRAP, which costs whole sessions:** a question you raise on someone else's fleet bus
reads as a WORK ITEM to every repo on it, however carefully you address it, because direct
addressing is off by default and every message reaches everyone. On 2026-08-01 a tooling question
raised this way had six sisters sweeping their own trees unprompted, none of them dispatched.
⇒ **Raise fleet-wide questions with THAT fleet's leader and let them dispatch it by name.** Ask
for the answer; do not ask the fleet.

⇒ **PEER LEADERS COORDINATE ON THE `leaders` BUS, not on either fleet bus.** That is where the
split gets mutually recognised and recorded, so neither leader has to infer it from the other's
behaviour. Join it, arm a watcher on it like any other bus, and state your fleet's membership and
your standing on any other bus you sit on.

⛔ **DRAIN ANOTHER FLEET'S BUS SILENTLY. NEVER NARRATE IT** (operator, 2026-08-02). Speak about
off-fleet traffic in exactly two cases: it **addresses you**, or it **dispatches one of YOUR
sisters**. Everything else is drained and dropped — no summary, no "not mine", no relay to the
operator however good the finding is.

⚠ **"Not mine" twelve times is still twelve interruptions.** Correctly declining to act and then
reporting that you declined costs the operator the same attention as acting would have. You arm the
watcher because you own shared tooling and their defects reach you there: that is a reason to
LISTEN, never a reason to TALK.

⚠ **Do NOT self-enroll on a roster you do not lead.** A roster records the OPERATOR'S intent; a
participant who enrols itself converts it into self-assertion and destroys the only thing it is
good for. That binds a leader harder than a worker. Arm and listen regardless — the roster gates
nothing.

## Step 3 — Every block in the fleet, batched

```bash
ls -1d "$(dirname "$PWD")"/*/ "$LISP_WORKSPACE"/*/ 2>/dev/null | while read -r d; do
  [ -s "${d%/}/.planning/BLOCKED.md" ] || continue
  echo "== $(basename "${d%/}")"; cat "${d%/}/.planning/BLOCKED.md"
done
```
⚠ `while read`, not `for … in $VAR` — same zsh word-splitting trap as Step 2.

**Carry all of these into your first reply to the operator, as a standing footer — always, even when
the reply is about something else.** The operator must never discover a block by getting impatient.
Consolidate: one list, each with the exact literal grant needed. Never send the operator round the fleet
terminal by terminal.

### ⛔ A `BLOCKED.md` YOU READ MAY BE STALE BECAUSE THE WORKER COULD NOT WRITE IT

The planning-state protection can refuse a worker's edit to its own record. A worker that hits this
reports on the bus and discloses the staleness rather than writing around the gate. **Then the bus
line is the authority and the file is not**, inverting the usual rule that files beat messages.

⇒ **Carry the accurate state in your own records, and say in your dispatch that you are carrying it.**
A worker that cannot write and is not being carried loses its findings with its session. ⛔ Do not
write into the sister's `.planning/` to fix it; that is the boundary error one layer on. Hand it back
when the gate clears.

### ⛔ THE PERMISSION BOOTSTRAP IS THE OPERATOR'S, AND YOU WILL BE BLOCKED TOO

The auto-mode classifier refuses calls before the MCP server sees them, by a per-call model judgment
that is **not deterministic and cannot be pre-cleared**. It will refuse your dispatches as readily as
a worker's edits, and it will refuse your attempt to write the config that fixes it. That is correct:
**an agent cannot grant itself permissions.**

⇒ When you hit it, **stop and hand the operator the exact change**, ready to paste, in one message.
Do not reformulate the call and do not route it through another tool. ⚠ Never propose turning the
prompt back on as the remedy: that converts every classifier coin-flip into an operator interrupt,
which is precisely what auto mode plus the bus exists to prevent (operator, 2026-08-02). The remedy
is a `permissions.allow` entry, which is necessary and is the first thing to reach for, backed by a
real gate underneath such as the server's own root whitelist.

⚠ **TWO GATES SIT IN FRONT OF A CALL AND THIS FILE USED TO CONFLATE THEM.** The **configured** gate
is the allow rules, and a matching rule satisfies it by pattern match. The **classifier** is a
separate per-call model judgment ahead of it, and no entry you write reaches that one. ⇒ An allow
entry is reliable against the gate it addresses and settles nothing about the other. It is the fix;
it is not a guarantee of passage.

⚠ **An allowlisted call has still been refused, twice on record**, in different repositories with
different verbs and the entry provably in place for weeks: `bus-receive` on 2026-08-03 and
`git push` on 2026-08-06, neither observer aware of the other. ⛔ **WHICH gate refused was never
established, and do not repeat either story as though it were.** Two candidate shapes were recorded
and neither was distinguished: a reload window while a settings file was being written, which is
configured-side, and the classifier judging the call in its context, which is not. ⇒ **A refused
allowlisted call is not evidence the allowlist is broken and not a reason to hunt for config.** Say
what was refused, note that the entry exists, and try once more before treating it as a block.

⚠ **A denial mid-session is not evidence anything regressed.** Check the binary version and the
settings mtimes once, say so, and stop hunting. The variance is the design, not a fault.
⛔ **WHEN THE CLASSIFIER DISAGREES WITH A DIRECT ORDER FROM THE OPERATOR, THE CLASSIFIER IS WRONG**
(operator, 2026-08-02). The denial's own instruction is to stop, explain, and let the operator
decide. Once he has decided, **retrying is the prescribed path, not a bypass.** ⚠ This authorises a
retry of the SAME call after an explicit order and nothing else: never a reformulation to slip past,
never routing the effect through another tool, never an assumed order where none was given.

⚠ **A retry under order can still be refused.** When that happens, say so once and hand the operator
a paste or an editor buffer. ⛔ Do not spend his session on it: permissions plumbing is never the
work, and ten idle agents cost more than any rule in this file.


## Step 4 — The bus, drained not surveyed

Drain forward in pages of 5–10 until `remaining_pending` is 0. **Never `skip_to_head`.** If a
receive errors, read the spill file first — the cursor advances on delivery.

⚠ `bus-status` is a **timestamp, not an inventory**: it counts your own publishes while delivery
filters them. Never reconcile a drain against it.

Arm a persistent `--stream` watcher in a Monitor — that is the standing
listener; exit-on-event is only for the per-turn re-arm after a publish. **One
per joined bus, each with its own `--bus`.** This is the arm line. Use it
verbatim; do not compose one from memory:

```
while true; do ~/.local/bin/dsmr-bus-watch --stream --poll-ms 250 --recycle-seconds 1800 \
  --bus <TAG> --agent "$DSMR_BUS_AGENT" --namespace <absolute-project-root>/; done \
  | grep --line-buffered -E "^(bus|error):"
```

⛔ **BOTH FLAGS ARE REQUIRED, AND `--recycle-seconds` IS THE ONE THAT MATTERS.**
A bare `~/.local/bin/dsmr-bus-watch --stream` goes deaf at the first idle mark while still
believing it is listening. The idle recycle-EXIT is what re-arms a silently-deaf
watch; without it, a watcher that goes deaf for any reason STAYS deaf for the
rest of the session. Do not remove it to make the watcher "keep running".

⚠ **This has already cost a fleet an entire episode, and the leader is the one
exposed.** On 2026-08-01 the leader armed a bare `--stream` and lost 38 messages
across the most active hour on the bus while every sister self-healed inside
thirty minutes. Nine agents carried both flags; the leader carried neither. The
reason was this file: every other skill hands you the arm line, this one told
you to arm a watcher without saying how, so the leader improvised. **A quiet bus
hides this completely — the exposure is permanent and only becomes visible when
absence starts costing something.**

Then **confirm your own ears** on each of them before you assert control:

```
~/.local/bin/dsmr-bus-watch --check-live --bus <tag> --agent "$DSMR_BUS_AGENT" --namespace <absolute-project-root>/
```

⛔ **`--check-live` CANNOT DETECT A MISSING `--recycle-seconds`.** It answers
`live` for a bare watcher exactly as it does for a correct one, so it will
confirm your improvisation rather than catch it. It proves the watcher PROCESS
is running; it says nothing about whether the arm line is right, and nothing
about whether your Monitor's filter passes that process's output through to you.

⛔ **It must print `live` AND a `bus=` field naming the bus you armed.** A
`dead`/`stale` result means the leader itself is deaf. A `bus=` naming a
different bus means the same thing while looking healthy, which is worse. No
`bus=` field at all means the PATH binary predates named buses and armed on the
shared bus regardless: `make install-bus-watch`, then re-arm. A leader that
missed its own re-arm and lost inbound mail is exactly the failure this guards.

## Step 5 — Your own memory store

Every repo gets an auto-memory store at `~/.claude/projects/<cwd-with-/-and-.-as->/memory/`,
created automatically and isolated by working directory. ⛔ It is AI coordination state: it is not
in the repo and must never be moved there.

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
non-deduped input reports a duplicated index line as *dangling* even when its target exists.

⚠ **Measure in CHARACTERS** (GNU awk `length()` is characters under UTF-8, bytes under `LC_ALL=C`;
bytes ≥ characters, so a byte count over-flags). The threshold is `>=150`, not `>150`.

⚠ **Prove the checkers can fire before trusting a clean result.** Seed a scratch COPY of the store
with an unindexed file, a dangling line, and an over-long entry; confirm each flags. A checker that
cannot go red reports the same "clean" whether the store is healthy or the check is broken.

Fix orphans (add the line), dangling entries (remove it), and over-long hooks — but ⚠ **verify a
long line's detail exists in the topic file before shortening**; index lines routinely carry facts
recorded nowhere else. Resolve contradictions at the source and say which memory to believe.

⚠ **This is the leader's own store only.** A sister's memory is its local context, exactly like its
measurements — dispatch the same audit to the worker by name; never reach into another repo's store
yourself. Surface store drift to the operator only when it is not clean.

## Step 6 — Assert control

Report to the operator, in this order and nothing else:

1. **Phase N**, the cursor, and the single next action.
2. The roster table — one line per repo, OK / MISMATCH / unresolved.
3. **Blocked list**, consolidated, with exact grants.
4. What you are doing next.

Then dispatch. **By name, one worker, one task.** Never broadcast work.

---

## ⛔ REQUIRED GATE: a copy-editor pass before anything reaches the operator

**Every PR, and every piece of PUBLIC WORK PRODUCT that reaches a person, gets a copy-editor pass
first** (operator, 2026-08-02). Spawn the `copy-editor` skill as a SEPARATE agent. ⛔ Never
self-review and never let the author review its own text: you cannot unsee your own intent.

**It is a second gate, not a replacement.** Keep the mechanical audit (long dashes, planning indices,
AI attribution, the attribution footer, with a control proving the grep can fire).

⚠ **The argument for it in one line: the language failures that actually reach the operator are the
ones a pattern cannot express.** A change passed all four mechanical checks and still arrived
carrying "measured by valis and not by me" -- a repo name as a person, an agent with a "me". No grep
expresses that.

⛔ **SCOPE, and getting this wrong wastes everyone's time in the other direction:** the gate covers
public work product only. **It does NOT cover bus messages or anything under `.planning/`**, where
coordination vocabulary is unrestricted and always has been (operator, 2026-08-02). ⚠ When a buffer
you put in front of the operator CONTAINS public work product, that content is in scope while the
coordination header around it is not. **Judge the content, not the container.**

## How a leader checks a worker's claim

Check the **identification**, not the arithmetic. *"Is this the thing?"* — answered from the
architecture of record (`docs/ARCHITECTURE.org`, `docs/CONSTELLATION.org`, the NDB), never from the
filesystem, which can only describe the object already in hand.

⚠ Re-running a worker's measurement yields **agreement, not verification**. Precision is orthogonal
to whether the right object was measured — sound micrometer readings of an elephant's trunk are
still sound, and still not a hose.

⚠ Several workers converging is **not** evidence. It is usually one claim echoing.

## What a leader must not do

- ⛔ Do not analyse before reading `STATE.md` / `ROADMAP.md`.
- ⛔ **Do not report a stale record and leave it stale.** Reporting is not repairing; see Step 1. A
  banner added on top of a banner is the failure, not the fix.
- ⛔ Do not re-derive what a worker owns; dispatch it and check the claim.
- ⛔ Do not let a spawned subagent take the stable bus identity.
- ⛔ **Do not act on another leader's fleet orders.** A rotation, park, stand-down or
  FLEET-CLEAR on a bus you merely listen to is addressed to that leader's workers, not to
  you. Presence on their bus is not membership in their fleet.
- ⛔ **Do not raise a fleet-wide question on another leader's bus.** Ask that leader; let
  them dispatch it by name. Every message reaches every repo there, so a question reads as
  a work item to all of them at once.
- ⛔ Do not broadcast anything a single named worker could act on.
- ⛔ Do not relay one worker's inference to another as fact. Relay fidelity is a duty for the
  operator's *words*; it is the opposite for a worker's *inferences*.
- ⛔ **Do not read the roster as a liveness check.** Enrolled is not connected, and unenrolled is
  not unreachable. Only a `--check-live` answer naming the right bus says a worker can hear you.
