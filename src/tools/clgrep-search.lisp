;;;; src/tools/clgrep-search.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: clgrep-search (VERB-08).
;;;; Lisp-aware, image-independent semantic grep over .lisp/.asd/.cl/.lsp/.ros
;;;; source files.  Default fast path: cl-ppcre regex with enclosing-form
;;;; context (D-09).  Opt-in structural mode via form_pattern (D-11).
;;;;
;;;; D-16 no-root guard at entry.  SAFETY-02: every file read goes through
;;;; allowed-read-path (root + ASDF source dirs).  Mode-independent —
;;;; dispatcher-side only (no *mode* branch, no dispatch-hermetic-call).
;;;;
;;;; Wire shape follows cl-mcp docs/tools.md (D-01 parity), with the
;;;; addition of form_pattern for the D-11 structural mode.  Results are
;;;; deduplicated by (file . form-start-byte): multiple regex hits inside
;;;; the same form produce one result with a match_lines array.

(defpackage #:dsmr-mcp/src/tools/clgrep-search
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content)
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path)
  (:import-from #:dsmr-mcp/src/clgrep
                #:semantic-grep)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:export #:clgrep-search-tool))

(in-package #:dsmr-mcp/src/tools/clgrep-search)

;;; ---------------------------------------------------------------------------
;;; clgrep-search-tool CLOS class
;;; ---------------------------------------------------------------------------

(defclass clgrep-search-tool (mcp-tool)
  ;; CRITICAL: class-allocated slots use :initform (NOT :default-initargs).
  ;; c2mop:class-prototype does not apply :default-initargs; the metaclass
  ;; finalize-inheritance :after reads the prototype for the name slot.
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "clgrep-search")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Lisp-aware semantic grep over .lisp/.asd/.cl/.lsp/.ros source files. \
Unlike plain text grep, returns the top-level form signature (defun/defmethod/etc.) \
containing each match. Works WITHOUT loading any Lisp system — no side effects. \
Use this first for code exploration; follow with lisp-read-file for definition detail. \
Default: returns signatures only (token-efficient). Set include_form=true for full \
form text. Set form_pattern to a shape like \"(defun _ ...)\" for structural matching \
(D-11: _, ?name, ... wildcards; no predicates or full unification).")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((pattern
                  :type :string
                  :description "cl-ppcre regular expression to search for (required in regex mode).")
                 (path
                  :type :string
                  :description "Search root: absolute path or relative to project root. \
Defaults to project root.")
                 (recursive
                  :type :boolean
                  :description "Search subdirectories recursively (default: true).")
                 (case_insensitive
                  :type :boolean
                  :description "Case-insensitive regex matching (default: false).")
                 (form_types
                  :type :array
                  :description "Restrict to these form types, e.g. [\"defun\", \"defmethod\"] \
(optional, all types by default).")
                 (limit
                  :type :integer
                  :description "Maximum number of results to return (default: 200).")
                 (include_form
                  :type :boolean
                  :description "Include full form text in each result (default: false).")
                 (form_pattern
                  :type :string
                  :description "Structural form-shape pattern (D-11 opt-in). Uses _, ?name, \
... wildcards. Example: \"(defun _ ...)\". When supplied, pattern is ignored and structural \
matching replaces the regex fast path."))
                :required ("pattern"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: image-independent Lisp-aware semantic grep.
Regex fast path (D-09) or opt-in structural mode (D-11).
Discovery honors .gitignore; .git/ and build artifacts are always excluded (D-10).
Per-file errors are logged and skipped (never abort the run).
Results are deduplicated by (file, form-start-byte)."))

(c2mop:ensure-finalized (find-class 'clgrep-search-tool))

;;; ---------------------------------------------------------------------------
;;; Result deduplication: group by (file . form-start-byte)
;;; ---------------------------------------------------------------------------

(defun %format-match-ht (match)
  "Convert one match alist to a wire hash-table."
  (let ((ht (make-hash-table :test 'equal)))
    (dolist (pair match)
      (let ((key (string-downcase (substitute #\_ #\- (symbol-name (car pair))))))
        (setf (gethash key ht) (cdr pair))))
    ht))

(defun %deduplicate-results (results)
  "Deduplicate results by (file . form-start-byte).
Multiple regex hits inside the same form produce one entry with a
match_lines array listing each (line, match) pair in order."
  (let ((groups (make-hash-table :test #'equal))
        (order nil))
    (dolist (r results)
      (let* ((file (cdr (assoc :file r)))
             (fsb  (cdr (assoc :form-start-byte r)))
             (key  (cons file fsb)))
        (unless (gethash key groups)
          (push key order))
        (push r (gethash key groups))))
    (map 'simple-vector
         (lambda (key)
           (let* ((matches (nreverse (gethash key groups)))
                  (rep (%format-match-ht (first matches)))
                  (match-lines
                   (map 'simple-vector
                        (lambda (m)
                          (make-ht "line"  (cdr (assoc :line m))
                                   "match" (cdr (assoc :match m))))
                        matches)))
             ;; For structural mode the match-lines are already in each entry
             (when (cdr (assoc :match-lines (first matches)))
               ;; Structural mode has pre-built match-lines; use them directly
               (setf match-lines
                     (coerce (mapcar (lambda (pair-list)
                                       (make-ht "line"  (cdr (assoc :line pair-list))
                                                "match" (cdr (assoc :match pair-list))))
                                     (cdr (assoc :match-lines (first matches))))
                             'simple-vector)))
             (setf (gethash "match_lines" rep) match-lines)
             ;; Remove the raw match-lines alist entry from the hash-table
             (remhash "match_lines" rep)
             (setf (gethash "match_lines" rep) match-lines)
             rep))
         (nreverse order))))

;;; ---------------------------------------------------------------------------
;;; tool-handle
;;; ---------------------------------------------------------------------------

(defmethod tool-handle ((tool clgrep-search-tool) id args)
  (let* ((session      (tool-session tool))
         (root         (session-project-root session)))
    ;; D-16: reject when no root is set
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError" t
                             "error_type" "project-root-not-set"
                             "content"
                             (text-content "clgrep-search: no project root set. \
Call fs-set-project-root first.")))))
    (let* ((pattern         (gethash "pattern" args))
           (path-str        (gethash "path" args))
           (recursive       (let ((v (gethash "recursive" args)))
                              (if (null v) t v)))
           (case-insensitive (gethash "case_insensitive" args))
           (form-types-raw  (gethash "form_types" args))
           (limit           (or (gethash "limit" args) 200))
           (include-form    (gethash "include_form" args))
           (form-pattern    (gethash "form_pattern" args)))
      ;; pattern is required when no form_pattern is given
      (when (and (null form-pattern)
                 (or (null pattern)
                     (and (stringp pattern)
                          (zerop (length (string-trim '(#\Space #\Tab) pattern))))))
        (return-from tool-handle
          (result id (make-ht "isError" t
                               "error_type" "invalid-argument"
                               "content"
                               (text-content "clgrep-search: pattern is required \
(or provide form_pattern for structural mode).")))))
      ;; Resolve the search root: path arg (relative to root) or fall back to root
      (let* ((search-root
              (if path-str
                  (or (allowed-read-path path-str root)
                      (return-from tool-handle
                        (result id (make-ht "isError" t
                                             "error_type" "sandbox-violation"
                                             "content"
                                             (text-content
                                              (format nil "clgrep-search: ~A is outside \
the read allow-list." path-str))))))
                  root))
             ;; Coerce form_types vector to list of strings
             (form-types (when form-types-raw
                           (coerce form-types-raw 'list)))
             ;; Use empty string as the pattern in structural mode (not used for regex)
             (effective-pattern (or pattern "")))
        (log-event :info "clgrep.search"
                   "pattern" effective-pattern
                   "path" (namestring search-root)
                   "limit" limit
                   "include_form" include-form
                   "form_pattern" (or form-pattern ""))
        (handler-case
            (multiple-value-bind (raw-results limited)
                (semantic-grep search-root effective-pattern
                               :recursive recursive
                               :case-insensitive case-insensitive
                               :form-types form-types
                               :include-form include-form
                               :limit limit
                               :form-pattern form-pattern
                               :session-root root)
              (let* ((deduped (%deduplicate-results raw-results))
                     (count   (length deduped))
                     (summary (with-output-to-string (s)
                                (format s "~D ~:[matches~;match~] for ~S~@[ in ~A~]:~%"
                                        count (= count 1)
                                        (or form-pattern effective-pattern)
                                        path-str)
                                (loop for m across deduped
                                      do (format s "  ~A:~A [~A] ~A~%"
                                                 (gethash "file" m)
                                                 (gethash "line" m)
                                                 (or (gethash "form_type" m) "?")
                                                 (or (gethash "signature" m)
                                                     (gethash "form_name" m)
                                                     ""))))))
                (result id
                        (make-ht "content" (text-content summary)
                                 "matches" deduped
                                 "count"   count
                                 "limited" limited))))
          (error (e)
            (result id (make-ht "isError" t
                                 "error_type" "search-error"
                                 "content"
                                 (text-content
                                  (format nil "clgrep-search: ~A"
                                          (princ-to-string e)))))))))))
