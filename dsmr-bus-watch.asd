;;;; dsmr-bus-watch.asd
;;;;
;;;; Cross-agent bus wakeup watcher: a standalone binary that watches the
;;;; coordination-bus WAL and signals a new foreign message so a dormant sister
;;;; agent can be re-armed/woken without an operator nudge.
;;;;
;;;; Produces bin/dsmr-bus-watch via (asdf:make :dsmr-bus-watch) / `make bus-watch`.
;;;; It is a Lisp-only executable so a sister repo's machine needs no Python or
;;;; SBCL of its own to arm the watcher.
;;;;
;;;; This lives in its own .asd (rather than alongside dsmr-mcp.asd) so its
;;;; primary system name matches the file and its lean dependency closure stays
;;;; minimal: it depends ONLY on the bus WAL leaf (which is ZeroMQ-free) plus its
;;;; own entrypoint — never on broker/zmq/the MCP server — so the binary is small.
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
               "dsmr-bus-watch/src/bus/watch")
  :build-operation "program-op"
  :build-pathname "bin/dsmr-bus-watch"
  :entry-point "dsmr-bus-watch/src/bus/watch:main")
