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
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:%handle-code-describe)
  (:import-from #:dsmr-mcp/src/tools/code-describe
                #:code-describe-tool)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
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
