;;;; tests/bus/host-brokers-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the brokers the host service runs: one thread per bus that
;;;; holds a membership of its own before it contends, waits behind a broker a
;;;; client elected and records that as a degradation, serves once it wins, is
;;;; relaunched when it dies, and never rotates the log when it stops. Also the
;;;; discovery of which buses the service should serve.
;;;;
;;;; Every bus lives under a fresh short directory in /tmp used as the state
;;;; home (a socket path has to fit in 107 bytes), the fleet and service logs are
;;;; installed there before anything can report, every broker a case starts is
;;;; stopped when it ends, and the only process a case signals is the `sleep` it
;;;; started to stand in for an incumbent broker.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-brokers-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/host-brokers-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:brokers #:dsmr-bus-host/src/bus/host/brokers)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:conditions #:dsmr-bus-host/src/bus/host/conditions)
                    (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:election #:dsmr-mcp/src/bus/election)
                    (#:tz #:dsmr-mcp/src/bus/zmq)
                    (#:wal #:dsmr-mcp/src/bus/wal)))

(in-package #:dsmr-mcp/tests/bus/host-brokers-test)

;;; ------------------------------------------------------------------ fixtures

(defvar *brokers* '()
  "Bus brokers started during the current case, stopped when it ends.")

(defvar *cleanups* '()
  "Functions to call when the current case ends, newest first.")

(defvar *reports* '()
  "Reports COLLECT-REPORT has been handed, newest first, each as (level code
   msg).")

(defun short-temp-dir ()
  "A new empty directory directly under /tmp with a short name, so the sockets
   of a bus rooted inside it fit the unix-domain path limit."
  (loop for dir = (format nil "/tmp/h43bb-~36R~36R/" (sb-posix:getpid) (random 1000000))
        unless (probe-file dir)
          do (ensure-directories-exist dir)
             (return (pathname dir))))

(defun call-with-host (thunk)
  "Call THUNK with XDG_STATE_HOME pointing at a fresh short directory and the
   fleet and service logs installed inside it. Afterwards every broker is
   stopped, every clean-up run and the directory removed."
  (let* ((state (short-temp-dir))
         (previous (uiop:getenv "XDG_STATE_HOME"))
         (*brokers* '())
         (*cleanups* '())
         (*reports* '()))
    (unwind-protect
         (progn
           (sb-posix:setenv "XDG_STATE_HOME" (namestring state) 1)
           (fleetlog:install-fleet-log
            :path (hostfiles:fleet-log-path)
            :service-log-path (merge-pathnames "service.log" (hostfiles:host-dir)))
           (funcall thunk))
      (dolist (fn *cleanups*)
        (ignore-errors (funcall fn)))
      (dolist (bb *brokers*)
        (ignore-errors (brokers:stop-bus-broker bb)))
      (fleetlog:remove-fleet-log)
      (if previous
          (sb-posix:setenv "XDG_STATE_HOME" previous 1)
          (ignore-errors (sb-posix:unsetenv "XDG_STATE_HOME")))
      (ignore-errors (uiop:delete-directory-tree state :validate t
                                                       :if-does-not-exist :ignore)))))

(defmacro with-host (() &body body)
  "Run BODY inside CALL-WITH-HOST."
  `(call-with-host (lambda () ,@body)))

(defun on-exit (fn)
  "Call FN when the current case ends."
  (push fn *cleanups*))

(defun paths (bus)
  (broker:make-bus-paths (broker:default-state-root bus)))

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

(defun start (bus)
  "Start the service's broker for BUS, noting it for stopping."
  (let ((bb (brokers:start-bus-broker bus :report-fn #'collect-report)))
    (when bb (push bb *brokers*))
    bb))

(defun check (bb now &key leader)
  "Check BB under the healing supervisor, as the service at this pid."
  (healing (lambda ()
             (brokers:check-bus-broker bb (sb-posix:getpid) now
                                       :report-fn #'collect-report
                                       :leader-registered-p leader
                                       :recovered-fn nil))))

(defun await (thunk &optional (seconds 5))
  "Call THUNK every 20 ms until it answers true or SECONDS pass, and return its
   last answer."
  (loop repeat (* 50 seconds)
        for answer = (funcall thunk)
        when answer do (return answer)
        do (sleep 0.02)
        finally (return (funcall thunk))))

(defun state-is (bb state)
  (lambda () (eq state (brokers:bus-broker-state bb))))

(defun head (bus)
  "The highest seq in BUS's log."
  (values (wal:scan (broker:bus-paths-wal (paths bus)))))

(defun submit (bus text)
  "Send TEXT to BUS's broker and wait until the log holds one more record."
  (let ((before (head bus))
        (submitter (tz:make-submitter (broker:bus-paths-submit-endpoint (paths bus)))))
    (unwind-protect
         (progn (tz:send-message submitter text)
                (await (lambda () (> (head bus) before))))
      (sleep 0.05)
      (tz:close-endpoint submitter))))

(defun send-only (bus text)
  "Send TEXT to BUS's broker without waiting for it to land."
  (let ((submitter (tz:make-submitter (broker:bus-paths-submit-endpoint (paths bus)))))
    (tz:send-message submitter text)
    (sleep 0.2)
    (tz:close-endpoint submitter)))

(defun archives (bus)
  "The archived logs in BUS's root."
  (remove-if-not (lambda (file) (search "bus.wal.archive-" (file-namestring file)))
                 (uiop:directory-files (broker:bus-paths-root (paths bus)))))

(defun hold-lock (path)
  "Take the exclusive election lock on PATH through a descriptor of its own,
   as an incumbent broker would, and return the descriptor."
  (let ((fd (election:open-lock path)))
    (unless (election:try-lock-exclusive fd)
      (election:close-lock fd)
      (error "The lock on ~A is already held." path))
    fd))

(defun free-p (path)
  "True when nobody holds any lock on PATH: a fresh descriptor takes it
   exclusively at once. The lock taken is let go again."
  (let ((fd (election:open-lock path)))
    (unwind-protect
         (when (election:try-lock-exclusive fd)
           (election:unlock fd)
           t)
      (election:close-lock fd))))

(defun start-sleeper ()
  "Start a `sleep` standing in for an incumbent broker process, ended when the
   case ends, and return its pid."
  (let* ((process (uiop:launch-program (list "sleep" "600")
                                       :input nil :output nil :error-output nil))
         (pid (uiop:process-info-pid process)))
    (on-exit (lambda ()
               (ignore-errors (sb-posix:kill pid sb-posix:sigkill))
               (ignore-errors (uiop:wait-process process))))
    (await (lambda () (hostfiles:proc-starttime pid)))
    pid))

(defun write-incumbent-identity (bus pid)
  "Leave the identity record an incumbent broker with PID would write."
  (let ((path (broker:broker-identity-path (paths bus))))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (with-standard-io-syntax
        (prin1 (list :pid pid :ppid-at-start 4242 :started-at 3900000000
                     :image "/x/dsmr.core")
               out)))))

;;; ------------------------------------------------------------- the archive

(define-test the-service-broker-never-rotates-the-log-when-it-stops
  "A fresh bus served by the service takes a message, and stopping the
   service's broker leaves no archive and the same generation, though no other
   process is a member of the bus."
  (with-host ()
    (let ((bb (start "b1")))
      (true (await (state-is bb :serving)))
      (submit "b1" "first")
      (is = 1 (head "b1"))
      (let ((generation (wal:generation (broker:bus-paths-wal (paths "b1")))))
        (brokers:stop-bus-broker bb)
        (is eq :stopped (brokers:bus-broker-state bb))
        (false (archives "b1") "no archive was written")
        (is = generation (wal:generation (broker:bus-paths-wal (paths "b1"))))
        (is = 1 (head "b1") "the log keeps its record"))
      (true (free-p (broker:bus-paths-members (paths "b1")))
            "no membership is left behind"))))

(define-test a-client-broker-stopping-last-rotates-the-log
  "The control for the case above: a broker started the ordinary way, with no
   extra membership, stopped with archiving asked for, as the last member out
   does rotate the log, so the archive check can see a rotation."
  (with-host ()
    (let* ((p (paths "b2"))
           (br (broker:start-broker p :block nil)))
      (true br)
      (let ((submitter (tz:make-submitter (broker:bus-paths-submit-endpoint p))))
        (unwind-protect
             (progn (tz:send-message submitter "first")
                    (await (lambda () (broker:broker-step br))))
          (tz:close-endpoint submitter)))
      (is = 1 (head "b2"))
      (broker:stop-broker br :archive t)
      (is = 1 (length (archives "b2")) "the log was archived")
      (is = 1 (wal:generation (broker:bus-paths-wal p)) "and its generation moved"))))

;;; ------------------------------------------------------------ the standby

(define-test a-bus-held-by-a-client-broker-is-recorded-as-degraded
  "While another process holds the election, the service's broker waits in
   standby as a member of the bus, the bus is recorded as degraded with the
   incumbent's identity and reported once; ten minutes on with the bus's
   leader registered it is reported once more as an error; and when the
   incumbent lets go the service serves and the record is cleared."
  (with-host ()
    (let* ((p (paths "b3"))
           (sleeper (start-sleeper)))
      (broker:ensure-bus-dirs p)
      (let ((incumbent (hold-lock (broker:bus-paths-lock p))))
        (on-exit (lambda () (ignore-errors (election:close-lock incumbent))))
        (write-incumbent-identity "b3" sleeper)
        (let ((bb (start "b3"))
              (now (get-universal-time)))
          (sleep 0.3)
          (is eq :standby (brokers:bus-broker-state bb))
          (false (free-p (broker:bus-paths-members p))
                 "the service is a member while it waits")
          (check bb now)
          (check bb (+ now 1))
          (is = 1 (length (reports :warn "degraded")) "reported once")
          (multiple-value-bind (record status) (hostfiles:read-degraded-record "b3")
            (is eq :ok status)
            (is eql sleeper (getf record :incumbent-pid))
            (is eql (hostfiles:proc-starttime sleeper) (getf record :incumbent-start))
            (is eql 4242 (getf record :ppid-at-start))
            (is eql 3900000000 (getf record :started-at))
            (is equal "/x/dsmr.core" (getf record :image))
            (is eql now (getf record :detected-at)))
          (let ((snapshot (brokers:bus-broker-snapshot bb (sb-posix:getpid))))
            (is eq :client (getf snapshot :owner))
            (is eql sleeper (getf snapshot :incumbent-pid))
            (is eql now (getf snapshot :degraded-since)))
          (check bb (+ now 601))
          (false (reports :error "still-degraded") "no leader, no escalation")
          (check bb (+ now 601) :leader t)
          (check bb (+ now 700) :leader t)
          (is = 1 (length (reports :error "still-degraded")) "escalated once")
          (election:close-lock incumbent)
          (true (await (state-is bb :serving)) "the service took the role")
          (check bb (+ now 800))
          (is eq :absent (nth-value 1 (hostfiles:read-degraded-record "b3")))
          (is = 1 (count-if (lambda (r) (search "recovered" (third r)))
                            (reports :info "degraded")))
          (is eq :host (getf (brokers:bus-broker-snapshot bb (sb-posix:getpid)) :owner))
          (is eql (sb-posix:getpid)
              (broker:broker-identity-pid (broker:read-broker-identity p))))))))

(define-test a-waiting-broker-stops-when-asked
  "A broker still waiting for the role stops within its bound and leaves no
   lock behind once the incumbent goes."
  (with-host ()
    (let* ((p (paths "b5")))
      (broker:ensure-bus-dirs p)
      (let ((incumbent (hold-lock (broker:bus-paths-lock p)))
            (bb (start "b5")))
        (sleep 0.2)
        (is eq :standby (brokers:bus-broker-state bb))
        (let ((start (get-internal-real-time)))
          (brokers:stop-bus-broker bb :join-seconds 0.5)
          (true (< (- (get-internal-real-time) start)
                   (* 2 internal-time-units-per-second))))
        (false (sb-thread:thread-alive-p (brokers:bus-broker-thread bb)))
        (is eq :stopped (brokers:bus-broker-state bb))
        (election:close-lock incumbent)
        (true (free-p (broker:bus-paths-lock p)) "the election lock is free")
        (true (free-p (broker:bus-paths-members p)) "the membership is let go")))))

;;; ---------------------------------------------------------------- failure

(define-test a-broker-thread-that-dies-is-started-again
  "A serving broker that fails to append ends in :FAILED; the check raises
   BROKER-THREAD-DIED, and its heal brings the broker back to serving."
  (with-host ()
    (let* ((p (paths "b4"))
           (bb (start "b4"))
           (log (uiop:native-namestring (broker:bus-paths-wal p))))
      (true (await (state-is bb :serving)))
      (submit "b4" "first")
      (sb-posix:chmod log #o400)
      (on-exit (lambda () (ignore-errors (sb-posix:chmod log #o600))))
      (send-only "b4" "second")
      (true (await (state-is bb :failed)) "the thread failed")
      (true (brokers:bus-broker-last-error bb))
      (sb-posix:chmod log #o600)
      (check bb (get-universal-time))
      (is = 1 (length (reports :info "broker-thread-died")))
      (true (search "restart-broker-thread" (third (first (reports :info "broker-thread-died")))))
      (true (await (state-is bb :serving)) "serving again")
      (submit "b4" "third")
      (is = 2 (head "b4")))))

(define-test an-unusable-bus-name-is-reported-and-not-served
  "A bus whose name cannot name a bus is reported and nothing is started."
  (with-host ()
    (let ((result (healing (lambda () (start "bad name")))))
      (false (brokers:bus-broker-p result))
      (is = 1 (length (reports :error "bus-root-unusable"))))))

;;; -------------------------------------------------------------- discovery

(define-test discovery-finds-the-buses-in-use
  "The unnamed bus, every bus a registration names, and every bus some process
   is a member of are served; a directory whose name cannot name a bus, and a
   bus nobody is a member of, are not."
  (with-host ()
    (let ((root (broker:default-state-root nil)))
      (flet ((member-of (dir)
               (let* ((path (merge-pathnames "members" (merge-pathnames dir root)))
                      (fd (progn (ensure-directories-exist path)
                                 (election:open-lock path))))
                 (election:lock-shared fd)
                 (on-exit (lambda () (election:close-lock fd))))))
        (member-of "mb/")
        (member-of "Bad Name/")
        (ensure-directories-exist (merge-pathnames "idle/" root))
        (with-open-file (out (merge-pathnames "idle/members" root)
                             :direction :output :if-does-not-exist :create)
          (declare (ignore out)))
        (let ((found (brokers:discover-buses :registered-buses '("rb"))))
          (is equal '(nil "rb" "mb") found))))))
