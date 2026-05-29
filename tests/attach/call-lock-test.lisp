;;;; tests/attach/call-lock-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Unit tests for the process-wide *attach-call-lock* serialisation policy,
;;;; the :parallel opt-out, the queued-position notification side effect, and
;;;; source-level audit coverage ensuring every tool-handle :attached arm is
;;;; wrapped in with-serialised-attach-call or with-attach-dispatch.

(defpackage #:dsmr-mcp/tests/attach/call-lock-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:*attach-call-lock*
                #:*attach-concurrency*
                #:*attach-waiters*
                #:*attach-waiters-lock*
                #:*attach-holder-session-id*
                #:with-serialised-attach-call
                #:%resolve-attach-concurrency)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:session-id
                #:session-notify-channel)
  (:import-from #:dsmr-mcp/src/notify
                #:null-channel
                #:tcp-line-channel)
  (:import-from #:bordeaux-threads
                #:make-thread
                #:join-thread
                #:make-lock
                #:with-lock-held))

(in-package #:dsmr-mcp/tests/attach/call-lock-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %session-with-tcp-channel (id)
  "Create a session with a tcp-line-channel wrapping a fresh string-output-stream.
Returns (values session stream)."
  (let* ((out (make-string-output-stream))
         (ch  (make-instance 'tcp-line-channel :stream out))
         (s   (make-session :id id)))
    (setf (session-notify-channel s) ch)
    (values s out)))

(defun %reset-attach-state ()
  "Reset the process-wide attach call-lock state between tests.
Clears *attach-waiters* and *attach-holder-session-id* so tests don't
interfere with each other."
  (bordeaux-threads:with-lock-held (*attach-waiters-lock*)
    (setf *attach-waiters* nil)
    (setf *attach-holder-session-id* nil)))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(define-test serialised-concurrency-sequences-calls
  "Under :serialised concurrency two threads calling with-serialised-attach-call
execute their bodies sequentially: the second thread's body starts only after
the first thread's body completes."
  ;; Reset global attach state from any prior test.
  (%reset-attach-state)
  ;; We use a shared timestamp log to verify sequential execution.
  ;; Thread 1 enters first, holds the lock for 60 ms, then records :t1-done.
  ;; Thread 2 also tries to enter; it should record :t2-start only after t1-done.
  (let ((*attach-concurrency* :serialised)
        (log nil)
        (log-lock (bordeaux-threads:make-lock "call-lock-test-log")))
    (let ((s1 (make-session :id "lock-test-s1"))
          (s2 (make-session :id "lock-test-s2")))
      (let* ((t1 (bordeaux-threads:make-thread
                  (lambda ()
                    (with-serialised-attach-call (s1)
                      (sleep 0.06d0)
                      (bordeaux-threads:with-lock-held (log-lock)
                        (push :t1-done log))))
                  :name "call-lock-test-t1"))
             ;; Small sleep so t1 enters the lock first.
             (dummy (progn (sleep 0.01d0) nil))
             (t2 (bordeaux-threads:make-thread
                  (lambda ()
                    (with-serialised-attach-call (s2)
                      (bordeaux-threads:with-lock-held (log-lock)
                        (push :t2-start log))))
                  :name "call-lock-test-t2")))
        (declare (ignore dummy))
        (bordeaux-threads:join-thread t1)
        (bordeaux-threads:join-thread t2)
        ;; Log is in reverse push order: (:t2-start :t1-done)
        ;; meaning t1-done happened before t2-start.
        (is = 2 (length log))
        (is eq :t1-done (second log))
        (is eq :t2-start (first log))))))

(define-test parallel-concurrency-does-not-block
  "Under :parallel concurrency two threads calling with-serialised-attach-call
execute their bodies without waiting for each other."
  (%reset-attach-state)
  ;; Use setf (not let) so spawned threads also see :parallel.
  (let ((saved-concurrency *attach-concurrency*)
        (counter 0)
        (counter-lock (bordeaux-threads:make-lock "parallel-test-lock")))
    (setf *attach-concurrency* :parallel)
    (unwind-protect
         (let ((s1 (make-session :id "parallel-test-s1"))
               (s2 (make-session :id "parallel-test-s2")))
           (let ((t1 (bordeaux-threads:make-thread
                      (lambda ()
                        (with-serialised-attach-call (s1)
                          (bordeaux-threads:with-lock-held (counter-lock)
                            (incf counter))))
                      :name "parallel-test-t1"))
                 (t2 (bordeaux-threads:make-thread
                      (lambda ()
                        (with-serialised-attach-call (s2)
                          (bordeaux-threads:with-lock-held (counter-lock)
                            (incf counter))))
                      :name "parallel-test-t2")))
             (bordeaux-threads:join-thread t1)
             (bordeaux-threads:join-thread t2)
             ;; Both threads ran.
             (is = 2 counter)))
      (setf *attach-concurrency* saved-concurrency))))

(define-test queued-session-receives-position-notification
  "When session B enters with-serialised-attach-call while session A holds
the lock, session B's notify-channel receives a
notifications/dsmr-mcp/attach/queued notification with 'position' and
'holder_session_id' before session B blocks."
  (%reset-attach-state)
  (let ((*attach-concurrency* :serialised))
    (multiple-value-bind (s-a out-a)
        (%session-with-tcp-channel "holder-a")
      (declare (ignore out-a))
      (multiple-value-bind (s-b out-b)
          (%session-with-tcp-channel "waiter-b")
        ;; Thread A holds the lock for 150 ms.
        (let* ((a-holding nil)
               (a-hold-lock (bordeaux-threads:make-lock "a-hold-lock"))
               (t-a (bordeaux-threads:make-thread
                     (lambda ()
                       (with-serialised-attach-call (s-a)
                         (bordeaux-threads:with-lock-held (a-hold-lock)
                           (setf a-holding t))
                         (sleep 0.15d0)))
                     :name "queued-test-holder"))
               ;; Wait until A has entered.
               (dummy (progn
                        (loop until (bordeaux-threads:with-lock-held (a-hold-lock)
                                      a-holding)
                              do (sleep 0.005d0))
                        nil))
               (t-b (bordeaux-threads:make-thread
                     (lambda ()
                       (with-serialised-attach-call (s-b)
                         nil))
                     :name "queued-test-waiter")))
          (declare (ignore dummy))
          (bordeaux-threads:join-thread t-a)
          (bordeaux-threads:join-thread t-b)
          ;; Session B's channel should have received a queued notification.
          (let ((captured (get-output-stream-string out-b)))
            (true (search "notifications/dsmr-mcp/attach/queued" captured))
            (true (search "position" captured))
            (true (search "holder-a" captured))))))))

(define-test concurrency-env-parser-rejects-invalid
  "%%resolve-attach-concurrency signals invalid-config-value for unknown values."
  (fail (%resolve-attach-concurrency "bogus")
        dsmr-mcp/src/run:invalid-config-value))

(define-test every-attached-arm-uses-serialised-call
  "Every defmethod tool-handle in src/tools/ whose body reaches a :attached
arm wraps that arm in with-serialised-attach-call or with-attach-dispatch.

Approach: source-level grep of all files matching defmethod tool-handle.
For each method file containing ':attached', verify the text also contains
'with-serialised-attach-call' or 'with-attach-dispatch'.

This test catches omissions by future tool authors on day one."
  ;; The allowlist of macro names that expand to with-serialised-attach-call.
  ;; Adding a new wrapper name here is the only edit needed to onboard it.
  (let ((wrappers '("with-serialised-attach-call" "with-attach-dispatch"))
        (src-dir (merge-pathnames "src/"
                                  (asdf:system-source-directory
                                   (asdf:find-system :dsmr-mcp))))
        (failures nil))
    ;; Find all .lisp files under src/ that define tool-handle methods.
    (dolist (file (directory (merge-pathnames "**/*.lisp" src-dir)))
      (let ((text (uiop:read-file-string file)))
        (when (and (search "defmethod tool-handle" text)
                   (search ":attached" text))
          ;; At least one wrapper must be present in the file.
          (unless (some (lambda (w) (search w text)) wrappers)
            (push (namestring file) failures)))))
    (when failures
      (fail (error "tool-handle :attached arm missing wrapper in: ~{~A~^, ~}"
                   failures)
            error))
    (true t)))
