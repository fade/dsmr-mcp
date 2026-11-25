;;;; tests/bus/host-service-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the host service's supervisor, run in this process: one
;;;; tick against a clock the case chooses writes the status summary that
;;;; --host-status reads, an orderly stop lets everything go without rotating a
;;;; log or removing an agent's files, and the watchdog's progress rule. The
;;;; memory cases hand the service readings and pool records of their choosing
;;;; and check which worker it asks for, when, and what it reports. The I/O
;;;; thread cases start the service's I/O thread, hold one pass inside the
;;;; memory reader, and read the messages the duty loop sends to a
;;;; notification socket the case binds.
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
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
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

(defun readings (available-percent &key (some 0.0) (full 0.0))
  "A memory reading with AVAILABLE-PERCENT of a 1 GB host available."
  (memory:make-memory-readings :some-avg10 some :full-avg10 full
                               :mem-total-kb 1000000
                               :mem-available-kb (* 10000 available-percent)))

(defparameter *recorded-stalls*
  '((3.2 62) (4.2 59) (2.2 64) (2.1 64))
  "The four FLEET WARN memory-pressure lines of 2026-11-22/23 in the fleet log
   of the development host, as (some-avg10 available-percent). A WARN line
   records no full figure. At these shares pressure was entered only through
   full >= enter-full, so full is taken as 2.0, the default enter-full and
   the least value the record implies.")

(defun recorded-stall (i)
  "A reading of the Ith entry of *RECORDED-STALLS*, cycling, with full 2.0."
  (destructuring-bind (some percent) (nth (mod i 4) *recorded-stalls*)
    (readings percent :some some :full 2.0)))

(defparameter *incident-reading*
  '(:some-avg10 2.7 :full-avg10 2.0 :mem-total-kb 1000000 :mem-available-kb 710000
    :io-full-avg10 15.0)
  "The FLEET WARN reading of the 2026-11-22 16:39Z incident on the development
   host, an md5sum pass over the source tree: some avg10 2.7, 71% available,
   I/O full avg10 15 during the episode. Memory full is unrecorded and taken
   as 2.0, the default enter-full and the least value that entered pressure.
   I/O some is unrecorded and left out.")

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

(defun publish (workers &key (stem (own-stem)) (owner stem) (at (%unix-time)))
  "Publish WORKERS as the record of the server STEM, the record saying it
   belongs to the server OWNER names and was written AT, in Unix seconds."
  (multiple-value-bind (pid start) (pool-records:parse-server-stem owner)
    (pool-records:write-worker-record
     stem (list :server-pid pid :server-start start :written-at at
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

(define-test a-pool-whose-record-has-gone-stale-is-never-asked
  "A live server whose pool stopped rewriting its record a minute ago is never
   asked for relief, and pressure with nothing else to ask is reported as
   unrelieved after sixty seconds, naming the pool that is not answering."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (setf *reading* (readings 5))
      (publish (list (worker 1 :stateful t :spawned-at (- now 200)
                               :last-activity (- now 100)))
               :at (- now 60))
      (check svc now)
      (is equal '() (requests) "a pool whose record is a minute old was asked")
      (check svc (+ now 61))
      (is equal '() (requests))
      (let ((lines (fleet-lines-with "ERROR code=memory-pressure-unrelieved")))
        (is = 1 (length lines))
        (true (and lines (search "1 pool not answering" (first lines)))
              "~A" lines)))))

(define-test a-pool-that-left-a-request-unanswered-is-passed-over-for-another
  "When a request is withdrawn unanswered, relief moves on at once to a worker
   of another pool instead of asking the silent pool for the same worker
   again, even though that pool's record still offers it first."
  (with-memory-case (state)
    (let* ((svc (memory-service))
           (now (%unix-time))
           (later (+ now 301))
           (other (sb-ext:run-program "/bin/sleep" '("60") :wait nil)))
      (unwind-protect
           (let ((other-stem (pool-records:server-stem (sb-ext:process-pid other))))
             (setf *reading* (readings 5))
             (publish (list (worker 1 :stateful t :spawned-at (- now 200)
                                      :last-activity (- now 100)))
                      :at later)
             (publish (list (worker 1 :stateful t :spawned-at (- now 200)
                                      :last-activity (- now 50)))
                      :stem other-stem :at later)
             (pool-records:write-hibernate-request (own-stem) 1 :hibernate :now now)
             (check svc later)
             (let ((asked (mapcar #'cdr (pool-records:pending-requests))))
               (is = 1 (length asked))
               (multiple-value-bind (pid start) (pool-records:parse-server-stem other-stem)
                 (is eql pid (getf (first asked) :server-pid)
                     "the silent pool was asked again: ~S" asked)
                 (is eql start (getf (first asked) :server-start))))
             (is = 1 (length (reported "memory-request-stale" :warn))))
        (ignore-errors (sb-ext:process-kill other 15))
        (ignore-errors (sb-ext:process-wait other))))))

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

(define-test recorded-stalls-with-most-memory-available-ask-no-worker-to-give-memory-back
  "The first two recorded FLEET WARN readings of 2026-11-22/23
   (*RECORDED-STALLS*), 62% and 59% available, leave an idle stateful worker
   alone and write no memory-pressure line. Reclaim is reported once, at
   INFO, with the share of the reading that entered it."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (publish (list (worker 1 :stateful t :spawned-at (- now 100)
                               :last-activity (- now 50))))
      (setf *reading* (recorded-stall 0))
      (check svc now)
      (setf *reading* (recorded-stall 1))
      (check svc (+ now 1))
      (is equal '() (requests))
      (is = 0 (length (fleet-lines-with "code=memory-pressure")))
      (is equal '() (reported "memory-pressure"))
      (let ((reclaim (reported "memory-reclaim" :info)))
        (is = 1 (length reclaim))
        (true (search "not a shortage" (fourth (first reclaim))))
        (true (search "available=59%" (fourth (first reclaim))))
        (false (search "I/O" (fourth (first reclaim))))))))

(define-test recorded-stalls-with-most-memory-available-never-become-unrelieved
  "The recorded FLEET WARN readings of 2026-11-22/23 (*RECORDED-STALLS*),
   cycled once a second for 62 s with no worker published, write neither a
   WARN memory-pressure line nor an unrelieved line, and end in reclaim."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (publish '())
      (loop for i from 0 to 62
            do (setf *reading* (recorded-stall i))
               (check svc (+ now i)))
      (is = 0 (length (fleet-lines-with "code=memory-pressure-unrelieved")))
      (is = 0 (length (fleet-lines-with "WARN code=memory-pressure")))
      (is eq :reclaim (memory:memory-state-verdict (service::service-memory-state svc))))))

(define-test pressure-held-open-only-by-recorded-stalls-ends
  "A pressure episode fed only the recorded FLEET WARN readings of
   2026-11-22/23 (*RECORDED-STALLS*), 59-64% available, ends after the 30 s
   hold and is never reported unrelieved. No recorded pressure entry exists
   to replay, so the service's state is constructed."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (publish '())
      (setf (service::service-memory-state svc)
            (memory:make-memory-state :verdict :pressure :since now))
      (let ((verdicts (loop for i from 0 to 61
                            collect (progn (setf *reading* (recorded-stall i))
                                           (check svc (+ now i))
                                           (memory:memory-state-verdict
                                            (service::service-memory-state svc))))))
        (is eq :pressure (nth 29 verdicts))
        (false (member :pressure (nthcdr 30 verdicts))))
      (is = 0 (length (fleet-lines-with "code=memory-pressure-unrelieved"))))))

(define-test ample-memory-during-the-hold-asks-no-worker-to-give-memory-back
  "Pressure entered 50 s earlier on a shortage, then the recorded FLEET WARN
   readings of 2026-11-22/23 (*RECORDED-STALLS*), 59-64% available, through
   the 30 s hold: the idle stateful worker is left alone and the episode
   ends. The entry is constructed: no recorded shortage exists."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (publish (list (worker 1 :stateful t :spawned-at (- now 100)
                               :last-activity (- now 50))))
      (setf (service::service-memory-state svc)
            (memory:make-memory-state :verdict :pressure :since (- now 50)))
      (loop for i from 0 to 30
            do (setf *reading* (recorded-stall i))
               (check svc (+ now i)))
      (is equal '() (requests))
      (is eq :ok (memory:memory-state-verdict (service::service-memory-state svc))))))

