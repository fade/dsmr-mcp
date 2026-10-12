;;;; tests/integration/bus/host-cli-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process cover for the watcher binary's side of the host bus service:
;;;; --detach registering an agent with the service, and falling back to a
;;;; watcher of its own when the service is installed and silent; --reap
;;;; deregistering instead of signalling the service; and --host-status, the
;;;; report a leader reads.
;;;;
;;;; These run the real binary against a stand-in service (host-stub.lisp), a
;;;; second process that beats, acknowledges registrations and holds the
;;;; per-identity locks the way the service does. Locks, process groups and
;;;; signals are properties of processes, and none of them can be shown from
;;;; inside the test image.
;;;;
;;;; Every case runs under its own state root (see host-support). With no built
;;;; binary (`make bus-watch`) the cases skip, and a skip is a failure for the
;;;; runner this file is meant to be run by.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/host-cli-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/bus/host-cli-test
  (:use #:cl #:zebra #:dsmr-mcp/tests/integration/bus/host-support)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles))
  ;; The lock probe the watcher itself uses, so a case reads the holder exactly
  ;; as --reap and --detach do.
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%lock-holder))

(in-package #:dsmr-mcp/tests/integration/bus/host-cli-test)

(defparameter *bus* "hc"
  "The bus every case arms on. Short, because the state root has to leave room
   for the bus's socket path under the kernel's limit.")

(defparameter *namespace* "/dsmr-bus-watch-it/host/"
  "The namespace every identity here is built under.")

(defparameter *agent* "hoster"
  "The agent name every case registers.")

(defun id-args ()
  (identity-args *bus* *namespace* *agent*))

(defun my-stem ()
  (stem *bus* *namespace* *agent*))

(defun my-file (state type)
  (detach-file state *bus* *namespace* *agent* type))

(defun registration-of (state)
  "The registration plist for this case's identity under STATE, and its read
   status."
  (with-state-home (state)
    (hostfiles:read-registration (hostfiles:registration-path (my-stem)))))

(defun registration-files (state)
  "Every registration file under STATE."
  (remove "reg" (ignore-errors
                 (uiop:directory-files
                  (merge-pathnames "dsmr-mcp/host/register/" state)))
          :key #'pathname-type :test-not #'equal))

(defun seconds-since (start)
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(defmacro with-binary ((bin) &body body)
  "Run BODY with BIN bound to the built watcher, or skip the case when there is
   none. A real branch, so a skip never runs the body."
  `(let ((,bin (watcher-binary)))
     (if (null ,bin)
         (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
         (progn ,@body))))

(defun first-line (text)
  (subseq text 0 (or (position #\Newline text) (length text))))

;;; --detach -------------------------------------------------------------------

(define-test detach-without-a-service-writes-no-registration
  "On a host with no service installed, --detach starts a watcher of its own
exactly as before and leaves nothing for a service to find."
  (with-binary (bin)
    (with-host-state (state)
      (multiple-value-bind (out err code)
          (apply #'run-in state bin "--detach" "--poll-ms" "100" (id-args))
        (is = 0 code "--detach failed: ~A" err)
        (true (uiop:string-prefix-p "detached pid=" out) "got ~S" out)
        (is string= (uiop:native-namestring (my-file state "log"))
            (field "log" (first-line out)))
        (true (search (format nil "~%monitor: tail -q -n0 -F ") out))
        (let ((pid (parse-integer (field "pid" out))))
          (true (alive-p pid) "the watcher it reported is running"))
        (is equal '() (registration-files state)
            "no registration was written")))))

(define-test detach-registers-with-a-live-service
  "With the service up, --detach registers the agent, waits for the service to
serve it, and reports the service's pid in the same two lines as before."
  (with-binary (bin)
    (with-host-state (state)
      (let* ((service (start-stub-service state))
             (session (start-sleeper))
             (started (get-internal-real-time)))
        (multiple-value-bind (out err code)
            (apply #'run-in-env state
                   (list (format nil "CLAUDE_PID=~D" session))
                   bin "--detach" "--poll-ms" "100" "--recycle-seconds" "300"
                   "--deaf-seconds" "120" (id-args))
          (is = 0 code "--detach failed: ~A" err)
          (true (< (seconds-since started) 10) "it answered within 10s")
          (true (uiop:string-prefix-p "detached pid=" out) "got ~S" out)
          (is = service (parse-integer (field "pid" out))
              "the pid reported is the service's")
          (is string= *bus* (field "bus" out))
          (is string= (uiop:native-namestring (my-file state "log"))
              (field "log" (first-line out)))
          (true (search (format nil "~%monitor: tail -q -n0 -F ") out)))
        (multiple-value-bind (reg status) (registration-of state)
          (is eq :ok status)
          (dolist (key '(:id :bus :poll-ms :recycle-seconds :deaf-seconds
                         :session-pid :session-start :token :registered-at))
            (true (getf reg key) "the registration carries ~S" key))
          (is string= (full-id *namespace* *agent*) (getf reg :id))
          (is string= *bus* (getf reg :bus))
          (is = 100 (getf reg :poll-ms))
          (is = 300 (getf reg :recycle-seconds))
          (is = 120 (getf reg :deaf-seconds))
          (is = session (getf reg :session-pid) "the session is CLAUDE_PID")
          (is = (hostfiles:proc-starttime session) (getf reg :session-start)
              "with that process's start time")
          (is = 16 (length (getf reg :token))))))))

(define-test detach-twice-reports-running
  "A second --detach while the service already serves the identity reports it
running and refreshes the registration's session."
  (with-binary (bin)
    (with-host-state (state)
      (let ((service (start-stub-service state))
            (first-session (start-sleeper))
            (second-session (start-sleeper)))
        (multiple-value-bind (out err code)
            (apply #'run-in-env state
                   (list (format nil "CLAUDE_PID=~D" first-session))
                   bin "--detach" (id-args))
          (is = 0 code "first --detach failed: ~A" err)
          (true (uiop:string-prefix-p "detached pid=" out) "got ~S" out))
        (let ((first-token (getf (registration-of state) :token)))
          (multiple-value-bind (out err code)
              (apply #'run-in-env state
                     (list (format nil "CLAUDE_PID=~D" second-session))
                     bin "--detach" (id-args))
            (is = 0 code "second --detach failed: ~A" err)
            (true (uiop:string-prefix-p "running pid=" out) "got ~S" out)
            (is = service (parse-integer (field "pid" out))))
          (let ((reg (registration-of state)))
            (is = second-session (getf reg :session-pid)
                "the registration names the newer session")
            (is = (hostfiles:proc-starttime second-session)
                (getf reg :session-start))
            (false (equal first-token (getf reg :token))
                   "and carries a new token")))))))

(define-test detach-falls-back-when-the-service-is-down
  "With the service installed and not beating, --detach waits a bounded time,
says why on STDERR and starts a watcher of its own, leaving the registration
for the service to find when it returns."
  (with-binary (bin)
    (with-host-state (state)
      (with-state-home (state)
        (hostfiles:ensure-host-dir)
        (hostfiles:write-plist-file (hostfiles:service-state-path)
                                    (list :installed t)))
      (let ((started (get-internal-real-time)))
        (multiple-value-bind (out err code)
            (apply #'run-in state bin "--detach" "--poll-ms" "100" (id-args))
          (let ((elapsed (seconds-since started)))
            (is = 0 code "--detach failed: ~A" err)
            (true (<= 5 elapsed 16) "it waited a bounded time (~,1Fs)" elapsed))
          (true (uiop:string-prefix-p "detached pid=" out) "got ~S" out)
          (true (search "host service" err) "stderr says why: ~S" err)
          (let ((pid (parse-integer (field "pid" out))))
            (true (alive-p pid) "a watcher of its own is running"))
          (is eq :ok (nth-value 1 (registration-of state))
              "the registration stays for the returning service"))))))

;;; --reap ---------------------------------------------------------------------

(defun register-by-hand (state)
  "Leave a registration for this case's identity under STATE without running
   --detach, for a stand-in that never acknowledges with the lock it holds."
  (with-state-home (state)
    (hostfiles:write-registration
     (my-stem)
     (list :id (full-id *namespace* *agent*) :bus *bus* :poll-ms 1000
           :recycle-seconds 600 :deaf-seconds 600 :session-pid nil
           :session-start nil :token "0000000000000000" :registered-at 0))))

(define-test reap-deregisters-instead-of-signalling-the-service
  "Reaping an identity the service watches removes its registration and leaves
the service running: it holds every identity's lock, and signalling it would
leave every agent on the host deaf."
  (with-binary (bin)
    (with-host-state (state)
      (let ((service (start-stub-service state)))
        (multiple-value-bind (out err code)
            (apply #'run-in state bin "--detach" (id-args))
          (declare (ignore out))
          (is = 0 code "--detach failed: ~A" err))
        (is = service (%lock-holder (my-file state "pid"))
            "the service holds the identity's lock before the reap")
        (multiple-value-bind (out err code)
            (apply #'run-in state bin "--reap" (id-args))
          (is = 0 code "--reap failed: ~A" err)
          (is string= (format nil "reaped pid=~D bus=~A signal=deregister"
                              service *bus*)
              out))
        (is eq :absent (nth-value 1 (registration-of state))
            "the registration is gone")
        (false (eql service (%lock-holder (my-file state "pid")))
               "the service let go of the identity")
        (true (alive-p service) "and the service is still running")))))

(define-test reap-signals-a-holder-the-service-pid-does-not-name
  "The guard keys on the service's own pid. With service.pid naming some other
process, the holder is an ordinary watcher to --reap and is stopped the old
way, which is what shows the guard, not luck, spared the service above."
  (with-binary (bin)
    (with-host-state (state)
      (let ((service (start-stub-service state))
            (other (start-sleeper)))
        (multiple-value-bind (out err code)
            (apply #'run-in state bin "--detach" (id-args))
          (declare (ignore out))
          (is = 0 code "--detach failed: ~A" err))
        (with-state-home (state)
          (with-open-file (o (hostfiles:service-pid-path) :direction :output
                                                          :if-exists :supersede)
            (format o "~D~%" other)))
        (multiple-value-bind (out err code)
            (apply #'run-in state bin "--reap" (id-args))
          (is = 0 code "--reap failed: ~A" err)
          (is string= (format nil "reaped pid=~D bus=~A signal=term" service *bus*)
              out))
        (true (await-true (lambda () (not (alive-p service))) 5)
              "the stand-in took the signal and exited")))))

(define-test reap-never-signals-the-service-s-process-group
  "A lock holder in the service's process group is never signalled, even when
it is not the service itself, because signalling a group the service leads
reaches the service."
  (with-binary (bin)
    (with-host-state (state)
      (let ((service (start-stub-service state :role "lock-in-child")))
        (register-by-hand state)
        (let ((holder (await-true
                       (lambda ()
                         (let ((pid (%lock-holder (my-file state "pid"))))
                           (and pid (/= pid service) pid)))
                       30)))
          (true holder "a child of the service holds the identity's lock")
          (when holder
            (is = service (sb-posix:getpgid holder)
                "in the service's process group")
            (multiple-value-bind (out err code)
                (apply #'run-in state bin "--reap" (id-args))
              (declare (ignore err))
              (is = 1 code)
              (is string= (format nil "survived pid=~D bus=~A" holder *bus*) out))
            (true (alive-p holder) "the holder is still running")
            (true (alive-p service) "and so is the service")))))))
