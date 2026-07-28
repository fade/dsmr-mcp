---
name: fleet
description: "Assemble a fleet on its own named bus from the leader's terminal: validate the names, declare the leader, enroll each sister, hand every repo its tag, and print the arm line each sister will use. Use when starting a new fleet, adding or removing a participant on a running one, closing enrollment, or when the operator types /fleet. Covers what the roster is (advisory) and what it is NOT (evidence anybody is connected)."
---

# /fleet

Assemble a fleet on **its own bus**, from the leader's terminal, in one pass.

```
/fleet <leader> <sister> <sister> ...
```

The first position is the leader, and **the leader names the bus**. Local practice
names an agent after its repository, so `/fleet valis fulcrum mercer hekate seven`
is a fleet led by `valis`, on the bus called `valis`, with four sisters joined.

## Read this first: the two failures this exists to prevent

**A watcher on the wrong bus reports healthy and never fires.** It has a live
heartbeat, `--check-live` says `live`, and no message ever reaches it. Nobody
learns until the operator notices that a dispatch went unanswered. That is why a
bus name that cannot be honoured is refused outright instead of quietly falling
back to the shared bus, and why every liveness answer now names the bus it
answered for.

⛔ **The roster is not a liveness check, and it is not a gate.** An agent absent
from the roster still reaches the bus, publishes on it, and receives from it.
Enrollment records intent; it enforces nothing and proves nothing about who is
connected. **Never conclude a sister is up because it is on the roster, and never
conclude it is unreachable because it is not.** Liveness is
`dsmr-bus-watch --check-live`, run per bus, and nothing else.

## What isolation actually is

Each named bus gets its **own state root**: its own write-ahead log, broker lock,
membership lock, cursors directory and its own pair of sockets. That separation,
plus the filesystem permissions on that directory, is the whole isolation
mechanism. There is no membership check inside the transport and no cryptographic
guard to look for, because the transport has no security surface that could back
one.

A declared leader plus a gate the leader can close is the entire answer to two
fleets on one machine. It is enough because each fleet names its own bus and
records its own leader, so nobody is guessing which fleet a message belongs to.

## Step 1 - Check every name before touching anything

A name becomes one directory segment inside the bus state root, so its cost is
charged against the socket path budget. Check each name in the line, the leader's
included:

- at most **32 characters**;
- **alphanumerics plus `-`, `_` and `.`** only. Any separator, any whitespace, and
  every other character is refused;
- **not reserved**: `default`, `cursors`, `watch`, `roster`, `members`, `bus.wal`,
  `broker.lock`, `submit.ipc`, `pub.ipc`, `.`, `..`.

`default` is reserved for its own reason: it is the word printed for the shared
unnamed bus, so a bus actually called `default` would be unreadable in exactly the
output an operator uses to tell buses apart.

⚠ **A refusal at this point is deliberate and is not a bug to work around.** An
over-long name, or one whose derived socket path would not fit the kernel's
unix-domain limit, is refused loudly and nothing is created. Nothing is ever
shortened to fit, because a truncated socket path is a silently different bus:
two agents would both report success and never hear each other.

## Step 2 - Declare the leader, then enroll each sister

Through the `bus-roster` verb, naming the bus explicitly:

```
bus-roster {"action": "declare-leader", "agent": "<leader>", "bus": "<tag>"}
bus-roster {"action": "enroll",         "agent": "<sister>", "bus": "<tag>"}
   ... once per sister ...
bus-roster {"action": "list",           "bus": "<tag>"}
```

- `agent` takes either a full `NAMESPACE/NAME` bus id, or the bare name, which is
  qualified with **this session's own project namespace**. A bare name can never
  reach into another project's namespace, which matters because two projects may
  both run an agent called `valis`.

⚠ **A bare name is qualified with YOUR namespace**, so naming a sister that way
enrolls an agent in your own project rather than the sister's. For a sister in
another repository, give the full id: its repository path, a separator, its name.

```
/home/fade/SourceCode/lisp/parachute/parachute
```

Write it the way it reads. The join normalizes, so a repository path with or
without its trailing separator gives the same id, and a doubled separator folds
onto the same entry as a single one. You cannot get this wrong by typing it
naturally.

⇒ **The way that avoids composing anything at all: enroll from the sister's own
session**, where a bare name is qualified with that session's namespace by
construction.

⇒ A mismatched entry breaks nothing, because the roster enforces nothing. That is
why it fails silently, and why reachability is always `--check-live` and never the
roster.
- `list` returns every entry with its status, role, enrollment time and departure
  time, plus whether the gate is open and who leads.
- `disenroll` marks an agent departed and stamps when. It is not a cutoff: see
  below.

⚠ **An enroll that the gate refuses comes back as a normal answer, not an error.**
It carries `enrolled: false` with a named reason. Nothing failed: the leader
declined to list an agent that remains free to use the bus. Do not retry it, and
do not treat it as a transport problem.

## Step 3 - Set each sister's tag. DO IT, do not describe it.

⛔ **Run this. Do not print the edit and ask the operator to make it.** The tag is
the one fact that differs per repo, and making a person carry it into nine files
by hand is clerical work this skill exists to remove.

```sh
~/.claude/skills/fleet/assign-bus.sh --tag <tag> --apply --yes <repo> [<repo> ...]
```

