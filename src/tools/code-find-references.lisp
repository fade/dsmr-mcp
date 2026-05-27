;;;; src/tools/code-find-references.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; code-find-references MCP tool (VERB-15): find xref locations for a symbol.
;;;;
;;;; Dual-mode dispatch following inspect-object.lisp's pattern:
;;;;   :attached  — injects %build-code-find-refs-form (sb-introspect who-calls /
;;;;                who-references / who-binds / who-sets / who-macroexpands) into
;;;;                the live image via bounded-slime-eval.
;;;;   :hermetic  — routes through dispatch-hermetic-call to the worker's
;;;;                worker/code-find-references handler.
;;;;   :inline    — returns a typed "requires attached or hermetic mode" error.
;;;;
;;;; Result shape: {references: [{path, line, caller, relation}, ...]}
;;;; project_only defaults to true; relation optionally filters to one xref kind.

(defpackage #:dsmr-mcp/src/tools/code-find-references
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
                #:%build-code-find-refs-form)
  (:import-from #:slynk-client
                #:slime-network-error)
  (:import-from #:bordeaux-threads
                #:with-lock-held)
  (:export #:code-find-references-tool
           #:%dispatch-attach-code-find-references))

(in-package #:dsmr-mcp/src/tools/code-find-references)

;;; ---------------------------------------------------------------------------
;;; code-find-references-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass code-find-references-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "code-find-references")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Find all callers and references to a symbol using \
sb-introspect xref (who-calls, who-references, who-binds, who-sets, \
who-macroexpands). Returns entries with project-relative path, line, \
caller name, and relation. project_only (default true) restricts results \
to paths under the project root. relation optionally filters to one kind \
(\"calls\", \"references\", \"binds\", \"sets\", \"macroexpands\"). \
When the symbol is not found, returns a typed error with a redirect hint. \
Requires attached or hermetic mode.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((symbol
                  :type :string
                  :description "Symbol name to find references to. \
Package-qualified form preferred (e.g. \"my-pkg:my-fn\").")
                 (package
                  :type :string
                  :description "Package name for unqualified symbols. Optional.")
                 (project-only
                  :type :boolean
                  :description "Restrict results to paths under *project-root* \
(default: true). Set to false to include all loaded systems.")
                 (relation
                  :type :string
                  :description "Filter to one xref relation: \"calls\", \
\"references\", \"binds\", \"sets\", or \"macroexpands\". Omit for all."))
                :required ("symbol"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: find xref references to a symbol.
Attached path injects an sb-introspect xref form into the live image.
Hermetic path runs sb-introspect xref in the worker process.
Both paths return the same references envelope."))

(c2mop:ensure-finalized (find-class 'code-find-references-tool))

;;; ---------------------------------------------------------------------------
;;; Result decoder
;;; ---------------------------------------------------------------------------

(defun %decode-code-refs-result (raw symbol-name)
  "Decode the raw result from the injected form or engine into a wire envelope.

RAW is either:
  - a list of (:path PATH :line LINE :caller CALLER :relation RELATION) plists
  - a plist with :not-found key (typed error)
  - NIL (empty result — no references found, not an error)"
  (cond
    ;; Typed not-found marker: outer list starts with :not-found keyword.
    ((and (listp raw) (eq (car raw) :not-found))
     (let* ((kind  (getf raw :not-found))
            (name  (getf raw :name))
            (hint  (getf raw :hint))
            (etype (ecase kind
                     (:package  "package-not-found")
                     (:symbol   "symbol-not-found")
                     (:source-location "found-but-no-source-location"))))
       (make-ht "isError"    t
                "error_type" etype
                "content"
                (text-content (format nil "~@[~A: ~]~A" name hint)))))
    ;; NIL — no references (valid, not an error).
    ((null raw)
     (make-ht "references" #()))
    ;; List of reference plists.
    ((and (listp raw) (or (null raw) (listp (car raw))))
     (let* ((refs (mapcar (lambda (ref)
                            (make-ht "path"     (or (getf ref :path) "")
                                     "line"     (or (getf ref :line) 0)
                                     "caller"   (or (getf ref :caller) "")
                                     "relation" (or (getf ref :relation) "")))
                          raw)))
       (make-ht "references" (coerce refs 'simple-vector))))
    ;; Unexpected shape.
    (t
     (log-event :warn "code-find-references.unexpected-result"
                "symbol" symbol-name
                "type" (princ-to-string (type-of raw)))
     (make-ht "isError" t
              "error_type" "symbol-not-found"
              "content"
              (text-content "Unexpected result from code-find-references.")))))

;;; ---------------------------------------------------------------------------
;;; Attached dispatcher
;;; ---------------------------------------------------------------------------

(defun %dispatch-attach-code-find-references (tool id params)
  "Dispatch code-find-references to the attached Slynk image.
Builds the injected sb-introspect xref form, acquires the call-lock, and
runs bounded-slime-eval. Returns a wire envelope hash-table."
  (declare (ignore id))
  (let* ((symbol-name  (and params (gethash "symbol" params)))
         (package-name (and params (gethash "package" params)))
         ;; project_only defaults to true (absent key -> true).
         (project-only (multiple-value-bind (val presentp)
                           (gethash "project_only" (or params (make-hash-table)))
                         (if presentp val t)))
         (relation     (and params (gethash "relation" params))))
    (unless (and (stringp symbol-name) (plusp (length symbol-name)))
      (return-from %dispatch-attach-code-find-references
        (make-ht "isError" t
                 "content"
                 (text-content "code-find-references: 'symbol' parameter is required."))))
    (let* ((form (handler-case
                     (%build-code-find-refs-form symbol-name package-name
                                                 (if project-only t nil))
                   (error (e)
                     (return-from %dispatch-attach-code-find-references
                       (make-ht "isError" t
                                "content"
                                (text-content
                                 (format nil "code-find-references: form build error: ~A" e)))))))
           ;; The relation filter is handled by the form builder via the
           ;; project-only/finders machinery. If the caller wants a specific
           ;; relation on the attached path we re-filter client-side below.
           (lock (repl-eval-tool-call-lock tool))
           (raw  (handler-case
                     (with-lock-held (lock)
                       (bounded-slime-eval form (repl-eval-tool-slynk-conn tool)))
                   (slime-network-error (e)
                     (log-event :warn "code-find-references.attach.network-error"
                                "error" (handler-case (princ-to-string e)
                                          (error () "")))
                     (return-from %dispatch-attach-code-find-references
                       (make-ht "isError"    t
                                "error_type" "NETWORK_ERROR"
                                "content"
                                (text-content
                                 (format nil "code-find-references: Slynk connection error: ~A"
                                         e)))))))
           ;; If a relation filter was requested and the form returned a list,
           ;; filter client-side (the build-refs-form accepts a relation arg only
           ;; implicitly via the finders list, so we filter here for simplicity).
           (filtered-raw
             (if (and (stringp relation)
                      (plusp (length relation))
                      (listp raw)
                      (not (getf raw :not-found)))
                 (remove-if-not
                  (lambda (entry)
                    (string-equal relation (getf entry :relation)))
                  raw)
                 raw)))
      (%decode-code-refs-result filtered-raw symbol-name))))

;;; ---------------------------------------------------------------------------
;;; tool-handle method
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool code-find-references-tool) id args)
  "Route code-find-references by *mode*.
Attached: injects an sb-introspect xref form into the live image.
Hermetic: routes to worker/code-find-references via dispatch-hermetic-call.
Inline: returns a typed mode error."
  (ecase *mode*
    (:attached
     (let ((repl-tool (get-tool-instance (tool-session tool) "repl-eval")))
       (result id (%dispatch-attach-code-find-references repl-tool id args))))
    (:hermetic
     (dispatch-hermetic-call (tool-session tool) id "code-find-references" args))
    (:inline
     (rpc-error id -32603
                "code-find-references requires attached or hermetic mode."))))
