---
name: executor-routing
description: The rule a GSD planner applies when choosing which executor runs a plan; it sets `agent_hint: shell-developer` on a plan whose every modified file is shell, Makefile, CI or git-hook, and is read by gsd-planner through agent_skills rather than invoked directly.
---

# Executor routing

Apply this rule to every PLAN.md you write, after its files list is settled.

## The rule

Write `agent_hint: shell-developer` in the PLAN.md frontmatter, on the line after `autonomous:`,
if and only if EVERY path in `files_modified` and in every task's `<files>` is one of:

- a Makefile: `Makefile`, `GNUmakefile`, or `*.mk`;
- a shell script: `*.sh`, `*.bash`, or an extensionless script whose shebang runs `sh`, `bash` or
  `dash` (git hook scripts included);
- a CI workflow definition: `.github/workflows/*.yml`, `.github/workflows/*.yaml`,
  `.forgejo/workflows/*`, `.woodpecker.yml`, `.woodpecker/*`;
- a shell test driver.

Planning state the plan writes (evidence, notes, its own SUMMARY.md) lives outside the repository
and does not count either way.

## When to leave it unset

Leave `agent_hint` out of the frontmatter when ANY modified file is:

- Common Lisp: `.lisp`, `.asd`, `.ros`;
- C: `.c`, `.h`;
- any other programming language;
- documentation: `.md`, `.org`, a README;
- an agent or skill definition;
- a systemd unit or any other configuration file;
- a zsh script.

A mixed plan gets no hint. Unset means the project's default executor, which in this project is
lisp-developer through `planning.agents.specialized`. Never write `agent_hint: lisp-developer`
explicitly, and never write any name other than `shell-developer`.

## Constraints on a hinted plan

- Do not split or reshape a plan only to make it routable. Classify the plan you would have written
  anyway.
- Every `<verify>` command in a hinted plan must be shell: make targets, `shellcheck`, `bash -n`,
  `sh -n`, a script's own self-test. shell-developer cannot drive a Lisp image, so a verify step
  that needs one makes the plan unroutable; leave the hint off.

## Why

Lisp work stays on the strongest model. The shell that builds, installs and tests our systems does
not need it. Routing that work to shell-developer runs it on a cheaper model, under an agent that
refuses Lisp edits and whose tool set cannot reach the coordination bus.
