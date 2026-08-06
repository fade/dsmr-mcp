;;;; tests/code-intelligence/code-describe-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for the code-describe verb (VERB-14): dual-mode coverage.
;;;;
;;;; Coverage:
;;;;   - Hermetic: %handle-code-describe returns type + arglist + doc for a function
;;;;   - Hermetic: missing symbol returns typed not-found error
;;;;   - Inline: tool-handle with *mode* bound to :inline returns typed mode error

(defpackage #:dsmr-mcp/tests/code-intelligence/code-describe-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/tests/support/slynk-fixture
                #:with-temporary-slynk-listener)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:%handle-code-describe)
  (:import-from #:dsmr-mcp/src/tools/code-describe
                #:code-describe-tool
                #:%dispatch-attach-code-describe)
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
                #:make-ht))

(in-package #:dsmr-mcp/tests/code-intelligence/code-describe-test)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun make-params (&rest kvs)
  "Build a string-keyed hash-table from alternating key/value pairs."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k ht) v))
    ht))

;;; ---------------------------------------------------------------------------
;;; Hermetic: %handle-code-describe returns type + arglist + doc for a function
;;; ---------------------------------------------------------------------------

(define-test code-describe-hermetic-returns-arglist-and-doc
  "Calling %handle-code-describe for a function with known metadata returns a
hash-table with 'name', 'type', 'arglist', and 'doc' fields that are non-empty
strings."
  (let* ((params (make-params "symbol" "dsmr-mcp/src/code-core:code-find-definition"))
         (result (%handle-code-describe params nil)))
    (true (hash-table-p result))
    (false (gethash "isError" result))
    ;; Required fields must be present and be strings.
    (true (stringp (gethash "name"    result)))
    (true (stringp (gethash "type"    result)))
    (true (stringp (gethash "arglist" result)))
    (true (stringp (gethash "doc"     result)))
    ;; type must be one of the known kinds.
    (let ((ty (gethash "type" result)))
      (true (member ty '("function" "generic-function" "macro"
                         "variable" "class" "condition" "structure")
                    :test #'string=)))
    ;; arglist must be non-empty (at least "()" for zero-arg functions).
    (true (plusp (length (gethash "arglist" result))))))

(define-test code-describe-hermetic-function-type-is-function
  "code-describe for a plain defun returns type='function'."
  (let* ((params (make-params "symbol" "dsmr-mcp/src/code-core:code-find-definition"
                              "package" "dsmr-mcp/src/code-core"))
         (result (%handle-code-describe params nil)))
    (false (gethash "isError" result))
    (is string= "function" (gethash "type" result))))

;;; ---------------------------------------------------------------------------
;;; Hermetic: package not found returns typed not-found error
;;; ---------------------------------------------------------------------------

(define-test code-describe-package-not-found-returns-typed-error
  "When %handle-code-describe is called with a package that is not loaded in
the image, the response has isError=t and error_type='package-not-found'."
  (let* ((params (make-params "symbol"  "some-fn"
                              "package" "nonexistent-package-xyzzy-88888"))
         (result (%handle-code-describe params nil)))
    (true (hash-table-p result))
    (true (gethash "isError" result))
    (is string= "package-not-found" (gethash "error_type" result))))

;;; ---------------------------------------------------------------------------
;;; Attached: %dispatch-attach-code-describe returns name + arglist + doc via Slynk
;;; ---------------------------------------------------------------------------

(defun %make-code-describe-attach-session (id conn)
  "Create a test session wired to the given Slynk connection."
  (let* ((session (make-session :id id :slynk-attach "127.0.0.1:1"))
         (*current-session-id* id)
         (repl-tool (get-tool-instance session "repl-eval")))
    (setf (repl-eval-tool-slynk-conn repl-tool) conn)
    (values session repl-tool)))

(define-test code-describe-attached-returns-name-and-arglist
  "Calling %dispatch-attach-code-describe via the in-process Slynk fixture for a
known function returns an envelope with 'name' and 'arglist' string fields.
The attached path delegates to Slynk's describe-symbol + operator-arglist so
the doc field carries describe text and arglist carries the arglist string."
  (with-temporary-slynk-listener (conn)
    (multiple-value-bind (session repl-tool)
        (%make-code-describe-attach-session "cd-attach-name-arglist" conn)
      (declare (ignore session))
      (let* ((params (make-ht "symbol" "dsmr-mcp/src/code-core:code-find-definition"))
             (result (%dispatch-attach-code-describe repl-tool nil params nil)))
        (true (hash-table-p result))
        (false (gethash "isError" result))
        ;; 'name' must be a non-empty string.
        (true (stringp (gethash "name" result)))
        (true (plusp (length (gethash "name" result))))
        ;; 'arglist' must be a non-empty string (at least "()" for zero-arg).
        (true (stringp (gethash "arglist" result)))
        (true (plusp (length (gethash "arglist" result))))
        ;; 'doc' must be present as a string (may be empty).
        (true (stringp (gethash "doc" result)))))))

;;; ---------------------------------------------------------------------------
;;; Inline: tool-handle returns typed mode error
;;; ---------------------------------------------------------------------------

(define-test code-describe-inline-returns-mode-error
  "Calling tool-handle on a code-describe-tool instance with *mode* bound to
:inline returns a JSON-RPC error response with code -32603."
  (let ((tool (make-instance 'code-describe-tool))
        (params (make-params "symbol" "cl:car")))
    (let* ((*mode* :inline)
           (response (tool-handle tool nil params)))
      (true (hash-table-p response))
      (let ((err (gethash "error" response)))
        (true (hash-table-p err))
        (is = -32603 (gethash "code" err))
        (let ((msg (gethash "message" err)))
          (true (stringp msg))
          (true (search "code-describe" msg)))))))
