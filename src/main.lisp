;;;; src/main.lisp
;;;;
;;;; Placeholder root package for dsmr-mcp. The real implementation lands
;;;; phase-by-phase per .planning/ROADMAP.md; this file exists so the
;;;; system can load and tests can run from day zero.

(defpackage #:dsmr-mcp/src/main
  (:nicknames #:dsmr-mcp #:dsmr)
  ;; NOTE: deliberately NOT claiming the unqualified `mcp' nickname.
  ;; cl-mcp does, and the two should be loadable in the same image
  ;; for users still running both. See .planning/PROJECT.md
  ;; "cl-mcp coexistence" decision row.
  (:use #:cl)
  (:export #:version
           #:*default-mode*))

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
