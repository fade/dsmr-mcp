;;;; src/bus/inert-read.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The one Lisp reader for bus state files. Cursors, log generation counters,
;;;; heartbeats, roster entries, host records and broker identities sit under a
;;;; state root that every bus participant of the same user can write, so their
;;;; content is untrusted. READ-DATUM reads one datum with fixed reader
;;;; variables and read-time evaluation off, and refuses the dispatch syntax no
;;;; bus writer emits: #S, #=, ##, #A, #n( and #n*.
;;;;
;;;; CL only: the watcher binary loads this leaf and must not pull in a parser
;;;; library or a messaging library.

(defpackage #:dsmr-mcp/src/bus/inert-read
  (:use #:cl)
  (:export #:read-datum
           #:refused-syntax
           #:refused-syntax-character
           #:refused-syntax-reason))

(in-package #:dsmr-mcp/src/bus/inert-read)

(define-condition refused-syntax (reader-error)
  ((sub-char :initarg :sub-char :initform nil :reader refused-syntax-character
             :documentation "The # dispatch sub-character refused, upcased, or NIL
                             when the refusal names no syntax.")
   (reason :initarg :reason :initform nil :reader refused-syntax-reason
           :documentation "Why the input was refused, as text, when SUB-CHAR is NIL."))
  (:report
   (lambda (condition stream)
     (let ((source (stream-error-stream condition))
           (sub-char (refused-syntax-character condition)))
       (format stream "Refused a bus state file~@[ ~A~]: ~:[~A~;~:*#~A syntax, ~
                       which no bus writer emits~]. Check what wrote the file."
               (and (typep source 'file-stream)
                    (ignore-errors (namestring (pathname source))))
               sub-char
               (refused-syntax-reason condition)))))
  (:documentation
   "READER-ERROR signalled by READ-DATUM for input it refuses.
    #S runs an image-defined constructor and its slot initforms. #A runs an
    image-defined type expander. #n( , #n* and #A allocate from a count in the
    text. #= and ## build circular structure that makes a plist walk loop
    forever. Any other condition the reader signals, storage exhaustion
    included, arrives as this condition with SUB-CHAR NIL."))

(defun %refuse (stream sub-char arg)
  "Dispatch macro function: signal REFUSED-SYNTAX for SUB-CHAR on STREAM.
   Signals even while *READ-SUPPRESS* is true, so a skipped #+ or #- branch
   fails closed."
  (declare (ignore arg))
  (error 'refused-syntax :stream stream :sub-char (char-upcase sub-char)))

(defun %refuse-counted (stream sub-char arg)
  "Dispatch macro function for #( and #*: signal REFUSED-SYNTAX when ARG, the
   count, is present, since the standard reader allocates from it before
   reading any content. Without a count, read as the standard readtable does."
  (if arg
      (%refuse stream sub-char arg)
      (funcall (get-dispatch-macro-character #\# sub-char nil) stream sub-char arg)))

(defun %make-refusing-readtable ()
  "A copy of the standard readtable that refuses #S, #=, ##, #A, #n( and #n*.
   The entries hold function names, not function objects, so a redefinition of
   %REFUSE or %REFUSE-COUNTED reaches the table. The standard readtable itself
   is never modified."
  (let ((table (copy-readtable nil)))
    (dolist (sub-char '(#\S #\= #\# #\A))
      (set-dispatch-macro-character #\# sub-char '%refuse table))
    (dolist (sub-char '(#\( #\*) table)
      (set-dispatch-macro-character #\# sub-char '%refuse-counted table))))

(defparameter *refusing-readtable* (%make-refusing-readtable)
  "Readtable READ-DATUM reads under. Rebuilt on every load, so reloading this
   file applies a changed refused set; never mutated otherwise.")

(defun read-datum (stream &optional eof-value)
  "Read one datum from STREAM and return it, or EOF-VALUE at end of file.

   Binds the reader variables to fixed values, independent of the caller:
   *READ-EVAL* NIL, *READ-BASE* 10, *READ-DEFAULT-FLOAT-FORMAT* SINGLE-FLOAT,
   *READ-SUPPRESS* NIL, *PACKAGE* CL-USER, and *READTABLE* the refusing copy of
   the standard readtable. Printer variables are left as the caller has them.

   Signals only these conditions, each an ERROR:
   - READER-ERROR for malformed syntax and for #.;
   - REFUSED-SYNTAX, a READER-ERROR, for #S, #=, ##, #A, #n( and #n*, and for
     any other condition the reader signals, storage exhaustion included;
   - END-OF-FILE for a form cut off by end of file."
  (let ((*readtable* *refusing-readtable*)
        (*read-eval* nil)
        (*read-base* 10)
        (*read-default-float-format* 'single-float)
        (*read-suppress* nil)
        (*package* (find-package "CL-USER")))
    (handler-case (read stream nil eof-value)
      (serious-condition (c)
        (if (typep c '(or reader-error end-of-file))
            (error c)
            (error 'refused-syntax
                   :stream stream
                   :reason (format nil "the reader signalled ~S" (type-of c))))))))
