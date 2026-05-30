;;;; src/tools/fs-write-file.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: write text to a file under the session root only (D-13).
;;;; Mode-independent (dispatcher-side). D-16 no-root guard at entry.
;;;; Pitfall 6: existing .lisp/.asd files are refused; use lisp-edit-form.

(defpackage #:dsmr-mcp/src/tools/fs-write-file
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
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically
                #:lisp-source-path-p)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/lsp/client
                #:find-lsp-client
                #:bump-uri-version)
  (:import-from #:dsmr-mcp/src/lsp/document
                #:notify-did-change))

(in-package #:dsmr-mcp/src/tools/fs-write-file)

(defclass fs-write-file-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "fs-write-file")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Write text content to a file under the session root. \
Parent directories are created automatically. For editing EXISTING Lisp source \
files use lisp-edit-form instead.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((path
                  :type :string
                  :description "Relative or absolute path under the project root.")
                 (content
                  :type :string
                  :description "Text content to write."))
                :required ("path" "content"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: write text to a file atomically.
D-13: writes are allowed only under the current session root. ASDF source
dirs are read-only. Existing .lisp/.asd files are refused to prevent
accidental structural corruption (Pitfall 6)."))

(c2mop:ensure-finalized (find-class 'fs-write-file-tool))

(defmethod tool-handle ((tool fs-write-file-tool) id args)
  (let* ((session (tool-session tool))
         (root    (session-project-root session)))
    ;; D-16: reject when no root is set
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content"
                            (text-content "fs-write-file: no project root set. Call fs-set-project-root first.")))))
    (let* ((path-str (gethash "path" args))
           (content  (gethash "content" args)))
      (unless (and path-str (stringp path-str))
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "error_type" "invalid-argument"
                              "content" (text-content "fs-write-file: path must be a string.")))))
      (unless (stringp content)
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "error_type" "invalid-argument"
                              "content" (text-content "fs-write-file: content must be a string.")))))
      ;; D-13: ensure-write-path checks containment under session root only
      (let ((pn (ensure-write-path path-str root)))
        (unless pn
          (return-from tool-handle
            (result id (make-ht "isError" t
                                "error_type" "sandbox-violation"
                                "content" (text-content
                                           (format nil "fs-write-file: ~A is outside the write sandbox \
(session root only, not ASDF source dirs)." path-str))
                                "path" path-str))))
        ;; Pitfall 6: refuse to overwrite existing Lisp source files
        (when (and (probe-file pn) (lisp-source-path-p pn))
          (return-from tool-handle
            (result id (make-ht "isError" t
                                "error_type" "lisp-overwrite-refused"
                                "content" (text-content
                                           (format nil "fs-write-file: cannot overwrite existing \
Lisp source file ~A. Use lisp-edit-form for structural edits." (namestring pn)))
                                "path" (namestring pn)
                                "next_tool" "lisp-edit-form"))))
        (log-event :info "fs.write-file"
                   "path" (namestring pn)
                   "bytes" (length content))
        (handler-case
            (progn
              (write-file-string-atomically pn content)
              ;; D-10: fire-and-forget didChange after successful write.
              ;; The ignore-errors wrapper ensures a notification failure (alive-lsp
              ;; not running, no registered client) never fails the edit tool call.
              (ignore-errors
                (let ((lsp-client (find-lsp-client root)))
                  (when lsp-client
                    (notify-did-change
                     lsp-client pn content
                     (bump-uri-version lsp-client (namestring pn))))))
              (result id
                      (make-ht "success" t
                               "content" (text-content
                                          (format nil "Wrote ~A (~D chars)" (namestring pn) (length content)))
                               "path" (namestring pn)
                               "bytes" (length content))))
          (error (e)
            (result id (make-ht "isError" t
                                "error_type" "write-error"
                                "content" (text-content
                                           (format nil "fs-write-file: ~A" (princ-to-string e)))
                                "path" path-str))))))))
