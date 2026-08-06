;;;; tests/fs/lisp-read-file-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for VERB-06: lisp-read-file tool and read-file-collapsed.
;;;; - Collapsed view shows signatures only with in-package in full.
;;;; - name_pattern expands exactly the matching form.
;;;; - Raw mode slices by offset/limit and appends a pagination footer.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/fs/lisp-read-file-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/fs/lisp-read-file-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/lisp-read-file
                #:read-file-collapsed)
  (:import-from #:dsmr-mcp/src/state
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/fs/lisp-read-file-test)

;;; Sample Lisp source used throughout these tests.

(defparameter *sample-lisp*
  "(in-package #:cl-user)

(defun foo (x y)
  \"Foo docstring.\"
  (+ x y))

(defun bar (z)
  \"Bar docstring.\"
  (* z z))

(defvar *counter* 0
  \"A counter.\")
"
  "Small Lisp snippet with two defuns, an in-package, and a defvar.")

;;;; -------------------------------------------------------------------------
;;;; Unit tests for read-file-collapsed
;;;; -------------------------------------------------------------------------

(define-test collapsed-view-shows-signatures-only
  "Collapsed mode renders definition signatures with '...' body markers
and includes in-package forms in full."
  (multiple-value-bind (display mode meta)
      (read-file-collapsed *sample-lisp*
                           :collapsed t
                           :source-path #p"test.lisp")
    ;; mode must be lisp-collapsed (no pattern matched)
    (is string= "lisp-collapsed" mode)
    ;; The display must contain collapsed signatures for both defuns.
    ;; A collapsed defun looks like "(defun name args ...)"
    (true (search "defun foo" display))
    (true (search "..." display))
    (true (search "defun bar" display))
    ;; in-package must appear in full (not collapsed to "(in-package ...)")
    (true (search "(in-package" display))
    ;; in-package form should not have "..." appended -- it's shown in full
    (false (search "(in-package ...)" display))
    ;; meta must report 4 total forms (in-package + foo + bar + *counter*)
    (is = 4 (gethash "total_forms" meta))
    ;; in-package is always expanded; no pattern so only 1 form expanded.
    (is = 1 (gethash "expanded_forms" meta))))

(define-test name-pattern-expands-only-matching-form
  "name_pattern regex expands exactly the matching definition; mode becomes
lisp-snippet and expanded_forms is 1."
  (multiple-value-bind (display mode meta)
      (read-file-collapsed *sample-lisp*
                           :collapsed t
                           :name-pattern "^foo$"
                           :source-path #p"test.lisp")
    ;; mode must be lisp-snippet because a pattern matched
    (is string= "lisp-snippet" mode)
    ;; in-package + foo both expanded = 2
    (is = 2 (gethash "expanded_forms" meta))
    ;; The expanded foo body must appear (raw form text)
    (true (search "(+ x y)" display))
    ;; bar must still be collapsed (signature only)
    (true (search "defun bar" display))
    ;; bar's body must not appear in the output
    (false (search "(* z z)" display))))

(define-test raw-mode-slices-by-offset-limit
  "collapsed=nil with limit=3 returns only 3 lines and appends a pagination
footer.  meta reports truncated=t and the correct total_lines."
  (multiple-value-bind (display mode meta)
      (read-file-collapsed *sample-lisp*
                           :collapsed nil
                           :offset 0
                           :limit 3)
    (is string= "raw" mode)
    ;; Footer is present when more lines remain
    (true (search "[Showing lines" display))
    ;; Truncated flag is true (CL boolean, not JSON)
    (true (gethash "truncated" meta))
    ;; total_lines reflects the full file (more than 3 lines)
    (let ((total (gethash "total_lines" meta)))
      ;; zebra (is > expected actual): (> 3 total) must be false, so test (> total 3)
      (is > 3 total))))

;;;; -------------------------------------------------------------------------
;;;; Tool integration tests (via tool-handle)
;;;; -------------------------------------------------------------------------

(define-test tool-handle-collapsed-view-via-fixture
  "The lisp-read-file MCP tool returns a collapsed view for a .lisp file
written under the session root."
  (with-temp-project-root (session root)
    (let* ((pn       (write-fixture-file root "example.lisp" *sample-lisp*))
           (abs-path (namestring pn))
           (tool     (get-tool-instance session "lisp-read-file"))
           (args     (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash "path" h) abs-path)
                       h))
           (resp     (tool-handle tool 1 args))
           (res      (gethash "result" resp)))
      ;; No error
      (false (gethash "isError" res))
      ;; mode is lisp-collapsed
      (is string= "lisp-collapsed" (gethash "mode" res))
      ;; text contains the collapsed signature
      (let ((text (gethash "text" res)))
        (true (search "defun foo" text))
        (true (search "..." text))))))

(define-test tool-handle-no-root-returns-error
  "When no project root is set the tool returns a typed error rather than
crashing."
  ;; Build a session with nil root.
  (let* ((session (dsmr-mcp/src/state:make-session :id "no-root" :project-root nil))
         (tool    (get-tool-instance session "lisp-read-file"))
         (args    (let ((h (make-hash-table :test 'equal)))
                    (setf (gethash "path" h) "/tmp/anything.lisp")
                    h))
         (resp    (tool-handle tool 1 args))
         (res     (gethash "result" resp)))
    (true (gethash "isError" res))
    (is string= "project-root-not-set" (gethash "error_type" res))))
