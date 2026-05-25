# Contributing to dsmr-mcp

dsmr-mcp is AGPL-3.0-or-later. By contributing you agree your changes ship under that license.

## Keep planning scaffolding out of the code

dsmr-mcp is built against a planning workflow whose artifacts — roadmaps, phase
plans, research notes, decision logs — live outside the published tree. **None
of that scaffolding belongs in a tracked file.** A reader who clones this repo
has the code and nothing else: a planning index is noise to them, and a pointer
to an unpublished planning file is a dead link.

**Symbols — absolute rule, tests included.** A function, variable, class,
package, macro, or test name must never embed a planning index. No `phase-`,
`plan-`, `task-`, `wave-`, `d-NN-`, `t-NN-`, `req-`, or milestone-number prefix
or infix. Name the symbol for what it does:

- `(define-test error-context-parity …)` — not `d-17-error-context-parity`
- `verify-id-survival` — not `verify-req-09`
- `attach-object-registry` — not `phase-5-registry`

**Comments and docstrings.** Write the *what* and *why* in plain prose. Never
point at a planning artifact ("see PROJECT.md decision row", "wired by Plan
01-01", "per research Q1") — the file isn't published, so the pointer goes
nowhere. If the rationale matters, write the rationale.

**Allowed:** naming a real external product the code interoperates with — e.g.
a comment noting an error code "matches what Claude Code / Codex MCP clients
expect" — is domain context, not scaffolding. Keep it.

## Code conventions

- **JSON:** `com.inuoe.jzon`. Mind `nil` → `false`/`null` for nullable fields.
- **stdout is the JSON-RPC channel.** All diagnostics go to stderr via log4cl —
  never write to stdout from server code.
- **Cold-build before you trust a change.** This is a `package-inferred-system`:
  every file declares its own dependencies. A warm REPL hides missing-package
  errors, so verify against a cleared fasl cache and a fresh SBCL.
- **Code injected into an attached image must be portable ANSI.** The attached
  image may be any Common Lisp implementation, so injected payloads carry no
  SBCL-only or MOP-dependent forms. dsmr-mcp's own dispatcher and hermetic
  worker may use SBCL features freely.

## Running the tests

```sh
sbcl --non-interactive --eval "(asdf:test-system :dsmr-mcp)"
```
