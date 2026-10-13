;;;; tests/bus/host-identity-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for one agent as the host service serves it: the pid file, log,
;;;; heartbeat and markers it claims and releases, and the wake line it writes,
;;;; which has to be the very line a detached watcher writes for the same
;;;; records. Every file lives under a fresh temporary state home, the fleet and
;;;; service logs are installed there before anything can report, and the clock
;;;; is handed in.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-identity-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/host-identity-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:ident #:dsmr-bus-host/src/bus/host/identity)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:heartbeat #:dsmr-mcp/src/bus/heartbeat)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:watch-stream
                #:default-wal-path
                #:default-cursors-dir
                #:%signal-line
                #:%poll-forward
                #:%directory-entries
                #:%reap-notifiers
                #:%unix-time))

(in-package #:dsmr-mcp/tests/bus/host-identity-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *self* "/home/x/proj/alpha"
  "The identity every fixture serves.")

(defparameter *other* "/ns/other"
  "An agent in another project, the author of every foreign record.")

(defparameter *bus* "hi"
  "The bus every fixture serves on.")

(defvar *claimed* '()
  "Identities claimed during the current case, released when it ends.")

(defvar *stub-dir* nil
  "Where the current case's stand-in notification programs write their calls.")

(defun fresh-temp-dir (prefix)
  "A new empty directory under the system temp directory."
  (let ((name (uiop:with-temporary-file (:pathname p :keep t :prefix prefix) p)))
    (ignore-errors (delete-file name))
    (let ((dir (uiop:ensure-directory-pathname name)))
      (ensure-directories-exist dir)
      dir)))

(defun write-text (path text)
  "Replace PATH with TEXT."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (write-string text out))
  path)

