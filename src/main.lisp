;;;; src/main.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Root package and public API surface for dsmr-mcp. Exports are
;;;; collected here phase-by-phase; implementation lives in per-module
;;;; packages. This plan (01-01) owns the run re-export: it imports
;;;; #:run from dsmr-mcp/src/run and unconditionally re-exports it so
;;;; Plans 02 and 03 do NOT touch this file's wiring.

(defpackage #:dsmr-mcp/src/main
  (:nicknames #:dsmr-mcp #:dsmr)
  ;; NOTE: deliberately NOT claiming the unqualified `mcp' nickname.
  ;; cl-mcp reserves it and the two must be loadable in the same image
  ;; during the migration window. See .planning/PROJECT.md
  ;; "cl-mcp coexistence" decision row.
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/run
                #:run
                #:process-json-line)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*)
  (:export #:version
           #:*default-mode*
           ;; Plan 01-01 re-exports — owned by this file, unconditionally.
           ;; Plan 03 supplies the run body in dsmr-mcp/src/run; this
           ;; import resolves at load time because src/run.lisp (stub) is
           ;; present. Do NOT move or conditionalize this wiring.
           #:run
           #:process-json-line
           #:make-session
           #:*current-session-id*))

(in-package #:dsmr-mcp/src/main)

(defparameter +version+ "0.1.0"
  "Current dsmr-mcp version. Bumped per ROADMAP.md milestone closure.")

(defparameter *default-mode* :attached
  "Either :ATTACHED (route REPL verbs to a user-supplied Slynk listener,
the documented default) or :HERMETIC (fork a child SBCL worker per
session, used as a fallback when the live image is unavailable or for
parallel workers that intentionally want isolation from the host
image).")

(defun version ()
  "Return the dsmr-mcp version string."
  +version+)
