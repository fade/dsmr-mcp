;;;; tests/scaffold/project-scaffold-shape-test.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Two claims are under test here, and both are the kind that pass for the
;;;; wrong reason if the instrument is not aimed carefully.
;;;;
;;;; The first is that the scaffold's file list exists in one place. Comparing
;;;; the manifest against the catalogue does not establish that: two unrelated
;;;; constants satisfy an equality check exactly as readily as two related ones.
;;;; So the control here removes an entry from the catalogue and asserts the
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
  (:use #:cl #:zebra)
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
  (:import-from #:dsmr-mcp/src/repo-classify
                #:project-disposition-required)
  (:import-from #:dsmr-mcp/src/project-debt
                #:render-pre-commit-hook)
  (:import-from #:dsmr-mcp/src/project-gate-scan
                #:linter-path
                #:gate-scanner-available-p)
  (:import-from #:dsmr-mcp/src/project-hook
                #:gate-hook-path
                #:gate-hook-wired-p
                #:configured-hooks-supported-p)
  (:import-from #:dsmr-mcp/src/git
                #:run-git
                #:git-toplevel
                #:git-head-sha
                #:git-status-porcelain)
  (:import-from #:dsmr-mcp/tests/support/fs-fixture
                #:with-temp-project-root)
  (:import-from #:dsmr-mcp/tests/support/git-fixture
                #:with-temp-git-repo
                #:with-git-lacking-configured-hooks
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
what the catalogue held."
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

;;; --- the manifest is read from the catalogue ---------------------------------

(define-test manifest-paths-are-the-catalogs-emitted-paths
  "The scaffold writes exactly what the catalogue says it writes, in that order."
  (is equal (catalog-emitted-paths) (manifest-paths)))

(define-test control-a-shortened-catalog-shortens-the-manifest
  "CONTROL for the claim that the file list lives in one place only.

Binds the catalogue to itself minus one emitting entry. A scaffold still holding
its own copy of the list answers with every path and fails here, which is
what makes the parity test above evidence rather than a coincidence between two
constants."
  (let* ((dropped (catalog-item :readme))
         (full-count (length (manifest-paths))))
    (true dropped "the catalogue has no readme entry to drop")
    (let ((*shape-catalog* (remove dropped *shape-catalog*)))
      (let ((shortened (manifest-paths)))
        (is = (1- full-count) (length shortened)
            "dropping one catalogue entry did not shorten the manifest")
        (false (find "README.md" shortened :test #'string=)
               "the dropped path is still in the manifest")))))

(define-test items-outside-the-worktree-are-not-in-the-manifest
  "Nothing installed under the repository's git directory reaches a manifest."
  (let ((hook (catalog-item :pre-commit)))
    (true hook "the catalogue has no pre-commit entry")
    (is eq :git-dir (shape-item-install-target hook))
    (false (find (shape-item-path hook) (manifest-paths) :test #'string=)
           "a git-directory item was written into the worktree manifest")))

;;; --- the scaffold initializes git --------------------------------------------

(define-test scaffolding-outside-a-repository-creates-one
  "A project written where no repository exists becomes one."
  (with-temp-project-root (session root)
    (let* ((outcome (scaffold-into root))
           (project (project-directory outcome)))
      (true (getf outcome :git-initialised)
            "write-scaffold did not report initializing a repository")
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
             "write-scaffold reported initializing a repository it was told to skip")
      (false (dot-git-present-p project)
             "a git directory was created despite init-git being false")
      (true (probe-file (merge-pathnames "README.md" project))
            "the project tree was not written")
      (let ((gate (getf outcome :gate-hook)))
        (is eq :not-installed (getf gate :action-taken)
            "a gate was reported installed in a project with no repository")
        (true (stringp (getf gate :reason))
              "the result does not say why no gate was installed")))))

(define-test control-no-repository-is-nested-inside-an-existing-one
  "CONTROL for the nesting guard, observed two independent ways.

Scaffolding inside a checkout must not create a repository under it. The
report saying so is the thing that would otherwise be taken on trust, so the
git directory's absence is also asserted directly: a report wired to answer NIL
would satisfy the first assertion and not the second."
  (with-temp-git-repo (root :initial-file "README" :initial-content "enclosing")
    (let* ((outcome (scaffold-into root :disposition :contributing))
           (project (project-directory outcome)))
      (false (getf outcome :git-initialised)
             "write-scaffold reported initializing a nested repository")
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
      (scaffold-into root :disposition :contributing)
      (is equal before (git-head-sha root)
          "scaffolding moved the enclosing repository's head")
      (is equal (list "?? scaffolds/") (git-status-porcelain root)
          "scaffolding changed something in the enclosing repository besides adding the new directory")
      ;; The instrument, exercised: a real commit must change what it reads.
      (fixture-commit-file root "README" "enclosing, amended"
                           :message "prove the head reading moves")
      (false (equal before (git-head-sha root))
             "the head reading did not move across a real commit, so the assertion above proves nothing"))))

(defun %file-text (path)
  "Return the text of PATH, or NIL when it does not exist."
  (when (probe-file path) (uiop:read-file-string path)))

(define-test scaffolding-into-an-existing-repository-asks-first
  "With no disposition recorded and none supplied, a scaffold into an existing
repository signals PROJECT-DISPOSITION-REQUIRED and writes nothing: no project
directory, no .envrc, and the local exclude as it was. The same holds with
init-git NIL."
  (dolist (init-git '(t nil))
    (with-temp-git-repo (root :initial-file "README" :initial-content "enclosing")
      (let* ((exclude (merge-pathnames ".git/info/exclude" root))
             (before (%file-text exclude))
             (outcome (handler-case (scaffold-into root :init-git init-git)
                        (project-disposition-required () :asked))))
        (is eq :asked outcome "init-git ~A: the scaffold asks: ~S" init-git outcome)
        (false (probe-file (merge-pathnames
                            (format nil "scaffolds/~A/" *sample-name*) root))
               "init-git ~A: no project directory was written" init-git)
        (false (probe-file (merge-pathnames ".envrc" root))
               "init-git ~A: no .envrc was written" init-git)
        (is equal before (%file-text exclude)
            "init-git ~A: the local exclude is unchanged" init-git)))))

(define-test an-answer-is-recorded-in-the-existing-repository-then-scaffolded
  "Answered, the scaffold records the disposition in the enclosing repository's
.envrc, lists .envrc in its local exclude, writes the project, and reports the
record. A second scaffold into the same repository asks nothing and reports
the declaration already present."
  (with-temp-git-repo (root :initial-file "README" :initial-content "enclosing")
    (let* ((outcome (scaffold-into root :disposition :forked :init-git nil))
           (recorded (getf outcome :disposition))
           (envrc (%file-text (merge-pathnames ".envrc" root))))
      (is eq :forked (getf recorded :disposition) "~S" recorded)
      (is eq :created (getf recorded :action-taken) "~S" recorded)
      (true (and envrc (search "export DSMR_PROJECT_DISPOSITION=forked" envrc))
            "the enclosing .envrc declares forked: ~S" envrc)
      (true (search (format nil "~%.envrc~%")
                    (format nil "~%~A" (%file-text (merge-pathnames ".git/info/exclude"
                                                                     root))))
            "the local exclude lists .envrc")
      (true (probe-file (merge-pathnames "README.md" (project-directory outcome)))
            "the project was written")
      (is equal (list "?? scaffolds/") (git-status-porcelain root)
          "only the new project shows in git status"))
    (let* ((*sample-name* "shape-parity-second")
           (again (getf (scaffold-into root :init-git nil) :disposition)))
      (is eq :forked (getf again :disposition) "~S" again)
      (is eq :already-present (getf again :action-taken) "~S" again))))

(define-test a-repository-the-scaffold-creates-takes-no-other-disposition
  "A repository the scaffold creates is ours. Supplying another disposition is
refused before anything is written; supplying ours is accepted and recorded."
  (with-temp-project-root (session root)
    (true (handler-case (progn (scaffold-into root :disposition :contributing) nil)
            (dsmr-mcp/src/project-scaffold-core:invalid-argument-error () t))
          "contributing is refused for a repository the scaffold creates")
    (false (probe-file (merge-pathnames (format nil "scaffolds/~A/" *sample-name*)
                                        root))
           "nothing was written")
    (let ((recorded (getf (scaffold-into root :disposition :ours) :disposition)))
      (is eq :ours (getf recorded :disposition) "~S" recorded))))

(defun %licence-text-in (project)
  "Return the relative paths of the files under PROJECT that carry licence text:
a LICENSE file, an SPDX identifier, a :license line, or a License heading."
  (let ((found '()))
    (dolist (file (directory (merge-pathnames "**/*.*" project))
                  (sort found #'string<))
      (when (uiop:file-pathname-p file)
        (let ((text (uiop:read-file-string file))
              (relative (enough-namestring file project)))
          (when (or (string= "LICENSE" (file-namestring file))
                    (search "SPDX-License-Identifier" text)
                    (search ":license" text)
                    (search "## License" text))
            (push relative found)))))))

(define-test a-contributing-repository-gets-no-licence-and-no-tracked-apparatus
  "Inside a repository declared contributing, the scaffold writes no licence
text at all, and every apparatus file it writes is excluded rather than left
for the next commit: git status lists the project's own sources and none of
CLAUDE.md, AGENTS.md, .mallet.lisp, scripts/lint-lisp.sh or .envrc. The result
says no licence was written. A project the scaffold creates is the control: it
carries the licence it was given."
  (with-temp-git-repo (root :initial-file "README" :initial-content "enclosing")
    (let* ((outcome (scaffold-into root :disposition :contributing))
           (project (project-directory outcome))
           (status (values (run-git (list "status" "--porcelain"
                                          "--untracked-files=all")
                                    :directory root))))
      (is equal '() (%licence-text-in project) "no file carries licence text")
      (true (search "src/main.lisp" status)
            "control: the project's own source shows in git status: ~A" status)
      (dolist (path '("CLAUDE.md" "AGENTS.md" ".mallet.lisp"
                      "scripts/lint-lisp.sh" ".envrc"))
        (true (probe-file (merge-pathnames path project)) "~A was written" path)
        (false (search (format nil "/~A~%" path) status)
               "~A is not listed by git status: ~A" path status))
      (is eq :omitted (getf (getf outcome :licence) :action-taken)
          "the result says no licence was written: ~S" (getf outcome :licence))))
  (with-temp-project-root (session root)
    (let ((project (project-directory (scaffold-into root))))
      (true (member "LICENSE" (%licence-text-in project) :test #'string=)
            "control: a project the scaffold creates has its LICENSE")
      (true (member "src/main.lisp" (%licence-text-in project) :test #'string=)
            "control: and SPDX headers"))))

(define-test a-forked-repository-gets-no-licence
  "Inside a repository declared forked, the scaffold writes no licence text: a
fork keeps the licence it came with."
  (with-temp-git-repo (root :initial-file "README" :initial-content "enclosing")
    (let* ((outcome (scaffold-into root :disposition :forked))
           (project (project-directory outcome)))
      (is equal '() (%licence-text-in project) "no file carries licence text")
      (true (probe-file (merge-pathnames "src/main.lisp" project))
            "control: the project was written"))))

(define-test a-failure-after-the-record-reports-the-record
  "When the project cannot be written after the disposition was recorded in the
enclosing repository, the failure names the .envrc it wrote, so the caller
learns the repository changed. The project directory is not left behind."
  (with-temp-git-repo (root :initial-file "README" :initial-content "enclosing")
    (let ((destination (merge-pathnames "scaffolds/" root)))
      (ensure-directories-exist destination)
      (uiop:run-program (list "chmod" "555" (namestring destination)))
      (unwind-protect
           (let ((condition (handler-case (progn (scaffold-into root :disposition :forked)
                                                 nil)
                              (error (c) c))))
             (true condition "the scaffold fails")
             (is string= "SCAFFOLD-FAILED-AFTER-WRITING"
                 (and condition (symbol-name (type-of condition)))
                 "the failure is the one that reports earlier writes: ~A" condition)
             (true (search (namestring (merge-pathnames ".envrc" (truename root)))
                           (princ-to-string condition))
                   "the failure names the .envrc it wrote: ~A" condition)
             (true (search "DSMR_PROJECT_DISPOSITION=forked"
                           (or (%file-text (merge-pathnames ".envrc" root)) ""))
                   "control: the record was written")
             (false (probe-file (merge-pathnames
                                 (format nil "~A/" *sample-name*) destination))
                    "no project directory was left"))
        (uiop:run-program (list "chmod" "755" (namestring destination)))))))

;;; --- the scaffold creates the project with its lint gate --------------------

(defun %project-file (project relative-path)
  "Return the absolute pathname of RELATIVE-PATH under PROJECT."
  (merge-pathnames relative-path (uiop:ensure-directory-pathname project)))

(defun %executable-p (path)
  "Return T when PATH names a file the current user may execute."
  (zerop (nth-value 2 (uiop:run-program (list "test" "-x" (namestring path))
                                        :ignore-error-status t))))

(defun %run-gate (project gate)
  "Run GATE from PROJECT with MALLET naming the linter.
Returns the combined output and the exit code. The gate is run directly rather
than through git hook run: git init on a host with an init template also seeds
that template's own pre-commit hook, and its verdict is not under test here."
  (multiple-value-bind (output error-output code)
      (uiop:run-program (list "/usr/bin/env"
                              (format nil "MALLET=~A" (namestring (linter-path)))
                              (namestring gate))
                        :directory (namestring project)
                        :output :string
                        :error-output :output
                        :ignore-error-status t)
    (declare (ignore error-output))
    (values output code)))

(defun %stage (project paths)
  "Stage PATHS, relative to PROJECT, in PROJECT's repository.
Forced: the host's exclude patterns hide some generated files, and the check is
over every file the scaffold generated."
  (run-git (list* "add" "-f" "--" paths) :directory project))

(defun %hooks-listing (root)
  "Return the sorted names of the entries in ROOT's hooks directory."
  (let ((hooks (merge-pathnames ".git/hooks/" (uiop:ensure-directory-pathname root))))
    (sort (mapcar #'namestring
                  (append (uiop:directory-files hooks)
                          (uiop:subdirectories hooks)))
          #'string<)))

(defun %local-config (root)
  "Return the output of git config --local --list at ROOT."
  (values (run-git (list "config" "--local" "--list") :directory root)))

(define-test the-gate-files-are-emitted-because-the-catalog-says-so
  "The linter config and the lint script are in the manifest by their catalogue flags."
  (dolist (key '(:mallet-config :lint-script :pre-commit))
    (true (shape-item-emit-on-scaffold-p (catalog-item key))
          "a gate item is not marked for emission in the catalogue"))
  (let ((paths (manifest-paths)))
    (true (find ".mallet.lisp" paths :test #'string=)
          "the linter config is not in the manifest")
    (true (find "scripts/lint-lisp.sh" paths :test #'string=)
          "the lint script is not in the manifest"))
  (let ((*shape-catalog* (remove (catalog-item :lint-script) *shape-catalog*)))
    (false (find "scripts/lint-lisp.sh" (manifest-paths) :test #'string=)
           "the lint script is listed somewhere other than the catalogue")))

(define-test the-gate-files-carry-the-chosen-licence-and-no-severity-pins
  "The lint script names the licence the caller chose; the linter config pins nothing."
  (with-temp-project-root (session root)
    (let* ((project (project-directory (scaffold-into root :init-git nil)))
           (script (%project-file project "scripts/lint-lisp.sh"))
           (config (%project-file project ".mallet.lisp"))
           (script-text (uiop:read-file-string script))
           (config-text (uiop:read-file-string config)))
      (true (%executable-p script) "the lint script is not executable")
      (true (search (format nil "~%# SPDX-License-Identifier: MIT~%") script-text)
            "the lint script does not carry the chosen licence identifier")
      (false (search "{{" script-text) "the lint script holds an unrendered placeholder")
      (false (search "{{" config-text) "the linter config holds an unrendered placeholder")
      (false (search ":set-severity" config-text)
             "a new project's linter config pins a severity")
      (let ((*read-eval* nil))
        (with-input-from-string (in config-text)
          (true (consp (read in nil nil)) "the linter config does not read as a form")
          (is eq :eof (read in nil :eof)
              "the linter config holds more than one form"))))))

(define-test a-new-repository-gets-the-blocking-gate-wired
  "A scaffold that creates the repository installs the blocking gate in its own hooks.
A git without configured hooks gets no gate, reported not installed."
  (with-temp-project-root (session root)
    (let* ((outcome (scaffold-into root))
           (project (project-directory outcome))
           (gate-report (getf outcome :gate-hook))
           (gate (gate-hook-path project)))
      (if (configured-hooks-supported-p project)
          (progn
            (is eq :created (getf gate-report :action-taken)
                "the result does not report the gate as created")
            (is equal (namestring gate) (namestring (getf gate-report :path))
                "the reported gate path is not the repository's gate path")
            (true (probe-file gate) "no gate file at the repository's gate path")
            (true (%executable-p gate) "the installed gate is not executable")
            (is string= (render-pre-commit-hook :profile :ours)
                (uiop:read-file-string gate)
                "the installed gate is not the blocking rendering")
            (is eq :created (getf (getf gate-report :wiring) :action-taken)
                "the wiring was not reported as created")
            (true (gate-hook-wired-p project) "the gate is not wired"))
          (progn
            (false (probe-file gate) "a gate file was written where git cannot run it")
            (is eq :not-installed (getf gate-report :action-taken)
                "the gate is not reported as not installed: ~S" gate-report)
            (true (and (getf gate-report :reason)
                       (search "configured hooks" (getf gate-report :reason)))
                  "the report gives no reason: ~S" gate-report))))))

(define-test a-git-without-configured-hooks-gets-no-gate-file
  "UNSUPPORTED-GIT CONTROL. Where git cannot run configured hooks, the scaffold
writes no gate script and reports the gate not installed, with the reason."
  (with-temp-project-root (session root)
    (with-git-lacking-configured-hooks ()
      (let* ((outcome (scaffold-into root))
             (project (project-directory outcome))
             (gate-report (getf outcome :gate-hook)))
        (true (getf outcome :git-initialised)
              "precondition: the scaffold created the repository")
        (false (probe-file (gate-hook-path project))
               "a gate file was written where git cannot run it")
        (is eq :not-installed (getf gate-report :action-taken)
            "the gate is not reported as not installed: ~S" gate-report)
        (true (and (getf gate-report :reason)
                   (search "configured hooks" (getf gate-report :reason)))
              "the report gives no reason: ~S" gate-report)
        (false (gate-hook-wired-p project) "the gate reads as wired")))))

(define-test the-generated-entry-point-reads-its-port-without-ignore-errors
  "The generated src/main.lisp carries no ignore-errors, which its own gate refuses.
It still falls back to 4005 for an unset or malformed SLYNK_PORT."
  (let ((main (cdr (assoc "src/main.lisp" (sample-manifest) :test #'string=))))
    (true main "the manifest has no src/main.lisp")
    (false (search "ignore-errors" main)
           "the generated entry point calls ignore-errors")
    (true (search "(parse-integer raw-port :junk-allowed t)" main)
          "the generated entry point does not parse SLYNK_PORT leniently")
    (true (search "4005" main)
          "the generated entry point has no default port")))

(define-test the-new-gate-passes-the-generated-files-and-refuses-a-failing-form
  "The scaffold's own files pass their gate; a staged failing form is refused.

Without the linter the blocking gate refuses any staged Lisp change and says
the linter is missing, so that branch asserts the refusal instead."
  (with-temp-project-root (session root)
    (let* ((outcome (scaffold-into root))
           (project (project-directory outcome))
           (gate (gate-hook-path project)))
      (%stage project (getf outcome :files))
      (if (gate-scanner-available-p)
          (multiple-value-bind (output code) (%run-gate project gate)
            (is = 0 code
                "the gate refused the scaffold's own generated files: ~A" output)
            (let ((main (%project-file project "src/main.lisp")))
              (with-open-file (out main :direction :output :if-exists :append)
                (format out "~%(defun planted-finding ()~%  (ignore-errors (error \"planted\")))~%"))
              (%stage project (list "src/main.lisp"))
              (multiple-value-bind (output code) (%run-gate project gate)
                (is = 1 code "the gate let a failing form through: ~A" output)
                (true (find-if (lambda (line)
                                 (and (uiop:string-prefix-p "src/main.lisp:" line)
                                      (search "[no-ignore-errors]" line)))
                               (uiop:split-string output :separator '(#\Newline)))
                      "the refusal does not name the planted finding: ~A" output))))
          (multiple-value-bind (output code) (%run-gate project gate)
            (is = 1 code "the blocking gate passed with no linter: ~A" output)
            (true (search "linter not found" output)
                  "the refusal does not say the linter is missing: ~A" output))))))

(define-test control-an-enclosing-repository-gets-no-gate
  "CONTROL: a scaffold inside a checkout leaves that checkout's hooks and config alone.

The hooks listing and the local config are read before and after and must be
identical. A config write is then made in the same fixture and the reading is
asserted to change, so the equality is evidence rather than a constant."
  (with-temp-git-repo (root :initial-file "README" :initial-content "enclosing")
    (let ((hooks-before (%hooks-listing root))
          (config-before (%local-config root)))
      (let ((gate (getf (scaffold-into root :disposition :contributing) :gate-hook)))
        (is eq :not-installed (getf gate :action-taken)
            "a gate was installed for a project inside an existing repository")
        (true (stringp (getf gate :reason))
              "the result does not say why no gate was installed"))
      (is equal hooks-before (%hooks-listing root)
          "the enclosing repository's hooks directory changed")
      (is string= config-before (%local-config root)
          "the enclosing repository's local config changed")
      (run-git (list "config" "--local" "probe.moved" "true") :directory root)
      (false (string= config-before (%local-config root))
             "the config reading did not move across a real write"))))
