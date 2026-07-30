;;;; src/lisp-edit-comment-core.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Locator for comment regions in a Lisp source file: the piece that answers
;;;; "which run of comment lines does this substring name" and "what is the
;;;; comment attached to this form".  Mode-independent (dispatcher-side): it
;;;; reads files and walks the Eclector CST, and never talks to an attached
;;;; Lisp image.
;;;;
;;;; A comment region is a maximal run of comment lines with no blank line
;;;; inside it.  Line comments (any number of semicolons) and block comments
;;;; (#|..|#) group together under one adjacency rule, so a block comment
;;;; followed on the next line by a semicolon comment is a single region.
;;;;
;;;; A run flush against the form below it (no blank line) is that form's
;;;; leading comment and is reached by naming the form, not by substring; a
;;;; blank line between the run and the form makes the run free-standing.
;;;; This is the whole difference between the two addressing modes, and it is
;;;; the reason a file-header comment sitting directly on top of an IN-PACKAGE
;;;; form is reached by naming that form.
;;;;
;;;; Path resolution and the read sandbox are reused from
;;;; dsmr-mcp/src/lisp-edit-form-core rather than reimplemented, so both
;;;; editing families share one set of sandbox semantics.

(defpackage #:dsmr-mcp/src/lisp-edit-comment-core
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/cst
                #:cst-node
                #:cst-node-kind
                #:cst-node-value
                #:cst-node-start
                #:cst-node-end
                #:cst-node-start-line
                #:cst-node-end-line
                #:parse-top-level-forms)
  (:import-from #:dsmr-mcp/src/lisp-edit-form-core
                #:%locate-target-form
                #:%normalize-paths)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path)
  (:import-from #:dsmr-mcp/src/fs
                #:read-file-string)
  (:export #:%comment-regions
           #:%comment-runs
           #:%leading-comment-run
           #:%match-region-by-substring
           #:%locate-comment-regions
           #:%region-first-node
           #:%region-last-node
           #:%region-text
           #:%region-line-range
           #:%region-anchor-form
           #:%true-end-line))

(in-package #:dsmr-mcp/src/lisp-edit-comment-core)

;;;; -------------------------------------------------------------------------
;;;; Comment node recognition
;;;; -------------------------------------------------------------------------

(defun %comment-reason-p (value)
  "Return T when VALUE, the CST-NODE-VALUE of a :SKIPPED node, tags a comment.
Comments are line comments, whose value is a cons of :LINE-COMMENT and the
semicolon count, and block comments, whose value is :BLOCK-COMMENT.

Everything else Eclector reports as skipped input is deliberately excluded:
#; datum comments (:S-EXPRESSION-COMMENT) and #+/#- reader-conditional skips
(a cons of :SHARPSIGN-PLUS or :SHARPSIGN-MINUS) suppress a form rather than
carry prose, so editing them is a form edit, and a bare :READER-MACRO skip is
not comment text either."
  (or (and (consp value) (eq (car value) :line-comment))
      (eq value :block-comment)))

(defun %comment-node-p (node)
  "Return T when NODE is a CST node holding comment text."
  (and (typep node 'cst-node)
       (eq (cst-node-kind node) :skipped)
       (%comment-reason-p (cst-node-value node))))

;;;; -------------------------------------------------------------------------
;;;; Line adjacency
;;;; -------------------------------------------------------------------------

(defun %true-end-line (node)
  "Return the last source line NODE actually occupies.

For a line comment CST-NODE-END-LINE is always one past the comment, because
the semicolon reader consumes the line's trailing newline as part of the node,
putting the node's end offset on the following line.  A line comment occupies
exactly one line, so its start line is its true end line.  Block comments have
no such skew and end on the line carrying their closing delimiter.

Reading CST-NODE-END-LINE directly for both styles is what makes a
blank-line test pass for one style and fail for the other."
  (if (and (consp (cst-node-value node))
           (eq (car (cst-node-value node)) :line-comment))
      (cst-node-start-line node)
      (cst-node-end-line node)))

(defun %contiguous-p (earlier later)
  "Return T when LATER starts on the line right after EARLIER ends.
That is the same as saying no blank line separates the two nodes.  The test
holds uniformly for line comments, block comments, and forms, which is why it
answers both 'is this run maximal' and 'is this run attached to that form'.

A byte-gap comparison cannot replace this: a line comment's span already
includes its own trailing newline while a block comment's does not, so the
byte distance to whatever follows differs by style even when the lines are
adjacent."
  (= (1+ (%true-end-line earlier)) (cst-node-start-line later)))

;;;; -------------------------------------------------------------------------
;;;; Regions
;;;; -------------------------------------------------------------------------

(defun %make-region (first-node last-node original)
  "Build a region from FIRST-NODE through LAST-NODE over the text ORIGINAL.
A region is a list of the first node, the last node, and the exact source text
spanning them.  The text runs from FIRST-NODE's start offset to LAST-NODE's end
offset and no further, so a splice built from it never reaches into the
whitespace separating the run from its neighbours."
  (list first-node last-node
        (subseq original (cst-node-start first-node) (cst-node-end last-node))))

(defun %region-first-node (region)
  "Return the CST node opening REGION."
  (first region))

(defun %region-last-node (region)
  "Return the CST node closing REGION."
  (second region))

(defun %region-text (region)
  "Return REGION's exact source text."
  (third region))

(defun %region-line-range (region)
  "Return REGION's first and last source line as two values, both 1-based."
  (values (cst-node-start-line (%region-first-node region))
          (%true-end-line (%region-last-node region))))

(defun %comment-runs (nodes original)
  "Return every maximal comment run in NODES, in source order.
NODES are the CST nodes of ORIGINAL as returned by PARSE-TOP-LEVEL-FORMS.  A
run ends at the first blank line or the first node that is not comment text.
Runs attached to the form below them are included here; %COMMENT-REGIONS
filters those out."
  (let ((runs nil)
        (pending nil))
    (flet ((close-run ()
             (when pending
               (let ((ordered (nreverse pending)))
                 (push (%make-region (first ordered) (car (last ordered)) original)
                       runs))
               (setf pending nil))))
      (dolist (node nodes)
        (cond
          ((not (%comment-node-p node))
           (close-run))
          ((and pending (not (%contiguous-p (first pending) node)))
           (close-run)
           (push node pending))
          (t
           (push node pending))))
      (close-run))
    (nreverse runs)))

(defun %region-anchor-form (nodes region)
  "Return the form REGION is the leading comment of, or NIL when free-standing.
The answer is the node right after REGION in NODES when that node is a form
and no blank line separates the two.  Anything else, including end of file and
a suppressed form, leaves REGION free-standing."
  (let* ((last-node (%region-last-node region))
         (position (position last-node nodes))
         (next (and position (nth (1+ position) nodes))))
    (when (and next
               (eq (cst-node-kind next) :expr)
               (%contiguous-p last-node next))
      next)))

(defun %comment-regions (nodes original)
  "Return the free-standing comment regions of ORIGINAL, in source order.
These are the maximal comment runs no form claims as its leading comment, and
they are the unit substring anchoring addresses.  A run flush against the form
below it is that form's leading comment and is reached through
%LEADING-COMMENT-RUN instead, so it does not appear here."
  (remove-if (lambda (region) (%region-anchor-form nodes region))
             (%comment-runs nodes original)))

;;;; -------------------------------------------------------------------------
;;;; Leading comment of a form
;;;; -------------------------------------------------------------------------

(defun %leading-comment-run (nodes target)
  "Return the comment run attached above TARGET, or NIL when it has none.
NODES are the CST nodes of the file in source order and TARGET is one of them.
The walk goes backwards from TARGET and stops at the first blank line, the
first node that is not comment text, or the start of the file, so the result
is the maximal run sitting flush on top of TARGET.  A blank line anywhere
between the run and TARGET means TARGET has no leading comment and the run is
a free-standing banner instead."
  (let ((position (position target nodes)))
    (when position
      (let ((ordered (coerce nodes 'vector))
            (run nil)
            (index (1- position)))
        (loop
          (when (minusp index)
            (return))
          (let ((candidate (aref ordered index)))
            (unless (and (%comment-node-p candidate)
                         (%contiguous-p candidate (or (first run) target)))
              (return))
            (push candidate run)
            (decf index)))
        run))))

;;;; -------------------------------------------------------------------------
;;;; Substring anchoring
;;;; -------------------------------------------------------------------------

(defun %region-summary-line (region)
  "Return REGION's first source line, trimmed, for use in an error report."
  (let* ((text (%region-text region))
         (break (position #\Newline text)))
    (string-trim '(#\Space #\Tab #\Return)
                 (subseq text 0 (or break (length text))))))

(defun %describe-region-candidate (region index)
  "Return a one-line description of REGION for an error report.
INDEX is the region's position among the candidates being listed."
  (multiple-value-bind (start-line end-line) (%region-line-range region)
    (format nil "[~D] lines ~D-~D: ~A"
            index start-line end-line (%region-summary-line region))))

(defun %describe-region-candidates (regions)
  "Return a list of one-line descriptions for REGIONS, numbered from zero."
  (loop for region in regions
        for index from 0
        collect (%describe-region-candidate region index)))

(defun %region-overlaps-lines-p (region line-start line-end)
  "Return T when REGION covers any line in the inclusive range LINE-START to
LINE-END.  A null LINE-END means the range is the single line LINE-START."
  (multiple-value-bind (region-start region-end) (%region-line-range region)
    (let ((low line-start)
          (high (or line-end line-start)))
      (and (<= region-start high)
           (>= region-end low)))))

(defun %match-region-by-substring (regions substring &optional line-start line-end)
  "Return the one region in REGIONS whose text contains SUBSTRING.
When SUBSTRING appears in more than one region and LINE-START is supplied, the
candidates are narrowed to those overlapping the line range before deciding.

Signals an error listing every candidate when SUBSTRING matches no region or
still matches more than one, so an anchor that does not name exactly one
region can never resolve to a target."
  (let ((hits (remove-if-not (lambda (region) (search substring (%region-text region)))
                             regions)))
    (when (and (rest hits) line-start)
      (setf hits (remove-if-not (lambda (region)
                                  (%region-overlaps-lines-p region line-start line-end))
                                hits)))
    (cond
      ((null hits)
       (error "No comment region contains ~S. Regions available:~%~{  ~A~%~}"
              substring (%describe-region-candidates regions)))
      ((null (rest hits))
       (first hits))
      (t
       (error "~S matches ~D comment regions. Narrow it with a longer ~
substring or a line range:~%~{  ~A~%~}"
              substring (length hits) (%describe-region-candidates hits))))))

;;;; -------------------------------------------------------------------------
;;;; Prologue
;;;; -------------------------------------------------------------------------

(defun %locate-comment-regions (file-path readtable session-root)
  "Read and parse FILE-PATH, returning its free-standing comment regions.

This is the prologue for substring anchoring, which has no form to name and so
cannot go through %LOCATE-TARGET-FORM.  SESSION-ROOT is the session's project
root, passed explicitly rather than read from a global, and FILE-PATH must
resolve inside the read allow-list.

Returns five values:
  ABS      -- absolute pathname of the file
  REL      -- project-relative namestring, for writes via ENSURE-WRITE-PATH
  ORIGINAL -- full file text
  NODES    -- parsed CST nodes in source order
  REGIONS  -- free-standing comment regions in source order"
  (multiple-value-bind (abs rel) (%normalize-paths file-path session-root)
    (let ((pn (allowed-read-path (namestring abs) session-root)))
      (unless pn
        (error "~A is outside the read allow-list (root: ~A)"
               file-path session-root))
      (let* ((original (read-file-string pn))
             (nodes (parse-top-level-forms original
                                           :readtable readtable
                                           :source-path pn)))
        (values pn rel original nodes (%comment-regions nodes original))))))
