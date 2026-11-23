;;;; tests/read-time-eval-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Regression tests for source files that use read-time evaluation (#.).
;;;; A #. form reads as an inert value; nothing in a file or in replacement
;;;; text is evaluated, and text outside an edited form is preserved.
;;;;
;;;; Fixture: tests/fixtures/read-time-eval/conditions.lisp.sample is a byte
;;;; copy of lines 1-8 and 73-166 of src/conditions.lisp from the boomer TLS
;;;; library, at commit 844634b2ff85f2707f4ea31e0cbb2d44130a9533.  That file is
;;;; MIT licensed, Copyright (C) 2026 Anthony Green; its licence header is kept
;;;; in the excerpt.  The excerpt holds five top-level forms and 54 occurrences
;;;; of #.; the .sample suffix keeps it out of *.lisp scans.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/read-time-eval-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/read-time-eval-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/cst
                #:parse-top-level-forms
                #:cst-node-kind
                #:cst-node-value
                #:cst-node-start
                #:cst-node-end)
  (:import-from #:dsmr-mcp/src/read-time-eval
                #:read-time-eval-p
                #:read-time-eval-expression
                #:inert-readtable)
  (:import-from #:dsmr-mcp/src/lisp-edit-form
                #:edit-form)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/read-time-eval-test)

;;;; -------------------------------------------------------------------------
;;;; Helpers
;;;; -------------------------------------------------------------------------

(defvar *read-time-evaluated* nil
  "Set to T by the probe form when its #. expression is evaluated.")

(defparameter +probe+
  "#.(setf dsmr-mcp/tests/read-time-eval-test::*read-time-evaluated* t)"
  "Synthetic #. form that sets *READ-TIME-EVALUATED* when evaluated.")

(defun fixture-text ()
  "Return the recorded fixture as a string."
  (uiop:read-file-string
   (asdf:system-relative-pathname
    "dsmr-mcp" "tests/fixtures/read-time-eval/conditions.lisp.sample")))

(defun probe-form-text ()
  "Return a synthetic top-level form holding the probe."
  (format nil "(defparameter *probe* ~A)" +probe+))

(defun write-conditions (root text)
  "Write TEXT under ROOT as src/conditions.lisp; return its absolute pathname."
  (write-fixture-file root "src/conditions.lisp" text))

(defun count-read-time-evals (text)
  "Return the number of occurrences of #. in TEXT."
  (loop with count = 0
        for pos = (search "#." text) then (search "#." text :start2 (+ pos 2))
        while pos
        do (incf count)
        finally (return count)))

(defun form-node (text form-type form-name)
  "Return the :EXPR node of TEXT whose head is FORM-TYPE and whose name is FORM-NAME."
  (find-if (lambda (node)
             (let ((value (cst-node-value node)))
               (and (eq (cst-node-kind node) :expr)
                    (consp value)
                    (symbolp (first value))
                    (string-equal (symbol-name (first value)) form-type)
                    (consp (rest value))
                    (symbolp (second value))
                    (string-equal (symbol-name (second value)) form-name))))
           (parse-top-level-forms text :source-path #p"conditions.lisp")))

(defun form-text (text node)
  "Return the source text of NODE within TEXT."
  (subseq text (cst-node-start node) (cst-node-end node)))

(defun replace-once (string old new)
  "Return STRING with its single occurrence of OLD replaced by NEW."
  (let ((pos (search old string)))
    (assert pos () "~S not found" old)
    (concatenate 'string (subseq string 0 pos) new (subseq string (+ pos (length old))))))

(defun check-splice (original written node replacement)
  "Assert WRITTEN is ORIGINAL with NODE's span replaced by REPLACEMENT."
  (let ((start (cst-node-start node))
        (end (cst-node-end node)))
    (true (string= (subseq original 0 start) (subseq written 0 start)))
    (true (string= replacement
                   (subseq written start (min (length written)
                                              (+ start (length replacement))))))
    (true (string= (subseq original end)
                   (subseq written (+ start (length replacement)))))))

(defun replace-form (root pn form-type form-name content &rest keys)
  "Run edit-form replace on PN under ROOT; return the file text afterwards."
  (apply #'edit-form (namestring root) (namestring pn)
         form-type form-name "replace" content keys)
  (uiop:read-file-string pn))

;;;; -------------------------------------------------------------------------
;;;; Parsing and editing beside #. forms
;;;; -------------------------------------------------------------------------

(define-test fixture-parses-whole
  "The recorded file reads as five forms with nothing left unparsed."
  (multiple-value-bind (nodes unparsed-from)
      (parse-top-level-forms (fixture-text) :source-path #p"conditions.lisp")
    (is = 5 (count :expr nodes :key #'cst-node-kind))
    (false unparsed-from)))

(define-test replace-a-form-beside-read-time-evals
  "Replacing the form before the first #. form leaves every other byte as it was."
  (with-temp-project-root (session root)
    (let* ((original (fixture-text))
           (pn (write-conditions root original))
           (node (form-node original "define-condition" "tls-alert-error"))
           (replacement (replace-once (form-text original node)
                                      "TLS alert received from peer"
                                      "TLS alert received from the peer"))
           (written (replace-form root pn "define-condition" "tls-alert-error"
                                  replacement)))
      (check-splice original written node replacement)
      (is = 54 (count-read-time-evals written)))))

(define-test replace-a-form-after-read-time-evals
  "Replacing the form after both #. forms leaves the whole prefix as it was."
  (with-temp-project-root (session root)
    (let* ((original (fixture-text))
           (pn (write-conditions root original))
           (node (form-node original "define-condition" "tls-decode-error"))
           (replacement (replace-once (form-text original node)
                                      "Error decoding TLS data"
                                      "Error while decoding TLS data"))
           (written (replace-form root pn "define-condition" "tls-decode-error"
                                  replacement)))
      (check-splice original written node replacement)
      (is = 54 (count-read-time-evals written)))))

(define-test reading-a-file-never-evaluates-its-read-time-forms
  "A file holding the probe parses and takes an edit without evaluating the probe."
  (let ((*read-time-evaluated* nil))
    (with-temp-project-root (session root)
      (let* ((original (format nil "~A~%~A~%" (fixture-text) (probe-form-text)))
             (pn (write-conditions root original)))
        (multiple-value-bind (nodes unparsed-from)
            (parse-top-level-forms original :source-path #p"conditions.lisp")
          (is = 6 (count :expr nodes :key #'cst-node-kind))
          (false unparsed-from))
        (let* ((node (form-node original "define-condition" "tls-alert-error"))
               (replacement (replace-once (form-text original node)
                                          "TLS alert received from peer"
                                          "TLS alert received from the peer"))
               (written (replace-form root pn "define-condition" "tls-alert-error"
                                      replacement)))
          (true (search (probe-form-text) written))
          (false *read-time-evaluated*))))))

(define-test probe-runs-when-read-time-evaluation-is-on
  "Positive control: the probe sets the flag when read with evaluation enabled."
  (let ((*read-time-evaluated* nil))
    (with-standard-io-syntax
      (let ((*read-eval* t))
        (read-from-string +probe+)))
    (true *read-time-evaluated*)))

;;;; -------------------------------------------------------------------------
;;;; The inert #. reader
;;;; -------------------------------------------------------------------------

(define-test case-keys-read-as-read-time-evals
  "The CASE keys of known-alert-description-p read as inert values."
  (let* ((value (cst-node-value (form-node (fixture-text) "defun"
                                           "known-alert-description-p")))
         (case-form (fifth value))
         (keys (first (third case-form))))
    (true (every #'read-time-eval-p keys))
    (true (symbolp (read-time-eval-expression (first keys))))
    (is string= "+ALERT-CLOSE-NOTIFY+"
        (symbol-name (read-time-eval-expression (first keys))))))

(define-test inert-readtable-reads-without-evaluating
  "Under the inert readtable #. yields its expression, and a suppressed #. yields nothing."
  (let ((standard-entry (get-dispatch-macro-character #\# #\. (copy-readtable nil)))
        (from (copy-readtable nil)))
    (let ((from-entry (get-dispatch-macro-character #\# #\. from))
          (*read-eval* nil))
      (let ((*readtable* (inert-readtable nil)))
        (let ((object (read-from-string "#.(+ 1 2)")))
          (true (read-time-eval-p object))
          (is equal '(+ 1 2) (read-time-eval-expression object))
          (is string= "#.(+ 1 2)" (prin1-to-string object)))
        (is eql 7 (read-from-string "#+(or) #.(error \"x\") 7")))
      (inert-readtable from)
      (is eq standard-entry
          (get-dispatch-macro-character #\# #\. (copy-readtable nil)))
      (is eq from-entry (get-dispatch-macro-character #\# #\. from)))))

(define-test custom-readtable-path-reads-without-evaluating
  "The custom-readtable fallback reads #. inertly and leaves the readtable it is given unchanged."
  (let* ((text "(defconstant +k+ #.(+ 1 2))")
         (custom (copy-readtable nil))
         (entry (get-dispatch-macro-character #\# #\. custom))
         (nodes (let ((dsmr-mcp/src/cst::*line-table*
                        (dsmr-mcp/src/cst::build-line-table text))
                      (*package* *package*))
                  (with-input-from-string (stream text)
                    (dsmr-mcp/src/cst::%read-remaining-with-cl-reader
                     stream nil custom)))))
    (is = 1 (length nodes))
    (true (read-time-eval-p (third (cst-node-value (first nodes)))))
    (is eq entry (get-dispatch-macro-character #\# #\. custom))))
