;;;; tests/read-time-eval-edge-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Edge cases of the inert #. reader:
;;;;   - feature expressions built with #. (#+#. and #-#.);
;;;;   - a #. at end of input, at end of list, or after a numeric argument;
;;;;   - #. nested inside other syntax;
;;;;   - readtable isolation.
;;;; Every source-reading path is checked twice: once as shipped, where the
;;;; probe must not run, and once under a control that evaluates what the
;;;; inert #. entry returns, where the probe must run.  The control shows the
;;;; path reaches the #. entry and that the probe names the real special.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/read-time-eval-edge-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/read-time-eval-edge-test
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
                #:inert-readtable
                #:inert-eclector-readtable)
  (:import-from #:dsmr-mcp/src/lisp-edit-form
                #:edit-form
                #:validate-and-repair-content)
  (:import-from #:dsmr-mcp/src/lisp-patch-form
                #:patch-form)
  (:import-from #:dsmr-mcp/src/validate
                #:try-reader-check)
  (:import-from #:dsmr-mcp/src/package-context
                #:extract-in-package-name-from-text)
  (:import-from #:dsmr-mcp/src/lisp-read-file
                #:read-file-collapsed)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/read-time-eval-edge-test)

;;;; -------------------------------------------------------------------------
;;;; Probes and helpers
;;;; -------------------------------------------------------------------------

(defvar *evaluated* nil
  "Set to T when a probe's #. expression is evaluated.")

(defparameter +probe+
  "#.(cl:setf dsmr-mcp/tests/read-time-eval-edge-test::*evaluated* cl:t)"
  "A #. form that sets *EVALUATED* when evaluated.")

(defparameter +feature-probe+
  "#.(cl:progn (cl:setf dsmr-mcp/tests/read-time-eval-edge-test::*evaluated* cl:t) '(:or))"
  "A #. feature expression that sets *EVALUATED*, then names no feature.")

(defparameter +inert-entries+
  '(dsmr-mcp/src/read-time-eval::%inert-sharpsign-dot
    dsmr-mcp/src/read-time-eval::%inert-eclector-sharpsign-dot)
  "The #. reader entries the control wraps.")

(defun call-with-evaluating-reader (thunk)
  "Call THUNK with each inert #. entry wrapped to evaluate what it returns.
Remove the wrappers on exit."
  (unwind-protect
       (progn
         (dolist (name +inert-entries+)
           (sb-int:encapsulate
            name 'evaluating-control
            (lambda (function &rest arguments)
              (let ((value (apply function arguments)))
                (when (read-time-eval-p value)
                  (eval (read-time-eval-expression value)))
                value))))
         (funcall thunk))
    (dolist (name +inert-entries+)
      (sb-int:unencapsulate name 'evaluating-control))))

(defun evaluated-p (thunk &key control)
  "Return T when calling THUNK set *EVALUATED*.
With CONTROL true, call it under CALL-WITH-EVALUATING-READER.  Errors from
THUNK are ignored: other tests check each path's result."
  (let ((*evaluated* nil))
    (ignore-errors
     (if control
         (call-with-evaluating-reader thunk)
         (funcall thunk)))
    *evaluated*))

(defun parse (text)
  "Parse TEXT; return (values nodes unparsed-from), or the type of an escaping error."
  (handler-case (parse-top-level-forms text :source-path #p"edge.lisp")
    (error (e) (type-of e))))

(defun expr-names (nodes)
  "Return the second element of each :EXPR node value in NODES, as lowercase strings."
  (loop for node in nodes
        for value = (cst-node-value node)
        when (and (eq (cst-node-kind node) :expr)
                  (consp value) (consp (rest value)) (symbolp (second value)))
          collect (string-downcase (symbol-name (second value)))))

(defun replace-text (string old new)
  "Return STRING with its single occurrence of OLD replaced by NEW."
  (let ((pos (search old string)))
    (assert pos () "~S not found" old)
    (concatenate 'string (subseq string 0 pos) new (subseq string (+ pos (length old))))))

(defun custom-read (text &optional (custom (copy-readtable nil)))
  "Read TEXT through the custom-readtable fallback; return (values nodes unparsed-from)."
  (let ((dsmr-mcp/src/cst::*line-table* (dsmr-mcp/src/cst::build-line-table text))
        (*package* *package*))
    (with-input-from-string (stream text)
      (dsmr-mcp/src/cst::%read-remaining-with-cl-reader stream nil custom))))

(defun dispatch-entries (readtable)
  "Return the #. #+ and #- entries of the CL READTABLE."
  (mapcar (lambda (char) (get-dispatch-macro-character #\# char readtable))
          '(#\. #\+ #\-)))

(defun eclector-dispatch-entries (readtable)
  "Return the #. #+ and #- entries of the Eclector READTABLE."
  (mapcar (lambda (char)
            (eclector.readtable:get-dispatch-macro-character readtable #\# char))
          '(#\. #\+ #\-)))

;;;; -------------------------------------------------------------------------
;;;; Every reader path: never evaluates, and the control shows it reads the probe
;;;; -------------------------------------------------------------------------

(defun probed-file-text (probe)
  "Return file text holding PROBE in a form before IN-PACKAGE and a target form."
  (format nil "(defparameter *p* ~A)~%(in-package #:edge-probe)~%(defun target () 1)~%"
          probe))

(defun feature-probed-file-text ()
  "Return file text whose second form is guarded by the #. feature probe."
  (format nil "(defun a () 1)~%#+~A (defun b () 2)~%(in-package #:edge-probe)~%(defun target () 1)~%"
          +feature-probe+))

(defun path-thunks (text content)
  "Return (name . thunk) for each path that reads TEXT as a file or CONTENT as edit text."
  (flet ((in-project (function)
           (lambda ()
             (with-temp-project-root (session root)
               (let ((pn (write-fixture-file root "src/edge.lisp" text)))
                 (funcall function root pn))))))
    (list
     (cons :parse (lambda () (parse-top-level-forms text :source-path #p"edge.lisp")))
     (cons :edit-form
           (in-project (lambda (root pn)
                         (edit-form (namestring root) (namestring pn) "defun" "target"
                                    "replace" "(defun target () 2)"))))
     (cons :patch-form
           (in-project (lambda (root pn)
                         (patch-form (namestring root) (namestring pn) "defun" "target"
                                     "() 1)" "() 2)"))))
     (cons :read-file (lambda () (read-file-collapsed text :source-path #p"edge.lisp")))
     (cons :check-parens (lambda () (try-reader-check text)))
     (cons :package (lambda () (extract-in-package-name-from-text text)))
     (cons :custom-readtable (lambda () (custom-read text)))
     (cons :replacement (lambda () (validate-and-repair-content content))))))

(defun path-results (text content &key control)
  "Return (name . evaluated-p) for each path over TEXT and CONTENT."
  (loop for (name . thunk) in (path-thunks text content)
        collect (cons name (evaluated-p thunk :control control))))

(defparameter +all-false+
  '((:parse) (:edit-form) (:patch-form) (:read-file) (:check-parens) (:package)
    (:custom-readtable) (:replacement))
  "PATH-RESULTS when no path evaluated the probe.")

(defparameter +all-true+
  '((:parse . t) (:edit-form . t) (:patch-form . t) (:read-file . t)
    (:check-parens . t) (:package . t) (:custom-readtable . t) (:replacement . t))
  "PATH-RESULTS when every path evaluated the probe.")

(define-test no-reader-path-evaluates-a-read-time-eval
  "No path evaluates a #. in a file or in edit text."
  (is equal +all-false+
      (path-results (probed-file-text +probe+)
                    (format nil "(defun target () ~A)" +probe+))))

(define-test every-reader-path-reaches-the-probe
  "Control: evaluating what the inert #. entry returns runs the probe on every path."
  (is equal +all-true+
      (path-results (probed-file-text +probe+)
                    (format nil "(defun target () ~A)" +probe+)
                    :control t)))

(define-test no-reader-path-evaluates-a-read-time-eval-feature
  "No path evaluates a #. feature expression in a file or in edit text."
  (is equal +all-false+
      (path-results (feature-probed-file-text)
                    (format nil "(defun target () #+~A 1)" +feature-probe+))))

(define-test every-reader-path-reaches-the-feature-probe
  "Control: evaluating the inert value runs the feature probe on every path."
  (is equal +all-true+
      (path-results (feature-probed-file-text)
                    (format nil "(defun target () #+~A 1)" +feature-probe+)
                    :control t)))

;;;; -------------------------------------------------------------------------
;;;; Feature expressions built with #.
;;;; -------------------------------------------------------------------------

(defparameter +feature+
  "#.(cl:if (cl:find-package \"EDGE-ABSENT\") '(:and) '(:or))"
  "A #. feature expression in the portability idiom.")

(defun feature-file-text ()
  "Return file text with one form under #+#. and one under #-#."
  (format nil "(defun a () 1)~%#+~A (defun b () 2)~%#-~A (defun c () 3)~%(defun d () 4)~%"
          +feature+ +feature+))

(define-test read-time-eval-features-read-their-forms-as-present
  "A form under #+#. or #-#. is read, so all four forms parse."
  (multiple-value-bind (nodes unparsed-from) (parse (feature-file-text))
    (is equal '("a" "b" "c" "d") (expr-names nodes))
    (false unparsed-from))
  (multiple-value-bind (nodes unparsed-from) (custom-read (feature-file-text))
    (is equal '("a" "b" "c" "d") (expr-names nodes))
    (false unparsed-from)))

(define-test decided-features-still-decide
  "#+ and #- over an ordinary feature expression still skip or keep their form."
  (let ((text (format nil "#+(or) (defun skipped () 1)~%#-(or) (defun kept () 2)~%~
                           #+(and) (defun kept-too () 3)~%#-(and) (defun skipped-too () 4)~%")))
    (is equal '("kept" "kept-too") (expr-names (parse text)))
    (is equal '("kept" "kept-too") (expr-names (custom-read text)))
    (false (try-reader-check text))))

(define-test forms-under-read-time-eval-features-are-editable
  "Forms after and under #+#. are found, and an edit changes only their span.
A guarded form's span starts at its #+, as for any feature expression, so a
replacement that keeps the guard carries it."
  (with-temp-project-root (session root)
    (let* ((original (feature-file-text))
           (pn (write-fixture-file root "src/edge.lisp" original))
           (guarded (format nil "#+~A (defun b () 2)" +feature+))
           (replacement (format nil "#+~A (defun b () 20)" +feature+))
           (after-d (replace-text original "(defun d () 4)" "(defun d () 40)")))
      (edit-form (namestring root) (namestring pn) "defun" "d" "replace"
                 "(defun d () 40)" :normalize-blank-lines nil)
      (is string= after-d (uiop:read-file-string pn))
      (edit-form (namestring root) (namestring pn) "defun" "b" "replace"
                 replacement :normalize-blank-lines nil)
      (is string= (replace-text after-d guarded replacement)
          (uiop:read-file-string pn)))))

(define-test read-time-eval-features-in-view-check-and-package
  "The read-file view, check-parens and package detection accept #+#. and #-#."
  (let ((text (feature-file-text)))
    (multiple-value-bind (display mode meta)
        (read-file-collapsed text :source-path #p"edge.lisp")
      (declare (ignore mode))
      (is = 4 (gethash "total_forms" meta))
      (true (search "(defun d" display)))
    (false (try-reader-check text))
    (is equal "EDGE-PROBE"
        (extract-in-package-name-from-text
         (format nil "#+~A (defun b () 2)~%(in-package #:edge-probe)~%" +feature+)))
    (let ((content (format nil "(defun x () #+~A 1 #-~A 2)" +feature+ +feature+)))
      (is equal content (validate-and-repair-content content)))))

;;;; -------------------------------------------------------------------------
;;;; Malformed #.: end of list, end of input, numeric argument, comma
;;;; -------------------------------------------------------------------------

(define-test read-time-eval-before-a-close-paren-is-an-error
  "(list #.) is a reader error, not a read of (list)."
  (multiple-value-bind (nodes unparsed-from)
      (parse (format nil "(list #.)~%(defun z () 1)~%"))
    (is equal '() (expr-names nodes))
    (is eql 0 unparsed-from)))

(define-test read-time-eval-at-end-of-input-stops-the-parse
  "A #. at end of input, alone or before a comment, ends the parse at the last form."
  (dolist (tail '("#." "#.   " "#. ; trailing comment" "#. ; trailing comment
"))
    (let ((text (format nil "(defun a () 1)~%~A" tail)))
      (is equal '(("a") 14)
          (multiple-value-bind (nodes unparsed-from) (parse text)
            (if (listp nodes)
                (list (expr-names nodes) unparsed-from)
                nodes))
          "tail ~S" tail)
      (true (try-reader-check text) "check-parens on tail ~S" tail))))

(define-test comma-after-read-time-eval-in-backquote-is-an-error
  "A comma straight after #. inside backquote: check-parens refuses it, as SBCL's
reader does; the Eclector parse accepts it, as Eclector's own #. entry does."
  (let ((text "(defmacro m (x) `(list #.,x))"))
    (true (try-reader-check text))
    (multiple-value-bind (nodes unparsed-from) (parse text)
      (is equal '("m") (expr-names nodes))
      (false unparsed-from))))

(define-test numeric-argument-to-read-time-eval-is-reported
  "#1. signals as each standard reader does: an error from Eclector, a warning from SBCL."
  (is eql 0 (nth-value 1 (handler-bind ((warning #'muffle-warning))
                           (parse "(defparameter *x* #1.(+ 1 2))"))))
  (is eq :warned
      (handler-case (let ((*read-eval* nil)
                          (*readtable* (inert-readtable nil)))
                      (read-from-string "#1.(+ 1 2)")
                      :quiet)
        (warning () :warned))))

;;;; -------------------------------------------------------------------------
;;;; #. nested inside other syntax
;;;; -------------------------------------------------------------------------

(defparameter +nested-cases+
  (list (cons :double (format nil "(defparameter *x* #.~A)" +probe+))
        (cons :suppressed (format nil "(defparameter *x* #+(or) ~A 1)" +probe+))
        (cons :backquote (format nil "(defmacro m (x) `(list ,x ~A))" +probe+))
        (cons :comment (format nil "(defparameter *x* #. ; note~%~A)"
                               (subseq +probe+ 2)))
        (cons :in-package (format nil "(in-package ~A)" +probe+))
        (cons :feature (format nil "#+~A (defparameter *x* 1)" +feature-probe+)))
  "Each (name . text): a #. nested in other syntax.")

(define-test nested-read-time-evals-parse-whole-and-never-run
  "Each nested case parses whole, checks clean, and never evaluates the probe."
  (loop for (name . text) in +nested-cases+
        do (let ((*evaluated* nil))
             (multiple-value-bind (nodes unparsed-from) (parse text)
               (is = 1 (count :expr nodes :key #'cst-node-kind) "~A forms" name)
               (false unparsed-from "~A unparsed" name))
             (false (try-reader-check text) "~A check-parens" name)
             (false *evaluated* "~A evaluated" name))))

(define-test nested-read-time-evals-reach-the-probe
  "Control: every nested case but the suppressed one runs the probe when evaluated."
  (is equal '((:double . t) (:suppressed) (:backquote . t) (:comment . t)
              (:in-package . t) (:feature . t))
      (loop for (name . text) in +nested-cases+
            collect (cons name (evaluated-p (lambda () (parse text)) :control t)))))

(define-test double-read-time-eval-nests-inert-values
  "#.#.X reads as an inert value whose expression is the inert value of X."
  (let* ((value (cst-node-value (first (parse "(defparameter *x* #.#.(+ 1 2))"))))
         (outer (third value)))
    (true (read-time-eval-p outer))
    (true (read-time-eval-p (read-time-eval-expression outer)))
    (is equal '(+ 1 2) (read-time-eval-expression (read-time-eval-expression outer)))))

;;;; -------------------------------------------------------------------------
;;;; Readtable isolation
;;;; -------------------------------------------------------------------------

(defparameter +isolation-text+
  (format nil "(defparameter *x* #.(+ 1 2))~%#+#.(cl:quote (:or)) (defun b () 2)~%")
  "Text that exercises the #. #+ and #- entries.")

(define-test eclector-readtable-is-unchanged-by-a-parse
  "Building the inert Eclector readtable and parsing leave Eclector's readtable as it was."
  (let ((before (eclector-dispatch-entries eclector.reader:*readtable*)))
    (inert-eclector-readtable)
    (parse +isolation-text+)
    (is equal before (eclector-dispatch-entries eclector.reader:*readtable*))))

(define-test cl-readtables-are-unchanged-by-a-parse
  "The standard, current and custom CL readtables keep their entries after every reader runs."
  (let* ((custom (copy-readtable nil))
         (standard (dispatch-entries (copy-readtable nil)))
         (current (dispatch-entries *readtable*))
         (custom-before (dispatch-entries custom)))
    (inert-readtable custom)
    (custom-read +isolation-text+ custom)
    (try-reader-check +isolation-text+)
    (extract-in-package-name-from-text +isolation-text+)
    (is equal standard (dispatch-entries (copy-readtable nil)))
    (is equal current (dispatch-entries *readtable*))
    (is equal custom-before (dispatch-entries custom))))

(define-test named-readtable-is-unchanged-by-a-parse
  "A readtable found by name for :READTABLE keeps its entries after a parse."
  (if (find-package :named-readtables)
      (true t "named-readtables is loaded; the stub is not installed")
      (let* ((custom (copy-readtable nil))
             (before (dispatch-entries custom))
             (package (make-package :named-readtables :use '())))
        (unwind-protect
             (let ((finder (intern "FIND-READTABLE" package)))
               (setf (symbol-function finder)
                     (lambda (designator)
                       (when (string-equal designator "EDGE-SYNTAX") custom)))
               (multiple-value-bind (nodes unparsed-from)
                   (parse-top-level-forms +isolation-text+
                                          :source-path #p"edge.lisp"
                                          :readtable "EDGE-SYNTAX")
                 (is = 2 (count :expr nodes :key #'cst-node-kind))
                 (false unparsed-from))
               (is equal before (dispatch-entries custom)))
          (delete-package package)))))
