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
  (:local-nicknames (#:wal #:dsmr-mcp/src/bus/wal))
  ;; The file names come from the watcher's own stem functions, so these cases
  ;; look where the binary writes and can never drift from it.
  (:import-from #:dsmr-bus-watch/src/bus/watch
                #:%detach-stem
                #:%legacy-detach-stem))

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

(defun stub-dir (state)
  "The directory under the state root STATE holding the stub notify-send."
  (merge-pathnames "stub-bin/" state))

(defun notify-calls-file (state)
  "The file the stub notify-send under STATE appends each call to."
  (merge-pathnames "notify-calls" state))

(defun install-notify-stub (state)
  "Write a stub notify-send into STATE's stub directory that appends its
   arguments, one call per line, to the calls file and does nothing else.

   Every watcher these cases start finds the stub first on its PATH, so no case
   can put a real notification on the developer's desktop."
  (let ((stub (merge-pathnames "notify-send" (stub-dir state))))
    (ensure-directories-exist stub)
    (with-open-file (out stub :direction :output :if-exists :supersede)
      (format out "#!/bin/sh~%printf '%s\\n' \"$*\" >> '~A'~%"
              (uiop:native-namestring (notify-calls-file state))))
    (sb-posix:chmod (uiop:native-namestring stub) #o755)
    stub))

(defun notify-calls (state)
  "Every call the stub notify-send under STATE has received, one string each."
  (or (ignore-errors (uiop:read-file-lines (notify-calls-file state))) '()))

(defvar *watcher-path* nil
  "When set, the whole PATH a watcher is run with. When NIL, the stub directory
   under the case's state root is put in front of the inherited PATH.")

(defun watcher-env (state)
  "The environment assignments a watcher under STATE runs with: the private
   state root, and a PATH that finds the stub notify-send first."
  (list (format nil "XDG_STATE_HOME=~A" (uiop:native-namestring state))
        (format nil "PATH=~A"
                (or *watcher-path*
                    (format nil "~A:~A"
                            (string-right-trim "/" (uiop:native-namestring
                                                    (stub-dir state)))
                            (or (uiop:getenv "PATH") ""))))))

(defun fresh-state-home ()
  "A new, empty state root directly under /tmp, holding a stub notify-send.
   Kept short on purpose: the bus refuses a state root whose derived socket path
   would pass 107 characters."
  (let* ((suffix (let ((*random-state* (make-random-state t)))
                   (format nil "~36R" (random (expt 36 8)))))
         (dir (pathname (format nil "/tmp/dbw-~A/" suffix))))
    (ensure-directories-exist dir)
    (install-notify-stub dir)
    dir))

(defun run-in (state bin &rest args)
  "Run BIN with ARGS under the state root STATE, with no ambient bus identity or
   bus selector and the stub notify-send first on PATH, and return (values
   stdout stderr exit-code)."
  (uiop:run-program (append (list "env" "-u" "DSMR_BUS_AGENT" "-u" "DSMR_BUS_SELECTOR")
                            (watcher-env state)
                            (list (uiop:native-namestring bin))
                            args)
                    :output '(:string :stripped t)
                    :error-output '(:string :stripped t)
                    :ignore-error-status t))

(defun identity-args ()
  (list "--bus" *bus* "--agent" *agent* "--namespace" *namespace*))

(defun full-id (&optional (namespace *namespace*) (agent *agent*))
  "The full bus id of AGENT under NAMESPACE, joined with one separator."
  (format nil "~A/~A" (string-right-trim "/" namespace) agent))

(defun detach-file (state type &key (namespace *namespace*) (agent *agent*) legacy)
  "The detached watcher's file of TYPE for AGENT under NAMESPACE on *BUS*, under
   the state root STATE. With LEGACY, the file under the older name-only stem."
  (merge-pathnames (format nil "dsmr-mcp/watch/~A.~A"
                           (funcall (if legacy #'%legacy-detach-stem #'%detach-stem)
                                    *bus* (full-id namespace agent))
                           type)
                   state))

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
  (uiop:launch-program (append (list "env" "-u" "DSMR_BUS_AGENT" "-u" "DSMR_BUS_SELECTOR")
                               (watcher-env state)
                               (list (uiop:native-namestring bin))
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

(define-test same-name-in-two-namespaces-keeps-separate-logs-and-readers
  "Two agents of one name in different namespaces are two agents: each gets its
   own watcher and log, and a reader of one is never counted for the other."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (let ((ns-a "/tmp/ns-a/")
                (ns-b "/tmp/ns-b/")
                (name "x"))
            (flet ((who (ns)
                     (list "--bus" *bus* "--agent" name "--namespace" ns))
                   (log-of (ns)
                     (detach-file state "log" :namespace ns :agent name)))
              (flet ((readers (ns)
                       (field "readers" (apply #'run-in state bin "--check-live"
                                               (who ns)))))
                (unwind-protect
                     (progn
                       (dolist (ns (list ns-a ns-b))
                         (multiple-value-bind (out err code)
                             (apply #'run-in state bin "--detach" "--poll-ms" "100"
                                    (who ns))
                           (is = 0 code "--detach for ~A failed: ~A ~A" ns out err)))
                       (sleep 0.5)
                       (false (equal (log-of ns-a) (log-of ns-b)))
                       (true (probe-file (log-of ns-a)))
                       (true (probe-file (log-of ns-b)))
                       (let ((tail (uiop:launch-program
                                    (list "tail" "-f"
                                          (uiop:native-namestring (log-of ns-a)))
                                    :output nil :error-output nil :input nil)))
                         (unwind-protect
                              (progn
                                (sleep 0.3)
                                (is equal "1" (readers ns-a)
                                    "the tail on ns-a's log was not counted")
                                (is equal "0" (readers ns-b)
                                    "ns-a's reader was counted for ns-b"))
                           (stop-process tail))))
                  (dolist (ns (list ns-a ns-b))
                    (ignore-errors (apply #'run-in state bin "--reap" (who ns))))))))))))

(define-test check-live-accepts-a-doubled-separator
  "A doubled separator names the same agent, so a healthy agent probed with one
   must read live, not dead."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "100" (identity-args))
          (sleep 0.5)
          (dolist (who (list (list "--agent-id"
                                   (format nil "~A/~A" *namespace* *agent*))
                             (list "--agent" *agent*
                                   "--namespace" (format nil "~A/" *namespace*))))
            (multiple-value-bind (live err code)
                (apply #'run-in state bin "--check-live" "--bus" *bus* who)
              (declare (ignore err))
              (is = 0 code "~S read ~S" who live)
              (true (eql 0 (search "live pid=" live)) "~S read ~S" who live)))))))

(define-test a-watcher-under-the-old-file-names-is-adopted
  "A watcher an earlier build started is still writing under the old name-only
   files, and the agent it serves must keep hearing it until the next restart.
   Renaming a running watcher's files stands in for that build honestly: its
   record lock and its open log both follow the inode across rename(2)."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (let* ((out (apply #'run-in state bin "--detach" "--poll-ms" "100"
                             (identity-args)))
                 (pid (parse-integer (field "pid" out)))
                 (old-pid (detach-file state "pid" :legacy t))
                 (old-log (detach-file state "log" :legacy t)))
            (flet ((move (type legacy-path)
                     (sb-posix:rename (uiop:native-namestring (detach-file state type))
                                      (uiop:native-namestring legacy-path))))
              (move "pid" old-pid)
              (move "log" old-log))
            (sleep 0.3)
            (multiple-value-bind (live err code)
                (apply #'run-in state bin "--check-live" (identity-args))
              (declare (ignore err))
              (is = 0 code)
              (true (eql 0 (search (format nil "live pid=~D " pid) live))
                    "the adopted watcher did not read live: ~S" live))
            (multiple-value-bind (again err code)
                (apply #'run-in state bin "--detach" (identity-args))
              (is = 0 code "--detach beside an adopted watcher failed: ~A" err)
              (true (eql 0 (search (format nil "running pid=~D " pid) again))
                    "--detach did not report the adopted watcher: ~S" again)
              (is equal (uiop:native-namestring old-log)
                  (field "log" (first (uiop:split-string
                                       again :separator '(#\Newline))))))
            (is = 1 (length (directory (merge-pathnames "dsmr-mcp/watch/*.pid" state)))
                "--detach started a second watcher beside the adopted one")
            (multiple-value-bind (idle err code)
                (apply #'run-in state bin "--wake" "--wake-seconds" "1"
                       "--poll-ms" "50" (identity-args))
              (declare (ignore err))
              (is = 0 code)
              (is string= "idle wake-seconds=1" idle))
            (multiple-value-bind (reaped err code)
                (apply #'run-in state bin "--reap" (identity-args))
              (declare (ignore err))
              (is = 0 code)
              (true (search (format nil "reaped pid=~D" pid) reaped) "~A" reaped))
            (false (alive-p pid)))))))

;;; unheard mail ---------------------------------------------------------------

(defun await (seconds predicate)
  "True once PREDICATE returns true, checking every tenth of a second for up to
   SECONDS."
  (loop repeat (* 10 seconds)
        thereis (funcall predicate)
        do (sleep 0.1)))

(defun detach-deafness-watcher (state bin)
  "Start a detached watcher under STATE that raises the deafness alarm after two
   seconds of unheard mail, and give it time to arm."
  (multiple-value-bind (out err code)
      (apply #'run-in state bin "--detach" "--poll-ms" "50" "--deaf-seconds" "2"
             (identity-args))
    (declare (ignore out))
    (is = 0 code "--detach failed: ~A" err))
  (sleep 0.5))

(defun follow-log (state)
  "Start a tail following the detached log under STATE, the way an agent's
   listener holds it, and return the process."
  (uiop:launch-program (list "tail" "-f" (uiop:native-namestring
                                          (detach-file state "log")))
                       :output nil :error-output nil :input nil))

(define-test unheard-mail-notifies-once-and-leaves-a-marker
  "Mail that reaches the log while nothing follows it, and stays unread past the
   threshold, must tell the operator once, naming the agent, the bus and the
   repository, and leave a marker the leader can read."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (detach-deafness-watcher state bin)
          (wal:append-record (bus-wal state *bus*) 1 "nobody is listening")
          (sleep 0.5)
          (is = 0 (length (notify-calls state)) "notified before the threshold")
          (true (await 8 (lambda () (notify-calls state)))
                "no notification after the line sat unheard")
          (sleep 1)
          (let ((calls (notify-calls state)))
            (is = 1 (length calls) "expected one notification, got ~S" calls)
            (let ((call (first calls)))
              (true (search "--urgency=critical" call) "~S" call)
              (true (search (format nil "~A cannot hear the bus" *agent*) call) "~S" call)
              (true (search (format nil "bus ~A:" *bus*) call) "~S" call)
              (true (search (string-right-trim "/" *namespace*) call) "~S" call)))
          (let ((marker (detach-file state "deaf")))
            (true (probe-file marker) "no deafness marker beside the pid file")
            (true (eql 0 (search "since=" (or (ignore-errors
                                               (uiop:read-file-string marker))
                                              "")))
                  "the marker does not say since when")
            (let* ((live (apply #'run-in state bin "--check-live" (identity-args)))
                   (deaf (field "deaf" live)))
              (true (and deaf (plusp (length deaf)) (every #'digit-char-p deaf)
                         (= (+ (search " deaf=" live) (length " deaf=") (length deaf))
                            (length live)))
                    "--check-live does not end with deaf=<epoch>: ~S" live)))))))

(define-test a-second-unheard-line-does-not-notify-again
  "One episode is one notification, however much more mail arrives unheard."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (detach-deafness-watcher state bin)
          (let ((wal (bus-wal state *bus*)))
            (wal:append-record wal 1 "first, unheard")
            (true (await 8 (lambda () (notify-calls state))) "never notified")
            (wal:append-record wal 2 "second, still unheard")
            (sleep 4)
            (is = 1 (length (notify-calls state))
                "a second unheard line notified again"))))))

(define-test a-reader-clears-the-deaf-marker
  "Once something follows the log again the agent is heard, and the marker the
   leader reads must go."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (detach-deafness-watcher state bin)
          (wal:append-record (bus-wal state *bus*) 1 "unheard for now")
          (let ((marker (detach-file state "deaf")))
            (true (await 8 (lambda () (probe-file marker))) "no marker was written")
            (let ((tail (follow-log state)))
              (unwind-protect
                   (true (await 5 (lambda () (not (probe-file marker))))
                         "the marker stayed with a reader on the log")
                (stop-process tail))))))))

(define-test mail-with-a-reader-never-notifies
  "Mail written while the log is being followed was heard, so nothing is raised
   however long it is since."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (detach-deafness-watcher state bin)
          (let ((tail (follow-log state)))
            (unwind-protect
                 (progn
                   (sleep 0.5)
                   (wal:append-record (bus-wal state *bus*) 1 "heard as it lands")
                   (sleep 6)
                   (is = 0 (length (notify-calls state))
                       "mail with a reader on the log raised the alarm")
                   (false (probe-file (detach-file state "deaf"))))
              (stop-process tail)))))))

(define-test a-quiet-bus-never-notifies
  "Nothing following the log is the normal state between turns; with no mail
   written there is nothing unheard and nothing to raise."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (detach-deafness-watcher state bin)
          (sleep 6)
          (is = 0 (length (notify-calls state)) "a quiet bus raised the alarm")
          (false (probe-file (detach-file state "deaf")))))))

(define-test a-missing-notify-send-still-leaves-the-marker
  "Without notify-send the leader must still see the episode, the log must say
   why no notification went out, and the watch must carry on."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (let* ((empty (merge-pathnames "empty-bin/" state))
                 (*watcher-path* (string-right-trim
                                  "/" (uiop:native-namestring
                                       (ensure-directories-exist empty)))))
            (detach-deafness-watcher state bin)
            (wal:append-record (bus-wal state *bus*) 1 "unheard, and no desktop")
            (true (await 8 (lambda () (probe-file (detach-file state "deaf"))))
                  "no marker without notify-send")
            (true (await-log-text (detach-file state "log")
                                  "notify-send is not on PATH")
                  "the log does not say why nobody was notified")
            (is = 0 (length (notify-calls state)))
            (multiple-value-bind (live err code)
                (apply #'run-in state bin "--check-live" (identity-args))
              (declare (ignore err))
              (is = 0 code "the watcher did not stay live: ~S" live)))))))

