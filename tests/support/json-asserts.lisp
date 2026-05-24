;;;; tests/support/json-asserts.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Small jzon-flavoured Parachute helpers for asserting on JSON-RPC
;;;; hash-table shapes. Every protocol test imports these rather than
;;;; hand-rolling gethash walks inline.
;;;;
;;;; hash-table key assertion is the canonical assertion shape —
;;;; no JSON string comparison, no snapshot tests.

(defpackage #:dsmr-mcp/tests/support/json-asserts
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:export #:gethash*
           #:jsonrpc-error-code
           #:jsonrpc-error-message
           #:jsonrpc-result))

(in-package #:dsmr-mcp/tests/support/json-asserts)

(defun gethash* (table &rest keys)
  "Walk KEYS through nested hash-tables starting from TABLE.
Returns the value at the deepest key, or NIL if any intermediate
table is missing or the final key is absent."
  (loop for k in keys
        for v = (and (hash-table-p table) (gethash k table))
              then (and (hash-table-p v) (gethash k v))
        finally (return v)))

(defun jsonrpc-error-code (obj)
  "Return the integer error code from a parsed JSON-RPC error envelope,
or NIL if OBJ is a success response (has no \"error\" key)."
  (let ((e (and (hash-table-p obj) (gethash "error" obj))))
    (and e (gethash "code" e))))

(defun jsonrpc-error-message (obj)
  "Return the error message string from a parsed JSON-RPC error envelope,
or NIL if OBJ is a success response."
  (let ((e (and (hash-table-p obj) (gethash "error" obj))))
    (and e (gethash "message" e))))

(defun jsonrpc-result (obj)
  "Return the result payload from a parsed JSON-RPC success envelope,
or NIL if OBJ has no \"result\" key."
  (and (hash-table-p obj) (gethash "result" obj)))
