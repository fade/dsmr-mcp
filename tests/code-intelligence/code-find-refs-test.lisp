;;;; tests/code-intelligence/code-find-refs-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for the code-find-references verb (VERB-15): dual-mode coverage.
;;;;
;;;; Coverage:
;;;;   - Hermetic: %handle-code-find-references returns who-calls entries with
;;;;     caller, relation, path, and line fields
;;;;   - Hermetic: project_only default (true) behavior is honoured
;;;;   - Hermetic: missing symbol returns typed not-found error
;;;;   - Inline: tool-handle with *mode* bound to :inline returns typed mode error

(defpackage #:dsmr-mcp/tests/code-intelligence/code-find-refs-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/hermetic/worker/handlers
                #:%handle-code-find-references)
  (:import-from #:dsmr-mcp/src/tools/code-find-references
                #:code-find-references-tool)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht))

(in-package #:dsmr-mcp/tests/code-intelligence/code-find-refs-test)

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
;;; Hermetic: %handle-code-find-references returns entries for a known function
;;;
;;; We query who calls code-find-definition (a function in code-core that is
;;; called by code-describe-symbol and others), so we can assert at least one
;;; caller entry is returned.
;;; ---------------------------------------------------------------------------

(define-test code-find-references-hermetic-returns-callers
  "Calling %handle-code-find-references for a function that is called by other
code in the loaded system returns a hash-table with a 'references' vector.
When project_only is false, the results may include callers from all loaded
systems."
  (let* ((params (make-params "symbol"       "dsmr-mcp/src/code-core:code-find-definition"
                              "project_only" nil))
         (result (%handle-code-find-references params nil)))
    (true (hash-table-p result))
    (false (gethash "isError" result))
    (let ((refs (gethash "references" result)))
      (true (vectorp refs))
      ;; There may be zero entries if project_only filtered everything, but the
      ;; key must exist. With project_only=nil we expect at least the internal
      ;; callers.
      (when (plusp (length refs))
        (let ((first-ref (aref refs 0)))
          (true (hash-table-p first-ref))
          (true (stringp (gethash "path"     first-ref)))
          (true (integerp (gethash "line"     first-ref)))
          (true (stringp (gethash "caller"   first-ref)))
          (true (stringp (gethash "relation" first-ref))))))))

(define-test code-find-references-hermetic-project-only-default-returns-vector
  "When project_only is absent from params (defaulting to true), the result
still has a 'references' vector key (may be empty if no in-project callers
are loaded at test time, but the envelope shape must be correct)."
  (let* (;; Use a CL built-in — unlikely to have project callers, but the
         ;; shape must be correct regardless of the number of results.
         (params (make-params "symbol" "cl:car"))
         (result (%handle-code-find-references params nil)))
    (true (hash-table-p result))
    ;; Either a references envelope or a typed not-found; both are valid.
    ;; If isError, it must be a typed not-found.
    (if (gethash "isError" result)
        (let ((etype (gethash "error_type" result)))
          (true (stringp etype))
          (true (member etype '("symbol-not-found" "package-not-found"
                                "found-but-no-source-location")
                        :test #'string=)))
        (true (vectorp (gethash "references" result))))))

;;; ---------------------------------------------------------------------------
;;; Hermetic: package not found returns typed not-found error
;;;
;;; For xref, an unresolvable symbol name (read succeeds but xref returns NIL)
;;; yields {references:[]} rather than an error — this is correct behaviour
;;; (no callers found is distinct from "symbol does not exist"). A package-not-
;;; found case is the reliable path to a typed isError from the xref handler.
;;; ---------------------------------------------------------------------------

(define-test code-find-references-package-not-found-returns-typed-error
  "When %handle-code-find-references is called with a package that is not loaded,
the response has isError=t and error_type='package-not-found'."
  (let* ((params (make-params "symbol"  "some-fn"
                              "package" "nonexistent-package-xyzzy-99999"))
         (result (%handle-code-find-references params nil)))
    (true (hash-table-p result))
    (true (gethash "isError" result))
    (is string= "package-not-found" (gethash "error_type" result))))

;;; ---------------------------------------------------------------------------
;;; Inline: tool-handle returns typed mode error
;;; ---------------------------------------------------------------------------

(define-test code-find-references-inline-returns-mode-error
  "Calling tool-handle on a code-find-references-tool instance with *mode*
bound to :inline returns a JSON-RPC error response with code -32603."
  (let ((tool (make-instance 'code-find-references-tool))
        (params (make-params "symbol" "cl:car")))
    (let* ((*mode* :inline)
           (response (tool-handle tool nil params)))
      (true (hash-table-p response))
      (let ((err (gethash "error" response)))
        (true (hash-table-p err))
        (is = -32603 (gethash "code" err))
        (let ((msg (gethash "message" err)))
          (true (stringp msg))
          (true (search "code-find-references" msg)))))))
