# Harness agents

These are subagent definitions for the agentic harness this project is developed with. I keep
a definition here when it belongs to this harness and nowhere else, so that the copy an agent
loads has a history and a review path like the rest of the code.

## What is here

| Agent | Purpose |
|---|---|
| `Explore` | Read-only fan-out search on Haiku, replacing the built-in Explore agent, which otherwise runs on whatever model the calling session uses |
| `shell-developer` | Writes the shell that builds, installs, and tests our systems: Makefiles, install scripts, git hooks, test drivers, and CI workflows |

I gave shell work its own executor because it does not need the strongest model, and Lisp work
does. A GSD plan whose every file is shell, make, CI, or a git hook can run on a cheaper model; every
Lisp change still goes to `lisp-developer`, and `shell-developer` refuses to edit a `.lisp` or
`.asd` file at all.

## Deploying, and the direction that matters

An agent runtime loads subagent definitions from its own configuration directory, not from this
tree, so tracking a definition here does nothing on its own.

```sh
make check-agents      # report drift between this tree and the deployed copies
make install-agents    # deploy this tree to $SUBAGENTDIR (default ~/.claude/agents)
```

⛔ **The migration direction is from the deployed copy into this tree.** A definition edited in
place is the newer one, and `install-agents` overwrites without asking. Run `check-agents` first,
and bring changes here before you deploy.

`check-agents` reports three kinds of drift: a tracked definition that was never deployed, a
deployed copy that differs from this tree, and a backup left beside a deployed definition. It
never edits anything, so you can run it against a live fleet.

This README is never deployed. An agents directory is flat, and a stray Markdown file in it would
be read as one more agent.

## What is deliberately NOT here

- **`lisp-developer`** stays global and on the strongest model. I maintain it where it lives, in the
  deployed agents directory, because every Lisp project on the host uses it and its tool wiring
  belongs to the host rather than to this project.
- **The `gsd-*` agents** belong to GSD, which installs and upgrades them with its
  own installer. A copy here would be a fork that the next GSD upgrade overwrites.

Both deploy targets work per file over the definitions tracked here, so neither one ever writes or
reports on these agents.
