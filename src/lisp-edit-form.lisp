;;;; src/lisp-edit-form.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Structure-aware editing of top-level Lisp forms.
;;;; Implements VERB-20 (D-07): CST-driven replace/insert/delete with
;;;; parinfer auto-repair on missing closes, dry-run preview, and comment/
;;;; indentation preservation.
;;;;
;;;; Key contracts:
;;;;   - validate-and-repair-content returns (values content parinfer-warning-or-nil)
;;;;   - edit-form takes session-root as an explicit first parameter (D-03).
;;;;   - Dry-run preview is computed by the SAME %apply-operation path as the
;;;;     real apply, so the preview is always faithful (D-07).
;;;;   - All writes go through ensure-write-path + write-file-string-atomically
;;;;     (D-13: current session root only).
;;;;
;;;; Fresh AGPL write adapting patterns from cl-mcp/src/lisp-edit-form.lisp (MIT).

(defpackage #:dsmr-mcp/src/lisp-edit-form
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/cst
                #:cst-node-start
                #:cst-node-end)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:import-from #:dsmr-mcp/src/project-root
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/parinfer
                #:apply-indent-mode)
  (:import-from #:dsmr-mcp/src/lisp-edit-form-core
                #:%locate-target-form
                #:%normalize-paths
                #:%whitespace-char-p)
  (:import-from #:dsmr-mcp/src/package-context
                #:call-with-lenient-packages)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/lsp/client
                #:find-lsp-client
                #:bump-uri-version)
  (:import-from #:dsmr-mcp/src/lsp/document
                #:notify-did-change)
  (:export #:edit-form
           #:validate-and-repair-content))

(in-package #:dsmr-mcp/src/lisp-edit-form)

;;;; -------------------------------------------------------------------------
;;;; Content validation and parinfer repair
;;;; -------------------------------------------------------------------------

(defun %ensure-trailing-newline (text)
  "Return TEXT, ensuring it ends with a newline character."
  (if (and (plusp (length text))
           (char= (char text (1- (length text))) #\Newline))
      text
      (concatenate 'string text (string #\Newline))))

(defun %trim-outer-whitespace (text)
  "Trim leading and trailing whitespace from TEXT."
  (string-trim '(#\Space #\Tab #\Newline #\Return) text))

(defun %split-leading-whitespace (text)
  "Return (values leading-ws rest-text) splitting TEXT at the first non-whitespace."
  (let ((ws-end (or (position-if-not #'%whitespace-char-p text)
                    (length text))))
    (values (subseq text 0 ws-end)
            (subseq text ws-end))))

(defun %split-trailing-whitespace (text)
  "Return (values text-without-trailing trailing-ws) splitting TEXT."
  (let ((last-non-ws (position-if-not #'%whitespace-char-p text :from-end t)))
    (if last-non-ws
        (values (subseq text 0 (1+ last-non-ws))
                (subseq text (1+ last-non-ws)))
        (values "" text))))

(defun %normalized-separator (left-text right-text)
  "Return the separator to insert between LEFT-TEXT and RIGHT-TEXT.
No separator before the first form; one blank line between forms; newline at EOF."
  (cond
    ((zerop (length left-text)) "")
    ((zerop (length right-text)) (string #\Newline))
    (t (format nil "~%~%"))))

(defun %ensure-blank-separation (prefix between)
  "Extend BETWEEN so that PREFIX+BETWEEN ends with at least two newlines.
Keeps existing whitespace and adds only the minimal needed newlines."
  (flet ((trailing-newlines (str)
           (loop for i downfrom (1- (length str)) to 0
                 while (char= (char str i) #\Newline)
                 count 1)))
    (let* ((combined (concatenate 'string prefix between))
           (missing (max 0 (- 2 (trailing-newlines combined)))))
      (if (zerop missing)
          between
          (concatenate 'string between
                       (make-string missing :initial-element #\Newline))))))

(defun %comment-only-p (text)
  "Return T when TEXT contains only comments/whitespace and no readable forms.
Allows replace to delete a form by replacing it with a '; removed' comment."
  (and (stringp text)
       (some (lambda (ch) (not (%whitespace-char-p ch))) text)
       (handler-case
           (multiple-value-bind (form pos)
               (read-from-string text nil :eof)
             (declare (ignore pos))
             (eq form :eof))
         (error () nil))
       (or (find #\; text)
           (search "#|" text))))

(defun %try-parse-content (text)
  "Try to read TEXT as a single top-level form under lenient package handling.
Returns TEXT on success, or (values nil error) on failure."
  (let ((*read-eval* nil)
        (*readtable* (copy-readtable nil)))
    (handler-case
        (call-with-lenient-packages
         (lambda ()
           (multiple-value-bind (form pos)
               (read-from-string text nil :eof)
             (when (eq form :eof)
               (if (%comment-only-p text)
                   (return-from %try-parse-content text)
                   (error "content is empty")))
             ;; Check for trailing content after the first form.
             (let* ((len (length text))
                    (rest-start (or (position-if-not #'%whitespace-char-p
                                                     text :start pos)
                                    len)))
               (when (< rest-start len)
                 ;; Multiple forms: try reading the rest to confirm.
                 (handler-case
                     (multiple-value-bind (form2 ignored)
                         (read-from-string text nil :eof :start rest-start :end len)
                       (declare (ignore ignored))
                       (unless (eq form2 :eof)
                         (error "content must contain exactly one top-level form")))
                   (end-of-file () nil)
                   (reader-error () nil))))
             text)))
      (error (e)
        (values nil e)))))

(defun validate-and-repair-content (content &optional package-name source-path)
  "Ensure CONTENT is a single valid top-level form.

If it parses cleanly, return (values content nil).
If it fails due to missing closing parens, attempt repair via apply-indent-mode
and return (values repaired-content parinfer-warning-string) when repair succeeds.
Signals an error when both the original and the repaired content fail to parse.

Comment-only content (no readable form, has ';' or '#|') is accepted verbatim
with a nil second value.

D-07: The parinfer-warning second value is surfaced to the MCP client as
a 'parinfer_warning' field in the result, so the agent sees what was auto-repaired."
  (declare (ignore package-name source-path))
  (when (%comment-only-p content)
    (return-from validate-and-repair-content (values content nil)))
  (multiple-value-bind (result err)
      (%try-parse-content content)
    (if result
        (values result nil)
        ;; Attempt parinfer repair.
        (let ((repaired (apply-indent-mode content)))
          (multiple-value-bind (repaired-result repaired-err)
              (%try-parse-content repaired)
            (cond
              (repaired-result
               (log-event :info "lisp.edit.form" "auto-repair" "success"
                          "original-error" (princ-to-string err))
               (let ((added-count (- (length repaired) (length content))))
                 (values repaired-result
                         (format nil "~D closing delimiter~:P ~
~[were~;was~:;were~] added by parinfer"
                                 added-count added-count))))
              (t
               (error "content parse error: ~A (repair also failed: ~A)"
                      err repaired-err))))))))

;;;; -------------------------------------------------------------------------
;;;; Operation application
;;;; -------------------------------------------------------------------------

(defun %apply-operation-preserve-spacing (text node operation content)
  "Apply OPERATION using minimal splice preserving surrounding whitespace/comments."
  (let ((start (cst-node-start node))
        (end   (cst-node-end node)))
    (ecase operation
      ((:replace)
       (concatenate 'string (subseq text 0 start) content (subseq text end)))
      ((:insert-before)
       (let* ((snippet (%ensure-trailing-newline content))
              (prefix  (subseq text 0 start))
              (sep     (if (zerop start)
                           ""
                           (%ensure-blank-separation prefix ""))))
         (concatenate 'string prefix sep snippet (subseq text start))))
      ((:insert-after)
       (let* ((snippet  (%ensure-trailing-newline content))
              (suffix   (subseq text end))
              (ws-end   (or (position-if-not
                             (lambda (ch) (member ch '(#\Space #\Tab #\Newline #\Return)))
                             suffix)
                            (length suffix)))
              (between  (%ensure-blank-separation (subseq text 0 end)
                                                  (subseq suffix 0 ws-end)))
              (rest     (subseq suffix ws-end))
              (prefix   (subseq text 0 end)))
         (concatenate 'string prefix between snippet rest)))
      ((:delete)
       (let* ((suffix (subseq text end))
              (ws-end (or (position-if-not
                           (lambda (ch) (member ch '(#\Space #\Tab #\Newline #\Return)))
                           suffix)
                          (length suffix))))
         (concatenate 'string (subseq text 0 start)
                      (subseq suffix ws-end)))))))

(defun %apply-operation-normalized (text node operation content)
  "Apply OPERATION normalizing blank lines between top-level forms."
  (let ((start (cst-node-start node))
        (end   (cst-node-end node)))
    (ecase operation
      ((:replace)
       (let ((snippet (%trim-outer-whitespace content)))
         (multiple-value-bind (prefix-core ignored1)
             (%split-trailing-whitespace (subseq text 0 start))
           (declare (ignore ignored1))
           (multiple-value-bind (ignored2 suffix-core)
               (%split-leading-whitespace (subseq text end))
             (declare (ignore ignored2))
             (concatenate 'string prefix-core
                          (%normalized-separator prefix-core snippet) snippet
                          (%normalized-separator snippet suffix-core)
                          suffix-core)))))
      ((:insert-before)
       (let ((snippet (%trim-outer-whitespace content)))
         (multiple-value-bind (prefix-core ignored)
             (%split-trailing-whitespace (subseq text 0 start))
           (declare (ignore ignored))
           (let ((target (subseq text start end))
                 (suffix (subseq text end)))
             (concatenate 'string prefix-core
                          (%normalized-separator prefix-core snippet) snippet
                          (%normalized-separator snippet target) target
                          suffix)))))
      ((:insert-after)
       (let ((snippet (%trim-outer-whitespace content)))
         (multiple-value-bind (ignored suffix-core)
             (%split-leading-whitespace (subseq text end))
           (declare (ignore ignored))
           (let ((prefix (subseq text 0 end)))
             (concatenate 'string prefix (%normalized-separator prefix snippet)
                          snippet (%normalized-separator snippet suffix-core)
                          suffix-core)))))
      ((:delete)
       (multiple-value-bind (prefix-core ignored1)
           (%split-trailing-whitespace (subseq text 0 start))
         (declare (ignore ignored1))
         (multiple-value-bind (ignored2 suffix-core)
             (%split-leading-whitespace (subseq text end))
           (declare (ignore ignored2))
           (cond
             ((and (zerop (length prefix-core)) (zerop (length suffix-core)))
              "")
             ((zerop (length prefix-core))
              suffix-core)
             ((zerop (length suffix-core))
              (concatenate 'string prefix-core (string #\Newline)))
             (t
              (concatenate 'string prefix-core
                           (%normalized-separator prefix-core suffix-core)
                           suffix-core)))))))))

(defun %apply-operation (text node operation content normalize-blank-lines)
  "Apply OPERATION to NODE within TEXT.
When NORMALIZE-BLANK-LINES is non-nil, blank lines around top-level forms are
normalized; otherwise surrounding whitespace and comments are preserved."
  (if normalize-blank-lines
      (%apply-operation-normalized text node operation content)
      (%apply-operation-preserve-spacing text node operation content)))

;;;; -------------------------------------------------------------------------
;;;; Public API
;;;; -------------------------------------------------------------------------

(defun edit-form (session-root file-path form-type form-name operation content
                  &key dry-run (normalize-blank-lines t) readtable)
  "Structure-aware edit of the top-level form identified by FORM-TYPE and FORM-NAME
in FILE-PATH under SESSION-ROOT (D-03).

OPERATION is one of :replace, :insert-before, :insert-after, :delete (or their
underscore-separated string equivalents).
CONTENT is the replacement form text (required for non-delete operations).
When DRY-RUN is non-nil, returns a result hash-table with original/preview
without writing; otherwise writes atomically through the write jail (D-13).

After a successful write, fires a fire-and-forget textDocument/didChange
notification to the project's alive-lsp instance when one is registered (D-10).
Notification failures never propagate to the caller.

Returns:
  On dry-run: a hash-table with would_change/original/preview/path/operation
              and optionally parinfer_warning.
  On apply:   (values updated-text parinfer-warning-or-nil changed-p)"
  (let* ((op-str (string-downcase (if (symbolp operation)
                                      (symbol-name operation)
                                      operation)))
         (op-key
           (cond ((string= op-str "replace")        :replace)
                 ((string= op-str "insert-before")  :insert-before)
                 ((string= op-str "insert-after")   :insert-after)
                 ((string= op-str "insert_before")  :insert-before)
                 ((string= op-str "insert_after")   :insert-after)
                 ((string= op-str "delete")         :delete)
                 (t (error "Unsupported operation: ~A" operation)))))
    (unless (or (eq op-key :delete) (stringp content))
      (error "content is required for ~A operation" operation))
    (multiple-value-bind (abs rel original nodes target target-snippet file-package-name)
        (%locate-target-form file-path form-type form-name readtable session-root)
      (declare (ignore nodes file-package-name))
      (if (eq op-key :delete)
          ;; Delete: no content validation.
          (let* ((updated (%apply-operation original target op-key nil normalize-blank-lines))
                 (would-change (not (string= original updated))))
            (log-event :debug "lisp.edit.form"
                       "path" (namestring abs) "operation" "delete"
                       "form_type" form-type "form_name" form-name
                       "dry_run" dry-run "would_change" would-change)
            (cond
              (dry-run
               (let ((ht (make-hash-table :test 'equal)))
                 (setf (gethash "would_change" ht) would-change
                       (gethash "original"     ht) target-snippet
                       (gethash "preview"      ht) updated
                       (gethash "path"         ht) (namestring abs)
                       (gethash "operation"    ht) "delete")
                 ht))
              (would-change
               (let ((abs-write (ensure-write-path rel session-root)))
                 (unless abs-write
                   (error "Write path ~A is outside the session root ~A" rel session-root))
                 (write-file-string-atomically abs-write updated)
                 ;; D-10: fire-and-forget didChange after the successful write.
                 (ignore-errors
                   (let ((lsp-client (find-lsp-client session-root)))
                     (when lsp-client
                       (notify-did-change
                        lsp-client abs-write updated
                        (bump-uri-version lsp-client (namestring abs-write)))))))
               (values updated nil t))
              (t (values updated nil nil))))
          ;; Non-delete: validate and repair content.
          (multiple-value-bind (validated-content parinfer-warning)
              (validate-and-repair-content content)
            (let* ((updated (%apply-operation original target op-key
                                              validated-content normalize-blank-lines))
                   (would-change (not (string= original updated))))
              (log-event :debug "lisp.edit.form"
                         "path" (namestring abs) "operation" op-str
                         "form_type" form-type "form_name" form-name
                         "dry_run" dry-run "would_change" would-change)
              (cond
                (dry-run
                 (let ((ht (make-hash-table :test 'equal)))
                   (setf (gethash "would_change" ht) would-change
                         (gethash "original"     ht) target-snippet
                         (gethash "preview"      ht) updated
                         (gethash "path"         ht) (namestring abs)
                         (gethash "operation"    ht) op-str)
                   (when parinfer-warning
                     (setf (gethash "parinfer_warning" ht) parinfer-warning))
                   ht))
                (would-change
                 (let ((abs-write (ensure-write-path rel session-root)))
                   (unless abs-write
                     (error "Write path ~A is outside the session root ~A" rel session-root))
                   (write-file-string-atomically abs-write updated)
                   ;; D-10: fire-and-forget didChange after the successful write.
                   (ignore-errors
                     (let ((lsp-client (find-lsp-client session-root)))
                       (when lsp-client
                         (notify-did-change
                          lsp-client abs-write updated
                          (bump-uri-version lsp-client (namestring abs-write)))))))
                 (values updated parinfer-warning t))
                (t (values updated parinfer-warning nil)))))))))
