;;;; tests/bus/host-memory-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for how the host service reads memory pressure and chooses a
;;;; worker to relieve it: the parsing of /proc/pressure/memory and
;;;; /proc/meminfo, the classifier's entry, hysteresis and clearing, the
;;;; thresholds taken from the environment, and the order workers are offered
;;;; in. The readings and the clock are values the test hands in, so nothing
;;;; here depends on how much memory this host has or sleeps.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/bus/host-memory-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/bus/host-memory-test
  (:use #:cl #:zebra)
  (:local-nicknames (#:memory #:dsmr-bus-host/src/bus/host/memory))
  (:import-from #:sb-posix))

(in-package #:dsmr-mcp/tests/bus/host-memory-test)

;;; ------------------------------------------------------------------ fixtures

(defparameter *psi-sample*
  (format nil "some avg10=12.50 avg60=3.10 avg300=0.80 total=6542~%~
               full avg10=0.40 avg60=0.10 avg300=0.00 total=6431~%")
  "Two lines as /proc/pressure/memory writes them.")

(defparameter *meminfo-sample*
  (format nil "MemTotal:       65536000 kB~%~
               MemFree:         1024000 kB~%~
               MemAvailable:   20480000 kB~%~
               Buffers:          512000 kB~%~
               SwapCached:            0 kB~%~
               SwapTotal:       8388608 kB~%~
               SwapFree:        8000000 kB~%")
  "The lines of /proc/meminfo the service reads, with some it ignores.")

(defun readings (&key some full (total 1000) (available 500))
  "Readings with SOME and FULL as the PSI avg10 values and AVAILABLE out of
   TOTAL kilobytes free."
  (memory:make-memory-readings :some-avg10 some :full-avg10 full
                               :mem-total-kb total :mem-available-kb available
                               :swap-total-kb 0 :swap-free-kb 0))

(defun calm ()
  "Readings well inside the clearing thresholds: some 1, 25% available."
  (readings :some 1.0 :full 0.0 :available 250))

(defun run-classifier (state steps)
  "Feed STEPS, a list of (now readings), to the classifier from STATE and
   return the list of verdicts and the last state."
  (let ((verdicts '()))
    (loop for (now reading) in steps
          do (multiple-value-bind (verdict next)
                 (memory:classify-memory reading state now)
               (push verdict verdicts)
               (setf state next)))
    (values (nreverse verdicts) state)))

(defun under-pressure (since)
  "A state that entered pressure at SINCE."
  (memory:make-memory-state :verdict :pressure :since since))

(defun verdict-at (state steps now)
  "The verdict the classifier gives at NOW after STEPS from STATE."
  (multiple-value-bind (verdicts last) (run-classifier state steps)
    (declare (ignore verdicts))
    (values (memory:classify-memory (calm) last now))))

(defun getenv-from (alist)
  "A getenv function answering from ALIST of (name . value)."
  (lambda (name) (cdr (assoc name alist :test #'string=))))

(defun worker (id &rest keys &key (state :bound) (stateful nil) (busy nil)
                                  (spawned-at 10) (last-activity 100)
                                  refused-at &allow-other-keys)
  "A worker entry as a pool publishes it."
  (declare (ignore keys))
  (list :id id :pid (+ 1000 id) :state state :session (format nil "s~D" id)
        :stateful stateful :busy busy :spawned-at spawned-at
        :last-activity last-activity
        :refused-reason (and refused-at "refused") :refused-at refused-at
        :core-bytes nil))

(defun pool-record (server-pid &rest workers)
  "A pool's record for the server SERVER-PID, started at 77, listing WORKERS."
  (list :server-pid server-pid :server-start 77 :written-at 990
        :service-seen t :workers workers :last-action nil))

(defun pss-by-pid (alist)
  "A PSS reader answering from ALIST of (pid . kilobytes), 100 otherwise."
  (lambda (pid) (or (cdr (assoc pid alist)) 100)))

(defun always-alive (pid start)
  (declare (ignore pid start))
  t)

(defun rank (records &rest keys)
  "Rank RECORDS at NOW 1000 with every owner alive and the default PSS."
  (apply #'memory:rank-candidates records 1000
         (append keys (list :owner-alive-p #'always-alive
                            :pss-fn (pss-by-pid '())))))

(defun ranked-ids (candidates)
  (mapcar (lambda (c) (getf c :worker-id)) candidates))

;;; ------------------------------------------------------------------- parsing

(define-test psi-text-gives-the-some-and-full-ten-second-averages
  "The avg10 figure of each line is read; an empty text has neither."
  (multiple-value-bind (some full) (memory:parse-psi-text *psi-sample*)
    (is = 12.5 some)
    (is = 0.4 full))
  (multiple-value-bind (some full) (memory:parse-psi-text "")
    (is eq nil some)
    (is eq nil full)))

(define-test meminfo-text-gives-the-four-sizes-in-kilobytes
  "Total, available, swap total and swap free are read as integers."
  (let ((plist (memory:parse-meminfo-text *meminfo-sample*)))
    (is eql 65536000 (getf plist :mem-total-kb))
    (is eql 20480000 (getf plist :mem-available-kb))
    (is eql 8388608 (getf plist :swap-total-kb))
    (is eql 8000000 (getf plist :swap-free-kb))))

(define-test a-host-without-pressure-files-still-reads-its-memory
  "With no PSI file the pressure fields are empty and meminfo is still read,
   so the available-memory rule keeps working."
  (let ((r (memory:read-memory-readings :psi-path "/nonexistent/pressure")))
    (is eq nil (memory:memory-readings-some-avg10 r))
    (is eq nil (memory:memory-readings-full-avg10 r))
    (true (typep (memory:memory-readings-mem-total-kb r) '(integer 1)))
    (true (integerp (memory:memory-readings-mem-available-kb r)))
    (true (realp (memory:available-fraction r)))))

(define-test the-available-fraction-needs-both-sizes
  "Available over total, or nothing when either is missing or the total is 0."
  (is = 1/4 (rational (memory:available-fraction (readings :available 250))))
  (is eq nil (memory:available-fraction (readings :total nil)))
  (is eq nil (memory:available-fraction (readings :total 0)))
  (is eq nil (memory:available-fraction (readings :available nil))))

;;; ---------------------------------------------------------------- classifier

(define-test one-stall-reading-is-not-pressure-two-in-a-row-are
  "Some at 15 once leaves the verdict ok; a second reading in a row enters
   pressure."
  (is equal '(:ok :pressure)
      (run-classifier (memory:make-memory-state)
                      (list (list 0 (readings :some 15.0))
                            (list 1 (readings :some 15.0))))))

(define-test a-calm-reading-between-two-stalls-resets-the-count
  "Stall, calm, stall is three ok verdicts: the hits must be consecutive."
  (is equal '(:ok :ok :ok)
      (run-classifier (memory:make-memory-state)
                      (list (list 0 (readings :some 15.0))
                            (list 1 (readings :some 1.0))
                            (list 2 (readings :some 15.0))))))

(define-test a-full-stall-twice-enters-pressure
  "Full at 2.5 on two readings in a row is pressure."
  (is equal '(:ok :pressure)
      (run-classifier (memory:make-memory-state)
                      (list (list 0 (readings :some 0.0 :full 2.5))
                            (list 1 (readings :some 0.0 :full 2.5))))))

(define-test low-available-memory-enters-pressure-at-once
  "Available below 12% of total is pressure on the first reading."
  (is equal '(:pressure)
      (run-classifier (memory:make-memory-state)
                      (list (list 0 (readings :some 0.0 :available 110))))))

(define-test pressure-clears-only-after-thirty-seconds-of-calm
  "Calm from 10 still reads pressure at 39 and clears at 40."
  (let ((steps (loop for now from 10 to 38 collect (list now (calm)))))
    (is eq :pressure (verdict-at (under-pressure 0) steps 39))
    (is eq :ok (verdict-at (under-pressure 0)
                           (append steps (list (list 39 (calm))))
                           40))))

(define-test one-uncalm-reading-restarts-the-clearing-hold
  "Calm from 10, 15% available at 25, calm again from 26: still pressure at
   55, ok at 56."
  (let ((steps (append (loop for now from 10 to 24 collect (list now (calm)))
                       (list (list 25 (readings :some 1.0 :available 150)))
                       (loop for now from 26 to 54 collect (list now (calm))))))
    (is eq :pressure (verdict-at (under-pressure 0) steps 55))
    (is eq :ok (verdict-at (under-pressure 0)
                           (append steps (list (list 55 (calm))))
                           56))))

(define-test missing-pressure-figures-do-not-block-clearing
  "With no PSI figures and 25% available, pressure clears after 30 s."
  (let ((no-psi (readings :available 250)))
    (is equal '(:pressure :ok)
        (run-classifier (under-pressure 0)
                        (list (list 10 no-psi) (list 40 no-psi))))))

(define-test without-a-memory-total-the-available-rule-is-silent
  "No total means the available rule can neither enter pressure nor clear it."
  (let ((no-total (readings :some 0.0 :total nil :available 10)))
    (is equal '(:ok :ok :ok)
        (run-classifier (memory:make-memory-state)
                        (list (list 0 no-total) (list 1 no-total) (list 2 no-total))))
    (is equal '(:pressure :pressure :pressure)
        (run-classifier (under-pressure 0)
                        (list (list 10 no-total) (list 40 no-total)
                              (list 100 no-total))))))

(define-test the-classifier-leaves-its-state-argument-alone
  "Every slot of the state handed in reads the same after the call."
  (let ((state (memory:make-memory-state :verdict :ok :psi-hits 1)))
    (memory:classify-memory (readings :some 15.0) state 5)
    (is eq :ok (memory:memory-state-verdict state))
    (is = 1 (memory:memory-state-psi-hits state))
    (is eq nil (memory:memory-state-since state))
    (is eq nil (memory:memory-state-clear-since state)))
  (let ((state (under-pressure 0)))
    (memory:classify-memory (calm) state 5)
    (is eq :pressure (memory:memory-state-verdict state))
    (is eql 0 (memory:memory-state-since state))
    (is eq nil (memory:memory-state-clear-since state))))

;;; ---------------------------------------------------------------- thresholds

(define-test thresholds-default-when-the-environment-says-nothing
  "With nothing set, every threshold is its default and there is no warning."
  (multiple-value-bind (th warnings)
      (memory:thresholds-from-environment :getenv (getenv-from '()))
    (is = 10.0 (memory:memory-thresholds-enter-some th))
    (is = 2.0 (memory:memory-thresholds-enter-full th))
    (is = 0.12 (memory:memory-thresholds-enter-available th))
    (is = 3.0 (memory:memory-thresholds-leave-some th))
    (is = 0.20 (memory:memory-thresholds-leave-available th))
    (is = 30 (memory:memory-thresholds-hold-seconds th))
    (is = 10 (memory:memory-thresholds-min-kill-age-seconds th))
    (is eq nil warnings)))

(define-test thresholds-are-read-from-the-environment-with-percents-scaled
  "A stall threshold is taken as given; a percentage is divided by 100."
  (let ((th (memory:thresholds-from-environment
             :getenv (getenv-from '(("DSMR_PRESSURE_ENTER_SOME" . "20")
                                    ("DSMR_PRESSURE_ENTER_AVAILABLE_PERCENT" . "5"))))))
    (is = 20.0 (memory:memory-thresholds-enter-some th))
    (is = 0.05 (memory:memory-thresholds-enter-available th))))

(define-test a-bad-threshold-falls-back-to-its-default-with-a-named-warning
  "An unreadable value keeps the default and yields one warning naming the
   variable."
  (multiple-value-bind (th warnings)
      (memory:thresholds-from-environment
       :getenv (getenv-from '(("DSMR_PRESSURE_ENTER_SOME" . "x"))))
    (is = 10.0 (memory:memory-thresholds-enter-some th))
    (is = 1 (length warnings))
    (true (stringp (first warnings)))
    (true (search "DSMR_PRESSURE_ENTER_SOME" (first warnings)))))

(define-test the-minimum-kill-age-is-read-from-the-process-environment
  "DSMR_PRESSURE_MIN_KILL_AGE_SECONDS=3 in the real environment reads as 3."
  (let* ((name "DSMR_PRESSURE_MIN_KILL_AGE_SECONDS")
         (before (sb-posix:getenv name)))
    (unwind-protect
         (progn
           (sb-posix:setenv name "3" 1)
           (is = 3 (memory:memory-thresholds-min-kill-age-seconds
                    (memory:thresholds-from-environment))))
      (if before
          (sb-posix:setenv name before 1)
          (sb-posix:unsetenv name)))))

;;; ------------------------------------------------------------------- ranking

(define-test fresh-workers-go-first-then-stateful-by-age-with-larger-pss-first
  "A fresh idle worker is offered for stopping first; the two stateful idle
   workers follow for hibernation, the larger one first on a tie; the busy
   worker is never offered."
  (let* ((records (list (pool-record 11
                                     (worker 1 :last-activity 100)
                                     (worker 2 :stateful t :last-activity 50)
                                     (worker 3 :stateful t :last-activity 50)
                                     (worker 4 :stateful t :busy t :last-activity 1))))
         (ranked (memory:rank-candidates records 1000
                                         :owner-alive-p #'always-alive
                                         :pss-fn (pss-by-pid '((1003 . 900)
                                                               (1002 . 300))))))
    (is equal '(1 3 2) (ranked-ids ranked))
    (is equal '(:kill :hibernate :hibernate)
        (mapcar (lambda (c) (getf c :action)) ranked))
    (let ((first (first ranked)))
      (is string= "11-77" (getf first :stem))
      (is eql 1001 (getf first :pid))
      (is string= "s1" (getf first :session))
      (is eq nil (getf first :stateful))
      (is eql 100 (getf first :last-activity))
      (is eql 100 (getf first :pss-kb)))
    (is eql 900 (getf (second ranked) :pss-kb))))

(define-test hibernated-refused-and-requested-workers-are-not-offered
  "A hibernated or resuming worker, one refused 100 s ago and one with a
   request outstanding are left out; one refused 400 s ago is offered."
  (let ((ranked (rank (list (pool-record 11
                                         (worker 1 :stateful t :state :hibernated)
                                         (worker 2 :stateful t :state :resuming)
                                         (worker 3 :stateful t :refused-at 900)
                                         (worker 4 :stateful t)
                                         (worker 5 :stateful t :refused-at 600)))
                      :pending '(("11-77" . 4)))))
    (is equal '(5) (ranked-ids ranked))))

(define-test a-fresh-worker-is-not-stopped-before-its-minimum-age
  "A fresh worker spawned 5 s ago is left out by default and offered with a
   minimum age of 0; one with no spawn time is left out."
  (let ((young (list (pool-record 11 (worker 1 :spawned-at 995 :last-activity 995))))
        (unknown (list (pool-record 11 (worker 2 :spawned-at nil)))))
    (is equal '() (ranked-ids (rank young)))
    (is equal '(1) (ranked-ids (rank young :min-kill-age 0)))
    (is equal '() (ranked-ids (rank unknown)))))

(define-test a-worker-with-no-activity-is-ordered-by-its-spawn-time
  "No last activity and spawned at 30 orders as activity 30, ahead of a
   worker last active at 40."
  (let ((ranked (rank (list (pool-record 11
                                         (worker 1 :stateful t :last-activity 40)
                                         (worker 2 :stateful t :last-activity nil
                                                   :spawned-at 30))))))
    (is equal '(2 1) (ranked-ids ranked))))

(define-test the-workers-of-a-dead-server-are-not-offered
  "When the owner check says the server is gone, none of its workers are
   offered, and the live server's still are."
  (let ((ranked (memory:rank-candidates
                 (list (pool-record 11 (worker 1) (worker 2 :stateful t))
                       (pool-record 12 (worker 3 :stateful t)))
                 1000
                 :pss-fn (pss-by-pid '())
                 :owner-alive-p (lambda (pid start)
                                  (declare (ignore start))
                                  (/= pid 11)))))
    (is equal '(3) (ranked-ids ranked))))
