;;;; tests/support/test-watchdog.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; A per-test time limit for zebra runs. WATCHDOG-REPORT arms a watchdog thread
;;;; around each top-level test. A test still running when its bound passes is
;;;; stopped by a THROW delivered to its thread, recorded as failed in zebra's
;;;; result tree with a description naming the test and the bound, and the run
;;;; continues with the next test. The stop is never a signalled condition:
;;;; zebra counts an escaping SBCL timeout as a pass, and a handler in the test
;;;; could swallow a condition. The stopped test's cleanups run; one still
;;;; running after the grace is abandoned by a second stop.
;;;;
;;;; Above the stopped test's result line the report prints the stopped
;;;; thread's backtrace, the threads the test started, this image's descendant
;;;; processes, and their /proc/locks lines, then what is still running after
;;;; the unwind. This module only reads /proc for this image and its
;;;; descendants: it starts no program, reads no process's environment, and
;;;; signals no process. Stopping what a test left running is that test's
;;;; cleanup's job, and a long-lived descendant such as a session pool worker
;;;; may serve later tests.
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

(defstruct (%arming (:constructor %make-arming (name seconds grace)))
  "One armed watchdog. STATE is :RUNNING, :STOPPING, or :DONE, and only the test
thread writes it. THREADS-BEFORE is the thread list at arming; SECTIONS and
BACKTRACE hold the diagnostics taken at the stop; ABANDONED is true once a
second stop was delivered to a stuck cleanup."
  name
  seconds
  grace
  (state :running)
  (tag (list :test-watchdog))
  (thread sb-thread:*current-thread*)
  (threads-before (sb-thread:list-all-threads))
  (finished (sb-thread:make-semaphore :name "test watchdog finished"))
  (watchdog nil)
  (sections nil)
  (backtrace nil)
  (abandoned nil))

