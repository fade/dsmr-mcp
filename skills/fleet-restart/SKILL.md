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

4. **Leave your detached bus watcher RUNNING. PARK DOES NOT REAP** (operator ruling, 2026-09-30).
   The watcher outlives the session by design: at bring-up, `--detach` answers `running` and adopts
   it, and the new session re-arms only its background `--wake`. While you are down it answers
   `--check-live` with `live … readers=0` — running, nobody listening — which is what parked
   means; the bus holds your mail on your cursor. ⛔ Do not run `--reap` here. `--reap` is for an
   agent LEAVING the fleet (`bus-leave`, disenrollment) or retiring a host; see **bus-watch**.

5. Send the leader **exactly one line**: `PARKED <repo> @<short-sha>`

⛔ **No park announcement longer than that line.** No summaries, no findings, no lessons, no
state-of-the-repo. Anything a successor needs belongs in `PARK.md` and the repo's `.planning`;
anything not in a file is not park state and will be lost — correctly.

**Leader:** confirm each worker by **reading its `PARK.md` and running `git -C <repo> rev-parse
HEAD`**. Never confirm from a message. When every repo's file exists and its `sha` matches the live
HEAD, broadcast `FLEET-CLEAR` (one word) and tell the operator it is safe to restart.

⛔ **`FLEET-CLEAR` IS ADDRESSED TO THE OPERATOR, NOT TO A WORKER. IT LIFTS NOTHING.** It reports that
every park file matches live HEAD, so it is safe for HIM to take the fleet down. ⇒ **On a
`FLEET-CLEAR` a worker stays parked and stays silent, and resumes only when its session is actually
restarted and it comes up through `/worker`.** A worker that treats it as a resume signal starts work
inside the one window where nothing should move: the seconds in which the operator is killing the
sessions.

⚠ **This is written down because the protocol used to define the broadcast and never its meaning to
the audience that receives it, and a repo filled the gap with a guess.** Measured 2026-09-07: one
sister's `PARK.md` carried ~50 references to `FLEET-CLEAR`, ten section headings announcing a lift
across as many park cycles, and the reading stated as a rule in its own words. It had been practice
there for about a month, and every cycle made it look more settled. **A one-word signal with no
stated meaning for its receiver does not stay undefined; it gets defined locally, and then it is
indistinguishable from convention.**

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
3. Arm the standing listener: `~/.local/bin/dsmr-bus-watch --detach --bus <TAG> --agent
   <your-name> --namespace <absolute-project-root>/` **once** (expect `running`: the watcher
   survived the park and is adopted), then the background Bash (`run_in_background`) wake,
   `~/.local/bin/dsmr-bus-watch --wake --all-buses --agent <your-name> --namespace
   <absolute-project-root>/`, re-armed only after each wake (drain, re-arm; see **bus-watch**).
   Then **confirm it with `~/.local/bin/dsmr-bus-watch --check-live --bus <TAG> --agent
   <your-name> --namespace <absolute-project-root>/`**. It must print `live`, `bus=<TAG>` and
   `readers=1` or more. Bringing the leader up deaf leaves the
   whole fleet talking to no one.
4. **Read `.planning/STATE.md` and `.planning/ROADMAP.md` before anything else.** State the phase
   number you are resuming under.
5. Expect a quiet bus. Workers are not up. Do not block on them.
6. As each worker checks in, confirm its live HEAD against its `PARK.md`. **A mismatch is a STOP —
   reconcile before any work.** Then run the reader check for it (`--check-live --bus <TAG>
   --agent <sister> --namespace <sister-root>/`; see **leader**). `readers=0` once it has
   announced is a deaf sister: surface it to the operator, who must type in its terminal.
7. Collect every `BLOCKED.md` across the fleet into your first reply to the operator.

### Worker

1. Boot; cold-verify.
2. Rejoin the bus under your own stable identity; drain forward to 0.
3. Read **your own** `.planning/PARK.md`. Check out its `branch`; confirm `git rev-parse HEAD`
   equals its `sha`. **Mismatch ⇒ stop and report; do not work.**
4. Send **one line**: `RESUMED <repo> @<short-sha>`
5. Arm your watch (`--detach` once, which adopts the watcher your park left running, then the
   background `--wake`) and **confirm it with `--check-live` (must print `live`, your `bus=`, and
   `readers=1` or more) before going silent.** **Go silent.** Await dispatch by
   name. A worker that goes silent on a `dead`/`stale` or `readers=0` watch is deaf to its own
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
- Watch: `~/.local/bin/dsmr-bus-watch --detach --bus <TAG> --agent <name> --namespace
  <absolute-project-root>/` once per session per bus (answers `detached` or `running`), then the
  standing listener is a background Bash (`run_in_background`) command,
  `~/.local/bin/dsmr-bus-watch --wake --all-buses --agent <name> --namespace
  <absolute-project-root>/`, which exits on the next message; drain every bus, then re-arm the
  same line. On `nowatcher` (exit 1) re-run `--detach`, then re-arm. The literal path matches the
  narrow Bash allow rule, which resolves before the classifier. ⛔ **Not the Monitor:** Monitor
  allow rules are dropped in auto mode (it runs through the shell) and it expires every 30
  minutes, so each re-arm faced the classifier and an outage left agents deaf with their watcher
  live (2026-09-29, established 2026-09-30). ⛔ **The recycle is required, not decoration.**
  `--stream` exits 0 on its idle window as a self-heal, so a bare watcher goes deaf at the first
  idle mark while still reporting armed. `--detach` carries that recycle itself; the `while true
  … --stream --recycle-seconds 1800` Monitor loop is a last-resort fallback only for a binary
  without `--wake` (`make install-bus-watch` first). See the **bus-watch** skill for the full form.
  **Park does not reap**; `--reap --all-buses` is for leaving the fleet or retiring a host.
  Confirm liveness with `~/.local/bin/dsmr-bus-watch --check-live --bus <TAG> --agent <name>
  --namespace <absolute-project-root>/`. Require `live`, the right `bus=` and `readers=1` or more
  before you report ready, never `dead`/`stale`/`readers=0`.
- Boot: `fs-set-project-root {"path":"."}` → `load-system {"system":"<sys>"}`.
- Park state: `.planning/PARK.md` per repo. Blocks: `.planning/BLOCKED.md` per repo.