(define-test ample-memory-during-the-hold-is-never-reported-unrelieved
  "Pressure entered 50 s earlier on a shortage with no worker to relieve,
   then the recorded FLEET WARN readings of 2026-11-22/23
   (*RECORDED-STALLS*), 59-64% available, through the 30 s hold: the episode
   passes 60 s and ends without an unrelieved line. The entry is
   constructed: no recorded shortage exists."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (publish '())
      (setf (service::service-memory-state svc)
            (memory:make-memory-state :verdict :pressure :since (- now 50)))
      (loop for i from 0 to 30
            do (setf *reading* (recorded-stall i))
               (check svc (+ now i)))
      (is = 0 (length (fleet-lines-with "code=memory-pressure-unrelieved")))
      (is eq :ok (memory:memory-state-verdict (service::service-memory-state svc))))))

(define-test the-recorded-incident-is-reported-as-io-driven-reclaim
  "The WARN reading of the 2026-11-22 16:39Z incident (*INCIDENT-READING*),
   given twice because the reading before it is unrecorded but was also a
   stall, asks nothing of an idle stateful worker and is reported once as
   reclaim driven by I/O, with the I/O full figure."
  (with-memory-case (state)
    (let ((svc (memory-service))
          (now (%unix-time)))
      (publish (list (worker 1 :stateful t :spawned-at (- now 100)
                               :last-activity (- now 50))))
      (setf *reading* (apply #'memory:make-memory-readings *incident-reading*))
      (check svc now)
      (check svc (+ now 1))
      (is equal '() (requests))
      (is equal '() (reported "memory-pressure"))
      (let ((reclaim (reported "memory-reclaim" :info)))
        (is = 1 (length reclaim))
        (true (search "I/O-driven" (fourth (first reclaim))))
        (true (search "io full avg10=15.0" (fourth (first reclaim))))))))

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

;;; ------------------------------------------------- the duty loop and the I/O thread

(defvar *stall-armed* nil
  "Which stand-in stalls on its next call: :MEMORY for
   STALLING-MEMORY-READER, :SURVEY for STALLING-SURVEY, NIL for neither.")

(defvar *stall-entered* nil
  "True once STALLING-MEMORY-READER has entered its stall.")

(defvar *stall-release* (sb-thread:make-semaphore :name "stall")
  "Signalled to end the stall. These *STALL-* variables are global, not bound per case,
   because the I/O thread sees no case's dynamic bindings.")

(defvar *stall-left* nil
  "True once STALLING-MEMORY-READER has left its stall.")

(defvar *stall-service* nil
  "The service whose mutex STALLING-MEMORY-READER holds when armed with
   :MEMORY-LOCKED.")

(defvar *stall-broker-states* nil
  "The states of *STALL-SERVICE*'s brokers when STALLING-MEMORY-READER left
   its slow read, while the I/O thread was still running.")

(defun broker-states (svc)
  "The state of each of SVC's brokers, from its published snapshot."
  (mapcar (lambda (entry)
            (dsmr-bus-host/src/bus/host/brokers:bus-broker-state (cdr entry)))
          (service::%served-brokers svc)))

(defun stalling-memory-reader ()
  "A memory reader with 50% of memory available. Once armed with :MEMORY,
   the next call blocks the pass that made it until *STALL-RELEASE* is
   signalled, or for at most 60 s; armed with :MEMORY-LOCKED, it blocks the
   same way holding *STALL-SERVICE*'s mutex; armed with :MEMORY-SLOW, it
   takes 2 s, then sets *STALL-BROKER-STATES* to the states of
   *STALL-SERVICE*'s brokers."
  (case *stall-armed*
    (:memory
     (setf *stall-armed* nil
           *stall-entered* t)
     (sb-thread:wait-on-semaphore *stall-release* :timeout 60)
     (setf *stall-left* t))
    (:memory-locked
     (setf *stall-armed* nil)
     (sb-thread:with-recursive-lock ((service::service-mutex *stall-service*))
       (setf *stall-entered* t)
       (sb-thread:wait-on-semaphore *stall-release* :timeout 60))
     (setf *stall-left* t))
    (:memory-slow
     (setf *stall-armed* nil
           *stall-entered* t)
     (sleep 2)
     (setf *stall-broker-states* (broker-states *stall-service*)
           *stall-left* t)))
  (readings 50))

(defun stalling-survey (survey)
  "A survey function that answers SURVEY as the service's own does. Once
   armed with :SURVEY, the next call blocks the pass that made it until
   *STALL-RELEASE* is signalled, or for at most 60 s, before it answers."
  (when (eq *stall-armed* :survey)
    (setf *stall-armed* nil
          *stall-entered* t)
    (sb-thread:wait-on-semaphore *stall-release* :timeout 60)
    (setf *stall-left* t))
  (ident:run-survey survey))

(defun drain (sock)
  "Every datagram waiting on SOCK, oldest first, without blocking."
  (let ((buffer (make-array 64 :element-type '(unsigned-byte 8)))
        (got '()))
    (loop
      (multiple-value-bind (received length)
          (handler-case (sb-bsd-sockets:socket-receive sock buffer nil)
            (error () nil))
        (if (and received length (plusp length))
            (push (map 'string #'code-char (subseq buffer 0 length)) got)
            (return))))
    (nreverse got)))

(defun tick (svc sock now)
  "Run one supervisor tick of SVC at NOW and return the messages it sent to
   SOCK."
  (service:supervisor-tick svc now)
  (drain sock))

(defun beats (messages)
  "How many of MESSAGES are WATCHDOG=1."
  (count "WATCHDOG=1" messages :test #'string=))

(defun call-with-io-service (state thunk &key (diagnostic (make-broadcast-stream))
                                             (survey-fn #'ident:run-survey))
  "Call THUNK with a service whose I/O thread is started, whose memory reader
   is STALLING-MEMORY-READER, whose survey function is SURVEY-FN and whose
   backtraces go to DIAGNOSTIC, and with a bound, non-blocking datagram
   socket under STATE that NOTIFY_SOCKET names. *STALL-SERVICE* is set to
   the service. Afterwards the stall is
   released, the service stopped, its I/O thread joined, NOTIFY_SOCKET
   restored and the socket closed."
  (let ((path (uiop:native-namestring (merge-pathnames "notify.sock" state)))
        (sock (make-instance 'sb-bsd-sockets:local-socket :type :datagram))
        (previous (uiop:getenv "NOTIFY_SOCKET"))
        (svc nil))
    (setf *stall-armed* nil
          *stall-entered* nil
          *stall-left* nil
          *stall-broker-states* nil
          *stall-release* (sb-thread:make-semaphore :name "stall"))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-bind sock path)
           (setf (sb-bsd-sockets:non-blocking-mode sock) t)
           (sb-posix:setenv "NOTIFY_SOCKET" path 1)
           (setf svc (service:make-service :feed-p nil
                                           :memory-reader #'stalling-memory-reader
                                           :survey-fn survey-fn
                                           :diagnostic-stream diagnostic))
           (push svc *services*)
           (setf *stall-service* svc)
           (service:start-io-thread svc)
           (funcall thunk svc sock))
      (setf *stall-armed* nil)
      (sb-thread:signal-semaphore *stall-release* 10)
      (when svc
        (ignore-errors (service:stop-service svc :mark-clean nil))
        (let ((thread (service::service-io-thread svc)))
          (when thread
            (sb-thread:join-thread thread :default nil :timeout 10))))
      (if previous
          (sb-posix:setenv "NOTIFY_SOCKET" previous 1)
          (ignore-errors (sb-posix:unsetenv "NOTIFY_SOCKET")))
      (ignore-errors (sb-bsd-sockets:socket-close sock)))))

(defmacro with-io-service ((svc sock state &rest options) &body body)
  "Run BODY inside CALL-WITH-IO-SERVICE with SVC and SOCK bound."
  `(call-with-io-service ,state (lambda (,svc ,sock) ,@body) ,@options))

(defun await-ready (svc sock)
  "Tick SVC on the wall clock until READY=1 reaches SOCK, for at most 15 s.
   True when it did."
  (loop repeat 60
        thereis (member "READY=1" (tick svc sock (%unix-time)) :test #'string=)
        do (sleep 0.25)))

(defun enter-stall (svc sock &optional (kind :memory))
  "Arm the stand-in KIND names (*STALL-ARMED*) and tick SVC on the wall clock
   until a pass enters the stall, for at most 10 s. Returns the clock of the
   tick that saw it entered and the sequence number of the stalled pass, or
   NIL when no pass entered it."
  (setf *stall-armed* kind)
  (loop repeat 40
        for now = (%unix-time)
        do (tick svc sock now)
           (sleep 0.25)
           (when *stall-entered*
             (return (values now (service::service-io-posted svc))))))

(defun await-completion (svc sock sequence clock)
  "Tick SVC from CLOCK on, 2 s of its clock per tick, until the duty loop has
   consumed the completion of pass SEQUENCE, for at most 10 s. True when it
   did."
  (loop repeat 20
        for now from (+ clock 2) by 2
        do (sleep 0.5)
           (tick svc sock now)
        thereis (>= (service::service-io-consumed svc) sequence)))

(define-test the-beat-goes-on-while-a-pass-is-stalled
  "With a pass held inside the memory reader for 16 s of the duty loop's
   clock, every once-a-second tick still sends WATCHDOG=1, and the pass
   completes once released."
  (with-memory-case (state)
    (with-io-service (svc sock state)
      (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
      (multiple-value-bind (start sequence) (enter-stall svc sock)
        (true start "no pass entered the stalling reader within 10 s")
        (when start
          (loop for offset from 2 to 16 by 2
                do (sleep 0.5)
                   (is = 1 (beats (tick svc sock (+ start offset)))
                       "WATCHDOG=1 count at stall start + ~D s" offset))
          (true *stall-entered*)
          (false *stall-left* "the stall ended before its release")
          (sb-thread:signal-semaphore *stall-release*)
          (true (await-completion svc sock sequence (+ start 16))
                "the released pass was not consumed within 10 s"))))))

(define-test a-wedged-io-thread-stops-the-beat
  "With a pass held past the I/O progress window, no WATCHDOG=1 is sent from
   stall start + 24 s, the I/O thread's backtrace naming the stalled reader is
   written once to the diagnostic stream, and the beat returns within three
   ticks of the release."
  (with-memory-case (state)
    (let ((diagnostic (make-string-output-stream)))
      (with-io-service (svc sock state :diagnostic diagnostic)
        (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
        (let ((start (enter-stall svc sock)))
          (true start "no pass entered the stalling reader within 10 s")
          (when start
            ;; The last duty before the stall can finish up to one tick
            ;; after START, so the window is counted from START + 2 s.
            (loop for offset from 2 to 28 by 2
                  do (sleep 0.5)
                     (let ((count (beats (tick svc sock (+ start offset)))))
                       (cond ((<= offset 18)
                              (is = 1 count "WATCHDOG=1 count at stall start + ~D s" offset))
                             ((>= offset 24)
                              (is = 0 count "WATCHDOG=1 count at stall start + ~D s" offset)))))
            (sleep 1)
            (let ((text (get-output-stream-string diagnostic)))
              (is = 1 (loop for at = (search "made no progress for" text)
                              then (search "made no progress for" text :start2 (1+ at))
                            while at
                            count t)
                  "backtrace headers written: ~A" text)
              (true (search "\"host service io\"" text) "the header does not name the I/O thread")
              (true (search "STALLING-MEMORY-READER" text)
                    "the backtrace does not show the stalled reader: ~A" text))
            (sb-thread:signal-semaphore *stall-release*)
            (true (loop for offset from 30 to 34 by 2
                        do (sleep 0.5)
                        thereis (plusp (beats (tick svc sock (+ start offset)))))
                  "WATCHDOG=1 did not return within three ticks of the release")))))))

(define-test a-stop-does-not-wait-on-a-wedged-pass
  "With a pass held while it holds the service mutex, an orderly stop
   returns within the stop budget and half a second, says it was not
   orderly, and writes no clean-stop marker, so the next start records an
   unclean restart."
  (with-memory-case (state)
    (with-io-service (svc sock state)
      (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
      (let ((start (enter-stall svc sock :memory-locked))
            (bound (+ service::+stop-budget-seconds+ 1/2)))
        (true start "no pass entered the stalling reader within 10 s")
        (when start
          (true (sb-thread:mutex-owner (service::service-mutex svc))
                "the stalled pass does not hold the service mutex")
          (let ((began (get-internal-real-time)))
            (service:stop-service svc :mark-clean t)
            (let ((seconds (/ (- (get-internal-real-time) began)
                              internal-time-units-per-second)))
              (true (< seconds bound) "the stop took ~,1F s, bound ~,1F s" seconds bound)))
          (false (service::service-stop-orderly-p svc) "the stop says it was orderly")
          (false (probe-file (hostfiles:clean-stop-path))
                 "a clean-stop marker was written with a pass wedged"))))))

(define-test a-stop-waits-for-a-pass-that-is-still-running
  "With a pass inside a memory read that takes 2 s, an orderly stop waits
   for the pass to end, says it was orderly, and writes the clean-stop
   marker."
  (with-memory-case (state)
    (with-io-service (svc sock state)
      (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
      (let ((start (enter-stall svc sock :memory-slow)))
        (true start "no pass entered the slow reader within 10 s")
        (when start
          (false *stall-left* "the slow read ended before the stop")
          (service:stop-service svc :mark-clean t)
          (true (probe-file (hostfiles:clean-stop-path))
                "no clean-stop marker after a pass that was only running")
          (true (service::service-stop-orderly-p svc) "the stop says it was not orderly"))))))

(defun unit-stop-timeout (path)
  "The TimeoutStopSec= value of the systemd unit at PATH in whole seconds,
   written bare or with an `s`, or NIL when the unit sets none or spells it
   otherwise."
  (loop for line in (uiop:read-file-lines path)
        for trimmed = (string-trim '(#\Space #\Tab) line)
        when (uiop:string-prefix-p "TimeoutStopSec=" trimmed)
          return (multiple-value-bind (value end)
                     (parse-integer trimmed :start 15 :junk-allowed t)
                   (and value
                        (member (subseq trimmed end) '("" "s") :test #'string=)
                        value))))

(define-test the-stop-budget-fits-the-unit-s-stop-timeout
  "The shipped unit's TimeoutStopSec leaves at least 2 s beyond the stop
   budget, and the budget's share for the I/O thread leaves room for the
   quiet window and for joining the brokers and readers."
  (let ((timeout (unit-stop-timeout (asdf:system-relative-pathname
                                     "dsmr-mcp" "scripts/units/dsmr-bus-host.service")))
        (budget service::+stop-budget-seconds+)
        (join service::+stop-join-seconds+))
    (true timeout "the unit sets no TimeoutStopSec in whole seconds")
    (when timeout
      (true (<= (+ budget 2) timeout)
            "stop budget ~D s leaves less than 2 s of TimeoutStopSec=~D" budget timeout))
    (true (< 0 join budget) "join share ~D s, budget ~D s" join budget)
    (true (< service::+stop-quiet-seconds+ (- budget join))
          "quiet window ~D s, I/O share ~D s" service::+stop-quiet-seconds+ (- budget join))))

(define-test the-brokers-serve-until-the-io-thread-ends
  "During an orderly stop with a pass still running, every broker is still
   serving when the pass leaves its last duty, and none is serving once the
   stop returns."
  (with-memory-case (state)
    (with-io-service (svc sock state)
      (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
      (true (loop repeat 40
                  thereis (let ((states (broker-states svc)))
                            (and states (every (lambda (s) (eq s :serving)) states)))
                  do (tick svc sock (%unix-time))
                     (sleep 0.25))
            "no broker was serving before the stop: ~S" (broker-states svc))
      (let ((start (enter-stall svc sock :memory-slow)))
        (true start "no pass entered the slow reader within 10 s")
        (when start
          (service:stop-service svc :mark-clean t)
          (true *stall-broker-states* "the slow read recorded no broker")
          (true (every (lambda (s) (eq s :serving)) *stall-broker-states*)
                "broker states while the pass ran: ~S" *stall-broker-states*)
          (true (notany (lambda (s) (eq s :serving)) (broker-states svc))
                "broker states after the stop: ~S" (broker-states svc)))))))

(define-test a-stop-keeps-the-stall-watchdog-s-loop-clause-fresh
  "While an orderly stop waits on a wedged pass for its quiet window and
   then joins the brokers and readers, the supervisor loop is noted on every
   turn of the wait and before every join, so the stall watchdog's loop
   clause never sees the loop 2 s old, and the stop ends inside the stop
   budget."
  (with-memory-case (state)
    (with-io-service (svc sock state)
      (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
      (let ((start (enter-stall svc sock :memory-locked)))
        (true start "no pass entered the stalling reader within 10 s")
        (when start
          (let ((units internal-time-units-per-second)
                (worst 0)
                (done nil))
            (service::%note-loop)
            (let ((sampler (sb-thread:make-thread
                            (lambda ()
                              (loop until done
                                    do (setf worst (max worst
                                                        (/ (- (get-internal-real-time)
                                                              service::*last-loop*)
                                                           units)))
                                       (sleep 0.05)))
                            :name "stall sampler"))
                  (began (get-internal-real-time)))
              (service:stop-service svc :mark-clean t)
              (let ((seconds (/ (- (get-internal-real-time) began) units)))
                (setf done t)
                (sb-thread:join-thread sampler :default nil :timeout 5)
                (true (>= seconds (- service::+stop-quiet-seconds+ 1/2))
                      "the stop took only ~,1F s, so it proves nothing" seconds)
                (true (< seconds service::+stop-budget-seconds+)
                      "the stop took ~,1F s" seconds)
                (true (< worst 2) "the loop was ~,1F s old during the stop" worst)))))))))

(define-test a-pass-asked-to-stop-starts-no-broker
  "A pass reads a new registration on a bus not yet served and starts that
   bus's broker and reader; a pass run after the stop request does neither."
  (with-memory-case (state)
    (register "alpha")
    (let ((svc (memory-service))
          (now (%unix-time)))
      (service:run-duties svc now)
      (register "beta" :bus "late")
      (service:run-duties svc (+ now 5))
      (true (gethash "late" (service::service-brokers svc))
            "the bus late is not served without a stop request")
      (register "gamma" :bus "later")
      (service:request-stop svc)
      (service:run-duties svc (+ now 10))
      (false (gethash "later" (service::service-brokers svc))
             "a broker was started for the bus later after the stop request")
      (false (gethash "later" (service::service-watches svc))
             "a reader was started for the bus later after the stop request"))))

(define-test a-stop-request-wakes-an-idle-io-thread
  "REQUEST-STOP ends an I/O thread waiting for its next pass within 1 s, and
   the stopping flag has no exported writer that could skip the wake-up."
  (with-memory-case (state)
    (with-io-service (svc sock state)
      (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
      (let ((thread (service::service-io-thread svc)))
        (true (loop repeat 40
                    thereis (= (service::service-io-posted svc)
                               (service::service-io-completed svc))
                    do (sleep 0.05))
              "the I/O thread did not go idle")
        (funcall (find-symbol "REQUEST-STOP" '#:dsmr-bus-host/src/bus/host/main) svc)
        (true (loop repeat 20
                    thereis (not (sb-thread:thread-alive-p thread))
                    do (sleep 0.05))
              "the I/O thread was still waiting 1 s after the request")))
    (false (eq :external (nth-value 1 (find-symbol "SERVICE-STOPPING"
                                                   '#:dsmr-bus-host/src/bus/host/main)))
           "SERVICE-STOPPING is still exported")
    (is eq :external (nth-value 1 (find-symbol "REQUEST-STOP"
                                               '#:dsmr-bus-host/src/bus/host/main)))))

(define-test a-failing-readiness-line-abandons-nothing-else
  "When the readiness line cannot be written, the failure is reported as a
   duty failure and the rest of the pass still runs: the status summary for
   the readiness is written."
  (with-memory-case (state)
    (register "alpha")
    (let ((svc (memory-service))
          (now (%unix-time)))
      (service:run-duties svc now)
      (setf (service::service-ready-p svc) t)
      (ignore-errors (delete-file (hostfiles:service-status-path)))
      (sb-int:encapsulate 'fleetlog:service-log 'failing-readiness
                          (lambda (original level control &rest args)
                            (if (search "ready buses" control)
                                (error "stand-in service log failure")
                                (apply original level control args))))
      (unwind-protect
           (let ((escaped (nth-value 1 (ignore-errors (service:run-duties svc (1+ now)) t))))
             (false escaped "the pass was abandoned: ~A" escaped)
             (true (probe-file (hostfiles:service-status-path))
                   "the status summary was not written")
             (true (reported "duty-failed") "the failure was not reported"))
        (sb-int:unencapsulate 'fleetlog:service-log 'failing-readiness)))))

(define-test io-progress-stall-rule
  "The stall watchdog's rule: the service has stalled when its loop has not
   come round for more than the window, or when a pass has been outstanding
   for more than the window; a pass done in time, or none outstanding, is
   no stall."
  (false (service:stall-p 100 nil nil 100))
  (false (service:stall-p 100 nil 0 100) "no pass outstanding")
  (false (service:stall-p 100 t 40 100) "outstanding for exactly the window")
  (true (service:stall-p 100 t 39 100) "outstanding past the window")
  (false (service:stall-p 100 t 39 100 :window 61))
  (true (service:stall-p 39 nil nil 100) "the loop has not come round")
  (false (service:stall-p 40 t 95 100)))

(define-test mail-is-announced-while-a-cursor-survey-is-stalled
  "With the I/O thread held inside one agent's cursor survey, mail published
   to that agent reaches its wake log within 5 s while the survey is still
   held: the survey takes no service mutex, so the bus reader delivers."
  (with-memory-case (state)
    (register "alpha")
    (with-io-service (svc sock state :survey-fn #'stalling-survey)
      (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
      (let* ((paths (default-bus-paths))
             (wal-path (broker:bus-paths-wal paths))
             (cursor (merge-pathnames (envelope:encode-id (id "alpha"))
                                      (uiop:ensure-directory-pathname
                                       (broker:bus-paths-cursors-dir paths))))
             (log (hostfiles:watch-state-file (hostfiles:detach-stem nil (id "alpha")) "log"))
             (head (values (wal:scan wal-path))))
        ;; A cursor at the head with a write date the identity has not
        ;; recorded, so the held survey goes on to read the log.
        (write-text cursor (format nil "~D" head))
        (sb-posix:utimes (uiop:native-namestring cursor) (- (%unix-time) 100)
                         (- (%unix-time) 100))
        (multiple-value-bind (start sequence) (enter-stall svc sock :survey)
          (true start "no pass entered the stalling survey within 10 s")
          (when start
            (let ((before (if (probe-file log) (length (uiop:read-file-lines log)) 0)))
              (wal:append-record wal-path (1+ head)
                                 (envelope:wrap-envelope "c1" "/ns/other" "x"
                                                         :to (id "alpha")))
              (true (loop repeat 100
                          thereis (and (probe-file log)
                                       (> (length (uiop:read-file-lines log)) before))
                          do (sleep 0.05))
                    "no wake line within 5 s while the survey was held")
              (false *stall-left* "the survey was released before the mail was announced"))
            (sb-thread:signal-semaphore *stall-release*)
            (true (await-completion svc sock sequence start)
                  "the released pass was not consumed within 10 s")))))))

(defvar *failed-surveys* '()
  "Whether each survey FAILING-SURVEY was handed was forced, newest first.")

(defun failing-survey (survey)
  "A survey function that notes whether SURVEY is forced, then signals."
  (push (and (ident::survey-forced survey) t) *failed-surveys*)
  (error "stand-in survey failure"))

(defun served-identity (svc agent)
  "The identity SVC serves for AGENT on the unnamed bus, or NIL."
  (sb-thread:with-recursive-lock ((service::service-mutex svc))
    (loop for identity being the hash-values
            of (dsmr-bus-host/src/bus/host/registry:registry-identities
                (service:service-registry svc))
          when (equal (id agent) (ident:identity-id identity))
            return identity)))

(define-test a-survey-that-keeps-failing-still-samples-deafness
  "With every survey signalling, a forced one still starts the next recycle
   window, so later ticks inside it are not forced, and the deafness rule is
   still sampled: mail unheard past the threshold raises the marker."
  (with-memory-case (state)
    (register "alpha")
    (setf *failed-surveys* '())
    (let ((svc (service:make-service :feed-p nil :report-fn #'recording-report
                                     :memory-reader (lambda () *reading*)
                                     :survey-fn #'failing-survey))
          (start (%unix-time))
          (marker (hostfiles:watch-state-file (hostfiles:detach-stem nil (id "alpha"))
                                              "deaf")))
      (push svc *services*)
      (service:run-duties svc start)
      (let* ((identity (served-identity svc "alpha"))
             (wal-path (broker:bus-paths-wal (default-bus-paths)))
             (head (values (wal:scan wal-path))))
        (true identity "alpha is not served")
        (wal:append-record wal-path (1+ head)
                           (envelope:wrap-envelope "c1" "/ns/other" "x" :to (id "alpha")))
        (sb-thread:with-recursive-lock ((service::service-mutex svc))
          (ident:identity-deliver identity
                                  (values (dsmr-bus-watch/src/bus/watch::%poll-forward
                                           wal-path (wal:make-reader) head))
                                  start :readers 0))
        (setf *failed-surveys* '())
        (loop for offset from 700 to 703
              do (service:run-duties svc (+ start offset)))
        (is = 4 (length *failed-surveys*) "surveys asked: ~S" *failed-surveys*)
        (is = 1 (count t *failed-surveys*) "forced surveys: ~S" *failed-surveys*)
        (true (probe-file marker) "no deaf marker after 700 s of unheard mail")))))

(defun slow-survey (survey)
  "A survey function that answers SURVEY as the service's own does. While
   *STALL-ARMED* is :SLOW, each call first sets *STALL-ENTERED* and takes
   1 s."
  (when (eq *stall-armed* :slow)
    (setf *stall-entered* t)
    (sleep 1))
  (ident:run-survey survey))

(define-test a-slow-pass-that-keeps-progressing-keeps-the-beat
  "With ten agents whose surveys take 1 s each, one pass outlasts the I/O
   progress window on the duty loop's clock, yet every once-a-second tick
   still sends WATCHDOG=1: each finished survey counts as progress."
  (with-memory-case (state)
    (dotimes (i 10) (register (format nil "agent~D" i)))
    (with-io-service (svc sock state :survey-fn #'slow-survey)
      (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
      (multiple-value-bind (start sequence) (enter-stall svc sock :slow)
        (true start "no pass entered the slow survey within 10 s")
        (when start
          (loop for offset from 2 to 28 by 2
                do (sleep 0.5)
                   (is = 1 (beats (tick svc sock (+ start offset)))
                       "WATCHDOG=1 count at slow pass start + ~D s" offset))
          (true (< (service::service-io-completed svc) sequence)
                "the pass ended inside the window, so it proves nothing")
          (setf *stall-armed* nil)
          (true (await-completion svc sock sequence (+ start 28))
                "the slow pass was not consumed within 10 s"))))))

(define-test a-stop-cuts-short-a-pass-of-slow-surveys
  "With fifteen agents whose surveys take 1 s each and a pass inside them,
   an orderly stop skips the surveys left and returns within the stop
   budget, says it was orderly, and writes the clean-stop marker."
  (with-memory-case (state)
    (dotimes (i 15) (register (format nil "agent~D" i)))
    (with-io-service (svc sock state :survey-fn #'slow-survey)
      (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
      (let ((start (enter-stall svc sock :slow)))
        (true start "no pass entered the slow survey within 10 s")
        (when start
          (let ((began (get-internal-real-time)))
            (service:stop-service svc :mark-clean t)
            (let ((seconds (/ (- (get-internal-real-time) began)
                              internal-time-units-per-second)))
              (true (< seconds service::+stop-budget-seconds+)
                    "the stop took ~,1F s, budget ~D s" seconds service::+stop-budget-seconds+)))
          (true (service::service-stop-orderly-p svc) "the stop says it was not orderly")
          (true (probe-file (hostfiles:clean-stop-path))
                "no clean-stop marker after a pass that was only running"))))))

(defvar *diagnostic-release* (sb-thread:make-semaphore :name "diagnostic")
  "Signalled to let a BLOCKING-STREAM's first write go through. Global, since
   the thread that writes sees no case's bindings.")

(defclass blocking-stream (sb-gray:fundamental-character-output-stream)
  ((text :initform (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)
         :reader blocking-stream-text)
   (entered :initform nil :accessor blocking-stream-entered)
   (released :initform nil :accessor blocking-stream-released))
  (:documentation "A character output stream whose first write blocks until
   *DIAGNOSTIC-RELEASE* is signalled, or for at most 60 s, then keeps what
   it is written."))

(defun %hold-first-write (stream)
  "Block STREAM's first write until *DIAGNOSTIC-RELEASE* is signalled."
  (unless (blocking-stream-released stream)
    (setf (blocking-stream-entered stream) t)
    (sb-thread:wait-on-semaphore *diagnostic-release* :timeout 60)
    (setf (blocking-stream-released stream) t)))

(defmethod sb-gray:stream-line-column ((stream blocking-stream))
  nil)

(defmethod sb-gray:stream-write-char ((stream blocking-stream) char)
  (%hold-first-write stream)
  (vector-push-extend char (blocking-stream-text stream)))

(define-test a-blocked-diagnostic-write-holds-up-neither-the-pass-nor-the-beat
  "With the diagnostic stream blocked, a wedged pass that is then released
   completes and the beat returns; the backtrace, taken in the I/O thread,
   reaches the stream once it unblocks."
  (with-memory-case (state)
    (setf *diagnostic-release* (sb-thread:make-semaphore :name "diagnostic"))
    (let ((diagnostic (make-instance 'blocking-stream)))
      (with-io-service (svc sock state :diagnostic diagnostic)
        (unwind-protect
             (progn
               (true (await-ready svc sock) "READY=1 did not arrive within 15 s")
               (let ((start (enter-stall svc sock)))
                 (true start "no pass entered the stalling reader within 10 s")
                 (when start
                   (loop for offset from 2 to 28 by 2
                         do (sleep 0.5)
                            (tick svc sock (+ start offset)))
                   (sleep 1)
                   (true (blocking-stream-entered diagnostic)
                         "no backtrace reached the diagnostic stream")
                   (sb-thread:signal-semaphore *stall-release*)
                   (true (loop for offset from 30 to 40 by 2
                               do (sleep 0.5)
                               thereis (plusp (beats (tick svc sock (+ start offset)))))
                         "WATCHDOG=1 did not return while the diagnostic write was blocked")
                   (sb-thread:signal-semaphore *diagnostic-release*)
                   (true (loop repeat 40
                               thereis (search "STALLING-MEMORY-READER"
                                               (copy-seq (blocking-stream-text diagnostic)))
                               do (sleep 0.05))
                         "the backtrace does not show the stalled reader"))))
          (sb-thread:signal-semaphore *diagnostic-release* 10))))))
