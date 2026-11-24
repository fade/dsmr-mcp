;;;; src/bus/inert-read.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The one Lisp reader for bus state files. Cursors, log generation counters,
;;;; heartbeats, roster entries, host records and broker identities sit under a
;;;; state root that every bus participant of the same user can write, so their
;;;; content is untrusted. READ-DATUM reads one datum under standard syntax with
;;;; read-time evaluation off, and refuses the dispatch syntax no bus writer
;;;; emits: #S, #= and ##.
;;;;
;;;; CL only: the watcher binary loads this leaf and must not pull in a parser
;;;; library or a messaging library.

(defpackage #:dsmr-mcp/src/bus/inert-read
  (:use #:cl)
  (:export #:read-datum
           #:refused-syntax
           #:refused-syntax-character))

(in-package #:dsmr-mcp/src/bus/inert-read)

(define-condition refused-syntax (reader-error)
  ((sub-char :initarg :sub-char :reader refused-syntax-character
             :documentation "The # dispatch sub-character that was refused."))
  (:report
   (lambda (condition stream)
     (let ((source (stream-error-stream condition)))
       (format stream "Refused #~A syntax in a bus state file~@[ ~A~]: no bus ~
                       writer emits it. Check what wrote the file."
               (refused-syntax-character condition)
               (and (typep source 'file-stream)
                    (ignore-errors (namestring (pathname source))))))))
  (:documentation
   "READER-ERROR signalled by READ-DATUM for #S, #= or ##.
    #S runs an image-defined constructor and its slot initforms; #= and ##
    build circular structure that makes a plist walk loop forever."))

(defun %refuse (stream sub-char arg)
  "Dispatch macro function: signal REFUSED-SYNTAX for SUB-CHAR on STREAM.
   Signals even while *READ-SUPPRESS* is true, so a skipped #+ or #- branch
   fails closed."
  (declare (ignore arg))
  (error 'refused-syntax :stream stream :sub-char sub-char))

(defun %make-refusing-readtable ()
  "A copy of the standard readtable with #S, #= and ## set to signal
   REFUSED-SYNTAX. The standard readtable itself is never modified."
  (let ((table (copy-readtable nil)))
    (dolist (sub-char '(#\S #\= #\#) table)
      (set-dispatch-macro-character #\# sub-char #'%refuse table))))

(defvar *refusing-readtable* (%make-refusing-readtable)
  "Readtable READ-DATUM reads under. Built once at load; never mutated.")

(defun read-datum (stream &optional eof-value)
  "Read one datum from STREAM under standard syntax and return it, or EOF-VALUE
   at end of file.

   Binds the reader variables to their standard values, independent of the
   caller: *READ-EVAL* NIL, *READ-BASE* 10, *READ-DEFAULT-FLOAT-FORMAT*
   SINGLE-FLOAT, *READ-SUPPRESS* NIL, *PACKAGE* CL-USER, and *READTABLE* the
   refusing copy of the standard readtable. Printer variables are left as the
   caller has them.

   Signals READER-ERROR for #. and REFUSED-SYNTAX (a READER-ERROR) for #S, #=
   and ##. Signals END-OF-FILE for a form cut off by end of file."
  (let ((*readtable* *refusing-readtable*)
        (*read-eval* nil)
        (*read-base* 10)
        (*read-default-float-format* 'single-float)
        (*read-suppress* nil)
        (*package* (find-package "CL-USER")))
    (read stream nil eof-value)))
