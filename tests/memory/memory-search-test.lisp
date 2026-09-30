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

(define-test scope-all-needs-no-root
  "Scope all needs no session root."
  (with-search-fixture (tmp repo store)
    (%plant tmp "-other-store" "theirs.md" :name "theirs" :body "a planted term
")
    (is equal '("theirs.md")
        (%hit-files (search-memory "planted" :scope "all")))))

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
