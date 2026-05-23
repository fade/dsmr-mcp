;;;; tests/run-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for dsmr-mcp:run transport stubs and keyword/env precedence.
;;;; Asserts via the non-blocking resolve-transport seam so tests never
;;;; enter the blocking :stdio loop (D-17).

(defpackage #:dsmr-mcp/tests/run-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/run
                #:run
                #:resolve-transport
                #:transport-not-implemented-error))

(in-package #:dsmr-mcp/tests/run-test)

;;; ---------------------------------------------------------------------------
;;; Transport stub tests (D-17)
;;; ---------------------------------------------------------------------------

(define-test tcp-stub-signals-transport-not-implemented
  "D-17: run :transport :tcp signals transport-not-implemented-error in Phase 1."
  (fail (run :transport :tcp) transport-not-implemented-error))

(define-test http-stub-signals-transport-not-implemented
  "D-17: run :transport :http signals transport-not-implemented-error in Phase 1."
  (fail (run :transport :http) transport-not-implemented-error))

;;; ---------------------------------------------------------------------------
;;; Keyword/env precedence (D-15)
;;; ---------------------------------------------------------------------------

(define-test keyword-beats-env-for-transport
  "D-15: an explicit :transport keyword overrides DSMR_TRANSPORT env var.
Uses resolve-transport to avoid entering the blocking :stdio loop."
  (let ((old-val (uiop:getenv "DSMR_TRANSPORT")))
    (unwind-protect
         (progn
           ;; Set env to "tcp" — keyword :stdio should still win.
           (setf (uiop:getenv "DSMR_TRANSPORT") "tcp")
           (is eq :stdio (resolve-transport :transport :stdio)))
      ;; Restore original env value.
      (if old-val
          (setf (uiop:getenv "DSMR_TRANSPORT") old-val)
          (setf (uiop:getenv "DSMR_TRANSPORT") "")))))

(define-test env-beats-default-for-transport
  "D-15: DSMR_TRANSPORT env var overrides the :stdio built-in default
when no keyword is passed.  Uses resolve-transport (non-blocking seam)."
  (let ((old-val (uiop:getenv "DSMR_TRANSPORT")))
    (unwind-protect
         (progn
           ;; Set env to "tcp" — no keyword passed, so env should win.
           (setf (uiop:getenv "DSMR_TRANSPORT") "tcp")
           (is eq :tcp (resolve-transport)))
      ;; Restore original env value.
      (if old-val
          (setf (uiop:getenv "DSMR_TRANSPORT") old-val)
          (setf (uiop:getenv "DSMR_TRANSPORT") "")))))
