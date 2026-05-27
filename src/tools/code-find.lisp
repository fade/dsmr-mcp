;;;; src/tools/code-find.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; code-find MCP tool (VERB-13): locate definition(s) for a symbol.
;;;;
;;;; Dual-mode dispatch following inspect-object.lisp's pattern:
;;;;   :attached  — injects %build-code-find-form into the live image via
;;;;                bounded-slime-eval under the per-session call-lock.
;;;;   :hermetic  — routes through dispatch-hermetic-call to the worker's
;;;;                worker/code-find handler.
;;;;   :inline    — returns a typed "requires attached or hermetic mode" error.
;;;;
;;;; Result shape: {locations: [{path, line, kind}, ...]}
;;;; Not-found shapes (typed redirect hints):
;;;;   package-not-found / symbol-not-found / found-but-no-source-location

(defpackage #:dsmr-mcp/src/tools/code-find
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
                #:%build-code-find-form
                #:package-not-found
                #:symbol-not-found
                #:found-but-no-source-location)
  (:import-from #:slynk-client
                #:slime-network-error)
  (:import-from #:bordeaux-threads
                #:with-lock-held)
  (:export #:code-find-tool
           #:%dispatch-attach-code-find))

(in-package #:dsmr-mcp/src/tools/code-find)

;;; ---------------------------------------------------------------------------
;;; code-find-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass code-find-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "code-find")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Locate definition(s) for a symbol in the loaded image. \
Returns project-relative path, line, and kind (function/method/class/etc.) \
for every definition. When the symbol is not found, returns a typed error \
with a redirect hint (e.g. try load-system, or clgrep-search for text search). \
Requires attached or hermetic mode.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((symbol
                  :type :string
                  :description "Symbol name to locate. Package-qualified form \
preferred (e.g. \"my-pkg:my-fn\"). Unqualified names use the optional package arg.")
                 (package
                  :type :string
                  :description "Package name for unqualified symbols. \
Optional; defaults to CL-USER when omitted."))
                :required ("symbol"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: locate definition(s) for a symbol in the image.
Attached mode injects an sb-introspect form into the live image.
Hermetic mode runs sb-introspect in the worker process.
Both paths return the same locations envelope."))

(c2mop:ensure-finalized (find-class 'code-find-tool))

;;; ---------------------------------------------------------------------------
;;; Result decoder — convert the raw list returned by the injected form or
;;; the code-core engine into the wire envelope hash-table.
;;; ---------------------------------------------------------------------------

(defun %decode-not-found (raw)
  "Decode a not-found marker plist into a typed isError hash-table."
  (let* ((kind (getf raw :not-found))
         (name (getf raw :name))
         (hint (getf raw :hint))
         (etype (ecase kind
                  (:package  "package-not-found")
                  (:symbol   "symbol-not-found")
                  (:source-location "found-but-no-source-location"))))
    (make-ht "isError"    t
             "error_type" etype
             "content"
             (text-content
              (format nil "~@[~A: ~]~A" name hint)))))

(defun %decode-code-find-result (raw)
  "Decode the raw result from the attached injected form into a wire envelope.

RAW is either:
  - a list of (:path PATH :line LINE :kind KIND) plists (success)
  - a plist with :not-found key (typed error)
  - NIL (treated as symbol-not-found)"
  (cond
    ;; Nil result — treat as symbol-not-found.
    ((null raw)
     (make-ht "isError" t
              "error_type" "symbol-not-found"
              "content" (text-content "Symbol not found in image.")))
    ;; Typed not-found marker: plist with :not-found keyword.
    ((and (listp raw) (getf raw :not-found))
     (%decode-not-found raw))
    ;; Success: list of location plists.
    ((and (listp raw) (listp (car raw)))
     (let* ((locs (mapcar (lambda (loc)
                            (make-ht "path" (or (getf loc :path) "")
                                     "line" (or (getf loc :line) 0)
                                     "kind" (or (getf loc :kind) "")))
                          raw)))
       (make-ht "locations" (coerce locs 'simple-vector))))
    ;; Unexpected shape — log and return error.
    (t
     (log-event :warn "code-find.unexpected-result" "type" (princ-to-string (type-of raw)))
     (make-ht "isError" t
              "error_type" "symbol-not-found"
              "content" (text-content "Unexpected result from code-find.")))))

;;; ---------------------------------------------------------------------------
;;; Attached dispatcher
;;; ---------------------------------------------------------------------------

(defun %dispatch-attach-code-find (tool id params)
  "Dispatch code-find to the attached Slynk image.
Builds the injected form, acquires the call-lock, and runs bounded-slime-eval.
Returns a wire envelope hash-table (without the result wrapper)."
  (declare (ignore id))
  (let* ((symbol-name  (and params (gethash "symbol" params)))
         (package-name (and params (gethash "package" params))))
    (unless (and (stringp symbol-name) (plusp (length symbol-name)))
      (return-from %dispatch-attach-code-find
        (make-ht "isError" t
                 "content"
                 (text-content "code-find: 'symbol' parameter is required."))))
    (let* ((form (handler-case
                     (%build-code-find-form symbol-name package-name)
                   (error (e)
                     (return-from %dispatch-attach-code-find
                       (make-ht "isError" t
                                "content"
                                (text-content
                                 (format nil "code-find: form build error: ~A" e)))))))
           (lock (repl-eval-tool-call-lock tool))
           (raw  (handler-case
                     (with-lock-held (lock)
                       (bounded-slime-eval form (repl-eval-tool-slynk-conn tool)))
                   (slime-network-error (e)
                     (log-event :warn "code-find.attach.network-error"
                                "error" (handler-case (princ-to-string e)
                                          (error () "")))
                     (return-from %dispatch-attach-code-find
                       (make-ht "isError"    t
                                "error_type" "NETWORK_ERROR"
                                "content"
                                (text-content
                                 (format nil "code-find: Slynk connection error: ~A" e))))))))
      (%decode-code-find-result raw))))

;;; ---------------------------------------------------------------------------
;;; tool-handle method
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool code-find-tool) id args)
  "Route code-find by *mode*.
Attached: injects an sb-introspect form into the live image.
Hermetic: routes to worker/code-find via dispatch-hermetic-call.
Inline: returns a typed mode error."
  (ecase *mode*
    (:attached
     (let ((repl-tool (get-tool-instance (tool-session tool) "repl-eval")))
       (result id (%dispatch-attach-code-find repl-tool id args))))
    (:hermetic
     (dispatch-hermetic-call (tool-session tool) id "code-find" args))
    (:inline
     (rpc-error id -32603
                "code-find requires attached or hermetic mode."))))
