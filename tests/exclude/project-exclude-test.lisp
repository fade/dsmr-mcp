;;;; tests/exclude/project-exclude-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for exclude drift detection and repair, over real git
;;;; repositories.
;;;;
;;;; Two things this file is deliberately built to avoid.
;;;;
;;;; The first is asserting against ambient state. Every test writes its own
;;;; template file and makes that the pattern set of record for its own extent,
;;;; rather than reading the developer's ~/.config, so the suite gives the same
;;;; answer on a build host that has no template at all. Every fixture likewise
;;;; seeds the baseline exclude it intends to measure, because whether git init
;;;; populates that file depends on the host's configured template directory.
;;;;
;;;; The second is an absence assertion aimed at nothing. A check that reports
;;;; "no drift" passes just as readily against a repository it never looked at,
;;;; so the tests that assert a clean answer are paired with one that must come
;;;; back dirty, and the two run against fixtures that differ by exactly one
;;;; pattern.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/exclude/project-exclude-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/exclude/project-exclude-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-exclude
                #:*exclude-template-path*
                #:exclude-template-path
                #:exclude-template-missing-error
                #:template-exclude-patterns
                #:parse-exclude-patterns
                #:repo-exclude-path
                #:missing-exclude-patterns
                #:ensure-exclude-patterns
                #:repair-repo-exclude)
  (:import-from #:dsmr-mcp/src/git
                #:not-a-repository-error)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:seed-exclude-patterns)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/exclude/project-exclude-test)

;;; ---------------------------------------------------------------------------
;;; The template fixture
;;; ---------------------------------------------------------------------------

(defvar +fixture-template-patterns+
  '(".planning/" ".planning" ".claude/" ".claude"
    "AGENTS.md" "CLAUDE.md" "CONTEXT-HANDOFF.md")
  "The pattern set every test in this file measures against.

It is written to a file the test creates, never read from the developer's
~/.config. A suite that read the real template would assert a different thing on
every machine, and would report nothing at all on a host that has no template.")

(defun %write-fixture-template (directory patterns)
  "Write PATTERNS to a template file under DIRECTORY and return its pathname.

A leading comment block and a blank line go in ahead of them, so the parse being
exercised is the one a real template presents rather than a bare list."
  (let ((path (merge-pathnames "info/exclude"
                               (uiop:ensure-directory-pathname directory))))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create
                              :element-type 'character)
      (write-line "# A fixture pattern set, written by the test that reads it." out)
      (write-line "# Comment lines and blank lines carry no pattern." out)
      (terpri out)
      (dolist (pattern patterns)
        (write-line pattern out)))
    path))

