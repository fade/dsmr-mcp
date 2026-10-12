;;;; tests/integration/bus/host-restore-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process cover for `dsmr-bus-watch --host-restore`, which hands a bus
;;;; whose broker a client elected back to the host service.
;;;;
;;;; A file under the state root names the process that gets the signal, so
;;;; most of these cases are about what must NOT be signalled: a live process
;;;; that is not a broker, a real broker whose recorded start time no longer
;;;; matches, and a real broker while no service is alive to take its bus. The
;;;; matching case runs a real broker in a separate process, the way a client
;;;; elects one, against the stand-in service (host-stub.lisp) holding the bus's
;;;; membership lock, and shows the broker's orderly exit leaves the log
;;;; unrotated. The control beside it runs the same restore with the stand-in a
;;;; member of a different bus, and the log does rotate: that is what shows the
;;;; membership lock, not luck or an empty log, kept the first one whole.
;;;;
;;;; Every case runs under its own state root (see host-support), with the bus
;;;; directory inside it. With no built binary (`make bus-watch`) the cases
;;;; skip, and a skip is a failure for the runner this file is meant to be run
;;;; by.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/host-restore-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/integration/bus/host-restore-test
  (:use #:cl #:zebra #:dsmr-mcp/tests/integration/bus/host-support)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:bus #:dsmr-mcp/src/bus/bus)
                    (#:wal #:dsmr-mcp/src/bus/wal)))

(in-package #:dsmr-mcp/tests/integration/bus/host-restore-test)

(defparameter *bus* "hr"
  "The bus every case restores. Short, because the bus directory sits inside
   the state root and its socket paths must stay under the kernel's limit.")

(defparameter *ready-seconds* 120
  "How long a spawned broker may take to come up. A checkout with a prebuilt
   image starts one in well under a second; one without builds the broker from
   source first.")

(defmacro with-binary ((bin) &body body)
  "Run BODY with BIN bound to the built watcher, or skip the case when there is
   none. A real branch, so a skip never runs the body."
  `(let ((,bin (watcher-binary)))
     (if (null ,bin)
         (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
         (progn ,@body))))

(defun bus-root (state)
  "The directory of the case's bus, inside its state root."
  (merge-pathnames (format nil "~A/" *bus*) state))

(defun broker-ready-p (paths pid)
  "True once the broker PID has won the election on the bus at PATHS and bound
   its intake. Read from the identity the broker writes and the socket it
   binds, never by probing the election lock: a probe takes the lock for an
   instant, and a broker started without blocking that loses to the probe
   exits."
  (and (eql pid (broker:broker-identity-pid (broker:read-broker-identity paths)))
       (probe-file (merge-pathnames "submit.ipc" (broker:bus-paths-root paths)))
       t))

(defun reap (process)
  "Make sure PROCESS, which this case started, is gone and waited for. A
   SIGKILL, because a crashed broker never rotates its log."
  (when (uiop:process-alive-p process)
    (ignore-errors (uiop:terminate-process process :urgent t)))
  (ignore-errors (uiop:wait-process process)))

(defmacro with-broker ((paths pid state) &body body)
  "Run BODY with a real broker serving the case's bus in a process of its own,
   as a client starts one. PATHS names the bus and PID the broker."
  (let ((process (gensym "PROCESS")))
    `(let* ((,paths (broker:ensure-bus-dirs (broker:make-bus-paths (bus-root ,state))))
            (,process (broker:spawn-broker ,paths :block nil))
            (,pid (uiop:process-info-pid ,process)))
       (unwind-protect
            (progn
              (unless (await-true (lambda () (broker-ready-p ,paths ,pid))
                                  *ready-seconds*)
                (error "the broker (pid ~D) did not come up within ~Ds; see ~A"
                       ,pid *ready-seconds*
                       (merge-pathnames "broker.log" (broker:bus-paths-root ,paths))))
              ,@body)
         (reap ,process)))))

(defun put-a-record (paths)
  "Publish one message on the bus at PATHS and let go of the bus again, so the
   log has something to rotate and this process holds no membership lock."
  (let ((client (bus:connect-client paths)))
    (unwind-protect
         (progn
           (bus:publish client "restore-me")
           (await-true (lambda () (plusp (wal:scan (broker:bus-paths-wal paths)))) 10))
      (bus:disconnect-client client))))

(defun archive-count (paths)
  (length (directory (merge-pathnames "bus.wal.archive-*"
                                      (broker:bus-paths-root paths)))))

(defun generation (paths)
  (wal:generation (broker:bus-paths-wal paths)))

(defun record-incumbent (state pid root &key (start-offset 0))
  "Record the bus as degraded with PID as its incumbent, the way the service
   does, giving PID's start time moved by START-OFFSET clock ticks."
  (with-state-home (state)
    (hostfiles:write-degraded-record
     *bus*
     (list :bus *bus*
           :root (uiop:native-namestring root)
           :incumbent-pid pid
           :incumbent-start (+ start-offset (hostfiles:proc-starttime pid))
           :ppid-at-start (sb-posix:getpid)
           :started-at (get-universal-time)
           :image "dsmr.core"
           :detected-at (get-universal-time)))))

(defun record-status (state)
  "How the degraded record for the case's bus reads under STATE."
  (with-state-home (state)
    (nth-value 1 (hostfiles:read-degraded-record *bus*))))

(defun restore (state bin &rest more)
  "Run --host-restore for the case's bus under STATE."
  (apply #'run-in state bin "--host-restore" "--bus" *bus* more))

;;; refusals -------------------------------------------------------------------

(define-test restore-refuses-a-process-that-is-not-a-broker
  "A record naming a live process that is not running the broker, with that
process's true start time, is refused and the process is left alone."
  (with-binary (bin)
    (with-host-state (state)
      (start-stub-service state)
      (let ((sleeper (start-sleeper)))
        (record-incumbent state sleeper (bus-root state))
        (multiple-value-bind (out err code) (restore state bin)
          (is = 1 code "stderr: ~A" err)
          (is string= (format nil "refused bus=~A reason=not-a-broker" *bus*) out))
        (true (alive-p sleeper) "the process was not signalled")
        (is eq :ok (record-status state) "the record stays")))))

(define-test restore-refuses-a-recycled-pid
  "A record naming a real broker for the bus with a start time that is not the
broker's is refused: that pid now belongs to a later process."
  (with-binary (bin)
    (with-host-state (state)
      (start-stub-service state)
      (with-broker (paths pid state)
        (record-incumbent state pid (bus-root state) :start-offset 1)
        (multiple-value-bind (out err code) (restore state bin)
          (is = 1 code "stderr: ~A" err)
          (is string= (format nil "refused bus=~A reason=recycled-pid" *bus*) out))
        (true (alive-p pid) "the broker was not signalled")
        (true (broker-ready-p paths pid) "and still serves the bus")))))

(define-test restore-refuses-while-the-service-is-not-alive
  "A correct record is still refused while no service is alive, because there
is nothing to hand the bus to and the client's broker is the only one serving
it."
  (with-binary (bin)
    (with-host-state (state)
      (with-broker (paths pid state)
        (record-incumbent state pid (bus-root state))
        (multiple-value-bind (out err code) (restore state bin)
          (is = 1 code "stderr: ~A" err)
          (is string= (format nil "refused bus=~A reason=service-not-alive" *bus*)
              out))
        (true (alive-p pid) "the broker was not signalled")
        (true (broker-ready-p paths pid) "and still serves the bus")))))

(define-test restore-reports-a-bus-that-is-not-degraded
  "With no degraded record there is nothing to do and nothing is signalled."
  (with-binary (bin)
    (with-host-state (state)
      (multiple-value-bind (out err code) (restore state bin)
        (is = 0 code "stderr: ~A" err)
        (is string= (format nil "clean bus=~A" *bus*) out))
      (multiple-value-bind (out err code)
          (run-in state bin "--host-restore" "--all-buses")
        (is = 0 code "stderr: ~A" err)
        (is string= "clean bus=*" out)))))

(define-test restore-reports-an-incumbent-already-gone
  "A record whose incumbent has already exited needs no signal."
  (with-binary (bin)
    (with-host-state (state)
      (start-stub-service state)
      (let ((sleeper (start-sleeper)))
        (record-incumbent state sleeper (bus-root state))
        (stop-process sleeper)
        (multiple-value-bind (out err code) (restore state bin)
          (is = 0 code "stderr: ~A" err)
          (is string= (format nil "vacated bus=~A incumbent=~D" *bus* sleeper) out))))))

;;; signalling -----------------------------------------------------------------

(define-test restore-hands-the-bus-to-the-service-without-rotating-the-log
  "The recorded broker exits on SIGTERM, the service takes its bus and clears
the record, and because the service is a member of the bus the broker's exit
neither archives the log nor moves its generation."
  (with-binary (bin)
    (with-host-state (state)
      (with-broker (paths pid state)
        (put-a-record paths)
        (true (plusp (wal:scan (broker:bus-paths-wal paths)))
              "the log holds a record, so a rotation would have something to seal")
        (start-stub-service state :hold-members (bus-root state))
        (record-incumbent state pid (bus-root state))
        (let ((archives (archive-count paths))
              (generation (generation paths)))
          (multiple-value-bind (out err code) (restore state bin)
            (is = 0 code "stderr: ~A" err)
            (is string= (format nil "restored bus=~A incumbent=~D signal=term"
                                *bus* pid)
                out))
          (true (await-true (lambda () (not (alive-p pid))) 5) "the broker is gone")
          (is eq :absent (record-status state) "the service cleared the record")
          (is = archives (archive-count paths) "no archive was written")
          (is = generation (generation paths) "the log's generation did not move"))))))

(define-test restore-without-the-membership-lock-rotates-the-log
  "The control for the case above: the same restore, with the stand-in a member
of some other bus, leaves the broker the last member of its own, and its
orderly exit rotates the log."
  (with-binary (bin)
    (with-host-state (state)
      (with-broker (paths pid state)
        (put-a-record paths)
        (start-stub-service state :hold-members (merge-pathnames "elsewhere/" state))
        (record-incumbent state pid (bus-root state))
        (let ((archives (archive-count paths))
              (generation (generation paths)))
          (multiple-value-bind (out err code) (restore state bin)
            (is = 0 code "stderr: ~A" err)
            (is string= (format nil "restored bus=~A incumbent=~D signal=term"
                                *bus* pid)
                out))
          (true (await-true (lambda () (> (archive-count paths) archives)) 10)
                "the last member's exit archived the log")
          (is = (1+ generation) (generation paths) "and moved its generation"))))))

(define-test restore-kills-a-broker-that-ignores-sigterm-and-reports-no-takeover
  "A recorded broker still there 5s after SIGTERM gets SIGKILL. When the service
then does not take the bus within 10s, the restore says so and fails."
  (with-binary (bin)
    (with-host-state (state)
      (start-stub-service state)
      (let* ((root (uiop:native-namestring (bus-root state)))
             ;; A shell that ignores SIGTERM, with the broker's entry point and
             ;; the bus root on its command line.
             (process (uiop:launch-program
                       (list "sh" "-c" "trap '' TERM; while :; do sleep 1; done"
                             "broker-main" root)
                       :input nil :output nil :error-output nil))
             (pid (uiop:process-info-pid process)))
        (unwind-protect
             (progn
               (true (await-true (lambda ()
                                   (search "broker-main"
                                           (format nil "~{~A ~}"
                                                   (hostfiles:proc-cmdline pid))))
                                 5)
                     "the stand-in broker is running")
               (record-incumbent state pid (bus-root state))
               (multiple-value-bind (out err code) (restore state bin)
                 (is = 1 code "stderr: ~A" err)
                 (is string= (format nil "signalled bus=~A incumbent=~D signal=kill service-took=no"
                                     *bus* pid)
                     out))
               (true (await-true (lambda () (not (alive-p pid))) 2)
                     "SIGKILL took it")
               (is eq :ok (record-status state) "the record stays for the service"))
          (reap process))))))
