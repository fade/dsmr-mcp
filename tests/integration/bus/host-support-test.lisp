;;;; tests/integration/bus/host-support-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Cover for the deadlines host-support puts on the waits every host case
;;;; makes. Each case plants the hang it proves against with /bin/sh, sleep, or
;;;; a thread of its own, and stops what it planted on the way out: a process
;;;; by the pid it recorded, a thread through a stop flag. The cases need no
;;;; built binary and never skip.

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

(define-test an-error-in-a-case-thread-reaches-the-joining-case
  (is equal '(1 2)
      (multiple-value-list
       (join-within (start-case-thread "two values" (lambda () (values 1 2)))
                    5 "a thread returning two values")))
  (let ((condition
          (handler-case
              (progn (join-within (start-case-thread
                                   "planted error"
                                   (lambda () (error "planted error in a case thread")))
                                  5 "a thread signalling an error")
                     nil)
            (error (c) c))))
    (of-type simple-error condition)
    (is string= "planted error in a case thread"
        (and condition (princ-to-string condition)))))

(define-test a-join-past-its-bound-fails-naming-the-operation
  (let* ((stop (vector nil))
         (thread (start-case-thread "sleeper"
                                    (lambda ()
                                      (loop until (svref stop 0) do (sleep 0.05))
                                      :stopped))))
    (unwind-protect
         (let* ((started (get-internal-real-time))
                (condition (handler-case
                               (progn (join-within thread 1 "joining the sleeper") nil)
                             (deadline-passed (c) c)))
                (elapsed (seconds-since started)))
           (true condition "the join did not signal DEADLINE-PASSED")
           (true (< elapsed 3) "the join took ~,1F s to fail" elapsed)
           (when condition
             (is string= "joining the sleeper" (deadline-passed-operation condition))
             (is = 1 (deadline-passed-seconds condition))))
      (setf (svref stop 0) t)
      (is eq :stopped (join-within thread 5 "joining the stopped sleeper")))))

(define-test a-read-past-its-deadline-fails-as-an-error-not-a-timeout
  (let* ((process (uiop:launch-program (list "sleep" "600")
                                       :input nil :output :stream :error-output nil))
         (pid (uiop:process-info-pid process)))
    (unwind-protect
         (let* ((started (get-internal-real-time))
                (condition (handler-case
                               (progn
                                 (within-deadline ("reading the sleeper's output" 1)
                                   (read-line (uiop:process-info-output process) nil))
                                 nil)
                             (serious-condition (c) c)))
                (elapsed (seconds-since started)))
           (true (< elapsed 3) "the read took ~,1F s to fail" elapsed)
           (of-type deadline-passed condition)
           (true (typep condition 'error) "~S is not an ERROR" condition)
           (false (typep condition 'sb-ext:timeout) "~S is an SBCL timeout" condition))
      (stop-process pid)
      (unless (uiop:process-alive-p process)
        (ignore-errors (uiop:wait-process process))))))
