;;;; src/bus/host/main.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The host bus service itself: its entry point, the supervisor loop that
;;;; schedules every duty the other host leaves define, the readiness and
;;;; watchdog messages it sends systemd, and the orderly stop.
;;;;
;;;; While it runs, one process per host takes over from the broker a client
;;;; elects for each bus and the watcher process each agent keeps per bus; those
;;;; remain the fallback whenever the service is down. Each bus has a broker
;;;; thread and one reader thread; every agent registered with the service is an
;;;; identity the supervisor ticks. The supervisor runs each duty under the
;;;; healing protocol, so a fault in one agent's files or one bus never stops the
;;;; others, and what cannot be healed reaches the fleet error log a leader
;;;; watches.
;;;;
;;;; The service also decides when the host gives memory back. It already comes
;;;; round once a second for every agent, so it reads the host's memory on the
;;;; same beat and, under pressure, asks the session pools to stop or hibernate
;;;; their idle workers, one worker at a time, a fresh one before a stateful
;;;; one, and never two at once, so the saving itself never deepens the
;;;; shortage. It asks through files beside the pools' worker records and acts
;;;; only on records of servers that are still running; once a minute it sweeps
;;;; away the cores, records and requests of servers that have gone. Pressure,
;;;; its relief and pressure nothing can relieve all reach the fleet log, and
;;;; the status summary says how memory stands.
;;;;
;;;; Every duty is a function of the time it is handed, so one tick can be run in
;;;; a test against a clock the test chooses. The loop around it is the only
;;;; place that reads the wall clock, and the only place that converts between
;;;; the two clocks in use: the identities, the registry and the bus readers take
;;;; Unix seconds, the brokers and the status summary universal time.
;;;;
;;;; Stopping is deliberate and never rotates a log. SIGTERM ends the loop; the
;;;; brokers let their roles go without archiving, the readers close, every
;;;; agent's descriptors are closed without removing its pid file or its
;;;; registration, and a clean-stop marker tells the next start that this was
;;;; not a crash.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix)
  (require :sb-bsd-sockets))

