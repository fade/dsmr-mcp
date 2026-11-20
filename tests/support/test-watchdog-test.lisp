;;;; tests/support/test-watchdog-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Controls for the per-test watchdog: the setting's parser, a stop that fails
;;;; the named test and lets the run continue, the under-bound and off cases, the
;;;; diagnostics printed at a stop, a stuck cleanup, and a race between a test
;;;; finishing and its stop.
;;;;
;;;; Fixtures are installed at run time into two scratch packages that no system
;;;; lists, so a fixture that fails on purpose never fails the real run. Both
;;;; packages are emptied before and after each use. Two packages fix the order
;;;; across packages; zebra gives no order within one. Every process, thread,
;;;; and lock a fixture creates is released by the fixture or by its control.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import set.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/support/test-watchdog-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/support/test-watchdog-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/support/test-watchdog
                #:run-test-packages
                #:parse-watchdog-seconds
                #:*default-watchdog-seconds*
                #:*proc-directory*))

(in-package #:dsmr-mcp/tests/support/test-watchdog-test)

;;; ------------------------------------------------------------------
;;; Scratch fixtures

(defvar *first-package*
  (or (find-package '#:dsmr-mcp-watchdog-fixtures-first)
      (make-package '#:dsmr-mcp-watchdog-fixtures-first :use '(#:cl)))
  "Scratch package run first. No system lists it.")

(defvar *second-package*
  (or (find-package '#:dsmr-mcp-watchdog-fixtures-second)
      (make-package '#:dsmr-mcp-watchdog-fixtures-second :use '(#:cl)))
  "Scratch package run second. No system lists it.")

(defun install-fixture (package name thunk)
  "Install a zebra test NAME in PACKAGE whose body calls THUNK."
  (setf (find-test name package)
        (make-instance 'test :name name :home package :tests (list thunk))))

(defun empty-fixture-packages ()
  (remove-all-tests-in-package *first-package*)
  (remove-all-tests-in-package *second-package*))

(defun qualified-name (package name)
  "NAME as zebra prints a test result: PACKAGE::NAME."
  (format nil "~A::~A" (package-name package) name))

(defun run-fixtures (builder &rest arguments)
  "Empty both scratch packages, call BUILDER to install fixtures, and run both
packages through RUN-TEST-PACKAGES with ARGUMENTS and a string stream. Return
its three values, then the captured output and the elapsed seconds."
  (empty-fixture-packages)
  (funcall builder)
  (unwind-protect
       (let ((stream (make-string-output-stream))
             (start (get-internal-real-time)))
         (multiple-value-bind (failed reports stopped)
             ;; A failing fixture makes zebra warn; that warning is the fixture
             ;; working.
             (handler-bind ((warning #'muffle-warning))
               (apply #'run-test-packages
                      (list (package-name *first-package*)
                            (package-name *second-package*))
                      :stream stream
                      arguments))
           (values failed reports stopped
                   (get-output-stream-string stream)
                   (/ (- (get-internal-real-time) start)
                      internal-time-units-per-second))))
    (empty-fixture-packages)))

(defun fixture-result (reports qualified-name)
  "The test result named QUALIFIED-NAME in any of REPORTS, or NIL."
  (loop for report in reports
          thereis (find-if (lambda (result)
                             (and (typep result 'test-result)
                                  (string= qualified-name
                                           (format-result result :oneline))))
                           (results report))))

(defun output-lines (output)
  (uiop:split-string output :separator '(#\Newline)))

(defun failed-line-p (output qualified-name)
  "True when OUTPUT holds a result line for QUALIFIED-NAME marked failed."
  (let ((mark (zebra::status-character :failed)))
    (some (lambda (line)
            (and (search qualified-name line) (search mark line)))
          (output-lines output))))

(defun named-in-failures-p (output qualified-name)
  "True when QUALIFIED-NAME appears after the Failures heading of OUTPUT."
  (let ((heading (search ";; Failures:" output)))
    (and heading (search qualified-name output :start2 heading) t)))

;;; ------------------------------------------------------------------
;;; The setting

(define-test the-setting-parses-strictly
  (is = 600 *default-watchdog-seconds*)
  (is = 600 (parse-watchdog-seconds nil))
  (is = 600 (parse-watchdog-seconds ""))
  (is = 600 (parse-watchdog-seconds "   "))
  (false (parse-watchdog-seconds "0"))
  (false (parse-watchdog-seconds "0.0"))
  (is = 600 (parse-watchdog-seconds "600"))
  (is = 2.5 (parse-watchdog-seconds "2.5"))
  (is = 45 (parse-watchdog-seconds " 45 "))
  (dolist (bad '("abc" "-1" "+5" "1e3" "5s" "1.2.3" "0x10"))
    (let ((report (handler-case (progn (parse-watchdog-seconds bad) nil)
                    (error (condition) (princ-to-string condition)))))
      (true report "~S is not refused" bad)
      (true (and report (search "DSMR_TEST_WATCHDOG_SECONDS" report))
            "the refusal of ~S does not name the variable" bad)
      (true (and report (search bad report))
            "the refusal of ~S does not name the value" bad))))

;;; ------------------------------------------------------------------
;;; Stop, fail, continue

(define-test a-stopped-test-fails-by-name-and-the-run-continues
  (let* ((started nil)
         (cleaned nil)
         (slow (qualified-name *first-package* "slow-fixture"))
         (sibling (qualified-name *first-package* "fast-sibling"))
         (later (qualified-name *second-package* "fast-later-package")))
    (multiple-value-bind (failed reports stopped output elapsed)
        (run-fixtures
         (lambda ()
           (install-fixture *first-package* "slow-fixture"
                            (lambda ()
                              (setf started t)
                              (unwind-protect
                                   (handler-case (sleep 30)
                                     (serious-condition () (true t)))
                                (setf cleaned t))))
           (install-fixture *first-package* "fast-sibling" (lambda () (true t)))
           (install-fixture *second-package* "fast-later-package"
                            (lambda () (true t))))
         :seconds 0.5)
      (true failed)
      (true started)
      (is equal (list slow) stopped)
      (let ((result (fixture-result reports slow)))
        (true result "no result for the stopped fixture")
        (when result
          (is eq :failed (status result))
          (let ((description (or (description result) "")))
            (true (search slow description))
            (true (search "0.5" description))
            (true (search "DSMR_TEST_WATCHDOG_SECONDS" description)))))
      (is eq :passed (status (fixture-result reports sibling)))
      (is eq :passed (status (fixture-result reports later)))
      (true cleaned "the stopped fixture's cleanup did not run")
      (true (< elapsed 10) "the run took ~,1F s" elapsed)
      (true (failed-line-p output slow))
      (true (named-in-failures-p output slow)))))

(define-test a-test-under-its-bound-passes-untouched
  (let ((name (qualified-name *first-package* "under-bound")))
    (multiple-value-bind (failed reports stopped output)
        (run-fixtures
         (lambda ()
           (install-fixture *first-package* "under-bound"
                            (lambda () (sleep 0.1) (true t))))
         :seconds 5)
      (false failed)
      (is eq :passed (status (fixture-result reports name)))
      (is equal '() stopped)
      (false (search "did not finish within" output))
      (false (search "per-test bound diagnostics" output)))))

(define-test no-bound-when-the-bound-is-off
  (let ((name (qualified-name *first-package* "unbounded")))
    (multiple-value-bind (failed reports stopped output)
        (run-fixtures
         (lambda ()
           (install-fixture *first-package* "unbounded"
                            (lambda () (sleep 1) (true t))))
         :seconds nil)
      (false failed)
      (is equal '() stopped)
      (is eq :passed (status (fixture-result reports name)))
      (true (search "Per-test bound: off" (first (output-lines output)))))))

;;; ------------------------------------------------------------------
;;; Diagnostics helpers

(defun proc-available-p ()
  "True when this host has a /proc to read."
  (and (probe-file "/proc/self/stat") t))

(defun block-until-stopped ()
  "Sleep 30 s. The call to SLEEP is not in tail position, so this frame stays on
the stack while it blocks."
  (declare (notinline sleep))
  (sleep 30)
  (values))

(defun start-helper-thread (name)
  "Start a thread NAME that waits up to 60 s on a fresh semaphore. Return the
thread and the semaphore that releases it."
  (let ((release (sb-thread:make-semaphore :name name)))
    (values (sb-thread:make-thread
             (lambda () (sb-thread:wait-on-semaphore release :timeout 60))
             :name name)
            release)))

(defun release-helper-thread (thread release)
  "Release THREAD through RELEASE and wait up to 5 s for it to exit."
  (sb-thread:signal-semaphore release)
  (sb-thread:join-thread thread :default nil :timeout 5))

(defun start-sleeping-child ()
  "Start a child process running sleep 300 and return its process info."
  (uiop:launch-program '("sleep" "300")))

(defun stop-child (child)
  "Stop CHILD, a process this file started, by its own pid, and reap it."
  (ignore-errors (sb-posix:kill (uiop:process-info-pid child) sb-posix:sigterm))
  (ignore-errors (uiop:wait-process child)))

(defun lock-scratch-file (directory)
  "Take a POSIX write lock on a file in DIRECTORY and return its descriptor."
  (let ((fd (sb-posix:open (format nil "~Alock" directory)
                           (logior sb-posix:o-rdwr sb-posix:o-creat)
                           #o600)))
    (sb-posix:fcntl fd sb-posix:f-setlk
                    (make-instance 'sb-posix:flock
                                   :type sb-posix:f-wrlck
                                   :whence sb-posix:seek-set
                                   :start 0
                                   :len 0))
    fd))

(defun stop-block (output qualified-name)
  "The text of OUTPUT from the first mention of QUALIFIED-NAME, its start line,
to its last mention before the summary, its result line."
  (let* ((start (or (search qualified-name output) 0))
         (summary (or (search ";; Summary:" output) (length output)))
         (end (or (search qualified-name output :from-end t :end2 summary)
                  summary)))
    (subseq output start (max start end))))

(defun split-at-unwind (block)
  "BLOCK split at its after-the-unwind heading: the part before it, and the part
from it to the closing line."
  (let* ((mark (or (search ";; -- after the unwind" block) (length block)))
         (end (or (search ";; ==== end of" block :start2 mark) (length block))))
    (values (subseq block 0 mark) (subseq block mark end))))

(defun process-line (pid)
  "The text that opens PID's line in a process section."
  (format nil ";; pid ~D " pid))

;;; ------------------------------------------------------------------
;;; What a stop prints

(define-test a-stop-shows-what-the-test-was-doing
  (unless (proc-available-p)
    (skip "/proc is unavailable on this host"))
  (let ((name (qualified-name *first-package* "blocked-fixture"))
        (helper-name "watchdog-control-helper")
        (child-pid nil)
        (helper nil))
    (multiple-value-bind (failed reports stopped output)
        (run-fixtures
         (lambda ()
           (install-fixture
            *first-package* "blocked-fixture"
            (lambda ()
              (multiple-value-bind (thread release) (start-helper-thread helper-name)
                (setf helper thread)
                (let ((child (start-sleeping-child))
                      (directory (format nil "~A/" (sb-posix:mkdtemp "/tmp/dsmr-wd-control-XXXXXX")))
                      (fd nil))
                  (setf child-pid (uiop:process-info-pid child))
                  (unwind-protect
                       (progn
                         (setf fd (lock-scratch-file directory))
                         (block-until-stopped)
                         (true t))
                    (release-helper-thread thread release)
                    (stop-child child)
                    (when fd (sb-posix:close fd))
                    (uiop:delete-directory-tree (uiop:ensure-directory-pathname directory)
                                                :validate t)))))))
         :seconds 0.5)
      (declare (ignore reports))
      (true failed)
      (is equal (list name) stopped)
      (multiple-value-bind (before after) (split-at-unwind (stop-block output name))
        (true (search "BLOCK-UNTIL-STOPPED" before)
              "the stopped thread's backtrace does not show the blocking call")
        (true (search (format nil "thread ~S" helper-name) before)
              "the helper thread is not listed")
        (true (search "WAIT-ON-SEMAPHORE" before :start2 (or (search helper-name before) 0))
              "the helper thread has no backtrace")
        (true (and child-pid (search (process-line child-pid) before))
              "the child process is not listed")
        (true (search (format nil ";; lock ") before)
              "no /proc/locks line is listed")
        (true (some (lambda (line)
                      (and (search ";; lock " line)
                           (member (princ-to-string (sb-posix:getpid))
                                   (uiop:split-string line :separator " ")
                                   :test #'string=)))
                    (output-lines before))
              "no /proc/locks line holds this image's pid")
        (true (plusp (length after)) "no after-the-unwind section")
        (false (and child-pid (search (process-line child-pid) after)))
        (false (search helper-name after)))
      (false (and helper (sb-thread:thread-alive-p helper))))))

(define-test a-stop-lists-what-the-test-left-running
  (unless (proc-available-p)
    (skip "/proc is unavailable on this host"))
  (let ((name (qualified-name *first-package* "leaking-fixture"))
        (helper-name "watchdog-control-leaked-helper")
        (child nil)
        (helper nil)
        (release nil))
    (unwind-protect
         (multiple-value-bind (failed reports stopped output)
             (run-fixtures
              (lambda ()
                (install-fixture
                 *first-package* "leaking-fixture"
                 (lambda ()
                   (multiple-value-setq (helper release) (start-helper-thread helper-name))
                   (setf child (start-sleeping-child))
                   (block-until-stopped)
                   (true t))))
              :seconds 0.5)
           (declare (ignore reports failed))
           (is equal (list name) stopped)
           (multiple-value-bind (before after) (split-at-unwind (stop-block output name))
             (declare (ignore before))
             (true (and child (search (process-line (uiop:process-info-pid child)) after))
                   "the leaked child is not listed after the unwind")
             (true (search helper-name after)
                   "the leaked thread is not listed after the unwind")))
      (when child (stop-child child))
      (when helper (release-helper-thread helper release)))))

(define-test a-stuck-cleanup-is-abandoned
  (let ((stuck (qualified-name *first-package* "stuck-cleanup"))
        (later (qualified-name *second-package* "after-stuck-cleanup")))
    (multiple-value-bind (failed reports stopped output elapsed)
        (run-fixtures
         (lambda ()
           (install-fixture *first-package* "stuck-cleanup"
                            (lambda ()
                              (unwind-protect (sleep 30)
                                (sleep 30))))
           (install-fixture *second-package* "after-stuck-cleanup"
                            (lambda () (true t))))
         :seconds 0.3
         :grace-seconds 0.5)
      (true failed)
      (is equal (list stuck) stopped)
      (true (< elapsed 5) "the run took ~,1F s" elapsed)
      (true (search "cleanup did not finish within 0.5 s and was abandoned" output))
      (is eq :failed (status (fixture-result reports stuck)))
      (is eq :passed (status (fixture-result reports later))))))

(defun all-results (result)
  "RESULT and every result under it."
  (cons result
        (when (typep result 'parent-result)
          (loop for child across (results result)
                append (all-results child)))))

(define-test a-stop-leaves-no-result-unfinished
  (let ((name (qualified-name *first-package* "stopped-in-a-check")))
    (multiple-value-bind (failed reports stopped)
        (run-fixtures
         (lambda ()
           (install-fixture *first-package* "stopped-in-a-check"
                            (lambda () (is = 1 (progn (sleep 30) 1)))))
         :seconds 0.3)
      (true failed)
      (is equal (list name) stopped)
      (let ((everything (loop for report in reports append (all-results report)))
            (fixture (fixture-result reports name)))
        (false (find :tentative everything :key #'status))
        (true fixture)
        (when fixture
          (let ((check (find-if-not (lambda (result) (typep result 'test-result))
                                    (results fixture))))
            (true check "the check in flight has no result")
            (when check
              (is eq :failed (status check)))))))))

(define-test a-stop-never-reaches-a-finished-test
  (let ((control-errors '())
        (random-state (make-random-state t))
        (names '()))
    (multiple-value-bind (failed reports)
        (handler-bind ((control-error
                         (lambda (condition) (push condition control-errors))))
          (multiple-value-prog1
              (run-fixtures
               (lambda ()
                 (dotimes (index 40)
                   (let ((name (format nil "race-~2,'0D" index))
                         (seconds (+ 0.02 (random 0.06 random-state))))
                     (push (qualified-name *first-package* name) names)
                     (install-fixture *first-package* name
                                      (lambda () (sleep seconds) (true t))))))
               :seconds 0.05)
            (sleep 0.5)))
      (declare (ignore failed))
      (is equal '() control-errors)
      (dolist (name names)
        (let ((result (fixture-result reports name)))
          (true result "no result for ~A" name)
          (when result
            (true (or (eq :passed (status result))
                      (and (eq :failed (status result))
                           (search "did not finish within" (or (description result) ""))))
                  "~A ended ~S: ~A" name (status result) (description result))))))))

(define-test a-stop-without-proc-says-so
  (let ((name (qualified-name *first-package* "stopped-without-proc"))
        (saved *proc-directory*))
    ;; The diagnostics are built in the watchdog thread, which sees only the
    ;; global value, so a LET binding would not reach it.
    (setf *proc-directory* "/nonexistent-proc-for-watchdog-control/")
    (unwind-protect
         (multiple-value-bind (failed reports stopped output)
             (run-fixtures
              (lambda ()
                (install-fixture *first-package* "stopped-without-proc"
                                 (lambda () (sleep 30))))
              :seconds 0.3)
           (declare (ignore reports))
           (true failed)
           (is equal (list name) stopped)
           (true (search "/proc is unavailable" output)))
      (setf *proc-directory* saved))))
