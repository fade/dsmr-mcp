;;;; tests/protocol/argument-validation-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP-05: argument validation test. A stub tool with a required "code"
;;;; argument, called via tools/call with an empty arguments hash, returns
;;;; -32602 whose message contains "code".
;;;;
;;;; This test exercises the validate-args -> arg-validation-error ->
;;;; -32602 path in src/dispatch.lisp.

(defpackage #:dsmr-mcp/tests/protocol/argument-validation-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/protocol
                #:process-json-line)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:*current-session-id*)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:*tool-classes*)
  (:shadowing-import-from #:dsmr-mcp/src/tools/helpers
                          #:result)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/tests/support/json-asserts
                #:jsonrpc-error-code
                #:jsonrpc-result
                #:gethash*))

(in-package #:dsmr-mcp/tests/protocol/argument-validation-test)

;;; In-test stub tool ---------------------------------------------------------
;;; This tool requires a "code" argument. Calling it without "code" must
;;; trigger arg-validation-error -> -32602 with a message naming "code".
;;; Class-allocated slots via :initform (Plan 01-01 deviation rule).

(defclass arg-val-test-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "arg-val-test")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Stub tool requiring a 'code' argument for validation tests.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties ((code :type :string :description "required code"))
                :required ("code"))))
  (:metaclass mcp-tool-class))

(c2mop:ensure-finalized (find-class 'arg-val-test-tool))

(defmethod dsmr-mcp/src/tools/base:tool-handle ((tool arg-val-test-tool) id args)
  "This method should only be reached with valid args; returns ok."
  (result id (make-ht "ok" t)))

;;; Helpers -------------------------------------------------------------------

(defun %initialize-and-call (tool-name arguments-json)
  "Initialize a fresh session and call TOOL-NAME with ARGUMENTS-JSON.
Returns the parsed response object."
  (let* ((session (make-session :id "av-test"))
         (*current-session-id* "av-test"))
    (process-json-line
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}"
      session)
    (jzon:parse
      (process-json-line
        (format nil
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",~
                 \"params\":{\"name\":\"~A\",\"arguments\":~A}}"
                tool-name arguments-json)
        session))))

;;; Tests ---------------------------------------------------------------------

(define-test missing-required-arg-returns-32602
  "MCP-05: calling a tool with an empty arguments object when a required
field exists returns -32602 Invalid Params."
  (true (gethash "arg-val-test" *tool-classes*))
  (let ((obj (%initialize-and-call "arg-val-test" "{}")))
    (is = -32602 (jsonrpc-error-code obj))))

(define-test missing-required-arg-message-names-field
  "MCP-05: the -32602 error message names the missing required field.
The message must contain \"code\" so the caller knows which field is absent."
  (let* ((obj (%initialize-and-call "arg-val-test" "{}"))
         (msg (gethash* obj "error" "message")))
    (true msg)
    (true (search "code" msg))))

(define-test valid-args-reach-tool-handle
  "MCP-05 (negative): when the required argument is present, validate-args
passes, tool-handle is called, and a success result is returned."
  (let ((obj (%initialize-and-call "arg-val-test" "{\"code\":\"hello\"}")))
    (false (gethash "error" obj))
    (true (hash-table-p (gethash "result" obj)))))

(define-test null-required-arg-is-present
  "MCP-05: a required field with jzon null sentinel 'null counts as
present — validate-args must not signal. The type check for null
is intentionally skipped (addendum §6: null is present-but-null)."
  ;; Calling with code: null — validate-args should NOT signal (null is present).
  ;; The tool-handle itself will receive null as the code value.
  (let ((obj (%initialize-and-call "arg-val-test" "{\"code\":null}")))
    ;; No arg-validation-error -> not -32602 from validation.
    ;; (It might be -32602 from elsewhere if tool-handle were to signal,
    ;;  but our stub just returns ok regardless of value.)
    (false (gethash "error" obj))
    (true (hash-table-p (gethash "result" obj)))))
