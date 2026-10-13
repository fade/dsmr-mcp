;;;; tests/integration/bus/host-ownership-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process tests that the host service owns the buses on its host: one
;;;; process serves every bus and every registered agent, with no watcher
;;;; process beside it, and restarting it rotates no log and loses nothing a
;;;; client submitted meanwhile.
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
                    (#:wal #:dsmr-mcp/src/bus/wal))
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
                #:publisher-lines))

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
