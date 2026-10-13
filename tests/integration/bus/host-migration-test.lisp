;;;; tests/integration/bus/host-migration-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process tests of moving a running fleet onto the host service, and
;;;; of agents still listening while the service is down.
;;;;
;;;; A host goes over to the service with its agents' detached watchers still
;;;; running and their listeners still waiting. Starting the service takes each
;;;; watcher over with no moment in which a probe reads the agent dead or a
;;;; listener hears that its watcher went, and the log each listener follows
;;;; keeps its inode. A watcher an agent starts later from a binary built before
;;;; the service is taken over at the service's next look. While the service is
;;;; installed but stopped, an agent's bring-up still ends with a watcher of its
;;;; own and a client still elects its own broker; the service, once back, takes
;;;; that watcher over and records the client's broker as the bus's owner.
;;;;
;;;; Every case runs the built bin/dsmr-bus-host and bin/dsmr-bus-watch under its
;;;; own fresh state root under /tmp, with stub desktop notifiers first on PATH
;;;; and no systemd notification socket. A missing binary is a failure here, not
;;;; a skip. Only processes a case started are ever signalled, and the service
;;;; looks for watchers only under its own state root: a watcher of the same
;;;; name under another root is left running.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/host-migration-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/integration/bus/host-migration-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:broker #:dsmr-mcp/src/bus/broker)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-mcp/tests/integration/bus/host-support
                #:watcher-binary
                #:host-binary
                #:run-in
                #:run-in-env
                #:full-id
                #:detach-file
                #:field
                #:alive-p
                #:await-true
                #:with-host-state
                #:with-state-home
                #:start-sleeper
                #:start-service
                #:kill-service
                #:launch-wake
                #:finish-wake
                #:publish
                #:lock-holder
                #:processes-under-state
                #:start-publisher
                #:publisher-lines
                #:elect-client-broker
                #:start-stale-watcher))

(in-package #:dsmr-mcp/tests/integration/bus/host-migration-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *ns* "/dsmr-host-it/move/"
  "The namespace the agents moving onto the service live in.")

(defparameter *client* "/dsmr-host-it/peer/client"
  "The client that writes to them, from a namespace of its own.")

(defparameter *fleet* '(("m" "alpha") ("m" "beta") (nil "gamma"))
  "The running fleet: three agents on two buses, the unnamed one as NIL.")

