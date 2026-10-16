;;;; tests/integration/hermetic/pool-resume-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The pool bringing a hibernated session back, proven with real workers.
;;;;
;;;; These cover what a session sees after its worker was saved to disk: its
;;;; next request is answered by the same worker with the world it had and no
;;;; reset notice, requests that arrive while the worker is saving or resuming
;;;; wait for it and all get that one worker, a core that cannot be resumed is
;;;; kept, reported and replaced with a notice saying why, resuming respects
;;;; the pool size, and every saved core is deleted once nothing needs it.
;;;;
;;;; Every case boots its workers from a worker core (WITH-WORKER-CORE-OR-SKIP)
;;;; and gives them a private XDG_STATE_HOME, so saved cores and the fleet
;;;; log land in a temporary directory that is removed afterwards.

(defpackage #:dsmr-mcp/tests/integration/hermetic/pool-resume-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:pool #:dsmr-mcp/src/hermetic/pool))
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool #:get-or-assign-worker
                #:release-session #:kill-session-worker
                #:pool-rpc-with-hard-kill
                #:with-session-worker #:hibernate-session-worker
                #:*after-assign-hook* #:*hibernate-worker-process-function*
                #:*circuit-breaker-map* #:pool-capacity-exceeded
                #:pool-resume-deferred
                #:*worker-pool-warmup* #:*max-pool-size*
                #:*health-check-interval-seconds*)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:*worker-core* #:hibernate-worker-process
                #:worker-id #:worker-pid #:worker-state #:worker-boot-kind
                #:worker-hibernate-core-path
                #:worker-last-resume-milliseconds
                #:check-and-clear-reset-notification
                #:worker-runtime-path #:worker-runtime-identity
                #:runtime-identity #:*resolved-worker-resume-timeout*)
  (:import-from #:dsmr-mcp/src/hermetic/pool-records
                #:server-stem #:owner-directory #:hibernate-root
                #:failed-core-directory)
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

(in-package #:dsmr-mcp/tests/integration/hermetic/pool-resume-test)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defvar *state-home* nil
  "The temporary state home of the case being run.")

(defun %make-temp-directory ()
  "Create a fresh private temporary directory and return its pathname."
  (uiop:ensure-directory-pathname
   (string-trim '(#\Newline #\Return #\Space)
                (uiop:run-program '("mktemp" "-d" "-t" "dsmr-pool-resume.XXXXXX")
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

(defmacro %pool-case ((&key (max-pool-size 4)) &body body)
  "Evaluate BODY against a running pool whose workers boot from the test
worker core, with no standbys and at most MAX-POOL-SIZE workers, inside a
private state home. The pool is shut down afterwards whatever happens. Skips
when no core can be built."
  (let ((core (gensym "CORE")))
    `(with-worker-core-or-skip (,core)
       (%with-state-home
         (let ((*mode* :hermetic)
               (*error-output* (make-string-output-stream))
               (*worker-core* ,core)
               (*worker-pool-warmup* 0)
               (*max-pool-size* ,max-pool-size)
               (*health-check-interval-seconds* 10.0d0))
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

(defun %join-within (thread seconds)
  "Join THREAD when it finishes within SECONDS and return its value, or
:still-running when it does not."
  (if (%wait-until seconds (lambda () (not (bt:thread-alive-p thread))))
      (bt:join-thread thread)
      :still-running))

(defun %no-crash-recorded (session)
  "Assert that SESSION has neither crash history nor a tripped breaker."
  (false (bt:with-lock-held (pool::*pool-lock*)
           (gethash session pool::*crash-history*))
         "crash history recorded for ~A" session)
  (false (bt:with-lock-held (pool::*pool-lock*)
           (gethash session *circuit-breaker-map*))
         "breaker entry recorded for ~A" session))

(defun %hibernated-core (session)
  "Hibernate SESSION's worker and return the path of its saved core, asserting
that the save succeeded."
  (multiple-value-bind (outcome reason) (hibernate-session-worker session)
    (is eq :hibernated outcome "reason ~A" reason))
  (let ((path (worker-hibernate-core-path (%session-worker session))))
    (true (and path (probe-file path)) "no core at ~A" path)
    path))

(defun %fleet-log ()
  "The fleet error log's text, or NIL when there is none."
  (ignore-errors (uiop:read-file-string (fleet-log-path))))

(defun %live-session-workers ()
  "The workers the pool tracks whose processes are running."
  (bt:with-lock-held (pool::*pool-lock*)
    (remove-if-not #'pool::%worker-process-alive-p pool::*all-workers*)))

;;; ---------------------------------------------------------------------------
;;; Transparent resume
;;; ---------------------------------------------------------------------------

(define-test a-hibernated-session-gets-its-world-back-on-its-next-request
  "The next request after a save is answered by the same worker, with the same
id, from a process resumed from its core: values, closures and object ids are
intact, there is no reset notice, and the core is gone."
  (%pool-case ()
    (%eval "keeper" "(defvar *kept* (list 1 2 3))")
    (%eval "keeper" "(defvar *counter* (let ((n 0)) (lambda () (incf n))))")
    (%eval "keeper" "(funcall *counter*)")
    (%eval "keeper" "(funcall *counter*)")
    (let* ((object-id (gethash "result_object_id" (%eval "keeper" "(list :kept-object 42)")))
           (w (%session-worker "keeper"))
           (id (worker-id w))
           (old-pid (worker-pid w))
           (path (%hibernated-core "keeper")))
      (true (integerp object-id) "object id ~S" object-id)
      (true (%wait-until 5 (lambda () (%process-gone-p old-pid))))
      (let ((r (get-or-assign-worker "keeper")))
        (is eq w r)
        (is = id (worker-id r))
        (is eq :bound (worker-state r))
        (is eq :resumed (worker-boot-kind r))
        (true (/= old-pid (worker-pid r)))
        (false (check-and-clear-reset-notification r))
        (true (%answers-p (%answer-in "keeper" "(equal *kept* (list 1 2 3))") "T"))
        (true (%answers-p (%answer-in "keeper" "(funcall *counter*)") 3))
        (let ((reply (with-session-worker (x "keeper")
                       (let ((params (make-hash-table :test 'equal)))
                         (setf (gethash "id" params) object-id)
                         (pool-rpc-with-hard-kill x "worker/inspect-object" params)))))
          (true (hash-table-p reply))
          (false (and (hash-table-p reply) (gethash "error" reply)) "~S" reply))
        (false (probe-file path))
        (false (probe-file (concatenate 'string path ".tmp")))
        (false (worker-hibernate-core-path r))
        (let ((ms (worker-last-resume-milliseconds r)))
          (format t "~&warm resume: ~A ms~%" ms)
          (true (and (integerp ms) (< ms 1000)) "warm resume took ~A ms" ms)))
      (%no-crash-recorded "keeper"))))

(define-test a-call-whose-worker-is-saved-before-it-is-held-gets-its-world-back
  "A worker saved between being assigned and being held for a call is never
used while saved: the call is answered by the same worker resumed from its
core, with no reset notice and no crash recorded."
  (%pool-case ()
    (%eval "race" "(defvar *kept* (list 1 2 3))")
    (let ((w (%session-worker "race"))
          (passes 0)
          (saves 0)
          (outcome nil)
          (answered-by nil)
          (had-reset :unset)
          (text nil))
      (let ((*after-assign-hook*
              (lambda (worker)
                (declare (ignore worker))
                (incf passes)
                (when (= passes 1)
                  (incf saves)
                  (setf outcome (hibernate-session-worker "race"))))))
        (with-session-worker (x "race")
          (setf answered-by x
                had-reset (check-and-clear-reset-notification x)
                text (%answer-on x "(equal *kept* (list 1 2 3))"))))
      (is eq :hibernated outcome)
      (is = 1 saves)
      (is = 2 passes)
      (is eq w answered-by)
      (is eq :resumed (worker-boot-kind w))
      (false had-reset)
      (true (%answers-p text "T") "~A" text)
      (%no-crash-recorded "race"))))

;;; ---------------------------------------------------------------------------
;;; Concurrency
;;; ---------------------------------------------------------------------------

(define-test requests-during-a-save-wait-and-share-the-resumed-worker
  "Four calls arriving while the worker is saving all wait, are answered by
the same worker resumed once, and leave exactly one live process and no crash."
  (%pool-case ()
    (%eval "crowd" "(defvar *kept* 1)")
    (let* ((w (%session-worker "crowd"))
           (old-pid (worker-pid w))
           (threads nil)
           (outcome nil))
      (let ((*hibernate-worker-process-function*
              (lambda (worker path &rest keys)
                (setf threads
                      (loop for i below 4
                            collect (bt:make-thread
                                     (lambda ()
                                       (handler-case
                                           (with-session-worker (x "crowd")
                                             (list x (%answer-on x "(+ 20 22)")))
                                         (error (e) (princ-to-string e))))
                                     :name (format nil "crowd-~D" i))))
                ;; Let every call reach the pool while the worker is saving.
                (sleep 1)
                (apply #'hibernate-worker-process worker path keys))))
        (setf outcome (hibernate-session-worker "crowd")))
      (is eq :hibernated outcome)
      (let ((results (mapcar (lambda (th) (%join-within th 120)) threads)))
        (is = 4 (length results))
        (dolist (r results)
          (true (and (consp r) (eq w (first r))) "answered by ~S" r)
          (true (and (consp r) (%answers-p (second r) 42)) "~S" r)))
      (is eq :bound (worker-state w))
      (is eq :resumed (worker-boot-kind w))
      (true (/= old-pid (worker-pid w)))
      (true (%process-gone-p old-pid))
      (is equal (list w) (%live-session-workers))
      (%no-crash-recorded "crowd"))))

(define-test requests-to-a-hibernated-session-start-one-process
  "Four requests arriving together for a hibernated session all get the same
worker, and only one process is started for them."
  (%pool-case ()
    (%eval "herd" "(defvar *kept* 1)")
    (let* ((w (%session-worker "herd"))
           (old-pid (worker-pid w))
           (go-flag nil))
      (%hibernated-core "herd")
      (let* ((threads (loop for i below 4
                            collect (bt:make-thread
                                     (lambda ()
                                       (loop until go-flag do (sleep 0.001))
                                       (handler-case
                                           (let ((x (get-or-assign-worker "herd")))
                                             (list x (worker-pid x)))
                                         (error (e) (princ-to-string e))))
                                     :name (format nil "herd-~D" i))))
             (results (progn (setf go-flag t)
                             (mapcar (lambda (th) (%join-within th 120)) threads))))
        (dolist (r results)
          (true (and (consp r) (eq w (first r))) "got ~S" r))
        (let ((pids (remove-duplicates (mapcar (lambda (r) (and (consp r) (second r)))
                                               results))))
          (is = 1 (length pids) "pids ~S" pids)
          (true (/= old-pid (first pids)))))
      (is equal (list w) (%live-session-workers))
      (true (%answers-p (%answer-in "herd" "*kept*") 1))
      (%no-crash-recorded "herd"))))

;;; ---------------------------------------------------------------------------
;;; A world that cannot come back
;;; ---------------------------------------------------------------------------

(define-test a-corrupt-core-is-kept-reported-and-replaced-with-a-notice
  "A core that no process can start from is moved to the failed directory, a
fleet line records it, and the session gets a fresh worker whose reset notice
says its world could not be resumed. No crash is counted."
  (%pool-case ()
    (%eval "corrupt" "(defvar *kept* 1)")
    (let* ((old-id (worker-id (%session-worker "corrupt")))
           (path (%hibernated-core "corrupt")))
      (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                                :if-exists :supersede)
        (write-sequence (make-array 4096 :element-type '(unsigned-byte 8)
                                         :initial-element 0)
                        out))
      (let ((r (get-or-assign-worker "corrupt")))
        (true (/= old-id (worker-id r)))
        (is eq :bound (worker-state r))
        (multiple-value-bind (had reason) (check-and-clear-reset-notification r)
          (true had)
          (true (and reason (search "could not be resumed" reason)) "~A" reason)))
      (false (probe-file path))
      (is = 1 (length (uiop:directory-files (failed-core-directory))))
      (let ((log (%fleet-log)))
        (true (and log (search "code=worker-resume-failed" log)) "~A" log))
      (true (%answers-p (%answer-in "corrupt" "(+ 1 1)") 2))
      (%no-crash-recorded "corrupt"))))

(define-test a-missing-core-is-reported-and-replaced-with-a-notice
  "When the saved core has gone, the session gets a fresh worker whose reset
notice names the missing file, and a fleet line records it."
  (%pool-case ()
    (%eval "vanished" "(defvar *kept* 1)")
    (let* ((old-id (worker-id (%session-worker "vanished")))
           (path (%hibernated-core "vanished")))
      (delete-file path)
      (let ((r (get-or-assign-worker "vanished")))
        (true (/= old-id (worker-id r)))
        (multiple-value-bind (had reason) (check-and-clear-reset-notification r)
          (true had)
          (true (and reason (search "could not be resumed" reason)) "~A" reason)
          (true (and reason (search (file-namestring path) reason)) "~A" reason)))
      (let ((log (%fleet-log)))
        (true (and log (search "code=worker-resume-failed" log)) "~A" log))
      (%no-crash-recorded "vanished"))))

(define-test a-resume-that-may-pass-keeps-the-world-for-the-next-call
  "A resume whose handshake runs out of time gives nothing up: that call fails
with an error saying the world is still saved, the worker stays hibernated
with its core in place, nothing is kept as failed or written to the fleet
log, and the next call resumes the same worker with its world."
  (%pool-case ()
    (%eval "flaky" "(defvar *kept* (list 1 2 3))")
    (let* ((w (%session-worker "flaky"))
           (id (worker-id w))
           (path (%hibernated-core "flaky")))
      ;; No handshake can arrive this soon.
      (let ((*resolved-worker-resume-timeout* 0.001))
        (let ((condition (handler-case (progn (get-or-assign-worker "flaky") nil)
                           (pool-resume-deferred (c) c))))
          (true condition "the call did not fail as one to retry")
          (true (and condition (search "still saved" (princ-to-string condition)))
                "~A" condition)))
      (is eq :hibernated (worker-state w))
      (is eq w (%session-worker "flaky"))
      (true (probe-file path) "the core was given up")
      (false (uiop:directory-files (failed-core-directory)))
      (let ((log (%fleet-log)))
        (false (and log (search "code=worker-resume-failed" log)) "~A" log))
      (let ((r (get-or-assign-worker "flaky")))
        (is eq w r)
        (is = id (worker-id r))
        (is eq :resumed (worker-boot-kind r))
        (false (check-and-clear-reset-notification r)))
      (true (%answers-p (%answer-in "flaky" "(equal *kept* (list 1 2 3))") "T"))
      (%no-crash-recorded "flaky"))))

(define-test a-resume-starts-the-runtime-that-wrote-the-core
  "A worker records the runtime it was started with, and its saved world is
resumed with that runtime, not with whatever this process would start a fresh
worker with. When that runtime is gone and this server's own executable is the
same file, the world is resumed with the server's executable."
  (%pool-case ()
    (%eval "runtime" "(defvar *kept* 9)")
    (let* ((w (%session-worker "runtime"))
           (recorded (worker-runtime-path w))
           (own (format nil "/proc/~D/exe" (sb-posix:getpid))))
      (true (and recorded (char= #\/ (char recorded 0))) "recorded ~A" recorded)
      (is equal (runtime-identity recorded) (worker-runtime-identity w))
      (%hibernated-core "runtime")
      ;; The record names a link to the same runtime, and a fresh worker
      ;; would be started from a path that does not exist, so only the
      ;; recorded runtime can bring the world back.
      (let* ((dir (merge-pathnames "runtime-link/" *state-home*))
             (link (uiop:native-namestring (merge-pathnames "sbcl" dir))))
        (ensure-directories-exist dir)
        (sb-posix:symlink recorded link)
        (bt:with-lock-held (pool::*pool-lock*)
          (setf (worker-runtime-path w) link))
        (let ((dsmr-mcp/src/hermetic/worker-client::*cached-sbcl-path*
                "/nonexistent-runtime/sbcl"))
          (let ((r (get-or-assign-worker "runtime")))
            (is eq w r)
            (is eq :resumed (worker-boot-kind r))
            (is string= link (worker-runtime-path r))
            (let ((argv0 (first (uiop:split-string
                                 (uiop:read-file-string
                                  (format nil "/proc/~D/cmdline" (worker-pid r)))
                                 :separator (string (code-char 0))))))
              (is string= link argv0)))))
      (true (%answers-p (%answer-in "runtime" "*kept*") 9))
      ;; The recorded runtime replaced by another file, as a package upgrade
      ;; does, while this server still runs the one that wrote the core.
      (true (equal (runtime-identity recorded) (runtime-identity own))
            "this test process does not run the workers' runtime ~A" recorded)
      (%hibernated-core "runtime")
      (bt:with-lock-held (pool::*pool-lock*)
        (setf (worker-runtime-path w) "/nonexistent-runtime/sbcl"
              (worker-runtime-identity w) (runtime-identity own)))
      (let ((r (get-or-assign-worker "runtime")))
        (is eq w r)
        (is eq :resumed (worker-boot-kind r))
        (is string= own (worker-runtime-path r)))
      (true (%answers-p (%answer-in "runtime" "*kept*") 9))
      (%no-crash-recorded "runtime"))))

;;; ---------------------------------------------------------------------------
;;; The pool size
;;; ---------------------------------------------------------------------------

(define-test resuming-at-the-size-limit-is-refused-and-stays-hibernated
  "With the pool full, a request for a hibernated session is refused and the
worker stays hibernated with its core on disk."
  (%pool-case (:max-pool-size 1)
    (%eval "cap-a" "(defvar *kept* 1)")
    (let ((path (%hibernated-core "cap-a")))
      (%eval "cap-b" "(+ 1 1)")
      (true (handler-case (progn (get-or-assign-worker "cap-a") nil)
              (pool-capacity-exceeded () t))
            "a hibernated session resumed past the limit")
      (is eq :hibernated (worker-state (%session-worker "cap-a")))
      (true (probe-file path)))))

;;; ---------------------------------------------------------------------------
;;; Cleanup
;;; ---------------------------------------------------------------------------

(define-test releasing-or-killing-a-hibernated-session-deletes-its-core
  "A hibernated worker's core is deleted when its session is released, and
when its worker is killed."
  (%pool-case ()
    (%eval "released" "(defvar *kept* 1)")
    (let ((path (%hibernated-core "released")))
      (release-session "released")
      (false (probe-file path)))
    (%eval "killed" "(defvar *kept* 1)")
    (let ((path (%hibernated-core "killed")))
      (is eq :killed (kill-session-worker "killed"))
      (false (probe-file path)))))

(define-test shutting-down-the-pool-removes-its-core-directory
  "Shutting the pool down removes the server's own core directory with every
core in it."
  (%pool-case ()
    (%eval "parked" "(defvar *kept* 1)")
    (%hibernated-core "parked")
    (let ((dir (uiop:native-namestring (owner-directory (server-stem)))))
      (true (probe-file dir))
      (shutdown-pool)
      (false (probe-file dir)))))

(define-test starting-the-pool-sweeps-what-dead-servers-left
  "A core directory left by a server that is no longer running is removed
when the pool starts."
  (%pool-case ()
    (let* ((dir (merge-pathnames "999999999-1/" (hibernate-root)))
           (file (merge-pathnames "7.core" dir)))
      (ensure-directories-exist file)
      (with-open-file (out file :direction :output :if-exists :supersede)
        (write-string "left behind" out))
      (true (probe-file file))
      (initialize-pool)
      (false (probe-file file))
      (false (probe-file (uiop:native-namestring dir))))))

(define-test a-cold-resume-brings-the-world-back
  "A core dropped from the page cache still resumes with the world it saved;
how long that took is printed, with no bound promised."
  (%pool-case ()
    (%eval "cold" "(defvar *kept* (list 4 5 6))")
    (let ((path (%hibernated-core "cold")))
      (uiop:run-program (list "dd" (format nil "if=~A" path) "iflag=nocache"
                              "count=0" "status=none")
                        :ignore-error-status t)
      (let ((r (get-or-assign-worker "cold")))
        (is eq :resumed (worker-boot-kind r))
        (false (check-and-clear-reset-notification r))
        (format t "~&cold resume: ~A ms~%" (worker-last-resume-milliseconds r))
        (true (integerp (worker-last-resume-milliseconds r))))
      (true (%answers-p (%answer-in "cold" "(equal *kept* (list 4 5 6))") "T")))))
