;;;; tests/protocol/tools-call-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; tools/call dispatch test.
;;;; - Unknown tool -> -32601
;;;; - Known stub tool with valid args -> structured result
;;;; The in-test stub must follow the :initform pattern (not :default-initargs)
;;;; because c2mop:class-prototype does not apply :default-initargs.

(defpackage #:dsmr-mcp/tests/protocol/tools-call-test
  (:use #:cl #:zebra)
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
                #:gethash*)
  (:import-from #:dsmr-mcp/tests/support/scoped-tools
                #:unregister-tool
                #:with-scoped-tools))

(in-package #:dsmr-mcp/tests/protocol/tools-call-test)

;;; In-test stub tool ---------------------------------------------------------
;;; Class-allocated slots via :initform (not :default-initargs) because
;;; c2mop:class-prototype does not apply :default-initargs. Package-qualified
;;; slot names since this package is not dsmr-mcp/src/tools/base.

(defclass proto-test-echo-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "proto-test-echo")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Synthetic echo tool for tools-call tests.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties ((code :type :string :description "code to echo"))
                :required ("code"))))
  (:metaclass mcp-tool-class))

(c2mop:ensure-finalized (find-class 'proto-test-echo-tool))

;; The metaclass registered the stub globally at finalization. Remove it:
;; a test fixture must not be visible to anything that walks the registry
;; (tools/list, the docs/tools.org parity renderer). The test below hands
;; the dispatcher a registry COPY carrying the stub, scoped dynamically.
(unregister-tool "proto-test-echo")

(defmethod dsmr-mcp/src/tools/base:tool-handle ((tool proto-test-echo-tool) id args)
  "Return the supplied code value in a result envelope."
  (result id (make-ht "ok" t "code" (and args (gethash "code" args)))))

;;; Helpers -------------------------------------------------------------------

(defun %initialize-session (session)
  "Send an initialize request to SESSION and return the session."
  (process-json-line
    (format nil
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",~
             \"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},~
             \"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}")
    session)
  session)

;;; Tests ---------------------------------------------------------------------

(define-test unknown-tool-returns-32601
  "tools/call for an unknown tool name returns -32601 Method not found."
  (let* ((session (make-session :id "tc-unknown"))
         (*current-session-id* "tc-unknown"))
    (%initialize-session session)
    (let* ((resp (process-json-line
                   "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"no-such-tool\",\"arguments\":{}}}"
                   session))
           (obj (jzon:parse resp)))
      (is = -32601 (jsonrpc-error-code obj)))))

(define-test known-tool-valid-args-returns-result
  "tools/call for a scoped stub tool with valid arguments
returns a structured success result (no error key)."
  ;; The fixture must stay out of the global registry (tools/list and the
  ;; docs parity renderer walk it); the call sees it via the scoped copy.
  (false (gethash "proto-test-echo" *tool-classes*))
  (with-scoped-tools (("proto-test-echo" proto-test-echo-tool))
    (let* ((session (make-session :id "tc-valid"))
           (*current-session-id* "tc-valid"))
      (%initialize-session session)
      (let* ((resp (process-json-line
                     "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"proto-test-echo\",\"arguments\":{\"code\":\"hello\"}}}"
                     session))
             (obj (jzon:parse resp)))
        ;; No error.
        (false (gethash "error" obj))
        ;; Result is present.
        (true (hash-table-p (gethash "result" obj)))
        ;; Our tool echoes back the code.
        (is equal t (gethash "ok" (gethash "result" obj)))
        (is equal "hello" (gethash "code" (gethash "result" obj)))))))
