;;;; src/lisp-patch-form.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Scoped text replacement within a matched top-level Lisp form.
;;;; Implements VERB-21 (D-08): exact-once old_text → new_text replacement
;;;; that fails hard and writes nothing when the patch would break form
;;;; structure. No parinfer repair — structural breaks are always errors here.
;;;;
;;;; Key contracts:
;;;;   - patch-operation-error signals expected failures (not found, multiple
;;;;     match, structural break). The file is NEVER written on these errors.
;;;;   - patch-form takes session-root as an explicit first parameter (D-03).
;;;;   - old_text must match exactly once (the exact-once invariant, D-08).
;;;;   - Dry-run returns original/preview without writing.
;;;;   - All writes go through ensure-write-path + write-file-string-atomically
;;;;     (D-13: current session root only).
;;;;
;;;; Fresh AGPL write adapting patterns from cl-mcp/src/lisp-patch-form.lisp (MIT).

(defpackage #:dsmr-mcp/src/lisp-patch-form
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/cst
                #:cst-node-start
                #:cst-node-end
                #:cst-node-value)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:import-from #:dsmr-mcp/src/project-root
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/lisp-edit-form-core
                #:%locate-target-form
                #:%normalize-paths
                #:%whitespace-char-p)
  (:import-from #:dsmr-mcp/src/package-context
                #:call-with-lenient-packages)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:patch-form
           #:patch-operation-error
           #:patch-operation-reason))

(in-package #:dsmr-mcp/src/lisp-patch-form)

;;;; -------------------------------------------------------------------------
;;;; patch-operation-error condition
;;;; -------------------------------------------------------------------------

(define-condition patch-operation-error (error)
  ((reason
    :initarg :reason
    :reader patch-operation-reason
    :documentation "Human-readable description of why the patch failed."))
  (:report (lambda (c s) (write-string (patch-operation-reason c) s)))
  (:documentation "Signalled for expected patch failures: old_text not found,
old_text matches multiple times (exact-once invariant), or the patched form
text fails to parse (structural break, D-08). The file is never written when
this condition is signalled."))

;;;; -------------------------------------------------------------------------
;;;; Scoped text replacement
;;;; -------------------------------------------------------------------------

(defun %apply-patch-operation (text node old-text new-text)
  "Replace OLD-TEXT with NEW-TEXT within the form at NODE in TEXT.
Returns two values: the modified full file text and the modified form text.

Signals PATCH-OPERATION-ERROR when OLD-TEXT:
  - is not found in the form (exact, whitespace-sensitive match), or
  - occurs more than once (the exact-once invariant, D-08)."
  (when (zerop (length old-text))
    (error 'patch-operation-error
           :reason "old_text must not be empty"))
  (let* ((start     (cst-node-start node))
         (end       (cst-node-end node))
         (form-text (subseq text start end))
         (match-pos (search old-text form-text)))
    (unless match-pos
      (let* ((form-value (cst-node-value node))
             (form-id    (if (consp form-value)
                             (format nil "~A ~A" (car form-value) (second form-value))
                             "matched")))
        (error 'patch-operation-error
               :reason (format nil "old_text not found in ~A form. ~
Matching is exact and whitespace-sensitive. ~
Use lisp-read-file with a name_pattern to inspect the exact form text. ~
old_text begins with: ~S~:[~;...~]"
                               form-id
                               (subseq old-text 0 (min (length old-text) 60))
                               (> (length old-text) 60)))))
    ;; Exact-once invariant: a second match is an error (D-08).
    (let ((second-match (search old-text form-text :start2 (1+ match-pos))))
      (when second-match
        ;; Count total occurrences for a helpful message.
        (let ((count (loop for pos = (search old-text form-text)
                                 then (search old-text form-text :start2 (1+ pos))
                           while pos
                           count 1)))
          (error 'patch-operation-error
                 :reason (format nil "old_text matches ~D times in the form; ~
provide more surrounding context to match exactly once"
                                 count)))))
    ;; Single match confirmed: apply the replacement.
    (let* ((modified-form
             (concatenate 'string
                          (subseq form-text 0 match-pos)
                          new-text
                          (subseq form-text (+ match-pos (length old-text)))))
           (modified-file
             (concatenate 'string
                          (subseq text 0 start)
                          modified-form
                          (subseq text end))))
      (values modified-file modified-form))))

;;;; -------------------------------------------------------------------------
;;;; Post-patch structural validation (fail-hard, no repair)
;;;; -------------------------------------------------------------------------

(defun %validate-form-parseable (form-text)
  "Validate that FORM-TEXT parses as a single complete Lisp form.
Does NOT attempt parinfer repair (D-08: fail hard, write nothing).
Signals PATCH-OPERATION-ERROR when the text does not parse correctly."
  (let ((*read-eval* nil)
        (*readtable* (copy-readtable nil)))
    (handler-case
        (call-with-lenient-packages
         (lambda ()
           (multiple-value-bind (form pos)
               (read-from-string form-text nil :eof)
             (when (eq form :eof)
               (error 'patch-operation-error
                      :reason "patch produced an empty form"))
             (let ((rest-start (or (position-if-not #'%whitespace-char-p
                                                    form-text :start pos)
                                   (length form-text))))
               (when (< rest-start (length form-text))
                 (error 'patch-operation-error
                        :reason "patch produced malformed form text (trailing content after the form)")))
             form-text)))
      (patch-operation-error (e)
        (error e))
      (error (e)
        (error 'patch-operation-error
               :reason (format nil "patch produced invalid Lisp: ~A. ~
The form could not be parsed after replacement. No changes were written to disk."
                               e))))))

;;;; -------------------------------------------------------------------------
;;;; Public API
;;;; -------------------------------------------------------------------------

(defun patch-form (session-root file-path form-type form-name old-text new-text
                   &key dry-run readtable)
  "Scoped exact-text replacement within the top-level form identified by
FORM-TYPE and FORM-NAME in FILE-PATH under SESSION-ROOT (D-03).

OLD-TEXT must match exactly once within the form (whitespace-sensitive, D-08).
If the patch would break form structure, signals PATCH-OPERATION-ERROR immediately
and writes nothing to disk (fail-hard, no parinfer repair).

When DRY-RUN is non-nil, returns a hash-table with original/preview without
writing. Otherwise writes atomically through the write jail (D-13).

Returns:
  On dry-run: a hash-table with would_change/original/preview/path/operation.
  On apply:   (values updated-text changed-p)"
  (multiple-value-bind (abs rel original nodes target target-snippet file-package-name)
      (handler-case
          (%locate-target-form file-path form-type form-name readtable session-root)
        (error (e)
          (error 'patch-operation-error :reason (format nil "~A" e))))
    (declare (ignore nodes file-package-name))
    (multiple-value-bind (updated modified-form)
        (%apply-patch-operation original target old-text new-text)
      (let ((would-change (not (string= original updated))))
        ;; Structural validation: only when the content actually changes.
        (when would-change
          (%validate-form-parseable modified-form))
        (log-event :debug "lisp.patch.form"
                   "path" (namestring abs)
                   "form_type" form-type "form_name" form-name
                   "dry_run" dry-run "would_change" would-change)
        (cond
          (dry-run
           (let ((ht (make-hash-table :test 'equal)))
             (setf (gethash "would_change" ht) would-change
                   (gethash "original"     ht) target-snippet
                   (gethash "preview"      ht) modified-form
                   (gethash "path"         ht) (namestring abs)
                   (gethash "operation"    ht) "patch")
             ht))
          (would-change
           (let ((abs-write (ensure-write-path rel session-root)))
             (unless abs-write
               (error "Write path ~A is outside the session root ~A" rel session-root))
             (write-file-string-atomically abs-write updated))
           (values updated t))
          (t
           (values updated nil)))))))
