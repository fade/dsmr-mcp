---
name: broker-rotate
description: "Retire a running dsmr-mcp bus broker and bring up a fresh one on current code, without losing messages or rotating the WAL. Use when the broker has been up long enough to be serving stale source, when a broker must be restarted to pick up a fix, or when the operator asks to reap or refresh the broker. Covers the last-member-out measurement that decides whether the WAL rotates, the correct signal, the authoritative liveness probe, and the two instruments that lie. Companion to bus-watch and fleet-restart."
---

# /broker-rotate

Replace a running coordination-bus broker with a fresh one on current source.

The broker is shared infrastructure: every sister in the fleet publishes through
it. This is not a repo-local act. **Get the operator's go before running it**,
and prefer a quiet bus.

Verified 2026-07-26 against a broker that had been up six days: the signal, the
shutdown, the election-lock probe, the socket rebind and the round-trip publish
were all executed and measured.

⚠ **One bound, stated because the first draft of this file overclaimed.** The
relaunch in step 3 was rewritten after that run. Its argv reconstruction is
tested and the detached-launch form is the one that actually brought the current
broker up, but the two have not been exercised together as a single command.
Check the `ARG[...]` output before you trust it.

## Why you would

The broker is a detached SBCL process that `quickload`s the broker subsystem
from the project source directory at spawn time. It then runs until something
kills it. A broker started weeks ago is serving the code that existed weeks ago,
and no amount of rebuilding the core or the watcher binary reaches it. Restart
is the only delivery mechanism.

The cheap tell: compare the broker's start time against the last commit that
touched anything under `src/bus/`.

## The one thing to measure BEFORE you signal

On a clean shutdown the broker runs `archive-on-clean-exit`, which rotates the
WAL to an archive **if the dying broker is the last member out**. With a fleet up
that does not fire, but "should not" is not a measurement, and a surprise WAL
rotation is fleet-visible.

```bash
B=~/.local/state/dsmr-mcp/bus
lsof "$B/members" 2>/dev/null | awk 'NR>1{print $2}' | sort -u   # who is a member
flock -n -x "$B/members" -c 'echo "LAST MEMBER OUT: rotation WILL fire"' \
  || echo "other members hold it: rotation will NOT fire"
```

Blocked is the safe answer. If it acquires, you are the last one out: either
accept the archive deliberately or wait until other agents are up.

⚠ Do not build a positive control by taking `flock -x` on the same file in the
same script. The lock is already held, so your control blocks forever and the
command dies on its timeout. `lsof` listing many distinct holders is the
independent corroboration, and it costs nothing.

## Rotate

### 1. Capture pre-state, so you can prove what did and did not change

```bash
B=~/.local/state/dsmr-mcp/bus
stat -c 'bus.wal inode=%i size=%s' "$B/bus.wal"
ls -la "$B"/*.ipc
ls "$B/cursors" | wc -l
ls -d "$B"/archive* 2>/dev/null | wc -l
```

The WAL **inode** is the number that matters. Unchanged inode proves no rotation
happened; size alone proves nothing, because a live bus is still being appended.

### 2. SIGTERM, never SIGKILL

```bash
kill -TERM <broker-pid>
```

`broker-main` installs a SIGTERM handler that breaks the serve loop and runs the
orderly shutdown: archive decision, close endpoints, release locks. **SIGHUP is
deliberately ignored** so the broker outlives the agent that spawned it, so HUP
does nothing. SIGKILL frees the flock (the kernel drops it on process death) but
skips the orderly path entirely.

Expect exit within a couple of seconds. If it is still alive after ~15s, **do not
escalate to -9**; investigate instead, because a broker that will not leave the
serve loop is a finding, not an obstacle.

### 3. Spawn the replacement explicitly. Do not assume something else will.

⛔ **`ensure-broker` firing on the next bus call is not a reliable respawn.** In
the verified run, a `bus-status` after the kill reported `Bus down (no broker)`
and no broker appeared. Spawn it yourself and confirm, rather than calling a verb
and hoping.

Relaunch what was actually running. Capture it **before** you signal, because
`/proc/<pid>` disappears the moment the process exits and the literal argv is
then gone for good.

⛔ **Do NOT capture with `ps -o args=` and paste it into a shell. It does not
round-trip, and the failure is silent in the worst way.** `ps` joins argv with
spaces and strips all quoting, so each `--eval` form, one single argument
containing spaces, parens and double quotes, comes back as dozens of bare words.
Bash rejects it outright with `syntax error near unexpected token '('`. Verified
2026-07-26; the paste is not merely fragile, it cannot work.

Capture the real argv, which is NUL-separated and preserves argument boundaries:

```bash
cp /proc/<broker-pid>/cmdline /tmp/broker.argv    # do this FIRST, before the kill
```

