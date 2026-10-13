;;;; tests/integration/bus/host-ownership-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process tests that the host service owns the buses on its host: one
;;;; process serves every bus and every registered agent, with no watcher
;;;; process beside it, and restarting it rotates no log and loses nothing a
;;;; client submitted meanwhile.
;;;;
;;;; The second half is about order on the bus. A bus a client's broker holds
;;;; is recorded as degraded and handed back by a leader's --host-restore with
;;;; no rotation and no moment in which nobody holds the role; a cursor left
;;;; pointing into a log that is gone is rewritten, said so in the fleet log
;;;; with its old position, and the mail it was hiding wakes the agent, at
;;;; registration and when the cursor is spoiled while the agent is served; and
;;;; the gap between a bus's roster and its registrations is reported, once,
;;;; and gates nobody.
;;;;
;;;; Every case runs the built bin/dsmr-bus-host and bin/dsmr-bus-watch under its
;;;; own fresh state root under /tmp, with stub desktop notifiers first on PATH
;;;; and no systemd notification socket. A missing binary is a failure here, not
;;;; a skip. Only processes a case started are ever signalled.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/host-ownership-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/integration/bus/host-ownership-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:wal #:dsmr-mcp/src/bus/wal)
                    (#:election #:dsmr-mcp/src/bus/election)
                    (#:roster #:dsmr-mcp/src/bus/roster))
  (:import-from #:dsmr-mcp/tests/integration/bus/host-support
                #:watcher-binary
                #:host-binary
                #:run-in
                #:full-id
                #:detach-file
                #:alive-p
                #:await-true
                #:with-host-state
                #:with-state-home
                #:start-service
                #:kill-service
                #:processes-under-state
                #:start-publisher
                #:publisher-lines
                #:publish-batch
                #:write-cursor
                #:start-foreign-broker))

(in-package #:dsmr-mcp/tests/integration/bus/host-ownership-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *ns* "/dsmr-host-it/own/"
  "The namespace the agents the service watches live in.")

(defparameter *client* "/dsmr-host-it/peer/client"
  "The client that publishes to them, from a namespace of its own.")

(defmacro with-binaries (() &body body)
  "Run BODY when both binaries are built. A missing one fails the case: these
   cases are what say the binaries own the bus, and without them they would
   prove nothing."
  `(progn
     (true (host-binary) "bin/dsmr-bus-host exists; run make bus-host")
     (true (watcher-binary) "bin/dsmr-bus-watch exists; run make bus-watch")
     (when (and (host-binary) (watcher-binary))
       ,@body)))

(defun id (agent)
  "AGENT's full bus id."
  (hostfiles:normalise-agent-id (full-id *ns* agent)))

(defun args (bus agent)
  "The watcher flags naming AGENT on BUS, NIL for the unnamed bus."
  (append (and bus (list "--bus" bus))
          (list "--agent" agent "--namespace" *ns*)))

(defun watch (state &rest arguments)
  "Run the watcher with ARGUMENTS under STATE; (values stdout stderr code)."
  (apply #'run-in state (watcher-binary) arguments))

(defun detach (state bus agent)
  "Arm AGENT on BUS under STATE with the unchanged --detach line;
   (values stdout stderr code)."
  (apply #'watch state "--detach" "--poll-ms" "50" (args bus agent)))

(defun check-live (state bus agent)
  "AGENT's --check-live line on BUS under STATE."
  (values (apply #'watch state "--check-live" (args bus agent))))

(defun bus-paths (state bus)
  "The paths of BUS, NIL for the unnamed one, under STATE."
  (with-state-home (state)
    (broker:make-bus-paths (broker:default-state-root bus))))

(defun broker-pid (state bus)
  "The pid BUS's broker identity record under STATE names, or NIL."
  (broker:broker-identity-pid (broker:read-broker-identity (bus-paths state bus))))

(defun archives (paths)
  "The archives of the log at PATHS, by name."
  (sort (mapcar #'file-namestring
                (directory (merge-pathnames "bus.wal.archive-*"
                                            (broker:bus-paths-root paths))))
        #'string<))

(defun generation (paths)
  (wal:generation (broker:bus-paths-wal paths)))

(defun head (paths)
  (or (ignore-errors (values (wal:scan (broker:bus-paths-wal paths)))) 0))

(defun client-counts (paths)
  "The count=N of every record in the log at PATHS from the publishing client,
   in log order."
  (loop for record in (wal:read-records (broker:bus-paths-wal paths))
        for (text nil sid) = (multiple-value-list
                              (envelope:decode-envelope (wal:record-body-string record)))
        when (and sid (string= sid (envelope:encode-id *client*))
                  text (eql 0 (search "count=" text)))
          collect (parse-integer text :start 6)))

(defun sent-count (state)
  "How many records the publishing client under STATE says it has submitted."
  (count-if (lambda (line) (eql 0 (search "sent " line)))
            (publisher-lines state)))

(defun log-lines (state bus agent)
  "The wake lines in AGENT's log on BUS under STATE, in order."
  (remove-if-not (lambda (line) (eql 0 (search "bus:" line)))
                 (or (ignore-errors
                      (uiop:read-file-lines (detach-file state bus *ns* agent "log")))
                     '())))

(defun line-seq (line)
  "The seq the wake line LINE announces, or NIL when there is no line."
  (and line (parse-integer line :start 4 :junk-allowed t)))

(defun seconds-since (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(defun host-status (state)
  "What --host-status prints under STATE, and the status it exits with."
  (multiple-value-bind (out err code) (watch state "--host-status")
    (declare (ignore err))
    (values out code)))

(defun fleet-lines (state level code)
  "The fleet log lines under STATE at LEVEL (\"WARN\", \"INFO\") under CODE."
  (let ((needle (format nil " FLEET ~A code=~A " level code)))
    (remove-if-not (lambda (line) (search needle line))
                   (or (ignore-errors
                        (uiop:read-file-lines
                         (merge-pathnames "dsmr-mcp/host/fleet-error.log" state)))
                       '()))))

(defun cursor-text (state bus agent)
  "AGENT's cursor on BUS under STATE, as written, or NIL when there is none."
  (with-state-home (state)
    (let ((path (merge-pathnames (envelope:encode-id (id agent))
                                 (broker:bus-paths-cursors-dir (bus-paths state bus)))))
      (and (probe-file path)
           (string-trim '(#\Space #\Newline) (uiop:read-file-string path))))))

(defun strand (state agent)
  "Leave the unnamed bus under STATE as a reboot used to: a log at generation
   2 holding three records from another agent, and AGENT's cursor at 372 of
   generation 1, a position in a log that has been rotated away."
  (publish-batch state nil (list (list *client* :text "one")
                                 (list *client* :text "two")
                                 (list *client* :text "three")))
  (let ((path (wal:generation-path (broker:bus-paths-wal (bus-paths state nil)))))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "2" out)))
  (write-cursor state nil (id agent) 372 1))

(defun start-lock-sampler (path hz)
  "Start a thread that, HZ times a second, tries to take the lock at PATH
   without waiting and lets it go at once, counting the tries and the ones
   that found it free. The tries keep to a schedule, so time spent trying does
   not lower the rate. Returns what STOP-LOCK-SAMPLER takes."
  (let* ((box (vector nil 0 0))
         (period (round internal-time-units-per-second hz))
         (thread (sb-thread:make-thread
                  (lambda ()
                    (loop with next = (get-internal-real-time)
                          until (svref box 0)
                          do (let ((fd (election:open-lock path)))
                               (unwind-protect
                                    (when (election:try-lock-exclusive fd)
                                      (incf (svref box 1))
                                      (election:unlock fd))
                                 (election:close-lock fd)))
                             (incf (svref box 2))
                             (incf next period)
                             (let ((wait (- next (get-internal-real-time))))
                               (when (plusp wait)
                                 (sleep (/ wait internal-time-units-per-second))))))
                  :name "broker lock sampler")))
    (cons thread box)))

(defun stop-lock-sampler (sampler)
  "Stop SAMPLER and return how many of its tries found the lock free, and how
   many tries it made."
  (destructuring-bind (thread . box) sampler
    (setf (svref box 0) t)
    (sb-thread:join-thread thread :default nil :timeout 5)
    (values (svref box 1) (svref box 2))))

;;; --------------------------------------------------------------------- cases

(define-test one-service-serves-every-bus
  "Three agents, two on one bus and one on the unnamed bus, are all served by
   the one service: within six seconds both buses' broker identity records name
   it, every agent's probe answers live with its pid, and of the processes
   running under the case's state root exactly one is the service and none is a
   detached watcher."
  (with-binaries ()
    (with-host-state (state)
      (let ((service (start-service state)))
        (dolist (pair '(("a" "alpha") ("a" "beta") (nil "gamma")))
          (destructuring-bind (bus agent) pair
            (multiple-value-bind (out err code) (detach state bus agent)
              (is = 0 code "--detach ~A failed: ~A" agent err)
              (true (eql 0 (search (format nil "detached pid=~D " service) out))
                    "--detach ~A did not name the service: ~S" agent out))))
        (let ((registered (get-internal-real-time)))
          (true (await-true (lambda ()
                              (and (eql service (broker-pid state "a"))
                                   (eql service (broker-pid state nil))))
                            6)
                "the broker records name ~S and ~S, not the service ~D, ~,1F s on"
                (broker-pid state "a") (broker-pid state nil) service
                (seconds-since registered)))
        (dolist (pair '(("a" "alpha") ("a" "beta") (nil "gamma")))
          (destructuring-bind (bus agent) pair
            (true (await-true (lambda ()
                                (eql 0 (search (format nil "live pid=~D " service)
                                               (check-live state bus agent))))
                              5)
                  "~A: ~S" agent (check-live state bus agent))))
        (let* ((under (processes-under-state state))
               (hosts (remove-if-not (lambda (p) (search "dsmr-bus-host" (cdr p))) under))
               (children (remove-if-not (lambda (p) (search "--detached-child" (cdr p)))
                                        under)))
          (is equal (list service) (mapcar #'car hosts) "~S" under)
          (is equal '() children "~S" under))))))

(define-test a-service-restart-rotates-and-loses-nothing
  "A client submits a record every tenth of a second for six seconds while the
   service is stopped with SIGTERM and started again. Afterwards the bus has
   the archives and the generation it had before, the log holds every record
   the client submitted, in order and with none missing, and the agent the
   service watches was told of the last of them."
  (with-binaries ()
    (with-host-state (state)
      (let ((paths (bus-paths state "a"))
            (first (start-service state)))
        (detach state "a" "alpha")
        (true (await-true (lambda () (eql first (broker-pid state "a"))) 8)
              "the service did not take the bus")
        (let ((archives (archives paths))
              (generation (generation paths))
              (publisher (start-publisher state "a" *client* 60))
              (began (get-internal-real-time)))
          (sleep 2)
          (is eql 0 (kill-service state sb-posix:sigterm) "the service did not stop in order")
          (let* ((sent-when-stopped (sent-count state))
                 (second (start-service state))
                 (sent-when-started (sent-count state)))
            (true (/= first second))
            (true (< sent-when-stopped sent-when-started)
                  "nothing was submitted while no service ran (~D, then ~D)"
                  sent-when-stopped sent-when-started)
            (true (await-true (lambda () (eql second (broker-pid state "a"))) 8)
                  "the restarted service did not take the bus")
            (true (await-true (lambda () (member "done" (publisher-lines state)
                                                 :test #'string=))
                              (+ 20 (- 6 (seconds-since began))))
                  "the client's last record never reached the log: ~S"
                  (last (publisher-lines state) 3))
            (ignore-errors (uiop:wait-process publisher))
            (let ((sent (sent-count state)))
              (is = 60 sent "the client sent ~D" sent)
              (is equal (loop for n from 1 to sent collect n) (client-counts paths)
                  "the log does not hold the client's records in order"))
            (format *trace-output* "~&bus a before: archives ~S generation ~D; after: archives ~S generation ~D; submitted ~D before the stop, ~D by the restart~%"
                    archives generation (archives paths) (generation paths)
                    sent-when-stopped sent-when-started)
            (is equal archives (archives paths) "a restart wrote an archive")
            (is = generation (generation paths) "a restart moved the generation")
            (let ((last-seq (head paths)))
              (true (await-true (lambda ()
                                  (eql last-seq (line-seq (car (last (log-lines state "a" "alpha"))))))
                                5)
                    "alpha's last line ~S does not announce the last record, ~D"
                    (car (last (log-lines state "a" "alpha"))) last-seq))
            (true (alive-p second))))))))

(define-test a-leader-restores-a-client-elected-bus
  "Started while a broker a client elected serves a bus, the service records
   the bus degraded and --host-status names the client's broker and exits 1.
   A leader's --host-restore then hands the bus back: it says restored, the
   service owns the bus, no archive is written, the generation stays, and a
   lock sampled fifty times a second across the hand-over is found free at
   most once."
  (with-binaries ()
    (with-host-state (state)
      (let ((paths (bus-paths state "b")))
        (publish-batch state "b" (list (list *client* :text "already here")))
        ;; The sampler's control: with no broker yet, it finds the lock free.
        (let ((control (start-lock-sampler (broker:bus-paths-lock paths) 50)))
          (sleep 0.3)
          (true (plusp (stop-lock-sampler control)) "the sampler cannot see a free lock"))
        (let* ((foreign (start-foreign-broker state "b"))
               (service (start-service state))
               (degraded (format nil "bus b owner=client incumbent=~D " foreign)))
          (true (await-true (lambda () (search degraded (host-status state))) 6)
                "--host-status does not show the client's broker: ~S" (host-status state))
          (multiple-value-bind (out code) (host-status state)
            (is eql 1 code "a degraded bus must make --host-status fail: ~S" out))
          (let ((archives (archives paths))
                (generation (generation paths))
                (sampler (start-lock-sampler (broker:bus-paths-lock paths) 50)))
            (multiple-value-bind (out err code) (watch state "--host-restore" "--bus" "b")
              (is eql 0 code "--host-restore failed: ~A" err)
              (is string= (format nil "restored bus=b incumbent=~D signal=term" foreign) out))
            (true (await-true (lambda () (search "bus b owner=host " (host-status state))) 7)
                  "--host-status does not show the service owning the bus: ~S"
                  (host-status state))
            (multiple-value-bind (free tries) (stop-lock-sampler sampler)
              (format *trace-output* "~&broker lock free in ~D of ~D samples across the hand-over~%"
                      free tries)
              (true (> tries 50) "the sampler hardly ran: ~D tries" tries)
              (true (<= free 1) "the broker lock was free in ~D samples" free))
            (is eql service (broker-pid state "b"))
            (false (alive-p foreign) "the client's broker is still running")
            (is equal archives (archives paths) "the hand-over wrote an archive")
            (is = generation (generation paths) "the hand-over moved the generation")
            (true (plusp (head paths)) "the log kept its record")))))))

(define-test a-stranded-cursor-is-announced-at-registration
  "An agent registering with a cursor stranded in a rotated-away log, while
   the new log already holds mail for it, hears of that mail at once: one wake
   line for the third record within two seconds of --detach. Its cursor is
   rewritten to the start of the current log, and the fleet log carries one
   warning with the position the rewrite discarded."
  (with-binaries ()
    (with-host-state (state)
      (strand state "alpha")
      (let ((service (start-service state)))
        (true (await-true (lambda () (eql service (broker-pid state nil))) 6)
              "the service did not take the unnamed bus")
        ;; Let the service's reader pass the mail first, as it has on a host
        ;; whose agents come back after the service.
        (sleep 1.5)
        (multiple-value-bind (out err code) (detach state nil "alpha")
          (is = 0 code "--detach failed: ~A" err)
          (true (eql 0 (search (format nil "detached pid=~D " service) out)) "~S" out))
        (true (await-true (lambda () (log-lines state nil "alpha")) 2)
              "no wake line within 2 s of registering")
        (sleep 1)
        (let ((lines (log-lines state nil "alpha")))
          (is = 1 (length lines) "~S" lines)
          (true (eql 0 (search "bus:3 " (first lines))) "~S" lines))
        (is equal "0 2" (cursor-text state nil "alpha"))
        (let ((warnings (fleet-lines state "WARN" "stranded-cursor")))
          (is = 1 (length warnings) "~S" warnings)
          (true (search "old-cursor=372" (first warnings)) "~S" warnings))))))

(define-test a-cursor-stranded-while-served-is-healed
  "A served agent's cursor rewritten by another process to a position in a log
   that is gone is healed within two seconds: rewritten to the start of the
   current log, with one more warning in the fleet log naming the position
   it held, and the mail it was hiding announced again."
  (with-binaries ()
    (with-host-state (state)
      (strand state "alpha")
      (let ((service (start-service state)))
        (detach state nil "alpha")
        (true (await-true (lambda () (log-lines state nil "alpha")) 3)
              "no wake line after registering")
        (true (await-true (lambda () (equal "0 2" (cursor-text state nil "alpha"))) 2))
        (is = 1 (length (fleet-lines state "WARN" "stranded-cursor")))
        ;; A new write date on the cursor is what the service looks for, and
        ;; it is kept in whole seconds.
        (sleep 1.1)
        (write-cursor state nil (id "alpha") 500 1)
        (let ((written (get-internal-real-time)))
          (true (await-true (lambda () (equal "0 2" (cursor-text state nil "alpha"))) 2)
                "the cursor still reads ~S ~,1F s after it was spoiled"
                (cursor-text state nil "alpha") (seconds-since written)))
        (true (await-true (lambda () (= 2 (length (fleet-lines state "WARN" "stranded-cursor"))))
                          1)
              "~S" (fleet-lines state "WARN" "stranded-cursor"))
        (let ((warnings (fleet-lines state "WARN" "stranded-cursor")))
          (is = 2 (length warnings) "~S" warnings)
          (true (search "old-cursor=500" (second warnings)) "~S" warnings))
        (true (await-true (lambda () (= 2 (length (log-lines state nil "alpha")))) 2)
              "the mail was not announced again: ~S" (log-lines state nil "alpha"))
        (true (alive-p service))))))

(define-test roster-gaps-are-findings-not-gates
  "With one agent enrolled on the unnamed bus's roster and never registered,
   enrolment closed, and another registered without ever being enrolled,
   --host-status shows both gaps as findings, the unenrolled agent is served
   all the same, and across several status snapshots the fleet log says each
   gap once."
  (with-binaries ()
    (with-host-state (state)
      (let ((paths (bus-paths state nil)))
        (broker:ensure-bus-dirs paths)
        (roster:enroll (id "xray") (broker:bus-paths-roster-dir paths)
                       (broker:bus-paths-roster-state paths))
        (roster:close-enrollment (broker:bus-paths-roster-state paths))
        (let ((service (start-service state))
              (enrolled (format nil "finding kind=enrolled-unregistered bus=default id=~A"
                                (id "xray")))
              (registered (format nil "finding kind=registered-unenrolled bus=default id=~A"
                                  (id "yankee"))))
          (multiple-value-bind (out err code) (detach state nil "yankee")
            (is = 0 code "--detach failed: ~A" err)
            (true (eql 0 (search (format nil "detached pid=~D " service) out)) "~S" out))
          (true (await-true (lambda ()
                              (let ((status (host-status state)))
                                (and (search enrolled status) (search registered status))))
                            7)
                "~S" (host-status state))
          (true (eql 0 (search (format nil "live pid=~D " service)
                               (check-live state nil "yankee")))
                "~S" (check-live state nil "yankee"))
          (sleep 15)
          (flet ((gap-lines (agent)
                   (remove-if-not (lambda (line)
                                    (search (format nil " id=~A " (id agent)) line))
                                  (fleet-lines state "INFO" "roster-gap"))))
            (is = 1 (length (gap-lines "xray")) "~S" (gap-lines "xray"))
            (is = 1 (length (gap-lines "yankee")) "~S" (gap-lines "yankee")))
          (let ((status (host-status state)))
            (true (search enrolled status) "~S" status)
            (true (search registered status) "~S" status))
          (true (eql 0 (search (format nil "live pid=~D " service)
                               (check-live state nil "yankee")))))))))
