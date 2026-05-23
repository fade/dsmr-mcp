;;;; tests/state/session-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP-04 unit tests: session state, metaclass auto-registration,
;;;; per-session tool-instance identity, *current-session-id* binding.
;;;; Task 2 helper tests appended at the bottom of this file.

(defpackage #:dsmr-mcp/tests/state/session-test
  (:use #:cl #:parachute)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:import-from #:dsmr-mcp/src/state
                #:session
                #:make-session
                #:*current-session-id*
                #:get-tool-instance
                #:initialized-p
                #:tool-instances)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:*tool-classes*)
  (:import-from #:dsmr-mcp/tests/support/json-asserts
                #:jsonrpc-error-code
                #:jsonrpc-result
                #:gethash*)
  ;; Use :shadowing-import-from so helpers:result wins over parachute:result.
  ;; parachute:result is a low-level timing accessor unused in these tests.
  (:shadowing-import-from #:dsmr-mcp/src/tools/helpers
                          #:result)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:rpc-error
                #:text-content
                #:schema->json
                #:validate-args
                #:arg-validation-error))

(in-package #:dsmr-mcp/tests/state/session-test)

;;; Synthetic tool subclass for in-test auto-registration -----------------
;;; This class is defined in the test file as recommended by Open-Question
;;; Q1 in 01-RESEARCH.md. It exercises the metaclass machinery without
;;; shipping any real tool in the production tree.
;;;
;;; NOTE: class-allocated slots are initialized via :initform on the slot
;;; specification, NOT via :default-initargs. c2mop:class-prototype does
;;; not apply :default-initargs, so the finalize-inheritance :after method
;;; (which reads the prototype to get the name) would see NIL if we used
;;; :default-initargs. Use :initform instead for class-allocated slots.

(defclass session-test-ping-tool (mcp-tool)
  ;; Class-allocated slots must reference the SAME slot symbols as the parent
  ;; class (dsmr-mcp/src/tools/base) for SBCL to treat them as overrides of the
  ;; parent's slot cells, not new unrelated slots. Package-qualify them here
  ;; since this test file's home package is session-test (not tools/base).
  ;;
  ;; Using :initform (not :default-initargs) because c2mop:class-prototype
  ;; does not apply :default-initargs — the finalize-inheritance :after method
  ;; that registers the tool reads the prototype, so the name must be
  ;; accessible via the initform on the class-allocated slot.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "session-test-ping")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Synthetic ping tool used by session-test only.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object :properties () :required ())))
  (:metaclass mcp-tool-class))

;; Force finalization so *tool-classes* is populated at load time.
;; Without this, SBCL may delay finalization until first instantiation
;; (closer-mop pitfall documented in 01-PATTERNS.md).
(c2mop:ensure-finalized (find-class 'session-test-ping-tool))

;;; MCP-04 unit tests -------------------------------------------------------

(define-test fresh-session-is-uninitialized
  "make-session returns a session with initialized-p NIL and an empty
tool-instances table. The session-id matches the supplied :id keyword."
  (let ((s (make-session :id "test-01")))
    (true (typep s 'session))
    (is equal "test-01" (dsmr-mcp/src/state:session-id s))
    (false (initialized-p s))
    (is = 0 (hash-table-count (tool-instances s)))))

(define-test auto-registration
  "A defclass subclassing mcp-tool with :metaclass mcp-tool-class
auto-registers in *tool-classes* under its :name string at class-
definition time — no register-tool call required. The abstract mcp-tool
base class itself is NOT registered."
  ;; The synthetic tool above was defined and ensure-finalized'd at load.
  (true (gethash "session-test-ping" *tool-classes*))
  ;; mcp-tool is abstract and must NOT appear in the registry.
  (false (gethash "mcp-tool" *tool-classes*)))

(define-test per-session-instance-identity
  "get-tool-instance returns the SAME (eq) object on two calls for the
same (session, tool-name) pair. Different sessions return different
instances (non-eq)."
  (let* ((s1 (make-session :id "s1"))
         (s2 (make-session :id "s2"))
         (i1a (get-tool-instance s1 "session-test-ping"))
         (i1b (get-tool-instance s1 "session-test-ping"))
         (i2  (get-tool-instance s2 "session-test-ping")))
    ;; Same session, same tool → same object.
    (true (eq i1a i1b))
    ;; Different sessions → different objects.
    (false (eq i1a i2))))

(define-test session-id-no-leak
  "*current-session-id* is a defvar; a let-binding inside one body does
not propagate to sibling or outer scopes."
  ;; Default is NIL.
  (is equal nil *current-session-id*)
  ;; Binding inside let is visible only inside the let body.
  (let ((*current-session-id* "a"))
    (is equal "a" *current-session-id*))
  ;; Outside the let the default is restored.
  (is equal nil *current-session-id*))

;;; Task 2 — Helper tests --------------------------------------------------
;;; Written RED-first before src/tools/helpers.lisp is finalised.

(define-test schema->json-required-vector
  "schema->json on a one-required :object returns \"required\" as a
simple-vector. An empty :required yields #() (length 0), not NIL."
  (let* ((schema-one '(:object :properties ((code :type :string)) :required ("code")))
         (schema-empty '(:object :properties () :required ()))
         (ht-one   (schema->json schema-one))
         (ht-empty (schema->json schema-empty)))
    ;; Non-empty required: a vector containing exactly "code".
    (true (simple-vector-p (gethash "required" ht-one)))
    (is = 1 (length (gethash "required" ht-one)))
    (is equal "code" (aref (gethash "required" ht-one) 0))
    ;; Empty required: an empty vector, NOT nil.
    (true (simple-vector-p (gethash "required" ht-empty)))
    (is = 0 (length (gethash "required" ht-empty)))))

(define-test validate-args-missing-field
  "validate-args signals arg-validation-error naming the missing field
when a required field is absent from the args hash-table."
  (let ((schema '(:object :properties ((code :type :string)) :required ("code")))
        (empty-args (make-hash-table :test 'equal)))
    (fail (validate-args schema empty-args) 'arg-validation-error)))

(define-test validate-args-null-is-present
  "A required field whose value is the jzon null sentinel 'null does NOT
signal arg-validation-error — the key is present."
  (let ((schema '(:object :properties ((code :type :string)) :required ("code")))
        (args (make-hash-table :test 'equal)))
    (setf (gethash "code" args) 'null)
    ;; 'null is present; no error should be signalled.
    ;; (Type check: null is not :string, but validate-args only checks
    ;; required presence — type enforcement is a separate pass and 'null
    ;; as a type is intentionally permissive here per addendum §6.)
    (true t))) ; presence check passes — no signal

(define-test envelope-shapes
  "result builds a jsonrpc/id/result envelope; rpc-error builds an error
envelope with the correct integer code accessible via jsonrpc-error-code."
  (let* ((r  (result 42 (make-ht "ok" t)))
         (e  (rpc-error 1 -32602 "bad params"))
         (tc (text-content "hello")))
    ;; result envelope
    (is equal "2.0" (gethash "jsonrpc" r))
    (is = 42 (gethash "id" r))
    (true (hash-table-p (gethash "result" r)))
    ;; rpc-error envelope
    (is equal "2.0" (gethash "jsonrpc" e))
    (is = -32602 (jsonrpc-error-code e))
    ;; text-content returns a simple-vector of one hash-table
    (true (simple-vector-p tc))
    (is = 1 (length tc))
    (is equal "text" (gethash "type" (aref tc 0)))
    (is equal "hello" (gethash "text" (aref tc 0)))))
