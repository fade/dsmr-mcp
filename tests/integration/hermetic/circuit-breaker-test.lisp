;;;; tests/integration/hermetic/circuit-breaker-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for crash recovery and circuit-breaker behaviour.
;;;; These tests SIGKILL real SBCL worker subprocesses via sb-posix:kill,
;;;; so they exercise the full OS-level crash path and may take several seconds.
;;;;
;;;; crash-triggers-reset-notification: SIGKILL a bound worker; after the health
;;;; monitor detects the crash, the next same-session get-or-assign-worker
;;;; succeeds and check-and-clear-reset-notification returns T exactly once
;;;; (second call returns NIL, the one-notification guarantee).
;;;;
;;;; circuit-breaker-trips-after-threshold: induce 3 crashes for one session;
;;;; the 4th get-or-assign-worker call must signal an error whose message
;;;; contains "Circuit breaker". The error fires within *circuit-breaker-cooldown*
;;;; (60 s) without attempting another spawn. The same trip is then read back
;;;; through the dispatch boundary, where it must arrive under the fixed name
;;;; circuit_open and carry the seconds left to wait, with an untripped session
;;;; as the control that the name is not simply always present.
;;;;
;;;; a-crashed-worker-reaches-the-caller-under-its-own-name: kill a bound worker
;;;; with the health check pushed out of the way, so a call lands on a worker
;;;; that has died between two ticks, and read the response. It must arrive
;;;; named backend_crashed, distinct from the breaker's name, with the identical
;;;; call on a live worker as the control.

