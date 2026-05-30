;;;; src/tools/lsp-diagnostics.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: lsp-diagnostics.
;;;; Delegates $/alive/tryCompile (default) or $/alive/compile (load=true) to
;;;; alive-lsp via the bridge layer.  When alive-lsp is unreachable, degrades
;;;; to in-process Eclector parse checking flagged degraded:lsp-unavailable (D-12).
;;;;
;;;; Input schema:
;;;;   file_path  (required) — absolute path to the Lisp file
;;;;   load       (optional, boolean) — when true, uses $/alive/compile which
;;;;              loads and evaluates the file in the alive-lsp image; default
;;;;              false uses $/alive/tryCompile (safe, no evaluation)
;;;;
;;;; SECURITY WARNING (T-lsp-bridge-02): load=true causes alive-lsp to load
;;;; and evaluate the file, mutating its Lisp image. This is opt-in behavior.
;;;; Default (load=false / tryCompile) is read-only and safe to call on every
;;;; edit. Only set load=true when you intentionally want to update the
;;;; alive-lsp image's compiled definitions.
;;;;
;;;; NOTE (Pitfall 5 from RESEARCH.md): an empty messages list does not guarantee
;;;; clean compilation. Some SBCL compiler errors lack source locations and are
;;;; silently dropped by alive-lsp's send-message filter.

(defpackage #:dsmr-mcp/src/tools/lsp-diagnostics
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
                #:bridge-diagnostics
                #:degraded-diagnostics)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/lsp-diagnostics)

;;; ---------------------------------------------------------------------------
;;; lsp-diagnostics-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass lsp-diagnostics-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "lsp-diagnostics")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Get compiler diagnostics from alive-lsp for a Lisp file. \
Requires a running alive-lsp server (attach-else-spawn per project root). \
Default (load=false): uses $/alive/tryCompile — safe read-only compilation \
check, does not evaluate or load the file. Optional load=true: uses \
$/alive/compile — evaluates and loads the file into the alive-lsp image \
(mutating, use with caution). Returns {messages: [{severity, location, \
message}]} where severity is 'error', 'warning', or 'info'. An empty \
messages list does not guarantee clean compilation (some errors lack source \
locations and are silently dropped). When alive-lsp is not reachable, \
returns a degraded Eclector parse check flagged degraded:lsp-unavailable.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((file_path
                  :type :string
                  :description "Absolute path to the Lisp file (within session root).")
                 (load
                  :type :boolean
                  :description "When true, use $/alive/compile (evaluates/loads \
the file in the alive-lsp image — mutating). Default false uses \
$/alive/tryCompile (safe, no evaluation)."))
                :required ("file_path"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: $/alive/tryCompile or $/alive/compile delegate.
Degrades to Eclector parse check when alive-lsp is unavailable."))

(c2mop:ensure-finalized (find-class 'lsp-diagnostics-tool))

;;; ---------------------------------------------------------------------------
;;; tool-handle
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool lsp-diagnostics-tool) id args)
  (let* ((root (session-project-root (tool-session tool))))
    ;; No-root guard.
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError"    t
                             "error_type" "project-root-not-set"
                             "content"
                             (text-content
                              "lsp-diagnostics: no project root set. \
Call fs-set-project-root first.")))))
    (let* ((file-path (gethash "file_path" args))
           (load-p    (gethash "load"      args)))
      (let ((pn (allowed-read-path file-path root)))
        (unless pn
          (return-from tool-handle
            (result id (make-ht "isError"    t
                                 "error_type" "sandbox-violation"
                                 "content"
                                 (text-content
                                  (format nil "lsp-diagnostics: ~A is outside \
the read allow-list." file-path))
                                 "path" file-path))))
        (let ((client (ensure-lsp-client root)))
          (if (null client)
              ;; D-12: degrade to Eclector parse check (not an error response).
              (let ((text (handler-case
                               (read-file-string pn)
                             (error (e)
                               (log-event :warn "lsp.tool.diagnostics.read-error"
                                          "path" (namestring pn)
                                          "error" (princ-to-string e))
                               ;; Return empty text — degraded-diagnostics handles empty cleanly.
                               ""))))
                (result id (degraded-diagnostics text)))
              ;; alive-lsp available — delegate to bridge.
              (handler-case
                  (result id (bridge-diagnostics client id (namestring pn)
                                                 :load-p (and load-p (not (eq load-p 'null)))))
                (lsp-connection-lost (e)
                  (log-event :warn "lsp.tool.diagnostics.conn-lost"
                             "error" (princ-to-string e))
                  ;; Wire-loss: degrade to Eclector.
                  (let ((text (handler-case
                                   (read-file-string pn)
                                 (error () ""))))
                    (result id (degraded-diagnostics text)))))))))))
