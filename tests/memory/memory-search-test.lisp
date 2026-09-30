;;;; tests/memory/memory-search-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for searching memory stores: which stores a scope reads, how
;;;; query terms match, and the coverage record that tells an empty answer
;;;; from a store that was never searched. Every store lives in a fresh temp
;;;; directory bound as the config dir, so the operator's real ~/.claude is
;;;; never read.

;; Package evolution guard: drop a stale package so re-loading this leaf into a
;; warm image picks up an evolved import list instead of erroring on conflicts.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/memory/memory-search-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/memory/memory-search-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/memory
                #:*claude-config-dir*
                #:store-name-for
                #:project-store-directory
                #:search-memory
                #:memory-search-aborted
                #:outcome-hits
                #:outcome-total
                #:outcome-limited
                #:outcome-coverage
                #:hit-page
                #:hit-tier
                #:hit-body-hits
                #:hit-excerpts
                #:hit-retired
                #:page-file
                #:page-store
                #:page-status
                #:page-status-reason
                #:page-updated)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/memory/memory-search-test)

;;; helpers -------------------------------------------------------------------

(defun %unique-temp-dir (stem)
  "Create and return a fresh temp directory named for STEM, as a truename.
The random suffix comes from an entropy-seeded state because SBCL's default
*random-state* repeats across fresh processes, and a repeated name could let a
leftover directory leak into a later run."
  (let* ((*random-state* (make-random-state t))
         (dir (uiop:ensure-directory-pathname
               (merge-pathnames
                (format nil "~A-~A/" stem (random (expt 2 48)))
                (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (truename dir)))

(defmacro with-search-fixture ((tmp repo store) &body body)
  "Bind TMP to a fresh temp directory serving as the Claude config dir, REPO
to a fixture repository root inside it, and STORE to the name of REPO's store
directory under TMP/projects/. The store directory itself is not created.
The tree is deleted afterwards."
  `(let* ((,tmp (%unique-temp-dir "dsmr-memory-search-test"))
          (*claude-config-dir* ,tmp))
     (unwind-protect
          (let* ((,repo (progn
                          (write-fixture-file ,tmp "repo/.git/HEAD" "ref: refs/heads/main
")
                          (truename (merge-pathnames "repo/" ,tmp))))
                 (,store (store-name-for ,repo)))
            (declare (ignorable ,repo ,store))
            ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       ,tmp :validate t :if-does-not-exist :ignore)))))

(defun %page-text (&key name description status body)
  "Page text with frontmatter carrying NAME, DESCRIPTION and STATUS when
given, followed by BODY."
  (with-output-to-string (out)
    (format out "---~%")
    (when name (format out "name: ~A~%" name))
    (when description (format out "description: ~A~%" description))
    (when status (format out "status: ~A~%" status))
    (format out "---~%")
    (when body (write-string body out))))

(defun %plant (tmp store file &rest page-args)
  "Write a page named FILE into STORE under TMP/projects/ and return its path."
  (write-fixture-file tmp (format nil "projects/~A/memory/~A" store file)
                      (apply #'%page-text page-args)))

(defun %hit-files (outcome)
  "The filenames of OUTCOME's hits, in rank order."
  (mapcar (lambda (hit) (file-namestring (page-file (hit-page hit))))
          (outcome-hits outcome)))

(defun %coverage (outcome key)
  "The coverage value under KEY in OUTCOME."
  (getf (outcome-coverage outcome) key))

(defun %skipped (outcome reason)
  "The count of pages skipped for REASON in OUTCOME, or 0."
  (or (cdr (assoc reason (%coverage outcome :pages-skipped))) 0))

;;; scope ---------------------------------------------------------------------

(define-test default-scope-reads-only-project-store
  "Scope project reads only the store derived from the session root; a
matching page in another store is not returned."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "mine.md" :name "mine" :body "a planted term
")
    (%plant tmp "-other-store" "theirs.md" :name "theirs" :body "a planted term
")
    (let ((outcome (search-memory "planted" :session-root repo)))
      (is equal '("mine.md") (%hit-files outcome))
      (is string= "project" (%coverage outcome :scope))
      (is = 1 (length (%coverage outcome :stores))))))

(define-test scope-all-names-each-store
  "Scope all searches every store and every hit names the store it came from."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "mine.md" :name "mine" :body "a planted term
")
    (%plant tmp "-other-store" "theirs.md" :name "theirs" :body "a planted term
")
    (let* ((outcome (search-memory "planted" :scope "all" :session-root repo))
           (stores (mapcar (lambda (hit) (page-store (hit-page hit)))
                           (outcome-hits outcome))))
      (is = 2 (length stores))
      (true (member store stores :test #'equal))
      (true (member "-other-store" stores :test #'equal))
      (is string= "all" (%coverage outcome :scope))
      (is = 2 (length (%coverage outcome :stores))))))

(define-test scope-all-needs-a-root
  "Scope all with no session root signals, as scope project does, rather
than reading every project's store for a caller with no project."
  (with-search-fixture (tmp repo store)
    (%plant tmp "-other-store" "theirs.md" :name "theirs" :body "a planted term
")
    (fail (search-memory "planted" :scope "all") error)))

(define-test project-scope-needs-a-root
  "Scope project with no session root signals rather than guessing a store."
  (with-search-fixture (tmp repo store)
    (fail (search-memory "planted") error)))

(define-test blank-query-returns-nothing
  "A query with no terms returns no hits and does not signal."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "mine.md" :name "mine" :body "anything
")
    (let ((outcome (search-memory "   " :session-root repo)))
      (is equal '() (outcome-hits outcome))
      (is = 0 (outcome-total outcome)))))

;;; matching ------------------------------------------------------------------

(define-test terms-are-anded
  "Every term must match somewhere in the page."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "one.md" :name "one" :body "alpha only
")
    (%plant tmp store "both.md" :name "both" :body "alpha and beta
")
    (is equal '("both.md")
        (%hit-files (search-memory "alpha beta" :session-root repo)))))

(define-test matching-ignores-case
  "Terms match regardless of letter case."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "cache.md" :name "cache" :body "the fasl cache
")
    (is equal '("cache.md")
        (%hit-files (search-memory "FASL" :session-root repo)))))

(define-test literal-mode-quotes-metachars
  "In literal mode a regex metacharacter matches only itself."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "abc.md" :name "p" :body "abc
")
    (%plant tmp store "dot.md" :name "q" :body "a.c
")
    (is equal '("dot.md")
        (%hit-files (search-memory "a.c" :session-root repo)))))

(define-test regex-mode-compiles-terms
  "In regex mode each term is a regular expression, and a malformed one
signals the regex library's syntax error to the caller."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "fal.md" :name "p" :body "a fal here
")
    (is equal '("fal.md")
        (%hit-files (search-memory "fas?l" :session-root repo :regex t)))
    (is equal '()
        (%hit-files (search-memory "fas?l" :session-root repo)))
    (fail (search-memory "(" :session-root repo :regex t)
        cl-ppcre:ppcre-syntax-error)))

(defun %abort-within (seconds thunk)
  "Call THUNK under an outer guard of SECONDS. Returns :ABORTED when it
signals MEMORY-SEARCH-ABORTED, :WEDGED when the guard fires first, and
:RETURNED when it returns normally. The guard keeps a regression from hanging
the suite."
  (handler-case
      (sb-ext:with-timeout seconds
        (funcall thunk)
        :returned)
    (memory-search-aborted () :aborted)
    (sb-ext:timeout () :wedged)))

(define-test backtracking-regex-is-stopped-by-the-time-limit
  "A pattern that backtracks without end on an ordinary line stops at the
time limit with MEMORY-SEARCH-ABORTED, instead of holding the caller."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "prose.md" :name "prose"
            :body (format nil "~{~A~^ ~} !~%" (loop repeat 30 collect "word")))
    (let ((started (get-internal-real-time)))
      (is eq :aborted
          (%abort-within 30 (lambda ()
                              (search-memory "^(\\w+\\s?)*$" :session-root repo
                                                             :regex t :time-limit 1))))
      (true (< (/ (- (get-internal-real-time) started) internal-time-units-per-second)
               10)
            "stopped close to the limit"))))

(define-test stack-exhaustion-is-a-clean-abort
  "A pattern whose matcher recurses once per character exhausts the stack on
a long line; the search reports MEMORY-SEARCH-ABORTED rather than letting a
storage condition escape."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "long.md" :name "long"
            :body (format nil "~A!~%" (make-string 200000 :initial-element #\a)))
    (is eq :aborted
        (%abort-within 30 (lambda ()
                            (search-memory "(a|ab)*$" :session-root repo :regex t))))))

;;; coverage ------------------------------------------------------------------

(define-test missing-project-store-is-reported
  "A session whose store does not exist gets zero hits and a coverage record
saying the store is missing, not an answer that looks like an empty store."
  (with-search-fixture (tmp repo store)
    (%plant tmp "-other-store" "theirs.md" :name "theirs" :body "planted
")
    (let* ((outcome (search-memory "planted" :session-root repo))
           (stores (%coverage outcome :stores)))
      (is equal '() (outcome-hits outcome))
      (is = 1 (length stores))
      (false (getf (first stores) :exists))
      (is string= (namestring (project-store-directory repo))
          (getf (first stores) :path))
      (is string= store (getf (first stores) :name))
      (is = 0 (%coverage outcome :pages-scanned)))))

(define-test existing-empty-store-is-distinguishable
  "An existing store with nothing matching reports that it exists."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "mine.md" :name "mine" :body "unrelated
")
    (let ((outcome (search-memory "planted" :session-root repo)))
      (is equal '() (outcome-hits outcome))
      (true (getf (first (%coverage outcome :stores)) :exists))
      (is = 1 (%coverage outcome :pages-scanned)))))

(define-test coverage-counts-what-was-read
  "Coverage counts pages scanned, pages skipped by reason and subdirectories
left unsearched."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "a.md" :name "a" :body "x
")
    (%plant tmp store "b.md" :name "b" :body "x
")
    (%plant tmp store "c.md" :name "c" :body "x
")
    (write-fixture-file tmp (format nil "projects/~A/memory/MEMORY.md" store) "index
")
    (write-fixture-file tmp (format nil "projects/~A/memory/a.md.bak" store) "x
")
    (write-fixture-file tmp (format nil "projects/~A/memory/retired/old.md" store) "x
")
    (let ((outcome (search-memory "x" :session-root repo)))
      (is = 3 (%coverage outcome :pages-scanned))
      (is = 1 (%skipped outcome :index))
      (is = 1 (%skipped outcome :not-markdown))
      (is = 1 (%coverage outcome :subdirectories-not-searched))
      (is = 3 (outcome-total outcome))
      (false (outcome-limited outcome)))))

;;; ranking -------------------------------------------------------------------

(defun %repeat-lines (text count)
  "COUNT lines each holding TEXT."
  (with-output-to-string (out)
    (dotimes (i count) (format out "~A~%" text))))

(define-test metadata-match-outranks-body-hits
  "A page matching every term in its filename, name or description ranks
ahead of a page matching only in its body, however many body hits that page
has."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "a.md" :name "a" :description "about the needle" :body "x
")
    (%plant tmp store "b.md" :name "b" :body (%repeat-lines "a needle" 10))
    (let* ((outcome (search-memory "needle" :session-root repo))
           (hits (outcome-hits outcome)))
      (is equal '("a.md" "b.md") (%hit-files outcome))
      (is = 0 (hit-tier (first hits)))
      (is = 2 (hit-tier (second hits)))
      (is = 10 (hit-body-hits (second hits))))))

(define-test partial-metadata-match-is-middle-tier
  "A page where only some terms match its metadata sits between a full
metadata match and a body-only match."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "full.md" :name "full" :description "needle and thread" :body "x
")
    (%plant tmp store "part.md" :name "part" :description "needle" :body "thread
")
    (%plant tmp store "body.md" :name "body" :body "needle thread
")
    (let ((outcome (search-memory "needle thread" :session-root repo)))
      (is equal '("full.md" "part.md" "body.md") (%hit-files outcome))
      (is equal '(0 1 2) (mapcar #'hit-tier (outcome-hits outcome))))))

(define-test tier-then-hits-then-store-then-file
  "Within a tier, pages order by body hits descending, then by store name and
filename ascending, so the order is the same on every run."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "p1.md" :name "p1" :body (%repeat-lines "needle" 1))
    (%plant tmp store "p2.md" :name "p2" :body (%repeat-lines "needle" 3))
    (%plant tmp store "p0.md" :name "p0" :body (%repeat-lines "needle" 1))
    (%plant tmp "-aaa" "z.md" :name "z" :body (%repeat-lines "needle" 1))
    (let ((outcome (search-memory "needle" :scope "all" :session-root repo)))
      (is equal '("p2.md" "z.md" "p0.md" "p1.md") (%hit-files outcome))
      (is equal '(3 1 1 1) (mapcar #'hit-body-hits (outcome-hits outcome))))))

;;; excerpts ------------------------------------------------------------------

(defun %excerpt-summary (hit)
  "HIT's excerpts as a list of (line . match)."
  (mapcar (lambda (e) (cons (getf e :line) (getf e :match)))
          (hit-excerpts hit)))

(defun %hit-named (outcome file)
  "The hit in OUTCOME whose page filename is FILE."
  (find file (outcome-hits outcome)
        :key (lambda (hit) (file-namestring (page-file (hit-page hit))))
        :test #'string=))

(define-test excerpts-carry-file-absolute-lines
  "Excerpt line numbers count from the top of the file, frontmatter included,
with CONTEXT lines either side of each match, overlapping windows merged, and
at most LINES-PER-PAGE matching lines per page."
  (with-search-fixture (tmp repo store)
    (let ((front "---
name: e
description: d
updated: 2026-01-01
status: active
---
"))
      (write-fixture-file tmp (format nil "projects/~A/memory/e.md" store)
                          (format nil "~Aone~%two~%the needle~%four~%five~%" front))
      (write-fixture-file tmp (format nil "projects/~A/memory/m.md" store)
                          (format nil "~Aneedle a~%needle b~%three~%" front))
      (write-fixture-file tmp (format nil "projects/~A/memory/many.md" store)
                          (format nil "~A~A" front (%repeat-lines "needle" 5)))
      (let ((outcome (search-memory "needle" :session-root repo)))
        (is equal '((8) (9 . t) (10))
            (%excerpt-summary (%hit-named outcome "e.md")))
        (is string= "the needle"
            (getf (second (hit-excerpts (%hit-named outcome "e.md"))) :text))
        (is equal '((7 . t) (8 . t) (9))
            (%excerpt-summary (%hit-named outcome "m.md")))
        (is = 3 (count-if #'cdr (%excerpt-summary (%hit-named outcome "many.md")))))
      (is equal '((9 . t))
          (%excerpt-summary
           (%hit-named (search-memory "needle" :session-root repo :context 0) "e.md")))
      (is = 1 (count-if #'cdr
                        (%excerpt-summary
                         (%hit-named (search-memory "needle" :session-root repo
                                                             :lines-per-page 1)
                                     "many.md")))))))

(define-test long-lines-are-truncated
  "An excerpt line longer than 240 characters is cut to 240."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "long.md" :name "long"
            :body (format nil "needle~A~%" (make-string 994 :initial-element #\x)))
    (let* ((hit (first (outcome-hits (search-memory "needle" :session-root repo))))
           (excerpt (find t (hit-excerpts hit) :key (lambda (e) (getf e :match)))))
      (is = 240 (length (getf excerpt :text))))))

(define-test cut-excerpt-keeps-the-match
  "When the match sits past the cut on a long line, the 240-character
excerpt moves along the line so the match is still shown."
  (with-search-fixture (tmp repo store)
    (%plant tmp store "late.md" :name "late"
            :body (format nil "~Aneedle~A~%"
                          (make-string 600 :initial-element #\x)
                          (make-string 400 :initial-element #\y)))
    (let* ((hit (first (outcome-hits (search-memory "needle" :session-root repo))))
           (excerpt (find t (hit-excerpts hit) :key (lambda (e) (getf e :match)))))
      (is = 240 (length (getf excerpt :text)))
      (true (search "needle" (getf excerpt :text))))))

;;; retired pages -------------------------------------------------------------

(defun %plant-retired-pair (tmp store)
  "Plant a superseded page a-old.md and an otherwise identical page b-new.md
with no status in STORE. Filename order puts a-old.md first, so any demotion
of the retired page shows as a change of order."
  (write-fixture-file tmp (format nil "projects/~A/memory/a-old.md" store)
                      "---
name: old
status: superseded
status_reason: replaced by b-new
updated: 2026-09-01
---
a needle
")
  (write-fixture-file tmp (format nil "projects/~A/memory/b-new.md" store)
                      "---
name: new
---
a needle
"))

(define-test retired-page-shown-and-flagged
  "A superseded page is returned by default, flagged retired, carries its
status, reason and update date, and ranks exactly where it would with no
status."
  (with-search-fixture (tmp repo store)
    (%plant-retired-pair tmp store)
    (let* ((outcome (search-memory "needle" :session-root repo))
           (old (first (outcome-hits outcome)))
           (new (second (outcome-hits outcome))))
      (is equal '("a-old.md" "b-new.md") (%hit-files outcome))
      (true (hit-retired old))
      (is equal '("superseded") (page-status (hit-page old)))
      (is string= "replaced by b-new" (page-status-reason (hit-page old)))
      (is string= "2026-09-01" (page-updated (hit-page old)))
      (is = (hit-tier new) (hit-tier old))
      (is = (hit-body-hits new) (hit-body-hits old))
      (is = 0 (%coverage outcome :hidden-retired)))))

(define-test hide-retired-excludes-and-counts
  "Hiding retired pages removes them from the hits and the total, and the
coverage says how many were hidden."
  (with-search-fixture (tmp repo store)
    (%plant-retired-pair tmp store)
    (let ((outcome (search-memory "needle" :session-root repo :hide-retired t)))
      (is equal '("b-new.md") (%hit-files outcome))
      (is = 1 (outcome-total outcome))
      (is = 1 (%coverage outcome :hidden-retired)))))

(define-test status-less-page-has-no-status
  "A page that states no status carries none and is not flagged retired."
  (with-search-fixture (tmp repo store)
    (%plant-retired-pair tmp store)
    (let ((new (%hit-named (search-memory "needle" :session-root repo) "b-new.md")))
      (false (page-status (hit-page new)))
      (false (hit-retired new)))))

(define-test retired-page-with-comment-or-mark-is-hidden
  "A retired status followed by a comment, and a page saved with a byte order
mark, are both recognised as retired and left out by HIDE-RETIRED."
  (with-search-fixture (tmp repo store)
    (write-fixture-file tmp (format nil "projects/~A/memory/commented.md" store)
                        "---
status: superseded  # replaced by current.md
---
a needle
")
    (write-fixture-file tmp (format nil "projects/~A/memory/marked.md" store)
                        (format nil "~C---~%name: marked~%status: refuted~%---~%a needle~%"
                                (code-char #xFEFF)))
    (%plant tmp store "current.md" :name "current" :body "a needle
")
    (let ((all (search-memory "needle" :session-root repo)))
      (is equal '("refuted") (page-status (hit-page (%hit-named all "marked.md"))))
      (is equal '("superseded") (page-status (hit-page (%hit-named all "commented.md")))))
    (let ((outcome (search-memory "needle" :session-root repo :hide-retired t)))
      (is equal '("current.md") (%hit-files outcome))
      (is = 2 (%coverage outcome :hidden-retired)))))

;;; pagination ----------------------------------------------------------------

(define-test limit-and-offset-slice-after-ranking
  "LIMIT and OFFSET slice the ranked list; TOTAL counts every match and
LIMITED says matches were left out. LIMIT is clamped to 1..100."
  (with-search-fixture (tmp repo store)
    ;; Filenames run opposite to rank, so slicing before ranking would show.
    (loop for file in '("a.md" "b.md" "c.md" "d.md" "e.md")
          for hits from 1
          do (%plant tmp store file :name "p" :body (%repeat-lines "needle" hits)))
    (let ((outcome (search-memory "needle" :session-root repo :limit 2 :offset 2)))
      (is equal '("c.md" "b.md") (%hit-files outcome))
      (is = 5 (outcome-total outcome))
      (true (outcome-limited outcome)))
    (let ((outcome (search-memory "needle" :session-root repo)))
      (is equal '("e.md" "d.md" "c.md" "b.md" "a.md") (%hit-files outcome))
      (false (outcome-limited outcome)))
    (is = 100 (%coverage (search-memory "needle" :session-root repo :limit 500) :limit))
    (let ((outcome (search-memory "needle" :session-root repo :limit 0)))
      (is = 1 (%coverage outcome :limit))
      (is = 1 (length (outcome-hits outcome))))
    (is = 0 (%coverage (search-memory "needle" :session-root repo :offset -3) :offset))))

(define-test last-page-and-past-end-are-not-limited
  "The final page, and an offset at or past the end, report nothing more to
fetch, so a client paging on LIMITED stops."
  (with-search-fixture (tmp repo store)
    (loop for file in '("a.md" "b.md" "c.md" "d.md" "e.md")
          do (%plant tmp store file :name "p" :body "needle
"))
    (let ((first-page (search-memory "needle" :session-root repo :limit 2)))
      (is = 2 (length (outcome-hits first-page)))
      (true (outcome-limited first-page)))
    (let ((last-page (search-memory "needle" :session-root repo :limit 2 :offset 4)))
      (is = 1 (length (outcome-hits last-page)))
      (false (outcome-limited last-page)))
    (let ((exact-end (search-memory "needle" :session-root repo :limit 3 :offset 2)))
      (is = 3 (length (outcome-hits exact-end)))
      (false (outcome-limited exact-end)))
    (dolist (offset '(5 9))
      (let ((past (search-memory "needle" :session-root repo :limit 2 :offset offset)))
        (is = 0 (length (outcome-hits past)))
        (is = 5 (outcome-total past))
        (false (outcome-limited past))))))
