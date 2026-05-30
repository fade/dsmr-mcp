;;;; dsmr-mcp-bridge.asd
;;;;
;;;; Bridge binary: standalone stdio<->TCP proxy for stdio-only MCP clients.
;;;;
;;;; Produces bin/dsmr-mcp-bridge via (asdf:make :dsmr-mcp-bridge).
;;;; The bridge is a Lisp-only executable so the client machine needs no
;;;; Python runtime.  Per-platform CI artefacts are a later concern;
;;;; today the operator builds locally with `make bridge`.
;;;;
;;;; This lives in its own .asd (rather than alongside dsmr-mcp.asd) so its
;;;; primary system name matches the file, and so its lean dependency closure
;;;; (usocket + bordeaux-threads only) never has to coexist with the full
;;;; server's secondary systems in one definition file.
;;;;
;;;; Build-operation note: the string form "program-op" is the CL Cookbook
;;;; recommended style for ASDF >= 3.1; if it fails with "operation not found"
;;;; on an older ASDF, replace with the symbol form 'asdf:program-op.

(asdf:defsystem "dsmr-mcp-bridge"
  :class :package-inferred-system
  :description "stdio<->TCP bridge binary for MCP clients that only speak stdio."
  :author "Brian O'Reilly <fade@deepsky.com>"
  :license "AGPL-3.0-or-later"
  :version "0.1.0"
  :depends-on ("usocket"
               "bordeaux-threads"
               "dsmr-mcp-bridge/scripts/stdio-tcp-bridge")
  :build-operation "program-op"
  :build-pathname "bin/dsmr-mcp-bridge"
  :entry-point "dsmr-mcp-bridge/scripts/stdio-tcp-bridge:main")
