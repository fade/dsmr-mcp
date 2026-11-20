;;;; tests/integration/bus/host-support-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cover for the deadlines host-support puts on the waits every host case
;;;; makes. Each case plants the hang it proves against with /bin/sh and sleep,
;;;; records the planted pid in a file under its own state root, and stops that
;;;; pid on the way out, so the cases need no built binary and never skip.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/integration/bus/host-support-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/integration/bus/host-support-test
  (:use #:cl #:zebra #:dsmr-mcp/tests/integration/bus/host-support))

(in-package #:dsmr-mcp/tests/integration/bus/host-support-test)

(defun seconds-since (start)
  "Seconds elapsed since START, an internal real time."
  (/ (- (get-internal-real-time) start) internal-time-units-per-second))

(defun planted-pid (file)
  "The pid recorded in FILE, waiting up to 5 s for it to appear, or NIL."
  (await-true (lambda ()
                (ignore-errors
                 (parse-integer (uiop:read-file-string file) :junk-allowed t)))
              5))

(defun stop-planted (file)
  "Stop the pid recorded in FILE when it is still alive."
  (let ((pid (ignore-errors
              (parse-integer (uiop:read-file-string file) :junk-allowed t))))
    (when (and pid (alive-p pid))
      (stop-process pid))))

(define-test a-run-past-its-bound-fails-naming-the-command-and-stops-it
  (with-host-state (state)
    (let ((pid-file (merge-pathnames "planted.pid" state)))
      (unwind-protect
           (let* ((started (get-internal-real-time))
                  (condition
                    (let ((*run-seconds* 2))
                      (handler-case
                          (progn
                            (run-in state #p"/bin/sh" "-c"
                                    (format nil "echo $$ > '~A'; exec sleep 600"
                                            (uiop:native-namestring pid-file)))
                            nil)
                        (deadline-passed (c) c))))
                  (elapsed (seconds-since started))
                  (pid (planted-pid pid-file)))
             (true condition "the run did not signal DEADLINE-PASSED")
             (true (< elapsed 10) "the run took ~,1F s to fail" elapsed)
             (true pid "no planted pid recorded")
             (when condition
               (true (search "exec sleep 600" (deadline-passed-operation condition))
                     "operation ~S does not name the command"
                     (deadline-passed-operation condition))
               (is = 2 (deadline-passed-seconds condition))
               (true (and pid (search (princ-to-string pid)
                                      (or (deadline-passed-detail condition) "")))
                     "detail ~S does not name pid ~A"
                     (deadline-passed-detail condition) pid))
             (false (alive-p pid) "planted pid ~A is still running" pid))
        (stop-planted pid-file)))))

(define-test a-run-returns-at-its-exit-though-a-descendant-holds-its-output
  (with-host-state (state)
    (let ((pid-file (merge-pathnames "planted.pid" state)))
      (unwind-protect
           (let ((started (get-internal-real-time)))
             (multiple-value-bind (out err code)
                 (run-in state #p"/bin/sh" "-c"
                         (format nil "sleep 600 & echo $! > '~A'; echo started"
                                 (uiop:native-namestring pid-file)))
               (declare (ignore err))
               (let ((elapsed (seconds-since started))
                     (pid (planted-pid pid-file)))
                 (true (< elapsed 5) "the run took ~,1F s to return" elapsed)
                 (is string= "started" out)
                 (is eql 0 code)
                 (true (alive-p pid) "planted sleeper ~A is not running" pid))))
        (stop-planted pid-file)))))

(define-test a-run-returns-its-outputs-and-code
  (with-host-state (state)
    (multiple-value-bind (out err code)
        (run-in state #p"/bin/sh" "-c" "echo out; echo err >&2; exit 3")
      (is string= "out" out)
      (is string= "err" err)
      (is eql 3 code))))
