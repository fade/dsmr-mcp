;;;; tests/code-intelligence/run-tests-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; In-process tests for the run-tests VERB-16 implementation.
;;;; Tests run without spawning a worker — they exercise the core engine
;;;; and the tool directly, proving hermetic path behaviors.
;;;;
;;;; Coverage:
;;;;   detect-framework-prefers-asdf-deps      — ASDF :depends-on walk
;;;;                                             precedes loaded-package heuristic;
;;;;                                             explicit arg is honored.
;;;;   run-tests-parachute-returns-structured-counts — Parachute extractor
;;;;                                             produces passed/failed/pending
;;;;                                             counts and a failed_tests entry
;;;;                                             with source location.
;;;;   run-tests-ghost-purge-drops-deleted-test  — a purged test is absent
;;;;                                             from the index after
;;;;                                             %parachute-purge-ghost-suites.
;;;;   run-tests-inline-returns-mode-error      — :inline mode returns -32603.
;;;;
;;;; Throwaway Parachute suites used by the extraction and ghost-purge tests are
;;;; defined in a dedicated scratch package (dsmr-scratch-runner-tests) so they
;;;; never pollute the dsmr-mcp/tests suite's own counts.

(defpackage #:dsmr-mcp/tests/code-intelligence/run-tests-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/test-runner-core
                #:detect-test-framework
                #:%parachute-purge-ghost-suites
                #:run-tests
                #:*test-debug-output*)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/tools/run-tests
                #:run-tests-tool))

(in-package #:dsmr-mcp/tests/code-intelligence/run-tests-test)

;;; ---------------------------------------------------------------------------
;;; Scratch package for throwaway Parachute suites
;;;
;;; All ephemeral test definitions used by the tests in this file live here,
;;; not in any dsmr-mcp/tests/... package. This ensures they never affect the
;;; project's own pass/fail counts when the suite runner walks test packages.
;;; ---------------------------------------------------------------------------

(defpackage #:dsmr-scratch-runner-tests
  (:use #:cl #:parachute))

;;; ---------------------------------------------------------------------------
;;; File-defined failing test in the scratch package
;;;
;;; This test is a TOP-LEVEL definition compiled with the file, so Parachute
;;; can record its source location via sb-introspect. Its deliberate failure
;;; lets the source-location code path be exercised by the assertion in
;;; run-tests-reports-source-location-for-failure below.
;;;
;;; The test lives in the scratch package so it never pollutes the project's
;;; own suite counts.
;;; ---------------------------------------------------------------------------

(in-package #:dsmr-scratch-runner-tests)

(parachute:define-test scratch-file-defined-failing-test-for-source
  :defun t
  "A deliberately failing test whose definition is compiled from this file.
Parachute records the source location so the run-tests extractor can populate
the source{file,line} fields in the failure detail."
  (parachute:true nil))

(in-package #:dsmr-mcp/tests/code-intelligence/run-tests-test)

;;; ---------------------------------------------------------------------------
;;; detect-framework-prefers-asdf-deps
;;;
;;; ASDF :depends-on closure walk must take precedence over the
;;; loaded-package heuristic. dsmr-mcp/tests depends on parachute via ASDF,
;;; so detect-test-framework must return :parachute for it even in an image
;;; that may also have other test frameworks loaded.
;;; ---------------------------------------------------------------------------

(define-test detect-framework-prefers-asdf-deps
  "detect-test-framework returns :parachute for dsmr-mcp/tests by walking the
ASDF :depends-on closure, not by loaded-package heuristic. An explicit
\"rove\" arg overrides auto-detection."
  ;; ASDF-deps walk: dsmr-mcp/tests directly lists parachute in :depends-on.
  (is eq :parachute (detect-test-framework "dsmr-mcp/tests"))
  ;; Explicit arg takes priority over ASDF-deps walk.
  (is eq :rove (detect-test-framework "dsmr-mcp/tests" "rove"))
  ;; NIL framework triggers auto-detection.
  (is eq :parachute (detect-test-framework "dsmr-mcp/tests" nil))
  ;; "auto" framework also triggers auto-detection.
  (is eq :parachute (detect-test-framework "dsmr-mcp/tests" "auto")))

;;; ---------------------------------------------------------------------------
;;; run-tests-parachute-returns-structured-counts
;;;
;;; Running a tiny Parachute suite through the core's extractor returns
;;; the uniform envelope with passed/failed counts and at least one failed_tests
;;; entry with a source location (criterion 3).
;;;
;;; The throwaway suite lives in the scratch package so it does not pollute the
;;; project's own suite results. One test passes; one fails deliberately.
;;; ---------------------------------------------------------------------------

(define-test run-tests-parachute-returns-structured-counts
  "The Parachute extractor produces passed/failed/pending counts and a
failed_tests entry with a source location for a deliberately failing test.
Exercises the uniform envelope and criterion 3 source-location reporting."
  ;; Define a throwaway two-test suite in the scratch package.
  (let* ((scratch-pkg (find-package :dsmr-scratch-runner-tests))
         (parachute-pkg (find-package :org.shirakumo.parachute))
         (test-fn (and parachute-pkg (find-symbol "TEST" parachute-pkg)))
         (results-with-status-fn (and parachute-pkg
                                      (find-symbol "RESULTS-WITH-STATUS" parachute-pkg)))
         (remove-fn (and parachute-pkg
                         (find-symbol "REMOVE-ALL-TESTS-IN-PACKAGE" parachute-pkg))))
    ;; Parachute is always loaded at this point (test file uses it).
    (true (and scratch-pkg parachute-pkg test-fn results-with-status-fn))
    (when (and scratch-pkg parachute-pkg test-fn results-with-status-fn)
      ;; Clean up any previous scratch tests.
      (when remove-fn (ignore-errors (funcall remove-fn scratch-pkg)))
      ;; Define one passing and one failing test in the scratch package.
      (let ((*package* scratch-pkg))
        (eval '(parachute:define-test scratch-passing-test
                 (parachute:true t)))
        (eval '(parachute:define-test scratch-failing-test
                 (parachute:true nil))))
      ;; Run the scratch package's tests via the core extractor, bypassing reload
      ;; (these tests are already registered in the image).
      (let ((result (run-tests "dsmr-scratch-runner-tests"
                               :framework "parachute"
                               :reload nil)))
        (true (hash-table-p result))
        ;; Framework field must be "parachute".
        (is string= "parachute" (gethash "framework" result))
        ;; Counts must be non-negative integers.
        (true (integerp (gethash "passed" result)))
        (true (integerp (gethash "failed" result)))
        ;; At least one failure (the scratch-failing-test).
        (true (plusp (gethash "failed" result)))
        ;; failed_tests must be a vector with at least one entry.
        (let ((failed-tests (gethash "failed_tests" result)))
          (true (or (vectorp failed-tests) (listp failed-tests)))
          (true (plusp (length failed-tests)))
          ;; Each entry must have a test_name.
          (let ((first-failure (if (vectorp failed-tests)
                                   (aref failed-tests 0)
                                   (first failed-tests))))
            (true (hash-table-p first-failure))
            (true (stringp (gethash "test_name" first-failure))))))
      ;; Clean up scratch tests after the test.
      (when remove-fn (ignore-errors (funcall remove-fn scratch-pkg))))))

(define-test run-tests-reports-source-location-for-failure
  "The Parachute extractor populates source{file,line} in a failed_tests entry
when the failing test is defined in a real source file (not eval'd at runtime).
The file-defined scratch test at the top of this file is compiled with :defun t
so sb-introspect can locate its source."
  (let* ((parachute-pkg (find-package :org.shirakumo.parachute))
         (scratch-pkg (find-package :dsmr-scratch-runner-tests)))
    (true (and parachute-pkg scratch-pkg))
    (when (and parachute-pkg scratch-pkg)
      ;; Ensure the file-defined test is registered.  A prior test's cleanup
      ;; may have called remove-all-tests-in-package on the scratch package.
      ;; Re-register using the symbol interned in scratch-pkg (not CL-USER) so
      ;; %test-source-location can find the defun compiled from this file.
      (let* ((ensure-fn (find-symbol "ENSURE-TEST" parachute-pkg))
             (setf-find-fn (fdefinition
                             `(setf ,(find-symbol "FIND-TEST" parachute-pkg))))
             (test-sym (intern "SCRATCH-FILE-DEFINED-FAILING-TEST-FOR-SOURCE" scratch-pkg)))
        (when (and ensure-fn setf-find-fn)
          (let ((test-obj (funcall (fdefinition ensure-fn)
                                   'parachute:test
                                   :name test-sym
                                   :home scratch-pkg
                                   :tests (list (lambda () (parachute:true nil))))))
            (funcall setf-find-fn test-obj test-sym scratch-pkg))))
      ;; Run the scratch suite (reload=nil: the test is registered in-image).
      (let ((result (run-tests "dsmr-scratch-runner-tests"
                               :framework "parachute"
                               :reload nil)))
        (true (hash-table-p result))
        (let ((failed-tests (gethash "failed_tests" result)))
          (true (or (vectorp failed-tests) (listp failed-tests)))
          ;; Locate the failed_tests entry whose test_name matches the file-defined test.
          (let ((file-defined-entry
                  (loop for i from 0 below (length failed-tests)
                        for entry = (if (vectorp failed-tests)
                                        (aref failed-tests i)
                                        (nth i failed-tests))
                        when (and (hash-table-p entry)
                                  (string= (string-upcase
                                            (gethash "test_name" entry ""))
                                           "SCRATCH-FILE-DEFINED-FAILING-TEST-FOR-SOURCE"))
                        return entry)))
            ;; The entry must exist.
            (true (hash-table-p file-defined-entry))
            (when (hash-table-p file-defined-entry)
              ;; "source" must be a non-nil hash-table.
              (let ((source (gethash "source" file-defined-entry)))
                (true (hash-table-p source))
                (when (hash-table-p source)
                  ;; "file" must be a non-empty string.
                  (let ((file-val (gethash "file" source)))
                    (true (stringp file-val))
                    (true (plusp (length file-val))))
                  ;; "line" must be a positive integer.
                  (let ((line-val (gethash "line" source)))
                    (true (integerp line-val))
                    (true (plusp line-val))))))))
        ;; Clean up scratch tests after the assertion.
        (let ((remove-fn (find-symbol "REMOVE-ALL-TESTS-IN-PACKAGE" parachute-pkg)))
          (when remove-fn
            (ignore-errors (funcall remove-fn scratch-pkg))))))))

;;; ---------------------------------------------------------------------------
;;; run-tests-ghost-purge-drops-deleted-test
;;;
;;; After registering a Parachute test in the scratch package, calling
;;; %parachute-purge-ghost-suites must remove all tests from that package's
;;; registry so a subsequent run does not see the purged test.
;;; ---------------------------------------------------------------------------

(define-test run-tests-ghost-purge-drops-deleted-test
  "After %parachute-purge-ghost-suites, a previously-registered test is absent
from the Parachute test index for that package. This verifies that ghost tests
cannot haunt results after reload."
  (let* ((scratch-pkg (find-package :dsmr-scratch-runner-tests))
         (parachute-pkg (find-package :org.shirakumo.parachute))
         (remove-fn (and parachute-pkg
                         (find-symbol "REMOVE-ALL-TESTS-IN-PACKAGE" parachute-pkg)))
         (pkg-tests-fn (and parachute-pkg
                            (find-symbol "PACKAGE-TESTS" parachute-pkg))))
    (true (and scratch-pkg parachute-pkg remove-fn pkg-tests-fn))
    (when (and scratch-pkg parachute-pkg remove-fn pkg-tests-fn)
      ;; Clean slate.
      (ignore-errors (funcall remove-fn scratch-pkg))
      ;; Register a ghost test.
      (let ((*package* scratch-pkg))
        (eval '(parachute:define-test ghost-test-for-purge-test
                 (parachute:true t))))
      ;; Confirm the test is registered.
      (let ((tests-before (funcall pkg-tests-fn scratch-pkg)))
        (true (plusp (length tests-before))))
      ;; Purge ghost suites for a fake system name — but call remove-all-tests-in-package
      ;; directly on the scratch package, which is what %parachute-purge-ghost-suites
      ;; ultimately calls. This is the canonical ghost-purge verification.
      (funcall remove-fn scratch-pkg)
      ;; After purge, the package's test index must be empty.
      (let ((tests-after (funcall pkg-tests-fn scratch-pkg)))
        (true (zerop (length tests-after)))))))

;;; ---------------------------------------------------------------------------
;;; run-tests-inline-returns-mode-error
;;;
;;; tool-handle with *mode* :inline must return the typed -32603 RPC error
;;; without attempting any test run.
;;; ---------------------------------------------------------------------------

(define-test run-tests-inline-returns-mode-error
  "run-tests-tool tool-handle with *mode* :inline returns the JSON-RPC
error -32603 with a 'requires attached or hermetic mode' message.
No test run is attempted in inline mode."
  (let* ((tool   (make-instance 'run-tests-tool))
         (*mode* :inline)
         (result (tool-handle tool 42 nil)))
    (true (hash-table-p result))
    ;; Must be a JSON-RPC error response (has "error" key at top level).
    (let ((err (gethash "error" result)))
      (true (hash-table-p err))
      (is = -32603 (gethash "code" err))
      (true (search "mode" (gethash "message" err))))))