;;; parking --------------------------------------------------------------------

(define-test park-suppresses-the-deaf-alarm
  "A parked agent is silent on purpose, so mail it leaves unread raises nothing,
   and --check-live says it is parked."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (detach-deafness-watcher state bin)
          (multiple-value-bind (out err code)
              (apply #'run-in state bin "--park" (identity-args))
            (is = 0 code "--park failed: ~A" err)
            (is string= (format nil "parked bus=~A" *bus*) out))
          (true (probe-file (detach-file state "parked")) "no park marker written")
          (let ((live (apply #'run-in state bin "--check-live" (identity-args))))
            (true (search " parked=1" live) "--check-live does not say parked: ~S" live)
            (true (< (search " readers=" live) (search " parked=1" live))
                  "parked= is not after readers=: ~S" live))
          (wal:append-record (bus-wal state *bus*) 1 "left for after the park")
          (sleep 6)
          (is = 0 (length (notify-calls state)) "a parked agent raised the alarm")
          (false (probe-file (detach-file state "deaf")))))))

(define-test unpark-re-enables-it
  "After --unpark, mail left unread raises the alarm again; mail from before the
   unpark does not count against the agent."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (detach-deafness-watcher state bin)
          (apply #'run-in state bin "--park" (identity-args))
          (let ((wal (bus-wal state *bus*)))
            (wal:append-record wal 1 "while parked")
            (sleep 3)
            (multiple-value-bind (out err code)
                (apply #'run-in state bin "--unpark" (identity-args))
              (is = 0 code "--unpark failed: ~A" err)
              (is string= (format nil "unparked bus=~A" *bus*) out))
            (false (probe-file (detach-file state "parked")) "the park marker stayed")
            (sleep 3)
            (is = 0 (length (notify-calls state))
                "mail from the park raised the alarm after unparking")
            (wal:append-record wal 2 "after the unpark")
            (true (await 8 (lambda () (notify-calls state)))
                  "unheard mail after the unpark raised nothing")
            (is = 1 (length (notify-calls state))))))))

