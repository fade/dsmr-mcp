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
