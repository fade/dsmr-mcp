;;;; src/project-scaffold.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Effectful I/O layer for project-scaffold.
;;;; Thin wrapper on top of the pure logic in project-scaffold-core.
;;;; Writes the scaffold tree atomically: all files go into a random-suffixed
;;;; temp directory, then a single rename-file commits the whole tree.
;;;; unwind-protect removes the temp dir on any failure so a partial write
;;;; never leaves debris under the session root.
;;;;
;;;; Route writes through ensure-write-path + write-file-string-atomically
;;;; (the write-jail primitives), NOT the fs-write-file tool: the tool
;;;; refuses existing .lisp/.asd files and fires LSP didChange, both
;;;; inappropriate for fresh-tree generation.

(defpackage #:dsmr-mcp/src/project-scaffold
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/project-scaffold-core
                #:validate-project-name
                #:validate-destination
                #:validate-text-field
                #:plan-scaffold
                #:invalid-argument-error)
  (:import-from #:dsmr-mcp/src/project-root
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:import-from #:dsmr-mcp/src/envrc-init
                #:envrc-content-with-derived-port)
  (:import-from #:dsmr-mcp/src/git
                #:git-toplevel
                #:git-init)
  (:import-from #:dsmr-mcp/src/project-debt
                #:render-pre-commit-hook)
  (:import-from #:dsmr-mcp/src/project-hook
                #:gate-hook-path
                #:wire-gate-hook)
  (:export #:write-scaffold))

(in-package #:dsmr-mcp/src/project-scaffold)

(defun %uuid-suffix ()
  "Return a short pseudo-random hex suffix for temp directory naming."
  (format nil "~8,'0X" (random #xFFFFFFFF)))

(defun %absolute-scaffold-paths (session-root destination name)
  "Return (values TARGET-DIR TEMP-DIR) as absolute directory pathnames.
Both paths are inside SESSION-ROOT. TEMP-DIR has a random suffix to avoid
collisions between concurrent scaffold calls."
  (let* ((dest-dir   (uiop:ensure-directory-pathname
                       (merge-pathnames
                        (uiop:ensure-directory-pathname destination)
                        session-root)))
         (target-dir (uiop:ensure-directory-pathname
                       (merge-pathnames
                        (uiop:ensure-directory-pathname name)
                        dest-dir)))
         (temp-dir   (uiop:ensure-directory-pathname
                       (merge-pathnames
                        (uiop:ensure-directory-pathname
                         (format nil ".tmp-~A" (%uuid-suffix)))
                        dest-dir))))
    (values target-dir temp-dir)))

(defun %check-within-root (dir session-root context)
  "Signal INVALID-ARGUMENT-ERROR if DIR is not under SESSION-ROOT.
Uses ensure-write-path for the symlink-safe containment check.
CONTEXT is a string describing which directory is being checked (for
the error message)."
  (unless (ensure-write-path (namestring dir) session-root)
    (error 'invalid-argument-error
           :field "destination"
           :value (namestring dir)
           :reason (format nil "~A resolves outside session root" context))))

(defun %executable-content-p (content)
  "True when CONTENT begins with a #! line, marking the file as a script.

The execute bit is derived from the file's own first two bytes rather than
declared in a table of names kept somewhere else. A script added to the
manifest later cannot then be forgotten, and the mode can never disagree with
the content it describes. Every shebang-bearing file this scaffold emits is one
the generated README and CLAUDE.md tell a person to run directly, so at the
bare process umask those instructions fail on their first step."
  (and (stringp content)
       (>= (length content) 2)
       (string= "#!" content :end2 2)))

(defun %write-plan-to-temp (temp-dir plan session-root)
  "Write all PLAN entries into TEMP-DIR, routing each file through the
write-jail (ensure-write-path) then write-file-string-atomically.
TEMP-DIR must already be inside SESSION-ROOT; this is asserted per-file."
  (ensure-directories-exist temp-dir)
  (let* ((temp-ns (namestring temp-dir))
         ;; ensure trailing slash
         (temp-prefix (if (char= (char temp-ns (1- (length temp-ns))) #\/)
                          temp-ns
                          (concatenate 'string temp-ns "/"))))
    (dolist (entry plan)
      (let* ((rel-in-temp (concatenate 'string temp-prefix (car entry)))
             (pn (ensure-write-path rel-in-temp session-root)))
        (unless pn
          (error 'invalid-argument-error
                 :field "destination"
                 :value rel-in-temp
                 :reason "file path resolves outside session root"))
        (write-file-string-atomically pn (cdr entry))
        (when (%executable-content-p (cdr entry))
          ;; chmod through run-program rather than sb-posix, matching how the
          ;; installer sets the execute bit on the binary it copies. A chmod
          ;; that cannot run must not discard an otherwise complete tree.
          (uiop:run-program (list "chmod" "+x" (namestring pn))
                            :ignore-error-status t))))))

(defun %register-with-asdf (name abs-asd)
  "Make the freshly emitted system findable in this image and report how.

A long-running image caches the source registry at its first lookup, so a
directory created afterwards stays invisible even when it sits squarely on a
configured tree. Dropping that cache is what makes the new project findable;
its only cost to the caller is one rescan of the configured trees at the next
lookup, since loaded code and loaded systems are left alone. A definition
already recorded under NAME is dropped as well, so the answer below reflects
what the registry can find rather than what an earlier call left behind.

Returns :SOURCE-REGISTRY when the rescan resolves NAME to this very .asd, which
also means any other image on this host will find it. Returns :LOAD-ASD when
the project sits outside every configured tree and had to be registered by
hand, which reaches no image but this one."
  (asdf:clear-source-registry)
  (ignore-errors (asdf:clear-system name))
  (let* ((found (ignore-errors (asdf:find-system name nil)))
         (source (and found (ignore-errors
                             (truename (asdf:system-source-file found))))))
    (if (and source (equal source (ignore-errors (truename abs-asd))))
        :source-registry
        (progn (ignore-errors (asdf:load-asd abs-asd))
               :load-asd))))

(defun %initialise-repository (target-dir)
  "Make TARGET-DIR a git repository when it is not already inside one.

Returns T when a repository was created here, NIL when none was.

A scaffolded project needs somewhere to keep the local ignore patterns that
must never appear in a tracked file, and that somewhere is the exclude file
under the repository's own git directory. Running git init is the whole of the
scaffold's part in it: git seeds that file from the configured init template at
the moment the repository is created.

⛔ Nothing here writes an ignore pattern, and nothing here should. The template
is the one list of record. On a host with no such template configured the file
arrives empty, and bringing it up to date is a repair belonging to the doctor
rather than a second copy of the list kept here.

Nothing is created when the directory already sits inside a repository. That
covers both the case where it is a repository root already and the case where
it lives inside somebody else's checkout, and in the second case a nested
repository would quietly shadow the enclosing one for every command run below
this point."
  (unless (git-toplevel target-dir)
    (git-init target-dir)
    t))

(defun %install-gate-hook (target-dir)
  "Install the blocking lint gate in the repository at TARGET-DIR and wire it.

Writes the :OURS rendering of the gate to GATE-HOOK-PATH through the write jail,
rooted at TARGET-DIR, sets its execute bit, and registers it with
WIRE-GATE-HOOK. Call only when the scaffold created the repository at
TARGET-DIR.

Returns (:PATH P :ACTION-TAKEN :CREATED :WIRING W), where W is the plist
WIRE-GATE-HOOK returns, or (:ACTION-TAKEN :NOT-INSTALLED :REASON R) when a step
fails. A failure is reported, never signalled: the project tree is already
written and complete, and a hook problem must not cost the caller that write."
  (flet ((not-installed (reason)
           (list :action-taken :not-installed :reason reason)))
    (handler-case
        (let* ((path (gate-hook-path target-dir))
               (jailed (ensure-write-path (namestring path) target-dir)))
          (if (null jailed)
              (not-installed
               (format nil "the gate path ~A resolves outside the new project"
                       (namestring path)))
              (progn
                (write-file-string-atomically
                 jailed (render-pre-commit-hook :profile :ours))
                (uiop:run-program (list "chmod" "+x" (namestring jailed)))
                (list :path path
                      :action-taken :created
                      :wiring (wire-gate-hook target-dir)))))
      (error (condition)
        (not-installed
         (format nil "the lint gate could not be installed: ~A" condition))))))

(defun write-scaffold (&key name description author license copyright year
                              destination overwrite session-root
                              (init-git t))
  "Generate the scaffold project atomically under SESSION-ROOT.
Returns a plist with:
  :target-dir       (absolute directory pathname)
  :relative-path    (namestring relative to session-root)
  :files            (list of relative path strings, in manifest order)
  :registration     :SOURCE-REGISTRY or :LOAD-ASD, see %register-with-asdf
  :git-initialised  (T when a repository was created here, NIL when not)
  :gate-hook        the lint gate, see %install-gate-hook; when no repository
                    was created here, (:ACTION-TAKEN :NOT-INSTALLED :REASON R)

INIT-GIT defaults to T. A scaffolded project is a git repository from the
moment it is written, unless it would nest inside one that already exists.
Whether that happened is reported rather than assumed, so no repository is
touched without the caller being told. The blocking lint gate is installed
only in a repository created here: an enclosing repository's hooks and config
are never written.

On any failure, signals INVALID-ARGUMENT-ERROR or propagates the
underlying error after cleaning up the temp directory (no debris)."
  (unless session-root
    (error 'invalid-argument-error
           :field "session-root" :value nil :reason "session root is required"))
  (validate-project-name name)
  (validate-destination (or destination "scaffolds"))
  (validate-text-field "description" (or description ""))
  (validate-text-field "author" (or author ""))
  (validate-text-field "copyright" (or copyright author ""))
  (let ((effective-destination (or destination "scaffolds")))
    (multiple-value-bind (target-dir temp-dir)
        (%absolute-scaffold-paths session-root effective-destination name)
      ;; Assert both target and temp resolve under the session root
      (%check-within-root target-dir session-root "target directory")
      (%check-within-root temp-dir session-root "temp directory")
      (when (and (uiop:directory-exists-p target-dir) (not overwrite))
        (error 'invalid-argument-error
               :field "name" :value name
               :reason (format nil "target directory already exists: ~A"
                               (namestring target-dir))))
      (let* ((manifest (plan-scaffold :name name
                                      :description (or description "")
                                      :author (or author "")
                                      :license (or license "AGPL-3.0-or-later")
                                      :copyright (or copyright author "Unknown")
                                      ;; year default is owned by plan-scaffold
                                      ;; (live current year); pass through as-is
                                      :year year
                                      :destination effective-destination))
             ;; Substitute the per-project derived Slynk port into the
             ;; generated .envrc and scripts/dev-boot.sh, so the new project
             ;; starts with its own port from day one rather than the shared
             ;; literal 4005.
             (manifest (mapcar
                        (lambda (entry)
                          (if (member (car entry) '(".envrc" "scripts/dev-boot.sh")
                                      :test #'string=)
                              (cons (car entry)
                                    (envrc-content-with-derived-port
                                     (cdr entry) target-dir))
                              entry))
                        manifest))
             (committed nil))
        (unwind-protect
             (progn
               (%write-plan-to-temp temp-dir manifest session-root)
               ;; Delete existing target AFTER temp is ready, preserving
               ;; atomicity: if the write failed, the original survives.
               (when (and overwrite (uiop:directory-exists-p target-dir))
                 (uiop:delete-directory-tree target-dir :validate t))
               (rename-file temp-dir target-dir)
               (setf committed t)
               ;; The repository is created only once the rename has committed
               ;; the tree, so a git failure propagates against a complete and
               ;; correct project rather than costing the caller the write.
               (let* ((git-initialised (when init-git
                                         (%initialise-repository target-dir)))
                      (abs-asd (namestring
                                (merge-pathnames (format nil "~A.asd" name) target-dir)))
                      (registration (when (probe-file abs-asd)
                                      (%register-with-asdf name abs-asd)))
                      (gate-hook
                        (if git-initialised
                            (%install-gate-hook target-dir)
                            (list :action-taken :not-installed
                                  :reason
                                  (if init-git
                                      (format nil "no repository was created here: ~
the project is inside an existing one, whose hooks are never written")
                                      (format nil "no repository was created: ~
the project has no hooks directory of its own"))))))
                 (list :target-dir target-dir
                       :relative-path (enough-namestring target-dir session-root)
                       :files (mapcar #'car manifest)
                       :registration registration
                       :git-initialised (and git-initialised t)
                       :gate-hook gate-hook)))
          (unless committed
            (when (uiop:directory-exists-p temp-dir)
              (ignore-errors
               (uiop:delete-directory-tree temp-dir :validate t)))))))))
