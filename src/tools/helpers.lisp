;;;; src/tools/helpers.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Response-building helpers and the schema-literal -> JSON converter.
;;;; Pure functions; no I/O, no global state.
;;;;
;;;; schema->json converts a class-allocated s-expression literal
;;;;   to a JSON Schema hash-table at tools/list time.
;;;; validate-args checks required fields against a schema literal.
;;;;
;;;; NOTE: No json-bool helper. Under jzon, nil encodes as JSON false and
;;;; the symbol 'null encodes as JSON null. There is no jzon:false sentinel
;;;; to wrap. (See 01-RESEARCH-ADDENDUM-jzon.md §8.)

(defpackage #:dsmr-mcp/src/tools/helpers
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:export #:make-ht
           #:result
           #:rpc-error
           #:text-content
           #:schema->json
           #:arg-validation-error
           #:arg-validation-field
           #:arg-validation-message
           #:validate-args))

(in-package #:dsmr-mcp/src/tools/helpers)

;;; Hash-table builder ------------------------------------------------------

(defun make-ht (&rest kvs)
  "Create an equal-keyed hash-table from alternating KEY VALUE pairs.
Every hash-table that participates in the JSON-RPC wire must use
:test 'equal so string-keyed lookups work.

Example: (make-ht \"jsonrpc\" \"2.0\" \"id\" 1)"
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k ht) v))
    ht))

;;; JSON-RPC envelope builders ----------------------------------------------

