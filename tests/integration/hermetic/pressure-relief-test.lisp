;;;; tests/integration/hermetic/pressure-relief-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Memory pressure relief proven end to end: the host service's memory duty
;;;; and a real session pool, in one process, sharing one state home.
;;;;
;;;; The service is handed a memory reading that says the host is short, and
;;;; its memory duty is run once a second against the wall clock, exactly as
;;;; its supervisor would run it; no broker is started, because nothing here
;;;; needs a bus. The pool answers through the files the two share. The case
;;;; checks that the service asks for the fresh worker first and the stateful
;;;; one after, that it says so in the fleet log and in its status summary, that
;;;; calm ends the episode, and that both sessions carry on afterwards: the
;;;; saved one with its world, the stopped one with a fresh worker, neither with
;;;; a reset notice nor a crash.
;;;;
;;;; Workers boot from a worker core (WITH-WORKER-CORE-OR-SKIP), and the case
;;;; runs under a private XDG_STATE_HOME removed afterwards.

(defpackage #:dsmr-mcp/tests/integration/hermetic/pressure-relief-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:pool #:dsmr-mcp/src/hermetic/pool)
                    (#:service #:dsmr-bus-host/src/bus/host/main)
                    (#:memory #:dsmr-bus-host/src/bus/host/memory)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles))
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool #:get-or-assign-worker
                #:pool-rpc-with-hard-kill #:with-session-worker
                #:*circuit-breaker-map*
                #:*pressure-kill-min-age-seconds* #:*pressure-agent-interval*
                #:*worker-pool-warmup* #:*max-pool-size*
                #:*health-check-interval-seconds*)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:*worker-core* #:worker-state #:worker-stateful-p #:worker-id
                #:check-and-clear-reset-notification)
  (:import-from #:dsmr-mcp/src/hermetic/pool-records
                #:server-stem #:worker-record-path #:read-worker-record)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-worker-core-or-skip)
  (:import-from #:bordeaux-threads)
  (:import-from #:sb-posix)
  (:import-from #:uiop))

(in-package #:dsmr-mcp/tests/integration/hermetic/pressure-relief-test)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defun %make-temp-directory ()
  "Create a fresh private temporary directory and return its pathname."
  (uiop:ensure-directory-pathname
   (string-trim '(#\Newline #\Return #\Space)
                (uiop:run-program '("mktemp" "-d" "-t" "dsmr-pressure-relief.XXXXXX")
                                  :output :string))))

(defmacro %relief-case (&body body)
  "Evaluate BODY against a running pool whose workers boot from the test worker
core, with no standbys, no minimum stop age and a pressure agent ticking every
second, inside a private state home where the fleet and service logs are
installed. The pool is shut down, the logs taken down and the state home
removed afterwards. Skips when no core can be built."
  (let ((core (gensym "CORE"))
        (home (gensym "HOME"))
        (old (gensym "OLD")))
    `(with-worker-core-or-skip (,core)
       (let ((,home (%make-temp-directory))
             (,old (sb-posix:getenv "XDG_STATE_HOME")))
         (unwind-protect
              (progn
                (sb-posix:setenv "XDG_STATE_HOME" (uiop:native-namestring ,home) 1)
                (fleetlog:install-fleet-log
                 :path (hostfiles:fleet-log-path)
                 :service-log-path (merge-pathnames "service.log" (hostfiles:host-dir)))
                (let ((*mode* :hermetic)
                      (*error-output* (make-string-output-stream))
                      (*worker-core* ,core)
                      (*worker-pool-warmup* 0)
                      (*max-pool-size* 4)
                      (*health-check-interval-seconds* 10.0d0)
                      (*pressure-kill-min-age-seconds* 0)
                      (*pressure-agent-interval* 1)
                      (conditions:*breakers* (make-hash-table :test 'equal
                                                              :synchronized t)))
                  (configure-log4cl-for-server :warn)
                  (unwind-protect
                       (progn (initialize-pool) ,@body)
                    (ignore-errors (shutdown-pool)))))
           (ignore-errors (fleetlog:remove-fleet-log))
           (if ,old
               (sb-posix:setenv "XDG_STATE_HOME" ,old 1)
               (sb-posix:unsetenv "XDG_STATE_HOME"))
           (ignore-errors (uiop:delete-directory-tree ,home :validate t)))))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %unix-now ()
  "The current time in Unix seconds."
  (- (get-universal-time) 2208988800))

(defun %readings (available-percent)
  "A memory reading with AVAILABLE-PERCENT of a 1 GB host available and no
stalls."
  (memory:make-memory-readings :some-avg10 0.0 :full-avg10 0.0
                               :mem-total-kb 1000000
                               :mem-available-kb (* 10000 available-percent)))

(defun %check (svc now)
  "Run SVC's memory duty at NOW the way its supervisor does."
  (service::%duty svc "memory" (lambda () (service::%check-memory svc now))
                  :subject "host"))

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

(defun %answer-in (session form)
  "Evaluate FORM on SESSION's worker, wrapped so the reply carries
answer=<value>, and return the reply text."
  (with-session-worker (w session)
    (%reply-text
     (%eval-on w (format nil "(format nil \"answer=~~A\" ~A)" form)))))

(defun %answers-p (text expected)
  "True when TEXT, a reply from %answer-in, carries exactly EXPECTED."
  (and (search (format nil "answer=~A\"" expected) text) t))

(defun %code-find-in (session)
  "Look a symbol up on SESSION's worker, a call that leaves no state behind."
  (with-session-worker (w session)
    (let ((params (make-hash-table :test 'equal)))
      (setf (gethash "symbol" params) "cl:car")
      (pool-rpc-with-hard-kill w "worker/code-find" params))))

(defun %session-worker (session)
  "The pool's entry for SESSION."
  (bt:with-lock-held (pool::*pool-lock*)
    (gethash session pool::*affinity-map*)))

(defun %wait-until (seconds predicate)
  "Poll PREDICATE every 0.1 s for up to SECONDS; return its last answer."
  (loop repeat (ceiling seconds 0.1)
        until (funcall predicate)
        do (sleep 0.1))
  (funcall predicate))

(defun %record-state (worker)
  "WORKER's state as this server's published record gives it, or NIL."
  (multiple-value-bind (plist status) (read-worker-record (worker-record-path (server-stem)))
    (and (eq status :ok)
         (getf (find (worker-id worker) (getf plist :workers)
                     :key (lambda (w) (getf w :id)))
               :state))))

(defun %fleet-lines-with (&rest needles)
  "The fleet log lines containing every one of NEEDLES."
  (let ((path (hostfiles:fleet-log-path)))
    (remove-if-not (lambda (line) (every (lambda (n) (search n line)) needles))
                   (and (probe-file path) (uiop:read-file-lines path)))))

(defun %no-crash-recorded (session)
  "Assert that SESSION has neither crash history nor a tripped breaker."
  (false (bt:with-lock-held (pool::*pool-lock*)
           (gethash session pool::*crash-history*))
         "crash history recorded for ~A" session)
  (false (bt:with-lock-held (pool::*pool-lock*)
           (gethash session *circuit-breaker-map*))
         "breaker entry recorded for ~A" session))

;;; ---------------------------------------------------------------------------
;;; The case
;;; ---------------------------------------------------------------------------

(define-test host-pressure-stops-a-fresh-worker-saves-a-stateful-one-and-both-carry-on
  "Pressure seen by the host service stops the fresh idle worker first, then
hibernates the stateful one; the fleet log and the status summary say so; calm
held for thirty seconds ends the episode; and afterwards the saved session gets
its world back and the stopped one a fresh worker, neither with a reset notice
or a crash."
  (%relief-case
    (true (%answers-p (%answer-in "s1" "(progn (defvar *kept* 7) *kept*)") 7))
    (%code-find-in "s2")
    (let* ((w1 (%session-worker "s1"))
           (w2 (%session-worker "s2"))
           (pressed t)
           (svc (service:make-service
                 :feed-p nil
                 :memory-reader (lambda () (%readings (if pressed 5 50)))
                 :memory-thresholds (memory:make-memory-thresholds
                                     :min-kill-age-seconds 0)))
           (began nil)
           (stopped-ms nil)
           (saved-ms nil)
           (w1-when-w2-stopped nil))
      (unwind-protect
           (progn
             (true (worker-stateful-p w1) "the defvar did not mark s1's worker stateful")
             (false (worker-stateful-p w2) "the code-find marked s2's worker stateful")
             (true (%wait-until 7 (lambda () (and (eq :bound (%record-state w1))
                                                  (eq :bound (%record-state w2)))))
                   "the record never named both workers bound")
             (setf began (get-internal-real-time))
             (loop repeat 30
                   do (%check svc (%unix-now))
                      (let ((ms (round (* 1000 (- (get-internal-real-time) began))
                                       internal-time-units-per-second)))
                        (when (and (null stopped-ms)
                                   (member (worker-state w2) '(:released :dead)))
                          (setf stopped-ms ms
                                w1-when-w2-stopped (worker-state w1)))
                        (when (and (null saved-ms) (eq :hibernated (worker-state w1)))
                          (setf saved-ms ms)))
                   until saved-ms
                   do (sleep 1))
             (format t "~&pressure to stopped: ~A ms, pressure to hibernated: ~A ms~%"
                     stopped-ms saved-ms)
             (true stopped-ms "s2's fresh worker was never stopped")
             (true saved-ms "s1's stateful worker was never hibernated")
             (is eq :bound w1-when-w2-stopped
                 "the stateful worker was saved before the fresh one was stopped")
             (true (and stopped-ms saved-ms (< stopped-ms saved-ms)))
             (is = 1 (length (%fleet-lines-with "WARN code=memory-pressure ")))
             (true (%wait-until 6 (lambda () (eq :hibernated (%record-state w1))))
                   "the record never named s1's worker hibernated")
             (service::%write-status svc (%unix-now))
             (let ((memory (getf (hostfiles:read-plist-file (hostfiles:service-status-path)
                                                            :max-bytes (* 1024 1024))
                                 :memory)))
               (is eq :pressure (getf memory :state))
               (is = 1 (getf memory :hibernated)))
             ;; Calm, held for thirty seconds by the clock the duty is handed.
             (setf pressed nil)
             (let ((now (%unix-now)))
               (%check svc now)
               (is eq :ok (%check svc (+ now 31))))
             (is = 1 (length (%fleet-lines-with "INFO code=memory-pressure " "recovered")))
             ;; Both sessions carry on.
             (let ((r1 (get-or-assign-worker "s1")))
               (is eq w1 r1)
               (false (check-and-clear-reset-notification r1)))
             (true (%answers-p (%answer-in "s1" "*kept*") 7))
             (let ((r2 (get-or-assign-worker "s2")))
               (false (eq w2 r2) "s2 kept its stopped worker")
               (false (check-and-clear-reset-notification r2)))
             (%no-crash-recorded "s1")
             (%no-crash-recorded "s2"))
        (ignore-errors (service:stop-service svc :mark-clean nil))))))
