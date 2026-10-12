;;;; tests/bus/host-buswatch-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the host service's watch of one bus: one shared read of the
;;;; log fanned out to every agent on the bus, the publication feed treated as a
;;;; doorbell that only shortens the wait, a log that grows with the feed silent
;;;; healed by remaking the feed, and a rotation healed once for every stranded
;;;; stable cursor on the bus.
;;;;
;;;; Every bus lives under a fresh short directory in /tmp used as the state
;;;; home (a socket path has to fit in 107 bytes), the fleet and service logs are
;;;; installed there before anything can report, and every publisher and feed a
;;;; case opens is closed when it ends.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-buswatch-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/host-buswatch-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:buswatch #:dsmr-bus-host/src/bus/host/buswatch)
                    (#:ident #:dsmr-bus-host/src/bus/host/identity)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:archive #:dsmr-mcp/src/bus/archive)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:tz #:dsmr-mcp/src/bus/zmq)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:default-wal-path
                #:default-cursors-dir
                #:%reap-notifiers
                #:%unix-time))

(in-package #:dsmr-mcp/tests/bus/host-buswatch-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *bus* "hb"
  "The bus every fixture watches.")

(defparameter *ns* "/home/x/proj"
  "The namespace every fixture's agents live in.")

(defparameter *other* "/ns/other"
  "An agent in another project, the author of every foreign record.")

(defvar *claimed* '()
  "Identities claimed during the current case, released when it ends.")

(defvar *watches* '()
  "Bus watches opened during the current case, closed when it ends.")

(defvar *endpoints* '()
  "Publishers opened during the current case, closed when it ends.")

(defvar *stopping* nil
  "Set to end the watch threads of the current case.")

(defvar *reports* '()
  "Reports COLLECT-REPORT has been handed, newest first, each as (level code
   msg).")

(defun short-temp-dir ()
  "A new empty directory directly under /tmp with a short name, so the sockets
   of a bus rooted inside it fit the unix-domain path limit."
  (loop for dir = (format nil "/tmp/h43bw-~36R~36R/" (sb-posix:getpid) (random 1000000))
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
  "Call THUNK with XDG_STATE_HOME pointing at a fresh short directory, the
   fleet and service logs installed inside it, the bus's directories made, and
   stand-in notification programs first on PATH. Afterwards every watch thread
   is stopped, every watch and publisher closed, every identity let go and the
   directory removed."
  (let* ((state (short-temp-dir))
         (stubs (merge-pathnames "stub/" state))
         (previous (uiop:getenv "XDG_STATE_HOME"))
         (previous-path (uiop:getenv "PATH"))
         (*claimed* '())
         (*watches* '())
         (*endpoints* '())
         (*stopping* nil)
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
           (fleetlog:install-fleet-log
            :path (hostfiles:fleet-log-path)
            :service-log-path (merge-pathnames "service.log" (hostfiles:host-dir)))
           (ensure-directories-exist (default-wal-path *bus*))
           (ensure-directories-exist (default-cursors-dir *bus*))
           (ensure-directories-exist (hostfiles:watch-state-dir))
           (funcall thunk))
      (setf *stopping* t)
      (dolist (bw *watches*)
        (ignore-errors (buswatch:close-bus-watch bw)))
      (dolist (endpoint *endpoints*)
        (ignore-errors (tz:close-endpoint endpoint)))
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

(defun id (agent)
  "The full id of AGENT in the fixtures' namespace."
  (format nil "~A/~A" *ns* agent))

(defun claim (agent)
  "Claim AGENT on the fixtures' bus for this process, noting it for release."
  (let ((identity (ident:claim-identity
                   (list :id (id agent) :bus *bus* :poll-ms 250 :recycle-seconds 600
                         :deaf-seconds 600 :session-pid (sb-posix:getpid)
                         :session-start nil :token "t1")
                   :service-pid (sb-posix:getpid)
                   :report-fn #'collect-report)))
    (push identity *claimed*)
    identity))

(defun open-watch (&key (feed t))
  "Open the watch of the fixtures' bus, noting it for closing."
  (let ((bw (buswatch:open-bus-watch *bus* :feed feed)))
    (push bw *watches*)
    bw))

(defun pub-endpoint ()
  (broker:bus-paths-pub-endpoint (broker:make-bus-paths (broker:default-state-root *bus*))))

(defun open-publisher ()
  "Bind a publisher on the bus's publication endpoint, noting it for closing."
  (let ((publisher (tz:make-publisher (pub-endpoint))))
    (push publisher *endpoints*)
    publisher))

(defun close-publisher (publisher)
  (tz:close-endpoint publisher)
  (setf *endpoints* (remove publisher *endpoints*)))

(defun wal-path () (default-wal-path *bus*))

(defun append-from (seq author &key to (text "x"))
  "Append record SEQ to the bus's log as published by AUTHOR."
  (wal:append-record (wal-path) seq (envelope:wrap-envelope "c1" author text :to to))
  seq)

(defun cursor-file (agent)
  "AGENT's cursor on the fixtures' bus."
  (merge-pathnames (envelope:encode-id (id agent)) (default-cursors-dir *bus*)))

(defun log-lines (agent)
  "The lines of AGENT's watch log, or NIL."
  (let ((path (hostfiles:watch-state-file (hostfiles:detach-stem *bus* (id agent)) "log")))
    (and (probe-file path) (uiop:read-file-lines path))))

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

(defun step-watch (bw identities)
  "One step of BW for IDENTITIES under the healing supervisor."
  (healing (lambda ()
             (buswatch:bus-watch-step bw identities (%unix-time)
                                      :report-fn #'collect-report))))

(defun run-watch (bw identities)
  "Run BW's thread over IDENTITIES until the case ends."
  (buswatch:start-bus-watch-thread bw (lambda () *stopping*)
                                   (lambda () identities)
                                   :report-fn #'collect-report))

(defun seconds-until (thunk &optional (limit 3))
  "Seconds until THUNK answers true, polled every 5 ms, or NIL when LIMIT
   seconds pass first."
  (let ((start (get-internal-real-time)))
    (loop
      (when (funcall thunk)
        (return (/ (- (get-internal-real-time) start)
                   (float internal-time-units-per-second))))
      (when (> (- (get-internal-real-time) start)
               (* limit internal-time-units-per-second))
        (return nil))
      (sleep 0.005))))

(defun line-count-reaches (agent n)
  (lambda () (>= (length (log-lines agent)) n)))

;;; ----------------------------------------------------------------- the reads

(define-test without-a-feed-a-record-still-wakes-within-the-backstop
  "With no publication feed at all, a record appended to the log is announced
   within the 250 ms backstop plus processing."
  (with-host ()
    (let* ((alpha (claim "alpha"))
           (bw (open-watch :feed nil)))
      (false (buswatch:bus-watch-feed bw))
      (run-watch bw (list alpha))
      (sleep 0.3)
      (append-from 1 *other*)
      (let ((seconds (seconds-until (line-count-reaches "alpha" 1))))
        (true seconds "the line was written")
        (true (and seconds (<= seconds 0.4)) "within 400 ms: ~A" seconds))
      (is = 1 (length (log-lines "alpha")))
      (true (uiop:string-prefix-p "bus:1 " (first (log-lines "alpha")))))))

(define-test a-publisher-restart-loses-no-wake
  "With a feed, a nudge after an append produces the line, and after the
   publisher is closed and bound again on the same endpoint every further
   append still produces its line within 400 ms."
  (with-host ()
    (let* ((alpha (claim "alpha"))
           (publisher (open-publisher))
           (bw (open-watch)))
      (true (buswatch:bus-watch-feed bw))
      (run-watch bw (list alpha))
      (sleep 0.3)
      (loop for seq from 1 to 2
            do (append-from seq *other*)
               (tz:send-message publisher (princ-to-string seq))
               (let ((seconds (seconds-until (line-count-reaches "alpha" seq))))
                 (true (and seconds (<= seconds 0.4))
                       "before the restart, record ~D within 400 ms: ~A" seq seconds)))
      (close-publisher publisher)
      (setf publisher (open-publisher))
      (loop for seq from 3 to 5
            do (append-from seq *other*)
               (tz:send-message publisher (princ-to-string seq))
               (let ((seconds (seconds-until (line-count-reaches "alpha" seq))))
                 (true (and seconds (<= seconds 0.4))
                       "after the restart, record ~D within 400 ms: ~A" seq seconds)))
      (is = 5 (length (log-lines "alpha")))
      (true (plusp (buswatch:bus-watch-nudges-seen bw)) "the feed rang at least once"))))

(define-test a-log-growing-under-a-silent-feed-remakes-the-feed
  "A feed connected to a publisher that never sends, while three records land
   over a second: the growth across two backstop ticks raises
   PUBLICATION-GAP, and its heal remakes the feed. The mail is announced all
   the same."
  (with-host ()
    (let* ((alpha (claim "alpha"))
           (publisher (open-publisher))
           (bw (open-watch))
           (before (buswatch:bus-watch-feed bw)))
      (declare (ignore publisher))
      (true before)
      (step-watch bw (list alpha))
      (loop for seq from 1 to 3
            do (append-from seq *other*)
               (step-watch bw (list alpha)))
      (true (reports :info "publication-gap") "the gap was healed and reported")
      (true (search "reconnect-feed" (third (first (reports :info "publication-gap")))))
      (true (buswatch:bus-watch-feed bw))
      (false (eq before (buswatch:bus-watch-feed bw)) "the feed is a new one")
      (is = 3 (length (log-lines "alpha"))))))

(define-test every-identity-is-fed-from-one-read
  "Two agents on one bus get their lines from a single read of the log: the
   shared reader is consulted once per step however many agents there are."
  (with-host ()
    (let* ((alpha (claim "alpha"))
           (beta (claim "beta"))
           (bw (open-watch :feed nil))
           (reads 0))
      (step-watch bw (list alpha beta))
      (append-from 1 *other*)
      (sb-int:encapsulate 'dsmr-bus-watch/src/bus/watch::%poll-forward 'count-reads
                          (lambda (f &rest args) (incf reads) (apply f args)))
      (unwind-protect
           (progn
             (step-watch bw (list alpha beta))
             (is = 1 reads "one read for two agents")
             (append-from 2 *other*)
             (step-watch bw (list alpha))
             (is = 2 reads "one read for one agent"))
        (sb-int:unencapsulate 'dsmr-bus-watch/src/bus/watch::%poll-forward 'count-reads))
      (is = 2 (length (log-lines "alpha")))
      (is = 1 (length (log-lines "beta")))
      (true (uiop:string-prefix-p "bus:1 " (first (log-lines "beta"))))
      (is = (with-open-file (in (wal-path) :element-type '(unsigned-byte 8))
              (file-length in))
          (wal:reader-offset (buswatch:bus-watch-reader bw))
          "the shared reader stands at the end of the log")
      (is = 3 (buswatch:bus-watch-progress bw)))))

;;; ------------------------------------------------------------------ rotation

(define-test a-rotation-rebases-every-stranded-stable-cursor-once
  "Cursors at 4 of generation 1 on a log holding 1 to 4; the log is archived,
   its generation bumped and two new records land. WAL-ROTATED is raised once,
   its heal rebases the agent's cursor and another stable cursor (each reported
   as a stranded cursor), leaves an ephemeral cursor alone, and the agent hears
   the new records in one line."
  (with-host ()
    (loop for seq from 1 to 4 do (append-from seq *other*))
    (write-text (wal:generation-path (wal-path)) "1")
    (write-text (cursor-file "alpha") "4 1")
    (write-text (cursor-file "beta") "4 1")
    (write-text (cursor-file "g123-456") "4 1")
    (let* ((alpha (claim "alpha"))
           (bw (open-watch :feed nil)))
      (is = 4 (ident:identity-floor alpha))
      (step-watch bw (list alpha))
      (false (log-lines "alpha") "nothing above the cursor yet")
      (archive:archive-wal (wal-path) (broker:bus-paths-root
                                       (broker:make-bus-paths
                                        (broker:default-state-root *bus*))))
      (is = 2 (wal:generation (wal-path)))
      (append-from 1 *other*)
      (append-from 2 *other*)
      (step-watch bw (list alpha))
      (step-watch bw (list alpha))
      (is = 1 (length (reports :info "wal-rotated")) "raised and healed once")
      (true (search "rebase-cursors" (third (first (reports :info "wal-rotated")))))
      (is = 2 (length (reports :warn "stranded-cursor")) "two stable cursors rebased")
      (true (every (lambda (r) (search "old-cursor=4" (third r)))
                   (reports :warn "stranded-cursor")))
      (is string= "0 2" (uiop:read-file-string (cursor-file "alpha")))
      (is string= "0 2" (uiop:read-file-string (cursor-file "beta")))
      (is string= "4 1" (uiop:read-file-string (cursor-file "g123-456"))
          "the ephemeral cursor is untouched")
      (is = 1 (length (log-lines "alpha")))
      (true (uiop:string-prefix-p "bus:2 " (first (log-lines "alpha"))))
      (is = 2 (ident:identity-floor alpha)))))

(define-test an-agent-without-a-cursor-hears-the-new-log-after-a-rotation
  "An agent with no cursor of its own was armed at the head of the old log.
   Everything in the new log arrived after the rotation, so it is all owed to
   the agent and is announced."
  (with-host ()
    (loop for seq from 1 to 3 do (append-from seq *other*))
    (let* ((alpha (claim "alpha"))
           (bw (open-watch :feed nil)))
      (is = 3 (ident:identity-floor alpha))
      (step-watch bw (list alpha))
      (archive:archive-wal (wal-path) (broker:bus-paths-root
                                       (broker:make-bus-paths
                                        (broker:default-state-root *bus*))))
      (append-from 1 *other*)
      (step-watch bw (list alpha))
      (is = 1 (length (log-lines "alpha")))
      (true (uiop:string-prefix-p "bus:1 " (first (log-lines "alpha")))))))
