---
name: bus-watch
description: "Stay reachable on the dsmr-mcp coordination bus without polling: launch ONE detached watcher per joined bus once per session, tail its log under a persistent Monitor, and each new message wakes you. Use when you need to listen for bus messages in the background, wake on a bus event, or stay attached across a session (lead or sister). Covers the detach-then-tail arm (the real wake), reaping the watcher at park, naming the bus with --bus, draining on wake, the stable-identity rule, and the --check-live liveness probe that names which bus it answered for. Companion to fleet and fleet-restart."
---

# /bus-watch

How a fleet agent stays reachable on the durable dsmr-mcp coordination bus
**without polling** — launch one detached watcher per joined bus at bring-up,
tail its log through the **Monitor tool**, and every new message wakes you.

Launch the watcher once per session. The only re-arm is the Monitor's tail after
its 30-minute expiry, and that is a read-only command. Reap the watcher at park.

## Read this first: the one mistake that made watches go deaf

A background watcher only helps if the harness actually re-invokes you when a
message lands. There are two ways to run it, and only one of them wakes you:

- **`Bash` with `run_in_background`** notifies you **only when the process
  exits.** A streaming watcher does not exit per message — and wrapped in
  `while true; …; done` it never exits at all. Its `bus:` lines pile into a task
  output file that nothing reads. **This is how watches went silently deaf for
  months.** Do not arm the bus this way.
- **The `Monitor` tool** turns **each stdout line into a live notification** that
  re-invokes you, and with `persistent: true` it stays armed for the whole
  session. **This is the arm.**

Same watcher, different harness primitive. Use the Monitor.

## The tool underneath

`dsmr-bus-watch` (on `PATH` at `~/.local/bin/dsmr-bus-watch`) watches the bus
write-ahead log. In `--stream` mode it prints one `bus:<SEQ>` line per poll that
turned up anything new for you, carrying the highest such seq, and keeps running;
on an idle window it prints `recycle:` and exits (a supervisor restarts it).
Signal goes to stdout; diagnostics to stderr. With `--detach` it becomes its own
supervisor: it runs detached, re-arms itself in place at each recycle, and writes
its signal lines to a per-(bus, agent) log file that the Monitor tails.

⚠ **A line means CHECK THE BUS, not "one message with this seq is waiting."**
`bus-receive` drains everything pending in a single call, so when several records
land between two polls they arrive as ONE line carrying the highest seq. That is
why the drain-on-wake step below is written to keep receiving until the bus says
empty, rather than assuming one line means one message.

⚠ **Consecutive lines may SKIP sequence numbers.** A gap is normal and never a
dropped record. Do not build anything that treats the seq stream as contiguous.

## Identity — mandatory, not optional

Pass **both** `--agent` and `--namespace`. They are what make the Monitor arm
correct and replay-free:

- **Name** — `--agent NAME`, falling back to `DSMR_BUS_AGENT` (set in the repo's
  `.envrc`).
- **Namespace** — `--namespace PATH`, the **same project root the MCP session
  uses**, trailing separator included. The cursor is keyed on the full
  `<namespace>/<name>` id, so a root off by even a trailing slash names a cursor
  that does not exist.

With an identity resolved:

- The watcher **arms at your durable cursor**, not the log head — so a message
  that landed between a drain and this arm still fires, and **when the streaming
  watcher recycles and re-arms, it re-arms at your advanced cursor and replays
  nothing.** Cursor-based arming is exactly what makes the recycle idempotent. Without an identity it arms at the head, wakes on your own
  publishes, replays on every restart, and has no keyed heartbeat for
  `--check-live`.
- It **ignores your own publishes** — arming and publishing happen in any order.

**If `--agent` comes back as `unknown argument`**, your PATH binary predates
identity support: `make install-bus-watch` from the dsmr-mcp checkout, then
re-arm. `make bus-watch` alone only writes `bin/` and leaves PATH untouched.

## Which bus? Name it, and check the answer names it back

A fleet can have its own bus. Each named bus has its own state root, so it has its
own write-ahead log, its own cursors and its own heartbeat directory. A watcher
arms on exactly one of them.

- **`--bus NAME`** arms on that named bus.
- With no flag, **`DSMR_BUS_SELECTOR`** answers. That is the variable the repo's
  `.envrc` declares and the same one the MCP session resolves its own bus from, so
  a watcher and the session it serves cannot end up on different buses while both
  report healthy.
- With neither, the watcher lands on the shared host-wide bus, which is exactly
  the paths it has always used. An **empty** `DSMR_BUS_SELECTOR` reads as unset, so
  a repo that has the declaration but no tag is on the shared bus.

