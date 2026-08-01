;;;; tests/lisp-edit-comment-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for comment-region editing, from locating a region through to
;;;; the write and out to the verb an agent calls: how a maximal comment
;;;; run is collapsed, which runs stand free of any form and which belong
;;;; to the form below them, how substring anchoring refuses to guess, and
;;;; what an edit has to leave untouched.
;;;;
;;;; The file-header cases are here because a reader's intuition and the
;;;; attachment rule disagree about them.  A header separated from the
;;;; first form by a blank line is free-standing; a header sitting flush on
;;;; top of the first form is that form's leading comment and substring
;;;; anchoring will not see it at all.  Both spellings are pinned so
;;;; neither has to be rediscovered.
;;;;
;;;; Three guarantees in the editing tests are easy to lose.  Everything
;;;; around an edited comment must come back byte for byte, and the only
;;;; check that sees a replacement swallowing it is the comparison of the
;;;; re-parsed file; the delimiter scan passes that case.  That comparison
;;;; is written in terms of every node that is not comment text rather than
;;;; in terms of expressions, so the swallow test puts reader-conditional
;;;; definitions in the span being absorbed: they are the case an
;;;; expression-shaped check cannot see, and the file that loses one still
;;;; loads on the machine that made the edit.  Replacement text that leaves
;;;; a delimiter open is refused ahead of all that, and the pair of tests
;;;; either side of that guard is what says where its boundary sits.  And a
;;;; comment written after code on the same line is refused rather than
;;;; edited, because nothing later could catch that: naming the form below
;;;; it and naming a substring of it both reach the same run, so both are
;;;; pinned, and the substring case is pinned for replacing as well as for
;;;; deleting.
;;;;
;;;; The last four tests go through the verb rather than the function under
;;;; it, because what they pin belongs to the verb: refusing to act with no
;;;; project root set, telling an expected anchor failure apart from an
;;;; unexpected one by its error type, and offering no way to insert.

