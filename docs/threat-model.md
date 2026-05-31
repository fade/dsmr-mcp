# dsmr-mcp Threat Model

This document states the trust posture of `dsmr-mcp` honestly enough that a
reviewer can decide whether to adopt it without reading the source. It
distinguishes the controls that are actually enforced from the postures that
are operator decisions.

## Posture

`dsmr-mcp` is a **trusted, localhost-only developer tool.** It connects an AI
agent to a live Common Lisp development image and to the local filesystem so
the agent can evaluate code, inspect running state, edit source, and run
tests inside the environment the developer is already working in.

The foundational assumption is that **the operator already trusts the agent**
to evaluate arbitrary code in their image. That trust is the whole point: the
agent is meant to work *inside* the developer's running world, not in a
forked sandbox that has to learn the world from scratch. Arbitrary code
evaluation in the attached image is therefore a feature, not a vulnerability.

Consequently, **`dsmr-mcp` is not a security sandbox against a malicious
agent.** It does not — and is not designed to — contain an agent that is
actively hostile to the operator. There is no privilege boundary between the
agent and the operator's image, because an agent that can call `repl-eval`
can already do anything the image can do. The one place where `dsmr-mcp`
*does* enforce an agent-facing boundary is the filesystem (see the project
root sandbox below), and even that is a guardrail against accidental reach,
not a containment layer against a determined adversary who also has eval.

By default the server binds only the loopback interface. Exposing it on a
non-loopback address — over the TCP or Streamable-HTTP transports, by setting
`DSMR_ALLOW_REMOTE` — is an **explicit operator decision**, not a supported
posture. It turns an unauthenticated arbitrary-eval endpoint into something
reachable from the network, with no built-in authentication or TLS.
Authenticated remote dispatch is a v2 concern (requirement `REM-01`,
"Remote dispatch (non-localhost) with TLS + auth"), not a v1 control.

## Trust boundaries

| Boundary | Default posture | Enforced control | Notes |
|----------|-----------------|------------------|-------|
| Client → dispatcher (stdio) | In-process / same-host pipe | None (trust is implicit) | The stdio transport is a local pipe between the MCP client and the dispatcher; whoever can write the pipe is already on the host. No network surface. |
| Client → dispatcher (TCP) | Bind `127.0.0.1` (loopback) | Loopback-only bind by default (`src/transport/tcp.lisp`, TRANS-04) | `DSMR_ALLOW_REMOTE=1` binds `0.0.0.0`; `DSMR_HOST` overrides the address explicitly. No auth on the connection — see the STRIDE register. |
| Client → dispatcher (Streamable HTTP) | Bind `127.0.0.1`; loopback-only CORS | Loopback-only bind + loopback-only `Origin` policy (`src/transport/http.lisp`, TRANS-04) | Non-loopback origins are rejected unless `DSMR_ALLOW_REMOTE` is set, mirroring the TCP bind decision. |
| Dispatcher → attached Slynk image | Full trust — the operator's OWN image | None (by design) | The attached transport routes eval into the operator's own running Lisp image over `slynk-client` (`src/attach/dispatch.lisp`). This is not a boundary to defend; it is the operator's own process. Arbitrary eval here is the product. |
| Dispatcher → hermetic worker | Crash isolation only | Forked SBCL child process (`src/hermetic/`) | The hermetic worker is a separate SBCL process for **crash isolation and parallelism**, not a privilege boundary. The worker has the same filesystem and eval capability the dispatcher grants it; isolating it protects the dispatcher from a worker *crash*, not from a worker's *actions*. |
| Agent → filesystem | Confined to the session project root | **The one enforced agent-facing control** (`src/project-root.lisp`, SAFETY-01..03) | Per-session project root. Writes are jailed under the root (`ensure-write-path`); reads are allowed under the root plus registered ASDF source directories (`allowed-read-path`). Symlinks are truename-resolved *before* the containment check, so a symlink inside the root that points outside it is rejected. A broad-root deny list blocks `/`, `/home/`, `/tmp/`, etc. Re-rooting outside the configured whitelist requires `human_approved: true` — an autonomous agent cannot self-approve the bypass. |

### What `DSMR_ALLOW_REMOTE` actually does

