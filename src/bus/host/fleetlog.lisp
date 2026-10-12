;;;; src/bus/host/fleetlog.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Where the host service says what it could not heal: the fleet error log,
;;;; and beside it the service's own routine log.
;;;;
;;;; The fleet error log is a file fleet leaders keep a watch on, so it holds
;;;; only what a leader may have to act on: a fault with no heal, a breaker that
;;;; tripped, a degradation. Each record is one line in the fleet line format,
;;;; rendered by the same function the watcher's failure alarm and the stranded
;;;; cursor heal use, so a leader's grep reads every writer the same way. A
;;;; fault that persists is one episode: its first line is written, at most one
;;;; repeat line an hour follows with a count of what came since, and one INFO
;;;; line says when it recovered. A leader is woken by episodes, never by the
;;;; ticks that keep seeing the same fault.
;;;;
;;;; The stdio MCP servers send every log record to standard error and nowhere
;;;; else, because standard output is their protocol. That rule does not bind
;;;; this service: it has no stdio protocol to protect, and the fleet log has to
;;;; be a file for a leader to follow. Both logs here sit on loggers of their own
;;;; with additivity off, so nothing they write reaches the root logger, and
;;;; nothing here reconfigures the root logger, so a server sharing the image
;;;; keeps its standard-error-only logging exactly as it was. The service log
;;;; also copies its warnings and errors to standard error, for the journal.

