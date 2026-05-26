;;;; src/cst.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Eclector CST engine for structural source editing and the collapsed-view
;;;; reader.  Produces CST-NODE values carrying byte offsets, 1-based line
;;;; numbers, and the read value so that downstream tools can locate, render,
;;;; and patch top-level forms without losing comment positions.
;;;;
;;;; Shared across lisp-read-file (collapsed view), lisp-edit-form (structural
;;;; editor), and clgrep (structural search).
;;;;
;;;; Fresh AGPL write adapting patterns from cl-mcp/src/cst.lisp (MIT).

(defpackage #:dsmr-mcp/src/cst
  (:use #:cl)
  (:import-from #:eclector.parse-result
                #:parse-result-client
                #:make-expression-result
                #:make-skipped-input-result)
  (:import-from #:dsmr-mcp/src/package-context
                #:call-with-lenient-packages
                #:call-with-file-package-context)
  (:export #:cst-node
           #:cst-node-kind
           #:cst-node-value
           #:cst-node-children
           #:cst-node-start
           #:cst-node-end
           #:cst-node-start-line
           #:cst-node-end-line
           #:parse-top-level-forms))

(in-package #:dsmr-mcp/src/cst)

;;;; -------------------------------------------------------------------------
;;;; CST node structure
;;;; -------------------------------------------------------------------------

(defstruct cst-node
  "A node produced by parse-top-level-forms.
KIND is :EXPR for expression nodes or :SKIPPED for comments and #; forms.
VALUE is the read Lisp value (:EXPR) or the skip reason keyword (:SKIPPED).
CHILDREN are child CST nodes from Eclector's orphan list.
START/END are 0-based byte offsets into the source text.
START-LINE/END-LINE are 1-based line numbers."
  kind
  value
  children
  (start 0 :type fixnum)
  (end 0 :type fixnum)
  (start-line 1 :type fixnum)
  (end-line 1 :type fixnum))

;;;; -------------------------------------------------------------------------
;;;; Line table -- character offset to 1-based line number
;;;; -------------------------------------------------------------------------

(declaim (type (simple-array fixnum (*)) *line-table*))
(defvar *line-table* (make-array 1 :element-type 'fixnum :initial-element 1)
  "Dynamically bound by parse-top-level-forms.
Maps character positions in the source text to 1-based line numbers.")

(defun build-line-table (text)
  "Return a fixnum array mapping each character offset in TEXT to a 1-based
line number.  The array has length (1+ (length TEXT)) so the final position
past EOF maps to the last line."
  (let* ((len (length text))
         (table (make-array (1+ len) :element-type 'fixnum))
         (line 1))
    (loop for i fixnum from 0 below len
          for ch = (char text i) do
            (setf (aref table i) line)
            (when (char= ch #\Newline)
              (incf line)))
    (setf (aref table len) line)
    table))

(defun %pos->line (pos)
  "Convert a 0-based character offset to a 1-based line number via *LINE-TABLE*."
  (aref *line-table* (min pos (1- (length *line-table*)))))

;;;; -------------------------------------------------------------------------
;;;; Eclector make-skipped-input-result arity guard
;;;;
;;;; Eclector <= 0.10: (client stream reason source)           -- 4 args
;;;; Eclector >= 0.11: (client stream reason children source)  -- 5 args
;;;; Our checkout is 0.12.0 (5-arg), but we guard for deployment safety.
;;;;
;;;; Feature keyword: :DSMR-MCP-ECLECTOR-5-ARG-SKIPPED
;;;; Deliberately distinct from cl-mcp's :CL-MCP-ECLECTOR-SKIPPED-HAS-CHILDREN
;;;; so both systems can coexist in one image without feature-flag collision.
;;;; -------------------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let* ((gf (fdefinition 'make-skipped-input-result))
         (ll (#+sbcl sb-mop:generic-function-lambda-list
              #+ccl ccl:generic-function-lambda-list
              #+(or ecl clasp) clos:generic-function-lambda-list
              #-(or sbcl ccl ecl clasp) closer-mop:generic-function-lambda-list
              gf))
         (required (loop for p in ll
                         until (and (symbolp p) (member p lambda-list-keywords))
                         count 1)))
    (cond
      ((= required 5)
       (pushnew :dsmr-mcp-eclector-5-arg-skipped *features*))
      ((= required 4)
       (setf *features* (remove :dsmr-mcp-eclector-5-arg-skipped *features*)))
      (t
       (warn "Unexpected arity ~D for ECLECTOR.PARSE-RESULT:MAKE-SKIPPED-INPUT-RESULT; ~
              expected 4 or 5 required arguments." required)))))

;;;; -------------------------------------------------------------------------
;;;; Eclector parse-result-client methods
;;;; The eval-when ensures the methods are defined at compile time so the
;;;; reader conditionals for make-skipped-input-result resolve before the
;;;; methods are emitted to the FASL.
;;;; -------------------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmethod make-expression-result ((client parse-result-client)
                                     result children source)
    (declare (ignore client))
    (destructuring-bind (start . end) source
      (make-cst-node :kind :expr
                     :value result
                     :children children
                     :start start
                     :end end
                     :start-line (%pos->line start)
                     :end-line (%pos->line end)))))

#+dsmr-mcp-eclector-5-arg-skipped
(defmethod make-skipped-input-result ((client parse-result-client)
                                      stream reason children source)
  (declare (ignore client stream children))
  (destructuring-bind (start . end) source
    (make-cst-node :kind :skipped
                   :value reason
                   :children nil
                   :start start
                   :end end
                   :start-line (%pos->line start)
                   :end-line (%pos->line end))))

#-dsmr-mcp-eclector-5-arg-skipped
(defmethod make-skipped-input-result ((client parse-result-client)
                                      stream reason source)
  (declare (ignore client stream))
  (destructuring-bind (start . end) source
    (make-cst-node :kind :skipped
                   :value reason
                   :children nil
                   :start start
                   :end end
                   :start-line (%pos->line start)
                   :end-line (%pos->line end))))

;;;; -------------------------------------------------------------------------
;;;; Custom readtable fallback
;;;; -------------------------------------------------------------------------

(defun %in-readtable-form-p (form)
  "Return the readtable designator when FORM is (IN-READTABLE ...), else NIL."
  (and (consp form)
       (let ((head (car form)))
         (and (symbolp head)
              (string= (symbol-name head) "IN-READTABLE")
              (consp (cdr form))
              (second form)))))

(defun %in-package-form-p (form)
  "Return the package designator string when FORM is (IN-PACKAGE ...), else NIL."
  (and (consp form)
       (let ((head (car form)))
         (and (symbolp head)
              (string= (symbol-name head) "IN-PACKAGE")
              (consp (cdr form))
              (let ((designator (second form)))
                (cond ((stringp designator) designator)
                      ((symbolp designator) (symbol-name designator))
                      (t nil)))))))

(defun %try-switch-readtable (designator)
  "Locate a named readtable for DESIGNATOR via named-readtables, or return NIL."
  (let ((pkg (or (find-package :named-readtables)
                 (find-package :editor-hints.named-readtables))))
    (when pkg
      (let ((find-fn (find-symbol "FIND-READTABLE" pkg)))
        (when (and find-fn (fboundp find-fn))
          (funcall find-fn designator))))))

(defun %read-remaining-with-cl-reader (stream nodes custom-readtable)
  "Read remaining forms from STREAM using the standard CL reader with CUSTOM-READTABLE.
Fallback path after an IN-READTABLE form is encountered.
Returns the complete node list in source order."
  (let ((*readtable* custom-readtable)
        (*read-eval* nil))
    (loop
      (let ((start-pos (file-position stream)))
        (loop for ch = (peek-char nil stream nil :eof)
              while (and (characterp ch)
                         (member ch '(#\Space #\Tab #\Newline #\Return)))
              do (read-char stream))
        (setf start-pos (file-position stream))
        (let ((form (handler-case (read stream nil :eof)
                      (error () (return (nreverse nodes))))))
          (when (eq form :eof)
            (return (nreverse nodes)))
          (let* ((end-pos (file-position stream))
                 (node (make-cst-node :kind :expr
                                      :value form
                                      :children nil
                                      :start start-pos
                                      :end end-pos
                                      :start-line (%pos->line start-pos)
                                      :end-line (%pos->line end-pos))))
            (let ((pkg-name (%in-package-form-p form)))
              (when pkg-name
                (let ((pkg (find-package pkg-name)))
                  (when pkg
                    (setf *package* pkg)))))
            (push node nodes)))))))

;;;; -------------------------------------------------------------------------
;;;; Core parse loop
;;;; -------------------------------------------------------------------------

(defun %update-package-from-node (result)
  "If RESULT is an in-package CST node, update *PACKAGE* accordingly."
  (when (and (typep result 'cst-node)
             (eq (cst-node-kind result) :expr))
    (let ((pkg-name (%in-package-form-p (cst-node-value result))))
      (when pkg-name
        (let ((pkg (find-package pkg-name)))
          (when pkg
            (setf *package* pkg)))))))

(defun %check-in-readtable (result stream nodes)
  "If RESULT is an in-readtable CST node, switch to the CL reader.
Returns (values custom-rt-nodes t) when switching, (values nil nil) otherwise."
  (when (and (typep result 'cst-node)
             (eq (cst-node-kind result) :expr))
    (let ((designator (%in-readtable-form-p (cst-node-value result))))
      (when designator
        (let ((custom-rt (%try-switch-readtable designator)))
          (when custom-rt
            (return-from %check-in-readtable
              (values (%read-remaining-with-cl-reader stream nodes custom-rt) t)))))))
  (values nil nil))

(defun %eclector-parse-loop (text)
  "Inner Eclector parse loop.  *LINE-TABLE* and *PACKAGE* must be bound."
  (let ((*readtable* (copy-readtable))
        (*read-eval* nil)
        (nodes '())
        (client (make-instance 'parse-result-client)))
    (with-input-from-string (stream text)
      (handler-case
          (call-with-lenient-packages
           (lambda ()
             (loop
               (multiple-value-bind (result orphan-results)
                   (eclector.parse-result:read client stream nil :eof)
                 (dolist (orphan orphan-results)
                   (push orphan nodes))
                 (when (eq result :eof)
                   (return (nreverse nodes)))
                 (push result nodes)
                 (%update-package-from-node result)
                 (multiple-value-bind (rt-nodes switched)
                     (%check-in-readtable result stream nodes)
                   (when switched
                     (return rt-nodes)))))))
        (reader-error (e)
          (let ((msg (format nil "~A" e)))
            (if (search "READ-EVAL" msg)
                (error
                 "Reader error: ~A~%~%Read-time evaluation (#.) is disabled for ~
security. If you need to parse files containing #., consider removing or ~
replacing the #. forms, or use a separate evaluation step." e)
                (nreverse nodes))))))))

(defun %parse-core (text readtable)
  "Run the Eclector or CL-reader parse loop over TEXT.
*LINE-TABLE* and *PACKAGE* must already be bound by the caller."
  (if readtable
      (let ((custom-rt (%try-switch-readtable readtable)))
        (if custom-rt
            (call-with-lenient-packages
             (lambda ()
               (with-input-from-string (stream text)
                 (%read-remaining-with-cl-reader stream nil custom-rt))))
            (error "Readtable ~S not found." readtable)))
      (%eclector-parse-loop text)))

;;;; -------------------------------------------------------------------------
;;;; Public API
;;;; -------------------------------------------------------------------------

(defun parse-top-level-forms (text &key readtable source-path initial-package)
  "Parse TEXT into a list of CST-NODE values in source order.

Each node is either:
  :EXPR    -- a successfully read Lisp form with byte offsets and line numbers.
  :SKIPPED -- a comment or #; suppressed form, also with offsets/lines.

Keyword arguments:
  READTABLE       -- a named-readtable designator string; when supplied, the
                     standard CL reader is used (Eclector skipped, no comment nodes).
  SOURCE-PATH     -- pathname of the file, used to synthesize a package context
                     for the file's IN-PACKAGE declaration when INITIAL-PACKAGE
                     is not given.
  INITIAL-PACKAGE -- package designator string to bind as *PACKAGE* before parsing.
                     Overrides the IN-PACKAGE extraction from SOURCE-PATH.

Unknown package prefixes are handled leniently: ephemeral stub packages are
created and cleaned up after parsing, with their symbols recorded in
*homeless-due-to-teardown* so display code can suppress spurious #: prefixes."
  (let ((*line-table* (build-line-table text))
        (*package* *package*))
    (cond
      (initial-package
       (let ((pkg (or (find-package (string-upcase initial-package))
                      (find-package initial-package))))
         (when pkg
           (setf *package* pkg)))
       (call-with-lenient-packages
        (lambda ()
          (%parse-core text readtable))))
      (source-path
       (call-with-file-package-context
        text
        (lambda ()
          (%parse-core text readtable))))
      (t
       (call-with-lenient-packages
        (lambda ()
          (%parse-core text readtable)))))))
