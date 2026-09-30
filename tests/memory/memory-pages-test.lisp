;;;; tests/memory/memory-pages-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Zebra tests for the memory page layer: deriving a session's store name,
;;;; walking up to the repository root (linked worktrees included), confining
;;;; reads to store pages, and reading page frontmatter. Every path lives in a
;;;; fresh temp directory bound as the config dir, so the operator's real
;;;; ~/.claude is never read.

;; Package evolution guard: drop a stale package so re-loading this leaf into a
;; warm image picks up an evolved import list instead of erroring on conflicts.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/memory/memory-pages-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/memory/memory-pages-test
  (:use #:cl #:zebra)
  (:import-from #:dsmr-mcp/src/memory
                #:*claude-config-dir*
                #:claude-config-dir
                #:projects-directory
                #:store-name-for
                #:repository-root
                #:project-store-directory
                #:memory-page-path
                #:list-store-pages
                #:parse-frontmatter
                #:read-memory-page
                #:page-store
                #:page-name
                #:page-description
                #:page-status
                #:page-lines
                #:page-body-start
                #:retired-status-p)
  (:import-from #:dsmr-mcp/src/project-root
                #:allowed-read-path)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file))

(in-package #:dsmr-mcp/tests/memory/memory-pages-test)

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

(defmacro with-memory-fixture ((var) &body body)
  "Bind VAR to a fresh temp directory that also serves as the Claude config
dir for the dynamic extent of BODY, and delete the tree afterwards."
  `(let* ((,var (%unique-temp-dir "dsmr-memory-test"))
          (*claude-config-dir* ,var))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       ,var :validate t :if-does-not-exist :ignore)))))

(defun %dir (root relative)
  "Create the directory RELATIVE (ending in /) under ROOT and return its truename."
  (let ((pn (merge-pathnames relative root)))
    (ensure-directories-exist pn)
    (truename pn)))

(defun %same-path-p (a b)
  "True when A and B name the same existing or literal path."
  (and a b
       (string= (namestring (or (ignore-errors (truename a)) a))
                (namestring (or (ignore-errors (truename b)) b)))))

(defun %symlink (target link)
  "Make LINK a symbolic link to TARGET."
  (ensure-directories-exist link)
  (uiop:run-program (list "ln" "-s"
                          (uiop:native-namestring target)
                          (uiop:native-namestring link))))

(defun %git-marker-above-p (dir)
  "True when DIR or any ancestor holds a .git entry."
  (let ((components (pathname-directory dir)))
    (loop for n from (length components) downto 1
          for d = (make-pathname :directory (subseq components 0 n)
                                 :name nil :type nil :defaults dir)
            thereis (probe-file (merge-pathnames ".git" d)))))

;;; store naming --------------------------------------------------------------

(define-test store-name-maps-every-non-alnum
  "Every character outside ASCII letters and digits becomes a hyphen, so dots,
underscores and slashes all map the same way, and so does a non-ASCII letter."
  (is string= "-home-fade--claude" (store-name-for #p"/home/fade/.claude/"))
  (is string= "-home-fade-system-scripts"
      (store-name-for #p"/home/fade/system_scripts/"))
  (is string= "-home-fade-SourceCode-lisp-DeepSkyV2-valis"
      (store-name-for #p"/home/fade/SourceCode/lisp/DeepSkyV2/valis/"))
  (is string= "-tmp-caf-"
      (store-name-for (pathname (format nil "/tmp/caf~C/" (code-char 233))))))

;;; repository root -----------------------------------------------------------

(define-test repository-root-walks-up
  "A subdirectory of a repository maps to the directory holding .git."
  (with-memory-fixture (tmp)
    (let ((repo (%dir tmp "repo/")))
      (write-fixture-file repo ".git/HEAD" "ref: refs/heads/main
")
      (let ((deep (%dir repo "a/b/")))
        (true (%same-path-p repo (repository-root deep)))))))

(define-test repository-root-worktree-maps-to-main
  "A linked worktree maps back to its main checkout through gitdir and
commondir, so every worktree of a repository shares one store."
  (with-memory-fixture (tmp)
    (let* ((main (%dir tmp "main/"))
           (wt (%dir tmp "wt/"))
           (wt-gitdir (%dir main ".git/worktrees/wt/")))
      (write-fixture-file main ".git/HEAD" "ref: refs/heads/main
")
      (write-fixture-file wt-gitdir "commondir" "../..
")
      (write-fixture-file wt ".git"
                          (format nil "gitdir: ~A~%"
                                  (string-right-trim
                                   "/" (uiop:native-namestring wt-gitdir))))
      (true (%same-path-p main (repository-root wt)))
      (true (%same-path-p main (repository-root (%dir wt "src/")))))))

(define-test repository-root-outside-repo
  "A directory with no .git anywhere above it maps to itself."
  (with-memory-fixture (tmp)
    (if (%git-marker-above-p tmp)
        (skip "the temp directory sits inside a git repository")
        (let ((lonely (%dir tmp "lonely/x/")))
          (true (%same-path-p lonely (repository-root lonely)))))))

;;; store directory -----------------------------------------------------------

(define-test project-store-honours-config-dir
  "The store sits under the bound config dir, and under CLAUDE_CONFIG_DIR when
nothing is bound."
  (with-memory-fixture (tmp)
    (let* ((proj (%dir tmp "proj/"))
           (expected (merge-pathnames
                      (make-pathname :directory
                                     (list :relative "projects"
                                           (store-name-for proj) "memory"))
                      tmp)))
      (true (%same-path-p expected (project-store-directory proj)))
      (let ((alt (%dir tmp "alt-config/"))
            (old (uiop:getenv "CLAUDE_CONFIG_DIR")))
        (unwind-protect
             (let ((*claude-config-dir* nil))
               (setf (uiop:getenv "CLAUDE_CONFIG_DIR") (uiop:native-namestring alt))
               (true (uiop:subpathp (project-store-directory proj)
                                    (merge-pathnames "projects/" alt))))
          (setf (uiop:getenv "CLAUDE_CONFIG_DIR") (or old "")))))))

;;; read confinement ----------------------------------------------------------

(define-test symlink-outside-store-is-rejected
  "A page link inside a store that resolves outside the projects directory is
refused; a regular page resolves to its truename."
  (with-memory-fixture (tmp)
    (let* ((projects (%dir tmp "projects/"))
           (good (write-fixture-file tmp "projects/s/memory/good.md" "body
"))
           (secret (write-fixture-file tmp "outside/secret.md" "secret
"))
           (leak (merge-pathnames "projects/s/memory/leak.md" tmp)))
      (%symlink secret leak)
      (true (probe-file leak) "the symlink exists")
      (false (memory-page-path leak projects))
      (true (%same-path-p good (memory-page-path good projects))))))

(define-test page-path-requires-store-depth-and-md
  "Only a .md file directly inside <store>/memory/ passes."
  (with-memory-fixture (tmp)
    (let ((projects (%dir tmp "projects/")))
      (false (memory-page-path
              (write-fixture-file tmp "projects/s/memory/sub/x.md" "x") projects))
      (false (memory-page-path
              (write-fixture-file tmp "projects/s/x.md" "x") projects))
      (false (memory-page-path
              (write-fixture-file tmp "projects/s/memory/x.md.bak-2026-01-01" "x")
              projects))
      (true (memory-page-path
             (write-fixture-file tmp "projects/s/memory/ok.md" "x") projects)))))

(define-test list-store-pages-reports-exclusions
  "Listing a store skips the index and non-markdown files, counts them by
reason, and counts subdirectories it did not search."
  (with-memory-fixture (tmp)
    (let ((projects (%dir tmp "projects/"))
          (store (%dir tmp "projects/s/memory/")))
      (write-fixture-file store "MEMORY.md" "- index")
      (write-fixture-file store "a.md" "a")
      (write-fixture-file store "x.md.bak-2026-01-01" "old")
      (write-fixture-file store "retired/b.md" "b")
      (multiple-value-bind (pages skipped subdirs) (list-store-pages store projects)
        (is = 1 (length pages))
        (is string= "a.md" (file-namestring (first pages)))
        (is = 2 (length skipped))
        (is eql 1 (cdr (assoc :index skipped)))
        (is eql 1 (cdr (assoc :not-markdown skipped)))
        (is eql 1 subdirs)))))

(define-test read-jail-is-not-widened
  "The general read allow-list still refuses a memory page: memory reads go
through their own check only."
  (with-memory-fixture (tmp)
    (let ((session-root (%dir tmp "proj/"))
          (page (write-fixture-file tmp "projects/s/memory/a.md" "a")))
      (false (allowed-read-path page session-root)))))

;;; frontmatter ---------------------------------------------------------------

(defun %page (&rest lines)
  "Join LINES into page text, each line ending in a newline."
  (format nil "~{~A~%~}" lines))

(defparameter *frontmatter-rows*
  (list
   (list "nested metadata block with a trailing space after the key"
         (%page "---" "name: fleet" "description: \"a quoted one\"" "metadata: "
                "  type: project" "  modified: 2026-08-30T18:25:10.000Z" "---" "" "Body")
         '(:frontmatter-p t :name "fleet" :description "a quoted one"
           :status nil :updated nil)
         8)
   (list "double-quoted escapes"
         (%page "---"
                "description: \"say \\\"hi\\\" \\\\ a\\nb\\tc \\/ \\u00e9\""
                "---" "Body")
         (list :description (format nil "say \"hi\" \\ a~%b~Cc / ~C"
                                    #\Tab (code-char 233)))
         4)
   (list "single-quoted doubling"
         (%page "---" "description: 'it''s fine'" "---" "Body")
         '(:description "it's fine")
         4)
   (list "plain value holding a colon and space"
         (%page "---" "description: a: b" "---" "Body")
         '(:description "a: b")
         4)
   (list "plain value holding a hash"
         (%page "---" "description: see #42" "---" "Body")
         '(:description "see #42")
         4)
   (list "block list status"
         (%page "---" "status:" "  - superseded" "  - disputed" "---" "Body")
         '(:status ("superseded" "disputed"))
         6)
   (list "scalar status"
         (%page "---" "status: obsolete" "---" "Body")
         '(:status ("obsolete"))
         4)
   (list "flow list status"
         (%page "---" "status: [provisional, disputed]" "---" "Body")
         '(:status ("provisional" "disputed"))
         4)
   (list "status inside the metadata block"
         (%page "---" "name: n" "metadata:" "  status: refuted" "---" "Body")
         '(:status ("refuted"))
         6)
   (list "unrecognised status kept verbatim"
         (%page "---" "status: banana" "---" "Body")
         '(:status ("banana"))
         4)
   (list "status reason and update time"
         (%page "---" "status: superseded" "status_reason: Replaced by x."
                "updated: '2026-09-29T21:15:00Z'" "---" "Body")
         '(:status ("superseded") :status-reason "Replaced by x."
           :updated "2026-09-29T21:15:00Z")
         6)
   (list "unterminated frontmatter"
         (%page "---" "name: x" "body text")
         '(:frontmatter-p nil :name nil :status nil)
         1)
   (list "no frontmatter"
         (%page "# Title" "text")
         '(:frontmatter-p nil :status nil)
         1)
   (list "frontmatter that is not valid YAML"
         (%page "---" "name: [unclosed" "\"stray" "---" "Body")
         '(:frontmatter-p t :name "[unclosed" :status nil)
         5))
  "Rows of (label page-text expected-plist-subset expected-body-start).")

(define-test frontmatter-reads-real-shapes
  "Every frontmatter shape found on real pages parses leniently: status comes
from the top level or the metadata block as a verbatim list, plain values are
kept whole, and a missing or broken block leaves the whole file as body. A
page without a status never reports one, and never the word current."
  (dolist (row *frontmatter-rows*)
    (destructuring-bind (label text expected body-start) row
      (multiple-value-bind (plist start) (parse-frontmatter text)
        (loop for (key value) on expected by #'cddr
              do (is equal value (getf plist key) "~A: ~S" label key))
        (is eql body-start start "~A: body start" label)
        (unless (getf expected :status)
          (false (find "current"
                       (loop for value in plist
                             when (stringp value) collect value
                             when (consp value) append value)
                       :test #'equalp)
                 "~A: no invented status" label))))))

(define-test read-memory-page-line-numbers
  "Page lines cover the whole file, so the body start indexes the first body
line; the name falls back to the filename stem; an oversized page is read up
to the cap and says so."
  (with-memory-fixture (tmp)
    (let ((path (write-fixture-file tmp "projects/s/memory/stem.md"
                                    (%page "---" "description: d" "---"
                                           "First body line" "second"))))
      (multiple-value-bind (page capped) (read-memory-page path "s")
        (true page)
        (false capped)
        (is = 4 (page-body-start page))
        (is string= "First body line" (aref (page-lines page) (1- (page-body-start page))))
        (is = 5 (length (page-lines page)))
        (is string= "stem" (page-name page))
        (is string= "d" (page-description page))
        (is string= "s" (page-store page))
        (false (page-status page))))
    (let ((big (write-fixture-file tmp "projects/s/memory/big.md"
                                   (make-string 1000 :initial-element #\x))))
      (multiple-value-bind (page capped) (read-memory-page big "s" :max-chars 100)
        (true page)
        (true capped)))
    (false (read-memory-page (merge-pathnames "projects/s/memory/absent.md" tmp) "s"))))

(define-test retired-status-recognised
  "Obsolete, superseded and refuted retire a page in any letter case; the
provisional and disputed values, no status, and an unknown value do not."
  (true (retired-status-p '("obsolete")))
  (true (retired-status-p '("Superseded")))
  (true (retired-status-p '("disputed" "REFUTED")))
  (false (retired-status-p '("provisional")))
  (false (retired-status-p '("disputed")))
  (false (retired-status-p nil))
  (false (retired-status-p '("banana"))))
