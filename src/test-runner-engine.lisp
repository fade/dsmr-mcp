;;;; src/test-runner-engine.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The framework engine behind run-tests: detection, ghost purges, the
;;;; Zebra/Rove/FiveAM extractors, the ASDF text fallback, and the
;;;; uniform result envelope.
;;;;
;;;; DEPENDENCY-FREE BY CONTRACT.  This file is loaded into two very
;;;; different places: in-process by the dsmr-mcp server and its hermetic
;;;; workers (via the normal ASDF build, through the test-runner-core
;;;; facade), and — crucially — into the OPERATOR'S OWN attached image by
;;;; the attach-time bootstrap, where no dsmr-mcp system is or ever will be
;;;; loaded.  It therefore must not reference any dsmr-mcp package, must
;;;; need only what every image already has (CL, ASDF, UIOP), and must
;;;; guard implementation-specific access:
;;;;   - sb-introspect is required softly below and reached via find-symbol
;;;;     at call time (source locations degrade to NIL without it);
;;;;   - the eval timeout uses sb-ext:with-timeout under #+sbcl and is a
;;;;     no-op wrapper elsewhere (the run is then unbounded on non-SBCL).
;;;; Logging goes through *log-hook*, NIL by default (silent in a foreign
;;;; image); the in-process facade binds it to the server's structured
;;;; logger.
;;;;
;;;; The bootstrap stamps *loaded-fingerprint* with the content hash of the
;;;; file it loaded, so a long-lived attached image reloads the engine when
;;;; the server under it upgrades (package presence alone would pin the
;;;; image to the first engine version it ever saw).

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (ignore-errors (require :sb-introspect)))

