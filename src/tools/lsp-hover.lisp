;;;; src/tools/lsp-hover.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: lsp-hover.
;;;; Delegates textDocument/hover to alive-lsp via the bridge layer.
;;;; When alive-lsp is unreachable, returns a structured lsp-unavailable error
;;;; (D-12 — no degraded equivalent for hover).
;;;;
;;;; Input schema: file_path (required), line (required), character (required).
;;;; file_path is resolved through allowed-read-path before being forwarded.
;;;;
;;;; Note: alive-lsp advertises hoverProvider: nil in capabilities but the
;;;; handle-hover handler is registered and callable. Returns {value: ""} when
;;;; no hover is available at the position (quality depends on image state).

(defpackage #:dsmr-mcp/src/tools/lsp-hover
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
                #:bridge-hover
                #:make-lsp-unavailable-envelope
                #:add-lsp-result-summary)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/lsp-hover)

;;; ---------------------------------------------------------------------------
;;; lsp-hover-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass lsp-hover-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "lsp-hover")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Get hover documentation from alive-lsp at a position in a Lisp file. \
Requires a running alive-lsp server (attach-else-spawn per project root). \
Returns {value: \"<docstring>\"} where value is an empty string when no \
documentation is found at the position. Quality depends on which packages \
are loaded in the alive-lsp image. Returns lsp-unavailable when alive-lsp \
is not reachable.")
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
  (:documentation "MCP tool: textDocument/hover delegate to alive-lsp.
Returns docstring text or empty string; lsp-unavailable when the server is down."))

(c2mop:ensure-finalized (find-class 'lsp-hover-tool))

;;; ---------------------------------------------------------------------------
;;; tool-handle
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool lsp-hover-tool) id args)
  (let* ((root (session-project-root (tool-session tool))))
    ;; No-root guard.
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError"    t
                             "error_type" "project-root-not-set"
                             "content"
                             (text-content
                              "lsp-hover: no project root set. \
Call fs-set-project-root first.")))))
    (let* ((file-path (gethash "file_path" args))
           (line      (gethash "line"      args))
           (char      (gethash "character" args)))
      (let ((pn (allowed-read-path file-path root)))
        (unless pn
          (return-from tool-handle
            (result id (make-ht "isError"    t
                                 "error_type" "sandbox-violation"
                                 "content"
                                 (text-content
                                  (format nil "lsp-hover: ~A is outside \
the read allow-list." file-path))
                                 "path" file-path))))
        (let ((client (ensure-lsp-client root)))
          (if (null client)
              (result id (make-lsp-unavailable-envelope "lsp-hover"))
              (handler-case
                  (result id (add-lsp-result-summary
                              (bridge-hover client id (namestring pn) line char)
                              "hover"))
                (lsp-connection-lost (e)
                  (log-event :warn "lsp.tool.hover.conn-lost"
                             "error" (princ-to-string e))
                  (result id (make-lsp-unavailable-envelope "lsp-hover"))))))))))
