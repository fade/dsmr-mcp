;;;; tests/protocol/argument-validation-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Argument validation test. A stub tool with a required "code" argument,
;;;; called via tools/call with an empty arguments hash, returns -32602 whose
;;;; message contains "code".
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
                #:gethash*)
  (:import-from #:dsmr-mcp/tests/support/scoped-tools
                #:unregister-tool
                #:with-scoped-tools))

(in-package #:dsmr-mcp/tests/protocol/argument-validation-test)

;;; In-test stub tool ---------------------------------------------------------
;;; This tool requires a "code" argument. Calling it without "code" must
;;; trigger arg-validation-error -> -32602 with a message naming "code".
;;; Class-allocated slots via :initform (not :default-initargs) because
;;; c2mop:class-prototype does not apply :default-initargs.

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

;; The metaclass registered the stub globally at finalization. Remove it:
;; a test fixture must not be visible to anything that walks the registry
;; (tools/list, the docs/tools.org parity renderer). The tests below hand
;; the dispatcher a registry COPY carrying the stub, scoped dynamically.
(unregister-tool "arg-val-test")

(defmethod dsmr-mcp/src/tools/base:tool-handle ((tool arg-val-test-tool) id args)
  "This method should only be reached with valid args; returns ok."
  (result id (make-ht "ok" t)))

;;; Helpers -------------------------------------------------------------------

(defun %initialize-and-call (tool-name arguments-json)
  "Initialize a fresh session and call TOOL-NAME with ARGUMENTS-JSON,
with the stub tool visible through a scoped registry copy.
Returns the parsed response object."
  (with-scoped-tools (("arg-val-test" arg-val-test-tool))
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
          session)))))

;;; Tests ---------------------------------------------------------------------

(define-test missing-required-arg-returns-32602
  "Calling a tool with an empty arguments object when a required
field exists returns -32602 Invalid Params."
  ;; The fixture must stay out of the global registry (tools/list and the
  ;; docs parity renderer walk it); calls see it via the scoped copy.
  (false (gethash "arg-val-test" *tool-classes*))
  (let ((obj (%initialize-and-call "arg-val-test" "{}")))
    (is = -32602 (jsonrpc-error-code obj))))

(define-test missing-required-arg-message-names-field
  "The -32602 error message names the missing required field.
The message must contain \"code\" so the caller knows which field is absent."
  (let* ((obj (%initialize-and-call "arg-val-test" "{}"))
         (msg (gethash* obj "error" "message")))
    (true msg)
    (true (search "code" msg))))

(define-test valid-args-reach-tool-handle
  "When the required argument is present, validate-args passes,
tool-handle is called, and a success result is returned."
  (let ((obj (%initialize-and-call "arg-val-test" "{\"code\":\"hello\"}")))
    (false (gethash "error" obj))
    (true (hash-table-p (gethash "result" obj)))))

(define-test null-required-arg-is-present
  "A required field with jzon null sentinel 'null counts as present —
validate-args must not signal. The type check for null is intentionally
skipped (null is present-but-null: its type compliance depends on whether
the schema allows null, which validate-args does not enforce)."
  ;; Calling with code: null — validate-args should NOT signal (null is present).
  ;; The tool-handle itself will receive null as the code value.
  (let ((obj (%initialize-and-call "arg-val-test" "{\"code\":null}")))
    ;; No arg-validation-error -> not -32602 from validation.
    ;; (It might be -32602 from elsewhere if tool-handle were to signal,
    ;;  but our stub just returns ok regardless of value.)
    (false (gethash "error" obj))
    (true (hash-table-p (gethash "result" obj)))))

(define-test mixed-case-required-entry-normalizes-consistently
  "A :required entry with mixed case (e.g. \"Code\") must normalize to the
same wire key (\"code\") that the type-check pass uses, so presence and type
checks agree on one key.  Tests validate-args directly."
  ;; Schema with mixed-case :required entry "Code" against property (code :type :string).
  (let ((schema '(:object
                  :properties ((code :type :string :description "test"))
                  :required ("Code"))))
    ;; An args hash with wire key "code" (lowercase — what jzon delivers) must
    ;; pass the required-presence check even though :required says "Code".
    (let ((args-present (dsmr-mcp/src/tools/helpers:make-ht "code" "hello")))
      (true (dsmr-mcp/src/tools/helpers:validate-args schema args-present)))
    ;; An args hash missing "code" must fail with arg-validation-error.
    (let ((args-missing (make-hash-table :test 'equal)))
      (fail (dsmr-mcp/src/tools/helpers:validate-args schema args-missing)
            dsmr-mcp/src/tools/helpers:arg-validation-error))
    ;; A symbol :required entry CODE must also normalize to "code" correctly.
    (let ((schema-sym '(:object
                        :properties ((code :type :string))
                        :required (code)))
          (args-present (dsmr-mcp/src/tools/helpers:make-ht "code" "hello")))
      (true (dsmr-mcp/src/tools/helpers:validate-args schema-sym args-present)))))

(define-test enum-value-must-be-a-member
  "A property with an :enum is a closed set: a present value outside the set
signals arg-validation-error, while a member (and an absent optional field)
passes. Without this the enum is advertised in tools/list but never enforced."
  (let ((schema '(:object
                  :properties ((mode :type :string
                                     :enum ("read" "write" "append")))
                  :required ())))
    ;; In-set value passes.
    (true (dsmr-mcp/src/tools/helpers:validate-args
           schema (dsmr-mcp/src/tools/helpers:make-ht "mode" "write")))
    ;; Absent optional enum field passes (enum constrains value, not presence).
    (true (dsmr-mcp/src/tools/helpers:validate-args
           schema (make-hash-table :test 'equal)))
    ;; Out-of-set value fails.
    (fail (dsmr-mcp/src/tools/helpers:validate-args
           schema (dsmr-mcp/src/tools/helpers:make-ht "mode" "delete"))
          dsmr-mcp/src/tools/helpers:arg-validation-error)))
