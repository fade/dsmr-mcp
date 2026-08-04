;;;; tests/scaffold/project-scaffold-shape-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Two claims are under test here, and both are the kind that pass for the
;;;; wrong reason if the instrument is not aimed carefully.
;;;;
;;;; The first is that the scaffold's file list exists in one place. Comparing
;;;; the manifest against the catalog does not establish that: two unrelated
;;;; constants satisfy an equality check exactly as readily as two related ones.
;;;; So the control here removes an entry from the catalog and asserts the
;;;; manifest gets shorter. A manifest still carrying its own list cannot pass
;;;; that.
;;;;
;;;; The second is that scaffolding into an existing checkout leaves it alone.
;;;; That is a claim about something NOT happening, which is the kind that
;;;; passes when the instrument is pointed at nothing at all, so the enclosing
;;;; repository is a real one with real history, its head is read before and
;;;; after, and a commit is then made inside the same test to prove the reading
;;;; can move.

;; Package evolution guard - delete prior definition on warm reload.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((pkg (find-package '#:dsmr-mcp/tests/scaffold/project-scaffold-shape-test)))
    (when pkg
      (sb-ext:without-package-locks (delete-package pkg)))))

(defpackage #:dsmr-mcp/tests/scaffold/project-scaffold-shape-test
  (:use #:cl #:parachute)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item-path
                #:shape-item-emit-on-scaffold-p
                #:shape-item-install-target)
  (:import-from #:dsmr-mcp/src/project-shape-catalog
                #:*shape-catalog*
                #:catalog-item)
  (:import-from #:dsmr-mcp/src/project-scaffold-core
                #:render-template
                #:plan-scaffold)
  (:import-from #:dsmr-mcp/src/project-scaffold
                #:write-scaffold)
  (:import-from #:dsmr-mcp/src/git
                #:git-toplevel
                #:git-head-sha
                #:git-status-porcelain)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:fixture-commit-file))

(in-package #:dsmr-mcp/tests/scaffold/project-scaffold-shape-test)

;;; --- helpers ----------------------------------------------------------------

(defvar *sample-name* "shape-parity-proj"
  "The project name both sides of the derivation check are rendered with.")

(defun sample-manifest (&rest args)
  "Return a planned manifest for the sample project."
  (apply #'plan-scaffold
         :name *sample-name*
         :description "a sample project"
         :author "Tester"
         :license "MIT"
         :copyright "Tester"
         :year "2026"
         :destination "scaffolds"
         args))

(defun manifest-paths ()
  "Return the relative paths the scaffold writes, in the order it writes them."
  (mapcar #'car (sample-manifest)))

(defun catalog-emitted-paths (&optional (catalog *shape-catalog*))
  "Return the paths CATALOG says the scaffold writes, in order.

Reads its argument on every call, so binding *SHAPE-CATALOG* changes the answer.
A version closing over a fixed list would satisfy the parity assertion no matter
what the catalog held."
  (let ((bindings (list (cons "name" *sample-name*))))
    (mapcar (lambda (item) (render-template (shape-item-path item) bindings))
            (remove-if-not (lambda (item)
                             (and (shape-item-emit-on-scaffold-p item)
                                  (eq :worktree (shape-item-install-target item))))
                           catalog))))

(defun project-directory (outcome)
  "Return the directory WRITE-SCAFFOLD reports it created."
  (getf outcome :target-dir))

(defun dot-git-present-p (project-dir)
  "Return T when PROJECT-DIR holds a git directory of its own."
  (and (probe-file (merge-pathnames ".git/" project-dir)) t))

(defun scaffold-into (root &rest args)
  "Write the sample project under ROOT and return the result plist."
  (apply #'write-scaffold
         :session-root root
         :name *sample-name*
         :description "a sample project"
         :author "Tester"
         :license "MIT"
         :copyright "Tester"
         :year "2026"
         :destination "scaffolds"
         args))

;;; --- the manifest is read from the catalog -----------------------------------

(define-test manifest-paths-are-the-catalogs-emitted-paths
  "The scaffold writes exactly what the catalog says it writes, in that order."
  (is equal (catalog-emitted-paths) (manifest-paths)))

(define-test control-a-shortened-catalog-shortens-the-manifest
  "CONTROL for the claim that the file list lives in one place only.

Binds the catalog to itself minus one emitting entry. A scaffold still holding
its own copy of the list answers with all twelve paths and fails here, which is
what makes the parity test above evidence rather than a coincidence between two
constants."
  (let* ((dropped (catalog-item :readme))
         (full-count (length (manifest-paths))))
    (true dropped "the catalog has no readme entry to drop")
    (let ((*shape-catalog* (remove dropped *shape-catalog*)))
      (let ((shortened (manifest-paths)))
        (is = (1- full-count) (length shortened)
            "dropping one catalog entry did not shorten the manifest")
        (false (find "README.md" shortened :test #'string=)
               "the dropped path is still in the manifest")))))

(define-test items-outside-the-worktree-are-not-in-the-manifest
  "Nothing installed under the repository's git directory reaches a manifest."
  (let ((hook (catalog-item :pre-commit)))
    (true hook "the catalog has no pre-commit entry")
    (is eq :git-dir (shape-item-install-target hook))
    (false (find (shape-item-path hook) (manifest-paths) :test #'string=)
           "a git-directory item was written into the worktree manifest")))

;;; --- the scaffold initialises git --------------------------------------------

(define-test scaffolding-outside-a-repository-creates-one
  "A project written where no repository exists becomes one."
  (with-temp-project-root (session root)
    (let* ((outcome (scaffold-into root))
           (project (project-directory outcome)))
      (true (getf outcome :git-initialised)
            "write-scaffold did not report initialising a repository")
      (true (dot-git-present-p project)
            "no git directory was created in the new project")
      (is equal (truename project) (truename (git-toplevel project))
          "the new project is not the root of its own repository"))))

(define-test init-git-nil-creates-no-repository
  "Asked not to, the scaffold writes the tree and creates no repository."
  (with-temp-project-root (session root)
    (let* ((outcome (scaffold-into root :init-git nil))
           (project (project-directory outcome)))
      (false (getf outcome :git-initialised)
             "write-scaffold reported initialising a repository it was told to skip")
      (false (dot-git-present-p project)
             "a git directory was created despite init-git being false")
      (true (probe-file (merge-pathnames "README.md" project))
            "the project tree was not written"))))

(define-test control-no-repository-is-nested-inside-an-existing-one
  "CONTROL for the nesting guard, observed two independent ways.

Scaffolding inside a checkout must not create a repository under it. The
report saying so is the thing that would otherwise be taken on trust, so the
git directory's absence is also asserted directly: a report wired to answer NIL
would satisfy the first assertion and not the second."
  (with-temp-git-repo (root :initial-file "README" :initial-content "enclosing")
    (let* ((outcome (scaffold-into root))
           (project (project-directory outcome)))
      (false (getf outcome :git-initialised)
             "write-scaffold reported initialising a nested repository")
      (false (dot-git-present-p project)
             "a nested git directory was created inside an existing checkout")
      (is equal (truename root) (truename (git-toplevel project))
          "the new project does not belong to the enclosing repository"))))

(define-test control-the-enclosing-repository-is-left-unmoved
  "CONTROL for non-destructiveness, with the instrument proven able to move.

The enclosing repository's head is read before and after the scaffold and must
be the same commit, and its working tree must report nothing but the new
untracked directory. An equality assertion on a value that never changes is not
evidence of anything, so a commit is then made in the same fixture and the head
is asserted to have moved."
  (with-temp-git-repo (root :initial-file "README" :initial-content "enclosing")
    (let ((before (git-head-sha root)))
      (true before "the fixture repository has no commit to compare against")
      (scaffold-into root)
      (is equal before (git-head-sha root)
          "scaffolding moved the enclosing repository's head")
      (is equal (list "?? scaffolds/") (git-status-porcelain root)
          "scaffolding changed something in the enclosing repository besides adding the new directory")
      ;; The instrument, exercised: a real commit must change what it reads.
      (fixture-commit-file root "README" "enclosing, amended"
                           :message "prove the head reading moves")
      (false (equal before (git-head-sha root))
             "the head reading did not move across a real commit, so the assertion above proves nothing"))))
