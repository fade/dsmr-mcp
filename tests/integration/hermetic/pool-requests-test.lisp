;;;; tests/integration/hermetic/pool-requests-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The pool answering the host service, proven with real workers.
;;;;
;;;; These cover the pool's half of the files it shares with the host service:
;;;; it publishes a record of its workers and keeps it fresh, it stops a fresh
;;;; idle worker or hibernates a stateful one when asked, it refuses what is no
;;;; longer safe by the time it reads the request, a stop can never take a
;;;; worker out from under a call, it ignores what is stale, unknown or not
;;;; addressed to it, it says once when no service is listening, and it takes
;;;; its files with it when it stops.
;;;;
;;;; Every case boots its workers from a worker core (WITH-WORKER-CORE-OR-SKIP)
;;;; and gives the pool a private XDG_STATE_HOME, so records, requests and
;;;; saved cores land in a temporary directory that is removed afterwards.

(defpackage #:dsmr-mcp/tests/integration/hermetic/pool-requests-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:pool #:dsmr-mcp/src/hermetic/pool))
  (:import-from #:dsmr-mcp/src/hermetic/pool
                #:initialize-pool #:shutdown-pool #:get-or-assign-worker
                #:pool-rpc-with-hard-kill #:with-session-worker
                #:act-on-hibernate-request
                #:*after-assign-hook* #:*circuit-breaker-map*
                #:*pressure-kill-min-age-seconds* #:*pressure-agent-interval*
                #:*worker-pool-warmup* #:*max-pool-size*
                #:*health-check-interval-seconds*)
  (:import-from #:dsmr-mcp/src/hermetic/worker-client
                #:*worker-core* #:worker-id #:worker-state #:worker-in-flight
                #:check-and-clear-reset-notification)
  (:import-from #:dsmr-mcp/src/hermetic/pool-records
                #:server-stem #:parse-server-stem
                #:worker-record-path #:read-worker-record
                #:write-hibernate-request #:request-path)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/log
                #:configure-log4cl-for-server)
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-worker-core-or-skip)
  (:import-from #:bordeaux-threads)
  (:import-from #:log4cl)
  (:import-from #:sb-posix)
  (:import-from #:uiop))

(in-package #:dsmr-mcp/tests/integration/hermetic/pool-requests-test)

;;; ---------------------------------------------------------------------------
;;; Capturing the pool's log lines
;;; ---------------------------------------------------------------------------

(defclass %capture-appender (log4cl:appender)
  ((lines :initform nil :accessor %captured-lines)
   (lock :initform (bt:make-lock "pool-requests-capture") :reader %capture-lock))
  (:documentation "Keeps the text of every log line it is handed, from any
thread, so a case can count what a pool thread logged."))

(defmethod log4cl:appender-do-append ((appender %capture-appender) logger level
                                      log-func)
  (declare (ignore logger level))
  (let ((text (with-output-to-string (s) (funcall log-func s))))
    (bt:with-lock-held ((%capture-lock appender))
      (push text (%captured-lines appender))))
  (values))

(defvar *capture* nil
  "The capture appender of the case being run.")

(defun %count-logged (needle)
  "How many captured lines contain NEEDLE."
  (bt:with-lock-held ((%capture-lock *capture*))
    (count-if (lambda (line) (search needle line))
              (%captured-lines *capture*))))

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defvar *state-home* nil
  "The temporary state home of the case being run.")

(defun %make-temp-directory ()
  "Create a fresh private temporary directory and return its pathname."
  (uiop:ensure-directory-pathname
   (string-trim '(#\Newline #\Return #\Space)
                (uiop:run-program '("mktemp" "-d" "-t" "dsmr-pool-requests.XXXXXX")
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

(defmacro %pool-case ((&key (min-kill-age 0) (agent-interval 1)
                            (shutdown t))
                      &body body)
  "Evaluate BODY against a running pool whose workers boot from the test
worker core, with no standbys, a minimum pressure-stop age of MIN-KILL-AGE
seconds and a pressure agent ticking every AGENT-INTERVAL seconds, inside a
private state home, with the pool's log lines captured in *CAPTURE*. The pool
is shut down afterwards whatever happens; when SHUTDOWN is NIL, BODY is
expected to shut it down itself. Skips when no core can be built."
  (let ((core (gensym "CORE")))
    `(with-worker-core-or-skip (,core)
       (%with-state-home
         (let ((*mode* :hermetic)
               (*error-output* (make-string-output-stream))
               (*worker-core* ,core)
               (*worker-pool-warmup* 0)
               (*max-pool-size* 4)
               (*health-check-interval-seconds* 10.0d0)
               (*pressure-kill-min-age-seconds* ,min-kill-age)
               (*pressure-agent-interval* ,agent-interval)
               (*capture* (make-instance '%capture-appender)))
           (configure-log4cl-for-server :warn)
           (log4cl:add-appender log4cl:*root-logger* *capture*)
           (unwind-protect
                (progn
                  (initialize-pool)
                  (unwind-protect (progn ,@body)
                    (when ,shutdown
                      (ignore-errors (shutdown-pool)))))
             (ignore-errors (shutdown-pool))
             (ignore-errors
              (log4cl:remove-appender log4cl:*root-logger* *capture*))))))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %unix-now ()
  "The current time in Unix seconds."
  (- (get-universal-time) (encode-universal-time 0 0 0 1 1 1970 0)))

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

(defun %no-crash-recorded (session)
  "Assert that SESSION has neither crash history nor a tripped breaker."
  (false (bt:with-lock-held (pool::*pool-lock*)
           (gethash session pool::*crash-history*))
         "crash history recorded for ~A" session)
  (false (bt:with-lock-held (pool::*pool-lock*)
           (gethash session *circuit-breaker-map*))
         "breaker entry recorded for ~A" session))

(defun %record ()
  "This server's published worker record, or NIL when there is none."
  (multiple-value-bind (plist status) (read-worker-record (worker-record-path (server-stem)))
    (and (eq status :ok) plist)))

(defun %last-result (worker-id)
  "The result of the last request the record says was answered, when it was
for WORKER-ID."
  (let ((action (getf (%record) :last-action)))
    (and action (eql (getf action :worker-id) worker-id)
         (getf action :result))))

(defun %await-result (worker-id seconds)
  "Wait up to SECONDS for the record to name an answer for WORKER-ID; return
it, or NIL."
  (%wait-until seconds (lambda () (%last-result worker-id))))

(defun %request (worker-id action &key now)
  "Write a request to this server for WORKER-ID and return its path."
  (write-hibernate-request (server-stem) worker-id action
                           :now now :reason "pool requests test"))

(defun %consumed-p (path seconds)
  "True when the request at PATH is gone within SECONDS."
  (%wait-until seconds (lambda () (not (probe-file path)))))

(defun %kill-request (worker)
  "A :kill request plist for WORKER of this server, as the agent reads one."
  (multiple-value-bind (pid start) (parse-server-stem (server-stem))
    (list :server-pid pid :server-start start
          :worker-id (worker-id worker) :action :kill
          :requested-at (%unix-now) :reason "pool requests test")))

;;; ---------------------------------------------------------------------------
;;; The published record
;;; ---------------------------------------------------------------------------

(define-test the-pool-publishes-its-workers-and-keeps-the-record-fresh
  "A record for this server appears within 3 s of start, names a bound worker
after its first call, and is rewritten within 6 s even when nothing changed."
  (%pool-case ()
    (true (%wait-until 3 #'%record) "no record within 3 s")
    (%answer-in "published" "(+ 1 1)")
    (let ((id (worker-id (%session-worker "published"))))
      (true (%wait-until 3 (lambda ()
                             (let ((w (find id (getf (%record) :workers)
                                            :key (lambda (w) (getf w :id)))))
                               (and w (eq :bound (getf w :state))
                                    (equal "published" (getf w :session))))))
            "the record never named worker ~A bound to the session" id))
    (let ((written (getf (%record) :written-at)))
      (true (%wait-until 6.5 (lambda ()
                               (let ((now (getf (%record) :written-at)))
                                 (and now (> now written)))))
            "the record was not rewritten after ~A" written))))

;;; ---------------------------------------------------------------------------
;;; Requests the pool acts on
;;; ---------------------------------------------------------------------------

(define-test a-kill-request-stops-a-fresh-idle-worker-without-a-notice
  "A :kill request for a fresh idle worker is consumed within 3 s, the worker
is gone, and the session's next worker is a new one with no reset notice."
  (%pool-case ()
    (let* ((first (get-or-assign-worker "fresh"))
           (id (worker-id first))
           (path (%request id :kill)))
      (true (%consumed-p path 3) "request not consumed")
      (true (member (worker-state first) '(:released :dead)) "state ~A"
            (worker-state first))
      (false (eq first (%session-worker "fresh")))
      (let ((next (get-or-assign-worker "fresh")))
        (true (/= id (worker-id next)))
        (false (check-and-clear-reset-notification next)))
      (is eq :killed (%await-result id 3))
      (%no-crash-recorded "fresh"))))

(define-test a-stop-that-finds-a-call-holding-the-worker-is-busy
  "When a call takes the worker after the stop chose it and before the stop
acts, the stop answers busy, the worker keeps serving and the call is
answered."
  (%pool-case ()
    (let* ((w (get-or-assign-worker "lose"))
           (thread nil)
           (result nil))
      (let ((pool::*before-pressure-stop-hook*
              (lambda (worker)
                (setf thread
                      (bt:make-thread
                       (lambda ()
                         ;; A failure in the call comes back as text, so it
                         ;; fails the assertion below instead of the run.
                         (handler-case (%answer-in "lose" "(progn (sleep 2) 42)")
                           (error (e) (format nil "call failed: ~A" e))))
                       :name "pool-requests-call"))
                (%wait-until 10 (lambda () (= 1 (worker-in-flight worker)))))))
        (setf result (act-on-hibernate-request (%kill-request w))))
      (is eq :busy result)
      (is eq :bound (worker-state w))
      (is eq w (%session-worker "lose"))
      (true thread)
      (let ((text (bt:join-thread thread)))
        (true (%answers-p text 42) "~A" text))
      (%no-crash-recorded "lose"))))

(define-test a-call-that-arrives-after-a-stop-gets-a-fresh-worker
  "When a stop lands between a call being assigned its worker and holding it,
the call is answered by a replacement worker with no reset notice and no
crash recorded."
  (%pool-case ()
    (let ((passes 0)
          (stopped-id nil)
          (stop-result nil)
          (answered-by nil)
          (had-reset :unset)
          (text nil))
      (let ((*after-assign-hook*
              (lambda (worker)
                (incf passes)
                (when (= passes 1)
                  (setf stopped-id (worker-id worker)
                        stop-result (act-on-hibernate-request
                                     (%kill-request worker)))))))
        (with-session-worker (w "win")
          (setf answered-by (worker-id w)
                had-reset (check-and-clear-reset-notification w)
                text (%answer-on w "(+ 40 2)"))))
      (is eq :killed stop-result)
      (true (%answers-p text 42) "~A" text)
      (true (and stopped-id (/= stopped-id answered-by)))
      (false had-reset)
      (%no-crash-recorded "win"))))

(define-test a-kill-request-for-a-worker-just-spawned-is-too-young
  "With the default minimum age, a :kill request for a fresh idle worker
spawned 2 s earlier is answered too-young and the worker keeps serving."
  (%pool-case (:min-kill-age nil)
    (let* ((w (get-or-assign-worker "young"))
           (id (worker-id w)))
      (sleep 2)
      (let ((path (%request id :kill)))
        (true (%consumed-p path 3) "request not consumed"))
      (is eq :too-young (%await-result id 3))
      (is eq :bound (worker-state w))
      (is eq w (%session-worker "young")))))

(define-test a-hibernate-request-saves-a-stateful-idle-worker
  "A :hibernate request for a stateful idle worker ends with the worker
hibernated, the answer recorded and the request file gone."
  (%pool-case ()
    (%answer-in "saved" "(progn (defvar *kept* 7) *kept*)")
    (let* ((w (%session-worker "saved"))
           (id (worker-id w))
           (path (%request id :hibernate)))
      (true (%consumed-p path 60) "request not consumed")
      (is eq :hibernated (worker-state w))
      (is eq :hibernated (%await-result id 3))
      (false (probe-file path)))))

(define-test a-kill-request-for-a-stateful-worker-has-changed
  "A :kill request for a worker that holds state is answered changed and the
worker keeps serving with its world."
  (%pool-case ()
    (%answer-in "stateful" "(progn (defvar *kept* 7) *kept*)")
    (let* ((w (%session-worker "stateful"))
           (id (worker-id w))
           (path (%request id :kill)))
      (true (%consumed-p path 3) "request not consumed")
      (is eq :changed (%await-result id 3))
      (is eq :bound (worker-state w))
      (true (%answers-p (%answer-in "stateful" "*kept*") 7)))))

;;; ---------------------------------------------------------------------------
;;; Requests the pool refuses or never sees
;;; ---------------------------------------------------------------------------

(define-test stale-unknown-and-foreign-requests-are-never-acted-on
  "A request 400 s old is removed without action, one for an unknown worker is
removed as unknown, and one addressed to another server is left alone."
  (%pool-case ()
    (let* ((w (get-or-assign-worker "stale"))
           (id (worker-id w))
           (stale (%request id :kill :now (- (%unix-now) 400))))
      (true (%consumed-p stale 3) "stale request not removed")
      (is eq :stale (%await-result id 3))
      (is eq :bound (worker-state w))
      (is eq w (%session-worker "stale")))
    (let ((unknown (%request 999 :kill)))
      (true (%consumed-p unknown 3) "unknown request not removed")
      (is eq :unknown-worker (%await-result 999 3)))
    (let ((foreign (write-hibernate-request "999999-12345" 1 :kill)))
      (sleep 3)
      (true (probe-file foreign) "another server's request was touched")
      (ignore-errors (delete-file foreign)))))

(define-test without-a-service-the-pool-warns-once
  "With no host service beating, the pool logs one warning that pressure
relief is inactive, and does not repeat it on later ticks."
  (%pool-case ()
    (true (%wait-until 3 (lambda () (= 1 (%count-logged "pool.pressure.no-service")))))
    (sleep 3)
    (is = 1 (%count-logged "pool.pressure.no-service"))))

(define-test shutdown-takes-the-pool-files-with-it
  "Stopping the pool removes its record and the requests waiting for it, and
leaves another server's request alone."
  (%pool-case (:agent-interval 60 :shutdown nil)
    (true (%wait-until 3 #'%record) "no record within 3 s")
    (let* ((stem (server-stem))
           (record (worker-record-path stem))
           (mine (%request 7 :kill))
           (foreign (write-hibernate-request "999999-12345" 1 :kill)))
      (true (probe-file mine))
      (shutdown-pool)
      (false (probe-file record) "record left behind")
      (false (probe-file mine) "own request left behind")
      (true (probe-file foreign) "another server's request was removed")
      (ignore-errors (delete-file foreign))
      (false (probe-file (request-path stem 7))))))
