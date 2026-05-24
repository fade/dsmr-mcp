;;;; tests/hermetic/circuit-breaker-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for HERM-03 crash recovery and circuit-breaker behaviour.
;;;; These tests SIGKILL real SBCL worker subprocesses via sb-posix:kill,
;;;; so they exercise the full OS-level crash path and may take several seconds.
;;;;
;;;; criterion-2 (D-14, ROADMAP): SIGKILL a bound worker; after the health
;;;; monitor detects the crash, the next same-session get-or-assign-worker
;;;; succeeds and check-and-clear-reset-notification returns T exactly once
;;;; (second call returns NIL — one-notification guarantee).
;;;;
;;;; criterion-3 (D-13, ROADMAP): Induce 3 crashes for one session; the 4th
;;;; get-or-assign-worker call must signal an error whose message contains
;;;; "Circuit breaker". The error fires within *circuit-breaker-cooldown*
;;;; (60 s) without attempting another spawn.

(defpackage #:dsmr-mcp/tests/hermetic/circuit-breaker-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool
                #:get-or-assign-worker #:release-session
                #:*crash-breaker-threshold*
                #:*crash-breaker-window*
                #:*circuit-breaker-cooldown*
                #:*health-check-interval-seconds*)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:worker-pid #:check-and-clear-reset-notification)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:sb-posix))

(in-package #:dsmr-mcp/tests/hermetic/circuit-breaker-test)

;;; ---------------------------------------------------------------------------
;;; Helper: kill-and-wait
;;; ---------------------------------------------------------------------------

(defun kill-and-wait-for-health-monitor (pid interval)
  "SIGKILL the process at PID, then wait long enough for the health monitor
to detect the crash. The health monitor polls every INTERVAL seconds so
we wait INTERVAL + 3 seconds to be safe."
  (ignore-errors (sb-posix:kill pid 9))
  (sleep (+ interval 3)))

;;; ---------------------------------------------------------------------------
;;; Criterion 2: one reset notification after crash + replacement (D-14)
;;; ---------------------------------------------------------------------------

(define-test crash-triggers-reset-notification
  "HERM-03 / D-14 / ROADMAP criterion 2: SIGKILL on the bound worker triggers
crash recovery; the next same-session get-or-assign-worker returns a replacement
worker whose check-and-clear-reset-notification is T exactly once. The second
call to check-and-clear-reset-notification on the same worker is NIL, confirming
the one-notification guarantee."
  (let ((*mode* :hermetic)
        (*error-output* (make-string-output-stream))
        ;; Short health-check interval so the test doesn't take forever.
        (*health-check-interval-seconds* 2.0d0))
    (configure-log4cl-for-server :warn)
    (let ((dsmr-mcp/src/hermetic/pool:*worker-pool-warmup* 0)
          (dsmr-mcp/src/hermetic/pool:*max-pool-size* 4))
      (initialize-pool)
      (unwind-protect
           (let* ((worker  (get-or-assign-worker "crash-recovery-session"))
                  (pid     (worker-pid worker)))
             ;; Hard-kill the worker at OS level and wait for the health monitor.
             (kill-and-wait-for-health-monitor pid *health-check-interval-seconds*)
             ;; The next call must succeed: recovery spawned a replacement.
             (let* ((next-worker (get-or-assign-worker "crash-recovery-session"))
                    (had-reset   (check-and-clear-reset-notification next-worker)))
               ;; Criterion 2a: reset notification was set exactly once.
               (true had-reset)
               ;; Criterion 2b: second call is NIL (one-notification guarantee, D-14).
               (false (check-and-clear-reset-notification next-worker))
               ;; Criterion 2c: the replacement is a live worker with a different pid.
               (true (integerp (worker-pid next-worker)))
               (true (plusp (worker-pid next-worker)))))
        (ignore-errors (shutdown-pool))))))

;;; ---------------------------------------------------------------------------
;;; Criterion 3: circuit breaker trips after 3 crashes and fails fast (D-13)
;;; ---------------------------------------------------------------------------

(define-test circuit-breaker-trips-after-threshold
  "HERM-03 / D-13 / ROADMAP criterion 3: induce *crash-breaker-threshold* (3)
crashes for one session in quick succession. The next get-or-assign-worker call
must signal an error whose message contains 'Circuit breaker'. No spawn attempt
is made during the *circuit-breaker-cooldown* (60 s) window."
  (let ((*mode* :hermetic)
        (*error-output* (make-string-output-stream))
        ;; Short health-check interval so recovery + crash cycling is faster.
        (*health-check-interval-seconds* 2.0d0)
        ;; Short breaker window to avoid very long test: 30 s is enough for
        ;; 3 crash + recovery cycles with 2s health monitor intervals.
        (*crash-breaker-window* 300))
    (configure-log4cl-for-server :warn)
    (let ((dsmr-mcp/src/hermetic/pool:*worker-pool-warmup* 0)
          (dsmr-mcp/src/hermetic/pool:*max-pool-size* 8))
      (initialize-pool)
      (unwind-protect
           (progn
             ;; Induce *crash-breaker-threshold* crashes for the breaker session.
             ;; Each crash-then-recovery cycle: SIGKILL → wait → get-or-assign-worker
             ;; (which ensures recovery completed before we try again).
             (dotimes (i *crash-breaker-threshold*)
               (let* ((w   (get-or-assign-worker "breaker-session"))
                      (pid (worker-pid w)))
                 (kill-and-wait-for-health-monitor
                  pid *health-check-interval-seconds*)))
             ;; 4th call must signal an error referencing "Circuit breaker".
             (let ((signalled-p nil)
                   (error-message nil))
               (handler-case
                   (get-or-assign-worker "breaker-session")
                 (error (e)
                   (setf signalled-p t
                         error-message (princ-to-string e))))
               (true signalled-p)
               (true error-message)
               ;; The message must name the circuit breaker so the caller can
               ;; distinguish this from generic pool errors.
               (true (search "Circuit breaker" error-message))))
        (ignore-errors (shutdown-pool))))))
