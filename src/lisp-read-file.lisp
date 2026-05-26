;;;; src/lisp-read-file.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Collapsed-view reader for Lisp source files (VERB-06).
;;;; Provides read-file-collapsed: given file text, produces a token-efficient
;;;; top-level-signature view.  Each definition is collapsed to its head+name+args
;;;; line with a "..." body marker; in-package forms are shown in full.
;;;; name_pattern / content_pattern (cl-ppcre) expand only matching forms.
;;;; collapsed=false slices by offset/limit with a truncation footer.
;;;;
;;;; Fresh AGPL write adapting cl-mcp/src/lisp-read-file.lisp (MIT).

(defpackage #:dsmr-mcp/src/lisp-read-file
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/cst
                #:parse-top-level-forms
                #:cst-node
                #:cst-node-kind
                #:cst-node-value
                #:cst-node-start
                #:cst-node-end
                #:cst-node-start-line
                #:cst-node-end-line)
  (:import-from #:dsmr-mcp/src/fs
                #:read-file-string)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path)
  (:import-from #:dsmr-mcp/src/package-context
                #:*homeless-due-to-teardown*)
  (:import-from #:cl-ppcre
                #:scan
                #:create-scanner)
  (:export #:read-file-collapsed
           #:*lisp-source-extensions*))

(in-package #:dsmr-mcp/src/lisp-read-file)

;;;; -------------------------------------------------------------------------
;;;; Parameters
;;;; -------------------------------------------------------------------------

(defparameter *lisp-source-extensions*
  '("lisp" "lsp" "cl" "asd" "ros")
  "File extensions treated as Lisp source for collapsed-view mode.")

(defparameter *default-line-limit* 500
  "Default maximum line count when LIMIT is not supplied in raw mode.")

(defparameter *text-context-lines* 5
  "Lines of context around each content_pattern match in raw text mode.")

;;;; -------------------------------------------------------------------------
;;;; Symbol printing with homeless-due-to-teardown awareness
;;;; -------------------------------------------------------------------------

(defun %print-homeless-symbol-name (stream name)
  (write-string (ecase *print-case*
                  (:downcase (string-downcase name))
                  (:upcase name)
                  (:capitalize (string-capitalize name)))
                stream))

(defun %print-source-symbol (stream sym)
  "Pprint-dispatch handler that suppresses #: for symbols that became homeless
due to stub-package teardown, while preserving #: for genuinely uninterned ones."
  (cond
    ((and (symbolp sym) (null (symbol-package sym)))
     (unless (gethash sym *homeless-due-to-teardown*)
       (write-string "#:" stream))
     (%print-homeless-symbol-name stream (symbol-name sym)))
    (t
     (let ((*print-pprint-dispatch* (copy-pprint-dispatch nil))
           (*print-circle* nil))
       (prin1 sym stream)))))

(defvar *source-pprint-dispatch*
  (let ((table (copy-pprint-dispatch nil)))
    (set-pprint-dispatch 'symbol #'%print-source-symbol 0 table)
    table)
  "Pprint dispatch used by form renderers.  Homeless-due-to-teardown symbols
print without #: while genuinely uninterned symbols retain their prefix.")

;;;; -------------------------------------------------------------------------
;;;; Lisp source extension predicate
;;;; -------------------------------------------------------------------------

(defun %lisp-source-p (path)
  "Return T when PATH has a Lisp source extension."
  (let* ((pn (if (pathnamep path) path (pathname path)))
         (type (pathname-type pn)))
    (and type (member (string-downcase type) *lisp-source-extensions*
                      :test #'string=))))

;;;; -------------------------------------------------------------------------
;;;; Form rendering helpers
;;;; -------------------------------------------------------------------------

(defun %form->string (form)
  "Render FORM as Lisp source text using the homeless-aware pprint dispatch."
  (let ((*print-pretty* t)
        (*print-case* :downcase)
        (*print-right-margin* 80)
        (*print-circle* nil)
        (*print-pprint-dispatch* *source-pprint-dispatch*))
    (with-output-to-string (out)
      (write form :stream out :pretty t :right-margin 80))))

(defun %docstring-first-line (s)
  (when (stringp s)
    (let* ((pos (or (position #\Newline s) (length s)))
           (slice (subseq s 0 pos)))
      (string-trim '(#\Space #\Tab) slice))))

(defun %truncate-doc (docstring)
  (let ((line (%docstring-first-line docstring)))
    (when (and line (plusp (length line)))
      (if (> (length line) 80)
          (concatenate 'string (subseq line 0 77) "...")
          line))))

(defun %collapse-def-form (form)
  "Produce a collapsed signature line for a definition form."
  (let* ((*print-case* :downcase)
         (*print-circle* nil)
         (*print-pprint-dispatch* *source-pprint-dispatch*)
         (head (car form))
         (name (second form))
         (qualifiers
          (when (and (symbolp head) (string= (symbol-name head) "DEFMETHOD"))
            (loop for part in (cddr form)
                  while (and part (symbolp part))
                  collect part)))
         (args
          (case head
            ((defmethod) (or (find-if #'listp (cddr form)) (third form)))
            (otherwise (third form))))
         (args-display
          (if args
              (with-output-to-string (out)
                (let ((*print-right-margin* most-positive-fixnum))
                  (write args :stream out :pretty t :case :downcase)))
              "()"))
         (doc (%truncate-doc (find-if #'stringp (cddr form))))
         (qual-str (when qualifiers
                     (format nil "~{~(~S~)~^ ~}" qualifiers)))
         (name-str (with-output-to-string (out)
                     (let ((*print-case* :downcase)
                           (*print-circle* nil)
                           (*print-pprint-dispatch* *source-pprint-dispatch*))
                       (if name
                           (write name :stream out)
                           (write-string "" out))))))
    (if qual-str
        (format nil "(~(~A~) ~A ~A ~A ...~@[ ;; ~A~])"
                head name-str qual-str args-display doc)
        (format nil "(~(~A~) ~A ~A ...~@[ ;; ~A~])"
                head name-str args-display doc))))

(defun %collapse-generic (form)
  (cond
    ((consp form)
     (format nil "(~(~A~) ...)" (car form)))
    (t (prin1-to-string form))))

(defun %definition-names (form)
  "Return a list of lowercase name strings for a definition form."
  (when (consp form)
    (let ((head (car form))
          (name (second form)))
      (when (and (symbolp head)
                 (let ((n (symbol-name head)))
                   (or (and (>= (length n) 3) (string= n "DEF" :end1 3))
                       (and (>= (length n) 7) (string= n "DEFINE-" :end1 7)))))
        (list (string-downcase
               (if (symbolp name)
                   (symbol-name name)
                   (prin1-to-string name))))))))

;;;; -------------------------------------------------------------------------
;;;; Line number helpers
;;;; -------------------------------------------------------------------------

(defun %line-number-width (line-count)
  (max 1 (length (write-to-string line-count))))

(defun %add-line-numbers (text start-line width)
  "Prefix each line of TEXT with a right-justified line number."
  (with-output-to-string (out)
    (with-input-from-string (stream text)
      (loop for line = (read-line stream nil nil)
            while line
            for idx from start-line do
              (format out "~VD: ~A~%" width idx line)))))

(defun %ensure-trailing-newline (s)
  (if (and (plusp (length s)) (char= (char s (1- (length s))) #\Newline))
      s
      (concatenate 'string s (string #\Newline))))

;;;; -------------------------------------------------------------------------
;;;; Collapsed-mode rendering
;;;; -------------------------------------------------------------------------

(defun %line-stats (text)
  "Return three values: source-lines, comment-lines, blank-lines for TEXT."
  (let ((source 0)
        (comment 0)
        (blank 0))
    (with-input-from-string (stream text)
      (loop for line = (read-line stream nil nil)
            while line do
              (incf source)
              (let ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) line)))
                (cond
                  ((string= trimmed "")
                   (incf blank))
                  ;; Line or block comment start
                  ((and (plusp (length trimmed))
                        (char= (char trimmed 0) #\;))
                   (incf comment))
                  ((and (>= (length trimmed) 2)
                        (char= (char trimmed 0) #\#)
                        (char= (char trimmed 1) #\|))
                   (incf comment))))))
    (values source comment blank)))

(defun %comment-node-p (node)
  "Return T when NODE is a skipped comment or #; form."
  (and (typep node 'cst-node)
       (eq (cst-node-kind node) :skipped)
       (let ((reason (cst-node-value node)))
         (or (eq reason :block-comment)
             (eq reason :s-expression-comment)
             (and (consp reason) (eq (car reason) :line-comment))))))

(defun %known-def-head-p (head)
  "Return T when HEAD is a well-known definition form symbol."
  (and (symbolp head)
       (member (symbol-name head)
               '("DEFUN" "DEFMACRO" "DEFVAR" "DEFPARAMETER" "DEFCONSTANT"
                 "DEFCLASS" "DEFSTRUCT" "DEFGENERIC" "DEFMETHOD")
               :test #'string=)))

(defun %in-package-head-p (head)
  "Return T when HEAD is IN-PACKAGE."
  (and (symbolp head) (string= (symbol-name head) "IN-PACKAGE")))

(defun %format-one-node (node name-scanner content-scanner line-width)
  "Return two values: rendered display string and whether the node was expanded.
Expansion happens when name-scanner matches a definition name, content-scanner
matches the form text, or the form is an in-package."
  (let* ((form (cst-node-value node))
         (head (and (consp form) (car form)))
         (names (%definition-names form))
         (full-string nil)
         (name-match (and name-scanner
                          (some (lambda (n) (scan name-scanner n)) names)))
         (content-match (and content-scanner
                             (let ((repr (or full-string
                                             (setf full-string (%form->string form)))))
                               (scan content-scanner repr))))
         (in-pkg-p (%in-package-head-p head))
         (expand-p (or name-match content-match in-pkg-p))
         (start-line (cst-node-start-line node)))
    (cond
      (expand-p
       (values (%add-line-numbers (or full-string (%form->string form))
                                  start-line line-width)
               t))
      ((%known-def-head-p head)
       (values (format nil "~VD: ~A" line-width start-line
                       (%collapse-def-form form))
               nil))
      (t
       (values (format nil "~VD: ~A" line-width start-line
                       (%collapse-generic form))
               nil)))))

(defun %update-package-from-form (form)
  "When FORM is (in-package PKG), update *PACKAGE*."
  (when (and (consp form)
             (symbolp (car form))
             (string= (symbol-name (car form)) "IN-PACKAGE")
             (consp (cdr form)))
    (let* ((designator (second form))
           (pkg-name (cond
                       ((stringp designator) designator)
                       ((symbolp designator) (symbol-name designator)))))
      (when pkg-name
        (let ((pkg (find-package pkg-name)))
          (when pkg
            (setf *package* pkg)))))))

(defun %format-lisp-file (text name-scanner content-scanner &key readtable source-path)
  "Parse TEXT as Lisp source and return (values display meta).
name-scanner and content-scanner are compiled cl-ppcre scanners or NIL."
  (multiple-value-bind (source-lines comment-lines blank-lines)
      (%line-stats text)
    (let* ((nodes (parse-top-level-forms text
                                         :readtable readtable
                                         :source-path source-path))
           (line-width (%line-number-width source-lines))
           (expanded 0)
           (total-forms 0)
           (*package* *package*))
      (let ((display
             (with-output-to-string (out)
               (dolist (node nodes)
                 (cond
                   ((%comment-node-p node)
                    ;; Omit comment nodes from collapsed view.
                    nil)
                   ((and (typep node 'cst-node)
                         (eq (cst-node-kind node) :expr))
                    (incf total-forms)
                    (multiple-value-bind (rendered expanded-p)
                        (%format-one-node node name-scanner content-scanner line-width)
                      (when expanded-p (incf expanded))
                      (write-string (%ensure-trailing-newline rendered) out))
                    ;; Track in-package for correct symbol printing.
                    (%update-package-from-form (cst-node-value node))))))))
        (let ((meta (make-hash-table :test #'equal)))
          (setf (gethash "total_forms" meta) total-forms
                (gethash "expanded_forms" meta) expanded
                (gethash "comment_lines" meta) comment-lines
                (gethash "blank_lines" meta) blank-lines
                (gethash "source_lines" meta) source-lines)
          (values display meta))))))

;;;; -------------------------------------------------------------------------
;;;; Raw mode (collapsed=false) -- line slicing
;;;; -------------------------------------------------------------------------

(defun %read-lines-slice (text offset limit)
  "Return two values: sliced text and total line count.
OFFSET is 0-based; LIMIT is the maximum lines to return."
  (let ((lines '())
        (count 0)
        (line-idx 0)
        (hit-limit nil))
    (with-input-from-string (stream text)
      (loop for raw-line = (read-line stream nil :eof)
            until (eq raw-line :eof) do
              (when (>= line-idx offset)
                (when (or (null limit) (< count limit))
                  (push raw-line lines)
                  (incf count))
                (when (and limit (>= count limit))
                  (setf hit-limit t)
                  ;; Consume remaining lines to count total.
                  (loop for rem = (read-line stream nil :eof)
                        until (eq rem :eof)
                        do (incf line-idx))
                  (return)))
              (incf line-idx)))
    (let ((total (if hit-limit
                     (+ offset count (- line-idx offset count))
                     line-idx)))
      (values (format nil "~{~A~%~}" (nreverse lines)) total))))

;;;; -------------------------------------------------------------------------
;;;; Public API
;;;; -------------------------------------------------------------------------

(defun read-file-collapsed (text &key (collapsed t) name-pattern content-pattern
                                   offset limit readtable source-path)
  "Render TEXT as a collapsed view or raw slice.  Returns (values display mode meta).

When COLLAPSED is T and SOURCE-PATH has a Lisp extension:
  Each top-level form is rendered as its signature line.  In-package forms are
  shown in full.  NAME-PATTERN / CONTENT-PATTERN (cl-ppcre) expand matching forms.
  mode is \"lisp-collapsed\" or \"lisp-snippet\" (when a pattern matched).
  meta keys: total_forms, expanded_forms, comment_lines, blank_lines, source_lines.

When COLLAPSED is NIL:
  Lines are sliced by OFFSET (0-based, default 0) and LIMIT (default 500).
  A truncation footer is appended when more lines remain.
  mode is \"raw\".
  meta keys: total_lines, truncated (CL t or nil)."
  (let ((name-scanner
         (when (and name-pattern (stringp name-pattern) (plusp (length name-pattern)))
           (handler-case (create-scanner name-pattern)
             (error (e) (error "Invalid name_pattern regex: ~A" e)))))
        (content-scanner
         (when (and content-pattern (stringp content-pattern)
                    (plusp (length content-pattern)))
           (handler-case (create-scanner content-pattern)
             (error (e) (error "Invalid content_pattern regex: ~A" e))))))
    (cond
      ;; Collapsed Lisp view -- either no source-path or it has a Lisp extension.
      ((and collapsed
            (or (null source-path)
                (and source-path (%lisp-source-p source-path))))
       (multiple-value-bind (display meta)
           (%format-lisp-file text name-scanner content-scanner
                              :readtable readtable
                              :source-path source-path)
         (let ((mode (if (and (or name-scanner content-scanner)
                              (plusp (gethash "expanded_forms" meta 0)))
                         "lisp-snippet"
                         "lisp-collapsed")))
           (values display mode meta))))
      ;; Raw mode -- line slicing.
      ((not collapsed)
       (let* ((eff-offset (or offset 0))
              (eff-limit  (or limit *default-line-limit*)))
         (multiple-value-bind (sliced total)
             (%read-lines-slice text eff-offset eff-limit)
           (let* ((meta       (make-hash-table :test #'equal))
                  (start-line (1+ eff-offset))
                  (end-line   (min (+ eff-offset eff-limit) total))
                  (footer     (when (< end-line total)
                                (format nil
                                        "[Showing lines ~D-~D of ~D. Use offset=~D to read more.]~%"
                                        start-line end-line total end-line)))
                  (eof-msg    (when (and (string= sliced "") (> eff-offset 0))
                                (format nil
                                        "[Offset ~D is past end of file (~D total line~:P).]~%"
                                        eff-offset total)))
                  (content    (cond
                                (footer  (concatenate 'string sliced footer))
                                (eof-msg eof-msg)
                                (t       sliced))))
             (setf (gethash "truncated"   meta) (if footer t nil)
                   (gethash "total_lines" meta) total)
             (values content "raw" meta)))))
      ;; Collapsed but non-Lisp extension: fall through to raw slice.
      (t
       (let* ((eff-offset (or offset 0))
              (eff-limit  (or limit *default-line-limit*)))
         (multiple-value-bind (sliced total)
             (%read-lines-slice text eff-offset eff-limit)
           (let* ((meta     (make-hash-table :test #'equal))
                  (start-line (1+ eff-offset))
                  (end-line   (min (+ eff-offset eff-limit) total))
                  (footer   (when (< end-line total)
                              (format nil
                                      "[Showing lines ~D-~D of ~D. Use offset=~D to read more.]~%"
                                      start-line end-line total end-line)))
                  (content  (if footer
                                (concatenate 'string sliced footer)
                                sliced)))
             (setf (gethash "truncated"   meta) (if footer t nil)
                   (gethash "total_lines" meta) total)
             (values content "raw" meta))))))))
