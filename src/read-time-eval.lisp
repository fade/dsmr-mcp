;;;; src/read-time-eval.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Inert reading of read-time evaluation (#.) for source readers.
;;;;
;;;; A #. form reads as a READ-TIME-EVAL object holding the unevaluated
;;;; expression that followed it.  The readtables built here replace the #.
;;;; dispatch entry and leave *READ-EVAL* alone: callers keep it bound to NIL,
;;;; so a reader that lacks the inert entry refuses #. instead of evaluating it.

(defpackage #:dsmr-mcp/src/read-time-eval
  (:use #:cl)
  ;; Eclector symbols are referenced package-qualified throughout:
  ;; ECLECTOR.READTABLE:COPY-READTABLE would clash with CL:COPY-READTABLE.
  (:import-from #:eclector.reader)
  (:import-from #:eclector.readtable)
  (:export #:read-time-eval
           #:read-time-eval-p
           #:read-time-eval-expression
           #:make-read-time-eval
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

(defun %inert-sharpsign-dot (stream sub-char parameter)
  "CL reader #. entry: read the next object and return it unevaluated.
Return a READ-TIME-EVAL holding the object, or NIL when *READ-SUPPRESS* is true."
  (declare (ignore sub-char parameter))
  (let ((expression (read stream t nil t)))
    (if *read-suppress*
        nil
        (make-read-time-eval expression))))

(defun %inert-eclector-sharpsign-dot (stream sub-char parameter)
  "Eclector #. entry: read the next object and return it unevaluated.
Return a READ-TIME-EVAL holding the object, or NIL when the client state
reports *READ-SUPPRESS* as true."
  (declare (ignore sub-char parameter))
  (let ((expression (eclector.reader:read stream t nil t)))
    (if (eclector.reader:state-value eclector.reader:*client* '*read-suppress*)
        nil
        (make-read-time-eval expression))))

(defun inert-readtable (from)
  "Return a copy of readtable FROM whose #. entry reads without evaluating.
FROM is passed to COPY-READTABLE, so NIL means the standard readtable.
FROM is not modified.  *READ-EVAL* is neither bound nor set."
  (let ((readtable (copy-readtable from)))
    (set-dispatch-macro-character #\# #\. #'%inert-sharpsign-dot readtable)
    readtable))

(defun inert-eclector-readtable (&optional (from eclector.reader:*readtable*))
  "Return a copy of Eclector readtable FROM whose #. entry reads without evaluating.
FROM defaults to the current Eclector readtable and is not modified.
*READ-EVAL* is neither bound nor set."
  (let ((readtable (eclector.readtable:copy-readtable from)))
    (eclector.readtable:set-dispatch-macro-character
     readtable #\# #\. #'%inert-eclector-sharpsign-dot)
    readtable))