(defmacro with-binaries (() &body body)
  "Run BODY when both binaries are built. A missing one fails the case: these
   cases are what say a fleet can move onto the service, and without them they
   would prove nothing."
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

(defun check-live (state bus agent)
  "AGENT's --check-live line on BUS under STATE."
  (values (apply #'watch state "--check-live" (args bus agent))))

(defun status-word (line)
  "The first word of a --check-live line."
  (subseq line 0 (or (position #\Space line) (length line))))

(defun host-status (state)
  "What --host-status prints under STATE, and the status it exits with."
  (multiple-value-bind (out err code) (watch state "--host-status")
    (declare (ignore err))
    (values out code)))

(defun installed-p (state)
  "True when the host service is installed under STATE."
  (with-state-home (state) (hostfiles:service-installed-p)))

(defun cmdline (pid)
  "PID's command line, its arguments joined by spaces, or NIL."
  (let ((text (ignore-errors
               (uiop:read-file-string (format nil "/proc/~D/cmdline" pid)
                                      :external-format :latin-1))))
    (and text (substitute #\Space (code-char 0)
                          (string-right-trim (string (code-char 0)) text)))))

(defun detached-child-p (pid)
  "True when PID runs the watcher binary as a detached child."
  (let ((line (cmdline pid)))
    (and line (search "dsmr-bus-watch" line) (search "--detached-child" line) t)))

(defun ino (path)
  "The inode of the file at PATH."
  (sb-posix:stat-ino (sb-posix:stat (uiop:native-namestring path))))

(defun seconds-since (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(defun legacy-detach (state bus agent)
  "Arm AGENT on BUS under STATE with the unchanged --detach line while no
   service is installed there, and return the pid of the watcher it started
   once its probe reads live."
  (multiple-value-bind (out err code)
      (apply #'watch state "--detach" "--poll-ms" "100" (args bus agent))
    (unless (and (eql code 0) (eql 0 (search "detached pid=" out)))
      (error "--detach failed (~A): ~A ~A" code out err))
    (let ((pid (parse-integer (field "pid" out))))
      (unless (await-true (lambda () (eql 0 (search (format nil "live pid=~D " pid)
                                                   (check-live state bus agent))))
                          5)
        (error "the watcher ~D for ~A never read live: ~A"
               pid agent (check-live state bus agent)))
      pid)))

(defun start-samplers (state agents)
  "Start probing every agent in AGENTS, (bus agent) pairs, under STATE with
   --check-live twenty times a second until STOP-SAMPLERS is called.

   One run of the binary takes most of a tenth of a second while several run
   at once, so each agent gets two samplers, the second 50 ms behind the
   first, each keeping to a schedule of ten probes a second so the time a
   probe takes does not lower the rate."
  (let ((stop (vector nil))
        (period (round internal-time-units-per-second 10)))
    (list stop
          (get-internal-real-time)
          (loop for (bus agent) in agents
                collect (let ((bus bus) (agent agent))
                          (cons agent
                                (loop for delay in '(0 0.05)
                                      collect (let ((delay delay))
                                                (sb-thread:make-thread
                                                 (lambda ()
                                                   (sleep delay)
                                                   (loop with next = (get-internal-real-time)
                                                         until (svref stop 0)
                                                         collect (status-word
                                                                  (check-live state bus agent))
                                                         do (incf next period)
                                                            (let ((wait (- next (get-internal-real-time))))
                                                              (when (plusp wait)
                                                                (sleep (/ wait internal-time-units-per-second))))))
                                                 :name (format nil "check-live ~A" agent))))))))))

(defun stop-samplers (samplers)
  "Stop SAMPLERS, from START-SAMPLERS, and return two values: an alist of each
   agent and every status word read for it, and the seconds sampled."
  (destructuring-bind (stop started threads) samplers
    (setf (svref stop 0) t)
    (let ((seconds (seconds-since started)))
      (values (loop for (agent . pair) in threads
                    collect (cons agent (loop for thread in pair
                                              append (sb-thread:join-thread thread))))
              seconds))))

(defun wake-args (bus agent)
  "A background wake for AGENT on BUS, kept armed as an agent keeps one."
  (append (list "--wake" "--poll-ms" "50" "--wake-seconds" "120") (args bus agent)))

(defun detached-children-under (state)
  "The processes under STATE running as a detached watcher, as (pid . cmdline)."
  (remove-if-not (lambda (entry) (search "--detached-child" (cdr entry)))
                 (processes-under-state state)))

;;; ----------------------------------------------------------------- migration

(define-test starting-the-service-adopts-running-watchers-without-a-gap
  "Three agents on two buses, each with a watcher of its own and a background
   wake waiting on it. Starting the service takes all three over: for ten
   seconds from the start no probe of any of them reads dead and no wake gives
   up, every log keeps its inode, the next record reaches every waiting wake,
   and no watcher process is left. A watcher of the same name under another
   state root is not touched."
  (with-binaries ()
    (with-host-state (state)
      (false (installed-p state) "no service is installed before the fleet arms")
      (let* ((legacy (loop for (bus agent) in *fleet*
                           collect (legacy-detach state bus agent)))
             (inodes (loop for (bus agent) in *fleet*
                           collect (ino (detach-file state bus *ns* agent "log"))))
             (wakes (loop for (bus agent) in *fleet*
                          collect (launch-wake state (wake-args bus agent)))))
        (true (every #'detached-child-p legacy) "each agent has a watcher of its own")
        (is = 3 (length (detached-children-under state)))
        (with-host-state (elsewhere)
          (let ((stranger (legacy-detach elsewhere "m" "alpha")))
            (sleep 0.5)
            (true (every #'uiop:process-alive-p wakes) "every wake is armed and waiting")
            (let ((samplers (start-samplers state *fleet*))
                  (svc nil)
                  (samples nil)
                  (sampled 0))
              (unwind-protect
                   (progn
                     (sleep 1)
                     (let ((started (get-internal-real-time)))
                       (setf svc (start-service state))
                       (true (await-true
                              (lambda ()
                                (loop for (bus agent) in *fleet*
                                      always (eql svc (lock-holder state bus *ns* agent))))
                              6)
                             "the service holds every agent's pid file")
                       (loop until (>= (seconds-since started) 10)
                             do (sleep 0.1))))
                (multiple-value-setq (samples sampled) (stop-samplers samplers)))
              (format t "~&;; sampled ~,1Fs: ~{~A~^, ~}~%" sampled
                      (loop for (agent . words) in samples
                            collect (format nil "~A ~D samples ~D dead" agent (length words)
                                            (count "dead" words :test #'string=))))
              (loop for (agent . words) in samples
                    do (true (>= (length words) (* 15 sampled))
                             "only ~D samples of ~A in ~,1Fs" (length words) agent sampled)
                       (false (member "dead" words :test #'string=)
                              "a probe of ~A read no watcher: ~S" agent words)
                       (true (member "live" words :test #'string=)))
              (true (every #'uiop:process-alive-p wakes)
                    "no waiting wake gave up across the adoption")
              (loop for pid in legacy
                    do (true (await-true (lambda () (not (alive-p pid))) 2)
                             "watcher ~D is gone" pid))
              (loop for (bus agent) in *fleet*
                    for inode in inodes
                    do (is eql 0 (search (format nil "live pid=~D " svc)
                                         (check-live state bus agent)))
                       (is = inode (ino (detach-file state bus *ns* agent "log"))
                           "~A's log kept its inode" agent))
              (is equal '() (detached-children-under state)
                  "no watcher process is left under the root")
              (true (alive-p stranger) "the watcher under another root is untouched")
              (is eql stranger (lock-holder elsewhere "m" *ns* "alpha"))
              (loop for (bus agent) in *fleet*
                    do (publish state bus *client* :to (id agent) :text agent))
              (loop for wake in wakes
                    for (nil agent) in *fleet*
                    do (multiple-value-bind (code out err) (finish-wake wake 15)
                         (is eql 0 code "~A's wake returned: ~S ~S" agent out err)
                         (true (eql 0 (search "bus:" out)) "~A's wake printed ~S" agent out)
                         (false (search "nowatcher" out))
                         (false (search "nowatcher" err)))))))))))

(define-test a-stale-binary-watcher-is-adopted
  "A watcher started with the detached child's own command line after the
   service is up, as a binary built before the service starts one, is taken
   over at the service's next look, within five seconds, its probe reading
   live with the service's pid throughout."
  (with-binaries ()
    (with-host-state (state)
      (let* ((svc (start-service state))
             (pid (start-stale-watcher state "m" *ns* "delta"))
             (seen (get-internal-real-time))
             (inode (ino (detach-file state "m" *ns* "delta" "log"))))
        (true (detached-child-p pid) "the watcher runs as a detached child")
        (true (await-true (lambda () (eql svc (lock-holder state "m" *ns* "delta"))) 7)
              "the service holds delta's pid file")
        (let ((elapsed (seconds-since seen)))
          (format t "~&;; stale watcher adopted ~,2Fs after it took its lock~%" elapsed)
          ;; The service looks every five seconds on a whole-second clock, ticking
          ;; four times a second, so the look can come a quarter second past five.
          (true (<= elapsed 5.5) "adopted ~,2Fs after it started watching" elapsed))
        (true (await-true (lambda () (not (alive-p pid))) 2) "the watcher is gone")
        (is eql 0 (search (format nil "live pid=~D " svc) (check-live state "m" "delta")))
        (is = inode (ino (detach-file state "m" *ns* "delta" "log")))
        (is equal '() (detached-children-under state))))))

;;; ------------------------------------------------------------------ fallback

(define-test agents-keep-listening-while-the-service-is-down
  "With the service installed and stopped, an agent's --detach waits its
   bounded time, says it is falling back and leaves the agent a watcher of its
   own, and a client elects its own broker for a new bus and publishes through
   it. The service, started again, takes the watcher over and records the
   client's broker as the owner of that bus."
  (with-binaries ()
    (with-host-state (state)
      (let ((svc (start-service state))
            (session (start-sleeper)))
        (true (installed-p state) "the service is installed")
        (is eql 0 (kill-service state sb-posix:sigterm) "the service stopped in order")
        (false (alive-p svc))
        (true (installed-p state) "a stopped service stays installed")
        (let ((started (get-internal-real-time)))
          (multiple-value-bind (out err code)
              (apply #'run-in-env state (list (format nil "CLAUDE_PID=~D" session))
                     (watcher-binary) "--detach" "--poll-ms" "50" (args "m" "epsilon"))
            (let ((waited (seconds-since started))
                  (legacy (ignore-errors (parse-integer (or (field "pid" out) "")))))
              (format t "~&;; --detach fell back after ~,2Fs~%" waited)
              (is eql 0 code "--detach: ~S ~S" out err)
              (true (eql 0 (search "detached pid=" out)) "--detach printed ~S" out)
              (true (search "starting a watcher of this agent's own" err)
                    "stderr names the fallback: ~S" err)
              (true (>= waited 4.5) "--detach waited for the service first (~,2Fs)" waited)
              (true (integerp legacy))
              (when (integerp legacy)
                (false (eql legacy svc))
                (true (detached-child-p legacy) "the agent's own watcher runs")
                (is eql 0 (search (format nil "live pid=~D " legacy)
                                  (check-live state "m" "epsilon")))
                (multiple-value-bind (answer broker) (elect-client-broker state "c")
                  (is eq :spawned answer "the client elected its own broker")
                  (true (alive-p broker))
                  (start-publisher state "c" *client* 1)
                  (true (await-true (lambda () (member "done" (publisher-lines state)
                                                       :test #'string=))
                                    30)
                        "the client's record reached the log: ~S" (publisher-lines state))
                  (let ((records (with-state-home (state)
                                   (wal:read-records
                                    (broker:bus-paths-wal
                                     (broker:make-bus-paths
                                      (broker:default-state-root "c")))))))
                    (true (find-if (lambda (record)
                                     (search "count=1" (wal:record-body-string record)))
                                   records)
                          "bus c's log holds the client's record"))
                  (let ((svc2 (start-service state))
                        (back (get-internal-real-time)))
                    (true (await-true (lambda ()
                                        (eql svc2 (lock-holder state "m" *ns* "epsilon")))
                                      6)
                          "the returned service holds epsilon's pid file")
                    (format t "~&;; fallback watcher adopted ~,2Fs after the restart~%"
                            (seconds-since back))
                    (true (await-true (lambda () (not (alive-p legacy))) 2)
                          "the agent's own watcher is gone")
                    (is eql 0 (search (format nil "live pid=~D " svc2)
                                      (check-live state "m" "epsilon")))
                    (true (await-true (lambda ()
                                        (search "bus c owner=client" (host-status state)))
                                      7)
                          "--host-status names the client's broker: ~S"
                          (host-status state))
                    (true (alive-p broker) "the client's broker was left serving")
                    (is equal '() (detached-children-under state))))))))))))
