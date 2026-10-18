;;;; tests/bus/host-wake-service-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the host service's wake clients as the running service
;;;; serves them, in this process. Covered:
;;;;   - the service listens on the wake socket, resolves each request against
;;;;     the agents it serves, catches a newcomer up from the log, persists what
;;;;     it delivered across a restart, and counts clients instead of scanning
;;;;     /proc;
;;;;   - an identity offers every wake line it writes to a hook, and never
;;;;     re-delivers below the position it persisted;
;;;;   - a bus watch takes its reader counts from outside.
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
                    (#:service #:dsmr-bus-host/src/bus/host/main)
                    (#:listeners #:dsmr-bus-host/src/bus/host/listeners)
                    (#:memory #:dsmr-bus-host/src/bus/host/memory)
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

(defvar *services* '()
  "Services made during the current case, stopped when it ends.")

(defvar *clients* '()
  "Client sockets opened during the current case, closed when it ends.")

(defstruct client
  "A test wake client: its socket and the octets read but not yet returned."
  socket
  (pending (make-array 0 :element-type '(unsigned-byte 8) :adjustable t
                         :fill-pointer 0)))

(defun call-with-host (thunk)
  "Call THUNK with XDG_STATE_HOME pointing at a fresh short directory, the fleet
   and service logs installed inside it, the host directory and the bus's
   directories made, and stand-in notify-send and gdbus programs first on PATH.
   Afterwards every client is closed, every service stopped, every watch
   closed, every identity released and the directory removed."
  (let* ((state (short-temp-dir))
         (stubs (merge-pathnames "stub/" state))
         (previous (uiop:getenv "XDG_STATE_HOME"))
         (previous-path (uiop:getenv "PATH"))
         (*claimed* '())
         (*watches* '())
         (*services* '())
         (*clients* '())
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
      (dolist (client *clients*)
        (ignore-errors (sb-bsd-sockets:socket-close (client-socket client))))
      (dolist (svc *services*)
        (ignore-errors (service:stop-service svc :mark-clean nil)))
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

;;; -------------------------------------------------- the service: fixtures

(defun register (agent &key (bus *bus*) (deaf-seconds 600) (token "t1"))
  "Leave a registration for AGENT on BUS, as --detach would, naming no
   session."
  (hostfiles:write-registration
   (stem agent bus)
   (list :id (id agent) :bus bus :poll-ms 250 :recycle-seconds 600
         :deaf-seconds deaf-seconds :token token :registered-at (%unix-time)
         :cli-version "test")))

(defun seed-log (&key (bus *bus*))
  "Give BUS's log a first record, seq 1, addressed to an agent no fixture
   serves, so every fixture agent steps over it without a line."
  (append-from 1 *other* :bus bus :to "/ns/nobody"))

(defun write-cursor (agent seq &key (bus *bus*))
  "Set AGENT's cursor on BUS to SEQ."
  (write-text (cursor-file agent bus) (princ-to-string seq)))

(defun new-service ()
  "A started service run by this process, listening on the wake socket,
   reading its buses without a feed and reading calm memory, noted for
   stopping."
  (let ((svc (service:make-service
              :feed-p nil
              :memory-reader (lambda ()
                               (memory:make-memory-readings
                                :some-avg10 0.0 :full-avg10 0.0
                                :mem-total-kb 1000000 :mem-available-kb 500000)))))
    (push svc *services*)
    (service:start-service svc)
    svc))

(defun tick (svc now)
  "One supervisor tick of SVC at NOW, in Unix seconds."
  (service:supervisor-tick svc now))

(defun connect ()
  "A client connected to the host's wake socket, noted for closing."
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (sb-bsd-sockets:socket-connect socket (uiop:native-namestring
                                           (hostfiles:wake-socket-path)))
    (let ((client (make-client :socket socket)))
      (push client *clients*)
      client)))

(defun send-text (client text)
  "Send TEXT from CLIENT as UTF-8."
  (sb-bsd-sockets:socket-send (client-socket client)
                              (sb-ext:string-to-octets text :external-format :utf-8)
                              nil :nosignal t))

(defun read-reply (client &optional (seconds 2))
  "The next line CLIENT receives within SECONDS, without its newline, :EOF when
   the connection was closed, or :TIMEOUT when no whole line arrived."
  (let* ((socket (client-socket client))
         (fd (sb-bsd-sockets:socket-file-descriptor socket))
         (deadline (+ (get-internal-real-time)
                      (round (* seconds internal-time-units-per-second))))
         (chunk (make-array 4096 :element-type '(unsigned-byte 8))))
    (loop
      (let* ((buffer (client-pending client))
             (newline (position 10 buffer)))
        (when newline
          (let ((line (sb-ext:octets-to-string (subseq buffer 0 newline)
                                               :external-format :utf-8))
                (rest (make-array (- (length buffer) newline 1)
                                  :element-type '(unsigned-byte 8) :adjustable t
                                  :fill-pointer (- (length buffer) newline 1))))
            (replace rest buffer :start2 (1+ newline))
            (setf (client-pending client) rest)
            (return line))))
      (let ((remaining (/ (- deadline (get-internal-real-time))
                          internal-time-units-per-second)))
        (when (<= remaining 0)
          (return :timeout))
        (when (sb-sys:wait-until-fd-usable fd :input remaining nil)
          (let ((count (handler-case
                           (nth-value 1 (sb-bsd-sockets:socket-receive socket chunk nil))
                         (error () 0))))
            (if (or (null count) (zerop count))
                (return :eof)
                (loop for index below count
                      do (vector-push-extend (aref chunk index)
                                             (client-pending client))))))))))

(defun wake-request (agent &key (bus *bus*) hook all-buses (pid 4242))
  "A version 1 wake request, with its newline, naming AGENT by full id on BUS
   (NIL for none), as a hook client when HOOK, for every bus when ALL-BUSES."
  (format nil "WAKE 1 hook=~D allbuses=~D agent=- ns=- agentid=~A envagent=- ~
               bus=~A envbus=- cwd=- pid=~D~%"
          (if hook 1 0) (if all-buses 1 0)
          (hostfiles:percent-encode-field (id agent))
          (if bus (hostfiles:percent-encode-field bus) "-")
          pid))

(defun waiting-client (agent &rest keys &key bus hook all-buses)
  "A client connected to the wake socket that has sent AGENT's wake request,
   built by WAKE-REQUEST from KEYS."
  (declare (ignore bus hook all-buses))
  (let ((client (connect)))
    (send-text client (apply #'wake-request agent keys))
    client))

(defun decoded (reply index)
  "The text field INDEX of REPLY decoded, or NIL for `-` or a reply that is
   not a string. Index 3 is stdout, 4 stderr."
  (and (stringp reply)
       (let ((field (nth index (uiop:split-string reply :separator " "))))
         (and field (hostfiles:percent-decode-field field)))))

(defun eventually (thunk &optional (seconds 3))
  "The first true value THUNK returns within SECONDS, or NIL."
  (loop with deadline = (+ (get-internal-real-time)
                           (* seconds internal-time-units-per-second))
        for value = (funcall thunk)
        when value
          return value
        when (> (get-internal-real-time) deadline)
          return nil
        do (sleep 0.02)))

(defun queued (svc agent count &key (bus *bus*))
  "True once COUNT clients wait on AGENT's stem on BUS in SVC's hub."
  (eventually (lambda ()
                (= count (listeners:hub-reader-count (service:service-hub svc)
                                                     (stem agent bus))))))

(defun call-recording-tick-readers (thunk)
  "Call THUNK with IDENTITY-TICK wrapped to note the :READERS it is handed, and
   return the noted values, oldest first."
  (let ((seen '())
        (original (fdefinition 'ident:identity-tick)))
    (unwind-protect
         (progn
           (setf (fdefinition 'ident:identity-tick)
                 (lambda (identity now &rest keys)
                   (push (getf keys :readers) seen)
                   (apply original identity now keys)))
           (funcall thunk))
      (setf (fdefinition 'ident:identity-tick) original))
    (nreverse seen)))

;;; ----------------------------------------------------- the service: cases

(define-test a-waiting-client-is-handed-the-next-wake-line
  "A background client queued for a registered agent is handed the next wake
   line as EXIT 0 event, its text the very line the agent's log got, and is
   then closed."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (let ((svc (new-service)))
      (tick svc (%unix-time))
      (let ((client (waiting-client "alpha")))
        (true (queued svc "alpha" 1))
        (append-from 2 *other*)
        (let ((reply (read-reply client 3)))
          (true (eventually (lambda () (log-lines "alpha"))) "no line was written")
          (let ((line (first (log-lines "alpha"))))
            (true (uiop:string-prefix-p "bus:2 from=" line) "~S" line)
            (is equal (listeners:event-reply nil "hw" line) reply)
            (is equal (format nil "~A~%" line) (decoded reply 3))))
        (is eq :eof (read-reply client 2))))))

(define-test a-hook-client-is-handed-the-line-with-the-drain-advice
  "A hook client is handed the line as EXIT 2 event, the line and the drain
   advice on stderr and nothing on stdout."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (let ((svc (new-service)))
      (tick svc (%unix-time))
      (let ((client (waiting-client "alpha" :hook t)))
        (true (queued svc "alpha" 1))
        (append-from 2 *other*)
        (let ((reply (read-reply client 3)))
          (true (eventually (lambda () (log-lines "alpha"))))
          (let ((line (first (log-lines "alpha"))))
            (is equal (listeners:event-reply t "hw" line) reply)
            (true (and (stringp reply) (uiop:string-prefix-p "EXIT 2 event - " reply)))
            (true (search "Drain the bus now" (or (decoded reply 4) "")))
            (true (uiop:string-prefix-p line (or (decoded reply 4) "")))))))))

(define-test mail-that-arrived-unheard-reaches-the-next-client
  "A line written while no client waits is handed at once to the next client
   that connects, caught up from the log above the agent's cursor."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (let ((svc (new-service)))
      (tick svc (%unix-time))
      (append-from 2 *other*)
      (true (eventually (lambda () (log-lines "alpha"))) "no line was written")
      (let ((reply (read-reply (waiting-client "alpha") 2)))
        (is equal (listeners:event-reply nil "hw" (first (log-lines "alpha"))) reply)))))

(define-test mail-the-cursor-has-passed-is-not-handed-over
  "Once the agent's cursor has moved past mail that arrived unheard, a new
   client is not handed that mail and waits instead."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (let ((svc (new-service)))
      (tick svc (%unix-time))
      (append-from 2 *other*)
      (true (eventually (lambda () (log-lines "alpha"))) "no line was written")
      (write-cursor "alpha" 2)
      (let ((client (waiting-client "alpha")))
        (true (queued svc "alpha" 1))
        (is eq :timeout (read-reply client 1))))))

(define-test only-the-head-of-the-queue-gets-a-line
  "With two background clients waiting, only the first is handed the next
   line; the second is handed the one after."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (let ((svc (new-service)))
      (tick svc (%unix-time))
      (let ((a (waiting-client "alpha")))
        (true (queued svc "alpha" 1))
        (let ((b (waiting-client "alpha")))
          (true (queued svc "alpha" 2))
          (append-from 2 *other*)
          (let ((reply (read-reply a 3)))
            (true (and (stringp reply) (uiop:string-prefix-p "bus:2 " (decoded reply 3)))
                  "~S" reply))
          (is eq :timeout (read-reply b 0.3) "the second client was handed the first line")
          (append-from 3 *other*)
          (let ((reply (read-reply b 3)))
            (true (and (stringp reply) (uiop:string-prefix-p "bus:3 " (decoded reply 3)))
                  "~S" reply)))))))

(define-test a-delivered-seq-survives-a-restart-and-is-not-handed-again
  "Each send is persisted as the stem's delivered position with the log's
   generation. A fresh service on the same state home does not hand that seq
   to a new client again, and does hand it the next one."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (let ((first (new-service)))
      (tick first (%unix-time))
      (let ((client (waiting-client "alpha")))
        (true (queued first "alpha" 1))
        (append-from 2 *other*)
        (let ((reply (read-reply client 3)))
          (true (and (stringp reply) (uiop:string-prefix-p "bus:2 " (decoded reply 3)))
                "~S" reply)))
      (is eql 2 (eventually (lambda ()
                              (hostfiles:read-delivered-position
                               (stem "alpha") :generation (wal:generation (wal-path))))))
      (service:stop-service first :mark-clean t))
    (let ((second (new-service)))
      (tick second (%unix-time))
      (let ((client (waiting-client "alpha")))
        (true (queued second "alpha" 1))
        (is eq :timeout (read-reply client 1) "a seq handed over before the restart came again")
        (append-from 3 *other*)
        (let ((reply (read-reply client 3)))
          (true (and (stringp reply) (uiop:string-prefix-p "bus:3 " (decoded reply 3)))
                "~S" reply))))))

(define-test a-delivered-position-from-a-rotated-log-does-not-hold-mail-back
  "A delivered position written for another generation of the log is ignored:
   mail in the current log still reaches the next client."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (hostfiles:write-delivered-position (stem "alpha") 50
                                        :generation (1+ (wal:generation (wal-path))))
    (append-from 2 *other*)
    (let ((svc (new-service)))
      (tick svc (%unix-time))
      (let ((reply (read-reply (waiting-client "alpha") 3)))
        (true (and (stringp reply) (uiop:string-prefix-p "bus:2 " (decoded reply 3)))
              "~S" reply)))))

(define-test a-client-before-the-first-scan-waits-for-it
  "A client that connects before the registrations have been read gets no
   reply; after the first tick a registered agent's client is queued and an
   unregistered agent's client reads the nowatcher reply."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (let* ((svc (new-service))
           (alpha (waiting-client "alpha"))
           (ghost (waiting-client "ghost")))
      (is eq :timeout (read-reply alpha 0.5))
      (is eq :timeout (read-reply ghost 0.2))
      (tick svc (%unix-time))
      (true (queued svc "alpha" 1))
      (let ((reply (read-reply ghost 2)))
        (is equal (listeners:nowatcher-reply nil "hw" (id "ghost") t) reply)
        (is equal (format nil "nowatcher bus=hw~%") (decoded reply 3))))))

(define-test an-unregistered-agent-is-told-no-watcher-serves-it
  "A request for every bus from an agent registered nowhere is answered with
   the nowatcher reply labelled `*`, and a request naming a bus that cannot be
   a bus is refused as bad-bus."
  (with-host (state)
    (let ((svc (new-service)))
      (tick svc (%unix-time))
      (let ((reply (read-reply (waiting-client "ghost" :bus nil :all-buses t) 2)))
        (is equal (listeners:nowatcher-reply nil "*" (id "ghost") t) reply)
        (is equal (format nil "nowatcher bus=*~%") (decoded reply 3)))
      (let ((reply (read-reply (waiting-client "ghost" :bus "a b") 2)))
        (true (and (stringp reply) (uiop:string-prefix-p "ERR bad-bus " reply))
              "~S" reply)))))

(define-test a-client-whose-registration-goes-is-told-and-closed
  "When an agent's registration is removed, the next tick tells its waiting
   client that no watcher serves it, in its mode, and closes it."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (let ((svc (new-service))
          (now (%unix-time)))
      (tick svc now)
      (let ((client (waiting-client "alpha")))
        (true (queued svc "alpha" 1))
        (delete-file (hostfiles:registration-path (stem "alpha")))
        (tick svc (+ now 1))
        (let ((reply (read-reply client 2)))
          (is equal (listeners:nowatcher-reply nil "hw" (id "alpha") t) reply)
          (is equal (format nil "nowatcher bus=hw~%") (decoded reply 3)))
        (is eq :eof (read-reply client 2))))))

(define-test an-all-buses-client-hears-every-bus-it-is-registered-on
  "A request for every bus waits on each bus the agent is registered on, and a
   line on either reaches it labelled with that bus."
  (with-host (state)
    (dolist (bus '("hw" "hx"))
      (seed-log :bus bus)
      (register "alpha" :bus bus)
      (write-cursor "alpha" 1 :bus bus))
    (let ((svc (new-service)))
      (tick svc (%unix-time))
      (let ((client (waiting-client "alpha" :bus nil :all-buses t :hook t)))
        (true (queued svc "alpha" 1 :bus "hw"))
        (true (queued svc "alpha" 1 :bus "hx"))
        (append-from 2 *other* :bus "hx")
        (let ((reply (read-reply client 3)))
          (true (eventually (lambda () (log-lines "alpha" "hx"))))
          (is equal (listeners:event-reply t "hx" (first (log-lines "alpha" "hx"))) reply)))
      (let ((client (waiting-client "alpha" :bus nil :all-buses t :hook t)))
        (true (queued svc "alpha" 1 :bus "hw"))
        (append-from 2 *other* :bus "hw")
        (let ((reply (read-reply client 3)))
          (true (eventually (lambda () (log-lines "alpha" "hw"))))
          (is equal (listeners:event-reply t "hw" (first (log-lines "alpha" "hw"))) reply))))))

(define-test the-identity-tick-counts-hub-clients-not-proc-readers
  "With a hub running, the identity tick is handed the number of waiting
   clients as its readers, 0 with none and 1 with one, and neither the ticks
   nor a delivery runs the /proc census."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (let* ((svc (new-service))
           (now (%unix-time))
           (seen '())
           (calls
             (call-counting-census
              (lambda ()
                (setf seen
                      (call-recording-tick-readers
                       (lambda ()
                         (tick svc now)
                         (let ((client (waiting-client "alpha")))
                           (true (queued svc "alpha" 1))
                           (tick svc (+ now 1))
                           (append-from 2 *other*)
                           (true (stringp (read-reply client 3))
                                 "the client was not handed the line")))))))))
      (is equal '(0 1) seen)
      (is = 0 calls "the census ran inside the service"))))

(define-test a-line-nobody-hears-raises-deafness-and-a-client-clears-it
  "A wake line written while no client waits starts the deafness clock; past
   the threshold the identity tick raises the marker, and a client that then
   connects and is handed the line clears it at the next tick."
  (with-host (state)
    (seed-log)
    (register "alpha" :deaf-seconds 2)
    (write-cursor "alpha" 1)
    (let* ((svc (new-service))
           (now (%unix-time))
           (marker (hostfiles:watch-state-file (stem "alpha") "deaf")))
      (tick svc now)
      (append-from 2 *other*)
      (true (eventually (lambda () (log-lines "alpha"))) "no line was written")
      (tick svc (+ now 5))
      (true (probe-file marker) "no deafness marker after the threshold")
      ;; Heard has to come after the unheard line in whole seconds.
      (sleep 1.1)
      (let ((client (waiting-client "alpha")))
        (true (stringp (read-reply client 3)) "the client was not handed the line"))
      (tick svc (+ now 6))
      (false (probe-file marker) "the marker outlived the client"))))

(define-test a-wedged-accept-loop-stops-the-watchdog
  "The hub's accept loop counts toward the watchdog: while it runs the service
   reads as progressing, and a hub whose count is held still past the window
   reads as stalled."
  (with-host (state)
    (let* ((svc (new-service))
           (real (service:service-hub svc))
           (now (%unix-time)))
      (true real "the hub did not start")
      (true (service::%threads-progressing-p svc now))
      (sleep 0.6)
      (true (service::%threads-progressing-p svc (+ now 11))
            "a running accept loop read as stalled")
      (unwind-protect
           (progn
             (setf (service:service-hub svc) (listeners:make-hub))
             (service::%threads-progressing-p svc (+ now 20))
             (false (service::%threads-progressing-p svc (+ now 31))
                    "a held count read as progressing"))
        (setf (service:service-hub svc) real)))))

(define-test stopping-the-service-stops-the-hub-first
  "An orderly stop ends every waiting client, which reads end of file, and
   removes the wake socket."
  (with-host (state)
    (seed-log)
    (register "alpha")
    (write-cursor "alpha" 1)
    (let ((svc (new-service)))
      (tick svc (%unix-time))
      (let ((client (waiting-client "alpha")))
        (true (queued svc "alpha" 1))
        (service:stop-service svc :mark-clean nil)
        (is eq :eof (read-reply client 2))
        (false (probe-file (hostfiles:wake-socket-path)) "the socket file is still there")
        (false (service:service-hub svc))))))

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
