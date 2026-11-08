;;;; src/project-doctor.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Bringing a repository up to the declared shape, in an order that cannot
;;;; leak, and reporting every change.
;;;;
;;;; The ordering is the whole of the safety design and it is not a convention
;;;; that can be relaxed. Our operational apparatus belongs on disk in a
;;;; repository we do not own and must never reach that repository's index. A
;;;; file of ours written into a foreign worktree before its path is excluded is
;;;; visible in the maintainer's git status from the instant it lands, and the
;;;; next thing that maintainer stages sweeps it up. So the local exclude is
;;;; brought up to date first and the files are written second. There is no
;;;; window in between because the code cannot express one: the write step is
;;;; not reachable until the exclude step has returned.
;;;;
;;;; Nothing here touches git history. No add, no commit, no removal, no branch
;;;; change. The git state this module writes is the local exclude file, an
;;;; upstream remote when the caller supplies one, and the two hook.lisp-gate
;;;; configured-hook entries in the local config that make git run the lint
;;;; gate. All of it lives under the repository's own git directory and is
;;;; invisible to every upstream. The head sha is read before and after every
;;;; run and the two are required to match, so a call that somehow reached a
;;;; committing path fails loudly rather than leaving a commit of ours in
;;;; somebody else's log.
;;;;
;;;; Nothing here deletes, and nothing here overwrites a file the doctor does not
;;;; own or replaces a config value it did not write. A repair creates a file
;;;; that is absent; a destination that already holds something else is a
;;;; finding to report. The doctor's own files and entries are the exception:
;;;; a gate script of its own rendering that is stale is rewritten, and a
;;;; hook.lisp-gate.command entry of its own is rewired for the current
;;;; profile. Neither DELETE-FILE nor a directory-tree removal appears in this
;;;; module at all. The destructive primitive lives elsewhere in this corner of
;;;; the codebase and this is the module that must not reach for it.
;;;;
;;;; What changed is reported separately from what was already correct, using
;;;; the action-taken vocabulary the exclude repair already established rather
;;;; than a second one invented here.
;;;;
;;;; Writes go through ENSURE-WRITE-PATH and WRITE-FILE-STRING-ATOMICALLY, the
;;;; write-jail primitives, and not through the fs-write-file tool: that tool
;;;; refuses existing Lisp sources and fires an editor notification, neither of
;;;; which belongs in a repair of somebody else's repository.

