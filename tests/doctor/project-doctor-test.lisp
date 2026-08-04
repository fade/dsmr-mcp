;;;; tests/doctor/project-doctor-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for repository normalisation, over real git repositories.
;;;;
;;;; The property this file exists to defend is the one whose failure reaches a
;;;; third party: our tooling must never become tracked content in a repository
;;;; we do not own. Every other check here can be green while that one fails.
;;;;
;;;; Almost every assertion in this file is about absence, and an absence
;;;; assertion passes just as readily when the instrument is pointed at nothing
;;;; at all. So each of them is paired, inside one test, with the same
;;;; instrument observed answering the other way: a status that has been seen
;;;; non-empty before it is required to be empty, a first run that changed
;;;; something before a second run that must not, a snapshot comparison caught
;;;; noticing a hand edit before it is trusted to report equality, a baseline
;;;; asserted absent before it is asserted present.
;;;;
;;;; The ordering test is the one nothing else would catch. Exclude-then-write
;;;; and write-then-exclude produce identical end states on a run that
;;;; succeeds, so the only way to tell them apart is to make the write fail and
;;;; look at the exclude afterwards.
;;;;
;;;; A foreign repository is held to the quality gate throughout this file,
;;;; which is not how the catalog maps profiles to tiers by default. The
;;;; mapping is deliberately provisional, and this is the configuration in
;;;; which apparatus of ours is written into a worktree we do not own, which is
;;;; the only configuration in which the leak under test can happen at all. A
;;;; suite measuring the default mapping would write nothing and pass every
;;;; never-leak assertion without exercising one of them.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/doctor/project-doctor-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/doctor/project-doctor-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-doctor
                #:normalise-repository
                #:report-changed
                #:report-already-correct
                #:report-recorded-debt
                #:report-accepted
                #:report-unresolved
                #:report-classification
                #:report-profile
                #:report-exclude
                #:report-debt-baseline
                #:report-remote-added
                #:report-head-sha-before
                #:report-head-sha-after
                #:verify-no-tracked-apparatus
                #:*repair-writer*)
  (:import-from #:dsmr-mcp/src/project-deviation
                #:deviation-item
                #:foreign-apparatus-tracked)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item-key)
  (:import-from #:dsmr-mcp/src/project-shape-catalog
                #:catalog-item
                #:apparatus-paths-for-profile
                #:*assessed-tiers*)
  (:import-from #:dsmr-mcp/src/project-exclude
                #:*exclude-template-path*
                #:parse-exclude-patterns
                #:repo-exclude-path)
  (:import-from #:dsmr-mcp/src/project-gate-scan
                #:*linter-path*
                #:linter-path
                #:gate-scanner-available-p)
  (:import-from #:dsmr-mcp/src/git
                #:run-git
                #:git-head-sha
                #:git-remote-url
                #:git-tracked-files
                #:git-status-porcelain)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:fixture-commit-file
                #:seed-exclude-patterns
                #:+ours-origin-url+
                #:+third-party-origin-url+
                #:+third-party-upstream-url+)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/doctor/project-doctor-test)

;;; ---------------------------------------------------------------------------
;;; The pattern set every fixture is measured against
;;; ---------------------------------------------------------------------------

(defvar +fixture-template-patterns+
  '(".claude/" "AGENTS.md" "CLAUDE.md")
  "The exclude patterns of record for the extent of this file.

Written to a file each test creates. A suite reading the developer's own
template would measure something different on every machine and nothing at all
on a build host that has none.

Deliberately does NOT list any of the apparatus paths the catalog names. The
patterns that keep our own files out of a maintainer's index have to come from
the catalog, and a template already carrying them would hide a run that never
consulted it.")

(defun %write-fixture-template (directory patterns)
  "Write PATTERNS to a template file under DIRECTORY and return its pathname."
  (let ((path (merge-pathnames "info/exclude"
                               (uiop:ensure-directory-pathname directory))))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create
                              :element-type 'character)
      (write-line "# A fixture pattern set, written by the test that reads it." out)
      (terpri out)
      (dolist (pattern patterns)
        (write-line pattern out)))
    path))

(defmacro with-fixture-template ((&key (patterns '+fixture-template-patterns+))
                                 &body body)
  "Make a freshly written template the pattern set of record for BODY.

The environment override is cleared as well as the variable bound, so a shell
that already points the check elsewhere cannot change what this suite measures."
  (let ((dir (gensym "TEMPLATE-DIR-"))
        (path (gensym "TEMPLATE-"))
        (saved (gensym "SAVED-")))
    `(let* ((,dir (%make-temp-directory))
            (,path (%write-fixture-template ,dir ,patterns))
            (,saved (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE"))
            (*exclude-template-path* ,path))
       (unwind-protect
            (progn
              (setf (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE") "")
              ,@body)
         (setf (uiop:getenv "DSMR_GIT_EXCLUDE_TEMPLATE") (or ,saved ""))
         (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore)))))

(defmacro with-gated-foreign-profile (&body body)
  "Hold a foreign repository to the quality gate for the extent of BODY.

This is the configuration in which our apparatus is written into a worktree
belonging to somebody else, and therefore the only one in which the leak these
tests are aimed at can occur. Under the catalog's default mapping a foreign
repository is held to the invariants alone, nothing of ours would be written,
and every never-leak assertion here would pass without measuring anything."
  `(let ((*assessed-tiers* '((:ours . (:invariant :gate))
                             (:foreign . (:invariant :gate)))))
     ,@body))

(defmacro with-no-linter ((root) &body body)
  "Run BODY with the quality-gate scanner genuinely unreachable.

Both the variable and the environment override are handled: a developer whose
shell already points DSMR_LINTER at a real binary would otherwise be running a
different test from the one written here."
  (let ((saved (gensym "SAVED-")))
    `(let ((,saved (uiop:getenv "DSMR_LINTER"))
           (*linter-path* (merge-pathnames
                           "no-linter-here"
                           (uiop:ensure-directory-pathname ,root))))
       (unwind-protect
            (progn (setf (uiop:getenv "DSMR_LINTER") "") ,@body)
         (setf (uiop:getenv "DSMR_LINTER") (or ,saved ""))))))

;;; ---------------------------------------------------------------------------
;;; Fixture shapes
;;; ---------------------------------------------------------------------------

(defun %clear-ambient-ignores (root)
  "Make every path in ROOT stageable regardless of how the host ignores things.

A repository created on this machine inherits a seeded local exclude and a
global ignore file, and both cover our apparatus paths by design. A fixture that
has to place such a path in the index, or that must see one appear in git
status, would otherwise answer differently depending on whose machine the suite
ran on. Both sources are emptied for this repository alone."
  (seed-exclude-patterns root '())
  (let ((empty (write-fixture-file root ".git/no-ignores" "")))
    (run-git (list "config" "core.excludesFile" (namestring empty))
             :directory root))
  root)

(defun %remove-seeded-hook (root)
  "Delete any pre-commit hook the host's git template seeded into ROOT.

The template configured on this machine installs one into every new repository,
so a fixture that does not clear it starts with part of the gate already in
place and measures a different repair from the one written down."
  (uiop:delete-file-if-exists
   (merge-pathnames ".git/hooks/pre-commit" (uiop:ensure-directory-pathname root))))

(defun %seed-library (root)
  "Give ROOT the committed shape of a working third-party Lisp library.

Committed rather than merely written, so the working tree starts clean. A
fixture whose own files are untracked makes git status non-empty before the
doctor has done anything, and the emptiness this file asserts would then be
measuring the fixture rather than the run."
  (fixture-commit-file root "example.asd" "(asdf:defsystem \"example\")")
  (fixture-commit-file root "src/main.lisp" ";; source")
  (fixture-commit-file root "tests/main-test.lisp" ";; tests")
  root)

(defparameter +violating-source+
  "(defun swallow (x)
  (ignore-errors (error \"boom\"))
  x)
"
  "A source file carrying one violation nobody could call a matter of taste.
The rule against swallowing every condition is on by default, so a scan
reporting nothing here reported nothing at all.")

(defun %foreign-fixture (root)
  "Prepare ROOT as a clean, committed, foreign repository ready to be adopted."
  (%clear-ambient-ignores root)
  (%remove-seeded-hook root)
  (%seed-library root)
  root)

;;; ---------------------------------------------------------------------------
;;; Reading a run
;;; ---------------------------------------------------------------------------

(defun %changed-items (report)
  "Return the item key of every change the run reported, NIL for the exclude."
  (mapcar (lambda (entry) (getf entry :item)) (report-changed report)))

(defun %unresolved-keys (report)
  "Return the item key each unresolved finding names, or NIL when it names none."
  (mapcar (lambda (entry)
            (or (getf entry :item)
                (let ((item (deviation-item (getf entry :deviation))))
                  (and item (shape-item-key item)))))
          (report-unresolved report)))

(defun %exclude-patterns-in (root)
  "Return the patterns ROOT's local exclude currently declares."
  (let ((path (repo-exclude-path root)))
    (if (probe-file path)
        (parse-exclude-patterns (uiop:read-file-string path))
        '())))

(defun %has-pattern-p (root pattern)
  "Return true when ROOT's local exclude declares PATTERN."
  (and (member pattern (%exclude-patterns-in root) :test #'string=) t))

;;; ---------------------------------------------------------------------------
;;; Whole-tree snapshots
;;; ---------------------------------------------------------------------------

(defun %git-directory-p (directory)
  "Return true when DIRECTORY is a repository's own git directory."
  (let ((last (car (last (pathname-directory directory)))))
    (and (stringp last) (string= last ".git"))))

(defun %relative-to (path base)
  "Return PATH as it reads from BASE."
  (let ((p (namestring path))
        (b (namestring (uiop:ensure-directory-pathname base))))
    (if (and (>= (length p) (length b)) (string= b p :end2 (length b)))
        (subseq p (length b))
        p)))

(defun %snapshot (root)
  "Return a sorted list of (RELATIVE-PATH . CONTENT) for every file under ROOT
outside its git directory.

Content rather than a length, so a change that happens to preserve the size is
still a change. This is what lets non-destructiveness be asserted over the whole
tree instead of over one hand-picked file, which would only ever prove that one
file survived."
  (let ((base (uiop:ensure-directory-pathname root))
        (found '()))
    (uiop:collect-sub*directories
     base
     (lambda (directory) (not (%git-directory-p directory)))
     (lambda (directory) (not (%git-directory-p directory)))
     (lambda (directory)
       (dolist (file (uiop:directory-files directory))
         (push (cons (%relative-to file base) (uiop:read-file-string file))
               found))))
    (sort found #'string< :key #'car)))

;;; ---------------------------------------------------------------------------
;;; CONTROL 1: nothing of ours reaches the maintainer's git status
;;; ---------------------------------------------------------------------------

(define-test control-nothing-of-ours-reaches-the-maintainers-status
  "CONTROL, and it is the one that matters. V-2.

The non-empty half comes first, deliberately. An apparatus file written into a
foreign worktree with the exclude left alone must appear in that maintainer's
git status, and unless that has been observed, \"git status is clean\" is
equally true of a repository in which nothing was ever written. The second half
then runs a full repair over a fresh fixture and requires the same instrument,
on the same kind of repository, to answer empty.

The index is checked as well as the status. Present is the correct state for an
adopted repository; in the index is the leak."
  (with-fixture-template ()
    (with-gated-foreign-profile
      ;; First: the instrument answering the other way.
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (is equal '() (git-status-porcelain root)
            "precondition: the fixture starts clean")
        (write-fixture-file root ".mallet.lisp" ";; linter configuration")
        (true (git-status-porcelain root)
              "an apparatus file written with the exclude untouched is visible")
        (true (find-if (lambda (line) (search ".mallet.lisp" line))
                       (git-status-porcelain root))
              "and it is that file the maintainer would see"))
      ;; Then: the same instrument over a full run, and it must answer empty.
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (let ((report (normalise-repository root :policy :repair)))
          (true (report-changed report)
                "the run wrote something, so the emptiness below is about a run"))
        (is equal '() (git-status-porcelain root)
            "after a full repair the maintainer sees nothing at all")
        (dolist (path (apparatus-paths-for-profile :foreign))
          (false (member path (git-tracked-files root) :test #'string=)
                 "no apparatus path is in the index"))))))

;;; ---------------------------------------------------------------------------
;;; CONTROL 2: the exclude is updated before anything is written
;;; ---------------------------------------------------------------------------

(define-test control-the-exclude-is-updated-before-any-file-is-written
  "CONTROL. The ordering, which nothing else in this file would notice.

Exclude-then-write and write-then-exclude leave identical end states on a run
that succeeds, so the difference can only be seen when the write does not
happen. The writer is replaced with one that signals; the run dies; and the
exclude must already carry the apparatus patterns.

If the ordering were reversed the exclude would still be at its starting state
here, and this is the only test in the file that would go red."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (false (%has-pattern-p root ".mallet.lisp")
               "precondition: the exclude does not carry the apparatus pattern")
        (let ((*repair-writer*
                (lambda (path content)
                  (declare (ignore path content))
                  (error "the write step was replaced and refuses to run"))))
          (fail (normalise-repository root :policy :repair) 'simple-error
                "the run dies at the first write"))
        (true (%has-pattern-p root ".mallet.lisp")
              "the exclude already carried the apparatus pattern when the write ran")
        (true (%has-pattern-p root "scripts/lint-lisp.sh")
              "and every other apparatus path with it")
        (true (%has-pattern-p root ".gate-baseline.md")
              "the frozen baseline's path among them, before anything could write it")
        (false (probe-file (merge-pathnames ".mallet.lisp" root))
               "and no apparatus file exists, which is what makes the order visible")))))

;;; ---------------------------------------------------------------------------
;;; CONTROL 3: idempotence, with the first run observed changing something
;;; ---------------------------------------------------------------------------

(define-test control-a-second-run-changes-nothing-and-the-first-one-did
  "CONTROL. V-4.

Both halves in one test. An idempotence assertion over a run that never did
anything is satisfied by an implementation that does nothing at all, so the
first run is required to report changes before the second is required to report
none."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (let ((first (normalise-repository root :policy :repair)))
          (true (report-changed first)
                "the first run changed something")
          (is eq :updated (getf (report-exclude first) :action-taken)
              "including the local exclude"))
        (let ((second (normalise-repository root :policy :repair)))
          (is equal '() (report-changed second)
              "the second run changed nothing")
          (is eq :already-present (getf (report-exclude second) :action-taken)
              "and found the exclude already correct")
          (true (report-already-correct second)
                "and says what it found already correct rather than only staying silent"))))))

;;; ---------------------------------------------------------------------------
;;; CONTROL 4: nothing pre-existing is overwritten or deleted
;;; ---------------------------------------------------------------------------

(define-test control-nothing-pre-existing-is-overwritten-or-deleted
  "CONTROL. V-5.

The whole tree is compared before and after, and then the comparison itself is
put to work: one file is edited by hand and the same comparison must notice. An
equality assertion that has never been observed failing is not an instrument,
and a snapshot function that returned a constant would satisfy the first half
perfectly.

The fixture deliberately already carries a file at one of the paths a repair
would otherwise write. Without it the tree holds nothing a repair could collide
with, and the comparison would be equally happy against an implementation that
overwrites everything it finds."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (write-fixture-file root ".mallet.lisp" ";; the maintainer's own file")
        (let ((before (%snapshot root)))
          (true (assoc ".mallet.lisp" before :test #'string=)
                "precondition: the tree holds a file a repair could collide with")
          (normalise-repository root :policy :repair)
          (let ((after (%snapshot root)))
            (dolist (entry before)
              (is equal (cdr entry) (cdr (assoc (car entry) after :test #'string=))
                  "every file present before the run is byte-identical after it"))
            ;; The comparison, caught noticing.
            (write-fixture-file root "src/main.lisp" ";; edited by hand")
            (let ((edited (%snapshot root)))
              (false (equal (cdr (assoc "src/main.lisp" before :test #'string=))
                            (cdr (assoc "src/main.lisp" edited :test #'string=)))
                     "the comparison detects a change when there is one"))))))))

(define-test an-existing-file-at-an-apparatus-path-survives-the-repair
  "A file the repository already had is never replaced, and the rest of the
group is still installed around it."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (write-fixture-file root ".mallet.lisp" ";; the maintainer's own file")
        (normalise-repository root :policy :repair)
        (is equal ";; the maintainer's own file"
            (uiop:read-file-string (merge-pathnames ".mallet.lisp" root))
            "the existing file is untouched")
        (true (probe-file (merge-pathnames "scripts/lint-lisp.sh" root))
              "and the parts of the gate that were absent are installed")))))

(define-test a-destination-that-already-exists-is-reported-rather-than-replaced
  "An item that is unsatisfied while something already occupies its destination
is a finding, never a write.

A directory standing where a file is expected is the case that makes the two
questions come apart: the assertion is unsatisfied and the path is occupied."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (ensure-directories-exist
         (uiop:ensure-directory-pathname (merge-pathnames ".mallet.lisp" root)))
        (let ((report (normalise-repository root :policy :repair)))
          (true (member :mallet-config (%unresolved-keys report))
                "the occupied destination is reported unresolved")
          (false (member :mallet-config (%changed-items report))
                 "and nothing was written there"))))))

;;; ---------------------------------------------------------------------------
;;; CONTROL 5: the head sha does not move
;;; ---------------------------------------------------------------------------

(define-test control-the-head-sha-does-not-move-and-the-check-would-notice
  "CONTROL.

The doctor makes no commits, so the head sha before a run equals the one after.
That equality is worth nothing unless the two readings can differ, so the same
fixture then takes a commit and the same comparison must see it.

The hook is removed before that commit. The run just installed a working quality
gate, and it refuses the fixture's own source, which is the gate doing its job
rather than anything to do with the head sha."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (let ((before (git-head-sha root))
              (report (normalise-repository root :policy :repair)))
          (is equal before (git-head-sha root)
              "the run left the head where it found it")
          (is equal (report-head-sha-before report) (report-head-sha-after report)
              "and the report says so with both values")
          ;; The comparison, caught noticing.
          (%remove-seeded-hook root)
          (fixture-commit-file root "extra.txt" "x" :message "a commit")
          (false (equal before (git-head-sha root))
                 "a commit does move it, so the equality above was measuring"))))))

;;; ---------------------------------------------------------------------------
;;; CONTROL 6: the frozen baseline is written, not merely reported
;;; ---------------------------------------------------------------------------

(define-test control-the-frozen-baseline-is-written-not-merely-reported
  "CONTROL. SC-2.

Absent before and present after, in one test. An existence assertion that was
never observed failing cannot tell a document that was written from a report
saying one was, and this phase's whole debt story rests on the difference.

The same test asserts the file is neither tracked nor visible in the
maintainer's status. Present, excluded and invisible is the whole two-mode
requirement in one place.

Takes an explicit branch when no linter is installed rather than relying on a
skip form to end the test."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (fixture-commit-file root "src/violating.lisp" +violating-source+)
        (let ((baseline (merge-pathnames ".gate-baseline.md" root)))
          (false (probe-file baseline)
                 "precondition: no baseline exists before the run")
          (if (not (gate-scanner-available-p (linter-path)))
              (let ((report (normalise-repository root :policy :record-as-debt)))
                (is eq :not-enumerated
                    (getf (report-debt-baseline report) :action-taken)
                    "with no linter installed the debt is not enumerated")
                (false (probe-file baseline)
                       "and nothing is written"))
              (let ((report (normalise-repository root :policy :record-as-debt)))
                (is eq :created (getf (report-debt-baseline report) :action-taken)
                    "the run says it created the baseline")
                (true (probe-file baseline)
                      "and the file is on disk, which is the part a report cannot fake")
                (false (member ".gate-baseline.md" (git-tracked-files root)
                               :test #'string=)
                       "it is not tracked in a repository we do not own")
                (is equal '() (git-status-porcelain root)
                    "and it is invisible to the maintainer")
                (true (report-recorded-debt report)
                      "the run reports what it froze"))))))))

(define-test the-baseline-names-the-seeded-violation
  "The document describes the repository it was written for.

A baseline rendered from a template rather than from a scan would satisfy every
existence assertion in this file while naming no repository at all."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (fixture-commit-file root "src/violating.lisp" +violating-source+)
        (if (not (gate-scanner-available-p (linter-path)))
            (with-no-linter (root)
              (let ((report (normalise-repository root :policy :record-as-debt)))
                (is eq :not-enumerated
                    (getf (report-debt-baseline report) :action-taken)
                    "with no linter installed there is nothing to name")))
            (let* ((report (normalise-repository root :policy :record-as-debt))
                   (text (uiop:read-file-string
                          (merge-pathnames ".gate-baseline.md" root))))
              (true (plusp (getf (report-debt-baseline report) :site-count))
                    "the scan found at least one site")
              (true (search "violating.lisp" text)
                    "the baseline names the file the violation is in")
              (true (search "| src/violating.lisp:" text)
                    "and gives its position, so a reader can go and look")))))))

(define-test a-second-record-as-debt-run-leaves-the-baseline-alone
  "The frozen record is not rewritten.

A baseline is what was true when the gate went in. Rewriting it on a later run
destroys the record it exists to be, and makes that run report a change where
there was none."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (fixture-commit-file root "src/violating.lisp" +violating-source+)
        (if (not (gate-scanner-available-p (linter-path)))
            (let ((report (normalise-repository root :policy :record-as-debt)))
              (is eq :not-enumerated
                  (getf (report-debt-baseline report) :action-taken)
                  "with no linter installed there is no baseline to leave alone"))
            (let ((baseline (merge-pathnames ".gate-baseline.md" root)))
              (normalise-repository root :policy :record-as-debt)
              (let ((written (file-write-date baseline))
                    (text (uiop:read-file-string baseline)))
                (let ((second (normalise-repository root :policy :record-as-debt)))
                  (is eq :already-present
                      (getf (report-debt-baseline second) :action-taken)
                      "the second run found it already present")
                  (is = written (file-write-date baseline)
                      "and did not rewrite it")
                  (is equal text (uiop:read-file-string baseline)
                      "its content is unchanged")))))))))

;;; ---------------------------------------------------------------------------
;;; CONTROL 7: an unavailable linter writes no baseline and says so
;;; ---------------------------------------------------------------------------

(define-test control-an-unavailable-linter-writes-no-baseline-and-says-so
  "CONTROL.

A baseline claiming zero sites would pass every other assertion in this file
while being a false record of a repository nobody scanned, and once written it
is indistinguishable from an honest empty one. So the scanner is made genuinely
unreachable, and the run must write nothing and name the reason."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (fixture-commit-file root "src/violating.lisp" +violating-source+)
        (with-no-linter (root)
          (false (gate-scanner-available-p (linter-path))
                 "precondition: the bound path holds no linter")
          (let ((report (normalise-repository root :policy :record-as-debt)))
            (is eq :not-enumerated
                (getf (report-debt-baseline report) :action-taken)
                "the run says the debt was not enumerated")
            (false (probe-file (merge-pathnames ".gate-baseline.md" root))
                   "and no document was written")
            (true (find-if (lambda (entry)
                             (search "not enumerated" (getf entry :reason)))
                           (report-unresolved report))
                  "an unresolved finding names the reason")))))))

;;; ---------------------------------------------------------------------------
;;; Reporting
;;; ---------------------------------------------------------------------------

(define-test a-repair-run-reports-what-it-wrote-and-what-was-already-right
  "Changed and already-correct are separate lists, and both are populated."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (let ((report (normalise-repository root :policy :repair)))
          (is eq :foreign (report-profile report))
          (true (report-classification report))
          (true (member :mallet-config (%changed-items report))
                "the linter configuration was written and reported")
          (true (member :lint-script (%changed-items report))
                "the lint script with it")
          (true (probe-file (merge-pathnames ".git/hooks/pre-commit" root))
                "and the hook, which lives where no worktree reaches")
          (true (member :asd-system (report-already-correct report))
                "the system definition was found already correct")
          (true (member :src-dir (report-already-correct report))))))))

(define-test a-dry-run-writes-nothing-and-still-names-what-would-change
  "The file set and the exclude are identical afterwards, and the report is not."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (let ((before (%snapshot root))
              (exclude-before (%exclude-patterns-in root)))
          (let ((report (normalise-repository root :policy :repair :dry-run t)))
            (true (report-changed report)
                  "the report names what would change")
            (true (every (lambda (entry)
                           (member (getf entry :action-taken)
                                   '(:would-create :would-update)))
                         (report-changed report))
                  "and every entry says it would rather than did")
            (is eq :would-update (getf (report-exclude report) :action-taken)))
          (is equal before (%snapshot root)
              "not one file under the root changed")
          (is equal exclude-before (%exclude-patterns-in root)
              "and the exclude is exactly as it was")
          (false (probe-file (merge-pathnames ".mallet.lisp" root))
                 "nothing was created"))))))

(define-test with-no-policy-nothing-is-written-and-every-finding-comes-back
  "An unattended run decides nothing.

Without a policy there is no outcome, because nobody chose one. The findings
come back with the decisions each of them admits, for the caller to pick from."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (let ((before (%snapshot root))
              (exclude-before (%exclude-patterns-in root))
              (report (normalise-repository root)))
          (is equal '() (report-changed report))
          (true (report-unresolved report)
                "every finding comes back")
          (true (every (lambda (entry) (getf entry :restarts))
                       (report-unresolved report))
                "each carrying the decisions it admits")
          (is equal before (%snapshot root)
              "and nothing was written")
          (is equal exclude-before (%exclude-patterns-in root)
              "not even the exclude"))))))

;;; ---------------------------------------------------------------------------
;;; A policy that does not apply
;;; ---------------------------------------------------------------------------

(define-test a-tracked-apparatus-file-is-unresolved-and-the-run-continues
  "Our apparatus already committed in somebody else's tree admits no repair, and
one such finding must not silence the rest.

Removing the file from their index is a change to their tracked tree, which is
the same act, in the other direction, as the leak the finding reports. So the
run reports it, says what could be decided about it instead, and carries on."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (fixture-commit-file root "CLAUDE.md" "# committed by somebody")
        (true (member "CLAUDE.md" (git-tracked-files root) :test #'string=)
              "precondition: it really is in their index")
        (let* ((report (normalise-repository root :policy :repair))
               (leak (find-if (lambda (entry)
                                (typep (getf entry :deviation)
                                       'foreign-apparatus-tracked))
                              (report-unresolved report))))
          (true leak "the leak is reported unresolved")
          (false (member :repair (getf leak :restarts))
                 "repair is not among the decisions it admits")
          (true (member :record-as-debt (getf leak :restarts))
                "and the decisions that are on offer are named")
          (true (report-changed report)
                "the remaining findings were still acted on"))
        (true (member "CLAUDE.md" (git-tracked-files root) :test #'string=)
              "the committed file is still tracked")
        (true (probe-file (merge-pathnames "CLAUDE.md" root))
              "and still present")))))

(define-test acceptance-writes-nothing-and-is-reported-separately
  "A finding judged correct as written is recorded and not acted on."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +third-party-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (let ((before (%snapshot root))
              (report (normalise-repository root :policy :accept-as-deliberate)))
          (true (report-accepted report)
                "the findings are recorded as accepted")
          (is equal '() (report-changed report)
              "and none of them is reported as a change")
          (is equal before (%snapshot root)
              "nothing under the root was written"))))))

;;; ---------------------------------------------------------------------------
;;; The upstream a fork-then-clone never recorded
;;; ---------------------------------------------------------------------------

(define-test a-supplied-upstream-is-added-and-reads-back
  "A repository whose origin is ours and which records no upstream cannot be
told apart from one of our own projects. Supplying the upstream is the repair,
and it is reported like any other."
  (with-fixture-template ()
    (with-gated-foreign-profile
      (with-temp-git-repo (root :origin-url +ours-origin-url+
                                :initial-file "README.md" :initial-content "x")
        (%foreign-fixture root)
        (false (git-remote-url root "upstream")
               "precondition: there is no upstream")
        (let ((report (normalise-repository
                       root :policy :repair
                            :upstream-url +third-party-upstream-url+)))
          (true (report-remote-added report)
                "the run reports the remote it added")
          (is eq :added (getf (report-remote-added report) :action-taken)))
        (is equal +third-party-upstream-url+ (git-remote-url root "upstream")
            "and git can read it back")))))

;;; ---------------------------------------------------------------------------
;;; The post-condition, asked directly
;;; ---------------------------------------------------------------------------

(define-test the-post-condition-fires-on-apparatus-that-entered-the-index
  "VERIFY-NO-TRACKED-APPARATUS answers quietly for a clean repository and
signals for one whose index gained a path of ours.

Both halves in one test. A post-condition that has only ever been asked about
clean repositories is a line of code, not a check."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%clear-ambient-ignores root)
      (is equal '() (verify-no-tracked-apparatus
                     root :foreign dsmr-mcp/src/project-shape:*shape-catalog*)
          "a repository tracking none of our apparatus is quiet")
      (fixture-commit-file root "CLAUDE.md" "# leaked")
      (fail (verify-no-tracked-apparatus
             root :foreign dsmr-mcp/src/project-shape:*shape-catalog*)
            'foreign-apparatus-tracked
            "a path of ours in the index signals")
      (is equal '() (verify-no-tracked-apparatus
                     root :foreign dsmr-mcp/src/project-shape:*shape-catalog*
                     :already-tracked '("CLAUDE.md"))
          "unless it was already there when the run started, which is theirs to
report and not ours to have caused"))))