(define-test detach-clears-a-stale-park-marker
  "Bring-up ends a park, so a marker left by one must not silence the alarm for
   the session that follows."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (detach-deafness-watcher state bin)
          (apply #'run-in state bin "--park" (identity-args))
          (true (probe-file (detach-file state "parked")))
          (multiple-value-bind (out err code)
              (apply #'run-in state bin "--detach" (identity-args))
            (is = 0 code "--detach failed: ~A" err)
            (true (eql 0 (search "running pid=" out)) "~S" out))
          (false (probe-file (detach-file state "parked"))
                 "--detach left the park marker in place")
          (let ((live (apply #'run-in state bin "--check-live" (identity-args))))
            (false (search "parked=" live) "~S" live))))))

(define-test park-over-all-buses-marks-every-watcher
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (let ((who (list "--agent" *agent* "--namespace" *namespace*)))
            (apply #'run-in state bin "--detach" "--poll-ms" "100" "--bus" *bus* who)
            (apply #'run-in state bin "--detach" "--poll-ms" "100" "--bus" "dt2" who)
            (multiple-value-bind (out err code)
                (apply #'run-in state bin "--park" "--all-buses" who)
              (is = 0 code "--park --all-buses failed: ~A" err)
              (is equal (list "parked bus=dt" "parked bus=dt2")
                  (sort (uiop:split-string out :separator '(#\Newline)) #'string<)))
            (is = 2 (length (directory (merge-pathnames "dsmr-mcp/watch/*.parked"
                                                        state))))
            (multiple-value-bind (out err code)
                (apply #'run-in state bin "--unpark" "--all-buses" who)
              (declare (ignore err))
              (is = 0 code)
              (is equal (list "unparked bus=dt" "unparked bus=dt2")
                  (sort (uiop:split-string out :separator '(#\Newline)) #'string<)))
            (is = 0 (length (directory (merge-pathnames "dsmr-mcp/watch/*.parked"
                                                        state)))))))))

(define-test park-without-an-identity-says-unknown
  "With no identity there is no marker to write, and saying so must not look
   like success: the same `unknown` and exit 2 that --check-live gives."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (dolist (flag (list "--park" "--unpark"))
            (multiple-value-bind (out err code)
                (run-in state bin flag "--bus" *bus*)
              (declare (ignore err))
              (is = 2 code "~A with no identity exited ~A" flag code)
              (is string= "unknown" out)))
          (false (directory (merge-pathnames "dsmr-mcp/watch/*.parked" state)))))))

(defun run-in-with-input (state bin input &rest args)
  "Run BIN with ARGS under STATE as RUN-IN does, with the string INPUT on its
   standard input (none when NIL), and return (values stdout stderr exit-code
   seconds), SECONDS being how long it took."
  (let ((start (get-internal-real-time)))
    (multiple-value-bind (out err code)
        (uiop:run-program (append (list "env" "-u" "DSMR_BUS_AGENT" "-u" "DSMR_BUS_SELECTOR")
                                  (watcher-env state)
                                  (list (uiop:native-namestring bin))
                                  args)
                          :input (and input (make-string-input-stream input))
                          :output '(:string :stripped t)
                          :error-output '(:string :stripped t)
                          :ignore-error-status t)
      (values out err code
              (/ (- (get-internal-real-time) start)
                 internal-time-units-per-second)))))

(defun launch-hook (state bin &rest extra)
  "Start BIN as a Stop hook listener for the case's identity under STATE, with
   the arguments in EXTRA added, and return the process. STDOUT and STDERR are
   separate streams, since hook mode must keep the first empty."
  (uiop:launch-program (append (list "env" "-u" "DSMR_BUS_AGENT" "-u" "DSMR_BUS_SELECTOR")
                               (watcher-env state)
                               (list (uiop:native-namestring bin)
                                     "--wake" "--hook" "--poll-ms" "50")
                               extra
                               (identity-args))
                       :output :stream :error-output :stream :input nil))

(defun finish-and-read-both (process seconds)
  "Wait up to SECONDS for PROCESS, started by LAUNCH-HOOK, to exit, then return
   (values exit-code stdout stderr), both outputs whole and stripped. The exit
   code is NIL when it had to be killed."
  (let ((code (await-exit process seconds)))
    (stop-process process)
    (flet ((slurp (stream)
             (string-trim '(#\Newline #\Space)
                          (or (ignore-errors (uiop:slurp-stream-string stream)) ""))))
      (values code
              (slurp (uiop:process-info-output process))
              (slurp (uiop:process-info-error-output process))))))

(define-test hook-wake-reports-idle-on-stderr-and-exits-two
  "A hook on a quiet bus must still wake the session when its wait ends, so the
   listener is renewed before the harness's timeout ends it."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let ((hook (launch-hook state bin "--wake-seconds" "1")))
            (unwind-protect
                 (multiple-value-bind (code out err) (finish-and-read-both hook 6)
                   (is eql 2 code "a quiet hook did not exit 2")
                   (is string= "" out)
                   (true (eql 0 (search "idle wake-seconds=1" err)) "got ~S" err))
              (stop-process hook)))))))