Then exec it back with the boundaries intact, detached, appending to the bus log:

```bash
setsid xargs -0 -a /tmp/broker.argv sh -c 'exec "$@"' sh \
  >> "$B/broker.log" 2>&1 < /dev/null &
```

`xargs -0` splits on NUL rather than whitespace, and `sh -c 'exec "$@"' sh`
execs argument 1 with the rest as its arguments, so nothing is ever re-parsed by
a shell. Confirm the reconstruction before relying on it:

```bash
xargs -0 -a /tmp/broker.argv sh -c 'printf "ARG[%s]\n" "$@"' sh
```

Each `--eval` form must appear as exactly one `ARG[...]`. If a Lisp form is split
across several, stop: the capture is wrong and launching it will start a broker
that is not the one you retired.

**If you must hand-write the command instead** (no live process to capture from),
write `(quote (...))` rather than `'(...)` in the `--eval` forms. The reader
treats them identically, and it spares you nesting a single quote inside a
single-quoted shell argument.

It quickloads from source, so first light takes roughly 20 to 30 seconds on a
warm fasl cache. Longer is normal on a cold one.

### 4. Wait on the election lock, which is the only honest liveness signal

```bash
for i in $(seq 1 20); do
  flock -n -x "$B/broker.lock" -c true 2>/dev/null \
    && echo "lock FREE (no broker yet)" \
    || { echo "lock HELD: a broker is serving"; break; }
  sleep 3
done
```

## Two instruments that lie, both of which cost time in the verified run

⛔ **`pgrep -f broker-main` matches your own monitoring shell.** The pattern
appears in the command line of the very loop you are running, so it reports a
broker that does not exist, with a stable plausible pid, for as long as you care
to watch. It is a textbook false positive and it reads exactly like success.
Match on a string that cannot appear in your own command, or better, use the
election lock, which cannot be faked by a bystander process.

⚠ **`broker.log` is appended by the spawning process's redirection, not by the
broker's own logging.** If you launch without redirecting, the log's mtime stays
frozen at the previous broker's start and looks like proof that nothing spawned.
Check the mtime, but never treat a stale one as conclusive on its own.

## Verify, with the WAL inode as the anchor

```bash
ps -eo pid,lstart,args | grep 'dsmr-mcp/src/bus/broker' | grep -v grep
stat -c 'bus.wal inode=%i size=%s' "$B/bus.wal"   # inode MUST match pre-state
ls -la "$B"/*.ipc                                  # timestamps should be NOW
ls -d "$B"/archive* 2>/dev/null | wc -l            # expect unchanged
tail -6 "$B/broker.log"
```

Then a real round trip: `bus-status` should report **Bus up**, and a `bus-publish`
should return a sequence number **higher than the last one before the rotation**.
That advancing seq is the proof the new broker is actually serving, as opposed to
merely holding a lock.

✅ **Stale unix domain sockets are not a problem.** `pub.ipc` and `submit.ipc`
were six days old in the verified run and the new broker rebound both cleanly,
stamping them with the current time. This was an open worry beforehand; it is
settled.

## Watchers survive it

The reasonable fear is that a rotation is exactly when a watcher goes quietly
deaf. In the verified run it did not happen to anyone. A rollcall taken minutes
after the rotation had every sister on the fleet report `live` from
`--check-live`, several of them still holding the same watcher pid they armed
with, so the watch rode the rotation rather than being re-armed into looking
healthy. Cursors were kept rather than rebuilt: agents received the rollcall as
one new message with no re-delivery of the sequences before it.

⚠ That is evidence from one rotation, on a fleet whose watcher binaries were all
current. It is not a guarantee, and it says nothing about a watcher running an
older binary. Still worth a rollcall afterwards rather than an assumption.

## Expect the cursor reaper to fire, and expect it to be loud

A fresh broker reaps orphaned ephemeral cursors at startup. In the verified run
it removed 185 of 394 in one line:

```
dsmr-mcp bus: reaped 185 orphaned ephemeral cursors older than 7 days
```

That is correct behavior, not damage. It also carries a finding worth keeping:
if the reaper only runs at broker start, a broker up for weeks never reaps again,
which is a sufficient explanation for a cursor directory that grows without bound
while the reaping code looks correct on inspection. Treat that as a lead rather
than a conclusion; it was observed once, and observing the reap is not the same as
proving the reaper has no periodic path.

## What a good rotation looks like when you report it

Claim, evidence, bound:

- old pid and how long it had been up, new pid and what source it loaded;
- WAL inode identical before and after, archive count unchanged, messages lost: 0;
- an advancing published seq as the round-trip proof;
- and what you did **not** verify.

🄯 Brian O'Reilly <fade@deepsky.com>, 2026
