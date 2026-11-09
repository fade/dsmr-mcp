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
                #:configured-hooks-supported-p
                #:wire-gate-hook)
  (:import-from #:dsmr-mcp/src/repo-classify
                #:resolve-disposition
                #:record-disposition
                #:disposition-profile
                #:disposition-writes-licence-p)
  (:import-from #:dsmr-mcp/src/project-exclude
                #:repair-repo-exclude)
  (:import-from #:dsmr-mcp/src/project-shape-catalog
                #:apparatus-paths-for-profile)
  (:export #:write-scaffold
           #:scaffold-failed-after-writing
           #:scaffold-failure-writes
           #:scaffold-failure-cause))

(in-package #:dsmr-mcp/src/project-scaffold)

(define-condition scaffold-failed-after-writing (error)
  ((writes :initarg :writes :reader scaffold-failure-writes)
   (cause  :initarg :cause  :reader scaffold-failure-cause))
  (:documentation
   "Signalled when the scaffold fails after it wrote to the enclosing
repository. WRITES lists those writes: the disposition record plist and the
exclude plist. CAUSE is the underlying condition.")
  (:report
   (lambda (condition stream)
     (format stream "The scaffold failed: ~A~%Before it failed, it ~{~A~^, and ~}."
             (scaffold-failure-cause condition)
             (mapcar (lambda (write)
                       (if (getf write :disposition)
                           (format nil "recorded the disposition ~(~A~) in ~A"
                                   (getf write :disposition)
                                   (namestring (getf write :path)))
                           (format nil "added ~{~A~^ ~} to ~A"
                                   (getf write :added-patterns)
                                   (namestring (getf write :path)))))
                     (scaffold-failure-writes condition))))))

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
TARGET-DIR. Where git cannot run configured hooks, nothing is written.

Returns (:PATH P :ACTION-TAKEN :CREATED :WIRING W), where W is the plist
WIRE-GATE-HOOK returns, or (:ACTION-TAKEN :NOT-INSTALLED :REASON R) when a step
fails. A failure is reported, never signalled: the project tree is already
written and complete, and a hook problem must not cost the caller that write."
  (flet ((not-installed (reason)
           (list :action-taken :not-installed :reason reason)))
    (handler-case
        (let* ((path (gate-hook-path target-dir))
               (jailed (ensure-write-path (namestring path) target-dir)))
          (cond
            ((not (configured-hooks-supported-p target-dir))
             (not-installed
              "this git cannot run configured hooks, so the gate is not installed"))
            ((null jailed)
             (not-installed
              (format nil "the gate path ~A resolves outside the new project"
                      (namestring path))))
            (t
             (write-file-string-atomically
              jailed (render-pre-commit-hook :profile :ours))
             (uiop:run-program (list "chmod" "+x" (namestring jailed)))
             (list :path path
                   :action-taken :created
                   :wiring (wire-gate-hook target-dir :profile :ours)))))
      (error (condition)
        (not-installed
         (format nil "the lint gate could not be installed: ~A" condition))))))

(defun %record-origin-disposition (target-dir)
  "Record the disposition ours in the .envrc of the repository at TARGET-DIR.

Call only when the scaffold created that repository: creating the code is where
it originates, so ours is a fact here rather than an inference. Returns the plist
RECORD-DISPOSITION returns, or (:ACTION-TAKEN :NOT-RECORDED :REASON R) when it
signals. A failure is reported, never signalled, for the reason given at
%INSTALL-GATE-HOOK."
  (handler-case (record-disposition target-dir :ours :jail target-dir)
    (error (condition)
      (list :action-taken :not-recorded
            :reason (format nil "the disposition could not be recorded: ~A"
                            condition)))))

(defun %enclosing-repository (target-dir)
  "Return the root of the existing repository the project at TARGET-DIR will sit
in, or NIL when there is none.

The search starts at the parent of TARGET-DIR, never TARGET-DIR itself, which an
overwrite replaces, and climbs to the nearest directory that exists."
  (let ((dir (uiop:pathname-parent-directory-pathname target-dir)))
    (loop until (or (uiop:directory-exists-p dir)
                    (equal dir (uiop:pathname-parent-directory-pathname dir)))
          do (setf dir (uiop:pathname-parent-directory-pathname dir)))
    (let ((top (git-toplevel dir)))
      (and top (uiop:ensure-directory-pathname top)))))

(defun %declare-disposition (target-dir disposition init-git session-root)
  "Settle the disposition before anything is scaffolded at TARGET-DIR.

Inside an existing repository: resolve its disposition, with DISPOSITION as the
answer when nothing is recorded, and record a supplied answer in that
repository's .envrc. Returns the plist RECORD-DISPOSITION returns, or
(:PATH P :DISPOSITION D :ACTION-TAKEN :ALREADY-PRESENT) for a recorded value.

Outside every repository returns NIL: a repository the scaffold creates is
recorded ours after it exists, and with INIT-GIT NIL there is none to record in.

Signals, each before anything is written:
  PROJECT-DISPOSITION-REQUIRED    nothing recorded and DISPOSITION is NIL.
  PROJECT-DISPOSITION-ERROR       any other refusal RESOLVE-DISPOSITION or
                                  RECORD-DISPOSITION signals.
  INVALID-ARGUMENT-ERROR          DISPOSITION is supplied outside every
                                  repository and is not ours, or INIT-GIT is NIL."
  (let ((enclosing (%enclosing-repository target-dir)))
    (cond
      (enclosing
       (multiple-value-bind (resolved source)
           (resolve-disposition enclosing :supplied disposition)
         (if (eq source :argument)
             (record-disposition enclosing resolved :jail session-root)
             (list :path source :disposition resolved
                   :action-taken :already-present))))
      ((null disposition) nil)
      ((and init-git (eq disposition :ours)) nil)
      (t
       (error 'invalid-argument-error
              :field "disposition" :value disposition
              :reason (if init-git
                          "the scaffold creates this repository, so its disposition is ours"
                          "the project is outside every repository and init_git is false, so there is no repository to record a disposition in"))))))

(defun %path-in-repository (target-dir enclosing)
  "Return TARGET-DIR relative to the repository root ENCLOSING, as a string
ending in a slash. TARGET-DIR need not exist; its nearest existing ancestor is
resolved, so a symlink on the way does not change the answer."
  (let ((dir (uiop:ensure-directory-pathname target-dir))
        (tail '()))
    (loop until (uiop:directory-exists-p dir)
          do (push (car (last (pathname-directory dir))) tail)
             (setf dir (uiop:pathname-parent-directory-pathname dir)))
    (format nil "~A~{~A/~}"
            (enough-namestring (truename dir) (truename enclosing))
            tail)))

(defun %apparatus-exclude-patterns (enclosing target-dir profile)
  "Return the local-exclude patterns that keep the apparatus PROFILE excludes
out of the index of the repository at ENCLOSING, each anchored under the
project at TARGET-DIR."
  (let ((prefix (%path-in-repository target-dir enclosing)))
    (mapcar (lambda (path) (format nil "/~A~A" prefix path))
            (apparatus-paths-for-profile profile))))

(defun %write-project (&key target-dir temp-dir session-root name description
                             author license copyright year destination overwrite
                             init-git declared licence note-write)
  "Write the project for WRITE-SCAFFOLD once its disposition is settled, and
return WRITE-SCAFFOLD's result plist.

DECLARED is the enclosing repository's disposition record, or NIL when there is
none. LICENCE is the :LICENCE plist; :OMITTED plans no licence text. NOTE-WRITE
is called with the exclude plist when the enclosing repository's exclude is
changed, before any project file is written."
  (let* ((enclosing (and declared (%enclosing-repository target-dir)))
         (exclude (when enclosing
                    (repair-repo-exclude
                     enclosing
                     :template-patterns (%apparatus-exclude-patterns
                                         enclosing target-dir
                                         (disposition-profile
                                          (getf declared :disposition)))))))
    (when (member (getf exclude :action-taken) '(:created :updated))
      (funcall note-write exclude))
    (let* ((manifest (plan-scaffold :name name
                                    :description (or description "")
                                    :author (or author "")
                                    :license license
                                    :copyright (or copyright author "Unknown")
                                    ;; year default is owned by plan-scaffold
                                    ;; (live current year); pass through as-is
                                    :year year
                                    :destination destination
                                    :without-licence (eq :omitted
                                                         (getf licence :action-taken))))
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
the project has no hooks directory of its own")))))
                    (disposition
                      (cond
                        (declared declared)
                        (git-initialised
                         (%record-origin-disposition target-dir))
                        (t
                         (list :action-taken :not-recorded
                               :reason
                               (format nil "the project is in no repository, ~
so there is nowhere to record a disposition"))))))
               (list :target-dir target-dir
                     :relative-path (enough-namestring target-dir session-root)
                     :files (mapcar #'car manifest)
                     :registration registration
                     :git-initialised (and git-initialised t)
                     :gate-hook gate-hook
                     :disposition disposition
                     :licence licence
                     :exclude exclude)))
        (unless committed
          (when (uiop:directory-exists-p temp-dir)
            (ignore-errors
             (uiop:delete-directory-tree temp-dir :validate t))))))))

(defun write-scaffold (&key name description author license copyright year
                              destination overwrite session-root
                              (init-git t) disposition)
  "Generate the scaffold project atomically under SESSION-ROOT.
Returns a plist with:
  :target-dir       (absolute directory pathname)
  :relative-path    (namestring relative to session-root)
  :files            (list of relative path strings, in manifest order)
  :registration     :SOURCE-REGISTRY or :LOAD-ASD, see %register-with-asdf
  :git-initialised  (T when a repository was created here, NIL when not)
  :gate-hook        the lint gate, see %install-gate-hook; when no repository
                    was created here, (:ACTION-TAKEN :NOT-INSTALLED :REASON R)
  :disposition      inside an existing repository, its disposition, see
                    %declare-disposition; in a repository created here, the
                    ours record, see %record-origin-disposition; in none,
                    (:ACTION-TAKEN :NOT-RECORDED :REASON R)
  :licence          (:ACTION-TAKEN :WRITTEN :LICENSE L), or
                    (:ACTION-TAKEN :OMITTED :REASON R) when none was written
  :exclude          inside an existing repository, the plist
                    REPAIR-REPO-EXCLUDE returned for the apparatus paths;
                    otherwise NIL

DISPOSITION answers the disposition question for an existing repository the
project will sit in. With nothing recorded there and no answer, the call signals
PROJECT-DISPOSITION-REQUIRED and writes nothing; an answer is recorded in that
repository's .envrc before the project is written. A repository the scaffold
creates takes only ours.

Inside an existing repository the disposition governs what is written. Unless
it is ours, the project carries no licence text at all, whatever LICENSE says:
no LICENSE file, and no SPDX identifier, :license line, or License section. The
apparatus paths the disposition keeps out of the index are added to that
repository's local exclude, anchored under the project, before any project file
is written.

INIT-GIT defaults to T. A scaffolded project is a git repository from the
moment it is written, unless it would nest inside one that already exists.
Whether that happened is reported rather than assumed, so no repository is
touched without the caller being told. The blocking lint gate is installed
only in a repository created here: an enclosing repository's hooks and config
are never written.

On any failure, signals INVALID-ARGUMENT-ERROR or propagates the
underlying error after cleaning up the temp directory (no debris). A failure
after the enclosing repository's .envrc or exclude was written signals
SCAFFOLD-FAILED-AFTER-WRITING, which names those writes and carries the
underlying condition."
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
      (let* ((declared (%declare-disposition target-dir disposition init-git
                                             session-root))
             (declared-as (getf declared :disposition))
             (writes-licence (or (null declared)
                                 (disposition-writes-licence-p declared-as)))
             (writes (when (member (getf declared :action-taken) '(:created :added))
                       (list declared))))
        (handler-case
            (%write-project
             :target-dir target-dir :temp-dir temp-dir :session-root session-root
             :name name :description description :author author
             :license (or license "AGPL-3.0-or-later")
             :copyright copyright :year year
             :destination effective-destination :overwrite overwrite
             :init-git init-git :declared declared
             :licence (if writes-licence
                          (list :action-taken :written
                                :license (or license "AGPL-3.0-or-later"))
                          (list :action-taken :omitted
                                :reason (format nil "the enclosing repository is declared ~A, ~
so no licence text is written into it"
                                                (string-downcase declared-as))))
             :note-write (lambda (write) (setf writes (append writes (list write)))))
          (error (condition)
            (if writes
                (error 'scaffold-failed-after-writing :writes writes :cause condition)
                (error condition))))))))
