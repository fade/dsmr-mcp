;;;; tests/integration/bus/watch-detach-integration-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process tests for the watcher's lifecycle: the detached mode that lets
;;;; an agent launch its watcher once per session, the reap that stops it at park,
;;;; and the two ways a watch that has wedged must still end, on SIGTERM and on
;;;; its own stall watchdog.
;;;;
;;;; These have to run the real binary. Sessions, process groups, record locks and
;;;; a write blocked on a full pipe are all properties of a process, and none of
;;;; them can be shown from inside the test image.
;;;;
;;;; Every case runs under a private XDG_STATE_HOME. The default state directory
;;;; holds the logs, pid files and heartbeats of the watchers the agents on this
;;;; machine are actually listening through, and a reap aimed at the wrong one
;;;; would leave a live agent deaf.
;;;;
;;;; Gated: with no built binary (`make bus-watch`) the cases skip.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/watch-detach-integration-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/integration/bus/watch-detach-integration-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal)))

(in-package #:dsmr-mcp/tests/integration/bus/watch-detach-integration-test)

;;; helpers -------------------------------------------------------------------

(defparameter *bus* "dt"
  "The bus every case arms on. Short, because the state root has to leave room
   for the bus's socket path under the kernel's limit.")

(defparameter *namespace* "/dsmr-bus-watch-it/detach/"
  "The namespace every identity here is built under.")

(defparameter *agent* "detacher"
  "The agent name every case watches for.")

(defun watcher-binary ()
  "The built watcher binary path, or NIL if it has not been built."
  (let ((p (merge-pathnames "bin/dsmr-bus-watch"
                            (asdf:system-source-directory "dsmr-mcp"))))
    (when (probe-file p) p)))

(defun fresh-state-home ()
  "A new, empty state root directly under /tmp. Kept short on purpose: the bus
   refuses a state root whose derived socket path would pass 107 characters."
  (let* ((suffix (let ((*random-state* (make-random-state t)))
                   (format nil "~36R" (random (expt 36 8)))))
         (dir (pathname (format nil "/tmp/dbw-~A/" suffix))))
    (ensure-directories-exist dir)
    dir))

(defun run-in (state bin &rest args)
  "Run BIN with ARGS under the state root STATE, with no ambient bus identity or
   bus selector, and return (values stdout stderr exit-code)."
  (uiop:run-program (append (list "env" "-u" "DSMR_BUS_AGENT" "-u" "DSMR_BUS_SELECTOR"
                                  (format nil "XDG_STATE_HOME=~A"
                                          (uiop:native-namestring state))
                                  (uiop:native-namestring bin))
                            args)
                    :output '(:string :stripped t)
                    :error-output '(:string :stripped t)
                    :ignore-error-status t))

(defun identity-args ()
  (list "--bus" *bus* "--agent" *agent* "--namespace" *namespace*))

(defun detach-file (state type)
  (merge-pathnames (format nil "dsmr-mcp/watch/~A--~A.~A" *bus* *agent* type) state))

(defun field (key line)
  "The value of KEY=... in LINE, or NIL."
  (let ((start (search (concatenate 'string key "=") line)))
    (when start
      (let* ((from (+ start (length key) 1))
             (end (or (position #\Space line :start from) (length line))))
        (subseq line from end)))))

(defun alive-p (pid)
  "True when PID names a process that exists and is not a zombie."
  (and (handler-case (progn (sb-posix:kill pid 0) t)
         (sb-posix:syscall-error () nil))
       (let ((stat (ignore-errors
                    (uiop:read-file-string (format nil "/proc/~D/stat" pid)))))
         (not (and stat
                   (let ((close (position #\) stat :from-end t)))
                     (and close (char= (char stat (+ close 2)) #\Z))))))))

(defun await-exit (process seconds)
  "Wait up to SECONDS for PROCESS to exit. Returns its exit code, or NIL when it
   is still running."
  (loop repeat (* 10 seconds)
        while (uiop:process-alive-p process)
        do (sleep 0.1))
  (unless (uiop:process-alive-p process)
    (uiop:wait-process process)))

(defmacro with-state ((state bin) &body body)
  "Run BODY with STATE bound to a private state root, and on the way out reap
   whatever detached watcher the case left there, SIGKILL anything the reap could
   not stop, and remove the root."
  `(let ((,state (fresh-state-home)))
     (unwind-protect (progn ,@body)
       (ignore-errors (apply #'run-in ,state ,bin "--reap" "--all-buses"
                             (identity-args)))
       (let ((pid (ignore-errors
                   (parse-integer (first (uiop:read-file-lines
                                          (detach-file ,state "pid")))
                                  :junk-allowed t))))
         (when pid (ignore-errors (sb-posix:kill (- pid) sb-posix:sigkill))))
       (ignore-errors (uiop:delete-directory-tree ,state :validate t)))))

(defun launch-wedged-with (bin wal extra)
  "Start BIN streaming on WAL, with the arguments in EXTRA added, so that its
   first wake line blocks for good, and return the process.

   The child's STDOUT is a pipe this test holds and never reads. A shell fills
   that pipe to capacity before it execs the watcher, and WAL already holds a
   record above --after 0, so the watcher's first emit is a write into a full
   pipe. That is the state a watcher is left in when the monitor reading it stops
   draining while something still holds the read end open."
  (uiop:launch-program
   (append (list "sh" "-c"
                 "head -c 65536 /dev/zero; exec \"$0\" \"$@\""
                 (uiop:native-namestring bin)
                 "--stream" "--wal" (uiop:native-namestring wal) "--after" "0"
                 "--poll-ms" "50" "--recycle-seconds" "1")
           extra)
   :output :stream :error-output nil :input nil))

(defun temp-wal-with-a-record ()
  (let ((path (uiop:with-temporary-file (:pathname p :keep t :type "wal"
                                         :prefix "dsmr-bus-watch-wedge-")
                p)))
    (ignore-errors (delete-file path))
    (wal:append-record path 1 "a message nobody will read")
    path))

;;; detach --------------------------------------------------------------------

(define-test detach-starts-one-watcher-and-a-second-detach-starts-none
  "Running --detach again while the watcher is up must report the SAME pid and
   start nothing, since an agent runs it on every bring-up."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (multiple-value-bind (out1 err1 code1)
              (apply #'run-in state bin "--detach" "--poll-ms" "100" (identity-args))
            (is = 0 code1 "first --detach failed: ~A" err1)
            (true (search "detached pid=" out1))
            (true (search "monitor: tail -q -n0 -F " out1))
            (let ((pid (parse-integer (field "pid" out1))))
              (true (alive-p pid))
              (multiple-value-bind (out2 err2 code2)
                  (apply #'run-in state bin "--detach" (identity-args))
                (declare (ignore err2))
                (is = 0 code2)
                (true (search "running pid=" out2))
                (is = pid (parse-integer (field "pid" out2))
                    "a second --detach reported another watcher"))))))))

(define-test a-detached-watcher-runs-in-its-own-session
  "The detached watcher must lead its own session, so that nothing sent to the
   harness session that launched it reaches it."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (let* ((out (apply #'run-in state bin "--detach" (identity-args)))
                 (pid (parse-integer (field "pid" out))))
            (is = pid (sb-posix:getpgid pid) "not the leader of its process group")
            (is = pid (sb-posix:getsid pid) "not the leader of its session"))))))

(define-test check-live-answers-for-a-detached-watcher
  "--check-live reads the heartbeat a detached watcher keeps, and names the bus."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (let* ((out (apply #'run-in state bin "--detach" "--poll-ms" "100"
                             (identity-args)))
                 (pid (field "pid" out)))
            (sleep 0.5)
            (multiple-value-bind (live err code)
                (apply #'run-in state bin "--check-live" (identity-args))
              (declare (ignore err))
              (is = 0 code)
              (true (eql 0 (search (format nil "live pid=~A " pid) live))
                    "expected the detached watcher's pid, got ~S" live)
              (true (search (format nil "bus=~A" *bus*) live))))))))

(define-test a-detached-watcher-writes-its-wakes-to-its-log
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let ((wal (merge-pathnames (format nil "dsmr-mcp/bus/~A/bus.wal" *bus*)
                                      state)))
            (ensure-directories-exist wal)
            (wal:append-record wal 1 "a message from a sister agent")
            (let ((log (detach-file state "log")))
              (true (loop repeat 50
                          thereis (search "bus:1" (or (ignore-errors
                                                       (uiop:read-file-string log))
                                                      ""))
                          do (sleep 0.1))
                    "no wake line reached ~A" log)))))))

;;; reap ----------------------------------------------------------------------

(define-test reap-removes-the-detached-watcher
  "--reap must leave no process behind, no pid file, and a heartbeat probe that
   answers dead."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (let* ((out (apply #'run-in state bin "--detach" "--poll-ms" "100"
                             (identity-args)))
                 (pid (parse-integer (field "pid" out))))
            (true (alive-p pid))
            (multiple-value-bind (reaped err code)
                (apply #'run-in state bin "--reap" (identity-args))
              (declare (ignore err))
              (is = 0 code)
              (true (search (format nil "reaped pid=~D" pid) reaped))
              (true (search "signal=term" reaped)
                    "the watcher needed SIGKILL: ~A" reaped))
            (false (alive-p pid))
            (false (probe-file (detach-file state "pid")))
            (multiple-value-bind (probe err code)
                (apply #'run-in state bin "--check-live" (identity-args))
              (declare (ignore err))
              (is = 1 code)
              (true (search "dead" probe)))
            (multiple-value-bind (again err code)
                (apply #'run-in state bin "--reap" (identity-args))
              (declare (ignore err))
              (is = 0 code)
              (true (search "none" again))))))))

(define-test reap-escalates-to-sigkill-and-takes-the-whole-group
  "A watcher loop that ignores SIGTERM, standing in for the orphan found in the
   field, must still be gone when --reap returns, along with everything else in
   its process group."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (let* ((pid-path (detach-file state "pid"))
                 ;; $0 names the binary so the loop reads as a watcher, which is
                 ;; how a loop started by hand shows up with no lock on its file.
                 (loop-process
                   (uiop:launch-program
                    (list "setsid" "sh" "-c"
                          "trap '' TERM; sleep 600 & while :; do sleep 1; done"
                          "dsmr-bus-watch")
                    :input nil :output nil :error-output nil)))
            (declare (ignore loop-process))
            (sleep 0.5)
            (let ((pid (parse-integer
                        (string-trim '(#\Newline #\Space)
                                     (uiop:run-program
                                      (list "pgrep" "-f" "-n"
                                            "trap '' TERM; sleep 600")
                                      :output :string))
                        :junk-allowed t)))
              (ensure-directories-exist pid-path)
              (with-open-file (out pid-path :direction :output :if-exists :supersede)
                (format out "~D~%" pid))
              (multiple-value-bind (reaped err code)
                  (apply #'run-in state bin "--reap" (identity-args))
                (declare (ignore err))
                (is = 0 code "reap reported a survivor: ~A" reaped)
                (true (search "signal=kill" reaped) "~A" reaped))
              (false (alive-p pid))
              (true (handler-case (progn (sb-posix:kill (- pid) 0) nil)
                      (sb-posix:syscall-error () t))
                    "members of the watcher's process group survived the reap")))))))

;;; wedged watches ------------------------------------------------------------

(define-test sigterm-ends-a-watch-wedged-on-a-full-pipe
  "The field failure: a watcher blocked writing to a pipe nobody drains ignored
   SIGTERM for hours. With the stall watchdog off, SIGTERM alone must end it."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (let* ((wal (temp-wal-with-a-record))
               (p (launch-wedged-with bin wal (list "--stall-seconds" "0"))))
          (unwind-protect
               (progn
                 ;; Wedged: a one-second recycle window has long passed and it
                 ;; is still running.
                 (sleep 2.5)
                 (if (not (uiop:process-alive-p p))
                     (skip ("this pipe did not fill; cannot wedge the watcher here"))
                     (progn
                       (sb-posix:kill (uiop:process-info-pid p) sb-posix:sigterm)
                       (is eql 143 (await-exit p 3)
                           "the wedged watcher did not end on SIGTERM"))))
            (when (uiop:process-alive-p p)
              (ignore-errors (sb-posix:kill (uiop:process-info-pid p)
                                            sb-posix:sigkill)))
            (ignore-errors (delete-file wal)))))))

(define-test the-stall-watchdog-ends-a-wedged-watch
  "Nobody has to signal a wedged watch for it to end: once its poll loop has not
   come round for the stall window, it exits 75."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (let* ((wal (temp-wal-with-a-record))
               (p (launch-wedged-with bin wal (list "--stall-seconds" "1"))))
          (unwind-protect
               (is eql 75 (await-exit p 6)
                   "the wedged watcher outlived its stall window")
            (when (uiop:process-alive-p p)
              (ignore-errors (sb-posix:kill (uiop:process-info-pid p)
                                            sb-posix:sigkill)))
            (ignore-errors (delete-file wal)))))))

;;; waking and readers ---------------------------------------------------------

(defun launch-in (state bin &rest args)
  "Start BIN with ARGS under the state root STATE, as RUN-IN would, and return
   the process without waiting. Its STDOUT is a stream the test reads."
  (uiop:launch-program (append (list "env" "-u" "DSMR_BUS_AGENT" "-u" "DSMR_BUS_SELECTOR"
                                     (format nil "XDG_STATE_HOME=~A"
                                             (uiop:native-namestring state))
                                     (uiop:native-namestring bin))
                               args)
                       :output :stream :error-output nil :input nil))

(defun bus-wal (state bus)
  "The write-ahead log for BUS under the state root STATE, its directory made."
  (let ((wal (merge-pathnames (format nil "dsmr-mcp/bus/~A/bus.wal" bus) state)))
    (ensure-directories-exist wal)
    wal))

(defun await-log-text (log text &optional (seconds 5))
  "True once the file LOG contains TEXT, waiting up to SECONDS."
  (loop repeat (* 10 seconds)
        thereis (search text (or (ignore-errors (uiop:read-file-string log)) ""))
        do (sleep 0.1)))

(defun stop-process (process)
  "SIGKILL PROCESS if it is still running, and reap it."
  (when (uiop:process-alive-p process)
    (ignore-errors (sb-posix:kill (uiop:process-info-pid process) sb-posix:sigkill)))
  (ignore-errors (uiop:wait-process process)))

(defun finish-and-read (process seconds)
  "Wait up to SECONDS for PROCESS to exit, then return (values exit-code
   first-line). The exit code is NIL when it had to be killed. It is stopped
   before its output is read, so a process that never exits cannot hold the
   read, and the suite, open for good."
  (let ((code (await-exit process seconds)))
    (stop-process process)
    (values code (read-line (uiop:process-info-output process) nil ""))))

(define-test wake-exits-at-once-when-no-watcher-runs
  "With no detached watcher there is nothing to wake on, and waiting would leave
   the agent deaf for good; the answer must come straight back, naming the bus."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (multiple-value-bind (out err code)
              (apply #'run-in state bin "--wake" (identity-args))
            (is = 1 code "--wake with no watcher: ~A" err)
            (is string= (format nil "nowatcher bus=~A" *bus*) out))
          (multiple-value-bind (out err code)
              (apply #'run-in state bin "--wake" "--all-buses" (identity-args))
            (declare (ignore err))
            (is = 1 code)
            (is string= "nowatcher bus=*" out))))))

(define-test wake-prints-the-next-wake-line-and-not-an-old-one
  "A wake armed after a line reached the log must return the NEXT line, since
   the agent has already drained the one before it."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let ((wal (bus-wal state *bus*))
                (log (detach-file state "log")))
            (wal:append-record wal 1 "an old message")
            (true (await-log-text log "bus:1") "the first wake never reached the log")
            (let ((wake (apply #'launch-in state bin "--wake" "--poll-ms" "50"
                               (identity-args))))
              (unwind-protect
                   (progn
                     (sleep 0.5)
                     (true (uiop:process-alive-p wake) "--wake returned on an old line")
                     (wal:append-record wal 2 "a new message")
                     (multiple-value-bind (code line) (finish-and-read wake 5)
                       (is eql 0 code "--wake did not return on a new line")
                       (true (eql 0 (search "bus:2" line))
                             "expected the new wake line, got ~S" line)))
                (stop-process wake))))))))

(define-test wake-over-all-buses-returns-from-whichever-bus-speaks
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (let ((who (list "--agent" *agent* "--namespace" *namespace*)))
            (apply #'run-in state bin "--detach" "--poll-ms" "50" "--bus" *bus* who)
            (apply #'run-in state bin "--detach" "--poll-ms" "50" "--bus" "dt2" who)
            (let ((wake (apply #'launch-in state bin "--wake" "--all-buses"
                               "--poll-ms" "50" who)))
              (unwind-protect
                   (progn
                     (sleep 0.5)
                     (wal:append-record (bus-wal state "dt2") 1 "on the second bus")
                     (multiple-value-bind (code line) (finish-and-read wake 5)
                       (is eql 0 code "--wake --all-buses did not return")
                       (true (eql 0 (search "bus:1" line)) "got ~S" line)))
                (stop-process wake))))))))

(define-test a-quiet-wake-ends-idle-and-exits-zero
  "A wake on a silent bus must end on its own with `idle` and exit 0, so the
   agent's background runner sees a completion it re-arms from, never a wait it
   kills at its ceiling."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let ((wake (apply #'launch-in state bin "--wake" "--wake-seconds" "1"
                             "--poll-ms" "50" (identity-args))))
            (unwind-protect
                 (multiple-value-bind (code line) (finish-and-read wake 6)
                   (is eql 0 code "a quiet --wake did not end with exit 0")
                   (is string= "idle wake-seconds=1" line))
              (stop-process wake)))))))

(define-test wake-ends-on-sigterm-and-when-its-watcher-is-reaped
  "A waiting wake must stop when told to, and must not outlive the watcher it
   was following: a wait on a log nothing writes to again never ends."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let ((wake (apply #'launch-in state bin "--wake" "--poll-ms" "50"
                             (identity-args))))
            (unwind-protect
                 (progn
                   (sleep 0.5)
                   (sb-posix:kill (uiop:process-info-pid wake) sb-posix:sigterm)
                   (is eql 143 (await-exit wake 3) "--wake did not end on SIGTERM"))
              (stop-process wake)))
          (let ((wake (apply #'launch-in state bin "--wake" "--poll-ms" "50"
                             (identity-args))))
            (unwind-protect
                 (progn
                   (sleep 0.5)
                   (apply #'run-in state bin "--reap" (identity-args))
                   (multiple-value-bind (code line) (finish-and-read wake 5)
                     (is eql 1 code "--wake kept waiting after its watcher was reaped")
                     (is string= (format nil "nowatcher bus=~A" *bus*) line)))
              (stop-process wake)))))))

(define-test check-live-counts-the-readers-of-the-detached-log
  "`live ... readers=0` is how a leader spots an agent whose watcher is up and
   whose follower is gone, so nobody reading must count 0 and a tail must count."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "100" (identity-args))
          (sleep 0.5)
          (flet ((readers ()
                   (field "readers" (apply #'run-in state bin "--check-live"
                                           (identity-args)))))
            (is equal "0" (readers) "the watcher's own output counted as a reader")
            (let ((tail (uiop:launch-program
                         (list "tail" "-f" (uiop:native-namestring
                                            (detach-file state "log")))
                         :output nil :error-output nil :input nil)))
              (unwind-protect
                   (progn
                     (sleep 0.3)
                     (is equal "1" (readers) "a tail on the log was not counted"))
                (stop-process tail)))
            (is equal "0" (readers) "a reader that has gone was still counted")
            (let ((wake (apply #'launch-in state bin "--wake" (identity-args))))
              (unwind-protect
                   (progn
                     (sleep 0.5)
                     (is equal "1" (readers) "a waiting --wake was not counted"))
                (stop-process wake))))))))