(defpackage #:dsmr-bus-host/src/bus/host/fleetlog
  (:use #:cl)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles))
  ;; Naming log4cl symbols through :import-from is what lets the
  ;; package-inferred system see that this leaf needs the log4cl system.
  (:import-from #:log4cl
                #:layout
                #:layout-to-stream
                #:log-level-to-string
                #:+log-level-info+
                #:+log-level-warn+
                #:daily-file-appender
                #:fixed-stream-appender
                #:add-appender
                #:remove-all-appenders
                #:logger-appenders
                #:logger-additivity
                #:set-log-level
                #:%get-logger)
  (:export
   #:install-fleet-log
   #:remove-fleet-log
   #:fleet-report
   #:fleet-recovered
   #:service-log
   #:episode-step
   #:episode-close
   #:fleet-logger
   #:service-logger
   #:fleet-appender
   #:service-log-path
   #:+repeat-interval+))

(in-package #:dsmr-bus-host/src/bus/host/fleetlog)

;;; ------------------------------------------------------------------- loggers

(defun fleet-logger ()
  "The logger the fleet error log hangs from."
  (%get-logger (list "dsmr" "host" "fleet") "." nil))

(defun service-logger ()
  "The logger the service's routine log hangs from."
  (%get-logger (list "dsmr" "host" "service") "." nil))

(defun fleet-appender ()
  "The fleet error log's file appender, or NIL before the log is installed."
  (find-if (lambda (appender) (typep appender 'daily-file-appender))
           (logger-appenders (fleet-logger))))

(defun service-log-path ()
  "The service log's default place: service.log in the host directory."
  (merge-pathnames "service.log" (hostfiles:host-dir)))

;;; ------------------------------------------------------------------- layouts

(defclass fleet-layout (layout) ()
  (:documentation "Writes a record's message and a newline, nothing more. The
   message is already a whole fleet line."))

(defmethod layout-to-stream ((layout fleet-layout) stream logger level log-func)
  (declare (ignore logger level))
  (funcall log-func stream)
  (terpri stream)
  (values))

(defun %iso-utc-now ()
  "The time now as 2026-10-12T16:30:00Z."
  (multiple-value-bind (s mi h d mo y) (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h mi s)))

(defun %one-line (text)
  "TEXT with every control character made a space, so a record is one line."
  (map 'string (lambda (ch)
                 (if (or (< (char-code ch) 32) (= (char-code ch) 127)) #\Space ch))
       text))

(defclass service-layout (layout) ()
  (:documentation "Writes <ISO-8601 UTC> <LEVEL> <message> on one line."))

(defmethod layout-to-stream ((layout service-layout) stream logger level log-func)
  (declare (ignore logger))
  (format stream "~A ~A ~A~%"
          (%iso-utc-now)
          (log-level-to-string level)
          (%one-line (with-output-to-string (s) (funcall log-func s))))
  (values))

;;; ------------------------------------------------------------------- install

(defun %name-format (path)
  "PATH as a log4cl file name pattern, with any percent sign in it escaped so
   the pattern expands to PATH itself."
  (with-output-to-string (out)
    (loop for ch across (uiop:native-namestring path)
          do (when (char= ch #\%) (write-char #\% out))
             (write-char ch out))))

(defun %daily-appender (path layout)
  "An appender that writes to PATH and, when the UTC date changes, renames the
   file to PATH.YYYYMMDD and starts a new one. A follower that tracks the file
   by inode, as the watcher's fleet-log wake does, carries on across the
   rename."
  (make-instance 'daily-file-appender
                 :name-format (%name-format path)
                 :backup-name-format (concatenate 'string (%name-format path) ".%Y%m%d")
                 :utc t
                 :immediate-flush t
                 :layout layout))

(defvar *episodes* '()
  "Every fault the fleet log has told about and not yet seen recover, keyed on
   (code bus id subject). See EPISODE-STEP.")

(defvar *episodes-lock* (sb-thread:make-mutex :name "fleet log episodes")
  "Held while an episode is stepped, so two threads reporting one fault write
   one line between them.")

(defun install-fleet-log (&key (path (hostfiles:fleet-log-path))
                               (service-log-path (service-log-path)))
  "Point the fleet error log at PATH and the service log at SERVICE-LOG-PATH,
   creating the host directory when either is in it, and forget every open
   episode. Installing again replaces both logs' appenders. Returns PATH and
   SERVICE-LOG-PATH.

   Only the service's own two loggers are touched: each gets additivity off
   and its own appenders, and the root logger keeps exactly the appenders it
   had."
  (let ((host (namestring (hostfiles:host-dir))))
    (when (or (uiop:string-prefix-p host (namestring path))
              (uiop:string-prefix-p host (namestring service-log-path)))
      (hostfiles:ensure-host-dir)))
  (ensure-directories-exist path)
  (ensure-directories-exist service-log-path)
  (let ((fleet (fleet-logger))
        (service (service-logger)))
    (dolist (logger (list fleet service))
      (remove-all-appenders logger)
      (setf (logger-additivity logger) nil)
      (set-log-level logger +log-level-info+))
    (add-appender fleet (%daily-appender path (make-instance 'fleet-layout)))
    (add-appender service (%daily-appender service-log-path
                                           (make-instance 'service-layout)))
    (add-appender service (make-instance 'fixed-stream-appender
                                         :stream (make-synonym-stream '*error-output*)
                                         :immediate-flush t
                                         :filter +log-level-warn+
                                         :layout (make-instance 'service-layout))))
  (sb-thread:with-mutex (*episodes-lock*)
    (setf *episodes* '()))
  (values path service-log-path))

(defun remove-fleet-log ()
  "Take both logs' appenders down, closing their files, and forget every open
   episode."
  (remove-all-appenders (fleet-logger))
  (remove-all-appenders (service-logger))
  (sb-thread:with-mutex (*episodes-lock*)
    (setf *episodes* '()))
  (values))

(defun %ensure-installed ()
  "Install the logs at their default places if nothing has yet, so a fault
   reported before the service set its logs up is still written down."
  (unless (fleet-appender)
    (install-fleet-log)))

;;; ------------------------------------------------------------------ episodes

(defconstant +repeat-interval+ 3600
  "Seconds an open episode stays quiet before another line about it is
   written.")

(defstruct (episode (:copier nil))
  "One fault the fleet log has told about. SINCE is when it was first seen,
   LAST-LINE when a line about it was last written, UNWRITTEN how many times
   it has come back since that line, and TOTAL how many times it has been seen
   in all."
  since last-line (unwritten 0) (total 1))

(defun episode-step (episodes key now &key (repeat-every +repeat-interval+))
  "Decide what one more sighting of the fault named KEY at NOW writes, given
   the open EPISODES (an alist keyed on KEY). Returns (values new-episodes
   action repeats), ACTION one of:

   :WRITE        nothing is open for KEY, so this is news: write the line.
   :SUPPRESS     KEY is open and a line about it was written less than
                 REPEAT-EVERY seconds ago.
   :REPEAT-LINE  KEY is open and the last line is at least REPEAT-EVERY seconds
                 old: write one line, carrying REPEATS, the sightings since.

   Pure: EPISODES is not modified."
  (let ((open (cdr (assoc key episodes :test #'equal)))
        (others (remove key episodes :key #'car :test #'equal)))
    (if (null open)
        (values (acons key (make-episode :since now :last-line now) others)
                :write nil)
        (let ((unwritten (1+ (episode-unwritten open)))
              (total (1+ (episode-total open))))
          (if (>= (- now (episode-last-line open)) repeat-every)
              (values (acons key (make-episode :since (episode-since open)
                                               :last-line now :unwritten 0
                                               :total total)
                             others)
                      :repeat-line unwritten)
              (values (acons key (make-episode :since (episode-since open)
                                               :last-line (episode-last-line open)
                                               :unwritten unwritten :total total)
                             others)
                      :suppress nil))))))

(defun episode-close (episodes key)
  "Close the episode for KEY. Returns (values new-episodes episode), EPISODE
   being the one that was open, or NIL when none was. Pure."
  (values (remove key episodes :key #'car :test #'equal)
          (cdr (assoc key episodes :test #'equal))))

;;; ------------------------------------------------------------------- writing

(defun %emit (logger level line)
  "Send LINE to LOGGER at LEVEL (:error, :warn or :info)."
  (ecase level
    (:error (log4cl:log-error :logger logger "~A" line))
    (:warn (log4cl:log-warn :logger logger "~A" line))
    (:info (log4cl:log-info :logger logger "~A" line))))

(defun %level (level)
  "LEVEL as one of the keywords :error, :warn and :info, whatever case or type
   it came in."
  (intern (string-upcase (string level)) :keyword))

(defun fleet-report (level code &key bus id subject msg (now (get-universal-time)))
  "Report a fault to the fleet error log at LEVEL (:error, :warn or :info)
   under CODE, for BUS and agent ID, about SUBJECT, saying MSG, at NOW.

   One fault (the same CODE, BUS, ID and SUBJECT) is one episode: the first
   report writes its line, later ones write nothing until an hour has passed
   since the last line, and then one line carrying repeats=<n>. Returns the
   action taken, :WRITE, :SUPPRESS or :REPEAT-LINE.

   Its arguments are the ones the supervisor hands its report function, so this
   can be given to CALL-WITH-HEALING as that function."
  (%ensure-installed)
  (let ((level (%level level))
        (key (list code bus id subject)))
    (multiple-value-bind (action repeats)
        (sb-thread:with-mutex (*episodes-lock*)
          (multiple-value-bind (next action repeats) (episode-step *episodes* key now)
            (setf *episodes* next)
            (values action repeats)))
      (case action
        (:write
         (%emit (fleet-logger) level
                (hostfiles:fleet-line level code :bus bus :id id :msg msg :time now)))
        (:repeat-line
         (%emit (fleet-logger) level
                (hostfiles:fleet-line level code :bus bus :id id :time now
                                                 :msg (format nil "~@[~A ~]repeats=~D"
                                                              msg repeats)))))
      action)))

(defun fleet-recovered (code &key bus id subject (now (get-universal-time)))
  "Say the fault reported under CODE for BUS, ID and SUBJECT has cleared, at
   NOW: one INFO line, written only when the fleet log had told about it and
   not yet about its recovery. Returns true when it wrote the line."
  (%ensure-installed)
  (let ((episode (sb-thread:with-mutex (*episodes-lock*)
                   (multiple-value-bind (next episode)
                       (episode-close *episodes* (list code bus id subject))
                     (setf *episodes* next)
                     episode))))
    (when episode
      (%emit (fleet-logger) :info
             (hostfiles:fleet-line
              :info code :bus bus :id id :time now
              :msg (format nil "recovered after ~D sighting~:P over ~D s"
                           (episode-total episode)
                           (max 0 (- now (episode-since episode))))))
      t)))

(defun service-log (level control &rest args)
  "Write a routine record to the service log at LEVEL (:error, :warn or :info),
   its text made by FORMAT from CONTROL and ARGS. Warnings and errors are also
   copied to standard error, for the journal."
  (unless (logger-appenders (service-logger))
    (install-fleet-log))
  (%emit (service-logger) (%level level) (apply #'format nil control args))
  (values))
