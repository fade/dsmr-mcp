;;;; src/test-runner-core.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Test-runner engine shared between the attached-injection path and the
;;;; hermetic worker handler.
;;;;
;;;; Provides:
;;;;   detect-test-framework   — ASDF-deps-first framework detection.
;;;;   run-tests               — in-process entry point (hermetic path).
;;;;   %build-run-tests-form   — builds the sexp injected into the attached
;;;;                             image (attached path).
;;;;   %parachute-purge-ghost-suites — clears stale Parachute registrations
;;;;                             for all packages in a system before reload.
;;;;   %rove-purge-ghost-suites — ported from cl-mcp; clears stale Rove suites.
;;;;   *test-debug-output*     — broadcast stream for intentional debug output
;;;;                             during test execution.
;;;;
;;;; Framework detection precedence (explicit arg > ASDF :depends-on closure >
;;;; loaded-package heuristic) ensures correct results even when multiple test
;;;; frameworks are loaded simultaneously in a long-lived attached image.
;;;;
;;;; Ghost-purge + force-reload: by default, stale per-framework test
;;;; registrations are purged and the test system is reloaded before running, so
;;;; tests deleted from source on disk no longer haunt results.  Pass
;;;; reload=false to opt out (for tight hot-reload loops).
;;;;
;;;; Timeout: the test run is wrapped in sb-ext:with-timeout (300 s default)
;;;; so a runaway test loop is interrupted in the target image.
;;;; sb-ext:timeout is a serious-condition and therefore cannot be swallowed by
;;;; handler-case (error ...) arms — it reliably fires even inside test bodies
;;;; that catch general errors.

