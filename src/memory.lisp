;;;; src/memory.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Finding and reading Claude Code memory pages: which store belongs to a
;;;; session, which files in a store may be read, and what a page's
;;;; frontmatter says about its status.

(defpackage #:dsmr-mcp/src/memory
  (:use #:cl)
  (:import-from #:cl-ppcre
                #:split
                #:scan
                #:all-matches
                #:create-scanner
                #:quote-meta-chars)
  (:import-from #:dsmr-mcp/src/log
                #:log-event)
  (:import-from #:sb-posix)
  (:export #:*claude-config-dir*
           #:claude-config-dir
           #:projects-directory
           #:store-name-for
           #:repository-root
           #:project-store-directory
           #:memory-page-path
           #:list-store-pages
           #:parse-frontmatter
           #:read-memory-page
           #:memory-page
           #:memory-page-p
           #:page-file
           #:page-store
           #:page-name
           #:page-description
           #:page-status
           #:page-status-reason
           #:page-updated
           #:page-lines
           #:page-body-start
           #:retired-status-p
           #:search-memory
           #:*search-time-limit*
           #:memory-search-aborted
           #:search-abort-reason
           #:memory-search-outcome
           #:memory-search-outcome-p
           #:outcome-hits
           #:outcome-total
           #:outcome-limited
           #:outcome-coverage
           #:memory-hit
           #:memory-hit-p
           #:hit-page
           #:hit-tier
           #:hit-body-hits
           #:hit-excerpts
           #:hit-retired))

(in-package #:dsmr-mcp/src/memory)

;;; ---------------------------------------------------------------------------
;;; Where the stores live
;;; ---------------------------------------------------------------------------

(defvar *claude-config-dir* nil
  "When non-NIL, the Claude config directory to use instead of the
environment. Tests bind it to a fixture so the real config is never read.")

(defun %safe-truename (path)
  "The truename of PATH, or NIL when it does not exist or cannot be resolved."
  (and path (ignore-errors (truename path))))

(defun claude-config-dir ()
  "The Claude config directory as a directory pathname: *CLAUDE-CONFIG-DIR*
when bound, else a non-empty $CLAUDE_CONFIG_DIR, else ~/.claude/. The harness
honours the same variable, so a relocated config is followed here too."
  (let ((env (uiop:getenv "CLAUDE_CONFIG_DIR")))
    (cond (*claude-config-dir*
           (uiop:ensure-directory-pathname *claude-config-dir*))
          ((and env (plusp (length env)))
           (uiop:ensure-directory-pathname (uiop:parse-native-namestring env)))
          (t (merge-pathnames ".claude/" (user-homedir-pathname))))))

(defun projects-directory ()
  "The truename of <config>/projects/, or NIL when it does not exist."
  (let ((dir (%safe-truename (merge-pathnames "projects/" (claude-config-dir)))))
    (and dir (uiop:directory-exists-p dir) dir)))

;;; ---------------------------------------------------------------------------
;;; Store naming and the repository root
;;; ---------------------------------------------------------------------------

(defun %ascii-alnum-p (char)
  "True for ASCII letters and digits only. The standard alphanumeric
predicate accepts non-ASCII letters too, and the harness maps those to a
hyphen, so it would derive the wrong store name."
  (let ((code (char-code char)))
    (or (<= 48 code 57) (<= 65 code 90) (<= 97 code 122))))

(defun store-name-for (directory)
  "The store name the harness derives for DIRECTORY: its native path with the
trailing slash removed and every character outside ASCII letters and digits
replaced by a hyphen."
  (let* ((native (uiop:native-namestring (uiop:ensure-directory-pathname directory)))
         (trimmed (if (and (> (length native) 1)
                           (char= #\/ (char native (1- (length native)))))
                      (subseq native 0 (1- (length native)))
                      native)))
    (map 'string (lambda (c) (if (%ascii-alnum-p c) c #\-)) trimmed)))

(defun %git-marker-p (dir)
  "True when DIR holds a .git entry, either a directory or a file."
  (ignore-errors
   (or (uiop:directory-exists-p (merge-pathnames ".git/" dir))
       (probe-file (merge-pathnames ".git" dir)))))

(defun %first-line (file)
  "The first line of FILE, trimmed of surrounding whitespace, or NIL."
  (ignore-errors
   (with-open-file (in file :external-format '(:utf-8 :replacement #\?))
     (let ((line (read-line in nil nil)))
       (and line (string-trim '(#\Space #\Tab #\Return #\Newline) line))))))

(defun %resolve-dir-text (text base)
  "Resolve the directory named by TEXT, taken relative to BASE when it is not
absolute. Returns a truename, or NIL when it does not exist."
  (when (and text (plusp (length text)))
    (let ((pn (uiop:ensure-directory-pathname (uiop:parse-native-namestring text))))
      (%safe-truename (if (uiop:absolute-pathname-p pn)
                          pn
                          (uiop:merge-pathnames* pn base))))))

(defun %root-from-marker (dir)
  "The repository root for DIR, which holds a .git entry. A .git directory
makes DIR the root. A .git file names the real git directory; when that
directory carries a commondir file (a linked worktree), the common directory
it names is the main checkout's .git, and its parent is the root. Anything
that cannot be followed leaves DIR as the root."
  (if (uiop:directory-exists-p (merge-pathnames ".git/" dir))
      dir
      (let* ((line (%first-line (merge-pathnames ".git" dir)))
             (gitdir (and line
                          (> (length line) 7)
                          (string-equal "gitdir:" line :end2 7)
                          (%resolve-dir-text (string-trim " " (subseq line 7)) dir)))
             (common (and gitdir
                          (%resolve-dir-text
                           (%first-line (merge-pathnames "commondir" gitdir))
                           gitdir))))
        (if (and common
                 (equal ".git" (car (last (pathname-directory common)))))
            (uiop:pathname-parent-directory-pathname common)
            dir))))

(defun repository-root (directory)
  "The root of the git repository holding DIRECTORY, found by walking up to
the first directory with a .git entry. A linked worktree maps back to its main
checkout, so every worktree of a repository shares one store. DIRECTORY itself
is returned when no .git exists above it. Reads files only, runs no git
process, and never signals."
  (let* ((start (uiop:ensure-directory-pathname directory))
         (start (or (%safe-truename start) start))
         (components (pathname-directory start)))
    (or (ignore-errors
         (loop for n from (length components) downto 1
               for dir = (make-pathname :directory (subseq components 0 n)
                                        :name nil :type nil :version nil
                                        :defaults start)
               when (%git-marker-p dir)
                 return (%root-from-marker dir)))
        start)))

(defun project-store-directory (session-root)
  "The memory store directory for SESSION-ROOT, whether or not it exists:
<config>/projects/<store name of the repository root>/memory/. Nothing is
cached, because the config dir and the stores can change during a session."
  (let* ((dir (uiop:ensure-directory-pathname session-root))
         (root (repository-root (or (%safe-truename dir) dir))))
    (merge-pathnames (make-pathname :directory (list :relative "projects"
                                                     (store-name-for root)
                                                     "memory"))
                     (claude-config-dir))))

;;; ---------------------------------------------------------------------------
;;; Read confinement
;;; ---------------------------------------------------------------------------

(defun %regular-file-p (path)
  "True when PATH, already resolved, is a regular file. A named pipe or a
device node named like a page would block the read that follows, so anything
but a regular file is refused."
  (ignore-errors
   (sb-posix:s-isreg (sb-posix:stat-mode (sb-posix:stat (uiop:native-namestring path))))))

(defun memory-page-path (file projects-dir)
  "The resolved pathname of FILE when it is a memory page, else NIL.
A memory page is a regular file of type exactly md sitting directly inside
<store>/memory/ under PROJECTS-DIR. Both paths are resolved before the
containment test, so a symlink inside a store cannot reach a file outside the
projects directory. This check is separate from the general read allow-list on
purpose: memory stores are readable here and nowhere else."
  (let ((resolved (%safe-truename file))
        (root (and projects-dir
                   (%safe-truename (uiop:ensure-directory-pathname projects-dir)))))
    (when (and resolved root
               (pathname-name resolved)
               (not (ignore-errors (uiop:directory-exists-p resolved)))
               (%regular-file-p resolved)
               (equal "md" (pathname-type resolved))
               (uiop:subpathp resolved root))
      (let ((below (nthcdr (length (pathname-directory root))
                           (pathname-directory resolved))))
        (when (and (= 2 (length below))
                   (equal "memory" (second below)))
          resolved)))))

(defun list-store-pages (store-dir projects-dir)
  "List the readable pages directly inside STORE-DIR. Returns three values:
the resolved page pathnames sorted by filename; an alist from skip reason to
count, the reasons being :INDEX (MEMORY.md, or a link that resolves to it,
which the harness already loads every session), :NOT-MARKDOWN (type not
exactly md, such as a .md.bak copy) and :OUTSIDE-STORE (refused by
MEMORY-PAGE-PATH); and the number of subdirectories left unsearched. Stores
are flat, so the listing does not recurse. A missing store yields no pages."
  (let ((dir (%safe-truename (uiop:ensure-directory-pathname store-dir)))
        (pages '())
        (skipped '()))
    (flet ((skip (reason)
             (let ((cell (assoc reason skipped)))
               (if cell
                   (incf (cdr cell))
                   (push (cons reason 1) skipped)))))
      (unless dir
        (return-from list-store-pages (values '() '() 0)))
      (dolist (file (ignore-errors (uiop:directory-files dir)))
        (cond ((and (equal "MEMORY" (pathname-name file))
                    (equal "md" (pathname-type file)))
               (skip :index))
              ((not (equal "md" (pathname-type file)))
               (skip :not-markdown))
              (t
               (let ((page (memory-page-path file projects-dir)))
                 (cond ((null page) (skip :outside-store))
                       ;; A link to the index is still the index.
                       ((equal "MEMORY" (pathname-name page)) (skip :index))
                       (t (push (cons (file-namestring file) page) pages)))))))
      (values (mapcar #'cdr (sort pages #'string< :key #'car))
              (nreverse skipped)
              (length (ignore-errors (uiop:subdirectories dir)))))))

;;; ---------------------------------------------------------------------------
;;; Frontmatter
;;;
;;; The reader is line oriented and deliberately lenient. Real pages carry
;;; plain values with an embedded ": " or a "#", which a strict YAML parser
;;; rejects or truncates, and a page with broken frontmatter must still be
;;; readable as body. It never signals.
;;; ---------------------------------------------------------------------------

(defparameter *frontmatter-scan-limit* 200
  "How many lines to look through for the closing delimiter before deciding
the page has no frontmatter.")

(defun %split-lines (text)
  "Split TEXT into a list of lines, dropping a trailing carriage return from
each. A final newline does not produce an extra empty line."
  (let ((lines '())
        (start 0)
        (len (length text)))
    (loop for pos = (position #\Newline text :start start)
          while pos
          do (push (subseq text start pos) lines)
             (setf start (1+ pos)))
    (when (< start len)
      (push (subseq text start) lines))
    (mapcar (lambda (line)
              (if (and (plusp (length line))
                       (char= #\Return (char line (1- (length line)))))
                  (subseq line 0 (1- (length line)))
                  line))
            (nreverse lines))))

(defun %trim (string)
  "STRING without surrounding spaces and tabs."
  (string-trim '(#\Space #\Tab) string))

(defun %unquote-double (string)
  "The value of the double-quoted scalar STRING, which starts with a quote.
Handles the escapes real pages use; an unknown escape is kept as written and
a missing closing quote takes the rest of the line."
  (with-output-to-string (out)
    (let ((i 1)
          (len (length string)))
      (loop while (< i len)
            do (let ((c (char string i)))
                 (cond ((char= c #\")
                        (return))
                       ((and (char= c #\\) (< (1+ i) len))
                        (let ((next (char string (1+ i))))
                          (incf i 2)
                          (case next
                            (#\n (write-char #\Newline out))
                            (#\t (write-char #\Tab out))
                            (#\r (write-char #\Return out))
                            ((#\" #\\ #\/) (write-char next out))
                            (#\u
                             (let ((code (and (<= (+ i 4) len)
                                              (parse-integer string :start i :end (+ i 4)
                                                                    :radix 16 :junk-allowed t))))
                               (if code
                                   (progn (write-char (code-char code) out)
                                          (incf i 4))
                                   (write-string "\\u" out))))
                            (t (write-char #\\ out)
                               (write-char next out)))))
                       (t (write-char c out)
                          (incf i))))))))

(defun %unquote-single (string)
  "The value of the single-quoted scalar STRING, which starts with a quote.
A doubled quote stands for one quote; a missing closing quote takes the rest."
  (with-output-to-string (out)
    (let ((i 1)
          (len (length string)))
      (loop while (< i len)
            do (let ((c (char string i)))
                 (cond ((and (char= c #\') (< (1+ i) len)
                             (char= #\' (char string (1+ i))))
                        (write-char #\' out)
                        (incf i 2))
                       ((char= c #\')
                        (return))
                       (t (write-char c out)
                          (incf i))))))))

(defun %scalar-value (raw)
  "The string value of the scalar text RAW, or NIL when it is empty. Quoted
scalars are unquoted, and an empty quoted value such as \"\" is no value at
all; a plain scalar is taken whole, with no comment stripping, because real
values contain a # that is part of the text."
  (let* ((s (and raw (%trim raw)))
         (value (cond ((or (null s) (zerop (length s))) nil)
                      ((char= #\" (char s 0)) (%unquote-double s))
                      ((char= #\' (char s 0)) (%unquote-single s))
                      (t s))))
    (and value (plusp (length value)) value)))

(defun %parse-flow-list (raw)
  "The items of the flow sequence RAW, written [a, b], as a list of strings."
  (let* ((s (%trim raw))
         (close (position #\] s :from-end t))
         (inner (subseq s 1 (or close (length s)))))
    (remove nil (mapcar #'%scalar-value (split "," inner)))))

(defun %item-line-p (trimmed)
  "True when TRIMMED is a block sequence item such as - value."
  (or (string= "-" trimmed)
      (and (> (length trimmed) 1) (string= "- " trimmed :end2 2))))

(defun %parse-entries (lines)
  "Read frontmatter LINES into a list of entries (KEY KIND DATA). KIND is
:SCALAR with the raw value text, :SEQ with a list of raw item texts, :MAP with
an alist of subkey to raw value text, or :EMPTY for a key with nothing under
it. A key with an empty value opens a block one level deep; lines that fit no
shape are ignored."
  (let ((entries '())
        (open nil))
    (dolist (line lines (nreverse entries))
      (let ((trimmed (%trim line)))
        (cond
          ((zerop (length trimmed)))
          ((and open
                (%item-line-p trimmed)
                (member (second open) '(:empty :seq)))
           (setf (second open) :seq)
           (setf (third open) (append (third open) (list (subseq trimmed 1)))))
          ((member (char line 0) '(#\Space #\Tab))
           (let ((colon (position #\: trimmed)))
             (when (and open colon (plusp colon)
                        (member (second open) '(:empty :map)))
               (setf (second open) :map)
               (push (cons (%trim (subseq trimmed 0 colon))
                           (subseq trimmed (1+ colon)))
                     (third open)))))
          ((char= #\# (char line 0)))
          (t
           (let ((colon (position #\: line)))
             (setf open nil)
             (when (and colon (plusp colon))
               (let* ((key (%trim (subseq line 0 colon)))
                      (rest (subseq line (1+ colon)))
                      (entry (if (zerop (length (%trim rest)))
                                 (list key :empty nil)
                                 (list key :scalar rest))))
                 (push entry entries)
                 (when (eq :empty (second entry))
                   (setf open entry)))))))))))

(defun %entry (key entries)
  "The last entry for KEY in ENTRIES, or NIL."
  (find key entries :key #'first :test #'string= :from-end t))

(defun %entry-string (key entries)
  "The string value of the scalar entry for KEY, or NIL."
  (let ((entry (%entry key entries)))
    (and entry (eq :scalar (second entry)) (%scalar-value (third entry)))))

(defun %strip-comment (string)
  "STRING without a trailing YAML comment: from the first # that starts the
text or follows a space or tab. A # inside a word is kept."
  (let ((hash (loop for i from 0 below (length string)
                    when (and (char= #\# (char string i))
                              (or (zerop i)
                                  (member (char string (1- i)) '(#\Space #\Tab))))
                      return i)))
    (if hash (subseq string 0 hash) string)))

(defun %status-scalar (raw)
  "The status value in the scalar text RAW, or NIL. A plain value loses a
trailing comment, which the lenient reading of free text keeps, because a
status is a single word and a comment after it must not stop it being
recognised."
  (let ((s (and raw (%trim raw))))
    (cond ((or (null s) (zerop (length s))) nil)
          ((member (char s 0) '(#\" #\')) (%scalar-value s))
          (t (%scalar-value (%strip-comment s))))))

(defun %status-from-raw (raw)
  "A status list from the raw scalar text RAW: a flow list gives its items, a
single value gives a one-element list. Values are kept exactly as written,
apart from a trailing comment, because a value this reader does not know must
still reach whoever reads the result."
  (let ((s (and raw (%trim raw))))
    (cond ((or (null s) (zerop (length s))) nil)
          ((char= #\[ (char s 0)) (%parse-flow-list (%strip-comment s)))
          (t (let ((value (%status-scalar s)))
               (and value (list value)))))))

(defun %entries-status (entries)
  "The status list from ENTRIES: the top-level status key first, falling back
to a status key inside the metadata block."
  (let ((top (%entry "status" entries))
        (metadata (%entry "metadata" entries)))
    (cond ((and top (eq :scalar (second top)))
           (%status-from-raw (third top)))
          ((and top (eq :seq (second top)))
           (remove nil (mapcar #'%status-scalar (third top))))
          ((and metadata (eq :map (second metadata)))
           (%status-from-raw
            (cdr (assoc "status" (third metadata) :test #'string=)))))))

(defun %strip-bom (text)
  "TEXT without a leading byte order mark. The UTF-8 decoder keeps it as a
character, and left in place it hides the opening delimiter."
  (if (and (plusp (length text))
           (char= (char text 0) (code-char #xFEFF)))
      (subseq text 1)
      text))

(defun parse-frontmatter (text)
  "Read the frontmatter of page TEXT. Returns two values: a plist
(:FRONTMATTER-P :NAME :DESCRIPTION :STATUS :STATUS-REASON :UPDATED) and the
1-based line number of the first body line. Frontmatter exists only when line
1 is ---, after any byte order mark, and a closing --- or ... follows within
the scan limit; otherwise the whole text is body. STATUS is a list of the
values exactly as written, or NIL when the page states none. The harness's
own metadata block is read for a status fallback only; its modified time is
the harness's write time, not the author's update time, so it is not reported
as UPDATED. Never signals."
  (flet ((no-frontmatter ()
           (values (list :frontmatter-p nil :name nil :description nil
                         :status nil :status-reason nil :updated nil)
                   1)))
    (handler-case
        (let* ((lines (%split-lines (%strip-bom text)))
               (delimiter-p (lambda (line)
                              (member (string-right-trim '(#\Space #\Tab) line)
                                      '("---" "...") :test #'string=)))
               (close (and lines
                           (string= "---" (string-right-trim '(#\Space #\Tab)
                                                             (first lines)))
                           (position-if delimiter-p lines
                                        :start 1
                                        :end (min (length lines)
                                                  (1+ *frontmatter-scan-limit*))))))
          (if (null close)
              (no-frontmatter)
              (let ((entries (%parse-entries (subseq lines 1 close))))
                (values (list :frontmatter-p t
                              :name (%entry-string "name" entries)
                              :description (%entry-string "description" entries)
                              :status (%entries-status entries)
                              :status-reason (%entry-string "status_reason" entries)
                              :updated (%entry-string "updated" entries))
                        (+ close 2)))))
      (error () (no-frontmatter)))))

;;; ---------------------------------------------------------------------------
;;; Pages
;;; ---------------------------------------------------------------------------

(defstruct (memory-page (:conc-name page-))
  "One memory page as read from disk. LINES holds every line of the file,
frontmatter included, so a line number counts from the top of the file and an
agent can open the file at it; a search clears it on the pages it returns once
their excerpts are taken. BODY-START is the 1-based first body line."
  file store name description status status-reason updated lines body-start)

(defun read-memory-page (path store-name &key (max-chars 262144))
  "Read the page at PATH, which belongs to the store STORE-NAME. Returns two
values: a MEMORY-PAGE, or NIL when the file cannot be read, and true when the
read stopped at MAX-CHARS characters. Invalid UTF-8 is replaced rather than
refused, and the size cap keeps one oversized page from stalling a search.
The buffer is sized to the file, since a UTF-8 file never decodes to more
characters than it has bytes, so a small page costs only its own size. The
name falls back to the filename stem."
  (handler-case
      (with-open-file (in path :external-format '(:utf-8 :replacement #\?))
        (let* ((buffer (make-string (max 0 (min max-chars (file-length in)))))
               (count (read-sequence buffer in))
               (capped (and (= count (length buffer))
                            (peek-char nil in nil nil)
                            t))
               (text (%strip-bom (if (= count (length buffer))
                                     buffer
                                     (subseq buffer 0 count)))))
          (multiple-value-bind (plist body-start) (parse-frontmatter text)
            (values (make-memory-page
                     :file path
                     :store store-name
                     :name (or (getf plist :name) (pathname-name path))
                     :description (getf plist :description)
                     :status (getf plist :status)
                     :status-reason (getf plist :status-reason)
                     :updated (getf plist :updated)
                     :lines (coerce (%split-lines text) 'simple-vector)
                     :body-start body-start)
                    capped))))
    (error () (values nil nil))))

(defun retired-status-p (status-list)
  "True when STATUS-LIST holds obsolete, superseded or refuted in any letter
case: the values that say a page should no longer be relied on."
  (some (lambda (status)
          (member status '("obsolete" "superseded" "refuted") :test #'string-equal))
        status-list))

;;; ---------------------------------------------------------------------------
;;; Search
;;;
;;; Everything here only reads. A search walks every page of every store in
;;; scope, because ranking needs every match before the result is sliced, and
;;; it records what it read so an empty answer can be told apart from a store
;;; that does not exist.
;;; ---------------------------------------------------------------------------

(defstruct (memory-hit (:conc-name hit-))
  "One page that matched a search. TIER is 0 when every term matches the
filename, name or description, 1 when at least one does, and 2 when only the
body matches. BODY-HITS counts matches over body lines. EXCERPTS is a list of
plists (:LINE n :TEXT s :MATCH bool) numbered from the top of the file.
RETIRED is true when the page's status says it should no longer be relied on."
  page tier body-hits excerpts retired)

(defstruct (memory-search-outcome (:conc-name outcome-))
  "The result of a search. HITS is the ranked slice asked for, TOTAL the
number of matching pages before slicing, LIMITED true when matches lie beyond
the end of the slice, and COVERAGE a plist recording what was searched."
  hits total limited coverage)

(defun %query-terms (query)
  "The whitespace-separated terms of QUERY, empty ones dropped."
  (remove "" (split "\\s+" (or query "")) :test #'string=))

(defun %term-scanners (terms regex)
  "A case-insensitive scanner for each of TERMS. Without REGEX each term is
matched literally. A malformed regular expression signals the regex
library's syntax error, which reaches the caller unchanged."
  (mapcar (lambda (term)
            (create-scanner (if regex term (quote-meta-chars term))
                            :case-insensitive-mode t))
          terms))

(defun %resolve-stores (scope session-root)
  "The stores SCOPE covers, as a list of (name . directory). Scope project
gives the one store derived from SESSION-ROOT, whether or not it exists.
Scope all gives every existing <projects>/*/memory/ directory, sorted by
store name. Both scopes need SESSION-ROOT: scope all reads other projects'
memory, which a caller with no project of its own is not given."
  (unless (or (string-equal scope "all") (string-equal scope "project"))
    (error "Unknown memory search scope ~S; expected project or all." scope))
  (unless session-root
    (error "A memory search needs a session root, whatever its scope."))
  (if (string-equal scope "all")
      (let ((projects (projects-directory)))
        (sort (loop for sub in (and projects (ignore-errors (uiop:subdirectories projects)))
                    for memory = (%safe-truename (merge-pathnames "memory/" sub))
                    when (and memory (ignore-errors (uiop:directory-exists-p memory)))
                      collect (cons (car (last (pathname-directory sub))) memory))
              #'string< :key #'car))
      (let ((dir (project-store-directory session-root)))
        (list (cons (car (last (butlast (pathname-directory dir)))) dir)))))

(defun %metadata-texts (page)
  "The filename, name and description of PAGE, where present."
  (remove nil (list (file-namestring (page-file page))
                    (page-name page)
                    (page-description page))))

(defparameter *excerpt-line-limit* 240
  "The longest excerpt line returned; longer lines are cut to this length.")

(defun %excerpt-text (text start)
  "TEXT cut to at most *EXCERPT-LINE-LIMIT* characters. START is where the
first match on the line begins, or NIL for a context line; when the match
would fall past the cut, the window slides along the line so the match stays
in view."
  (let ((limit *excerpt-line-limit*)
        (len (length text)))
    (if (<= len limit)
        text
        (let ((from (if start
                        (min (- len limit) (max 0 (- start 40)))
                        0)))
          (subseq text from (+ from limit))))))

(defun %match-page (page scanners context lines-per-page)
  "The MEMORY-HIT for PAGE when every one of SCANNERS matches its filename,
name, description or body, else NIL. Each body line is scanned once per
scanner, and that one pass yields the match test, the body hit count and the
excerpts, so an expensive pattern costs one scan of the page, not several.
The tier is 0 when every scanner matches the metadata, 1 when some do and 2
when none does. Excerpts are the first LINES-PER-PAGE matching body lines,
each with CONTEXT body lines either side; overlapping windows merge into one
run with no line repeated. Each excerpt is a plist (:LINE n :TEXT s :MATCH
bool), where n counts from the top of the file so an agent can open the file
at that line, and MATCH marks the selected matching lines."
  (let* ((metadata (%metadata-texts page))
         (lines (page-lines page))
         (first-line (page-body-start page))
         (last-line (length lines))
         (in-metadata (mapcar (lambda (scanner)
                                (and (some (lambda (text) (scan scanner text)) metadata) t))
                              scanners))
         (in-body (make-list (length scanners) :initial-element nil))
         (body-hits 0)
         (matching '()))
    (loop for index from (1- first-line) below last-line
          for text = (svref lines index)
          do (let ((start nil))
               (loop for scanner in scanners
                     for cell on in-body
                     do (let ((found (all-matches scanner text)))
                          (when found
                            (setf (car cell) t)
                            (incf body-hits (floor (length found) 2))
                            (setf start (if start (min start (first found)) (first found))))))
               (when (and start (< (length matching) lines-per-page))
                 (push (cons (1+ index) start) matching))))
    (when (every (lambda (meta body) (or meta body)) in-metadata in-body)
      (let* ((matched (count t in-metadata))
             (matching (nreverse matching))
             (shown (sort (remove-duplicates
                           (loop for (m) in matching
                                 nconc (loop for n from (max first-line (- m context))
                                               to (min last-line (+ m context))
                                             collect n)))
                          #'<)))
        (make-memory-hit
         :page page
         :tier (cond ((= matched (length scanners)) 0)
                     ((plusp matched) 1)
                     (t 2))
         :body-hits body-hits
         :excerpts (mapcar (lambda (n)
                             (let ((start (cdr (assoc n matching))))
                               (list :line n
                                     :text (%excerpt-text (svref lines (1- n)) start)
                                     :match (and start t))))
                           shown)
         :retired (and (retired-status-p (page-status page)) t))))))

(defun %hit< (a b)
  "True when hit A ranks ahead of hit B: lower tier first, then more body
hits, then store name and filename ascending so the order is repeatable.
Status plays no part, because ranking a retired page lower would push it
past the limit and hide it by another route."
  (let ((ta (hit-tier a)) (tb (hit-tier b))
        (ha (hit-body-hits a)) (hb (hit-body-hits b))
        (sa (page-store (hit-page a))) (sb (page-store (hit-page b))))
    (cond ((/= ta tb) (< ta tb))
          ((/= ha hb) (> ha hb))
          ((string/= sa sb) (string< sa sb))
          (t (string< (file-namestring (page-file (hit-page a)))
                      (file-namestring (page-file (hit-page b))))))))

(defparameter *search-time-limit* 10
  "Seconds a search may run before it stops with MEMORY-SEARCH-ABORTED. The
verb runs where the server reads requests, so while a search runs nothing
else is read; this bounds how long a pattern that backtracks without end, or a
very broad search, can hold the session.")

(define-condition memory-search-aborted (error)
  ((reason :initarg :reason :reader search-abort-reason))
  (:report (lambda (condition stream)
             (format stream "the search stopped because ~A"
                     (search-abort-reason condition))))
  (:documentation "Signalled when a search runs past its time limit or
exhausts the stack or heap. REASON says which, in words a caller can act on."))

(define-condition search-deadline-reached (serious-condition)
  ()
  (:documentation "Signalled into a searching thread when its time runs out.
It is deliberately not an ERROR, so the handlers that turn an unreadable page
into a skipped one cannot swallow it and let the search run on."))

(defun %call-with-deadline (seconds thunk)
  "Call THUNK and return its values, signalling MEMORY-SEARCH-ABORTED instead
when it runs longer than SECONDS or exhausts the stack or heap. A regular
expression can backtrack without end inside a single match, so the bound
interrupts the running match rather than being checked between pages. NIL or
a non-positive SECONDS means no time limit."
  (let ((timer (sb-ext:make-timer (lambda () (error 'search-deadline-reached))
                                  :name "memory-search deadline"
                                  :thread sb-thread:*current-thread*)))
    (handler-case
        (unwind-protect
             (progn
               (when (and seconds (plusp seconds))
                 (sb-ext:schedule-timer timer seconds))
               (funcall thunk))
          (sb-ext:unschedule-timer timer))
      (search-deadline-reached ()
        (error 'memory-search-aborted
               :reason (format nil "it ran longer than ~A second~:P; narrow the ~
terms, simplify the pattern or search one project" seconds)))
      (storage-condition ()
        (error 'memory-search-aborted
               :reason (format nil "it ran out of stack or memory, which a ~
regular expression that backtracks deeply can cause; simplify the pattern"))))))

(defun search-memory (query &key (scope "project") session-root regex hide-retired
                              (limit 20) (offset 0) (context 1) (lines-per-page 3)
                              (time-limit *search-time-limit*))
  "Search memory pages for QUERY and return a MEMORY-SEARCH-OUTCOME.
QUERY is split on whitespace and a page matches when every term matches its
filename, name, description or body, ignoring case. Terms are literal unless
REGEX is true, and a malformed regular expression signals the regex
library's syntax error. SCOPE project searches the store derived from
SESSION-ROOT and scope all searches every store; both signal an error when
SESSION-ROOT is not given.
Hits are ranked by metadata tier, then body hits, then store and filename,
and then sliced by OFFSET and LIMIT; TOTAL counts every match before the
slice, and LIMITED is true only when matches lie beyond the slice. Retired
pages are returned and flagged unless HIDE-RETIRED is true, in which case
they are dropped before counting and the number dropped is reported as
:HIDDEN-RETIRED. LIMIT is clamped to 1..100, OFFSET to at least 0 and
CONTEXT to 0..5. A missing store is not an error: it shows in the coverage
with :EXISTS NIL. A search that runs longer than TIME-LIMIT seconds, or
exhausts the stack or heap, signals MEMORY-SEARCH-ABORTED."
  (let* ((limit (max 1 (min 100 limit)))
         (offset (max 0 offset))
         (context (max 0 (min 5 context)))
         (lines-per-page (max 1 lines-per-page))
         (scanners (%term-scanners (%query-terms query) regex))
         (stores (%resolve-stores scope session-root))
         (projects-dir (projects-directory))
         (store-records '())
         (skipped '())
         (scanned 0)
         (capped 0)
         (subdirectories 0)
         (matches '()))
    (flet ((skip (reason count)
             (let ((cell (assoc reason skipped)))
               (if cell
                   (incf (cdr cell) count)
                   (setf skipped (append skipped (list (cons reason count))))))))
      (%call-with-deadline
       time-limit
       (lambda ()
         (loop for (name . dir) in stores
               for exists = (and (ignore-errors (uiop:directory-exists-p dir)) t)
               do (push (list :name name :path (namestring dir) :exists exists)
                        store-records)
                  (when exists
                    (multiple-value-bind (pages skips subdirs)
                        (list-store-pages dir projects-dir)
                      (incf subdirectories subdirs)
                      (loop for (reason . count) in skips do (skip reason count))
                      (dolist (path pages)
                        (multiple-value-bind (page cappedp) (read-memory-page path name)
                          (cond ((null page) (skip :unreadable 1))
                                (t (incf scanned)
                                   (when cappedp (incf capped))
                                   (let ((hit (and scanners
                                                   (%match-page page scanners context
                                                                lines-per-page))))
                                     (when hit
                                       ;; The excerpts are taken, so the page's
                                       ;; full text need not live until the slice.
                                       (setf (page-lines page) nil)
                                       (push hit matches))))))))))))
      (let* ((shown (if hide-retired (remove-if #'hit-retired matches) matches))
             (hidden (- (length matches) (length shown)))
             (ranked (stable-sort (copy-list shown) #'%hit<))
             (total (length ranked))
             (start (min offset total))
             (slice (subseq ranked start (min total (+ offset limit)))))
        (log-event :debug "memory.search"
                   "scope" (string-downcase scope)
                   "stores" (length stores)
                   "scanned" scanned
                   "matches" total)
        (make-memory-search-outcome
         :hits slice
         :total total
         :limited (< (+ start (length slice)) total)
         :coverage (list :scope (string-downcase scope)
                         :config-dir (namestring (claude-config-dir))
                         :projects-dir (and projects-dir (namestring projects-dir))
                         :stores (nreverse store-records)
                         :pages-scanned scanned
                         :pages-skipped skipped
                         :pages-capped capped
                         :subdirectories-not-searched subdirectories
                         :hidden-retired hidden
                         :limit limit
                         :offset offset))))))
