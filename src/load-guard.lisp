;;;; src/load-guard.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Time limit for in-process load-system and run-tests that never unwinds
;;;; through ASDF or LOAD.
;;;;
;;;; Provides:
;;;;   call-with-load-guard        - run a thunk on a thread of its own, reply
;;;;                                 at the limit, leave the thread to finish.
;;;;   running-operation           - the guarded operation that makes a call
;;;;                                 answer busy, or NIL.
;;;;   wait-for-guarded-operations - poll until no such operation remains.
;;;;
;;;; Design notes:
;;;;   An asynchronous interrupt delivered inside ASDF or LOAD can leave ASDF
;;;;   half-updated in a worker that keeps serving. The guard therefore runs
;;;;   each operation on its own thread and only bounds the caller's wait. At
;;;;   the limit the caller gets its timeout reply; the thread runs on, and
;;;;   until it finishes every further guarded call answers busy instead of
;;;;   starting a second operation. No code here interrupts, destroys or
;;;;   terminates an operation's thread.
;;;;
;;;;   A guarded call made from inside a guarded operation is not refused
;;;;   because of its own ancestors: each record holds its parent, and only
;;;;   records outside the caller's chain count as busy.

(defpackage #:dsmr-mcp/src/load-guard
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:current-thread
                #:thread-alive-p
                #:make-lock
                #:with-lock-held
                #:make-condition-variable
                #:condition-wait
                #:condition-notify)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:asdf)
  (:export #:call-with-load-guard
           #:running-operation
           #:wait-for-guarded-operations
           #:busy-message
           #:busy-retry-text))

(in-package #:dsmr-mcp/src/load-guard)

;;; ---------------------------------------------------------------------------
;;; State
;;; ---------------------------------------------------------------------------

(defstruct (guarded-op (:constructor %make-guarded-op
                           (operation system start parent)))
  "One live guarded operation: OPERATION and SYSTEM name it, START is its
internal real time, THREAD runs it, PARENT is the record of the operation
that made the call, or NIL."
  operation
  system
  start
  (thread nil)
  parent)

(defvar *guard-lock* (make-lock "dsmr-mcp load guard")
  "Protects *GUARDED-OPS* and every per-call result cell.")

(defvar *guarded-ops* '()
  "Live guarded operations, oldest first. Read and written under *GUARD-LOCK*.")

(defun %elapsed-seconds (start)
  "Whole seconds since internal real time START."
  (floor (- (get-internal-real-time) start) internal-time-units-per-second))

(defun %elapsed-ms (start)
  "Milliseconds since internal real time START, rounded."
  (round (* 1000 (- (get-internal-real-time) start))
         internal-time-units-per-second))

(defun %prune-dead-ops ()
  "Drop records whose thread is no longer alive. Call with *GUARD-LOCK* held."
  (setf *guarded-ops*
        (remove-if (lambda (op)
                     (let ((th (guarded-op-thread op)))
                       (and th (not (thread-alive-p th)))))
                   *guarded-ops*)))

(defun %caller-chain ()
  "Records of the operation running on the current thread and its parents.
Call with *GUARD-LOCK* held."
  (let ((self (find (current-thread) *guarded-ops* :key #'guarded-op-thread)))
    (loop for op = self then (guarded-op-parent op)
          while op
          collect op)))

(defun %blocking-op ()
  "Oldest live record outside the caller's chain, or NIL.
Call with *GUARD-LOCK* held."
  (%prune-dead-ops)
  (let ((chain (%caller-chain)))
    (find-if (lambda (op) (not (member op chain))) *guarded-ops*)))

;;; ---------------------------------------------------------------------------
;;; Observation
;;; ---------------------------------------------------------------------------

(defun running-operation ()
  "Return (values OPERATION SYSTEM ELAPSED-SECONDS) for the oldest live guarded
operation outside the caller's chain, or NIL when there is none."
  (let ((op (with-lock-held (*guard-lock*) (%blocking-op))))
    (when op
      (values (guarded-op-operation op)
              (guarded-op-system op)
              (%elapsed-seconds (guarded-op-start op))))))

(defun wait-for-guarded-operations (seconds)
  "Poll RUNNING-OPERATION every 0.05 s for up to SECONDS.
Return T as soon as it reports NIL, else NIL. Observes only."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop
      (unless (running-operation)
        (return t))
      (when (>= (get-internal-real-time) deadline)
        (return nil))
      (sleep 0.05))))

(defun busy-message (operation system elapsed-seconds)
  "Text of a busy reply naming the running OPERATION, its SYSTEM and
ELAPSED-SECONDS."
  (format nil "Previous ~A of ~A still running (~D s elapsed)"
          operation system elapsed-seconds))

(defun busy-retry-text ()
  "Sentence appended to the content text of every busy reply."
  "Retry when it finishes; pool-kill-worker stops a worker whose load never does.")

;;; ---------------------------------------------------------------------------
;;; call-with-load-guard
;;; ---------------------------------------------------------------------------

(defstruct (guard-cell (:constructor %make-guard-cell ()))
  "Result of one guarded call. STATE is :PENDING, :VALUE or :CONDITION.
ABANDONED is true once the caller has stopped waiting."
  (state :pending)
  (result nil)
  (abandoned nil))

(defun %run-operation-body (thunk tag)
  "Call THUNK with the debugger hooks bound to a throw to TAG.
Return (:value V) or (:condition C)."
  (catch tag
    (let* ((hook (lambda (condition old-hook)
                   (declare (ignore old-hook))
                   (throw tag (list :condition condition))))
           (*debugger-hook* hook)
           #+sbcl (sb-ext:*invoke-debugger-hook* hook))
      (handler-case (list :value (funcall thunk))
        (serious-condition (c)
          (list :condition c))))))

(defun %finish-operation (op cell cv outcome)
  "Record OUTCOME in CELL, drop OP and wake the caller. Log the outcome when
the caller has already given up."
  (let ((outcome (or outcome
                     (list :condition
                           (make-condition
                            'simple-error
                            :format-control "Guarded ~A of ~A exited without a result"
                            :format-arguments (list (guarded-op-operation op)
                                                    (guarded-op-system op))))))
        (abandoned nil))
    (with-lock-held (*guard-lock*)
      (setf (guard-cell-state cell) (first outcome)
            (guard-cell-result cell) (second outcome)
            abandoned (guard-cell-abandoned cell)
            *guarded-ops* (remove op *guarded-ops*))
      (condition-notify cv))
    (when abandoned
      (let ((ms (%elapsed-ms (guarded-op-start op))))
        (if (eq (first outcome) :value)
            (log-event :info "load-guard.abandoned-finished"
                       "operation" (guarded-op-operation op)
                       "system" (guarded-op-system op)
                       "duration_ms" ms
                       "outcome" "value")
            (log-event :warn "load-guard.abandoned-finished"
                       "operation" (guarded-op-operation op)
                       "system" (guarded-op-system op)
                       "duration_ms" ms
                       "outcome" "condition"
                       "condition_type"
                       (princ-to-string (type-of (second outcome)))))))))

(defun call-with-load-guard (operation system timeout-seconds thunk
                             &key on-timeout on-busy)
  "Run THUNK on a thread of its own and wait at most TIMEOUT-SECONDS for it.

OPERATION and SYSTEM are strings naming the work. Return THUNK's value when it
finishes in time. A condition escaping THUNK is signalled in the caller with
ERROR. At the limit, return (funcall ON-TIMEOUT ELAPSED-MS) and leave the
thread running. While a guarded operation outside the caller's chain is live,
start nothing and return (funcall ON-BUSY OPERATION SYSTEM ELAPSED-SECONDS)
for the oldest one. The thread is never interrupted or terminated."
  (let* ((start  (get-internal-real-time))
         (cell   (%make-guard-cell))
         (cv     (make-condition-variable :name "dsmr-mcp load guard"))
         (tag    (list :load-guard))
         (out    *standard-output*)
         (err    *error-output*)
         (trc    *trace-output*)
         (dbg    *debug-io*)
         (pkg    *package*)
         (rt     *readtable*)
         (dpd    *default-pathname-defaults*)
         (reg    asdf:*central-registry*)
         (busy   nil)
         (op     nil))
    (with-lock-held (*guard-lock*)
      (setf busy (%blocking-op))
      (unless busy
        (setf op (%make-guarded-op operation system start
                                   (first (%caller-chain))))
        (setf (guarded-op-thread op)
              (make-thread
               (lambda ()
                 (let ((*standard-output* out)
                       (*error-output* err)
                       (*trace-output* trc)
                       (*debug-io* dbg)
                       (*package* pkg)
                       (*readtable* rt)
                       (*default-pathname-defaults* dpd)
                       (asdf:*central-registry* reg)
                       (outcome nil))
                   (unwind-protect
                        (setf outcome (%run-operation-body thunk tag))
                     (%finish-operation op cell cv outcome))))
               :name (format nil "dsmr-mcp ~A ~A" operation system)))
        (setf *guarded-ops* (append *guarded-ops* (list op)))))
    (when busy
      (let ((secs (%elapsed-seconds (guarded-op-start busy))))
        (log-event :info "load-guard.busy"
                   "operation" operation "system" system
                   "running_operation" (guarded-op-operation busy)
                   "running_system" (guarded-op-system busy)
                   "elapsed_seconds" secs)
        (return-from call-with-load-guard
          (funcall on-busy (guarded-op-operation busy)
                   (guarded-op-system busy) secs))))
    (let ((state nil) (result nil))
      (with-lock-held (*guard-lock*)
        (let ((deadline (+ start (* timeout-seconds
                                    internal-time-units-per-second))))
          (loop while (eq (guard-cell-state cell) :pending)
                for remaining = (- deadline (get-internal-real-time))
                while (plusp remaining)
                do (condition-wait cv *guard-lock*
                                   :timeout (/ remaining
                                               internal-time-units-per-second))))
        (setf state (guard-cell-state cell)
              result (guard-cell-result cell))
        (when (eq state :pending)
          (setf (guard-cell-abandoned cell) t)))
      (ecase state
        (:value result)
        (:condition (error result))
        (:pending
         (log-event :warn "load-guard.abandoned"
                    "operation" operation "system" system
                    "timeout" timeout-seconds)
         (funcall on-timeout (%elapsed-ms start)))))))
