;;;; tests/integration/bus/host-service-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process tests that an agent's listener cannot tell the host service
;;;; from a detached watcher of its own. The commands every agent already runs
;;;; (--check-live, --wake, --wake --hook, --detach) are run unchanged against
;;;; an identity the real bin/dsmr-bus-host holds, and must answer exactly as
;;;; they do for a watcher: the same probe line, the same wake lines byte for
;;;; byte, the same reminder of mail left unread.
;;;;
;;;; The second half follows a registration through its life: it outlives a
;;;; restart of the service, a session that ends without parking keeps its
;;;; unread-mail alarm, one that ends parked goes quietly, a reap deregisters
;;;; rather than signals, and a service killed outright is heard by every
;;;; listener waiting on it.
;;;;
;;;; In one process a lock can never conflict with its own holder, and the way
;;;; POSIX drops a lock when any descriptor on the file closes cannot show. So
;;;; these run the binaries as separate processes, each case on its own fresh
;;;; state root under /tmp with stub desktop notifiers first on PATH. A missing
;;;; binary is a failure here, not a skip. Only processes a case started are
;;;; ever signalled.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/host-service-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/integration/bus/host-service-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles))
  (:import-from #:dsmr-mcp/tests/integration/bus/host-support
                #:watcher-binary
                #:host-binary
                #:run-in
                #:run-in-env
                #:identity-args
                #:full-id
                #:detach-file
                #:field
                #:alive-p
                #:await-true
                #:with-host-state
                #:with-state-home
                #:start-service
                #:kill-service
                #:start-sleeper
                #:stop-process
                #:notify-calls
                #:launch-wake
                #:finish-wake
                #:publish
                #:publish-batch
                #:write-cursor
                #:lock-holder))

(in-package #:dsmr-mcp/tests/integration/bus/host-service-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *bus* "hs"
  "The bus every case arms on. Short, so the bus's socket paths stay under the
   kernel's limit beneath a state root in /tmp.")

(defparameter *ns* "/dsmr-host-it/svc/"
  "The namespace the agents the service watches live in.")

(defparameter *other* "/dsmr-host-it/peer/teller"
  "The agent that sends them mail, from a namespace of its own.")

(defparameter +hook-input+ "{\"hook_event_name\":\"Stop\"}"
  "What the harness hands a Stop hook on its standard input.")

(defun id (agent)
  "AGENT's full bus id."
  (hostfiles:normalise-agent-id (full-id *ns* agent)))

(defun args (agent)
  "The watcher flags naming AGENT on the case's bus."
  (identity-args *bus* *ns* agent))

(defun watch (state &rest arguments)
  "Run the watcher with ARGUMENTS under STATE; (values stdout stderr code)."
  (apply #'run-in state (watcher-binary) arguments))

(defun check-live (state agent)
  "AGENT's --check-live line under STATE."
  (values (apply #'watch state "--check-live" (args agent))))

(defun live-under-p (state agent pid)
  "True when AGENT's probe under STATE answers live with PID as its watcher."
  (eql 0 (search (format nil "live pid=~D " pid) (check-live state agent))))

(defun service-status (state)
  "The service's status summary under STATE, or NIL."
  (with-state-home (state)
    (multiple-value-bind (plist read)
        (hostfiles:read-plist-file (hostfiles:service-status-path)
                                   :max-bytes (* 1024 1024))
      (and (eq read :ok) plist))))

(defun bus-owner (state)
  "Who the status summary under STATE says owns the case's bus."
  (getf (find *bus* (getf (service-status state) :buses)
              :key (lambda (entry) (getf entry :bus)) :test #'equal)
        :owner))

(defun await-served (state service agent &key (seconds 10))
  "True once the service SERVICE owns the case's bus under STATE and answers
   for AGENT, waiting up to SECONDS. Discovery of a new bus runs every five
   seconds, so a bus first named by a registration takes up to that long."
  (await-true (lambda ()
                (and (eq :host (bus-owner state))
                     (live-under-p state agent service)))
              seconds))

(defun log-lines (state agent)
  "The wake lines in AGENT's log under STATE, in order."
  (remove-if-not (lambda (line) (eql 0 (search "bus:" line)))
                 (or (ignore-errors
                      (uiop:read-file-lines
                       (detach-file state *bus* *ns* agent "log")))
                     '())))

(defun seconds-since (start)
  "Seconds of real time since the internal real time START."
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(defun detach (state agent &rest extra)
  "Arm AGENT under STATE with the unchanged --detach line plus EXTRA flags;
   (values stdout stderr code)."
  (apply #'watch state "--detach" "--poll-ms" "50" (append extra (args agent))))

(defun detach-in-session (state agent session &rest extra)
  "Arm AGENT under STATE as DETACH does, from inside the agent session SESSION,
   a pid the case started; (values stdout stderr code)."
  (apply #'run-in-env state (list (format nil "CLAUDE_PID=~D" session))
         (watcher-binary) "--detach" "--poll-ms" "50" (append extra (args agent))))

(defun registration-state (state agent)
  "The state the status summary under STATE gives AGENT's registration, or NIL
   when it lists none."
  (getf (find (id agent) (getf (service-status state) :registrations)
              :key (lambda (entry) (getf entry :id)) :test #'equal)
        :state))

(defun fleet-lines (state code)
  "The fleet log lines under STATE reporting CODE."
  (let ((needle (format nil " code=~A " code)))
    (remove-if-not (lambda (line) (search needle line))
                   (or (ignore-errors
                        (uiop:read-file-lines
                         (merge-pathnames "dsmr-mcp/host/fleet-error.log" state)))
                       '()))))

(defun registration-file (state agent)
  "AGENT's registration file under STATE."
  (with-state-home (state)
    (hostfiles:registration-path (hostfiles:detach-stem *bus* (id agent)))))

;;; ------------------------------------------------- listeners, unchanged

(define-test the-binaries-are-built
  "Every case below runs both binaries; without them they would prove nothing."
  (true (host-binary) "bin/dsmr-bus-host exists; run make bus-host")
  (true (watcher-binary) "bin/dsmr-bus-watch exists; run make bus-watch"))

(define-test check-live-sees-a-service-held-identity
  "--check-live on an identity the service holds answers live with the
   service's pid. Nothing follows the log, so it counts no readers: the
   service's own write-only descriptor on the log is never one. A background
   --wake following the log counts as one."
  (when (and (host-binary) (watcher-binary))
    (with-host-state (state)
      (let ((service (start-service state)))
        (multiple-value-bind (out err code) (detach state "alpha")
          (is = 0 code "--detach failed: ~A" err)
          (true (eql 0 (search (format nil "detached pid=~D " service) out))
                "--detach did not name the service: ~S" out))
        (true (await-served state service "alpha"))
        (let ((live (check-live state "alpha")))
          (true (eql 0 (search (format nil "live pid=~D " service) live)) "~S" live)
          (true (search (format nil "bus=~A" *bus*) live) "~S" live)
          (is equal "0" (field "readers" live)))
        (let ((wake (launch-wake state (list* "--wake" "--wake-seconds" "30"
                                              "--poll-ms" "50" (args "alpha")))))
          (sleep 0.7)
          (true (uiop:process-alive-p wake))
          (is equal "1" (field "readers" (check-live state "alpha"))
              "a waiting --wake was not counted")
          (finish-wake wake 0))
        (is equal "0" (field "readers" (check-live state "alpha"))
            "a reader that has gone was still counted")))))

(define-test wake-and-hook-hear-a-service-held-identity
  "A background --wake prints the wake line for mail the service delivers and
   exits 0. A Stop hook listener given the hook's input exits 2 with the same
   line on STDERR and nothing on STDOUT."
  (when (and (host-binary) (watcher-binary))
    (with-host-state (state)
      (let ((service (start-service state)))
        (detach state "alpha")
        (true (await-served state service "alpha"))
        (let ((wake (launch-wake state (list* "--wake" "--wake-seconds" "30"
                                              "--poll-ms" "50" (args "alpha")))))
          (sleep 0.7)
          (let ((seq (publish state *bus* *other* :text "for the wake")))
            (multiple-value-bind (code out err) (finish-wake wake 5)
              (is eql 0 code "--wake did not return on the line: ~S" err)
              (true (eql 0 (search (format nil "bus:~D from=" seq) out)) "~S" out)
              (true (search "teller" out) "the sender is not named: ~S" out))))
        (let ((hook (launch-wake state (list* "--wake" "--hook" "--wake-seconds" "30"
                                              "--poll-ms" "50" (args "alpha"))
                                 :hook-input +hook-input+)))
          (sleep 0.7)
          (let ((seq (publish state *bus* *other* :text "for the hook")))
            (multiple-value-bind (code out err) (finish-wake hook 5)
              (is eql 2 code "the hook did not wake the session")
              (is string= "" out)
              (true (eql 0 (search (format nil "bus:~D from=" seq) err)) "~S" err)
              (true (search "bus-receive" err) "no advice to drain the bus: ~S" err))))))))

(define-test service-and-watcher-write-the-same-line
  "For the same records in the same batches, the wake lines a detached watcher
   writes and the ones the service writes are byte-identical: an addressed
   record, then one batch holding the agent's own publish and a broadcast."
  (when (and (host-binary) (watcher-binary))
    (flet ((feed (state)
             (let ((first (publish state *bus* *other* :to (id "alpha")
                                                       :text "for alpha alone")))
               (true (await-true (lambda () (= 1 (length (log-lines state "alpha")))) 5)
                     "no line for the addressed record")
               (let ((last (publish-batch state *bus*
                                          (list (list (id "alpha") :text "my own")
                                                (list *other* :text "for everyone")))))
                 (true (await-true (lambda () (= 2 (length (log-lines state "alpha")))) 5)
                       "no line for the batch")
                 (sleep 0.5)
                 (values first last (log-lines state "alpha"))))))
      (with-host-state (watcher-root)
        (with-host-state (service-root)
          (multiple-value-bind (out err code) (detach watcher-root "alpha")
            (is = 0 code "the watcher's --detach failed: ~A" err)
            (false (with-state-home (watcher-root) (hostfiles:service-installed-p))
                   "the watcher root must have no service")
            (let ((watcher (parse-integer (field "pid" out))))
              (true (search "dsmr-bus-watch"
                            (uiop:read-file-string (format nil "/proc/~D/cmdline"
                                                           watcher))))))
          (let ((service (start-service service-root)))
            (detach service-root "alpha")
            (true (await-served service-root service "alpha")))
          (multiple-value-bind (a-first a-last watcher-lines) (feed watcher-root)
            (multiple-value-bind (b-first b-last service-lines) (feed service-root)
              (is = a-first b-first)
              (is = a-last b-last)
              (is = 2 (length watcher-lines) "~S" watcher-lines)
              (is equal watcher-lines service-lines)
              (true (search " to=" (first service-lines)) "~S" service-lines)
              (true (eql 0 (search (format nil "bus:~D from=" b-last)
                                   (second service-lines)))
                    "~S" service-lines)
              (false (search " to=" (second service-lines)) "~S" service-lines))))))))

(define-test service-announces-unread-mail-again
  "Mail still above the agent's cursor once its --recycle-seconds pass with the
   log quiet is announced again, with the same line, and not before."
  (when (and (host-binary) (watcher-binary))
    (with-host-state (state)
      (write-cursor state *bus* (id "alpha") 0)
      (let ((service (start-service state)))
        (detach state "alpha" "--recycle-seconds" "3")
        (true (await-served state service "alpha"))
        (publish state *bus* *other* :text "nobody reads this")
        (true (await-true (lambda () (log-lines state "alpha")) 5) "no first line")
        (let ((first-seen (get-internal-real-time)))
          (loop until (or (>= (length (log-lines state "alpha")) 2)
                          (> (seconds-since first-seen) 8))
                do (sleep 0.05))
          (let ((gap (seconds-since first-seen))
                (lines (log-lines state "alpha")))
            (is = 2 (length lines) "~S" lines)
            (is equal (first lines) (second lines))
            (true (<= 2.9 gap 6) "announced again after ~,2F s" gap)))))))

(define-test the-service-keeps-the-pid-lock-across-a-full-cycle
  "After the service has run a whole supervisor cycle since the agent
   registered (the registration scan, the census of readers, the status
   snapshot), it still holds the agent's pid-file lock: it never dropped it by
   opening the file again. The probe answers live and a second --detach finds
   the agent already served."
  (when (and (host-binary) (watcher-binary))
    (with-host-state (state)
      (let ((service (start-service state)))
        (detach state "alpha")
        (true (await-served state service "alpha"))
        (let ((registered (get-universal-time)))
          (true (await-true (lambda ()
                              (let ((written (getf (service-status state) :written-at)))
                                (and written (> written (+ registered 5)))))
                            12)
                "no status snapshot a full cycle after the registration"))
        (is eql service (lock-holder state *bus* *ns* "alpha"))
        (true (live-under-p state "alpha" service) "~S" (check-live state "alpha"))
        (multiple-value-bind (out err code) (detach state "alpha")
          (is = 0 code "~A" err)
          (true (eql 0 (search (format nil "running pid=~D " service) out)) "~S" out))))))

;;; ---------------------------------------- registration and its end

(define-test registration-survives-a-service-restart
  "--detach with the service up registers and names the service; again, it
   says the agent is already served. The registration outlives the service:
   stopped and started again, the service answers for the agent within five
   seconds of the new start, with no new --detach."
  (when (and (host-binary) (watcher-binary))
    (with-host-state (state)
      (let ((first (start-service state)))
        (multiple-value-bind (out err code) (detach state "alpha")
          (is = 0 code "~A" err)
          (true (eql 0 (search (format nil "detached pid=~D " first) out)) "~S" out))
        (true (await-served state first "alpha"))
        (multiple-value-bind (out err code) (detach state "alpha")
          (is = 0 code "~A" err)
          (true (eql 0 (search (format nil "running pid=~D " first) out)) "~S" out))
        (is eql 0 (kill-service state sb-posix:sigterm))
        (let* ((launched (get-internal-real-time))
               (second (start-service state)))
          (true (/= first second))
          (true (await-true (lambda () (live-under-p state "alpha" second))
                            (max 0.1 (- 5 (seconds-since launched))))
                "not live under the new service ~,1F s after its start: ~S"
                (seconds-since launched) (check-live state "alpha")))))))

(define-test a-crashed-unparked-session-keeps-its-alarm
  "When the session an agent registered from ends without parking, the
   service lapses the identity within five seconds and writes it no more wake
   lines. Mail that then waits unread still raises the deafness alarm, once
   for the episode: one notification and a marker, however much more arrives."
  (when (and (host-binary) (watcher-binary))
    (with-host-state (state)
      (write-cursor state *bus* (id "alpha") 0)
      (let ((service (start-service state))
            (session (start-sleeper)))
        (multiple-value-bind (out err code)
            (detach-in-session state "alpha" session "--deaf-seconds" "3")
          (is = 0 code "~A" err)
          (true (eql 0 (search (format nil "detached pid=~D " service) out)) "~S" out))
        (true (await-served state service "alpha"))
        (true (stop-process session) "the session did not end")
        (let ((ended (get-internal-real-time)))
          (true (await-true (lambda () (fleet-lines state "session-lapsed")) 5)
                "no lapse reported within 5 s")
          (true (await-true (lambda () (eq :lapsed (registration-state state "alpha")))
                            (max 0.1 (- 7 (seconds-since ended))))
                "the status does not show the lapse: ~S"
                (registration-state state "alpha")))
        (is = 1 (length (fleet-lines state "session-lapsed")))
        (publish state *bus* *other* :text "while the session is gone")
        (true (await-true (lambda ()
                            (and (notify-calls state)
                                 (probe-file (detach-file state *bus* *ns* "alpha" "deaf"))))
                          10)
              "no alarm for mail left unread")
        (sleep 1)
        (is = 1 (length (notify-calls state)) "~S" (notify-calls state))
        (true (search "alpha cannot hear the bus" (first (notify-calls state)))
              "~S" (notify-calls state))
        (is equal '() (log-lines state "alpha") "a wake line was written after the lapse")
        (publish state *bus* *other* :text "more of the same episode")
        (sleep 4)
        (is = 1 (length (notify-calls state)) "the same episode notified again")
        (is equal '() (log-lines state "alpha"))
        (is eq :lapsed (registration-state state "alpha"))))))

(define-test a-parked-session-ending-deregisters-quietly
  "An agent that parked and whose session then ended is deregistered within
   five seconds: its pid file and registration go, its park marker stays, the
   probe answers dead and parked, and nothing is raised, though mail reached
   its log while it was parked."
  (when (and (host-binary) (watcher-binary))
    (with-host-state (state)
      (let ((service (start-service state))
            (session (start-sleeper)))
        (detach-in-session state "alpha" session "--deaf-seconds" "3")
        (true (await-served state service "alpha"))
        (multiple-value-bind (out err code) (apply #'watch state "--park" (args "alpha"))
          (is = 0 code "~A" err)
          (is string= (format nil "parked bus=~A" *bus*) out))
        (let ((seq (publish state *bus* *other* :text "while parked")))
          (true (await-true (lambda () (log-lines state "alpha")) 5))
          (true (eql 0 (search (format nil "bus:~D " seq)
                               (first (log-lines state "alpha"))))))
        (true (stop-process session) "the session did not end")
        (true (await-true (lambda ()
                            (and (not (probe-file (detach-file state *bus* *ns* "alpha" "pid")))
                                 (not (probe-file (registration-file state "alpha")))))
                          5)
              "the parked agent was not deregistered within 5 s")
        (true (probe-file (detach-file state *bus* *ns* "alpha" "parked")))
        (let ((live (check-live state "alpha")))
          (true (eql 0 (search (format nil "dead bus=~A" *bus*) live)) "~S" live)
          (true (search "parked=1" live) "~S" live))
        (sleep 4)
        (is equal '() (notify-calls state))
        (true (alive-p service))))))

(define-test reap-deregisters-from-the-service
  "--reap on an agent the service holds deregisters it instead of signalling:
   it says so, the service keeps running, the agent's pid file goes, and
   another agent on the same service is still served."
  (when (and (host-binary) (watcher-binary))
    (with-host-state (state)
      (let ((service (start-service state)))
        (detach state "alpha")
        (detach state "beta")
        (true (await-served state service "alpha"))
        (true (await-served state service "beta"))
        (multiple-value-bind (out err code)
            (apply #'watch state "--reap" (args "alpha"))
          (is = 0 code "~A" err)
          (is string= (format nil "reaped pid=~D bus=~A signal=deregister" service *bus*)
              out))
        (true (alive-p service) "the reap ended the service")
        (true (await-true (lambda ()
                            (not (probe-file (detach-file state *bus* *ns* "alpha" "pid"))))
                          5)
              "alpha's pid file is still there")
        (true (live-under-p state "beta" service) "~S" (check-live state "beta"))))))

(define-test a-killed-service-is-heard-by-every-listener
  "Losing the service is never silent. Killed outright while one agent waits
   in a background --wake and another in a Stop hook, the wake prints
   nowatcher and exits 1 within three seconds, and the hook wakes its session
   with nowatcher on STDERR. Started again, as systemd would, the service
   answers for every registered agent within five seconds."
  (when (and (host-binary) (watcher-binary))
    (with-host-state (state)
      (let ((service (start-service state)))
        (detach state "alpha")
        (detach state "beta")
        (true (await-served state service "alpha"))
        (true (await-served state service "beta"))
        (let ((wake (launch-wake state (list* "--wake" "--wake-seconds" "30"
                                              "--poll-ms" "50" (args "alpha"))))
              (hook (launch-wake state (list* "--wake" "--hook" "--wake-seconds" "30"
                                              "--poll-ms" "50" (args "beta"))
                                 :hook-input +hook-input+)))
          (sleep 1)
          (true (uiop:process-alive-p wake) "the wake did not wait")
          (true (uiop:process-alive-p hook) "the hook did not wait")
          (true (kill-service state sb-posix:sigkill) "the service outlived SIGKILL")
          (multiple-value-bind (code out err) (finish-wake wake 3)
            (is eql 1 code "the wake did not end: ~S" err)
            (is string= (format nil "nowatcher bus=~A" *bus*) out))
          (multiple-value-bind (code out err) (finish-wake hook 3)
            (is eql 2 code "the hook did not wake its session")
            (is string= "" out)
            (true (eql 0 (search (format nil "nowatcher bus=~A" *bus*) err)) "~S" err)))
        (let* ((launched (get-internal-real-time))
               (again (start-service state)))
          (true (await-true (lambda ()
                              (and (live-under-p state "alpha" again)
                                   (live-under-p state "beta" again)))
                            (max 0.1 (- 5 (seconds-since launched))))
                "not every agent was served again ~,1F s after the restart"
                (seconds-since launched)))))))
