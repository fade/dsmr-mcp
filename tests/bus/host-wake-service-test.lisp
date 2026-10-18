;;;; tests/bus/host-wake-service-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the host service's wake clients as the running service
;;;; serves them, in this process. Covered:
;;;;   - an identity offers every wake line it writes to a hook, and never
;;;;     re-delivers below the position it persisted;
;;;;   - a bus watch takes its reader counts from outside;
;;;;   - the service listens on the wake socket, resolves each request against
;;;;     the agents it serves, catches a newcomer up from the log, persists what
;;;;     it delivered across a restart, and counts clients instead of scanning
;;;;     /proc.
;;;;
;;;; The state home is a fresh short directory under /tmp (a socket path has to
;;;; fit in 107 bytes), the fleet and service logs are installed there before
;;;; anything can report, and every identity, watch, service and client socket
;;;; a case opens is let go when it ends.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-wake-service-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix)
  (require :sb-bsd-sockets))

(defpackage #:dsmr-mcp/tests/bus/host-wake-service-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:ident #:dsmr-bus-host/src/bus/host/identity)
                    (#:buswatch #:dsmr-bus-host/src/bus/host/buswatch)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:default-wal-path
                #:default-cursors-dir
                #:%poll-forward
                #:%reap-notifiers
                #:%unix-time))

(in-package #:dsmr-mcp/tests/bus/host-wake-service-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *ns* "/home/x/proj"
  "The namespace every fixture's agents live in.")

(defparameter *other* "/ns/other"
  "An agent in another project, the author of every foreign record.")

(defparameter *bus* "hw"
  "The bus the identity cases serve on.")

(defvar *claimed* '()
  "Identities claimed during the current case, released when it ends.")

(defvar *watches* '()
  "Bus watches opened during the current case, closed when it ends.")

(defvar *reports* '()
  "Reports COLLECT-REPORT has been handed, newest first, each as (level code
   msg).")

(defun short-temp-dir ()
  "A new empty directory directly under /tmp with a short name, so a socket
   inside it fits the unix-domain path limit."
  (loop for dir = (format nil "/tmp/h45ws-~36R~36R/" (sb-posix:getpid) (random 1000000))
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
   and service logs installed inside it, the host directory and the bus's
   directories made, and stand-in notify-send and gdbus programs first on PATH.
   Afterwards every watch is closed, every identity released and the directory
   removed."
  (let* ((state (short-temp-dir))
         (stubs (merge-pathnames "stub/" state))
         (previous (uiop:getenv "XDG_STATE_HOME"))
         (previous-path (uiop:getenv "PATH"))
         (*claimed* '())
         (*watches* '())
         (*reports* '()))
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
           (hostfiles:ensure-host-dir)
           (fleetlog:install-fleet-log
            :path (hostfiles:fleet-log-path)
            :service-log-path (merge-pathnames "service.log" (hostfiles:host-dir)))
           (ensure-directories-exist (default-wal-path *bus*))
           (ensure-directories-exist (default-cursors-dir *bus*))
           (ensure-directories-exist (hostfiles:watch-state-dir))
           (funcall thunk state))
      (dolist (bw *watches*)
        (ignore-errors (buswatch:close-bus-watch bw :join-seconds 1)))
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

(defmacro with-host ((state) &body body)
  "Run BODY inside CALL-WITH-HOST with STATE bound to the state home."
  `(call-with-host (lambda (,state) (declare (ignorable ,state)) ,@body)))

(defun id (agent)
  "The full id of AGENT in the fixtures' namespace."
  (format nil "~A/~A" *ns* agent))

(defun collect-report (level code &key bus id subject msg)
  "A report function that keeps what it is handed in *REPORTS*."
  (declare (ignore bus id subject))
  (push (list level code msg) *reports*))

(defun reports (level code)
  "The reports at LEVEL under CODE so far."
  (remove-if-not (lambda (r) (and (eq level (first r)) (string= code (second r))))
                 *reports*))

(defun healing (thunk)
  "Call THUNK under the healing supervisor, collecting every report, with
   breakers of its own."
  (conditions:call-with-healing thunk :report-fn #'collect-report
                                      :breakers (make-hash-table :test 'equal)))

(defun wal-path (&optional (bus *bus*)) (default-wal-path bus))

(defun cursor-file (agent &optional (bus *bus*))
  "AGENT's cursor on BUS."
  (merge-pathnames (envelope:encode-id (id agent)) (default-cursors-dir bus)))

(defun stem (agent &optional (bus *bus*))
  "The file stem of AGENT on BUS."
  (hostfiles:detach-stem bus (id agent)))

(defun append-from (seq author &key to (bus *bus*) (text "x"))
  "Append record SEQ to BUS's log as published by AUTHOR, addressed to TO when
   given."
  (ensure-directories-exist (wal-path bus))
  (wal:append-record (wal-path bus) seq (envelope:wrap-envelope "c1" author text :to to))
  seq)

(defun records-above (floor &optional (bus *bus*))
  "The records of BUS's log with seq above FLOOR, oldest first."
  (values (%poll-forward (wal-path bus) (wal:make-reader) floor)))

(defun log-lines (agent &optional (bus *bus*))
  "The lines of AGENT's watch log on BUS, or NIL."
  (let ((path (hostfiles:watch-state-file (stem agent bus) "log")))
    (and (probe-file path) (uiop:read-file-lines path))))

(defun claim (agent &key (bus *bus*))
  "Claim AGENT on BUS for this process, noting it for release."
  (let ((identity (ident:claim-identity
                   (list :id (id agent) :bus bus :poll-ms 250 :recycle-seconds 600
                         :deaf-seconds 600 :session-pid (sb-posix:getpid)
                         :session-start nil :token "t1")
                   :service-pid (sb-posix:getpid)
                   :report-fn #'collect-report)))
    (push identity *claimed*)
    identity))

(defun open-watch (&rest keys)
  "Open the watch of the fixtures' bus with KEYS, noting it for closing."
  (let ((bw (apply #'buswatch:open-bus-watch *bus* :feed nil keys)))
    (push bw *watches*)
    bw))

(defun call-counting-census (thunk)
  "Call THUNK with the /proc census of log readers replaced by one that counts
   its calls and answers 0 for every log, and return the number of calls."
  (let ((calls 0)
        (original (fdefinition 'ident:log-reader-counts)))
    (unwind-protect
         (progn
           (setf (fdefinition 'ident:log-reader-counts)
                 (lambda (paths &rest keys)
                   (declare (ignore keys))
                   (incf calls)
                   (let ((table (make-hash-table :test 'equal)))
                     (dolist (path paths table)
                       (setf (gethash (uiop:native-namestring path) table) 0)))))
           (funcall thunk))
      (setf (fdefinition 'ident:log-reader-counts) original))
    calls))

;;; ------------------------------------------------- the identity side: hooks

(define-test an-announced-line-is-handed-to-the-hook
  "A delivery writes the wake line to the log and hands the same line, with
   its seq and the time, to the identity's announce hook, once."
  (with-host (state)
    (loop for seq from 1 to 5 do (append-from seq *other*))
    (write-text (cursor-file "alpha") "4")
    (let ((identity (claim "alpha"))
          (calls '())
          (now (%unix-time)))
      (setf (ident:identity-announce-hook identity)
            (lambda (who seq line at) (push (list who seq line at) calls) t))
      (true (ident:identity-deliver identity (records-above 0) now))
      (is = 1 (length calls))
      (destructuring-bind (who seq line at) (first calls)
        (is eq identity who)
        (is = 5 seq)
        (is = now at)
        (is equal (list line) (log-lines "alpha"))
        (true (uiop:string-prefix-p "bus:5 " line) "~S" line)))))

(define-test without-a-hook-the-line-is-only-written
  "An identity with no announce hook writes its wake line exactly as before."
  (with-host (state)
    (loop for seq from 1 to 5 do (append-from seq *other*))
    (write-text (cursor-file "alpha") "4")
    (let ((identity (claim "alpha")))
      (false (ident:identity-announce-hook identity))
      (true (ident:identity-deliver identity (records-above 0) (%unix-time)))
      (is = 1 (length (log-lines "alpha")))
      (true (uiop:string-prefix-p "bus:5 " (first (log-lines "alpha")))))))

(define-test a-failing-hook-does-not-stop-the-announcement
  "A hook that signals is reported, and the line is written all the same."
  (with-host (state)
    (loop for seq from 1 to 5 do (append-from seq *other*))
    (write-text (cursor-file "alpha") "4")
    (let ((identity (claim "alpha")))
      (setf (ident:identity-announce-hook identity)
            (lambda (who seq line at)
              (declare (ignore who seq line at))
              (error "the hub is gone")))
      (true (ident:identity-deliver identity (records-above 0) (%unix-time)
                                    :report-fn #'collect-report))
      (is = 1 (length (log-lines "alpha")))
      (let ((failed (reports :error "announce-hook-failed")))
        (is = 1 (length failed))
        (true (search "the hub is gone" (third (first failed))))))))

;;; ------------------------------------------- the identity side: the floor

(define-test the-floor-at-claim-is-never-below-the-delivered-position
  "A position persisted for the log's current generation raises the floor a
   claim takes from the cursor, so a seq handed over before a restart is not
   handed over again."
  (with-host (state)
    (loop for seq from 1 to 10 do (append-from seq *other*))
    (write-text (cursor-file "alpha") "4")
    (hostfiles:write-delivered-position (stem "alpha") 9
                                        :generation (wal:generation (wal-path)))
    (let ((identity (claim "alpha")))
      (is = 9 (ident:identity-floor identity)))))

(define-test a-delivered-position-from-another-generation-is-ignored
  "A position written for a log that has since rotated says nothing about the
   new one, and with no position at all the floor is the cursor."
  (with-host (state)
    (loop for seq from 1 to 10 do (append-from seq *other*))
    (write-text (cursor-file "alpha") "4")
    (let ((identity (claim "alpha")))
      (is = 4 (ident:identity-floor identity) "no delivered file")
      (ident:release-identity identity :remove-files t))
    (hostfiles:write-delivered-position (stem "alpha") 9
                                        :generation (1+ (wal:generation (wal-path))))
    (let ((identity (claim "alpha")))
      (is = 4 (ident:identity-floor identity) "a rotated log's position"))))

(define-test the-heard-time-counts-as-a-saved-offset
  "The time a client was last handed a line counts as heard exactly as a
   listener's saved offset does: the later of the two is taken."
  (with-host (state)
    (let* ((identity (claim "alpha"))
           (offset (hostfiles:watch-state-file (stem "alpha") "offset"))
           (base (- (%unix-time) 1000)))
      (false (ident::%offset-time identity) "neither")
      (setf (ident:identity-heard-at identity) base)
      (is = base (ident::%offset-time identity) "heard time alone")
      (write-text offset "0")
      (sb-posix:utimes (uiop:native-namestring offset) (+ base 50) (+ base 50))
      (is = (+ base 50) (ident::%offset-time identity) "a later offset")
      (setf (ident:identity-heard-at identity) (+ base 100))
      (is = (+ base 100) (ident::%offset-time identity) "a later heard time"))))

;;; ---------------------------------------------- the bus watch: readers

(define-test a-bus-watch-takes-readers-from-its-readers-fn
  "A watch given a readers function asks it for each agent's readers and never
   runs the /proc census; the count it answers reaches the deafness rule. A
   watch without one still runs the census."
  (with-host (state)
    (loop for seq from 1 to 5 do (append-from seq *other*))
    (write-text (cursor-file "alpha") "4")
    (write-text (cursor-file "beta") "4")
    (let* ((alpha (claim "alpha"))
           (beta (claim "beta"))
           (asked '())
           (bw (open-watch :readers-fn (lambda (identity)
                                         (push identity asked)
                                         (if (eq identity alpha) 1 0))))
           (calls (call-counting-census
                   (lambda ()
                     (healing (lambda ()
                                (buswatch:bus-watch-step bw (list alpha beta) (%unix-time)
                                                         :report-fn #'collect-report)))))))
      (is = 0 calls "the census ran beside a readers function")
      (true (member alpha asked))
      (true (member beta asked))
      (is = 1 (length (log-lines "alpha")))
      (is = 1 (length (log-lines "beta")))
      (false (dsmr-bus-watch/src/bus/watch::deaf-state-unheard-since
              (ident:identity-deaf-state alpha))
             "a line written with a reader started the clock")
      (true (dsmr-bus-watch/src/bus/watch::deaf-state-unheard-since
             (ident:identity-deaf-state beta))
            "a line written with no reader did not start the clock")))
  (with-host (state)
    (loop for seq from 1 to 5 do (append-from seq *other*))
    (write-text (cursor-file "alpha") "4")
    (let* ((alpha (claim "alpha"))
           (bw (open-watch))
           (calls (call-counting-census
                   (lambda ()
                     (healing (lambda ()
                                (buswatch:bus-watch-step bw (list alpha) (%unix-time)
                                                         :report-fn #'collect-report)))))))
      (true (plusp calls) "the census did not run without a readers function"))))
