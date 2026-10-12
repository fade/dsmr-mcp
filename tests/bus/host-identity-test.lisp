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
                #:%directory-entries))

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
   service logs installed inside it, and the bus's directories made. Every
   identity claimed in THUNK is released afterwards, and the directory is
   removed."
  (let ((state (fresh-temp-dir "dsmr-host-identity"))
        (previous (uiop:getenv "XDG_STATE_HOME"))
        (*claimed* '()))
    (unwind-protect
         (progn
           (sb-posix:setenv "XDG_STATE_HOME" (namestring state) 1)
           (fleetlog:install-fleet-log
            :path (hostfiles:fleet-log-path)
            :service-log-path (merge-pathnames "service.log" (hostfiles:host-dir)))
           (ensure-directories-exist (default-wal-path *bus*))
           (ensure-directories-exist (default-cursors-dir *bus*))
           (ensure-directories-exist (hostfiles:watch-state-dir))
           (funcall thunk))
      (dolist (identity *claimed*)
        (ignore-errors (ident:release-identity identity :remove-files nil)))
      (fleetlog:remove-fleet-log)
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
