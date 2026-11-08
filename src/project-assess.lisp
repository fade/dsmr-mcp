;;;; src/project-assess.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; Look at a repository and say how it differs from the declared shape,
;;;; without touching it.
;;;;
;;;; Nothing here writes. There is no atomic-write call, no directory creation,
;;;; no deletion, and every git command the assessment runs is a read: the
;;;; listing of what a repository tracks, and the hook list and local config
;;;; reads that say whether the lint gate is wired. That is a property of the
;;;; module rather than a promise about how it is used: an assessment that
;;;; cannot write cannot damage a third party's tree however it is called, and
;;;; the repair engine that does write is a separate module with its own tests.
;;;;
;;;; What makes the report worth reading is that a repository is only measured
;;;; against what it is answerable for. A flat requirement that every repository
;;;; carry every file we like to have would report roughly ninety working
;;;; third-party repositories in $LISP_WORKSPACE as sick, and a list that is mostly
;;;; false entries hides the true ones. A repository we do not own is answerable
;;;; for none of our conventions at all, only for our own apparatus being where
;;;; we need it and out of its index. Which items a profile is held to is read
;;;; from the catalog. It is not restated here: two copies would mean a revised
;;;; answer had to be applied in two files in two subsystems.
;;;;
;;;; A quality gate is assessed through its group, as one unit. The linter
;;;; configuration and the script that runs it never occur apart in the measured
;;;; population, and the hook is what makes either take effect, so a half
;;;; installed gate is one finding about one gate rather than a scattering of
;;;; unrelated absences.
;;;;
;;;; Deviations are CONSTRUCTED here and never signalled. One call reports every
;;;; finding in a repository; signalling would stop at the first and leave the
;;;; rest unmeasured. The caller decides what to do, and the deviation carries
;;;; enough to decide with.
;;;;
;;;; A clean answer is distinguishable from no answer. The returned structure
;;;; carries the classification, the profile and the keys of every item found
;;;; already correct, so an empty deviation list arrives with the evidence of
;;;; the work that produced it.

