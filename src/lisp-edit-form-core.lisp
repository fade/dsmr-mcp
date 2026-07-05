;;;; src/lisp-edit-form-core.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Shared form-matching and path-normalization helpers for lisp-edit-form
;;;; and lisp-patch-form.  Contains the common prologue (%locate-target-form)
;;;; and all helpers needed to locate a named top-level form in a file:
;;;; form-type + form-name matching (including defmethod specializers, (setf
;;;; name) form names, and '#:' package-prefix stripping), name[N] 0-indexed
;;;; selection, and path resolution under the session root.
;;;;
;;;; Key adaptation from cl-mcp: %normalize-paths takes SESSION-ROOT as an
;;;; explicit parameter rather than reading a process-global *project-root*.
;;;; This is required for multi-client safety (D-03).
;;;;
;;;; Fresh AGPL write adapting patterns from cl-mcp/src/lisp-edit-form-core.lisp (MIT).

(defpackage #:dsmr-mcp/src/lisp-edit-form-core
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/cst
                #:cst-node
                #:cst-node-kind
                #:cst-node-value
                #:cst-node-start
                #:cst-node-end
                #:parse-top-level-forms)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path)
  (:import-from #:dsmr-mcp/src/fs
                #:read-file-string)
  (:import-from #:dsmr-mcp/src/package-context
                #:extract-in-package-name-from-text)
  (:import-from #:cl-ppcre
                #:scan-to-strings)
  (:import-from #:uiop
                #:ensure-directory-pathname
                #:enough-pathname
                #:native-namestring
                #:subpathp
                #:absolute-pathname-p
                #:merge-pathnames*)
  (:export #:%locate-target-form
           #:%find-target
           #:%definition-candidates
           #:%strip-name-prefix
           #:%normalize-paths
           #:%normalize-string
           #:%strip-hash-colon
           #:%whitespace-char-p))

(in-package #:dsmr-mcp/src/lisp-edit-form-core)

;;;; -------------------------------------------------------------------------
;;;; String normalization helpers
;;;; -------------------------------------------------------------------------

(defun %normalize-string (thing)
  "Normalize THING to a lowercase string for form matching.
Uses SYMBOL-NAME for symbols to strip the package prefix from the output."
  (string-downcase
   (if (symbolp thing)
       (symbol-name thing)
       (princ-to-string thing))))

(defun %whitespace-char-p (ch)
  "Return T when CH is a horizontal or vertical whitespace character."
  (member ch '(#\Space #\Tab #\Newline #\Return)))

(defun %strip-name-prefix (name)
  "Strip reader macro prefixes (#: : \"...\") from NAME for form-name matching.
Handles uninterned symbols (#:foo), keywords (:foo), and string literals (\"foo\")."
  (cond
    ((and (>= (length name) 2) (string= (subseq name 0 2) "#:"))
     (subseq name 2))
    ((and (plusp (length name)) (char= (char name 0) #\:))
     (subseq name 1))
    ((and (>= (length name) 2)
          (char= (char name 0) #\")
          (char= (char name (1- (length name))) #\"))
     (subseq name 1 (1- (length name))))
    (t name)))

(defun %strip-hash-colon (s)
  "Return S with every '#:' reader-macro prefix removed (outside string literals).
This normalizes uninterned symbol prints produced by PRIN1 on symbols from
package-inferred-system sources, so candidate strings and user-supplied
form-name strings compare equal regardless of whether the original source
used interned or uninterned symbols.  Keyword prefixes ':foo' are preserved
so defmethod qualifiers like ':after' still match.

Scans S as a simple state machine tracking string literal boundaries."
  (with-output-to-string (out)
    (let ((len (length s))
          (in-string nil)
          (i 0))
      (loop while (< i len) do
        (let ((c (char s i)))
          (cond
            ;; Escaped character inside a string literal: emit both.
            ((and in-string (char= c #\\) (< (1+ i) len))
             (write-char c out)
             (write-char (char s (1+ i)) out)
             (incf i 2))
            ;; String delimiter: toggle and pass through.
            ((char= c #\")
             (write-char c out)
             (setf in-string (not in-string))
             (incf i))
            ;; '#:' outside string: drop both characters.
            ((and (not in-string)
                  (char= c #\#)
                  (< (1+ i) len)
                  (char= (char s (1+ i)) #\:))
             (incf i 2))
            ;; Everything else: pass through.
            (t
             (write-char c out)
             (incf i))))))))

;;;; -------------------------------------------------------------------------
;;;; Form-type candidate matching
;;;; -------------------------------------------------------------------------

(defun %defmethod-candidates (form)
  "Return candidate signature strings for a DEFMETHOD FORM.
Candidates are generated in order of increasing specificity:
  1. name only: \"resize\"
  2. name + qualifier: \"resize :after\"
  3. name + lambda-list: \"resize ((s shape) factor)\"
  4. name + qualifier + lambda-list: \"resize :after ((s shape) factor)\"

Every candidate is passed through %strip-hash-colon so that lambda-list
prints from package-inferred-system sources (uninterned symbols as '#:foo')
compare equal to user inputs written without the '#:' prefix."
  (destructuring-bind (_ name &rest rest) form
    (declare (ignore _))
    (let ((qualifiers nil) (lambda-list nil))
      (dolist (part rest)
        (when (listp part) (setf lambda-list part) (return))
        (push part qualifiers))
      (let ((name-str (%normalize-string name))
            (lambda-str
              (and lambda-list
                   (%strip-hash-colon
                    (%normalize-string
                     (with-output-to-string (s) (prin1 lambda-list s))))))
            (qual-str
              (and qualifiers
                   (%strip-hash-colon
                    (%normalize-string
                     (format nil "~{~S~^ ~}" (nreverse qualifiers)))))))
        (remove nil
                (list name-str
                      (and qual-str (format nil "~A ~A" name-str qual-str))
                      (and lambda-str (format nil "~A ~A" name-str lambda-str))
                      (and qual-str lambda-str
                           (format nil "~A ~A ~A" name-str qual-str lambda-str))))))))

(defun %definition-candidates (form form-type)
  "Return candidate strings that identify FORM with FORM-TYPE.
Handles the common cases: defmethod (specializers + qualifiers), defstruct
with option lists, (setf name) form names, and compound name specs such as
the (\"c-name\" lisp-name) shape used by sb-alien:define-alien-routine and
sibling def-forms — for those, every symbol in the name spec becomes a
candidate so the Lisp-side name is matchable."
  (let ((name (second form)))
    (cond
      ((string= form-type "defmethod")
       (%defmethod-candidates form))
      ;; defstruct: (defstruct (name &rest options) ...) — use just the name.
      ((and (string= form-type "defstruct")
            (listp name) (symbolp (car name)))
       (list (%normalize-string (car name))))
      ((symbolp name)
       (list (%normalize-string name)))
      ;; (setf name) form names.
      ((and (consp name)
            (= (length name) 2)
            (symbolp (car name))
            (string= (symbol-name (car name)) "SETF"))
       (list (%normalize-string (second name))
             (format nil "(setf ~A)" (%normalize-string (second name)))))
      ;; General compound name spec, e.g. ("sendmsg" %scm-sendmsg) from
      ;; sb-alien:define-alien-routine / define-alien-variable. Pull out every
      ;; symbol (ignoring C-name strings and other atoms) so the Lisp-side name
      ;; can match.
      ((consp name)
       (let ((syms nil))
         (labels ((walk (x)
                    (cond ((and x (symbolp x)) (push x syms))
                          ((consp x) (walk (car x)) (walk (cdr x))))))
           (walk name))
         (mapcar #'%normalize-string (nreverse syms))))
      (t (list (%normalize-string name))))))

;;;; -------------------------------------------------------------------------
;;;; Target form search
;;;; -------------------------------------------------------------------------

(defun %find-target (nodes form-type form-name)
  "Find a target CST node matching FORM-TYPE and FORM-NAME in NODES.

If FORM-NAME ends with [N] (e.g., 'resize[1]'), select the Nth match (0-indexed).
If multiple matches exist without an index, signals an error with candidate info.
Returns a single CST node, or NIL when no match is found."
  (multiple-value-bind (base-name index)
      (let ((match (nth-value 1 (scan-to-strings "^(.+?)\\[(\\d+)\\]$" form-name))))
        (if match
            (values (aref match 0) (parse-integer (aref match 1)))
            (values form-name nil)))
    (let ((target (%strip-hash-colon
                   (string-downcase (%strip-name-prefix base-name))))
          (matches nil))
      (when (zerop (length target))
        (error "form_name resolved to empty string after prefix stripping; ~
provide a non-empty name (e.g. \"my-pkg\" instead of \"#:\" alone)"))
      (loop for node in nodes
            when (and (typep node 'cst-node)
                      (eq (cst-node-kind node) :expr))
              do (let ((value (cst-node-value node)))
                   (when (and (consp value)
                              (symbolp (car value))
                              (string= (string-downcase (symbol-name (car value)))
                                       form-type)
                              (some (lambda (cand) (string= cand target))
                                    (%definition-candidates value form-type)))
                     (push node matches))))
      (setf matches (nreverse matches))
      (cond
        ((null matches)
         nil)
        ((and index (< index (length matches)))
         (nth index matches))
        (index
         (error "Index [~D] out of range; only ~D match~:P found for ~A ~A"
                index (length matches) form-type form-name))
        ((= (length matches) 1)
         (first matches))
        (t
         ;; Multiple matches without index — provide selection guidance.
         (let ((descriptions
                 (loop for node in matches
                       for i from 0
                       collect (let* ((form (cst-node-value node))
                                      (cands (%definition-candidates form form-type)))
                                 (format nil "[~D] ~A" i
                                         (or (car (last cands)) (first cands)))))))
           (error "Multiple matches for ~A ~A. Specify an index:~%~{  ~A~%~}"
                  form-type form-name descriptions)))))))

;;;; -------------------------------------------------------------------------
;;;; Path normalization
;;;; -------------------------------------------------------------------------

(defun %normalize-paths (file-path session-root)
  "Return two values: absolute pathname and project-relative namestring.
SESSION-ROOT is the current session's project root (D-03: explicit parameter,
not a global).  Signals when FILE-PATH cannot be resolved under SESSION-ROOT.

Note: the relative namestring is used for writes (so the write jail in
ensure-write-path sees a path relative to the session root)."
  (let* ((pn (if (uiop:absolute-pathname-p file-path)
                 (uiop:ensure-pathname file-path)
                 (uiop:merge-pathnames* file-path session-root)))
         (resolved (or (handler-case (truename pn) (file-error () nil)) pn))
         (root-dir (uiop:ensure-directory-pathname session-root))
         (rel (uiop:enough-pathname resolved root-dir))
         (rel-namestring (uiop:native-namestring rel)))
    (values resolved rel-namestring)))

;;;; -------------------------------------------------------------------------
;;;; Shared prologue
;;;; -------------------------------------------------------------------------

(defun %locate-target-form (file-path form-type form-name readtable session-root)
  "Shared prologue for lisp-edit-form and lisp-patch-form.

Reads FILE-PATH (checking that it is allowed under SESSION-ROOT), parses it
into CST nodes, locates the target form matching FORM-TYPE and FORM-NAME, and
returns the matched node together with the file text and related data.

Returns seven values:
  ABS          -- absolute pathname of the file
  REL          -- project-relative namestring (for writes via ensure-write-path)
  ORIGINAL     -- full file text string
  NODES        -- list of parsed CST nodes in source order
  TARGET       -- matched CST node
  TARGET-SNIPPET -- text of the matched form (subseq of ORIGINAL)
  FILE-PACKAGE-NAME -- package name named by the file's first IN-PACKAGE form"
  (let ((form-type-str (string-downcase form-type)))
    (multiple-value-bind (abs rel)
        (%normalize-paths file-path session-root)
      (let* ((pn (allowed-read-path (namestring abs) session-root)))
        (unless pn
          (error "~A is outside the read allow-list (root: ~A)"
                 file-path session-root))
        (multiple-value-bind (original) (read-file-string pn)
          (let* ((nodes (parse-top-level-forms original
                                               :readtable readtable
                                               :source-path pn))
                 (target (%find-target nodes form-type-str form-name)))
            (unless target
              (error "Form ~A ~A not found in ~A"
                     form-type form-name (namestring pn)))
            (let ((target-snippet (subseq original
                                          (cst-node-start target)
                                          (cst-node-end target)))
                  (file-package-name (extract-in-package-name-from-text original)))
              (values pn rel original nodes target target-snippet
                      file-package-name))))))))
