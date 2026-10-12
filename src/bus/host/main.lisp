;;;; src/bus/host/main.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The host bus service itself: its entry point, the supervisor loop that
;;;; schedules every duty the other host leaves define, the readiness and
;;;; watchdog messages it sends systemd, and the orderly stop.
;;;;
;;;; One process per host does what used to take a broker per bus and a watcher
;;;; process per agent per bus. Each bus has a broker thread and one reader
;;;; thread; every agent registered with the service is an identity the
;;;; supervisor ticks. The supervisor runs each duty under the healing protocol,
;;;; so a fault in one agent's files or one bus never stops the others, and what
;;;; cannot be healed reaches the fleet error log a leader watches.
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
                    (#:brokers #:dsmr-bus-host/src/bus/host/brokers))
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

(defstruct (service (:constructor make-service
                        (&key (pid (sb-posix:getpid))
                              (report-fn #'ident:report-to-logs)
                              (feed-p t)
                         &aux (registry (registry:make-registry :service-pid pid)))))
  "One running host service.

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
   STOPPED says the orderly stop has run. LOCK-FD holds the service lock."
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
  lock-fd)

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
   its state, and the gaps between each bus's roster and its registrations."
  (let* ((buses (%served-buses svc))
         (findings (%duty svc "roster"
                          (lambda ()
                            (with-service-lock (svc)
                              (registry:roster-gap-findings
                               (service-registry svc) buses #'%roster-dir
                               :report-fn (service-report-fn svc)))))))
    (%duty svc "status"
           (lambda ()
             (hostfiles:ensure-host-dir)
             (hostfiles:write-plist-file
              (hostfiles:service-status-path)
              (list :pid (service-pid svc)
                    :written-at (+ now +unix-epoch+)
                    :buses (loop for bus in buses
                                 collect (brokers:bus-broker-snapshot
                                          (gethash bus (service-brokers svc))
                                          (service-pid svc)))
                    :registrations (with-service-lock (svc)
                                     (registry:registry-snapshot (service-registry svc)))
                    :findings (if (listp findings) findings '())))))))

(defun %due-p (last now interval)
  "True when a duty last run at LAST is due again at NOW."
  (or (null last) (>= (- now last) interval)))

(defun supervisor-tick (svc now)
  "Do SVC's duties for one tick at NOW, in Unix seconds, and return SVC.

   Every tick reads the registrations. Once every five seconds the service
   takes over any detached watcher left running and looks for buses to serve,
   starting a broker and a reader for each new one. Once a second it refreshes
   its beat, looks at every agent's session and does every agent's duties,
   checks every broker, and tells systemd it is ready and alive. Once every five
   seconds, last, it writes its status summary. The first tick does all of it."
  (let ((five (%due-p (service-last-five svc) now 5))
        (second (%due-p (service-last-second svc) now 1)))
    (%scan-registrations svc now)
    (when five
      (%adopt svc now)
      (%discover svc))
    (when second
      (setf (service-last-second svc) now)
      (%duty svc "beat" (lambda () (%write-beat now)))
      (%tick-identities svc now)
      (%check-brokers svc now)
      (%tell-systemd svc now))
    (when five
      (setf (service-last-five svc) now)
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
