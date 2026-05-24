;;;; src/main.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Root package and public API surface for dsmr-mcp. Exports are
;;;; collected here; implementation lives in per-module packages.

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
           ;; Re-exported entry points wired here so callers use the top-level
           ;; dsmr-mcp package without knowing the internal module layout.
           #:run
           #:process-json-line
           #:make-session
           #:*current-session-id*))

(in-package #:dsmr-mcp/src/main)

(defparameter +version+ "0.1.0"
  "Current dsmr-mcp version string.")

(defparameter *default-mode* :attached
  "Either :ATTACHED (route REPL verbs to a user-supplied Slynk listener,
the documented default) or :HERMETIC (fork a child SBCL worker per
session, used as a fallback when the live image is unavailable or for
parallel workers that intentionally want isolation from the host
image).")

(defun version ()
  "Return the dsmr-mcp version string."
  +version+)
