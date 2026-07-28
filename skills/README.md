# Harness skills

This project is the record of the agentic harness it is developed with, not only an MCP
server. The skills here are the generalisable parts of that harness. They were written
directly into one machine's agent configuration while the fleet was being brought up, which
left the only copy on a single host and outside version control. This directory is where
they live now.

## What is here

| Skill | Purpose |
|---|---|
| `fleet` | Assemble a fleet on a bus of its own and hand each repo its tag |
| `leader` | Rebuild a leader's repo and whole-fleet context, then assert control |
| `worker` | Rebuild a sister's repo context, pre-clear permissions, arm its watch, go quiet |
| `bus-watch` | Stay reachable on the coordination bus without polling |
| `fleet-restart` | Coordinated park and bring-up across a fleet |
| `broker-rotate` | Retire a running broker and start a fresh one without losing messages |
| `rotate-context-window` | Snapshot in-flight state so the next instance resumes cleanly |
| `scaffold-project` | Generate a new Common Lisp project from this project's skeleton |

## Deploying, and the direction that matters

An agent loads skills from its own configuration directory, not from this tree, so tracking
a skill here does nothing on its own.

```sh
make check-skills      # report drift between this tree and the deployed copies
make install-skills    # deploy this tree to $SKILLDIR (default ~/.claude/skills)
```

⛔ **The migration direction is from the deployed copy into this tree.** A skill edited in
place while a fleet was running is the newer one, and `install-skills` overwrites without
asking. Run `check-skills` first, and bring changes here before deploying.

⚠ **A skill tracked here but never deployed is worse than one that was never tracked.** It
reads as version controlled while an agent loads something else, and nothing reports the
divergence. The `scaffold-project` entry rotted nineteen lines behind exactly that way. Port
and deploy together.

Command names are deliberately unchanged. A fleet's bring-up path invokes `worker` and
`leader` by name across every participating repository, so renaming them is a coordinated
change to make when no bring-up depends on the old names.

## What is deliberately NOT here

Not everything in an agent's skills directory belongs to this project, and adopting a
third-party skill would fork an artifact whose own installer will later overwrite the fork.

- **The `gsd-*` planning system** (67 skills) is the `get-shit-done-cc` package, installed and
  upgraded by its own tooling and tracked by its own file manifest. Local adjustments to it
  belong in that package's patch directory, not here.
- **`graphify`** is a separate installed tool with its own CLI and version marker. The skill
  ships with the tool.
- **Skills shipped with the agent itself** are the vendor's to maintain.