(defpackage #:dsmr-mcp/src/test-runner-core
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:text-content)
  ;; sb-introspect for test source locations (Parachute + FiveAM).
  (:import-from #:sb-introspect)
  ;; sb-ext for with-timeout (SBCL-specific, intentional):
  (:import-from #:sb-ext)
  ;; asdf always present:
  (:import-from #:asdf)
  (:import-from #:uiop)
  (:export #:run-tests
           #:detect-test-framework
           #:%parachute-purge-ghost-suites
           #:%rove-purge-ghost-suites
           #:*test-debug-output*
           #:%build-run-tests-form))

(in-package #:dsmr-mcp/src/test-runner-core)

;;; ---------------------------------------------------------------------------
;;; *test-debug-output*
;;;
;;; A broadcast stream that test code can write to for intentional debug output.
;;; During a test run, this is rebound to a capturing string stream; the captured
;;; output is included in the run-tests response as "debug_output". Outside of a
;;; test run, output is discarded (broadcast to zero streams).
;;; ---------------------------------------------------------------------------

(defvar *test-debug-output* (make-broadcast-stream)
  "Stream for intentional debug output during test execution.
Test code can write to this stream: (format dsmr-mcp/src/test-runner-core:*test-debug-output*
\"debug: ~A~%\" value). Output is captured and returned in the run-tests response.
Outside of test execution this is a broadcast-stream; output is discarded.")

(defvar *max-test-output-length* 50000
  "Maximum characters for stdout/stderr captured during test execution.")

(defun %truncate-test-output (string)
  "Truncate STRING to *max-test-output-length* if it exceeds the limit."
  (if (> (length string) *max-test-output-length*)
      (format nil "~A~%... (truncated, ~D total chars)"
              (subseq string 0 *max-test-output-length*)
              (length string))
      string))

;;; ---------------------------------------------------------------------------
;;; Unified Result Envelope
;;;
;;; make-test-result builds the standard wire hash-table returned by every
;;; framework extractor. The shape is identical across Parachute, Rove, and
;;; FiveAM so callers and test assertions can use the same field names.
;;; make-failure-detail builds one entry in the failed_tests array.
;;; ---------------------------------------------------------------------------

(defun make-test-result (&key passed failed pending passed-tests failed-tests
                           framework duration)
  "Create a unified test result hash table.
Fields: passed, failed, pending (counts), framework (string), duration_ms
(integer), failed_tests (vector of failure-detail hash-tables)."
  (let* ((normalized-failed-tests (if (vectorp failed-tests)
                                      failed-tests
                                      (coerce (or failed-tests '()) 'vector)))
         (ht (make-ht "passed"      (or passed 0)
                      "failed"      (or failed 0)
                      "framework"   (string-downcase (symbol-name framework))
                      "failed_tests" normalized-failed-tests
                      "duration_ms" (or duration 0))))
    (when pending
      (setf (gethash "pending" ht) pending))
    (when passed-tests
      (setf (gethash "passed_tests" ht) (coerce passed-tests 'vector)))
    ht))

(defun make-failure-detail (&key test-name description form values reason source)
  "Create a failure detail hash-table for one entry in failed_tests.
Fields: test_name (required), plus optional description, form, values, reason, source."
  (let ((ht (make-ht "test_name" (if (stringp test-name)
                                     test-name
                                     (princ-to-string test-name)))))
    (when description
      (setf (gethash "description" ht) description))
    (when form
      (setf (gethash "form" ht) (princ-to-string form)))
    (when values
      (setf (gethash "values" ht)
            (coerce (mapcar #'princ-to-string values) 'vector)))
    (when reason
      (setf (gethash "reason" ht)
            (if (stringp reason)
                reason
                (princ-to-string reason))))
    (when source
      (setf (gethash "source" ht)
            (if (listp source)
                (make-ht "file" (first source)
                         "line" (second source))
                (princ-to-string source))))
    ht))

;;; ---------------------------------------------------------------------------
;;; Framework Detection
;;;
;;; precedence: explicit arg > ASDF :depends-on closure > loaded-package
;;; heuristic. The ASDF-deps walk is preferred over the loaded-package heuristic
;;; because a long-lived attached image may have several test frameworks loaded
;;; simultaneously (e.g., Parachute from dsmr's own suite AND Rove from a
;;; project under test). Without the ASDF-deps check, the heuristic would always
;;; return the first framework whose package happens to be loaded.
;;; ---------------------------------------------------------------------------

(defun %detect-from-asdf-deps (system-name)
  "Walk SYSTEM-NAME's ASDF :depends-on closure (with visited-set deduplication)
checking for parachute / rove / fiveam system name strings.
Returns :parachute, :rove, :fiveam, or NIL when none found.
Walks at least 2 levels (the test system plus its direct deps); the visited hash
prevents cycles and bounds the total work on deeply nested systems."
  (let ((visited (make-hash-table :test #'equal)))
    (labels ((walk (name)
               (when (and (stringp name) (not (gethash name visited)))
                 (setf (gethash name visited) t)
                 (let ((sys (ignore-errors (asdf:find-system name nil))))
                   (when sys
                     (let ((deps (ignore-errors (asdf:system-depends-on sys))))
                       (dolist (dep deps)
                         (let ((dep-name (if (consp dep) (second dep) dep)))
                           (when (stringp dep-name)
                             (cond
                               ((string-equal dep-name "parachute")
                                (return-from %detect-from-asdf-deps :parachute))
                               ((string-equal dep-name "rove")
                                (return-from %detect-from-asdf-deps :rove))
                               ((string-equal dep-name "fiveam")
                                (return-from %detect-from-asdf-deps :fiveam)))
                             (walk dep-name))))))))))
      (walk system-name))
    nil))

(defun detect-test-framework (system-name &optional explicit-framework)
  "Return the test framework keyword for SYSTEM-NAME: :parachute / :rove /
:fiveam / :asdf.

Detection precedence:
  1. EXPLICIT-FRAMEWORK arg when non-NIL and not \"auto\" — the caller knows best.
  2. ASDF :depends-on closure inspection — walk the system's dependency tree
     looking for parachute / rove / fiveam system names.  Reliable even when
     multiple frameworks are loaded in the same image.
  3. Loaded-package heuristic — fall back to find-package.
  4. :asdf — unknown framework; use ASDF test-op with captured text."
  (cond
    ;; 1. Explicit arg: intern it as a keyword.
    ((and explicit-framework
          (not (string-equal explicit-framework "auto")))
     (intern (string-upcase explicit-framework) :keyword))
    ;; 2. ASDF :depends-on closure walk.
    ((and (stringp system-name)
          (%detect-from-asdf-deps system-name)))
    ;; 3. Loaded-package heuristic.
    ((find-package :org.shirakumo.parachute) :parachute)
    ((find-package :rove)                   :rove)
    ((find-package :fiveam)                 :fiveam)
    ;; 4. Unknown — use ASDF test-op text fallback.
    (t :asdf)))

;;; ---------------------------------------------------------------------------
;;; Source Location Lookup
;;;
;;; Used by Parachute and FiveAM extractors to attach file + line to each
;;; failed test. sb-introspect:find-definition-sources-by-name looks up the
;;; defun generated by define-test (Parachute with :defun t, which is default)
;;; or the deftest function (FiveAM). Guard: (symbolp name) — string-named
;;; Parachute tests do not produce a defun and cannot be located.
;;; ---------------------------------------------------------------------------

(defun %test-source-location (name-symbol)
  "Return (list FILE LINE) for NAME-SYMBOL's :function definition, or NIL.
Uses sb-introspect to locate the defun generated by define-test (Parachute)
or deftest (FiveAM). Returns NIL when the name is a string rather than a
symbol — string-named tests do not produce a defun and have no source location."
  (unless (symbolp name-symbol)
    (return-from %test-source-location nil))
  (let* ((pkg (find-package :sb-introspect))
         (find-fn (and pkg (find-symbol "FIND-DEFINITION-SOURCES-BY-NAME" pkg)))
         (path-fn (and pkg (find-symbol "DEFINITION-SOURCE-PATHNAME" pkg)))
         (offset-fn (and pkg (find-symbol "DEFINITION-SOURCE-CHARACTER-OFFSET" pkg))))
    (unless (and find-fn path-fn offset-fn)
      (return-from %test-source-location nil))
    (let ((sources (ignore-errors
                     (funcall find-fn name-symbol :function))))
      (when sources
        (let* ((src (first sources))
               (pathname (ignore-errors (funcall path-fn src)))
               (offset   (ignore-errors (funcall offset-fn src)))
               (line     (when (and pathname offset)
                           (ignore-errors
                             (with-open-file (stream pathname :if-does-not-exist nil)
                               (when stream
                                 (let ((line 1))
                                   (dotimes (i offset line)
                                     (when (char= (read-char stream nil #\Space) #\Newline)
                                       (incf line)))))))))
               (path-str (when pathname
                           (map 'string #'identity (namestring pathname)))))
          (when (and path-str line)
            (list path-str line)))))))

;;; ---------------------------------------------------------------------------
;;; ASDF Fallback (text capture)
;;; ---------------------------------------------------------------------------

(defun %run-asdf-fallback (system-name)
  "Run tests using asdf:test-system with text output capture.
Returns the standard make-test-result envelope with framework=asdf."
  (log-event :info "test-runner" "framework" "asdf-fallback" "system" system-name)
  (let ((output (make-string-output-stream))
        (error-output (make-string-output-stream))
        (debug-stream (make-string-output-stream))
        (start-time (get-internal-real-time))
        (success nil)
        (condition-message nil))
    (handler-case
        (progn
          (let ((*standard-output* output)
                (*error-output* error-output)
                (*test-debug-output* debug-stream)
                (*standard-input* (make-string-input-stream "")))
            (asdf:test-system system-name))
          (setf success t))
      (error (c)
        (setf condition-message (princ-to-string c))
        (format error-output "~&Error: ~A~%" c)))
    (let* ((end-time (get-internal-real-time))
           (duration-ms (round (* 1000 (/ (- end-time start-time)
                                          internal-time-units-per-second))))
           (stdout (%truncate-test-output (get-output-stream-string output)))
           (stderr (%truncate-test-output (get-output-stream-string error-output)))
           (failure-reason (or condition-message
                               (and (plusp (length stderr)) stderr)
                               "asdf:test-system failed"))
           (failed-tests (if success
                             #()
                             (vector (make-failure-detail
                                      :test-name system-name
                                      :reason failure-reason))))
           (ht (make-ht "passed"      0
                        "failed"      (if success 0 1)
                        "pending"     0
                        "framework"   "asdf"
                        "duration_ms" duration-ms
                        "failed_tests" failed-tests
                        "success"     success)))
      (when (plusp (length stdout))
        (setf (gethash "stdout" ht) stdout))
      (when (plusp (length stderr))
        (setf (gethash "stderr" ht) stderr))
      (let ((debug-output (get-output-stream-string debug-stream)))
        (when (plusp (length debug-output))
          (setf (gethash "debug_output" ht) debug-output)))
      ht)))

;;; ---------------------------------------------------------------------------
;;; Parachute Backend
;;;
;;; Net-new (cl-mcp has no Parachute extractor). Walks the test-result tree
;;; returned by (parachute:test ...) to extract passed/failed/pending counts
;;; and per-failed-test detail including source locations via sb-introspect.
;;; ---------------------------------------------------------------------------

(defun %parachute-purge-ghost-suites (system-name)
  "Remove Parachute test registrations for all packages associated with
SYSTEM-NAME before reload. This prevents tests deleted from source from
haunting subsequent runs.

Uses parachute:remove-all-tests-in-package (the public Parachute API) via
uiop:symbol-call to avoid a hard compile-time dependency on the parachute
package. Walks the ASDF :depends-on closure with a visited-set to cover all
test sub-systems in a package-inferred layout."
  (let ((visited-systems (make-hash-table :test #'equal)))
    (labels ((purge-pkg (pkg-name)
               (when (stringp pkg-name)
                 (let ((pkg (find-package (string-upcase pkg-name))))
                   (when pkg
                     (ignore-errors
                       (uiop:symbol-call :org.shirakumo.parachute
                                        :remove-all-tests-in-package pkg))))))
             (walk-system (name)
               (when (and (stringp name) (not (gethash name visited-systems)))
                 (setf (gethash name visited-systems) t)
                 (purge-pkg name)
                 (let ((sys (ignore-errors (asdf:find-system name nil))))
                   (when sys
                     (dolist (dep (ignore-errors (asdf:system-depends-on sys)))
                       (let ((dep-name (if (consp dep) (second dep) dep)))
                         (when (stringp dep-name)
                           (walk-system dep-name)))))))))
      (walk-system system-name))))

(defun %parachute-result-counts (result-obj)
  "Walk a Parachute test-result or parent-result tree and return
(values passed failed pending) counts."
  (let ((passed 0) (failed 0) (pending 0))
    (labels ((count-result (r)
               (let* ((pkg (find-package :org.shirakumo.parachute))
                      (status-fn (and pkg (find-symbol "STATUS" pkg)))
                      (results-fn (and pkg (find-symbol "RESULTS" pkg)))
                      (status (and status-fn (ignore-errors (funcall status-fn r)))))
                 (cond
                   ;; If this is a leaf result (not a parent-result), count it.
                   ((not (ignore-errors (funcall results-fn r)))
                    (case status
                      (:passed (incf passed))
                      (:failed (incf failed))
                      (:skipped (incf pending))
                      (t)))
                   ;; Parent result: recurse into children.
                   (t
                    (let ((children (ignore-errors (funcall results-fn r))))
                      (when children
                        (dotimes (i (length children))
                          (count-result (aref children i))))))))))
      (count-result result-obj))
    (values passed failed pending)))

(defun %parachute-extract-failures (result-obj)
  "Walk a Parachute test-result tree and collect failure details for each
:failed leaf result.  Returns a list of make-failure-detail hash-tables.

Parent result nodes carry the test name symbol as the NAME of their expression
(a PARACHUTE:TEST object).  That symbol is propagated down to leaf failures so
source locations are populated for file-defined tests even when the leaf's own
expression is an assertion form rather than a test object."
  (let ((failures nil))
    (labels ((walk (r parent-test-sym)
               (let* ((pkg (find-package :org.shirakumo.parachute))
                      (status-fn  (and pkg (find-symbol "STATUS" pkg)))
                      (results-fn (and pkg (find-symbol "RESULTS" pkg)))
                      (expr-fn    (and pkg (find-symbol "EXPRESSION" pkg)))
                      (name-fn    (and pkg (find-symbol "NAME" pkg)))
                      (status (and status-fn (ignore-errors (funcall status-fn r))))
                      (children (ignore-errors
                                  (and results-fn (funcall results-fn r)))))
                 (if (and children (plusp (length children)))
                     ;; Parent result: extract this node's test symbol (when its
                     ;; expression has a non-nil symbol name) and pass it into
                     ;; children so leaf failures can report the containing test.
                     (let* ((expr (and expr-fn (ignore-errors (funcall expr-fn r))))
                            (node-name (and expr name-fn
                                            (ignore-errors (funcall name-fn expr))))
                            (node-test-sym (if (and node-name (symbolp node-name))
                                               node-name
                                               parent-test-sym)))
                       (dotimes (i (length children))
                         (walk (aref children i) node-test-sym)))
                     ;; Leaf result: record if failed.
                     (when (eq status :failed)
                       (let* ((expr     (and expr-fn (ignore-errors (funcall expr-fn r))))
                              (leaf-name (and expr name-fn
                                              (ignore-errors (funcall name-fn expr))))
                              ;; Prefer a non-nil symbol from the leaf itself; fall
                              ;; back to the nearest ancestor test symbol.
                              (effective-sym (cond
                                               ((and leaf-name (symbolp leaf-name)) leaf-name)
                                               (t parent-test-sym)))
                              (test-name (cond
                                           (effective-sym
                                            (princ-to-string effective-sym))
                                           (expr (princ-to-string expr))
                                           (t "unknown")))
                              (source (when effective-sym
                                        (%test-source-location effective-sym)))
                              (reason-str (ignore-errors
                                            (let* ((fmt-fn (find-symbol "FORMAT-RESULT"
                                                                        :org.shirakumo.parachute))
                                                   (ext-kw (intern "EXTENSIVE" :keyword)))
                                              (and fmt-fn
                                                   (funcall fmt-fn r ext-kw))))))
                         (push (make-failure-detail
                                :test-name test-name
                                :reason (or reason-str "failed")
                                :source source)
                               failures)))))))
      (walk result-obj nil))
    (nreverse failures)))

(defun %run-parachute-tests (system-name)
  "Run tests using Parachute for SYSTEM-NAME and return the uniform envelope.
Invokes (parachute:test SYSTEM-DESIGNATOR) via dynamic symbol lookup so
the function works whether the parachute package is called org.shirakumo.parachute
or parachute."
  (log-event :info "test-runner" "framework" "parachute" "system" system-name)
  (let* ((pkg (find-package :org.shirakumo.parachute))
         (test-fn (and pkg (find-symbol "TEST" pkg)))
         (context-var (and pkg (find-symbol "*CONTEXT*" pkg)))
         (parent-var  (and pkg (find-symbol "*PARENT*" pkg))))
    (unless test-fn
      (log-event :warn "test-runner" "message" "Parachute not loaded; falling back to ASDF")
      (return-from %run-parachute-tests (%run-asdf-fallback system-name)))
    (let ((start-time (get-internal-real-time))
          (stdout-stream (make-string-output-stream))
          (stderr-stream (make-string-output-stream))
          (debug-stream  (make-string-output-stream))
          result-obj
          run-error)
      (handler-case
          (let ((*standard-output* stdout-stream)
                (*error-output*    stderr-stream)
                (*test-debug-output* debug-stream)
                (*standard-input* (make-string-input-stream "")))
            ;; Bind both *CONTEXT* and *PARENT* to NIL so this run's result
            ;; objects do not register themselves into any outer Parachute context
            ;; (e.g. when run-tests is called from inside a define-test body
            ;; during our own test suite). *PARENT* is set by eval-in-context
            ;; :around on parent-result and causes new result objects to attach
            ;; to the outer test-result via initialize-instance :after.
            (let ((isolation-vars (remove nil (list context-var parent-var))))
              (setf result-obj
                    (progv isolation-vars (make-list (length isolation-vars))
                      (funcall test-fn
                               (or (find-package (string-upcase system-name))
                                   (intern (string-upcase system-name) :keyword)))))))
        (error (c)
          (setf run-error (princ-to-string c))))
      (let* ((end-time (get-internal-real-time))
             (duration-ms (round (* 1000 (/ (- end-time start-time)
                                            internal-time-units-per-second))))
             (stdout (%truncate-test-output (get-output-stream-string stdout-stream)))
             (stderr (%truncate-test-output (get-output-stream-string stderr-stream)))
             (debug-output (get-output-stream-string debug-stream)))
        (if run-error
            (let ((ht (make-test-result
                       :passed 0 :failed 1 :pending 0
                       :failed-tests
                       (list (make-failure-detail
                              :test-name system-name
                              :reason (format nil "Test runner crashed: ~A" run-error)))
                       :framework :parachute
                       :duration duration-ms)))
              (when (plusp (length stdout)) (setf (gethash "stdout" ht) stdout))
              (when (plusp (length stderr)) (setf (gethash "stderr" ht) stderr))
              (when (plusp (length debug-output)) (setf (gethash "debug_output" ht) debug-output))
              ht)
            ;; Normal path: extract counts + failures from the result tree.
            (multiple-value-bind (passed failed pending)
                (%parachute-result-counts result-obj)
              (let* ((failures (when (plusp failed)
                                 (%parachute-extract-failures result-obj)))
                     (ht (make-test-result
                          :passed passed :failed failed :pending pending
                          :failed-tests failures
                          :framework :parachute
                          :duration duration-ms)))
                (when (plusp (length stdout)) (setf (gethash "stdout" ht) stdout))
                (when (plusp (length stderr)) (setf (gethash "stderr" ht) stderr))
                (when (plusp (length debug-output)) (setf (gethash "debug_output" ht) debug-output))
                ht)))))))

;;; ---------------------------------------------------------------------------
;;; Rove Backend
;;;
;;; Ported near-verbatim from cl-mcp/src/test-runner-core.lisp (lines 103-784).
;;; These functions are Rove-version-specific and have already absorbed all the
;;; edge cases (FAILED-ASSERTION without TEST-NAME method, aggregate test
;;; systems with zero counts, sub-system retry). Only mechanical substitutions
;;; applied: cl-mcp/src/log:log-event -> dsmr-mcp/src/log:log-event.
;;; ---------------------------------------------------------------------------

(defun %extract-defpackage-names-from-file (pathname)
  "Return a list of package names mentioned in (defpackage ...) forms of
the Lisp source file at PATHNAME. Returns NIL on any error."
  (handler-case
      (with-open-file (stream pathname :direction :input)
        (let ((*read-eval* nil)
              (*package* (find-package :cl-user))
              (names nil))
          (loop
            (let ((form (handler-case (read stream nil :eof)
                          (error () :eof))))
              (when (eq form :eof) (return))
              (when (and (consp form)
                         (symbolp (car form))
                         (or (string= (symbol-name (car form)) "DEFPACKAGE")
                             (string= (symbol-name (car form)) "DEFINE-PACKAGE"))
                         (consp (cdr form)))
                (let ((name-form (second form)))
                  (push
                   (cond
                     ((stringp name-form) name-form)
                     ((symbolp name-form) (symbol-name name-form))
                     (t nil))
                   names)))))
          (remove-if-not #'stringp (nreverse names))))
    (error () nil)))

(defun %rove-purge-ghost-suites (system-name)
  "Remove Rove suite entries for every test package associated with
SYSTEM-NAME. Prevents ghost deftests — tests deleted from source but still
remembered by Rove's in-image registry.

Rove stores per-package suites in ROVE/CORE/SUITE/PACKAGE::*PACKAGE-SUITES*.
Clearing the entry for a package makes Rove rebuild the suite from scratch on
the next deftest load.

Two discovery strategies combined:
  1. Dependency names: walk SYSTEM-NAME's transitive dependency list and clear
     packages whose name matches each string dep (covers package-inferred layouts).
  2. Component source files: recursively walk the ASDF component tree, read each
     source file's defpackage forms, and clear those packages (covers classic
     defsystems where the package name does not match the ASDF sub-system name)."
  (let ((pkgs-var (find-symbol "*PACKAGE-SUITES*" :rove/core/suite/package)))
    (when (and pkgs-var (boundp pkgs-var)
               (hash-table-p (symbol-value pkgs-var)))
      (let ((suites (symbol-value pkgs-var))
            (visited-systems (make-hash-table :test #'equal))
            (visited-files   (make-hash-table :test #'equal)))
        (labels ((clear-pkg (pkg-name)
                   (let ((pkg (and (stringp pkg-name) (find-package pkg-name))))
                     (when pkg (remhash pkg suites))))
                 (walk-components (component)
                   (when component
                     (cond
                       ((typep component 'asdf:cl-source-file)
                        (let ((path (ignore-errors
                                      (asdf:component-pathname component))))
                          (when (and path
                                     (not (gethash (namestring path) visited-files))
                                     (probe-file path))
                            (setf (gethash (namestring path) visited-files) t)
                            (dolist (pkg-name
                                     (%extract-defpackage-names-from-file path))
                              (clear-pkg pkg-name)))))
                       ((ignore-errors (asdf:component-children component))
                        (dolist (child (asdf:component-children component))
                          (walk-components child))))))
                 (walk-system (name)
                   (when (and (stringp name)
                              (not (gethash name visited-systems)))
                     (setf (gethash name visited-systems) t)
                     (clear-pkg name)
                     (let ((sys (ignore-errors (asdf:find-system name nil))))
                       (when sys
                         (walk-components sys)
                         (dolist (dep (ignore-errors (asdf:system-depends-on sys)))
                           (cond
                             ((stringp dep) (walk-system dep))
                             ((and (consp dep) (stringp (second dep)))
                              (walk-system (second dep))))))))))
          (walk-system system-name))))))

(defun %rove-extract-assertions (test-node)
  "Recursively extract failed assertions from a Rove test node."
  (let* ((pkg (find-package :rove/core/result))
         (test-failed-fn (fdefinition (find-symbol "TEST-FAILED-TESTS" pkg)))
         (assertion-form-fn (fdefinition (find-symbol "ASSERTION-FORM" pkg)))
         (assertion-desc-fn (fdefinition (find-symbol "ASSERTION-DESCRIPTION" pkg)))
         (assertion-reason-fn (fdefinition (find-symbol "ASSERTION-REASON" pkg)))
         (assertion-values-fn (fdefinition (find-symbol "ASSERTION-VALUES" pkg)))
         (assertion-source-fn (fdefinition (find-symbol "ASSERTION-SOURCE-LOCATION" pkg)))
         (failed-assertion-class (find-symbol "FAILED-ASSERTION" pkg))
         (children (funcall test-failed-fn test-node)))
    (loop for child in children
          if (typep child failed-assertion-class)
            collect (make-failure-detail
                     :form (funcall assertion-form-fn child)
                     :description (funcall assertion-desc-fn child)
                     :reason (funcall assertion-reason-fn child)
                     :values (funcall assertion-values-fn child)
                     :source (funcall assertion-source-fn child))
          else
            append (%rove-extract-assertions child))))

(defun %safe-rove-test-name (test-name-fn node)
  "Call TEST-NAME-FN on NODE, falling back gracefully on error."
  (handler-case (funcall test-name-fn node)
    (error ()
      (let* ((pkg (find-package :rove/core/result))
             (desc-sym (find-symbol "ASSERTION-DESCRIPTION" pkg)))
        (or (and desc-sym
                 (ignore-errors (funcall (fdefinition desc-sym) node)))
            "<unknown test>")))))

(defun %rove-extract-test-failures (stats &key single-test-p)
  "Extract all failure details from Rove stats."
  (let* ((pkg (find-package :rove/core/result))
         (stats-pkg (find-package :rove/core/stats))
         (test-name-fn (fdefinition (find-symbol "TEST-NAME" pkg)))
         (test-failed-fn (fdefinition (find-symbol "TEST-FAILED-TESTS" pkg)))
         (stats-failed-fn (fdefinition (find-symbol "STATS-FAILED-TESTS" stats-pkg)))
         (failed-tests (funcall stats-failed-fn stats))
         (results nil))
    (if single-test-p
        (loop for test-fail across failed-tests
              do (let ((test-name (%safe-rove-test-name test-name-fn test-fail)))
                   (loop for testing-fail in (funcall test-failed-fn test-fail)
                         do (let ((testing-desc (%safe-rove-test-name test-name-fn testing-fail))
                                  (assertions (%rove-extract-assertions testing-fail)))
                              (dolist (assertion assertions)
                                (setf (gethash "test_name" assertion)
                                      (format nil "~A / ~A" test-name testing-desc))
                                (push assertion results))))))
        (loop for suite-fail across failed-tests
              do (loop for test-fail in (funcall test-failed-fn suite-fail)
                       do (loop for testing-fail in (funcall test-failed-fn test-fail)
                                do (let ((test-name (%safe-rove-test-name test-name-fn test-fail))
                                         (testing-desc (%safe-rove-test-name test-name-fn testing-fail))
                                         (assertions (%rove-extract-assertions testing-fail)))
                                     (dolist (assertion assertions)
                                       (setf (gethash "test_name" assertion)
                                             (format nil "~A / ~A" test-name testing-desc))
                                       (push assertion results)))))))
    (nreverse results)))

(defun %coerce-test-symbol (test-name)
  "Convert TEST-NAME to a fully qualified test symbol."
  (cond
    ((null test-name)
     (error "Test name must not be NIL"))
    ((symbolp test-name)
     (unless (symbol-package test-name)
       (error "Test symbol must be package-qualified: ~S" test-name))
     test-name)
    ((stringp test-name)
     (let* ((name (string-upcase test-name))
            (colon-pos (search "::" name)))
       (unless colon-pos
         (error "Test name must be fully qualified (pkg::name): ~A" test-name))
       (let* ((pkg-name (subseq name 0 colon-pos))
              (sym-name (subseq name (+ colon-pos 2)))
              (pkg (find-package pkg-name)))
         (unless pkg
           (error "Test package not found: ~A" pkg-name))
         (intern sym-name pkg))))
    (t
     (error "Test name must be a string or symbol: ~S" test-name))))

(defun %normalize-tests-arg (tests)
  "Normalize TESTS to a non-empty list of fully-qualified test symbols."
  (let ((items (cond
                 ((null tests) nil)
                 ((vectorp tests) (coerce tests 'list))
                 ((listp tests) tests)
                 (t (error "tests must be an array of test names")))))
    (when (and tests (null items))
      (error "tests must contain at least one test name"))
    (mapcar #'%coerce-test-symbol items)))

(defun %ensure-rove-test-name-method ()
  "Add a TEST-NAME method for FAILED-ASSERTION if Rove is loaded and the method
is missing. Rove's TEST-NAME generic function has no method for FAILED-ASSERTION,
causing NO-APPLICABLE-METHOD crashes. This monkey-patch lets Rove's internal
iteration proceed."
  (let ((pkg (find-package :rove/core/result)))
    (when pkg
      (let ((test-name-gf (ignore-errors
                            (fdefinition (find-symbol "TEST-NAME" pkg))))
            (fa-class (find-class (find-symbol "FAILED-ASSERTION" pkg) nil))
            (desc-fn (ignore-errors
                       (fdefinition (find-symbol "ASSERTION-DESCRIPTION" pkg)))))
        (when (and test-name-gf fa-class desc-fn
                   (typep test-name-gf 'generic-function)
                   (null (ignore-errors
                           (find-method test-name-gf nil (list fa-class)))))
          (eval
           `(defmethod ,(find-symbol "TEST-NAME" pkg)
                ((obj ,(find-symbol "FAILED-ASSERTION" pkg)))
              (or (ignore-errors (funcall ,desc-fn obj))
                  "<assertion>"))))))))

(defun %find-rove-test-sub-systems (system-name)
  "Return test sub-system names from SYSTEM-NAME's ASDF :depends-on.
Filters string dependencies that have SYSTEM-NAME/ as a prefix."
  (let* ((sys (ignore-errors (asdf:find-system system-name nil)))
         (deps (when sys (ignore-errors (asdf:system-depends-on sys))))
         (prefix (concatenate 'string (string-downcase system-name) "/")))
    (remove-if-not (lambda (dep)
                     (and (stringp dep)
                          (uiop:string-prefix-p prefix dep)))
                   deps)))

(defun %rove-extract-selected-failures (results)
  "Extract failure details from selected test RESULTS returned by rove:run-tests."
  (let* ((pkg (find-package :rove/core/result))
         (test-name-fn (fdefinition (find-symbol "TEST-NAME" pkg)))
         (failed-assertion-class (find-symbol "FAILED-ASSERTION" pkg))
         (assertion-form-fn (fdefinition (find-symbol "ASSERTION-FORM" pkg)))
         (assertion-desc-fn (fdefinition (find-symbol "ASSERTION-DESCRIPTION" pkg)))
         (assertion-reason-fn (fdefinition (find-symbol "ASSERTION-REASON" pkg)))
         (assertion-values-fn (fdefinition (find-symbol "ASSERTION-VALUES" pkg)))
         (assertion-source-fn (fdefinition (find-symbol "ASSERTION-SOURCE-LOCATION" pkg)))
         (failure-details nil))
    (dolist (test-result results)
      (if (typep test-result failed-assertion-class)
          (push (make-failure-detail
                 :test-name (princ-to-string test-result)
                 :form (funcall assertion-form-fn test-result)
                 :description (funcall assertion-desc-fn test-result)
                 :reason (funcall assertion-reason-fn test-result)
                 :values (funcall assertion-values-fn test-result)
                 :source (funcall assertion-source-fn test-result))
                failure-details)
          (let ((test-name (princ-to-string (funcall test-name-fn test-result)))
                (assertions (%rove-extract-assertions test-result)))
            (dolist (assertion assertions)
              (setf (gethash "test_name" assertion) test-name)
              (push assertion failure-details)))))
    (nreverse failure-details)))

(defun %run-rove-selected-tests (test-symbols)
  "Run Rove TEST-SYMBOLS and return structured results."
  (%ensure-rove-test-name-method)
  (log-event :info "test-runner" "framework" "rove" "selected_tests"
             (format nil "~{~A~^, ~}" test-symbols))
  (let* ((result-pkg (find-package :rove/core/result))
         (reporter-pkg (find-package :rove/reporter))
         (rove-pkg (find-package :rove))
         (run-tests-fn (fdefinition (find-symbol "RUN-TESTS" rove-pkg)))
         (passed-tests-fn (fdefinition (find-symbol "PASSED-TESTS" result-pkg)))
         (failed-tests-fn (fdefinition (find-symbol "FAILED-TESTS" result-pkg)))
         (pending-tests-fn (fdefinition (find-symbol "PENDING-TESTS" result-pkg)))
         (report-stream-sym (find-symbol "*REPORT-STREAM*" reporter-pkg))
         (start-time (get-internal-real-time))
         (stdout-stream (make-string-output-stream))
         (stderr-stream (make-string-output-stream))
         (debug-stream (make-string-output-stream))
         results
         rove-error)
    (unless report-stream-sym
      (error "Rove internal symbol *REPORT-STREAM* not found; incompatible Rove version?"))
    (handler-case
        ;; run-tests returns (values successp results-list); we only need results-list.
        (setf results
              (nth-value 1
                (progv (list report-stream-sym)
                    (list (make-broadcast-stream))
                  (let ((*standard-output* stdout-stream)
                        (*error-output* stderr-stream)
                        (*test-debug-output* debug-stream)
                        (*standard-input* (make-string-input-stream "")))
                    (funcall run-tests-fn test-symbols)))))
      (error (c)
        (setf rove-error (princ-to-string c))
        (log-event :error "test-runner" "message" "rove:run-tests crashed"
                   "error" rove-error)))
    (let* ((end-time (get-internal-real-time))
           (duration-ms (round (* 1000 (/ (- end-time start-time)
                                          internal-time-units-per-second))))
           (stdout (%truncate-test-output (get-output-stream-string stdout-stream)))
           (stderr (%truncate-test-output (get-output-stream-string stderr-stream)))
           (debug-output (get-output-stream-string debug-stream)))
      (if rove-error
          (let ((ht (make-test-result
                     :passed 0 :failed (length test-symbols)
                     :failed-tests
                     (mapcar (lambda (sym)
                               (make-failure-detail
                                :test-name (princ-to-string sym)
                                :reason (format nil "Test runner crashed: ~A" rove-error)))
                             test-symbols)
                     :framework :rove :duration duration-ms)))
            (when (plusp (length stdout)) (setf (gethash "stdout" ht) stdout))
            (when (plusp (length stderr)) (setf (gethash "stderr" ht) stderr))
            (when (plusp (length debug-output)) (setf (gethash "debug_output" ht) debug-output))
            ht)
          (let ((passed 0) (failed 0) (pending 0))
            (dolist (test-result results)
              (incf passed (length (funcall passed-tests-fn test-result)))
              (incf failed (length (funcall failed-tests-fn test-result)))
              (incf pending (length (funcall pending-tests-fn test-result))))
            (let ((ht (make-test-result
                       :passed passed :failed failed :pending pending
                       :failed-tests
                       (when (plusp failed)
                         (%rove-extract-selected-failures results))
                       :framework :rove :duration duration-ms)))
              (when (plusp (length stdout)) (setf (gethash "stdout" ht) stdout))
              (when (plusp (length stderr)) (setf (gethash "stderr" ht) stderr))
              (when (plusp (length debug-output)) (setf (gethash "debug_output" ht) debug-output))
              ht))))))

(defun %run-rove-tests (system-name)
  "Run tests using Rove for SYSTEM-NAME and return structured results."
  (%ensure-rove-test-name-method)
  (log-event :info "test-runner" "framework" "rove" "system" system-name)
  (let* ((result-pkg (find-package :rove/core/result))
         (reporter-pkg (find-package :rove/reporter))
         (rove-pkg (find-package :rove))
         (run-fn (fdefinition (find-symbol "RUN" rove-pkg)))
         (passed-tests-fn (fdefinition (find-symbol "PASSED-TESTS" result-pkg)))
         (failed-tests-fn (fdefinition (find-symbol "FAILED-TESTS" result-pkg)))
         (pending-tests-fn (fdefinition (find-symbol "PENDING-TESTS" result-pkg)))
         (test-name-fn (fdefinition (find-symbol "TEST-NAME" result-pkg)))
         (report-stream-sym (find-symbol "*REPORT-STREAM*" reporter-pkg))
         (last-report-sym (find-symbol "*LAST-SUITE-REPORT*" rove-pkg))
         (pkgs-var (find-symbol "*PACKAGE-SUITES*" :rove/core/suite/package))
         (start-time (get-internal-real-time))
         (stdout-stream (make-string-output-stream))
         (stderr-stream (make-string-output-stream))
         (debug-stream (make-string-output-stream))
         rove-error)
    (unless (and report-stream-sym last-report-sym)
      (error "Rove internal symbols not found; incompatible Rove version?"))
    (handler-case
        (progv (list report-stream-sym)
            (list (make-broadcast-stream))
          (let ((*standard-output* stdout-stream)
                (*error-output* stderr-stream)
                (*test-debug-output* debug-stream)
                (*standard-input* (make-string-input-stream "")))
            (funcall run-fn
                     (intern (string-upcase system-name) :keyword))))
      (error (c)
        (setf rove-error (princ-to-string c))
        (log-event :error "test-runner" "message" "rove:run crashed"
                   "error" rove-error)))
    (let* ((end-time (get-internal-real-time))
           (duration-ms (round (* 1000 (/ (- end-time start-time)
                                          internal-time-units-per-second))))
           (stdout (%truncate-test-output (get-output-stream-string stdout-stream)))
           (stderr (%truncate-test-output (get-output-stream-string stderr-stream)))
           (debug-output (get-output-stream-string debug-stream)))
      (if rove-error
          (let ((ht (make-test-result :passed 0 :failed 1
                                      :failed-tests
                                      (list (make-failure-detail
                                             :test-name system-name
                                             :reason (format nil "Test runner crashed: ~A"
                                                             rove-error)))
                                      :framework :rove :duration duration-ms)))
            (when (plusp (length stdout)) (setf (gethash "stdout" ht) stdout))
            (when (plusp (length stderr)) (setf (gethash "stderr" ht) stderr))
            (when (plusp (length debug-output)) (setf (gethash "debug_output" ht) debug-output))
            ht)
          (let ((suite-results (symbol-value last-report-sym))
                (passed 0) (failed 0) (pending 0)
                (failure-details nil))
            (labels ((%extract-suites (suites)
                       (dolist (suite-result suites)
                         (dolist (pkg-result (funcall passed-tests-fn suite-result))
                           (incf passed (length (funcall passed-tests-fn pkg-result)))
                           (incf failed (length (funcall failed-tests-fn pkg-result)))
                           (incf pending (length (funcall pending-tests-fn pkg-result))))
                         (dolist (pkg-result (funcall failed-tests-fn suite-result))
                           (incf passed (length (funcall passed-tests-fn pkg-result)))
                           (incf failed (length (funcall failed-tests-fn pkg-result)))
                           (incf pending (length (funcall pending-tests-fn pkg-result))))
                         (dolist (pkg-result
                                  (append (funcall passed-tests-fn suite-result)
                                          (funcall failed-tests-fn suite-result)))
                           (dolist (test-fail (funcall failed-tests-fn pkg-result))
                             (let ((test-name (%safe-rove-test-name test-name-fn test-fail))
                                   (assertions (%rove-extract-assertions test-fail)))
                               (dolist (a assertions)
                                 (setf (gethash "test_name" a) (princ-to-string test-name))
                                 (push a failure-details))))))))
              (%extract-suites suite-results)
              ;; Fallback for aggregate test systems with zero counts.
              (when (and (zerop (+ passed failed pending)) (null rove-error))
                (let ((sub-systems (%find-rove-test-sub-systems system-name)))
                  (when sub-systems
                    (log-event :info "test-runner" "message"
                               "zero counts; retrying sub-systems"
                               "count" (length sub-systems))
                    (dolist (sub-sys sub-systems)
                      (let ((run-ok nil))
                        (handler-case
                            (progn
                              (when (and pkgs-var (boundp pkgs-var)
                                         (hash-table-p (symbol-value pkgs-var)))
                                (let ((pkg (find-package (string-upcase sub-sys))))
                                  (when pkg (remhash pkg (symbol-value pkgs-var)))))
                              (ignore-errors (asdf/system-registry:clear-system sub-sys))
                              (progv (list report-stream-sym)
                                  (list (make-broadcast-stream))
                                (let ((*standard-output* (make-broadcast-stream))
                                      (*error-output* (make-broadcast-stream))
                                      (*test-debug-output* (make-broadcast-stream))
                                      (*standard-input* (make-string-input-stream "")))
                                  (funcall run-fn
                                           (intern (string-upcase sub-sys) :keyword))))
                              (setf run-ok t))
                          (error (c)
                            (incf failed 1)
                            (push (make-failure-detail
                                   :test-name sub-sys
                                   :reason (format nil "Sub-system crashed: ~A"
                                                   (princ-to-string c)))
                                  failure-details)
                            (log-event :warn "test-runner" "message" "sub-system test error"
                                       "sub-system" sub-sys "error" (princ-to-string c))))
                        (when run-ok
                          (%extract-suites (symbol-value last-report-sym))))))))
              (let ((ht (make-test-result :passed passed :failed failed :pending pending
                                          :failed-tests (nreverse failure-details)
                                          :framework :rove :duration duration-ms)))
                (when (plusp (length stdout)) (setf (gethash "stdout" ht) stdout))
                (when (plusp (length stderr)) (setf (gethash "stderr" ht) stderr))
                (when (plusp (length debug-output)) (setf (gethash "debug_output" ht) debug-output))
                ht)))))))

;;; ---------------------------------------------------------------------------
;;; FiveAM Backend
;;;
;;; Net-new. Invoked only when (find-package :fiveam) is non-NIL. The ASDF
;;; text fallback covers FiveAM's absence. Source locations use sb-introspect
;;; on the test name symbol (same strategy as Parachute).
;;; ---------------------------------------------------------------------------

(defun %run-fiveam-tests (system-name)
  "Run tests using FiveAM for SYSTEM-NAME and return structured results.
Only called when the :fiveam package is loaded. Falls back to ASDF text output
when FiveAM's expected API symbols cannot be found."
  (log-event :info "test-runner" "framework" "fiveam" "system" system-name)
  (unless (find-package :fiveam)
    (return-from %run-fiveam-tests (%run-asdf-fallback system-name)))
  (let* ((fiveam-pkg (find-package :fiveam))
         (run-fn (and fiveam-pkg (find-symbol "RUN!" fiveam-pkg)))
         (get-suite-fn (and fiveam-pkg (find-symbol "GET-TEST" fiveam-pkg))))
    (unless (and run-fn get-suite-fn)
      (log-event :warn "test-runner" "message"
                 "FiveAM API symbols not found; falling back to ASDF")
      (return-from %run-fiveam-tests (%run-asdf-fallback system-name)))
    (let ((start-time (get-internal-real-time))
          (stdout-stream (make-string-output-stream))
          (stderr-stream (make-string-output-stream))
          (debug-stream  (make-string-output-stream))
          run-error
          results-list)
      (handler-case
          (let ((*standard-output* stdout-stream)
                (*error-output*    stderr-stream)
                (*test-debug-output* debug-stream)
                (*standard-input* (make-string-input-stream "")))
            ;; fiveam:run! runs a named suite and prints a report; we prefer
            ;; fiveam:run which returns result objects without printing.
            (let* ((run-quiet-fn (find-symbol "RUN" fiveam-pkg))
                   (suite-sym (intern (string-upcase system-name) :keyword))
                   (suite (ignore-errors (funcall get-suite-fn suite-sym))))
              (if suite
                  (setf results-list (funcall (or run-quiet-fn run-fn) suite))
                  ;; No named suite found — fall back.
                  (progn
                    (log-event :warn "test-runner" "message"
                               "FiveAM suite not found; falling back to ASDF"
                               "system" system-name)
                    (return-from %run-fiveam-tests (%run-asdf-fallback system-name))))))
        (error (c)
          (setf run-error (princ-to-string c))))
      (let* ((end-time (get-internal-real-time))
             (duration-ms (round (* 1000 (/ (- end-time start-time)
                                            internal-time-units-per-second))))
             (stdout (%truncate-test-output (get-output-stream-string stdout-stream)))
             (stderr (%truncate-test-output (get-output-stream-string stderr-stream)))
             (debug-output (get-output-stream-string debug-stream)))
        (if run-error
            (let ((ht (make-test-result
                       :passed 0 :failed 1 :pending 0
                       :failed-tests
                       (list (make-failure-detail
                              :test-name system-name
                              :reason (format nil "FiveAM runner crashed: ~A" run-error)))
                       :framework :fiveam :duration duration-ms)))
              (when (plusp (length stdout)) (setf (gethash "stdout" ht) stdout))
              (when (plusp (length stderr)) (setf (gethash "stderr" ht) stderr))
              (when (plusp (length debug-output)) (setf (gethash "debug_output" ht) debug-output))
              ht)
            ;; results-list is a list of fiveam result objects (test-result subclasses).
            (let* ((passed 0) (failed 0) (pending 0)
                   (failures nil)
                   ;; FiveAM result accessor names (via dynamic lookup).
                   (status-fn   (find-symbol "TEST-PASSED-P" fiveam-pkg))
                   (reason-fn   (find-symbol "REASON" fiveam-pkg))
                   (testcase-fn (find-symbol "TEST-CASE" fiveam-pkg))
                   (name-fn     (find-symbol "NAME" fiveam-pkg))
                   (pass-class  (find-symbol "TEST-PASSED" fiveam-pkg))
                   (fail-class  (find-symbol "TEST-FAILURE" fiveam-pkg))
                   (skip-class  (find-symbol "TEST-SKIPPED" fiveam-pkg)))
              (dolist (r results-list)
                (cond
                  ((and pass-class (typep r (find-class pass-class nil)))
                   (incf passed))
                  ((and skip-class (typep r (find-class skip-class nil)))
                   (incf pending))
                  ((and fail-class (typep r (find-class fail-class nil)))
                   (incf failed)
                   (let* ((testcase (and testcase-fn (ignore-errors
                                                       (funcall (fdefinition testcase-fn) r))))
                          (test-name (and testcase name-fn
                                         (ignore-errors
                                           (funcall (fdefinition name-fn) testcase))))
                          (reason (and reason-fn (ignore-errors
                                                   (funcall (fdefinition reason-fn) r))))
                          (source (when (symbolp test-name)
                                    (%test-source-location test-name))))
                     (push (make-failure-detail
                            :test-name (or (and test-name (princ-to-string test-name))
                                           "unknown")
                            :reason (or (and reason (princ-to-string reason)) "failed")
                            :source source)
                           failures)))
                  (t
                   ;; Unknown result type — check status-fn if available.
                   (if (and status-fn
                            (ignore-errors (funcall (fdefinition status-fn) r)))
                       (incf passed)
                       (incf failed)))))
              (let ((ht (make-test-result
                         :passed passed :failed failed :pending pending
                         :failed-tests (nreverse failures)
                         :framework :fiveam :duration duration-ms)))
                (when (plusp (length stdout)) (setf (gethash "stdout" ht) stdout))
                (when (plusp (length stderr)) (setf (gethash "stderr" ht) stderr))
                (when (plusp (length debug-output)) (setf (gethash "debug_output" ht) debug-output))
                ht)))))))

;;; ---------------------------------------------------------------------------
;;; System Reload + Ghost-Purge
;;;
;;; Before running tests, purge stale framework registrations and force-reload
;;; the test system. This implements the lisp-edit-form -> run-tests hot-reload
;;; loop: edits become live before test execution. reload=false opts out.
;;; ---------------------------------------------------------------------------

(defun %ensure-system-loaded (system-name framework)
  "Purge stale framework test registrations then force-reload SYSTEM-NAME.
Ghost-purge removes tests that were deleted from source so they cannot haunt
the subsequent run. ASDF:CLEAR-SYSTEM then ASDF:LOAD-SYSTEM ensures edits
made via lisp-edit-form are picked up before the run."
  ;; Ghost-purge: per-framework, before clearing/reloading.
  (case framework
    (:parachute (ignore-errors (%parachute-purge-ghost-suites system-name)))
    (:rove      (ignore-errors (%rove-purge-ghost-suites system-name))))
  ;; Force-reload: clear ASDF's loaded state then re-load from source.
  (when (asdf:find-system system-name nil)
    (let ((asd-src (ignore-errors
                     (asdf:system-source-file
                      (asdf:find-system system-name nil)))))
      (asdf:clear-system system-name)
      (when asd-src
        (ignore-errors (asdf:load-asd asd-src)))))
  (asdf:load-system system-name))

;;; ---------------------------------------------------------------------------
;;; Main Entry Points
;;; ---------------------------------------------------------------------------

(defun run-tests (system-name &key framework test tests
                                (timeout-seconds 300) (reload t))
  "Run tests for SYSTEM-NAME using the specified or auto-detected FRAMEWORK.
Returns a hash-table with structured results (the uniform envelope).

FRAMEWORK — optional string or keyword: \"parachute\", \"rove\", \"fiveam\",
  \"auto\" (or NIL). When absent or \"auto\", detection uses the ASDF
  :depends-on closure first.
TEST — optional string: run only this specific test (fully qualified).
TESTS — optional list/vector: run only these tests (array of strings).
TIMEOUT-SECONDS — default 300; the entire purge+reload+run is wrapped in
  sb-ext:with-timeout inside the current process so a runaway test is
  interrupted.
RELOAD — default true; purges stale framework registrations and force-reloads
  the test system before running. Pass NIL to skip reload (for tight loops
  where you have already managed the reload externally)."
  (when (and test tests) (error "Specify either TEST or TESTS, not both"))
  (let ((effective-timeout (or timeout-seconds 300)))
    (handler-case
        (sb-ext:with-timeout effective-timeout
          (let* ((fw (detect-test-framework system-name
                                            (and framework
                                                 (if (stringp framework) framework
                                                     (symbol-name framework)))))
                 (selective-p (or test tests)))
            (log-event :info "test-runner" "action" "run-tests"
                       "system" system-name
                       "framework" (string-downcase (symbol-name fw))
                       "reload" reload
                       "test" (cond (test (princ-to-string test))
                                    (tests "selected")
                                    (t "all")))
            ;; Reload + ghost-purge unless opted out.
            (when reload
              (handler-case (%ensure-system-loaded system-name fw)
                (error (load-err)
                  (return-from run-tests
                    (make-test-result
                     :passed 0 :failed 1 :pending 0
                     :framework (or fw :load-error)
                     :duration 0
                     :failed-tests
                     (list (make-failure-detail
                            :test-name "SYSTEM-LOAD"
                            :description (format nil "Could not load test system ~A"
                                                 system-name)
                            :reason (map 'string #'identity
                                         (princ-to-string load-err)))))))))
            (case fw
              (:parachute
               (%run-parachute-tests system-name))
              (:rove
               (if (find-package :rove)
                   (if selective-p
                       (let ((selected (if test
                                           (list (%coerce-test-symbol test))
                                           (%normalize-tests-arg tests))))
                         (%run-rove-selected-tests selected))
                       (%run-rove-tests system-name))
                   (progn
                     (log-event :warn "test-runner" "message"
                                "Rove not loaded; falling back to ASDF")
                     (%run-asdf-fallback system-name))))
              (:fiveam
               (if (find-package :fiveam)
                   (%run-fiveam-tests system-name)
                   (progn
                     (log-event :warn "test-runner" "message"
                                "FiveAM not loaded; falling back to ASDF")
                     (%run-asdf-fallback system-name))))
              (t
               (%run-asdf-fallback system-name)))))
      (sb-ext:timeout ()
        (log-event :warn "test-runner.timeout" "system" system-name
                   "timeout" effective-timeout)
        (make-test-result
         :passed 0 :failed 1 :pending 0
         :framework :timeout
         :duration (round (* effective-timeout 1000))
         :failed-tests
         (list (make-failure-detail
                :test-name "TIMEOUT"
                :reason (format nil "Test run timed out after ~A seconds"
                                effective-timeout))))))))

(defun %build-run-tests-form (system-name framework test tests
                              timeout-seconds reload)
  "Return the sexp that, when evaluated in the attached image, runs tests for
SYSTEM-NAME under sb-ext:with-timeout.

The form performs ghost-purge + ASDF reload (unless reload=false) inside the
attached image so edits made via lisp-edit-form become live before the run.
All helper symbols are interned in CL-USER with the %DSMR-RUNNER- prefix to
satisfy the Slynk IO-package constraint (symbols not in CL or CL-USER get
package-qualified and the remote reader fails). No loop keyword inside the form
— uses dolist/do*.

Returns one of:
  (list :ok RESULT-HASH-PLIST)    — run completed; result is encoded as a plist
  (list :timeout TIMEOUT-SECS)   — sb-ext:with-timeout fired
  (list :error ERROR-STRING)     — error signalled during setup"
  (let* ((effective-timeout (or timeout-seconds 300))
         (fw-str (and framework
                      (if (stringp framework) framework (symbol-name framework)))))
    (flet ((cs (n) (intern n (find-package :common-lisp-user))))
      (let ((s-sys     (cs "%DSMR-RUNNER-SYS"))
            (s-fw      (cs "%DSMR-RUNNER-FW"))
            (s-result  (cs "%DSMR-RUNNER-RESULT"))
            (s-passed  (cs "%DSMR-RUNNER-PASSED"))
            (s-failed  (cs "%DSMR-RUNNER-FAILED"))
            (s-pending (cs "%DSMR-RUNNER-PENDING"))
            (s-dur     (cs "%DSMR-RUNNER-DUR"))
            (s-fails   (cs "%DSMR-RUNNER-FAILS"))
            (s-pkg     (cs "%DSMR-RUNNER-PKG"))
            (s-testfn  (cs "%DSMR-RUNNER-TESTFN")))
        `(handler-case
             (sb-ext:with-timeout ,effective-timeout
               (let ((,s-sys ,system-name))
                 ;; Run via the test-runner-core's run-tests function in-image.
                 ;; The core is loaded in the attached image since dsmr-mcp is
                 ;; the server itself; find it dynamically.
                 (let* ((,s-pkg    (find-package :dsmr-mcp/src/test-runner-core))
                        (,s-testfn (and ,s-pkg
                                        (find-symbol "RUN-TESTS" ,s-pkg))))
                   (if ,s-testfn
                       (let ((,s-result (funcall ,s-testfn ,s-sys
                                                 :framework ,(and fw-str fw-str)
                                                 :test ,test
                                                 :tests ,tests
                                                 :timeout-seconds ,(max 1 (- effective-timeout 1))
                                                 :reload ,reload)))
                         ;; Encode the result hash-table as a plist for wire transfer.
                         ;; Only encode the fields we need; hash-tables can't cross the rex.
                         (let ((,s-passed  (gethash "passed"      ,s-result 0))
                               (,s-failed  (gethash "failed"      ,s-result 0))
                               (,s-pending (gethash "pending"     ,s-result 0))
                               (,s-dur     (gethash "duration_ms" ,s-result 0))
                               (,s-fw      (gethash "framework"   ,s-result "unknown"))
                               (,s-fails   (gethash "failed_tests" ,s-result #())))
                           (list :ok
                                 (list :passed  ,s-passed
                                       :failed  ,s-failed
                                       :pending ,s-pending
                                       :duration ,s-dur
                                       :framework (map 'string #'identity ,s-fw)
                                       :failed-count (length ,s-fails)))))
                       ;; test-runner-core not loaded in attached image — fall back.
                       (list :error (map 'string #'identity
                                         "test-runner-core not loaded in attached image; use hermetic mode"))))))
           (sb-ext:timeout ()
             (list :timeout ,effective-timeout))
           (error (e)
             (list :error (map 'string #'identity (princ-to-string e)))))))))
