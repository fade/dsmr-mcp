;;;; tests/lisp-edit-form-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for VERB-20: lisp-edit-form structural editor.
;;;; Covers comment preservation on replace, parinfer auto-repair warning,
;;;; and dry-run preview faithfulness.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/lisp-edit-form-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/lisp-edit-form-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/lisp-edit-form
                #:edit-form
                #:validate-and-repair-content)
  (:import-from #:dsmr-mcp/src/state
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/lisp-edit-form)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/lisp-edit-form-test)

;;;; -------------------------------------------------------------------------
;;;; Helpers
;;;; -------------------------------------------------------------------------

(defun make-args (&rest kvs)
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k ht) v))
    ht))

;;;; -------------------------------------------------------------------------
;;;; Test: replace preserves surrounding comments and adjacent forms
;;;; -------------------------------------------------------------------------

(define-test replace-preserves-surrounding-comments
  "Replacing a defun leaves its leading comment and adjacent forms intact.
The replaced content appears in the file; surrounding text is untouched."
  (with-temp-project-root (session root)
    (let* ((source ";; Module header comment.

;; This is the foo function.
(defun foo (x)
  \"Foo docstring.\"
  (* x x))

(defun bar (y)
  \"Bar docstring.\"
  (+ y 1))
")
           (pn (write-fixture-file root "test.lisp" source))
           (new-body (format nil "(defun foo (x)~%  \"New foo.\"~%  (1+ x))"))
           (after (multiple-value-bind (updated warning changed-p)
                      (edit-form (namestring root) (namestring pn)
                                 "defun" "foo"
                                 "replace" new-body
                                 :dry-run nil)
                    (declare (ignore updated warning))
                    (assert changed-p () "edit-form did not change the file")
                    (uiop:read-file-string pn))))
      ;; The module header comment must survive.
      (true (search ";; Module header comment." after))
      ;; The foo-specific comment must survive (it is outside the form boundary).
      (true (search ";; This is the foo function." after))
      ;; The new body must be present.
      (true (search "New foo." after))
      (true (search "(1+ x)" after))
      ;; The old body must be gone.
      (false (search "(* x x)" after))
      ;; bar must still be present and intact.
      (true (search "defun bar" after))
      (true (search "(+ y 1)" after)))))

;;;; -------------------------------------------------------------------------
;;;; Test: missing close paren triggers parinfer auto-repair warning
;;;; -------------------------------------------------------------------------

(define-test missing-close-paren-triggers-parinfer-warning
  "Supplying content with a missing closing paren auto-repairs via parinfer
and the result carries a non-nil parinfer_warning (D-07)."
  (with-temp-project-root (session root)
    (let* ((source "(defun foo (x)
  (* x x))
")
           (pn (write-fixture-file root "test.lisp" source))
           ;; Intentionally missing the closing paren for defun.
           (bad-content (format nil "(defun foo (x)~%  (+ x 1)"))
           (result (edit-form (namestring root) (namestring pn)
                              "defun" "foo"
                              "replace" bad-content
                              :dry-run t)))
      ;; Must report would_change = t
      (true (gethash "would_change" result))
      ;; Must carry a parinfer_warning (D-07).
      (true (gethash "parinfer_warning" result))
      ;; The parinfer warning must mention added delimiters.
      (true (search "parinfer" (string-downcase (gethash "parinfer_warning" result))))
      ;; The preview must contain the repaired content.
      (true (search "(+ x 1)" (gethash "preview" result))))))

;;;; -------------------------------------------------------------------------
;;;; Test: dry-run preview text matches the file content from a real apply
;;;; -------------------------------------------------------------------------

(define-test dry-run-preview-matches-apply
  "The dry_run preview is produced by the same code path as the real apply,
so the preview text is byte-identical to the file content after applying
the same edit (D-07 faithfulness)."
  (with-temp-project-root (session root)
    (let* ((source "(defun foo (x)
  (* x x))

(defun bar (y)
  y)
")
           (new-content (format nil "(defun foo (x)~%  (- x 1))"))
           ;; Dry-run first: capture preview.
           (pn-dry (write-fixture-file root "dry.lisp" source))
           (dry-result (edit-form (namestring root) (namestring pn-dry)
                                  "defun" "foo"
                                  "replace" new-content
                                  :dry-run t))
           (preview-text (gethash "preview" dry-result))
           ;; Real apply on a separate copy.
           (pn-real (write-fixture-file root "real.lisp" source)))
      (edit-form (namestring root) (namestring pn-real)
                 "defun" "foo"
                 "replace" new-content
                 :dry-run nil)
      (let ((applied-text (uiop:read-file-string pn-real)))
        ;; The dry-run preview must equal the applied file content exactly.
        (is string= applied-text preview-text)))))

;;;; -------------------------------------------------------------------------
;;;; Test: tool-handle no-root guard
;;;; -------------------------------------------------------------------------

(define-test tool-handle-no-root-returns-error
  "When no project root is set the lisp-edit-form tool returns a typed error
rather than crashing (D-16 no-root guard)."
  (let* ((session (dsmr-mcp/src/state:make-session :id "no-root" :project-root nil))
         (tool    (get-tool-instance session "lisp-edit-form"))
         (args    (make-args "file_path" "/tmp/x.lisp"
                             "form_type" "defun"
                             "form_name" "foo"
                             "operation" "replace"
                             "content"   "(defun foo () nil)"))
         (resp    (tool-handle tool 1 args))
         (res     (gethash "result" resp)))
    (true (gethash "isError" res))
    (is string= "project-root-not-set" (gethash "error_type" res))))
