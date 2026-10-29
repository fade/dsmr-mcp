---
name: restart-session-in-place
description: "Restart a running Claude Code session inside its existing kitty tab, by typing /clear and then /worker (or /leader) into it over kitty remote control, so a change to CLAUDE.md, a skill, settings or a hook reaches a session that is already running without opening a new window. Use when the operator asks to restart, refresh or reload running sessions or a fleet and wants no new tabs; a leader uses it on its own fleet only. Not for a dead or hung session, a non-kitty terminal, or your own session."
---

# /restart-session-in-place

CLAUDE.md loads once, when a session starts, and subagents inherit the parent's copy. A change
to it, to a skill, to settings or to a hook therefore reaches only new sessions. Opening new
windows for a fleet is `start-sisters.sh`. This skill restarts the sessions that are already
running, in the tab they already occupy: `restart-session-in-place.sh` types `/clear` and then a
role command into the window over kitty remote control.

## When to use it, and when not

Use it when a configuration change must reach sessions that are running and the operator wants
no new windows.

Do not use it for:

- a dead or hung session: there is nothing at a prompt to type into. Use `start-sisters.sh` or
  the fleet-restart skill.
- a terminal that is not kitty, or a kitty without remote control: the script reports
  `unsupported` and exits 3.
- your own session: the calling window is always refused. The operator types `/clear` there
  himself.

## Who may restart whom

⛔ A leader restarts only its own fleet. The targets come from its own roster, never from
another leader's sisters. A worker never runs this against another session. The script cannot
know a roster: the caller names the targets, and the caller owns that choice.

## Before restarting

`/clear` drops the target's conversation, and its bring-up rebuilds from files (PARK.md,
STATE.md). The target must therefore be parked or at a clean pause. See the fleet-restart skill
for parking. A session that is busy or holds typed input is refused, never interrupted.

Always run with `--dry-run` first. It resolves every target, runs the idle test on each, and
types nothing. A session counts as idle only when Claude Code's own prompt frame is on screen
with nothing typed in it (a dim suggested prompt is not typed input), no turn is running, and
no background agents or task panel are open. Anything doubtful is refused.

A restart takes minutes: each target waits for a new transcript, an idle prompt, and the
follow-up's answer, each bounded by `--timeout`. Run the script in the background
(`run_in_background`), or give the calling shell a timeout of at least
`targets x (3 x timeout + 30)` seconds. A shell timeout shorter than that kills the run
mid-sequence. The script then prints a `failed: interrupted` line for the target it was typing
into and `not-run` for the rest, but the window it was typing into is left cleared.

## How to call it

Once installed it is on PATH. From a checkout it is `scripts/restart-session-in-place.sh`.

```sh
restart-session-in-place.sh --dry-run zebra mallet     # check first, type nothing
restart-session-in-place.sh zebra mallet               # /clear then /worker, one at a time
restart-session-in-place.sh --then /leader valis       # a leader tab
restart-session-in-place.sh --then '' zebra            # /clear only
restart-session-in-place.sh --then '/worker TAG' zebra # a worker on a fleet tag
restart-session-in-place.sh /home/fade/SourceCode/lisp/zebra   # a path, to break an ambiguity
restart-session-in-place.sh --timeout 300 zebra        # each wait is bounded, default 120 seconds
restart-session-in-place.sh --expect 'some new text' zebra
```

A name matches the one window whose tab title is the name and whose claude process runs in a
directory with that name, across every kitty instance. A same-titled plain REPL in another
instance is never matched. A path matches by the exact directory instead.

`--then` must be empty or start with `/`, with no backslash, because kitty decodes backslash
escapes in what it types.

`--expect PATTERN` checks that the restarted session loaded the new configuration. Choose text
that is present in the NEW configuration and absent from the old one, with no quotes or
backslashes: it is matched as a fixed string against the raw transcript. A file modification
time proves nothing, because `cp -p` keeps the old one. Not allowed with `--then ''`, since no
turn is written to check.

Never improvise the typing by hand with a kitten command held in a shell variable. Under zsh
the variable is not split, nothing is sent, and nothing is reported.

## Reading the result

One line per target on standard output:

```
NAME SOCKET WINDOW old=ID new=ID VERDICT
```

`old` is the newest transcript in the target's directory before the restart, so with two
sessions in one directory it can name the other one. `new` is the transcript the restart
started. `-` marks a field that is not known.

| Verdict | Meaning | What to do |
|---|---|---|
| `ok` | restarted, the follow-up ran, and the pattern was found when one was given | confirm the sister by its own bring-up announcement, not by this verdict alone |
| `would-restart` | `--dry-run`: every check passed | run it again without `--dry-run` |
| `refused: ...` | nothing was typed | busy: wait and try again later, never interrupt. Several matches: pass the path. No match: check the name and that the tab is a claude session |
| `failed: ...` | typing began and a stage did not complete | look at the target; the stage and the bound are in the message |
| `not-run` | an earlier target stopped the run, or a target failed to resolve | nothing was typed there |

In a real run the first refusal or failure stops the run, so a `not-run` line is not a problem
with that target. A `--dry-run` checks every target and stops at none.

Exit status: 0 every target ok (every target `would-restart` under `--dry-run`), 1 any refused
or failed, 2 usage error or two targets that resolve to one window, 3 unsupported environment.