(defpackage #:dsmr-mcp/src/test-runner-engine
  (:use #:cl)
  (:import-from #:asdf)
  (:import-from #:uiop)
  (:export #:run-tests
           #:detect-test-framework
           #:test-result-summary
           #:*zebra-system-name*
           #:*zebra-package-name*
           #:%detect-from-asdf-deps
           #:%dependency-system-name
           #:%test-system-siblings
           #:%test-system-name-p
           #:%zebra-package
           #:%zebra-system-p
           #:%resolve-test-packages
           #:%zebra-purge-ghost-suites
           #:%rove-purge-ghost-suites
           #:*test-debug-output*
           #:*log-hook*
           #:*loaded-fingerprint*))

(in-package #:dsmr-mcp/src/test-runner-engine)

;;; ---------------------------------------------------------------------------
;;; Logging hook and bootstrap stamp
;;; ---------------------------------------------------------------------------

(defvar *log-hook* nil
  "When non-NIL, a function with the signature of the server's log-event
\(LEVEL MESSAGE &rest FIELDS).  NIL — the default, and the state in a
foreign attached image — makes %LOG a no-op, so the engine never assumes a
logging system exists where it runs.")

(defvar *loaded-fingerprint* nil
  "Content fingerprint of the engine file this image loaded, stamped by the
attach-time bootstrap after a successful load.  NIL when the engine arrived
through the normal ASDF build.  The bootstrap reloads the engine whenever
this differs from the fingerprint of the file the server ships.")

(defun %log (level &rest fields)
  "Forward to *LOG-HOOK* when bound; otherwise do nothing."
  (when *log-hook*
    (apply *log-hook* level fields))
  (values))

;;; ---------------------------------------------------------------------------
;;; Local wire-envelope helpers
;;;
;;; Duplicates of the two tiny constructors in src/tools/helpers.lisp.  The
;;; result envelope must keep the exact shape the rest of the server
;;; expects, but importing the helpers would drag dsmr-mcp packages into
;;; the foreign image; two ten-line copies are the cheaper dependency.
;;; ---------------------------------------------------------------------------

(defun make-ht (&rest kvs)
  "Create an equal-keyed hash-table from alternating KEY VALUE pairs."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k ht) v))
    ht))

(defun text-content (text)
  "Return a one-element simple-vector wrapping TEXT as a text content object."
  (vector (make-ht "type" "text" "text" text)))

;;; ---------------------------------------------------------------------------
;;; Timeout portability shim
;;; ---------------------------------------------------------------------------

(defmacro %with-timeout ((seconds) &body body)
  "sb-ext:with-timeout on SBCL; no timeout enforcement elsewhere.
The engine may run inside an arbitrary attached image, so the timeout is a
best-effort guard, not a portability promise."
  #+sbcl `(sb-ext:with-timeout ,seconds ,@body)
  #-sbcl `(progn ,seconds ,@body))
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
Test code can write to this stream — by its home name
dsmr-mcp/src/test-runner-engine:*test-debug-output*, or via the
re-exporting facade as dsmr-mcp/src/test-runner-core:*test-debug-output* —
e.g. (format ...:*test-debug-output* \"debug: ~A~%\" value). Output is
captured and returned in the run-tests response as \"debug_output\".
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
;;; framework extractor. The shape is identical across Zebra, Rove, and
;;; FiveAM so callers and test assertions can use the same field names.
;;; make-failure-detail builds one entry in the failed_tests array.
;;; ---------------------------------------------------------------------------

(defun test-result-summary (passed failed pending framework duration-ms
                            failed-tests)
  "One-line human text for a run-tests result envelope.
The client renders a tools/call result through its content block alone, so
every envelope needs this alongside the structured fields, which remain
authoritative. FAILED-TESTS is a vector of failure-detail hash-tables (or
nil); the first few failing tests are shown with name AND a truncated
reason so the headline says what broke without the caller parsing the
structure (counts alone once hid a target-resolution crash behind a bare
\"0 passed, 1 failed\")."
  (let ((head (format nil "~D passed, ~D failed~@[, ~D pending~] (~A, ~D ms)"
                      (or passed 0) (or failed 0)
                      (and pending (plusp pending) pending)
                      (or framework "unknown") (or duration-ms 0))))
    (if (and failed-tests (plusp (length failed-tests)))
        (let* ((entries
                 (map 'list
                      (lambda (f)
                        (let* ((name (or (and (hash-table-p f)
                                              (gethash "test_name" f))
                                         "?"))
                               (reason (and (hash-table-p f)
                                            (gethash "reason" f)))
                               (snippet (and (stringp reason)
                                             (plusp (length reason))
                                             (substitute
                                              #\Space #\Newline
                                              (subseq reason 0 (min 80 (length reason)))))))
                          (if snippet
                              (format nil "~A — ~A~:[~;…~]" name snippet
                                      (> (length reason) 80))
                              (format nil "~A" name))))
                      failed-tests))
               (shown (subseq entries 0 (min 3 (length entries))))
               (more  (- (length entries) (length shown))))
          (format nil "~A; failing: ~{~A~^; ~}~[~:; (+~:*~D more)~]"
                  head shown more))
        head)))

(defun make-test-result (&key passed failed pending passed-tests failed-tests
                           framework duration)
  "Create a unified test result hash table.
Fields: passed, failed, pending (counts), framework (string), duration_ms
(integer), failed_tests (vector of failure-detail hash-tables), content
(text block summary — the client renders results through content alone)."
  (let* ((normalized-failed-tests (if (vectorp failed-tests)
                                      failed-tests
                                      (coerce (or failed-tests '()) 'vector)))
         (fw (string-downcase (symbol-name framework)))
         (ht (make-ht "passed"      (or passed 0)
                      "failed"      (or failed 0)
                      "framework"   fw
                      "failed_tests" normalized-failed-tests
                      "duration_ms" (or duration 0)
                      "content"
                      (text-content
                       (test-result-summary passed failed pending fw
                                            duration normalized-failed-tests)))))
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
;;; simultaneously (e.g., Zebra from dsmr's own suite AND Rove from a
;;; project under test). Without the ASDF-deps check, the heuristic would always
;;; return the first framework whose package happens to be loaded.
;;; ---------------------------------------------------------------------------

(defparameter *zebra-system-name* "zebra"
  "The ASDF system providing the zebra test API.")

(defparameter *zebra-package-name* "ZEBRA"
  "The package the zebra test API is presented under.")

(defvar *active-zebra-package* nil
  "The zebra package the run in progress was dispatched against.
%RUN-ZEBRA-TESTS binds it so the result walkers, which are handed a result
object and never see a system name, read the same API the run used.")

(defun %zebra-system-p (name)
  "True when NAME designates the system providing the zebra test API."
  (and (stringp name)
       (string-equal name *zebra-system-name*)))

(defun %dependency-system-name (dep)
  "Return the system name DEP designates as a string, or NIL when it names none.

ASDF coerces a plain dependency to a lowercase string whether it was written as
a string, a symbol or a keyword, so the only spellings that survive parsing are
the compound designators it leaves as lists.  (:version NAME VERSION) carries
the name second, but (:feature FEATURE NAME) carries it third, behind the
feature expression.  Reading the second element of a :feature form yields the
feature rather than the system, so a dependency guarded by a feature named no
system that could be matched."
  (let ((name (if (consp dep)
                  (if (eq (first dep) :feature)
                      (third dep)
                      (second dep))
                  dep)))
    (typecase name
      (string name)
      (symbol (string-downcase (symbol-name name)))
      (t nil))))

(defun %test-system-name-p (system-name)
  "True when SYSTEM-NAME already names a test system by the usual conventions."
  (and (stringp system-name)
       (some (lambda (suffix)
               (let ((n (length system-name))
                     (s (length suffix)))
                 (and (> n s)
                      (string-equal suffix system-name :start2 (- n s)))))
             '("/tests" "/test" "-tests" "-test"))))

(defun %test-system-siblings (system-name)
  "Return the conventional test-system names beside SYSTEM-NAME, likeliest first.

A library does not depend on its own test system; the dependency runs the other
way.  Descending through a library's dependencies therefore never reaches the
system that names the test framework, and someone who asks about the library
gets no answer at all.  These are the names to consult when that happens."
  (when (and (stringp system-name) (plusp (length system-name)))
    (mapcar (lambda (suffix) (concatenate 'string system-name suffix))
            '("/tests" "/test" "-tests" "-test"))))

(defun %detect-from-asdf-deps (system-name)
  "Walk SYSTEM-NAME's ASDF :depends-on closure (with visited-set deduplication)
checking for zebra / rove / fiveam system name strings.
Returns :zebra, :rove, :fiveam, or NIL when none found.

The second return value is the dependency name that matched, and the third is
the system that declared it, which need not be SYSTEM-NAME.

When SYSTEM-NAME names no framework anywhere beneath it, its conventional test
siblings are consulted before giving up.  Naming a library is the way a caller
actually asks for its tests, and a library depends on neither its tests nor
their framework, so descending alone answers NIL for every well-formed project
and sends the caller to a fallback that reports success without running a
recognised suite.

Walks at least 2 levels (the test system plus its direct deps); the visited hash
prevents cycles and bounds the total work on deeply nested systems."
  (let ((visited (make-hash-table :test #'equal)))
    (labels ((framework-named-by (dep-name)
               (cond
                ((%zebra-system-p dep-name) :zebra)
                ((string-equal dep-name "rove") :rove)
                ((string-equal dep-name "fiveam") :fiveam)))
             (walk (name)
               (when (and (stringp name) (not (gethash name visited)))
                 (setf (gethash name visited) t)
                 (let ((sys (ignore-errors (asdf/system:find-system name nil))))
                   (when sys
                     (let ((deps
                            (ignore-errors
                             (asdf/system:system-depends-on sys))))
                       (dolist (dep deps)
                         (let ((dep-name (%dependency-system-name dep)))
                           (when dep-name
                             (let ((framework (framework-named-by dep-name)))
                               (when framework
                                 (return-from %detect-from-asdf-deps
                                   (values framework dep-name name))))
                             (walk dep-name))))))))))
      (walk system-name)
      (unless (%test-system-name-p system-name)
        (mapc #'walk (%test-system-siblings system-name))))
    nil))

(defun %zebra-package ()
  "Return the loaded package providing the zebra test API, or NIL.

The package the run in progress was dispatched against wins, so the result
walkers read the same API the run used even though they never see a system
name."
  (or *active-zebra-package*
      (find-package *zebra-package-name*)))

(defun detect-test-framework (system-name &optional explicit-framework)
  "Return the test framework keyword for SYSTEM-NAME: :zebra / :rove /
:fiveam / :asdf.

The second value is the system that DECLARED the framework, which need not be
SYSTEM-NAME.  Naming a library resolves the framework its test sibling
declares, and that sibling is the system holding both the framework dependency
and the suites: loading and running the library instead leaves the framework
absent and the suites unregistered.  The walk already establishes which system
declared the framework, so discarding it here and re-deriving it from the
caller's name later is what sent a correctly detected project to the ASDF
fallback.  NIL when the answer came from anywhere but the dependency walk.

Detection precedence:
  1. EXPLICIT-FRAMEWORK arg when non-NIL and not \"auto\", because the caller
     knows best.  Nothing is walked, so there is no declaring system and the
     caller's own name is used unchanged.
  2. ASDF :depends-on closure inspection, walking the system's dependency tree
     and its test siblings for zebra / rove / fiveam system names.  Reliable
     even when several frameworks are loaded in the same image.
  3. Loaded-package heuristic, falling back to find-package.
  4. :asdf, meaning unknown framework; use ASDF test-op with captured text."
  (cond
   ((and explicit-framework (not (string-equal explicit-framework "auto")))
    (values (intern (string-upcase explicit-framework) :keyword) nil))
   (t
    (multiple-value-bind (framework matched declared-by)
        (when (stringp system-name) (%detect-from-asdf-deps system-name))
      (declare (ignore matched))
      (cond
       (framework (values framework declared-by))
       ((%zebra-package) (values :zebra nil))
       ((find-package :rove) (values :rove nil))
       ((find-package :fiveam) (values :fiveam nil))
       (t (values :asdf nil)))))))

;;; ---------------------------------------------------------------------------
;;; Source Location Lookup
;;;
;;; Used by Zebra and FiveAM extractors to attach file + line to each
;;; failed test. sb-introspect:find-definition-sources-by-name looks up the
;;; defun generated by define-test (Zebra with :defun t, which is default)
;;; or the deftest function (FiveAM). Guard: (symbolp name) — string-named
;;; Zebra tests do not produce a defun and cannot be located.
;;; ---------------------------------------------------------------------------

(defun %test-source-location (name-symbol)
  "Return (list FILE LINE) for NAME-SYMBOL's :function definition, or NIL.
Uses sb-introspect to locate the defun generated by define-test (Zebra)
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
  (%log :info "test-runner" "framework" "asdf-fallback" "system" system-name)
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
           ;; asdf:test-system reports one bit: whether the perform method
           ;; signalled.  Nothing here reads the suite's own counts, so a run
           ;; that completed establishes only that test-op completed, never
           ;; that any test ran, and never that any test passed.  Reporting
           ;; that bit as "success" produced a green verdict over a suite
           ;; whose failures were sitting unread in the captured stdout, so
           ;; the key is gone and the outcome says what was established.
           (ht (make-ht "passed"      0
                        "failed"      (if success 0 1)
                        "pending"     0
                        "framework"   "asdf"
                        "duration_ms" duration-ms
                        "failed_tests" failed-tests
                        "counts_parsed" nil
                        "outcome"     (if success "unverified" "failed")
                        "content"
                        (text-content
                         (if success
                             (format nil "asdf test-op completed for ~A in ~D ms. \
NO test counts were parsed and this is NOT a pass; the run is unverified. \
Name the test system (~A/tests) to get counted results."
                                     system-name duration-ms system-name)
                             (format nil "asdf test-op FAILED for ~A: ~A"
                                     system-name failure-reason))))))
      (when (plusp (length stdout))
        (setf (gethash "stdout" ht) stdout))
      (when (plusp (length stderr))
        (setf (gethash "stderr" ht) stderr))
      (let ((debug-output (get-output-stream-string debug-stream)))
        (when (plusp (length debug-output))
          (setf (gethash "debug_output" ht) debug-output)))
      ht)))

;;; ---------------------------------------------------------------------------
;;; Zebra Backend
;;;
;;; Net-new (cl-mcp has no Zebra extractor). Walks the test-result tree
;;; returned by (zebra:test ...) to extract passed/failed/pending counts
;;; and per-failed-test detail including source locations via sb-introspect.
;;; ---------------------------------------------------------------------------

(defun %zebra-purge-ghost-suites (system-name)
  "Remove Zebra test registrations for all packages associated with
SYSTEM-NAME before reload. This prevents tests deleted from source from
haunting subsequent runs.

The framework's REMOVE-ALL-TESTS-IN-PACKAGE is looked up at run time rather
than called by name, so the engine carries no compile-time dependency on the
framework and carries no compile-time dependency on the framework. Walks the
ASDF :depends-on closure with a visited-set to cover all test sub-systems in a
package-inferred layout."
  (let* ((visited-systems (make-hash-table :test #'equal))
         (pkg (%zebra-package))
         (remove-sym
          (and pkg (find-symbol "REMOVE-ALL-TESTS-IN-PACKAGE" pkg)))
         (remove-fn (and remove-sym (fboundp remove-sym) remove-sym)))
    (labels ((purge-pkg (pkg-name)
               (when (and remove-fn (stringp pkg-name))
                 (let ((target (find-package (string-upcase pkg-name))))
                   (when target
                     (ignore-errors (funcall remove-fn target))))))
             (walk-system (name)
               (when (and (stringp name) (not (gethash name visited-systems)))
                 (setf (gethash name visited-systems) t)
                 (purge-pkg name)
                 (let ((sys (ignore-errors (asdf/system:find-system name nil))))
                   (when sys
                     (dolist
                         (dep
                          (ignore-errors (asdf/system:system-depends-on sys)))
                       (let ((dep-name
                              (if (consp dep)
                                  (second dep)
                                  dep)))
                         (when (stringp dep-name) (walk-system dep-name)))))))))
      (walk-system system-name))))

(defun %zebra-result-counts (result-obj)
  "Walk a Zebra test-result or parent-result tree and return
(values passed failed pending) counts.

A report's RESULTS vector lists every recorded result FLAT while each
test-result also nests its own children, so the same comparison-result is
reachable twice; the EQ visited set counts each result exactly once
(without it a 1-pass/1-fail suite reads as 2/2)."
  (let ((passed 0) (failed 0) (pending 0)
        (seen (make-hash-table :test 'eq)))
    (labels ((count-result (r)
               (unless (gethash r seen)
                 (setf (gethash r seen) t)
                 (let* ((pkg (%zebra-package))
                        (status-fn (and pkg (find-symbol "STATUS" pkg)))
                        (results-fn (and pkg (find-symbol "RESULTS" pkg)))
                        (status (and status-fn (ignore-errors (funcall status-fn r))))
                        (children (ignore-errors (funcall results-fn r))))
                   (if (and children (plusp (length children)))
                       ;; Parent result: recurse into children.
                       (dotimes (i (length children))
                         (count-result (aref children i)))
                       ;; Leaf result: count it.
                       (case status
                         (:passed (incf passed))
                         (:failed (incf failed))
                         (:skipped (incf pending))
                         (t)))))))
      (count-result result-obj))
    (values passed failed pending)))

(defun %zebra-extract-failures (result-obj)
  "Walk a Zebra test-result tree and collect failure details for each
:failed leaf result.  Returns a list of make-failure-detail hash-tables.

Parent result nodes carry the test name symbol as the NAME of their expression
(a ZEBRA:TEST object).  That symbol is propagated down to leaf failures so
source locations are populated for file-defined tests even when the leaf's own
expression is an assertion form rather than a test object.

A report lists every result FLAT while test-results also nest the same
children; the EQ visited set records each failure once.  The walk reaches
the nested copy (which carries its test's name) before the flat duplicate,
so the surviving entry is the well-named one."
  (let ((failures nil)
        (seen (make-hash-table :test 'eq)))
    (labels ((walk (r parent-test-sym)
               (when (gethash r seen)
                 (return-from walk))
               (setf (gethash r seen) t)
               (let* ((pkg (%zebra-package))
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
                                            (let* ((fmt-fn (and pkg
                                                                (find-symbol "FORMAT-RESULT"
                                                                             pkg)))
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

(defun %package-has-zebra-tests-p (pkg)
  "True when PKG (a package or NIL) has registered Zebra tests."
  (let* ((para (%zebra-package))
         (fn (and para (find-symbol "PACKAGE-TESTS" para))))
    (and fn pkg (ignore-errors (and (funcall fn pkg) t)))))

(defun %resolve-test-packages (system-name)
  "Resolve SYSTEM-NAME to the list of packages a Zebra run should cover.

1:1 fast path: a package named like the system that actually CONTAINS
registered tests.  Otherwise SYSTEM-NAME is treated as an umbrella (the
package-inferred norm: \"proj/tests\" has no same-named package; the tests
live in per-file subsystem packages): walk its :depends-on closure with a
visited set, keeping only subsystems whose ASDF primary system matches the
umbrella's — the constraint that keeps foreign dependencies like zebra
itself, which every test umbrella depends on, out of the run — and map each
kept subsystem to its same-named package when that package has tests.

Returns NIL when nothing is found; the caller decides the fallback.  This
resolver only READS system metadata — reload/purge policy stays with the
caller."
  (let ((direct (find-package (string-upcase system-name))))
    (if (%package-has-zebra-tests-p direct)
        (list direct)
        (let ((primary (ignore-errors (asdf:primary-system-name system-name)))
              (visited (make-hash-table :test #'equal))
              (packages '()))
          (when primary
            (labels ((walk (name)
                       (when (and (stringp name)
                                  (not (gethash name visited))
                                  (equal primary
                                         (ignore-errors
                                           (asdf:primary-system-name name))))
                         (setf (gethash name visited) t)
                         (let ((pkg (find-package (string-upcase name))))
                           (when (%package-has-zebra-tests-p pkg)
                             (push pkg packages)))
                         (let ((sys (ignore-errors (asdf:find-system name nil))))
                           (when sys
                             (dolist (dep (ignore-errors
                                            (asdf:system-depends-on sys)))
                               (let ((dep-name (if (consp dep) (second dep) dep)))
                                 (when (stringp dep-name)
                                   (walk dep-name)))))))))
              (walk system-name)))
          (nreverse packages)))))

(defun %run-zebra-tests (system-name)
  "Run tests using Zebra for SYSTEM-NAME and return the uniform envelope.
The entry point is looked up by symbol rather than called by name, so the
function carries no compile-time dependency on the framework.

The resolved package is pinned for the duration of the run.  Package resolution
and result extraction happen at different points and would otherwise be free to
disagree, and a disagreement would show up
as an empty run rather than as an error."
  (%log :info "test-runner" "framework" "zebra" "system" system-name)
  (let* ((pkg (%zebra-package))
         (*active-zebra-package* pkg)
         (test-fn (and pkg (find-symbol "TEST" pkg)))
         (context-var (and pkg (find-symbol "*CONTEXT*" pkg)))
         (parent-var  (and pkg (find-symbol "*PARENT*" pkg)))
         (targets (and test-fn (%resolve-test-packages system-name))))
    (unless test-fn
      (%log :warn "test-runner" "message" "Zebra not loaded; falling back to ASDF")
      (return-from %run-zebra-tests (%run-asdf-fallback system-name)))
    (unless targets
      (%log :warn "test-runner" "message"
            "no Zebra test packages resolve for system; falling back to ASDF"
            "system" system-name)
      (return-from %run-zebra-tests (%run-asdf-fallback system-name)))
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
            ;; objects do not register themselves into any outer Zebra context
            ;; (e.g. when run-tests is called from inside a define-test body
            ;; during our own test suite). *PARENT* is set by eval-in-context
            ;; :around on parent-result and causes new result objects to attach
            ;; to the outer test-result via initialize-instance :after.
            (let ((isolation-vars (remove nil (list context-var parent-var))))
              (setf result-obj
                    (progv isolation-vars (make-list (length isolation-vars))
                      ;; TARGETS is a list of packages; zebra:test on a
                      ;; list returns one merged report, so umbrella systems
                      ;; (several sub-packages) and the 1:1 case (singleton)
                      ;; take the same path.
                      (funcall test-fn targets)))))
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
                       :framework :zebra
                       :duration duration-ms)))
              (when (plusp (length stdout)) (setf (gethash "stdout" ht) stdout))
              (when (plusp (length stderr)) (setf (gethash "stderr" ht) stderr))
              (when (plusp (length debug-output)) (setf (gethash "debug_output" ht) debug-output))
              ht)
            ;; Normal path: extract counts + failures from the result tree.
            (multiple-value-bind (passed failed pending)
                (%zebra-result-counts result-obj)
              (let* ((failures (when (plusp failed)
                                 (%zebra-extract-failures result-obj)))
                     (ht (make-test-result
                          :passed passed :failed failed :pending pending
                          :failed-tests failures
                          :framework :zebra
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
;;; applied: cl-mcp/src/log:%log -> dsmr-mcp/src/log:%log.
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
  (%log :info "test-runner" "framework" "rove" "selected_tests"
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
        (%log :error "test-runner" "message" "rove:run-tests crashed"
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
  (%log :info "test-runner" "framework" "rove" "system" system-name)
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
        (%log :error "test-runner" "message" "rove:run crashed"
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
                    (%log :info "test-runner" "message"
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
                            (%log :warn "test-runner" "message" "sub-system test error"
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
;;; on the test name symbol (same strategy as Zebra).
;;; ---------------------------------------------------------------------------

(defun %run-fiveam-tests (system-name)
  "Run tests using FiveAM for SYSTEM-NAME and return structured results.
Only called when the :fiveam package is loaded. Falls back to ASDF text output
when FiveAM's expected API symbols cannot be found."
  (%log :info "test-runner" "framework" "fiveam" "system" system-name)
  (unless (find-package :fiveam)
    (return-from %run-fiveam-tests (%run-asdf-fallback system-name)))
  (let* ((fiveam-pkg (find-package :fiveam))
         (run-fn (and fiveam-pkg (find-symbol "RUN!" fiveam-pkg)))
         (get-suite-fn (and fiveam-pkg (find-symbol "GET-TEST" fiveam-pkg))))
    (unless (and run-fn get-suite-fn)
      (%log :warn "test-runner" "message"
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
                    (%log :warn "test-runner" "message"
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

(defun %ensure-system-loaded (system-name framework &optional test-system)
  "Purge stale framework test registrations then force-reload what the run needs.
Ghost-purge removes tests that were deleted from source so they cannot haunt
the subsequent run. ASDF:CLEAR-SYSTEM then ASDF:LOAD-SYSTEM ensures edits
made via lisp-edit-form are picked up before the run.

TEST-SYSTEM is the system that declared the test framework, when detection
found one.  It is loaded alongside SYSTEM-NAME because a library depends on
neither its tests nor their framework: loading only the name the caller asked
about leaves the framework package absent and the suites unregistered, and
every backend then degrades to the ASDF fallback.  SYSTEM-NAME is still
reloaded so an edit to the library is picked up whichever name was asked for."
  (let ((targets (remove-duplicates (remove nil (list system-name test-system))
                                    :test #'equal :from-end t)))
    ;; Ghost-purge: per-framework, before clearing/reloading.  The suites live
    ;; in the test system, so that is the name the purge has to be given.
    (let ((suite-system (or test-system system-name)))
      (case framework
        (:zebra (ignore-errors (%zebra-purge-ghost-suites suite-system)))
        (:rove  (ignore-errors (%rove-purge-ghost-suites suite-system)))))
    ;; Force-reload: clear ASDF's loaded state then re-load from source.
    (dolist (name targets)
      (let ((sys (asdf:find-system name nil)))
        (when sys
          (let ((asd-src (ignore-errors (asdf:system-source-file sys))))
            (asdf:clear-system name)
            (when asd-src
              (ignore-errors (asdf:load-asd asd-src)))))))
    (dolist (name targets)
      (asdf:load-system name))))

;;; ---------------------------------------------------------------------------
;;; Main Entry Points
;;; ---------------------------------------------------------------------------

(defun run-tests (system-name &key framework test tests
                                (timeout-seconds 300) (reload t))
  "Run tests for SYSTEM-NAME using the specified or auto-detected FRAMEWORK.
Returns a hash-table with structured results (the uniform envelope).

FRAMEWORK — optional string or keyword: \"zebra\", \"rove\", \"fiveam\",
  \"auto\" (or NIL). When absent or \"auto\", detection uses the ASDF
  :depends-on closure first.
TEST — optional string: run only this specific test (fully qualified).
TESTS — optional list/vector: run only these tests (array of strings).
TIMEOUT-SECONDS — default 300; the entire purge+reload+run is wrapped in
  a timeout (sb-ext:with-timeout on SBCL) inside the current process so a runaway test is
  interrupted.
RELOAD — default true; purges stale framework registrations and force-reloads
  the test system before running. Pass NIL to skip reload (for tight loops
  where you have already managed the reload externally)."
  (when (and test tests) (error "Specify either TEST or TESTS, not both"))
  (let ((effective-timeout (or timeout-seconds 300)))
    (handler-case
        (%with-timeout (effective-timeout)
          (multiple-value-bind (fw declaring-system)
              (detect-test-framework system-name
                                     (and framework
                                          (if (stringp framework) framework
                                              (symbol-name framework))))
            ;; The system the run is actually dispatched against.  Detection
            ;; may have found the framework on a test sibling, and that
            ;; sibling is where the suites are registered; running the
            ;; caller's name instead resolves no suites and falls through to
            ;; the ASDF fallback, which reports a pass over nothing.
            (let* ((target (or declaring-system system-name))
                   (selective-p (or test tests)))
            (%log :info "test-runner" "action" "run-tests"
                       "system" system-name
                       "target" target
                       "framework" (string-downcase (symbol-name fw))
                       "reload" reload
                       "test" (cond (test (princ-to-string test))
                                    (tests "selected")
                                    (t "all")))
            ;; Reload + ghost-purge unless opted out.
            (when reload
              (handler-case (%ensure-system-loaded system-name fw declaring-system)
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
            ;; Each arm returns the result AND the system the counts actually
            ;; came from, because those two can differ.  A branch that falls
            ;; back runs the name the caller gave, not the sibling detection
            ;; preferred, and a run over selected test names ran no system at
            ;; all.  Deriving the label from TARGET instead of from the arm
            ;; would let a result name a system nothing touched.
            (multiple-value-bind (result ran-system)
                (case fw
                  (:zebra
                   (values (%run-zebra-tests target) target))
                  (:rove
                   (if (find-package :rove)
                       (if selective-p
                           (let ((selected (if test
                                               (list (%coerce-test-symbol test))
                                               (%normalize-tests-arg tests))))
                             (values (%run-rove-selected-tests selected) nil))
                           (values (%run-rove-tests target) target))
                       (progn
                         (%log :warn "test-runner" "message"
                                    "Rove not loaded; falling back to ASDF")
                         (values (%run-asdf-fallback system-name) system-name))))
                  (:fiveam
                   (if (find-package :fiveam)
                       (values (%run-fiveam-tests target) target)
                       (progn
                         (%log :warn "test-runner" "message"
                                    "FiveAM not loaded; falling back to ASDF")
                         (values (%run-asdf-fallback system-name) system-name))))
                  (t
                   (values (%run-asdf-fallback system-name) system-name)))
              ;; Say which system the counts came from whenever it is not the
              ;; one asked about, so a redirected run is visible rather than
              ;; silently answering a different question.
              (when (and (hash-table-p result)
                         ran-system
                         (not (equal ran-system system-name)))
                (setf (gethash "tested_system" result) ran-system))
              result))))
      #+sbcl
      (sb-ext:timeout ()
        (%log :warn "test-runner.timeout" "system" system-name
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
