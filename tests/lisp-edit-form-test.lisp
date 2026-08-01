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
  (:import-from #:dsmr-mcp/src/parinfer
                #:apply-indent-mode)
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

;;;; -------------------------------------------------------------------------
;;;; Test: compound name specs (e.g. sb-alien:define-alien-routine) are matchable
;;;; -------------------------------------------------------------------------

(define-test compound-name-spec-is-matchable
  "A top-level form whose name is a compound spec list — such as the
(\"c-name\" lisp-name) shape used by sb-alien:define-alien-routine — is located
by its Lisp-side symbol name, not stringified as the whole list. A dry-run
replace targeting the Lisp name locates the form and previews correctly."
  (with-temp-project-root (session root)
    (let* ((source ";; Alien bindings.
(sb-alien:define-alien-routine (\"sendmsg\" %scm-sendmsg) sb-alien:long
  (fd sb-alien:int)
  (msg sb-alien:system-area-pointer)
  (flags sb-alien:int))

(defun neighbor (x)
  (1+ x))
")
           (pn (write-fixture-file root "alien.lisp" source))
           (new-content (format nil
                                "(sb-alien:define-alien-routine (\"sendmsg\" %scm-sendmsg) sb-alien:long~%  (fd sb-alien:int)~%  (msg sb-alien:system-area-pointer)~%  (flags sb-alien:unsigned-int))"))
           ;; This call must NOT signal \"Form ... not found\" — the compound
           ;; name spec has to resolve to the Lisp-side symbol %scm-sendmsg.
           (result (edit-form (namestring root) (namestring pn)
                              "define-alien-routine" "%scm-sendmsg"
                              "replace" new-content
                              :dry-run t)))
      ;; The form was located and a real replacement would change the file.
      (true (gethash "would_change" result))
      ;; The preview carries the new content.
      (true (search "sb-alien:unsigned-int" (gethash "preview" result)))
      ;; The old element type is gone from the replaced form's preview.
      (false (search "(flags sb-alien:int)" (gethash "preview" result)))
      ;; The surrounding form is untouched in the preview.
      (true (search "defun neighbor" (gethash "preview" result))))))

;;;; -------------------------------------------------------------------------
;;;; Test: %definition-candidates pulls symbols out of a compound name spec
;;;; -------------------------------------------------------------------------

(define-test definition-candidates-extracts-symbols-from-name-spec
  "%definition-candidates yields a candidate per symbol in a compound name
spec (ignoring C-name strings), while the defstruct-with-options and
(setf name) clauses keep taking precedence."
  ;; Compound spec: the Lisp-side symbol is a candidate; the C-name string is not.
  (is equal '("%scm-sendmsg")
      (dsmr-mcp/src/lisp-edit-form-core::%definition-candidates
       '(sb-alien:define-alien-routine ("sendmsg" %scm-sendmsg) sb-alien:long)
       "define-alien-routine"))
  ;; (setf name) still resolves through its dedicated clause.
  (is equal '("foo" "(setf foo)")
      (dsmr-mcp/src/lisp-edit-form-core::%definition-candidates
       '(defun (setf foo) (v x)) "defun"))
  ;; defstruct-with-options still uses just the struct name.
  (is equal '("point")
      (dsmr-mcp/src/lisp-edit-form-core::%definition-candidates
       '(defstruct (point (:conc-name pt-)) x y) "defstruct"))
  ;; A bare-symbol name is unchanged.
  (is equal '("frobnicate")
      (dsmr-mcp/src/lisp-edit-form-core::%definition-candidates
       '(defun frobnicate (a b)) "defun")))

(define-test two-top-level-forms-in-one-call-is-refused
  "Content holding two top-level forms is refused, and the file is left byte
for byte as it was.

Parinfer repairs a missing delimiter; it cannot repair a payload that is simply
not one form, and asked to try it answers confidently and wrongly. It reads the
payload's indentation as structure, so a docstring continuation flush at column
zero looks like a dedent back to top level: a close paren lands inside the
docstring, the form's own closing paren then looks like an excess one and is
dropped, and the call still reports success. The refusal is what keeps the file
readable."
  (with-temp-project-root (session root)
    (let* ((source "(in-package #:cl-user)

(defun alpha (x)
  \"Alpha docstring.\"
  (* x 2))

(defun gamma (z)
  \"Gamma stays put.\"
  z)
")
           (pn (write-fixture-file root "two-form.lisp" source))
           ;; Two top-level forms in one payload. The second carries a
           ;; multi-line docstring whose continuation lines sit at column zero.
           (two-forms "(defun alpha (x)
  \"Alpha docstring.\"
  (* x 2))

(defun beta (y)
  \"First line of beta docstring.
Second line, flush at column zero.
Third line.\"
  (+ y 1))"))
      ;; The call must refuse outright.
      (fail (edit-form (namestring root) (namestring pn)
                       "defun" "alpha" "replace" two-forms
                       :dry-run nil))
      (let ((after (uiop:read-file-string pn)))
        ;; Nothing was written.
        (is string= source after)
        ;; In particular no close paren was smuggled into a docstring.
        (false (search "docstring.)" after))
        ;; And the form below the target still stands on its own.
        (true (search "(defun gamma (z)" after))))))

(define-test string-continuation-lines-are-not-read-as-indentation
  "apply-indent-mode leaves a multi-line string literal alone.

Leading whitespace on a line that begins inside a string is text, not
indentation. Read as indentation, a docstring continuation flush at column zero
dedents the enclosing form closed: the repair puts a close paren inside the
docstring and then drops the form's real one. Repairing the form below has to
append the single missing paren at the end and change nothing else."
  (let* ((paren-short "(defun alpha (x)
  \"First line of the docstring.
Second line, flush at column zero.
Third line.\"
  (* x 2)")
         (repaired (apply-indent-mode paren-short)))
    ;; No close paren was smuggled into the docstring.
    (false (search "docstring.)" repaired))
    ;; The repair is exactly one appended delimiter, nothing else moved.
    (is string= (concatenate 'string paren-short ")") repaired)))