Give it the repository path of every sister in the line, and the leader's own. It
sets `DSMR_BUS_SELECTOR` in each `.envrc`, backs every file up first, refuses any
edit that would leave more or fewer than one declaration, runs `direnv allow`, and
reports per repo. It is idempotent: run it twice and the second run says "already
correct".

Drop `--yes` to be asked before each write. Drop `--apply` for a dry run with a
diff, which is worth doing the first time you point it at a fleet you care about.

**Resolve the paths before calling it.** The line gives you agent names, not
directories. Local practice names an agent after its repository, so a name usually
maps to a sibling directory of the leader's, but check rather than assume: a wrong
path is silently skipped with `SKIP no .envrc` rather than failing loudly. Read the
script's summary line and confirm the changed count equals the number of repos you
named.

⚠ **What it does not do, and must not:** it does not restart anything. A running
session keeps the environment it launched with, so every repo it changed needs its
session exited and started fresh from a shell in that directory. A `/mcp` reconnect
is not enough. Say so, per repo, in your report.

The variable is already declared in each `.envrc`, empty, because empty reads as
unset everywhere. Assigning a repo to a fleet is setting that value, never adding
a line. The script enforces that distinction; you do not have to.

## Step 4 - Print the arm line each sister will use

Show it with `--bus` spelled out, even though the environment would supply the
same value. The flag exists precisely so the line an operator reads names the bus
it arms on:

```
while true; do dsmr-bus-watch --stream --poll-ms 250 --recycle-seconds 1800 \
  --bus <tag> --agent "$DSMR_BUS_AGENT" --namespace <absolute-project-root>/ \
  || echo "error:watch-crashed rc=$?"; sleep 1;
done | grep --line-buffered -E "^(bus|error):"
```

⛔ **Print the loop, never the bare watcher.** `--stream` exits 0 on its idle
window deliberately, because that exit is the self-heal that re-arms a watch
which has gone silently deaf. The Monitor tool ends a watch when its command
exits, so a sister handed a bare `dsmr-bus-watch --stream` goes deaf at the first
idle mark while believing it is armed. The `while true` loop turns that exit into
a re-arm; the `grep` keeps `recycle:` off the sister's context.

Each sister arms that in **its own session**, through the Monitor tool with
`persistent: true`. See the **bus-watch** skill for why a background Bash task is
not an arm. Then it confirms:

```
dsmr-bus-watch --check-live --bus <tag> --agent "$DSMR_BUS_AGENT" --namespace <absolute-project-root>/
```

and must see **both** `live` **and** `bus=<tag>` before going silent.

## Step 5 - Close enrollment, and know what that means

```
bus-roster {"action": "close-enrollment", "bus": "<tag>"}
```

- **What it does:** stops the leader from listing new participants. Existing
  entries carry on unaffected.
- **What it does not do:** stop anybody from connecting, publishing or receiving.
  A refused agent uses the bus exactly as any other participant does.
- Reopen with `open-enrollment`. The gate is meant to be opened and shut as the
  operator sees fit; there is no ceremony to it.

Closing is worth doing anyway, because it makes an unexpected join visible in the
roster instead of invisible in the traffic.

## Removing a participant

`disenroll` marks the entry departed with a time. The clean departure is the
agent's own act: it runs `bus-leave`, which reads out whatever is still waiting for
it, records the departure with its time, and disconnects. From then the bus's
busmaster holds that agent's cursor at the head of the log, so nothing it never
read can pin the log. A sister that returns later resumes at the current head and
receives no backlog for the period it was away, which is what having left means.

Leaving twice returns the same departure time, so a repeated leave is safe.

## An agent can join a bus it does not lead

This is why the design is shaped the way it is, not an edge case. An agent leads
one bus and joins another it cooperates with, for example to report operational
findings to a project it is not a member of.

- **Joining never confers leadership.** Leadership belongs to whoever assembled
  the bus and is recorded per bus.
- **A joined agent is a full member in every other respect**: it publishes,
  receives, appears in the roster, and can be enrolled and disenrolled like anyone
  else.
- **It reads that fleet's traffic**, which is a cost it chose by joining. That is
  the one thing segmentation buys, and joining spends it deliberately.
- **Every joined bus needs its own armed watcher**, with its own `--bus` and its
  own liveness answer. One watcher does not cover two buses.

## Quick reference

| Situation | Do |
|---|---|
| Assemble a fleet | validate names, `declare-leader`, `enroll` per sister, print the `.envrc` value and the arm line, `close-enrollment` |
| A name is refused | fix the name. Never shorten it to fit; a truncated socket path is a different bus |
| Add a sister to a running fleet | `open-enrollment` if shut, `enroll`, hand it the tag, have it arm and confirm `bus=<tag>` |
| Remove one | the sister runs `bus-leave`; the leader records it with `disenroll` |
| "Is this sister connected?" | `--check-live --bus <tag>` in that sister's session. **Not** the roster |
| Enroll came back `enrolled: false` | the gate is shut. That agent still uses the bus; nothing failed |
| Sister says `live` with no `bus=` field | its `dsmr-bus-watch` binary predates named buses and armed on the shared bus. `make install-bus-watch`, then re-arm |
| Two fleets on one machine | two tags, two declared leaders, two closed gates. There is no further guard and none is coming |

Companion skills: **bus-watch** (how a watch is armed and proved), **worker** (how
a sister brings itself up on its buses), **fleet-restart** (park and bring-up).
