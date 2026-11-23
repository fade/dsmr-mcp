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
                #:edit-form
                #:validate-and-repair-content)
  (:import-from #:dsmr-mcp/src/lisp-patch-form
                #:patch-form
                #:patch-operation-error)
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

;;;; -------------------------------------------------------------------------
;;;; Replacement and patch text holding #. forms
;;;; -------------------------------------------------------------------------

(define-test replace-a-read-time-eval-form-with-text-holding-read-time-evals
  "Replacing a form that holds #. writes the replacement text exactly as sent."
  (with-temp-project-root (session root)
    (let* ((original (fixture-text))
           (pn (write-conditions root original))
           (node (form-node original "defun" "known-alert-description-p"))
           (replacement (replace-once (form-text original node)
                                      "Return T if CODE is a known TLS alert description, NIL otherwise."
                                      "Return T when CODE is a known TLS alert description."))
           (written (replace-form root pn "defun" "known-alert-description-p"
                                  replacement)))
      (check-splice original written node replacement)
      (is = 54 (count-read-time-evals written)))))

(define-test dry-run-preview-of-a-read-time-eval-form
  "A dry run of the same replacement previews the file the apply writes, and writes nothing."
  (with-temp-project-root (session root)
    (let* ((original (fixture-text))
           (pn (write-conditions root original))
           (node (form-node original "defun" "known-alert-description-p"))
           (replacement (replace-once (form-text original node)
                                      "Return T if CODE is a known TLS alert description, NIL otherwise."
                                      "Return T when CODE is a known TLS alert description."))
           (result (edit-form (namestring root) (namestring pn)
                              "defun" "known-alert-description-p"
                              "replace" replacement :dry-run t)))
      (true (string= original (uiop:read-file-string pn)))
      (let ((written (replace-form root pn "defun" "known-alert-description-p"
                                   replacement)))
        (is string= written (gethash "preview" result))))))

(define-test patch-inside-a-read-time-eval-form
  "Patching one string inside a form that holds #. changes only that string."
  (with-temp-project-root (session root)
    (let* ((original (fixture-text))
           (pn (write-conditions root original)))
      (patch-form (namestring root) (namestring pn)
                  "defun" "alert-description-name"
                  "\"unknown_ca\"" "\"unknown_certificate_authority\"")
      (let ((written (uiop:read-file-string pn)))
        (is string= (replace-once original "\"unknown_ca\""
                                  "\"unknown_certificate_authority\"")
            written)
        (is = 54 (count-read-time-evals written))))))

(define-test patch-text-may-add-a-read-time-eval
  "Patch text that adds a #. clause is accepted and written verbatim."
  (with-temp-project-root (session root)
    (let* ((original (fixture-text))
           (pn (write-conditions root original))
           (old "    (otherwise (format nil \"unknown(~D)\" code))")
           (new (format nil "    (#.+alert-ech-required+ \"ech_required\")~%~A" old)))
      (patch-form (namestring root) (namestring pn)
                  "defun" "alert-description-name" old new)
      (let ((written (uiop:read-file-string pn)))
        (is string= (replace-once original old new) written)
        (is = 55 (count-read-time-evals written))))))

(define-test replacement-text-is-never-evaluated
  "Replacement text holding the probe is validated and written without evaluating it."
  (let ((*read-time-evaluated* nil))
    (with-temp-project-root (session root)
      (let* ((original (fixture-text))
             (pn (write-conditions root original))
             (node (form-node original "define-condition" "tls-alert-error"))
             (replacement (replace-once (form-text original node)
                                        "\"TLS alert received from peer\""
                                        +probe+)))
        (multiple-value-bind (content error)
            (ignore-errors (validate-and-repair-content replacement))
          (false error)
          (is equal replacement content))
        (false *read-time-evaluated*)
        (multiple-value-bind (written error)
            (ignore-errors (replace-form root pn "define-condition" "tls-alert-error"
                                         replacement))
          (false error)
          (false *read-time-evaluated*)
          (when written
            (check-splice original written node replacement)))))))

(define-test patch-text-is-never-evaluated
  "Patch text holding the probe is checked and written without evaluating it."
  (let ((*read-time-evaluated* nil))
    (with-temp-project-root (session root)
      (let* ((original (fixture-text))
             (pn (write-conditions root original)))
        (let ((error (handler-case
                         (progn
                           (patch-form (namestring root) (namestring pn)
                                       "defun" "alert-description-name"
                                       "\"unknown_ca\"" +probe+)
                           nil)
                       (error (e) e))))
          (false error)
          (false *read-time-evaluated*)
          (true (search +probe+ (uiop:read-file-string pn))))))))

(define-test one-form-rule-still-holds-with-read-time-evals
  "Replacement text holding two forms, one with #., is refused as more than one form."
  (with-temp-project-root (session root)
    (let* ((original (fixture-text))
           (pn (write-conditions root original))
           (content (format nil "(defun a () #.+k+)~%(defun b () 1)"))
           (error (nth-value 1 (ignore-errors
                                (edit-form (namestring root) (namestring pn)
                                           "defun" "known-alert-description-p"
                                           "replace" content)))))
      (true error)
      (true (and error
                 (search "exactly one top-level form" (princ-to-string error))))
      (is string= original (uiop:read-file-string pn)))))

(define-test broken-patch-still-refused-beside-read-time-evals
  "A patch that unbalances a form holding #. is refused and the file is unchanged."
  (with-temp-project-root (session root)
    (let* ((original (fixture-text))
           (pn (write-conditions root original)))
      (fail (patch-form (namestring root) (namestring pn)
                        "defun" "alert-description-name"
                        "(#.+alert-unknown-ca+ \"unknown_ca\")"
                        "(#.+alert-unknown-ca+ \"unknown_ca\"")
          'patch-operation-error)
      (is string= original (uiop:read-file-string pn)))))
