;;;; tests/integration/hermetic/pool-hibernate-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The pool putting a session's worker to disk, proven with real workers.
;;;;
;;;; These cover what the pool decides around a save: which calls make a
;;;; worker hold state, that an idle worker is saved and leaves no crash
;;;; behind, that a worker serving a call, running a thread of its own or
;;;; short of disk is left serving, that a call can never be handed a worker
;;;; that is being stopped or saved, that a worker which dies mid-save is
;;;; replaced with a notice instead of a crash count, that a saved worker
;;;; frees its place in the pool, and that nothing retires a worker for
;;;; being idle.
;;;;
;;;; Every case boots its workers from a worker core (WITH-WORKER-CORE-OR-SKIP)
;;;; and gives them a private XDG_STATE_HOME, so saved cores and the fleet
;;;; log land in a temporary directory that is removed afterwards.

(defpackage #:dsmr-mcp/tests/integration/hermetic/pool-hibernate-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:pool #:dsmr-mcp/src/hermetic/pool))
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool #:get-or-assign-worker
                #:kill-session-worker #:pool-rpc-with-hard-kill
                #:with-session-worker #:hibernate-session-worker
                #:*after-assign-hook* #:*free-disk-bytes-function*
                #:*hibernate-worker-process-function*
                #:*circuit-breaker-map* #:pool-capacity-exceeded
                #:*worker-pool-warmup* #:*max-pool-size*
                #:*health-check-interval-seconds*)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:*worker-core* #:hibernate-worker-process #:worker-ping
                #:hibernate-refusal-token
                #:worker-id #:worker-pid #:worker-state
                #:worker-stateful-p #:worker-spawned-at #:worker-last-activity
                #:worker-in-flight #:worker-spawn-root
                #:worker-hibernate-core-path
                #:worker-last-hibernate-milliseconds
                #:worker-refused-reason #:worker-refused-at
                #:worker-consecutive-missed-pings #:worker-liveness
                #:check-and-clear-reset-notification)
  (:import-from #:dsmr-mcp/src/hermetic/pool-records
                #:server-stem #:owner-directory #:hibernated-core-path)
  (:import-from #:dsmr-mcp/src/bus/hostfiles
                #:fleet-log-path)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-worker-core-or-skip)
  (:import-from #:bordeaux-threads)
  (:import-from #:sb-posix)
  (:import-from #:uiop))

(in-package #:dsmr-mcp/tests/integration/hermetic/pool-hibernate-test)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defvar *state-home* nil
  "The temporary state home of the case being run.")

(defun %make-temp-directory ()
  "Create a fresh private temporary directory and return its pathname."
  (uiop:ensure-directory-pathname
   (string-trim '(#\Newline #\Return #\Space)
                (uiop:run-program '("mktemp" "-d" "-t" "dsmr-pool-hibernate.XXXXXX")
                                  :output :string))))

(defmacro %with-state-home (&body body)
  "Evaluate BODY with XDG_STATE_HOME, and *STATE-HOME*, naming a new temporary
directory. Workers spawned inside inherit it. The variable is restored and the
directory removed afterwards."
  (let ((old (gensym "OLD")))
    `(let* ((*state-home* (%make-temp-directory))
            (,old (sb-posix:getenv "XDG_STATE_HOME")))
       (unwind-protect
            (progn
              (sb-posix:setenv "XDG_STATE_HOME"
                               (uiop:native-namestring *state-home*) 1)
              ,@body)
         (if ,old
             (sb-posix:setenv "XDG_STATE_HOME" ,old 1)
             (sb-posix:unsetenv "XDG_STATE_HOME"))
         (ignore-errors
          (uiop:delete-directory-tree *state-home* :validate t))))))

(defmacro %pool-case ((&key (max-pool-size 4) (health-interval 10.0d0))
                      &body body)
  "Evaluate BODY against a running pool whose workers boot from the test
worker core, with no standbys, at most MAX-POOL-SIZE workers and a health
check every HEALTH-INTERVAL seconds, inside a private state home. The pool is
shut down afterwards whatever happens. Skips when no core can be built."
  (let ((core (gensym "CORE")))
    `(with-worker-core-or-skip (,core)
       (%with-state-home
         (let ((*mode* :hermetic)
               (*error-output* (make-string-output-stream))
               (*worker-core* ,core)
               (*worker-pool-warmup* 0)
               (*max-pool-size* ,max-pool-size)
               (*health-check-interval-seconds* ,health-interval))
           (configure-log4cl-for-server :warn)
           (initialize-pool)
           (unwind-protect (progn ,@body)
             (ignore-errors (shutdown-pool))))))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %eval-on (worker code)
  "Send CODE to WORKER through the pool's call path and return the reply."
  (let ((params (make-hash-table :test 'equal)))
    (setf (gethash "code" params) code)
    (pool-rpc-with-hard-kill worker "worker/eval" params)))

(defun %reply-text (reply)
  "The text of the first content block of REPLY, or \"\"."
  (let ((content (and (hash-table-p reply) (gethash "content" reply))))
    (or (and (vectorp content) (plusp (length content))
             (gethash "text" (aref content 0)))
        "")))

(defun %answer-on (worker form)
  "Evaluate FORM in WORKER wrapped so the reply carries answer=<value>, and
return the reply text."
  (%reply-text
   (%eval-on worker (format nil "(format nil \"answer=~~A\" ~A)" form))))

(defun %answer-in (session form)
  "As %answer-on, on SESSION's worker held for the call."
  (with-session-worker (w session)
    (%answer-on w form)))

(defun %answers-p (text expected)
  "True when TEXT, a reply from %answer-on, carries exactly EXPECTED."
  (and (search (format nil "answer=~A\"" expected) text) t))

(defun %eval (session code)
  "Evaluate CODE on SESSION's worker, held for the call, and return the reply."
  (with-session-worker (w session)
    (%eval-on w code)))

(defun %session-worker (session)
  "The pool's entry for SESSION."
  (bt:with-lock-held (pool::*pool-lock*)
    (gethash session pool::*affinity-map*)))

(defun %process-gone-p (pid)
  "True when PID names no process, or only a zombie waiting to be reaped."
  (let ((stat (ignore-errors
               (uiop:read-file-string (format nil "/proc/~D/stat" pid)))))
    (or (null stat)
        (let ((close (position #\) stat :from-end t)))
          (and close
               (< (+ close 2) (length stat))
               (char= (char stat (+ close 2)) #\Z))))))

(defun %wait-until (seconds predicate)
  "Poll PREDICATE every 0.1 s for up to SECONDS; return its last answer."
  (loop repeat (ceiling seconds 0.1)
        until (funcall predicate)
        do (sleep 0.1))
  (funcall predicate))

(defun %no-crash-recorded (session)
  "Assert that SESSION has neither crash history nor a tripped breaker."
  (false (bt:with-lock-held (pool::*pool-lock*)
           (gethash session pool::*crash-history*))
         "crash history recorded for ~A" session)
  (false (bt:with-lock-held (pool::*pool-lock*)
           (gethash session *circuit-breaker-map*))
         "breaker entry recorded for ~A" session))

;;; ---------------------------------------------------------------------------
;;; Reading a refusal
;;; ---------------------------------------------------------------------------

(define-test a-refusal-is-read-through-the-server-error-prefix
  "The worker's server puts \"Internal error: \" before every handler error, and
the refusal word is read after it, not taken from it."
  (is equal "has-threads"
      (hibernate-refusal-token "Internal error: has-threads: user-sleeper"))
  (is equal "bad-path"
      (hibernate-refusal-token "Internal error: bad-path: /x is not absolute"))
  (is equal "save-timeout" (hibernate-refusal-token "save-timeout: 170")))

;;; ---------------------------------------------------------------------------
;;; What makes a worker stateful
;;; ---------------------------------------------------------------------------

(define-test only-calls-that-can-leave-state-mark-a-worker-stateful
  "A fresh worker is stamped when it spawns; a code-find leaves it stateless,
an eval of a defvar marks it stateful, and no call is left counted in flight."
  (%pool-case ()
    (let ((before (pool::%unix-now))
          (root (let ((e (uiop:getenv "DSMR_PROJECT_ROOT")))
                  (and e (plusp (length e)) e)))
          (held-count nil)
          (w nil))
      (with-session-worker (worker "stateful")
        (setf w worker
              held-count (worker-in-flight worker))
        (let ((params (make-hash-table :test 'equal)))
          (setf (gethash "symbol" params) "cl:car")
          (pool-rpc-with-hard-kill worker "worker/code-find" params)))
      (true (and (integerp (worker-spawned-at w))
                 (<= before (worker-spawned-at w) (pool::%unix-now)))
            "spawned-at ~A" (worker-spawned-at w))
      (true (and (integerp (worker-last-activity w))
                 (>= (worker-last-activity w) (worker-spawned-at w))))
      (is equal root (worker-spawn-root w))
      (is = 1 held-count)
      (is = 0 (worker-in-flight w))
      (false (worker-stateful-p w))
      (%eval "stateful" "(defvar *marked* 1)")
      (true (worker-stateful-p w))
      (is = 0 (worker-in-flight w)))))

;;; ---------------------------------------------------------------------------
;;; Hibernating
;;; ---------------------------------------------------------------------------

(define-test an-idle-worker-hibernates-without-counting-a-crash
  "An idle worker that holds state is saved to a private core under the
server's own directory, its process ends, and no crash is recorded."
  (%pool-case ()
    (%eval "keeper" "(defvar *kept* 42)")
    (let* ((w (%session-worker "keeper"))
           (pid (worker-pid w)))
      (multiple-value-bind (outcome reason) (hibernate-session-worker "keeper")
        (is eq :hibernated outcome "reason ~A" reason))
      (true (%wait-until 5 (lambda () (%process-gone-p pid)))
            "process ~A still running" pid)
      (is eq :hibernated (worker-state w))
      (let ((path (worker-hibernate-core-path w))
            (root (uiop:native-namestring
                   (merge-pathnames "dsmr-mcp/hibernate/" *state-home*))))
        (true (and path (probe-file path)) "no core at ~A" path)
        (when (and path (probe-file path))
          (is = #o600 (logand #o777 (sb-posix:stat-mode (sb-posix:stat path)))))
        (is equal (uiop:native-namestring
                   (hibernated-core-path (server-stem) (worker-id w)))
            path)
        (is equal (uiop:native-namestring (owner-directory (server-stem)))
            (directory-namestring path))
        (true (uiop:string-prefix-p root path) "~A not under ~A" path root))
      (true (plusp (or (worker-last-hibernate-milliseconds w) 0)))
      (%no-crash-recorded "keeper"))))

(define-test a-worker-serving-a-call-is-busy-and-finishes-the-call
  "While a call holds the worker, hibernation answers busy and the call
completes normally."
  (%pool-case ()
    (%eval "busy" "(+ 1 1)")
    (let* ((w (%session-worker "busy"))
           (thread (bt:make-thread
                    (lambda ()
                      (handler-case
                          (%reply-text (%eval "busy" "(progn (sleep 3) :finished)"))
                        (error (e) (princ-to-string e))))
                    :name "busy-call")))
      (true (%wait-until 5 (lambda () (= 1 (worker-in-flight w))))
            "the call never took the worker")
      (multiple-value-bind (outcome reason) (hibernate-session-worker "busy")
        (is eq :busy outcome)
        (is equal "busy" reason))
      (is eq :bound (worker-state w))
      (let ((text (bt:join-thread thread)))
        (true (search "FINISHED" text) "~A" text))
      (is equal "busy" (worker-refused-reason w))
      (%no-crash-recorded "busy"))))

(define-test a-call-whose-worker-is-stopped-before-it-is-held-gets-a-fresh-one
  "A worker stopped between being assigned and being held for a call, as a
pressure stop would, is never used: the call is answered by a new worker and
no crash is recorded."
  (%pool-case ()
    (%eval "race" "(+ 1 1)")
    (let ((first-id (worker-id (%session-worker "race")))
          (passes 0)
          (kills 0)
          (answered-by nil)
          (had-reset :unset)
          (text nil))
      (let ((*after-assign-hook*
              (lambda (worker)
                (declare (ignore worker))
                (incf passes)
                (when (= passes 1)
                  (incf kills)
                  (kill-session-worker "race")))))
        (with-session-worker (w "race")
          (setf answered-by (worker-id w)
                had-reset (check-and-clear-reset-notification w)
                text (%answer-on w "(+ 40 2)"))))
      (true (%answers-p text 42) "~A" text)
      (true (/= first-id answered-by))
      (false had-reset)
      (is = 1 kills)
      (is = 2 passes)
      (%no-crash-recorded "race"))))

(define-test a-ping-queued-behind-a-save-is-skipped
  "A liveness ping started while a save is under way, or waiting on the
worker's channel behind it, records nothing, and the worker ends hibernated."
  (%pool-case ()
    (%eval "pinged" "(defvar *kept* 1)")
    (let* ((w (%session-worker "pinged"))
           (liveness-before (worker-liveness w))
           (idle-thread nil)
           (queued-thread nil))
      (let ((*hibernate-worker-process-function*
              (lambda (worker path &rest keys)
                (setf idle-thread
                      (bt:make-thread
                       (lambda () (pool::%ping-idle-worker worker))
                       :name "idle-ping"))
                (sleep 2)
                (setf queued-thread
                      (bt:make-thread
                       (lambda ()
                         (sleep 0.2)
                         (handler-case
                             (worker-ping worker
                                          :timeout 2
                                          :eligible-p #'pool::%ping-eligible-p)
                           (error (e) e)))
                       :name "queued-ping"))
                (apply #'hibernate-worker-process worker path keys))))
        (multiple-value-bind (outcome reason) (hibernate-session-worker "pinged")
          (is eq :hibernated outcome "reason ~A" reason)))
      (let ((idle (bt:join-thread idle-thread))
            (queued (bt:join-thread queued-thread)))
        (false idle)
        (is eq :skipped queued "queued ping answered ~A" queued))
      (is = 0 (worker-consecutive-missed-pings w))
      (is eq liveness-before (worker-liveness w))
      (is eq :hibernated (worker-state w))
      (%no-crash-recorded "pinged"))))

(define-test a-worker-that-dies-while-saving-is-replaced-with-a-notice
  "A worker killed during its save leaves no core; the session's next call is
answered by a new worker whose reset notice says why, a fleet line records it,
and no crash is counted."
  (%pool-case ()
    (%eval "doomed" "(defvar *kept* 1)")
    (let* ((w (%session-worker "doomed"))
           (old-id (worker-id w))
           (path (hibernated-core-path (server-stem) old-id)))
      (let ((*hibernate-worker-process-function*
              (lambda (worker core-path &rest keys)
                (declare (ignore core-path keys))
                (sb-posix:kill (worker-pid worker) sb-posix:sigkill)
                (%wait-until 5 (lambda () (%process-gone-p (worker-pid worker))))
                (values :died nil))))
        (multiple-value-bind (outcome reason) (hibernate-session-worker "doomed")
          (is eq :died outcome "reason ~A" reason)))
      (false (probe-file path))
      (let ((had nil) (reason nil) (new-id nil) (text nil))
        (with-session-worker (nw "doomed")
          (multiple-value-setq (had reason)
            (check-and-clear-reset-notification nw))
          (setf new-id (worker-id nw)
                text (%answer-on nw "(+ 1 1)")))
        (true had)
        (true (and reason (search "died while hibernating" reason)) "~A" reason)
        (true (/= old-id new-id))
        (true (%answers-p text 2) "~A" text))
      (%no-crash-recorded "doomed")
      (let ((log (ignore-errors (uiop:read-file-string (fleet-log-path)))))
        (true (and log (search "code=worker-hibernate-died" log)) "~A" log)))))

(define-test a-save-whose-answer-comes-too-late-never-returns-the-worker-to-service
  "When the worker's answer to a save comes later than the pool waits, the
worker may still be saving, so it is never put back to serving: its process is
ended, and the session's next call is answered either by the same worker with
its world back, when the save had finished, or by a fresh worker whose reset
notice says why. No crash is counted either way."
  (%pool-case ()
    (%eval "late" "(defvar *kept* 1)")
    (let* ((w (%session-worker "late"))
           (old-id (worker-id w))
           (old-pid (worker-pid w))
           (outcome nil))
      ;; The pool's wait is cut far below any save, so the worker's answer
      ;; arrives after the pool has stopped waiting for it.
      (let ((*hibernate-worker-process-function*
              (lambda (worker core-path &rest keys)
                (declare (ignore keys))
                (hibernate-worker-process worker core-path :timeout 0.05))))
        (multiple-value-bind (result reason) (hibernate-session-worker "late")
          (setf outcome result)
          (true (member result '(:timeout :hibernated)) "outcome ~A ~A" result reason)))
      (false (eq :bound (worker-state w)) "the worker went back to serving")
      (true (%wait-until 5 (lambda () (%process-gone-p old-pid)))
            "the worker's process is still running")
      (let ((had nil) (reason nil) (new-id nil) (text nil))
        (with-session-worker (nw "late")
          (multiple-value-setq (had reason)
            (check-and-clear-reset-notification nw))
          (setf new-id (worker-id nw)
                text (%answer-on nw "(+ 1 1)")))
        (true (%answers-p text 2) "~A" text)
        (if (eq outcome :timeout)
            (progn
              (true had)
              (true (and reason (search "stopped answering" reason)) "~A" reason)
              (true (/= old-id new-id)))
            (progn
              (false had)
              (is = old-id new-id))))
      (%no-crash-recorded "late")
      ;; The save the worker started may still be writing its partial core;
      ;; let it finish before the state home is removed.
      (let ((tmp (concatenate 'string
                              (uiop:native-namestring
                               (hibernated-core-path (server-stem) old-id))
                              ".tmp")))
        (%wait-until 20 (lambda ()
                          (let ((a (ignore-errors (sb-posix:stat-size (sb-posix:stat tmp)))))
                            (sleep 0.5)
                            (eql a (ignore-errors
                                    (sb-posix:stat-size (sb-posix:stat tmp)))))))))))

(define-test a-worker-running-a-session-thread-refuses-and-keeps-serving
  "A worker running a thread the session started refuses with has-threads,
keeps the reason, and still answers."
  (%pool-case ()
    (%eval "threaded"
           "(progn (sb-thread:make-thread (lambda () (sleep 600)) :name \"user-sleeper\") t)")
    (let ((w (%session-worker "threaded")))
      (multiple-value-bind (outcome reason) (hibernate-session-worker "threaded")
        (is eq :refused outcome)
        (is equal "has-threads" reason))
      (is eq :bound (worker-state w))
      (is equal "has-threads" (worker-refused-reason w))
      (true (integerp (worker-refused-at w)))
      (true (%answers-p (%answer-in "threaded" "(+ 1 2)") 3))
      (%no-crash-recorded "threaded"))))

(define-test too-little-free-disk-refuses-and-writes-nothing
  "Without twice the expected core size free, the worker is left serving and
nothing is written."
  (%pool-case ()
    (%eval "cramped" "(defvar *kept* 7)")
    (let ((w (%session-worker "cramped")))
      (let ((*free-disk-bytes-function* (constantly 1)))
        (multiple-value-bind (outcome reason) (hibernate-session-worker "cramped")
          (is eq :disk outcome)
          (is equal "disk" reason)))
      (is eq :bound (worker-state w))
      (is equal "disk" (worker-refused-reason w))
      (is equal '() (uiop:directory-files (owner-directory (server-stem))))
      (true (%answers-p (%answer-in "cramped" "*kept*") 7)))))

(define-test a-hibernated-worker-gives-up-its-place-in-the-pool
  "At the size limit a new session is refused; once one worker is hibernated
the new session gets a worker."
  (%pool-case (:max-pool-size 2)
    (%eval "cap-a" "(defvar *kept* 1)")
    (%eval "cap-b" "(+ 1 1)")
    (true (handler-case (progn (get-or-assign-worker "cap-c") nil)
            (pool-capacity-exceeded () t))
          "a third session was given a worker at the limit")
    (is eq :hibernated (hibernate-session-worker "cap-a"))
    (is eq :bound (worker-state (get-or-assign-worker "cap-c")))))

;;; ---------------------------------------------------------------------------
;;; Idleness and the health check
;;; ---------------------------------------------------------------------------

(define-test an-idle-worker-is-never-reaped-for-idleness
  "A bound worker last used ten days ago survives the health check with its
process and its world."
  (%pool-case (:health-interval 0.2d0)
    (%eval "idle" "(defvar *kept* 42)")
    (let ((w (%session-worker "idle")))
      (bt:with-lock-held (pool::*pool-lock*)
        (setf (worker-last-activity w) (- (pool::%unix-now) (* 10 24 60 60))))
      (pool::%check-worker-liveness (list w))
      (sleep 1)
      (true (pool::%worker-process-alive-p w))
      (is eq :bound (worker-state w))
      (is eq w (%session-worker "idle"))
      (true (%answers-p (%answer-in "idle" "*kept*") 42)))))

(define-test the-health-check-leaves-a-hibernated-worker-alone
  "The health check over a hibernated worker records no crash and leaves it
hibernated and bound to its session."
  (%pool-case (:health-interval 0.2d0)
    (%eval "resting" "(defvar *kept* 1)")
    (let ((w (%session-worker "resting")))
      (is eq :hibernated (hibernate-session-worker "resting"))
      (pool::%check-worker-liveness (list w))
      (sleep 1)
      (is eq :hibernated (worker-state w))
      (is eq w (%session-worker "resting"))
      (false (bt:with-lock-held (pool::*pool-lock*) pool::*recovery-threads*))
      (%no-crash-recorded "resting"))))