(defmacro with-fixture-template ((path-var &key (patterns '+fixture-template-patterns+))
                                 &body body)
  "Bind PATH-VAR to a freshly written template file, make it the pattern set of
record for the extent of BODY, and delete it afterwards.

The environment override is cleared as well as the variable bound, so a
developer whose shell already points the check somewhere cannot change what this
suite measures. PATH-VAR is declared ignorable: most tests care only that the
template is in place, not where it landed."
  (let ((dir (gensym "TEMPLATE-DIR-"))
        (saved (gensym "SAVED-")))
    `(let* ((,dir (%make-temp-directory))
            (,path-var (%write-fixture-template ,dir ,patterns))
            (,saved (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE"))
            (*exclude-template-path* ,path-var))
       (declare (ignorable ,path-var))
       (unwind-protect
            (progn
              (setf (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE") "")
              ,@body)
         (setf (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE") (or ,saved ""))
         (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore)))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun %all-but-last (list)
  "Return LIST without its final element."
  (butlast list))

(defun %read-exclude (root)
  "Return the text of the exclude file belonging to the repository at ROOT."
  (uiop:read-file-string (repo-exclude-path root)))

(defun %lines (text)
  "Return the non-empty lines of TEXT, in order."
  (remove-if (lambda (line) (string= line ""))
             (uiop:split-string text :separator '(#\Newline))))

;;; ---------------------------------------------------------------------------
;;; Reading a template
;;; ---------------------------------------------------------------------------

(define-test parse-keeps-patterns-and-drops-everything-else
  "Comments, blank lines and surrounding whitespace carry no pattern."
  (is equal '(".planning/" "CLAUDE.md")
      (parse-exclude-patterns
       (format nil "# a comment~%~%  .planning/  ~%   # indented comment~%CLAUDE.md~%")))
  (is equal '() (parse-exclude-patterns ""))
  (is equal '() (parse-exclude-patterns (format nil "# only~%~%"))))

(define-test the-template-supplies-the-pattern-set
  "The patterns come back in template order, read from the file at call time."
  (with-fixture-template (path)
    (is equal (namestring path) (namestring (exclude-template-path)))
    (is equal +fixture-template-patterns+ (template-exclude-patterns))))

(define-test an-absent-template-signals-rather-than-reporting-clean
  "A host with no template must not report every repository as carrying every
pattern. That answer is a false clean on the one check whose whole purpose is to
find a missing pattern, and nothing downstream could tell it from a real one.

CONTROL: the same repair call is made twice, once with the template present and
once with it absent, and only the second signals. Were the absent case merely
returning an empty set, the first call's :UPDATED would be indistinguishable
from the second's."
  (with-fixture-template (path)
    (with-temp-git-repo (root)
      (seed-exclude-patterns root (%all-but-last +fixture-template-patterns+))
      (is eq :updated (getf (repair-repo-exclude root) :action-taken))
      (let ((*exclude-template-path*
              (merge-pathnames "no-such-template" (%make-temp-directory))))
        (fail (template-exclude-patterns) 'exclude-template-missing-error)
        (fail (repair-repo-exclude root) 'exclude-template-missing-error)))))

;;; ---------------------------------------------------------------------------
;;; The pure transform
;;; ---------------------------------------------------------------------------

(define-test missing-patterns-are-reported-in-template-order
  "What is absent, in the order the template declares it, and NIL for nothing."
  (is equal '(".claude" "CONTEXT-HANDOFF.md")
      (missing-exclude-patterns '("CLAUDE.md" ".planning" ".planning/" ".claude/" "AGENTS.md")
                                +fixture-template-patterns+))
  (is eq nil (missing-exclude-patterns +fixture-template-patterns+
                                       +fixture-template-patterns+)))

(define-test the-merge-is-pure-and-idempotent
  "The input text is never mutated, and applying the transform twice yields what
applying it once yields.

CONTROL: the first application is asserted to have changed the text. An
idempotence check on a transform that does nothing at all passes trivially."
  (let* ((original (format nil "# local~%my-local-scratch/~%"))
         (untouched (copy-seq original))
         (once (ensure-exclude-patterns original +fixture-template-patterns+))
         (twice (ensure-exclude-patterns once +fixture-template-patterns+)))
    (is string= untouched original "the input string is not mutated")
    (isnt string= original once "the first application adds the missing patterns")
    (is string= once twice "a second application changes nothing")
    (is eq nil (missing-exclude-patterns (parse-exclude-patterns once)
                                         +fixture-template-patterns+))))

;;; ---------------------------------------------------------------------------
;;; Repair over real repositories
;;; ---------------------------------------------------------------------------

(define-test drift-is-detected-and-repaired
  "A repository one pattern behind the template is reported and repaired.

CONTROL: a second repository seeded with every template pattern is measured in
the same test and must come back :ALREADY-PRESENT. A check that cannot report
clean has not detected anything when it reports drift."
  (with-fixture-template (path)
    (with-temp-git-repo (drifted)
      (seed-exclude-patterns drifted (%all-but-last +fixture-template-patterns+))
      (let ((report (repair-repo-exclude drifted)))
        (is eq :updated (getf report :action-taken))
        (is equal '("CONTEXT-HANDOFF.md") (getf report :added-patterns))
        (true (probe-file (getf report :backup-path))
              "an updated repository keeps a backup of what it had")
        (is eq nil (missing-exclude-patterns
                    (parse-exclude-patterns (%read-exclude drifted))
                    +fixture-template-patterns+))))
    (with-temp-git-repo (compliant)
      (seed-exclude-patterns compliant +fixture-template-patterns+)
      (let ((report (repair-repo-exclude compliant)))
        (is eq :already-present (getf report :action-taken))
        (is eq nil (getf report :added-patterns))
        (is eq nil (getf report :backup-path))))))

(define-test a-second-repair-writes-nothing
  "Running the repair again reports what was found rather than acting, and the
file is not rewritten.

CONTROL: the write date is asserted to have CHANGED across the first repair,
which proves the instrument can observe a write at all. Without it, a stopped
clock would satisfy the second assertion. A second of real time is allowed to
pass before each call, since a rewrite inside the same second would carry the
same date as no write at all."
  (with-fixture-template (path)
    (with-temp-git-repo (root)
      (seed-exclude-patterns root (%all-but-last +fixture-template-patterns+))
      (let ((before (file-write-date (repo-exclude-path root))))
        (sleep 1.1)
        (let ((first (repair-repo-exclude root)))
          (is eq :updated (getf first :action-taken))
          (let ((after-first (file-write-date (repo-exclude-path root))))
            (isnt = before after-first "the first repair is observably a write")
            (sleep 1.1)
            (let ((second (repair-repo-exclude root)))
              (is eq :already-present (getf second :action-taken))
              (is eq nil (getf second :added-patterns))
              (is = after-first (file-write-date (repo-exclude-path root))
                  "the second repair leaves the file alone"))))))))

(define-test local-entries-and-comments-survive-a-repair
  "Entries a repository carries for its own reasons are not the template's to
remove, and neither are its comments.

CONTROL: the repaired file is asserted to be strictly longer than the original
and to contain every one of its lines. Asserting only that one local entry
survived would pass against a repair that dropped the rest."
  (with-fixture-template (path)
    (with-temp-git-repo (root)
      (seed-exclude-patterns root (list "# entries this repository keeps for itself"
                                        "my-local-scratch/"
                                        ".planning/"
                                        ".claude/"))
      (let* ((original (%read-exclude root))
             (original-lines (%lines original))
             (report (repair-repo-exclude root))
             (repaired (%read-exclude root))
             (repaired-lines (%lines repaired)))
        (is eq :updated (getf report :action-taken))
        (true (member "my-local-scratch/" repaired-lines :test #'string=)
              "the local entry survives")
        (true (member "# entries this repository keeps for itself" repaired-lines
                      :test #'string=)
              "the local comment survives")
        (true (> (length repaired) (length original))
              "the repaired file is strictly longer than what it replaced")
        (dolist (line original-lines)
          (true (member line repaired-lines :test #'string=)
                (format nil "the original line ~S survives" line)))))))

(define-test the-backup-holds-what-the-file-held
  "An update is recoverable: the backup is the pre-repair file, byte for byte."
  (with-fixture-template (path)
    (with-temp-git-repo (root)
      (seed-exclude-patterns root (%all-but-last +fixture-template-patterns+))
      (let* ((original (%read-exclude root))
             (report (repair-repo-exclude root))
             (backup (getf report :backup-path)))
        (is eq :updated (getf report :action-taken))
        (true (probe-file backup) "the backup exists on disk")
        (is string= original (uiop:read-file-string backup)
            "the backup is what the file held before the repair")
        (isnt string= original (%read-exclude root)
              "and the file itself did change, so the backup is worth having")))))

(define-test a-repository-with-no-exclude-file-is-created
  "Nothing to back up, so nothing is backed up, and the action says created."
  (with-fixture-template (path)
    (with-temp-git-repo (root)
      (let ((exclude (repo-exclude-path root)))
        (when (probe-file exclude)
          (delete-file exclude))
        (let ((report (repair-repo-exclude root)))
          (is eq :created (getf report :action-taken))
          (is eq nil (getf report :backup-path))
          (is equal +fixture-template-patterns+ (getf report :added-patterns))
          (is eq nil (missing-exclude-patterns
                      (parse-exclude-patterns (%read-exclude root))
                      +fixture-template-patterns+)))))))

(define-test a-dry-run-reports-and-writes-nothing
  "What would be added is named, and the file is left exactly as it was."
  (with-fixture-template (path)
    (with-temp-git-repo (root)
      (seed-exclude-patterns root (%all-but-last +fixture-template-patterns+))
      (let ((before (%read-exclude root))
            (stamp (file-write-date (repo-exclude-path root))))
        (sleep 1.1)
        (let ((report (repair-repo-exclude root :dry-run t)))
          (is eq :would-update (getf report :action-taken))
          (is equal '("CONTEXT-HANDOFF.md") (getf report :added-patterns))
          (is eq nil (getf report :backup-path))
          (is string= before (%read-exclude root) "the file is unchanged")
          (is = stamp (file-write-date (repo-exclude-path root))
              "and it was not rewritten with the same content"))))))

(define-test a-plain-directory-is-not-a-repository
  "There is no local exclude file outside a repository, so there is nothing to
repair and the caller is told so rather than handed a fabricated one."
  (with-fixture-template (path)
    (let ((plain (%make-temp-directory)))
      (unwind-protect
           (progn
             (fail (repair-repo-exclude plain) 'not-a-repository-error)
             (is eq nil (probe-file (repo-exclude-path plain))))
        (uiop:delete-directory-tree plain :validate t
                                          :if-does-not-exist :ignore)))))
