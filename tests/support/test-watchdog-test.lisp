;;;; tests/support/test-watchdog-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Controls for the per-test watchdog: the setting's parser, a stop that fails
;;;; the named test and lets the run continue, and the under-bound and off cases.
;;;;
;;;; Fixtures are installed at run time into two scratch packages that no system
;;;; lists, so a fixture that fails on purpose never fails the real run. Both
;;;; packages are emptied before and after each use. Two packages fix the order
;;;; across packages; zebra gives no order within one.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import set.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/support/test-watchdog-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/support/test-watchdog-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/support/test-watchdog
                #:run-test-packages
                #:parse-watchdog-seconds
                #:*default-watchdog-seconds*))

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
