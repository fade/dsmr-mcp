---
name: fleet-restart
description: "Coordinated take-down and bring-up of a multi-agent fleet (one leader plus N sister agents in other repos) coordinating over a durable bus. Use when the operator asks to restart the agents/fleet/constellation, when you are a leader or sister coming back up after such a restart, or when you need to park a fleet at a clean resumable state. Park state lives in FILES, never in bus messages."
---

# /fleet-restart

One **leader** (valis) and **N workers** — one sister per repo. N is discovered from the repos on
disk and `docs/CONSTELLATION.org`, never hardcoded; every rule here must hold unchanged at any N.

**The invariant: park state lives in FILES, never in bus messages.** A message can cross, truncate,
or arrive after the count that needed it — all three happened in a single evening and produced three
wrong roll-calls. A file cannot. The bus carries **one line per worker**, and that line is a
pointer, not the state.

Read `~/.claude/CLAUDE.md` § *Fleet discipline* first — the message budget and the
never-block-silently rule apply throughout and are not restated here.

---

## Phase 1 — Park (take-down)

**Leader broadcasts once:** `PARK` — nothing else. No agenda, no explanation, no discussion.

**Each agent (leader included) then, without talking to anyone:**

1. Reach a clean pause. Green build, no edit mid-flight, no half-applied plan. If mid-task, finish
   the atomic unit or commit a WIP commit. **Never park on a dirty tree.**
2. Write `.planning/PARK.md` — this exact schema, nothing added:

```
repo:      <name>
sha:       <full 40-char sha>
branch:    <branch>
dirty:     <count of modified TRACKED files>
open_prs:  <count, gh-checked NOW, never carried forward>
blocked:   <none | one sentence>
next:      <the single next action a successor takes>
written:   <ISO-8601>
```

⚠ **Derive the `sha` from `git rev-parse HEAD`, never from a short form you have
   seen quoted.** One agent nearly parked on a **fabricated** 40-char sha, expanded from an
   abbreviation it had only read. It caught it by verifying the field against `rev-parse` after
   writing it, and that same check is what surfaced an out-of-band merge nobody had told it about.
   The resume contract compares the parked sha to live HEAD, so a fabricated one halts the next
   bring-up as a **false divergence**.

3. **Check `STATE.md` before you park. It is read cold by your successor and it rots silently.**

   - **`Stopped at:` in `## Session Continuity` must be TRUE right now.** It is a machine
     interface: the planning SDK regenerates frontmatter `stopped_at` from that body line, so a
     stale sentence there reappears after every phase operation and cannot be fixed in the
     frontmatter. One repo carried `context exhaustion at 75%` for three days that way. ⛔ A stale
     `stopped_at` makes a cleanly parked repo read as one that **died mid-task** — the exact
     misreading this protocol exists to prevent. Same applies to `Last activity:`, `Phase:`,
     `Plan:` and `Status:` under `## Current Position`.
   - **ONE banner, and read it end to end for self-contradiction.** A single banner accumulates
     contradictions as readily as a stack does, and it is harder to spot. Collapse, do not append.
   - **Size check: if `STATE.md` exceeds ~200 lines, retire the oldest closed-phase material
     before parking.** Length is itself a defect: it stops being read whole, so the live position
     hides inside history and the machine-interface lines drift hundreds of lines apart. Move
     retired sections to `.planning/state-archive/`, ⛔ **archive never delete** (`.planning` is
     outside git: no diff, no revert), always leave a pointer, and move content **by line range
     rather than retyping it** so rulings stay byte-exact.

4. Send the leader **exactly one line**: `PARKED <repo> @<short-sha>`

⛔ **No park announcement longer than that line.** No summaries, no findings, no lessons, no
state-of-the-repo. Anything a successor needs belongs in `PARK.md` and the repo's `.planning`;
anything not in a file is not park state and will be lost — correctly.

**Leader:** confirm each worker by **reading its `PARK.md` and running `git -C <repo> rev-parse
HEAD`**. Never confirm from a message. When every repo's file exists and its `sha` matches the live
HEAD, broadcast `FLEET-CLEAR` (one word) and tell the operator it is safe to restart.

⛔ **Never stamp on a partial set.** A worker that has not written `PARK.md` is *unresolved*, not
absent — a crossing can only ever manufacture a false absence, never a false presence.

---

## Phase 2 — Ordering

```
all agents DOWN  →  leader restarted FIRST  →  workers brought up one at a time
```

