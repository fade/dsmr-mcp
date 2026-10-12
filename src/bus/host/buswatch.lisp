;;;; src/bus/host/buswatch.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The host service's watch of one bus: one reader of the bus's log, shared by
;;;; every agent the service serves on that bus.
;;;;
;;;; The log is the truth and the broker's publication is only a doorbell. The
;;;; broker appends a record to the log and then publishes nothing but its
;;;; sequence number, and that nudge can be lost three ways: a subscriber that
;;;; has just connected misses the first nudges sent to it, a subscriber that
;;;; falls behind is dropped at the high-water mark, and a broker that restarts
;;;; rebinds its socket while nudges are in flight. So no nudge is ever read for
;;;; what it says. A nudge only ends the wait early; the wait itself is capped at
;;;; a quarter of a second, and every step, nudged or not, reads the log forward
;;;; from where it last stopped. A watch with no feed at all still hears every
;;;; record within that quarter second.
;;;;
;;;; Reading once per bus and handing the records to each agent is what makes a
;;;; service for the whole host cheaper than a watcher per agent: the cost of a
;;;; read no longer multiplies by the number of agents on the bus.
;;;;
;;;; A log that grows step after step while the feed stays silent means the feed
;;;; has stopped hearing the broker. Nothing is lost, since the read found the
;;;; records, but the wake has fallen back to the slow path, so that is raised as
;;;; a fault whose heal remakes the feed. A log that restarts under the reader,
;;;; or whose generation moves, has been rotated, and every stable cursor on the
;;;; bus is stranded at once; that is raised as a fault whose heal rebases each
;;;; of them once and arms every agent on the bus again.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-bus-host/src/bus/host/buswatch
  (:use #:cl)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:tz #:dsmr-mcp/src/bus/zmq)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:ident #:dsmr-bus-host/src/bus/host/identity))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%poll-forward
                #:%unix-time
                #:%cursor-holds-seq-p
                #:%stranded-fleet-message)
  (:export
   #:bus-watch
   #:bus-watch-p
   #:bus-watch-name
   #:bus-watch-paths
   #:bus-watch-wal-path
   #:bus-watch-cursors-dir
   #:bus-watch-reader
   #:bus-watch-feed
   #:bus-watch-generation
   #:bus-watch-progress
   #:bus-watch-nudges-seen
   #:bus-watch-growth-without-nudge
   #:bus-watch-lock
   #:bus-watch-last-seq
   #:bus-watch-thread
   #:open-bus-watch
   #:close-bus-watch
   #:bus-watch-step
   #:rebase-bus-cursors
   #:start-bus-watch-thread))

(in-package #:dsmr-bus-host/src/bus/host/buswatch)

(defconstant +backstop-ms+ 250
  "The longest a step waits for a nudge before reading the log anyway.")

(defconstant +gap-ticks+ 2
  "How many steps in a row the log may grow with the feed silent before the
   feed is taken to have stopped hearing the broker.")

(defstruct (bus-watch (:constructor %make-bus-watch))
  "The service's watch of the bus NAME (NIL for the unnamed bus).

   PATHS are the bus's paths, WAL-PATH its log and CURSORS-DIR its cursors.
   READER is the one position in the log every agent on the bus is fed from.
   FEED is the subscription to the broker's publications, or NIL when the watch
   reads on the backstop alone; FEED-WANTED says whether it should have one.
   GENERATION is the log generation the reader last saw, LAST-SEQ the highest
   seq it has read. PROGRESS counts steps, NUDGES-SEEN the nudges that ended a
   wait, and GROWTH-WITHOUT-NUDGE the steps in a row in which the log grew while
   the feed said nothing. LOCK is held while agents are handed records or armed
   again; the supervisor shares it for its own changes to the same agents.
   THREAD runs the steps, and STOPPING asks it to end."
  name paths wal-path cursors-dir reader feed
  (feed-wanted t)
  (generation 0)
  (last-seq 0)
  (progress 0)
  (nudges-seen 0)
  (growth-without-nudge 0)
  lock
  thread
  (stopping nil))

(defun %bus-key (name)
  "NAME as the agents' registrations spell it: NIL for the unnamed bus."
  (if (or (null name) (zerop (length name)) (string= name "default"))
      nil
      name))

(defun %subject (bw)
  "What a fault about BW is about: the bus, `default` for the unnamed one."
  (or (%bus-key (bus-watch-name bw)) "default"))

(defun %on-bus-p (bw identity)
  "True when IDENTITY is served on BW's bus and has not been let go."
  (and (equal (%bus-key (ident:identity-bus identity)) (%bus-key (bus-watch-name bw)))
       (not (eq (ident:identity-state identity) :released))))

(defun %make-feed (bw)
  "A new subscription to BW's broker publications, waiting at most the
   backstop for a nudge."
  (tz:make-feed (broker:bus-paths-pub-endpoint (bus-watch-paths bw))
                :timeout-ms +backstop-ms+))

(defun open-bus-watch (name &key (feed t) lock)
  "A watch of the bus NAME (NIL for the unnamed bus), subscribed to its
   broker's publications when FEED is true. LOCK is the mutex shared with the
   supervisor; a new one is made when none is given.

   Nothing is read here. The first step reads the log from its head and hands
   each agent what lies above its own floor, so mail that landed before the
   watch opened is not missed."
  (let* ((paths (broker:make-bus-paths (broker:default-state-root (%bus-key name))))
         (wal-path (broker:bus-paths-wal paths))
         (bw (%make-bus-watch
              :name (%bus-key name)
              :paths paths
              :wal-path wal-path
              :cursors-dir (broker:bus-paths-cursors-dir paths)
              :reader (wal:make-reader)
              :feed-wanted (and feed t)
              :generation (wal:generation wal-path)
              :lock (or lock (sb-thread:make-mutex
                              :name (format nil "bus watch ~A" (or name "default")))))))
    (when feed
      (setf (bus-watch-feed bw) (%make-feed bw)))
    bw))

(defun close-bus-watch (bw &key (join-seconds 2))
  "Stop BW's thread, waiting up to JOIN-SECONDS for its step to end, and close
   its feed. Safe to call more than once."
  (setf (bus-watch-stopping bw) t)
  (let ((thread (bus-watch-thread bw)))
    (when (and thread (sb-thread:thread-alive-p thread))
      (sb-thread:join-thread thread :default nil :timeout join-seconds)))
  (when (bus-watch-feed bw)
    (tz:close-endpoint (bus-watch-feed bw))
    (setf (bus-watch-feed bw) nil))
  (values))

;;; ------------------------------------------------------------------- the step

(defun %wait (bw)
  "Wait for a nudge on BW's feed, or the backstop, whichever comes first.
   True when a nudge ended the wait. What the nudge says is not looked at."
  (let ((feed (bus-watch-feed bw)))
    (if feed
        (and (tz:recv-message feed) t)
        (progn (sleep (/ +backstop-ms+ 1000)) nil))))

(defun %report-cursor (report-fn bw action report)
  "Report what was done about one stranded cursor, with its old position."
  (let ((rebased-p (eq action :rebased)))
    (funcall report-fn (if rebased-p :warn :error)
             (if rebased-p "stranded-cursor" "stranded-cursor-clamped")
             :bus (bus-watch-name bw) :id (getf report :id)
             :subject (getf report :id)
             :msg (%stranded-fleet-message report))))

(defun %arm-again (bw identities report-fn)
  "Set the floor of every agent on BW's bus from its cursor over the log as it
   now is. An agent with no cursor of its own gets a floor of 0: it was armed at
   the head of the old log, and everything in the new one arrived after the
   rotation, so all of it is owed."
  (dolist (identity identities)
    (when (%on-bus-p bw identity)
      (let ((path (merge-pathnames (envelope:encode-id (ident:identity-id identity))
                                   (uiop:ensure-directory-pathname
                                    (bus-watch-cursors-dir bw)))))
        (if (%cursor-holds-seq-p path)
            (ident:identity-baseline identity (bus-watch-wal-path bw)
                                     (bus-watch-cursors-dir bw)
                                     :report-fn report-fn)
            (setf (ident:identity-floor identity) 0))))))

(defun rebase-bus-cursors (bw identities &key (report-fn #'ident:report-to-logs))
  "Rebase every stranded stable cursor on BW's bus, once, then arm every agent
   in IDENTITIES on the bus again. Returns how many cursors were rewritten.

   Each cursor is reported with the position it held, since the rewrite
   discards the only record of it. Ephemeral agents' cursors are left alone:
   they belong to sessions that come and go and are swept by the broker. A
   cursor that is still a position in this log is not touched."
  (let ((rebased 0))
    (sb-thread:with-recursive-lock ((bus-watch-lock bw))
      (dolist (file (ignore-errors
                     (uiop:directory-files
                      (uiop:ensure-directory-pathname (bus-watch-cursors-dir bw)))))
        (let* ((name (file-namestring file))
               (id (and (not (broker:ephemeral-cursor-name-p name))
                        (envelope:decode-id name))))
          (when (and id (%cursor-holds-seq-p file))
            (multiple-value-bind (baseline action report)
                (hostfiles:heal-stranded-baseline id (bus-watch-wal-path bw) file
                                                  :rebase-p t)
              (declare (ignore baseline))
              (when (member action '(:rebased :clamped))
                (when (eq action :rebased) (incf rebased))
                (%report-cursor report-fn bw action report))))))
      (%arm-again bw identities report-fn))
    rebased))

(defun %rotated (bw identities report-fn)
  "BW's log was rotated. Raise WAL-ROTATED offering REBASE-CURSORS; skipped,
   every agent is still armed again, each healing its own cursor if it is
   stranded, so none goes on filtering against the old log."
  (restart-case
      (progn
        (conditions:raise-fault 'conditions:wal-rotated
                                :bus (bus-watch-name bw)
                                :subject (%subject bw)
                                :detail (format nil "the log restarted at generation ~D"
                                                (bus-watch-generation bw)))
        (sb-thread:with-recursive-lock ((bus-watch-lock bw))
          (%arm-again bw identities report-fn)))
    (conditions:rebase-cursors ()
      :report "Rebase every stranded stable cursor on the bus and arm its agents again."
      (rebase-bus-cursors bw identities :report-fn report-fn))))

(defun %remake-feed (bw)
  "Close BW's feed and subscribe again."
  (when (bus-watch-feed bw)
    (tz:close-endpoint (bus-watch-feed bw)))
  (setf (bus-watch-feed bw) nil
        (bus-watch-feed bw) (%make-feed bw)))

(defun %watch-gap (bw nudged grew)
  "Count the steps in a row in which BW's log GREW while the feed was silent
   (NUDGED false), and when there have been enough, raise PUBLICATION-GAP
   offering RECONNECT-FEED. A watch without a feed has nothing to count."
  (if (and (bus-watch-feed bw) grew (not nudged))
      (when (>= (incf (bus-watch-growth-without-nudge bw)) +gap-ticks+)
        (setf (bus-watch-growth-without-nudge bw) 0)
        (restart-case
            (conditions:raise-fault 'conditions:publication-gap
                                    :bus (bus-watch-name bw)
                                    :subject (%subject bw)
                                    :detail (format nil "the log grew to ~D over ~D steps ~
                                                         with no publication heard"
                                                    (bus-watch-last-seq bw) +gap-ticks+))
          (conditions:reconnect-feed ()
            :report "Close the publication feed and subscribe again."
            (%remake-feed bw))))
      (setf (bus-watch-growth-without-nudge bw) 0)))

(defun %deliver (bw identities records now)
  "Hand RECORDS to every agent in IDENTITIES on BW's bus. The readers of every
   log are counted in one pass, and only when there is something to announce."
  (when records
    (let* ((served (remove-if-not (lambda (identity) (%on-bus-p bw identity))
                                  identities))
           (counts (ident:log-reader-counts (mapcar #'ident:identity-log-path served))))
      (sb-thread:with-recursive-lock ((bus-watch-lock bw))
        (dolist (identity served)
          (ident:identity-deliver
           identity records now
           :readers (gethash (uiop:native-namestring (ident:identity-log-path identity))
                             counts)))))))

(defun bus-watch-step (bw identities now &key (report-fn #'ident:report-to-logs))
  "One step of BW: wait for a nudge or the backstop, read the log forward once,
   and hand what was read to every agent in IDENTITIES on the bus. NOW is Unix
   seconds. Returns how many records the read found.

   Faults are raised for the supervisor to decide: WAL-ROTATED when the log
   restarted under the reader or its generation moved, PUBLICATION-GAP when it
   has grown for several steps with the feed silent. Run the step under the
   healing supervisor; outside one a fault is an error."
  (let ((nudged (%wait bw)))
    (when nudged (incf (bus-watch-nudges-seen bw)))
    (multiple-value-bind (records last restarted)
        (%poll-forward (bus-watch-wal-path bw) (bus-watch-reader bw) 0)
      (let* ((generation (wal:generation (bus-watch-wal-path bw)))
             (rotated (or restarted (/= generation (bus-watch-generation bw))))
             (grew (and (not rotated) (> last (bus-watch-last-seq bw)))))
        (setf (bus-watch-generation bw) generation
              (bus-watch-last-seq bw) last)
        (when rotated
          (%rotated bw identities report-fn))
        (%deliver bw identities records now)
        (%watch-gap bw nudged grew)
        (incf (bus-watch-progress bw))
        (length records)))))

;;; ----------------------------------------------------------------- the thread

(defun start-bus-watch-thread (bw stop-fn identities-fn
                               &key (report-fn #'ident:report-to-logs))
  "Run BW's steps in a thread of its own until STOP-FN answers true or BW is
   closed, and return the thread. IDENTITIES-FN gives the agents to feed at each
   step. Each step runs under the healing supervisor with REPORT-FN. An error
   that is not a fault is reported and the next step goes on, a quarter second
   later, so one bad step never ends the watch."
  (let ((thread
          (sb-thread:make-thread
           (lambda ()
             (loop until (or (bus-watch-stopping bw) (funcall stop-fn))
                   do (handler-case
                          (conditions:call-with-healing
                           (lambda ()
                             (bus-watch-step bw (funcall identities-fn) (%unix-time)
                                             :report-fn report-fn))
                           :report-fn report-fn)
                        (error (e)
                          (ignore-errors
                           (funcall report-fn :error "bus-watch-failed"
                                    :bus (bus-watch-name bw) :subject (%subject bw)
                                    :msg (princ-to-string e)))
                          (sleep (/ +backstop-ms+ 1000))))))
           :name (format nil "bus watch ~A" (%subject bw)))))
    (setf (bus-watch-thread bw) thread)
    thread))
