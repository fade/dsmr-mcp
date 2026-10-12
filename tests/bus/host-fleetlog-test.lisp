;;;; tests/bus/host-fleetlog-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the host service's fleet error log and service log: the
;;;; line a fleet report writes, that installing the logs leaves the root
;;;; logger and standard error alone, the per-episode dedupe (first line, at
;;;; most one repeat line an hour, one recovered line), that the service log is
;;;; a separate file, and that the fleet log is set up to roll to a dated name.
;;;; Every file lives in a temporary directory, and the clock is handed in.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-fleetlog-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/host-fleetlog-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog))
  (:import-from #:log4cl
                #:logger-appenders
                #:logger-additivity
                #:*root-logger*
                #:daily-file-appender
                #:appender-next-backup-file))

(in-package #:dsmr-mcp/tests/bus/host-fleetlog-test)

;;; ------------------------------------------------------------------ fixtures

(defun fresh-temp-dir ()
  "A new empty directory under the system temp directory."
  (let ((name (uiop:with-temporary-file (:pathname p :keep t :prefix "dsmr-fleetlog") p)))
    (ignore-errors (delete-file name))
    (let ((dir (uiop:ensure-directory-pathname name)))
      (ensure-directories-exist dir)
      dir)))

(defmacro with-logs ((fleet service) &body body)
  "Install the fleet log at FLEET and the service log at SERVICE, both in a
   fresh temporary directory, run BODY, then take both logs down and remove
   the directory."
  (let ((dir (gensym "DIR")))
    `(let* ((,dir (fresh-temp-dir))
            (,fleet (merge-pathnames "fleet-error.log" ,dir))
            (,service (merge-pathnames "service.log" ,dir)))
       (unwind-protect
            (progn (fleetlog:install-fleet-log :path ,fleet :service-log-path ,service)
                   ,@body)
         (fleetlog:remove-fleet-log)
         (ignore-errors (uiop:delete-directory-tree ,dir :validate t
                                                         :if-does-not-exist :ignore))))))

(defun file-lines (path)
  "The lines of PATH, or NIL when it does not exist."
  (and (probe-file path) (uiop:read-file-lines path)))

(defun utc-date (universal-time)
  "UNIVERSAL-TIME's UTC date as YYYYMMDD."
  (multiple-value-bind (s mi h d mo y) (decode-universal-time universal-time 0)
    (declare (ignore s mi h))
    (format nil "~4,'0D~2,'0D~2,'0D" y mo d)))

;;; ---------------------------------------------------------------- fleet line

(define-test a-fleet-report-appends-one-fleet-line
  "One report is one line, in the fleet line format, with the time first."
  (with-logs (fleet service)
    (fleetlog:fleet-report :error "stranded-cursor" :bus "b" :id "/n/a" :msg "m")
    (let ((lines (file-lines fleet)))
      (is = 1 (length lines))
      (true (uiop:string-suffix-p
             (first lines) " FLEET ERROR code=stranded-cursor bus=b id=/n/a msg=m"))
      (true (digit-char-p (char (first lines) 0)))
      (is = 20 (length (subseq (first lines) 0 (position #\Space (first lines))))))))

(define-test a-fleet-report-carries-no-line-break-into-the-log
  "A message with a newline in it still makes exactly one line."
  (with-logs (fleet service)
    (fleetlog:fleet-report :warn "publication-gap" :bus "b"
                                                   :msg (format nil "one~%two"))
    (is = 1 (length (file-lines fleet)))))

(define-test installing-the-logs-leaves-the-root-logger-and-stderr-alone
  "The fleet and service loggers do not pass records up, the root logger keeps
   exactly the appenders it had, and a fleet report writes nothing to standard
   error."
  (let ((before (copy-list (logger-appenders *root-logger*))))
    (with-logs (fleet service)
      (is equal before (logger-appenders *root-logger*))
      (false (logger-additivity (fleetlog:fleet-logger)))
      (false (logger-additivity (fleetlog:service-logger)))
      (let ((err (make-string-output-stream)))
        (let ((*error-output* err))
          (fleetlog:fleet-report :error "stale-beat" :bus "b" :msg "x"))
        (is string= "" (get-output-stream-string err)))
      (is = 1 (length (file-lines fleet))))
    (is equal before (logger-appenders *root-logger*))))

;;; ------------------------------------------------------------------- episodes

(define-test the-episode-step-writes-then-suppresses-then-repeats-hourly
  "First sight writes; a repeat inside the hour is suppressed; the first repeat
   an hour or more after the last line writes a repeat line counting what came
   since. The step is pure."
  (let ((key '("c" "b" "/n/a" nil))
        (episodes '()))
    (multiple-value-bind (next action) (fleetlog:episode-step episodes key 0)
      (is eq :write action)
      (is eq nil episodes)
      (setf episodes next))
    (multiple-value-bind (next action) (fleetlog:episode-step episodes key 10)
      (is eq :suppress action)
      (setf episodes next))
    (multiple-value-bind (next action) (fleetlog:episode-step episodes key 3599)
      (is eq :suppress action)
      (setf episodes next))
    (multiple-value-bind (next action repeats) (fleetlog:episode-step episodes key 3600)
      (is eq :repeat-line action)
      (is = 3 repeats)
      (setf episodes next))
    (multiple-value-bind (next action) (fleetlog:episode-step episodes key 3700)
      (is eq :suppress action)
      (setf episodes next))
    (multiple-value-bind (next action) (fleetlog:episode-step episodes '("c" "b" "/n/b" nil) 3700)
      (declare (ignore next))
      (is eq :write action))))

(define-test a-repeating-fault-writes-a-first-line-a-repeat-line-and-a-recovered-line
  "Through the log itself: the first report writes, reports inside the hour
   do not, the first one after the hour writes a line carrying the repeat
   count, and clearing the fault writes one INFO line saying it recovered."
  (with-logs (fleet service)
    (flet ((report (now)
             (fleetlog:fleet-report :error "stale-beat" :bus "b" :id "/n/a"
                                                        :msg "beat is old" :now now)))
      (is eq :write (report 0))
      (is eq :suppress (report 10))
      (is eq :suppress (report 20))
      (is = 1 (length (file-lines fleet)))
      (is eq :repeat-line (report 3600))
      (let ((lines (file-lines fleet)))
        (is = 2 (length lines))
        (true (search "repeats=3" (second lines))))
      (true (fleetlog:fleet-recovered "stale-beat" :bus "b" :id "/n/a" :now 3700))
      (let ((lines (file-lines fleet)))
        (is = 3 (length lines))
        (true (search " FLEET INFO code=stale-beat " (third lines)))
        (true (search "recovered" (third lines))))
      (false (fleetlog:fleet-recovered "stale-beat" :bus "b" :id "/n/a" :now 3800))
      (is = 3 (length (file-lines fleet)))
      ;; recovered closed the episode, so the fault returning is news again
      (is eq :write (report 3900))
      (is = 4 (length (file-lines fleet))))))

(define-test recovering-a-fault-that-was-never-open-writes-nothing
  "A recovered line only ever ends an episode the log has already told about."
  (with-logs (fleet service)
    (false (fleetlog:fleet-recovered "stale-beat" :bus "b" :id "/n/a" :now 0))
    (is eq nil (file-lines fleet))))

;;; --------------------------------------------------------------- service log

(define-test the-service-log-is-its-own-file
  "Routine service records go to the service log, never to the fleet log, and
   an INFO record does not reach standard error while a WARN record does, for
   the journal."
  (with-logs (fleet service)
    (let ((err (make-string-output-stream)))
      (let ((*error-output* err))
        (fleetlog:service-log :info "started ~D buses" 2))
      (is string= "" (get-output-stream-string err))
      (let ((lines (file-lines service)))
        (is = 1 (length lines))
        (true (search "INFO" (first lines)))
        (true (search "started 2 buses" (first lines))))
      (is eq nil (file-lines fleet))
      (let ((*error-output* err))
        (fleetlog:service-log :warn "bus ~A is slow" "b"))
      (true (search "bus b is slow" (get-output-stream-string err)))
      (is = 2 (length (file-lines service)))
      (is eq nil (file-lines fleet)))))

;;; ------------------------------------------------------------------ rollover

(define-test the-fleet-log-rolls-to-a-dated-name
  "The fleet log's appender rolls daily, and the name the current file will
   be renamed to is the fleet log's name with the date appended."
  (with-logs (fleet service)
    (fleetlog:fleet-report :error "stale-beat" :bus "b" :msg "x")
    (let ((appender (fleetlog:fleet-appender)))
      (true (typep appender 'daily-file-appender))
      (is string= (format nil "~A.~A" (uiop:native-namestring fleet)
                          (utc-date (get-universal-time)))
          (appender-next-backup-file appender)))))
