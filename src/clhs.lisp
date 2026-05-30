;;;; src/clhs.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Common Lisp HyperSpec lookup (VERB-09): resolve a symbol or a section
;;;; number against a locally-installed HyperSpec and return readable extracted
;;;; text plus the resolved entry URL.
;;;;
;;;; The section filename math, Map_Sym.txt symbol-path parse, and latin-1 HTML
;;;; tag-strip are ported from cl-mcp/src/clhs.lisp (MIT). What differs here is
;;;; root resolution: instead of a Quicklisp-first loader, a 3-tier env-first
;;;; chain (D-01) resolves the HyperSpec root, and the pure layer fails open
;;;; (returns NIL) when none resolves so the tool can surface a structured
;;;; not-found rather than signalling on the wire (D-04).
;;;;
;;;; :clhs is a SOFT dependency: tier 3 reaches it lazily via asdf:find-system
;;;; at lookup time and it is never declared in dsmr-mcp.asd :depends-on. The
;;;; env/workspace tiers are read-only and never install.

(defpackage #:dsmr-mcp/src/clhs
  (:use #:cl)
  (:import-from #:cl-ppcre
                #:split
                #:regex-replace-all)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:text-content)
  (:export #:clhs-lookup
           #:%section-to-filename
           #:%section-number-p))

(in-package #:dsmr-mcp/src/clhs)

;;; ---------------------------------------------------------------------------
;;; Root resolution (3-tier, env-first) — D-01
;;; ---------------------------------------------------------------------------

(defvar *clhs-symbol-map* nil
  "Cached hash table mapping uppercase symbol names to relative HyperSpec paths.")

(defvar *clhs-root* nil
  "Cached HyperSpec root directory pathname (the dir holding Data/ and Body/).")

(defun %hyperspec-root-if-mapped (dir)
  "Return DIR as an absolute directory pathname iff Data/Map_Sym.txt exists
under it; otherwise NIL. DIR may be a string or pathname; a leading ~ is
expanded via truename before the probe (SBCL expands ~ in truename/probe-file).
A nonexistent directory signals on truename and is caught, yielding NIL."
  (when dir
    (handler-case
        (let ((root (truename (uiop:ensure-directory-pathname dir))))
          (when (probe-file (merge-pathnames "Data/Map_Sym.txt" root))
            root))
      (error () nil))))

(defun %resolve-foreign-clhs-root ()
  "Tier 3: resolve a HyperSpec root from the foreign :clhs library.
:clhs is a soft dependency loaded lazily here, never declared in the system.
When the library resolves but no local HyperSpec is present, install it once
via INSTALL-CLHS-USE-LOCAL after logging the network action at :info (D-03).
Returns a mapped root pathname, or NIL on any failure (fail-open)."
  (handler-case
      (when (asdf:find-system :clhs nil)
        (unless (find-package :clhs)
          (asdf:load-system :clhs))
        (let* ((root-fn (find-symbol "HYPERSPEC-ROOT" :clhs))
               (root    (and root-fn (funcall root-fn))))
          (or (%hyperspec-root-if-mapped root)
              ;; No local tree yet — gated network install (D-03).
              (let ((install-fn (find-symbol "INSTALL-CLHS-USE-LOCAL" :clhs)))
                (when (and install-fn (fboundp install-fn))
                  (log-event :info "clhs.install"
                             "action" "installing HyperSpec via clhs-use-local")
                  (funcall install-fn)
                  (%hyperspec-root-if-mapped
                   (and root-fn (funcall root-fn))))))))
    (error (c)
      (log-event :warn "clhs.install"
                 "action" "foreign clhs resolution failed"
                 "error" (princ-to-string c))
      nil)))

(defun %resolve-hyperspec-root ()
  "Resolve a HyperSpec root via the 3-tier chain, or NIL when none resolves.

  Tier 1: DSMR_HYPERSPEC_DIR (points at the root; read-only, never installs).
  Tier 2: $LISP_WORKSPACE/HyperSpec/ (read-only, never installs).
  Tier 3: the foreign :clhs library (may install over the network, gated)."
  (or
   (let ((env (uiop:getenv "DSMR_HYPERSPEC_DIR")))
     (and env (plusp (length env)) (%hyperspec-root-if-mapped env)))
   (let ((ws (uiop:getenv "LISP_WORKSPACE")))
     (and ws (plusp (length ws))
          (%hyperspec-root-if-mapped
           (merge-pathnames "HyperSpec/" (uiop:ensure-directory-pathname ws)))))
   (%resolve-foreign-clhs-root)))

(defun %load-symbol-map ()
  "Resolve a HyperSpec root, parse Data/Map_Sym.txt into a fresh table, and
cache both root and table. Returns the table, or NIL when no HyperSpec
resolves (the caller surfaces the structured not-found, never a crash)."
  (let ((root (%resolve-hyperspec-root)))
    (when root
      (let ((map-file (merge-pathnames "Data/Map_Sym.txt" root))
            (table (make-hash-table :test 'equalp)))
        (with-open-file (s map-file :external-format :latin-1)
          (loop for symbol = (read-line s nil)
                for path = (read-line s nil)
                while (and symbol path)
                do (setf (gethash symbol table) path)))
        (setf *clhs-root* root
              *clhs-symbol-map* table)
        (log-event :info "clhs" "action" "loaded symbol map"
                   "count" (hash-table-count table))
        table))))

(defun %get-symbol-map ()
  "Return the cached symbol map, loading it on first use. NIL when unresolvable."
  (or *clhs-symbol-map* (%load-symbol-map)))

(defun %get-clhs-root ()
  "Return the resolved HyperSpec root, ensuring the map is loaded. NIL when
unresolvable."
  (%get-symbol-map)
  *clhs-root*)

;;; ---------------------------------------------------------------------------
;;; Section number -> filename math (ported verbatim)
;;; ---------------------------------------------------------------------------

(defun %section-to-filename (section-string)
  "Convert a section number like '22.3.1' to a filename like '22_ca.htm'.
Each subsection letter corresponds to a=1, b=2, c=3, etc.
Chapter numbers are zero-padded to 2 digits (e.g., 7 -> 07)."
  (let* ((parts (split "\\." section-string))
         (chapter-num (parse-integer (first parts)))
         (chapter (format nil "~2,'0D" chapter-num))
         (subsections (rest parts)))
    (if (null subsections)
        (format nil "~A_.htm" chapter)
        (format nil "~A_~{~A~}.htm"
                chapter
                (mapcar (lambda (n)
                          (code-char (+ (char-code #\a) (1- (parse-integer n)))))
                        subsections)))))

(defun %section-number-p (string)
  "Return T if STRING looks like a section number (e.g., '22.3', '3.1.2')."
  (and (> (length string) 0)
       (every (lambda (c) (or (digit-char-p c) (char= c #\.))) string)
       (digit-char-p (char string 0))))

(defun %section-local-path (section-string)
  "Return the absolute local file path for a section number, or NIL if not found."
  (let ((root (%get-clhs-root)))
    (when root
      (let* ((filename (%section-to-filename section-string))
             (path (merge-pathnames (format nil "Body/~A" filename) root)))
        (when (probe-file path)
          (namestring path))))))

;;; ---------------------------------------------------------------------------
;;; Symbol -> path / URL resolution (ported verbatim, table-guarded)
;;; ---------------------------------------------------------------------------

(defun %symbol-relative-path (symbol-name)
  "Return the relative path (e.g., 'Body/m_loop.htm') for SYMBOL-NAME, or NIL."
  (let ((table (%get-symbol-map)))
    (when table
      (let* ((key (string-upcase (string-trim " " symbol-name)))
             (raw-path (gethash key table)))
        (when raw-path
          ;; Map_Sym.txt stores paths like "../Body/m_loop.htm"; strip "../".
          (if (and (>= (length raw-path) 3)
                   (string= "../" raw-path :end2 3))
              (subseq raw-path 3)
              raw-path))))))

(defun %symbol-local-path (symbol-name)
  "Return the absolute local file path for SYMBOL-NAME, or NIL."
  (let ((relative (%symbol-relative-path symbol-name))
        (root (%get-clhs-root)))
    (when (and relative root)
      (namestring (merge-pathnames relative root)))))

(defun %symbol-url (symbol-name)
  "Return the HyperSpec URL for SYMBOL-NAME.
Returns a file:// URL for local installations, or http:// URL otherwise."
  (let ((local-path (%symbol-local-path symbol-name)))
    (cond
      ((and local-path (probe-file local-path))
       (format nil "file://~A" local-path))
      (t
       ;; Fallback to the LispWorks remote URL when the symbol maps but the
       ;; local file is missing.
       (let ((relative (%symbol-relative-path symbol-name)))
         (when relative
           (format nil "http://www.lispworks.com/documentation/HyperSpec/~A"
                   relative)))))))

;;; ---------------------------------------------------------------------------
;;; HTML text extraction (ported verbatim; latin-1 is load-bearing)
;;; ---------------------------------------------------------------------------

(defconstant +brief-max-chars+
  1500
  "Character limit for brief mode when no Description heading is found.
Covers Syntax + Arguments for most entries and the introductory
paragraph of section pages.")

(defun %extract-text-from-html (path &key (max-chars 8000) brief)
  "Extract plain text from HTML file at PATH.
Returns at most MAX-CHARS characters of content.
When BRIEF is true, stop before the Description section.  If no
Description heading is found (e.g. section pages), the result is
truncated to +BRIEF-MAX-CHARS+ after extraction.  The char limit is
applied post-hoc so that long Syntax sections are not cut short before
the Description sentinel is reached.

HyperSpec entry pages are read as :latin-1 — the bundled tree is not UTF-8
and a strict reader would choke on the high-bit characters in some pages."
  (unless (probe-file path) (return-from %extract-text-from-html nil))
  (with-open-file (s path :external-format :latin-1)
    (let ((result
            (make-array 0 :element-type 'character :adjustable t
                          :fill-pointer 0))
          (in-script nil)
          (in-style nil)
          (hit-description nil))
      (flet ((append-text (text)
               (when (and text (< (length result) max-chars))
                 (loop for char across text
                       while (< (length result) max-chars)
                       do (vector-push-extend char result)))))
        (loop for line = (read-line s nil)
              while (and line (< (length result) max-chars))
              do (let ((text line))
                   (when (search "<script" text :test #'char-equal)
                     (setf in-script t))
                   (when (search "</script>" text :test #'char-equal)
                     (setf in-script nil)
                     (setf text ""))
                   (when (search "<style" text :test #'char-equal)
                     (setf in-style t))
                   (when (search "</style>" text :test #'char-equal)
                     (setf in-style nil)
                     (setf text ""))
                   (unless (or in-script in-style)
                     (setf text (regex-replace-all "<[^>]+>" text ""))
                     (setf text (regex-replace-all "&lt;" text "<"))
                     (setf text (regex-replace-all "&gt;" text ">"))
                     (setf text (regex-replace-all "&amp;" text "&"))
                     (setf text (regex-replace-all "&quot;" text "\""))
                     (setf text (regex-replace-all "&nbsp;" text " "))
                     (setf text (regex-replace-all "&#\\d+;" text ""))
                     ;; Collapse multiple spaces
                     (setf text (regex-replace-all "  +" text " "))
                     (let ((trimmed (string-trim '(#\Space #\Tab) text)))
                       ;; In brief mode, stop at the Description section.
                       (when (and brief
                                  (>= (length trimmed) 12)
                                  (string-equal trimmed "Description:" :end1 12))
                         (setf hit-description t)
                         (return))
                       (when (plusp (length trimmed))
                         (append-text trimmed)
                         (append-text (string #\Newline))))))))
      ;; Post-hoc brief cap: if the Description heading was never found
      ;; (e.g. section pages), truncate to +brief-max-chars+.
      (let ((text (coerce result 'string)))
        (if (and brief (not hit-description)
                 (> (length text) +brief-max-chars+))
            (subseq text 0 +brief-max-chars+)
            text)))))

;;; ---------------------------------------------------------------------------
;;; Lookup entry points
;;; ---------------------------------------------------------------------------

(defun clhs-lookup-section (section-string &key (include-content t) brief)
  "Look up a section number (e.g., '22.3') in the HyperSpec.
Returns a hash table with section / url / source, plus extracted content
when INCLUDE-CONTENT is true and the page is local. A section that does not
resolve to a local file returns an isError hash-table (no remote content)."
  (let* ((local-path (%section-local-path section-string))
         (is-local (and local-path (probe-file local-path)))
         (filename (%section-to-filename section-string))
         (url (if is-local
                  (format nil "file://~A" local-path)
                  (format nil "http://www.lispworks.com/documentation/HyperSpec/Body/~A"
                          filename))))
    (unless is-local
      (log-event :warn "clhs" "action" "section not found locally"
                 "section" section-string)
      (return-from clhs-lookup-section
        (make-ht "content"
                 (text-content (format nil "Section ~A not found in local HyperSpec index"
                                       section-string))
                 "isError" t)))
    (let ((result (make-ht "section" section-string
                           "url" url
                           "source" (if is-local "local" "remote"))))
      (when (and include-content is-local)
        (let ((content (%extract-text-from-html local-path :brief brief)))
          (when content
            (setf (gethash "content" result) (text-content content)))))
      result)))

(defun clhs-lookup (query &key (include-content t) brief)
  "Look up QUERY in the Common Lisp HyperSpec.
QUERY is either a symbol name ('loop', 'format', 'handler-case') or a section
number ('22.3', '3.1.2'), auto-detected by the digits-and-dots shape.

Returns a result hash-table (section/symbol + url + source + optional content),
or NIL when no HyperSpec resolves at all — the caller surfaces the structured
not-found (D-04) in that case. Signals an error for an unknown symbol when a
HyperSpec IS resolvable; the tool's handler-case maps that to an isError too."
  ;; Fail open: no resolvable HyperSpec -> NIL (the tool builds the D-04 isError).
  (unless (%get-symbol-map)
    (return-from clhs-lookup nil))
  (if (%section-number-p query)
      (clhs-lookup-section query :include-content include-content :brief brief)
      (let* ((normalized (string-upcase (string-trim " " query)))
             (url (%symbol-url query))
             (local-path (%symbol-local-path query))
             (is-local (and local-path (probe-file local-path))))
        (unless url
          (error "No HyperSpec entry found for '~A'. ~
                  Verify it is a standard Common Lisp symbol or valid section number."
                 query))
        (let ((result (make-ht "symbol" (string-downcase normalized)
                               "url" url
                               "source" (if is-local "local" "remote"))))
          (when (and include-content is-local)
            (let ((content (%extract-text-from-html local-path :brief brief)))
              (when content
                (setf (gethash "content" result) (text-content content)))))
          result))))
