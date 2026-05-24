# dsmr-mcp

DeepSky Systems Model Context Protocol server for Common Lisp.

dsmr-mcp gives AI agents a verb surface for writing and debugging
Common Lisp **inside a running development image**. It connects to a
user-supplied [Slynk] listener over [`slynk-client`] and exposes
`repl-eval`, structural editing, code intelligence, thread / restart
/ condition inspection, and an [`alive-lsp`] bridge over JSON-RPC 2.0
on stdio, TCP, or Streamable HTTP.

When the live image is unavailable — or when an agent worker is
intentionally isolated for parallelism — dsmr-mcp falls back to a
forked SBCL worker reachable over a documented file-based ICP wire.
Attached mode is the default; hermetic mode is the fallback.

[Slynk]: https://github.com/joaotavora/sly
[`slynk-client`]: https://gitlab.com/shookakko/slynk-client
[`alive-lsp`]: https://github.com/nobody-famous/alive-lsp

## Status

**Pre-alpha**, under active development. The attached and hermetic
evaluation paths and the core MCP protocol surface are in place; the
broader verb surface is still being built.

## Project Lineage

dsmr-mcp is an independent, AGPL-licensed reimplementation in the
same problem space as [`cl-mcp`](https://github.com/cl-ai-project/cl-mcp).
`cl-mcp` is MIT-licensed and remains a fine choice for projects that
want the hermetic-worker-first posture. dsmr-mcp is for the
attached-image-first workflow and the AGPL toolchain in
`$LISP_WORKSPACE` (`eve-gate`, `eve-quant`, `charmed`,
`charmed-mcclim`, `ubiquitous`, `slynk-client`).

`.planning/FEATURES.md` catalogues which cl-mcp capabilities dsmr-mcp
preserves, re-architects, drops, or adds — and why.

## License

AGPL-3.0-or-later. See `LICENSE`.
