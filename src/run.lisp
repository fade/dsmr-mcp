;;;; src/run.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Stub package exporting #:run so src/main.lisp's :import-from resolves
;;;; at load time. Plan 03 fills in the real function body here.

(defpackage #:dsmr-mcp/src/run
  (:use #:cl)
  (:export #:run
           #:process-json-line))

(in-package #:dsmr-mcp/src/run)

;; Stub — Plan 03 replaces this with the full implementation.
;; Declared here so dsmr-mcp/src/main can re-export the symbol and
;; callers can (fboundp 'dsmr-mcp:run) without errors.
(defun run (&rest args &key transport slynk-attach mode port bind log-level project-root &allow-other-keys)
  "Entry point for the dsmr-mcp MCP server. Stub — Plan 03 implements.
See CONTEXT.md D-14, D-15, D-16, D-17 for the full keyword surface."
  (declare (ignore args transport slynk-attach mode port bind log-level project-root))
  (error "dsmr-mcp:run is not yet implemented (Plan 03 delivers the body)."))

(defun process-json-line (line session)
  "Parse and dispatch one JSON-RPC line. Stub — Plan 02 implements."
  (declare (ignore line session))
  (error "process-json-line is not yet implemented (Plan 02 delivers the body)."))
