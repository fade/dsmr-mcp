;;;; tests/memory/memory-search-tool-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the memory-search verb as a client sees it: argument
;;;; errors, the structured result, and the text content, which is the only
;;;; part most clients display. Every store lives in a fresh temp directory
;;;; bound as the config dir, so the operator's real ~/.claude is never read.

;; Package evolution guard: drop a stale package so re-loading this leaf into a
;; warm image picks up an evolved import list instead of erroring on conflicts.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/memory/memory-search-tool-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/memory/memory-search-tool-test
  (:use #:cl #:zebra)
  ;; Importing the class forces the tool file to load, which registers it.
  (:import-from #:dsmr-mcp/src/tools/memory-search
                #:memory-search-tool)
  (:import-from #:dsmr-mcp/src/tools/base
                #:tool-handle
                #:*tool-classes*)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht)
  (:import-from #:dsmr-mcp/src/state
                #:make-session
                #:get-tool-instance)
  (:import-from #:dsmr-mcp/src/memory
                #:*claude-config-dir*
                #:*search-time-limit*
                #:store-name-for)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/memory/memory-search-tool-test)

;;; helpers -------------------------------------------------------------------

(defun %unique-temp-dir (stem)
  "Create and return a fresh temp directory named for STEM, as a truename.
The suffix comes from an entropy-seeded state because SBCL's default
*random-state* repeats across fresh processes."
  (let* ((*random-state* (make-random-state t))
         (dir (uiop:ensure-directory-pathname
               (merge-pathnames
                (format nil "~A-~A/" stem (random (expt 2 48)))
                (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (truename dir)))

(defmacro with-tool-fixture ((tmp repo store) &body body)
  "Bind TMP to a fresh temp config dir, REPO to a fixture repository inside
it, and STORE to the name of REPO's store directory. The store directory is
not created. The tree is deleted afterwards."
  `(let* ((,tmp (%unique-temp-dir "dsmr-memory-tool-test"))
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

(defun %page-text (&key name description status reason body)
  "Page text with frontmatter carrying the given fields, then BODY."
  (with-output-to-string (out)
    (format out "---~%")
    (when name (format out "name: ~A~%" name))
    (when description (format out "description: ~A~%" description))
    (when status (format out "status: ~A~%" status))
    (when reason (format out "status_reason: ~A~%" reason))
    (format out "---~%")
    (when body (write-string body out))))

(defun %plant (tmp store file &rest page-args)
  "Write a page named FILE into STORE under TMP/projects/."
  (write-fixture-file tmp (format nil "projects/~A/memory/~A" store file)
                      (apply #'%page-text page-args)))

(defun %call (root &rest kvs)
  "Call memory-search in a session rooted at ROOT (or rootless when NIL)
with the arguments KVS and return the result payload."
  (let* ((session (make-session :id "memory-search-tool-test" :project-root root))
         (tool (get-tool-instance session "memory-search")))
    (gethash "result" (tool-handle tool "req-1" (apply #'make-ht kvs)))))

(defun %content-text (payload)
  "The text of PAYLOAD's first content item, or NIL."
  (let ((vec (and (hash-table-p payload) (gethash "content" payload))))
    (when (and (vectorp vec) (plusp (length vec)))
      (gethash "text" (aref vec 0)))))

(defun %results (payload)
  "PAYLOAD's results as a list."
  (coerce (gethash "results" payload) 'list))

(defun %result-named (payload name)
  "The result in PAYLOAD whose name is NAME."
  (find name (%results payload) :key (lambda (r) (gethash "name" r))
                                :test #'equal))

(defun %line-containing (text needle)
  "The first line of TEXT containing NEEDLE, or NIL."
  (find-if (lambda (line) (search needle line))
           (uiop:split-string text :separator '(#\Newline))))

(defun %has-value-key-p (object)
  "True when any hash-table reachable from OBJECT has a key named value."
  (typecase object
    (hash-table
     (or (nth-value 1 (gethash "value" object))
         (loop for v being the hash-values of object
               thereis (%has-value-key-p v))))
    (string nil)
    (vector (some #'%has-value-key-p object))
    (t nil)))

(defun %tree-snapshot (dir)
  "Every file under DIR with its size, write date and full content, sorted by
name, so two snapshots are equal only when nothing was created, removed or
changed."
  (sort (loop for path in (directory (merge-pathnames "**/*.*" dir))
              unless (uiop:directory-pathname-p path)
                collect (with-open-file (in path :element-type '(unsigned-byte 8))
                          (let ((bytes (make-array (file-length in)
                                                   :element-type '(unsigned-byte 8))))
                            (read-sequence bytes in)
                            (list (namestring path)
                                  (length bytes)
                                  (file-write-date path)
                                  (coerce bytes 'list)))))
        #'string< :key #'first))

;;; registration and arguments ------------------------------------------------

(define-test memory-search-is-registered
  "The verb is registered under its wire name when the tool file loads."
  (true (gethash "memory-search" *tool-classes*)))

(define-test no-root-default-scope-errors
  "The default scope needs a project root, and the refusal does not point a
rootless caller at another scope."
  (with-tool-fixture (tmp repo store)
    (let ((payload (%call nil "query" "x")))
      (is eq t (gethash "isError" payload))
      (is string= "project-root-not-set" (gethash "error_type" payload))
      (false (search "scope all" (%content-text payload))))))

(define-test scope-all-needs-a-root
  "Scope all reads other projects' stores, so a rootless session is refused
with the same error the default scope gives, and nothing is searched."
  (with-tool-fixture (tmp repo store)
    (%plant tmp "-other-store" "theirs.md" :name "theirs" :body "a planted term
")
    (let ((payload (%call nil "query" "planted" "scope" "all")))
      (is eq t (gethash "isError" payload))
      (is string= "project-root-not-set" (gethash "error_type" payload))
      (false (gethash "results" payload))
      (false (search "theirs" (%content-text payload))))))

(define-test blank-query-is-invalid
  "A query of only whitespace is an argument error, not an empty search."
  (with-tool-fixture (tmp repo store)
    (let ((payload (%call repo "query" "   ")))
      (is eq t (gethash "isError" payload))
      (is string= "invalid-argument" (gethash "error_type" payload)))))

(define-test scope-matches-the-enum-exactly
  "The verb accepts the scope values exactly as the schema lists them, so a
direct call and a call over the wire agree on what is refused."
  (with-tool-fixture (tmp repo store)
    (let ((payload (%call repo "query" "x" "scope" "All")))
      (is eq t (gethash "isError" payload))
      (is string= "invalid-argument" (gethash "error_type" payload)))))

(define-test bad-regex-is-invalid
  "A malformed regular expression is the caller's mistake, reported as an
argument error rather than a failed search."
  (with-tool-fixture (tmp repo store)
    (%plant tmp store "a.md" :name "a" :body "text
")
    (let ((payload (%call repo "query" "(" "regex" t)))
      (is eq t (gethash "isError" payload))
      (is string= "invalid-argument" (gethash "error_type" payload)))))

(define-test backtracking-regex-is-a-search-error
  "A pattern that backtracks without end returns a search-error once the time
limit passes, and the session answers the next call. The outer guard keeps a
regression from hanging the suite."
  (with-tool-fixture (tmp repo store)
    (%plant tmp store "prose.md" :name "prose"
            :body (format nil "~{~A~^ ~} !~%" (loop repeat 30 collect "word")))
    (let ((payload (handler-case
                       (sb-ext:with-timeout 30
                         (let ((*search-time-limit* 1))
                           (%call repo "query" "^(\\w+\\s?)*$" "regex" t)))
                     (sb-ext:timeout () :wedged))))
      (true (hash-table-p payload) "the call returned")
      (when (hash-table-p payload)
        (is eq t (gethash "isError" payload))
        (is string= "search-error" (gethash "error_type" payload))
        (true (search "second" (%content-text payload)))))
    (is = 1 (gethash "count" (%call repo "query" "prose")))))

(define-test last-page-offers-no-more
  "The final page and an offset past the end neither set limited nor tell
the caller to pass another offset."
  (with-tool-fixture (tmp repo store)
    (loop for file in '("a.md" "b.md" "c.md")
          do (%plant tmp store file :name "p" :body "needle
"))
    (let ((first-page (%call repo "query" "needle" "limit" 2)))
      (is eq t (gethash "limited" first-page))
      (true (search "pass offset 2 for more" (%content-text first-page))))
    (let ((last-page (%call repo "query" "needle" "limit" 2 "offset" 2)))
      (is = 1 (gethash "count" last-page))
      (false (gethash "limited" last-page))
      (false (search "for more" (%content-text last-page))))
    (let ((past (%call repo "query" "needle" "limit" 2 "offset" 7)))
      (is = 0 (gethash "count" past))
      (false (gethash "limited" past))
      (false (search "for more" (%content-text past)))
      (true (search "past the last" (%content-text past))))))

;;; status visibility ---------------------------------------------------------

(define-test retired-page-marked-in-text
  "A superseded page is returned, flagged in the structured result, and
marked with its status and reason on its own line of the text content."
  (with-tool-fixture (tmp repo store)
    (%plant tmp store "old.md" :name "old rule" :status "superseded"
                               :reason "replaced by the new rule"
                               :body "a planted term
")
    (let* ((payload (%call repo "query" "planted"))
           (hit (%result-named payload "old rule"))
           (text (%content-text payload))
           (line (%line-containing text "old.md")))
      (true hit)
      (is equalp #("superseded") (gethash "status" hit))
      (is string= "replaced by the new rule" (gethash "status_reason" hit))
      (is eq t (gethash "retired" hit))
      (true line)
      (true (search "[status: superseded]" line))
      (true (search "replaced by the new rule" line)))))

(define-test hide-retired-reports-hidden
  "Hiding retired pages removes them and says how many were hidden."
  (with-tool-fixture (tmp repo store)
    (%plant tmp store "old.md" :name "old rule" :status "superseded"
                               :body "a planted term
")
    (%plant tmp store "live.md" :name "live rule" :body "a planted term
")
    (let* ((payload (%call repo "query" "planted" "hide_retired" t))
           (text (%content-text payload)))
      (is equal '("live rule")
          (mapcar (lambda (r) (gethash "name" r)) (%results payload)))
      (is = 1 (gethash "hidden_retired" (gethash "coverage" payload)))
      (true (search "1 retired page hidden" text)))))

(define-test status-less-result-has-no-status-key
  "A page without a status carries no status keys, and the text never
invents one for it."
  (with-tool-fixture (tmp repo store)
    (%plant tmp store "plain.md" :name "plain" :body "a planted term
")
    (let* ((payload (%call repo "query" "planted"))
           (hit (%result-named payload "plain")))
      (true hit)
      (false (nth-value 1 (gethash "status" hit)))
      (false (nth-value 1 (gethash "status_reason" hit)))
      (false (nth-value 1 (gethash "updated" hit)))
      (false (search "current" (string-downcase (%content-text payload))))
      (false (search "[status:" (%content-text payload))))))

;;; scope and coverage --------------------------------------------------------

(define-test scope-all-results-name-store
  "With scope all, every result names the store directory it came from."
  (with-tool-fixture (tmp repo store)
    (%plant tmp store "mine.md" :name "mine" :body "a planted term
")
    (%plant tmp "-other-store" "theirs.md" :name "theirs" :body "a planted term
")
    (let ((payload (%call repo "query" "planted" "scope" "all")))
      (is = 2 (length (%results payload)))
      (is equal (sort (list store "-other-store") #'string<)
          (sort (mapcar (lambda (r) (gethash "store" r)) (%results payload))
                #'string<))
      (true (search "-other-store/theirs.md" (%content-text payload))))))

(define-test missing-store-text-says-nothing-searched
  "An absent project store is not an error, and both the coverage and the
text say that nothing was searched."
  (with-tool-fixture (tmp repo store)
    (let* ((payload (%call repo "query" "planted"))
           (coverage (gethash "coverage" payload))
           (record (aref (gethash "stores" coverage) 0))
           (text (%content-text payload)))
      (false (gethash "isError" payload))
      (is = 0 (gethash "count" payload))
      (is eq nil (gethash "exists" record))
      (true (search (gethash "path" record) text))
      (true (search "does not exist" text)))))

(define-test memory-index-never-returned
  "MEMORY.md is never a result, and the coverage counts it as skipped."
  (with-tool-fixture (tmp repo store)
    (write-fixture-file tmp (format nil "projects/~A/memory/MEMORY.md" store)
                        "- [a page](a.md) zyxquux
")
    (%plant tmp store "a.md" :name "a" :body "nothing to find
")
    (let* ((payload (%call repo "query" "zyxquux"))
           (skipped (gethash "pages_skipped" (gethash "coverage" payload))))
      (is = 0 (gethash "count" payload))
      (is = 1 (gethash "index" skipped)))))

(define-test search-writes-nothing
  "A search leaves every file in the config dir exactly as it was."
  (with-tool-fixture (tmp repo store)
    (write-fixture-file tmp (format nil "projects/~A/memory/MEMORY.md" store)
                        "- [old](old.md)
")
    (%plant tmp store "old.md" :name "old rule" :status "superseded"
                               :body "a planted term
")
    (%plant tmp "-other-store" "theirs.md" :name "theirs" :body "a planted term
")
    (let ((before (%tree-snapshot tmp)))
      (%call nil "query" "planted" "scope" "all")
      (is equal before (%tree-snapshot tmp)))))

(define-test no-value-key-in-response
  "No object in the response carries a key named value."
  (with-tool-fixture (tmp repo store)
    (%plant tmp store "old.md" :name "old rule" :status "superseded"
                               :reason "gone" :body "a planted term
")
    (%plant tmp store "plain.md" :name "plain" :body "a planted term
")
    (let ((payload (%call repo "query" "planted")))
      (is = 2 (gethash "count" payload))
      (false (%has-value-key-p payload)))))