The leader comes up first so the coordination identity and bus watch are live before any worker
re-announces.

---

## Phase 3 — Bring-up

### Leader

1. Boot the image; cold-verify (project root set, system loads, a worker spawns). If the tooling
   image wedged during the client restart, restart it too — a carried-over wedged image hangs
   everything silently.
2. Rejoin the bus under the stable leader identity. **The main loop owns that identity**; never let
   a spawned subagent become the bus peer. Drain forward — **never `skip_to_head`** — in pages of
   5–10 until `remaining_pending` reads 0. If a receive errors, read the spill file before moving
   on: the cursor advances on delivery.
3. Arm a persistent `--stream` watcher in a Monitor as the standing listener
   (exit-on-event is only the per-turn re-arm after a publish). Then **confirm it
   with `~/.local/bin/dsmr-bus-watch --check-live --agent "$DSMR_BUS_AGENT" --namespace
   <absolute-project-root>/`**. It must print `live`. Bringing the leader up deaf leaves the
   whole fleet talking to no one.
4. **Read `.planning/STATE.md` and `.planning/ROADMAP.md` before anything else.** State the phase
   number you are resuming under.
5. Expect a quiet bus. Workers are not up. Do not block on them.
6. As each worker checks in, confirm its live HEAD against its `PARK.md`. **A mismatch is a STOP —
   reconcile before any work.**
7. Collect every `BLOCKED.md` across the fleet into your first reply to the operator.

### Worker

1. Boot; cold-verify.
2. Rejoin the bus under your own stable identity; drain forward to 0.
3. Read **your own** `.planning/PARK.md`. Check out its `branch`; confirm `git rev-parse HEAD`
   equals its `sha`. **Mismatch ⇒ stop and report; do not work.**
4. Send **one line**: `RESUMED <repo> @<short-sha>`
5. Arm your persistent `--stream` watch and **confirm it with `--check-live`
   (must print `live`) before going silent.** **Go silent.** Await dispatch by
   name. A worker that goes silent on a `dead`/`stale` watch is deaf to its own
   dispatch, and no one learns until the operator notices the wait.

⛔ **Bring-up is the checklist above and nothing else.** Do not explore the tooling, do not report
what the harness can now do, do not verify another repo, do not comment on another worker's park, do
not summarise last session — it is in your files.

---

## Failure modes this protocol exists to prevent

- **State in messages.** Crossed, truncated, or late messages produced three wrong roll-calls in one
  evening. Files cannot cross. Confirm from files and `git`, never from what someone said.
- **Parking on a dirty tree.** Uncommitted work does not survive the restart. Commit first.
- **The bring-up frenzy.** Workers each publishing a multi-thousand-character resume essay and then
  corroborating each other exhausts every context before any work starts. One line each.
- **Silent blocking.** A worker waiting at a prompt is invisible until the operator gets impatient.
  Write `BLOCKED.md`, send one line, park.
- **A subagent taking the leader's bus identity.** Shared-cursor desync. Subagents use ephemeral
  identities.
- **Stamping on a partial set.** It puts repos through a restart in unknown state. Wait.
- **Skipping the parked-SHA confirmation.** It is the only thing distinguishing a correct resume
  from a silent divergence.

## Reference implementation (valis constellation)

- Bus: durable `dsmr-mcp` (`bus-status` / `bus-receive` / `bus-publish`, stable `agent_id`); leader
  identity is `valis`. ⚠ `bus-status` is a **timestamp, not an inventory** — it counts your own
  publishes while delivery filters them, so never reconcile a drain against it; page on
  `remaining_pending`.
- Watch: a persistent Monitor over `while true; do ~/.local/bin/dsmr-bus-watch --stream
  --recycle-seconds 1800 ...; done` is the standing listener; re-arm after publishing. ⛔ **The
  loop is required, not decoration.** `--stream` exits 0 on its idle window as a self-heal, and
  Monitor ends a watch when its command exits, so a bare watcher goes deaf at the first idle mark
  while still reporting armed. See the **bus-watch** skill for the full form. Confirm liveness with
  `~/.local/bin/dsmr-bus-watch --check-live --agent "$DSMR_BUS_AGENT" --namespace <absolute-project-root>/`. Require `live` before you
  park or report ready, never `dead`/`stale`.
- Boot: `fs-set-project-root {"path":"."}` → `load-system {"system":"<sys>"}`.
- Park state: `.planning/PARK.md` per repo. Blocks: `.planning/BLOCKED.md` per repo.
