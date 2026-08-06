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
  (:use #:cl #:zebra)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
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
  ;; End-to-end CONC-01 offload test: drives serve-streams over real OS pipes
  ;; with a mock backend verb that blocks on a condition variable.
  (:import-from #:dsmr-mcp/src/transport/stdio
                #:serve-streams)
  (:import-from #:dsmr-mcp/src/state
                #:make-session)
  (:import-from #:dsmr-mcp/src/hermetic/dispatch
                #:+worker-routed-tools+)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:*tool-classes*)
  ;; result shadows zebra:result (the mock handler builds a tool result
  ;; envelope; this package does not use zebra's result symbol).
  (:shadowing-import-from #:dsmr-mcp/src/tools/helpers
                #:result)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/tests/support/scoped-tools
                #:unregister-tool)
  (:import-from #:bordeaux-threads
                #:make-thread #:join-thread
                #:make-lock #:with-lock-held
                #:make-condition-variable #:condition-wait #:condition-notify))

(in-package #:dsmr-mcp/tests/transport/concurrent-dispatch-test)

;;; ===========================================================================
;;; End-to-end CONC-01: the read loop offloads backend calls and stays
;;; responsive. Driven over real OS pipes (a synchronous string-stream cannot
;;; model a blocking handler) with a mock backend verb that parks on a condition
;;; variable until the test releases it.
;;;
;;; sb-posix must be loaded before the pipe-driver form below is READ, since it
;;; names sb-posix:pipe; keep this require as its own earlier top-level form.
;;; ===========================================================================

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

;; Fixtures + pipe driver for the two end-to-end tests below. Wrapped in a
;; top-level PROGN so its subforms are still processed as top-level definitions
;; (the defclass is compiled before the defmethod that specialises on it).
(progn
  ;; Rendezvous between the test thread and the mock handler running on a
  ;; dispatch worker. *mock-entered* counts handler invocations that reached the
  ;; park point; *mock-released* gates their return. One lock + cv guards both
  ;; (each waiter re-checks its own predicate).
  (defvar *mock-lock* (make-lock "concurrent-dispatch-mock"))
  (defvar *mock-cv* (make-condition-variable :name "concurrent-dispatch-mock"))
  (defvar *mock-entered* 0)
  (defvar *mock-released* nil)

  (defclass blocking-backend-tool (mcp-tool)
    ((dsmr-mcp/src/tools/base::name
      :allocation :class :initform "mock-blocking-backend")
     (dsmr-mcp/src/tools/base::description
      :allocation :class :initform "Mock backend verb that blocks until released.")
     (dsmr-mcp/src/tools/base::input-schema
      :allocation :class :initform '(:object :properties () :required ())))
    (:metaclass mcp-tool-class))
  (c2mop:ensure-finalized (find-class 'blocking-backend-tool))
  ;; The defclass auto-registers in the global registry at finalization; scrub
  ;; it so tools/list and the docs parity renderer never see the fixture. The
  ;; pipe driver re-installs it (and the matching backend-verb tag) only for the
  ;; duration of a single test, then restores both.
  (unregister-tool "mock-blocking-backend")

  (defmethod tool-handle ((tool blocking-backend-tool) id args)
    (declare (ignore args))
    ;; Signal entry, then park until the test releases us.
    (with-lock-held (*mock-lock*)
      (incf *mock-entered*)
      (sb-thread:condition-broadcast *mock-cv*))
    (with-lock-held (*mock-lock*)
      (loop until *mock-released*
            do (condition-wait *mock-cv* *mock-lock*)))
    (result id (make-ht "ok" t)))

  (defun %wait-until (predicate timeout)
    "Block until PREDICATE returns true or TIMEOUT seconds elapse, waking on the
mock cv. Returns PREDICATE's final value — NIL means the deadline won, which a
caller asserts on rather than hanging forever."
    (with-lock-held (*mock-lock*)
      (let ((deadline (+ (get-internal-real-time)
                         (round (* timeout internal-time-units-per-second)))))
        (loop until (funcall predicate)
              do (let ((remaining (/ (- deadline (get-internal-real-time))
                                     internal-time-units-per-second)))
                   (when (<= remaining 0) (return))
                   (condition-wait *mock-cv* *mock-lock* :timeout remaining)))
        (funcall predicate))))

  (defun %release-mock ()
    (with-lock-held (*mock-lock*)
      (setf *mock-released* t)
      (sb-thread:condition-broadcast *mock-cv*)))

  (defun %rpc-init-line (id)
    (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}" id))
  (defun %rpc-call-line (id name)
    (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"method\":\"tools/call\",\"params\":{\"name\":\"~A\",\"arguments\":{}}}" id name))
  (defun %rpc-ping-line (id)
    (format nil "{\"jsonrpc\":\"2.0\",\"id\":~A,\"method\":\"ping\"}" id))

  (defun call-with-mock-backend-server (body)
    "Drive serve-streams over real OS pipes with a scoped 'mock-blocking-backend'
backend verb bound to BLOCKING-BACKEND-TOOL, then call BODY with two closures:
SEND (write one JSON-RPC line to the server) and RECV (read + parse one response
line, time-bounded so a wedged loop fails the test instead of hanging).

A fresh handshake (initialize + initialized) runs first and its response is
drained, so BODY sees a clean output channel. Teardown (always) releases the
mock, restores the global backend-verb list and tool registry, closes the
server's input to drive it to EOF, joins the serve thread, and closes the pipe
streams — so a failing assertion never leaks a blocked handler or a live thread."
    (setf *mock-entered* 0 *mock-released* nil)
    (let ((saved-verbs (symbol-value '+worker-routed-tools+))
          (serve-thread nil))
      (multiple-value-bind (in-read in-write) (sb-posix:pipe)
        (multiple-value-bind (out-read out-write) (sb-posix:pipe)
          (let ((server-in  (sb-sys:make-fd-stream in-read :input t
                                                   :external-format :utf-8 :buffering :none))
                (client-out (sb-sys:make-fd-stream in-write :output t
                                                   :external-format :utf-8 :buffering :none))
                (server-out (sb-sys:make-fd-stream out-write :output t
                                                   :external-format :utf-8 :buffering :none))
                (client-in  (sb-sys:make-fd-stream out-read :input t
                                                   :external-format :utf-8 :buffering :none)))
            (unwind-protect
                 (progn
                   ;; Install the scoped backend verb + mock class GLOBALLY: the
                   ;; serve loop and the dispatch-pool workers run on their own
                   ;; threads and read the global values, not a dynamic
                   ;; rebinding.
                   (setf (symbol-value '+worker-routed-tools+)
                         (cons "mock-blocking-backend" saved-verbs))
                   (setf (gethash "mock-blocking-backend" *tool-classes*)
                         (find-class 'blocking-backend-tool))
                   (setf serve-thread
                         (make-thread
                          (lambda ()
                            (serve-streams server-in server-out
                                           :session (make-session :id "concurrent-dispatch")))))
                   (flet ((send (line)
                            (write-line line client-out)
                            (finish-output client-out))
                          (recv ()
                            (sb-ext:with-timeout 10 (jzon:parse (read-line client-in)))))
                     (send (%rpc-init-line 0))
                     (send "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
                     (recv)             ; drain the initialize response
                     (funcall body #'send #'recv)))
              ;; Teardown — order matters: release first so parked workers can
              ;; finish, then EOF the input so the loop returns, then join.
              (%release-mock)
              (setf (symbol-value '+worker-routed-tools+) saved-verbs)
              (remhash "mock-blocking-backend" *tool-classes*)
              (ignore-errors (close client-out))
              (when serve-thread
                (ignore-errors (sb-ext:with-timeout 5 (join-thread serve-thread))))
              (ignore-errors (close server-in))
              (ignore-errors (close server-out))
              (ignore-errors (close client-in)))))))))

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

(define-test ping-stays-responsive-while-backend-call-blocks
  ;; CONC-01: a backend tools/call is offloaded to a worker and parks; a ping
  ;; sent AFTER it must get its response back while the backend call is still
  ;; held — proof the read loop is not serialized behind the backend call.
  (call-with-mock-backend-server
   (lambda (send recv)
     (funcall send (%rpc-call-line 1 "mock-blocking-backend"))
     ;; The offload actually reached a worker (not still on the read loop).
     (true (%wait-until (lambda () (>= *mock-entered* 1)) 10))
     (funcall send (%rpc-ping-line 2))
     (let ((resp (funcall recv)))
       ;; Ordering, not sleep-and-hope: the ping response is observed while the
       ;; backend tool is STILL held (not yet released).
       (false *mock-released*)
       (is = 2 (gethash "id" resp))
       (true (nth-value 1 (gethash "result" resp))))
     ;; Release; the backend call now completes and returns its own response.
     (%release-mock)
     (let ((resp (funcall recv)))
       (is = 1 (gethash "id" resp))))))

(define-test concurrent-backend-calls-do-not-serialize
  ;; CONC-01: two backend tools/calls submitted back-to-back must BOTH be
  ;; executing on worker threads at once before either is released — proof they
  ;; do not serialize on the read loop.
  (call-with-mock-backend-server
   (lambda (send recv)
     (funcall send (%rpc-call-line 1 "mock-blocking-backend"))
     (funcall send (%rpc-call-line 2 "mock-blocking-backend"))
     ;; Both handlers enter concurrently while neither has been released.
     (true (%wait-until (lambda () (>= *mock-entered* 2)) 10))
     (is >= *mock-entered* 2)
     (false *mock-released*)
     ;; Release both and drain the two responses (ids 1 and 2, any order).
     (%release-mock)
     (let ((ids (sort (list (gethash "id" (funcall recv))
                            (gethash "id" (funcall recv)))
                      #'<)))
       (is equal '(1 2) ids)))))
