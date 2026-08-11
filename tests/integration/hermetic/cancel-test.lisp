;;;; tests/integration/hermetic/cancel-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for client-initiated cancellation of a hermetic call.
;;;;
;;;; A notifications/cancelled for an in-flight hermetic call hard-kills and
;;;; respawns the disposable worker (kill-session-worker), which frees the
;;;; worker and unblocks the dispatch worker that was waiting on it. The session
;;;; stays usable: the next call spawns a fresh worker and runs normally. A
;;;; cancel of a still-queued call marks its promise cancelled so the pool worker
;;;; lazy-skips it before it runs -- it produces no result while other queued
;;;; calls still run.
;;;;
;;;; The kill + session-usable tests fork a real SBCL worker subprocess, so they
;;;; wrap their bodies in WITH-WORKER-CHILD-OR-SKIP and skip cleanly only when
;;;; the environment genuinely cannot build a worker child (see
;;;; tests/integration/support.lisp). The queued-drop test needs no subprocess:
;;;; it exercises the dispatch-pool lazy-skip the cancel handler relies on with
;;;; plain thunks, so it always runs.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/hermetic/cancel-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/hermetic/cancel-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool
                #:shutdown-pool
                #:get-or-assign-worker
                #:kill-session-worker
                #:pool-rpc-with-hard-kill)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:worker-pid)
  (:import-from #:dsmr-mcp/src/transport/dispatch-pool
                #:make-dispatch-pool
                #:dispatch-pool-submit
                #:dispatch-pool-shutdown
                #:await-promise
                #:dispatch-promise-thread
                #:dispatch-promise-cancelled
                #:dispatch-promise-lock)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-worker-child-or-skip))

(in-package #:dsmr-mcp/tests/integration/hermetic/cancel-test)

;;; ---------------------------------------------------------------------------
;;; (a) A cancel of a running hermetic call frees the worker
;;; ---------------------------------------------------------------------------

(define-test hermetic-cancel-frees-worker
  "A long hermetic call is offloaded through the dispatch pool; cancelling it
hard-kills the worker (kill-session-worker -> :killed). The blocked dispatch
promise then resolves rather than hanging (the worker thread unblocks), and the
session rebinds to a fresh worker (different pid) -- the worker is disposable."
  (with-worker-child-or-skip
    (let ((*mode* :hermetic)
          (*error-output* (make-string-output-stream)))
      (configure-log4cl-for-server :warn)
      (let ((dsmr-mcp/src/hermetic/pool:*worker-pool-warmup* 0)
            (dsmr-mcp/src/hermetic/pool:*max-pool-size* 4)
            (session "hermetic-cancel-frees")
            (pool (make-dispatch-pool :size 2)))
        (initialize-pool)
        (unwind-protect
             (let* ((w1 (get-or-assign-worker session))
                    (pid1 (worker-pid w1))
                    (promise
                      (dispatch-pool-submit
                       pool
                       (lambda ()
                         (pool-rpc-with-hard-kill
                          w1 "worker/eval"
                          (make-ht "code" "(sleep 30)" "timeout_seconds" 30)
                          :soft-timeout 30))
                       :session-id session
                       :request-id "hermetic-cancel-1"
                       :mode :hermetic)))
               ;; Wait until the dispatch worker has actually started the call
               ;; (records its thread), so this is the running-cancel path.
               (loop repeat 200
                     until (dispatch-promise-thread promise)
                     do (sleep 0.05))
               (true (dispatch-promise-thread promise)
                     "the dispatch worker never started the long call")
               ;; Mirror the cancel handler: mark cancelled, then hard-kill.
               (bt:with-lock-held ((dispatch-promise-lock promise))
                 (setf (dispatch-promise-cancelled promise) t))
               (is eq :killed (kill-session-worker session)
                   "kill-session-worker did not report a killed worker")
               ;; The blocked dispatch promise must resolve, not hang.
               (multiple-value-bind (result errorp fulfilled)
                   (await-promise promise :timeout 20)
                 (declare (ignore result errorp))
                 (true fulfilled
                       "blocked dispatch promise did not resolve after the kill"))
               ;; The session is freed: a fresh assignment spawns a NEW worker.
               (let ((w2 (get-or-assign-worker session)))
                 (true (/= pid1 (worker-pid w2))
                       "session was not rebound to a fresh worker after the kill")))
          (ignore-errors (dispatch-pool-shutdown pool))
          (ignore-errors (shutdown-pool)))))))

;;; ---------------------------------------------------------------------------
;;; (b) The session remains usable after a cancel
;;; ---------------------------------------------------------------------------

(define-test session-usable-after-cancel
  "After a session's worker is killed by a cancel, the session stays usable: a
fresh tools/call-equivalent (worker/eval) spawns a new worker and runs cleanly."
  (with-worker-child-or-skip
    (let ((*mode* :hermetic)
          (*error-output* (make-string-output-stream)))
      (configure-log4cl-for-server :warn)
      (let ((dsmr-mcp/src/hermetic/pool:*worker-pool-warmup* 0)
            (dsmr-mcp/src/hermetic/pool:*max-pool-size* 4)
            (session "hermetic-cancel-usable"))
        (initialize-pool)
        (unwind-protect
             (progn
               (get-or-assign-worker session)
               ;; The cancel: hard-kill the session's worker.
               (kill-session-worker session)
               ;; A fresh call must succeed against the respawned worker.
               (let* ((w (get-or-assign-worker session))
                      (resp (pool-rpc-with-hard-kill
                             w "worker/eval"
                             (make-ht "code" "(+ 1 2)")
                             :soft-timeout 30)))
                 (true (hash-table-p resp)
                       "a fresh call after a cancel did not return a result payload")))
          (ignore-errors (shutdown-pool)))))))

;;; ---------------------------------------------------------------------------
;;; (c) A cancel of a queued-not-started call drops it (no subprocess needed)
;;; ---------------------------------------------------------------------------

(define-test cancel-queued-call-drops-it
  "Cancelling a queued-not-started call marks its promise cancelled so the pool
worker lazy-skips it before running: it never runs its body and produces no
result (D-04), while the other queued calls still run. This is the dispatch-pool
lazy-skip the cancel handler relies on, exercised with plain thunks."
  (let ((pool (make-dispatch-pool :size 1))
        (gate (bt:make-lock "queued-gate"))
        (ran-blocker nil)
        (ran-cancelled nil)
        (ran-other nil))
    (unwind-protect
         (progn
           ;; Occupy the single worker with a blocker we hold via GATE.
           (bt:acquire-lock gate)
           (let ((blocker
                   (dispatch-pool-submit
                    pool
                    (lambda () (bt:with-lock-held (gate) (setf ran-blocker t) :done))
                    :session-id "queued" :request-id "blocker" :mode :hermetic))
                 (cancelled
                   (dispatch-pool-submit
                    pool
                    (lambda () (setf ran-cancelled t) :cancelled-body)
                    :session-id "queued" :request-id "to-cancel" :mode :hermetic))
                 (other
                   (dispatch-pool-submit
                    pool
                    (lambda () (setf ran-other t) :other)
                    :session-id "queued" :request-id "other" :mode :hermetic)))
             ;; The to-cancel call is still queued (no running thread): mirror the
             ;; cancel handler's queued branch and mark its promise cancelled.
             (true (null (dispatch-promise-thread cancelled))
                   "the to-cancel call should still be queued, not running")
             (bt:with-lock-held ((dispatch-promise-lock cancelled))
               (setf (dispatch-promise-cancelled cancelled) t))
             ;; Release the blocker so the single worker drains the queue.
             (bt:release-lock gate)
             (await-promise blocker :timeout 10)
             (multiple-value-bind (result errorp fulfilled cancelled-flag)
                 (await-promise cancelled :timeout 10)
               (declare (ignore errorp))
               (true fulfilled "the cancelled queued promise never resolved")
               (true cancelled-flag "the queued promise was not marked cancelled")
               (is eq nil result "a dropped queued call must produce no result"))
             (await-promise other :timeout 10)
             (true ran-blocker "the blocker did not run")
             (true ran-other "the other queued call did not run")
             (false ran-cancelled
                    "the cancelled queued call ran its body instead of being dropped")))
      (ignore-errors (bt:release-lock gate))
      (ignore-errors (dispatch-pool-shutdown pool)))))