(defpackage #:dsmr-mcp/src/project-assess
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/project-shape
                #:shape-item-key
                #:shape-item-path
                #:shape-item-group
                #:shape-item-assertion
                #:shape-item-match
                #:shape-item-install-target
                #:shape-group-items
                #:*shape-catalog*)
  (:import-from #:dsmr-mcp/src/project-shape-catalog
                #:item-assessed-p
                #:apparatus-paths-for-profile)
  (:import-from #:dsmr-mcp/src/project-deviation
                #:missing-shape-item
                #:drifted-shape-item
                #:foreign-apparatus-tracked)
  (:import-from #:dsmr-mcp/src/repo-classify
                #:classify-repository
                #:repo-profile)
  (:import-from #:dsmr-mcp/src/project-exclude
                #:template-exclude-patterns
                #:parse-exclude-patterns
                #:repo-exclude-path
                #:missing-exclude-patterns)
  (:import-from #:dsmr-mcp/src/project-hook
                #:gate-hook-path
                #:gate-hook-wired-p)
  (:import-from #:dsmr-mcp/src/project-debt
                #:render-pre-commit-hook)
  (:import-from #:sb-posix)
  (:import-from #:dsmr-mcp/src/git
                #:git-tracked-files
                #:git-common-dir)
  (:export #:assess-repository
           #:item-satisfied-p
           #:gate-file-state
           #:assessment
           #:assessment-p
           #:assessment-root
           #:assessment-classification
           #:assessment-profile
           #:assessment-deviations
           #:assessment-satisfied))

(in-package #:dsmr-mcp/src/project-assess)

;;; ---------------------------------------------------------------------------
;;; Is one item satisfied?
;;; ---------------------------------------------------------------------------

(defun %assertion-base (item root)
  "Return the directory ITEM's match is resolved against, under ROOT.

An item installed under the repository's git directory is looked for in the
directory every worktree shares and never in the working tree. Resolving it
against the worktree would report a hook as absent in every repository that
has one, and would report a same-named file in the tree as the hook."
  (ecase (shape-item-install-target item)
    (:worktree (uiop:ensure-directory-pathname root))
    (:git-dir (git-common-dir root))))

(defun %gate-signature ()
  "Return the opening two lines every rendering of the lint gate starts with."
  (let ((lines (uiop:split-string (render-pre-commit-hook :profile :foreign)
                                  :separator '(#\Newline))))
    (format nil "~A~%~A~%" (first lines) (second lines))))

(defun %executable-file-p (path)
  "Return true when PATH names a regular file with an execute bit set."
  (handler-case
      (let ((mode (sb-posix:stat-mode
                   (sb-posix:stat (uiop:native-namestring path)))))
        (and (sb-posix:s-isreg mode)
             (logtest mode (logior sb-posix:s-ixusr sb-posix:s-ixgrp
                                   sb-posix:s-ixoth))
             t))
    (sb-posix:syscall-error () nil)))

(defun gate-file-state (root profile)
  "Return the state of the file at GATE-HOOK-PATH of the repository at ROOT.

  :ABSENT   nothing is there.
  :CURRENT  an executable file holding the gate rendered for PROFILE.
  :STALE    a lint gate rendered for another profile, an earlier rendering of
            the gate, or the current one without its execute bit. The doctor
            replaces it.
  :OTHER    a directory, or a file that is not a lint gate. Nothing replaces it.
A lint gate is recognized by its two opening lines and a GATE_MODE line."
  (let ((path (gate-hook-path root)))
    (cond
      ((uiop:directory-exists-p path) :other)
      ((not (probe-file path)) :absent)
      (t
       (let ((text (handler-case (uiop:read-file-string path)
                     (error () nil))))
         (cond
           ((null text) :other)
           ((and (string= text (render-pre-commit-hook :profile profile))
                 (%executable-file-p path))
            :current)
           ((and (uiop:string-prefix-p (%gate-signature) text)
                 (search (format nil "~%GATE_MODE='") text))
            :stale)
           (t :other)))))))

(defun item-satisfied-p (item root &optional profile)
  "Return T when ITEM's assertion holds in the repository at ROOT, else NIL.

:FILE-EXISTS requires a file at the named relative path, and a directory of that
name does not satisfy it. :DIRECTORY-EXISTS requires a directory. :ANY-FILE-MATCHING
is satisfied by any one file at the top level matching the glob, which is how a
system definition is asserted without dictating what the project is called; it
does not descend, so a system definition buried in a subdirectory is not the
top-level one being asked about.

:GATE-HOOK-WIRED requires the gate script at GATE-HOOK-PATH and git listing it as an
enabled pre-commit hook with the expected command. Given PROFILE, the script
must be the executable rendering for PROFILE (see GATE-FILE-STATE) and the
command the one for PROFILE; with PROFILE NIL, any file there and either
profile's command satisfy it. A file named pre-commit is
not evidence of the gate: a git init template can seed one into every new
repository, and it is not ours.

An unrecognized assertion signals rather than answering NIL. NIL would report the
item as absent from every repository, which reads as a finding about the
repository rather than as the typo it is."
  (let ((base (%assertion-base item root))
        (match (shape-item-match item)))
    (ecase (shape-item-assertion item)
      (:file-exists
       (and (uiop:file-exists-p (merge-pathnames match base)) t))
      (:directory-exists
       (and (uiop:directory-exists-p (merge-pathnames match base)) t))
      (:any-file-matching
       (and (directory (merge-pathnames match base)) t))
      (:gate-hook-wired
       (and (if profile
                (eq :current (gate-file-state root profile))
                (uiop:file-exists-p (gate-hook-path root)))
            (gate-hook-wired-p root :profile profile)
            t)))))

;;; ---------------------------------------------------------------------------
;;; The result
;;; ---------------------------------------------------------------------------

(defstruct (assessment (:constructor %make-assessment)
                       (:copier nil)
                       (:predicate assessment-p))
  "What one read-only look at a repository found.

DEVIATIONS is a list of condition objects, possibly empty, none of them
signalled. SATISFIED is the list of item keys found already correct.

SATISFIED is not decoration. Without it an empty deviation list says only that
nothing was reported, which is equally true of a repository in perfect shape and
of an assessment that never looked at anything."
  (root           nil :read-only t)
  (classification nil :type keyword :read-only t)
  (profile        nil :type keyword :read-only t)
  (deviations     '() :type list    :read-only t)
  (satisfied      '() :type list    :read-only t))

;;; ---------------------------------------------------------------------------
;;; Naming an item in a report
;;; ---------------------------------------------------------------------------

(defun %item-label (item)
  "Return the path ITEM names, falling back to the pattern it is matched by."
  (or (shape-item-path item) (shape-item-match item)))

(defun %unsatisfied-label (item root profile)
  "Return how an unsatisfied ITEM is named in a finding about ROOT under PROFILE.
A gate that is present but not the rendering for PROFILE is named as such,
since calling it absent would misdescribe the repository."
  (if (and (eq :gate-hook-wired (shape-item-assertion item))
           (eq :stale (gate-file-state root profile)))
      (format nil "~A (a lint gate rendered for another profile or out of date)"
              (%item-label item))
      (%item-label item)))

;;; ---------------------------------------------------------------------------
;;; Which items this repository is held to
;;; ---------------------------------------------------------------------------

(defun %assessed-items (catalog profile)
  "Return the members of CATALOG that PROFILE is held to, in catalogue order.

What that comes to is the catalogue's to answer and not this module's. The
question a repository is measured against is part of the shape declaration, and
restating any of it here would mean a revised answer had to be applied twice."
  (remove-if-not (lambda (item) (item-assessed-p item profile)) catalog))

(defun %groups-in-order (items)
  "Return the distinct groups named by ITEMS, in first-appearance order."
  (let ((groups '()))
    (dolist (item items (nreverse groups))
      (let ((group (shape-item-group item)))
        (when (and group (not (member group groups)))
          (push group groups))))))

;;; ---------------------------------------------------------------------------
;;; The passes
;;; ---------------------------------------------------------------------------

(defun %assess-group (group members root profile)
  "Return two values: one deviation or NIL, and the keys of the satisfied members.

A group stands or falls together, so any unsatisfied member yields exactly one
finding naming the group and the members that are absent. Reporting them
separately would describe a partial install that does not occur, and would count
one absent gate as several unrelated faults."
  (let ((unsatisfied '())
        (satisfied '()))
    (dolist (item members)
      (if (item-satisfied-p item root profile)
          (push item satisfied)
          (push item unsatisfied)))
    (setf unsatisfied (nreverse unsatisfied)
          satisfied (nreverse satisfied))
    (values
     (when unsatisfied
       (make-condition 'missing-shape-item
                       :item (first members)
                       :repo root
                       :profile profile
                       :detail (format nil "the ~(~A~) is not installed; absent: ~{~A~^, ~}"
                                       group
                                       (mapcar (lambda (item)
                                                 (%unsatisfied-label item root
                                                                     profile))
                                               unsatisfied))))
     (mapcar #'shape-item-key satisfied))))

(defun %exclude-drift (root profile)
  "Return one DRIFTED-SHAPE-ITEM when ROOT's local exclude has fallen behind, else NIL.

The pattern set of record is read from the template on every call, so a pattern
added to the template becomes a finding in every repository at once. A repository
with no exclude file at all is measured as carrying no patterns, which is what it
carries.

The deviation names no catalogue item, because the local exclude is not one: it is
provisioned by git itself and never written by the scaffold. Declaring an item
for it here would put part of the shape outside the one file that holds the
shape. The path and the patterns it lacks are in the detail."
  (let* ((path (repo-exclude-path root))
         (existing (when (probe-file path) (uiop:read-file-string path)))
         (missing (missing-exclude-patterns
                   (parse-exclude-patterns (or existing ""))
                   (template-exclude-patterns))))
    (when missing
      (make-condition 'drifted-shape-item
                      :repo root
                      :profile profile
                      :detail (format nil "~A lacks ~D pattern~:P of record: ~{~A~^, ~}"
                                      (namestring path)
                                      (length missing)
                                      missing)))))

(defun %tracked-apparatus (root profile catalog)
  "Return one FOREIGN-APPARATUS-TRACKED deviation per apparatus path ROOT tracks.

Performed only under the :FOREIGN profile. Under :OURS the identical file is
ordinary project content and reporting it would be a false finding about a
repository that is behaving correctly, which is the whole of the two-mode design.

The question asked is what git TRACKS, never what is present on disk. Our
apparatus is meant to be present in a repository we do not own; what must never
happen is its arriving in somebody else's index. A check aimed at presence would
report every correctly adopted repository and miss nothing else."
  (when (eq profile :foreign)
    (let ((tracked (git-tracked-files root))
          (found '()))
      (dolist (path (apparatus-paths-for-profile profile catalog) (nreverse found))
        (when (member path tracked :test #'string=)
          (push (make-condition 'foreign-apparatus-tracked
                                :item (find path catalog
                                            :key #'shape-item-path
                                            :test #'equal)
                                :repo root
                                :profile profile
                                :detail
                                (format nil "~A is in the index of a repository we do not own"
                                        path))
                found))))))

;;; ---------------------------------------------------------------------------
;;; The assessment
;;; ---------------------------------------------------------------------------

(defun assess-repository (root &key declared-classification upstream-url
                                    (catalog *shape-catalog*))
  "Return an ASSESSMENT of the repository at ROOT. Writes nothing.

The repository is classified first, and an ambiguous classification propagates
unhandled. Whether a tree whose origin is ours but which records no upstream is
our own project is not inferable from anything on disk, and answering it here
would be a guess made where nobody can see it. The caller decides whether to ask.

Which items the profile is held to is read from the catalog. A repository we own
is measured against its own structure and the quality gate, so one legitimately
without a build script is never reported for it. A repository we do not own is
measured against our apparatus alone and never against its own layout.

Grouped items are assessed together and produce at most one finding each.
Ungrouped items produce one finding each. The local exclude is compared against
the pattern set of record. Under :FOREIGN, and only under :FOREIGN, the index is
read for apparatus that has leaked into it.

Every finding is a condition object built and returned, never signalled, so one
call reports everything the repository has rather than stopping at the first
thing wrong with it."
  (let* ((classification (classify-repository
                          root
                          :declared-classification declared-classification
                          :upstream-url upstream-url))
         (profile (repo-profile classification))
         (items (%assessed-items catalog profile))
         (deviations '())
         (satisfied '()))
    (dolist (group (%groups-in-order items))
      (multiple-value-bind (deviation keys)
          (%assess-group group (shape-group-items group items) root profile)
        (when deviation
          (push deviation deviations))
        (dolist (key keys)
          (push key satisfied))))
    (dolist (item items)
      (unless (shape-item-group item)
        (if (item-satisfied-p item root profile)
            (push (shape-item-key item) satisfied)
            (push (make-condition 'missing-shape-item
                                  :item item
                                  :repo root
                                  :profile profile
                                  :detail (format nil "nothing at ~A"
                                                  (%item-label item)))
                  deviations))))
    (let ((drift (%exclude-drift root profile)))
      (when drift
        (push drift deviations)))
    (dolist (leak (%tracked-apparatus root profile catalog))
      (push leak deviations))
    (%make-assessment :root root
                      :classification classification
                      :profile profile
                      :deviations (nreverse deviations)
                      :satisfied (nreverse satisfied))))
