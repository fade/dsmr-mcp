;;;; tests/integration/bus/fleet-log-wake-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cross-process cover for the watcher binary's fleet-log side: the
;;;; background listener a leader keeps on the host's fleet error log
;;;; (`--wake --fleet-log`).
;;;;
;;;; The listener is a separate process that exits when a line arrives, so the
;;;; cases start the real binary, write to the log from here, and read what it
;;;; printed and how it exited. Every case runs under its own state root (see
;;;; host-support). With no built binary (`make bus-watch`) the cases skip, and
;;;; a skip is a failure for the runner this file is meant to be run by.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/fleet-log-wake-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/bus/fleet-log-wake-test
  (:use #:cl #:zebra #:dsmr-mcp/tests/integration/bus/host-support)
  (:local-nicknames (#:hostfiles #:dsmr-mcp/src/bus/hostfiles)))

(in-package #:dsmr-mcp/tests/integration/bus/fleet-log-wake-test)

(defparameter *bus* "fl"
  "The bus an identity wake in these cases names.")

(defparameter *namespace* "/dsmr-bus-watch-it/fleet/"
  "The namespace every identity here is built under.")

(defparameter *agent* "lead"
  "The leader every fleet-log wake listens for.")

(defmacro with-binary ((bin) &body body)
  "Run BODY with BIN bound to the built watcher, or skip the case when there is
   none. A real branch, so a skip never runs the body."
  `(let ((,bin (watcher-binary)))
     (declare (ignorable ,bin))
     (if (null ,bin)
         (skip ("dsmr-bus-watch not built; run 'make bus-watch' to enable this test"))
         (progn ,@body))))

(defun id-args ()
  (identity-args *bus* *namespace* *agent*))

(defun fleet-log (state)
  "The fleet log under STATE."
  (with-state-home (state) (hostfiles:fleet-log-path)))

(defun install-service (state)
  "Leave the record that says the host service is installed under STATE."
  (with-state-home (state)
    (hostfiles:ensure-host-dir)
    (hostfiles:write-plist-file (hostfiles:service-state-path)
                                (list :pid 1 :stand-in t))))

(defun append-line (state line)
  "Append LINE to the fleet log under STATE as every writer does."
  (with-state-home (state)
    (hostfiles:append-fleet-line line)))

(defun a-fleet-line (code)
  (hostfiles:fleet-line :error code :bus *bus* :msg (format nil "test ~A" code)))

(defun start-wake (state &rest args)
  "Start the binary under STATE with ARGS, its output to a file, and return
   the process."
  (uiop:launch-program
   (append (list "env" "-u" "DSMR_BUS_AGENT" "-u" "DSMR_BUS_SELECTOR"
                 "-u" "CLAUDE_PID")
           (watcher-env state)
           (list (uiop:native-namestring (watcher-binary)))
           args)
   :input nil
   :output (uiop:native-namestring (merge-pathnames "wake.out" state))
   :if-output-exists :supersede
   :error-output (uiop:native-namestring (merge-pathnames "wake.err" state))
   :if-error-output-exists :supersede))

(defun finish-wake (state process seconds)
  "Wait up to SECONDS for PROCESS, and return its stdout (stripped) and its
   exit code, NIL when it is still running. A process still running is killed
   on the way out."
  (let ((code (await-exit process seconds)))
    (unless code
      (ignore-errors (uiop:terminate-process process :urgent t))
      (ignore-errors (uiop:wait-process process)))
    (values (string-right-trim
             '(#\Newline)
             (or (ignore-errors
                  (uiop:read-file-string (merge-pathnames "wake.out" state)))
                 ""))
            code)))

(defun settle ()
  "Give a just-started wake time to open the log and take its lock."
  (sleep 1.5))

;;; the wake ---------------------------------------------------------------------

(define-test fleet-wake-prints-the-next-fleet-line
  "A fleet line written after the wake starts is printed exactly, and a line
that is not a fleet line, or one written before the wake started, is not."
  (with-binary (bin)
    (with-host-state (state)
      (install-service state)
      (append-line state (a-fleet-line "before"))
      (let ((wake (apply #'start-wake state "--wake" "--fleet-log"
                         "--wake-seconds" "30" (id-args)))
            (line (a-fleet-line "after")))
        (settle)
        (append-line state "an ordinary line with no fleet marker")
        (append-line state line)
        (multiple-value-bind (out code) (finish-wake state wake 10)
          (is eql 0 code)
          (is string= line out))))))

(define-test fleet-wake-returns-idle-at-its-deadline
  "With nothing arriving, the wake returns the idle line and exits 0."
  (with-binary (bin)
    (with-host-state (state)
      (install-service state)
      (multiple-value-bind (out err code)
          (apply #'run-in state bin "--wake" "--fleet-log" "--wake-seconds" "2"
                 (id-args))
        (is = 0 code "stderr: ~A" err)
        (is string= "idle wake-seconds=2" out)))))

(define-test fleet-wake-resumes-from-its-saved-offset
  "A line written between two wakes, while nothing listened, is printed by
the second. The offset lives in the host directory under the identity's own
name, never beside the shared log."
  (with-binary (bin)
    (with-host-state (state)
      (install-service state)
      (let ((wake (apply #'start-wake state "--wake" "--fleet-log"
                         "--wake-seconds" "30" (id-args)))
            (first (a-fleet-line "first"))
            (between (a-fleet-line "between")))
        (settle)
        (append-line state first)
        (multiple-value-bind (out code) (finish-wake state wake 10)
          (is eql 0 code)
          (is string= first out))
        (append-line state between)
        (multiple-value-bind (out err code)
            (apply #'run-in state bin "--wake" "--fleet-log" "--wake-seconds" "5"
                   (id-args))
          (is = 0 code "stderr: ~A" err)
          (is string= between out))
        (let ((host (merge-pathnames "dsmr-mcp/host/" state)))
          (true (probe-file (merge-pathnames
                             (format nil "fleet-error--~A--~A.offset"
                                     *agent*
                                     (hostfiles:identity-hash
                                      (hostfiles:normalise-agent-id
                                       (full-id *namespace* *agent*))))
                             host))
                "the offset is kept under the identity's name")
          (false (probe-file (merge-pathnames "fleet-error.offset" host))
                 "and not beside the shared log"))))))

(define-test fleet-wake-follows-the-log-across-a-rollover
  "A log renamed away while the wake waits is left for the new file, and the
new file's fleet line is printed."
  (with-binary (bin)
    (with-host-state (state)
      (install-service state)
      (append-line state (a-fleet-line "old"))
      (let ((wake (apply #'start-wake state "--wake" "--fleet-log"
                         "--wake-seconds" "30" (id-args)))
            (log (fleet-log state))
            (line (a-fleet-line "rolled")))
        (settle)
        (rename-file log (make-pathname :type "log-2026-10-12" :defaults log))
        (append-line state line)
        (multiple-value-bind (out code) (finish-wake state wake 10)
          (is eql 0 code)
          (is string= line out))))))

(define-test fleet-wake-is-one-listener-per-identity
  "A second fleet-log wake for the same identity prints already-armed, while
the identity's bus listener is not held back by it."
  (with-binary (bin)
    (with-host-state (state)
      (install-service state)
      (let ((wake (apply #'start-wake state "--wake" "--fleet-log"
                         "--wake-seconds" "30" (id-args))))
        (settle)
        (multiple-value-bind (out err code)
            (apply #'run-in state bin "--wake" "--fleet-log" "--wake-seconds" "5"
                   (id-args))
          (is = 0 code "stderr: ~A" err)
          (is string= "already-armed" out))
        ;; The bus listener takes its own lock first, so reaching the missing
        ;; watcher shows the fleet listener did not stand in its way.
        (multiple-value-bind (out err code)
            (apply #'run-in state bin "--wake" "--wake-seconds" "5" (id-args))
          (is = 1 code "stderr: ~A" err)
          (is string= (format nil "nowatcher bus=~A" *bus*) out))
        (let ((line (a-fleet-line "release")))
          (append-line state line)
          (multiple-value-bind (out code) (finish-wake state wake 10)
            (is eql 0 code)
            (is string= line out)))))))

(define-test fleet-wake-reports-a-host-without-the-service
  "Where neither the service nor the fleet log has ever existed, the wake
says noservice and exits 1 instead of waiting on a log nothing writes."
  (with-binary (bin)
    (with-host-state (state)
      (multiple-value-bind (out err code)
          (apply #'run-in state bin "--wake" "--fleet-log" "--wake-seconds" "5"
                 (id-args))
        (is = 1 code "stderr: ~A" err)
        (is string= "noservice" out)))))

(define-test fleet-log-is-refused-with-the-hook-or-without-wake
  "A fleet-log listener cannot run as a Stop hook, and --fleet-log means
nothing without --wake: both are usage errors."
  (with-binary (bin)
    (with-host-state (state)
      (install-service state)
      (multiple-value-bind (out err code)
          (apply #'run-in state bin "--wake" "--hook" "--fleet-log"
                 "--wake-seconds" "2" (id-args))
        (declare (ignore err))
        (is = 64 code)
        (is string= "" out))
      (multiple-value-bind (out err code)
          (apply #'run-in state bin "--fleet-log" (id-args))
        (declare (ignore err))
        (is = 64 code)
        (is string= "" out)))))
