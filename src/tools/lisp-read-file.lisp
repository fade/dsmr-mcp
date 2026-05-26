;;;; src/tools/lisp-read-file.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: lisp-read-file -- collapsed signature view of Lisp source files.
;;;; Mode-independent (dispatcher-side).  D-16 no-root guard at entry.
;;;; SAFETY-02: path check via allowed-read-path (root + ASDF source dirs).
;;;; VERB-06/D-12: collapsed-by-default, name_pattern / content_pattern expansion.

(defpackage #:dsmr-mcp/src/tools/lisp-read-file
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
  (:import-from #:dsmr-mcp/src/lisp-read-file
                #:read-file-collapsed)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/lisp-read-file)

(defclass lisp-read-file-tool (mcp-tool)
  ;; Class-allocated slots use :initform (not :default-initargs).
  ;; c2mop:class-prototype does not apply :default-initargs; the metaclass
  ;; finalize-inheritance :after reads the prototype for the name slot.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "lisp-read-file")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Read a Lisp source file with a collapsed signature view to save context tokens. \
PREFER this over fs-read-file for .lisp and .asd files unless you need raw bytes. \
Use name_pattern to locate specific definitions. \
Use collapsed=true (default) to see only signatures, collapsed=false for full source. \
When raw mode output is truncated a '[Showing lines A-B of N. Use offset=B to read more.]' \
footer is appended to guide pagination.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((path
                  :type :string
                  :description "Path to the Lisp source file (absolute, or relative to project root).")
                 (collapsed
                  :type :boolean
                  :description "When true (default) collapse definitions to signatures; false for raw lines.")
                 (name_pattern
                  :type :string
                  :description "CL-PPCRE regex to match definition names to expand in collapsed view.")
                 (content_pattern
                  :type :string
                  :description "CL-PPCRE regex to match form content to expand in collapsed view.")
                 (offset
                  :type :integer
                  :description "0-based line offset for raw mode (collapsed=false) pagination.")
                 (limit
                  :type :integer
                  :description "Maximum lines to return in raw mode (default 500).")
                 (readtable
                  :type :string
                  :description "Named-readtable designator for files using custom reader macros."))
                :required ("path"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: collapsed-view Lisp file reader.
Produces token-efficient top-level signature views; expands matching forms on demand."))

(c2mop:ensure-finalized (find-class 'lisp-read-file-tool))

(defmethod tool-handle ((tool lisp-read-file-tool) id args)
  (let* ((session (tool-session tool))
         (root    (session-project-root session)))
    ;; D-16: reject when no root is set.
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content"
                            (text-content "lisp-read-file: no project root set. \
Call fs-set-project-root first.")))))
    (let* ((path-str       (gethash "path" args))
           (collapsed      (let ((v (gethash "collapsed" args)))
                             (if (null v) t v)))
           (name-pattern   (gethash "name_pattern" args))
           (content-pattern (gethash "content_pattern" args))
           (offset         (gethash "offset" args))
           (limit          (gethash "limit" args))
           (readtable      (gethash "readtable" args)))
      (unless (and path-str (stringp path-str) (plusp (length path-str)))
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "error_type" "invalid-argument"
                              "content"
                              (text-content "lisp-read-file: path must be a non-empty string.")))))
      ;; SAFETY-02/D-14: sandbox check via allowed-read-path.
      (let ((pn (allowed-read-path path-str root)))
        (unless pn
          (return-from tool-handle
            (result id (make-ht "isError" t
                                "error_type" "sandbox-violation"
                                "content"
                                (text-content
                                 (format nil "lisp-read-file: ~A is outside the read allow-list \
(project root + ASDF source dirs)." path-str))
                                "path" path-str))))
        (log-event :info "lisp-read-file.read"
                   "path" (namestring pn)
                   "collapsed" collapsed
                   "name_pattern" (or name-pattern "")
                   "content_pattern" (or content-pattern ""))
        (handler-case
            (multiple-value-bind (text truncated file-len read-len)
                (read-file-string pn)
              (declare (ignore truncated file-len read-len))
              (multiple-value-bind (rendered mode meta)
                  (read-file-collapsed text
                                       :collapsed collapsed
                                       :name-pattern name-pattern
                                       :content-pattern content-pattern
                                       :offset offset
                                       :limit limit
                                       :readtable readtable
                                       :source-path pn)
                (result id
                        (make-ht "content" (text-content rendered)
                                 "text"    rendered
                                 "path"    (namestring pn)
                                 "mode"    mode
                                 "meta"    meta))))
          (error (e)
            (result id (make-ht "isError" t
                                "error_type" "read-error"
                                "content"
                                (text-content
                                 (format nil "lisp-read-file: ~A" (princ-to-string e)))
                                "path" path-str))))))))
