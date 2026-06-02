;;;; tests/hermetic/pool-affinity-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Integration tests for warmup pool pre-spawning and strict per-session
;;;; affinity. Both tests spawn real workers via the pool so they require the
;;;; full hermetic worker subsystem.
;;;;
;;;; Warmup: initialize-pool launches standby workers asynchronously; a brief
;;;; sleep allows the replenish thread to complete.
;;;; Affinity: two sequential get-or-assign-worker calls for the same session
;;;; return a worker with the same pid. A different session-id gets a different
;;;; worker pid (scale-out isolation).

(defpackage #:dsmr-mcp/tests/integration/hermetic/pool-affinity-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool
                #:get-or-assign-worker #:release-session
                #:pool-status-info)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:worker-pid)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server))

(in-package #:dsmr-mcp/tests/integration/hermetic/pool-affinity-test)

;;; ---------------------------------------------------------------------------
;;; Spawn guard: these tests fork real SBCL worker subprocesses, so they skip
;;; cleanly (parachute skip, not fail) when the environment cannot spawn one —
;;; no sbcl on PATH, or no Quicklisp setup.lisp for the child to load dsmr-mcp.
;;;
;;; Assumption: the guard checks that sbcl and a Quicklisp setup.lisp exist; it
;;; does NOT verify that dsmr-mcp itself is resolvable in the child's source
;;; registry. On a runner with Quicklisp present but the project not on the
;;; child's CL_SOURCE_REGISTRY, the guard passes and the child fails to build,
;;; which surfaces as a test failure rather than the intended clean skip. A
;;; constrained runner must therefore make dsmr-mcp resolvable for the child.
;;; ---------------------------------------------------------------------------

(defun %sbcl-path ()
  (or (ignore-errors
        (let ((r (string-trim '(#\Newline #\Return #\Space)
                              (uiop:run-program '("which" "sbcl")
                                                :output :string
                                                :ignore-error-status t))))
          (and (plusp (length r)) r)))
      (find-if #'probe-file '("/usr/local/bin/sbcl" "/usr/bin/sbcl" "/opt/local/bin/sbcl"))))

(defun %quicklisp-setup-present-p ()
  (and (probe-file (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))) t))

(defun %spawnable-p ()
  (and (%sbcl-path) (%quicklisp-setup-present-p)))

;;; ---------------------------------------------------------------------------
;;; Warmup: initialize-pool spawns standby workers asynchronously
;;; ---------------------------------------------------------------------------

(define-test warmup-pool-spawns-standbys
  "initialize-pool with *worker-pool-warmup* = 1 spawns at least one standby
worker in the background. The test sleeps briefly to let the asynchronous
replenish thread complete, then verifies via pool-status-info."
  (unless (%spawnable-p)
    (skip "cannot spawn a worker subprocess (sbcl / quicklisp setup.lisp absent)"))
  (let ((*mode* :hermetic)
        (*error-output* (make-string-output-stream)))
    (configure-log4cl-for-server :warn)
    ;; Bind warmup and max in the current dynamic environment.
    ;; The pool init reads the bound values; the replenish thread captures them.
    (let ((dsmr-mcp/src/hermetic/pool:*worker-pool-warmup* 1)
          (dsmr-mcp/src/hermetic/pool:*max-pool-size* 4))
      (initialize-pool)
      (unwind-protect
           (progn
             ;; Allow the replenish thread time to spawn the standby worker.
             ;; Warmup spawn takes ~2–5 s (fresh SBCL image load); 30 s is safe.
             (loop repeat 60
                   until (let ((info (pool-status-info)))
                           (plusp (gethash "standby_count" info)))
                   do (sleep 0.5))
             (let* ((info (pool-status-info))
                    (standby-count (gethash "standby_count" info))
                    (pool-running (gethash "pool_running" info)))
               (true pool-running)
               (true (>= standby-count 1))))
        (ignore-errors (shutdown-pool))))))

;;; ---------------------------------------------------------------------------
;;; Strict session affinity and scale-out isolation
;;; ---------------------------------------------------------------------------

(define-test session-affinity-same-pid
  "Two sequential get-or-assign-worker calls for the same session-id return
the same worker (same pid). A second session-id gets a different worker with a
different pid, confirming scale-out assigns new workers per session."
  (unless (%spawnable-p)
    (skip "cannot spawn a worker subprocess (sbcl / quicklisp setup.lisp absent)"))
  (let ((*mode* :hermetic)
        (*error-output* (make-string-output-stream)))
    (configure-log4cl-for-server :warn)
    (let ((dsmr-mcp/src/hermetic/pool:*worker-pool-warmup* 0)
          (dsmr-mcp/src/hermetic/pool:*max-pool-size* 4))
      (initialize-pool)
      (unwind-protect
           (let* ((w1a (get-or-assign-worker "affinity-session-A"))
                  (pid-1a (worker-pid w1a))
                  ;; Second call for same session — must return same worker
                  (w1b (get-or-assign-worker "affinity-session-A"))
                  (pid-1b (worker-pid w1b))
                  ;; Different session — must get a different worker
                  (w2  (get-or-assign-worker "affinity-session-B"))
                  (pid-2 (worker-pid w2)))
             ;; Strict affinity: same session → same worker pid
             (is = pid-1a pid-1b)
             ;; Scale-out isolation: different session → different pid
             (true (/= pid-1a pid-2))
             ;; All pids must be positive integers
             (true (and (integerp pid-1a) (plusp pid-1a)))
             (true (and (integerp pid-2) (plusp pid-2))))
        (ignore-errors (shutdown-pool))))))
