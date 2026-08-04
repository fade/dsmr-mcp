;;;; tests/doctor/project-assess-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Parachute tests for read-only repository assessment, over real git
;;;; repositories.
;;;;
;;;; The claim this file exists to defend is a negative one, and it is the
;;;; expensive kind to get wrong. Assessment is supposed to say nothing about a
;;;; working third-party library, and a check that says nothing is satisfied
;;;; just as readily by a check aimed at nothing at all. So the emptiness
;;;; assertion is never made alone: the same test removes one file from the same
;;;; fixture and requires a finding to appear. An emptiness that has never been
;;;; observed non-empty is not evidence.
;;;;
;;;; The safety property is that our apparatus must never be TRACKED in somebody
;;;; else's repository, which is a different question from whether it is present
;;;; there. Present is correct and expected; tracked is the leak. Two fixtures
;;;; differ by exactly that one fact and must give different answers, because an
;;;; assessment that cannot tell them apart makes every never-leak claim in this
;;;; subsystem unfounded while looking perfectly healthy.
;;;;
;;;; The same file gets opposite answers under the two profiles, and that pair is
;;;; asserted inside a single test so the two halves cannot drift apart. Split
;;;; across two tests, deleting one leaves a suite that still passes and a
;;;; two-mode rule that has become one mode.
;;;;
;;;; Every fixture writes the pattern set it is measured against, rather than
;;;; reading the developer's own configuration, so the suite gives the same
;;;; answer on a build host that has no template at all.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/doctor/project-assess-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/doctor/project-assess-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-assess
                #:assess-repository
                #:item-satisfied-p
                #:assessment-root
                #:assessment-classification
                #:assessment-profile
                #:assessment-deviations
                #:assessment-satisfied)
  (:import-from #:dsmr-mcp/src/project-deviation
                #:deviation-item
                #:deviation-detail
                #:missing-shape-item
                #:drifted-shape-item
                #:foreign-apparatus-tracked)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item-key)
  (:import-from #:dsmr-mcp/src/project-shape-catalog
                #:catalog-item)
  (:import-from #:dsmr-mcp/src/project-exclude
                #:*exclude-template-path*)
  (:import-from #:dsmr-mcp/src/git
                #:run-git
                #:git-tracked-files
                #:git-status-porcelain)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:fixture-commit-file
                #:seed-exclude-patterns
                #:+ours-origin-url+
                #:+third-party-origin-url+)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:write-fixture-file
                #:%make-temp-directory))

(in-package #:dsmr-mcp/tests/doctor/project-assess-test)

;;; ---------------------------------------------------------------------------
;;; The pattern set every fixture is measured against
;;; ---------------------------------------------------------------------------

(defvar +fixture-template-patterns+
  '(".claude/" "AGENTS.md" "CLAUDE.md" ".mallet.lisp")
  "The exclude patterns of record for the extent of this file.

Written to a file each test creates. A suite reading the real template would
measure something different on every machine and nothing at all on a host that
has none.")

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

;;; ---------------------------------------------------------------------------
;;; Fixture shapes
;;; ---------------------------------------------------------------------------

(defun %seed-library (root)
  "Give ROOT the shape of a typical working third-party Lisp library.

A system definition, a source directory and a test directory: everything the
invariant tier asks for, and none of our own conventions. This is the shape that
must assess clean, because roughly ninety repositories on this machine have it."
  (write-fixture-file root "example.asd" "(asdf:defsystem \"example\")")
  (write-fixture-file root "src/main.lisp" ";; source")
  (write-fixture-file root "tests/main-test.lisp" ";; tests")
  root)

(defun %seed-quality-gate (root)
  "Install every part of the quality gate under ROOT, plus its frozen baseline."
  (write-fixture-file root ".mallet.lisp" ";; linter configuration")
  (write-fixture-file root "scripts/lint-lisp.sh" "#!/usr/bin/env bash")
  (write-fixture-file root ".git/hooks/pre-commit" "#!/usr/bin/env bash")
  (write-fixture-file root ".gate-baseline.md" "# baseline")
  root)

(defun %clear-ambient-ignores (root)
  "Make every path in ROOT stageable regardless of how the host ignores things.

A repository created on this machine inherits a seeded local exclude and a global
ignore file, and both cover our apparatus paths by design. A fixture that has to
place such a path in the index would otherwise succeed or fail depending on whose
machine the suite ran on, and the property under test has nothing to do with
either file. Both sources are emptied for this repository alone."
  (seed-exclude-patterns root '())
  (let ((empty (write-fixture-file root ".git/no-ignores" "")))
    (run-git (list "config" "core.excludesFile" (namestring empty))
             :directory root))
  root)

(defun %seed-clean-exclude (root)
  "Seed ROOT's local exclude with the whole pattern set of record."
  (seed-exclude-patterns root +fixture-template-patterns+))

;;; ---------------------------------------------------------------------------
;;; Reading an assessment
;;; ---------------------------------------------------------------------------

(defun %of-type (assessment type)
  "Return the deviations in ASSESSMENT that are of TYPE."
  (remove-if-not (lambda (deviation) (typep deviation type))
                 (assessment-deviations assessment)))

(defun %keys (deviations)
  "Return the item key each deviation names, with NIL for one naming no item."
  (mapcar (lambda (deviation)
            (let ((item (deviation-item deviation)))
              (and item (shape-item-key item))))
          deviations))

(defun %mentions-p (deviation text)
  "Return true when DEVIATION's detail contains TEXT."
  (let ((detail (deviation-detail deviation)))
    (and detail (search text detail) t)))

;;; ---------------------------------------------------------------------------
;;; One item at a time
;;; ---------------------------------------------------------------------------

(define-test item-satisfaction-follows-the-assertion-kind
  "Each assertion kind asks its own question of the tree."
  (with-temp-git-repo (root :origin-url +third-party-origin-url+
                            :initial-file "README.md" :initial-content "x")
    (%seed-library root)
    (true (item-satisfied-p (catalog-item :asd-system) root))
    (true (item-satisfied-p (catalog-item :src-dir) root))
    (true (item-satisfied-p (catalog-item :tests-dir) root))
    (false (item-satisfied-p (catalog-item :build-script) root))
    (false (item-satisfied-p (catalog-item :mallet-config) root))))

(define-test a-git-directory-item-is-looked-for-under-the-git-directory
  "CONTROL: the hook is resolved under .git/, and a same-named file in the
working tree does not satisfy it.

Resolving a git-directory item against the worktree would report the hook as
absent in every repository that has one, and would report an unrelated file that
happens to share the name as the hook."
  (with-temp-git-repo (root :origin-url +third-party-origin-url+
                            :initial-file "README.md" :initial-content "x")
    (let ((item (catalog-item :pre-commit)))
      ;; The host's configured template directory may seed a hook into every new
      ;; repository, so the baseline is established here rather than assumed.
      (uiop:delete-file-if-exists (merge-pathnames ".git/hooks/pre-commit" root))
      (false (item-satisfied-p item root))
      ;; A decoy at the same relative path in the working tree.
      (write-fixture-file root "hooks/pre-commit" "#!/usr/bin/env bash")
      (false (item-satisfied-p item root))
      (write-fixture-file root ".git/hooks/pre-commit" "#!/usr/bin/env bash")
      (true (item-satisfied-p item root)))))

;;; ---------------------------------------------------------------------------
;;; A clean answer, and the evidence that a look happened
;;; ---------------------------------------------------------------------------

(define-test a-satisfied-repository-reports-nothing-and-says-what-it-checked
  "An empty deviation list arrives with the classification, the profile and the
items found already correct, so it is distinguishable from an assessment that
never ran."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      (%seed-clean-exclude root)
      (let ((assessment (assess-repository root)))
        (is equal '() (assessment-deviations assessment))
        (is eq :foreign-with-upstream (assessment-classification assessment))
        (is eq :foreign (assessment-profile assessment))
        (true (assessment-root assessment))
        (true (member :asd-system (assessment-satisfied assessment)))
        (true (member :src-dir (assessment-satisfied assessment)))
        (true (member :tests-dir (assessment-satisfied assessment)))))))

(define-test an-absent-invariant-is-reported
  "A repository with no source directory is missing something every repository
of this kind has."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      (%seed-clean-exclude root)
      (uiop:delete-directory-tree (merge-pathnames "src/" root)
                                  :validate t :if-does-not-exist :ignore)
      (let* ((assessment (assess-repository root))
             (missing (%of-type assessment 'missing-shape-item)))
        (is = 1 (length missing))
        (is equal '(:src-dir) (%keys missing))))))

(define-test a-foreign-repository-is-not-held-to-our-conveniences
  "A third-party library without a build script is not sick, and reporting it as
such is the false entry that hides the true ones."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      (%seed-clean-exclude root)
      ;; The convenience really is absent, so the assertion below is aimed at
      ;; something rather than at a file that happens to be there.
      (false (item-satisfied-p (catalog-item :build-script) root))
      (false (item-satisfied-p (catalog-item :dev-boot) root))
      (let ((assessment (assess-repository root)))
        (false (member :build-script (%keys (assessment-deviations assessment))))
        (false (member :dev-boot (%keys (assessment-deviations assessment))))
        (false (member :readme (%keys (assessment-deviations assessment))))))))

;;; ---------------------------------------------------------------------------
;;; CONTROL: the false-positive flood
;;; ---------------------------------------------------------------------------

(define-test control-a-working-third-party-library-produces-no-findings
  "CONTROL: the most consequential test here. A typical third-party library
assesses clean, and the same fixture with one invariant removed does not.

The clean half alone would pass against an assessment that examined nothing, so
the dirty half runs against the same repository, one file apart. Without the
pair, an implementation that silently returned no findings at all would look
identical to a correct one."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      (%seed-clean-exclude root)
      (is equal '() (assessment-deviations (assess-repository root)))
      ;; One file apart, and the answer must change.
      (uiop:delete-directory-tree (merge-pathnames "src/" root)
                                  :validate t :if-does-not-exist :ignore)
      (let ((deviations (assessment-deviations (assess-repository root))))
        (is = 1 (length deviations))
        (is equal '(:src-dir) (%keys deviations))))))

;;; ---------------------------------------------------------------------------
;;; CONTROL: tracked is not the same as present
;;; ---------------------------------------------------------------------------

(define-test control-apparatus-tracked-is-a-finding-and-apparatus-present-is-not
  "CONTROL: two foreign repositories differing only in whether the apparatus file
was placed in the index.

Present is the correct state for an adopted repository; tracked is the leak. If
assessment cannot tell those two apart, every never-leak claim in this subsystem
is unfounded, and the suite would look exactly as healthy as it does now."
  (with-fixture-template ()
    ;; Tracked.
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      ;; The leak happens first and the exclude arrives afterwards, which is the
      ;; order a repository adopted after the fact actually reaches us in.
      (%clear-ambient-ignores root)
      (fixture-commit-file root "CLAUDE.md" "# apparatus")
      (%seed-clean-exclude root)
      (true (member "CLAUDE.md" (git-tracked-files root) :test #'string=))
      (let ((leaks (%of-type (assess-repository root) 'foreign-apparatus-tracked)))
        (is = 1 (length leaks))
        (is equal '(:claude-doc) (%keys leaks))))
    ;; Present and untracked, everything else identical.
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      (%seed-clean-exclude root)
      (write-fixture-file root "CLAUDE.md" "# apparatus")
      (false (member "CLAUDE.md" (git-tracked-files root) :test #'string=))
      (is equal '()
          (%of-type (assess-repository root) 'foreign-apparatus-tracked)))))

;;; ---------------------------------------------------------------------------
;;; CONTROL: the same file, two profiles, opposite answers
;;; ---------------------------------------------------------------------------

(define-test control-the-same-tracked-file-is-contraband-only-in-a-foreign-tree
  "CONTROL: one repository, one tracked linter configuration, assessed both ways.

Under our own profile it is ordinary project content and reporting it would be a
false finding about a repository behaving correctly. Under a foreign profile the
identical file is our tooling in somebody else's index. Both halves are asserted
here rather than in two tests, so deleting one cannot leave a green suite whose
two-mode rule has quietly become one mode."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      ;; Placed in the index before the exclude arrives, since git will not add
      ;; a path an ignore file already covers.
      (%clear-ambient-ignores root)
      (fixture-commit-file root ".mallet.lisp" ";; linter configuration")
      (%seed-clean-exclude root)
      (true (member ".mallet.lisp" (git-tracked-files root) :test #'string=))
      (let ((foreign (assess-repository
                      root :declared-classification :foreign-with-upstream))
            (ours (assess-repository root :declared-classification :ours)))
        (is = 1 (length (%of-type foreign 'foreign-apparatus-tracked)))
        (is equal '(:mallet-config)
            (%keys (%of-type foreign 'foreign-apparatus-tracked)))
        (is equal '() (%of-type ours 'foreign-apparatus-tracked))))))

;;; ---------------------------------------------------------------------------
;;; CONTROL: a gate is one thing
;;; ---------------------------------------------------------------------------

(define-test control-a-half-installed-quality-gate-is-exactly-one-finding
  "CONTROL: the linter configuration present and its script absent yields ONE
deviation naming the gate, asserted on the count rather than on non-emptiness.

The gate's parts never occur apart in the measured population, so a partial
install is one fact about one gate. Counting it as several would inflate every
report by two entries that say nothing the first does not."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +ours-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      (%seed-quality-gate root)
      (%seed-clean-exclude root)
      ;; Remove two of the gate's three parts, leaving the configuration.
      (uiop:delete-file-if-exists (merge-pathnames "scripts/lint-lisp.sh" root))
      (uiop:delete-file-if-exists (merge-pathnames ".git/hooks/pre-commit" root))
      (let* ((assessment (assess-repository root :declared-classification :ours))
             (deviations (assessment-deviations assessment)))
        (is = 1 (length deviations))
        (is equal '(:mallet-config) (%keys deviations))
        (true (%mentions-p (first deviations) "scripts/lint-lisp.sh"))
        (true (%mentions-p (first deviations) "hooks/pre-commit"))
        (true (member :gate-baseline (assessment-satisfied assessment)))))))

;;; ---------------------------------------------------------------------------
;;; Exclude drift
;;; ---------------------------------------------------------------------------

(define-test exclude-drift-is-one-finding-listing-what-is-missing
  "A local exclude that has fallen behind the pattern set of record is one
drifted item whose detail names the patterns it lacks.

Paired with a fixture one pattern apart that must come back clean, so the dirty
answer is not something this check gives to every repository."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      (seed-exclude-patterns root (butlast +fixture-template-patterns+))
      (let ((drift (%of-type (assess-repository root) 'drifted-shape-item)))
        (is = 1 (length drift))
        (true (%mentions-p (first drift) (car (last +fixture-template-patterns+))))))
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      (%seed-clean-exclude root)
      (is equal '() (%of-type (assess-repository root) 'drifted-shape-item)))))

;;; ---------------------------------------------------------------------------
;;; The repository is not touched
;;; ---------------------------------------------------------------------------

(define-test assessment-leaves-the-repository-exactly-as-it-found-it
  "Nothing about the tree, the index or the local exclude changes across an
assessment, including one that has findings to report."
  (with-fixture-template ()
    (with-temp-git-repo (root :origin-url +third-party-origin-url+
                              :initial-file "README.md" :initial-content "x")
      (%seed-library root)
      (seed-exclude-patterns root (butlast +fixture-template-patterns+))
      (let* ((exclude (merge-pathnames ".git/info/exclude" root))
             (tracked-before (git-tracked-files root))
             (status-before (git-status-porcelain root))
             (exclude-before (uiop:read-file-string exclude))
             (assessment (assess-repository root)))
        ;; There is something to report, so the run is not trivially inert.
        (true (plusp (length (assessment-deviations assessment))))
        (is equal tracked-before (git-tracked-files root))
        (is equal status-before (git-status-porcelain root))
        (is equal exclude-before (uiop:read-file-string exclude))))))