;; Package evolution guard
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/lisp-edit-comment-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/lisp-edit-comment-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/lisp-edit-comment-core
                #:%comment-regions
                #:%comment-runs
                #:%leading-comment-run
                #:%match-region-by-substring
                #:%locate-comment-regions
                #:%region-first-node
                #:%region-last-node
                #:%region-text
                #:%region-line-range
                #:%region-anchor-form
                #:%true-end-line)
  (:import-from #:dsmr-mcp/src/lisp-edit-form-core
                #:%find-target)
  (:import-from #:dsmr-mcp/src/cst
                #:cst-node-kind
                #:cst-node-start
                #:cst-node-end
                #:cst-node-start-line
                #:cst-node-end-line
                #:cst-node-value
                #:parse-top-level-forms)
  (:import-from #:dsmr-mcp/src/lisp-edit-comment
                #:edit-comment
                #:comment-operation-error
                #:comment-operation-reason)
  (:import-from #:dsmr-mcp/src/validate
                #:scan-parens
                #:try-reader-check)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle)
  (:import-from #:dsmr-mcp/src/tools/lisp-edit-comment)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/lisp-edit-comment-test)

;;;; -------------------------------------------------------------------------
;;;; Helpers
;;;; -------------------------------------------------------------------------

(defun nodes-of (source)
  "Parse SOURCE and return its CST nodes in source order."
  (parse-top-level-forms source))

(defun region-texts (source)
  "Return the text of every free-standing comment region in SOURCE."
  (mapcar #'%region-text (%comment-regions (nodes-of source) source)))

(defun run-texts (source)
  "Return the text of every maximal comment run in SOURCE, attached or not."
  (mapcar #'%region-text (%comment-runs (nodes-of source) source)))

(defun node-text (source node)
  "Return NODE's exact source text out of SOURCE."
  (subseq source (cst-node-start node) (cst-node-end node)))

(defun error-from (thunk)
  "Call THUNK and return the error it signalled, or NIL when it returned."
  (handler-case (progn (funcall thunk) nil)
    (error (e) e)))

(defun make-args (&rest kvs)
  "Build the string-keyed argument table a tool-handle call expects."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k ht) v))
    ht))

;;;; -------------------------------------------------------------------------
;;;; Fixtures
;;;; -------------------------------------------------------------------------

(defparameter +banner-between-forms+
  (format nil "(defun before () 1)~%~%~
;;; Descriptor passing.~%~
;;; Two lines, one banner.~%~%~
(defun after () 2)~%")
  "A two-line banner standing free between two forms.")

(defparameter +mixed-style-run+
  (format nil "(defun before () 1)~%~%~
#| Block opens here~%~
and closes here. |#~%~
;; A semicolon line flush against the block.~%~%~
(defun after () 2)~%")
  "A block comment and a semicolon line with no blank line between them.")

(defparameter +two-banners+
  (format nil "(defun before () 1)~%~%~
;; First banner.~%~%~
;; Second banner.~%~%~
(defun after () 2)~%")
  "Two single-line banners separated by a blank line.")

(defparameter +leading-flush+
  (format nil "(defun before () 1)~%~%~
;; Explains the function below.~%~
(defun after () 2)~%")
  "A comment sitting flush on top of a form.")

(defparameter +leading-detached+
  (format nil "(defun before () 1)~%~%~
;; Explains nothing in particular.~%~%~
(defun after () 2)~%")
  "The same comment with a blank line before the form.")

(defparameter +trailing-comment-then-blank+
  (format nil "(defun a () 1) ; note about a~%~%(defun b () 2)~%")
  "A comment after code, detached from the form below it by a blank line.")

(defparameter +banner-between-forms-crlf+
  (let ((eol (concatenate 'string (string #\Return) (string #\Newline))))
    (format nil "(defun a () 1)~A~A;; Banner.~A~A(defun b () 2)~A"
            eol eol eol eol eol))
  "The banner shape again, written the way a file edited on Windows arrives.
Nothing else in the suite has carriage returns in it, and the splice used to
put a bare newline into exactly this file.")

(defparameter +datum-comment-hides-the-banner+
  (format nil "(defun a () 1)~%~%;; Banner text.~%~%~
#;(defun skipped () 2)~%~%(defun b () 2)~%")
  "A file whose banner is genuinely unreachable, and the one shape the
datum-comment explanation describes. The parse stops at the datum comment, so
the banner above it never reaches the node list either and a substring naming it
finds nothing at all.")

(defparameter +damage-below-the-banner+
  (format nil "(defun a () 1)~%~%;;; Banner to rewrite.~%~%(defun b () 2)~%~%~
(defun c () #<unreadable>)~%")
  "A file the standard reader cannot get through, with the damage seven lines
below the comment anyone would want to edit. The comment edit is harmless and
has nothing to do with the token on the last line.")

(defparameter +header-detached+
  (format nil ";;;; SPDX-License-Identifier: AGPL-3.0-or-later~%~
;;;; File header prose.~%~%~
(in-package :fixture-package)~%~%~
(defun body () 1)~%")
  "A file header separated from the first form by a blank line.")

(defparameter +header-flush+
  (format nil ";;;; SPDX-License-Identifier: AGPL-3.0-or-later~%~
;;;; File header prose.~%~
(in-package :fixture-package)~%~%~
(defun body () 1)~%")
  "A file header sitting flush on top of the first form, the ordinary shape.")

;;;; -------------------------------------------------------------------------
;;;; Run collapsing
;;;; -------------------------------------------------------------------------

(define-test banner-run-collapses-maximally
  "A multi-line banner between two forms is one region, not one per line.
Anchoring on a substring unique to the banner returns that region."
  (let ((regions (%comment-regions (nodes-of +banner-between-forms+)
                                   +banner-between-forms+)))
    (is = 1 (length regions))
    (let ((region (first regions)))
      (true (search "Descriptor passing." (%region-text region)))
      (true (search "one banner." (%region-text region)))
      (is equal '(3 4) (multiple-value-list (%region-line-range region)))
      (is eq region (%match-region-by-substring regions "Descriptor passing.")))))

(define-test mixed-style-run-is-one-region
  "A block comment and a semicolon line with no blank line between them
collapse into a single region, so the two comment styles share one unit."
  (let ((regions (%comment-regions (nodes-of +mixed-style-run+) +mixed-style-run+)))
    (is = 1 (length regions))
    (let ((text (%region-text (first regions))))
      (true (search "Block opens here" text))
      (true (search "closes here. |#" text))
      (true (search "semicolon line flush" text)))))

(define-test blank-line-splits-adjacent-runs
  "A blank line inside what looks like one comment block ends the run."
  (let ((regions (%comment-regions (nodes-of +two-banners+) +two-banners+)))
    (is = 2 (length regions))
    (true (search "First banner." (%region-text (first regions))))
    (true (search "Second banner." (%region-text (second regions))))
    (false (search "Second banner." (%region-text (first regions))))))

(define-test region-text-stops-at-the-run-boundary
  "A region's text covers exactly its own nodes, so a splice built from it
cannot reach into the whitespace separating the run from its neighbours."
  (let* ((regions (%comment-regions (nodes-of +banner-between-forms+)
                                    +banner-between-forms+))
         (region (first regions)))
    (is = (cst-node-start (%region-first-node region))
        (search ";;; Descriptor" +banner-between-forms+))
    (is string= (subseq +banner-between-forms+
                        (cst-node-start (%region-first-node region))
                        (cst-node-end (%region-last-node region)))
        (%region-text region))
    (false (search "defun" (%region-text region)))))

(define-test suppressed-form-does-not-join-a-comment-region
  "A reader-conditional skip is not comment text, so it neither extends a run
nor becomes a region of its own."
  (let* ((source (format nil ";; Live comment.~%~
#+(or) (defun suppressed () 1)~%~%~
(defun live () 1)~%"))
         (regions (%comment-regions (nodes-of source) source)))
    (is = 1 (length regions))
    (is string= (format nil ";; Live comment.~%") (%region-text (first regions)))))

;;;; -------------------------------------------------------------------------
;;;; Line adjacency
;;;; -------------------------------------------------------------------------

(define-test line-comment-end-line-is-normalized
  "A line comment's raw end line sits one past the comment because the reader
consumes the trailing newline; the normalized end line does not.  A block
comment has no such skew, and the adjacency test spans both styles."
  (let* ((nodes (nodes-of +mixed-style-run+))
         (comments (remove-if-not
                    (lambda (n) (dsmr-mcp/src/lisp-edit-comment-core::%comment-node-p n))
                    nodes))
         (block-node (first comments))
         (line-node (second comments)))
    (is eq :block-comment (cst-node-value block-node))
    (is = (cst-node-end-line block-node) (%true-end-line block-node))
    (is = (1+ (cst-node-start-line line-node)) (cst-node-end-line line-node))
    (is = (cst-node-start-line line-node) (%true-end-line line-node))
    (true (dsmr-mcp/src/lisp-edit-comment-core::%contiguous-p block-node line-node)))
  (let* ((nodes (nodes-of +two-banners+))
         (comments (remove-if-not
                    (lambda (n) (dsmr-mcp/src/lisp-edit-comment-core::%comment-node-p n))
                    nodes)))
    (is = 2 (length comments))
    (false (dsmr-mcp/src/lisp-edit-comment-core::%contiguous-p
            (first comments) (second comments)))))

;;;; -------------------------------------------------------------------------
;;;; Leading comment of a form
;;;; -------------------------------------------------------------------------

(define-test leading-run-requires-no-blank-line
  "A comment flush on top of a form is that form's leading comment.  Insert a
blank line and the form has none, because the run became a free-standing
banner instead."
  (let* ((nodes (nodes-of +leading-flush+))
         (target (%find-target nodes "defun" "after"))
         (run (%leading-comment-run nodes target)))
    (true target)
    (is = 1 (length run))
    (true (search "Explains the function below." (node-text +leading-flush+ (first run))))
    (is = 0 (length (region-texts +leading-flush+))))
  (let* ((nodes (nodes-of +leading-detached+))
         (target (%find-target nodes "defun" "after")))
    (true target)
    (is eq nil (%leading-comment-run nodes target))
    (is = 1 (length (region-texts +leading-detached+)))))

(define-test leading-run-collects-the-whole-flush-block
  "The backward walk keeps going while the lines stay adjacent, so a
multi-line block above a form comes back whole."
  (let* ((source (format nil "(defun before () 1)~%~%~
;; First line.~%~
;; Second line.~%~
;; Third line.~%~
(defun after () 2)~%"))
         (nodes (nodes-of source))
         (target (%find-target nodes "defun" "after"))
         (run (%leading-comment-run nodes target)))
    (is = 3 (length run))
    (true (search "First line." (node-text source (first run))))
    (true (search "Third line." (node-text source (third run))))))

(define-test leading-run-stops-at-the-preceding-form
  "A form above the comment ends the walk, so a comment run never absorbs
whatever sat before it."
  (let* ((source (format nil "(defun before () 1)~%~
;; Flush under the form above.~%~
(defun after () 2)~%"))
         (nodes (nodes-of source))
         (run (%leading-comment-run nodes (%find-target nodes "defun" "after"))))
    (is = 1 (length run))
    (true (search "Flush under the form above." (node-text source (first run))))))

(define-test region-anchor-form-names-the-claiming-form
  "An attached run reports the form that claims it, which is what lets an
anchoring failure say where the text actually went."
  (let* ((nodes (nodes-of +leading-flush+))
         (runs (%comment-runs nodes +leading-flush+))
         (anchor (%region-anchor-form nodes (first runs))))
    (is = 1 (length runs))
    (true anchor)
    (is equal '(defun after) (subseq (cst-node-value anchor) 0 2)))
  (let* ((nodes (nodes-of +leading-detached+))
         (runs (%comment-runs nodes +leading-detached+)))
    (is eq nil (%region-anchor-form nodes (first runs)))))

;;;; -------------------------------------------------------------------------
;;;; File header, both spellings
;;;; -------------------------------------------------------------------------

(define-test file-header-above-a-blank-line-is-free-standing
  "A header separated from the first form by a blank line is a region of its
own and is reached by substring."
  (let ((regions (%comment-regions (nodes-of +header-detached+) +header-detached+)))
    (is = 1 (length regions))
    (let ((region (first regions)))
      (is equal '(1 2) (multiple-value-list (%region-line-range region)))
      (true (search "SPDX-License-Identifier" (%region-text region)))
      (true (search "File header prose." (%region-text region)))
      (is eq region (%match-region-by-substring regions "SPDX-License-Identifier"))))
  (let* ((nodes (nodes-of +header-detached+))
         (target (%find-target nodes "in-package" "fixture-package")))
    (true target)
    (is eq nil (%leading-comment-run nodes target))))

(define-test file-header-flush-with-in-package-is-its-leading-comment
  "A header sitting flush on top of the first form belongs to that form, which
is the ordinary shape of a Lisp source file.  Substring anchoring sees no
region at all; naming the IN-PACKAGE form is what reaches the header."
  (is = 0 (length (region-texts +header-flush+)))
  (let* ((nodes (nodes-of +header-flush+))
         (target (%find-target nodes "in-package" "fixture-package"))
         (run (%leading-comment-run nodes target)))
    (true target)
    (is = 2 (length run))
    (true (search "SPDX-License-Identifier" (node-text +header-flush+ (first run))))
    (true (search "File header prose." (node-text +header-flush+ (second run))))
    (is eq target (%region-anchor-form
                   nodes (first (%comment-runs nodes +header-flush+)))))
  ;; The run exists; only its addressing mode differs from the detached case.
  (is = 1 (length (run-texts +header-flush+)))
  (let ((err (error-from (lambda ()
                           (%match-region-by-substring
                            (%comment-regions (nodes-of +header-flush+) +header-flush+)
                            "SPDX-License-Identifier")))))
    (true err)))

;;;; -------------------------------------------------------------------------
;;;; Substring anchoring
;;;; -------------------------------------------------------------------------

(define-test absent-substring-fails-loud
  "A substring present in no region signals rather than returning a region."
  (let* ((regions (%comment-regions (nodes-of +two-banners+) +two-banners+))
         (err (error-from (lambda ()
                            (%match-region-by-substring regions "Third banner.")))))
    (true err)
    (true (search "Third banner." (princ-to-string err))))
  (fail (%match-region-by-substring
         (%comment-regions (nodes-of +two-banners+) +two-banners+)
         "nowhere in the file")
        error))

(define-test ambiguous-substring-fails-loud
  "A substring matching more than one region signals and lists the candidates,
so the caller can pick rather than have one chosen silently.

The candidates are listed by line range and opening line. They used to be
numbered, which advertised a selector this verb does not have: there is no index
argument here, so a caller reading a number off the list had nothing to put it
in. The line range is what the verb does accept."
  (let* ((source (format nil "(defun before () 1)~%~%~
;; Shared wording here.~%~%~
;; Shared wording there.~%~%~
(defun after () 2)~%"))
         (regions (%comment-regions (nodes-of source) source))
         (err (error-from (lambda ()
                            (%match-region-by-substring regions "Shared wording")))))
    (is = 2 (length regions))
    (true err)
    (let ((report (princ-to-string err)))
      (true (search "lines 3-3:" report))
      (true (search "lines 5-5:" report))
      (false (search "[0]" report))
      (false (search "[1]" report))
      (true (search "Shared wording here." report))
      (true (search "Shared wording there." report)))))

(define-test line-range-narrows-an-ambiguous-substring
  "A line range settles a substring that matches more than one region. It is
applied whenever it is given rather than only once the substring alone has
failed, so this is the case where the two constraints agree and the narrowing
is what the caller wanted."
  (let* ((source (format nil "(defun before () 1)~%~%~
;; Shared wording here.~%~%~
;; Shared wording there.~%~%~
(defun after () 2)~%"))
         (regions (%comment-regions (nodes-of source) source))
         (picked (%match-region-by-substring regions "Shared wording" 5 5)))
    (true (search "Shared wording there." (%region-text picked)))
    (is equal '(5 5) (multiple-value-list (%region-line-range picked)))))

(define-test line-range-that-matches-nothing-fails-loud
  "A line range excluding every substring hit signals instead of falling back
to the substring's own ambiguous result."
  (let* ((source (format nil "(defun before () 1)~%~%~
;; Shared wording here.~%~%~
;; Shared wording there.~%~%~
(defun after () 2)~%"))
         (regions (%comment-regions (nodes-of source) source)))
    (fail (%match-region-by-substring regions "Shared wording" 90 99) error)))

(define-test sole-substring-hit-outside-the-line-range-is-refused
  "A caller who states both a substring and a line range has stated two
constraints about one comment. When they disagree the range used to be dropped
without a word and the substring's region rewritten, so a caller working from
line numbers that had moved got a silent edit of a comment they did not name.

The refusal names both, because from the outside there is no way to tell which
of the two went stale. The whole call is driven through the verb so the promise
being made is the one that matters: the file on disk is byte for byte what it
was."
  (with-temp-project-root (session root)
    (true session)
    (let* ((source (format nil "(defun before () 1)~%~%;; Alpha banner.~%~%~
;; Beta banner.~%~%(defun after () 2)~%"))
           (path (write-fixture-file root "ranged.lisp" source))
           (err (error-from
                 (lambda ()
                   (edit-comment (namestring root) (namestring path)
                                 "region" "replace"
                                 :substring "Alpha" :line-start 5 :line-end 5
                                 :content (format nil ";; Rewritten alpha.~%"))))))
      (true (typep err 'comment-operation-error))
      (let ((reason (comment-operation-reason err)))
        (true (search "lines 3 to 3" reason))
        (true (search "lines 5 to 5" reason)))
      (is string= source (uiop:read-file-string path)))))

(define-test line-end-alone-names-the-comment-on-that-line
  "The other half of the same rule: a lone line_end is a whole constraint, so
it selects the comment sitting on that line rather than being ignored. Without
this the refusal below could be satisfied by an implementation that treated any
lone line_end as an impossible range and refused everything."
  (let* ((source (format nil "(defun before () 1)~%~%~
;; Shared wording here.~%~%~
;; Shared wording there.~%~%~
(defun after () 2)~%"))
         (regions (%comment-regions (nodes-of source) source))
         (picked (%match-region-by-substring regions "Shared wording" nil 5)))
    (true (search "Shared wording there." (%region-text picked)))
    (is equal '(5 5) (multiple-value-list (%region-line-range picked)))))

(define-test line-end-alone-refuses-a-match-outside-it
  "A caller who names only the last line has named a line, and a substring
resolving somewhere else is a disagreement exactly as it is when the first line
was the one named.

The bound used to be dropped whenever its partner was absent, so this call
rewrote the comment the substring alone found, reported success, and named a
line the caller had not asked for. The whole thing is driven through the verb
because only the verb shows the call is reachable: nothing in the schema
requires line_start, so line_end on its own arrives over the wire. The file is
read back afterwards because the promise is about the file, not about the
report."
  (with-temp-project-root (session root)
    (let* ((source (format nil "(defun before () 1)~%~%;; Alpha banner.~%~%~
;; Beta banner.~%~%(defun after () 2)~%"))
           (path (write-fixture-file root "ranged.lisp" source))
           (tool (get-tool-instance session "lisp-edit-comment"))
           (args (make-args "file_path" (namestring path)
                            "mode" "region"
                            "operation" "replace"
                            "substring" "Alpha"
                            "line_end" 5
                            "content" (format nil ";; WRONG TARGET.~%")))
           (res (gethash "result" (tool-handle tool 1 args))))
      (true (gethash "isError" res))
      (is string= "comment-operation-error" (gethash "error_type" res))
      (let ((report (gethash "text" (elt (gethash "content" res) 0))))
        (true (search "lines 3 to 3" report))
        (true (search "lines 5 to 5" report)))
      (is string= source (uiop:read-file-string path)))))

;;;; -------------------------------------------------------------------------
;;;; Prologue and read sandbox
;;;; -------------------------------------------------------------------------

(define-test region-locator-reads-a-file-under-the-session-root
  "The substring-anchoring prologue resolves a project-relative path, reads
the file, and returns its free-standing regions alongside the parse."
  (with-temp-project-root (session root)
    (true session)
    (write-fixture-file root "fixture.lisp" +banner-between-forms+)
    (multiple-value-bind (abs rel original nodes regions)
        (%locate-comment-regions "fixture.lisp" nil root)
      (true abs)
      (is string= "fixture.lisp" rel)
      (is string= +banner-between-forms+ original)
      (true (plusp (length nodes)))
      (is = 1 (length regions))
      (true (search "Descriptor passing." (%region-text (first regions)))))))

(define-test region-locator-refuses-a-path-outside-the-session-root
  "A path escaping the read allow-list signals before anything is parsed."
  (with-temp-project-root (session root)
    (true session)
    (write-fixture-file root "fixture.lisp" +banner-between-forms+)
    (fail (%locate-comment-regions "../../etc/passwd" nil root) error)))

;;;; -------------------------------------------------------------------------
;;;; Editing a region: the comment changes, the code around it does not
;;;; -------------------------------------------------------------------------

(define-test banner-replace-keeps-neighbours
  "Replacing a free-standing banner rewrites the comment and leaves the forms
either side of it byte for byte as they were."
  (with-temp-project-root (session root)
    (true session)
    (let ((path (write-fixture-file root "banner.lisp" +banner-between-forms+)))
      (edit-comment (namestring root) (namestring path) "region" "replace"
                    :substring "Descriptor passing."
                    :content (format nil ";;; Rewritten in one line.~%"))
      (let ((result (uiop:read-file-string path)))
        (true (search "Rewritten in one line." result))
        (false (search "Descriptor passing." result))
        (is string= (format nil "(defun before () 1)~%~%~
;;; Rewritten in one line.~%~%(defun after () 2)~%")
            result)))))

(define-test banner-delete-leaves-one-blank-line
  "Deleting a banner takes the whitespace run that followed it and no more, so
the forms either side end up separated by a single blank line rather than by
the gap the banner used to fill.

What the report says it removed is that whole span and not the comment alone.
The two differ by exactly the whitespace the delete took, so a report naming the
comment's own bytes understates the edit by the one part of it a caller would
not have predicted."
  (with-temp-project-root (session root)
    (true session)
    (let ((path (write-fixture-file root "banner.lisp" +banner-between-forms+)))
      (multiple-value-bind (updated changed report)
          (edit-comment (namestring root) (namestring path) "region" "delete"
                        :substring "Descriptor passing.")
        (declare (ignore updated))
        (true changed)
        (is string= (format nil "(defun before () 1)~%~%(defun after () 2)~%")
            (uiop:read-file-string path))
        ;; The banner's own bytes end with the newline closing its last line.
        ;; The span removed carries the blank line after it as well.
        (let ((removed (gethash "before" report))
              (comment (format nil ";;; Descriptor passing.~%~
;;; Two lines, one banner.~%")))
          (is string= (concatenate 'string comment (string #\Newline)) removed)
          (is = (1+ (length comment)) (length removed)))
        ;; The comparison ran and is reported as having run.
        (true (gethash "forms_verified_unchanged" report))))))

(define-test mixed-style-run-edits-as-one-region
  "A block comment and the semicolon line flush beneath it are one region, so a
single replace covers both styles at once."
  (with-temp-project-root (session root)
    (true session)
    (let ((path (write-fixture-file root "mixed.lisp" +mixed-style-run+)))
      (edit-comment (namestring root) (namestring path) "region" "replace"
                    :substring "Block opens here"
                    :content (format nil ";; One line replaces both styles.~%"))
      (let ((result (uiop:read-file-string path)))
        (false (search "Block opens here" result))
        (false (search "semicolon line flush" result))
        (is string= (format nil "(defun before () 1)~%~%~
;; One line replaces both styles.~%~%(defun after () 2)~%")
            result)))))

;;;; -------------------------------------------------------------------------
;;;; Editing the comment attached to a form, and what counts as attached
;;;; -------------------------------------------------------------------------

(define-test alien-routine-leading-edit-keeps-the-form
  "The shape that prompted this work: a banner sitting flush on top of an alien
routine whose name is a compound spec. Naming the routine reaches the banner,
and the routine comes back byte for byte unchanged, as do the forms either
side of it."
  (with-temp-project-root (session root)
    (true session)
    (let* ((routine (format nil "(sb-alien:define-alien-routine ~
(\"sendmsg\" %scm-sendmsg) sb-alien:long~%  (fd sb-alien:int)~%~
  (msg sb-alien:system-area-pointer)~%  (flags sb-alien:int))"))
           (source (format nil "(defun closer () nil)~%~%~
;;; SCM_RIGHTS fd passing.~%;;; Stale wording to correct.~%~A~%~%~
(defun neighbour (x) (1+ x))~%" routine))
           (path (write-fixture-file root "alien.lisp" source)))
      (edit-comment (namestring root) (namestring path) "leading" "replace"
                    :form-type "define-alien-routine" :form-name "%scm-sendmsg"
                    :content (format nil ";;; Descriptor passing over a unix socket.~%"))
      (let ((result (uiop:read-file-string path)))
        (true (search "Descriptor passing over a unix socket." result))
        (false (search "Stale wording to correct." result))
        (true (search routine result))
        (true (search "(defun closer () nil)" result))
        (true (search "(defun neighbour (x) (1+ x))" result))))))

(define-test leading-comment-flush-against-a-form-is-editable
  "A comment directly above a form, with no blank line, is reached by naming
the form and is rewritten in place without the form moving."
  (with-temp-project-root (session root)
    (true session)
    (let ((path (write-fixture-file root "flush.lisp" +leading-flush+)))
      (edit-comment (namestring root) (namestring path) "leading" "replace"
                    :form-type "defun" :form-name "after"
                    :content (format nil ";; Now says something else.~%"))
      (is string= (format nil "(defun before () 1)~%~%~
;; Now says something else.~%(defun after () 2)~%")
          (uiop:read-file-string path)))))

(define-test blank-line-detaches-a-comment-from-leading-mode
  "A blank line between a comment and the form below it makes the comment
free-standing. Leading mode refuses it and writes nothing; region mode reaches
the same comment and edits it."
  (with-temp-project-root (session root)
    (true session)
    (let* ((path (write-fixture-file root "detached.lisp" +leading-detached+))
           (err (error-from (lambda ()
                              (edit-comment (namestring root) (namestring path)
                                            "leading" "replace"
                                            :form-type "defun" :form-name "after"
                                            :content ";; taken by the wrong form")))))
      (true (typep err 'comment-operation-error))
      (is string= +leading-detached+ (uiop:read-file-string path))
      (edit-comment (namestring root) (namestring path) "region" "replace"
                    :substring "Explains nothing in particular."
                    :content (format nil ";; Reached through region mode.~%"))
      (true (search "Reached through region mode." (uiop:read-file-string path))))))

(define-test same-line-trailing-comment-is-not-a-leading-comment
  "A comment written after code on the same line is prose about that code. The
line-adjacency test on its own hands it to the form on the next line, and
replacing it would then destroy a comment belonging to the form above while
every form in the file stayed byte for byte identical, so no later check could
notice. Leading mode refuses such a run outright and writes nothing. A run
that does begin its own line is unaffected and still edits."
  (with-temp-project-root (session root)
    (true session)
    (let* ((source (format nil "(defun a () 1) ; note about a~%(defun b () 2)~%"))
           (path (write-fixture-file root "trailing.lisp" source))
           (err (error-from (lambda ()
                              (edit-comment (namestring root) (namestring path)
                                            "leading" "replace"
                                            :form-type "defun" :form-name "b"
                                            :content ";; taken by the wrong form")))))
      (true (typep err 'comment-operation-error))
      (true (search "same line" (comment-operation-reason err)))
      (is string= source (uiop:read-file-string path)))
    (let* ((source (format nil "(defun a () 1)~%; note about b~%(defun b () 2)~%"))
           (path (write-fixture-file root "own-line.lisp" source)))
      (edit-comment (namestring root) (namestring path) "leading" "replace"
                    :form-type "defun" :form-name "b"
                    :content (format nil "; note that now says more~%"))
      (is string= (format nil "(defun a () 1)~%; note that now says more~%~
(defun b () 2)~%")
          (uiop:read-file-string path)))))

(define-test free-standing-trailing-comment-refuses-a-region-delete
  "A comment written after code is free-standing as soon as a blank line
detaches it from the form below, so a substring reaches it and the rule leading
mode enforces has to hold here too. Deleting this one takes the blank line
along with the comment and leaves the two forms on a single line, while every
form survives byte for byte at a correctly shifted offset: the form comparison,
the delimiter scan and the reader all pass a file that has just lost the shape
it was written in. The run is refused for beginning after code, before anything
is written."
  (with-temp-project-root (session root)
    (true session)
    ;; The refusals here and below would pass for the wrong reason if this
    ;; shape ever stopped being free-standing, so the precondition is asserted
    ;; rather than assumed.
    (let ((regions (%comment-regions (nodes-of +trailing-comment-then-blank+)
                                     +trailing-comment-then-blank+)))
      (is = 1 (length regions))
      (true (search "note about a" (%region-text (first regions)))))
    (let* ((path (write-fixture-file root "trailing-free.lisp"
                                     +trailing-comment-then-blank+))
           (err (error-from (lambda ()
                              (edit-comment (namestring root) (namestring path)
                                            "region" "delete"
                                            :substring "note about a")))))
      (true (typep err 'comment-operation-error))
      (true (search "same line" (comment-operation-reason err)))
      (is string= +trailing-comment-then-blank+ (uiop:read-file-string path))
      ;; Naming the damage rather than leaving it to the byte comparison: this
      ;; is the single line the two forms were merged onto.
      (false (search "(defun a () 1) (defun b () 2)"
                     (uiop:read-file-string path))))))

(define-test free-standing-trailing-comment-refuses-a-region-replace
  "Replacing that same run is refused on the same rule rather than on the
operation. Replacement text carrying no newline of its own consumes the blank
line and rewrites the line the code sits on, and the form comparison sees that
no better than it sees the delete, so one rule that fails closed covers both."
  (with-temp-project-root (session root)
    (true session)
    (let* ((path (write-fixture-file root "trailing-free-replace.lisp"
                                     +trailing-comment-then-blank+))
           (err (error-from (lambda ()
                              (edit-comment (namestring root) (namestring path)
                                            "region" "replace"
                                            :substring "note about a"
                                            :content "; rewritten")))))
      (true (typep err 'comment-operation-error))
      (true (search "same line" (comment-operation-reason err)))
      (is string= +trailing-comment-then-blank+ (uiop:read-file-string path)))))

(define-test own-line-banner-still-edits-in-region-mode
  "The refusal narrows nothing else. A banner that begins its own line between
two forms is still rewritten in region mode, and the forms either side of it
come back byte for byte unchanged."
  (with-temp-project-root (session root)
    (true session)
    (let* ((source (format nil "(defun a () 1)~%~%; note about neither.~%~%~
(defun b () 2)~%"))
           (path (write-fixture-file root "own-line-region.lisp" source)))
      (edit-comment (namestring root) (namestring path) "region" "replace"
                    :substring "note about neither."
                    :content (format nil "; note that now says more.~%"))
      (is string= (format nil "(defun a () 1)~%~%; note that now says more.~%~%~
(defun b () 2)~%")
          (uiop:read-file-string path)))))

;;;; -------------------------------------------------------------------------
;;;; Refusing to write: bad anchors, previews, and a corrupting replacement
;;;; -------------------------------------------------------------------------

(define-test absent-substring-writes-nothing
  "A substring naming no region signals before the splice, so the file on disk
is exactly what it was."
  (with-temp-project-root (session root)
    (true session)
    (let* ((path (write-fixture-file root "banner.lisp" +banner-between-forms+))
           (err (error-from (lambda ()
                              (edit-comment (namestring root) (namestring path)
                                            "region" "replace"
                                            :substring "nowhere in this file"
                                            :content ";; never written")))))
      (true (typep err 'comment-operation-error))
      (is string= +banner-between-forms+ (uiop:read-file-string path)))))

(define-test ambiguous-substring-writes-nothing
  "A substring matching two regions lists both and edits neither, so a caller
picks rather than discovers afterwards which one was rewritten."
  (with-temp-project-root (session root)
    (true session)
    (let* ((source (format nil "(defun before () 1)~%~%;; Shared wording here.~%~%~
;; Shared wording there.~%~%(defun after () 2)~%"))
           (path (write-fixture-file root "ambiguous.lisp" source))
           (err (error-from (lambda ()
                              (edit-comment (namestring root) (namestring path)
                                            "region" "replace"
                                            :substring "Shared wording"
                                            :content ";; never written")))))
      (true (typep err 'comment-operation-error))
      (true (search "Shared wording here." (comment-operation-reason err)))
      (true (search "Shared wording there." (comment-operation-reason err)))
      (is string= source (uiop:read-file-string path)))))

(define-test dry-run-preview-matches-the-applied-file
  "The preview comes off the same splice the real edit uses, so it equals the
file a real apply produces, and the previewed file is left untouched. The
changed-region report names the lines the comment occupied and the line the
replacement now ends on."
  (with-temp-project-root (session root)
    (true session)
    (let* ((replacement (format nil ";;; Fresh wording.~%;;; Over two lines.~%"))
           (dry-path (write-fixture-file root "dry.lisp" +banner-between-forms+))
           (preview (edit-comment (namestring root) (namestring dry-path)
                                  "region" "replace"
                                  :substring "Descriptor passing."
                                  :content replacement :dry-run t))
           (real-path (write-fixture-file root "real.lisp" +banner-between-forms+)))
      (true (gethash "would_change" preview))
      (is string= +banner-between-forms+ (uiop:read-file-string dry-path))
      (edit-comment (namestring root) (namestring real-path) "region" "replace"
                    :substring "Descriptor passing." :content replacement)
      (is string= (uiop:read-file-string real-path) (gethash "preview" preview))
      (let ((report (gethash "changed_region" preview)))
        (is = 3 (gethash "line_start" report))
        (is = 4 (gethash "line_end" report))
        (is = 4 (gethash "line_end_after" report))
        (is string= replacement (gethash "after" report))))))

(define-test form-absorbing-content-is-refused-before-the-write
  "Replacement text that opens a block comment closed by a delimiter already
sitting further down the file turns whatever it spans into comment text. The
swallowed span here holds reader-conditional definitions, and that is the case
that matters: the reader skips a #+ccl form on an implementation that is not
CCL, so it never arrives as an expression, and the file that lost the function
still loads cleanly on the machine that made the edit. Nobody finds out until
the file is loaded somewhere else.

The delimiter scan and the reader both pass on the spliced file, and the count
of expressions in it does not move, so neither of those can see the loss.
Comparing every node that is not comment text does see it, which is why the
comparison is written that way rather than in terms of expressions. It runs
before the write, so the file is left alone."
  (with-temp-project-root (session root)
    (true session)
    (let* ((banner (format nil ";;; Banner to rewrite.~%"))
           (source (format nil "(defun before () 1)~%~%~A~%~
#+ccl  (defun ccl-only  () (ccl-frob))~%~
#+abcl (defun abcl-only () (abcl-frob))~%~%~
;; tail |#~%(defun after () 3)~%" banner))
           (absorbing "#| swallow")
           (start (search banner source))
           (end (+ start (length banner)))
           (spliced (concatenate 'string (subseq source 0 start) absorbing
                                 (subseq source end)))
           (path (write-fixture-file root "absorbing.lisp" source)))
      ;; The cheaper guards see nothing wrong with the spliced file: it is
      ;; balanced and it reads without error.
      (true (getf (scan-parens spliced) :ok))
      (is eq nil (try-reader-check spliced))
      ;; Counting expressions sees nothing either, because a conditional
      ;; definition is not one. Counting everything that is not comment text
      ;; sees two definitions go. Narrow the comparison back to expressions and
      ;; these two lines say the file was unharmed.
      (is = 2 (count :expr (parse-top-level-forms source) :key #'cst-node-kind))
      (is = 2 (count :expr (parse-top-level-forms spliced) :key #'cst-node-kind))
      (is = 4 (count-if-not
               (lambda (n) (dsmr-mcp/src/lisp-edit-comment-core::%comment-node-p n))
               (parse-top-level-forms source)))
      (is = 2 (count-if-not
               (lambda (n) (dsmr-mcp/src/lisp-edit-comment-core::%comment-node-p n))
               (parse-top-level-forms spliced)))
      ;; The comparison itself, on exactly the splice the verb would perform.
      (let ((err (error-from
                  (lambda ()
                    (dsmr-mcp/src/lisp-edit-comment::%verify-forms-survived
                     source (parse-top-level-forms source) spliced nil
                     start end absorbing)))))
        (true (typep err 'comment-operation-error)))
      ;; And through the verb, where the content guard reaches the same
      ;; conclusion sooner. Either way nothing is written and both conditional
      ;; definitions are still there to be found by name.
      (let ((err (error-from (lambda ()
                               (edit-comment (namestring root) (namestring path)
                                             "region" "replace"
                                             :substring "Banner to rewrite."
                                             :content absorbing))))
            (on-disk (uiop:read-file-string path)))
        (true (typep err 'comment-operation-error))
        (is string= source on-disk)
        (true (search "ccl-only" on-disk))
        (true (search "abcl-only" on-disk))))))

(define-test replacement-that-leaves-a-block-comment-open-is-refused
  "A replacement is refused outright when it opens a delimiter it never closes.
Whatever eventually closes it is code already sitting below the comment, so
such text can only re-type that code. The check needs nothing but the caller's
own string, so it runs before the file is even read."
  (with-temp-project-root (session root)
    (true session)
    (let* ((path (write-fixture-file root "open.lisp" +banner-between-forms+))
           (err (error-from (lambda ()
                              (edit-comment (namestring root) (namestring path)
                                            "region" "replace"
                                            :substring "Descriptor passing."
                                            :content "#| swallow")))))
      (true (typep err 'comment-operation-error))
      (true (search "self-contained" (comment-operation-reason err)))
      (is string= +banner-between-forms+ (uiop:read-file-string path)))))

(define-test unbalanced-delimiter-inside-comment-prose-is-still-accepted
  "Prose is allowed to be lopsided. A comment saying call (foo with one paren
leaves a delimiter unclosed only in the sense that the character is on the
line; the reader never sees it, so refusing such text would make the verb
useless for exactly the comments people write about code. The boundary the
guard has to respect is that this lands and the unclosed block comment above
does not."
  (with-temp-project-root (session root)
    (true session)
    (let* ((path (write-fixture-file root "prose.lisp" +banner-between-forms+))
           (replacement (format nil ";;; call (foo with one paren~%")))
      (edit-comment (namestring root) (namestring path) "region" "replace"
                    :substring "Descriptor passing." :content replacement)
      (let ((on-disk (uiop:read-file-string path)))
        (true (search "call (foo with one paren" on-disk))
        (true (search "(defun before () 1)" on-disk))
        (is eq nil (search "Descriptor passing." on-disk))))))

(define-test no-project-root-refuses-a-comment-edit
  "With no project root set the verb answers with a typed error instead of
touching the filesystem."
  (let* ((session (make-session :id "no-root" :project-root nil))
         (tool (get-tool-instance session "lisp-edit-comment"))
         (args (make-args "file_path" "/tmp/x.lisp"
                          "mode" "region"
                          "operation" "replace"
                          "substring" "Descriptor passing."
                          "content" ";;; New banner."))
         (res (gethash "result" (tool-handle tool 1 args))))
    (true (gethash "isError" res))
    (is string= "project-root-not-set" (gethash "error_type" res))))

(define-test newline-free-content-keeps-the-comment-free-standing
  "A comment run's bytes end after the newline closing its last line, so
replacement text carrying no newline of its own used to take the blank line
below the comment with it. That blank line is what made the run free-standing:
without it the comment is flush against the form beneath, which means substring
anchoring cannot see it and the caller has lost the only handle this verb
offers on the comment it just wrote.

So the assertion is in two halves. The file differs from the original in the
banner's own line and nowhere else, and a second region-mode call naming the
new wording still resolves."
  (with-temp-project-root (session root)
    (true session)
    (let ((path (write-fixture-file root "banner.lisp" +banner-between-forms+)))
      (edit-comment (namestring root) (namestring path) "region" "replace"
                    :substring "Descriptor passing."
                    :content ";;; Rewritten banner.")
      (is string= (format nil "(defun before () 1)~%~%;;; Rewritten banner.~%~%~
(defun after () 2)~%")
          (uiop:read-file-string path))
      (let ((preview (edit-comment (namestring root) (namestring path)
                                   "region" "replace"
                                   :substring "Rewritten banner."
                                   :content (format nil ";;; Third pass.~%")
                                   :dry-run t)))
        (true (gethash "would_change" preview))))))

(define-test header-replaced-without-a-newline-keeps-the-form-below-it
  "The leading-mode half of the guarantee above, where the cost is far higher
than a lost handle. A file header sits flush on top of the first form, so the
run's bytes end on the newline that closes the header's last line and the form
below starts the next line. Splicing replacement text that carries no newline
of its own puts that form on the header's last line, inside the comment: the
opening paren is commented out and the form's remaining lines are left as loose
top-level junk ending in a close paren the reader cannot match.

What a caller sees when that happens is not the damage but a count. The re-parse
gives up at the stray close paren, so the comparison reports far fewer nodes
than the file had, and it reports the same shortfall whatever the replacement
said, because the shortfall is the truncated parse rather than the content. That
is the reading that sends someone looking for a miscomputed span, so the shape
is pinned here: the form below the header keeps its own line, and the file still
holds every expression it held before."
  (with-temp-project-root (session root)
    (true session)
    (let ((path (write-fixture-file root "header.lisp" +header-flush+)))
      (edit-comment (namestring root) (namestring path) "leading" "replace"
                    :form-type "in-package" :form-name "fixture-package"
                    :content ";;;; One line, carrying no newline of its own.")
      (let ((updated (uiop:read-file-string path)))
        (is string= (format nil ";;;; One line, carrying no newline of its own.~%~
(in-package :fixture-package)~%~%(defun body () 1)~%")
            updated)
        (flet ((expression-count (source)
                 (count :expr (nodes-of source) :key #'cst-node-kind)))
          (is = (expression-count +header-flush+) (expression-count updated)))))))

(define-test crlf-file-keeps-its-line-endings-through-a-replace
  "Replacement text arrives with whatever line endings the caller's editor
produced. Splicing it verbatim into a file terminated by carriage return and
newline leaves the rewritten line the only bare-newline line in the file, which
is the sort of damage that shows up as a whole-file diff the next time anyone
touches it. The content is converted to the terminator the file already uses,
including the one appended because the content carries none of its own."
  (with-temp-project-root (session root)
    (true session)
    (let ((path (write-fixture-file root "crlf.lisp" +banner-between-forms-crlf+)))
      (edit-comment (namestring root) (namestring path) "region" "replace"
                    :substring "Banner."
                    :content ";; Rewritten.")
      (let ((written (uiop:read-file-string path)))
        (true (search "Rewritten." written))
        (is = 0 (loop for index from 0 below (length written)
                      count (and (char= (char written index) #\Newline)
                                 (or (zerop index)
                                     (not (char= (char written (1- index))
                                                 #\Return))))))
        (let ((eol (concatenate 'string (string #\Return) (string #\Newline))))
          (is string= (format nil "(defun a () 1)~A~A;; Rewritten.~A~A~
(defun b () 2)~A" eol eol eol eol eol)
              written))))))

(define-test deleting-the-last-comment-leaves-the-blank-line-above-it
  "The whitespace trim a delete performs only runs forward, so a comment that
ends the file has nothing after it to absorb and the blank line above it stays.
This is the documented behaviour rather than the intended one, and it is pinned
here so the docstring that now states the exception cannot quietly stop being
true. Harmless in itself, but it is the shape a whitespace linter reports."
  (with-temp-project-root (session root)
    (true session)
    (let ((path (write-fixture-file
                 root "tail.lisp"
                 (format nil "(defun a () 1)~%~%;; Trailing banner.~%"))))
      (edit-comment (namestring root) (namestring path) "region" "delete"
                    :substring "Trailing banner.")
      (is string= (format nil "(defun a () 1)~%~%")
          (uiop:read-file-string path)))))

(define-test empty-replacement-content-is-spliced-verbatim
  "A caller passing the empty string is saying there should be nothing here.
Appending a terminator to that would put back the line they asked to remove, so
the empty string is the one content the terminator rule leaves alone. The blank
line the comment used to sit between survives on both sides, which is what
distinguishes an empty replace from a delete."
  (with-temp-project-root (session root)
    (true session)
    (let ((path (write-fixture-file root "empty.lisp" +banner-between-forms+)))
      (edit-comment (namestring root) (namestring path) "region" "replace"
                    :substring "Descriptor passing." :content "")
      (is string= (format nil "(defun before () 1)~%~%~%(defun after () 2)~%")
          (uiop:read-file-string path)))))

(define-test unchanged-content-reports-no-verification
  "A replacement identical to what is already there changes nothing, so the
comparison that would prove the rest of the file survived is never run. The
report says so rather than carrying a verification that did not happen.

This is the case that shows the field is derived. A constant would read exactly
the same here as on an edit that was genuinely checked, and a caller with no way
to tell the two apart is better off with no field at all."
  (with-temp-project-root (session root)
    (true session)
    (let ((path (write-fixture-file root "noop.lisp" +banner-between-forms+)))
      (multiple-value-bind (updated changed report)
          (edit-comment (namestring root) (namestring path) "region" "replace"
                        :substring "Descriptor passing."
                        :content (format nil ";;; Descriptor passing.~%~
;;; Two lines, one banner.~%"))
        (is string= +banner-between-forms+ updated)
        (is eq nil changed)
        (is eq nil (gethash "forms_verified_unchanged" report))
        (is string= +banner-between-forms+ (uiop:read-file-string path))))))

(define-test verb-replaces-a-banner-and-reports-the-region
  "A region replace driven through the verb rewrites the banner, leaves the
forms around it alone, and reports the lines the edit covered.

The content here carries no newline of its own, which is the case a caller
reaches by accident, so the assertion is on the whole file rather than on
fragments of it: searching for three pieces passes just as happily when the
blank line below the banner has been eaten, which is how this test drove that
defect for a whole phase without pinning anything about it."
  (with-temp-project-root (session root)
    (let* ((path (write-fixture-file root "banner.lisp" +banner-between-forms+))
           (tool (get-tool-instance session "lisp-edit-comment"))
           (args (make-args "file_path" (namestring path)
                            "mode" "region"
                            "operation" "replace"
                            "substring" "Descriptor passing."
                            "content" ";;; Rewritten banner."))
           (res (gethash "result" (tool-handle tool 1 args))))
      (is eq nil (gethash "isError" res))
      (true (gethash "would_change" res))
      (let ((report (gethash "changed_region" res)))
        (is = 3 (gethash "line_start" report))
        (is = 4 (gethash "line_end" report))
        (is = 3 (gethash "line_end_after" report))
        (true (gethash "forms_verified_unchanged" report)))
      ;; The prose says what was compared. It used to promise the surroundings
      ;; were unchanged, which a delete makes false by design.
      (let ((summary (gethash "text" (elt (gethash "content" res) 0))))
        (true (search "compared against the original" summary))
        (false (search "Surrounding forms verified unchanged" summary)))
      (is = (length (uiop:read-file-string path)) (gethash "characters" res))
      (is string= (format nil "(defun before () 1)~%~%;;; Rewritten banner.~%~%~
(defun after () 2)~%")
          (uiop:read-file-string path)))))

(define-test verb-reports-an-absent-anchor-as-a-typed-error
  "A substring naming no comment comes back as its own error type, distinct
from an unexpected failure, and the file is left as it was."
  (with-temp-project-root (session root)
    (let* ((path (write-fixture-file root "banner.lisp" +banner-between-forms+))
           (tool (get-tool-instance session "lisp-edit-comment"))
           (args (make-args "file_path" (namestring path)
                            "mode" "region"
                            "operation" "replace"
                            "substring" "no such text anywhere"
                            "content" ";;; Rewritten banner."))
           (res (gethash "result" (tool-handle tool 1 args))))
      (true (gethash "isError" res))
      (is string= "comment-operation-error" (gethash "error_type" res))
      (is string= +banner-between-forms+ (uiop:read-file-string path)))))

(define-test datum-comment-note-appears-only-where-it-applies
  "The explanation about datum comments used to be appended to every region-mode
refusal, including on files with no datum comment anywhere in them. An
explanation attached to every failure carries no information: a reader cannot
tell the occasional case where it names the true cause from the many where it
was printed regardless, so the one time it would have helped it reads as the
noise it has been every other time.

Both directions are pinned, because either one alone is satisfied by a constant.
On a file with no datum comment neither an absent substring nor an ambiguous one
mentions them. On a file with one the note is there, and it is the true cause:
the parse stops at the datum comment, so the banner above it is not in the node
list and the substring finds nothing."
  (with-temp-project-root (session root)
    (true session)
    (let* ((clean (format nil "(defun before () 1)~%~%;; Alpha banner.~%~%~
;; Beta banner.~%~%(defun after () 2)~%"))
           (clean-path (write-fixture-file root "clean.lisp" clean))
           (absent (error-from
                    (lambda ()
                      (edit-comment (namestring root) (namestring clean-path)
                                    "region" "replace"
                                    :substring "nowhere in this file"
                                    :content ";; never written"))))
           (ambiguous (error-from
                       (lambda ()
                         (edit-comment (namestring root) (namestring clean-path)
                                       "region" "replace"
                                       :substring "banner."
                                       :content ";; never written")))))
      (true (typep absent 'comment-operation-error))
      (false (search "#;" (comment-operation-reason absent)))
      (false (search "datum" (comment-operation-reason absent)))
      (true (typep ambiguous 'comment-operation-error))
      (false (search "#;" (comment-operation-reason ambiguous)))
      (is string= clean (uiop:read-file-string clean-path)))
    (let* ((path (write-fixture-file root "datum.lisp"
                                     +datum-comment-hides-the-banner+))
           (err (error-from
                 (lambda ()
                   (edit-comment (namestring root) (namestring path)
                                 "region" "replace"
                                 :substring "Banner text."
                                 :content ";; never written")))))
      (true (typep err 'comment-operation-error))
      (true (search "#; datum comment" (comment-operation-reason err)))
      (is string= +datum-comment-hides-the-banner+ (uiop:read-file-string path)))))

(define-test internal-failure-reaches-the-unexpected-error-channel
  "An anchor failure and a fault in the verb are different news, and a caller
acts on them differently: a bad anchor is retried with a better one, a fault is
reported. Both used to arrive as the anchor-failure type, because the resolvers
retyped every condition raised anywhere beneath them, so an agent reading the
result retried an anchor that was already right while the defect went
unreported.

A value of the wrong type for the line range is the case the review drove. Over
the wire the schema catches this one at dispatch; what matters is where a fault
lands once it is past the schema, so the call goes straight to the verb. Only
the locator's own condition is retyped now, so this reaches the unexpected
channel, and it carries no anchor advice, because none of that advice applies."
  (with-temp-project-root (session root)
    (let* ((source (format nil "(defun before () 1)~%~%;; Alpha banner.~%~%~
;; Beta banner.~%~%(defun after () 2)~%"))
           (path (write-fixture-file root "typed.lisp" source))
           (tool (get-tool-instance session "lisp-edit-comment"))
           (args (make-args "file_path" (namestring path)
                            "mode" "region"
                            "operation" "replace"
                            "substring" "Alpha"
                            "line_start" "5"
                            "content" (format nil ";; never written~%")))
           (res (gethash "result" (tool-handle tool 1 args))))
      (true (gethash "isError" res))
      (is string= "edit-comment-error" (gethash "error_type" res))
      (let ((text (gethash "text" (elt (gethash "content" res) 0))))
        (false (search "#; datum comment" text))
        (false (search "Regions available" text)))
      (is string= source (uiop:read-file-string path)))))

(define-test pre-existing-damage-does-not-block-a-comment-edit
  "The whole-file checks used to run against the edited text only, so any token
the reader could not get through, anywhere in the file, was reported as damage
this edit had caused. The message said the edit broke the file and named a line
the edit never touched, and no comment anywhere in such a file could be reached
by this verb again.

The checks run against the original first now. One the file was already failing
says nothing about the edit, so it is skipped and the state is reported instead
of charged. The comment lands, the file is written, and the report says the file
was already in that state.

The reader error sits seven lines below the banner, which is the reproduction
the review recorded."
  (with-temp-project-root (session root)
    (true session)
    ;; The precondition, asserted rather than assumed: the file really does
    ;; fail to read, and the failure really is below the comment.
    (let ((reader (try-reader-check +damage-below-the-banner+)))
      (true reader)
      (is = 7 (getf reader :line)))
    (let ((path (write-fixture-file root "damaged.lisp" +damage-below-the-banner+)))
      (multiple-value-bind (updated changed report)
          (edit-comment (namestring root) (namestring path) "region" "replace"
                        :substring "Banner to rewrite."
                        :content (format nil ";;; Rewritten banner.~%"))
        (declare (ignore updated))
        (true changed)
        (true (gethash "already_unreadable" report))
        (true (gethash "forms_verified_unchanged" report)))
      (let ((written (uiop:read-file-string path)))
        (is string= (format nil "(defun a () 1)~%~%;;; Rewritten banner.~%~%~
(defun b () 2)~%~%(defun c () #<unreadable>)~%")
            written)
        ;; The damage is untouched, which is the point: the edit neither caused
        ;; it nor took it upon itself to repair it.
        (true (search "#<unreadable>" written))))))

(define-test a-clean-file-is-still-refused-when-the-edit-would-break-it
  "The converse, and the reason the skip narrows the check rather than removing
it. When the original passes and the edited text fails, the refusal is exactly
what it always was and nothing is written. Only a check the file was already
failing is skipped, and only for that file.

Both branches are driven directly, because the comparison of everything outside
the file's comments sits in front of them and refuses damaging content sooner.
That ordering is what makes these two a backstop rather than the guarantee, and
it is why the guarantee is stated in terms of the comparison."
  (let* ((clean +banner-between-forms+)
         (unbalanced (format nil "(defun a () 1)~%~%;; Banner.~%~%(defun b () 2~%"))
         (unreadable (format nil "(defun a () 1)~%~%;; Banner.~%~%~
(defun b () #<unreadable>)~%"))
         (parens-err (error-from
                      (lambda ()
                        (dsmr-mcp/src/lisp-edit-comment::%verify-still-reads
                         clean unbalanced))))
         (reader-err (error-from
                      (lambda ()
                        (dsmr-mcp/src/lisp-edit-comment::%verify-still-reads
                         clean unreadable)))))
    (true (typep parens-err 'comment-operation-error))
    (true (search "no longer has balanced delimiters"
                  (comment-operation-reason parens-err)))
    (true (typep reader-err 'comment-operation-error))
    (true (search "no longer reads cleanly" (comment-operation-reason reader-err)))
    ;; A file already in that state reports it instead of signalling, and a
    ;; clean file that stays clean reports nothing.
    (true (dsmr-mcp/src/lisp-edit-comment::%verify-still-reads unreadable unreadable))
    (is eq nil (dsmr-mcp/src/lisp-edit-comment::%verify-still-reads clean clean))))

(define-test verb-offers-no-insert-operation
  "Replace and delete are the whole operation set. Placing a brand new comment
relative to a form is what the form editor's insert operations already do, so
an insert here is refused as an argument error and nothing is written."
  (with-temp-project-root (session root)
    (let* ((path (write-fixture-file root "banner.lisp" +banner-between-forms+))
           (tool (get-tool-instance session "lisp-edit-comment"))
           (args (make-args "file_path" (namestring path)
                            "mode" "region"
                            "operation" "insert_before"
                            "substring" "Descriptor passing."
                            "content" ";;; New banner."))
           (res (gethash "result" (tool-handle tool 1 args))))
      (true (gethash "isError" res))
      (is string= "invalid-argument" (gethash "error_type" res))
      (is string= +banner-between-forms+ (uiop:read-file-string path)))))
