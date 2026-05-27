;;;; src/code-core.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Shared sb-introspect engine backing code-find (VERB-13), code-describe
;;;; (VERB-14), and code-find-references (VERB-15) across both the attached
;;;; injection path and the hermetic worker path.
;;;;
;;;; Design: one codepath / result shape for location and xref queries
;;;; regardless of whether the caller is the dispatcher (injecting a form into
;;;; the attached image) or the worker handler (running in-process). The
;;;; attached path for code-describe delegates to Slynk instead — see
;;;; %build-code-describe-form below.
;;;;
;;;; Typed not-found markers: the engine never signals raw errors for
;;;; missing packages or symbols; it returns keyword-tagged plists with an
;;;; actionable redirect hint the agent can act on immediately.
;;;;
;;;; Wire-string coercion: every string returned from the form builders must be
;;;; coerced with (map 'string #'identity s) before leaving the injected form
;;;; (SIMPLE-BASE-STRING under *print-readably* corrupts the Slynk rex).

(defpackage #:dsmr-mcp/src/code-core
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  ;; sb-introspect is always present in SBCL; declare it for cold-build
  ;; (package-inferred-system requires explicit deps per file).
  (:import-from #:sb-introspect)
  (:import-from #:uiop
                #:read-file-string
                #:ensure-pathname
                #:enough-pathname
                #:ensure-directory-pathname
                #:native-namestring)
  (:export
   ;; Typed not-found markers
   #:package-not-found
   #:symbol-not-found
   #:found-but-no-source-location
   ;; Core engine
   #:%parse-symbol
   #:%ensure-sb-introspect
   #:%offset->line
   #:code-find-definition
   #:code-describe-symbol
   #:code-find-references
   #:%format-xref-caller
   ;; Injected-form builders (attached path)
   #:%build-code-find-form
   #:%build-code-describe-form
   #:%build-code-find-refs-form))

(in-package #:dsmr-mcp/src/code-core)

;;;; ---------------------------------------------------------------------------
;;;; Typed not-found markers;;;;
;;;; Returned as plists with :kind and :hint so the caller can build a typed
;;;; error response without signal-escaping the engine.
;;;; ---------------------------------------------------------------------------

(defun package-not-found (package-name)
  "Return a package-not-found marker plist for PACKAGE-NAME."
  (list :not-found :package
        :name package-name
        :hint (format nil "Package ~A not found in the image. ~
Try load-system to load the relevant system first."
                      package-name)))

(defun symbol-not-found (symbol-name)
  "Return a symbol-not-found marker plist for SYMBOL-NAME."
  (list :not-found :symbol
        :name symbol-name
        :hint "Symbol not found. Defining system may not be loaded \
— try load-system, or clgrep-search for text search."))

(defun found-but-no-source-location (symbol-name)
  "Return a found-but-no-source-location marker plist for SYMBOL-NAME."
  (list :not-found :source-location
        :name symbol-name
        :hint "Symbol found but has no source location \
(compiled without debug info, or a primitive)."))

;;;; ---------------------------------------------------------------------------
;;;; Package resolution helpers
;;;; ---------------------------------------------------------------------------

(defun %ensure-package (package)
  "Resolve PACKAGE designator to a package object.
Returns the current *package* when PACKAGE is nil or empty.
Signals an error when PACKAGE is a non-empty designator that does not exist."
  (cond
    ((null package) *package*)
    ((and (stringp package) (string= package "")) *package*)
    ((packagep package) package)
    ((symbolp package)
     (or (find-package package)
         (error "Package ~S does not exist" package)))
    ((stringp package)
     (or (find-package (string-upcase package))
         (error "Package ~A does not exist" package)))
    (t (error "Invalid package designator ~S" package))))

;;;; ---------------------------------------------------------------------------
;;;; %parse-symbol — reader-parses designator with *read-eval* nil
;;;; ---------------------------------------------------------------------------

(defun %parse-symbol (symbol-name &key package)
  "Read SYMBOL-NAME as a symbol or (setf name) list without permitting evaluation.
PACKAGE provides the ambient *package* when SYMBOL-NAME is unqualified.
When a package marker (colon) appears in SYMBOL-NAME, PACKAGE is ignored and
the caller's *package* is used so that pkg:sym / pkg::sym resolve naturally.
Binds *read-eval* to nil to disable #. injection.
Returns the read object (a symbol or (setf ...) list) or signals an error."
  (unless (stringp symbol-name)
    (error "symbol must be a string"))
  (let* ((qualified-p (position #\: symbol-name))
         (*package* (if qualified-p
                        *package*
                        (handler-case
                            (%ensure-package package)
                          (error () *package*))))
         (*readtable* (copy-readtable nil))
         (*read-eval* nil))
    (multiple-value-bind (obj end) (read-from-string symbol-name nil :eof)
      (declare (ignore end))
      (when (eq obj :eof)
        (error "Symbol name ~S is empty" symbol-name))
      ;; Accept symbols and (setf ...) lists (for accessor names).
      (unless (or (symbolp obj)
                  (and (consp obj)
                       (eq (first obj) 'setf)
                       (consp (rest obj))
                       (symbolp (second obj))))
        (error "~S is not a symbol or (setf name) designator" symbol-name))
      obj)))

;;;; ---------------------------------------------------------------------------
;;;; %ensure-sb-introspect — return the sb-introspect package
;;;; ---------------------------------------------------------------------------

(defun %ensure-sb-introspect ()
  "Return the SB-INTROSPECT package when running under SBCL, NIL otherwise.
Uses find-package so the core stays cold-buildable without a compile-time
hard reference to any sb-introspect symbol."
  #+sbcl
  (or (find-package :sb-introspect)
      (ignore-errors
       (require :sb-introspect)
       (find-package :sb-introspect)))
  #-sbcl
  nil)

;;;; ---------------------------------------------------------------------------
;;;; %offset->line — character offset to 1-based line number
;;;;
;;;; Ported from cl-mcp/src/code-core.lisp. This is load-bearing: SBCL's
;;;; definition-source-character-offset often points at whitespace or a
;;;; reader conditional preceding the (defun ...) form. The scanner walks
;;;; forward past whitespace, ; comments, #|...|# block comments, and
;;;; #+/#- reader conditionals to find the opening ( of the definition.
;;;; ---------------------------------------------------------------------------

(defun %offset->line (pathname offset)
  "Convert character OFFSET within PATHNAME to a 1-based line number.
SBCL's DEFINITION-SOURCE-CHARACTER-OFFSET typically points at whitespace or
a reader-conditional directive preceding the actual defining form. Walks forward
from OFFSET past whitespace, ';' line comments, '#|...|#' block comments, and
'#+feature' / '#-feature' reader conditionals to reach the first '(' that opens
the definition. Scan capped at 1024 characters of look-ahead. Returns NIL when
the file cannot be read or the offset is out of range."
  (when (and pathname offset)
    (handler-case
        (let* ((physical (translate-logical-pathname pathname))
               (content (uiop:read-file-string physical))
               (len (length content))
               (start (min (max offset 0) len))
               (limit (min len (+ start 1024))))
          (labels ((ws-p (ch)
                     (or (char= ch #\Space) (char= ch #\Tab)
                         (char= ch #\Newline) (char= ch #\Return)))
                   (skip-balanced-list (i)
                     (let ((depth 0))
                       (do ()
                           ((>= i limit))
                         (let ((c (char content i)))
                           (incf i)
                           (cond
                             ((char= c #\() (incf depth))
                             ((char= c #\))
                              (decf depth)
                              (when (zerop depth) (return))))))
                       i))
                   (skip-atom (i)
                     (do ()
                         ((or (>= i limit)
                              (let ((c (char content i)))
                                (or (ws-p c) (char= c #\() (char= c #\))
                                    (char= c #\;))))
                          i)
                       (incf i)))
                   (skip-conditional (i)
                     ;; Skip '#+' or '#-' plus the following feature expression.
                     (incf i 2)
                     (do ()
                         ((or (>= i limit) (not (ws-p (char content i)))))
                       (incf i))
                     (if (< i limit)
                         (if (char= (char content i) #\()
                             (skip-balanced-list i)
                             (skip-atom i))
                         i))
                   (skip-block-comment (i)
                     ;; Skip '#|...|#'.
                     (let ((end (search "|#" content :start2 (+ i 2) :end2 limit)))
                       (if end (+ end 2) limit))))
            (let ((i start))
              (do ()
                  ((>= i limit))
                (let ((ch (char content i)))
                  (cond
                    ((ws-p ch) (incf i))
                    ((char= ch #\;)
                     ;; Skip to end of line.
                     (let ((nl (position #\Newline content :start i :end limit)))
                       (setf i (if nl (1+ nl) limit))))
                    ((char= ch #\#)
                     (cond
                       ;; '#|...|#' block comment
                       ((and (< (1+ i) limit)
                             (char= (char content (1+ i)) #\|))
                        (setf i (skip-block-comment i)))
                       ;; '#+' or '#-' reader conditional
                       ((and (< (1+ i) limit)
                             (or (char= (char content (1+ i)) #\+)
                                 (char= (char content (1+ i)) #\-)))
                        (setf i (skip-conditional i)))
                       (t (return))))
                    (t (return)))))
              (1+ (count #\Newline content :end (min i len))))))
      (error (e)
        (log-event :warn "code.find.line-error"
                   "path" (princ-to-string pathname)
                   "error" (princ-to-string e))
        nil))))

;;;; ---------------------------------------------------------------------------
;;;; normalize-path-for-display — make paths project-relative when possible
;;;; ---------------------------------------------------------------------------

(defun %normalize-path (pathname &optional root)
  "Return a display string for PATHNAME.
When ROOT is non-NIL and PATHNAME resolves to a path under ROOT, returns a
project-relative namestring (no leading directory separator). When PATHNAME is
not under ROOT, or when ROOT is NIL, returns the absolute namestring unchanged.
Wraps relativization in ignore-errors so a malformed root degrades to the
absolute namestring rather than signalling."
  (when pathname
    (ignore-errors
      (let* ((translated (translate-logical-pathname pathname)))
        (if root
            (let* ((resolved  (or (handler-case (truename translated)
                                    (file-error () nil))
                                  translated))
                   (root-dir  (uiop:ensure-directory-pathname root))
                   (rel       (ignore-errors
                                 (uiop:enough-pathname resolved root-dir))))
              (if rel
                  (uiop:native-namestring rel)
                  (namestring translated)))
            (namestring translated))))))

;;;; ---------------------------------------------------------------------------
;;;; code-find-definition — multi-location, all definition kinds
;;;; ---------------------------------------------------------------------------

(defun code-find-definition (symbol-name &key package root)
  "Return a list of definition location plists for SYMBOL-NAME.
Each plist: (:path PATH :line LINE :kind KIND-STRING).
Returns the typed not-found marker plist when the package or symbol is absent.
Iterates all definition kinds so each method of a generic function appears as a
separate :method entry (multi-location). Uses the two-pass NIL-pathname
strategy: prefer entries with non-NIL path (avoid implicitly-created GF entries),
fall back to any entry when no path-bearing entries exist.
ROOT, when non-NIL, causes path values to be project-relative (no leading
separator) for files under ROOT; files outside ROOT keep their absolute path."
  ;; Guard: package resolution failure returns a typed marker.
  (let ((pkg-check
          (when (and package (stringp package) (plusp (length package)))
            (unless (find-package (string-upcase package))
              (return-from code-find-definition
                (package-not-found package))))))
    (declare (ignore pkg-check)))
  (let ((sym (handler-case
                  (%parse-symbol symbol-name :package package)
                (error (e)
                  (log-event :warn "code.find.parse-error"
                             "symbol" symbol-name
                             "error" (princ-to-string e))
                  (return-from code-find-definition
                    (symbol-not-found symbol-name)))))
        (results nil))
    #+sbcl
    (let* ((pkg (%ensure-sb-introspect))
           (find-by-name (and pkg (find-symbol "FIND-DEFINITION-SOURCES-BY-NAME" pkg)))
           (path-fn      (and pkg (find-symbol "DEFINITION-SOURCE-PATHNAME" pkg)))
           (offset-fn    (and pkg (find-symbol "DEFINITION-SOURCE-CHARACTER-OFFSET" pkg)))
           (kinds '(:function :generic-function :method :macro
                    :class :condition :structure :type
                    :variable :constant :method-combination :package)))
      (when find-by-name
        ;; First pass: collect entries with non-NIL pathname.
        (dolist (kind kinds)
          (dolist (src (ignore-errors (funcall find-by-name sym kind)))
            (let* ((pathname (and path-fn (funcall path-fn src)))
                   (offset   (and offset-fn (funcall offset-fn src)))
                   (line     (%offset->line pathname offset))
                   (path     (%normalize-path pathname root)))
              (when (and path line)
                (push (list :path path :line line
                            :kind (string-downcase (symbol-name kind)))
                      results)))))
        ;; Second pass: if first pass found nothing, accept NIL-pathname entries
        ;; (covers implicitly-created GFs with no explicit source location).
        (when (null results)
          (dolist (kind kinds)
            (dolist (src (ignore-errors (funcall find-by-name sym kind)))
              (let* ((pathname (and path-fn (funcall path-fn src)))
                     (offset   (and offset-fn (funcall offset-fn src)))
                     (line     (or (%offset->line pathname offset)
                                   (when pathname 1)))
                     (path     (%normalize-path pathname root)))
                (when (and path line)
                  (push (list :path path :line line
                              :kind (string-downcase (symbol-name kind)))
                        results)))))))
      (cond
        ;; Locations found: return the list.
        (results (nreverse results))
        ;; Symbol is known to the image but has no source location.
        ((or (fboundp sym) (boundp sym) (find-class sym nil))
         (found-but-no-source-location symbol-name))
        ;; Symbol is not known to the image at all.
        (t
         (log-event :warn "code.find.not-found" "symbol" symbol-name)
         (symbol-not-found symbol-name))))
    #-sbcl
    (error "code-find-definition requires SBCL")))

;;;; ---------------------------------------------------------------------------
;;;; %format-xref-caller — render sb-introspect caller names readably
;;;;
;;;; Ported verbatim from cl-mcp/src/code-core.lisp (handles all SBCL-internal
;;;; caller shapes: FAST-METHOD, :method, flet/labels, lambda, generic lists).
;;;; ---------------------------------------------------------------------------

(defun %format-xref-caller (name)
  "Render an SB-INTROSPECT xref caller NAME as a short human-readable string.
Normalizes SBCL-internal shapes (FAST-METHOD, :method, flet, labels, lambda).
Returns NIL for NIL input."
  (when name
    (handler-case
        (let ((*print-case* :downcase)
              (*print-readably* nil)
              (*print-gensym* nil))
          (cond
            ((symbolp name)
             (princ-to-string name))
            ((not (consp name))
             (princ-to-string name))
            ;; SBCL FAST-METHOD / SLOW-METHOD wrapper
            ((and (symbolp (car name))
                  (or (string= (symbol-name (car name)) "FAST-METHOD")
                      (string= (symbol-name (car name)) "SLOW-METHOD")))
             (format nil "(defmethod ~{~(~A~)~^ ~})" (cdr name)))
            ;; :method or METHOD keyword
            ((and (symbolp (car name))
                  (or (string= (symbol-name (car name)) "METHOD")
                      (eq (car name) :method)))
             (format nil "(defmethod ~{~(~A~)~^ ~})" (cdr name)))
            ;; (lambda ...) or (:lambda ...) — drop absolute file paths
            ((and (symbolp (car name))
                  (or (string= (symbol-name (car name)) "LAMBDA")
                      (eq (car name) :lambda)))
             "(lambda)")
            ;; (flet name :in parent) / (labels name :in parent)
            ((and (symbolp (car name))
                  (or (string= (symbol-name (car name)) "FLET")
                      (string= (symbol-name (car name)) "LABELS"))
                  (consp (cdr name)))
             (format nil "~(~A~) ~(~A~)~@[ :in ~(~A~)~]"
                     (car name)
                     (second name)
                     (let ((in (member :in name))) (and in (second in)))))
            (t
             ;; Generic form: strip absolute path strings from pieces.
             (format nil "(~{~A~^ ~})"
                     (mapcar
                      (lambda (piece)
                        (cond
                          ((and (stringp piece)
                                (or (uiop:string-prefix-p "/" piece)
                                    (uiop:string-prefix-p "\\" piece)))
                           "...")
                          (t (format nil "~(~A~)" piece))))
                      name)))))
      (error () nil))))

;;;; ---------------------------------------------------------------------------
;;;; %finder->relation — xref function name to relation keyword
;;;; ---------------------------------------------------------------------------

(defun %finder->relation (finder-name)
  "Map an sb-introspect XREF function name string to a relation string."
  (cond
    ((string= finder-name "WHO-CALLS")        "calls")
    ((string= finder-name "WHO-MACROEXPANDS") "macroexpands")
    ((string= finder-name "WHO-BINDS")        "binds")
    ((string= finder-name "WHO-REFERENCES")   "references")
    ((string= finder-name "WHO-SETS")         "sets")
    (t (string-downcase finder-name))))

;;;; ---------------------------------------------------------------------------
;;;; code-find-references — xref with project_only filter
;;;; ---------------------------------------------------------------------------

(defun %path-inside-project-p (pathname project-root)
  "Return T when PATHNAME is inside PROJECT-ROOT.
Returns T when PROJECT-ROOT is NIL (no filter when root not set)."
  (cond
    ((not project-root) t)
    ((not pathname) nil)
    (t (let* ((pn (ignore-errors (translate-logical-pathname pathname)))
              (ns (and pn (ignore-errors (namestring pn))))
              (root-ns (ignore-errors
                         (namestring
                          (uiop:ensure-directory-pathname project-root)))))
         (and ns root-ns
              (uiop:string-prefix-p root-ns ns))))))

(defun code-find-references (symbol-name &key package (project-only t) relation root)
  "Return a list of reference plists for SYMBOL-NAME.
Each plist: (:path PATH :line LINE :caller CALLER-STRING :relation RELATION-STRING).
RELATION optionally restricts to a single relation name (\"calls\", \"references\",
\"binds\", \"sets\", \"macroexpands\").
PROJECT-ONLY (default T) restricts results to paths under ROOT when ROOT is non-NIL.
When ROOT is NIL, PROJECT-ONLY has no effect (all paths returned).
ROOT, when non-NIL, also causes path values to be project-relative for files under
ROOT; files outside ROOT keep their absolute path.
Returns a typed not-found marker plist when the package or symbol is absent."
  ;; Package guard.
  (when (and package (stringp package) (plusp (length package)))
    (unless (find-package (string-upcase package))
      (return-from code-find-references (package-not-found package))))
  (let ((sym (handler-case
                  (%parse-symbol symbol-name :package package)
                (error (e)
                  (log-event :warn "code.refs.parse-error"
                             "symbol" symbol-name
                             "error" (princ-to-string e))
                  (return-from code-find-references
                    (symbol-not-found symbol-name)))))
        (results nil))
    #+sbcl
    (let* ((pkg (%ensure-sb-introspect))
           (all-finders '("WHO-CALLS"
                          "WHO-MACROEXPANDS"
                          "WHO-BINDS"
                          "WHO-REFERENCES"
                          "WHO-SETS"))
           ;; Filter to requested relation when provided.
           (finders (if (and relation (stringp relation) (plusp (length relation)))
                        (let* ((rel (string-upcase relation))
                               (mapped (cond
                                         ((string= rel "CALLS")        "WHO-CALLS")
                                         ((string= rel "MACROEXPANDS") "WHO-MACROEXPANDS")
                                         ((string= rel "BINDS")        "WHO-BINDS")
                                         ((string= rel "REFERENCES")   "WHO-REFERENCES")
                                         ((string= rel "SETS")         "WHO-SETS")
                                         ;; Accept WHO-* directly too.
                                         ((member rel all-finders :test #'string=) rel)
                                         (t nil))))
                          (if mapped (list mapped) all-finders))
                        all-finders))
           (path-fn    (and pkg (find-symbol "DEFINITION-SOURCE-PATHNAME" pkg)))
           (offset-fn  (and pkg (find-symbol "DEFINITION-SOURCE-CHARACTER-OFFSET" pkg)))
           (seen (make-hash-table :test #'equal)))
      (dolist (finder-name finders)
        (let ((fn (and pkg (find-symbol finder-name pkg))))
          (when fn
            (dolist (entry (ignore-errors (funcall fn sym)))
              (let* ((caller-name (and (consp entry) (car entry)))
                     (definition  (if (consp entry) (cdr entry) entry)))
                (when definition
                  (let* ((pathname   (and path-fn   (funcall path-fn   definition)))
                         (offset     (and offset-fn (funcall offset-fn definition)))
                         (line       (%offset->line pathname offset))
                         (path       (%normalize-path pathname root))
                         (caller-str (%format-xref-caller caller-name))
                         (rel-str    (%finder->relation finder-name)))
                    (when (and path line
                               (or (not project-only)
                                   (%path-inside-project-p pathname root)))
                      (let ((key (format nil "~A:~A:~A:~A"
                                         path line rel-str
                                         (or caller-str ""))))
                        (unless (gethash key seen)
                          (setf (gethash key seen) t)
                          (push (list :path path
                                      :line line
                                      :caller (or caller-str "")
                                      :relation rel-str)
                                results))))))))))))
    #-sbcl
    (error "code-find-references requires SBCL")
    (nreverse results)))

;;;; ---------------------------------------------------------------------------
;;;; code-describe-symbol — hermetic path describe engine
;;;;
;;;; Used by the hermetic worker handler. The attached path uses Slynk instead
;;;; (see %build-code-describe-form below).
;;;; ---------------------------------------------------------------------------

(defun code-describe-symbol (symbol-name &key package root)
  "Return a plist of symbol metadata for the hermetic path.
Plist keys: :name :type :arglist :doc :path :line.
Returns the typed not-found marker plist when the package or symbol is absent.
ROOT, when non-NIL, causes the path value to be project-relative for files under
ROOT (threaded through to code-find-definition); files outside ROOT keep their
absolute path."
  ;; Package guard.
  (when (and package (stringp package) (plusp (length package)))
    (unless (find-package (string-upcase package))
      (return-from code-describe-symbol (package-not-found package))))
  (let ((sym (handler-case
                  (%parse-symbol symbol-name :package package)
                (error (e)
                  (log-event :warn "code.describe.parse-error"
                             "symbol" symbol-name
                             "error" (princ-to-string e))
                  (return-from code-describe-symbol
                    (symbol-not-found symbol-name))))))
    (let* ((class (find-class sym nil))
           (type
             (cond
               ((macro-function sym)            "macro")
               ((and (fboundp sym)
                     (typep (symbol-function sym) 'generic-function))
                "generic-function")
               ((fboundp sym)                   "function")
               ((boundp sym)                    "variable")
               ((and class (ignore-errors
                              (subtypep (class-name class) 'condition)))
                "condition")
               #+sbcl
               ((and class
                     (typep class (find-class 'structure-class)))
                "structure")
               (class                           "class")
               (t                               nil))))
      (when (null type)
        (return-from code-describe-symbol (symbol-not-found symbol-name)))
      #+sbcl
      (%ensure-sb-introspect)
      (let* ((fn (cond
                   ((macro-function sym))
                   ((fboundp sym) (symbol-function sym))
                   (t nil)))
             (fn-ll-sym (%sb-introspect-sym "FUNCTION-LAMBDA-LIST"))
             (arglist
               (cond
                 (fn
                  (handler-case
                      (let ((args (and fn-ll-sym (funcall fn-ll-sym fn))))
                        (cond
                          ((null args) "()")
                          ((listp args)
                           (format nil "~(~A~)" args))
                          (t (format nil "~(~A~)" args))))
                    (error (e)
                      (log-event :warn "code.describe.arglist-error"
                                 "symbol" symbol-name
                                 "error" (princ-to-string e))
                      "()")))
                 (class
                  (handler-case
                      (let* ((slots-fn #+sbcl (find-symbol "CLASS-DIRECT-SLOTS" "SB-MOP")
                                       #-sbcl nil)
                             (slots (and slots-fn
                                         (ignore-errors (funcall slots-fn class))))
                             (slot-name-fn #+sbcl (find-symbol "SLOT-DEFINITION-NAME" "SB-MOP")
                                           #-sbcl nil))
                        (if (and slots slot-name-fn)
                            (format nil "(~{~(~A~)~^ ~})"
                                    (mapcar (lambda (s) (funcall slot-name-fn s)) slots))
                            "()"))
                    (error () "()")))
                 (t "()")))
             (doc
               (cond
                 ((or (macro-function sym) (fboundp sym))
                  (documentation sym 'function))
                 ((boundp sym)  (documentation sym 'variable))
                 (class         (documentation sym 'type))
                 (t             nil)))
             ;; Reuse code-find-definition for location; pass root for relativization.
             (locs (ignore-errors (code-find-definition symbol-name :package package :root root)))
             (first-loc (and (consp locs) (listp (car locs)) (car locs)))
             (path (and first-loc (getf first-loc :path)))
             (line (and first-loc (getf first-loc :line))))
        (list :name (princ-to-string sym)
              :type type
              :arglist (or arglist "()")
              :doc  (or doc "")
              :path (or path "")
              :line (or line 0))))))

(defun %sb-introspect-sym (name)
  "Return symbol NAME from the SB-INTROSPECT package or NIL."
  (let ((pkg (%ensure-sb-introspect)))
    (and pkg (find-symbol name pkg))))

;;;; ---------------------------------------------------------------------------
;;;; Injected-form builders — CL-USER symbol hygiene (Critical Constraints)
;;;;
;;;; Rules (from src/attach/wrap-form.lisp):
;;;;   1. Every helper variable interned in CL-USER with %DSMR-CODE- prefix.
;;;;   2. No loop inside forms — use dolist / do / mapcar.
;;;;   3. Coerce every string leaving the form: (map 'string #'identity s).
;;;; ---------------------------------------------------------------------------

(defun %build-code-find-form (symbol-name package-name &optional root-namestring)
  "Build an injected form that locates all definitions for SYMBOL-NAME in the
attached image using sb-introspect. Returns a list of (:path PATH :line LINE
:kind KIND) plists, or a typed not-found plist.
ROOT-NAMESTRING, when non-NIL, is a namestring for the session project root;
paths under that root are returned relative (no leading separator); paths outside
it are returned absolute.
Uses CL-USER symbol hygiene; no loop; coerces all strings."
  (flet ((cs (n) (intern n (find-package :common-lisp-user))))
    (let ((s-pkg       (cs "%DSMR-CODE-PKG"))
          (s-sym       (cs "%DSMR-CODE-SYM"))
          (s-intr      (cs "%DSMR-CODE-INTR"))
          (s-find-fn   (cs "%DSMR-CODE-FINDFN"))
          (s-path-fn   (cs "%DSMR-CODE-PATHFN"))
          (s-off-fn    (cs "%DSMR-CODE-OFFFN"))
          (s-kinds     (cs "%DSMR-CODE-KINDS"))
          (s-results   (cs "%DSMR-CODE-RES"))
          (s-kind      (cs "%DSMR-CODE-KIND"))
          (s-srcs      (cs "%DSMR-CODE-SRCS"))
          (s-src       (cs "%DSMR-CODE-SRC"))
          (s-pn        (cs "%DSMR-CODE-PN"))
          (s-off       (cs "%DSMR-CODE-OFF"))
          (s-line      (cs "%DSMR-CODE-LINE"))
          (s-path      (cs "%DSMR-CODE-PATH"))
          (s-content   (cs "%DSMR-CODE-CONT"))
          (s-len       (cs "%DSMR-CODE-LEN"))
          (s-start     (cs "%DSMR-CODE-START"))
          (s-limit     (cs "%DSMR-CODE-LIM"))
          (s-i         (cs "%DSMR-CODE-I"))
          (s-ch        (cs "%DSMR-CODE-CH"))
          (s-nl        (cs "%DSMR-CODE-NL")))
      `(let* ((,s-pkg  (and ,package-name (find-package ,package-name)))
              (,s-sym  (let ((*package* (or ,s-pkg (find-package :common-lisp-user)))
                             (*read-eval* nil)
                             (*readtable* (copy-readtable nil)))
                         (ignore-errors (read-from-string ,symbol-name))))
              (,s-intr  (find-package :sb-introspect))
              (,s-find-fn (and ,s-intr
                               (find-symbol "FIND-DEFINITION-SOURCES-BY-NAME" ,s-intr)))
              (,s-path-fn (and ,s-intr
                               (find-symbol "DEFINITION-SOURCE-PATHNAME" ,s-intr)))
              (,s-off-fn  (and ,s-intr
                               (find-symbol "DEFINITION-SOURCE-CHARACTER-OFFSET" ,s-intr)))
              (,s-kinds '(:function :generic-function :method :macro
                          :class :condition :structure :type
                          :variable :constant :method-combination :package))
              (,s-results nil))
         (cond
           ;; Package not found.
           ((and ,package-name (not ,s-pkg))
            (list :not-found :package :name (map 'string #'identity ,package-name)
                  :hint "Package not found in the image. Try load-system first."))
           ;; Symbol not parseable.
           ((null ,s-sym)
            (list :not-found :symbol :name (map 'string #'identity ,symbol-name)
                  :hint "Symbol not found. Try load-system or clgrep-search."))
           (t
            ;; First pass: prefer definitions with non-NIL pathname.
            (when ,s-find-fn
              (dolist (,s-kind ,s-kinds)
                (dolist (,s-src (ignore-errors
                                  (funcall ,s-find-fn ,s-sym ,s-kind)))
                  (let* ((,s-pn   (and ,s-path-fn (funcall ,s-path-fn ,s-src)))
                         (,s-off  (and ,s-off-fn  (funcall ,s-off-fn  ,s-src)))
                         ;; Inline %offset->line to avoid package deps in the form.
                         (,s-line
                           (when (and ,s-pn ,s-off)
                             (ignore-errors
                               (let* ((,s-content (uiop:read-file-string
                                                   (translate-logical-pathname ,s-pn)))
                                      (,s-len   (length ,s-content))
                                      (,s-start (min (max ,s-off 0) ,s-len))
                                      (,s-limit (min ,s-len (+ ,s-start 1024)))
                                      (,s-i     ,s-start))
                                 (do ()
                                     ((>= ,s-i ,s-limit))
                                   (let ((,s-ch (char ,s-content ,s-i)))
                                     (cond
                                       ((or (char= ,s-ch #\Space) (char= ,s-ch #\Tab)
                                            (char= ,s-ch #\Newline) (char= ,s-ch #\Return))
                                        (incf ,s-i))
                                       ((char= ,s-ch #\;)
                                        (let ((,s-nl (position #\Newline ,s-content
                                                               :start ,s-i :end ,s-limit)))
                                          (setf ,s-i (if ,s-nl (1+ ,s-nl) ,s-limit))))
                                       (t (return)))))
                                 (1+ (count #\Newline ,s-content
                                            :end (min ,s-i ,s-len)))))))
                         ;; Relativize path when root-namestring is baked in.
                         (,s-path
                           (and ,s-pn
                             (ignore-errors
                               (let* ((%pn-tr  (translate-logical-pathname ,s-pn))
                                      (%pn-res (or (handler-case (truename %pn-tr)
                                                     (file-error () nil))
                                                   %pn-tr)))
                                 (map 'string #'identity
                                      (if ,root-namestring
                                          (let* ((%rdir (uiop:ensure-directory-pathname
                                                         ,root-namestring))
                                                 (%rel  (ignore-errors
                                                          (uiop:enough-pathname
                                                           %pn-res %rdir))))
                                            (if %rel
                                                (uiop:native-namestring %rel)
                                                (namestring %pn-tr)))
                                          (namestring %pn-tr))))))))
                    (when (and ,s-path ,s-line)
                      (push (list :path ,s-path :line ,s-line
                                  :kind (map 'string #'identity
                                             (string-downcase (symbol-name ,s-kind))))
                            ,s-results))))))
            ;; Return results or typed not-found.
            (cond
              (,s-results (nreverse ,s-results))
              ((or (fboundp ,s-sym) (boundp ,s-sym) (find-class ,s-sym nil))
               (list :not-found :source-location
                     :name (map 'string #'identity ,symbol-name)
                     :hint "Symbol found but has no source location (no debug info, or primitive)."))
              (t
               (list :not-found :symbol
                     :name (map 'string #'identity ,symbol-name)
                     :hint "Symbol not found. Try load-system or clgrep-search.")))))))))

(defun %build-code-describe-form (symbol-name package-name &optional root-namestring)
  "Build an injected form that describes SYMBOL-NAME in the attached image using
Slynk's describe-symbol and operator-arglist. Returns a list of two strings:
the describe output and the arglist string (either may be NIL).
ROOT-NAMESTRING is accepted for signature consistency with the other form builders
but is not used here: the attached code-describe path returns path=\"\" (Slynk's
describe output contains no path field); the hermetic path relativizes via
code-describe-symbol calling code-find-definition with :root.
Uses CL-USER symbol hygiene; coerces all strings."
  (declare (ignore root-namestring))
  (flet ((cs (n) (intern n (find-package :common-lisp-user))))
    (let ((s-desc (cs "%DSMR-CODE-DESC"))
          (s-args (cs "%DSMR-CODE-ARGS")))
      `(let ((,s-desc (ignore-errors (slynk:describe-symbol ,symbol-name)))
             (,s-args (ignore-errors (slynk:operator-arglist ,symbol-name ,package-name))))
         (list (and ,s-desc (map 'string #'identity ,s-desc))
               (and ,s-args (map 'string #'identity ,s-args)))))))

(defun %build-code-find-refs-form (symbol-name package-name project-only
                                   &optional root-namestring)
  "Build an injected form that returns xref references for SYMBOL-NAME in the
attached image using sb-introspect who-calls/who-references/etc.
PROJECT-ONLY (T/NIL) restricts results to paths under the session project root.
ROOT-NAMESTRING, when non-NIL, is a namestring for the session project root;
paths under that root are returned relative (no leading separator) and the
project_only filter keys off that root. When NIL, project_only has no effect
and paths remain absolute.
Returns a list of (:path PATH :line LINE :caller CALLER :relation RELATION) plists,
or a typed not-found plist. Uses CL-USER symbol hygiene; no loop; coerces strings."
  (flet ((cs (n) (intern n (find-package :common-lisp-user))))
    (let ((s-pkg       (cs "%DSMR-CODE-RPKG"))
          (s-sym       (cs "%DSMR-CODE-RSYM"))
          (s-intr      (cs "%DSMR-CODE-RINTR"))
          (s-path-fn   (cs "%DSMR-CODE-RPATHFN"))
          (s-off-fn    (cs "%DSMR-CODE-ROFFFN"))
          (s-finders   (cs "%DSMR-CODE-RFINDERS"))
          (s-finder    (cs "%DSMR-CODE-RFINDER"))
          (s-fn        (cs "%DSMR-CODE-RFN"))
          (s-results   (cs "%DSMR-CODE-RRES"))
          (s-seen      (cs "%DSMR-CODE-RSEEN"))
          (s-entry     (cs "%DSMR-CODE-RENTRY"))
          (s-cname     (cs "%DSMR-CODE-RCNAME"))
          (s-def       (cs "%DSMR-CODE-RDEF"))
          (s-pn        (cs "%DSMR-CODE-RPN"))
          (s-off       (cs "%DSMR-CODE-ROFF"))
          (s-line      (cs "%DSMR-CODE-RLINE"))
          (s-path      (cs "%DSMR-CODE-RPATH"))
          (s-cstr      (cs "%DSMR-CODE-RCSTR"))
          (s-key       (cs "%DSMR-CODE-RKEY"))
          (s-rel       (cs "%DSMR-CODE-RREL"))
          (s-content   (cs "%DSMR-CODE-RCONT"))
          (s-len       (cs "%DSMR-CODE-RLEN"))
          (s-start     (cs "%DSMR-CODE-RSTART"))
          (s-limit     (cs "%DSMR-CODE-RLIM"))
          (s-i         (cs "%DSMR-CODE-RI"))
          (s-ch        (cs "%DSMR-CODE-RCH"))
          (s-nl        (cs "%DSMR-CODE-RNL")))
      `(let* ((,s-pkg    (and ,package-name (find-package ,package-name)))
              (,s-sym    (let ((*package* (or ,s-pkg (find-package :common-lisp-user)))
                               (*read-eval* nil)
                               (*readtable* (copy-readtable nil)))
                           (ignore-errors (read-from-string ,symbol-name))))
              (,s-intr   (find-package :sb-introspect))
              (,s-path-fn (and ,s-intr
                               (find-symbol "DEFINITION-SOURCE-PATHNAME" ,s-intr)))
              (,s-off-fn  (and ,s-intr
                               (find-symbol "DEFINITION-SOURCE-CHARACTER-OFFSET" ,s-intr)))
              (,s-finders '("WHO-CALLS" "WHO-MACROEXPANDS" "WHO-BINDS"
                            "WHO-REFERENCES" "WHO-SETS"))
              (,s-results nil)
              (,s-seen   (make-hash-table :test 'equal)))
         (cond
           ((and ,package-name (not ,s-pkg))
            (list :not-found :package :name (map 'string #'identity ,package-name)
                  :hint "Package not found. Try load-system first."))
           ((null ,s-sym)
            (list :not-found :symbol :name (map 'string #'identity ,symbol-name)
                  :hint "Symbol not found. Try load-system or clgrep-search."))
           (t
            (dolist (,s-finder ,s-finders)
              (let ((,s-fn (and ,s-intr (find-symbol ,s-finder ,s-intr))))
                (when ,s-fn
                  (dolist (,s-entry (ignore-errors (funcall ,s-fn ,s-sym)))
                    (let* ((,s-cname (and (consp ,s-entry) (car ,s-entry)))
                           (,s-def   (if (consp ,s-entry) (cdr ,s-entry) ,s-entry)))
                      (when ,s-def
                        (let* ((,s-pn   (and ,s-path-fn (funcall ,s-path-fn ,s-def)))
                               (,s-off  (and ,s-off-fn  (funcall ,s-off-fn  ,s-def)))
                               ;; Inline %offset->line (simplified: skip whitespace only).
                               (,s-line
                                 (when (and ,s-pn ,s-off)
                                   (ignore-errors
                                     (let* ((,s-content (uiop:read-file-string
                                                         (translate-logical-pathname ,s-pn)))
                                            (,s-len   (length ,s-content))
                                            (,s-start (min (max ,s-off 0) ,s-len))
                                            (,s-limit (min ,s-len (+ ,s-start 1024)))
                                            (,s-i     ,s-start))
                                       (do ()
                                           ((>= ,s-i ,s-limit))
                                         (let ((,s-ch (char ,s-content ,s-i)))
                                           (cond
                                             ((or (char= ,s-ch #\Space) (char= ,s-ch #\Tab)
                                                  (char= ,s-ch #\Newline) (char= ,s-ch #\Return))
                                              (incf ,s-i))
                                             ((char= ,s-ch #\;)
                                              (let ((,s-nl
                                                      (position #\Newline ,s-content
                                                                :start ,s-i :end ,s-limit)))
                                                (setf ,s-i (if ,s-nl (1+ ,s-nl) ,s-limit))))
                                             (t (return)))))
                                       (1+ (count #\Newline ,s-content
                                                  :end (min ,s-i ,s-len)))))))
                               ;; Relativize path when root-namestring is baked in.
                               (,s-path
                                 (and ,s-pn
                                   (ignore-errors
                                     (let* ((%pn-tr  (translate-logical-pathname ,s-pn))
                                            (%pn-res (or (handler-case (truename %pn-tr)
                                                           (file-error () nil))
                                                         %pn-tr)))
                                       (map 'string #'identity
                                            (if ,root-namestring
                                                (let* ((%rdir (uiop:ensure-directory-pathname
                                                               ,root-namestring))
                                                       (%rel  (ignore-errors
                                                                (uiop:enough-pathname
                                                                 %pn-res %rdir))))
                                                  (if %rel
                                                      (uiop:native-namestring %rel)
                                                      (namestring %pn-tr)))
                                                (namestring %pn-tr)))))))
                               (,s-cstr
                                 ;; Simplified caller formatting inline.
                                 (when ,s-cname
                                   (ignore-errors
                                     (let ((*print-case* :downcase)
                                           (*print-readably* nil))
                                       (map 'string #'identity
                                            (if (symbolp ,s-cname)
                                                (princ-to-string ,s-cname)
                                                (format nil "~(~A~)" ,s-cname)))))))
                               (,s-rel
                                 (map 'string #'identity
                                      (cond
                                        ((string= ,s-finder "WHO-CALLS")        "calls")
                                        ((string= ,s-finder "WHO-MACROEXPANDS") "macroexpands")
                                        ((string= ,s-finder "WHO-BINDS")        "binds")
                                        ((string= ,s-finder "WHO-REFERENCES")   "references")
                                        ((string= ,s-finder "WHO-SETS")         "sets")
                                        (t "unknown")))))
                          ;; Project-only filter: when root-namestring is present, use it
                          ;; as the filter root; when absent, no filtering occurs.
                          (when (and ,s-path ,s-line
                                     (or (not ,project-only)
                                         (not ,root-namestring)
                                         (uiop:string-prefix-p
                                          (namestring
                                           (uiop:ensure-directory-pathname ,root-namestring))
                                          ;; Compare against the absolute path for filtering,
                                          ;; even when the displayed path is relative.
                                          (let* ((%pn-tr2 (translate-logical-pathname ,s-pn))
                                                 (%pn-res2 (or (handler-case (truename %pn-tr2)
                                                                 (file-error () nil))
                                                               %pn-tr2)))
                                            (namestring %pn-res2)))))
                            (let ((,s-key (format nil "~A:~A:~A:~A"
                                                  ,s-path ,s-line ,s-rel
                                                  (or ,s-cstr ""))))
                              (unless (gethash ,s-key ,s-seen)
                                (setf (gethash ,s-key ,s-seen) t)
                                (push (list :path ,s-path :line ,s-line
                                            :caller (or ,s-cstr "")
                                            :relation ,s-rel)
                                      ,s-results))))))))))
            (if ,s-results
                (nreverse ,s-results)
                ;; Return empty list (not a not-found error) when no references.
                nil))))))))
