;;;; tests/clgrep-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute test suite for VERB-08: clgrep-search.
;;;; Tests: regex find with form context, .gitignore exclusion, form_types
;;;; filtering, and the structural form_pattern mode (D-11).

;; Package evolution guard — delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/clgrep-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/clgrep-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file)
  (:import-from #:dsmr-mcp/src/clgrep
                #:semantic-grep
                #:collect-target-files
                #:match-form-pattern)
  (:import-from #:dsmr-mcp/src/cst
                #:parse-top-level-forms
                #:cst-node-kind
                #:cst-node-value)
  ;; Force registration of clgrep-search-tool in *tool-classes*
  (:import-from #:dsmr-mcp/src/tools/clgrep-search
                #:clgrep-search-tool)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:get-tool-instance))

(in-package #:dsmr-mcp/tests/clgrep-test)

;;;; ---------------------------------------------------------------------------
;;;; Helper: make a session-owned tool instance
;;;; ---------------------------------------------------------------------------

(defun %make-clgrep-session (root)
  (make-session :id "clgrep-test" :project-root root))

;;;; ---------------------------------------------------------------------------
;;;; Test: regex fast path finds a known pattern
;;;; ---------------------------------------------------------------------------

(define-test finds-pattern-without-system-load
  ;; Write two small Lisp files with known defuns; grep for one of them.
  ;; The search must work without loading any ASDF system (image-independent).
  (with-temp-project-root (_session root)
    (write-fixture-file root "alpha.lisp"
      "(defpackage #:alpha (:use #:cl))
(in-package #:alpha)

(defun greet (name)
  \"Say hello.\"
  (format nil \"Hello, ~A!\" name))

(defmacro with-greeting (name &body body)
  `(let ((greeter (greet ,name))) ,@body))
")
    (write-fixture-file root "beta.lisp"
      "(defpackage #:beta (:use #:cl))
(in-package #:beta)

(defun farewell (name)
  \"Say goodbye.\"
  (format nil \"Goodbye, ~A!\" name))
")
    ;; Search for \"greet\" — should find it in alpha.lisp with signature context
    (let ((results (semantic-grep root "greet"
                                  :recursive t
                                  :session-root root)))
      (true (>= (length results) 1))
      ;; Every hit should carry a file path ending in .lisp
      (dolist (r results)
        (let ((file (cdr (assoc :file r))))
          (true (and (stringp file) (plusp (length file))))))
      ;; At least one hit should have form-type "defun"
      (true (some (lambda (r) (equal (cdr (assoc :form-type r)) "defun"))
                  results))
      ;; The hit in alpha.lisp should carry the greet signature
      (let ((alpha-hits (remove-if-not
                         (lambda (r)
                           (search "alpha" (cdr (assoc :file r)) :test #'char-equal))
                         results)))
        (true (some (lambda (r) (search "greet" (or (cdr (assoc :signature r)) "")))
                    alpha-hits))))))

;;;; ---------------------------------------------------------------------------
;;;; Test: .gitignore-listed file is excluded from results
;;;; ---------------------------------------------------------------------------

(define-test gitignore-listed-file-excluded
  (with-temp-project-root (_session root)
    ;; Write two Lisp files and gitignore one of them
    (write-fixture-file root "visible.lisp"
      "(defun visible-fn () t)")
    (write-fixture-file root "hidden.lisp"
      "(defun hidden-fn () :secret)")
    ;; .gitignore lists hidden.lisp
    (write-fixture-file root ".gitignore"
      "hidden.lisp
")
    ;; Search for hidden-fn — should find nothing (file is gitignored)
    (let ((results (semantic-grep root "hidden-fn"
                                  :recursive t
                                  :session-root root)))
      (is = 0 (length results)))
    ;; Visible file is still findable
    (let ((results (semantic-grep root "visible-fn"
                                  :recursive t
                                  :session-root root)))
      (true (>= (length results) 1)))))

;;;; ---------------------------------------------------------------------------
;;;; Test: form_types filter restricts results to the specified type
;;;; ---------------------------------------------------------------------------

(define-test form-types-filter-restricts-results
  (with-temp-project-root (_session root)
    (write-fixture-file root "mixed.lisp"
      "(defpackage #:mixed (:use #:cl))
(in-package #:mixed)

(defvar *count* 0)

(defun counter () *count*)

(defmacro increment () `(incf *count*))
")
    ;; Without filter: all three forms containing \"count\" or \"*count*\" are hits
    (let ((all-results (semantic-grep root "count"
                                      :recursive t
                                      :session-root root)))
      (true (>= (length all-results) 1)))
    ;; With defun filter: only the defun hit
    (let ((defun-results (semantic-grep root "count"
                                        :recursive t
                                        :form-types '("defun")
                                        :session-root root)))
      (dolist (r defun-results)
        (let ((ft (cdr (assoc :form-type r))))
          (is equal "defun" ft))))
    ;; With defmacro filter: only macro hits
    (let ((macro-results (semantic-grep root "count"
                                        :recursive t
                                        :form-types '("defmacro")
                                        :session-root root)))
      (dolist (r macro-results)
        (let ((ft (cdr (assoc :form-type r))))
          (is equal "defmacro" ft))))))

;;;; ---------------------------------------------------------------------------
;;;; Test: structural form_pattern matches defun shapes (D-11)
;;;; ---------------------------------------------------------------------------

(define-test structural-pattern-matches-defun-shape
  (with-temp-project-root (_session root)
    (write-fixture-file root "shapes.lisp"
      "(defpackage #:shapes (:use #:cl))
(in-package #:shapes)

(defun area (r)
  (* r r 3.14159))

(defmacro with-area (r &body body)
  `(let ((area (area ,r))) ,@body))

(defvar *pi* 3.14159)
")
    ;; Structural search for (defun _ ...): should match defun only, not defmacro
    (let ((results (semantic-grep root nil
                                  :form-pattern "(defun _ ...)"
                                  :recursive t
                                  :session-root root)))
      (true (>= (length results) 1))
      ;; Every result must be a defun
      (dolist (r results)
        (let ((ft (cdr (assoc :form-type r))))
          (is equal "defun" ft))))
    ;; Structural search for (defmacro _ ...): should match only defmacro
    (let ((results (semantic-grep root nil
                                  :form-pattern "(defmacro _ ...)"
                                  :recursive t
                                  :session-root root)))
      (true (>= (length results) 1))
      (dolist (r results)
        (is equal "defmacro" (cdr (assoc :form-type r)))))
    ;; (defvar _ ...) should match the defvar
    (let ((results (semantic-grep root nil
                                  :form-pattern "(defvar _ ...)"
                                  :recursive t
                                  :session-root root)))
      (true (>= (length results) 1))
      (dolist (r results)
        (is equal "defvar" (cdr (assoc :form-type r)))))))

;;;; ---------------------------------------------------------------------------
;;;; Test: clgrep-search-tool is registered and works end-to-end
;;;; ---------------------------------------------------------------------------

(define-test tool-registered-and-no-root-guard
  ;; clgrep-search-tool must be in *tool-classes* after load
  (true (gethash "clgrep-search"
                 (symbol-value
                  (find-symbol "*TOOL-CLASSES*"
                               (find-package "DSMR-MCP/SRC/TOOLS/BASE")))))
  ;; Without a root set, tool-handle returns a typed error
  (let* ((session (make-session :id "no-root"))
         (tool    (get-tool-instance session "clgrep-search"))
         (result  (tool-handle tool "req-1"
                                (make-ht "pattern" "defun"))))
    (is equal t (gethash "isError" (gethash "result" result)))
    (is equal "project-root-not-set"
        (gethash "error_type" (gethash "result" result)))))

(define-test nil-session-root-signals-error
  "semantic-grep must signal an error when session-root is NIL rather than
silently reading all files in the walk root without sandbox validation.
Regression for the SAFETY-02 bypass when the session-root keyword is omitted."
  (with-temp-project-root (_session root)
    (write-fixture-file root "sample.lisp"
      "(defun something () t)")
    ;; Calling without session-root must signal an error — not return results
    (let ((errored nil))
      (handler-case
          (semantic-grep root "something")
        (error (e)
          (setf errored t)
          ;; The error message should mention session-root
          (true (search "session-root" (princ-to-string e)))))
      (true errored
            "semantic-grep must signal an error when session-root is NIL"))))
