;;;; tests/support/test-watchdog.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; A per-test time limit for zebra runs. WATCHDOG-REPORT arms a watchdog thread
;;;; around each top-level test. A test still running when its bound passes is
;;;; stopped by a THROW delivered to its thread, recorded as failed in zebra's
;;;; result tree with a description naming the test and the bound, and the run
;;;; continues with the next test. The stop is never a signalled condition:
;;;; zebra counts an escaping SBCL timeout as a pass, and a handler in the test
;;;; could swallow a condition.
;;;;
;;;; RUN-TEST-PACKAGES runs a list of test packages under this report and is
;;;; what the integration test-op calls.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defpackage #:dsmr-mcp/tests/support/test-watchdog
  (:use #:cl)
  (:import-from #:zebra)
  (:local-nicknames (#:zb #:zebra))
  (:export #:watchdog-report
           #:run-test-packages
           #:parse-watchdog-seconds
           #:watchdog-seconds-from-environment
           #:*default-watchdog-seconds*
           #:*cleanup-grace-seconds*))

(in-package #:dsmr-mcp/tests/support/test-watchdog)

;;; ------------------------------------------------------------------
;;; The setting

(defparameter *default-watchdog-seconds* 600
  "Per-test bound in seconds when DSMR_TEST_WATCHDOG_SECONDS is unset or blank.
Several times the run time of the slowest integration test, so only a hang
reaches it.")

(defparameter *cleanup-grace-seconds* 60
  "Seconds a stopped test's cleanup may run before a second stop abandons it.")

(defun %refuse-watchdog-seconds (value)
  (error "DSMR_TEST_WATCHDOG_SECONDS is ~S, which is not a number of seconds. ~
          Set it to digits with an optional decimal point, or to 0 to turn the ~
          per-test bound off."
         value))

(defun parse-watchdog-seconds (value)
  "Return the per-test bound VALUE sets, in seconds, or NIL when the bound is off.
VALUE is the text of DSMR_TEST_WATCHDOG_SECONDS, or NIL.
- NIL, an empty string, or a blank one gives *DEFAULT-WATCHDOG-SECONDS*.
- Surrounding whitespace is ignored.
- ASCII digits with at most one decimal point give that many seconds as an
  exact rational; zero gives NIL.
- Anything else signals an ERROR naming the variable and VALUE.
VALUE never reaches the Lisp reader."
  (let ((text (and value
                   (string-trim '(#\Space #\Tab #\Newline #\Return #\Page)
                                value))))
    (when (or (null text) (zerop (length text)))
      (return-from parse-watchdog-seconds *default-watchdog-seconds*))
    (unless (and (every (lambda (char) (or (char<= #\0 char #\9) (char= char #\.)))
                        text)
                 (<= (count #\. text) 1)
                 (some (lambda (char) (char<= #\0 char #\9)) text))
      (%refuse-watchdog-seconds value))
    (let* ((point (position #\. text))
           (whole (subseq text 0 (or point (length text))))
           (fraction (if point (subseq text (1+ point)) ""))
           (seconds (+ (if (plusp (length whole)) (parse-integer whole) 0)
                       (if (plusp (length fraction))
                           (/ (parse-integer fraction)
                              (expt 10 (length fraction)))
                           0))))
      (if (zerop seconds) nil seconds))))

(defun watchdog-seconds-from-environment ()
  "Return PARSE-WATCHDOG-SECONDS of DSMR_TEST_WATCHDOG_SECONDS in this
process's environment."
  (parse-watchdog-seconds (uiop:getenv "DSMR_TEST_WATCHDOG_SECONDS")))

(defun %format-seconds (seconds)
  "SECONDS as text: an integer as is, any other real in decimal notation."
  (if (integerp seconds)
      (format nil "~D" seconds)
      (format nil "~F" seconds)))

;;; ------------------------------------------------------------------
;;; The report

(defclass watchdog-report (zb:plain)
  ((seconds :initarg :seconds :initform nil :reader watchdog-seconds
            :documentation "Per-test bound in seconds, or NIL for none.")
   (grace-seconds :initarg :grace-seconds :reader grace-seconds
                  :documentation "Seconds a stopped test's cleanup may run.")
   (stopped :initform '() :accessor stopped-tests
            :documentation "Names of the tests stopped at the bound, newest first."))
  (:default-initargs :grace-seconds *cleanup-grace-seconds*)
  (:documentation
   "A zebra PLAIN report that runs each top-level test under a per-test bound.
ZEBRA:TEST passes :SECONDS and :GRACE-SECONDS through to MAKE-INSTANCE."))

(defvar *armed-reports* '()
  "Watchdog reports with a watchdog armed in this thread's dynamic extent. A
child test runs under its parent's watchdog.")

(defstruct (%arming (:constructor %make-arming (name seconds grace)))
  "One armed watchdog. STATE is :RUNNING, :STOPPING, or :DONE, and is written
by the test thread except for the move to :STOPPING, which the stop function
makes in the test thread too."
  name
  seconds
  grace
  (state :running)
  (tag (list :test-watchdog))
  (thread sb-thread:*current-thread*)
  (finished (sb-thread:make-semaphore :name "test watchdog finished"))
  (watchdog nil))

(defun %stop-function (arming)
  "The function delivered to the test thread to stop it. It throws to the
arming's catch while the state is :RUNNING or :STOPPING and returns otherwise,
so a stop that arrives after the catch has exited does nothing."
  (lambda ()
    (when (member (%arming-state arming) '(:running :stopping))
      (setf (%arming-state arming) :stopping)
      (throw (%arming-tag arming) arming))))

(defun %deliver-stop (arming)
  "Interrupt the test thread with the stop function. Never signals."
  (handler-case
      (sb-thread:interrupt-thread (%arming-thread arming) (%stop-function arming))
    (error () nil)))

(defun %watch (arming)
  "Body of the watchdog thread: wait for the test to finish, and deliver the
stop when the bound passes first."
  (unless (sb-thread:wait-on-semaphore (%arming-finished arming)
                                       :timeout (float (%arming-seconds arming) 1d0))
    (when (eq (%arming-state arming) :running)
      (%deliver-stop arming))))

(defun %diagnostics (arming)
  "The block printed above a stopped test's result line."
  (with-output-to-string (out)
    (format out "~&;; ==== per-test bound: ~A did not finish within ~A s ====~%"
            (%arming-name arming) (%format-seconds (%arming-seconds arming)))
    (format out ";; ==== end of per-test bound diagnostics for ~A ====~%"
            (%arming-name arming))))

(defun %record-stop (report result arming)
  "Fail RESULT for a stop at the bound, print the diagnostics and its result
line, and add its name to REPORT's stopped tests."
  (let ((name (%arming-name arming))
        (out (zb:output report)))
    (setf (zb:status result) :failed
          (zb:description result)
          (format nil "~A did not finish within ~A s (DSMR_TEST_WATCHDOG_SECONDS); ~
                       see the diagnostics above its result line"
                  name (%format-seconds (%arming-seconds arming))))
    (write-string (%diagnostics arming) out)
    (force-output out)
    (zb:report-on result report)
    (push name (stopped-tests report))))

(defun %run-armed (report result next)
  "Call NEXT, the rest of the method chain for RESULT, under a watchdog.
Interrupts stay deferred except while NEXT runs, so the state reaches :DONE
before any stop can arrive after the catch."
  (let* ((arming (%make-arming (zb:format-result result :oneline)
                               (watchdog-seconds report)
                               (grace-seconds report)))
         (outcome nil))
    (sb-sys:without-interrupts
      (setf outcome
            (catch (%arming-tag arming)
              (setf (%arming-watchdog arming)
                    (sb-thread:make-thread
                     #'%watch
                     :name (format nil "test watchdog: ~A" (%arming-name arming))
                     :arguments (list arming)))
              (multiple-value-list
               (sb-sys:with-local-interrupts (funcall next)))))
      (setf (%arming-state arming) :done))
    (sb-thread:signal-semaphore (%arming-finished arming))
    (when (%arming-watchdog arming)
      (sb-thread:join-thread (%arming-watchdog arming) :default nil :timeout 30))
    (cond ((eq outcome arming)
           (%record-stop report result arming)
           nil)
          (t (values-list outcome)))))

(defmethod zb:eval-in-context :around ((report watchdog-report) (result zb:test-result))
  "Run RESULT under REPORT's per-test bound unless the bound is off or a
watchdog of REPORT is already armed in this thread."
  (if (and (watchdog-seconds report)
           (eq (zb:status result) :unknown)
           (not (member report *armed-reports*)))
      (let ((*armed-reports* (cons report *armed-reports*)))
        (%run-armed report result (lambda () (call-next-method))))
      (call-next-method)))

;;; ------------------------------------------------------------------
;;; The runner

(defun run-test-packages (names &key (seconds (watchdog-seconds-from-environment))
                                     (grace-seconds *cleanup-grace-seconds*)
                                     (stream *standard-output*))
  "Run the zebra tests of each package in NAMES, in order, under WATCHDOG-REPORT.
SECONDS is the per-test bound, NIL for none; GRACE-SECONDS bounds a stopped
test's cleanup; STREAM receives the output, whose first line states the bound.
Signal an ERROR when a package is not loaded. Return three values: true when
any test failed, the reports in run order, and the names of the stopped tests
in run order."
  (format stream "~&Per-test bound: ~:[off (DSMR_TEST_WATCHDOG_SECONDS=0)~;~:*~A s ~
                  (DSMR_TEST_WATCHDOG_SECONDS)~]~%"
          (and seconds (%format-seconds seconds)))
  (let ((zb:*parent* nil)
        (zb:*context* nil)
        (failed nil)
        (reports '()))
    (dolist (name names)
      (let* ((package (or (find-package (string-upcase name))
                          (error "Test package ~S not loaded." name)))
             (report (zb:test package :report 'watchdog-report
                                      :seconds seconds
                                      :grace-seconds grace-seconds
                                      :stream stream)))
        (push report reports)
        (when (zb:results-with-status :failed report)
          (setf failed t))))
    (setf reports (nreverse reports))
    (values failed
            reports
            (loop for report in reports
                  append (reverse (stopped-tests report))))))
