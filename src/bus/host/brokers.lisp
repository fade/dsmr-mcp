;;;; src/bus/host/brokers.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The bus brokers the host service runs: one thread per bus, in place of a
;;;; broker process elected by whichever client happened to come first.
;;;;
;;;; The service never rotates a bus's log when it stops, and it holds a
;;;; membership of each bus of its own for as long as it runs. Under systemd a
;;;; restart or a reboot reaches the service as SIGTERM, which is a clean stop,
;;;; and a broker that rotates its log on a clean stop whenever it is the last
;;;; member out is exactly what stranded every stable cursor on the host after
;;;; past reboots: the log was emptied and renumbered under agents whose cursors
;;;; still named positions in the old one. So the service's brokers are always
;;;; stopped with archiving refused, and the extra membership, taken before the
;;;; service even contends for the role, means a broker elsewhere that does ask
;;;; to archive cannot find itself the last member while the service lives.
;;;; Rotating a log is a deliberate act now, never a side effect of a stop.
;;;;
;;;; A client may still elect a broker of its own while the service is down,
;;;; and that keeps the bus working. When the service comes back it waits behind
;;;; that broker in the election, which costs nothing, and records the bus as
;;;; degraded so a leader can hand it back; it takes the role the moment the
;;;; incumbent lets go. A broker the service runs is told apart from one a
;;;; client elected by the pid in the bus's broker identity record.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-bus-host/src/bus/host/brokers
  (:use #:cl)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:election #:dsmr-mcp/src/bus/election)
                    (#:selector #:dsmr-mcp/src/bus/selector)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:ident #:dsmr-bus-host/src/bus/host/identity))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%pid-alive-p)
  (:export
   #:bus-broker
   #:bus-broker-p
   #:bus-broker-name
   #:bus-broker-paths
   #:bus-broker-members-fd
   #:bus-broker-state
   #:bus-broker-broker
   #:bus-broker-thread
   #:bus-broker-progress
   #:bus-broker-standby-since
   #:bus-broker-degraded-since
   #:bus-broker-incumbent-pid
   #:bus-broker-last-error
   #:start-bus-broker
   #:stop-bus-broker
   #:check-bus-broker
   #:discover-buses
   #:bus-broker-snapshot))

(in-package #:dsmr-bus-host/src/bus/host/brokers)

(defconstant +still-degraded-seconds+ 600
  "How long a bus may stay degraded, with its leader registered to act on it,
   before that is reported as an error rather than a warning.")

(defstruct (bus-broker (:constructor %make-bus-broker))
  "The service's broker for the bus NAME (NIL for the unnamed bus).

   PATHS are the bus's paths and MEMBERS-FD the service's own membership of the
   bus, held until the broker is stopped. STATE is :STANDBY while the thread
   waits for the role, :SERVING once it has it, :FAILED when the thread ended
   with an error (kept in LAST-ERROR) and :STOPPED once stopped. BROKER is the
   serving broker and THREAD the thread running it; PROGRESS counts its serve
   steps. STANDBY-SINCE is when the thread began waiting and DEGRADED-SINCE
   when the bus was found held by a broker a client elected, whose pid is
   INCUMBENT-PID; both are universal time. STILL-REPORTED says the long
   degradation has been reported. STOP-FN, when given, is asked whether to stop
   at every step, and REPORT-FN is the report function checks use by default."
  name paths members-fd
  (state :standby)
  broker thread
  (progress 0)
  standby-since degraded-since incumbent-pid
  (still-reported nil)
  last-error
  (stop-requested nil)
  stop-fn
  (report-fn #'ident:report-to-logs))

(defun %bus-key (name)
  "NAME as the agents' registrations spell it: NIL for the unnamed bus."
  (if (or (null name) (zerop (length name)) (string= name "default"))
      nil
      name))

(defun %subject (bb-or-name)
  "What a fault about a bus is about: its name, `default` for the unnamed one."
  (or (%bus-key (if (bus-broker-p bb-or-name) (bus-broker-name bb-or-name) bb-or-name))
      "default"))

;;; ------------------------------------------------------------------ the thread

(defun %stopping-p (bb)
  "True once BB has been asked to stop, by STOP-BUS-BROKER or its STOP-FN."
  (or (bus-broker-stop-requested bb)
      (let ((fn (bus-broker-stop-fn bb)))
        (and fn (funcall fn)))))

(defun %serve (bb)
  "The body of BB's thread: wait for the role, serve until asked to stop, and
   let the role go without archiving. An error ends the thread in :FAILED with
   the error kept, and never reaches the rest of the process."
  (let ((br nil))
    (handler-case
        (progn
          (unwind-protect
               (progn
                 (setf br (broker:start-broker (bus-broker-paths bb) :block t))
                 (setf (bus-broker-broker bb) br
                       (bus-broker-state bb) :serving)
                 (loop until (%stopping-p bb)
                       do (broker:broker-step br)
                          (broker:custodial-tick br)
                          (incf (bus-broker-progress bb))))
            (when br
              (broker:stop-broker br :archive nil)))
          (setf (bus-broker-state bb) :stopped))
      (error (e)
        (setf (bus-broker-last-error bb) e
              (bus-broker-state bb) :failed)))))

(defun %launch (bb)
  "Start BB's thread, waiting for the role, and return BB."
  (setf (bus-broker-state bb) :standby
        (bus-broker-broker bb) nil
        (bus-broker-last-error bb) nil
        (bus-broker-standby-since bb) (get-universal-time))
  (setf (bus-broker-thread bb)
        (sb-thread:make-thread (lambda () (%serve bb))
                               :name (format nil "bus broker ~A" (%subject bb))))
  bb)

(defun start-bus-broker (name &key stop-fn (report-fn #'ident:report-to-logs))
  "Run the broker for the bus NAME (NIL for the unnamed bus) in a thread of its
   own, and return its BUS-BROKER. STOP-FN, when given, is asked at every step
   whether to stop. REPORT-FN is kept as the default for later checks.

   The service joins the bus as a member before its thread contends for the
   role, and keeps that membership until the broker is stopped. The thread
   waits behind any broker already serving the bus, which costs nothing.

   A name that cannot name a bus raises BUS-ROOT-UNUSABLE, and NIL is returned:
   that bus is not served and the others carry on."
  (let ((paths (handler-case (broker:make-bus-paths (broker:default-state-root
                                                     (%bus-key name)))
                 (selector:invalid-bus-name (e)
                   (conditions:raise-fault 'conditions:bus-root-unusable
                                           :bus name :subject (%subject name)
                                           :detail (princ-to-string e))
                   (return-from start-bus-broker nil)))))
    (broker:ensure-bus-dirs paths)
    (%launch (%make-bus-broker :name (%bus-key name)
                               :paths paths
                               :members-fd (broker:join-members paths)
                               :stop-fn stop-fn
                               :report-fn report-fn))))

(defun stop-bus-broker (bb &key (join-seconds 2))
  "Stop BB and let its membership go, and return its final state.

   A serving broker finishes its step and lets the role go without archiving,
   within JOIN-SECONDS. A broker still waiting for the role is waiting inside
   the kernel's lock call; when it has not ended within JOIN-SECONDS its thread
   is ended. The descriptor it was waiting on is then left open but holds no
   lock, and the process that stops its brokers is about to exit."
  (setf (bus-broker-stop-requested bb) t)
  (let ((thread (bus-broker-thread bb)))
    (when (and thread (sb-thread:thread-alive-p thread))
      (sb-thread:join-thread thread :default nil :timeout join-seconds)
      (when (sb-thread:thread-alive-p thread)
        (sb-thread:terminate-thread thread)
        (sb-thread:join-thread thread :default nil :timeout join-seconds))))
  (when (bus-broker-members-fd bb)
    (ignore-errors (election:close-lock (bus-broker-members-fd bb)))
    (setf (bus-broker-members-fd bb) nil))
  (unless (eq (bus-broker-state bb) :failed)
    (setf (bus-broker-state bb) :stopped))
  (bus-broker-state bb))

;;; ------------------------------------------------------------------- checks

(defun %fleet-recovered (name)
  "Tell the fleet log that the degradation of the bus NAME has cleared."
  (fleetlog:fleet-recovered "degraded" :bus name :subject (%subject name)))

(defun %incumbent (bb service-pid)
  "The identity record of the broker holding BB's bus, when that broker is a
   live process other than the service and the role is really held; else NIL."
  (let* ((paths (bus-broker-paths bb))
         (record (broker:read-broker-identity paths))
         (pid (and record (broker:broker-identity-pid record))))
    (and (integerp pid)
         (> pid 1)
         (/= pid service-pid)
         (%pid-alive-p pid)
         (broker:broker-running-p paths)
         record)))

(defun %degraded-record (bb record now)
  "The degraded record for BB's bus, held by the broker RECORD names, found at
   NOW (universal time)."
  (let ((pid (broker:broker-identity-pid record)))
    (list :bus (bus-broker-name bb)
          :root (namestring (broker:bus-paths-root (bus-broker-paths bb)))
          :incumbent-pid pid
          :incumbent-start (hostfiles:proc-starttime pid)
          :ppid-at-start (broker:broker-identity-ppid-at-start record)
          :started-at (broker:broker-identity-started-at record)
          :image (broker:broker-identity-image record)
          :detected-at now)))

(defun %leader-registered-p (leader-registered-p name)
  "LEADER-REGISTERED-P as an answer for the bus NAME: called with NAME when it
   is a function, taken as it is otherwise."
  (if (functionp leader-registered-p)
      (funcall leader-registered-p name)
      leader-registered-p))

(defun %check-standby (bb service-pid now report-fn leader-registered-p)
  "BB is waiting for the role. When a broker a client elected holds it, record
   the bus as degraded and raise CLIENT-ELECTED-BROKER, once per episode; when
   that has lasted long enough with the bus's leader registered to act, report
   it as an error, once."
  (let ((record (%incumbent bb service-pid))
        (name (bus-broker-name bb)))
    (cond
      ((null record))
      ((null (bus-broker-degraded-since bb))
       (hostfiles:write-degraded-record name (%degraded-record bb record now))
       (setf (bus-broker-degraded-since bb) now
             (bus-broker-incumbent-pid bb) (broker:broker-identity-pid record)
             (bus-broker-still-reported bb) nil)
       (conditions:raise-fault 'conditions:client-elected-broker
                               :bus name :subject (%subject bb)
                               :detail (format nil "the bus is served by a broker a client ~
                                                    elected, pid ~D; a leader can hand it ~
                                                    back with --host-restore"
                                               (broker:broker-identity-pid record))))
      ((and (not (bus-broker-still-reported bb))
            (>= (- now (bus-broker-degraded-since bb)) +still-degraded-seconds+)
            (%leader-registered-p leader-registered-p name))
       (setf (bus-broker-still-reported bb) t)
       (funcall report-fn :error "still-degraded"
                :bus name :subject (%subject bb)
                :msg (format nil "the bus has been served by a client-elected broker, ~
                                  pid ~D, for ~D s with its leader registered"
                             (bus-broker-incumbent-pid bb)
                             (- now (bus-broker-degraded-since bb))))))))

(defun %check-serving (bb now report-fn recovered-fn)
  "BB serves its bus. Clear any degraded record, this run's or one an earlier
   run of the service left, and say the bus has recovered."
  (let* ((name (bus-broker-name bb))
         (since (bus-broker-degraded-since bb))
         (recorded (eq :ok (nth-value 1 (hostfiles:read-degraded-record name)))))
    (when (or since recorded)
      (hostfiles:clear-degraded-record name)
      (setf (bus-broker-degraded-since bb) nil
            (bus-broker-incumbent-pid bb) nil
            (bus-broker-still-reported bb) nil)
      (funcall report-fn :info "degraded"
               :bus name :subject (%subject bb)
               :msg (if since
                        (format nil "recovered: the service serves the bus again after ~D s"
                                (max 0 (- now since)))
                        "recovered: the service serves the bus again"))
      (when recovered-fn
        (funcall recovered-fn name)))))

(defun check-bus-broker (bb service-pid now
                         &key (report-fn (bus-broker-report-fn bb))
                              leader-registered-p
                              (recovered-fn #'%fleet-recovered))
  "Look at BB from the supervisor, as the service running with SERVICE-PID, at
   NOW (universal time). Returns BB's state.

   A broker whose thread has ended raises BROKER-THREAD-DIED offering
   RESTART-BROKER-THREAD. One waiting behind a broker a client elected records
   the bus as degraded and raises CLIENT-ELECTED-BROKER once per episode, and
   reports an error once when that has lasted ten minutes while
   LEADER-REGISTERED-P (a boolean, or a function of the bus name) says the
   bus's leader is registered to act on it. One serving clears the degraded
   record and reports the recovery, also through RECOVERED-FN when given.

   Run it under the healing supervisor; outside one a fault is an error."
  (let ((state (bus-broker-state bb))
        (thread (bus-broker-thread bb)))
    (cond
      ((or (eq state :failed)
           (and (member state '(:standby :serving))
                thread (not (sb-thread:thread-alive-p thread))))
       (restart-case
           (conditions:raise-fault 'conditions:broker-thread-died
                                   :bus (bus-broker-name bb) :subject (%subject bb)
                                   :detail (format nil "~@[~A~]"
                                                   (bus-broker-last-error bb)))
         (conditions:restart-broker-thread ()
           :report "Start the bus's broker thread again."
           (%launch bb))))
      ((eq state :standby)
       (%check-standby bb service-pid now report-fn leader-registered-p))
      ((eq state :serving)
       (%check-serving bb now report-fn recovered-fn)))
    (bus-broker-state bb)))

(defun bus-broker-snapshot (bb service-pid)
  "BB as one bus entry of the service's status summary: :BUS, :OWNER (:HOST
   while the service serves it, :CLIENT while a broker a client elected does,
   :NONE otherwise), :INCUMBENT-PID and :DEGRADED-SINCE (universal time)."
  (let* ((since (bus-broker-degraded-since bb))
         (incumbent (and (not since)
                         (eq (bus-broker-state bb) :standby)
                         (%incumbent bb service-pid))))
    (list :bus (bus-broker-name bb)
          :owner (cond (since :client)
                       (incumbent :client)
                       ((eq (bus-broker-state bb) :serving) :host)
                       (t :none))
          :incumbent-pid (cond (since (bus-broker-incumbent-pid bb))
                               (incumbent (broker:broker-identity-pid incumbent)))
          :degraded-since since)))

;;; ---------------------------------------------------------------- discovery

(defun %valid-bus-p (name)
  "True when NAME can name a bus whose sockets fit."
  (handler-case (progn (selector:bus-root name) t)
    (error () nil)))

(defun %members-held-p (path)
  "True when some process holds the membership lock at PATH. Probed with a
   non-blocking exclusive lock on a fresh descriptor, let go at once; a file
   that does not exist is not created."
  (and (probe-file path)
       (let ((fd (election:open-lock path)))
         (unwind-protect
              (if (election:try-lock-exclusive fd)
                  (progn (election:unlock fd) nil)
                  t)
           (election:close-lock fd)))))

(defun discover-buses (&key registered-buses)
  "The buses the service should serve, as a list of names with NIL for the
   unnamed bus, which always comes first: then every bus REGISTERED-BUSES
   names, then every bus directory some process is a member of. A directory
   whose name cannot name a bus is never served, so nothing outside the bus
   state directory is reached."
  (let ((found (list nil)))
    (dolist (name registered-buses)
      (let ((key (%bus-key name)))
        (when (and key (%valid-bus-p key))
          (push key found))))
    (dolist (dir (sort (ignore-errors (uiop:subdirectories (selector:bus-root nil)))
                       #'string< :key #'namestring))
      (let ((name (car (last (pathname-directory dir)))))
        (when (and (stringp name)
                   (%valid-bus-p name)
                   (%members-held-p (merge-pathnames "members" dir)))
          (push name found))))
    (remove-duplicates (nreverse found) :test #'equal :from-end t)))
