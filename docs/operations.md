# dsmr-mcp Operations Runbook

This is the field runbook for `dsmr-mcp`. When the server misbehaves,
find the matching failure mode below and follow the
symptom → cause → check → fix recipe. It documents the health surface
(`pool-status` and the attached-mode equivalent) and the four failure
modes that actually happen in the field: cold start, attached-mode
degradation, the hermetic-worker crash loop, and alive-lsp absence.

Security note: none of these recipes ever tell you to relax a control to
make a symptom go away. Questions about binding off-loopback or exposing
the server to the network belong in `docs/threat-model.md`, not here —
`dsmr-mcp` is a trusted, localhost-only tool.

## Cold start

`dsmr-mcp` boots through `dsmr-mcp:run`, which resolves every setting
with the precedence **keyword argument > `DSMR_*` environment variable >
`.dsmr-mcp.conf` > built-in default**, then dispatches to the selected
transport.

### Boot by transport

- **stdio** (the default) — `(dsmr-mcp:run)` or `(dsmr-mcp:run
  :transport :stdio)`. Blocks reading `*standard-input*` until EOF.
  This is the transport an MCP client launches as a subprocess and
  speaks one JSON-RPC message per line.
- **TCP** — `(dsmr-mcp:run :transport :tcp :port 7000)`. A threaded,
  multi-client line-delimited JSON-RPC listener, one session per
  connection.
- **HTTP** — `(dsmr-mcp:run :transport :http :port 7000)`. Streamable
  HTTP over Hunchentoot for Claude Code URL mode.

### Environment surfaces that select mode and Slynk target

| Variable | Effect |
|----------|--------|
| `DSMR_TRANSPORT` | `stdio` (default), `tcp`, or `http`. |
| `DSMR_MODE` | `attached` (default), `hermetic`, or `auto`. `auto` probes the Slynk listener and falls back to `hermetic` when it is unreachable; explicit `attached` never falls back. |
| `DSMR_SLYNK_ATTACH` | `host:port` of the Slynk listener for attached mode (e.g. `127.0.0.1:4005`). |
| `DSMR_BIND` | Listener bind address for `tcp`/`http`. Default `127.0.0.1`. |
| `DSMR_ALLOW_REMOTE` | Must be `1`, `true`, or `yes` to allow a non-loopback `DSMR_BIND`. Absent it, a non-loopback bind is refused at startup (see "It will not start"). |
| `DSMR_LOG_LEVEL` | `debug`, `info` (default), `warn`, or `error`. Logs are structured JSON on **stderr**, never stdout. |
| `DSMR_PROJECT_ROOT` | Server working root; defaults to the process cwd. |

A malformed value for `DSMR_TRANSPORT`, `DSMR_MODE`, `DSMR_LOG_LEVEL`,
or `DSMR_PORT` signals a typed `invalid-config-value` at startup with a
human-readable message naming the offending variable — so an env-var typo
fails loudly and early rather than booting into a surprising mode.

### Confirm a clean load on a cold FASL cache

Before launching the server, confirm the system compiles and loads
cleanly from a cold cache. In a fresh SBCL:

```lisp
(asdf:load-system :dsmr-mcp)
```

A clean cold load returns with no aborting warnings. To force a truly
cold compile, clear the ASDF output cache first (typically
`~/.cache/common-lisp/`) so stale FASLs cannot mask a build break.

### It will not start — first things to check

1. **Package-inferred cold-build dependency errors.** `dsmr-mcp` is a
   `package-inferred-system`: each file's `defpackage` declares its own
   external dependencies. A warm REPL can hide a missing declaration
   because the package already exists in the image; a cold load surfaces
   it as `Package X does not exist`. If `(asdf:load-system :dsmr-mcp)`
   fails this way on a cold cache, the offending file's `defpackage` is
   missing an `:import-from` for the package it uses. Always confirm the
   cold load, not just the warm one.
2. **Quicklisp / userinit noise on the stdio channel.** On the stdio
   transport, anything written to `*standard-output*` that is not a
   JSON-RPC message corrupts the channel and the client sees a protocol
   error. A `~/.sbclrc` or Quicklisp banner that prints to stdout at
   startup is the usual culprit. Logs are deliberately routed to stderr
   for this reason; keep startup chatter off stdout.
3. **Non-loopback bind refused.** If `tcp`/`http` startup signals
   `invalid-config-value` for `DSMR_BIND`, the bind address is not
   loopback and `DSMR_ALLOW_REMOTE` is not set. This is the safety gate
   working as designed — see `docs/threat-model.md` before changing it.
4. **Hermetic mode wedged at startup.** When `*mode*` resolves to
   `hermetic`, `run` initializes the worker pool, which pre-warms the
   worker system's FASL cache once in the parent before any child
   spawns. On a cold cache this adds a one-time compile to startup; on a
   warm cache it returns immediately.

## Health checks

### `pool-status` — hermetic-mode health verb (OPS-03)

`pool-status` is the health surface for hermetic mode. It is an MCP verb
that takes no arguments and returns a structured JSON body with these
fields:

| Field | Meaning |
|-------|---------|
| `pool_running` | `true` when the pool's health monitor is live. |
| `total_workers` | Count of all live worker processes (bound + standby). |
| `standby_count` | Warm workers ready for immediate assignment. |
| `bound_count` | Workers currently bound to a session. |
| `max_pool_size` | Configured ceiling (`DSMR_MAX_POOL_SIZE`, default 16). |
| `warmup_target` | Configured standby target (`DSMR_WORKER_POOL_WARMUP`, default 1). |
| `workers` | Per-worker array of `id`, truncated `session`, `tcp_port`, `pid`, and `state`. The Slynk port is deliberately omitted so the health view cannot be used to bypass MCP policy. |

`pool-status` is only meaningful in hermetic mode. Called when `*mode*`
is **not** `:hermetic`, it returns an informative `isError` ("pool-status
is only available in hermetic mode") rather than empty or misleading
data — so seeing that error is itself a signal that the server is running
attached, not hermetic.

### Attached-mode health

There is no dedicated attached-mode health verb today. This is a known
gap, recorded here so the release plan or a follow-on can decide whether
to add one; do not add code to close it as part of this runbook.

The practical equivalent is a trivial `repl-eval` round-trip: evaluate a
constant and confirm the value comes back.

```
repl-eval  code: "42"
```

A successful response (the value `42`, no `isError`) confirms the Slynk
connection to the attached image is live end-to-end. A structured
`isError` with a `NETWORK_ERROR`-class message means the listener is
unreachable or the connection dropped — see "Attached-mode degradation"
below. Because the connection is opened eagerly at session
