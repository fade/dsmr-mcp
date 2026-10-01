---
name: bus-watch
description: "Stay reachable on the dsmr-mcp coordination bus without polling: launch ONE detached watcher per joined bus once per session, then let ONE listener wait on it: the session Stop hook as the primary, which re-arms itself at every turn end, or a one-shot background Bash `--wake` as the fallback, which you drain and re-arm. Use when you need to listen for bus messages in the background, wake on a bus event, or stay attached across a session (lead or sister). Covers the detach-then-listen arm, the already-armed rule, why the Monitor tail is retired, marking a park and keeping the watcher across it (reap only on leaving the fleet), naming the bus with --bus, draining on wake, the stable-identity rule, and the --check-live probe whose bus=, readers=, parked= and deaf= fields say whether you can actually hear. Companion to fleet and fleet-restart."
---

# /bus-watch

How a fleet agent stays reachable on the durable dsmr-mcp coordination bus
**without polling** — launch one detached watcher per joined bus at bring-up,
then keep a one-shot **`--wake`** running as a **background Bash command**
(`run_in_background`). It exits on the next message; the harness re-invokes you
when it exits; you drain and re-arm the same line.

When the operator has installed the session Stop hook, that hook is the
**primary** listener: it arms the same `--wake` at the end of every turn, so you
never re-arm, and the background `--wake` becomes the **fallback**, started once
at bring-up and wherever the hook is absent.

Launch the watcher once per session (it is adopted if already running). Re-arm
the background `--wake` only after it fires, so an idle agent never re-arms at
all. A park marks the watcher and does **not** reap it; only leaving the fleet
does.

## Read this first: two mistakes that made watches go deaf

A background listener only helps if the harness actually re-invokes you when a
message lands, and if the command that re-arms it is one the harness will let
run. Both have failed.

- **A STREAMING watcher under `run_in_background` never wakes you.** Background
  Bash notifies you **only when the process exits**. A `--stream` watcher does
  not exit per message — and wrapped in `while true; …; done` it never exits at
  all. Its `bus:` lines piled into a task output file that nothing read. **This
  is how watches went silently deaf for months.** `--wake` fixes the mismatch
  from the other side: it is one-shot, so its exit IS the message.
- **The `Monitor` tail could never be pre-approved, and went deaf every 30
  minutes.** Established 2026-09-30 from the Claude Code permission-modes docs
  ("How the classifier evaluates actions"): in auto mode, allow rules that match
  a call resolve BEFORE the classifier — **but `Monitor` allow rules are dropped
  in auto mode, because Monitor runs through the shell.** So the Monitor tail
  this skill used to prescribe was judged by the classifier on every re-arm, and
  it expired every 30 minutes regardless of `persistent: true`. During a
  classifier or server outage ("no verdict") the re-arm was denied and the agent
  went deaf while its detached watcher stayed live. A narrow **Bash** rule stays
  in effect in auto mode, and `~/.claude/settings.json` carries
  `Bash(~/.local/bin/dsmr-bus-watch:*)` and
  `Bash(/home/fade/.local/bin/dsmr-bus-watch:*)`.

⛔ **The Monitor is retired as the standing listener.** Do not reintroduce it
(tail or `--stream`): its rules are dropped in auto mode and it has a 30-minute
cap. The background `--wake` has neither problem. The one exception is the
last-resort `--stream` fallback below, for a binary too old to have `--wake`.

## The tool underneath

`dsmr-bus-watch` (on `PATH` at `~/.local/bin/dsmr-bus-watch`) watches the bus
write-ahead log. In `--stream` mode it prints one `bus:<SEQ>` line per poll that
turned up anything new for you, carrying the highest such seq, and keeps running;
on an idle window it prints `recycle:` and exits (a supervisor restarts it).
Signal goes to stdout; diagnostics to stderr. With `--detach` it becomes its own
supervisor: it runs detached, re-arms itself in place at each recycle, and writes
its signal lines to a per-(bus, agent) log file. `--wake` waits on that log and
exits with the next `bus:`/`error:` line written to it.