(defparameter *proc-directory* "/proc/"
  "Directory the diagnostics read process and lock state from. The watchdog
thread reads the global value.")

;;; ------------------------------------------------------------------
;;; Diagnostics. Every reader here returns NIL or prints a note rather than
;;; signalling.

(defun %backtrace-string ()
  "The current thread's backtrace, at most 60 frames, as a string."
  (with-output-to-string (out)
    (ignore-errors (sb-debug:print-backtrace :stream out :count 60))))

(defun %proc-text (pid file)
  "The text of FILE under PID's /proc directory, read byte for byte, or NIL when
it cannot be read. PID may be a pid or a string such as \"self\"."
  (ignore-errors
   (uiop:read-file-string (format nil "~A~A/~A" *proc-directory* pid file)
                          :external-format :latin-1)))

(defun %proc-available-p ()
  "True when *PROC-DIRECTORY* holds this process's stat file."
  (and (ignore-errors (probe-file (format nil "~Aself/stat" *proc-directory*))) t))

(defun %stat (pid)
  "Return PID's parent pid and state letter from its stat file, or NIL."
  (let* ((stat (%proc-text pid "stat"))
         (close (and stat (position #\) stat :from-end t)))
         (fields (and close
                      (remove "" (uiop:split-string (subseq stat (1+ close))
                                                    :separator " ")
                              :test #'string=))))
    (when (>= (length fields) 2)
      (values (parse-integer (second fields) :junk-allowed t)
              (first fields)))))

(defun %descendants ()
  "This image's descendant processes as a list of (PID . PARENT-PID), found by
walking parent pids outward from this image's pid, sorted by pid."
  (let* ((parents
           (loop for directory in (ignore-errors
                                   (uiop:subdirectories *proc-directory*))
                 for name = (car (last (pathname-directory directory)))
                 for pid = (and (stringp name) (plusp (length name))
                                (every (lambda (char) (char<= #\0 char #\9)) name)
                                (parse-integer name))
                 for parent = (and pid (%stat pid))
                 when parent collect (cons pid parent)))
         (found (list (sb-posix:getpid)))
         (descendants '()))
    (loop for grew = nil
          do (dolist (entry parents)
               (when (and (member (cdr entry) found)
                          (not (member (car entry) found)))
                 (push (car entry) found)
                 (push entry descendants)
                 (setf grew t)))
          while grew)
    (sort descendants #'< :key #'car)))

(defun %write-processes (out heading descendants)
  "Write HEADING and one line for each of DESCENDANTS, as %DESCENDANTS returns
them, to OUT: pid, parent pid, state letter, wait channel, and the command line
on one line, cut at 160 characters."
  (format out ";; -- ~A (this image is pid ~D)~%" heading (sb-posix:getpid))
  (cond ((not (%proc-available-p))
         (format out ";; /proc is unavailable: no process listing~%"))
        ((null descendants)
         (format out ";; none~%"))
        (t
         (dolist (entry descendants)
           (let* ((pid (car entry))
                  (letter (nth-value 1 (%stat pid)))
                  (wchan (%proc-text pid "wchan"))
                  ;; NULs separate arguments; other control characters inside
                  ;; an argument would break the one-line-per-process layout.
                  (command (substitute-if #\Space
                                          (lambda (char) (< (char-code char) 32))
                                          (string-right-trim
                                           (string (code-char 0))
                                           (or (%proc-text pid "cmdline") "")))))
             (format out ";; pid ~D ppid ~D state ~A wchan ~A: ~A~%"
                     pid (cdr entry) (or letter "gone")
                     (if (plusp (length wchan)) wchan "-")
                     (subseq command 0 (min 160 (length command)))))))))

(defun %write-locks (out descendants)
  "Write every /proc/locks line whose pid field is this image or one of
DESCENDANTS to OUT."
  (format out ";; -- /proc/locks lines naming this image or a descendant~%")
  (if (not (%proc-available-p))
      (format out ";; /proc is unavailable: no lock listing~%")
      (let ((pids (mapcar #'princ-to-string
                          (cons (sb-posix:getpid) (mapcar #'car descendants))))
            (any nil))
        (dolist (line (ignore-errors
                       (uiop:read-file-lines
                        (format nil "~Alocks" *proc-directory*))))
          ;; Fields: ID: [->] CLASS MODE ACCESS PID DEVICE:INODE START END
          (let ((fields (remove "->" (remove "" (uiop:split-string
                                                  line :separator '(#\Space #\Tab))
                                             :test #'string=)
                                :test #'string=)))
            (when (and (> (length fields) 4)
                       (member (nth 4 fields) pids :test #'string=))
              (setf any t)
              (format out ";; lock ~A~%" line))))
        (unless any
          (format out ";; none~%")))))

(defun %ask-backtrace (thread)
  "THREAD's backtrace as a string, taken by an interrupt that only prints into a
string, or NIL when THREAD does not answer within 2 s."
  (let ((box (list nil))
        (answered (sb-thread:make-semaphore :name "test watchdog backtrace")))
    (handler-case
        (sb-thread:interrupt-thread thread
                                    (lambda ()
                                      (setf (car box) (%backtrace-string))
                                      (sb-thread:signal-semaphore answered)))
      (error () (return-from %ask-backtrace nil)))
    (and (sb-thread:wait-on-semaphore answered :timeout 2)
         (car box))))

(defun %started-threads (arming)
  "Live threads absent from ARMING's thread list at arming, other than its
watchdog thread and the calling thread."
  (remove-if (lambda (thread)
               (or (member thread (%arming-threads-before arming))
                   (eq thread (%arming-watchdog arming))
                   (eq thread sb-thread:*current-thread*)
                   (not (sb-thread:thread-alive-p thread))))
             (sb-thread:list-all-threads)))

(defun %state-sections (arming)
  "The sections the watchdog thread records before the stop: each thread the
test started with its backtrace, the threads that predate the test by name,
this image's descendant processes, and their locks. Threads that predate the
test are never interrupted, since an interrupt can disturb a blocking call in
machinery that later tests rely on."
  (with-output-to-string (out)
    (format out ";; -- threads the test started~%")
    (let ((started (%started-threads arming)))
      (if (null started)
          (format out ";; none~%")
          (dolist (thread started)
            (format out ";; thread ~S:~%" (sb-thread:thread-name thread))
            (let ((backtrace (%ask-backtrace thread)))
              (if backtrace
                  (write-string backtrace out)
                  (format out ";; no backtrace: the thread did not answer within 2 s~%"))))))
    (format out ";; -- threads that existed before the test, not interrupted: ~
                ~:[none~;~:*~{~S~^, ~}~]~%"
            (loop for thread in (%arming-threads-before arming)
                  when (and (sb-thread:thread-alive-p thread)
                            (not (eq thread (%arming-thread arming))))
                    collect (sb-thread:thread-name thread)))
    (let ((descendants (%descendants)))
      (%write-processes out "descendant processes" descendants)
      (%write-locks out descendants))))

(defun %after-unwind-sections (arming)
  "The sections the test thread records once the stop has unwound: the
descendant processes still running and the threads the test started that are
still alive. Nothing listed here is signalled."
  (with-output-to-string (out)
    (%write-processes out "after the unwind: descendant processes still running"
                      (%descendants))
    (format out ";; -- after the unwind: threads the test started that are still alive~%")
    (let ((started (%started-threads arming)))
      (if (null started)
          (format out ";; none~%")
          (dolist (thread started)
            (format out ";; thread ~S~%" (sb-thread:thread-name thread)))))))

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

(defun %stop-function (arming)
  "The function delivered to the test thread to stop it. While the state is
:RUNNING or :STOPPING it sets :STOPPING, captures the test thread's backtrace on
the first stop, and throws to the arming's catch. Otherwise it returns, so a
stop that arrives after the catch has exited does nothing."
  (lambda ()
    (let ((state (%arming-state arming)))
      (when (member state '(:running :stopping))
        (setf (%arming-state arming) :stopping)
        (when (eq state :running)
          (setf (%arming-backtrace arming) (%backtrace-string)))
        (throw (%arming-tag arming) arming)))))

(defun %deliver-stop (arming)
  "Interrupt the test thread with the stop function. Never signals."
  (handler-case
      (sb-thread:interrupt-thread (%arming-thread arming) (%stop-function arming))
    (error () nil)))

(defun %watch (arming)
  "Body of the watchdog thread. Wait for the test to finish; when the bound
passes first, record the threads, processes, and locks, and deliver the stop.
When the stopped test has not reached its catch within the grace, deliver one
second stop to abandon its cleanup. No third stop follows: a thread blocked
with interrupts deferred is left to the outer time limit."
  (let ((finished (%arming-finished arming)))
    (unless (sb-thread:wait-on-semaphore
             finished :timeout (float (%arming-seconds arming) 1d0))
      (when (eq (%arming-state arming) :running)
        (setf (%arming-sections arming) (%state-sections arming))
        (when (eq (%arming-state arming) :running)
          (%deliver-stop arming)
          (unless (sb-thread:wait-on-semaphore
                   finished :timeout (float (%arming-grace arming) 1d0))
            (when (eq (%arming-state arming) :stopping)
              (setf (%arming-abandoned arming) t)
              (%deliver-stop arming))))))))

(defun %diagnostics (arming)
  "The block printed above a stopped test's result line: a header naming the
test and the bound, the stopped thread's backtrace, the sections recorded at the
stop, a note when the cleanup was abandoned, the after-the-unwind sections, and
a closing line."
  (let ((name (%arming-name arming)))
    (with-output-to-string (out)
      (format out "~&;; ==== per-test bound: ~A did not finish within ~A s ====~%"
              name (%format-seconds (%arming-seconds arming)))
      (format out ";; -- backtrace of the stopped thread~%~A"
              (or (%arming-backtrace arming) ";; none captured
"))
      (write-string (or (%arming-sections arming) "") out)
      (when (%arming-abandoned arming)
        (format out ";; -- cleanup did not finish within ~A s and was abandoned~%"
                (%format-seconds (%arming-grace arming))))
      (write-string (%after-unwind-sections arming) out)
      (format out ";; ==== end of per-test bound diagnostics for ~A ====~%" name))))

(defun %fail-unfinished (result)
  "Set to :FAILED every result under RESULT still :TENTATIVE, such as the check
that was running when the stop arrived."
  (loop for child across (zb:results result)
        do (when (eq (zb:status child) :tentative)
             (setf (zb:status child) :failed))
           (when (typep child 'zb:parent-result)
             (%fail-unfinished child))))

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
    (%fail-unfinished result)
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
