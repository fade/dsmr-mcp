;;;; tests/transport/concurrent-dispatch-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for the bounded BT dispatch pool + in-house promise/future.
;;;; Covers promise fulfill/await, await timeout, broadcast wakeup, the pool
;;;; concurrency bound, FIFO ordering, error capture, the *max-pool-size*
;;;; clamp, and the lazy-cancellation of a queued-not-started call.
;;;;
;;;; Package kept open for the end-to-end ping-while-busy test (over OS pipes)
;;;; that a later transport plan adds here.

(defpackage #:dsmr-mcp/tests/transport/concurrent-dispatch-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/transport/dispatch-pool
                #:dispatch-promise
                #:make-dispatch-promise
                #:dispatch-promise-lock
                #:dispatch-promise-cancelled
                #:fulfill-promise
                #:await-promise
                #:make-dispatch-pool
                #:dispatch-pool-submit
                #:dispatch-pool-shutdown
                #:*dispatch-pool-size*)
  ;; Internal clamp helper — imported by qualified name so the clamp behavior
  ;; can be exercised directly without mutating the process environment.
  (:import-from #:dsmr-mcp/src/transport/dispatch-pool
                #:%clamp-pool-size)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:*max-pool-size*)
  (:import-from #:bordeaux-threads
                #:make-thread #:join-thread
                #:make-lock #:with-lock-held
                #:make-condition-variable #:condition-wait #:condition-notify))

(in-package #:dsmr-mcp/tests/transport/concurrent-dispatch-test)

(define-test promise-fulfilled-from-worker-is-observed
  (let ((promise (make-dispatch-promise)))
    (make-thread (lambda () (sleep 0.05) (fulfill-promise promise :hello)))
    (multiple-value-bind (result errorp fulfilled)
        (await-promise promise :timeout 5)
      (is eq :hello result)
      (false errorp)
      (true fulfilled))))

(define-test fulfill-with-errorp-is-reported
  (let ((promise (make-dispatch-promise)))
    (fulfill-promise promise "boom" :errorp t)
    (multiple-value-bind (result errorp fulfilled)
        (await-promise promise :timeout 5)
      (is string= "boom" result)
      (true errorp)
      (true fulfilled))))

(define-test await-returns-on-timeout-when-unfulfilled
  (let ((promise (make-dispatch-promise))
        (start (get-internal-real-time)))
    (multiple-value-bind (result errorp fulfilled cancelled)
        (await-promise promise :timeout 0.2)
      (declare (ignore result errorp cancelled))
      (false fulfilled)
      (let ((elapsed (/ (- (get-internal-real-time) start)
                        internal-time-units-per-second)))
        ;; Returns near the deadline, not after an indefinite hang.
        (true (< elapsed 2))))))

(define-test fulfill-broadcasts-to-all-awaiters
  (let* ((promise (make-dispatch-promise))
         (woke-lock (make-lock "woke"))
         (woke 0)
         (t1 (make-thread (lambda ()
                            (await-promise promise :timeout 5)
                            (with-lock-held (woke-lock) (incf woke)))))
         (t2 (make-thread (lambda ()
                            (await-promise promise :timeout 5)
                            (with-lock-held (woke-lock) (incf woke))))))
    (sleep 0.2)                         ; let both threads enter the wait
    (fulfill-promise promise :ok)
    (join-thread t1)
    (join-thread t2)
    ;; A single fulfill woke BOTH awaiters (broadcast, not single-notify).
    (is = 2 woke)))

(define-test pool-runs-at-most-size-tasks-concurrently
  (let* ((pool (make-dispatch-pool :size 2))
         (clock (make-lock "concurrency"))
         (live 0)
         (max-seen 0)
         (promises '()))
    (unwind-protect
        (progn
          (dotimes (i 3)
            (push (dispatch-pool-submit
                   pool
                   (lambda ()
                     (with-lock-held (clock)
                       (incf live)
                       (setf max-seen (max max-seen live)))
                     (sleep 0.3)
                     (with-lock-held (clock) (decf live))
                     :ok))
                  promises))
          (dolist (p promises)
            (true (nth-value 2 (await-promise p :timeout 10))))
          ;; A size-2 pool never runs more than 2 of the 3 tasks at once.
          (is <= max-seen 2))
      (dispatch-pool-shutdown pool))))

(define-test pool-runs-queued-tasks-in-fifo-order
  (let* ((pool (make-dispatch-pool :size 1))
         (olock (make-lock "order"))
         (order '())
         (promises '()))
    (unwind-protect
        (progn
          (dotimes (i 5)
            (let ((n i))
              (push (dispatch-pool-submit
                     pool
                     (lambda ()
                       (with-lock-held (olock) (push n order))
                       n))
                    promises)))
          (dolist (p (reverse promises))
            (await-promise p :timeout 10))
          ;; Single worker drains the queue strictly first-in-first-out.
          (is equal '(0 1 2 3 4) (reverse order)))
      (dispatch-pool-shutdown pool))))

(define-test pool-captures-thunk-error-and-keeps-serving
  (let ((pool (make-dispatch-pool :size 1)))
    (unwind-protect
        (progn
          (let ((p (dispatch-pool-submit pool (lambda () (error "kaboom")))))
            (multiple-value-bind (result errorp fulfilled)
                (await-promise p :timeout 5)
              (true fulfilled)
              (true errorp)
              (true (search "kaboom" result))))
          ;; The pool serves the next submission normally.
          (let ((p2 (dispatch-pool-submit pool (lambda () 42))))
            (is = 42 (await-promise p2 :timeout 5))))
      (dispatch-pool-shutdown pool))))

(define-test dispatch-pool-size-is-clamped-to-max-pool-size
  ;; A requested size above the hermetic bound is capped to the bound.
  (is = 2 (%clamp-pool-size 8 2))
  ;; A NIL request defaults to the bound.
  (is = 2 (%clamp-pool-size nil 2))
  ;; A request below the bound is honored as-is.
  (is = 1 (%clamp-pool-size 1 2))
  ;; The live default never exceeds the hermetic child-process bound.
  (true (<= *dispatch-pool-size* *max-pool-size*)))

(define-test queued-cancelled-task-is-lazily-skipped
  ;; D-04: a queued-not-started call whose promise is marked cancelled is
  ;; skipped by the worker and never runs.
  (let* ((pool (make-dispatch-pool :size 1))
         (rel-lock (make-lock "release"))
         (rel-cv (make-condition-variable))
         (released nil)
         (counter 0))
    (unwind-protect
        (let* (;; Blocker occupies the single worker until released, so the
               ;; second task is guaranteed to still be queued when cancelled.
               (blocker (dispatch-pool-submit
                         pool
                         (lambda ()
                           (with-lock-held (rel-lock)
                             (loop until released
                                   do (condition-wait rel-cv rel-lock)))
                           :done)))
               (queued (dispatch-pool-submit
                        pool
                        (lambda () (incf counter) :ran))))
          ;; Cancel while the worker is still blocked on BLOCKER.
          (with-lock-held ((dispatch-promise-lock queued))
            (setf (dispatch-promise-cancelled queued) t))
          ;; Release the blocker so the worker advances to the queued task.
          (with-lock-held (rel-lock)
            (setf released t)
            (condition-notify rel-cv))
          (await-promise blocker :timeout 5)
          (multiple-value-bind (result errorp fulfilled cancelled)
              (await-promise queued :timeout 5)
            (declare (ignore result errorp))
            (true fulfilled)
            (true cancelled)
            ;; The cancelled thunk never ran.
            (is = 0 counter)))
      (dispatch-pool-shutdown pool))))