(defun call-with-host (thunk)
  "Call THUNK with XDG_STATE_HOME pointing at a fresh directory, the fleet and
   service logs installed inside it, the bus's directories made, and stand-in
   notify-send and gdbus programs first on PATH, so no desktop notification
   goes out. Every identity claimed in THUNK is released afterwards, and the
   directory is removed."
  (let* ((state (fresh-temp-dir "dsmr-host-identity"))
         (stubs (merge-pathnames "stub/" state))
         (previous (uiop:getenv "XDG_STATE_HOME"))
         (previous-path (uiop:getenv "PATH"))
         (*stub-dir* stubs)
         (*claimed* '()))
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
           (ensure-directories-exist (default-wal-path *bus*))
           (ensure-directories-exist (default-cursors-dir *bus*))
           (ensure-directories-exist (hostfiles:watch-state-dir))
           (funcall thunk))
      (dolist (identity *claimed*)
        (ignore-errors (ident:release-identity identity :remove-files nil)))
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

(defmacro with-host (() &body body)
  "Run BODY inside CALL-WITH-HOST."
  `(call-with-host (lambda () ,@body)))

(defun registration (&rest overrides)
  "A registration for *SELF* on *BUS*, with OVERRIDES taking precedence."
  (append overrides
          (list :id *self* :bus *bus* :poll-ms 250 :recycle-seconds 600
                :deaf-seconds 600 :session-pid (sb-posix:getpid)
                :session-start nil :token "t1")))

(defun claim (&rest overrides)
  "Claim *SELF* on *BUS* for this process, noting it for release."
  (multiple-value-bind (identity refusal)
      (ident:claim-identity (apply #'registration overrides)
                            :service-pid (sb-posix:getpid))
    (when identity (push identity *claimed*))
    (values identity refusal)))

(defun stem ()
  "The file stem of *SELF* on *BUS*."
  (hostfiles:detach-stem *bus* *self*))

(defun watch-file (type)
  "The per-identity watch file of TYPE for *SELF* on *BUS*."
  (hostfiles:watch-state-file (stem) type))

(defun beat-file ()
  "Where *SELF*'s heartbeat on *BUS* lives."
  (heartbeat:beat-path *self* (heartbeat:default-watch-dir *bus*)))

(defun wal-path () (default-wal-path *bus*))

(defun cursor-file ()
  "*SELF*'s cursor on *BUS*."
  (merge-pathnames (envelope:encode-id *self*) (default-cursors-dir *bus*)))

(defun append-from (seq author &key to (text "x"))
  "Append record SEQ to the bus's log as published by AUTHOR, addressed to TO
   when given."
  (wal:append-record (wal-path) seq (envelope:wrap-envelope "c1" author text :to to))
  seq)

(defun records-above (floor)
  "The records of the bus's log with seq above FLOOR, oldest first."
  (values (%poll-forward (wal-path) (wal:make-reader) floor)))

(defun file-text (path)
  "The text of PATH, or NIL when there is none. Never used on a pid file this
   process holds: it reads those through CHILD-READ."
  (and (probe-file path) (uiop:read-file-string path)))

(defun child-read (path)
  "The text of PATH as another process reads it. This process may hold a lock
   on PATH, and opening and closing a descriptor here would drop it."
  (uiop:run-program (list "cat" (uiop:native-namestring path))
                    :output :string :ignore-error-status t))

(defun open-count (target)
  "How many of this process's descriptors name the native path TARGET, deleted
   or not."
  (count-if (lambda (fd)
              (let ((link (ignore-errors
                           (sb-posix:readlink (format nil "/proc/self/fd/~A" fd)))))
                (and link (uiop:string-prefix-p target link))))
            (%directory-entries "/proc/self/fd")))

(defun native (path)
  "PATH's native namestring after symbolic links are resolved."
  (uiop:native-namestring (truename path)))

(defun locked-by-me-p (path)
  "True when /proc/locks shows this process holding a POSIX write lock on the
   file at PATH. Reading /proc/locks never touches PATH itself."
  (let ((ino (sb-posix:stat-ino (sb-posix:stat (uiop:native-namestring path))))
        (pid (princ-to-string (sb-posix:getpid))))
    (some (lambda (line)
            (let ((fields (remove "" (uiop:split-string line :separator " ")
                                  :test #'string=)))
              (and (>= (length fields) 6)
                   (string= "POSIX" (second fields))
                   (string= "WRITE" (fourth fields))
                   (string= pid (fifth fields))
                   (uiop:string-suffix-p (sixth fields) (format nil ":~D" ino)))))
          (uiop:read-file-lines "/proc/locks"))))

(defun start-foreign-lock-holder (path)
  "Start another SBCL that takes the watcher lock on PATH and holds it, and
   return its process once it says the lock is taken."
  (let* ((form (format nil "(let ((fd (sb-posix:open ~S (logior sb-posix:o-creat sb-posix:o-rdwr) #o644))) (sb-posix:fcntl fd sb-posix:f-setlk (make-instance (quote sb-posix:flock) :type sb-posix:f-wrlck :whence sb-posix:seek-set :start 0 :len 0)) (write-line \"locked\") (finish-output) (sleep 60))"
                       (uiop:native-namestring path)))
         (process (sb-ext:run-program (uiop:native-namestring sb-ext:*runtime-pathname*)
                                      (list "--noinform" "--no-sysinit" "--no-userinit"
                                            "--non-interactive"
                                            "--eval" "(require :sb-posix)"
                                            "--eval" form)
                                      :input nil :output :stream :error nil :wait nil)))
    (let ((line (read-line (sb-ext:process-output process) nil "")))
      (unless (string= line "locked")
        (error "The lock holder did not start: ~S" line)))
    process))

(defun stop-process (process)
  "End PROCESS and collect it."
  (ignore-errors (sb-ext:process-kill process 9))
  (ignore-errors (sb-ext:process-wait process))
  (ignore-errors (sb-ext:process-close process)))

(defun await (thunk &optional (seconds 3))
  "Call THUNK every 50 ms until it answers true or SECONDS pass, and return its
   last answer."
  (loop repeat (* 20 seconds)
        for answer = (funcall thunk)
        when answer do (return answer)
        do (sleep 0.05)
        finally (return (funcall thunk))))

(defun notify-calls (&optional (program "notify-send"))
  "How many times the stand-in PROGRAM has been called in this case."
  (let ((path (merge-pathnames (format nil "~A.calls" program) *stub-dir*)))
    (if (probe-file path) (length (uiop:read-file-lines path)) 0)))

(defvar *reports* '()
  "Reports COLLECT-REPORT has been handed, newest first, each as (level code
   msg).")

(defun collect-report (level code &key bus id subject msg)
  "A report function that keeps what it is handed in *REPORTS*."
  (declare (ignore bus id subject))
  (push (list level code msg) *reports*))

(defun healing (thunk &key (report-fn #'ident:report-to-logs))
  "Call THUNK under the healing supervisor with REPORT-FN and breakers of its
   own, so one case's heals never spend another's."
  (conditions:call-with-healing thunk :report-fn report-fn
                                      :breakers (make-hash-table :test 'equal)))

(defun fleet-lines ()
  "The lines of the fleet log, or NIL."
  (let ((path (hostfiles:fleet-log-path)))
    (and (probe-file path) (uiop:read-file-lines path))))

(defun log-lines ()
  "The lines of *SELF*'s watch log on *BUS*, or NIL."
  (let ((path (watch-file "log")))
    (and (probe-file path) (uiop:read-file-lines path))))

(defun mtime-unix (path)
  "PATH's write date in Unix seconds."
  (%unix-time (file-write-date path)))

(defun set-mtime (path unix-time)
  "Set PATH's access and write dates to UNIX-TIME."
  (sb-posix:utimes (uiop:native-namestring path) unix-time unix-time))

(defun write-stranded-bus (cursor-text)
  "Give the bus a log at generation 2 holding seqs 1 to 5 from *OTHER*, and
   *SELF* a cursor holding CURSOR-TEXT."
  (loop for seq from 1 to 5 do (append-from seq *other*))
  (write-text (wal:generation-path (wal-path)) "2")
  (write-text (cursor-file) cursor-text))

;;; --------------------------------------------------------------------- claim

(define-test claiming-writes-the-watcher-s-pid-file-log-and-beat
  "A claim leaves exactly the files a detached watcher leaves: a locked pid
   file naming this process and the identity, a log, and a heartbeat."
  (with-host ()
    (multiple-value-bind (identity refusal) (claim)
      (true identity)
      (false refusal)
      (is string= (format nil "~D~%~A~%" (sb-posix:getpid) *self*)
          (child-read (watch-file "pid")))
      (true (locked-by-me-p (watch-file "pid")) "the pid file is locked by us")
      (true (probe-file (watch-file "log")))
      (let ((beat (with-open-file (in (beat-file)) (read in))))
        (is eql (sb-posix:getpid) (getf beat :pid))
        (is eq :stream (getf beat :mode))))))

(define-test the-pid-file-is-open-exactly-once
  "The lock goes with the descriptor, and closing any descriptor on the file
   drops it, so the claim keeps exactly one open and opens no other."
  (with-host ()
    (claim)
    (is = 1 (open-count (native (watch-file "pid"))))
    (is = 1 (open-count (native (watch-file "log"))))
    (true (locked-by-me-p (watch-file "pid")))))

(define-test a-claim-is-refused-while-another-process-holds-the-lock
  "An identity some other process is watching is not taken from it."
  (with-host ()
    (let ((holder (start-foreign-lock-holder (watch-file "pid"))))
      (unwind-protect
           (multiple-value-bind (identity refusal) (claim)
             (false identity)
             (is eq :held refusal)
             (false (probe-file (beat-file)) "no beat is written for a refused claim"))
        (stop-process holder)))))

(define-test claim-removes-a-deaf-marker-left-by-an-earlier-holder
  "A marker from an episode that belonged to an earlier watcher is not this
   one's to keep."
  (with-host ()
    (write-text (watch-file "deaf") "since=1 agent=alpha bus=hi")
    (claim)
    (false (probe-file (watch-file "deaf")))))

;;; ------------------------------------------------------------------- fan-out

(define-test service-line-matches-the-watcher-line
  "Given the same records and the same baseline, the line the service writes
   to the identity's log is the line a detached watcher streams, byte for
   byte."
  (with-host ()
    (write-text (cursor-file) "0")
    (append-from 1 *other* :to *self*)
    (append-from 2 *other*)
    (append-from 3 *self*)
    (let ((watcher-lines '()))
      (watch-stream (wal-path) 0 :poll-ms 10 :recycle-seconds 0.2 :self-id *self*
                                 :emit (lambda (seq froms tos)
                                         (push (%signal-line seq froms tos)
                                               watcher-lines)))
      (is = 1 (length watcher-lines))
      (let ((identity (claim)))
        (is = 0 (ident:identity-floor identity))
        (ident:identity-deliver identity (records-above 0) 1000 :readers 1)
        (is string= (format nil "~A~%" (first watcher-lines))
            (file-text (watch-file "log")))
        (true (search " from=" (first watcher-lines)))
        (true (search " to=" (first watcher-lines)))
        (is = 3 (ident:identity-floor identity))))))

(define-test own-publishes-and-others-mail-write-nothing-but-advance-the-floor
  "A batch with nothing this agent would be handed wakes nobody, and is still
   stepped over."
  (with-host ()
    (write-text (cursor-file) "0")
    (append-from 1 *self*)
    (append-from 2 *other* :to "/ns/third")
    (let ((identity (claim)))
      (ident:identity-deliver identity (records-above 0) 1000 :readers 1)
      (is string= "" (file-text (watch-file "log")))
      (is = 2 (ident:identity-floor identity)))))

(define-test records-at-or-below-the-floor-are-not-announced-twice
  "A record handed over a second time is already considered."
  (with-host ()
    (write-text (cursor-file) "0")
    (append-from 1 *other*)
    (let ((identity (claim)))
      (ident:identity-deliver identity (records-above 0) 1000 :readers 1)
      (ident:identity-deliver identity (records-above 0) 1001 :readers 1)
      (is = 1 (length (uiop:read-file-lines (watch-file "log")))))))

(define-test the-baseline-comes-from-the-cursor
  "The identity is armed where the agent has consumed to, so mail above the
   cursor is announced on the first delivery."
  (with-host ()
    (append-from 1 *other*)
    (append-from 2 *other*)
    (write-text (cursor-file) "1")
    (let ((identity (claim)))
      (is = 1 (ident:identity-floor identity))
      (ident:identity-deliver identity (records-above (ident:identity-floor identity))
                              1000 :readers 1)
      (true (uiop:string-prefix-p "bus:2 " (file-text (watch-file "log")))))))

(define-test without-a-cursor-the-identity-arms-at-the-head
  "No cursor is not a cursor at 0: a whole log of mail is not owed to an agent
   that has never read."
  (with-host ()
    (append-from 1 *other*)
    (append-from 2 *other*)
    (let ((identity (claim)))
      (is = 2 (ident:identity-floor identity)))))

;;; ------------------------------------------------------------------- release

(define-test release-removes-the-pid-file-and-beat-and-leaves-the-rest
  "Deregistering takes away what says a watcher is running and nothing the
   agent or its listener owns."
  (with-host ()
    (write-text (watch-file "parked") "since=5")
    (write-text (watch-file "offset") "ino=1 pos=0")
    (write-text (cursor-file) "0")
    (append-from 1 *other*)
    (let* ((identity (claim))
           (pid-target (native (watch-file "pid"))))
      (ident:identity-deliver identity (records-above 0) 1000 :readers 1)
      (ident:release-identity identity)
      (false (probe-file (watch-file "pid")))
      (false (probe-file (beat-file)))
      (true (probe-file (watch-file "log")))
      (is = 1 (length (uiop:read-file-lines (watch-file "log"))))
      (is string= "since=5" (file-text (watch-file "parked")))
      (is string= "ino=1 pos=0" (file-text (watch-file "offset")))
      (is = 0 (open-count pid-target) "no descriptor is left on the pid file"))))

(define-test release-without-removing-files-only-closes-descriptors
  "An orderly stop of the service leaves every file for the service that
   follows it."
  (with-host ()
    (let* ((identity (claim))
           (pid-target (native (watch-file "pid")))
           (log-target (native (watch-file "log"))))
      (ident:release-identity identity :remove-files nil)
      (true (probe-file (watch-file "pid")))
      (true (probe-file (beat-file)))
      (true (probe-file (watch-file "log")))
      (is = 0 (open-count pid-target))
      (is = 0 (open-count log-target)))))

;;; ------------------------------------------------------------------- the beat

(define-test the-tick-advances-the-beat
  "The heartbeat is kept fresh by its write date, without being rewritten."
  (with-host ()
    (let ((identity (claim))
          (now (+ (%unix-time) 7)))
      (is eq :ok (ident:identity-tick identity now :readers 1))
      (is = now (mtime-unix (beat-file))))))

(define-test a-missing-beat-is-a-stale-beat-fault-and-is-rewritten
  "A beat that is gone is a fault, not something to pass over; the supervisor
   heals it by writing the beat again."
  (with-host ()
    (let ((identity (claim)))
      (delete-file (beat-file))
      (fail (ident:identity-tick identity (%unix-time) :readers 1) conditions:stale-beat)
      (let ((*reports* '()))
        (healing (lambda () (ident:identity-tick identity (%unix-time) :readers 1))
                 :report-fn #'collect-report)
        (true (probe-file (beat-file)))
        (true (find "stale-beat" *reports* :key #'second :test #'string=))))))

(define-test a-removed-pid-file-is-claimed-again
  "Probes read the pid file's lock as `a watcher is running`, so a pid file
   that disappears under the service is put back and locked again."
  (with-host ()
    (let ((identity (claim))
          (*reports* '()))
      (sb-posix:unlink (uiop:native-namestring (watch-file "pid")))
      (healing (lambda () (ident:identity-tick identity (%unix-time) :readers 1))
               :report-fn #'collect-report)
      (true (find "pid-claim-lost" *reports* :key #'second :test #'string=))
      (is string= (format nil "~D~%~A~%" (sb-posix:getpid) *self*)
          (child-read (watch-file "pid")))
      (true (locked-by-me-p (watch-file "pid")))
      (is = 1 (open-count (native (watch-file "pid")))))))

;;; --------------------------------------------------------------- deafness

(define-test unheard-mail-raises-the-deafness-alarm-once
  "A line written with nothing following the log, and still unheard after the
   threshold, raises one marker and one notification for the episode; a reader
   ends it."
  (with-host ()
    (write-text (cursor-file) "0")
    (append-from 1 *other*)
    (let ((identity (claim :recycle-seconds 100000))
          (start (%unix-time)))
      (ident:identity-deliver identity (records-above 0) start :readers 0)
      (dolist (offset '(1 300 599))
        (ident:identity-tick identity (+ start offset) :readers 0))
      (false (probe-file (watch-file "deaf")) "nothing before the threshold")
      (ident:identity-tick identity (+ start 600) :readers 0)
      (is string= (format nil "since=~D agent=~A bus=~A~%"
                          start (hostfiles:field-token *self*) *bus*)
          (file-text (watch-file "deaf")))
      (dolist (offset '(601 700 1300))
        (ident:identity-tick identity (+ start offset) :readers 0))
      (true (await (lambda () (plusp (notify-calls)))))
      (sleep 0.3)
      (is = 1 (notify-calls) "one notification for the episode")
      (is = 0 (notify-calls "gdbus"))
      (ident:identity-tick identity (+ start 1301) :readers 1)
      (false (probe-file (watch-file "deaf")) "a reader ends the episode"))))

(define-test a-parked-identity-raises-no-alarm
  "Parking is the agent saying it will not be listening, so its silence is not
   an alarm."
  (with-host ()
    (write-text (cursor-file) "0")
    (write-text (watch-file "parked") "since=1")
    (append-from 1 *other*)
    (let ((identity (claim :recycle-seconds 100000))
          (start (%unix-time)))
      (ident:identity-deliver identity (records-above 0) start :readers 0)
      (ident:identity-tick identity (+ start 600) :readers 0)
      (ident:identity-tick identity (+ start 1200) :readers 0)
      (false (probe-file (watch-file "deaf")))
      (sleep 0.3)
      (is = 0 (notify-calls))
      (true (probe-file (watch-file "parked")) "the park marker is never removed"))))

(define-test a-lapsed-identity-writes-no-line-and-keeps-the-alarm
  "An agent whose session ended without parking gets no wake lines, since
   nothing is there to wake, but mail left unread past the threshold still
   raises the alarm, and reading past it ends the lapse."
  (with-host ()
    (write-text (cursor-file) "0")
    (let ((identity (claim :recycle-seconds 100000))
          (start (%unix-time)))
      (ident:lapse-identity identity)
      (append-from 1 *other*)
      (false (ident:identity-deliver identity (records-above 0) start :readers 0))
      (is equal '() (log-lines))
      (is eq :ok (ident:identity-tick identity start :readers 0))
      (is eq :ok (ident:identity-tick identity (+ start 599) :readers 0))
      (false (probe-file (watch-file "deaf")))
      (is eq :ok (ident:identity-tick identity (+ start 600) :readers 0))
      (true (probe-file (watch-file "deaf")))
      (ident:identity-tick identity (+ start 700) :readers 0)
      (true (await (lambda () (plusp (notify-calls)))))
      (sleep 0.3)
      (is = 1 (notify-calls))
      (is equal '() (log-lines) "still no wake line")
      (write-text (cursor-file) "1")
      (is eq :heard (ident:identity-tick identity (+ start 701) :readers 0))
      (false (probe-file (watch-file "deaf")) "the episode is over"))))

(define-test an-unlapsed-identity-is-served-again
  "A session that comes back under the same identity is served lines again."
  (with-host ()
    (write-text (cursor-file) "0")
    (let ((identity (claim :recycle-seconds 100000)))
      (ident:lapse-identity identity)
      (ident:unlapse-identity identity (registration :token "t2" :session-pid 42))
      (is eq :serving (ident:identity-state identity))
      (is string= "t2" (ident:identity-token identity))
      (is eql 42 (ident:identity-session-pid identity))
      (append-from 1 *other*)
      (true (ident:identity-deliver identity (records-above 0) (%unix-time) :readers 1))
      (is = 1 (length (log-lines))))))

;;; --------------------------------------------------------- stranded cursors

(define-test a-stranded-cursor-is-rebased-at-claim-and-reported
  "A cursor left over from a rotated log is rewritten into the current one,
   its old position goes to the fleet log, and the mail already in the new log
   wakes the agent."
  (with-host ()
    (write-stranded-bus "372 1")
    (let ((identity (healing (lambda () (claim)))))
      (is = 0 (ident:identity-floor identity))
      (is string= "0 2" (file-text (cursor-file)))
      (let ((lines (fleet-lines)))
        (is = 1 (length lines))
        (true (search " FLEET WARN code=stranded-cursor " (first lines)) "~S" lines)
        (true (search "old-cursor=372" (first lines))))
      (ident:identity-deliver identity (records-above 0) (%unix-time) :readers 1)
      (let ((lines (log-lines)))
        (is = 1 (length lines))
        (true (uiop:string-prefix-p "bus:5 " (first lines)) "~S" lines)))))

(define-test a-refused-rebase-clamps-to-the-head-and-says-so
  "With the cursors directory read-only the rewrite cannot happen, so the
   identity arms at the head of the log, never at the stranded value, and the
   fleet log carries an error."
  (with-host ()
    (write-stranded-bus "372 1")
    (let* ((cursors (uiop:native-namestring (default-cursors-dir *bus*)))
           (identity (unwind-protect
                          (progn (sb-posix:chmod cursors #o500)
                                 (healing (lambda () (claim))))
                       (sb-posix:chmod cursors #o700))))
      (is = 5 (ident:identity-floor identity))
      (is string= "372 1" (file-text (cursor-file)))
      (let ((lines (fleet-lines)))
        (is = 1 (length lines))
        (true (search " FLEET ERROR code=stranded-cursor-clamped " (first lines))
              "~S" lines)))))

(define-test the-clamp-restart-arms-at-the-head-and-leaves-the-cursor
  "Taking the clamp rather than the rebase leaves the cursor as it was and
   reports the choice as an error."
  (with-host ()
    (write-stranded-bus "372 1")
    (let ((identity (handler-bind ((conditions:stranded-cursor
                                     (lambda (fault)
                                       (declare (ignore fault))
                                       (invoke-restart 'ident:clamp-baseline))))
                      (claim))))
      (is = 5 (ident:identity-floor identity))
      (is string= "372 1" (file-text (cursor-file)))
      (true (search " FLEET ERROR code=stranded-cursor-clamped "
                    (or (first (fleet-lines)) ""))))))

(define-test every-rewritten-cursor-position-reaches-the-fleet-log
  "Each rewrite discards a position nobody else recorded, so a second rewrite
   of the same agent's cursor within the hour is written to the fleet log with
   its own old position, not folded into the first as a repeat."
  (with-host ()
    (write-stranded-bus "372 1")
    (let ((first (healing (lambda () (claim)))))
      (ident:release-identity first))
    (write-text (cursor-file) "500 1")
    (true (healing (lambda () (claim))))
    (let ((lines (remove-if-not (lambda (line) (search " code=stranded-cursor " line))
                                (fleet-lines))))
      (is = 2 (length lines) "~S" lines)
      (true (search "old-cursor=372" (first lines)) "~S" lines)
      (true (search "old-cursor=500" (second lines)) "~S" lines))))

(define-test a-roster-gap-reaches-the-fleet-log-once-while-it-stands
  "A roster gap is a finding for a leader, so it is written to the fleet log
   at INFO, once however often it is seen. Its recovery is written there too,
   and a gap that opens again afterwards is written again. Routine INFO stays
   out of the fleet log."
  (with-host ()
    (flet ((gap (&optional msg)
             (ident:report-to-logs :info "roster-gap" :id "/n/x"
                                   :subject "enrolled-unregistered /n/x"
                                   :msg (or msg "/n/x enrolled on the roster with no registration")))
           (gap-lines ()
             (remove-if-not (lambda (line) (search " FLEET INFO code=roster-gap " line))
                            (fleet-lines))))
      (gap)
      (gap)
      (is = 1 (length (gap-lines)) "~S" (gap-lines))
      (gap "recovered: /n/x is no longer enrolled on the roster with no registration")
      (is = 2 (length (gap-lines)) "~S" (gap-lines))
      (true (search "recovered" (second (gap-lines))) "~S" (gap-lines))
      (gap)
      (is = 3 (length (gap-lines)) "~S" (gap-lines))
      (ident:report-to-logs :info "no-cursor" :id "/n/x" :msg "armed at the head")
      (is = 0 (count-if (lambda (line) (search "code=no-cursor" line)) (fleet-lines))))))

(define-test a-skipped-stranded-cursor-still-arms-at-the-head
  "A fault the supervisor skips, as it does once a breaker has tripped, must
   not leave the identity filtering on the stranded value."
  (with-host ()
    (write-stranded-bus "372 1")
    (let ((identity (handler-bind ((conditions:stranded-cursor
                                     (lambda (fault)
                                       (declare (ignore fault))
                                       (invoke-restart 'conditions:skip-fault))))
                      (claim))))
      (is = 5 (ident:identity-floor identity))
      (is string= "372 1" (file-text (cursor-file))))))

(define-test a-cursor-stranded-after-the-claim-is-caught-at-the-next-tick
  "A cursor rewritten under a served identity is looked at again on the next
   tick; stranded, it is rebased, and the mail it had been hiding is
   announced."
  (with-host ()
    (append-from 1 *other*)
    (append-from 2 *other*)
    (write-text (cursor-file) "2")
    (let ((identity (claim :recycle-seconds 100000))
          (start (%unix-time))
          (*reports* '()))
      (is = 2 (ident:identity-floor identity))
      (write-text (cursor-file) "99")
      (set-mtime (cursor-file) (- start 100))
      (healing (lambda () (ident:identity-tick identity start
                                               :readers 1 :report-fn #'collect-report))
               :report-fn #'collect-report)
      (true (find-if (lambda (report)
                       (and (eq :warn (first report))
                            (string= "stranded-cursor" (second report))))
                     *reports*)
            "~S" *reports*)
      (is string= "0 0" (file-text (cursor-file)))
      (let ((lines (log-lines)))
        (is = 1 (length lines))
        (true (uiop:string-prefix-p "bus:2 " (first lines)) "~S" lines)))))

;;; ---------------------------------------------------------------- re-announce

(define-test unread-mail-is-announced-again-after-the-recycle-window
  "Mail still above the cursor after a recycle window of quiet is announced
   again, on the clock a detached watcher re-arms on, and mail the agent has
   read is not."
  (with-host ()
    (write-text (cursor-file) "0")
    (append-from 1 *other*)
    (let ((start (%unix-time))
          (identity (claim :recycle-seconds 600 :deaf-seconds 0)))
      (ident:identity-deliver identity (records-above 0) start :readers 1)
      (is = 1 (length (log-lines)))
      (ident:identity-tick identity (+ start 600) :readers 1)
      (is = 1 (length (log-lines)) "not before the window is exceeded")
      (ident:identity-tick identity (+ start 601) :readers 1)
      (is = 2 (length (log-lines)))
      (true (every (lambda (line) (uiop:string-prefix-p "bus:1 " line)) (log-lines)))
      (write-text (cursor-file) "1")
      (ident:identity-tick identity (+ start 1200) :readers 1)
      (is = 2 (length (log-lines)) "mail the agent has read is not announced again"))))

;;; ------------------------------------------------------------------- readers

(define-test reader-census-counts-only-processes-reading-each-log
  "One pass over /proc counts, per log, the processes that could hear a line:
   a process holding the log open for reading counts, a write-only descriptor
   never does, and this process is left out unless asked."
  (with-host ()
    (let* ((read-log (write-text (hostfiles:watch-state-file "hi--a--00000001" "log") ""))
           (quiet-log (write-text (hostfiles:watch-state-file "hi--b--00000002" "log") ""))
           (reader (sb-ext:run-program "/bin/sh"
                                       (list "-c" "exec sleep 30 < \"$0\""
                                             (uiop:native-namestring read-log))
                                       :input nil :output nil :error nil :wait nil)))
      (flet ((count-of (counts path) (gethash (uiop:native-namestring path) counts)))
        (unwind-protect
             (with-open-file (out quiet-log :direction :output :if-exists :append)
               (declare (ignorable out))
               (true (await (lambda ()
                              (eql 1 (count-of (ident:log-reader-counts
                                                (list read-log quiet-log))
                                               read-log)))))
               (let ((counts (ident:log-reader-counts (list read-log quiet-log))))
                 (is eql 1 (count-of counts read-log))
                 (is eql 0 (count-of counts quiet-log)))
               (let ((counts (ident:log-reader-counts (list read-log quiet-log)
                                                      :exclude-pids '())))
                 (is eql 1 (count-of counts read-log))
                 (is eql 0 (count-of counts quiet-log)
                     "this process's write-only descriptor is not a reader")))
          (stop-process reader))))))