(define-test hook-wake-reports-a-line-on-stderr-and-exits-two
  "A line reaching the log must wake the session: the line on STDERR, then what
   to do about it, exit 2, and nothing on STDOUT."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let ((hook (launch-hook state bin)))
            (unwind-protect
                 (progn
                   (sleep 0.5)
                   (wal:append-record (bus-wal state *bus*) 1 "wake the session")
                   (multiple-value-bind (code out err) (finish-and-read-both hook 5)
                     (is eql 2 code "a hook did not exit 2 on a line")
                     (is string= "" out)
                     (true (eql 0 (search "bus:1" err)) "got ~S" err)
                     (true (search "bus-receive" err)
                           "stderr does not say to drain the bus: ~S" err)))
              (stop-process hook)))))))

(define-test a-second-hook-arm-steps-aside
  "Stop hooks stack when a turn ends while the last one is still waiting. The
   second must leave at once and say nothing, and the first must still wake the
   session on the next line."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let ((hook (launch-hook state bin)))
            (unwind-protect
                 (progn
                   (sleep 0.5)
                   (multiple-value-bind (out err code seconds)
                       (apply #'run-in-with-input state bin nil
                              "--wake" "--hook" "--wake-seconds" "3" "--poll-ms" "50"
                              (identity-args))
                     (is = 0 code "the second hook exited ~A: ~S" code err)
                     (is string= "" out)
                     (is string= "" err)
                     (true (< seconds 1) "the second hook waited ~,1F s" seconds))
                   (wal:append-record (bus-wal state *bus*) 1 "for the first hook")
                   (multiple-value-bind (code out err) (finish-and-read-both hook 5)
                     (is eql 2 code "the first hook did not wake on the line")
                     (is string= "" out)
                     (true (eql 0 (search "bus:1" err)) "got ~S" err)))
              (stop-process hook)))))))