⚠ **A bus name the bus will not accept stops the watcher.** It is named on stderr
and the process exits **64**. This is the one flag that refuses rather than falling
back to its default, and the asymmetry is the point: a mistyped cadence costs a
poll interval, while a bus name that quietly degraded to the shared bus would leave
a watch armed where nobody publishes, reporting live and never firing.

⛔ **`--check-live` names its bus on every answer, and you must read that field.**
Seeing `live` is not enough any more. A watch that is live on the wrong bus is deaf
in exactly the way that used to be invisible, and the field exists to make it
visible. `bus=default` is what the shared bus prints; no bus can be named
`default`, so the word is unambiguous.

**One watcher per joined bus.** An agent joined to two buses launches two
detached watchers, each with its own `--bus`, and confirms each one separately
(one Monitor may tail both logs, or one Monitor per bus). Each keeps its own
heartbeat under its own bus root, so the liveness answers do not collide and each
one is about the bus it names.

⚠ **The watcher binary and the MCP core deploy SEPARATELY, and this has cost the
fleet before.** `make install-bus-watch` publishes `~/.local/bin/dsmr-bus-watch`;
`make core` plus an MCP restart or `/mcp` reconnect publishes the server. Neither
carries the other. A running watcher also keeps the image it started with until it
is re-armed. So a sister can be running a watcher that does not understand `--bus`
while its own server already does: the watcher warns about an unknown flag, arms on
the shared bus, and answers `--check-live` with **no `bus=` field at all**. Treat a
missing `bus=` field as proof of a stale binary, not as an answer. A stale watcher
binary once made six sisters' reports unscoreable.

## Arm it — launch the watcher once, tail its log under a Monitor

The arm is **two steps per joined bus**, and they have different lifetimes.

**Step 1 — once per session: launch the detached watcher.**

```
~/.local/bin/dsmr-bus-watch --detach --poll-ms 250 \
  --bus <tag> --agent <name> --namespace <absolute-project-root>/
```

It makes sure exactly one detached streaming watcher runs for that (bus, agent),
in its own session with stdin from `/dev/null`, so it survives the shell that
started it **and the Monitor's 30-minute expiry**. It re-arms itself in place at
every idle recycle — the recycle-EXIT self-heal still happens, the detached
process carries it instead of a `while true` loop. It appends its `bus:` and
`error:` lines to `$XDG_STATE_HOME/dsmr-mcp/watch/<bus>--<agent>.log` (default
`~/.local/state/dsmr-mcp/watch/…`) with a pid file beside it. It is
**idempotent**: run it again while the watcher is up and it starts nothing.

It prints two lines:

```
detached pid=<pid> bus=<name> log=<path>      # or `running pid=…` when one was already up
monitor: tail -q -n0 -F <path> | grep --line-buffered -E '^(bus|error):'
```

Exit 1 means a watcher under the same name belongs to **another namespace** or the
child did not come up; exit 2 means no identity resolved. Neither armed anything
for you. The pass-through flags (`--poll-ms`, `--recycle-seconds`, …) reach the
detached watcher.

**Step 2 — the Monitor, re-armed on every 30-minute expiry: tail the log.**

```
Monitor(
  command: 'tail -q -n0 -F ~/.local/state/dsmr-mcp/watch/<tag>--<name>.log \
              | grep --line-buffered -E "^(bus|error):"',
  description: 'bus wake for <name> on <tag>',
  persistent: true
)
```

Use the exact `monitor:` line step 1 printed if it differs from this. One Monitor
may tail several buses' logs at once with a glob, `…/watch/*--<name>.log`; one
Monitor per bus is equally fine and keeps the description naming the bus.

⚠ **The Monitor expires at 30 minutes regardless of `persistent: true`.** Before
the detached watcher existed, every expiry meant re-launching the watcher itself,
and that re-launch was a fresh command the permission classifier could refuse or
leave without a verdict: six sightings across five sessions on 2026-09-29, each
one an agent gone deaf. **Re-arming is now a read-only `tail` of a log file**,
which is why it is expected to pass the classifier more reliably. That
expectation rests on a few samples, not a measurement — if a tail re-arm is
refused, it is still a refusal: say so, do not assume it cannot happen. The
watcher itself keeps running through the gap and nothing is lost: it re-announces
anything you have not drained at its next re-arm, and your durable cursor holds
the rest.