(defpackage #:dsmr-mcp/tests/integration/hermetic/circuit-breaker-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool
                #:get-or-assign-worker #:release-session
                #:*crash-breaker-threshold*
                #:*crash-breaker-window*
                #:*circuit-breaker-cooldown*
                #:*health-check-interval-seconds*)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:worker-pid #:worker-state #:worker-process-info
                #:check-and-clear-reset-notification)
  (:import-from #:dsmr-mcp/src/hermetic/dispatch
                #:dispatch-hermetic-call)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/state
                #:*mode* #:*current-session-id* #:make-session)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-worker-child-or-skip)
  (:import-from #:sb-posix))

(in-package #:dsmr-mcp/tests/integration/hermetic/circuit-breaker-test)

;;; ---------------------------------------------------------------------------
;;; These tests fork (and SIGKILL) real SBCL worker subprocesses, so they skip
;;; cleanly — and only when the environment genuinely cannot build a worker
;;; child — via WITH-WORKER-CHILD-OR-SKIP (see tests/integration/support.lisp).
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; Helper: kill-and-wait
;;; ---------------------------------------------------------------------------

(defun kill-and-wait-for-health-monitor (worker interval)
  "SIGKILL WORKER's OS process, then poll until the health monitor has OBSERVED
the death and marked WORKER :crashed — not merely until the OS reaps the pid.
The monitor only checks liveness every INTERVAL seconds and then recovers
asynchronously, so returning at OS-reap (which is near-instant) would let the
following get-or-assign-worker race an as-yet-undetected crash and reuse the
dead worker; waiting for the :crashed transition is what makes recovery
deterministic. Bounds the wait at a deadline of INTERVAL*8 seconds so a monitor
that never fires fails fast rather than hanging."
  (ignore-errors (sb-posix:kill (worker-pid worker) 9))
  (loop repeat (ceiling (* interval 8) 0.1)
        until (eq (worker-state worker) :crashed)
        do (sleep 0.1)))

(defun dispatch-payload (session-id)
  "Run one hermetic dispatch for SESSION-ID and return the payload a caller sees.

Reads the response rather than the condition. A failure the pool signals is only
half the story: what matters is whether the caller is told which failure it was,
in a form it can branch on, and only the response carries that."
  (let ((*current-session-id* session-id))
    (gethash "result"
             (dispatch-hermetic-call (make-session :id session-id)
                                     1 "repl-eval"
                                     (make-ht "code" "(+ 1 1)")))))

(defun payload-message (payload)
  "The text of PAYLOAD's first content entry, or NIL when it has none."
  (let ((content (and (hash-table-p payload) (gethash "content" payload))))
    (when (and content (plusp (length content)))
      (gethash "text" (aref content 0)))))

;;; ---------------------------------------------------------------------------
;;; One reset notification after crash + replacement
;;; ---------------------------------------------------------------------------

(define-test crash-triggers-reset-notification
  "SIGKILL on the bound worker triggers crash recovery; the next same-session
get-or-assign-worker returns a replacement worker whose
check-and-clear-reset-notification is T exactly once. The second call returns
NIL, confirming the one-notification guarantee."
  (with-worker-child-or-skip
    (let ((*mode* :hermetic)
          (*error-output* (make-string-output-stream))
          ;; Short health-check interval so the test doesn't take forever.
          (*health-check-interval-seconds* 2.0d0))
      (configure-log4cl-for-server :warn)
      (let ((dsmr-mcp/src/hermetic/pool:*worker-pool-warmup* 0)
            (dsmr-mcp/src/hermetic/pool:*max-pool-size* 4))
        (initialize-pool)
        (unwind-protect
             (let ((worker (get-or-assign-worker "crash-recovery-session")))
               ;; Hard-kill the worker at OS level and wait for the health monitor.
               (kill-and-wait-for-health-monitor worker *health-check-interval-seconds*)
               ;; The next call must succeed: recovery spawned a replacement.
               (let* ((next-worker (get-or-assign-worker "crash-recovery-session"))
                      (had-reset   (check-and-clear-reset-notification next-worker)))
                 ;; Reset notification was set exactly once.
                 (true had-reset)
                 ;; Second call returns NIL — one-notification guarantee.
                 (false (check-and-clear-reset-notification next-worker))
                 ;; The replacement is a live worker with a different pid.
                 (true (integerp (worker-pid next-worker)))
                 (true (plusp (worker-pid next-worker)))))
          (ignore-errors (shutdown-pool)))))))

;;; ---------------------------------------------------------------------------
;;; Circuit breaker trips after threshold crashes
;;; ---------------------------------------------------------------------------

(define-test circuit-breaker-trips-after-threshold
  "Inducing *crash-breaker-threshold* (3) crashes for one session in quick
succession causes the next get-or-assign-worker call to signal an error whose
message contains 'Circuit breaker'. No spawn attempt is made during the
*circuit-breaker-cooldown* (60 s) window."
  (with-worker-child-or-skip
    (let ((*mode* :hermetic)
          (*error-output* (make-string-output-stream))
          ;; Short health-check interval so recovery + crash cycling is faster.
          (*health-check-interval-seconds* 2.0d0)
          ;; Keep the production-default 300 s breaker window: the three crash +
          ;; recovery cycles complete well inside it, so all three crashes fall in
          ;; one window and the breaker trips. A shorter window risks the early
          ;; crashes ageing out before the threshold is reached, which would make
          ;; the breaker never trip and flake the test.
          (*crash-breaker-window* 300))
      (configure-log4cl-for-server :warn)
      (let ((dsmr-mcp/src/hermetic/pool:*worker-pool-warmup* 0)
            (dsmr-mcp/src/hermetic/pool:*max-pool-size* 8))
        (initialize-pool)
        (unwind-protect
             (progn
               ;; Control, before anything has tripped: the same call on a
               ;; healthy session must not come back named as a breaker trip.
               ;; Without it the assertion below cannot tell "the name fires on
               ;; a trip" from "the name fires always".
               (let ((payload (dispatch-payload "untripped-session")))
                 (isnt equal "circuit_open" (gethash "error_type" payload)
                       "an untripped session's call is not reported as a trip"))
               ;; Induce *crash-breaker-threshold* crashes for the breaker session.
               ;; Each crash-then-recovery cycle: SIGKILL → wait → get-or-assign-worker
               ;; (which ensures recovery completed before we try again).
               (dotimes (i *crash-breaker-threshold*)
                 (let ((w (get-or-assign-worker "breaker-session")))
                   (kill-and-wait-for-health-monitor
                    w *health-check-interval-seconds*)))
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
                 (true (search "Circuit breaker" error-message)))
               ;; The trip has to reach a caller under a fixed name, not only as
               ;; a sentence, and it has to carry the wait: a caller that cannot
               ;; branch on the name and cannot see how long to wait is being
               ;; told nothing it can act on.
               (let* ((payload (dispatch-payload "breaker-session"))
                      (message (payload-message payload)))
                 (true (gethash "isError" payload))
                 (is equal "circuit_open" (gethash "error_type" payload))
                 (true message)
                 (true (search "Circuit breaker" message))
                 (let* ((marker (search "Retry in " message))
                        (seconds (and marker
                                      (parse-integer message
                                                     :start (+ marker 9)
                                                     :junk-allowed t))))
                   (true (integerp seconds)
                         "the message names the seconds left in the cooldown")
                   (true (and (integerp seconds)
                              (plusp seconds)
                              (<= seconds *circuit-breaker-cooldown*))
                         "and they fall inside the cooldown window"))))
          (ignore-errors (shutdown-pool)))))))

(define-test a-crashed-worker-reaches-the-caller-under-its-own-name
  "A call landing on a worker that has just died comes back named a backend crash.

The two hermetic failures a caller can act on are named separately on purpose:
a tripped breaker says wait and says how long, a crashed backend says the worker
died and the call may simply be retried. One standing in for both would leave a
caller unable to tell a wait from a retry, so each is demonstrated on the fault
that actually produces it rather than one covering for the other.

The health check is pushed out beyond the run so the crash is still undetected
when the call goes in, which is the state a caller genuinely hits: the worker
died between two ticks. The control is the identical call on the same session
while the worker is alive."
  (with-worker-child-or-skip
    (let ((*mode* :hermetic)
          (*error-output* (make-string-output-stream))
          (*health-check-interval-seconds* 3600.0d0))
      (configure-log4cl-for-server :warn)
      (let ((dsmr-mcp/src/hermetic/pool:*worker-pool-warmup* 0)
            (dsmr-mcp/src/hermetic/pool:*max-pool-size* 4))
        (initialize-pool)
        (unwind-protect
             (let ((worker (get-or-assign-worker "crashed-backend-session")))
               ;; Control: while the worker is alive the same call succeeds and
               ;; carries no failure name at all.
               (let ((payload (dispatch-payload "crashed-backend-session")))
                 (isnt equal "backend_crashed" (gethash "error_type" payload)
                       "a live worker's call is not reported as a crash"))
               (let ((process (worker-process-info worker)))
                 (ignore-errors (sb-posix:kill (worker-pid worker) 9))
                 (loop repeat 100
                       while (sb-ext:process-alive-p process)
                       do (sleep 0.1))
                 (false (sb-ext:process-alive-p process)
                        "the worker's process is gone before the call goes in"))
               (let ((payload (dispatch-payload "crashed-backend-session")))
                 (true (gethash "isError" payload))
                 (is equal "backend_crashed" (gethash "error_type" payload))))
          (ignore-errors (shutdown-pool)))))))
