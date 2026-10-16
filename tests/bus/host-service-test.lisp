;;;; tests/bus/host-service-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the host service's supervisor, run in this process: one
;;;; tick against a clock the case chooses writes the status summary that
;;;; --host-status reads, an orderly stop lets everything go without rotating a
;;;; log or removing an agent's files, and the watchdog's progress rule. The
;;;; memory cases hand the service readings and pool records of their choosing
;;;; and check which worker it asks for, when, and what it reports.
;;;;
;;;; The state home is a fresh short directory under /tmp (a bus socket path has
;;;; to fit in 107 bytes), the fleet and service logs are installed there before
;;;; anything can report, and every service a case makes is stopped when it ends.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-service-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix)
  (require :sb-bsd-sockets))

(defpackage #:dsmr-mcp/tests/bus/host-service-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:service #:dsmr-bus-host/src/bus/host/main)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:ident #:dsmr-bus-host/src/bus/host/identity)
                    (#:memory #:dsmr-bus-host/src/bus/host/memory)
                    (#:pool-records #:dsmr-mcp/src/hermetic/pool-records))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%reap-notifiers
                #:%unix-time))

(in-package #:dsmr-mcp/tests/bus/host-service-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *ns* "/home/x/proj"
  "The namespace every fixture's agents live in.")

(defvar *services* '()
  "Services made during the current case, stopped when it ends.")

(defun short-temp-dir ()
  "A new empty directory directly under /tmp with a short name, so the sockets
   of a bus rooted inside it fit the unix-domain path limit."
  (loop for dir = (format nil "/tmp/h43sv-~36R~36R/" (sb-posix:getpid) (random 1000000))
        unless (probe-file dir)
          do (ensure-directories-exist dir)
             (return (pathname dir))))

(defun write-text (path text)
  "Replace PATH with TEXT."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string text out))
  path)

(defun call-with-host (thunk)
  "Call THUNK with XDG_STATE_HOME pointing at a fresh short directory, the fleet
   and service logs installed inside it, and stand-in notify-send and gdbus
   programs first on PATH. Afterwards every service is stopped without exiting
   and the directory is removed."
  (let* ((state (short-temp-dir))
         (stubs (merge-pathnames "stub/" state))
         (previous (uiop:getenv "XDG_STATE_HOME"))
         (previous-path (uiop:getenv "PATH"))
         (*services* '()))
    (unwind-protect
         (progn
           (sb-posix:setenv "XDG_STATE_HOME" (namestring state) 1)
           (dolist (program '("notify-send" "gdbus"))
             (let ((script (merge-pathnames program stubs)))
               (write-text script
                           (format nil "#!/bin/sh~%echo \"$*\" >> '~A~A.calls'~%"
                                   (uiop:native-namestring stubs) program))
               (sb-posix:chmod (uiop:native-namestring script) #o755)))
           (sb-posix:setenv "PATH" (format nil "~A:~A" (uiop:native-namestring stubs)
                                           (or previous-path ""))
                            1)
           (fleetlog:install-fleet-log
            :path (hostfiles:fleet-log-path)
            :service-log-path (merge-pathnames "service.log" (hostfiles:host-dir)))
           (funcall thunk state))
      (dolist (svc *services*)
        (ignore-errors (service:stop-service svc :mark-clean nil)))
      (loop repeat 30
            do (%reap-notifiers)
            until (null dsmr-bus-watch/src/bus/watch::*notify-processes*)
            do (sleep 0.1))
      (fleetlog:remove-fleet-log)
      (when previous-path (sb-posix:setenv "PATH" previous-path 1))
      (if previous
          (sb-posix:setenv "XDG_STATE_HOME" previous 1)
          (ignore-errors (sb-posix:unsetenv "XDG_STATE_HOME")))
      (ignore-errors (uiop:delete-directory-tree state :validate t
                                                       :if-does-not-exist :ignore)))))

(defmacro with-host ((state) &body body)
  "Run BODY inside CALL-WITH-HOST with STATE bound to the state home."
  `(call-with-host (lambda (,state) (declare (ignorable ,state)) ,@body)))

(defun id (agent)
  "The full id of AGENT in the fixtures' namespace."
  (format nil "~A/~A" *ns* agent))

(defun register (agent &key (bus nil) (token "t1"))
  "Leave a registration for AGENT on BUS, as --detach would, naming no session."
  (hostfiles:write-registration
   (hostfiles:detach-stem bus (id agent))
   (list :id (id agent) :bus bus :poll-ms 250 :recycle-seconds 600
         :deaf-seconds 600 :token token :registered-at (%unix-time)
         :cli-version "test")))

(defun new-service ()
  "A service run by this process, noted for clean-up."
  (let ((svc (service:make-service)))
    (push svc *services*)
    svc))

(defun read-status ()
  "The status summary and its read status."
  (hostfiles:read-plist-file (hostfiles:service-status-path) :max-bytes (* 1024 1024)))

(defun default-bus-paths ()
  (broker:make-bus-paths (broker:default-state-root nil)))

;;; --------------------------------------------------------------------- cases

(define-test one-tick-writes-the-status-the-probe-reads
  "One supervisor tick, at a time the case chooses, serves a registration and
   writes the status summary: the unnamed bus, the agent serving, and the time
   written taken from the clock the tick was handed, not the wall clock."
  (with-host (state)
    (register "alpha")
    (let* ((svc (new-service))
           (now (- (%unix-time) 3)))
      (service:supervisor-tick svc now)
      (multiple-value-bind (status read) (read-status)
        (is eq :ok read)
        (is = (sb-posix:getpid) (getf status :pid))
        (is = (+ now 2208988800) (getf status :written-at))
        (true (find nil (getf status :buses) :key (lambda (entry) (getf entry :bus)))
              "the unnamed bus is listed")
        (true (member (getf (find nil (getf status :buses)
                                  :key (lambda (entry) (getf entry :bus)))
                            :owner)
                      '(:host :none :client)))
        (let ((entry (find (id "alpha") (getf status :registrations)
                           :key (lambda (entry) (getf entry :id))
                           :test #'equal)))
          (true entry "the registration is listed")
          (is eq :serving (getf entry :state))
          (is eq nil (getf entry :bus)))
        ;; The unnamed bus's roster is empty, so the one registration is a
        ;; finding: registered, not enrolled. It is reported, and gates nothing.
        (is equal (list (list :kind :registered-unenrolled :bus nil :id (id "alpha")))
            (getf status :findings)))
      (true (probe-file (hostfiles:served-path (hostfiles:detach-stem nil (id "alpha"))))
            "the registration was acknowledged"))))

(define-test the-unnamed-bus-is-served-by-the-service
  "Within a few ticks the service's own broker holds the unnamed bus, and the
   status says the host owns it."
  (with-host (state)
    (let ((svc (new-service)))
      (true (loop repeat 40
                  do (service:supervisor-tick svc (%unix-time))
                     (when (eq :host
                               (getf (find nil (getf (read-status) :buses)
                                           :key (lambda (entry) (getf entry :bus)))
                                     :owner))
                       (return t))
                     (sleep 0.25))))))

(define-test an-orderly-stop-rotates-nothing-and-keeps-the-agent-s-files
  "The orderly stop lets the broker go without archiving although the service
   was the bus's only member, closes the agent's descriptors without removing
   its pid file or its registration, and leaves the clean-stop marker."
  (with-host (state)
    (register "alpha")
    (let* ((svc (new-service))
           (paths (default-bus-paths))
           (stem (hostfiles:detach-stem nil (id "alpha"))))
      (true (loop repeat 40
                  do (service:supervisor-tick svc (%unix-time))
                     (when (service:service-ready-p svc) (return t))
                     (sleep 0.25))
            "the service became ready")
      (let ((generation (wal:generation (broker:bus-paths-wal paths))))
        (service:stop-service svc :mark-clean t)
        (is equal '() (directory (merge-pathnames "bus.wal.archive-*"
                                                  (broker:bus-paths-root paths))))
        (is = generation (wal:generation (broker:bus-paths-wal paths))))
      (true (probe-file (hostfiles:clean-stop-path)))
      (true (probe-file (hostfiles:watch-state-file stem "pid")))
      (true (probe-file (hostfiles:registration-path stem)))
      ;; The membership and the role were let go: a fresh exclusive probe of the
      ;; membership lock succeeds.
      (let ((fd (dsmr-mcp/src/bus/election:open-lock (broker:bus-paths-members paths))))
        (unwind-protect
             (true (dsmr-mcp/src/bus/election:try-lock-exclusive fd))
          (dsmr-mcp/src/bus/election:close-lock fd))))))

(define-test a-thread-counts-as-progressing-only-while-its-count-moves
  "The watchdog's rule: a thread whose progress count has not moved for more
   than the window is stalled, and moving again makes it fresh."
  (let ((stamp (service:progress-step nil 5 100)))
    (is equal '(5 . 100) stamp)
    (setf stamp (service:progress-step stamp 5 105))
    (is equal '(5 . 100) stamp)
    (true (service:progress-fresh-p stamp 110))
    (false (service:progress-fresh-p stamp 111))
    (setf stamp (service:progress-step stamp 6 111))
    (true (service:progress-fresh-p stamp 111))))

(defun receive-one (sock)
  "One datagram from SOCK as a string, or NIL when none arrives within two
   seconds."
  (let ((buffer (make-array 64 :element-type '(unsigned-byte 8))))
    (loop repeat 20
          do (multiple-value-bind (got length)
                 (handler-case (sb-bsd-sockets:socket-receive sock buffer nil)
                   (sb-bsd-sockets:interrupted-error () nil))
               (when (and got length (plusp length))
                 (return (map 'string #'code-char (subseq buffer 0 length)))))
             (sleep 0.1))))

(define-test readiness-reaches-the-manager-s-socket-in-both-namespaces
  "The readiness message reaches a datagram socket named by path and one in
   the abstract namespace, named with a leading @. With no socket named,
   nothing is sent and nothing fails."
  (let* ((dir (short-temp-dir))
         (path (uiop:native-namestring (merge-pathnames "notify" dir)))
         (abstract (format nil "h43sv-notify-~D-~D" (sb-posix:getpid) (random 1000000)))
         (by-path (make-instance 'sb-bsd-sockets:local-socket :type :datagram))
         (by-name (make-instance 'sb-bsd-sockets:local-abstract-socket :type :datagram)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-bind by-path path)
           (sb-bsd-sockets:socket-bind by-name abstract)
           (setf (sb-bsd-sockets:non-blocking-mode by-path) t
                 (sb-bsd-sockets:non-blocking-mode by-name) t)
           (true (service:sd-notify "READY=1" :socket path))
           (is equal "READY=1" (receive-one by-path))
           (true (service:sd-notify "WATCHDOG=1" :socket (concatenate 'string "@" abstract)))
           (is equal "WATCHDOG=1" (receive-one by-name))
           (false (service:sd-notify "READY=1" :socket nil))
           (false (service:sd-notify "READY=1" :socket "")))
      (ignore-errors (sb-bsd-sockets:socket-close by-path))
      (ignore-errors (sb-bsd-sockets:socket-close by-name))
      (ignore-errors (uiop:delete-directory-tree dir :validate t
                                                     :if-does-not-exist :ignore)))))

;;; ------------------------------------------------------------ memory relief

(defvar *reports* '()
  "Every report the current memory case's service made, newest first, as
   (level code subject msg).")

(defun recording-report (level code &key bus id subject msg)
  "Note a report in *REPORTS*, then hand it to the service's logs as the
   service's own report function would."
  (push (list level code subject msg) *reports*)
  (ident:report-to-logs level code :bus bus :id id :subject subject :msg msg))

(defun reported (code &optional level)
  "The reports made under CODE, at LEVEL when given."
  (remove-if-not (lambda (r)
                   (and (equal code (second r))
                        (or (null level) (eq level (first r)))))
                 *reports*))

(defun readings (available-percent &key (some 0.0))
  "A memory reading with AVAILABLE-PERCENT of a 1 GB host available."
  (memory:make-memory-readings :some-avg10 some :full-avg10 0.0
                               :mem-total-kb 1000000
                               :mem-available-kb (* 10000 available-percent)))

(defvar *reading* nil
  "What the current memory case's service reads as the host's memory.")

(defun memory-service (&key (reader (lambda () *reading*)) thresholds)
  "A service that reads its memory through READER and reports through
   RECORDING-REPORT, noted for clean-up."
  (let ((svc (apply #'service:make-service :feed-p nil :report-fn #'recording-report
                    :memory-reader reader
                    (and thresholds (list :memory-thresholds thresholds)))))
    (push svc *services*)
    svc))

(defmacro with-memory-case ((state) &body body)
  "Run BODY inside WITH-HOST with fresh reports and fresh heal breakers, so one
   case's heals never use up another's."
  `(with-host (,state)
     (let ((*reports* '())
           (*reading* (readings 50))
           (conditions:*breakers* (make-hash-table :test 'equal :synchronized t)))
       ,@body)))

(defun check (svc now)
  "Run SVC's memory duty at NOW the way the supervisor does."
  (service::%duty svc "memory" (lambda () (service::%check-memory svc now))
                  :subject "host"))

(defun own-stem ()
  "This process's server stem: its records belong to a live owner."
  (pool-records:server-stem))

(defun worker (id &key stateful (state :bound) busy spawned-at last-activity)
  "One worker entry of a pool's record."
  (list :id id :pid nil :state state :session (format nil "s~D" id)
        :stateful stateful :busy busy :spawned-at spawned-at
        :last-activity last-activity :refused-reason nil :refused-at nil
        :core-bytes nil))

(defun publish (workers &key (stem (own-stem)) (owner stem))
  "Publish WORKERS as the record of the server STEM, the record saying it
   belongs to the server OWNER names."
  (multiple-value-bind (pid start) (pool-records:parse-server-stem owner)
    (pool-records:write-worker-record
     stem (list :server-pid pid :server-start start :written-at (%unix-time)
                :service-seen t :workers workers :last-action nil))))

(defun requests ()
  "The requests waiting, as plists."
  (mapcar #'cdr (pool-records:pending-requests)))

(defun fleet-lines-with (&rest needles)
  "The fleet log lines containing every one of NEEDLES."
  (let ((path (hostfiles:fleet-log-path)))
    (remove-if-not (lambda (line) (every (lambda (n) (search n line)) needles))
                   (and (probe-file path) (uiop:read-file-lines path)))))

(define-test calm-memory-asks-for-nothing
  "With memory to spare, an idle stateful worker is left alone."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (publish (list (worker 1 :stateful t :spawned-at (- now 100)
                               :last-activity (- now 50))))
      (check svc now)
      (is equal '() (requests)))))

(define-test pressure-asks-for-one-worker-at-a-time
  "Under pressure the service asks the owning pool to hibernate the idle
   stateful worker, and asks nothing more while that request stands, however
   long it stands short of the request timeout."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (setf *reading* (readings 5))
      (publish (list (worker 1 :stateful t :spawned-at (- now 100)
                               :last-activity (- now 50))
                     (worker 2 :stateful t :spawned-at (- now 100)
                               :last-activity (- now 40))))
      (check svc now)
      (let ((asked (requests)))
        (is = 1 (length asked))
        (is = 1 (getf (first asked) :worker-id))
        (is eq :hibernate (getf (first asked) :action)))
      (check svc (+ now 1))
      (is = 1 (length (requests)) "a second request while one stands")
      ;; Past the spacing between requests, the standing one still holds
      ;; every other back.
      (check svc (+ now 5))
      (let ((asked (requests)))
        (is = 1 (length asked) "a second request once the spacing had passed")
        (is = now (getf (first asked) :requested-at) "the standing request was made again")))))

(define-test requests-are-at-least-two-seconds-apart
  "Once a request is answered, the next is not made until two seconds after
   the last."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (setf *reading* (readings 5))
      (publish (list (worker 1 :stateful t :spawned-at (- now 100)
                               :last-activity (- now 50))
                     (worker 2 :stateful t :spawned-at (- now 100)
                               :last-activity (- now 40))))
      (check svc now)
      (is = 1 (length (requests)))
      ;; The pool answers: the worker is saved and its request removed.
      (dolist (entry (pool-records:pending-requests))
        (pool-records:remove-request (car entry)))
      (publish (list (worker 1 :stateful t :state :hibernated :spawned-at (- now 100)
                               :last-activity (- now 50))
                     (worker 2 :stateful t :spawned-at (- now 100)
                               :last-activity (- now 40))))
      (check svc (+ now 1))
      (is equal '() (requests) "asked again within two seconds")
      (check svc (+ now 2))
      (let ((asked (requests)))
        (is = 1 (length asked))
        (is = 2 (getf (first asked) :worker-id))))))

(define-test a-fresh-idle-worker-is-stopped-before-a-stateful-one-is-saved
  "A fresh idle worker old enough is asked to stop before any stateful worker
   is asked to hibernate, and one spawned three seconds ago is never asked."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (setf *reading* (readings 5))
      (publish (list (worker 1 :spawned-at (- now 60))
                     (worker 2 :stateful t :spawned-at (- now 200)
                               :last-activity (- now 100))
                     (worker 3 :spawned-at (- now 3))))
      (check svc now)
      (let ((asked (requests)))
        (is = 1 (length asked))
        (is = 1 (getf (first asked) :worker-id))
        (is eq :kill (getf (first asked) :action)))
      (dolist (entry (pool-records:pending-requests))
        (pool-records:remove-request (car entry)))
      (publish (list (worker 2 :stateful t :spawned-at (- now 200)
                               :last-activity (- now 100))
                     (worker 3 :spawned-at (- now 3))))
      (check svc (+ now 2))
      (let ((asked (requests)))
        (is = 1 (length asked))
        (is = 2 (getf (first asked) :worker-id))
        (is eq :hibernate (getf (first asked) :action)))
      (dolist (entry (pool-records:pending-requests))
        (pool-records:remove-request (car entry)))
      (publish (list (worker 2 :stateful t :state :hibernated
                               :spawned-at (- now 200) :last-activity (- now 100))
                     (worker 3 :spawned-at (- now 3))))
      (check svc (+ now 4))
      (is equal '() (requests) "the young worker was asked to stop"))))

(define-test a-dead-server-s-record-and-request-are-removed-and-never-acted-on
  "A record and a request whose server is gone are removed, and nothing is
   asked of the gone server."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time))
          (dead "999999999-12345"))
      (setf *reading* (readings 5))
      (publish (list (worker 1 :stateful t :spawned-at (- now 100)
                               :last-activity (- now 50)))
               :stem dead)
      (let ((request (pool-records:write-hibernate-request dead 1 :hibernate
                                                           :now now)))
        (check svc now)
        (false (probe-file request) "the dead server's request is still there"))
      (false (probe-file (pool-records:worker-record-path dead))
             "the dead server's record is still there")
      (is equal '() (requests)))))

(define-test a-request-left-unanswered-for-five-minutes-is-removed-with-a-warning
  "A request 301 seconds old is removed and reported as stale."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (setf *reading* (readings 5))
      (publish '())
      (let ((request (pool-records:write-hibernate-request (own-stem) 7 :hibernate
                                                           :now (- now 301))))
        (check svc now)
        (false (probe-file request) "the stale request is still there"))
      (is = 1 (length (reported "memory-request-stale" :warn))))))

(define-test pressure-with-nothing-left-to-relieve-is-reported-once-then-recovers
  "Pressure with no candidate is reported once as unrelieved after sixty
   seconds, not again in the same episode, and calm held for thirty seconds
   ends the episode with a recovered line."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (setf *reading* (readings 5))
      (publish '())
      (check svc now)
      (is = 1 (length (fleet-lines-with "WARN code=memory-pressure ")))
      (check svc (+ now 30))
      (is = 0 (length (fleet-lines-with "code=memory-pressure-unrelieved")))
      (check svc (+ now 61))
      (is = 1 (length (fleet-lines-with "ERROR code=memory-pressure-unrelieved")))
      (check svc (+ now 120))
      (is = 1 (length (fleet-lines-with "code=memory-pressure-unrelieved")))
      (setf *reading* (readings 50))
      (check svc (+ now 121))
      (check svc (+ now 151))
      (is eq :ok (memory:memory-state-verdict (service::service-memory-state svc)))
      (is = 1 (length (fleet-lines-with "INFO code=memory-pressure " "recovered"))))))

(define-test a-failing-memory-reader-never-stops-the-supervisor
  "A memory reader that signals is reported as a failed duty about the host,
   and the tick carries on and returns."
  (with-memory-case (state)
    (let ((svc (memory-service :reader (lambda () (error "no /proc here")))))
      (is eq svc (service:supervisor-tick svc (%unix-time)))
      (let ((failed (remove-if-not (lambda (r) (equal "host" (third r)))
                                   (reported "duty-failed" :error))))
        (is = 1 (length failed))
        (true (search "no /proc here" (fourth (first failed))))))))

(define-test the-status-summary-carries-the-memory-state-and-the-worker-counts
  "After one tick the status summary says how memory stands and counts the
   hibernated and resident workers of live servers."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (publish (list (worker 1 :stateful t :state :hibernated :spawned-at (- now 100))
                     (worker 2 :spawned-at (- now 100))
                     (worker 3 :stateful t :spawned-at (- now 100))))
      (publish (list (worker 1 :state :hibernated)) :stem "999999999-12345")
      (service:supervisor-tick svc now)
      (let ((memory (getf (read-status) :memory)))
        (true memory "no :memory in the summary")
        (is eq :ok (getf memory :state))
        (true (member :since memory))
        (is = 1 (getf memory :hibernated))
        (is = 2 (getf memory :resident))
        (is = 50 (getf memory :available-percent))))))

(define-test the-owner-sweep-removes-a-gone-server-s-cores-once-a-minute
  "The owner sweep removes the core directory of a server that is gone, and
   runs again only once sixty seconds have passed."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time))
          (dead "999999999-12345"))
      (pool-records:ensure-owner-directory dead)
      (service::%sweep-owners svc now)
      (false (probe-file (pool-records:owner-directory dead)) "first sweep left it")
      (pool-records:ensure-owner-directory dead)
      (service::%sweep-owners svc (+ now 30))
      (true (probe-file (pool-records:owner-directory dead)) "swept before it was due")
      (service::%sweep-owners svc (+ now 60))
      (false (probe-file (pool-records:owner-directory dead)) "the due sweep left it"))))

(define-test a-record-whose-name-disagrees-with-its-contents-is-skipped
  "A record filed under one live server's name that says it belongs to another
   is reported and never acted on."
  (with-memory-case (state)
    (let* ((svc (memory-service))
           (now (%unix-time))
           (other (sb-ext:run-program "/bin/sleep" '("30") :wait nil)))
      (unwind-protect
           (let ((other-stem (pool-records:server-stem (sb-ext:process-pid other))))
             (setf *reading* (readings 5))
             (publish (list (worker 1 :stateful t :spawned-at (- now 100)
                                      :last-activity (- now 50)))
                      :stem other-stem :owner (own-stem))
             (check svc now)
             (is equal '() (requests))
             (is = 1 (length (reported "worker-record-mismatch" :warn)))
             (true (probe-file (pool-records:worker-record-path other-stem))
                   "a live server's record was removed"))
        (ignore-errors (sb-ext:process-kill other 15))
        (ignore-errors (sb-ext:process-wait other))))))

(define-test a-threshold-the-environment-spells-wrongly-is-reported-once
  "A pressure threshold the environment cannot give is reported at WARN,
   naming the variable, on the first memory check and never again."
  (with-memory-case (state)
    (let ((previous (uiop:getenv "DSMR_PRESSURE_ENTER_SOME")))
      (unwind-protect
           (let ((svc (progn (sb-posix:setenv "DSMR_PRESSURE_ENTER_SOME" "banana" 1)
                             (memory-service)))
                 (now (%unix-time)))
             (check svc now)
             (check svc (+ now 1))
             (let ((warned (reported "memory-threshold-ignored" :warn)))
               (is = 1 (length warned))
               (true (search "DSMR_PRESSURE_ENTER_SOME" (fourth (first warned))))))
        (if previous
            (sb-posix:setenv "DSMR_PRESSURE_ENTER_SOME" previous 1)
            (ignore-errors (sb-posix:unsetenv "DSMR_PRESSURE_ENTER_SOME")))))))