(defpackage #:dsmr-bus-host/src/bus/host/main
  (:use #:cl)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:election #:dsmr-mcp/src/bus/election)
                    (#:roster #:dsmr-mcp/src/bus/roster)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:ident #:dsmr-bus-host/src/bus/host/identity)
                    (#:registry #:dsmr-bus-host/src/bus/host/registry)
                    (#:buswatch #:dsmr-bus-host/src/bus/host/buswatch)
                    (#:brokers #:dsmr-bus-host/src/bus/host/brokers)
                    (#:memory #:dsmr-bus-host/src/bus/host/memory)
                    (#:pool-records #:dsmr-mcp/src/hermetic/pool-records))
  (:import-from #:dsmr-bus-host/src/bus/host/conditions
                #:memory-pressure
                #:memory-pressure-unrelieved
                #:request-hibernation)
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%unix-time)
  (:export
   ;; entry point
   #:main
   ;; the service
   #:service
   #:make-service
   #:service-p
   #:service-pid
   #:service-registry
   #:service-brokers
   #:service-watches
   #:service-ready-p
   #:service-stopping
   #:start-service
   #:supervisor-tick
   #:stop-service
   ;; systemd
   #:sd-notify
   ;; watchdog rule
   #:progress-step
   #:progress-fresh-p))

(in-package #:dsmr-bus-host/src/bus/host/main)

;;; ----------------------------------------------------------------- constants

(defconstant +unix-epoch+ 2208988800
  "The universal time of the Unix epoch.")

(defconstant +progress-window+ 10
  "Seconds a broker or bus reader thread may go without progress before the
   service stops telling systemd it is alive.")

(defconstant +stall-seconds+ 60
  "Seconds the supervisor loop may go without coming round before the service
   ends itself so that it is restarted.")

(defconstant +memory-action-spacing+ 2
  "Seconds that must pass after a pool was asked to give memory back before
   another pool, or the same one, is asked again. Saving a world costs memory
   for a moment, so two saves at once could deepen the very shortage they are
   meant to relieve.")

(defconstant +memory-request-timeout+ 300
  "Seconds a request may wait for its pool to answer before it is taken back,
   so a pool that stopped listening cannot hold up relief for every other.")

(defconstant +unrelieved-seconds+ 60
  "Seconds pressure may last with no worker left to ask before it is reported
   as unrelieved, for a leader to act on.")

(defconstant +owner-sweep-seconds+ 60
  "Seconds between sweeps of the cores, worker records and requests that
   servers which have gone left behind.")

(defparameter *tick-seconds* 0.25
  "How long the supervisor loop sleeps between ticks. Registrations are scanned
   on every tick.")

(defparameter *usage*
  "Usage: dsmr-bus-host [--help]

The host bus service. One process per host runs the broker of every bus on
the host and the watch for every agent registered with it, writing each
agent's wake lines, heartbeat and pid file where its listeners already look.
It is started by systemd as a user service and takes no arguments. Run by
hand, it serves the same state root and will not start beside a running copy.

State root: $XDG_STATE_HOME/dsmr-mcp/, or ~~/.local/state/dsmr-mcp/ when
XDG_STATE_HOME is unset (here: ~Adsmr-mcp/). host/ holds the service's own
records and the fleet error log, bus/ the buses, watch/ the agents' files.

Exit status: 0 after an orderly stop on SIGTERM, 1 when another copy already
holds the service lock, 64 on an argument it does not take, 70 when it could
not start, 75 when its supervisor loop stalled.
"
  "The --help text, a format control taking the state home.")

;;; ---------------------------------------------------------------- the service

(defstruct (service (:constructor %make-service
                        (&key pid report-fn feed-p memory-reader memory-thresholds
                              memory-threshold-warnings
                         &aux (registry (registry:make-registry :service-pid pid)))))
  "One running host service. Made by MAKE-SERVICE.

   PID is the pid its records name and REGISTRY the agents it serves. MUTEX is
   held whenever those agents are changed or handed records, by the supervisor
   and by every bus reader alike. BROKERS and WATCHES map each served bus (NIL
   for the unnamed bus) to its broker and its reader; PROGRESS keeps, for each
   of those threads, its progress count and when the count last moved.
   REPORT-FN takes every report. FEED-P says whether the readers subscribe to
   the brokers' publications. LAST-SECOND and LAST-FIVE are when the once a
   second and once every five seconds duties last ran, in Unix seconds.
   SCANNED says the registrations have been read once, READY-P that systemd
   has been told the service is ready. STOPPING asks every thread to end;
   STOPPED says the orderly stop has run. LOCK-FD holds the service lock.

   MEMORY-READER returns the host's memory readings when called with no
   arguments. MEMORY-THRESHOLDS say where pressure starts and stops, and
   MEMORY-THRESHOLD-WARNINGS are what was wrong with the environment they were
   read from, until they have been reported. MEMORY-STATE is where the
   classifier stands, MEMORY-SINCE when the current verdict began and
   LAST-MEMORY-SUMMARY the last verdict with the readings behind it.
   LAST-MEMORY-ACTION is when a pool was last asked to give memory back,
   UNRELIEVED-REPORTED-P says this episode of pressure has been reported as
   unrelieved, and LAST-OWNER-SWEEP is when gone servers' files were last
   swept. All times are Unix seconds."
  pid
  registry
  (mutex (sb-thread:make-mutex :name "host service"))
  (brokers (make-hash-table :test 'equal))
  (watches (make-hash-table :test 'equal))
  (progress (make-hash-table :test 'equal))
  report-fn
  (feed-p t)
  last-second
  last-five
  (scanned nil)
  (ready-p nil)
  (stopping nil)
  (stopped nil)
  lock-fd
  memory-reader
  memory-thresholds
  memory-threshold-warnings
  (memory-state (memory:make-memory-state))
  (memory-since nil)
  (last-memory-summary nil)
  (last-memory-action nil)
  (unrelieved-reported-p nil)
  (last-owner-sweep nil))

(defun make-service (&key (pid (sb-posix:getpid))
                          (report-fn #'ident:report-to-logs)
                          (feed-p t)
                          (memory-reader #'memory:read-memory-readings)
                          memory-thresholds)
  "A host service for the process PID that reports through REPORT-FN, its bus
   readers subscribing to the brokers' publications when FEED-P is true.

   MEMORY-READER is called once a second for the host's memory. The pressure
   thresholds are MEMORY-THRESHOLDS when given, else read from the environment
   here, once; what the environment got wrong is reported on the first memory
   check, through REPORT-FN like every other finding."
  (multiple-value-bind (thresholds warnings)
      (if memory-thresholds
          (values memory-thresholds '())
          (memory:thresholds-from-environment))
    (%make-service :pid pid :report-fn report-fn :feed-p feed-p
                   :memory-reader memory-reader
                   :memory-thresholds thresholds
                   :memory-threshold-warnings warnings)))

(defmacro with-service-lock ((svc) &body body)
  "Run BODY holding SVC's mutex, the one the bus readers hold while they hand
   records to agents."
  `(sb-thread:with-recursive-lock ((service-mutex ,svc))
     ,@body))

(defun %bus-key (name)
  "NAME as the agents' registrations spell it: NIL for the unnamed bus."
  (if (or (null name) (zerop (length name)) (string= name "default"))
      nil
      name))

(defun %subject (bus)
  "What a report about BUS is about: its name, `default` for the unnamed one."
  (or (%bus-key bus) "default"))

(defun %identities (svc)
  "The agents SVC serves, as a fresh list taken under its mutex."
  (with-service-lock (svc)
    (loop for identity being the hash-values
            of (registry:registry-identities (service-registry svc))
          collect identity)))

(defun %duty (svc name thunk &key bus id (subject name))
  "Run THUNK, one of SVC's duties, under the healing protocol with SVC's report
   function, and return what it returns. An error that is not a fault is
   reported under duty-failed and NIL is returned, so one failing duty never
   stops the loop."
  (let ((report-fn (service-report-fn svc)))
    (handler-case
        (conditions:call-with-healing thunk :report-fn report-fn)
      (error (e)
        (ignore-errors
         (funcall report-fn :error "duty-failed" :bus bus :id id :subject subject
                  :msg (format nil "~A: ~A" name e)))
        nil))))

;;; ------------------------------------------------------------------- systemd

(defun sd-notify (message &key (socket (uiop:getenv "NOTIFY_SOCKET")))
  "Send MESSAGE, such as READY=1 or WATCHDOG=1, to the service manager's
   notification SOCKET, and return true. Does nothing and returns NIL when
   there is no socket, which is the case whenever the service is not run by
   systemd. A socket name starting with @ is in the abstract namespace.

   One datagram socket is opened per message and closed straight after; a
   failure to send is signalled."
  (when (and socket (plusp (length socket)))
    (let* ((abstract-p (char= (char socket 0) #\@))
           (sock (make-instance (if abstract-p
                                    'sb-bsd-sockets:local-abstract-socket
                                    'sb-bsd-sockets:local-socket)
                                :type :datagram)))
      (unwind-protect
           (sb-bsd-sockets:socket-send sock message nil
                                       :address (list (if abstract-p
                                                          (subseq socket 1)
                                                          socket)))
        (sb-bsd-sockets:socket-close sock))
      t)))

(defun %notify (svc message)
  "Send MESSAGE to systemd, reporting a failure rather than letting it end the
   tick."
  (handler-case (sd-notify message)
    (error (e)
      (ignore-errors
       (funcall (service-report-fn svc) :warn "notify-failed" :subject "systemd"
                :msg (format nil "~A could not be sent: ~A" message e)))
      nil)))

;;; -------------------------------------------------------------- the watchdog

(defun progress-step (stamp progress now)
  "STAMP, a thread's (count . when-it-last-moved), updated with its current
   PROGRESS count seen at NOW. Pure."
  (if (and stamp (eql (car stamp) progress))
      stamp
      (cons progress now)))

(defun progress-fresh-p (stamp now &key (window +progress-window+))
  "True when the count in STAMP moved within WINDOW seconds of NOW."
  (and stamp (<= (- now (cdr stamp)) window) t))

(defun %threads-progressing-p (svc now)
  "Note how far every serving broker thread and every bus reader thread has got
   at NOW, and answer true when each has moved within the progress window. A
   broker waiting for the role is not counted: it is meant to be still."
  (let ((table (service-progress svc))
        (all t))
    (flet ((note (key progress)
             (let ((stamp (progress-step (gethash key table) progress now)))
               (setf (gethash key table) stamp)
               (unless (progress-fresh-p stamp now)
                 (setf all nil)))))
      (maphash (lambda (bus bb)
                 (if (eq (brokers:bus-broker-state bb) :serving)
                     (note (cons :broker bus) (brokers:bus-broker-progress bb))
                     (remhash (cons :broker bus) table)))
               (service-brokers svc))
      (maphash (lambda (bus bw)
                 (note (cons :watch bus) (buswatch:bus-watch-progress bw)))
               (service-watches svc)))
    all))

;;; ----------------------------------------------------------------- the duties

(defun %roster-dir (bus)
  "Where BUS's roster lives."
  (broker:bus-paths-roster-dir (broker:make-bus-paths (broker:default-state-root bus))))

(defun %leader-registered-p (svc bus)
  "True when the leader BUS's roster declares is an agent SVC serves on BUS, so
   a long degradation of the bus has somebody registered to act on it."
  (let* ((paths (ignore-errors (broker:make-bus-paths (broker:default-state-root bus))))
         (leader (and paths (ignore-errors
                             (roster:leader (broker:bus-paths-roster-state paths))))))
    (and leader
         (let ((wanted (hostfiles:normalise-agent-id leader)))
           (some (lambda (identity)
                   (and (equal (%bus-key (ident:identity-bus identity)) (%bus-key bus))
                        (eq (ident:identity-state identity) :serving)
                        (equal (hostfiles:normalise-agent-id (ident:identity-id identity))
                               wanted)))
                 (%identities svc))))))

(defun %scan-registrations (svc now)
  "Bring the agents SVC serves into line with the registration files."
  (%duty svc "registrations"
         (lambda ()
           (with-service-lock (svc)
             (registry:scan-registrations (service-registry svc) now
                                          :report-fn (service-report-fn svc)))))
  (setf (service-scanned svc) t))

(defun %write-beat (now)
  "Refresh the service's beat file, whose write date says it is running."
  (with-open-file (out (hostfiles:service-beat-path) :direction :output
                                                     :if-exists :supersede
                                                     :if-does-not-exist :create)
    (format out "~D~%" now)))

(defun %tick-identities (svc now)
  "Look at every agent's session, then do every agent's duties for this tick,
   with one count of the readers of every agent's log."
  (let ((reg (service-registry svc))
        (report-fn (service-report-fn svc)))
    (with-service-lock (svc)
      (%duty svc "sessions"
             (lambda () (registry:check-sessions reg now :report-fn report-fn)))
      (let* ((identities (%identities svc))
             (counts (ident:log-reader-counts
                      (mapcar #'ident:identity-log-path identities))))
        (dolist (identity identities)
          (%duty svc "identity"
                 (lambda ()
                   (let ((result (ident:identity-tick
                                  identity now
                                  :readers (gethash (uiop:native-namestring
                                                     (ident:identity-log-path identity))
                                                    counts)
                                  :report-fn report-fn)))
                     (registry:settle-tick reg identity result :report-fn report-fn)))
                 :bus (ident:identity-bus identity)
                 :id (ident:identity-id identity)
                 :subject (ident:identity-stem identity)))))))

(defun %check-brokers (svc now)
  "Look at every bus's broker. NOW is Unix seconds; the brokers keep universal
   time, so it is converted here."
  (let ((universal (+ now +unix-epoch+)))
    (maphash (lambda (bus bb)
               (%duty svc "broker"
                      (lambda ()
                        (brokers:check-bus-broker
                         bb (service-pid svc) universal
                         :report-fn (service-report-fn svc)
                         :leader-registered-p (lambda (name)
                                                (%leader-registered-p svc name))))
                      :bus bus :subject (%subject bus)))
             (service-brokers svc))))

(defun %live-worker-records (svc &key prune)
  "The worker records the pools of live servers have published, as plists.

   A record is read only when the server its file name names is still the
   process it was, and used only when the server named inside agrees with that
   name, so nothing is ever asked of a server on the strength of a record filed
   under another's name. With PRUNE, a gone server's record is removed and a
   record that disagrees with its name is reported; without it, both are only
   passed over."
  (let ((report-fn (service-report-fn svc))
        (records '()))
    (dolist (stem (pool-records:worker-record-stems) (nreverse records))
      (multiple-value-bind (pid start) (pool-records:parse-server-stem stem)
        (if (not (hostfiles:process-matches-p pid start))
            (when (and prune (pool-records:remove-worker-record stem))
              (funcall report-fn :info "worker-record-swept" :subject stem
                       :msg (format nil "server ~A is gone; its worker record was removed"
                                    stem)))
            (multiple-value-bind (plist status)
                (pool-records:read-worker-record (pool-records:worker-record-path stem))
              (cond ((not (eq status :ok)))
                    ((and (eql (getf plist :server-pid) pid)
                          (eql (getf plist :server-start) start))
                     (push plist records))
                    (prune
                     (funcall report-fn :warn "worker-record-mismatch" :subject stem
                              :msg (format nil "the record filed as ~A names server ~A-~A; ~
                                                nothing is asked on its strength"
                                           stem (getf plist :server-pid)
                                           (getf plist :server-start)))))))))))

(defun %worker-counts (records)
  "The hibernated and the resident workers in RECORDS, as two values."
  (let ((hibernated 0) (resident 0))
    (dolist (record records)
      (dolist (worker (getf record :workers))
        (when (listp worker)
          (if (eq (getf worker :state) :hibernated)
              (incf hibernated)
              (incf resident)))))
    (values hibernated resident)))

(defun %report-threshold-warnings (svc)
  "Report, once, each pressure threshold the environment set to something the
   service cannot use, so a mistyped setting is seen rather than quietly
   replaced by its default."
  (let ((warnings (service-memory-threshold-warnings svc)))
    (setf (service-memory-threshold-warnings svc) '())
    (dolist (text warnings)
      (funcall (service-report-fn svc) :warn "memory-threshold-ignored"
               :subject (subseq text 0 (or (position #\= text) (length text)))
               :msg text))))

(defun %standing-requests (svc now)
  "The requests still waiting for a live pool at NOW, as (path . plist).

   A request whose server has gone is removed. One left unanswered for longer
   than the request timeout is withdrawn and reported, because its pool has
   stopped listening and would otherwise hold up relief for every other."
  (let ((report-fn (service-report-fn svc))
        (standing '()))
    (dolist (entry (pool-records:pending-requests) (nreverse standing))
      (destructuring-bind (path . plist) entry
        (let ((name (file-namestring path))
              (at (getf plist :requested-at)))
          (cond ((not (hostfiles:process-matches-p (getf plist :server-pid)
                                                   (getf plist :server-start)))
                 (when (pool-records:remove-request path)
                   (funcall report-fn :info "hibernate-request-swept" :subject name
                            :msg "its server is gone; the request was removed")))
                ((or (null at) (> (- now at) +memory-request-timeout+))
                 (pool-records:remove-request path)
                 (funcall report-fn :warn "memory-request-stale" :subject name
                          :msg (format nil "no answer within ~D s; the request was withdrawn"
                                       +memory-request-timeout+)))
                (t (push entry standing))))))))

(defun %relieve-pressure (svc now)
  "Ask one pool to give memory back, when that may be done at NOW, and return
   what was done: :REQUESTED, :IN-FLIGHT, :SPACED, or NIL when nothing was
   asked.

   Nothing is asked while any request stands anywhere on the host, nor within
   the action spacing of the last request. Otherwise the first candidate among
   the live servers' workers is asked for, through the memory-pressure fault,
   so the healing table's breaker bounds how often the service acts however
   long the pressure lasts. With no candidate, pressure that has lasted past
   the unrelieved limit is reported once for the episode."
  (when (%standing-requests svc now)
    (return-from %relieve-pressure :in-flight))
  (unless (%due-p (service-last-memory-action svc) now +memory-action-spacing+)
    (return-from %relieve-pressure :spaced))
  (let* ((thresholds (service-memory-thresholds svc))
         (records (%live-worker-records svc :prune t))
         (candidate (first (memory:rank-candidates
                            records now
                            :min-kill-age (memory:memory-thresholds-min-kill-age-seconds
                                           thresholds))))
         (since (memory:memory-state-since (service-memory-state svc))))
    (cond
      (candidate
       (let ((stem (getf candidate :stem))
             (id (getf candidate :worker-id))
             (action (getf candidate :action)))
         (restart-case
             (progn
               (conditions:raise-fault 'memory-pressure
                                       :subject "host"
                                       :detail (format nil "~(~A~) worker ~D of server ~A"
                                                       action id stem))
               nil)
           (request-hibernation ()
             :report "Ask the owning pool to hibernate or stop one idle worker."
             (pool-records:write-hibernate-request stem id action
                                                   :now now :reason "memory-pressure")
             (setf (service-last-memory-action svc) now)
             :requested))))
      ((and (not (service-unrelieved-reported-p svc))
            since
            (> (- now since) +unrelieved-seconds+))
       (setf (service-unrelieved-reported-p svc) t)
       (multiple-value-bind (hibernated resident) (%worker-counts records)
         (conditions:raise-fault 'memory-pressure-unrelieved
                                 :subject "host"
                                 :detail (format nil "short of memory for ~D s with no idle ~
                                                      worker left to ask; ~D resident, ~
                                                      ~D hibernated"
                                                 (- now since) resident hibernated)))
       nil))))

(defun %check-memory (svc now)
  "Read the host's memory at NOW, in Unix seconds, decide whether it is under
   pressure, and while it is, ask one pool at a time to give memory back.
   Returns the verdict, :OK or :PRESSURE.

   Entering pressure is reported at WARN with the readings that showed it, and
   leaving it writes the recovered line that closes the episode. The first
   check also reports any threshold the environment set to something
   unusable. Run under the healing protocol, as the supervisor runs it, since
   relief is asked for by raising a fault."
  (%report-threshold-warnings svc)
  (let ((readings (funcall (service-memory-reader svc)))
        (before (memory:memory-state-verdict (service-memory-state svc))))
    (multiple-value-bind (verdict state)
        (memory:classify-memory readings (service-memory-state svc) now
                                (service-memory-thresholds svc))
      (let* ((some (memory:memory-readings-some-avg10 readings))
             (available (memory:available-fraction readings))
             (percent (and available (round (* 100 available)))))
        (setf (service-memory-state svc) state
              (service-last-memory-summary svc) (list :state verdict
                                                      :some-avg10 some
                                                      :available-percent percent))
        (when (or (null (service-memory-since svc)) (not (eq verdict before)))
          (setf (service-memory-since svc) now))
        (cond ((and (eq verdict :pressure) (eq before :ok))
               (funcall (service-report-fn svc) :warn "memory-pressure" :subject "host"
                        :msg (format nil "the host is short of memory: some avg10=~
                                          ~:[-~;~:*~,1F~] available=~:[-~;~:*~D%~]"
                                     some percent)))
              ((and (eq verdict :ok) (eq before :pressure))
               (fleetlog:fleet-recovered "memory-pressure" :subject "host")
               (when (service-unrelieved-reported-p svc)
                 (fleetlog:fleet-recovered "memory-pressure-unrelieved" :subject "host"))
               (setf (service-unrelieved-reported-p svc) nil)))
        (when (eq verdict :pressure)
          (%relieve-pressure svc now))
        verdict))))

(defun %sweep-owners (svc now)
  "Once every owner-sweep interval, remove what servers that have gone left
   behind: hibernated cores, worker records and requests. A pool clears its
   own files when it stops; this catches every pool that never got to."
  (when (%due-p (service-last-owner-sweep svc) now +owner-sweep-seconds+)
    (setf (service-last-owner-sweep svc) now)
    (%duty svc "owner-sweep"
           (lambda ()
             (pool-records:sweep-dead-owners :report-fn (service-report-fn svc)))
           :subject "host")))

(defun %memory-summary (svc)
  "How memory stands, for the status summary: the verdict and since when, the
   readings behind it, the hibernated and resident workers of live servers,
   and when a pool was last asked to give memory back. Times are universal
   time, as everywhere else in the summary."
  (let ((summary (service-last-memory-summary svc))
        (since (service-memory-since svc))
        (last (service-last-memory-action svc)))
    (multiple-value-bind (hibernated resident) (%worker-counts (%live-worker-records svc))
      (list :state (or (getf summary :state) :unknown)
            :since (and since (+ since +unix-epoch+))
            :some-avg10 (getf summary :some-avg10)
            :available-percent (getf summary :available-percent)
            :hibernated hibernated
            :resident resident
            :last-action (and last (+ last +unix-epoch+))))))

(defun %ready-now-p (svc)
  "True once the registrations have been read and every bus's broker serves
   its bus or has recorded that a broker a client elected holds it."
  (and (service-scanned svc)
       (plusp (hash-table-count (service-brokers svc)))
       (loop for bb being the hash-values of (service-brokers svc)
             always (or (eq (brokers:bus-broker-state bb) :serving)
                        (brokers:bus-broker-degraded-since bb)))))

(defun %tell-systemd (svc now)
  "Say READY=1 once the service is ready, and from then on WATCHDOG=1 on every
   tick of this once a second duty in which every thread has progressed."
  (unless (service-ready-p svc)
    (when (%ready-now-p svc)
      (setf (service-ready-p svc) t)
      (%notify svc "READY=1")
      (fleetlog:service-log :info "ready buses=~D"
                            (hash-table-count (service-brokers svc)))))
  (let ((progressing (%threads-progressing-p svc now)))
    (when (and (service-ready-p svc) progressing)
      (%notify svc "WATCHDOG=1"))))

(defun %serve-bus (svc bus)
  "Start BUS's broker and its reader when SVC has neither yet."
  (let ((report-fn (service-report-fn svc))
        (stop-fn (lambda () (service-stopping svc))))
    (unless (gethash bus (service-brokers svc))
      (let ((bb (%duty svc "broker-start"
                       (lambda ()
                         (brokers:start-bus-broker bus :stop-fn stop-fn
                                                       :report-fn report-fn))
                       :bus bus :subject (%subject bus))))
        (when (brokers:bus-broker-p bb)
          (setf (gethash bus (service-brokers svc)) bb))))
    (unless (gethash bus (service-watches svc))
      (let ((bw (%duty svc "bus-watch-start"
                       (lambda ()
                         (buswatch:open-bus-watch bus :feed (service-feed-p svc)
                                                      :lock (service-mutex svc)))
                       :bus bus :subject (%subject bus))))
        (when (buswatch:bus-watch-p bw)
          (buswatch:start-bus-watch-thread bw stop-fn
                                           (lambda () (%identities svc))
                                           :report-fn report-fn)
          (setf (gethash bus (service-watches svc)) bw))))))

(defun %discover (svc)
  "Find the buses SVC should serve, start a broker and a reader for each new
   one, and return the list."
  (let* ((registered (remove-duplicates
                      (mapcar (lambda (identity) (%bus-key (ident:identity-bus identity)))
                              (%identities svc))
                      :test #'equal))
         (buses (or (%duty svc "discovery"
                           (lambda () (brokers:discover-buses :registered-buses registered)))
                    (list nil))))
    (dolist (bus buses)
      (%serve-bus svc bus))
    buses))

(defun %adopt (svc now)
  "Take over every detached watcher still running on this state root."
  (%duty svc "adoption"
         (lambda ()
           (with-service-lock (svc)
             (registry:adopt-legacy-watchers (service-registry svc) now
                                             :report-fn (service-report-fn svc))))))

(defun %served-buses (svc)
  "The buses SVC runs a broker for, the unnamed one first, then by name."
  (sort (loop for bus being the hash-keys of (service-brokers svc) collect bus)
        (lambda (a b)
          (cond ((null a) (not (null b)))
                ((null b) nil)
                (t (string< a b))))))

(defun %write-status (svc now)
  "Write the status summary --host-status reads: the service's pid, when it was
   written (universal time), each bus with its owner, each registration with
   its state, the gaps between each bus's roster and its registrations, and
   how memory stands."
  (let* ((buses (%served-buses svc))
         (findings (%duty svc "roster"
                          (lambda ()
                            (with-service-lock (svc)
                              (registry:roster-gap-findings
                               (service-registry svc) buses #'%roster-dir
                               :report-fn (service-report-fn svc))))))
         (memory (%duty svc "memory-status" (lambda () (%memory-summary svc))
                        :subject "host")))
    (%duty svc "status"
           (lambda ()
             (hostfiles:ensure-host-dir)
             (hostfiles:write-plist-file
              (hostfiles:service-status-path)
              (list* :pid (service-pid svc)
                     :written-at (+ now +unix-epoch+)
                     :buses (loop for bus in buses
                                  collect (brokers:bus-broker-snapshot
                                           (gethash bus (service-brokers svc))
                                           (service-pid svc)))
                     :registrations (with-service-lock (svc)
                                      (registry:registry-snapshot (service-registry svc)))
                     :findings (if (listp findings) findings '())
                     (and (listp memory) memory (list :memory memory))))))))

(defun %due-p (last now interval)
  "True when a duty last run at LAST is due again at NOW."
  (or (null last) (>= (- now last) interval)))

(defun supervisor-tick (svc now)
  "Do SVC's duties for one tick at NOW, in Unix seconds, and return SVC.

   Every tick reads the registrations. Once every five seconds the service
   takes over any detached watcher left running, looks for buses to serve,
   starting a broker and a reader for each new one, and, when a minute has
   passed since it last did, removes what servers that have gone left behind.
   Once a second it refreshes its beat, looks at every agent's session and
   does every agent's duties, checks every broker, reads the host's memory and
   relieves pressure one worker at a time, and tells systemd it is ready and
   alive. Last, it writes its status summary, every five seconds and also on
   the tick it becomes ready, so the summary never says a bus is unserved for
   five seconds after it is served. The first tick does all of it."
  (let ((five (%due-p (service-last-five svc) now 5))
        (second (%due-p (service-last-second svc) now 1))
        (was-ready (service-ready-p svc)))
    (%scan-registrations svc now)
    (when five
      (%adopt svc now)
      (%discover svc)
      (%sweep-owners svc now))
    (when second
      (setf (service-last-second svc) now)
      (%duty svc "beat" (lambda () (%write-beat now)))
      (%tick-identities svc now)
      (%check-brokers svc now)
      (%duty svc "memory" (lambda () (%check-memory svc now)) :subject "host")
      (%tell-systemd svc now))
    (when five
      (setf (service-last-five svc) now))
    (when (or five (and (not was-ready) (service-ready-p svc)))
      (%write-status svc now)))
  svc)

;;; ------------------------------------------------------------ start and stop

(defun %write-pid-file (pid)
  "Record PID as the service's in its pid file."
  (with-open-file (out (hostfiles:service-pid-path) :direction :output
                                                    :if-exists :supersede
                                                    :if-does-not-exist :create)
    (format out "~D~%" pid)))

(defun start-service (svc &key (now (%unix-time)))
  "Record SVC as the running host service, at NOW (Unix seconds), and return it.

   Writes the pid file and the state record. When an earlier run left a pid
   file but no clean-stop marker, it ended without an orderly stop, and that is
   reported to the fleet log as an unclean restart and counted in the state
   record. The marker is then removed, so a crash of this run reads the same
   way to the next."
  (hostfiles:ensure-host-dir)
  (let* ((previous-pid (hostfiles:read-service-pid))
         (clean (probe-file (hostfiles:clean-stop-path)))
         (unclean (and previous-pid (not clean)))
         (old (multiple-value-bind (plist status)
                  (hostfiles:read-plist-file (hostfiles:service-state-path))
                (and (eq status :ok) plist)))
         (count (+ (let ((n (getf old :unclean-restarts))) (if (integerp n) n 0))
                   (if unclean 1 0))))
    (%write-pid-file (service-pid svc))
    (hostfiles:write-plist-file
     (hostfiles:service-state-path)
     (list* :pid (service-pid svc)
            :started-at (+ now +unix-epoch+)
            :unclean-restarts count
            (loop for (key value) on old by #'cddr
                  unless (member key '(:pid :started-at :unclean-restarts))
                    append (list key value))))
    (when clean
      (ignore-errors (delete-file clean)))
    (when unclean
      (funcall (service-report-fn svc) :warn "unclean-restart" :subject "service"
               :msg (format nil "the previous run, pid ~D, ended without an orderly ~
                                 stop; ~D such restart~:P recorded"
                            previous-pid count))))
  svc)

(defun stop-service (svc &key (mark-clean t))
  "Stop SVC in order, and return it. Safe to call more than once.

   Every thread is asked to end; each broker lets its role go without
   archiving, then each reader closes, then every agent's descriptors are
   closed with its pid file, heartbeat and registration left in place for the
   service that follows. With MARK-CLEAN, the clean-stop marker is written last,
   so the next start knows this was not a crash."
  (unless (service-stopped svc)
    (setf (service-stopping svc) t)
    (maphash (lambda (bus bb)
               (declare (ignore bus))
               (ignore-errors (brokers:stop-bus-broker bb :join-seconds 1)))
             (service-brokers svc))
    (maphash (lambda (bus bw)
               (declare (ignore bus))
               (ignore-errors (buswatch:close-bus-watch bw :join-seconds 1)))
             (service-watches svc))
    (dolist (identity (%identities svc))
      (ignore-errors (ident:release-identity identity :remove-files nil)))
    (setf (service-stopped svc) t)
    (when mark-clean
      (with-open-file (out (hostfiles:clean-stop-path) :direction :output
                                                       :if-exists :supersede
                                                       :if-does-not-exist :create)
        (format out "~D~%" (%unix-time)))))
  svc)

;;; ---------------------------------------------------------------- the process

(defvar *stop-requested* nil
  "Set by SIGTERM or SIGINT; the supervisor loop ends on the next tick.")

(defvar *last-loop* 0
  "Internal real time at which the supervisor loop last came round.")

(defun %note-loop ()
  (setf *last-loop* (get-internal-real-time)))

(defun %start-stall-watchdog (stall-seconds)
  "Start a thread that ends the process with status 75 once the supervisor
   loop has not come round for STALL-SECONDS.

   A wedged service is worse than a dead one: it holds the service lock and
   every agent's pid file, so nothing can take its place, and its agents stop
   hearing the bus. Ending it lets systemd start it again. Under systemd's own
   watchdog this is a second line of defence; without one it is the only one.
   Nothing is written on the way out, since the stream the loop wedged on may
   be the one that would carry it."
  (%note-loop)
  (sb-thread:make-thread
   (lambda ()
     (loop
       (sleep (max 0.2 (min 5 (/ stall-seconds 4))))
       (when (> (- (get-internal-real-time) *last-loop*)
                (* stall-seconds internal-time-units-per-second))
         (sb-ext:exit :code 75 :abort t))))
   :name "host service stall watchdog"))

(defun %take-service-lock ()
  "Take the service lock without waiting, and return its descriptor, or NIL
   when another process holds it. The descriptor is kept for the life of the
   process."
  (let ((fd (election:open-lock (hostfiles:service-lock-path))))
    (if (election:try-lock-exclusive fd)
        fd
        (progn (election:close-lock fd) nil))))

(defun %install-signal-handlers ()
  "SIGTERM and SIGINT ask for an orderly stop; SIGHUP is ignored."
  (flet ((request-stop (signo context info)
           (declare (ignore signo context info))
           (setf *stop-requested* t)))
    (sb-sys:enable-interrupt sb-posix:sigterm #'request-stop)
    (sb-sys:enable-interrupt sb-posix:sigint #'request-stop)
    (sb-sys:enable-interrupt sb-posix:sighup :ignore)))

(defun %run ()
  "Run the service until it is asked to stop, then stop it in order and exit 0."
  (hostfiles:ensure-host-dir)
  (let ((fd (%take-service-lock)))
    (unless fd
      (format *error-output* "dsmr-bus-host: another host service holds the lock ~A; ~
                              not starting~%"
              (uiop:native-namestring (hostfiles:service-lock-path)))
      (finish-output *error-output*)
      (sb-ext:exit :code 1 :abort t))
    (fleetlog:install-fleet-log)
    (setf *stop-requested* nil)
    (%install-signal-handlers)
    (let ((svc (make-service)))
      (setf (service-lock-fd svc) fd)
      (start-service svc)
      (fleetlog:service-log :info "started pid=~D state=~A" (service-pid svc)
                            (uiop:native-namestring (hostfiles:state-home)))
      (%start-stall-watchdog +stall-seconds+)
      (loop until *stop-requested*
            do (%note-loop)
               (supervisor-tick svc (%unix-time))
               (sleep *tick-seconds*))
      (%note-loop)
      (%notify svc "STOPPING=1")
      (stop-service svc :mark-clean t)
      (fleetlog:service-log :info "stopped in order pid=~D" (service-pid svc))
      (sb-ext:exit :code 0 :abort t))))

(defun main ()
  "Entry point of the dsmr-bus-host executable. Takes no arguments but --help.

   The debugger and the low-level monitor are turned off first: systemd's
   watchdog ends a wedged service with SIGABRT, and a process that answered by
   waiting in the monitor for a command would never be restarted."
  (sb-ext:disable-debugger)
  (let ((args (uiop:command-line-arguments))
        (home (uiop:native-namestring (hostfiles:state-home))))
    (cond
      ((or (member "--help" args :test #'string=) (member "-h" args :test #'string=))
       (format *standard-output* *usage* home)
       (finish-output *standard-output*)
       (sb-ext:exit :code 0))
      (args
       (format *error-output* "dsmr-bus-host: no such argument: ~A~%~%" (first args))
       (format *error-output* *usage* home)
       (finish-output *error-output*)
       (sb-ext:exit :code 64))))
  (handler-case (%run)
    (error (e)
      (format *error-output* "dsmr-bus-host: ~A~%" e)
      (finish-output *error-output*)
      (sb-ext:exit :code 70 :abort t))))
