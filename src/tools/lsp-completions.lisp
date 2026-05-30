;;;; src/tools/lsp-completions.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: lsp-completions.
;;;; Delegates textDocument/completion to alive-lsp via the bridge layer.
;;;; When alive-lsp is unreachable, returns a structured lsp-unavailable error
;;;; (D-12 — no degraded equivalent for completions).
;;;;
;;;; Input schema: file_path (required), line (required), character (required).
;;;; file_path is resolved through allowed-read-path before being forwarded.

(defpackage #:dsmr-mcp/src/tools/lsp-completions
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
  (:import-from #:dsmr-mcp/src/lsp/client
                #:ensure-lsp-client
                #:lsp-connection-lost)
  (:import-from #:dsmr-mcp/src/lsp/bridge
                #:bridge-completions
                #:make-lsp-unavailable-envelope)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/lsp-completions)

;;; ---------------------------------------------------------------------------
;;; lsp-completions-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass lsp-completions-tool (mcp-tool)
  ;; CRITICAL: :initform on class-allocated slots, NOT :default-initargs.
  ;; c2mop:class-prototype does not apply :default-initargs.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "lsp-completions")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Get code completions from alive-lsp at a position in a Lisp file. \
Requires a running alive-lsp server (attach-else-spawn per project root). \
Returns {items: [...]} where each item has label, kind, documentation, \
insertText, insertTextFormat fields. Returns lsp-unavailable when \
alive-lsp is not reachable.")
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
                  :description "0-based character offset within the line."))
                :required ("file_path" "line" "character"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: textDocument/completion delegate to alive-lsp.
Returns a completion list or lsp-unavailable when the server is down."))

(c2mop:ensure-finalized (find-class 'lsp-completions-tool))

;;; ---------------------------------------------------------------------------
;;; tool-handle
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool lsp-completions-tool) id args)
  (let* ((root (session-project-root (tool-session tool))))
    ;; No-root guard — must be first.
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError"    t
                             "error_type" "project-root-not-set"
                             "content"
                             (text-content
                              "lsp-completions: no project root set. \
Call fs-set-project-root first.")))))
    (let* ((file-path (gethash "file_path" args))
           (line      (gethash "line"      args))
           (char      (gethash "character" args)))
      ;; Resolve path through sandbox.
      (let ((pn (allowed-read-path file-path root)))
        (unless pn
          (return-from tool-handle
            (result id (make-ht "isError"    t
                                 "error_type" "sandbox-violation"
                                 "content"
                                 (text-content
                                  (format nil "lsp-completions: ~A is outside \
the read allow-list." file-path))
                                 "path" file-path))))
        ;; Ensure alive-lsp client for this root.
        (let ((client (ensure-lsp-client root)))
          (if (null client)
              ;; alive-lsp unreachable — D-12 lsp-unavailable error.
              (result id (make-lsp-unavailable-envelope "lsp-completions"))
              ;; Delegate to bridge; catch wire-loss.
              (handler-case
                  (result id (bridge-completions client id (namestring pn) line char))
                (lsp-connection-lost (e)
                  (log-event :warn "lsp.tool.completions.conn-lost"
                             "error" (princ-to-string e))
                  (result id (make-lsp-unavailable-envelope "lsp-completions"))))))))))