(define-test a-default-wake-says-already-armed-while-a-hook-listens
  "A background wake started while a hook is listening for the same agent must
   say so and leave, or one message would wake the session twice."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let ((hook (launch-hook state bin)))
            (unwind-protect
                 (progn
                   (sleep 0.5)
                   (multiple-value-bind (out err code seconds)
                       (apply #'run-in-with-input state bin nil
                              "--wake" "--wake-seconds" "3" "--poll-ms" "50"
                              (identity-args))
                     (declare (ignore err))
                     (is = 0 code "a second wake exited ~A" code)
                     (is string= "already-armed" out)
                     (true (< seconds 1) "a second wake waited ~,1F s" seconds)))
              (stop-process hook)))))))

(define-test hook-nowatcher-wakes-once-then-stays-quiet
  "A missing watcher is worth waking the session for once, but the hook starts
   again at every turn end, and waking on each of them would never stop."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (multiple-value-bind (out err code)
              (apply #'run-in state bin "--wake" "--hook" (identity-args))
            (is = 2 code "the first nowatcher hook exited ~A" code)
            (is string= "" out)
            (true (eql 0 (search (format nil "nowatcher bus=~A" *bus*) err))
                  "stderr did not open with the nowatcher line: ~S" err)
            (true (search "--detach" err) "stderr does not say how to start one: ~S" err))
          (multiple-value-bind (out err code)
              (apply #'run-in state bin "--wake" "--hook" (identity-args))
            (is = 0 code "a second nowatcher hook woke the session again")
            (is string= "" out)
            (is string= "" err))))))

