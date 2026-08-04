;;;; src/project-shape-catalog.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; The declared shape of a project of ours: every file, what tier it sits in,
;;;; which files are our operational apparatus, and which tiers each kind of
;;;; repository is held to.
;;;;
;;;; ⚠ THE ANSWERS IN THIS FILE ARE PROVISIONAL. The tier each item is assigned,
;;;; the flags saying which items the scaffold writes, and the mapping from a
;;;; repository's profile to the tiers it is assessed against are all a reading
;;;; of what the repositories on this machine actually contain. They are not a
;;;; settled ruling, and the reading may be overruled.
;;;;
;;;; That is why they are here, in a file holding data and nothing else. Changing
;;;; the answer means editing this file. The item representation, the scaffold,
;;;; the assessment and every test survive a different answer unchanged.
;;;;
;;;; What the reading rests on. Two populations were counted. Among ten of our
;;;; own application repositories, a system definition plus src/ and tests/ is
;;;; present in all ten; the linter config and the lint script are present in
;;;; seven, and in exactly the same seven, never one without the other; a build
;;;; script is present in six. Among roughly ninety repositories in the wider
;;;; workspace, a system definition is near universal, src/ is in about a third,
;;;; tests/ in about a fifth, the linter config in three, and the build script
;;;; and lint script in none at all.
;;;;
;;;; The consequence that forces the tiering: requiring the full scaffold file
;;;; set everywhere would report roughly ninety working third-party repositories
;;;; as broken. A report that is mostly false entries hides the true ones, so a
;;;; single flat list cannot be the answer whichever list is chosen.
;;;;
;;;; The consequence that forces the grouping: the linter config and the lint
;;;; script never occur apart, and the hook is what makes either take effect.
;;;; Assessing them separately would describe a partial install that does not
;;;; happen, and would count one absent gate as three faults.

