;;;; src/tools/lisp-patch-form.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: lisp-patch-form -- scoped exact-text replacement within a form.
;;;; Mode-independent (dispatcher-side). D-16 no-root guard at entry.
;;;; VERB-21/D-08: exact-once match; fail-hard on structural break; no repair.

(defpackage #:dsmr-mcp/src/tools/lisp-patch-form
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
  (:import-from #:dsmr-mcp/src/lisp-patch-form
                #:patch-form
                #:patch-operation-error
                #:patch-operation-reason)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/lisp-patch-form)

(defclass lisp-patch-form-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "lisp-patch-form")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Scoped text replacement within a matched top-level Lisp form. \
Finds old_text (exact, whitespace-sensitive) within the form identified by \
form_type and form_name, and replaces it with new_text. old_text must match \
exactly once within the form. Most token-efficient way to make small changes \
to large forms. Does NOT auto-repair parentheses — if the patch breaks form \
structure it fails immediately and no changes are written to disk. \
Use lisp-edit-form instead when replacing or inserting entire forms.")
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
                  :description "Form name to match. Reader macro prefixes #: and : are stripped automatically.")
                 (old_text
                  :type :string
                  :description "Text to find within the matched form. Exact, whitespace-sensitive. \
Must occur exactly once in the form.")
                 (new_text
                  :type :string
                  :description "Replacement text for old_text.")
                 (dry_run
                  :type :boolean
                  :description "When true, return a preview without writing to disk.")
                 (readtable
                  :type :string
                  :description "Named-readtable designator for files using custom reader macros."))
                :required ("file_path" "form_type" "form_name" "old_text" "new_text"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: scoped exact-text form patch (VERB-21).
Locates a named top-level form and replaces old_text with new_text within it.
The exact-once invariant, fail-hard structural validation, and no-write-on-error
guarantee make this the safe narrow-replacement verb."))

(c2mop:ensure-finalized (find-class 'lisp-patch-form-tool))

(defmethod tool-handle ((tool lisp-patch-form-tool) id args)
  (let* ((session (tool-session tool))
         (root    (session-project-root session)))
    ;; D-16: reject when no root is set.
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError"    t
                            "error_type" "project-root-not-set"
                            "content"
                            (text-content "lisp-patch-form: no project root set. \
Call fs-set-project-root first.")))))
    (let* ((file-path  (gethash "file_path" args))
           (form-type  (gethash "form_type" args))
           (form-name  (gethash "form_name" args))
           (old-text   (gethash "old_text" args))
           (new-text   (gethash "new_text" args))
           (dry-run    (gethash "dry_run" args))
           (readtable  (gethash "readtable" args)))
      ;; Basic argument validation.
      (unless (and file-path (stringp file-path) (plusp (length file-path)))
        (return-from tool-handle
          (result id (make-ht "isError" t "error_type" "invalid-argument"
                              "content" (text-content "lisp-patch-form: file_path must be a non-empty string.")))))
      (unless (and form-type (stringp form-type) (plusp (length form-type)))
        (return-from tool-handle
          (result id (make-ht "isError" t "error_type" "invalid-argument"
                              "content" (text-content "lisp-patch-form: form_type must be a non-empty string.")))))
      (unless (and form-name (stringp form-name) (plusp (length form-name)))
        (return-from tool-handle
          (result id (make-ht "isError" t "error_type" "invalid-argument"
                              "content" (text-content "lisp-patch-form: form_name must be a non-empty string.")))))
      (unless (and old-text (stringp old-text) (plusp (length old-text)))
        (return-from tool-handle
          (result id (make-ht "isError" t "error_type" "invalid-argument"
                              "content" (text-content "lisp-patch-form: old_text must be a non-empty string.")))))
      (unless (and new-text (stringp new-text))
        (return-from tool-handle
          (result id (make-ht "isError" t "error_type" "invalid-argument"
                              "content" (text-content "lisp-patch-form: new_text must be a string.")))))
      (log-event :info "lisp-patch-form"
                 "file_path" file-path "form_type" form-type
                 "form_name" form-name "dry_run" dry-run)
      (handler-case
          (if dry-run
              (let ((preview-ht (patch-form root file-path form-type form-name
                                            old-text new-text
                                            :dry-run t
                                            :readtable readtable)))
                (let* ((would-change  (gethash "would_change" preview-ht))
                       (original-text (gethash "original" preview-ht))
                       (preview-text  (gethash "preview" preview-ht))
                       (summary       (format nil "Dry-run patch on ~A ~A in ~A (~:[no change~;would change~])~
~@[~%~%--- original ---~%~A~]~@[~%~%--- preview ---~%~A~]"
                                              form-type form-name file-path
                                              would-change original-text preview-text)))
                  (result id
                          (make-ht "path"         file-path
                                   "operation"    "patch"
                                   "form_type"    form-type
                                   "form_name"    form-name
                                   "would_change" would-change
                                   "original"     original-text
                                   "preview"      preview-text
                                   "content"      (text-content summary)))))
              (multiple-value-bind (updated changed-p)
                  (patch-form root file-path form-type form-name
                              old-text new-text
                              :dry-run nil
                              :readtable readtable)
                (let ((summary (if changed-p
                                   (format nil "Applied patch to ~A ~A in ~A (~D chars → ~D chars)"
                                           form-type form-name file-path
                                           (length old-text) (length new-text))
                                   (format nil "No change to ~A ~A in ~A (old_text already matches new_text)"
                                           form-type form-name file-path))))
                  (result id
                          (make-ht "path"         file-path
                                   "form_type"    form-type
                                   "form_name"    form-name
                                   "would_change" changed-p
                                   "bytes"        (length updated)
                                   "content"      (text-content summary))))))
        (patch-operation-error (e)
          ;; Typed error envelope: the write did NOT happen (D-08).
          (result id (make-ht "isError"    t
                              "error_type" "patch-operation-error"
                              "content"    (text-content
                                            (format nil "lisp-patch-form: ~A"
                                                    (patch-operation-reason e))))))
        (error (e)
          (result id (make-ht "isError"    t
                              "error_type" "patch-error"
                              "content"    (text-content
                                            (format nil "lisp-patch-form: ~A"
                                                    (princ-to-string e))))))))))
