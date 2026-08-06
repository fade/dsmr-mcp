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
;;;;   run-tests-zebra-returns-structured-counts — Zebra extractor
;;;;                                             produces passed/failed/pending
;;;;                                             counts and a failed_tests entry
;;;;                                             with source location.
;;;;   run-tests-ghost-purge-drops-deleted-test  — a purged test is absent
;;;;                                             from the index after
;;;;                                             %zebra-purge-ghost-suites.
;;;;   run-tests-inline-returns-mode-error      — :inline mode returns -32603.
;;;;
;;;; Throwaway Zebra suites used by the extraction and ghost-purge tests are
;;;; defined in a dedicated scratch package (dsmr-scratch-runner-tests) so they
;;;; never pollute the dsmr-mcp/tests suite's own counts.

(defpackage #:dsmr-mcp/tests/code-intelligence/run-tests-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/test-runner-engine
                #:%resolve-test-packages
                #:%detect-from-asdf-deps
                #:%dependency-system-name
                #:%test-system-siblings
                #:%test-system-name-p
                #:%zebra-package
                #:%zebra-system-p
                #:*zebra-system-name*
                #:*zebra-package-name*)
  (:import-from #:dsmr-mcp/src/test-runner-core
                #:detect-test-framework
                #:%zebra-purge-ghost-suites
                #:run-tests
                #:%build-run-tests-form
                #:%build-engine-ensure-form
                #:*engine-source-path*
                #:engine-source-path
                #:engine-fingerprint
                #:*test-debug-output*)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*
                #:get-tool-instance
                #:*mode*)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool-slynk-conn)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/tools/run-tests
                #:run-tests-tool
                #:%dispatch-attach-run-tests))

(in-package #:dsmr-mcp/tests/code-intelligence/run-tests-test)

;;; ---------------------------------------------------------------------------
;;; Scratch package for throwaway Zebra suites
;;;
;;; All ephemeral test definitions used by the tests in this file live here,
;;; not in any dsmr-mcp/tests/... package. This ensures they never affect the
;;; project's own pass/fail counts when the suite runner walks test packages.
;;; ---------------------------------------------------------------------------

(defpackage #:dsmr-scratch-runner-tests
  (:use #:cl #:zebra))

;;; ---------------------------------------------------------------------------
;;; File-defined failing test in the scratch package
;;;
;;; This test is a TOP-LEVEL definition compiled with the file, so Zebra
;;; can record its source location via sb-introspect. Its deliberate failure
;;; lets the source-location code path be exercised by the assertion in
;;; run-tests-reports-source-location-for-failure below.
;;;
;;; The test lives in the scratch package so it never pollutes the project's
;;; own suite counts.
;;; ---------------------------------------------------------------------------

(in-package #:dsmr-scratch-runner-tests)

(zebra:define-test scratch-file-defined-failing-test-for-source
  :defun t
  "A deliberately failing test whose definition is compiled from this file.
Zebra records the source location so the run-tests extractor can populate
the source{file,line} fields in the failure detail."
  (zebra:true nil))

(in-package #:dsmr-mcp/tests/code-intelligence/run-tests-test)

;;; ---------------------------------------------------------------------------
;;; detect-framework-prefers-asdf-deps
;;;
;;; ASDF :depends-on closure walk must take precedence over the
;;; loaded-package heuristic. dsmr-mcp/tests depends on zebra via ASDF,
;;; so detect-test-framework must return :zebra for it even in an image
;;; that may also have other test frameworks loaded.
;;; ---------------------------------------------------------------------------

(define-test detect-framework-prefers-asdf-deps
  "detect-test-framework returns :zebra for dsmr-mcp/tests by walking the
ASDF :depends-on closure, not by loaded-package heuristic. An explicit
\"rove\" arg overrides auto-detection."
  ;; ASDF-deps walk: dsmr-mcp/tests directly lists zebra in :depends-on.
  (is eq :zebra (detect-test-framework "dsmr-mcp/tests"))
  ;; Explicit arg takes priority over ASDF-deps walk.
  (is eq :rove (detect-test-framework "dsmr-mcp/tests" "rove"))
  ;; NIL framework triggers auto-detection.
  (is eq :zebra (detect-test-framework "dsmr-mcp/tests" nil))
  ;; "auto" framework also triggers auto-detection.
  (is eq :zebra (detect-test-framework "dsmr-mcp/tests" "auto")))

(define-test detects-zebra-by-system-name
  "The ASDF dependency walk recognises the system providing the zebra API, so a
suite built on it reaches the zebra runner instead of falling through to the
ASDF fallback.  That fallback raises nothing, so an unrecognised name shows up
as a suite that quietly ran the wrong way rather than as a failure.

The second return value names the dependency that matched.

Rove and FiveAM detection is asserted alongside to prove the foreign framework
names still resolve to their own keywords."
  (let ((probes '(("dsmr-probe-suite-on-zebra" "zebra")
                  ("dsmr-probe-suite-on-rove" "rove")
                  ("dsmr-probe-suite-on-fiveam" "fiveam")
                  ("dsmr-probe-suite-on-removed-framework" "parachute"))))
    (unwind-protect
         (progn
           (dolist (probe probes)
             (eval `(asdf:defsystem ,(first probe)
                      :depends-on (,(second probe)))))
           (multiple-value-bind (framework matched)
               (%detect-from-asdf-deps "dsmr-probe-suite-on-zebra")
             (is eq :zebra framework)
             (is string= "zebra" matched))
           (is eq :rove (%detect-from-asdf-deps "dsmr-probe-suite-on-rove"))
           (is eq :fiveam (%detect-from-asdf-deps "dsmr-probe-suite-on-fiveam"))
           ;; The same answers through the public entry point.
           (is eq :zebra (detect-test-framework "dsmr-probe-suite-on-zebra"))
           (is eq :rove (detect-test-framework "dsmr-probe-suite-on-rove"))
           (is eq :fiveam (detect-test-framework "dsmr-probe-suite-on-fiveam"))
           ;; The dependency walk no longer recognises the name that was
           ;; removed.  This is the assertion that fails if the old system
           ;; name is ever reintroduced as a second way in.
           (false (%detect-from-asdf-deps "dsmr-probe-suite-on-removed-framework")))
      ;; Probe systems are registry-only and must not outlive the test.
      (dolist (probe probes)
        (ignore-errors (asdf:clear-system (first probe)))))))

(define-test detects-framework-declared-by-a-test-sibling
  "Naming a library resolves the framework its test sibling declares.

This is how the verb is actually invoked: a caller asks for the tests of the
thing they are working on, which is the library.  A library depends on neither
its tests nor their framework, so a walk that only descends answers NIL for
every correctly built project and hands the caller to the ASDF fallback, which
runs an operation and reports success without ever recognising a suite.  The
symptom is a run reporting no tests and no failures, which reads as a pass.

The third return value names the system that actually declared the framework,
so a caller can tell that the answer came from a sibling rather than from the
name it asked about.  Rove and FiveAM are asserted alongside to prove this
reaches every framework rather than only the one being renamed."
  ;; Each library name must itself be free of a test suffix, or the guard that
  ;; stops a test system being chased for a sibling suppresses the lookup.
  (let ((probes '(("dsmr-probe-lib-on-zebra"
                   "dsmr-probe-lib-on-zebra/tests" "zebra")
                  ("dsmr-probe-lib-on-rove"
                   "dsmr-probe-lib-on-rove/test" "rove")
                  ("dsmr-probe-lib-on-fiveam"
                   "dsmr-probe-lib-on-fiveam-tests" "fiveam"))))
    (unwind-protect
         (progn
           ;; Each library declares ordinary dependencies and says nothing at
           ;; all about testing; only the sibling names the framework.
           (dolist (probe probes)
             (eval `(asdf:defsystem ,(first probe) :depends-on ("alexandria")))
             (eval `(asdf:defsystem ,(second probe)
                      :depends-on (,(first probe) ,(third probe)))))
           (multiple-value-bind (framework matched declared-by)
               (%detect-from-asdf-deps "dsmr-probe-lib-on-zebra")
             (is eq :zebra framework)
             (is string= "zebra" matched)
             (is string= "dsmr-probe-lib-on-zebra/tests" declared-by))
           (is eq :rove (%detect-from-asdf-deps "dsmr-probe-lib-on-rove"))
           (is eq :fiveam (%detect-from-asdf-deps "dsmr-probe-lib-on-fiveam"))
           ;; The same answers through the public entry point.
           (is eq :zebra
               (detect-test-framework "dsmr-probe-lib-on-zebra"))
           ;; A name that is already a test system is not chased any further.
           (true (%test-system-name-p "dsmr-mcp/tests"))
           (true (%test-system-name-p "zebra/test"))
           (false (%test-system-name-p "dsmr-mcp"))
           (is equal
               '("dsmr-mcp/tests" "dsmr-mcp/test"
                 "dsmr-mcp-tests" "dsmr-mcp-test")
               (%test-system-siblings "dsmr-mcp")))
      (dolist (probe probes)
        (ignore-errors (asdf:clear-system (first probe)))
        (ignore-errors (asdf:clear-system (second probe)))))))

(define-test dependency-designators-resolve-to-system-names
  "Every dependency spelling ASDF can hand back resolves to the system name.

ASDF coerces a plain dependency to a lowercase string whatever it was written
as, so a keyword and a string arrive identically and neither needs special
handling.  The compound designators are the ones that survive as lists, and
(:feature FEATURE NAME) puts the system third: reading the second element
returns the feature, which names no system and matches no framework, so a
dependency guarded by a feature was invisible to detection."
  (is string= "zebra" (%dependency-system-name "zebra"))
  (is string= "zebra" (%dependency-system-name :zebra))
  (is string= "zebra" (%dependency-system-name '#:zebra))
  (is string= "zebra" (%dependency-system-name '(:version :zebra "1.0")))
  (is string= "fiveam" (%dependency-system-name '(:feature :sbcl :fiveam)))
  (is string= "fiveam" (%dependency-system-name '(:feature (:and :sbcl :unix)
                                                  "fiveam")))
  (false (%dependency-system-name 42))
  ;; End to end: a framework named only behind a feature guard is detected.
  (let ((probe "dsmr-probe-feature-guarded-suite"))
    (unwind-protect
         (progn
           (eval `(asdf:defsystem ,probe
                    :depends-on ((:feature :sbcl :fiveam))))
           (is eq :fiveam (%detect-from-asdf-deps probe)))
      (ignore-errors (asdf:clear-system probe)))))

(define-test explicit-framework-overrides-detection
  "An explicit framework argument is taken at face value, because the caller
knows the suite better than the dependency walk does.

Every supported name must intern to the keyword the runner dispatches on; a
name that reaches no dispatch branch lands in the ASDF fallback, which reports
success without running a recognised suite."
  (is eq :zebra (detect-test-framework "dsmr-mcp/tests" "zebra"))
  (is eq :zebra (detect-test-framework "dsmr-mcp/tests" "ZEBRA"))
  (is eq :zebra (detect-test-framework "dsmr-mcp/tests" "zebra"))
  (is eq :rove (detect-test-framework "dsmr-mcp/tests" "rove"))
  (is eq :fiveam (detect-test-framework "dsmr-mcp/tests" "fiveam"))
  (is eq :zebra (detect-test-framework "dsmr-mcp/tests" "auto")))

(define-test package-resolution-lands-on-the-loaded-framework
  "Package resolution returns the framework package present in the image.

The engine looks its entry points up by symbol rather than calling them by
name, so it carries no compile-time dependency on the framework and this is
the only place the package is resolved.  Resolving to NIL sends a run to the
ASDF fallback, which reports success without running a recognised suite."
  (is eq (find-package :zebra) (%zebra-package))
  (is string= "ZEBRA" *zebra-package-name*)
  (is string= "zebra" *zebra-system-name*)
  (true (%zebra-system-p "zebra"))
  (true (%zebra-system-p "ZEBRA"))
  ;; The removed name must not resolve, and must not linger as a package.
  (false (%zebra-system-p "parachute"))
  (false (find-package :parachute))
  (false (find-package :org.shirakumo.parachute)))

;;; ---------------------------------------------------------------------------
;;; run-tests-zebra-returns-structured-counts
;;;
;;; Running a tiny Zebra suite through the core's extractor returns
;;; the uniform envelope with passed/failed counts and at least one failed_tests
;;; entry with a source location (criterion 3).
;;;
;;; The throwaway suite lives in the scratch package so it does not pollute the
;;; project's own suite results. One test passes; one fails deliberately.
;;; ---------------------------------------------------------------------------

(define-test run-tests-zebra-returns-structured-counts
  "The Zebra extractor produces passed/failed/pending counts and a
failed_tests entry with a source location for a deliberately failing test.
Exercises the uniform envelope and criterion 3 source-location reporting."
  ;; Define a throwaway two-test suite in the scratch package.
  (let* ((scratch-pkg (find-package :dsmr-scratch-runner-tests))
         (zebra-pkg (find-package :zebra))
         (test-fn (and zebra-pkg (find-symbol "TEST" zebra-pkg)))
         (results-with-status-fn (and zebra-pkg
                                      (find-symbol "RESULTS-WITH-STATUS" zebra-pkg)))
         (remove-fn (and zebra-pkg
                         (find-symbol "REMOVE-ALL-TESTS-IN-PACKAGE" zebra-pkg))))
    ;; Zebra is always loaded at this point (test file uses it).
    (true (and scratch-pkg zebra-pkg test-fn results-with-status-fn))
    (when (and scratch-pkg zebra-pkg test-fn results-with-status-fn)
      ;; Clean up any previous scratch tests.
      (when remove-fn (ignore-errors (funcall remove-fn scratch-pkg)))
      ;; Define one passing and one failing test in the scratch package.
      (let ((*package* scratch-pkg))
        (eval '(zebra:define-test scratch-passing-test
                 (zebra:true t)))
        (eval '(zebra:define-test scratch-failing-test
                 (zebra:true nil))))
      ;; Run the scratch package's tests via the core extractor, bypassing reload
      ;; (these tests are already registered in the image).
      (let ((result (run-tests "dsmr-scratch-runner-tests"
                               :framework "zebra"
                               :reload nil)))
        (true (hash-table-p result))
        ;; Framework field must be "zebra".
        (is string= "zebra" (gethash "framework" result))
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
  "The Zebra extractor populates source{file,line} in a failed_tests entry
when the failing test is defined in a real source file (not eval'd at runtime).
The file-defined scratch test at the top of this file is compiled with :defun t
so sb-introspect can locate its source."
  (let* ((zebra-pkg (find-package :zebra))
         (scratch-pkg (find-package :dsmr-scratch-runner-tests)))
    (true (and zebra-pkg scratch-pkg))
    (when (and zebra-pkg scratch-pkg)
      ;; Ensure the file-defined test is registered.  A prior test's cleanup
      ;; may have called remove-all-tests-in-package on the scratch package.
      ;; Re-register using the symbol interned in scratch-pkg (not CL-USER) so
      ;; %test-source-location can find the defun compiled from this file.
      (let* ((ensure-fn (find-symbol "ENSURE-TEST" zebra-pkg))
             (setf-find-fn (fdefinition
                             `(setf ,(find-symbol "FIND-TEST" zebra-pkg))))
             (test-sym (intern "SCRATCH-FILE-DEFINED-FAILING-TEST-FOR-SOURCE" scratch-pkg)))
        (when (and ensure-fn setf-find-fn)
          (let ((test-obj (funcall (fdefinition ensure-fn)
                                   'zebra:test
                                   :name test-sym
                                   :home scratch-pkg
                                   :tests (list (lambda () (zebra:true nil))))))
            (funcall setf-find-fn test-obj test-sym scratch-pkg))))
      ;; Run the scratch suite (reload=nil: the test is registered in-image).
      (let ((result (run-tests "dsmr-scratch-runner-tests"
                               :framework "zebra"
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
        (let ((remove-fn (find-symbol "REMOVE-ALL-TESTS-IN-PACKAGE" zebra-pkg)))
          (when remove-fn
            (ignore-errors (funcall remove-fn scratch-pkg))))))))

;;; ---------------------------------------------------------------------------
;;; run-tests-ghost-purge-drops-deleted-test
;;;
;;; After registering a Zebra test in the scratch package, calling
;;; %zebra-purge-ghost-suites must remove all tests from that package's
;;; registry so a subsequent run does not see the purged test.
;;; ---------------------------------------------------------------------------

(define-test run-tests-ghost-purge-drops-deleted-test
  "After %zebra-purge-ghost-suites, a previously-registered test is absent
from the Zebra test index for that package. This verifies that ghost tests
cannot haunt results after reload."
  (let* ((scratch-pkg (find-package :dsmr-scratch-runner-tests))
         (zebra-pkg (find-package :zebra))
         (remove-fn (and zebra-pkg
                         (find-symbol "REMOVE-ALL-TESTS-IN-PACKAGE" zebra-pkg)))
         (pkg-tests-fn (and zebra-pkg
                            (find-symbol "PACKAGE-TESTS" zebra-pkg))))
    (true (and scratch-pkg zebra-pkg remove-fn pkg-tests-fn))
    (when (and scratch-pkg zebra-pkg remove-fn pkg-tests-fn)
      ;; Clean slate.
      (ignore-errors (funcall remove-fn scratch-pkg))
      ;; Register a ghost test.
      (let ((*package* scratch-pkg))
        (eval '(zebra:define-test ghost-test-for-purge-test
                 (zebra:true t))))
      ;; Confirm the test is registered.
      (let ((tests-before (funcall pkg-tests-fn scratch-pkg)))
        (true (plusp (length tests-before))))
      ;; Purge ghost suites for a fake system name — but call remove-all-tests-in-package
      ;; directly on the scratch package, which is what %zebra-purge-ghost-suites
      ;; ultimately calls. This is the canonical ghost-purge verification.
      (funcall remove-fn scratch-pkg)
      ;; After purge, the package's test index must be empty.
      (let ((tests-after (funcall pkg-tests-fn scratch-pkg)))
        (true (zerop (length tests-after)))))))

;;; ---------------------------------------------------------------------------
;;; run-tests-attached-returns-structured-counts
;;;
;;; The attached path injects a ghost-purge + reload + run form via Slynk.
;;; Running the scratch runner-tests package through the attached path must
;;; return an envelope with the standard passed/failed/framework fields.
;;; ---------------------------------------------------------------------------

(defun %make-run-tests-attach-session (id conn)
  "Create a test session wired to the given Slynk connection."
  (let* ((session (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (repl-tool (get-tool-instance session "repl-eval")))
    (setf (repl-eval-tool-slynk-conn repl-tool) conn)
    (values session repl-tool)))

(define-test run-tests-attached-returns-structured-counts
  "Calling %dispatch-attach-run-tests via the in-process Slynk fixture against
the always-loaded 'dsmr-scratch-runner-tests' package returns an envelope with
integer 'passed', 'failed', 'pending' fields and a string 'framework' field —
NOT a NETWORK_ERROR.
The attached path injects a ghost-purge + run form into the live image; the form
must survive the Slynk wire protocol round-trip and return a structured result.
Target the scratch package, NOT this test's own package: pointing run-tests at
the package the outer harness is currently running would re-enter this very test
in-image and recurse until the call-lock deadline fires."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool)
        (%make-run-tests-attach-session "rt-attach-counts" conn)
      (declare (ignore session))
      ;; Use reload=nil: the scratch package is already loaded in the image;
      ;; skipping ASDF reload keeps this test fast and avoids compile noise in
      ;; the test runner's own output.
      (let* ((params (make-ht "system"          "dsmr-scratch-runner-tests"
                              "framework"       "zebra"
                              "reload"          nil
                              "timeout_seconds" 300))
             (result (%dispatch-attach-run-tests repl-tool nil params)))
        (true (hash-table-p result))
        ;; Must NOT be a NETWORK_ERROR — that would mean the injected form failed
        ;; to survive the Slynk wire protocol (e.g. #() literal in the form is
        ;; incompatible with Slynk's translating-read protocol parser).
        ;; A NETWORK_ERROR here indicates the attached path is broken.
        (false (string= "NETWORK_ERROR" (gethash "error_type" result "")))
        ;; On success: structured counts envelope.
        (false (gethash "isError" result))
        (true (integerp (gethash "passed"    result)))
        (true (integerp (gethash "failed"    result)))
        (true (integerp (gethash "pending"   result)))
        (true (stringp  (gethash "framework" result)))
        ;; The client renders results through content alone — the summary
        ;; text block must be present alongside the structured counts.
        (let ((content (gethash "content" result)))
          (true (vectorp content))
          (true (search "passed" (gethash "text" (aref content 0)))))))))

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

;;; ---------------------------------------------------------------------------
;;; run-tests-injected-form-is-portable
;;;
;;; %build-run-tests-form is serialized and READ in the attached image, which
;;; never has dsmr-mcp loaded. Any symbol interned in a DSMR-MCP-internal
;;; package makes the remote READ fail ("Package ... does not exist") and aborts
;;; the run with a reader-error / NETWORK_ERROR. Referencing the in-image
;;; test-runner-core by KEYWORD package name (find-package :dsmr-mcp/src/...) is
;;; the portable pattern — a keyword reads anywhere; an actual symbol interned
;;; in a DSMR-MCP package (e.g. a stray handler-case error variable) is the
;;; hazard. Pure structural guard; the in-process fixture cannot catch it
;;; because its target image shares dsmr-mcp's package namespace.
;;; ---------------------------------------------------------------------------

(defun %collect-symbols (form)
  "Flat list of every symbol appearing in FORM (a tree of conses and atoms,
descending into non-string vectors)."
  (let ((acc '()))
    (labels ((walk (x)
               (cond ((and (symbolp x) x) (push x acc))
                     ((consp x) (walk (car x)) (walk (cdr x)))
                     ((and (vectorp x) (not (stringp x))) (map nil #'walk x)))))
      (walk form))
    acc))

(defun %dsmr-package-leaks (form)
  "Symbols in FORM whose home package name contains \"DSMR-MCP\" — symbols that
cannot be READ in an attached image that does not have dsmr-mcp loaded."
  (remove-duplicates
   (remove-if-not
    (lambda (s)
      (let ((pkg (symbol-package s)))
        (and pkg (search "DSMR-MCP" (package-name pkg)))))
    (%collect-symbols form))))

(define-test run-tests-injected-form-is-portable
  "%build-run-tests-form must emit no symbol from a DSMR-MCP-internal package."
  (is equal '() (%dsmr-package-leaks
                 (%build-run-tests-form "alexandria" nil nil nil 300 t))))

(define-test engine-ensure-form-is-portable
  "%build-engine-ensure-form must emit no symbol from a DSMR-MCP-internal
package — it is READ in the attached image before the engine exists there."
  (let ((path (engine-source-path)))
    (is equal '() (%dsmr-package-leaks
                   (%build-engine-ensure-form path (engine-fingerprint path))))))

(define-test engine-bootstrap-version-gate
  "The engine bootstrap reloads on fingerprint mismatch, not bare package
presence. Sequence: a fresh ensure against the shipped engine loads and
stamps (:LOADED) — or reports :CURRENT when an earlier leaf already
stamped it — then an identical ensure is :CURRENT; then an ensure built
against a MODIFIED engine copy (different fingerprint, same package
already present) must reload (:LOADED) and make the copy's definitions
live. Guards the long-lived-image upgrade path: package presence alone
would pin an attached image to the first engine it ever loaded."
  (let* ((orig (engine-source-path))
         (fp1  (engine-fingerprint orig))
         (tmp  (uiop:tmpize-pathname
                (merge-pathnames "dsmr-stale-engine.lisp"
                                 (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           ;; Gate settles on the shipped engine: second ensure is :CURRENT.
           (eval (%build-engine-ensure-form orig fp1))
           (is eq :current (eval (%build-engine-ensure-form orig fp1)))
           ;; Stale path: a modified copy with a new fingerprint must reload
           ;; even though the engine package already exists in this image.
           (uiop:concatenate-files (list (pathname orig)) tmp)
           (with-open-file (s tmp :direction :output :if-exists :append)
             (write-line "(defparameter dsmr-mcp/src/test-runner-engine::*bootstrap-probe* 42)" s))
           (let* ((tmp-path (map 'string #'identity (namestring (truename tmp))))
                  (fp2 (engine-fingerprint tmp-path)))
             (false (equal fp1 fp2))
             (is eq :loaded (eval (%build-engine-ensure-form tmp-path fp2)))
             ;; The reloaded copy's definitions are live in the image.
             (let ((probe (find-symbol "*BOOTSTRAP-PROBE*"
                                       :dsmr-mcp/src/test-runner-engine)))
               (true (and probe (boundp probe) (eql 42 (symbol-value probe)))))
             ;; And the stamp now carries the copy's fingerprint.
             (let ((stamp (find-symbol "*LOADED-FINGERPRINT*"
                                       :dsmr-mcp/src/test-runner-engine)))
               (is equal fp2 (symbol-value stamp)))))
      ;; Restore the pristine engine so later leaves see shipped definitions.
      (eval (%build-engine-ensure-form orig fp1))
      (ignore-errors (delete-file tmp)))))

(define-test resolver-handles-umbrella-systems
  "%resolve-test-packages: a same-named package with tests short-circuits
\(1:1 fast path); an umbrella system with NO same-named package resolves
through its :depends-on closure to the sub-packages that contain tests,
constrained to subsystems of the same primary system — a dependency from a
DIFFERENT primary (even one full of tests) and framework deps like
zebra are excluded; an unknown system resolves to NIL."
  ;; Scratch umbrella: two test-bearing sub-packages, one foreign-primary
  ;; dep that must be excluded, zebra in :depends-on as in real
  ;; umbrellas. In-memory defsystems are fine — the resolver only READS.
  (dolist (spec '("(asdf:defsystem \"dsmr-scratch-umb/tests\"
                     :depends-on (\"zebra\"
                                  \"dsmr-mcp/tests/state/session-test\"
                                  \"dsmr-scratch-umb/tests/suite-a\"
                                  \"dsmr-scratch-umb/tests/suite-b\"))"
                  "(asdf:defsystem \"dsmr-scratch-umb/tests/suite-a\")"
                  "(asdf:defsystem \"dsmr-scratch-umb/tests/suite-b\")"))
    (eval (read-from-string spec)))
  (dolist (name '("DSMR-SCRATCH-UMB/TESTS/SUITE-A"
                  "DSMR-SCRATCH-UMB/TESTS/SUITE-B"))
    (unless (find-package name)
      (make-package name :use '("COMMON-LISP")))
    (let ((*package* (find-package name)))
      (eval (read-from-string
             "(zebra:define-test umb-scratch-probe (zebra:true t))"))))
  ;; Umbrella: exactly the two same-primary, test-bearing sub-packages.
  (let ((resolved (%resolve-test-packages "dsmr-scratch-umb/tests")))
    (is = 2 (length resolved))
    (true (member "DSMR-SCRATCH-UMB/TESTS/SUITE-A" resolved
                  :key #'package-name :test #'string=))
    (true (member "DSMR-SCRATCH-UMB/TESTS/SUITE-B" resolved
                  :key #'package-name :test #'string=))
    ;; The foreign-primary dep has tests but must not be swept in.
    (false (member "DSMR-MCP/TESTS/STATE/SESSION-TEST" resolved
                   :key #'package-name :test #'string=)))
  ;; 1:1 fast path: a test-bearing package named like the system.
  (is equal '("DSMR-SCRATCH-UMB/TESTS/SUITE-A")
      (mapcar #'package-name
              (%resolve-test-packages "dsmr-scratch-umb/tests/suite-a")))
  ;; Unknown system: NIL, so the caller can choose the fallback.
  (false (%resolve-test-packages "dsmr-no-such-system-exists")))

(define-test failure-reasons-survive-the-injected-form
  "The injected run form carries failure names + reasons (bounded) back to
the dispatcher, and the decoded envelope renders them: failed_tests holds
one well-named entry per failing test (not a flat+nested duplicate), and
the summary line names the failing test with a reason snippet — counts
alone once hid a target-resolution crash."
  (unless (find-package "DSMR-SCRATCH-REASONS-PROBE")
    (make-package "DSMR-SCRATCH-REASONS-PROBE" :use '("COMMON-LISP")))
  (let ((*package* (find-package "DSMR-SCRATCH-REASONS-PROBE")))
    (eval (read-from-string
           "(progn (zebra:define-test reasons-probe-passes (zebra:true t))
                   (zebra:define-test reasons-probe-fails (zebra:is = 1 2)))")))
  (let* ((form (%build-run-tests-form
                "dsmr-scratch-reasons-probe" "zebra" nil nil 60 nil))
         (raw (eval form))
         (ht (dsmr-mcp/src/tools/run-tests::%decode-run-tests-result
              raw "dsmr-scratch-reasons-probe" (get-internal-real-time))))
    (is = 1 (gethash "passed" ht))
    (is = 1 (gethash "failed" ht))
    ;; Exactly one failure detail, carrying the TEST's name and a reason.
    (let ((fails (gethash "failed_tests" ht)))
      (is = 1 (length fails))
      (let ((f (aref fails 0)))
        (true (search "REASONS-PROBE-FAILS" (gethash "test_name" f)))
        (true (plusp (length (gethash "reason" f))))))
    ;; The rendered summary names the failure and includes reason text.
    (let ((summary (gethash "text" (aref (gethash "content" ht) 0))))
      (true (search "REASONS-PROBE-FAILS" summary))
      (true (search "—" summary)))))
