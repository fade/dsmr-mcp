;;;; src/tools/lisp-edit-form.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: lisp-edit-form -- structure-aware Lisp form editor.
;;;; Mode-independent (dispatcher-side). D-16 no-root guard at entry.
;;;; VERB-20/D-07: CST-driven replace/insert/delete with parinfer auto-repair,
;;;; comment/indentation preservation, and dry-run preview.

(defpackage #:dsmr-mcp/src/tools/lisp-edit-form
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
  (:import-from #:dsmr-mcp/src/lisp-edit-form
                #:edit-form)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/lisp-edit-form)

(defclass lisp-edit-form-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "lisp-edit-form")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Structure-aware edit of a top-level Lisp form using Eclector CST parsing. \
Supports replace, insert_before, insert_after, and delete operations while preserving \
formatting and comments. PREFERRED METHOD for editing existing Lisp source code. \
Automatically repairs missing closing parentheses using parinfer (non-delete ops). \
ALWAYS use this tool instead of fs-write-file when modifying Lisp forms.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((file_path
                  :type :string
                  :description "Target file path (absolute, or relative to project root).")
                 (form_type
                  :type :string
                  :description "Form type to search, e.g. \"defun\", \"defmacro\", \"defmethod\".")
                 (form_name
                  :type :string
                  :description "Form name to match. For defmethod include specializers, \
e.g. \"print-object ((obj my-class) stream)\". Reader macro prefixes #: and : are \
stripped automatically.")
                 (operation
                  :type :string
                  :description "Operation: replace, insert_before, insert_after, or delete."
                  :enum ("replace" "insert_before" "insert_after" "delete"))
                 (content
                  :type :string
                  :description "Full Lisp form text for replace/insert operations. \
Required for replace/insert_before/insert_after; ignored for delete. \
Must contain exactly one top-level form. Missing closing parens are auto-repaired.")
                 (dry_run
                  :type :boolean
                  :description "When true, return a preview without writing to disk.")
                 (normalize_blank_lines
                  :type :boolean
                  :description "When true (default), normalize blank lines around top-level forms.")
                 (readtable
                  :type :string
                  :description "Named-readtable designator for files using custom reader macros."))
                :required ("file_path" "form_type" "form_name" "operation"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: structure-aware Lisp form editor (VERB-20).
Locates a named top-level form by type and name, then replaces, inserts around,
or deletes it. Parinfer auto-repairs missing closing parens and surfaces a
parinfer_warning. Dry-run previews the exact text that would be written."))

(c2mop:ensure-finalized (find-class 'lisp-edit-form-tool))

(defmethod tool-handle ((tool lisp-edit-form-tool) id args)
  (let* ((session  (tool-session tool))
         (root     (session-project-root session)))
    ;; D-16: reject when no root is set.
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError"     t
                            "error_type"  "project-root-not-set"
                            "content"
                            (text-content "lisp-edit-form: no project root set. \
Call fs-set-project-root first.")))))
    (let* ((file-path   (gethash "file_path" args))
           (form-type   (gethash "form_type" args))
           (form-name   (gethash "form_name" args))
           (operation   (gethash "operation" args))
           (content     (gethash "content" args))
           (dry-run     (gethash "dry_run" args))
           (norm-blank  (let ((v (gethash "normalize_blank_lines" args)))
                          (if (null v) t v)))
           (readtable   (gethash "readtable" args)))
      ;; Basic argument validation.
      (unless (and file-path (stringp file-path) (plusp (length file-path)))
        (return-from tool-handle
          (result id (make-ht "isError" t "error_type" "invalid-argument"
                              "content" (text-content "lisp-edit-form: file_path must be a non-empty string.")))))
      (unless (and form-type (stringp form-type) (plusp (length form-type)))
        (return-from tool-handle
          (result id (make-ht "isError" t "error_type" "invalid-argument"
                              "content" (text-content "lisp-edit-form: form_type must be a non-empty string.")))))
      (unless (and form-name (stringp form-name) (plusp (length form-name)))
        (return-from tool-handle
          (result id (make-ht "isError" t "error_type" "invalid-argument"
                              "content" (text-content "lisp-edit-form: form_name must be a non-empty string.")))))
      (unless (member operation '("replace" "insert_before" "insert_after" "delete")
                       :test #'string=)
        (return-from tool-handle
          (result id (make-ht "isError" t "error_type" "invalid-argument"
                              "content" (text-content
                                         (format nil "lisp-edit-form: operation must be one of \
replace, insert_before, insert_after, delete (got ~A)." operation))))))
      (unless (or (string= operation "delete") (and content (stringp content)))
        (return-from tool-handle
          (result id (make-ht "isError" t "error_type" "invalid-argument"
                              "content" (text-content
                                         (format nil "lisp-edit-form: content is required for ~A operation."
                                                 operation))))))
      (log-event :info "lisp-edit-form"
                 "file_path" file-path "form_type" form-type
                 "form_name" form-name "operation" operation
                 "dry_run" dry-run)
      (handler-case
          (if dry-run
              ;; Dry-run: edit-form returns a hash-table with original/preview.
              (let ((preview-ht (edit-form root file-path form-type form-name
                                           operation content
                                           :dry-run t
                                           :normalize-blank-lines norm-blank
                                           :readtable readtable)))
                (let* ((would-change    (gethash "would_change" preview-ht))
                       (original-text   (gethash "original" preview-ht))
                       (preview-text    (gethash "preview" preview-ht))
                       (parinfer-warn   (gethash "parinfer_warning" preview-ht))
                       (summary         (format nil "Dry-run ~A on ~A ~A in ~A (~:[no change~;would change~])~
~@[~%WARNING: ~A~]~@[~%~%--- original ---~%~A~]~@[~%~%--- preview ---~%~A~]"
                                                operation form-type form-name file-path
                                                would-change parinfer-warn
                                                original-text preview-text))
                       (ht              (make-ht "path"         file-path
                                                 "operation"    operation
                                                 "form_type"    form-type
                                                 "form_name"    form-name
                                                 "would_change" would-change
                                                 "original"     original-text
                                                 "preview"      preview-text
                                                 "content"      (text-content summary))))
                  (when parinfer-warn
                    (setf (gethash "parinfer_warning" ht) parinfer-warn))
                  (result id ht)))
              ;; Apply: edit-form returns (values updated-text parinfer-warning changed-p).
              (multiple-value-bind (updated parinfer-warn changed-p)
                  (edit-form root file-path form-type form-name
                             operation content
                             :dry-run nil
                             :normalize-blank-lines norm-blank
                             :readtable readtable)
                (let* ((summary  (if changed-p
                                     (format nil "Applied ~A to ~A ~A in ~A (~D chars)~@[~%WARNING: ~A~]"
                                             operation form-type form-name file-path
                                             (length updated) parinfer-warn)
                                     (format nil "No change to ~A ~A in ~A (content matches existing form)~@[~%WARNING: ~A~]"
                                             form-type form-name file-path parinfer-warn)))
                       (ht       (make-ht "path"         file-path
                                          "operation"    operation
                                          "form_type"    form-type
                                          "form_name"    form-name
                                          "would_change" changed-p
                                          "bytes"        (length updated)
                                          "content"      (text-content summary))))
                  (when parinfer-warn
                    (setf (gethash "parinfer_warning" ht) parinfer-warn))
                  (result id ht))))
        (error (e)
          (result id (make-ht "isError"    t
                              "error_type" "edit-form-error"
                              "content"    (text-content
                                            (format nil "lisp-edit-form: ~A"
                                                    (princ-to-string e))))))))))
