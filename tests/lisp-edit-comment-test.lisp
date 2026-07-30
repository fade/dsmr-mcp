;;;; tests/lisp-edit-comment-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Tests for the comment-region locator: how a maximal comment run is
;;;; collapsed, which runs stand free of any form and which belong to the form
;;;; below them, and how substring anchoring refuses to guess.
;;;;
;;;; The file-header cases are here because a reader's intuition and the
;;;; attachment rule disagree about them.  A header separated from the first
;;;; form by a blank line is free-standing; a header sitting flush on top of
;;;; the first form is that form's leading comment and substring anchoring
;;;; will not see it at all.  Both spellings are pinned so neither has to be
;;;; rediscovered.

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
                #:cst-node-start
                #:cst-node-end
                #:cst-node-start-line
                #:cst-node-end-line
                #:cst-node-value
                #:parse-top-level-forms)
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
so the caller can pick rather than have one chosen silently."
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
      (true (search "[0]" report))
      (true (search "[1]" report))
      (true (search "Shared wording here." report))
      (true (search "Shared wording there." report)))))

(define-test line-range-narrows-an-ambiguous-substring
  "A line range settles a substring that matches more than one region, and is
only consulted once the substring alone has failed to."
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
