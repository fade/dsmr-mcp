;;;; tests/validate-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for VERB-07: lisp-check-parens dual-pass paren/reader validator.
;;;; Covers: balanced code, unbalanced code, paren inside string/comment/block-
;;;; comment ignored (D-17), character literal ignored, reader error detected.

;; Package evolution guard — delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/validate-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/validate-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/validate
                #:scan-parens
                #:try-reader-check)
  (:import-from #:dsmr-mcp/src/state
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  ;; Force tool registration before any test body
  (:import-from #:dsmr-mcp/src/tools/lisp-check-parens)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/validate-test)

;;;; -------------------------------------------------------------------------
;;;; Helpers
;;;; -------------------------------------------------------------------------

(defun make-args (&rest kvs)
  "Build an equal-keyed hash table from alternating key/value pairs."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k ht) v))
    ht))

;;;; -------------------------------------------------------------------------
;;;; scan-parens unit tests
;;;; -------------------------------------------------------------------------

(define-test balanced-code-reports-ok
  "scan-parens returns :ok t for a well-formed top-level form."
  (let ((result (scan-parens "(defun f (x) (* x x))")))
    (true (getf result :ok))))

(define-test unbalanced-code-reports-kind-and-position
  "scan-parens returns :ok nil with kind=unclosed and a position for an
unclosed open paren."
  (let ((result (scan-parens "(defun f (x")))
    (false (getf result :ok))
    (is string= "unclosed" (getf result :kind))
    (true (integerp (getf result :offset)))
    (true (integerp (getf result :line)))
    (true (integerp (getf result :column)))))

(define-test paren-inside-string-is-ignored
  "A close paren inside a double-quoted string does not affect paren balance."
  (let ((result (scan-parens "(list \")\")")))
    (true (getf result :ok))))

(define-test paren-inside-line-comment-is-ignored
  "A close paren on a ; comment line does not affect paren balance."
  (let* ((src (format nil "(defun f ()~%  ; ) this is a comment~%  t)"))
         (result (scan-parens src)))
    (true (getf result :ok))))

(define-test paren-inside-block-comment-is-ignored
  "Delimiters inside a #| |# block comment do not affect paren balance."
  (let* ((src "(defun f () #| ) |# t)")
         (result (scan-parens src)))
    (true (getf result :ok))))

(define-test char-literal-open-paren-is-ignored
  "#\\( does not count as an open paren; the expression remains balanced."
  (let ((result (scan-parens "(list #\\( 1)")))
    (true (getf result :ok))))

;;;; -------------------------------------------------------------------------
;;;; try-reader-check unit tests
;;;; -------------------------------------------------------------------------

(define-test reader-error-detected
  "try-reader-check catches a reader error in balanced-but-unreadable code
(a bad dispatch character #$)."
  (let ((result (try-reader-check "(list #$ 1)")))
    ;; A non-nil plist means a reader error was found
    (true result)
    (is string= "reader-error" (getf result :kind))))

(define-test reader-check-clean-for-valid-code
  "try-reader-check returns nil (clean) for well-formed Lisp."
  (false (try-reader-check "(defun f (x) (+ x 1))")))

;;;; -------------------------------------------------------------------------
;;;; lisp-check-parens tool (via tool-handle) — inline code path
;;;; -------------------------------------------------------------------------

(define-test tool-balanced-code-returns-ok-true
  "lisp-check-parens tool returns ok=true for balanced inline code."
  (let* ((session (dsmr-mcp/src/state:make-session :id "test"))
         (tool    (get-tool-instance session "lisp-check-parens"))
         (resp    (tool-handle tool 1 (make-args "code" "(defun f (x) x)")))
         (res     (gethash "result" resp)))
    (true  (gethash "ok" res))
    (false (gethash "isError" res))))

(define-test tool-unbalanced-code-returns-ok-false-with-kind
  "lisp-check-parens tool returns ok=false with kind and position for
an unclosed paren in inline code."
  (let* ((session (dsmr-mcp/src/state:make-session :id "test"))
         (tool    (get-tool-instance session "lisp-check-parens"))
         (resp    (tool-handle tool 1 (make-args "code" "(defun f (x")))
         (res     (gethash "result" resp)))
    (false (gethash "ok" res))
    (true  (stringp (gethash "kind" res)))
    (true  (hash-table-p (gethash "position" res)))))

(define-test tool-path-xor-code-both-is-error
  "lisp-check-parens tool returns an error when both path and code are given."
  (let* ((session (dsmr-mcp/src/state:make-session :id "test"))
         (tool    (get-tool-instance session "lisp-check-parens"))
         (resp    (tool-handle tool 1 (make-args "code" "(foo)" "path" "/tmp/x.lisp")))
         (res     (gethash "result" resp)))
    (true  (gethash "isError" res))
    (is string= "invalid-argument" (gethash "error_type" res))))

(define-test tool-neither-path-nor-code-is-error
  "lisp-check-parens tool returns an error when neither path nor code is given."
  (let* ((session (dsmr-mcp/src/state:make-session :id "test"))
         (tool    (get-tool-instance session "lisp-check-parens"))
         (resp    (tool-handle tool 1 (make-args)))
         (res     (gethash "result" resp)))
    (true  (gethash "isError" res))
    (is string= "invalid-argument" (gethash "error_type" res))))

;;;; -------------------------------------------------------------------------
;;;; lisp-check-parens tool — file path branch
;;;; -------------------------------------------------------------------------

(define-test tool-file-path-balanced-returns-ok-true
  "lisp-check-parens tool reads a balanced file under the project root and
returns ok=true."
  (with-temp-project-root (session root)
    (let* ((pn      (write-fixture-file root "check.lisp"
                                        "(defun ok-form (x) (+ x 1))"))
           (tool    (get-tool-instance session "lisp-check-parens"))
           (resp    (tool-handle tool 1 (make-args "path" (namestring pn))))
           (res     (gethash "result" resp)))
      (false (gethash "isError" res))
      (true  (gethash "ok" res)))))

(define-test tool-file-path-unbalanced-returns-kind
  "lisp-check-parens tool reports an unbalanced file via kind and position."
  (with-temp-project-root (session root)
    (let* ((pn      (write-fixture-file root "unbalanced.lisp"
                                        "(defun broken (x"))
           (tool    (get-tool-instance session "lisp-check-parens"))
           (resp    (tool-handle tool 1 (make-args "path" (namestring pn))))
           (res     (gethash "result" resp)))
      (false (gethash "isError" res))
      (false (gethash "ok" res))
      (true  (stringp (gethash "kind" res))))))

(define-test tool-no-root-returns-typed-error
  "lisp-check-parens tool returns project-root-not-set when no root is set."
  (let* ((session (dsmr-mcp/src/state:make-session :id "no-root"))
         (tool    (get-tool-instance session "lisp-check-parens"))
         (resp    (tool-handle tool 1 (make-args "path" "/tmp/x.lisp")))
         (res     (gethash "result" resp)))
    (true  (gethash "isError" res))
    (is string= "project-root-not-set" (gethash "error_type" res))))
