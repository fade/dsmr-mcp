;;;; src/transport/dispatch-pool.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Bounded bordeaux-threads dispatch pool + in-house promise/future.
;;;;
;;;; This is the off-read-thread execution substrate for concurrent backend
;;;; tool dispatch. A caller submits a thunk and receives a promise back
;;;; immediately; worker threads run the thunk and fulfill the promise, and
;;;; awaiters wake via a condition broadcast.
;;;;
;;;; The pool is bounded with a FIFO queue and its size is derived from the
;;;; hermetic *max-pool-size* so the dispatch-thread layer cannot
;;;; over-subscribe the child-process layer (dispatch <= *max-pool-size* is
;;;; deadlock-free: every dispatch thread is guaranteed a worker slot).
;;;;
;;;; Dispatcher-side, SBCL-OK: bordeaux-threads does not export
;;;; condition-broadcast, so the %condition-broadcast shim calls
;;;; sb-thread:condition-broadcast directly (single-notify cannot wake the
;;;; multiple awaiters a job handle will eventually permit).

(defpackage #:dsmr-mcp/src/transport/dispatch-pool
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-lock #:with-lock-held
                #:make-condition-variable #:condition-wait #:condition-notify
                #:make-thread #:thread-alive-p #:join-thread #:current-thread)
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:*max-pool-size*)
  (:import-from #:dsmr-mcp/src/log #:log-event)
  (:export #:dispatch-promise #:make-dispatch-promise
           #:dispatch-promise-lock #:dispatch-promise-condvar
           #:dispatch-promise-result #:dispatch-promise-errorp
           #:dispatch-promise-fulfilled #:dispatch-promise-cancelled
           #:dispatch-promise-session-id #:dispatch-promise-request-id
           #:dispatch-promise-mode #:dispatch-promise-thread
           #:dispatch-promise-slynk-conn
           #:fulfill-promise #:await-promise
           #:make-dispatch-pool #:dispatch-pool-submit
           #:dispatch-pool-shutdown
           #:ensure-dispatch-pool
           #:*dispatch-pool-size* #:*dispatch-pool*))

(in-package #:dsmr-mcp/src/transport/dispatch-pool)

;;; ---------------------------------------------------------------------------
;;; condition-broadcast shim (verbatim from src/hermetic/pool.lisp:224-227)
;;; ---------------------------------------------------------------------------

(defun %condition-broadcast (condvar)
  "Wake ALL threads waiting on CONDVAR."
  #+sbcl (sb-thread:condition-broadcast condvar)
  #-sbcl (bt:condition-notify condvar))

;;; ---------------------------------------------------------------------------
;;; In-house promise/future
;;; ---------------------------------------------------------------------------

(defstruct dispatch-promise
  "One promise per in-flight tool call. A worker thread fulfills it; awaiters
block in await-promise until it is fulfilled or their deadline elapses.

The session-id / request-id / mode / thread / slynk-conn slots are carried now
so the cancel and cancellation-wiring layers thread their state through this
struct without re-touching it, and so a future client-visible job handle can
elevate the same record."
  (lock      (make-lock "dispatch-promise"))
  (condvar   (make-condition-variable :name "dispatch-promise"))
  (result    nil)
  (errorp    nil :type boolean)
  (fulfilled nil :type boolean)
  (cancelled nil :type boolean)
  (session-id nil)
  (request-id nil)
  (mode       nil)          ; :attached | :hermetic
  (thread     nil)          ; the worker thread running this call (orphan tracking)
  (slynk-conn nil))         ; attached-mode connection reference (for interrupt)

(defun fulfill-promise (promise result &key (errorp nil))
  "Set PROMISE's RESULT, mark it fulfilled, and wake every awaiter.
With ERRORP true the result is treated as an error payload (a princ string)
and await-promise reports it as such."
  (with-lock-held ((dispatch-promise-lock promise))
    (setf (dispatch-promise-result    promise) result
          (dispatch-promise-errorp    promise) errorp
          (dispatch-promise-fulfilled promise) t)
    (%condition-broadcast (dispatch-promise-condvar promise))))

(defun await-promise (promise &key timeout)
  "Block until PROMISE is fulfilled, returning
\(values result errorp fulfilled cancelled).

With TIMEOUT (seconds) the wait is bounded by a deadline loop; if the deadline
elapses before fulfillment, the FULFILLED secondary value is nil and there is
no indefinite hang. The deadline loop mirrors bounded-slime-eval — a timed
condition-wait, never a SIGALRM unwind."
  (with-lock-held ((dispatch-promise-lock promise))
    (if timeout
        (let ((deadline (+ (get-internal-real-time)
                           (round (* timeout internal-time-units-per-second)))))
          (loop until (dispatch-promise-fulfilled promise)
                do (let ((remaining (/ (- deadline (get-internal-real-time))
                                       internal-time-units-per-second)))
                     (when (<= remaining 0) (return))
                     (condition-wait (dispatch-promise-condvar promise)
                                     (dispatch-promise-lock promise)
                                     :timeout remaining))))
        (loop until (dispatch-promise-fulfilled promise)
              do (condition-wait (dispatch-promise-condvar promise)
                                 (dispatch-promise-lock promise))))
    (values (dispatch-promise-result    promise)
            (dispatch-promise-errorp    promise)
            (dispatch-promise-fulfilled promise)
            (dispatch-promise-cancelled promise))))

;;; ---------------------------------------------------------------------------
;;; Pool size — derived from and clamped to the hermetic bound
;;; ---------------------------------------------------------------------------

(defun %dispatch-env-int (name default &key (min nil))
  "Read an integer from environment variable NAME. Return DEFAULT when NAME is
unset or empty; when the value is unparseable, or below MIN, warn and return
DEFAULT. Local copy of the pool.lisp %env-int (which is private there)."
  (let ((s (uiop:getenv name)))
    (cond
      ((or (null s) (zerop (length s))) default)
      (t
       (handler-case
           (let ((n (parse-integer s)))
             (cond
               ((and min (< n min))
                (warn "~A=~A is below ~D; using default ~A" name n min default)
                default)
               (t n)))
         (error ()
           (warn "~A=~S is not an integer; using default ~A" name s default)
           default))))))

(defun %clamp-pool-size (requested max)
  "Clamp REQUESTED to (min REQUESTED MAX). A NIL REQUESTED defaults to MAX.
This is the hard guarantee that the dispatch layer can never exceed the
hermetic child-process bound — over-subscribing it would block every dispatch
thread on get-or-assign-worker."
  (min (or requested max) max))

(defvar *dispatch-pool-size*
  (%clamp-pool-size (%dispatch-env-int "DSMR_DISPATCH_POOL_SIZE" nil :min 1)
                    *max-pool-size*)
  "Number of worker threads in the dispatch pool. Defaults to *max-pool-size*
so each dispatch thread has a guaranteed hermetic worker slot (1:1 mapping),
and is clamped to never exceed *max-pool-size*. Override with the
DSMR_DISPATCH_POOL_SIZE env var (a smaller value when memory is constrained).")

;;; ---------------------------------------------------------------------------
;;; Bounded FIFO worker pool
;;; ---------------------------------------------------------------------------

(defstruct (dispatch-pool (:constructor %make-dispatch-pool))
  "Bounded pool of worker threads draining a FIFO task queue. Each task is a
\(promise . thunk) cons. The queue is a head/tail singly-linked list so enqueue
and dequeue are O(1) and strictly first-in-first-out."
  (lock          (make-lock "dispatch-pool"))
  (not-empty     (make-condition-variable :name "dispatch-pool-not-empty"))
  (queue-head    nil)          ; FIFO front: first cons of the pending-task list
  (queue-tail    nil)          ; FIFO back: last cons of the pending-task list
  (workers       nil)          ; list of worker threads
  (size          0 :type fixnum)
  (shutting-down nil :type boolean))

(defun %enqueue (pool task)
  "Append TASK to POOL's FIFO queue. Caller must hold the pool lock."
  (let ((cell (cons task nil)))
    (if (dispatch-pool-queue-tail pool)
        (setf (cdr (dispatch-pool-queue-tail pool)) cell)
        (setf (dispatch-pool-queue-head pool) cell))
    (setf (dispatch-pool-queue-tail pool) cell)))

(defun %dequeue (pool)
  "Pop and return the front TASK of POOL's FIFO queue, or NIL when empty.
Caller must hold the pool lock."
  (let ((cell (dispatch-pool-queue-head pool)))
    (when cell
      (setf (dispatch-pool-queue-head pool) (cdr cell))
      (when (null (dispatch-pool-queue-head pool))
        (setf (dispatch-pool-queue-tail pool) nil))
      (car cell))))

(defun %run-task (task)
  "Run one (promise . thunk) TASK on the calling worker thread.

Lazy cancellation: a task whose promise was marked cancelled while it sat in
the queue is skipped entirely — the thunk never runs and no result is produced
\(the promise is fulfilled but left cancelled). This satisfies a cancel of a
queued-not-started call without any queue-scan: the worker simply declines to
run it. Otherwise the worker records itself as the running thread (so a
concurrent cancel can tell queued from running) and runs the thunk, capturing
any error as a princ string."
  (let ((promise (car task))
        (thunk   (cdr task))
        (cancelled nil))
    (with-lock-held ((dispatch-promise-lock promise))
      (if (dispatch-promise-cancelled promise)
          (setf cancelled t)
          (setf (dispatch-promise-thread promise) (current-thread))))
    (cond
      (cancelled
       (fulfill-promise promise nil))
      (t
       (unwind-protect
           (handler-case
               (fulfill-promise promise (funcall thunk))
             (error (e)
               (fulfill-promise promise (princ-to-string e) :errorp t)))
         ;; Defensive: a non-local exit (e.g. a thread interrupt) must not
         ;; leave an awaiter blocked forever.
         (unless (dispatch-promise-fulfilled promise)
           (fulfill-promise promise "dispatch worker exited without a result"
                            :errorp t)))))))

(defun %dispatch-worker-loop (pool)
  "Body of a pool worker thread: wait for FIFO tasks and run them until the
pool is shutting down and the queue has drained."
  (loop
    (let ((task nil))
      (with-lock-held ((dispatch-pool-lock pool))
        (loop until (or (dispatch-pool-shutting-down pool)
                        (dispatch-pool-queue-head pool))
              do (condition-wait (dispatch-pool-not-empty pool)
                                 (dispatch-pool-lock pool)))
        (if (and (dispatch-pool-shutting-down pool)
                 (null (dispatch-pool-queue-head pool)))
            (return)
            (setf task (%dequeue pool))))
      (when task
        (%run-task task)))))

(defun make-dispatch-pool (&key (size *dispatch-pool-size*))
  "Create a dispatch pool and spawn SIZE worker threads, each draining the
shared FIFO queue. SIZE defaults to *dispatch-pool-size* (already clamped to
*max-pool-size*)."
  (let ((pool (%make-dispatch-pool :size size)))
    (setf (dispatch-pool-workers pool)
          (loop for i from 0 below size
                collect (make-thread
                         (lambda () (%dispatch-worker-loop pool))
                         :name (format nil "dispatch-worker-~D" i))))
    (log-event :info "dispatch.pool.start" "size" size)
    pool))

(defun dispatch-pool-submit (pool thunk &key session-id request-id mode)
  "Enqueue THUNK on POOL and return its dispatch-promise immediately. The
submitting thread does not block on task execution: a worker thread runs the
thunk and fulfills the promise. SESSION-ID / REQUEST-ID / MODE are recorded on
the promise for cancel and job-handle bookkeeping."
  (let ((promise (make-dispatch-promise :session-id session-id
                                        :request-id request-id
                                        :mode mode)))
    (with-lock-held ((dispatch-pool-lock pool))
      (when (dispatch-pool-shutting-down pool)
        (error "dispatch-pool-submit: pool is shutting down."))
      (%enqueue pool (cons promise thunk))
      (condition-notify (dispatch-pool-not-empty pool)))
    promise))

(defun dispatch-pool-shutdown (pool)
  "Stop POOL accepting new tasks, wake every idle worker, and join the workers
best-effort so in-flight tasks drain before the pool is torn down."
  (with-lock-held ((dispatch-pool-lock pool))
    (setf (dispatch-pool-shutting-down pool) t)
    (%condition-broadcast (dispatch-pool-not-empty pool)))
  (dolist (w (dispatch-pool-workers pool))
    (when (thread-alive-p w)
      (ignore-errors (join-thread w))))
  (log-event :info "dispatch.pool.shutdown")
  t)

;;; ---------------------------------------------------------------------------
;;; Process-wide pool — single entry point for the transport layer
;;; ---------------------------------------------------------------------------

(defvar *dispatch-pool* nil
  "Process-wide dispatch pool, created lazily by ensure-dispatch-pool.")

(defvar *dispatch-pool-init-lock* (make-lock "dispatch-pool-init")
  "Serializes lazy creation of *dispatch-pool*.")

(defun ensure-dispatch-pool ()
  "Return the process-wide dispatch pool, creating it on first use. The
transport layer routes every backend submission through this one accessor."
  (or *dispatch-pool*
      (with-lock-held (*dispatch-pool-init-lock*)
        (or *dispatch-pool*
            (setf *dispatch-pool* (make-dispatch-pool))))))