(define-test hook-without-an-identity-does-nothing
  "A session that is not in a fleet still runs the Stop hook at every turn end,
   and must neither be woken nor told anything."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (multiple-value-bind (out err code)
              (run-in state bin "--wake" "--hook" "--agent" "" "--bus" *bus*)
            (is = 0 code "a hook with no identity exited ~A: ~S" code err)
            (is string= "" out)
            (is string= "" err))))))

(define-test hook-inside-a-subagent-does-nothing
  "A Stop hook that fires inside a subagent is handed an `agent_id`, and must
   not arm a listener under the identity of the session that spawned it."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (multiple-value-bind (out err code seconds)
              (apply #'run-in-with-input state bin
                     "{\"hook_event_name\":\"Stop\",\"agent_id\":\"abc\"}"
                     "--wake" "--hook" "--wake-seconds" "2" "--poll-ms" "50"
                     (identity-args))
            (is = 0 code "a subagent's hook exited ~A: ~S" code err)
            (is string= "" out)
            (is string= "" err)
            (true (< seconds 1) "a subagent's hook waited ~,1F s" seconds))))))

(define-test mail-sent-between-arms-wakes-the-next-arm
  "A line that lands during a turn, after one hook has woken the session and
   before the next is armed, must wake the session as soon as the next arm
   starts. Otherwise it waits for whatever mail comes after it."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let ((wal (bus-wal state *bus*))
                (log (detach-file state "log")))
            (let ((hook (launch-hook state bin)))
              (unwind-protect
                   (progn
                     (sleep 0.5)
                     (wal:append-record wal 1 "wakes the first arm")
                     (multiple-value-bind (code out err) (finish-and-read-both hook 5)
                       (declare (ignore out))
                       (is eql 2 code)
                       (true (eql 0 (search "bus:1" err)) "got ~S" err)))
                (stop-process hook)))
            (wal:append-record wal 2 "lands while nothing listens")
            (true (await-log-text log "bus:2") "the line never reached the log")
            (multiple-value-bind (out err code seconds)
                (apply #'run-in-with-input state bin nil
                       "--wake" "--hook" "--wake-seconds" "5" "--poll-ms" "50"
                       (identity-args))
              (is = 2 code)
              (is string= "" out)
              (true (eql 0 (search "bus:2" err)) "the next arm reported ~S" err)
              (true (< seconds 2) "the next arm took ~,1F s" seconds)))))))