(defun result (id payload)
  "Build a JSON-RPC 2.0 success response hash-table.
Returns {\"jsonrpc\":\"2.0\",\"id\":ID,\"result\":PAYLOAD}."
  (make-ht "jsonrpc" "2.0" "id" id "result" payload))

(defun rpc-error (id code message &optional data)
  "Build a JSON-RPC 2.0 error response hash-table.
CODE must be an integer; MESSAGE a string.
Optional DATA (any JSON-encodable value) is included in the error
object only when supplied.
Returns {\"jsonrpc\":\"2.0\",\"id\":ID,\"error\":{\"code\":CODE,\"message\":MESSAGE[,\"data\":DATA]}}."
  (let* ((err (make-ht "code" code "message" message))
         (obj (make-ht "jsonrpc" "2.0" "id" id "error" err)))
    (when data
      (setf (gethash "data" err) data))
    obj))

(defun text-content (text)
  "Return a one-element simple-vector wrapping TEXT as a text content object.
The vector shape ensures jzon encodes it as a JSON array (not null).
Returns #({\"type\":\"text\",\"text\":TEXT})."
  (vector (make-ht "type" "text" "text" text)))

;;; Schema converter --------------------------------------------------------

(defun %kebab->snake (s)
  "Replace hyphens with underscores in string S."
  (substitute #\_ #\- s))

(defun schema->json (schema)
  "Convert a Lisp schema literal to an equal-keyed hash-table representing
a JSON Schema object. Called at tools/list time on the class-allocated
:input-schema literal.

Supported schema forms:
  :string | :integer | :number | :boolean | :null | :array | :object
    -> {\"type\": \"<name>\"}
    The bare :array / :object keywords emit an unconstrained array/object
    schema (no \"items\"/\"properties\"). Use the compound forms below when
    the item or property shapes need to be declared. The bare keywords are
    accepted here so a property :type matches the set validate-args checks.

  (:object :properties ((NAME &key type description enum) ...) :required (...))
    -> {\"type\":\"object\",\"properties\":{...},\"required\":[...]}
    Property NAMEs are downcased and kebab->snake'd.
    :required is coerced to a simple-vector (#() for empty — never nil).

  (:array :items ITEM-SCHEMA)
    -> {\"type\":\"array\",\"items\":SCHEMA->JSON(ITEM-SCHEMA)}

The \"required\" value is ALWAYS a simple-vector so jzon encodes it as
a JSON array. An empty required list becomes #(), not nil/null."
  (etypecase schema
    (keyword
     (ecase schema
       (:string  (make-ht "type" "string"))
       (:integer (make-ht "type" "integer"))
       (:number  (make-ht "type" "number"))
       (:boolean (make-ht "type" "boolean"))
       (:null    (make-ht "type" "null"))
       (:array   (make-ht "type" "array"))
       (:object  (make-ht "type" "object"))))
    (cons
     (case (car schema)
       (:object
        (destructuring-bind (&key properties required) (rest schema)
          (let ((props-ht (make-hash-table :test 'equal)))
            (dolist (p properties)
              (destructuring-bind (name &key type description enum) p
                (let ((prop (if type
                                (schema->json type)
                                (make-hash-table :test 'equal))))
                  (when description
                    (setf (gethash "description" prop) description))
                  (when enum
                    (setf (gethash "enum" prop) (coerce enum 'simple-vector)))
                  (setf (gethash (%kebab->snake (string-downcase (string name)))
                                 props-ht)
                        prop))))
            (make-ht "type"       "object"
                     "properties" props-ht
                     ;; Coerce required list to simple-vector so jzon
                     ;; encodes [] not null for empty (addendum §3).
                     "required"   (coerce required 'simple-vector)))))
       (:array
        (destructuring-bind (&key items) (rest schema)
          (make-ht "type"  "array"
                   "items" (schema->json items))))
       (otherwise
        (error "Unknown schema form: ~S" schema))))))

;;; Argument validation -----------------------------------------------------

(define-condition arg-validation-error (error)
  ((field
    :initarg :field
    :reader arg-validation-field
    :documentation "Name of the argument that failed validation.")
   (message
    :initarg :message
    :reader arg-validation-message
    :documentation "Human-readable description of the validation failure."))
  (:report (lambda (c s)
             (format s "Argument validation error: ~A"
                     (arg-validation-message c))))
  (:documentation "Signalled when a tool argument fails schema validation.
Use arg-validation-field to get the field name and
arg-validation-message for the human-readable error."))

(defun %check-type-match (value type field-name)
  "Check whether VALUE matches the schema TYPE keyword.
Signals arg-validation-error naming FIELD-NAME when the type does
not match. Returns normally (T) when the match succeeds or TYPE is NIL.

jzon type mapping (from addendum §1):
  :string  -> simple-string
  :integer -> integerp
  :number  -> numberp
  :boolean -> t or nil (not 'null)
  :array   -> simple-vector (jzon always returns vectors for arrays)
  :object  -> hash-table"
  (when type
    (let ((valid (ecase type
                   (:string  (stringp value))
                   (:integer (integerp value))
                   (:number  (numberp value))
                   (:boolean (or (eq value t) (eq value nil)))
                   (:array   (simple-vector-p value))
                   (:object  (hash-table-p value)))))
      (unless valid
        (error 'arg-validation-error
               :field field-name
               :message (format nil "~A must be ~A (got ~A)"
                                field-name
                                (ecase type
                                  (:string  "a string")
                                  (:integer "an integer")
                                  (:number  "a number")
                                  (:boolean "a boolean")
                                  (:array   "an array")
                                  (:object  "an object"))
                                (type-of value)))))))

(defun validate-args (schema args)
  "Validate ARGS (a hash-table or NIL) against SCHEMA (a schema literal).
SCHEMA must be an :object schema (validated here; other kinds error).

Required-field check: for each field in :required, normalizes the key
identically to how schema->json emits property names (downcase + kebab->snake)
and verifies the wire-exact key is present in ARGS using the second return
value of gethash so a value of 'null (jzon JSON null) still counts as
present (addendum §6).

Type checks: when a property has a :type, verifies the value type when
the key is present. When a property has an :enum, verifies the present,
non-null value is a member of the closed set. Unknown extra keys are
silently allowed (permissive per JSON Schema default).

Both passes use the same (%kebab->snake (string-downcase (string name)))
normalization so a :required entry and its matching property descriptor
always refer to the same wire key regardless of the case the schema
author used.

Returns T on success. Signals arg-validation-error on failure."
  (unless (and (consp schema) (eq (car schema) :object))
    (error "validate-args: schema must be an :object schema, got ~S" schema))
  (destructuring-bind (&key properties required) (rest schema)
    ;; Required-field presence pass.
    ;; Normalize each required name identically to the type-check pass:
    ;; downcase + kebab->snake so "Code" and CODE both become "code",
    ;; matching the wire key that schema->json emits to the client.
    (dolist (req required)
      (let ((key (%kebab->snake (string-downcase (string req)))))
        (multiple-value-bind (val presentp)
            (gethash key (or args (make-hash-table :test 'equal)))
          (declare (ignore val))
          (unless presentp
            (error 'arg-validation-error
                   :field req
                   :message (format nil "Missing required field: ~A" key))))))
    ;; Type-check and enum-membership pass on present fields.
    (dolist (prop properties)
      (destructuring-bind (name &key type enum &allow-other-keys) prop
        (let ((key (%kebab->snake (string-downcase (string name)))))
          (multiple-value-bind (val presentp)
              (gethash key (or args (make-hash-table :test 'equal)))
            ;; Skip both checks for the jzon null sentinel; null is
            ;; "present but null" — its compliance depends on whether the
            ;; schema allows null, which validate-args does not enforce.
            (when (and presentp (not (eq val 'null)))
              (when type
                (%check-type-match val type key))
              ;; Enum is a closed set: a present, non-null value must be a
              ;; member. Without this, an enum is advertised in tools/list
              ;; but never enforced — a client could pass any string.
              (when (and enum (not (member val enum :test #'equal)))
                (error 'arg-validation-error
                       :field name
                       :message (format nil "~A must be one of ~{~S~^, ~} (got ~S)"
                                        key enum val))))))))
    t))
