;;;; tests/elicitation/envrc-consent-schema-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The requestedSchema of the `.envrc` consent prompt, which has never had a
;;;; test.
;;;;
;;;; The reason is not visible from the assertions, so it is written here: a
;;;; `required` field in an MCP elicitation schema made the client reject the
;;;; accept action until that field was set, leaving only decline able to clear
;;;; the dialog. The operator could not consent to anything. The schema is
;;;; confirmation-only because the accept action already carries the operator's
;;;; consent, so there is nothing to ask for and nothing the client can demand.
;;;;
;;;; The prompt's surrounding path is being changed (the settings it offers now
;;;; include the fleet selector), which is why the guard is being added now: the
;;;; regression is one keyword away and nothing was watching for it.

;; Package evolution guard: drop a prior incarnation so a reload picks up the
;; current import/export set rather than stale symbols.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package
              '#:dsmr-mcp/tests/elicitation/envrc-consent-schema-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/elicitation/envrc-consent-schema-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/envrc-init
                #:envrc-elicitation-schema))

(in-package #:dsmr-mcp/tests/elicitation/envrc-consent-schema-test)

(defun %character-string-p (value)
  "True when VALUE is a string whose element type is CHARACTER.
A base-string reaching the JSON-RPC wire serializes as a `#A(... BASE-CHAR ...)`
reader literal that breaks framing, so element type is a wire property here and
not a detail."
  (and (stringp value)
       (subtypep (array-element-type value) 'character)
       (not (typep value 'base-string))))

(define-test consent-schema-requests-no-fields
  "The consent schema is a flat object that asks for nothing: type \"object\", an
empty properties table, and NO \"required\" key at all.

This is the guard on the bug that made the prompt unanswerable. A required
field made the client reject the accept action until the field was set, so only
decline could clear the dialog and the operator had no way to say yes. The
accept action is itself the consent, which is why there is nothing to ask for."
  (let ((schema (envrc-elicitation-schema)))
    (true (hash-table-p schema) "the schema must be a hash table")
    (is string= "object" (gethash "type" schema)
        "the schema declares a flat object")
    (let ((properties (gethash "properties" schema)))
      (true (hash-table-p properties) "properties must be a hash table")
      (is = 0 (hash-table-count properties)
          "properties must be empty: a field here is a field the client can
demand before it will let the operator accept"))
    (multiple-value-bind (value present) (gethash "required" schema)
      (declare (ignore value))
      (false present
             "the schema must carry no \"required\" key at all. Asserted on
presence rather than on value, so an explicitly nil entry fails here too: it
would still serialize as a key the client reads."))))

(define-test consent-schema-strings-are-wire-safe
  "Every key and every string value in the schema is a string of element type
CHARACTER. A simple-base-string reaching the JSON-RPC wire serializes as a
reader literal that breaks framing, which kills the connection rather than
merely garbling one prompt."
  (let ((schema (envrc-elicitation-schema)))
    (maphash (lambda (key value)
               (true (%character-string-p key)
                     (format nil "schema key ~S is not a character string" key))
               (when (stringp value)
                 (true (%character-string-p value)
                       (format nil "the value of ~S is not a character string"
                               key))))
             schema)))