Drop `--bus <tag>` only when you are deliberately on the shared host-wide bus
(its log stem is `default--<name>`). Spelling it out on a named bus is worth the
characters: it puts the bus in the Monitor's description and in the line an
operator reads, so an arm on the wrong bus is a visible mistake rather than an
invisible one.

Why each piece:

- **`--detach` launched once, never per re-arm** — the watcher launch is the
  command the classifier used to refuse; now it happens once, at bring-up, when
  you are present to handle a refusal.
- **`tail -q -n0 -F`** — `-F` follows the log across the watcher re-creating it;
  `-n0` starts at the end so a re-arm does not replay old wakes into your
  context. A wake that landed in the gap between Monitors is not lost: the
  watcher arms from your durable cursor at each recycle and announces it again,
  and a catch-up `bus-receive` after re-arming closes the gap at once.
- **`grep --line-buffered -E "^(bus|error):"`** — passes the wakes (`bus:`) and
  failures (`error:`), hides anything else. `--line-buffered` is required or
  matches sit in grep's buffer unseen. A persistent fault is written as one
  `error:` line, not one per retry, so it does not wake you every few seconds.
- **The path is absolute, never a bare `dsmr-bus-watch`.** Whether the bare name resolves depends
  on how the session was started: a tool call runs against a snapshot of the shell environment taken
  at session start, and a session launched by the fleet launcher can carry a much narrower `PATH`
  than one started from an interactive shell. When it does not resolve, the failure is silent in the
  worst way — the Monitor reports itself started, the command inside it says `command not found`
  where nobody is reading, and the agent is deaf with no error anywhere it will look. Measured
  2026-08-15 on a leader, whose whole fleet was reporting into it at the time.
- **Run the liveness probe from the same shell that armed.** A probe run anywhere with a richer
  `PATH` answers for a watcher that was never started. That is also how this was found, by luck: the
  probe happened to run in the arming shell and said `command not found` rather than `dead`.
- **`--agent <name>` is a literal, never `"$DSMR_BUS_AGENT"`.** The variable is
  inherited, so a session started by a process that began life in another tree
  arms its watch under that tree's name and listens on its cursor. It answers
  `--check-live` with `live`, which is true and useless: the probe proves a
  watcher exists, never that it is watching for you. Write the name out.
- **`--poll-ms 250`** — reaction latency is the poll interval, not the recycle
  window. The recycle window only governs how often the watcher self-heals,
  never how fast a message wakes you.
- **`--stall-seconds N` (default 120)** — a watcher whose poll loop stops cycling
  exits with status 75, so a wedged watcher reads as `dead`/`stale` rather than
  alive and deaf. SIGTERM ends a watcher at once.

### Fallback: the bare `--stream` loop, only when `--detach` is unavailable

If `~/.local/bin/dsmr-bus-watch --help` lacks `--detach`, the PATH binary is old:
`make install-bus-watch` from the dsmr-mcp checkout, then arm as above. Only if
that is impossible, arm the old supervised stream directly in the Monitor:

```
Monitor(
  command: 'while true; do
              { ~/.local/bin/dsmr-bus-watch --stream --poll-ms 250 --recycle-seconds 1800 \
                  --bus <tag> --agent <name> --namespace <absolute-project-root>/ \
                || echo "error:watch-crashed rc=$?"; } \
              | grep --line-buffered -E "^(bus|error):" || true
              sleep 1
            done',
  description: 'bus wake for <name> on <tag>',
  persistent: true
)
```

The lessons that shaped this form still hold for it, and `--detach` now carries
them internally:

- **The `while true` loop and `--recycle-seconds` are required, not decoration.**
  `--stream` exits 0 on its idle window as the self-heal that re-arms a watch
  gone silently deaf; a bare `--stream` goes deaf at the first idle mark while
  still reporting armed. (This same loop was fatal under `run_in_background`,
  which only fires on exit — that never comes.)
- **`|| echo "error:…"; sleep 1`** — a crash surfaces as an `error:` notification
  instead of silence, and the `sleep` stops a missing binary from hot-spinning.
- **The filter sits INSIDE the loop, and the whole stage ends in `|| true`.**
  Measured across four repos on 2026-08-15: with the filter on the outside, as
  `done | grep …`, the loop writes into a pipe it does not control, and when the
  reading end goes away the loop dies with it. The watch stops, the session stays
  up, and nothing announces either fact — a repo that has gone deaf reads exactly
  like a repo with nothing to say. Inside the loop, a filter that dies costs one
  iteration; `|| true` keeps a non-zero exit from ending the loop as well. Both
  were confirmed by a delivered wake afterwards rather than by a heartbeat.
