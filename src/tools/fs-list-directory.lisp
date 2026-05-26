;;;; src/tools/fs-list-directory.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: list directory entries under the read allow-list.
;;;; Mode-independent (dispatcher-side). D-16 no-root guard at entry.

(defpackage #:dsmr-mcp/src/tools/fs-list-directory
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
                #:list-directory-entries)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/fs-list-directory)

(defclass fs-list-directory-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "fs-list-directory")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "List directory entries. Hidden files and build artifacts are filtered by default.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((path
                  :type :string
                  :description "Absolute or project-relative directory path.")
                 (show_hidden
                  :type :boolean
                  :description "Include hidden files (default false). Build artifacts always filtered."))
                :required ("path"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: list directory entries with sandbox containment."))

(c2mop:ensure-finalized (find-class 'fs-list-directory-tool))

(defmethod tool-handle ((tool fs-list-directory-tool) id args)
  (let* ((session     (tool-session tool))
         (root        (session-project-root session)))
    ;; D-16: reject when no root is set
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content"
                            (text-content "fs-list-directory: no project root set. Call fs-set-project-root first.")))))
    (let* ((path-str    (gethash "path" args))
           (show-hidden (gethash "show_hidden" args)))
      (unless (and path-str (stringp path-str))
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "error_type" "invalid-argument"
                              "content" (text-content "fs-list-directory: path must be a string.")))))
      ;; D-14: allowed-read-path canonicalizes (truename) then checks containment
      (let ((pn (allowed-read-path path-str root)))
        (unless pn
          (return-from tool-handle
            (result id (make-ht "isError" t
                                "error_type" "sandbox-violation"
                                "content" (text-content
                                           (format nil "fs-list-directory: ~A is outside the read allow-list." path-str))
                                "path" path-str))))
        (log-event :info "fs.list-directory"
                   "path" (namestring pn)
                   "show-hidden" show-hidden)
        (handler-case
            (let* ((entries     (list-directory-entries pn :show-hidden show-hidden))
                   (entry-vec   (coerce
                                 (mapcar (lambda (pair)
                                           (make-ht "name" (car pair) "type" (cdr pair)))
                                         entries)
                                 'vector))
                   (count       (length entries))
                   (summary     (format nil "~D entr~:@P in ~A" count (namestring pn))))
              (result id
                      (make-ht "content"     (text-content summary)
                               "entries"     entry-vec
                               "path"        (namestring pn)
                               "show_hidden" (if show-hidden t nil))))
          (error (e)
            (result id (make-ht "isError" t
                                "error_type" "list-error"
                                "content" (text-content
                                           (format nil "fs-list-directory: ~A" (princ-to-string e)))
                                "path" path-str))))))))
