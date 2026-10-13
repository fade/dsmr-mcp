;;;; tests/integration/bus/host-adoption-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process cover for the host service taking over detached watchers
;;;; that were running before it: found only under its own state home, ended
;;;; and replaced with no moment in which a probe or a listener finds the
;;;; agent unwatched, and served on from the same log.
;;;;
;;;; The test image stands in for the service and calls the registry directly.
;;;; The watchers are real `bin/dsmr-bus-watch --detach` children, each under a
;;;; fresh state root of its case's own (see host-support), so the only
;;;; processes ended here are ones a case started. With no built binary (`make
;;;; bus-watch`) the cases skip, and a skip is a failure for the runner this
;;;; file is meant to be run by.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/host-adoption-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/bus/host-adoption-test
  (:use #:cl #:zebra #:dsmr-mcp/tests/integration/bus/host-support)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)
                    (#:registry #:dsmr-bus-host/src/bus/host/registry)
                    (#:ident #:dsmr-bus-host/src/bus/host/identity)
                    (#:fleetlog #:dsmr-bus-host/src/bus/host/fleetlog)
                    (#:envelope #:dsmr-mcp/src/bus/envelope)
                    (#:wal #:dsmr-mcp/src/bus/wal))
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:default-wal-path
                #:%poll-forward
                #:%legacy-detach-stem
                #:%unix-time))

(in-package #:dsmr-mcp/tests/integration/bus/host-adoption-test)

(defparameter *bus* "ha"
  "The bus every case arms on. Short, because the state root has to leave room
   for the bus's socket path under the kernel's limit.")

(defparameter *namespace* "/dsmr-bus-watch-it/adopt/"
  "The namespace every identity here is built under.")

(defparameter *agent* "adoptee"
  "The agent every case watches.")

(defparameter *other* "/ns/other"
  "The agent every published record comes from.")

(defun id-args () (identity-args *bus* *namespace* *agent*))

(defun my-id () (full-id *namespace* *agent*))

(defun my-stem () (stem *bus* *namespace* *agent*))

(defun my-file (state type) (detach-file state *bus* *namespace* *agent* type))

(defmacro with-binary ((bin) &body body)
  "Run BODY with BIN bound to the built watcher, or skip the case when there is
   none. A real branch, so a skip never runs the body."
  `(let ((,bin (watcher-binary)))
     (if (null ,bin)
         (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
         (progn ,@body))))

(defvar *reports* '()
  "Reports COLLECT-REPORT has been handed, newest first, as (level code msg).")

(defun collect-report (level code &key bus id subject msg)
  (declare (ignore bus id subject))
  (push (list level code msg) *reports*))

(defun reports (level code)
  (remove-if-not (lambda (r) (and (eq level (first r)) (string= code (second r))))
                 *reports*))

(defvar *registry* nil
  "The registry the test image serves from in the current case.")

(defmacro as-service ((state) &body body)
  "Run BODY as the service under STATE: XDG_STATE_HOME names it in this
   process, the fleet and service logs are installed inside it, and *REGISTRY*
   is a fresh registry served by this process. Every identity taken is let go
   afterwards."
  `(let ((*registry* (registry:make-registry :service-pid (sb-posix:getpid)))
         (*reports* '()))
     (with-state-home (,state)
       (fleetlog:install-fleet-log
        :path (merge-pathnames "fleet-error.log" ,state)
        :service-log-path (merge-pathnames "service.log" ,state))
       (unwind-protect (progn ,@body)
         (loop for identity being the hash-values of (registry:registry-identities *registry*)
               do (ignore-errors (ident:release-identity identity :remove-files nil)))
         (fleetlog:remove-fleet-log)))))

(defun start-legacy (state bin)
  "Start a detached watcher of this case's identity under STATE, the way an
   agent did before the service existed, and return its pid once its heartbeat
   reads live."
  (multiple-value-bind (out err code)
      (apply #'run-in state bin "--detach" "--poll-ms" "100" (id-args))
    (unless (and (eql code 0) (field "pid" out))
      (error "--detach failed (~A): ~A ~A" code out err))
    (let ((pid (parse-integer (field "pid" out))))
      (await-true (lambda ()
                    (uiop:string-prefix-p "live" (apply #'run-in state bin "--check-live"
                                                        (id-args))))
                  5)
      pid)))

(defun launch-adoption-wake (state bin)
  "Start a background wake for this case's identity under STATE, as an agent
   keeps one armed, and return the process."
  (uiop:launch-program (append (list "env" "-u" "DSMR_BUS_AGENT" "-u" "DSMR_BUS_SELECTOR"
                                     "-u" "CLAUDE_PID")
                               (watcher-env state)
                               (list (uiop:native-namestring bin) "--wake"
                                     "--poll-ms" "50" "--wake-seconds" "60")
                               (id-args))
                       :input nil :output :stream :error-output nil))

(defun ino (path)
  (sb-posix:stat-ino (sb-posix:stat (uiop:native-namestring path))))

(defun locked-by-me-p (path)
  "True when /proc/locks shows this process holding a POSIX write lock on the
   file at PATH. Asking through a descriptor of our own would drop the lock:
   closing any descriptor on a file lets go of this process's locks on it."
  (let ((suffix (format nil ":~D" (ino path)))
        (pid (princ-to-string (sb-posix:getpid))))
    (some (lambda (line)
            (let ((fields (remove "" (uiop:split-string line :separator " ")
                                  :test #'string=)))
              (and (>= (length fields) 6)
                   (string= "POSIX" (second fields))
                   (string= "WRITE" (fourth fields))
                   (string= pid (fifth fields))
                   (uiop:string-suffix-p (sixth fields) suffix))))
          (uiop:read-file-lines "/proc/locks"))))

(defun adopt (state &rest keys)
  "Find this case's watcher under STATE and adopt it, from the test image."
  (let ((legacy (find (my-stem) (registry:find-legacy-watchers)
                      :key (lambda (l) (getf l :stem)) :test #'equal)))
    (unless legacy (error "no watcher found to adopt under ~A" state))
    (apply #'registry:adopt-legacy-watcher *registry* legacy (%unix-time)
           :report-fn #'collect-report keys)))

(defun sample-around (state thunk &key (lead 1.0))
  "Sample --check-live for 3 s at 20 Hz in all, calling THUNK LEAD seconds in;
   return the samples and THUNK's value.

   One run of the binary takes about as long as the pause a sampler leaves
   between runs, so a single sampler only reaches half the rate. Two samplers,
   the second started 50 ms after the first, together take a sample every
   50 ms or so."
  (flet ((sampler (delay)
           (sb-thread:make-thread
            (lambda ()
              (sleep delay)
              (sample-check-live state (id-args) 20 3))
            :name "check-live sampler")))
    (let* ((samplers (list (sampler 0) (sampler 0.05)))
           (value (progn (sleep lead) (funcall thunk))))
      (values (loop for thread in samplers append (sb-thread:join-thread thread))
              value))))

(defun publish-seq (seq)
  "Append record SEQ from *OTHER*, addressed to everyone, to the case's bus."
  (ensure-directories-exist (default-wal-path *bus*))
  (wal:append-record (default-wal-path *bus*) seq
                     (envelope:wrap-envelope "c1" *other* "after the adoption")))

;;; ------------------------------------------------------------------- finding

(define-test legacy-watchers-are-found-only-under-their-own-state-home
  "A watcher whose pid file lies under another state home is never a candidate,
   so a service, or a test, cannot reach another fleet's watchers."
  (with-binary (bin)
    (with-host-state (state)
      (let ((pid (start-legacy state bin)))
        (with-host-state (elsewhere)
          (let ((stranger (start-legacy elsewhere bin)))
            (with-state-home (state)
              (let ((found (registry:find-legacy-watchers)))
                (is = 1 (length found) "found: ~S" found)
                (let ((legacy (first found)))
                  (is eql pid (getf legacy :pid))
                  (is eql (hostfiles:proc-starttime pid) (getf legacy :start))
                  (is equal (my-id) (getf legacy :id))
                  (is equal *bus* (getf legacy :bus))
                  (is equal (my-stem) (getf legacy :stem)))
                (false (find stranger found :key (lambda (l) (getf l :pid))))))
            (true (alive-p stranger))))
        (true (alive-p pid) "finding a watcher does not touch it")))))

;;; ------------------------------------------------------------------ adoption

(define-test adoption-leaves-no-moment-without-a-watcher
  "Taken over with the lock queued first, the identity never reads dead to a
   probe and a waiting listener never hears that its watcher went. The service
   writes on to the same log, which the listener is still following."
  (with-binary (bin)
    (with-host-state (state)
      (let* ((legacy (start-legacy state bin))
             (log-ino (ino (my-file state "log")))
             (wake (launch-adoption-wake state bin)))
        (unwind-protect
             (with-host-state (elsewhere)
               (let ((stranger (start-legacy elsewhere bin)))
                 (sleep 0.5)
                 (true (uiop:process-alive-p wake) "the wake is armed and waiting")
                 (as-service (state)
                   (multiple-value-bind (samples identity)
                       (sample-around state (lambda () (adopt state)))
                     (true (ident:identity-p identity) "adopted: ~S" identity)
                     (true (>= (length samples) 45) "only ~D samples in 3 s" (length samples))
                     (false (member "dead" samples :test #'string=)
                            "a probe saw no watcher: ~S" samples)
                     (true (await-true (lambda () (not (alive-p legacy))) 2)
                           "the legacy watcher is gone")
                     (true (uiop:process-alive-p wake)
                           "the waiting listener did not give up")
                     (true (locked-by-me-p (my-file state "pid"))
                           "this process holds the pid file's lock")
                     (let ((live (apply #'run-in state bin "--check-live" (id-args))))
                       (true (eql 0 (search (format nil "live pid=~D " (sb-posix:getpid))
                                            live))
                             "check-live answered ~S" live))
                     (is = log-ino (ino (my-file state "log")) "the log kept its inode")
                     (multiple-value-bind (plist status)
                         (hostfiles:read-registration
                          (hostfiles:registration-path (my-stem)))
                       (is eq :ok status "a registration was written for it")
                       (is equal (my-id) (getf plist :id))
                       (is equal *bus* (getf plist :bus))
                       (false (getf plist :session-pid)))
                     (is equal (getf (hostfiles:read-registration
                                      (hostfiles:registration-path (my-stem)))
                                     :token)
                         (getf (hostfiles:read-served-ack (my-stem)) :token))
                     (true (alive-p stranger) "a watcher of another state home is untouched")
                     (publish-seq 1)
                     (true (ident:identity-deliver
                            identity
                            (values (%poll-forward (default-wal-path *bus*)
                                                   (wal:make-reader)
                                                   (ident:identity-floor identity)))
                            (%unix-time))
                           "the service wrote a wake line")
                     (let ((code (await-exit wake 10)))
                       (is eql 0 code "the wake returned"))
                     (let ((line (read-line (uiop:process-info-output wake) nil "")))
                       (true (eql 0 (search "bus:1" line)) "the wake printed ~S" line)
                       (false (search "nowatcher" line)))))))
          (when (uiop:process-alive-p wake)
            (ignore-errors (uiop:terminate-process wake))
            (ignore-errors (uiop:wait-process wake))))))))

(define-test terminating-the-watcher-first-leaves-a-moment-without-one
  "The naive takeover, asking the watcher to stop and claiming its files after,
   lets a probe see no watcher at all; this is what queueing for the lock
   first prevents."
  (with-binary (bin)
    (with-host-state (state)
      (start-legacy state bin)
      (as-service (state)
        (multiple-value-bind (samples identity)
            (sample-around state (lambda () (adopt state :method :terminate-then-claim)))
          (true (ident:identity-p identity) "adopted: ~S" identity)
          (true (member "dead" samples :test #'string=)
                "no probe saw the gap: ~S" samples))))))

(defun start-name-only-watcher (state)
  "Start a process that holds the lock on this case's identity's name-only
   stem pid file under STATE, with the command line of a detached watcher, as
   one started by an older build would. Returns its process."
  (let* ((path (merge-pathnames (format nil "dsmr-mcp/watch/~A.pid"
                                        (%legacy-detach-stem *bus* (my-id)))
                                state))
         (form (format nil "(let* ((fd (sb-posix:open ~S (logior sb-posix:o-creat sb-posix:o-rdwr) #o644)) (s (sb-sys:make-fd-stream fd :output t))) (sb-posix:fcntl fd sb-posix:f-setlk (make-instance (quote sb-posix:flock) :type sb-posix:f-wrlck :whence sb-posix:seek-set :start 0 :len 0)) (format s \"~~D~~%~~A~~%\" (sb-posix:getpid) ~S) (finish-output s) (write-line \"locked\") (finish-output) (sleep 120))"
                       (uiop:native-namestring path) (my-id)))
         (process nil))
    (ensure-directories-exist path)
    (setf process (sb-ext:run-program
                   (uiop:native-namestring sb-ext:*runtime-pathname*)
                   (list "--noinform" "--no-sysinit" "--no-userinit" "--non-interactive"
                         "--eval" "(require :sb-posix)" "--eval" form
                         "--end-toplevel-options" "--detached-child"
                         "/older/bin/dsmr-bus-watch" "--bus" *bus*)
                   :input nil :output :stream :error nil :wait nil))
    (let ((line (read-line (sb-ext:process-output process) nil "")))
      (unless (string= line "locked")
        (error "the name-only watcher did not start: ~S" line)))
    process))

(define-test a-watcher-under-a-name-only-stem-is-reported-and-left-running
  "A watcher an older build started under the name-only stem is not taken
   over: its agent moves to the service at its next bring-up. It is reported,
   once."
  (with-host-state (state)
    (let* ((process (start-name-only-watcher state))
           (pid (sb-ext:process-pid process)))
      (unwind-protect
           (as-service (state)
             (let ((outcomes (registry:adopt-legacy-watchers *registry* (%unix-time)
                                                            :report-fn #'collect-report)))
               (is equal '(:left) outcomes)
               (is = 1 (length (reports :warn "legacy-stem-watcher")))
               (true (alive-p pid))
               (registry:adopt-legacy-watchers *registry* (%unix-time)
                                               :report-fn #'collect-report)
               (is = 1 (length (reports :warn "legacy-stem-watcher")) "reported once")
               (true (alive-p pid))
               (is = 0 (hash-table-count (registry:registry-identities *registry*)))))
        (ignore-errors (sb-ext:process-kill process 9))
        (ignore-errors (sb-ext:process-wait process))
        (ignore-errors (sb-ext:process-close process))))))
