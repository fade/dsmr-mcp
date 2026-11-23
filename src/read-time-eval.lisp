;;;; src/read-time-eval.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Inert reading of read-time evaluation (#.) for source readers.
;;;;
;;;; A #. form reads as a READ-TIME-EVAL object holding the unevaluated
;;;; expression that followed it.  The readtables built here replace the #.
;;;; dispatch entry and leave *READ-EVAL* alone: callers keep it bound to NIL,
;;;; so a reader that lacks the inert entry refuses #. instead of evaluating it.
;;;;
;;;; A feature expression holding #. (#+#.(...) and #-#.(...)) cannot be
;;;; decided without evaluation.  The form it guards reads as present, for #+
;;;; and #- alike, so the form stays locatable and editable.

(defpackage #:dsmr-mcp/src/read-time-eval
  (:use #:cl)
  ;; Eclector symbols are referenced package-qualified throughout:
  ;; ECLECTOR.READTABLE:COPY-READTABLE would clash with CL:COPY-READTABLE.
  (:import-from #:eclector.base)
  (:import-from #:eclector.reader)
  (:import-from #:eclector.readtable)
  (:export #:read-time-eval
           #:read-time-eval-p
           #:read-time-eval-expression
           #:make-read-time-eval
           #:holds-read-time-eval-p
           #:inert-feature-client
           #:inert-readtable
           #:inert-eclector-readtable))

(in-package #:dsmr-mcp/src/read-time-eval)

(defstruct (read-time-eval
            (:constructor make-read-time-eval (expression)))
  "The value a #. form reads as.
EXPRESSION is the object that followed #. in the source, unevaluated."
  (expression nil :read-only t))

(defmethod print-object ((object read-time-eval) stream)
  "Write OBJECT as #. followed by its expression, under the current printer settings."
  (write-string "#." stream)
  (write (read-time-eval-expression object) :stream stream)
  object)

(defun holds-read-time-eval-p (object)
  "Return true when OBJECT is a READ-TIME-EVAL or a cons tree holding one.
Each cons is visited once, so shared and circular structure terminates."
  (let ((seen (make-hash-table :test #'eq)))
    (labels ((walk (x)
               (cond ((read-time-eval-p x) t)
                     ((and (consp x) (not (gethash x seen)))
                      (setf (gethash x seen) t)
                      (or (walk (car x)) (walk (cdr x)))))))
      (walk object))))

(defun %featurep (feature-expression)
  "Return true when FEATURE-EXPRESSION is satisfied by *FEATURES*."
  #+sbcl (sb-int:featurep feature-expression)
  #-sbcl (uiop:featurep feature-expression))

(defun %inert-sharpsign-feature (stream sub-char parameter)
  "CL reader #+ and #- entry.
Decide an ordinary feature expression as the standard entry does.  A feature
expression holding a READ-TIME-EVAL cannot be decided without evaluating it,
so the form after it reads as present, for #+ and #- alike: it stays
locatable and editable, and its text is left as written."
  (when parameter
    (warn "A numeric argument was ignored in #~W~A." parameter sub-char))
  (let ((feature-expression (let ((*package* (find-package "KEYWORD"))
                                  #+sbcl (sb-impl::*reader-package* nil)
                                  (*read-suppress* nil))
                              (read stream t nil t))))
    (if (or (holds-read-time-eval-p feature-expression)
            (eq (not (%featurep feature-expression)) (char= sub-char #\-)))
        (read stream t nil t)
        (let ((*read-suppress* t))
          (read stream t nil t)
          (values)))))

(defun %inert-sharpsign-dot (stream sub-char parameter)
  "CL reader #. entry: read the next object and return it unevaluated.
Return a READ-TIME-EVAL holding the object, or NIL when *READ-SUPPRESS* is true.
A numeric argument is ignored without a warning.  On SBCL, any comma in the
object that no backquote inside the object encloses signals a reader error,
as in SBCL's own entry."
  (declare (ignore sub-char parameter))
  (let ((expression (let (#+sbcl (sb-impl::*backquote-depth* 0))
                      (read stream t nil t))))
    (if *read-suppress*
        nil
        (make-read-time-eval expression))))

(defun %read-eclector-sharpsign-dot-object (client stream)
  "Read the object after #. from STREAM for CLIENT, as Eclector's #. entry reads it.
Quasiquotation is forbidden inside the object, and the enclosing list reader
is hidden from it.  End of input signals END-OF-INPUT-AFTER-SHARPSIGN-DOT, and
a closing parenthesis signals OBJECT-MUST-FOLLOW-SHARPSIGN-DOT; both are
reader errors.  Uses Eclector internals, matching its sharpsign-dot."
  (eclector.reader::with-quasiquotation-state (client nil nil nil)
    (let ((eclector.reader::*list-reader* nil))
      (handler-case (eclector.reader:read stream t nil t)
        ((and eclector.base:end-of-file
              (not eclector.base:incomplete-construct))
            (condition)
          (eclector.base:%recoverable-reader-error
           stream 'eclector.reader:end-of-input-after-sharpsign-dot
           :stream-position (eclector.base:stream-position condition)
           :report 'eclector.reader::inject-nil)
          nil)
        (eclector.reader::end-of-list (condition)
          (eclector.base:%recoverable-reader-error
           stream 'eclector.reader:object-must-follow-sharpsign-dot
           :position-offset -1 :report 'eclector.reader::inject-nil)
          (unread-char (eclector.reader::%character condition) stream)
          nil)))))

(defun %inert-eclector-sharpsign-dot (stream sub-char parameter)
  "Eclector #. entry: read the next object and return it unevaluated.
Return a READ-TIME-EVAL holding the object, or NIL when the client state
reports *READ-SUPPRESS* as true.  A numeric argument is ignored and the
parse continues, as when SBCL loads the file.  End of input, or a closing
parenthesis in place of the object, signals a reader error."
  (declare (ignore sub-char parameter))
  (let* ((client eclector.reader:*client*)
         (suppress (eclector.reader:state-value client '*read-suppress*)))
    (if suppress
        (progn (eclector.reader:read stream t nil t) nil)
        (make-read-time-eval (%read-eclector-sharpsign-dot-object client stream)))))

(defvar *feature-sub-char* #\+
  "Sub-character of the Eclector #+ or #- entry whose feature expression is being decided.")

(defun %eclector-feature-entry (entry)
  "Return an Eclector #+ or #- entry that calls ENTRY with *FEATURE-SUB-CHAR* bound."
  (lambda (stream sub-char parameter)
    (let ((*feature-sub-char* sub-char))
      (funcall entry stream sub-char parameter))))

(defclass inert-feature-client ()
  ()
  (:documentation "Eclector client mixin for the inert readtable.
A feature expression holding a READ-TIME-EVAL cannot be decided without
evaluating it, so the form after it reads as present, for #+ and #- alike:
it stays locatable and editable, and its text is left as written."))

(defmethod eclector.reader:evaluate-feature-expression :around
    ((client inert-feature-client) feature-expression)
  "Return the value that reads the guarded form when FEATURE-EXPRESSION holds a
READ-TIME-EVAL: true under #+, false under #-.  Otherwise decide as usual."
  (if (holds-read-time-eval-p feature-expression)
      (char= *feature-sub-char* #\+)
      (call-next-method)))

(defun inert-readtable (from)
  "Return a copy of readtable FROM whose #. entry reads without evaluating.
Where FROM keeps the standard #+ or #- entry, the copy's entry reads a form
guarded by a feature expression holding #. as present.
FROM is passed to COPY-READTABLE, so NIL means the standard readtable.
FROM is not modified.  *READ-EVAL* is neither bound nor set."
  (let ((readtable (copy-readtable from))
        (standard (copy-readtable nil)))
    (set-dispatch-macro-character #\# #\. #'%inert-sharpsign-dot readtable)
    (dolist (sub-char '(#\+ #\-))
      (when (eq (get-dispatch-macro-character #\# sub-char readtable)
                (get-dispatch-macro-character #\# sub-char standard))
        (set-dispatch-macro-character #\# sub-char #'%inert-sharpsign-feature
                                      readtable)))
    readtable))

(defun inert-eclector-readtable (&optional (from eclector.reader:*readtable*))
  "Return a copy of Eclector readtable FROM whose #. entry reads without evaluating.
The copy's #+ and #- entries bind *FEATURE-SUB-CHAR* around FROM's entries,
for a client that is an INERT-FEATURE-CLIENT.
FROM defaults to the current Eclector readtable and is not modified.
*READ-EVAL* is neither bound nor set."
  (let ((readtable (eclector.readtable:copy-readtable from)))
    (eclector.readtable:set-dispatch-macro-character
     readtable #\# #\. #'%inert-eclector-sharpsign-dot)
    (dolist (sub-char '(#\+ #\-))
      (let ((entry (eclector.readtable:get-dispatch-macro-character
                    readtable #\# sub-char)))
        (when entry
          (eclector.readtable:set-dispatch-macro-character
           readtable #\# sub-char (%eclector-feature-entry entry)))))
    readtable))
