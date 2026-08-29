;;;; tests/integration/bus/broker-identity-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process tests for what a bus can say about the broker serving it.
;;;;
;;;; These cases need real processes and cannot be had any other way. Whether a
;;;; broker has been reparented is a property of a live process tree: the value
;;;; is read from the running broker, the value it started with is read from the
;;;; record it wrote, and the two disagree only when the process that spawned it
;;;; has actually gone. Nothing short of spawning one and letting its parent exit
;;;; produces that.
;;;;
;;;; The ordinary case is here for the same reason the reparented one is. Every
;;;; broker on a running fleet has been reparented, so a field hardcoded to
;;;; answer that would look right on every measurement anybody would ordinarily
;;;; take. The two cases together are what establish that it reads the world.
;;;;
;;;; Each leaf spawns real children and skips cleanly where the environment
;;;; cannot build one, so a runner without the toolchain reports unsupported
;;;; rather than broken. Every spawned broker is killed on the way out, the
;;;; orphaned one included, by the pid its own record names and never by a scan
;;;; of the process table: a broker of another bus is indistinguishable there.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/broker-identity-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/bus/broker-identity-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:status #:dsmr-mcp/src/bus/status)
                    (#:broker #:dsmr-mcp/src/bus/broker))
  (:import-from #:dsmr-mcp/tests/integration/support
                #:with-mcp-server-child-or-skip))

(in-package #:dsmr-mcp/tests/integration/bus/broker-identity-test)

;;; ---------------------------------------------------------------- helpers

(defparameter *ready-timeout* 180
  "Seconds to allow a cold-spawned broker to load its systems and take the role.")

(defun wait-until (predicate &key (timeout 30) (poll 0.2))
  "Poll PREDICATE until it answers true or TIMEOUT seconds pass."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop for value = (funcall predicate)
          when value return value
          when (> (get-internal-real-time) deadline) return nil
          do (sleep poll))))

(defun scratch-bus-root ()
  "A bus root of this test's own making, under the cache directory. Never a live
   bus: everything here spawns and kills brokers."
  (let ((dir (merge-pathnames
              (format nil "broker-identity-probe-~D-~D/"
                      (sb-posix:getpid) (random 100000000))
              (merge-pathnames "dsmr-mcp/" (uiop:xdg-cache-home)))))
    (ensure-directories-exist dir)
    dir))

(defmacro with-scratch-bus ((paths) &body body)
  "Bind PATHS to a fresh bus of this test's own, removed entirely afterwards."
  (let ((root (gensym "ROOT")))
    `(let* ((,root (scratch-bus-root))
            (,paths (broker:make-bus-paths ,root)))
       (broker:ensure-bus-dirs ,paths)
       (unwind-protect (progn ,@body)
         (ignore-errors (uiop:delete-directory-tree
                         ,root :validate t :if-does-not-exist :ignore))))))

(defun broker-ready-p (paths)
  "A broker is serving once it holds the election lock and has bound its intake."
  (and (broker:broker-running-p paths)
       (probe-file (merge-pathnames "submit.ipc" (broker:bus-paths-root paths)))))

(defun wait-for-broker (paths)
  (wait-until (lambda () (broker-ready-p paths)) :timeout *ready-timeout*))

(defun serves-this-bus-p (pid paths)
  "True when the process PID was started for the bus at PATHS, read from its own
   command line. The cross-check that keeps a teardown from killing a broker it
   did not start: every broker on the host has the same program name."
  (let ((cmdline (ignore-errors
                  (uiop:read-file-string (format nil "/proc/~D/cmdline" pid)))))
    (and cmdline
         (search (namestring (broker:bus-paths-root paths)) cmdline)
         t)))

(defun reap-broker (paths)
  "Kill whatever broker is serving PATHS, named by the pid its own record on this
   bus carries and confirmed against that process's command line.

   Deliberately built out of nothing the tests here are checking. A teardown that
   borrowed the reader under test would stop reaping at exactly the moment that
   reader was made to answer wrongly, and would leave a real broker process
   behind while the run went green. Reading the command line answers both
   questions at once: a process that has gone has no command line to read.

   Killed outright rather than asked politely. A clean last-member-out shutdown
   seals the log, and a teardown has no business doing that on the way past."
  (let* ((record (broker:read-broker-identity paths))
         (pid (broker:broker-identity-pid record)))
    (when (and pid (serves-this-bus-p pid paths))
      (ignore-errors (sb-posix:kill pid 9))
      (wait-until (lambda () (not (serves-this-bus-p pid paths))) :timeout 15))))

(defun spawn-orphaned-broker (paths)
  "Start a broker under a shell that waits for it to record itself and then
   exits, leaving the broker adopted by whatever adopts orphans on this host.

   The shell has to outlive the broker's own record and no longer, and that
   window is the whole point. The record carries the parent the broker had when
   it wrote it, the live parent is read from the running process, and the two
   disagree only when the spawning process was there for the first and gone by
   the second. Measured: a shell that exits at once is already gone when the
   record is written, so both values read as the adopter and their agreement
   establishes nothing.

   The broker's own output goes to the bus's log rather than being inherited. An
   inherited descriptor keeps this caller waiting on the broker instead of on the
   shell, which is the wait this is arranged to avoid."
  (broker:ensure-bus-dirs paths)
  (let* ((args (broker::%broker-spawn-args (broker:bus-paths-root paths)
                                           :block nil))
         (log (namestring (merge-pathnames "broker.log"
                                           (broker:bus-paths-root paths))))
         (record (namestring (broker:broker-identity-path paths)))
         (command (format nil "~A > ~A 2>&1 & i=0; ~
                              while [ ! -s ~A ] && [ $i -lt 900 ]; ~
                              do sleep 0.2; i=$((i+1)); done"
                          (uiop:escape-sh-command args)
                          (uiop:escape-sh-token log)
                          (uiop:escape-sh-token record))))
    (uiop:run-program (list "sh" "-c" command) :ignore-error-status t)))

(defun measured-parent-pid (pid)
  "The parent PID reports right now, read with the system's own process tool.

   Deliberately not the reader these tests are checking. A value taken with the
   instrument under test agrees with it by construction, and agreement is not
   verification: pinning the reader to a constant would silently pin this to the
   same constant and the comparison would still pass."
  (let ((printed (ignore-errors
                  (uiop:run-program (list "ps" "-o" "ppid=" "-p"
                                          (princ-to-string pid))
                                    :output :string
                                    :ignore-error-status t))))
    (and printed
         (parse-integer (string-trim '(#\Space #\Tab #\Newline #\Return) printed)
                        :junk-allowed t))))

(defun adopting-parent-pid ()
  "The pid that adopts an orphan on this host, measured rather than assumed.

   A shell backgrounds a short sleep and exits, and whatever the sleep's parent
   is afterwards is what will adopt an orphaned broker too. Measured because a
   host running a subreaper adopts to something other than the init process, and
   a hardcoded number would make this test wrong there rather than failing
   there."
  (let* ((printed (uiop:run-program
                   '("sh" "-c" "sleep 30 >/dev/null 2>&1 & echo $!")
                   :output :string :ignore-error-status t))
         (pid (parse-integer (string-trim '(#\Space #\Tab #\Newline #\Return) printed)
                             :junk-allowed t)))
    (unwind-protect (and pid (measured-parent-pid pid))
      (when pid (ignore-errors (sb-posix:kill pid 9))))))

(defun pid-that-does-not-exist ()
  "A pid no process answers to, found by looking rather than by picking a number
   and hoping. The pids in use cluster far below the kernel's ceiling, so the
   search from the top ends at once.

   It looks in the process table itself rather than asking the reader under test
   whether a process is alive. A plant built out of the thing it is planted
   against stops being a plant the moment that thing is wrong, which is the one
   moment it is needed."
  (loop for pid from 4000000 downto 100000
        unless (probe-file (format nil "/proc/~D/" pid)) return pid))

(defun plant-identity-record (paths plist)
  "Write PLIST as this bus's broker identity record.

   Written here rather than by a broker on purpose: the case being planted is a
   record that outlived the process it names, and no broker will write one of
   those to order."
  (with-open-file (out (broker:broker-identity-path paths)
                       :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (with-standard-io-syntax (prin1 plist out)))
  plist)

;;; ------------------------------------------------------------------ tests

(define-test a-broker-spawned-as-a-child-names-this-process-as-its-parent
  "The ordinary case, and the one that has to be plantable for the reparented
   case below to mean anything. Every broker on a running fleet is reparented, so
   a field that always answered so would agree with every measurement anybody
   would ordinarily take."
  (with-mcp-server-child-or-skip
    (with-scratch-bus (paths)
      (let ((proc nil))
        (unwind-protect
             (progn
               (setf proc (broker:spawn-broker paths :block nil))
               (true (wait-for-broker paths) "the spawned broker came up")
               (let ((identity (status:broker-identity paths)))
                 (is equal "running" (getf (getf identity :running) :value))
                 (is = (uiop:process-info-pid proc)
                     (getf (getf identity :pid) :value)
                     "the record names the process that was spawned")
                 (is = (sb-posix:getpid)
                     (getf (getf identity :parent-pid) :value)
                     "and it reports this process as its parent")))
          (when proc (ignore-errors (uiop:terminate-process proc :urgent t)))
          (reap-broker paths))))))

(define-test a-broker-whose-spawning-process-has-exited-is-adopted-by-another
  "The reparented case, planted by letting the shell that started the broker
   exit. Taken with the case above, this is what establishes that the parent is
   read from the running process rather than answered from a constant."
  (with-mcp-server-child-or-skip
    (with-scratch-bus (paths)
      (unwind-protect
           (progn
             (spawn-orphaned-broker paths)
             (true (wait-for-broker paths) "the detached broker came up")
             (let* ((identity (status:broker-identity paths))
                    (parent (getf (getf identity :parent-pid) :value))
                    (at-start (getf (getf identity :parent-pid-at-start) :value)))
               (is = (adopting-parent-pid) parent
                   "an orphan is adopted by whatever adopts orphans on this host")
               (true (/= parent (sb-posix:getpid))
                     "and not by the process running this test")
               (true (/= parent at-start)
                     "the parent it started under and the one it has now disagree, ~
                      which is the reparenting itself and is what neither value ~
                      shows on its own")))
        (reap-broker paths)))))

(define-test a-record-naming-a-vanished-process-does-not-report-a-broker-running
  "The specific way this field could lie, planted rather than argued about. An
   identity record is a file, it survives the broker that wrote it, and reporting
   it as current would be the stale-state failure the whole surface exists to
   remove."
  (with-scratch-bus (paths)
    (let ((absent (pid-that-does-not-exist)))
      (true absent "a pid with no process behind it was found to plant")
      (plant-identity-record paths
                             (list :pid absent
                                   :ppid-at-start 1
                                   :started-at (get-universal-time)
                                   :source-revision nil
                                   :version "planted"))
      (let ((identity (status:broker-identity paths)))
        (is equal "not-running" (getf (getf identity :running) :value)
            "nothing holds this bus's election lock, so nothing is serving it")
        (is equal "unavailable" (getf (getf identity :pid) :value)
            "and a pid nothing answers to is not repeated as though it were current")
        (is equal "unavailable" (getf (getf identity :parent-pid) :value)
            "nor is a parent invented for a process that is not there")))))

(define-test a-serving-broker-reports-an-advancing-uptime-and-a-definite-revision
  "Two fields that would each be satisfied by a constant, so each is pinned to
   something that moves or to a value taken from the record itself. The revision
   branches on the state read from the answer: a revision that is present must be
   a non-empty string equal to what the broker recorded, and one that is absent
   must say why. An empty string fails both."
  (with-mcp-server-child-or-skip
    (with-scratch-bus (paths)
      (let ((proc nil))
        (unwind-protect
             (progn
               (setf proc (broker:spawn-broker paths :block nil))
               (true (wait-for-broker paths) "the spawned broker came up")
               (let ((first (getf (getf (status:broker-identity paths)
                                        :uptime-seconds)
                                  :value)))
                 (sleep 3)
                 (let ((second (getf (getf (status:broker-identity paths)
                                           :uptime-seconds)
                                     :value)))
                   (true (> second first)
                         "the uptime is taken from the recorded start time and moves")))
               (let* ((identity (status:broker-identity paths))
                      (revision (getf identity :source-revision))
                      ;; Read straight out of the record the broker wrote rather
                      ;; than through the accessor the reader uses, so the two
                      ;; sides of this comparison cannot be made to agree by one
                      ;; change.
                      (recorded (getf (broker:read-broker-identity paths)
                                      :source-revision)))
                 (if (equal "unavailable" (getf revision :value))
                     (true (plusp (length (getf revision :establishes)))
                           "an absent revision says why it is absent")
                     (progn
                       (true (plusp (length (getf revision :value)))
                             "a reported revision is not an empty string")
                       (is equal recorded (getf revision :value)
                           "and it is what the broker itself recorded at start")))
                 (true (search "working tree" (getf revision :does-not-establish))
                       "and either way it says it settles nothing about the tree ~
                        as it stands now")))
          (when proc (ignore-errors (uiop:terminate-process proc :urgent t)))
          (reap-broker paths))))))
