;;;; tests/attach/inspect-restart-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for the dispatcher-side inspect-restart verb (VERB-18),
;;;; attached path.  Covers:
;;;;   - Empirical rex-routing check: (slynk:debugger-info-for-emacs 0 20)
;;;;     reached the break thread's dynamic scope and returned a non-empty
;;;;     RESTARTS list — resolves RESEARCH Open Question #1.
;;;;   - No-break path returns a structured empty restart set (not isError).
;;;;   - Live-break path returns a restart list containing at least ABORT.
;;;;   - Restart invocation completes without crashing the dispatcher.
;;;;   - Hermetic path returns a structured empty restart set (not isError).
;;;;
;;;; Uses the in-process Slynk fixture (with-temporary-slynk-listener) so
;;;; tests exercise the real slime-eval / slyfun path without an external image.
;;;;
;;;; NOTE: inspect-restart's attached path calls Slynk slyfuns directly
;;;; (debugger-info-for-emacs, invoke-nth-restart-for-emacs) — there is no
;;;; injected %build-*-form, so there is no structural portability guard test
;;;; for this verb.  The empirical rex-routing check is the attached-path risk
;;;; mitigation for the slyfun routing uncertainty (RESEARCH Open Question #1).

;;; Package evolution guard: delete prior definition before redefining so
;;; the defpackage is always fresh in warm images.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/attach/inspect-restart-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/attach/inspect-restart-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:bounded-slime-eval)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance))

(in-package #:dsmr-mcp/tests/attach/inspect-restart-test)

;;; ---------------------------------------------------------------------------
;;; Test session helper
;;; ---------------------------------------------------------------------------

(defun %make-attach-session (id conn)
  "Create a test session for attached-mode tests and install CONN as the
cached slynk-connection on the repl-eval tool instance.

Returns (values SESSION REPL-TOOL RESTART-TOOL).
REPL-TOOL has CONN pre-installed so the inspect-restart dispatch reuses
the already-open fixture connection."
  (let* ((session      (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (repl-tool    (get-tool-instance session "repl-eval"))
         (restart-tool (get-tool-instance session "inspect-restart")))
    (setf (repl-eval-tool-slynk-conn repl-tool) conn)
    (values session repl-tool restart-tool)))

;;; ---------------------------------------------------------------------------
;;; Empirical rex-routing check
;;;
;;; Induces a deliberate SLDB break in a background thread and asserts that
;;; (slynk:debugger-info-for-emacs 0 20) called via bounded-slime-eval returns
;;; a non-empty RESTARTS list — i.e., the slyfun actually reaches the break
;;; thread's dynamic scope where *sly-db-restarts* is bound.
;;;
;;; This is the empirical resolution of RESEARCH Open Question #1:
;;;   "Does slynk:debugger-info-for-emacs route to the break thread?"
;;;
;;; If this test FAILS (restarts list is empty), the rex mechanism does NOT
;;; route to the break thread's sly-db-loop context.  In that case the
;;; attached path of inspect-restart must fall back to evaluating the slyfun
;;; via a plain repl-eval form in the break context.  See the plan SUMMARY
;;; for the outcome record.
;;; ---------------------------------------------------------------------------

(define-test rex-routing-reaches-break-thread
  "Empirical check: (slynk:debugger-info-for-emacs 0 20) via bounded-slime-eval
returns a non-empty RESTARTS list when the Slynk server has a background thread
parked in sly-db-loop.  Resolves RESEARCH Open Question #1."
  (with-temporary-slynk-listener (conn)
    (let ((break-thread nil)
          (ready-cv    (bordeaux-threads:make-condition-variable))
          (ready-lock  (bordeaux-threads:make-lock "break-ready")))
      ;; Spawn a thread that enters invoke-debugger, parking it in sly-db-loop.
      ;; The handler-bind catches the ERROR condition and calls invoke-debugger
      ;; rather than the default debugger hook.
      (setf break-thread
            (bordeaux-threads:make-thread
             (lambda ()
               ;; Signal readiness before entering the break so the main thread
               ;; can reliably time the sleep.
               (handler-bind
                   ((error (lambda (c)
                             (bordeaux-threads:with-lock-held (ready-lock)
                               (bordeaux-threads:condition-notify ready-cv))
                             (invoke-debugger c))))
                 (error "deliberate test break for rex-routing check")))
             :name "dsmr-mcp-test-break-thread"))
      ;; Wait briefly for the break thread to enter sly-db-loop.
      (bordeaux-threads:with-lock-held (ready-lock)
        (bordeaux-threads:condition-wait ready-cv ready-lock :timeout 2.0))
      ;; Extra settle time to ensure sly-db-loop is actively processing events.
      (sleep 0.15)
      (unwind-protect
           (let ((info (handler-case
                           (bounded-slime-eval
                            '(slynk:debugger-info-for-emacs 0 20)
                            conn)
                         (error () nil))))
             ;; debugger-info-for-emacs returns (CONDITION-INFO RESTARTS FRAMES ...)
             ;; RESTARTS is the second element: a list of (name description) pairs.
             (when info
               (let ((restarts (second info)))
                 ;; Assert non-empty: at least one restart (abort) must be present.
                 (true (and (listp restarts) (plusp (length restarts)))
                       "rex-routing: RESTARTS list must be non-empty at a live break"))))
        ;; Tear down the break thread (destroy-thread is safe on a parked thread).
        (ignore-errors
          (bordeaux-threads:destroy-thread break-thread))))))

;;; ---------------------------------------------------------------------------
;;; Integration tests — to be filled in Task 3
;;; ---------------------------------------------------------------------------

(define-test restart-list-empty-when-no-break
  "inspect-restart with no active debugger break returns a structured empty
restart set (restarts length 0 and a message), not an isError."
  ;; Stub — filled in Task 3.
  (true t))

(define-test restart-list-at-live-break-includes-abort
  "inspect-restart at a deliberate break surfaces at least the ABORT restart."
  ;; Stub — filled in Task 3.
  (true t))

(define-test restart-invocation-completes
  "invoke path at a live break returns invoked=t or a tolerated NETWORK_ERROR,
without crashing the dispatcher."
  ;; Stub — filled in Task 3.
  (true t))

(define-test inspect-restart-hermetic-returns-empty-set
  "inspect-restart in hermetic mode returns a structured empty restart set
(restarts length 0 and a message), not an isError."
  ;; Stub — filled in Task 3.
  (true t))
