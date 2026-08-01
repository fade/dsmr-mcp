;;;; src/tools/lisp-edit-comment.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: lisp-edit-comment, the structure-aware comment editor.
;;;; Mode-independent (dispatcher-side): it reads and writes files on disk and
;;;; never talks to an attached Lisp image.
;;;;
;;;; One verb with two ways to name the target: a free-standing comment named
;;;; by a substring of it, or the comment sitting flush on top of a named form.
;;;; Replace and delete are the whole operation set. An anchor naming no
;;;; comment or more than one comes back as its own error type, told apart
;;;; from an unexpected failure, and the file is left exactly as it was.

(defpackage #:dsmr-mcp/src/tools/lisp-edit-comment
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
  (:import-from #:dsmr-mcp/src/lisp-edit-comment
                #:edit-comment
                #:comment-operation-error
                #:comment-operation-reason)
  (:import-from #:dsmr-mcp/src/log
                #:log-event))

(in-package #:dsmr-mcp/src/tools/lisp-edit-comment)

(defclass lisp-edit-comment-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "lisp-edit-comment")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Structure-aware edit of a comment in a Lisp source file. \
Replaces or deletes a comment the form editors cannot reach: a free-standing \
banner between top-level forms, or the comment sitting flush on top of a named \
form. Region mode names the comment by a unique substring of it; line_start and \
line_end constrain which comment is meant, either of them on its own is enough, \
and a match outside the range they give is refused rather than edited. Leading \
mode names the form the comment sits on, through form_type and form_name; a blank \
line between a comment and the form makes that comment free-standing, so name it \
by substring instead. Every surrounding form is proven byte for byte identical \
before anything is written, and an anchor naming no comment or more than one \
fails without writing. Use this instead of a plain text edit when changing \
comments in Lisp source. Adding a brand new comment is not offered here: \
lisp-edit-form insert_before already places one relative to a form.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((file_path
                  :type :string
                  :description "Target file path (absolute, or relative to project root).")
                 (mode
                  :type :string
                  :description "How the comment is named: \"region\" for a free-standing \
comment named by substring, or \"leading\" for the comment flush on top of a form."
                  :enum ("region" "leading"))
                 (operation
                  :type :string
                  :description "Operation: replace or delete. Delete also removes \
the whitespace run following the comment, so the forms either side end up \
separated by a single blank line. A comment that ends the file has nothing after \
it to remove, so the blank line above it stays."
                  :enum ("replace" "delete"))
                 (substring
                  :type :string
                  :description "Region mode: a substring of the comment to edit. Must \
match exactly one free-standing comment, or exactly one lying within the line \
range, when either line_start or line_end is given.")
                 (line_start
                  :type :integer
                  :description "Region mode: first source line of the wanted comment, \
1-based. This constrains which comment is meant, rather than settling a tie: a \
comment matching substring but lying outside the range is refused, naming both the \
range given and the lines the match sits on. It stands on its own: with line_end \
omitted the range is the single line named here.")
                 (line_end
                  :type :integer
                  :description "Region mode: last source line of the wanted comment, \
1-based. It constrains the target exactly as line_start does, and it stands on \
its own the same way: with line_start omitted the range is the single line named \
here, and a comment matching substring elsewhere is refused rather than edited. \
Given both, the range runs from line_start to line_end.")
                 (form_type
                  :type :string
                  :description "Leading mode: form type the comment sits on, \
e.g. \"defun\", \"defmacro\", \"defmethod\".")
                 (form_name
                  :type :string
                  :description "Leading mode: name of the form the comment sits on. \
For defmethod include specializers. Reader macro prefixes #: and : are stripped \
automatically.")
                 (content
                  :type :string
                  :description "Replacement comment text, including its own comment \
characters. Required for replace; ignored for delete. It replaces the comment \
run's own bytes, and those bytes end after the newline closing the comment's last \
line: when the text does not end in a newline, one is supplied, so the blank line \
below the comment survives and the comment can still be found by substring \
afterwards. Line endings are converted to the ones the file already uses. The \
empty string is spliced exactly as given.")
                 (dry_run
                  :type :boolean
                  :description "When true, return a preview without writing to disk.")
                 (readtable
                  :type :string
                  :description "Named-readtable designator. A file read through a custom \
readtable yields no comments at all, so naming one here makes every comment in the \
file unreachable by this tool."))
                :required ("file_path" "mode" "operation"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: structure-aware comment-region editor.
Locates a comment run by a substring of it or by the form it sits on, then
replaces or deletes exactly that run's bytes. The whitespace around the comment
survives untouched, every other form is compared byte for byte before the write,
and dry-run previews the exact text that would be written."))

(c2mop:ensure-finalized (find-class 'lisp-edit-comment-tool))

(defun %invalid-argument (id message)
  "Build the invalid-argument envelope for ID carrying MESSAGE."
  (result id (make-ht "isError"    t
                      "error_type" "invalid-argument"
                      "content"    (text-content message))))

(defun %non-empty-string-p (value)
  "Return T when VALUE is a string with at least one character in it."
  (and value (stringp value) (plusp (length value))))

(defun %region-summary (report)
  "Render REPORT, the changed-region hash-table, as the body of a result message.

The line about verification states what was actually checked rather than a fixed
claim.  The check compares the file's forms against the original and says they
all came back unchanged; when the edit changed nothing there was no comparison
to run and the message says that instead.

It makes no claim about the whitespace around the comment.  A delete removes the
whitespace run following the comment by design, so a message promising the
surroundings were left alone would be false every time a delete succeeded.

A file that was already failing to balance or to read says so on its own line,
because the whole-file checks were skipped for it rather than charged to this
edit, and a caller reading a plain success would otherwise take the file for
sound."
  (format nil "Lines ~A to ~A~@[, now ending on line ~A~].~%~A~@[~%~A~]~%~%\
--- before ---~%~A~@[~%--- after ---~%~A~]"
          (gethash "line_start" report)
          (gethash "line_end" report)
          (gethash "line_end_after" report)
          (if (gethash "forms_verified_unchanged" report)
              "Every form in the file was compared against the original and came back unchanged."
              "Nothing changed, so there was no comparison to run.")
          (and (gethash "already_unreadable" report)
               (format nil "This file did not balance or read cleanly before ~
the edit either, so that check was skipped rather than charged to the edit."))
          (gethash "before" report)
          (let ((after (gethash "after" report)))
            (and (plusp (length after)) after))))

(defmethod tool-handle ((tool lisp-edit-comment-tool) id args)
  (let* ((session (tool-session tool))
         (root    (session-project-root session)))
    ;; Reject before any file access: every path below resolves against the root.
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError"    t
                            "error_type" "project-root-not-set"
                            "content"
                            (text-content "lisp-edit-comment: no project root set. \
Call fs-set-project-root first.")))))
    (let* ((file-path  (gethash "file_path" args))
           (mode       (gethash "mode" args))
           (operation  (gethash "operation" args))
           (substring  (gethash "substring" args))
           (line-start (gethash "line_start" args))
           (line-end   (gethash "line_end" args))
           (form-type  (gethash "form_type" args))
           (form-name  (gethash "form_name" args))
           (content    (gethash "content" args))
           (dry-run    (gethash "dry_run" args))
           (readtable  (gethash "readtable" args)))
      ;; Basic argument validation.
      (unless (%non-empty-string-p file-path)
        (return-from tool-handle
          (%invalid-argument id "lisp-edit-comment: file_path must be a non-empty string.")))
      (unless (and (stringp mode) (member mode '("region" "leading") :test #'string=))
        (return-from tool-handle
          (%invalid-argument
           id (format nil "lisp-edit-comment: mode must be one of region, leading (got ~A)."
                      mode))))
      (unless (and (stringp operation)
                   (member operation '("replace" "delete") :test #'string=))
        (return-from tool-handle
          (%invalid-argument
           id (format nil "lisp-edit-comment: operation must be one of replace, delete (got ~A)."
                      operation))))
      (when (string= mode "region")
        (unless (%non-empty-string-p substring)
          (return-from tool-handle
            (%invalid-argument
             id "lisp-edit-comment: region mode needs substring, a non-empty substring of the comment to edit."))))
      (when (string= mode "leading")
        (unless (and (%non-empty-string-p form-type) (%non-empty-string-p form-name))
          (return-from tool-handle
            (%invalid-argument
             id "lisp-edit-comment: leading mode needs form_type and form_name, both non-empty strings."))))
      (when (string= operation "replace")
        (unless (stringp content)
          (return-from tool-handle
            (%invalid-argument
             id "lisp-edit-comment: content is required for the replace operation."))))
      (log-event :info "lisp-edit-comment"
                 "file_path" file-path "mode" mode
                 "operation" operation "dry_run" dry-run)
      (handler-case
          (if dry-run
              ;; Dry-run: edit-comment returns a hash-table with original/preview.
              (let* ((preview-ht (edit-comment root file-path mode operation
                                               :substring substring
                                               :line-start line-start
                                               :line-end line-end
                                               :form-type form-type
                                               :form-name form-name
                                               :content content
                                               :dry-run t
                                               :readtable readtable))
                     (would-change (gethash "would_change" preview-ht))
                     (report       (gethash "changed_region" preview-ht))
                     (summary      (format nil "Dry-run ~A of a comment in ~A (~:[no change~;would change~]).~%~A"
                                           operation file-path would-change
                                           (%region-summary report))))
                (result id (make-ht "path"           file-path
                                    "mode"           mode
                                    "operation"      operation
                                    "would_change"   would-change
                                    "original"       (gethash "original" preview-ht)
                                    "preview"        (gethash "preview" preview-ht)
                                    "changed_region" report
                                    "content"        (text-content summary))))
              ;; Apply: edit-comment returns (values updated changed-p report).
              (multiple-value-bind (updated changed-p report)
                  (edit-comment root file-path mode operation
                                :substring substring
                                :line-start line-start
                                :line-end line-end
                                :form-type form-type
                                :form-name form-name
                                :content content
                                :dry-run nil
                                :readtable readtable)
                (let ((summary (if changed-p
                                   (format nil "Applied ~A to a comment in ~A.~%~A"
                                           operation file-path (%region-summary report))
                                   (format nil "No change to the comment in ~A (content matches what is already there)."
                                           file-path))))
                  (result id (make-ht "path"           file-path
                                      "mode"           mode
                                      "operation"      operation
                                      "would_change"   changed-p
                                      ;; A character count, which is what the
                                      ;; string holds. The file on disk is
                                      ;; longer whenever it carries anything
                                      ;; outside ASCII.
                                      "characters"     (length updated)
                                      "changed_region" report
                                      "content"        (text-content summary))))))
        (comment-operation-error (e)
          ;; An expected failure, told apart from an unexpected one by its own
          ;; error type. The file was not written.
          (result id (make-ht "isError"    t
                              "error_type" "comment-operation-error"
                              "content"    (text-content
                                            (format nil "lisp-edit-comment: ~A"
                                                    (comment-operation-reason e))))))
        (error (e)
          (result id (make-ht "isError"    t
                              "error_type" "edit-comment-error"
                              "content"    (text-content
                                            (format nil "lisp-edit-comment: ~A"
                                                    (princ-to-string e))))))))))