`DSMR_ALLOW_REMOTE` is the single, documented opt-out that moves the network
bind off loopback. When it is unset (the default), the TCP and HTTP
transports bind `127.0.0.1` and the HTTP CORS policy accepts only loopback
origins. When it is set, the transports bind `0.0.0.0` and non-loopback HTTP
origins are accepted. The flag adds **no authentication and no transport
encryption** — it only removes the loopback restriction. Enabling it is an
operator's deliberate choice to expose an unauthenticated arbitrary-eval
surface to the network, and it should be paired with an external control
(SSH tunnel, VPN, firewall) until `REM-01` lands first-class auth/TLS in v2.

## STRIDE register

The register is scoped to the whole project. Every row carries a disposition
of exactly **mitigate**, **accept**, or **transfer**. Mitigations name the
specific control (file / verb) rather than generic advice; an `accept` row is
an honest statement that no control exists and none is intended at v1.

| Threat ID | Category | Component | Disposition | Mitigation / Rationale |
|-----------|----------|-----------|-------------|------------------------|
| T-01 | Tampering / Elevation | Arbitrary code evaluation in the attached image (`repl-eval`, `load-system`, the attached dispatch into the operator's own Slynk image, `src/attach/dispatch.lisp`) | accept | By design. The operator already trusts the agent to run code in their image; eval is the product. There is no privilege boundary to enforce here, so none is claimed. |
| T-02 | Tampering / Information disclosure | Filesystem access outside the project root (`fs-read-file`, `fs-write-file`, `fs-list-directory`, `lisp-edit-form`) | mitigate | Per-session project-root sandbox in `src/project-root.lisp`: `ensure-write-path` jails writes under the session root; `allowed-read-path` confines reads to the root plus registered ASDF source dirs; symlinks are truename-resolved before the containment check (a symlink escaping the root is rejected); a broad-root deny list blocks `/`, `/home/`, `/tmp/`, etc. |
| T-03 | Elevation / Policy bypass | Re-rooting the session to an arbitrary directory to widen the write jail (`fs-set-project-root`) | mitigate | Re-rooting outside the configured whitelist (`DSMR_RELATED_PROJECTS`) requires `human_approved: true` (`reroot-permission-required-error`, `src/project-root.lisp`). An autonomous agent cannot self-approve the bypass. |
| T-04 | Spoofing / Information disclosure | Off-loopback exposure of the unauthenticated eval surface (TCP / Streamable-HTTP transports) | accept (with documented opt-out) | Default bind is `127.0.0.1` and HTTP CORS is loopback-only (`src/transport/tcp.lisp`, `src/transport/http.lisp`, TRANS-04). Binding off loopback requires the operator to set `DSMR_ALLOW_REMOTE`; doing so is an explicit, documented decision. No auth/TLS at v1 — deferred to `REM-01`. |
| T-05 | Denial of service | Hermetic worker resource exhaustion / crash loop | mitigate | A circuit breaker in `src/hermetic/pool.lisp` trips after 3 crashes within a 300-second window (60-second cooldown), preventing a crashing worker from being respawned in a tight loop (HERM-03). |
| T-06 | Denial of service | A single hermetic call running unbounded (hung eval, infinite loop) | mitigate | `call-worker` (`src/hermetic/worker-client.lisp`) enforces a per-request timeout (default 30 s) and **hard-kills** the worker with SIGKILL on overrun, recording the kill as a crash against the breaker (SAFETY-05). This control is hermetic-only; the attached image is the operator's own and is not force-killed. |
| T-07 | Information disclosure | Evaluated values, source contents, and error context appearing in logs | accept | Logs are local, structured (`log4cl` on stderr), and operator-owned. Disclosure to the operator's own log sink is acceptable in a localhost, trusted-operator deployment; there is no log-redaction control at v1. |

## For reviewers

Before adopting `dsmr-mcp`, confirm these three things hold in your
environment:

1. **You trust the agent.** The agent can evaluate arbitrary code in the
   attached image. If you would not hand the agent a REPL to your process,
   do not connect it.
2. **The bind stays on loopback** unless you have deliberately fronted it
   with your own authentication and encryption. Check that `DSMR_ALLOW_REMOTE`
   is unset in any environment you do not fully control.
3. **The session project root is set to the project you intend.** The
   filesystem sandbox is the only agent-facing boundary the server enforces;
   verify it is rooted where you expect and that re-rooting requires human
   approval.

In one sentence: **`dsmr-mcp` is a trust-amplifier for an agent the operator
already trusts, not a containment layer for one they do not.**