(defpackage #:dsmr-mcp/src/project-doctor
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/project-assess
                #:assess-repository
                #:item-satisfied-p
                #:gate-file-state
                #:assessment-disposition
                #:assessment-disposition-source
                #:assessment-profile
                #:assessment-deviations
                #:assessment-satisfied)
  (:import-from #:dsmr-mcp/src/project-deviation
                #:deviation-item
                #:signal-deviation
                #:call-with-deviation-policy
                #:available-restarts
                #:policy-not-applicable-error
                #:foreign-apparatus-tracked)
  ;; The exclude repair is imported, and called, ahead of anything that writes a
  ;; file. Both orderings are deliberate and the source order is part of the
  ;; evidence that the runtime order holds.
  (:import-from #:dsmr-mcp/src/project-exclude
                #:repair-repo-exclude
                #:template-exclude-patterns)
  ;; The disposition is recorded after the exclude step, for the same reason.
  (:import-from #:dsmr-mcp/src/repo-classify
                #:record-disposition
                #:check-disposition-recordable
                #:disposition-warnings)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item-key
                #:shape-item-path
                #:shape-item-match
                #:shape-item-group
                #:shape-item-generator
                #:shape-item-assertion
                #:shape-item-install-target
                #:shape-group-items
                #:*shape-catalog*)
  (:import-from #:dsmr-mcp/src/project-shape-catalog
                #:catalog-item
                #:apparatus-paths-for-profile)
  (:import-from #:dsmr-mcp/src/project-debt
                #:adopted-repo-gate-severity
                #:render-gate-config
                #:render-lint-script
                #:render-pre-commit-hook
                #:render-debt-baseline)
  (:import-from #:dsmr-mcp/src/project-hook
                #:gate-hook-path
                #:configured-hooks-supported-p
                #:wire-gate-hook)
  (:import-from #:dsmr-mcp/src/project-gate-scan
                #:collect-debt-sites
                #:gate-scanner-unavailable-error
                #:gate-scanner-unavailable-path)
  (:import-from #:dsmr-mcp/src/template-render
                #:render-template)
  (:import-from #:dsmr-mcp/src/project-root
                #:ensure-write-path)
  (:import-from #:dsmr-mcp/src/fs
                #:write-file-string-atomically)
  (:import-from #:dsmr-mcp/src/git
                #:git-head-sha
                #:git-tracked-files
                #:git-remote-url
                #:git-remote-add
                #:git-common-dir)
  (:export #:normalise-repository
           #:doctor-report
           #:doctor-report-p
           #:report-root
           #:report-disposition
           #:report-disposition-source
           #:report-disposition-recorded
           #:report-warnings
           #:report-profile
           #:report-changed
           #:report-already-correct
           #:report-recorded-debt
           #:report-accepted
           #:report-unresolved
           #:report-exclude
           #:report-debt-baseline
           #:report-remote-added
           #:report-head-sha-before
           #:report-head-sha-after
           #:report-dry-run
           #:verify-no-tracked-apparatus
           #:*repair-writer*
           #:head-moved-error
           #:head-moved-root
           #:head-moved-before
           #:head-moved-after
           #:write-outside-root-error
           #:write-outside-root-path
           #:write-outside-root-root))

(in-package #:dsmr-mcp/src/project-doctor)

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition head-moved-error (error)
  ((root   :initarg :root   :reader head-moved-root)
   (before :initarg :before :reader head-moved-before)
   (after  :initarg :after  :reader head-moved-after))
  (:documentation
   "Signalled when a repository's head sha differs after a run from before it.

The doctor makes no commits, so a moved head means something ran that should
not have. Reported rather than tolerated, because a commit of ours in a third
party's log cannot be taken back once it has been pushed, and the only moment it
can be noticed cheaply is here.")
  (:report
   (lambda (condition stream)
     (format stream "~A moved from ~A to ~A during a run that makes no commits."
             (head-moved-root condition)
             (or (head-moved-before condition) "no commit")
             (or (head-moved-after condition) "no commit")))))

(setf (documentation 'head-moved-root 'function)
      "Return the repository whose head moved.")
(setf (documentation 'head-moved-before 'function)
      "Return the head sha read before the run, or NIL when there was no commit.")
(setf (documentation 'head-moved-after 'function)
      "Return the head sha read after the run, or NIL when there was no commit.")

(define-condition write-outside-root-error (error)
  ((path :initarg :path :reader write-outside-root-path)
   (root :initarg :root :reader write-outside-root-root))
  (:documentation
   "Signalled when a repair's destination resolves outside the write jail.

The containment check runs on the resolved pathname, so a symlinked parent
cannot carry a repair out of the tree it was asked to operate on. Signalled
rather than skipped: a repair that quietly declined to write would report the
repository as brought up to shape when it was not.")
  (:report
   (lambda (condition stream)
     (format stream "~A resolves outside ~A and was not written."
             (write-outside-root-path condition)
             (write-outside-root-root condition)))))

(setf (documentation 'write-outside-root-path 'function)
      "Return the destination that resolved outside the jail.")
(setf (documentation 'write-outside-root-root 'function)
      "Return the root the destination was required to be under.")

;;; ---------------------------------------------------------------------------
;;; The one seam a repair's write can be replaced at
;;; ---------------------------------------------------------------------------

(defvar *repair-writer* 'write-file-string-atomically
  "The function name a repair commits its content to disk with.

Held in a variable for one reason, and it is a property of the safety design
rather than a convenience. The ordering claim this module rests on is that an
apparatus path is excluded before its file exists, and the only way to know that
claim holds is to make the write fail and look at the exclude afterwards. A
writer that cannot be replaced can only be reasoned about.

Holds the symbol rather than the function object, so reloading the module that
defines the writer does not leave a stale function behind in a warm image.
DEFVAR for the same reason: a rebind an operator or a test has in place survives
the system being reloaded under it.")

;;; ---------------------------------------------------------------------------
;;; The report
;;; ---------------------------------------------------------------------------

(defstruct (doctor-report (:constructor %make-doctor-report)
                          (:conc-name report-)
                          (:copier nil)
                          (:predicate doctor-report-p))
  "What one normalization run did to a repository, and what it found already right.

CHANGED, ALREADY-CORRECT, RECORDED-DEBT, ACCEPTED and UNRESOLVED are separate
lists on purpose. A single list of findings cannot say which of them the run
acted on, and a report that cannot say what it changed is not a record of a run,
it is a description of one.

DISPOSITION and DISPOSITION-SOURCE are as the assessment resolved them.
DISPOSITION-RECORDED is the plist RECORD-DISPOSITION returned, or one with
:ALREADY-PRESENT naming the file the disposition was read from. WARNINGS are
the strings DISPOSITION-WARNINGS returned.

HEAD-SHA-BEFORE and HEAD-SHA-AFTER are both carried even though they are
required to match, because a reader checking that nothing was committed should
be able to see the two values rather than take the claim on trust."
  (root            nil :read-only t)
  (disposition     nil :read-only t)
  (disposition-source nil :read-only t)
  (disposition-recorded nil :read-only t)
  (warnings        '() :type list :read-only t)
  (profile         nil :read-only t)
  (changed         '() :type list :read-only t)
  (already-correct '() :type list :read-only t)
  (recorded-debt   '() :type list :read-only t)
  (accepted        '() :type list :read-only t)
  (unresolved      '() :type list :read-only t)
  (exclude         nil :read-only t)
  (debt-baseline   nil :read-only t)
  (remote-added    nil :read-only t)
  (head-sha-before nil :read-only t)
  (head-sha-after  nil :read-only t)
  (dry-run         nil :read-only t))

;;; ---------------------------------------------------------------------------
;;; Naming the repository, and the substitutions its files are rendered from
;;; ---------------------------------------------------------------------------

(defun %repo-name (root)
  "Return the directory name the repository at ROOT sits in."
  (or (car (last (pathname-directory (uiop:ensure-directory-pathname root))))
      "project"))

(defun %current-year ()
  "Return the current year as a string, for a rendered copyright line."
  (princ-to-string (nth-value 5 (decode-universal-time (get-universal-time)))))

(defun %bindings (root)
  "Return the substitution alist the shape items are rendered from for ROOT.

The project name comes from the directory the repository sits in, which is the
only name a repository we did not create is guaranteed to have. Both an item's
path and its content go through these, because the catalogue names one file after
the project it belongs to.

The licence, identifier, and copyright keys are bound to the empty string. An
adopted project's licence is its own, so a template that names one renders
nothing here."
  (list (cons "name" (%repo-name root))
        (cons "description" "")
        (cons "author" "")
        (cons "license" "")
        (cons "spdx" "")
        (cons "spdx-line" "")
        (cons "copyright" "")
        (cons "year" (%current-year))
        (cons "license-body" "")))

;;; ---------------------------------------------------------------------------
;;; Where an item lands, and what it should contain
;;; ---------------------------------------------------------------------------

(defun %gate-hook-item-p (item)
  "Return true when ITEM is the lint gate script git runs at pre-commit."
  (eq :gate-hook-wired (shape-item-assertion item)))

(defun %item-destination (item root bindings)
  "Return the absolute pathname ITEM installs to in the repository at ROOT.

A :GIT-DIR item lands under the git directory every worktree of the repository
shares. That directory is never part of any worktree and never reaches an
upstream, so an item installed there is invisible to a third party whatever the
profile. The gate script lands at GATE-HOOK-PATH, the path its configured-hook
command names."
  (if (%gate-hook-item-p item)
      (gate-hook-path root)
      (let ((base (ecase (shape-item-install-target item)
                    (:worktree (uiop:ensure-directory-pathname root))
                    (:git-dir (git-common-dir root))))
            (relative (render-template
                       (or (shape-item-path item) (shape-item-match item))
                       bindings)))
        (merge-pathnames relative base))))

(defun %item-jail (item root jail)
  "Return the directory a write of ITEM in the repository at ROOT must stay inside.
A :GIT-DIR item is bounded by the shared git directory, which in a linked
worktree lies outside the worktree and so outside JAIL; every other item is
bounded by JAIL."
  (ecase (shape-item-install-target item)
    (:worktree jail)
    (:git-dir (git-common-dir root))))

(defun %gate-item-p (item)
  "Return true when ITEM is one of the three files the quality gate is made of."
  (and (member (shape-item-key item) '(:mallet-config :lint-script :pre-commit))
       t))

(defun %writable-item-p (item)
  "Return true when ITEM's content can be produced without measuring the repository.

The frozen baseline is the item this excludes. Its content is a record of what a
particular tree contained at a particular moment, so it has no generator and
cannot be rendered from a template. It is written by recording debt, which is a
different decision from repairing a missing file, and offering to repair it would
produce a document describing no repository at all."
  (or (%gate-item-p item)
      (and (shape-item-generator item) t)))

(defun %without-empty-licence-lines (text)
  "Return TEXT without the lines a template leaves naming no licence.
Drops a line ending in SPDX-License-Identifier: with nothing after it, and a
:license \"\" line, so a file the doctor writes carries no licence tag at all
rather than a malformed one."
  (let ((lines (uiop:split-string text :separator '(#\Newline))))
    (format nil "~{~A~^~%~}"
            (remove-if (lambda (line)
                         (let ((trimmed (string-trim '(#\Space #\Tab #\Return)
                                                     line)))
                           (or (uiop:string-suffix-p trimmed
                                                     "SPDX-License-Identifier:")
                               (string= trimmed ":license \"\""))))
                       lines))))

(defun %item-content (item bindings severity project-name profile)
  "Return the text ITEM's file should carry.

The three gate files come from the debt module's renderers, so the severity a
newly adopted repository's gate is installed at reaches the file rather than
being decided again here. The gate script is rendered for PROFILE, :FOREIGN or
:OURS: informational in a repository we do not own, blocking in one we do.
Everything else comes from the item's own generator, which is the same one the
scaffold writes a new project from, with the licence lines the empty licence
bindings leave behind removed."
  (if (%gate-item-p item)
      (ecase (shape-item-key item)
        (:mallet-config (render-gate-config :severity severity
                                            :project-name project-name))
        (:lint-script (render-lint-script :severity severity
                                          :project-name project-name))
        (:pre-commit (render-pre-commit-hook :severity severity
                                             :project-name project-name
                                             :profile profile)))
      (%without-empty-licence-lines
       (funcall (shape-item-generator item) bindings))))

(defun %executable-item-p (item)
  "Return true when ITEM is a script that has to be executable to do anything."
  (and (member (shape-item-key item) '(:lint-script :pre-commit)) t))

(defun %make-executable (path)
  "Mark PATH executable.

A chmod failure must not undo a write that already completed, so its status is
not consulted, exactly as the existing installer does for the script it copies."
  (uiop:run-program (list "chmod" "+x" (namestring path))
                    :ignore-error-status t))

;;; ---------------------------------------------------------------------------
;;; The write, jailed
;;; ---------------------------------------------------------------------------

(defun %write-repair (destination content jail)
  "Write CONTENT to DESTINATION, which must resolve inside JAIL. Return the path.

Every destination goes through the symlink-safe containment check before any
byte is written, so a catalogue path that has been made to point elsewhere cannot
carry a repair out of the repository it was aimed at."
  (let ((resolved (ensure-write-path (namestring destination) jail)))
    (unless resolved
      (error 'write-outside-root-error :path destination :root jail))
    (funcall *repair-writer* resolved content)
    resolved))

;;; ---------------------------------------------------------------------------
;;; The patterns the exclude is brought up to
;;; ---------------------------------------------------------------------------

(defun %exclude-patterns (profile catalog)
  "Return the pattern set of record joined with PROFILE's apparatus paths.

Two sets answering two questions. The template says what git already seeds into
every repository; the catalogue says what our apparatus consists of. A repository
we do not own needs both, because an apparatus file the template has never heard
of is exactly the one that would appear in a maintainer's git status."
  (let* ((template (template-exclude-patterns))
         (extra (remove-if (lambda (path) (member path template :test #'string=))
                           (apparatus-paths-for-profile profile catalog))))
    (append template extra)))

;;; ---------------------------------------------------------------------------
;;; The post-condition on our own work
;;; ---------------------------------------------------------------------------

(defun %tracked-apparatus-paths (root profile catalog)
  "Return the apparatus paths PROFILE forbids that ROOT's index currently holds.

Asks what git TRACKS, never what is present on disk. Present is the correct
state for a repository we have adopted; in the index is the leak."
  (if (eq profile :foreign)
      (let ((tracked (git-tracked-files root)))
        (remove-if-not (lambda (path) (member path tracked :test #'string=))
                       (apparatus-paths-for-profile profile catalog)))
      '()))

(defun verify-no-tracked-apparatus (root profile catalog &key already-tracked)
  "Signal FOREIGN-APPARATUS-TRACKED when a run has put apparatus into ROOT's index.

ALREADY-TRACKED names the apparatus paths the repository tracked before the run
started, and those are excluded from the check. They are a finding about the
repository, reported by the assessment and never repairable, and the caller has
already been told about them. What is checked here is the difference: a path that
was not in the index before the run and is in it now.

That difference can only come from our own writes, which is why reaching it means
the exclude-before-write ordering failed rather than meaning anything about the
repository. Returns the empty list when the run was clean."
  (let ((leaked (remove-if (lambda (path)
                             (member path already-tracked :test #'string=))
                           (%tracked-apparatus-paths root profile catalog))))
    (when leaked
      (error 'foreign-apparatus-tracked
             :item (find (first leaked) catalog
                         :key #'shape-item-path :test #'equal)
             :repo root
             :profile profile
             :detail (format nil "~{~A~^, ~} entered the index during a run of ours"
                             leaked)))
    leaked))

;;; ---------------------------------------------------------------------------
;;; Repairing one finding
;;; ---------------------------------------------------------------------------

(defun %wiring-entry (deviation member wiring)
  "Return the report entry for WIRING, the plist WIRE-GATE-HOOK returned for MEMBER."
  (list* :deviation deviation :item (shape-item-key member) wiring))

(defun %repair-deviation (deviation root catalog bindings jail dry-run severity
                          exclude profile)
  "Return three values for DEVIATION: the changes made, what it left unresolved,
and the keys of members found already correct during the repair.

A deviation naming a grouped item is repaired across the whole group, because a
group is assessed as one unit and a finding about it names only its first member.
Members already satisfied are left alone.

Where git cannot run configured hooks, the gate script is neither written nor
wired, and is reported unresolved as :NOT-INSTALLED with the reason. Otherwise
it is handled by GATE-FILE-STATE for PROFILE:
  :ABSENT   rendered for PROFILE and written, reported :CREATED.
  :CURRENT  kept as it is.
  :STALE    a lint gate rendered for another profile or out of date; rewritten
            for PROFILE and reported :REPLACED. This is the only file a repair
            replaces, and only because it is the doctor's own.
  :OTHER    unresolved: something is already there.
DRY-RUN reports :WOULD-CREATE or :WOULD-REPLACE and writes nothing. With the file
in place, the gate is wired through WIRE-GATE-HOOK for PROFILE, with DRY-RUN
passed on. A wiring that writes or would write is a change and a :NOT-WIRED one
is unresolved; either entry names the member's key and the local config file. A
kept gate's key is returned as already correct only when its wiring is not
unresolved.

A deviation naming no item at all is the local exclude, which is not a catalogue
item and was brought up to the pattern set of record before any file was written.
Its entry here reports that repair rather than repeating it."
  (let ((item (deviation-item deviation))
        (changes '())
        (problems '())
        (kept '()))
    (if (null item)
        (push (list :deviation deviation
                    :path (getf exclude :path)
                    :action-taken (getf exclude :action-taken))
              changes)
        (dolist (member (if (shape-item-group item)
                            (shape-group-items (shape-item-group item) catalog)
                            (list item)))
          (unless (item-satisfied-p member root profile)
            (let* ((destination (%item-destination member root bindings))
                   (gate-p (%gate-hook-item-p member))
                   (state (when gate-p (gate-file-state root profile)))
                   (in-place nil)
                   (keep nil))
              (flet ((write-member (action)
                       (%write-repair destination
                                      (%item-content member bindings severity
                                                     (%repo-name root) profile)
                                      (%item-jail member root jail))
                       (when (%executable-item-p member)
                         (%make-executable destination))
                       (setf in-place t)
                       (push (list :deviation deviation
                                   :item (shape-item-key member)
                                   :path destination
                                   :action-taken action)
                             changes))
                     (would (action)
                       (setf in-place t)
                       (push (list :deviation deviation
                                   :item (shape-item-key member)
                                   :path destination
                                   :action-taken action)
                             changes)))
                (cond
                  ((not (%writable-item-p member))
                   (push (list :deviation deviation
                               :item (shape-item-key member)
                               :path destination
                               :reason
                               "this item's content is measured from the repository rather than rendered, so it is recorded as debt rather than repaired")
                         problems))
                  ((and gate-p (not (configured-hooks-supported-p root)))
                   (push (list :deviation deviation
                               :item (shape-item-key member)
                               :path destination
                               :action-taken :not-installed
                               :reason
                               "this git cannot run configured hooks, so the gate is not installed")
                         problems))
                  ((eq state :current)
                   (setf in-place t keep t))
                  ((eq state :stale)
                   (if dry-run
                       (would :would-replace)
                       (write-member :replaced)))
                  ((probe-file destination)
                   (push (list :deviation deviation
                               :item (shape-item-key member)
                               :path destination
                               :reason
                               "something is already there, and a repair never replaces what it finds")
                         problems))
                  (dry-run (would :would-create))
                  (t (write-member :created))))
              (when (and in-place gate-p)
                (let ((wiring (wire-gate-hook root :dry-run dry-run
                                                   :profile profile)))
                  (case (getf wiring :action-taken)
                    ((:created :would-create :replaced :would-replace)
                     (push (%wiring-entry deviation member wiring) changes))
                    (:not-wired
                     (setf keep nil)
                     (push (%wiring-entry deviation member wiring) problems)))))
              (when keep
                (push (shape-item-key member) kept))))))
    (values (nreverse changes) (nreverse problems) (nreverse kept))))

;;; ---------------------------------------------------------------------------
;;; Freezing the debt
;;; ---------------------------------------------------------------------------

(defun %record-debt-baseline (root catalog bindings jail dry-run disposition
                              severity)
  "Return two values: the baseline's report plist, and a reason it is absent or NIL.

The baseline is written once per run and never rewritten. It records what was
true when the gate went in, so a second run replacing it would destroy the record
it exists to be, and would also make that run report a change where there was
none.

An absent linter writes nothing at all and says so. A document asserting zero
sites and a document nobody managed to populate are indistinguishable once
written, and the written one is believed."
  (let ((item (catalog-item :gate-baseline catalog)))
    (if (null item)
        (values (list :path nil :site-count nil :action-taken :not-enumerated)
                "the catalogue declares no frozen baseline, so there is nowhere to record debt")
        (let ((destination (%item-destination item root bindings)))
          (if (probe-file destination)
              (values (list :path destination
                            :site-count nil
                            :action-taken :already-present)
                      nil)
              (handler-case
                  (let* ((sites (collect-debt-sites root))
                         (content (render-debt-baseline
                                   :repo-name (%repo-name root)
                                   :disposition disposition
                                   :severity severity
                                   :sites sites)))
                    (if dry-run
                        (values (list :path destination
                                      :site-count (length sites)
                                      :action-taken :would-create)
                                nil)
                        (progn
                          (%write-repair destination content jail)
                          (values (list :path destination
                                        :site-count (length sites)
                                        :action-taken :created)
                                  nil))))
                (gate-scanner-unavailable-error (condition)
                  (values (list :path destination
                                :site-count nil
                                :action-taken :not-enumerated)
                          (format nil
                                  "the gate was installed but the debt was not enumerated: no scanner at ~A"
                                  (gate-scanner-unavailable-path condition))))))))))

;;; ---------------------------------------------------------------------------
;;; The run
;;; ---------------------------------------------------------------------------

(defun normalise-repository (root &key policy disposition upstream-url
                                       dry-run session-root
                                       (catalog *shape-catalog*))
  "Bring the repository at ROOT up to the declared shape under POLICY and report it.

POLICY is one of the deviation module's policy keywords, or NIL. With NIL nothing
is written anywhere, including the local exclude, and every finding is returned
unresolved with the decisions it admits, for the caller to choose between. An
unattended run must not decide on its own what to do to a repository.

DISPOSITION answers the disposition question when the repository records none.
The disposition refusals propagate before anything is written: the question,
a conflict with the recorded value, an unreadable value, and, when the answer
would be recorded, a tracked .envrc. A supplied answer is recorded in the
worktree's .envrc after the exclude step and the repairs; a run with no policy
or a dry run reports :WOULD-RECORD instead. A recorded value is never rewritten.

UPSTREAM-URL, when supplied for a repository that records no upstream, adds that
remote. It decides nothing about the disposition.

DRY-RUN writes nothing at all and still names what would change.

A repair of the quality gate installs the gate script rendered for the
repository's profile and wires it as a configured pre-commit hook beside any
hook already there. The wiring is reported like a file: a change when written,
unresolved when an existing hook.lisp-gate entry differs. Where git cannot run
configured hooks, neither is written and the gate is reported unresolved.

Returns a DOCTOR-REPORT."
  (let* ((root (uiop:ensure-directory-pathname root))
         (jail (or session-root root))
         (head-before (git-head-sha root))
         (assessment (assess-repository root
                                        :disposition disposition
                                        :catalog catalog))
         (declared (assessment-disposition assessment))
         (source (assessment-disposition-source assessment))
         (profile (assessment-profile assessment))
         (bindings (%bindings root))
         (severity (adopted-repo-gate-severity))
         (already-tracked (%tracked-apparatus-paths root profile catalog))
         (silent (or dry-run (null policy)))
         (changed '())
         (recorded-debt '())
         (accepted '())
         (unresolved '())
         (kept '())
         (baseline nil)
         (remote-added nil)
         (recorded nil))

    ;; A disposition that will have to be recorded is checked for being
    ;; recordable before any write, so the refusal leaves nothing behind.
    (when (eq source :argument)
      (check-disposition-recordable root))

    ;; The offer to record where a repository came from, before anything else is
    ;; decided about it.
    (when (and upstream-url (null (git-remote-url root "upstream")))
      (setf remote-added
            (if silent
                (list :remote "upstream" :url upstream-url
                      :action-taken :would-add)
                (progn
                  (git-remote-add root "upstream" upstream-url)
                  (list :remote "upstream" :url upstream-url
                        :action-taken :added)))))

    ;; The exclude is brought up to date HERE, and nothing below may be lifted
    ;; above it. A file of ours that exists in a worktree we do not own and is
    ;; not yet excluded shows up in that maintainer's git status the moment it
    ;; lands, and the next thing staged sweeps it into their commit. Excluding
    ;; first means the interval in which that can happen does not exist.
    (let ((exclude (repair-repo-exclude
                    root
                    :template-patterns (%exclude-patterns profile catalog)
                    :dry-run silent)))

      (dolist (deviation (assessment-deviations assessment))
        (if (null policy)
            (push (list :deviation deviation
                        :restarts (available-restarts deviation)
                        :reason "no policy was supplied, so nothing was decided")
                  unresolved)
            (handler-case
                (ecase (call-with-deviation-policy
                        (lambda () (signal-deviation deviation))
                        :policy policy)
                  (:repaired
                   (multiple-value-bind (entries problems keys)
                       (%repair-deviation deviation root catalog bindings jail
                                          dry-run severity exclude profile)
                     (dolist (entry entries) (push entry changed))
                     (dolist (problem problems) (push problem unresolved))
                     (dolist (key keys) (pushnew key kept))))
                  (:recorded-as-debt
                   (unless baseline
                     (multiple-value-bind (report reason)
                         (%record-debt-baseline root catalog bindings jail
                                                dry-run declared severity)
                       (setf baseline report)
                       (when reason
                         (push (list :deviation deviation
                                     :restarts (available-restarts deviation)
                                     :reason reason)
                               unresolved))))
                   (push (list :deviation deviation :baseline baseline)
                         recorded-debt))
                  (:accepted
                   (push (list :deviation deviation) accepted)))
              ;; One finding the policy cannot speak to must not silence the
              ;; rest. Each is caught on its own and the walk continues.
              (policy-not-applicable-error (condition)
                (push (list :deviation deviation
                            :restarts (available-restarts deviation)
                            :reason (princ-to-string condition))
                      unresolved)))))

      ;; Recorded after the exclude step and the repairs, so the line joins a
      ;; freshly repaired .envrc whose path is already excluded.
      (setf recorded
            (if (eq source :argument)
                (record-disposition root declared :jail jail :dry-run silent)
                (list :path source :disposition declared
                      :action-taken :already-present)))

      ;; A post-condition on our own writes, not a finding about the repository.
      (verify-no-tracked-apparatus root profile catalog
                                   :already-tracked already-tracked)

      (let ((head-after (git-head-sha root)))
        (unless (equal head-before head-after)
          (error 'head-moved-error :root root
                                   :before head-before
                                   :after head-after))
        (%make-doctor-report
         :root root
         :disposition declared
         :disposition-source source
         :disposition-recorded recorded
         :warnings (disposition-warnings root declared :upstream-url upstream-url)
         :profile profile
         :changed (nreverse changed)
         :already-correct (append (assessment-satisfied assessment)
                                  (remove-if (lambda (key)
                                               (member key (assessment-satisfied
                                                            assessment)))
                                             (nreverse kept)))
         :recorded-debt (nreverse recorded-debt)
         :accepted (nreverse accepted)
         :unresolved (nreverse unresolved)
         :exclude exclude
         :debt-baseline baseline
         :remote-added remote-added
         :head-sha-before head-before
         :head-sha-after head-after
         :dry-run (and dry-run t))))))