(define-test a-first-arm-starts-at-the-end
  "With no offset saved there is no record of what the agent has read, and a
   first arm must not wake it for mail from before it ever listened. Every
   return saves one, the background wake's included."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let ((log (detach-file state "log"))
                (offset (detach-file state "offset")))
            (wal:append-record (bus-wal state *bus*) 1 "from before any listener")
            (true (await-log-text log "bus:1") "the line never reached the log")
            (false (probe-file offset) "an offset existed before any arm")
            (multiple-value-bind (out err code)
                (apply #'run-in-with-input state bin nil
                       "--wake" "--hook" "--wake-seconds" "1" "--poll-ms" "50"
                       (identity-args))
              (declare (ignore out))
              (is = 2 code)
              (true (eql 0 (search "idle wake-seconds=1" err))
                    "a first arm reported an old line: ~S" err))
            (true (probe-file offset) "a hook return saved no offset")
            (delete-file offset)
            (multiple-value-bind (out err code)
                (apply #'run-in-with-input state bin nil
                       "--wake" "--wake-seconds" "1" "--poll-ms" "50"
                       (identity-args))
              (declare (ignore err))
              (is = 0 code)
              (is string= "idle wake-seconds=1" out))
            (true (probe-file offset) "a background wake saved no offset"))))))

