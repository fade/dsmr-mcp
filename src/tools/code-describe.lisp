;;;; src/tools/code-describe.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; code-describe MCP tool (VERB-14): describe a symbol's type, arglist,
;;;; and docstring.
;;;;
;;;; Dual-mode dispatch following inspect-object.lisp's pattern:
;;;;   :attached  — injects %build-code-describe-form (delegates to Slynk's
;;;;                describe-symbol + operator-arglist) into the live image.
;;;;   :hermetic  — routes through dispatch-hermetic-call to the worker's
;;;;                worker/code-describe handler (sb-introspect + cl:documentation).
;;;;   :inline    — returns a typed "requires attached or hermetic mode" error.
;;;;
;;;; Both paths normalise to one envelope: {name, type, arglist, doc, path, line}.

(defpackage #:dsmr-mcp/src/tools/code-describe
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content
                #:rpc-error)
  (:import-from #:dsmr-mcp/src/attach/dispatch
                #:repl-eval-tool
                #:repl-eval-tool-slynk-conn
                #:repl-eval-tool-call-lock)
  (:import-from #:dsmr-mcp/src/attach/connection
                #:bounded-slime-eval)
  (:import-from #:dsmr-mcp/src/state
                #:*mode*
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/hermetic/dispatch
                #:dispatch-hermetic-call)
  (:import-from #:dsmr-mcp/src/code-core
                #:%build-code-describe-form)
  (:import-from #:slynk-client
                #:slime-network-error)
  (:import-from #:bordeaux-threads
                #:with-lock-held)
  (:export #:code-describe-tool
           #:%dispatch-attach-code-describe))

(in-package #:dsmr-mcp/src/tools/code-describe)

;;; ---------------------------------------------------------------------------
;;; code-describe-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass code-describe-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "code-describe")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Describe a symbol: type (function/macro/class/variable/etc.), \
argument list, docstring, and source location. The attached path delegates to \
Slynk for rich arglist and description text; the hermetic path uses \
sb-introspect and cl:documentation. When the symbol is not found, returns a \
typed error with a redirect hint. Requires attached or hermetic mode.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((symbol
                  :type :string
                  :description "Symbol name to describe. Package-qualified form \
preferred (e.g. \"my-pkg:my-fn\"). Unqualified names use the optional package arg.")
                 (package
                  :type :string
                  :description "Package name for unqualified symbols. \
Optional; defaults to CL-USER when omitted."))
                :required ("symbol"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: describe a symbol's type, arglist, and docstring.
Attached path uses Slynk's describe-symbol + operator-arglist.
Hermetic path uses sb-introspect + cl:documentation.
Both paths return the same envelope: name/type/arglist/doc/path/line."))

(c2mop:ensure-finalized (find-class 'code-describe-tool))

;;; ---------------------------------------------------------------------------
;;; Attached dispatcher
;;;
;;; The attached path calls %build-code-describe-form, which injects a form
;;; that uses Slynk's describe-symbol and operator-arglist to return a list of
;;; two strings: (describe-text arglist-text). The dispatcher normalises these
;;; into the wire envelope.
;;; ---------------------------------------------------------------------------

(defun %dispatch-attach-code-describe (tool id params)
  "Dispatch code-describe to the attached Slynk image.
Injects a form that uses Slynk's describe-symbol + operator-arglist.
Returns a wire envelope hash-table (without the result wrapper)."
  (declare (ignore id))
  (let* ((symbol-name  (and params (gethash "symbol" params)))
         (package-name (and params (gethash "package" params))))
    (unless (and (stringp symbol-name) (plusp (length symbol-name)))
      (return-from %dispatch-attach-code-describe
        (make-ht "isError" t
                 "content"
                 (text-content "code-describe: 'symbol' parameter is required."))))
    (let* ((form (handler-case
                     (%build-code-describe-form symbol-name package-name)
                   (error (e)
                     (return-from %dispatch-attach-code-describe
                       (make-ht "isError" t
                                "content"
                                (text-content
                                 (format nil "code-describe: form build error: ~A" e)))))))
           (lock (repl-eval-tool-call-lock tool))
           (raw  (handler-case
                     (with-lock-held (lock)
                       (bounded-slime-eval form (repl-eval-tool-slynk-conn tool)))
                   (slime-network-error (e)
                     (log-event :warn "code-describe.attach.network-error"
                                "error" (handler-case (princ-to-string e)
                                          (error () "")))
                     (return-from %dispatch-attach-code-describe
                       (make-ht "isError"    t
                                "error_type" "NETWORK_ERROR"
                                "content"
                                (text-content
                                 (format nil "code-describe: Slynk connection error: ~A" e))))))))
      ;; The form returns (list describe-string arglist-string).
      ;; describe-string is NIL when Slynk could not describe the symbol.
      (cond
        ((null raw)
         (make-ht "isError"    t
                  "error_type" "symbol-not-found"
                  "content"
                  (text-content
                   (format nil "Symbol ~S not found. Try load-system first, \
or clgrep-search for text search." symbol-name))))
        ((not (listp raw))
         (log-event :warn "code-describe.attach.unexpected" "type" (princ-to-string (type-of raw)))
         (make-ht "isError" t
                  "error_type" "symbol-not-found"
                  "content"
                  (text-content "Unexpected result from code-describe.")))
        (t
         (let* ((desc-text (first raw))
                (args-text (second raw)))
           (if (null desc-text)
               (make-ht "isError"    t
                        "error_type" "symbol-not-found"
                        "content"
                        (text-content
                         (format nil "Symbol ~S not found in image. \
Try load-system first, or clgrep-search for text search." symbol-name)))
               ;; Build the canonical envelope. Attached path returns describe text
               ;; and arglist; no type/path/line available from Slynk alone here.
               (make-ht "name"    (map 'string #'identity symbol-name)
                        "type"    ""
                        "arglist" (or (and (stringp args-text)
                                          (plusp (length args-text))
                                          (map 'string #'identity args-text))
                                     "()")
                        "doc"     (or (and (stringp desc-text)
                                           (plusp (length desc-text))
                                           (map 'string #'identity desc-text))
                                     "")
                        "path"    ""
                        "line"    0))))))))



;;; ---------------------------------------------------------------------------
;;; tool-handle method
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool code-describe-tool) id args)
  "Route code-describe by *mode*.
Attached: injects a Slynk describe form into the live image.
Hermetic: routes to worker/code-describe via dispatch-hermetic-call.
Inline: returns a typed mode error."
  (ecase *mode*
    (:attached
     (let ((repl-tool (get-tool-instance (tool-session tool) "repl-eval")))
       (result id (%dispatch-attach-code-describe repl-tool id args))))
    (:hermetic
     (dispatch-hermetic-call (tool-session tool) id "code-describe" args))
    (:inline
     (rpc-error id -32603
                "code-describe requires attached or hermetic mode."))))