⚠ **A line means CHECK THE BUS, not "one message with this seq is waiting."**
`bus-receive` drains everything pending in a single call, so when several records
land between two polls they arrive as ONE line carrying the highest seq. That is
why the drain-on-wake step below is written to keep receiving until the bus says
empty, rather than assuming one line means one message.

⚠ **Consecutive lines may SKIP sequence numbers.** A gap is normal and never a
dropped record. Do not build anything that treats the seq stream as contiguous.

## Identity — mandatory, not optional

Pass **both** `--agent` and `--namespace`. They are what make the arm correct
and replay-free:

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
detached watchers, each with its own `--bus`, and confirms each one separately.
One `--wake --all-buses` waits on every detached log the agent has. Each keeps its own
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

## Arm it: launch the watcher once, then let one listener wait on it

The arm is **two steps**, and they have different lifetimes.

**Step 1 — once per session per joined bus: launch (or adopt) the detached watcher.**

```
~/.local/bin/dsmr-bus-watch --detach --poll-ms 250 \
  --bus <tag> --agent <name> --namespace <absolute-project-root>/
```

It makes sure exactly one detached streaming watcher runs for that (bus, agent),
in its own session with stdin from `/dev/null`, so it survives the shell that
started it, **the session that started it, and a park or fleet restart**. It
re-arms itself in place at every idle recycle — the recycle-EXIT self-heal still
happens, the detached process carries it instead of a `while true` loop. It
appends its `bus:` and `error:` lines to
`$XDG_STATE_HOME/dsmr-mcp/watch/<bus>--<agent>--<hash>.log` (default
`~/.local/state/dsmr-mcp/watch/…`) with a pid file beside it. The hash is taken
over your full agent identity, namespace included, so two agents with the same
name in different projects keep separate files. It is
**idempotent and adopting**: run it while a watcher for you is already up — from
this session, a previous one, or before a park — and it starts nothing, prints
`running`, and that watcher is yours again. Either way it clears the park marker
for that bus (see *Park marks the watcher*).

It prints two lines:

```
detached pid=<pid> bus=<name> log=<path>      # or `running pid=…` when one was already up
monitor: tail -q -n0 -F <path> | grep --line-buffered -E '^(bus|error):'
```

Ignore the `monitor:` line: it names the retired Monitor form (see *Read this
first*). Exit 1 means a watcher under the same name belongs to **another
namespace** or the child did not come up; exit 2 means no identity resolved.
Neither armed anything for you. The pass-through flags (`--poll-ms`,
`--recycle-seconds`, …) reach the detached watcher.

**Step 2: one listener. The session hook is the primary; a background `--wake` is the fallback.**

The primary listener is a Stop hook that the operator installs once in
`~/.claude/settings.json` (he holds the paste-ready block; ⛔ no agent writes a
settings file). At the end of every turn it runs
`dsmr-bus-watch --wake --hook --all-buses` under your identity, in the
background, and waits. When mail reaches your detached log it exits and its
message wakes you as "Stop hook feedback". That feedback is not a blocked stop:
it is your wake. It says which of three things happened:

- `dsmr-bus-watch: mail has arrived for you on bus <b>. Drain the bus now ...`:
  drain every joined bus with `bus-receive`, act on what it holds, and end your
  turn.
- `dsmr-bus-watch: no mail arrived in <N> seconds; this wake only renews the
  listener ...`: there is nothing to drain. End your turn.
- `dsmr-bus-watch: no detached watcher is running for <id> on bus <b> ...`: run
  step 1 (`--detach`) for that bus, then end your turn. This one comes at most
  once an hour.

In all three, **you do nothing to re-arm.** The end of the turn runs the hook
again, and it arms the next listener itself. It resumes reading where the last
listener stopped, so mail that landed while you worked wakes you at once rather
than being skipped. A subagent's turn end never arms one.

The hook is installed when
`grep -c -- '--wake --hook' ~/.claude/settings.json` prints 1 or more. Check it
once at bring-up and remember the answer.

⛔ **One listener per identity, and `already-armed` is how you know.** Every
`--wake` takes a lock on your identity. A background `--wake` started while the
hook's listener waits prints `already-armed` and exits 0: the hook holds the
arm. **Do not re-arm and do not retry.** The hook steps aside silently in the
same way while a background `--wake` waits, so the two never listen at once.

