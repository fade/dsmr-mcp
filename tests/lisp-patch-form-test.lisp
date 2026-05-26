;;;; tests/lisp-patch-form-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for VERB-21: lisp-patch-form scoped exact-text replacement.
;;;; Covers the exact-once invariant, fail-hard structural break semantics
;;;; (file must not be written on error), and the basic replace path.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/lisp-patch-form-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/lisp-patch-form-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/lisp-patch-form
                #:patch-form
                #:patch-operation-error
                #:patch-operation-reason)
  (:import-from #:dsmr-mcp/src/state
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/lisp-patch-form)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/lisp-patch-form-test)

;;;; -------------------------------------------------------------------------
;;;; Helpers
;;;; -------------------------------------------------------------------------

(defun make-args (&rest kvs)
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k ht) v))
    ht))

;;;; -------------------------------------------------------------------------
;;;; Test: exact match replaces once
;;;; -------------------------------------------------------------------------

(define-test exact-match-replaces-once
  "Patching old_text to new_text within the target form succeeds and the
file on disk reflects the single replacement."
  (with-temp-project-root (session root)
    (let* ((source "(defun foo (x)
  ;; compute result
  (* x x))
")
           (pn (write-fixture-file root "test.lisp" source)))
      (multiple-value-bind (updated changed-p)
          (patch-form (namestring root) (namestring pn)
                      "defun" "foo"
                      "(* x x)" "(+ x x)"
                      :dry-run nil)
        (declare (ignore updated))
        ;; Must report changed.
        (true changed-p))
      (let ((after (uiop:read-file-string pn)))
        ;; New text is present.
        (true (search "(+ x x)" after))
        ;; Old text is gone.
        (false (search "(* x x)" after))
        ;; Comment must be preserved (patch does not touch surrounding text).
        (true (search ";; compute result" after))))))

;;;; -------------------------------------------------------------------------
;;;; Test: structural break fails and does not write
;;;; -------------------------------------------------------------------------

(define-test structural-break-fails-and-writes-nothing
  "A patch whose new_text unbalances the form raises patch-operation-error
and the file on disk is byte-identical to before (D-08: no write on break)."
  (with-temp-project-root (session root)
    (let* ((source "(defun foo (x)
  (+ x 1))
")
           (pn (write-fixture-file root "test.lisp" source))
           (before (uiop:read-file-string pn))
           (error-signalled nil))
      ;; Replace closing paren with something that breaks balance.
      (handler-case
          (patch-form (namestring root) (namestring pn)
                      "defun" "foo"
                      "(+ x 1))" "(+ x 1"
                      :dry-run nil)
        (patch-operation-error ()
          (setf error-signalled t)))
      ;; The error must have been signalled.
      (true error-signalled)
      ;; The file must be byte-identical to before the patch attempt.
      (let ((after (uiop:read-file-string pn)))
        (is string= before after)))))

;;;; -------------------------------------------------------------------------
;;;; Test: ambiguous old_text (matches twice) raises an error
;;;; -------------------------------------------------------------------------

(define-test ambiguous-old-text-errors
  "When old_text matches more than once in the form, patch-operation-error is
signalled (the exact-once invariant, D-08)."
  (with-temp-project-root (session root)
    (let* ((source "(defun foo (x)
  (+ x 1)
  (+ x 1))
")
           (pn (write-fixture-file root "test.lisp" source))
           (error-signalled nil)
           (reason nil))
      (handler-case
          (patch-form (namestring root) (namestring pn)
                      "defun" "foo"
                      "(+ x 1)" "(* x 2)"
                      :dry-run nil)
        (patch-operation-error (e)
          (setf error-signalled t
                reason (patch-operation-reason e))))
      ;; Must signal the error.
      (true error-signalled)
      ;; The reason must mention matching multiple times.
      (true (search "matches" reason)))))

;;;; -------------------------------------------------------------------------
;;;; Test: dry-run does not write
;;;; -------------------------------------------------------------------------

(define-test dry-run-returns-preview-without-writing
  "patch-form dry_run=t returns a preview hash-table and does NOT modify the
file on disk."
  (with-temp-project-root (session root)
    (let* ((source "(defun foo (x)
  (+ x 1))
")
           (pn (write-fixture-file root "test.lisp" source))
           (before (uiop:read-file-string pn))
           (result (patch-form (namestring root) (namestring pn)
                               "defun" "foo"
                               "(+ x 1)" "(* x 2)"
                               :dry-run t)))
      ;; Result must be a hash-table with preview.
      (true (hash-table-p result))
      (true (gethash "would_change" result))
      (true (search "(* x 2)" (gethash "preview" result)))
      ;; File must be unchanged.
      (let ((after (uiop:read-file-string pn)))
        (is string= before after)))))

;;;; -------------------------------------------------------------------------
;;;; Test: tool-handle no-root guard
;;;; -------------------------------------------------------------------------

(define-test tool-handle-no-root-returns-error
  "When no project root is set the lisp-patch-form tool returns a typed error
rather than crashing (D-16 no-root guard)."
  (let* ((session (dsmr-mcp/src/state:make-session :id "no-root" :project-root nil))
         (tool    (get-tool-instance session "lisp-patch-form"))
         (args    (make-args "file_path" "/tmp/x.lisp"
                             "form_type" "defun"
                             "form_name" "foo"
                             "old_text"  "x"
                             "new_text"  "y"))
         (resp    (tool-handle tool 1 args))
         (res     (gethash "result" resp)))
    (true (gethash "isError" res))
    (is string= "project-root-not-set" (gethash "error_type" res))))

(define-test patch-validation-accepts-absent-package-symbols
  "Structural validation of a patched form must not reject forms that contain
package-qualified symbols from packages absent in the dispatcher image.
call-with-lenient-packages must be active during the read-from-string call
so that dsmr-mcp/src/cst::some-fn or similar qualified symbols do not produce
a false patch-operation-error."
  (with-temp-project-root (session root)
    (let* ((source "(defun foo (x)
  (format t \"hello ~A\" x))
")
           (pn (write-fixture-file root "test.lisp" source))
           (error-signalled nil))
      ;; Patch the body to contain a fully-qualified symbol from a package
      ;; that is not in the current image.  If %validate-form-parseable is not
      ;; wrapped in call-with-lenient-packages, this would incorrectly signal
      ;; patch-operation-error with "package does not exist".
      (handler-case
          (patch-form (namestring root) (namestring pn)
                      "defun" "foo"
                      "(format t \"hello ~A\" x)"
                      "(nonexistent-pkg::do-thing x)"
                      :dry-run t)
        (patch-operation-error (e)
          (setf error-signalled t)
          ;; Log the reason for debugging if this unexpectedly fails
          (format *test-debug-output* "unexpected patch error: ~A~%"
                  (patch-operation-reason e))))
      ;; The dry-run must succeed: lenient packages means absent-package
      ;; symbols are read without signalling.
      (false error-signalled
             "patch validation must not reject a form with absent-package qualified symbols"))))
