---
name: executor-routing
description: The rule a GSD planner applies when choosing which executor runs a plan; it sets `agent_hint: shell-developer` on a plan whose every modified file is shell, Makefile, CI or git-hook, and is read by gsd-planner through agent_skills rather than invoked directly. Also carries two rules for every plan, hinted or not - tests of another program's output use recorded output, and a plan that builds something ends before installing it outside the repository.
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

## Every plan, hinted or not

1. **Tests of another program's output use recorded output.** When the change reads output it does
   not produce (a terminal screen, a CLI's text, a log, a JSON reply, a transcript), the plan's test
   task names where real captures come from and requires every state the code must tell apart.
   Never write a fixture into the plan from memory. On 2026-10-29 a plan specified a busy screen
   containing "esc to interrupt"; the Claude Code build in use never draws it, and the tests passed
   against a guard that could not fire.
2. **A plan that builds something ends at build, test and commit: no install task outside the
   repository**, even when the brief asks for one. Every deploy target reaches every session on the
   host. Note the deferred install in the plan; the leader deploys after the code review passes. On
   2026-10-29 a brief asked for deployment, the plan installed a session-restart script before
   review, and it stayed installed, with four blockers, until the review withdrew it.

Both rules are also in global `~/.claude/CLAUDE.md`, so the executor reads them whichever agent
this skill routes the plan to.

## Why

Lisp work stays on the strongest model. The shell that builds, installs and tests our systems does
not need it. Routing that work to shell-developer runs it on a cheaper model, under an agent that
refuses Lisp edits and whose tool set cannot reach the coordination bus.
