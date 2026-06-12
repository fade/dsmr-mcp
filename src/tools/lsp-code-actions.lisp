;;;; src/tools/lsp-code-actions.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: lsp-code-actions.
;;;; Synthesized discover-then-apply code-actions menu over alive-lsp's
;;;; primitive verbs (D-01/D-02/D-04). There is no codeAction provider in
;;;; alive-lsp; this tool builds the menu itself.
;;;;
;;;; DISCOVER mode (action absent or nil):
;;;;   Probes the position with $/alive/getPackageForPosition,
;;;;   $/alive/surroundingFormBounds, and $/alive/symbol to determine which
;;;;   actions are applicable, then returns a vector of action descriptors.
;;;;   Always includes 'format'; includes 'macroexpand' when a surrounding form
;;;;   is found; includes 'remove-from-export' when a symbol is found.
;;;;
;;;; APPLY mode (action hash-table from a prior discover result):
;;;;   Dispatches to $/alive/macroexpand1, $/alive/unexportSymbol, or
;;;;   textDocument/rangeFormatting depending on the chosen action.
;;;;   rangeFormatting is serialized per client (alive-lsp's blocking
;;;;   workspace/configuration round-trip is not concurrency-safe).
;;;;
;;;; When alive-lsp is unreachable, returns lsp-unavailable error (D-12).
;;;;
;;;; Input schema:
;;;;   file_path  (required) — absolute path within session root
;;;;   line       (required) — 0-based line for position (discover/apply)
;;;;   character  (required) — 0-based character offset for position
;;;;   action     (optional) — action descriptor hash-table from discover result

(defpackage #:dsmr-mcp/src/tools/lsp-code-actions
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content)
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path)
  (:import-from #:dsmr-mcp/src/fs
                #:read-file-string)
  (:import-from #:dsmr-mcp/src/lsp/client
                #:ensure-lsp-client
                #:lsp-connection-lost)
  (:import-from #:dsmr-mcp/src/lsp/bridge
                #:bridge-code-actions
                #:make-lsp-unavailable-envelope
                #:add-lsp-result-summary)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/lsp-code-actions)

;;; ---------------------------------------------------------------------------
;;; lsp-code-actions-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass lsp-code-actions-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "lsp-code-actions")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Synthesized discover-then-apply code-actions menu for a position \
in a Lisp file. Requires a running alive-lsp server. Two-step workflow: \
(1) Call without action to DISCOVER applicable actions at line/character — \
returns a vector of action descriptors (macroexpand, remove-from-export, format). \
(2) Call with action set to one of those descriptors to APPLY it. Actions are \
backed by $/alive/macroexpand1 (macro expansion at point), \
$/alive/unexportSymbol (remove symbol from package exports), and \
textDocument/rangeFormatting (format the surrounding form). \
Returns lsp-unavailable when alive-lsp is not reachable.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((file_path
                  :type :string
                  :description "Absolute path to the Lisp file (within session root).")
                 (line
                  :type :integer
                  :description "0-based line number of the cursor position.")
                 (character
                  :type :integer
                  :description "0-based character offset within the line.")
                 (action
                  :type :object
                  :description "Action descriptor hash-table from a prior discover \
call. Absent for discover mode; present to apply a chosen action."))
                :required ("file_path" "line" "character"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: synthesized code-actions over alive-lsp primitives.
Discover returns the applicable action menu; apply executes the chosen action."))

(c2mop:ensure-finalized (find-class 'lsp-code-actions-tool))

;;; ---------------------------------------------------------------------------
;;; tool-handle
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool lsp-code-actions-tool) id args)
  (let* ((root (session-project-root (tool-session tool))))
    ;; No-root guard.
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError"    t
                             "error_type" "project-root-not-set"
                             "content"
                             (text-content
                              "lsp-code-actions: no project root set. \
Call fs-set-project-root first.")))))
    (let* ((file-path (gethash "file_path" args))
           (line      (gethash "line"      args))
           (char      (gethash "character" args))
           (action-ht (let ((a (gethash "action" args)))
                        ;; Treat jzon null and missing as absent (discover mode).
                        (if (or (null a) (eq a 'null)) nil a))))
      (let ((pn (allowed-read-path file-path root)))
        (unless pn
          (return-from tool-handle
            (result id (make-ht "isError"    t
                                 "error_type" "sandbox-violation"
                                 "content"
                                 (text-content
                                  (format nil "lsp-code-actions: ~A is outside \
the read allow-list." file-path))
                                 "path" file-path))))
        (let ((client (ensure-lsp-client root)))
          (if (null client)
              (result id (make-lsp-unavailable-envelope "lsp-code-actions"))
              (handler-case
                  ;; Read file text for the apply-macroexpand path (needed when
                  ;; extracting form text for macroexpand; nil is safe as fallback).
                  (let ((text (when action-ht
                                (handler-case
                                    (read-file-string pn)
                                  (error () nil)))))
                    (result id (add-lsp-result-summary
                                (bridge-code-actions client id (namestring pn)
                                                     line char
                                                     :action-ht action-ht
                                                     :text text)
                                "code-actions")))
                (lsp-connection-lost (e)
                  (log-event :warn "lsp.tool.code-actions.conn-lost"
                             "error" (princ-to-string e))
                  (result id (make-lsp-unavailable-envelope "lsp-code-actions"))))))))))
