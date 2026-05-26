;;;; src/tools/fs-read-file.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: bounded file read under the session root + ASDF source dirs.
;;;; Mode-independent (dispatcher-side). D-16 no-root guard at entry.
;;;; SAFETY-03: truncation envelope returned when the read cap is hit.

(defpackage #:dsmr-mcp/src/tools/fs-read-file
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
                #:validate-args)
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path)
  (:import-from #:dsmr-mcp/src/fs
                #:read-file-string)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/fs-read-file)

(defclass fs-read-file-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "fs-read-file")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Read a text file within the project root or registered ASDF source dirs. \
Bounded by a 2 MB cap; use offset/limit to paginate large files.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((path
                  :type :string
                  :description "Absolute or project-relative path to the file.")
                 (offset
                  :type :integer
                  :description "0-based character offset to start reading (optional).")
                 (limit
                  :type :integer
                  :description "Maximum characters to return (optional; capped at 2 MB)."))
                :required ("path"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: bounded text file read with offset/limit pagination.
Returns a truncation envelope (truncated, file_length, read_length) when the
file extends beyond the effective read cap (SAFETY-03/D-17)."))

(c2mop:ensure-finalized (find-class 'fs-read-file-tool))

(defmethod tool-handle ((tool fs-read-file-tool) id args)
  (let* ((session (tool-session tool))
         (root    (session-project-root session)))
    ;; D-16: reject when no root is set
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content"
                            (text-content "fs-read-file: no project root set. Call fs-set-project-root first.")))))
    (let* ((path-str (gethash "path" args))
           (offset   (gethash "offset" args))
           (limit    (gethash "limit" args)))
      (unless (and path-str (stringp path-str))
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "error_type" "invalid-argument"
                              "content" (text-content "fs-read-file: path must be a string.")))))
      ;; D-14: allowed-read-path canonicalizes (truename) then checks containment
      (let ((pn (allowed-read-path path-str root)))
        (unless pn
          (return-from tool-handle
            (result id (make-ht "isError" t
                                "error_type" "sandbox-violation"
                                "content" (text-content
                                           (format nil "fs-read-file: ~A is outside the read allow-list \
(project root + ASDF source dirs)." path-str))
                                "path" path-str))))
        (log-event :info "fs.read-file"
                   "path" (namestring pn)
                   "offset" offset
                   "limit" limit)
        (handler-case
            (multiple-value-bind (text truncated file-len read-len)
                (read-file-string pn :offset offset :limit limit)
              (let ((ht (make-ht "content" (text-content text)
                                 "text" text
                                 "path" (namestring pn)
                                 "offset" offset
                                 "limit" limit)))
                ;; SAFETY-03: truncation envelope
                (when truncated
                  (setf (gethash "truncated"   ht) t
                        (gethash "file_length"  ht) file-len
                        (gethash "read_length"  ht) read-len))
                (result id ht)))
          (error (e)
            (result id (make-ht "isError" t
                                "error_type" "read-error"
                                "content" (text-content
                                           (format nil "fs-read-file: ~A" (princ-to-string e)))
                                "path" path-str))))))))