(defpackage #:dsmr-mcp/src/project-shape-catalog
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/project-shape
                #:make-shape-item
                #:shape-item-key
                #:shape-item-path
                #:shape-item-install-target
                #:item-disposition
                #:*shape-catalog*)
  ;; The substitution comes from its own leaf module rather than from the
  ;; scaffold. The scaffold derives its manifest from this catalog, so a
  ;; dependency in that direction would close a loop and the system would not
  ;; build.
  (:import-from #:dsmr-mcp/src/template-render
                #:render-template)
  (:import-from #:dsmr-mcp/src/project-scaffold-templates
                #:*asd-template*
                #:*main-lisp-template*
                #:*main-test-template*
                #:*build-template*
                #:*dev-boot-template*
                #:*agents-md-template*
                #:*claude-md-template*
                #:*readme-template*
                #:*gitignore-template*
                #:*prompt-template*
                #:*envrc-template*
                #:*license-template*
                #:*mallet-config-template*
                #:*lint-lisp-template*
                #:*pre-commit-hook-template*)
  (:export #:*shape-catalog*
           #:catalog-item
           #:*assessed-tiers*
           #:assessed-tiers-for-profile
           #:apparatus-paths-for-profile
           #:unknown-profile-error
           #:unknown-profile-error-profile))

(in-package #:dsmr-mcp/src/project-shape-catalog)

;;; ---------------------------------------------------------------------------
;;; Condition
;;; ---------------------------------------------------------------------------

(define-condition unknown-profile-error (error)
  ((profile :initarg :profile :reader unknown-profile-error-profile))
  (:documentation
   "Signaled when a repository profile has no entry in *ASSESSED-TIERS*.

Signalled rather than answered with an empty tier list, because an empty list
assesses every repository as clean and a clean report on a misspelled profile
looks exactly like a clean report on a healthy repository.")
  (:report
   (lambda (condition stream)
     (format stream "No tiers are declared for the repository profile ~S."
             (unknown-profile-error-profile condition)))))

(setf (documentation 'unknown-profile-error-profile 'function)
      "Return the unrecognised profile from an UNKNOWN-PROFILE-ERROR.")

;;; ---------------------------------------------------------------------------
;;; A generator is a template plus the bindings the caller supplies
;;; ---------------------------------------------------------------------------

(defun %renderer (template)
  "Return a generator closing over TEMPLATE.

The returned function takes the bindings alist and produces file content, so an
item's generator is one place rather than a rendering call repeated per file."
  (lambda (bindings) (render-template template bindings)))

;;; ---------------------------------------------------------------------------
;;; The catalog
;;; ---------------------------------------------------------------------------

;;; The items the scaffold writes appear here in the order it writes them, so
;;; that the emitted manifest can be derived from this list without changing
;;; what any existing project looks like.

(setf *shape-catalog*
      (list

       ;; Tier: invariant. Present in every one of our application repositories
       ;; that was counted, and the only items near universal in the wider
       ;; workspace. An absence here is a real finding about the repository.

       (make-shape-item
        :key :asd-system
        :path "{{name}}.asd"
        :tier :invariant
        :assertion :any-file-matching
        :match "*.asd"
        :generator (%renderer *asd-template*)
        :emit-on-scaffold-p t)

       (make-shape-item
        :key :src-dir
        :path "src/main.lisp"
        :tier :invariant
        :assertion :directory-exists
        :match "src/"
        :generator (%renderer *main-lisp-template*)
        :emit-on-scaffold-p t)

       (make-shape-item
        :key :tests-dir
        :path "tests/main-test.lisp"
        :tier :invariant
        :assertion :directory-exists
        :match "tests/"
        :generator (%renderer *main-test-template*)
        :emit-on-scaffold-p t)

       ;; Tier: gate. The quality gate, assessed through its group as one unit.
       ;;
       ;; ⚠ These three carry EMIT-ON-SCAFFOLD-P NIL, and that flag is the
       ;; unsettled part of the shape question. NIL leaves what the scaffold
       ;; writes exactly as it was. If a new project should be born with the gate
       ;; already installed, flipping these three flags to T is the entire
       ;; change, and nothing outside this file moves.

       (make-shape-item
        :key :mallet-config
        :path ".mallet.lisp"
        :tier :gate
        :group :quality-gate
        :apparatus-p t
        :assertion :file-exists
        :match ".mallet.lisp"
        :generator (%renderer *mallet-config-template*)
        :emit-on-scaffold-p nil
        :install-target :worktree)

       (make-shape-item
        :key :lint-script
        :path "scripts/lint-lisp.sh"
        :tier :gate
        :group :quality-gate
        :apparatus-p t
        :assertion :file-exists
        :match "scripts/lint-lisp.sh"
        :generator (%renderer *lint-lisp-template*)
        :emit-on-scaffold-p nil
        :install-target :worktree)

       (make-shape-item
        :key :pre-commit
        :path "hooks/pre-commit"
        :tier :gate
        :group :quality-gate
        :apparatus-p t
        :assertion :file-exists
        :match "hooks/pre-commit"
        :generator (%renderer *pre-commit-hook-template*)
        :emit-on-scaffold-p nil
        :install-target :git-dir)

       ;; The frozen record of what the gate would have fired on in this
       ;; repository at the moment it was installed. Its content is measured per
       ;; repository rather than rendered from a template, so it has no
       ;; generator. It is declared here so that it is excluded in a repository
       ;; we do not own by the same rule every other apparatus path goes through,
       ;; before anything writes it. It is not part of the gate group: the gate
       ;; works without it, and a missing baseline is not a missing gate.

       (make-shape-item
        :key :gate-baseline
        :path ".gate-baseline.md"
        :tier :gate
        :apparatus-p t
        :assertion :file-exists
        :match ".gate-baseline.md"
        :generator nil
        :emit-on-scaffold-p nil
        :install-target :worktree)

       ;; Tier: convenience. Advisory. A build script is present in six of ten of
       ;; our own repositories and in none of the ninety in the wider workspace,
       ;; so its absence says nothing about whether a repository is healthy.

       (make-shape-item
        :key :build-script
        :path "build.sh"
        :tier :convenience
        :assertion :file-exists
        :match "build.sh"
        :generator (%renderer *build-template*)
        :emit-on-scaffold-p t)

       (make-shape-item
        :key :dev-boot
        :path "scripts/dev-boot.sh"
        :tier :convenience
        :assertion :file-exists
        :match "scripts/dev-boot.sh"
        :generator (%renderer *dev-boot-template*)
        :emit-on-scaffold-p t)

       (make-shape-item
        :key :agents-doc
        :path "AGENTS.md"
        :tier :convenience
        :apparatus-p t
        :assertion :file-exists
        :match "AGENTS.md"
        :generator (%renderer *agents-md-template*)
        :emit-on-scaffold-p t)

       (make-shape-item
        :key :claude-doc
        :path "CLAUDE.md"
        :tier :convenience
        :apparatus-p t
        :assertion :file-exists
        :match "CLAUDE.md"
        :generator (%renderer *claude-md-template*)
        :emit-on-scaffold-p t)

       (make-shape-item
        :key :readme
        :path "README.md"
        :tier :convenience
        :assertion :file-exists
        :match "README.md"
        :generator (%renderer *readme-template*)
        :emit-on-scaffold-p t)

       (make-shape-item
        :key :gitignore
        :path ".gitignore"
        :tier :convenience
        :assertion :file-exists
        :match ".gitignore"
        :generator (%renderer *gitignore-template*)
        :emit-on-scaffold-p t)

       (make-shape-item
        :key :envrc
        :path ".envrc"
        :tier :convenience
        :apparatus-p t
        :assertion :file-exists
        :match ".envrc"
        :generator (%renderer *envrc-template*)
        :emit-on-scaffold-p t)

       (make-shape-item
        :key :prompt
        :path "prompts/repl-driven-development.md"
        :tier :convenience
        :assertion :file-exists
        :match "prompts/repl-driven-development.md"
        :generator (%renderer *prompt-template*)
        :emit-on-scaffold-p t)

       (make-shape-item
        :key :license
        :path "LICENSE"
        :tier :convenience
        :assertion :file-exists
        :match "LICENSE"
        :generator (%renderer *license-template*)
        :emit-on-scaffold-p t)))

(defun catalog-item (key &optional (catalog *shape-catalog*))
  "Return the item in CATALOG whose key is KEY, or NIL when there is none."
  (find key catalog :key #'shape-item-key))

;;; ---------------------------------------------------------------------------
;;; Which tiers each kind of repository is held to
;;; ---------------------------------------------------------------------------

;;; ⚠ This mapping is as provisional as the tiers themselves, and it lives here
;;; rather than beside the assessment for one reason: whether a repository we
;;; have just adopted from somebody else should be held to our quality gate is
;;; the same unsettled question as which tier each file belongs in. Split across
;;; two files in two subsystems, answering that question would mean editing
;;; both, and the claim that the provisional part is confined to one file would
;;; be a description of intent rather than a fact about the code.

(defvar *assessed-tiers*
  '((:ours . (:invariant :gate))
    (:foreign . (:invariant)))
  "The tiers each repository profile is assessed against.

Our own repositories are held to the quality gate. A repository we do not own is
held only to what makes it a working system, because our conventions are ours
and a third party's project is not defective for lacking them.

A DEFVAR rather than a DEFPARAMETER so that an override installed at runtime
survives reloading the system.")

(defun assessed-tiers-for-profile (profile)
  "Return the list of tiers PROFILE is assessed against.

Signals UNKNOWN-PROFILE-ERROR for a profile with no entry. Returning NIL instead
would report every repository as clean, and that report is indistinguishable
from the report for a repository that genuinely is."
  (let ((entry (assoc profile *assessed-tiers*)))
    (unless entry
      (error 'unknown-profile-error :profile profile))
    (cdr entry)))

;;; ---------------------------------------------------------------------------
;;; The paths to keep out of a repository's index
;;; ---------------------------------------------------------------------------

(defun apparatus-paths-for-profile (profile &optional (catalog *shape-catalog*))
  "Return the worktree paths in CATALOG that PROFILE must not track.

Derived from the same catalog everything else reads, so the set of paths to
exclude cannot fall behind the set of files that get written.

Items installed under the repository's git directory are left out: they are
never part of any worktree, so naming one here would add a pattern matching
nothing, or worse, matching an unrelated file that happens to share the name."
  (let ((excluded '()))
    (dolist (item catalog (nreverse excluded))
      (when (and (eq :worktree (shape-item-install-target item))
                 (eq :excluded (item-disposition item profile))
                 (shape-item-path item))
        (push (shape-item-path item) excluded)))))
