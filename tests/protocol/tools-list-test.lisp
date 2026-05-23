;;;; tests/protocol/tools-list-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP-03: tools/list returns result.tools as a JSON array.
;;;; With no tools registered it is length 0 and (vectorp tools) is true.
;;;; Optionally defines a single in-test stub tool to verify auto-registration
;;;; and descriptor shape.

(defpackage #:dsmr-mcp/tests/protocol/tools-list-test
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

(in-package #:dsmr-mcp/tests/protocol/tools-list-test)

;;; In-test stub tool ---------------------------------------------------------
;;; Defines a minimal tool for testing tools-list descriptor shape.
;;; Class-allocated slots use :initform (not :default-initargs) per the
;;; Plan 01-01 deviation rule: c2mop:class-prototype does not apply
;;; :default-initargs, so :initform is required for finalize-inheritance
;;; :after to see the name and register the class.

(defclass tools-list-echo-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "tools-list-echo")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Echo stub for tools-list shape tests.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object :properties ((msg :type :string :description "message"))
                :required ("msg"))))
  (:metaclass mcp-tool-class))

(c2mop:ensure-finalized (find-class 'tools-list-echo-tool))

(defmethod dsmr-mcp/src/tools/base:tool-handle ((tool tools-list-echo-tool) id args)
  (result id (make-ht "echoed" (and args (gethash "msg" args)))))

;;; Helpers -------------------------------------------------------------------

(defun %do-initialize (session)
  (process-json-line
    (format nil
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",~
             \"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},~
             \"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}")
    session))

;;; Tests ---------------------------------------------------------------------

(define-test tools-list-result-tools-is-vector
  "MCP-03: result.tools is a simple-vector (jzon encodes vectors as JSON
arrays). We assert with (vectorp tools) to match jzon's type mapping."
  (let* ((session (make-session :id "tl-vec"))
         (*current-session-id* "tl-vec"))
    (%do-initialize session)
    (let* ((resp (process-json-line
                   "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
                   session))
           (obj (jzon:parse resp))
           (tools (gethash* obj "result" "tools")))
      (true (vectorp tools)))))

(define-test tools-list-stub-tool-registered
  "MCP-03: the tools-list-echo stub tool is registered and appears in
tools/list with the expected name, description, and inputSchema."
  ;; Confirm registration before testing.
  (true (gethash "tools-list-echo" *tool-classes*))
  (let* ((session (make-session :id "tl-stub"))
         (*current-session-id* "tl-stub"))
    (%do-initialize session)
    (let* ((resp (process-json-line
                   "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
                   session))
           (obj (jzon:parse resp))
           (tools (gethash* obj "result" "tools"))
           ;; Find our specific tool among all registered tools.
           (echo-desc (loop for d across tools
                            when (equal "tools-list-echo" (gethash "name" d))
                            return d)))
      (true echo-desc)
      (is equal "tools-list-echo" (gethash "name" echo-desc))
      (is equal "Echo stub for tools-list shape tests." (gethash "description" echo-desc))
      (true (hash-table-p (gethash "inputSchema" echo-desc))))))

(define-test tools-list-input-schema-has-required
  "MCP-03: the inputSchema for the stub tool has a \"required\" key that
is a vector (not a list or nil)."
  (let* ((session (make-session :id "tl-schema"))
         (*current-session-id* "tl-schema"))
    (%do-initialize session)
    (let* ((resp (process-json-line
                   "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
                   session))
           (obj (jzon:parse resp))
           (tools (gethash* obj "result" "tools"))
           (echo-desc (loop for d across tools
                            when (equal "tools-list-echo" (gethash "name" d))
                            return d)))
      (when echo-desc
        (let ((schema (gethash "inputSchema" echo-desc)))
          (is equal "object" (gethash "type" schema))
          (true (vectorp (gethash "required" schema)))
          (is = 1 (length (gethash "required" schema)))
          (is equal "msg" (aref (gethash "required" schema) 0)))))))
