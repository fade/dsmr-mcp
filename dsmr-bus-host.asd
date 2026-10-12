;;;; dsmr-bus-host.asd
;;;;
;;;; The host bus service: one process per host that runs every bus broker on
;;;; the host and keeps one watcher for every agent registered with it, in place
;;;; of a broker elected by whichever client came first and a detached watcher
;;;; process per agent.
;;;;
;;;; It is a third deploy artifact, an executable built by
;;;; (asdf:make :dsmr-bus-host), beside the MCP server's image and the watcher
;;;; binary. It lives in its own .asd so its primary system name matches the
;;;; file and its dependency closure is its own. Unlike the watcher, which must
;;;; arm on a machine with no libzmq, the service runs brokers, so it may reach
;;;; the broker and ZeroMQ. It shares the host-file leaf with the watcher and the
;;;; MCP server, so all three name the same file for the same agent.
;;;;
;;;; Build-operation note: the string form "program-op" is the CL Cookbook
;;;; recommended style for ASDF >= 3.1; if it fails with "operation not found"
;;;; on an older ASDF, replace with the symbol form 'asdf:program-op.

(asdf:defsystem "dsmr-bus-host"
  :class :package-inferred-system
  :description "Host bus service: every bus broker and every registered agent's watcher in one supervised process."
  :author "Brian O'Reilly <fade@deepsky.com>"
  :license "AGPL-3.0-or-later"
  :version "0.1.0"
  :depends-on ("dsmr-mcp/src/bus/hostfiles"
               "dsmr-bus-host/src/bus/host/conditions"
               "dsmr-bus-host/src/bus/host/fleetlog"
               "dsmr-bus-host/src/bus/host/identity"
               "dsmr-bus-host/src/bus/host/registry")
  :build-operation "program-op"
  :build-pathname "bin/dsmr-bus-host"
  :entry-point "dsmr-bus-host/src/bus/host/main:main")