- ⚠ **This form dies with the Monitor.** Every 30-minute expiry needs the whole
  launch command again, which is exactly the re-arm the classifier refused on
  2026-09-29. Treat it as a stopgap until the binary is current.

**Each agent arms in its OWN session** — a Monitor wakes only the session that
started it. Substitute `<project-root>/` for your real root; keep the trailing
slash.

## Park: reap the detached watcher

⛔ **The detached watcher OUTLIVES the session.** That is its purpose, and it is
also why it must be stopped deliberately: an unreaped watcher is a listener
nobody reads, holding a heartbeat that answers `live` for an agent that is gone.
At park, after your last drain:

```
~/.local/bin/dsmr-bus-watch --reap --all-buses --agent <name> --namespace <absolute-project-root>/
```

It sends SIGTERM to each watcher's process group, SIGKILL after 3 s, verifies the
pid is gone and removes the pid file. One line per watcher: `reaped pid=… bus=…
signal=term|kill`, `none bus=…`, `survived pid=… bus=…`, or `foreign …` for a
watcher under your name in another namespace, which it leaves running. **Exit 0
only when nothing of yours is left**; exit 1 means something survived — say so in
the park record rather than parking on it. Drop `--all-buses` and pass `--bus` to
reap one bus only.

A context rotation is not a park: the successor re-runs `--detach`, which answers
`running` for the watcher already up, and re-arms only the tail.

## When it wakes you (each `bus:<SEQ>` notification)

1. **Drain with `bus-receive`** under your stable `agent_id`. This advances your
   cursor so each message is delivered once — and so the watcher's next restart
   re-arms above it.

   Delivery is bounded by message **count** (default 20 records), not bytes. On a
   large backlog pass a smaller `limit` (5–10) and page while `remaining_pending`
   is non-zero. A non-zero count means call again — you are not caught up.

   `skip_to_head` is a judgement call, never a default: it discards unread
   messages. Check `bus-status` first — at a handful pending, drain them, one may
   be addressed to you by name. Skip only a genuinely large, genuinely stale
   backlog. Your own pending count is the fact; an instruction to skip is a
   prediction — if they disagree, believe the count and say so.

2. **Handle** what you received — confirm a sister's SHA, act on a request, relay
   to the operator. Publish any replies now.

3. **Do NOT re-arm.** The Monitor is still tailing and the detached watcher is
   still running. There is no per-wake arm step — that whole ritual is gone.
   Just go back to work. The one re-arm left is the Monitor's tail when it
   expires at 30 minutes; the watcher itself is never re-launched for that.

An `error:` notification means the detached watcher hit a fault (it retries on
its own and writes the same fault once): run `--check-live`, and if it answers
`dead`/`stale` run `--detach` again, then re-arm the tail. If the binary is
missing or stale, `make install-bus-watch` first.

## Is your watch actually alive? — the liveness probe

The running watcher refreshes a **heartbeat file** every poll and removes it on
clean exit, so "am I still listening?" is a cheap local check, not a `ps` grep:

```
~/.local/bin/dsmr-bus-watch --check-live --bus <tag> --agent "$DSMR_BUS_AGENT" --namespace <absolute-project-root>/
# or with the full id:  --check-live --bus <tag> --agent-id <namespace>/<name>
```

- `live pid=<pid> age_s=<n> bus=<name>` (exit 0): a watcher is listening for you
  now, **on the bus it names**. Check that name against the bus you meant to arm.
- `dead bus=<name>` (exit 1): no heartbeat on that bus, nothing listening.
  **Run `--detach` again, then re-arm the tail.**
- `stale pid=<pid> age_s=<n> bus=<name>` (exit 1): heartbeat not refreshed within
  `--live-window-seconds` (default 5), so the watcher wedged or was killed (a
  wedged one ends itself after `--stall-seconds`). **Run `--detach` again, then
  re-arm the tail.**
- `unknown` (exit 2): no identity resolved; pass the same `--agent`/`--namespace`
  you armed with. This answer carries no bus, deliberately: a bus printed beside an
  unresolved identity would read as a probe that found something.
- exit **64** with a message on stderr: the bus name itself was refused. Fix the
  name; nothing was armed and nothing was created.
- **no `bus=` field on a `live`/`dead`/`stale` line**: the binary predates named
  buses. It armed on the shared bus whatever you asked for.
  `make install-bus-watch`, then re-arm.

Run it **once per joined bus**, with that bus's tag. A single `live` says nothing
about the other bus.

