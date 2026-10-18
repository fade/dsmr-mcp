;;;; dsmr-bus-watch.asd
;;;;
;;;; The SBCL program behind the bus watcher command: it watches the
;;;; coordination-bus WAL and signals a new foreign message so a dormant sister
;;;; agent can be re-armed or woken without an operator nudge.
;;;;
;;;; Produces bin/dsmr-bus-watch-lisp via (asdf:make :dsmr-bus-watch) / `make
;;;; bus-watch`. The installed `dsmr-bus-watch` is a small static C front end
;;;; (src/bus/wake/dsmr-bus-watch.c): it runs `--wake` and `--wake --hook`
;;;; itself against the host bus service and hands every other mode, argv
;;;; unchanged, to dsmr-bus-watch-lisp in its own directory. Both are
;;;; self-contained executables, so a sister repo's machine needs no Python or
;;;; SBCL of its own to arm a watcher.
;;;;
;;;; This lives in its own .asd (rather than alongside dsmr-mcp.asd) so its
;;;; primary system name matches the file and its lean dependency closure stays
;;;; minimal. It depends on ZeroMQ-free bus leaves only: the WAL, the message
;;;; envelope, the delivery cursor, the bus-root selector and the heartbeat,
;;;; plus the shared host-file leaf that names the files the watcher, the MCP
;;;; server and the host service all use, and its own entrypoint. Never the
;;;; broker, never ZeroMQ, never the MCP server. A sister repo needs no libzmq to
;;;; arm a watcher, and the binary stays small.
;;;;
;;;; Build-operation note: the string form "program-op" is the CL Cookbook
;;;; recommended style for ASDF >= 3.1; if it fails with "operation not found"
;;;; on an older ASDF, replace with the symbol form 'asdf:program-op.

(asdf:defsystem "dsmr-bus-watch"
  :class :package-inferred-system
  :description "Coordination-bus wakeup watcher binary for autonomous cross-agent coordination."
  :author "Brian O'Reilly <fade@deepsky.com>"
  :license "AGPL-3.0-or-later"
  :version "0.1.0"
  :depends-on ("dsmr-mcp/src/bus/wal"
               "dsmr-mcp/src/bus/envelope"
               "dsmr-mcp/src/bus/cursor"
               "dsmr-mcp/src/bus/selector"
               "dsmr-mcp/src/bus/heartbeat"
               "dsmr-mcp/src/bus/hostfiles"
               "dsmr-bus-watch/src/bus/watch")
  :build-operation "program-op"
  :build-pathname "bin/dsmr-bus-watch-lisp"
  :entry-point "dsmr-bus-watch/src/bus/watch:main")