(define-test an-offset-for-a-replaced-log-is-ignored
  "A saved offset names the file it was taken on. Once the log has been
   replaced, it says nothing about the new one, and the arm starts at the end."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" (identity-args))
          (let* ((log (detach-file state "log"))
                 (offset (detach-file state "offset")))
            (wal:append-record (bus-wal state *bus*) 1 "already in the log")
            (true (await-log-text log "bus:1") "the line never reached the log")
            (let ((ino (sb-posix:stat-ino (sb-posix:stat (uiop:native-namestring log)))))
              (flet ((save (ino)
                       (with-open-file (out offset :direction :output
                                                   :if-exists :supersede
                                                   :if-does-not-exist :create)
                         (format out "ino=~D pos=0~%" ino)))
                     (arm ()
                       (apply #'run-in-with-input state bin nil
                              "--wake" "--hook" "--wake-seconds" "1" "--poll-ms" "50"
                              (identity-args))))
                (save ino)
                (multiple-value-bind (out err code) (arm)
                  (declare (ignore out))
                  (is = 2 code)
                  (true (eql 0 (search "bus:1" err))
                        "an offset on the live log was not honoured: ~S" err))
                (save (+ ino 12345))
                (multiple-value-bind (out err code) (arm)
                  (declare (ignore out))
                  (is = 2 code)
                  (true (eql 0 (search "idle wake-seconds=1" err))
                        "an offset on another file was honoured: ~S" err)))))))))

(define-test a-hook-read-counts-as-heard
  "Mail written while no listener was armed, then reported by the next hook arm,
   was heard: the offset that arm saves must keep the deafness alarm quiet."
  (let ((bin (watcher-binary)))
    (if (null bin)
        (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
        (with-state (state bin)
          (apply #'run-in state bin "--detach" "--poll-ms" "50" "--deaf-seconds" "3"
                 (identity-args))
          (let ((wal (bus-wal state *bus*))
                (log (detach-file state "log")))
            (let ((hook (launch-hook state bin)))
              (unwind-protect
                   (progn
                     (sleep 0.5)
                     (wal:append-record wal 1 "heard by the first arm")
                     (is eql 2 (finish-and-read-both hook 5)))
                (stop-process hook)))
            (wal:append-record wal 2 "written with nothing armed")
            (true (await-log-text log "bus:2") "the line never reached the log")
            ;; The alarm compares whole seconds, and an offset saved in the
            ;; same second the line was written does not count as newer.
            (sleep 1.2)
            (multiple-value-bind (out err code seconds)
                (apply #'run-in-with-input state bin nil
                       "--wake" "--hook" "--wake-seconds" "3" "--poll-ms" "50"
                       (identity-args))
              (declare (ignore out))
              (is = 2 code)
              (true (eql 0 (search "bus:2" err)) "got ~S" err)
              (true (< seconds 1) "the next arm took ~,1F s" seconds))
            (sleep 5)
            (is = 0 (length (notify-calls state))
                "a line the next arm reported raised the alarm")
            (false (probe-file (detach-file state "deaf"))))))))
