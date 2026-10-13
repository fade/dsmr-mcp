;;;; tests/integration/bus/host-lifecycle-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process tests of the host service binary itself: it starts, beats and
;;;; serves the unnamed bus; a second copy on the same state root refuses to
;;;; start; SIGTERM stops it in order without rotating a log; a crash is
;;;; recorded as an unclean restart on the next start, and only a crash; agents
;;;; on two buses are served by the one process with no watcher beside it; and a
;;;; watchdog's SIGABRT ends it rather than leaving it waiting in the low-level
;;;; monitor.
;;;;
;;;; Every case runs the built bin/dsmr-bus-host under its own fresh state root
;;;; with no systemd notification socket in its environment. A missing binary is
;;;; a failure here, not a skip: these are the cases that say the binary works.
;;;; Only processes a case started are ever signalled.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/host-lifecycle-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/integration/bus/host-lifecycle-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:election #:dsmr-mcp/src/bus/election)
                    (#:tz #:dsmr-mcp/src/bus/zmq)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-mcp/tests/integration/bus/host-support
                #:host-binary
                #:watcher-env
                #:with-host-state
                #:with-state-home
                #:alive-p
                #:await-true
                #:stop-process))

(in-package #:dsmr-mcp/tests/integration/bus/host-lifecycle-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *ns* "/home/x/proj"
  "The namespace every fixture's agents live in.")

(defvar *services* '()
  "The service processes the current case started, newest first.")

(defun launch (state &key (input nil))
  "Start the service binary under STATE with no notification socket, its
   output appended to service.out under STATE, and return the process. INPUT
   is passed to the launch, so a case can hold the service's standard input
   open."
  (let* ((out (with-open-file (stream (merge-pathnames "service.out" state)
                                      :direction :output :if-exists :append
                                      :if-does-not-exist :create)
                (pathname stream)))
         (process (uiop:launch-program
                   (append (list "env" "-u" "NOTIFY_SOCKET" "-u" "DSMR_BUS_AGENT"
                                 "-u" "DSMR_BUS_SELECTOR")
                           (watcher-env state)
                           (list (uiop:native-namestring (host-binary))))
                   :input input
                   :output (uiop:native-namestring out)
                   :if-output-exists :append
                   :error-output :output)))
    (push process *services*)
    process))

(defun pid (process)
  (uiop:process-info-pid process))

(defun await-gone (process seconds)
  "Wait up to SECONDS for PROCESS to exit, and return its exit code, or NIL
   while it is still running."
  (when (await-true (lambda () (not (uiop:process-alive-p process))) seconds)
    (uiop:wait-process process)))

(defun call-with-service-state (thunk)
  "Call THUNK with a fresh state root; on the way out end every service the
   case started that is still running, and collect them all."
  (let ((*services* '()))
    (with-host-state (state)
      (unwind-protect (funcall thunk state)
        (dolist (process *services*)
          (when (uiop:process-alive-p process)
            (ignore-errors (stop-process (pid process))))
          (when (uiop:process-alive-p process)
            (ignore-errors (sb-posix:kill (pid process) sb-posix:sigkill)))
          (ignore-errors (await-gone process 5)))))))

(defmacro with-service-state ((state) &body body)
  `(call-with-service-state (lambda (,state) ,@body)))

(defun id (agent)
  (format nil "~A/~A" *ns* agent))

(defun register (state agent &key bus (token "t1"))
  "Leave a registration for AGENT on BUS under STATE, naming no session, so it
   never lapses."
  (with-state-home (state)
    (hostfiles:write-registration
     (hostfiles:detach-stem bus (id agent))
     (list :id (id agent) :bus bus :poll-ms 250 :recycle-seconds 600
           :deaf-seconds 600 :token token :cli-version "test"))))

(defun summary (state)
  "The service's status summary under STATE, or NIL."
  (with-state-home (state)
    (multiple-value-bind (plist read)
        (hostfiles:read-plist-file (hostfiles:service-status-path) :max-bytes (* 1024 1024))
      (and (eq read :ok) plist))))

(defun bus-owner (state bus)
  "Who the status summary under STATE says owns BUS."
  (getf (find bus (getf (summary state) :buses)
              :key (lambda (entry) (getf entry :bus)) :test #'equal)
        :owner))

(defun await-serving (state process &key (bus nil) (seconds 8))
  "Wait until PROCESS records itself as the service under STATE and the status
   says it owns BUS."
  (await-true (lambda ()
                (and (eql (with-state-home (state) (hostfiles:read-service-pid))
                          (pid process))
                     (eq :host (bus-owner state bus))))
              seconds))

(defun beat-mtime (state)
  "The service beat's modification time under STATE, in seconds."
  (with-state-home (state)
    (sb-posix:stat-mtime (sb-posix:stat (uiop:native-namestring
                                         (hostfiles:service-beat-path))))))

(defun fleet-lines (state code)
  "The fleet log lines under STATE carrying a WARN under CODE."
  (let ((needle (format nil " FLEET WARN code=~A " code)))
    (remove-if-not (lambda (line) (search needle line))
                   (or (ignore-errors
                        (uiop:read-file-lines
                         (merge-pathnames "dsmr-mcp/host/fleet-error.log" state)))
                       '()))))

(defun bus-paths (state bus)
  (with-state-home (state)
    (broker:make-bus-paths (broker:default-state-root bus))))

(defun head (paths)
  (or (ignore-errors (values (wal:scan (broker:bus-paths-wal paths)))) 0))

(defun submit (paths text)
  "Hand TEXT to the broker at PATHS and wait until the log holds one more
   record. The submitter is not a member of the bus."
  (let ((before (head paths))
        (submitter (tz:make-submitter (broker:bus-paths-submit-endpoint paths))))
    (unwind-protect
         (progn (tz:send-message submitter text)
                (await-true (lambda () (> (head paths) before)) 5))
      (sleep 0.05)
      (tz:close-endpoint submitter))))

(defun children-running (parent needle)
  "The pids of PARENT's children whose command line contains NEEDLE."
  (loop for dir in (ignore-errors (uiop:subdirectories "/proc/"))
        for name = (car (last (pathname-directory dir)))
        for child = (and (every #'digit-char-p name) (parse-integer name))
        for ppid = (and child (ignore-errors (hostfiles::%proc-ppid child)))
        for cmdline = (and (eql ppid parent)
                           (ignore-errors
                            (uiop:read-file-string (format nil "/proc/~D/cmdline" child))))
        when (and cmdline (search needle cmdline))
          collect child))

;;; --------------------------------------------------------------------- cases

(define-test the-service-binary-is-built
  "Every case below runs the binary; without it they would prove nothing."
  (true (host-binary) "bin/dsmr-bus-host exists; run make bus-host"))

(define-test the-service-starts-beats-and-serves-the-unnamed-bus
  "Started on a fresh state root, the service records its pid within six
   seconds, keeps its beat moving, and its status says it owns the unnamed
   bus."
  (when (host-binary)
    (with-service-state (state)
      (let ((process (launch state)))
        (true (await-true (lambda ()
                            (eql (with-state-home (state) (hostfiles:read-service-pid))
                                 (pid process)))
                          6))
        (let ((first (beat-mtime state)))
          (sleep 1.5)
          (true (> (beat-mtime state) first) "the beat moved"))
        (true (await-serving state process))
        (is = (pid process) (getf (summary state) :pid))
        (true (alive-p (pid process)))))))

(define-test a-second-copy-refuses-to-start-beside-the-first
  "A second copy on the same state root exits non-zero within five seconds
   and says which lock it found held; the first keeps running."
  (when (host-binary)
    (with-service-state (state)
      (let ((first (launch state)))
        (true (await-serving state first))
        (let* ((second (launch state))
               (code (await-gone second 5)))
          (true code "the second copy exited")
          (true (and code (/= code 0)))
          (true (search "service.lock"
                        (uiop:read-file-string (merge-pathnames "service.out" state)))))
        (true (alive-p (pid first)))
        (is eql (pid first) (with-state-home (state) (hostfiles:read-service-pid)))))))

(define-test sigterm-stops-the-service-in-order-without-rotating-the-log
  "SIGTERM ends the service with status 0 within five seconds. Although it
   was the bus's only member, no archive is written and the generation does
   not move; the log keeps its record; the clean-stop marker is left; and the
   agent it served keeps its pid file and registration."
  (when (host-binary)
    (with-service-state (state)
      (register state "alpha")
      (let* ((process (launch state))
             (paths (bus-paths state nil))
             (stem (hostfiles:detach-stem nil (id "alpha"))))
        (true (await-serving state process))
        (true (submit paths "first"))
        (let ((generation (wal:generation (broker:bus-paths-wal paths)))
              (records (head paths)))
          (true (>= records 1))
          (sb-posix:kill (pid process) sb-posix:sigterm)
          (is eql 0 (await-gone process 5))
          (is equal '() (directory (merge-pathnames "bus.wal.archive-*"
                                                    (broker:bus-paths-root paths))))
          (is = generation (wal:generation (broker:bus-paths-wal paths)))
          (is = records (head paths)))
        (with-state-home (state)
          (true (probe-file (hostfiles:clean-stop-path)))
          (true (probe-file (hostfiles:watch-state-file stem "pid")))
          (true (probe-file (hostfiles:registration-path stem))))
        (let ((fd (election:open-lock (broker:bus-paths-members paths))))
          (unwind-protect
               (true (election:try-lock-exclusive fd) "nobody is a member any more")
            (election:close-lock fd)))))))

(define-test a-crash-and-only-a-crash-is-recorded-as-an-unclean-restart
  "After SIGKILL the next start writes exactly one unclean-restart line to the
   fleet log. After an orderly stop the start that follows writes none."
  (when (host-binary)
    (with-service-state (state)
      (let ((first (launch state)))
        (true (await-serving state first))
        (is = 0 (length (fleet-lines state "unclean-restart")))
        (sb-posix:kill (pid first) sb-posix:sigkill)
        (true (await-gone first 5)))
      (let ((second (launch state)))
        (true (await-serving state second))
        (true (await-true (lambda () (fleet-lines state "unclean-restart")) 3))
        (is = 1 (length (fleet-lines state "unclean-restart")))
        (sb-posix:kill (pid second) sb-posix:sigterm)
        (is eql 0 (await-gone second 5)))
      (let ((third (launch state)))
        (true (await-serving state third))
        (sleep 1)
        (is = 1 (length (fleet-lines state "unclean-restart")))
        (sb-posix:kill (pid third) sb-posix:sigterm)
        (is eql 0 (await-gone third 5))))))

(define-test one-process-serves-agents-on-two-buses
  "Two agents on two buses are both acknowledged by the service itself, both
   buses are served, and the service has no watcher process beside it. The
   child scan is shown to see children by finding the service among this
   process's own."
  (when (host-binary)
    (with-service-state (state)
      (register state "alpha" :bus "ha")
      (register state "beta" :bus "hb")
      (let ((process (launch state)))
        (true (await-serving state process :bus "ha"))
        (true (await-serving state process :bus "hb"))
        (dolist (pair '(("alpha" "ha") ("beta" "hb")))
          (destructuring-bind (agent bus) pair
            (true (await-true
                   (lambda ()
                     (eql (pid process)
                          (getf (with-state-home (state)
                                  (hostfiles:read-served-ack
                                   (hostfiles:detach-stem bus (id agent))))
                                :pid)))
                   5)
                  (format nil "~A on ~A is acknowledged by the service" agent bus))))
        (is = 2 (count :serving (getf (summary state) :registrations)
                       :key (lambda (entry) (getf entry :state))))
        (true (member (pid process) (children-running (sb-posix:getpid) "dsmr-bus-host"))
              "the scan finds the service among this process's children")
        (is equal '() (children-running (pid process) "dsmr-bus-watch"))))))

(define-test the-abort-probe-sees-a-process-parked-in-the-monitor
  "The control on the case below. A plain SBCL, which keeps its low-level
   monitor, answers SIGABRT by waiting in it for a command on the standard
   input this case holds open, and the same probe reports it still running.
   Without this, an exit after SIGABRT could be a probe that cannot tell."
  (let ((process (uiop:launch-program
                  (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                        "--noinform" "--no-sysinit" "--no-userinit"
                        "--eval" "(sleep 30)")
                  :input :stream :output nil :error-output nil)))
    (unwind-protect
         (progn
           (sleep 1)
           (true (alive-p (pid process)))
           (sb-posix:kill (pid process) sb-posix:sigabrt)
           (false (await-gone process 3) "a process in the monitor is still running"))
      (ignore-errors (sb-posix:kill (pid process) sb-posix:sigkill))
      (ignore-errors (close (uiop:process-info-input process)))
      (ignore-errors (await-gone process 5)))))

(define-test a-watchdog-abort-ends-the-service
  "systemd's watchdog ends a wedged service with SIGABRT. The service must
   then exit, not wait in the low-level monitor for a command on its standard
   input, which this case holds open."
  (when (host-binary)
    (with-service-state (state)
      (let ((process (launch state :input :stream)))
        (unwind-protect
             (progn
               (true (await-serving state process))
               (sb-posix:kill (pid process) sb-posix:sigabrt)
               (true (await-gone process 5) "the service exited after SIGABRT"))
          (ignore-errors (close (uiop:process-info-input process))))))))
