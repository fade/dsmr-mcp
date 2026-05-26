;;;; src/clgrep.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Lisp-aware, image-independent semantic grep (VERB-08).
;;;;
;;;; Three modes:
;;;;   1. Regex fast path (default, D-09): cl-ppcre regex over source text,
;;;;      each hit reported with file:line + enclosing top-level form signature.
;;;;   2. Structural mode (D-11, opt-in via form_pattern): matches a bounded
;;;;      form-shape pattern (_, ?name, ...) against each top-level form's
;;;;      parsed CST node. No full unification, no predicate guards.
;;;;
;;;; File discovery (D-10): walks .lisp/.asd/.cl/.lsp/.ros under the search
;;;; root, skips hidden files and build artifacts, and honors .gitignore.
;;;; .ros (Roswell scripts) is a blessed Lisp source extension per D-10.
;;;;
;;;; Sandbox: every file read goes through allowed-read-path (D-16, SAFETY-02).
;;;; Per-file errors log a warning and are skipped, never aborting the walk
;;;; (Pitfall 8: one unreadable file must not abort the entire search run).
;;;;
;;;; Deduplication: regex results are grouped by (file . form-start-byte).
;;;; Multiple pattern hits inside the same form produce one result with a
;;;; match_lines array listing each (line, match) pair.
;;;;
;;;; Fresh AGPL write adapting algorithms from cl-mcp/src/utils/clgrep.lisp (MIT).