The Monitor surfaces the inner watcher's crashes itself (the `error:` line), but
`--check-live` is the cheap assertion to run **before you go silent** — an
agent with pending mail and no listener is the invisible state this closes — and **whenever a reply you expected never woke you.** It reads the
heartbeat only; it never consumes a message or touches your cursor.

## On bring-up (rejoin, then arm)

1. `bus-status` under your stable `agent_id` — confirm the broker is up and see
   the pending count. This also prints your self-identity and, now, whether a
   watcher is already live for you (`live_watcher`).
2. `bus-receive` (stable `agent_id`) — drain catch-up, repeating while
   `remaining_pending` is non-zero.
3. **Arm**: `--detach` once per joined bus, then the Monitor tailing each log.
   A `bus-receive` right after the tail is up closes any gap between the two.
4. `--check-live` per bus. `live` **with the `bus=` field naming the bus you
   armed** means you are actually listening to it. `dead`/`stale`/`unknown`, a bus
   field naming a different bus, or no bus field at all, all mean you rejoined
   blind. Fix it before you report ready.

A SessionStart hook may prime a one-shot watcher before turn one; it does not
replace this — the detached watcher plus the Monitor's tail is your standing
listener.

## Watch and receive under your STABLE identity

The main loop holds the agent's durable bus identity (`valis` for the lead;
sisters by their names), sourced from `DSMR_BUS_AGENT` in the repo's `.envrc`.
Never infer your identity from queue traffic — read it back from any bus tool's
self-identity line (`You are "<name>" (stable identity) …`) and pass that
`agent_id` to `bus-status` / `bus-receive` / `bus-publish`.

An unsourced `.envrc` yields an anonymous `gNNNN-1` cursor — pass `agent_id`
explicitly until a `direnv allow` + MCP restart fixes it. A spawned subagent that
resumes the shared cursor desyncs delivery state; if a subagent must touch the
bus it uses an `ephemeral` identity, which never advances the main cursor.

## Quick reference

| Situation | Do |
|---|---|
| Start listening (whole session) | `--detach` once per joined bus, then the **Monitor tool** (`persistent: true`) tailing the log it names. Never a `run_in_background` Bash task. |
| Monitor expired (30 min) | re-arm the **tail** only. Never re-launch the watcher for this; `--detach` is for bring-up and for a `dead` watcher. |
| Parking | last drain, then `--reap --all-buses --agent <name> --namespace <root>/`; exit 0, or say what survived. |
| `--help` lacks `--detach` | stale PATH binary. `make install-bus-watch`; the bare `--stream` loop is the fallback only if that is impossible. |
| Woke on `bus:<SEQ>` | `bus-receive` (stable id) → handle → back to work. **No re-arm.** |
| Woke on `error:…` | the detached watcher hit a fault — `--check-live`; on `dead`/`stale` run `--detach` again and re-arm the tail. |
| Am I still listening? | `~/.local/bin/dsmr-bus-watch --check-live --bus <tag> --agent <name> --namespace <absolute-project-root>/`, wanting `live` **and** the right `bus=`, or `--detach` again and re-arm the tail. |
| Before going silent | run `--check-live` per joined bus; never go silent on `dead`/`stale`, and never on a `bus=` that is not the one you armed. |
| Joined to two buses | two `--detach` runs, two `--bus` tags, two `--check-live` runs (one Monitor may glob both logs). One `live` covers one bus. |
| `--check-live` prints no `bus=` field | stale PATH binary that armed on the shared bus regardless of what you asked. `make install-bus-watch`, then re-arm. |
| `--bus` exits 64 | the name is refused (over 32 chars, a character outside `A-Z a-z 0-9 - _ .`, a reserved name, or a socket path too long). Fix the name; never shorten it to fit. |
| Large backlog | `bus-receive` with `limit` 5–10, page on `remaining_pending`. |
| `bus-receive` rejects `limit` | MCP predates bounded delivery — `/mcp` reconnect (keeps context). |
| `--check-live` says `unknown argument` | PATH binary predates liveness — `make install-bus-watch`, then re-arm. |
| Omitting `--agent`/`--namespace` | don't — it arms at the head, wakes on your own publishes, **replays on every restart**, and has no heartbeat to check. |
| Tempted to `run_in_background` a `while true` watcher | that is the two-month deafness bug — it only notifies on exit, which never comes. Use the Monitor. |

Companion skills: **fleet** (assembling a fleet on its own named bus) and
**fleet-restart** (park/bring-up discipline). The bus is the sole cross-repo
channel; this skill is how you stay attached to it.