With the hook installed, the background `--wake` below has one job: at
bring-up, before your first turn has ended, nothing else is listening, so arm it
once and pass the reader check. When it fires, drain as usual and do **not**
re-arm it; the hook takes over when that turn ends.

Know the gaps, because they are where the hook cannot help:

- **An interrupted turn fires no Stop hook.** If you are stopped with Esc during
  a turn that nothing was listening through (one the hook's own wake started),
  no listener is armed until a later turn ends normally. When you are resumed
  after an interrupt, let that turn run to its normal end. The deafness alarm
  (mail unread for ten minutes, see the liveness probe) is the net for the gap.
- **`stop_hook_active` is true on every turn the hook's wake started.** It is not
  a loop guard here and the hook does not read it. Never add a check that stops
  on it: a listener that did would never re-arm after its first wake.
- **During your own turn `readers=0` is normal** when the hook's wake started
  it: nothing reads the log until the turn ends and the hook arms. Deafness is
  the `deaf=` field, not a reader count.

**The fallback listener: a background Bash `--wake`, re-armed after each wake.**
Use it when the hook is not installed (the grep prints 0, or
`~/.local/bin/dsmr-bus-watch --help` lacks `--hook`), and once at bring-up as
above. Without the hook it is your only listener:

```
Bash(
  command: '~/.local/bin/dsmr-bus-watch --wake --all-buses --agent <name> --namespace <absolute-project-root>/',
  description: 'bus wake for <name>',
  run_in_background: true,
  timeout: 7200000
)
```

⛔ **`timeout: 7200000` is required.** The background default is 30 minutes, under
the 110-minute idle return below, so without it the runner kills the wait first
and tells you not to restart it. **The watch is permanent (operator ruling,
2026-10-01): long silence is normal, and nothing about a quiet bus is a reason to
stop listening.** If a kill ever does arrive, treat it as a wake anyway: drain,
then re-arm.

`--wake` waits for the next `bus:` or `error:` line to reach your detached
log(s), prints it exactly as the watcher wrote it, and **exits 0**. The harness
notifies you on that exit: that is the wake. `--all-buses` waits on every
detached watcher you have a pid file for and returns the first line any of them
gets, so one `--wake` covers every joined bus; `--bus <tag>` in its place waits
on one. Other exits:

- **`idle wake-seconds=<N>` and exit 0**: nothing arrived in N seconds (default
  6600, set with `--wake-seconds`). This is a wake like any other: drain every
  joined bus, then re-arm. It exists so the wait ends inside the runner's
  two-hour ceiling and re-arming stays the ordinary path.
- **`nowatcher bus=<name>` and exit 1** (`bus=*` under `--all-buses` when you
  have none): no live detached watcher to wait on, at the start or while
  waiting. Run step 1 (`--detach`) again, then re-arm the `--wake`.
- **exit 2**: no identity resolved; pass the `--agent`/`--namespace` you
  detached with.
- **exit 143**: it was sent SIGTERM (you, a restart, a reap). Re-arm if you are
  still meant to be listening.

Lines already in the log are never reported, so a re-arm never replays an old
wake into your context. A message that lands between one `--wake` exiting and
the next being armed is not lost: the watcher arms from your durable cursor at
each recycle and announces anything undrained again, and the catch-up
`bus-receive` in the wake procedure below closes the gap at once.

Why each piece:

- **A one-shot background Bash, not a Monitor** — background Bash wakes you on
  exit, and `--wake` exits exactly when there is something to read. There is no
  30-minute expiry, and **you re-arm only after traffic**, so an idle agent
  makes no re-arm calls at all and has nothing for an outage to refuse.
- **The literal `~/.local/bin/dsmr-bus-watch` path** — it is what the narrow
  Bash allow rule matches, and a matched rule resolves BEFORE the classifier in
  auto mode. A different spelling (a bare name, `$HOME/...`, a wrapper, a
  pipeline in front of it) does not match the rule and is judged by the
  classifier instead, which is the exposure this form exists to remove. Nothing
  may be piped in front of it or wrapped around it.
- **`--detach` launched once, never per re-arm** — the watcher launch happens at
  bring-up, when you are present to handle a refusal. `--wake` never launches
  anything.
- **The path is absolute, never a bare `dsmr-bus-watch`**, for a second reason
  too. Whether the bare name resolves depends on how the session was started: a
  tool call runs against a snapshot of the shell environment taken at session
  start, and a session launched by the fleet launcher can carry a much narrower
  `PATH` than one started from an interactive shell. When it does not resolve,
  the failure is silent in the worst way — the listener reports itself started,
  the command inside it says `command not found` where nobody is reading, and the
  agent is deaf with no error anywhere it will look. Measured 2026-08-15 on a
  leader, whose whole fleet was reporting into it at the time.
- **Run the liveness probe from the same shell that armed.** A probe run anywhere with a richer
  `PATH` answers for a watcher that was never started. That is also how this was found, by luck: the
  probe happened to run in the arming shell and said `command not found` rather than `dead`.
- **`--agent <name>` is a literal, never `"$DSMR_BUS_AGENT"`.** The variable is
  inherited, so a session started by a process that began life in another tree
  arms its watch under that tree's name and listens on its cursor. It answers
  `--check-live` with `live`, which is true and useless: the probe proves a
  watcher exists, never that it is watching for you. Write the name out.
- **`--poll-ms 250`** (on `--detach`) — reaction latency is the poll interval,
  not the recycle window. The recycle window only governs how often the watcher
  self-heals, never how fast a message wakes you.
- **`--stall-seconds N` (default 120)** — a watcher whose poll loop stops cycling
  exits with status 75, so a wedged watcher reads as `dead`/`stale` rather than
  alive and deaf, and a waiting `--wake` answers `nowatcher`. SIGTERM ends a
  watcher at once.

Drop `--bus <tag>` from `--detach` only when you are deliberately on the shared
host-wide bus (its log stem is `default--<name>--<hash>`). Spelling it out on a named bus
is worth the characters: it puts the bus in the line an operator reads, so an
arm on the wrong bus is a visible mistake rather than an invisible one.

### Why not the Monitor tail (retired 2026-09-30)

From 2026-09-29 the standing listener was a `Monitor` (`persistent: true`)
tailing the detached log: `tail -q -n0 -F <log> | grep --line-buffered -E
"^(bus|error):"`. It replaced a Monitor running the whole `--stream` loop, whose
every 30-minute re-arm re-launched the watcher and was refused or left without a
verdict six times across five sessions on 2026-09-29. The tail was expected to
pass the classifier more reliably because it is read-only. It did not solve the
problem, because **no Monitor call can be pre-approved in auto mode** (its allow
rules are dropped; it runs through the shell), and it **expires at 30 minutes
regardless of `persistent: true`**. So every half hour, busy or idle, the agent
had to win a fresh classifier verdict, and during an outage it lost it and went
deaf with its watcher still live. ⛔ Do not bring it back.

### Last-resort fallback: a binary without `--wake` or `--detach`

If `~/.local/bin/dsmr-bus-watch --help` lacks `--wake` or `--detach`, the PATH
binary is old: `make install-bus-watch` from the dsmr-mcp checkout, then arm as
above. Only if that is impossible, arm the old supervised stream directly in a
Monitor, knowing it has both defects above:

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
  2026-09-29, and no allow rule can pre-approve it. Treat it as a stopgap until
  the binary is current.

**Each agent arms in its OWN session** — a background command wakes only the
session that started it. Substitute `<project-root>/` for your real root; keep
the trailing slash.

## Park marks the watcher and keeps it; leaving the fleet reaps it

⛔ **PARK DOES NOT REAP (operator ruling, 2026-09-30).** A parked agent leaves its
detached watcher running, after marking the park while it is still listening:

```
~/.local/bin/dsmr-bus-watch --park --all-buses --agent <name> --namespace <absolute-project-root>/
```

It prints `parked bus=<b>` per watcher (`none bus=*` when you have none) and
exits 0; exit 1 means a marker could not be written. The marker tells the
watcher your silence is intended, so mail waiting on your cursor raises no
deafness notification while you are down. At the next bring-up, `--detach`
answers `running`, adopts the watcher and removes the marker; `--unpark` with
the same flags is the explicit form. The watcher is designed to survive a
session or fleet restart; reaping it at park only forces a cold re-launch at
bring-up. While parked, `--check-live` reads `live … parked=1`: the watcher
runs, nobody is listening, and that is intended. The bus holds the mail on your
cursor until you return.

`--reap` is for an agent **LEAVING the fleet** (`bus-leave`, disenrollment) or
for retiring a host:

```
~/.local/bin/dsmr-bus-watch --reap --all-buses --agent <name> --namespace <absolute-project-root>/
```

It sends SIGTERM to each watcher's process group, SIGKILL after 3 s, verifies the
pid is gone and removes the pid file. One line per watcher: `reaped pid=… bus=…
signal=term|kill`, `none bus=…`, `survived pid=… bus=…`, or `foreign …` for a
watcher under your name in another namespace, which it leaves running. **Exit 0
only when nothing of yours is left**; exit 1 means something survived — say so
rather than reporting yourself gone. Drop `--all-buses` and pass `--bus` to reap
one bus only. A reap also ends any waiting `--wake` with `nowatcher`.

A context rotation is not a park and not a departure either: the successor
re-runs `--detach`, which answers `running` for the watcher already up, and
arms only the listener.

## When the background `--wake` wakes you

A wake from the session hook is handled as step 2 says. A background `--wake`
wakes you by exiting, and the notification carries the line it printed:
`bus:<SEQ> …`, `error:…`, or `nowatcher bus=<name>`.

On **`bus:<SEQ>`**:

1. **Drain EVERY joined bus with `bus-receive`** under your stable `agent_id`.
   One `--wake --all-buses` returns on the first bus that has traffic, so drain
   them all, not only the one the line names. This advances your cursor so each
   message is delivered once — and so the watcher's next recycle re-arms above
   it.

   Delivery is bounded by message **count** (default 20 records), not bytes. On a
   large backlog pass a smaller `limit` (5–10) and page while `remaining_pending`
   is non-zero. A non-zero count means call again — you are not caught up.

   `skip_to_head` is a judgement call, never a default: it discards unread
   messages. Check `bus-status` first — at a handful pending, drain them, one may
   be addressed to you by name. Skip only a genuinely large, genuinely stale
   backlog. Your own pending count is the fact; an instruction to skip is a
   prediction — if they disagree, believe the count and say so.

2. **Re-arm the same `--wake` line** as a background Bash command, exactly as in
   step 2 of the arm, literal `~/.local/bin/...` path included. ⛔ **Skip this
   step when the session hook is installed**: the hook arms the next listener
   when this turn ends. Then one catch-up
   `bus-receive` per bus closes the gap between the old `--wake` exiting and the
   new one listening. **This is the only re-arm there is**, and it happens only
   after traffic: never on a timer, never while idle.

3. **Handle** what you received — confirm a sister's SHA, act on a request, relay
   to the operator. Publish any replies now. The `--detach` watcher is never
   re-launched for a wake; it is still running.

On **`nowatcher bus=<name>`** (exit 1): the detached watcher is gone. Run
`--detach` again for that bus (or for each joined bus on `bus=*`), then re-arm
the `--wake`, then drain.

On **`error:…`**: the detached watcher hit a fault (it retries on its own and
writes the same fault once): run `--check-live`, and if it answers
`dead`/`stale` run `--detach` again; then re-arm the `--wake` either way. If the
binary is missing or stale, `make install-bus-watch` first.

## Is your watch actually alive, and can you hear it? — the liveness probe

The running watcher refreshes a **heartbeat file** every poll and removes it on
clean exit, so "am I still listening?" is a cheap local check, not a `ps` grep:

```
~/.local/bin/dsmr-bus-watch --check-live --bus <tag> --agent <name> --namespace <absolute-project-root>/
# or with the full id:  --check-live --bus <tag> --agent-id <namespace>/<name>
```

- `live pid=<pid> age_s=<n> bus=<name> readers=<n>`, then `parked=1` and
  `deaf=<epoch>` when they apply (exit 0): a watcher is running for you now,
  **on the bus it names**. Check that name against the bus you meant to arm,
  **then read the rest**:
  - **`readers=1` or more**: something (a waiting `--wake`, the hook's or your
    own) holds the log open. You can hear. This is the only answer that proves
    it.
  - ⛔ **`deaf=<epoch>`: DEAF since that Unix time.** Mail reached the log and
    nothing read it for ten minutes (`--deaf-seconds` on `--detach`, default
    600). The watcher has already sent the operator a desktop notification
    saying so. Drain every joined bus, then arm a listener; the field clears
    once something reads the log. `deaf=unknown` means the marker exists but
    could not be read: treat it as deaf.
  - `parked=1`: you marked a park, so silence is intended and no alarm fires.
    Seen after bring-up, it means `--detach` did not run for that bus: run it.
  - `readers=0` with no `deaf=`: nothing follows the log at this moment. That is
    normal during a turn the hook's own wake started, and between a background
    `--wake` exiting and your re-arm. It becomes deafness only if it lasts with
    mail waiting, which is what `deaf=` reports. Without the hook, before you go
    silent, `readers=0` means re-arm the `--wake`.
  - `readers=unknown`: `/proc` could not say. Treat as unproven, not as heard.
- `dead bus=<name> readers=<n>` (exit 1): no heartbeat on that bus, nothing
  listening. **Run `--detach` again, then re-arm the `--wake`.**
- `stale pid=<pid> age_s=<n> bus=<name> readers=<n>` (exit 1): heartbeat not
  refreshed within `--live-window-seconds` (default 5), so the watcher wedged or
  was killed (a wedged one ends itself after `--stall-seconds`). **Run
  `--detach` again, then re-arm the `--wake`.**
- `unknown` (exit 2): no identity resolved; pass the same `--agent`/`--namespace`
  you armed with. This answer carries no bus, deliberately: a bus printed beside an
  unresolved identity would read as a probe that found something.
- exit **64** with a message on stderr: the bus name itself was refused. Fix the
  name; nothing was armed and nothing was created.
- **no `bus=` field on a `live`/`dead`/`stale` line**: the binary predates named
  buses. It armed on the shared bus whatever you asked for.
  `make install-bus-watch`, then re-arm.
- **no `readers=` field**: the binary predates the reader count (and `--wake`).
  `make install-bus-watch`, then re-arm.

Run it **once per joined bus**, with that bus's tag. A single `live` says nothing
about the other bus.

`--check-live` is the cheap assertion to run **before you go silent** — an agent
with pending mail and no listener is the invisible state this closes — and
**whenever a reply you expected never woke you.** It reads the heartbeat and
counts open readers only; it never consumes a message or touches your cursor.

## On bring-up (rejoin, then arm)

1. `bus-status` under your stable `agent_id` — confirm the broker is up and see
   the pending count. This also prints your self-identity and, now, whether a
   watcher is already live for you (`live_watcher`).
2. `bus-receive` (stable `agent_id`) — drain catch-up, repeating while
   `remaining_pending` is non-zero.
3. **Arm**: `--detach` once per joined bus (expect `running` if a watcher
   survived a park or restart; it is adopted and its park marker cleared), then
   the background `--wake` once. With the session hook installed this is the
   only background `--wake` you start; the hook takes over after it fires. A
   `bus-receive` right after the `--wake` is up closes any gap between the two.
4. `--check-live` per bus. `live` **with the `bus=` field naming the bus you
   armed AND `readers=1` or more** means you are actually listening to it.
   `dead`/`stale`/`unknown`, `readers=0`, `parked=1`, a bus field naming a
   different bus, or no bus field at all, all mean you rejoined blind. Fix it
   before you report ready.

A SessionStart hook may prime a one-shot watcher before turn one; it does not
replace this. The detached watcher plus one listener, the Stop hook or the
background `--wake`, is what keeps you reachable.

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
| Start listening (whole session) | `--detach` once per joined bus (answers `detached` or `running`), then `~/.local/bin/dsmr-bus-watch --wake --all-buses --agent <name> --namespace <root>/` as a **background Bash** command (`run_in_background`). Never the Monitor. With the session hook installed, that background `--wake` is the only one you start. |
| Session hook wakes you ("Stop hook feedback" from `dsmr-bus-watch`) | mail: drain every joined bus and act; idle: nothing; no watcher: `--detach`. Then end the turn. **Never re-arm**: the hook arms the next listener at turn end. |
| A `--wake` prints `already-armed` | another listener (the hook) holds the arm for you. Do not re-arm, do not retry. |
| Resumed after an interrupt (Esc) | let the turn end normally; an interrupted turn fires no Stop hook, so that end is what re-arms. |
| `--wake` exited with `bus:<SEQ>` | `bus-receive` every joined bus (stable id) → re-arm the same `--wake` line (not when the session hook is installed) → catch-up `bus-receive` → handle. |
| `--wake` exited with `nowatcher bus=…` | `--detach` again (each bus on `bus=*`), then re-arm the `--wake`. |
| `--wake` exited with `error:…` | the detached watcher hit a fault — `--check-live`; on `dead`/`stale` run `--detach` again; re-arm the `--wake`. |
| Idle for hours | nothing. No timer, no re-arm; the `--wake` waits indefinitely. |
| Parking | last drain, then `--park --all-buses --agent <name> --namespace <root>/`, then stop. **Do NOT reap**: the watcher stays up and `--detach` adopts it and clears the mark at bring-up. |
| Leaving the fleet / retiring a host | last drain, then `--reap --all-buses --agent <name> --namespace <root>/`; exit 0, or say what survived. |
| `--help` lacks `--wake` or `--detach` | stale PATH binary. `make install-bus-watch`; the bare `--stream` Monitor loop is the fallback only if that is impossible. |
| Am I still listening? | `~/.local/bin/dsmr-bus-watch --check-live --bus <tag> --agent <name> --namespace <absolute-project-root>/`, wanting `live`, the right `bus=`, **and `readers=1`+**. `deaf=`: drain, then arm a listener. `parked=1`: `--detach`. `dead`/`stale`: `--detach` again, then re-arm. |
| Before going silent | run `--check-live` per joined bus; never go silent on `dead`/`stale`, on `deaf=` or `parked=1`, on a `bus=` that is not the one you armed, or on `readers=0` without the session hook. |
| Joined to two buses | two `--detach` runs, two `--bus` tags, one `--wake --all-buses`, two `--check-live` runs. One `live` covers one bus. |
| `--check-live` prints no `bus=` field | stale PATH binary that armed on the shared bus regardless of what you asked. `make install-bus-watch`, then re-arm. |
| `--check-live` prints no `readers=` field | stale PATH binary without `--wake`. `make install-bus-watch`, then re-arm. |
| `--bus` exits 64 | the name is refused (over 32 chars, a character outside `A-Z a-z 0-9 - _ .`, a reserved name, or a socket path too long). Fix the name; never shorten it to fit. |
| Large backlog | `bus-receive` with `limit` 5–10, page on `remaining_pending`. |
| `bus-receive` rejects `limit` | MCP predates bounded delivery — `/mcp` reconnect (keeps context). |
| `--check-live` says `unknown argument` | PATH binary predates liveness — `make install-bus-watch`, then re-arm. |
| Omitting `--agent`/`--namespace` | don't — it arms at the head, wakes on your own publishes, **replays on every restart**, and has no heartbeat to check. |
| Tempted to `run_in_background` a `--stream` or `while true` watcher | that is the two-month deafness bug — it only notifies on exit, which never comes. Background only the one-shot `--wake`. |
| Tempted to go back to a Monitor tail | don't: Monitor allow rules are dropped in auto mode, so every re-arm faces the classifier, and it expires every 30 minutes. That is how agents went deaf through 2026-09-30. |

Companion skills: **fleet** (assembling a fleet on its own named bus) and
**fleet-restart** (park/bring-up discipline). The bus is the sole cross-repo
channel; this skill is how you stay attached to it.