(defpackage #:dsmr-mcp/src/clgrep
  (:use #:cl)
  (:import-from #:cl-ppcre
                #:create-scanner
                #:scan
                #:scan-to-strings
                #:all-matches-as-strings)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path)
  (:import-from #:dsmr-mcp/src/cst
                #:parse-top-level-forms
                #:cst-node-kind
                #:cst-node-value
                #:cst-node-start
                #:cst-node-end
                #:cst-node-start-line
                #:cst-node-end-line)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:semantic-grep
           #:collect-target-files
           #:match-form-pattern))

(in-package #:dsmr-mcp/src/clgrep)

;;;; -------------------------------------------------------------------------
;;;; File discovery (D-10)
;;;; -------------------------------------------------------------------------

(defparameter *lisp-extensions*
  '("lisp" "asd" "cl" "lsp" "ros")
  "Lisp source file extensions discovered by collect-target-files (D-10).
.ros (Roswell scripts) is explicitly blessed per the updated D-10.")

(defparameter *build-artifact-extensions*
  '("fasl" "ufasl" "x86f" "cfasl" "dx32fsl" "dx64fsl" "lx32fsl" "lx64fsl")
  "Extensions that identify build artifacts — excluded from the walk.")

(defun %target-file-p (pathname)
  "Return T when PATHNAME has a Lisp source extension (case-insensitive)."
  (let ((type (pathname-type pathname)))
    (and type
         (member (string-downcase type) *lisp-extensions* :test #'string=))))

(defun %hidden-or-artifact-p (pathname)
  "Return T when PATHNAME should be excluded as hidden or a build artifact.
Hidden: any component whose name starts with dot.
Artifacts: any component with a known build-artifact extension."
  (let ((name (pathname-name pathname))
        (type (pathname-type pathname)))
    (or
     ;; Hidden file: name starts with dot
     (and name (plusp (length name)) (char= (char name 0) #\.))
     ;; Build artifact by extension
     (and type (member (string-downcase type) *build-artifact-extensions*
                       :test #'string=)))))

(defun glob-to-regex (pattern)
  "Convert a gitignore glob PATTERN to a regular expression string.
Handles *, ?, **, and basic glob syntax."
  (let ((result (make-array 0 :element-type 'character :fill-pointer 0 :adjustable t))
        (i 0)
        (len (length pattern)))
    ;; Anchor to start if pattern starts with /
    (when (and (> len 0) (char= (char pattern 0) #\/))
      (vector-push-extend #\^ result)
      (incf i))
    (loop while (< i len)
          do (let ((char (char pattern i)))
               (cond
                 ;; Handle **/ for matching any directory depth
                 ((and (< (+ i 2) len)
                       (char= char #\*)
                       (char= (char pattern (+ i 1)) #\*)
                       (char= (char pattern (+ i 2)) #\/))
                  (loop for c across "(?:.*/|)" do (vector-push-extend c result))
                  (incf i 3))
                 ;; Handle /** at end for matching directory and contents
                 ((and (< (+ i 1) len)
                       (char= char #\*)
                       (char= (char pattern (+ i 1)) #\*)
                       (= (+ i 2) len))
                  (loop for c across ".*" do (vector-push-extend c result))
                  (incf i 2))
                 ;; Handle single * (match anything except /)
                 ((char= char #\*)
                  (loop for c across "[^/]*" do (vector-push-extend c result))
                  (incf i))
                 ;; Handle ? (match single char except /)
                 ((char= char #\?)
                  (loop for c across "[^/]" do (vector-push-extend c result))
                  (incf i))
                 ;; Escape special regex characters
                 ((find char ".+^$(){}[]|\\")
                  (vector-push-extend #\\ result)
                  (vector-push-extend char result)
                  (incf i))
                 ;; Regular characters
                 (t
                  (vector-push-extend char result)
                  (incf i)))))
    ;; If pattern ends with /, match directory and its contents
    (when (and (> len 0) (char= (char pattern (1- len)) #\/))
      (loop for c across ".*" do (vector-push-extend c result)))
    result))

(defun %parse-gitignore (gitignore-path)
  "Parse a .gitignore file and return a list of regex pattern strings.
Returns NIL if the file doesn't exist or can't be read."
  (handler-case
      (when (probe-file gitignore-path)
        (with-open-file (stream gitignore-path :direction :input)
          (loop for line = (read-line stream nil nil)
                while line
                for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
                unless (or (zerop (length trimmed))
                           (char= (char trimmed 0) #\#))
                collect (glob-to-regex trimmed))))
    (error () nil)))

(defun path-ignored-p (path root-dir ignore-patterns)
  "Return T when PATH matches any of the IGNORE-PATTERNS.
PATH is made relative to ROOT-DIR for matching."
  (let* ((relative (enough-namestring path root-dir))
         (normalized (substitute #\/ #\\ relative)))
    (dolist (pattern ignore-patterns nil)
      (when (scan pattern normalized)
        (return t)))))

(defun collect-target-files (root &key (recursive t))
  "Collect Lisp source files (.lisp/.asd/.cl/.lsp/.ros) from ROOT.
When ROOT is a single file, return it in a list if it's a target file.
When RECURSIVE is true (default), search subdirectories recursively.
Respects .gitignore patterns; .git/ and hidden files are always excluded."
  (let ((root-path (handler-case (truename root)
                     (file-error () (uiop:ensure-pathname root)))))
    ;; Single-file case
    (when (uiop:file-pathname-p root-path)
      (return-from collect-target-files
        (when (%target-file-p root-path) (list root-path))))
    ;; Directory case
    (let* ((root-dir (uiop:ensure-directory-pathname root-path))
           (gitignore-path (merge-pathnames ".gitignore" root-dir))
           (ignore-patterns (%parse-gitignore gitignore-path))
           ;; .git/ is always excluded
           (all-patterns (cons (glob-to-regex ".git/") ignore-patterns))
           (result nil))
      (labels ((collect-from-dir (dir)
                 ;; Skip directories that are hidden or ignored
                 (unless (path-ignored-p dir root-dir all-patterns)
                   (dolist (entry (uiop:directory* (merge-pathnames uiop:*wild-file* dir)))
                     (unless (or (%hidden-or-artifact-p entry)
                                 (path-ignored-p entry root-dir all-patterns))
                       (when (%target-file-p entry)
                         (push entry result))))
                   (when recursive
                     (dolist (subdir (uiop:subdirectories dir))
                       ;; Skip hidden subdirectories (e.g. .git/)
                       (let ((subname (car (last (pathname-directory subdir)))))
                         (unless (and (stringp subname)
                                      (plusp (length subname))
                                      (char= (char subname 0) #\.))
                           (collect-from-dir subdir))))))))
        (collect-from-dir root-dir))
      (nreverse result))))

;;;; -------------------------------------------------------------------------
;;;; Per-file form scanning (independent state machine, no Eclector)
;;;; -------------------------------------------------------------------------

(defstruct %toplevel-form
  "Byte-range and line-range for a top-level form."
  (start-pos 0 :type fixnum)
  (end-pos 0 :type fixnum)
  (start-line 1 :type fixnum)
  (end-line 1 :type fixnum))

(defun %scan-toplevel-forms (content)
  "Scan CONTENT and return a list of %toplevel-form structs.
Independent paren-balancing state machine that correctly handles strings,
line comments, block comments, and character literals.  Does NOT use
Eclector — this is the image-independent fast path."
  (let ((forms nil)
        (state :normal)
        (paren-depth 0)
        (block-comment-depth 0)
        (current-line 1)
        (form-start-pos nil)
        (form-start-line nil)
        (pos 0)
        (len (length content)))
    (loop while (< pos len)
          for char = (char content pos)
          do (case state
               (:normal
                (cond
                  ;; Character literal #\x — consume two more chars
                  ((and (char= char #\#)
                        (< (1+ pos) len)
                        (char= (char content (1+ pos)) #\\))
                   (incf pos 2)
                   (when (< pos len)
                     (when (char= (char content pos) #\Newline)
                       (incf current-line))
                     (incf pos))
                   (decf pos))
                  ;; String start
                  ((char= char #\") (setf state :string))
                  ;; Line comment
                  ((char= char #\;) (setf state :comment))
                  ;; Block comment start #|
                  ((and (char= char #\#)
                        (< (1+ pos) len)
                        (char= (char content (1+ pos)) #\|))
                   (setf state :block-comment block-comment-depth 1)
                   (incf pos))
                  ;; Open paren
                  ((char= char #\()
                   (when (zerop paren-depth)
                     (setf form-start-pos pos form-start-line current-line))
                   (incf paren-depth))
                  ;; Close paren
                  ((char= char #\))
                   (when (plusp paren-depth)
                     (decf paren-depth)
                     (when (zerop paren-depth)
                       (push (make-%toplevel-form
                              :start-pos form-start-pos
                              :end-pos (1+ pos)
                              :start-line form-start-line
                              :end-line current-line)
                             forms)
                       (setf form-start-pos nil form-start-line nil))))))
               (:string
                (cond
                  ((char= char #\\) (setf state :escape))
                  ((char= char #\") (setf state :normal))))
               (:escape (setf state :string))
               (:comment
                (when (char= char #\Newline) (setf state :normal)))
               (:block-comment
                (cond
                  ;; Nested block comment start #|
                  ((and (char= char #\#)
                        (< (1+ pos) len)
                        (char= (char content (1+ pos)) #\|))
                   (incf block-comment-depth)
                   (incf pos))
                  ;; Block comment end |#
                  ((and (char= char #\|)
                        (< (1+ pos) len)
                        (char= (char content (1+ pos)) #\#))
                   (decf block-comment-depth)
                   (when (zerop block-comment-depth)
                     (setf state :normal))
                   (incf pos)))))
             (when (char= char #\Newline)
               (incf current-line))
             (incf pos))
    (nreverse forms)))

;;;; -------------------------------------------------------------------------
;;;; Form type/name/signature extraction
;;;; -------------------------------------------------------------------------

(defparameter *known-form-types*
  '("defun" "defmethod" "defgeneric" "defmacro" "define-compiler-macro"
    "defvar" "defparameter" "defconstant"
    "defclass" "defstruct" "deftype" "define-condition"
    "defpackage" "in-package"
    "defsystem" "deftest" "define-test")
  "Form type keywords recognised by the signature extractor.")

(defun %extract-form-type-and-name (form-text)
  "Extract the form type and name from FORM-TEXT.
Returns (values type-string name-string) or (values nil nil)."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline) form-text)))
    (when (and (plusp (length trimmed)) (char= (char trimmed 0) #\())
      (multiple-value-bind (match groups)
          (scan-to-strings
           "^\\(\\s*([a-zA-Z][a-zA-Z0-9*_+.-]*)\\s+([^\\s()]+|\\([^)]+\\))"
           trimmed)
        (when match
          (let ((form-type (string-downcase (aref groups 0)))
                (form-name (aref groups 1)))
            (when (member form-type *known-form-types* :test #'string=)
              (values form-type form-name))))))))

(defun %extract-balanced-sexp (text start)
  "Extract a balanced S-expression starting at position START in TEXT.
Returns (values sexp-string end-pos) or (values nil nil)."
  (when (and (< start (length text)) (char= (char text start) #\())
    (let ((depth 1) (pos (1+ start)) (len (length text)) (state :normal))
      (loop while (and (< pos len) (plusp depth))
            for char = (char text pos)
            do (case state
                 (:normal
                  (cond ((char= char #\() (incf depth))
                        ((char= char #\)) (decf depth))
                        ((char= char #\") (setf state :string))
                        ((char= char #\;) (setf state :comment))
                        ((char= char #\\) (incf pos))))
                 (:string
                  (cond ((char= char #\\) (incf pos))
                        ((char= char #\") (setf state :normal))))
                 (:comment
                  (when (char= char #\Newline) (setf state :normal))))
               (incf pos))
      (when (zerop depth)
        (values (subseq text start pos) pos)))))

(defun %extract-form-signature (form-text)
  "Extract a collapsed signature from FORM-TEXT for display.
Returns a string or NIL."
  (multiple-value-bind (form-type form-name)
      (%extract-form-type-and-name form-text)
    (when (and form-type form-name)
      (cond
        ;; Lambda-list forms: show (name args)
        ((member form-type '("defun" "defmacro" "defgeneric" "defmethod"
                             "define-compiler-macro" "deftest" "define-test")
                 :test #'string=)
         (let* ((trimmed (string-trim '(#\Space #\Tab #\Newline) form-text))
                (name-pat (format nil "^\\(\\s*~A\\s+~A\\s*"
                                  (cl-ppcre:quote-meta-chars form-type)
                                  (cl-ppcre:quote-meta-chars form-name)))
                (name-end (nth-value 1 (scan name-pat trimmed))))
           (when name-end
             (multiple-value-bind (lambda-list _end)
                 (%extract-balanced-sexp trimmed name-end)
               (declare (ignore _end))
               (if lambda-list
                   (let ((params (string-trim '(#\Space #\Tab #\Newline)
                                              (subseq lambda-list 1 (1- (length lambda-list))))))
                     (if (zerop (length params))
                         (format nil "(~A)" form-name)
                         (format nil "(~A ~A)" form-name params)))
                   form-name)))))
        ;; Variable definitions
        ((member form-type '("defvar" "defparameter" "defconstant") :test #'string=)
         form-name)
        ;; Class: name + superclasses
        ((string= form-type "defclass")
         (let* ((trimmed (string-trim '(#\Space #\Tab #\Newline) form-text))
                (name-pat (format nil "^\\(\\s*defclass\\s+~A\\s*"
                                  (cl-ppcre:quote-meta-chars form-name)))
                (name-end (nth-value 1 (scan name-pat trimmed))))
           (when name-end
             (multiple-value-bind (supers _end)
                 (%extract-balanced-sexp trimmed name-end)
               (declare (ignore _end))
               (if supers
                   (let ((s (string-trim '(#\Space #\Tab #\Newline)
                                         (subseq supers 1 (1- (length supers))))))
                     (if (zerop (length s)) form-name
                         (format nil "(~A ~A)" form-name s)))
                   form-name)))))
        ;; Struct: just name
        ((string= form-type "defstruct") form-name)
        ;; Others: name only
        (t form-name)))))

;;;; -------------------------------------------------------------------------
;;;; Package map (fast in-package tracking)
;;;; -------------------------------------------------------------------------

(defun %build-package-map (content)
  "Build a sorted alist of (line-number . package-name) from in-package forms.
Pre-computes the package context for the entire file in a single pass."
  (let ((map nil) (current-line 1))
    (with-input-from-string (stream content)
      (loop for line = (read-line stream nil nil)
            while line
            do (let ((trimmed (string-trim '(#\Space #\Tab) line)))
                 (unless (and (plusp (length trimmed)) (char= (char trimmed 0) #\;))
                   (multiple-value-bind (match groups)
                       (scan-to-strings
                        "^\\(in-package\\s+[:#]?['\"]?([^)\\s'\"]+)" trimmed)
                     (when match
                       (push (cons current-line
                                   (string-upcase
                                    (string-left-trim ":#" (aref groups 0))))
                             map)))))
               (incf current-line)))
    (nreverse map)))

(defun %find-package-for-line (package-map line-number)
  "Find the active package at LINE-NUMBER using the pre-built PACKAGE-MAP."
  (let ((result nil))
    (dolist (entry package-map)
      (if (<= (car entry) line-number)
          (setf result (cdr entry))
          (return)))
    result))

;;;; -------------------------------------------------------------------------
;;;; Per-file regex search
;;;; -------------------------------------------------------------------------

(defun %search-file-regex (filepath content scanner form-types include-form)
  "Scan CONTENT (from FILEPATH) for regex SCANNER hits.
Returns a list of match alists."
  (let ((results nil)
        (forms-cache (%scan-toplevel-forms content))
        (package-map (%build-package-map content)))
    (with-input-from-string (stream content)
      (loop for line = (read-line stream nil nil)
            for line-number from 1
            while line
            when (scan scanner line)
            do (let* ((package (%find-package-for-line package-map line-number))
                      ;; Find enclosing form
                      (form-info
                       (dolist (form forms-cache nil)
                         (when (and (>= line-number (%toplevel-form-start-line form))
                                    (<= line-number (%toplevel-form-end-line form)))
                           (return form)))))
                 (let* ((full-form-text
                         (when form-info
                           (subseq content
                                   (%toplevel-form-start-pos form-info)
                                   (%toplevel-form-end-pos form-info))))
                        (form-type nil) (form-name nil) (signature nil))
                   (when full-form-text
                     (multiple-value-bind (ft fn)
                         (%extract-form-type-and-name full-form-text)
                       (setf form-type ft form-name fn))
                     (setf signature (%extract-form-signature full-form-text)))
                   ;; Apply form_types filter
                   (when (or (null form-types)
                             (and form-type
                                  (member form-type form-types :test #'string-equal)))
                     (let ((entry (list (cons :file (namestring filepath))
                                        (cons :line line-number)
                                        (cons :match line)
                                        (cons :package (or package "UNKNOWN"))
                                        (cons :form-type form-type)
                                        (cons :form-name form-name)
                                        (cons :signature signature)
                                        (cons :form-start-line
                                              (when form-info
                                                (%toplevel-form-start-line form-info)))
                                        (cons :form-end-line
                                              (when form-info
                                                (%toplevel-form-end-line form-info)))
                                        (cons :form-start-byte
                                              (when form-info
                                                (%toplevel-form-start-pos form-info)))
                                        (cons :form-end-byte
                                              (when form-info
                                                (%toplevel-form-end-pos form-info))))))
                       (when (and include-form full-form-text)
                         (setf entry (append entry (list (cons :form full-form-text)))))
                       (push entry results)))))))
    (nreverse results)))

;;;; -------------------------------------------------------------------------
;;;; Structural mode (D-11): form_pattern matching
;;;; -------------------------------------------------------------------------

(defun %parse-form-pattern (str)
  "Parse a form_pattern string into a list of pattern nodes.
Pattern nodes:
  :wildcard-one          -- _ matches any single form
  (:capture name-string) -- ?name captures a single form
  :wildcard-tail         -- ... matches zero or more remaining forms
  (:atom atom-string)    -- literal atom (symbol/string) match
  (:list . child-nodes)  -- parenthesized list of child pattern nodes"
  (let ((pos 0) (len (length str)))
    (labels
        ((skip-ws ()
           (loop while (and (< pos len)
                            (member (char str pos) '(#\Space #\Tab #\Newline #\Return)))
                 do (incf pos)))
         (read-atom-str ()
           (let ((start pos))
             (loop while (and (< pos len)
                              (not (member (char str pos)
                                           '(#\Space #\Tab #\Newline #\Return
                                             #\( #\)))))
                   do (incf pos))
             (subseq str start pos)))
         (parse-element ()
           (skip-ws)
           (when (>= pos len) (return-from parse-element nil))
           (let ((ch (char str pos)))
             (cond
               ((char= ch #\()
                (incf pos)
                (let ((elems '()))
                  (loop
                    (skip-ws)
                    (when (>= pos len) (error "Unterminated pattern list in ~S" str))
                    (when (char= (char str pos) #\))
                      (incf pos)
                      (return))
                    (let ((e (parse-element)))
                      (when e (push e elems))))
                  (list* :list (nreverse elems))))
               ((char= ch #\))
                nil)
               (t
                (let ((atom (read-atom-str)))
                  (cond
                    ((string= atom "_") :wildcard-one)
                    ((string= atom "...") :wildcard-tail)
                    ((and (plusp (length atom)) (char= (char atom 0) #\?))
                     (list :capture (subseq atom 1)))
                    (t (list :atom atom))))))))
         (parse-top ()
           (let ((elems '()))
             (loop (skip-ws)
                   (when (>= pos len) (return))
                   (let ((e (parse-element)))
                     (when e (push e elems))))
             (nreverse elems))))
      (parse-top))))

(defun %match-pattern-node (node value captures)
  "Match a single pattern NODE against VALUE.
Returns (values matched-p captures-alist) — captures-alist accumulates
?name -> value bindings."
  (etypecase node
    (keyword
     (ecase node
       (:wildcard-one (values t captures))
       (:wildcard-tail (error "wildcard-tail in scalar match position"))))
    (cons
     (ecase (car node)
       (:atom
        (let ((atom-str (string-downcase (cadr node))))
          (let ((val-str (cond ((symbolp value) (string-downcase (symbol-name value)))
                               ((stringp value) (string-downcase value))
                               (t nil))))
            (if (and val-str (string= atom-str val-str))
                (values t captures)
                (values nil nil)))))
       (:capture
        (values t (acons (cadr node) value captures)))
       (:list
        (unless (listp value)
          (return-from %match-pattern-node (values nil nil)))
        (%match-elements (cdr node) value captures))))))

(defun %match-elements (pattern-nodes values captures)
  "Match PATTERN-NODES against VALUES (list of Lisp values).
Returns (values matched-p captures-alist)."
  (loop
    (cond
      ((and (null pattern-nodes) (null values))
       (return (values t captures)))
      ((null pattern-nodes)
       (return (values nil nil)))
      ;; wildcard-tail: matches the rest
      ((eq (car pattern-nodes) :wildcard-tail)
       (return (values t captures)))
      ((null values)
       (return (values nil nil)))
      (t
       (multiple-value-bind (ok new-caps)
           (%match-pattern-node (car pattern-nodes) (car values) captures)
         (unless ok (return (values nil nil)))
         (setf pattern-nodes (cdr pattern-nodes)
               values (cdr values)
               captures new-caps))))))

(defun match-form-pattern (pattern-tree cst-node)
  "Test whether PATTERN-TREE matches the Lisp value in CST-NODE.
PATTERN-TREE is a list of pattern nodes as returned by %parse-form-pattern.
CST-NODE is a cst-node from parse-top-level-forms (dsmr-mcp/src/cst).

Returns (values matched-p captures-alist).
Only :EXPR nodes are tested; :SKIPPED nodes never match.

Wildcards:
  _      matches any single form (no capture)
  ?name  captures a single form under NAME
  ...    matches zero or more remaining forms (any tail)

No full unification, no predicate guards (D-11 bounded)."
  (unless (eq (cst-node-kind cst-node) :expr)
    (return-from match-form-pattern (values nil nil)))
  (unless (= 1 (length pattern-tree))
    ;; pattern_tree should be a single top-level pattern node (a list pattern)
    (return-from match-form-pattern (values nil nil)))
  (let ((pnode (car pattern-tree))
        (value (cst-node-value cst-node)))
    ;; Top-level pattern must be a :list node matching against a list value
    (unless (and (consp pnode) (eq (car pnode) :list))
      (return-from match-form-pattern (values nil nil)))
    (unless (listp value)
      (return-from match-form-pattern (values nil nil)))
    (%match-elements (cdr pnode) value nil)))

(defun %search-file-structural (filepath content pattern-tree form-types include-form
                                 session-root)
  "Scan CONTENT (from FILEPATH) for structural pattern matches.
Uses parse-top-level-forms (Eclector CST) to parse top-level forms, then
tests each :EXPR form against PATTERN-TREE via match-form-pattern."
  (let ((nodes (handler-case
                   (parse-top-level-forms content :source-path filepath)
                 (error (e)
                   (log-event :warn "clgrep.structural.parse-error"
                              "file" (namestring filepath)
                              "error" (princ-to-string e))
                   nil)))
        (results nil))
    (dolist (node nodes)
      (when (eq (cst-node-kind node) :expr)
        (multiple-value-bind (ok captures)
            (match-form-pattern pattern-tree node)
          (declare (ignore captures))
          (when ok
          (let* ((full-form-text (subseq content (cst-node-start node) (cst-node-end node)))
                 (form-type nil) (form-name nil) (signature nil))
            (multiple-value-bind (ft fn)
                (%extract-form-type-and-name full-form-text)
              (setf form-type ft form-name fn))
            (setf signature (%extract-form-signature full-form-text))
            ;; Apply form_types filter
            (when (or (null form-types)
                      (and form-type
                           (member form-type form-types :test #'string-equal)))
              (let ((entry (list (cons :file (namestring filepath))
                                  (cons :line (cst-node-start-line node))
                                  (cons :match (format nil "(structural match: ~A)" signature))
                                  (cons :package "UNKNOWN")
                                  (cons :form-type form-type)
                                  (cons :form-name form-name)
                                  (cons :signature signature)
                                  (cons :form-start-line (cst-node-start-line node))
                                  (cons :form-end-line (cst-node-end-line node))
                                  (cons :form-start-byte (cst-node-start node))
                                  (cons :form-end-byte (cst-node-end node))
                                  ;; Match_lines for structural: one entry per form
                                  (cons :match-lines
                                        (list (list (cons :line (cst-node-start-line node))
                                                    (cons :match signature)))))))
                (when (and include-form full-form-text)
                  (setf entry (append entry (list (cons :form full-form-text)))))
                (push entry results))))))))
    (nreverse results)))

;;;; -------------------------------------------------------------------------
;;;; Main entry point: semantic-grep
;;;; -------------------------------------------------------------------------

(defun semantic-grep (root pattern
                      &key (recursive t) case-insensitive form-types (include-form nil)
                           limit form-pattern session-root)
  "Search for PATTERN across all Lisp files in ROOT.

Keyword arguments:
  RECURSIVE        -- walk subdirectories recursively (default: T)
  CASE-INSENSITIVE -- cl-ppcre case-insensitive mode (default: nil)
  FORM-TYPES       -- list of form-type strings to filter (default: all)
  INCLUDE-FORM     -- include full form text in results (default: nil)
  LIMIT            -- max results to return (nil = unlimited)
  FORM-PATTERN     -- optional form-shape pattern string (D-11 structural mode)
  SESSION-ROOT     -- session project root for allowed-read-path checks (SAFETY-02)

Returns (values results limited-p) where RESULTS is a list of alists and
LIMITED-P is T when the result set was truncated by LIMIT."
  ;; Validate / compile the regex pattern up-front (fast-path only)
  (let ((scanner (when (null form-pattern)
                   (handler-case
                       (create-scanner pattern
                                       :case-insensitive-mode case-insensitive)
                     (cl-ppcre:ppcre-syntax-error (e)
                       (error "Invalid regex pattern ~S: ~A" pattern e)))))
        (pattern-tree (when form-pattern
                        (handler-case (%parse-form-pattern form-pattern)
                          (error (e)
                            (error "Invalid form_pattern ~S: ~A" form-pattern e)))))
        (files (collect-target-files root :recursive recursive))
        (all-results nil)
        (count 0)
        (limited nil))
    (block walk
      (dolist (file files)
        (when (and limit (>= count limit))
          (setf limited t)
          (return-from walk))
        ;; Sandbox check: only read files in the allow-list (SAFETY-02)
        (let ((allowed-pn (if session-root
                              (allowed-read-path file session-root)
                              file)))
          (when allowed-pn
            ;; Per-file guard (Pitfall 8): one bad file must not abort the walk
            (handler-case
                (let* ((content (uiop/stream:read-file-string allowed-pn))
                       (file-results
                        (if form-pattern
                            ;; Structural mode (D-11): parse CST and match pattern
                            (%search-file-structural allowed-pn content pattern-tree
                                                     form-types include-form session-root)
                            ;; Regex fast path (D-09)
                            (%search-file-regex allowed-pn content scanner
                                                form-types include-form))))
                  (dolist (r file-results)
                    (when (and limit (>= count limit))
                      (setf limited t)
                      (return-from walk))
                    (push r all-results)
                    (incf count)))
              (error (e)
                (log-event :warn "clgrep.file-error"
                           "file" (namestring file)
                           "error" (princ-to-string e)))))
          (unless allowed-pn
            (log-event :warn "clgrep.sandbox-skip"
                       "file" (namestring file))))))
    (values (nreverse all-results) limited)))
