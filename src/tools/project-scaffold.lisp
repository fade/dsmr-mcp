;;;; src/tools/project-scaffold.lisp
;;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;;;
;;;; MCP tool: emit a full DSMR-discipline Lisp project tree under the
;;;; session write-jail. Mode-independent (dispatcher-side). No-root guard
;;;; at entry: scaffold writes require a session root.

(defpackage #:dsmr-mcp/src/tools/project-scaffold
  (:use #:cl)
  (:import-from #:dsmr-mcp/src/tools/base
                #:mcp-tool
                #:mcp-tool-class
                #:tool-handle
                #:tool-session)
  (:import-from #:dsmr-mcp/src/tools/helpers
                #:make-ht
                #:result
                #:text-content)
  (:import-from #:dsmr-mcp/src/state
                #:session-project-root)
  (:import-from #:dsmr-mcp/src/project-scaffold
                #:write-scaffold)
  (:import-from #:dsmr-mcp/src/project-scaffold-core
                #:invalid-argument-error
                #:invalid-argument-field
                #:invalid-argument-reason)
  (:import-from #:dsmr-mcp/src/tools/project-doctor
                #:+accepted-dispositions+
                #:disposition-argument
                #:disposition-question-result
                #:disposition-refusal-result)
  (:import-from #:dsmr-mcp/src/repo-classify
                #:project-disposition-required
                #:project-disposition-conflict
                #:project-disposition-unreadable
                #:project-disposition-not-recordable)
  (:export #:project-scaffold-tool))

(in-package #:dsmr-mcp/src/tools/project-scaffold)

(defclass project-scaffold-tool (mcp-tool)
  ((dsmr-mcp/src/tools/base::name
    :allocation :class
    :initform "project-scaffold")
   (dsmr-mcp/src/tools/base::description
    :allocation :class
    :initform "Generate a complete Lisp project skeleton under the session root. \
Emits a package-inferred-system with a mode-dispatching executable, Zebra \
test suite, build recipe, dev-boot script, dependency-preference agent docs, \
a copied REPL-development guide, and a selectable license with per-file SPDX \
headers. The new project includes the lint gate (linter config, lint script, \
and a pre-commit gate) whenever the scaffold creates its repository, and then \
records the disposition ours in the project's untracked .envrc. Inside an \
existing repository with no disposition recorded, the call returns the \
question, the three answers (ours, contributing, or forked), and what each \
means, and writes nothing; a second call carries the answer in disposition, \
which is recorded in that repository's .envrc before the project is written. \
Returns a manifest of created files and next-step commands.")
   (dsmr-mcp/src/tools/base::input-schema
    :allocation :class
    :initform '(:object
                :properties
                ((name
                  :type :string
                  :description "Project name in lisp-case (e.g. foo-lib). \
Must match ^[a-z][a-z0-9-]*$ and be 1-64 characters.")
                 (license
                  :type :string
                  :enum ("AGPL-3.0-or-later" "GPL-3.0-or-later" "GPL-2.0-or-later"
                         "LGPL-3.0-or-later" "LGPL-2.1-or-later"
                         "MIT" "BSD-2-Clause" "BSD-3-Clause" "Apache-2.0")
                  :description "SPDX license identifier (default: AGPL-3.0-or-later).")
                 (author
                  :type :string
                  :description "Author string for .asd :author. No newlines.")
                 (copyright
                  :type :string
                  :description "Copyright holder for LICENSE file (defaults to author). No newlines.")
                 (description
                  :type :string
                  :description "One-line project description for .asd and README. No newlines.")
                 (destination
                  :type :string
                  :description "Relative parent directory under the session root \
where <name>/ is created (default: scaffolds). No leading / or .. segments.")
                 (year
                  :type :string
                  :description "Copyright year for LICENSE (default: current year).")
                 (overwrite
                  :type :boolean
                  :description "When true, replace an existing scaffold directory. Default: false.")
                 (init-git
                  :type :boolean
                  :description "When false, skip repository initialization. \
Default: true. A repository is created only when the new project would not sit \
inside an existing one.")
                 (disposition
                  :type :string
                  :enum ("ours" "contributing" "forked")
                  :description "What the existing repository the project goes \
into is, when its .envrc records nothing: ours, code originating with the \
operator; contributing, a third-party project the operator only contributes to; \
forked, forked to shorten the acceptance chain or because upstream is \
unmaintained. Recorded in that repository's .envrc before the project is \
written. A repository the scaffold creates takes only ours."))
                :required ("name"))))
  (:metaclass mcp-tool-class)
  (:documentation "MCP tool: generate a DSMR-discipline Lisp project skeleton.
Writes an atomic tree under the session root via temp-dir + rename-file.
No-root guard at entry: call fs-set-project-root first.
Initializes a git repository in the new project unless it would nest inside an
existing one, and reports which of those happened."))

(c2mop:ensure-finalized (find-class 'project-scaffold-tool))

(defun %wire-name (keyword)
  "Return KEYWORD as the lower-case string the wire carries."
  (string-downcase (symbol-name keyword)))

(defun %gate-hook-object (gate)
  "Return the gate_hook result object for GATE, the :GATE-HOOK plist of write-scaffold.
Carries action_taken always, path when the gate was installed, reason when it
was not, and the wiring's action_taken, plus its reason when it has one."
  (let ((object (make-ht "action_taken" (%wire-name (getf gate :action-taken))))
        (wiring (getf gate :wiring)))
    (when (getf gate :path)
      (setf (gethash "path" object) (namestring (getf gate :path))))
    (when (getf gate :reason)
      (setf (gethash "reason" object) (getf gate :reason)))
    (when wiring
      (let ((wiring-object (make-ht "action_taken"
                                    (%wire-name (getf wiring :action-taken)))))
        (when (getf wiring :reason)
          (setf (gethash "reason" wiring-object) (getf wiring :reason)))
        (setf (gethash "wiring" object) wiring-object)))
    object))

(defun %gate-hook-line (gate)
  "Return the content line saying whether the lint gate was installed, and why not."
  (let ((wiring (getf gate :wiring)))
    (cond
      ((not (eq :created (getf gate :action-taken)))
       (format nil "No lint gate was installed: ~A." (getf gate :reason)))
      ((member (getf wiring :action-taken) '(:created :already-present))
       (format nil "Installed the lint gate at ~A; it refuses a commit that ~
touches a failing form."
               (namestring (getf gate :path))))
      (t
       (format nil "Installed the lint gate at ~A, but it is not wired: ~A."
               (namestring (getf gate :path)) (getf wiring :reason))))))

(defun %disposition-object (recorded)
  "Return the disposition result object for RECORDED, the :DISPOSITION plist of
write-scaffold. Carries action_taken always, and disposition and path when one
was recorded, reason when none was."
  (let ((object (make-ht "action_taken" (%wire-name (getf recorded :action-taken)))))
    (when (getf recorded :disposition)
      (setf (gethash "disposition" object)
            (%wire-name (getf recorded :disposition))))
    (when (getf recorded :path)
      (setf (gethash "path" object) (namestring (getf recorded :path))))
    (when (getf recorded :reason)
      (setf (gethash "reason" object) (getf recorded :reason)))
    object))

(defun %disposition-line (recorded)
  "Return the content line saying whether the disposition was recorded, and why not."
  (cond
    ((null (getf recorded :disposition))
     (format nil "No disposition was recorded: ~A." (getf recorded :reason)))
    ((eq :already-present (getf recorded :action-taken))
     (format nil "The disposition ~A is already recorded in ~A."
             (%wire-name (getf recorded :disposition))
             (namestring (getf recorded :path))))
    (t
     (format nil "Recorded the disposition ~A in ~A."
             (%wire-name (getf recorded :disposition))
             (namestring (getf recorded :path))))))

(defmethod tool-handle ((tool project-scaffold-tool) id args)
  (let* ((session (tool-session tool))
         (root    (session-project-root session)))
    ;; No-root guard: scaffold writes under the session root
    (unless root
      (return-from tool-handle
        (result id (make-ht "isError" t
                            "error_type" "project-root-not-set"
                            "content"
                            (text-content "project-scaffold: no project root set. \
Call fs-set-project-root first.")))))
    ;; Read args (kebab->snake wire transform: description stays description,
    ;; others match schema property names directly)
    (let* ((name        (gethash "name" args))
           (license     (gethash "license" args))
           (author      (gethash "author" args))
           (copyright   (gethash "copyright" args))
           (description (gethash "description" args))
           (destination (gethash "destination" args))
           (year        (gethash "year" args))
           (overwrite   (gethash "overwrite" args))
           ;; Absent means the default, and the default is true. Reading the
           ;; value alone cannot tell an omitted argument from an explicit
           ;; false, and those two must not answer the same way.
           (init-git    (if (nth-value 1 (gethash "init_git" args))
                            (and (gethash "init_git" args) t)
                            t))
           (disposition (disposition-argument (gethash "disposition" args))))
      (when (eq disposition :invalid)
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "error_type" "invalid-argument"
                              "content"
                              (text-content
                               (format nil "project-scaffold: disposition must be one of ~{~A~^, ~}."
                                       (coerce +accepted-dispositions+ 'list)))))))
      (unless (and name (stringp name))
        (return-from tool-handle
          (result id (make-ht "isError" t
                              "error_type" "invalid-argument"
                              "content" (text-content "project-scaffold: name must be a string.")))))
      (handler-case
          (let* ((res         (write-scaffold
                               :session-root root
                               :name name
                               :description (or description
                                                "A Common Lisp project.")
                               :author (or author "Unknown")
                               :license (or license "AGPL-3.0-or-later")
                               :copyright (or copyright author "Unknown")
                               ;; year default (live current year) is owned by
                               ;; the scaffold core; pass the raw arg through
                               :year year
                               :destination (or destination "scaffolds")
                               :overwrite overwrite
                               :init-git init-git
                               :disposition disposition))
                 (target-dir  (getf res :target-dir))
                 (relative    (getf res :relative-path))
                 (files       (getf res :files))
                 (git-init-p  (getf res :git-initialised))
                 (abs-asd     (namestring
                               (merge-pathnames (format nil "~A.asd" name) target-dir)))
                 (registration (getf res :registration))
                 (next-steps  (vector
                               ;; Report what registration actually reached. A
                               ;; project on a configured source-registry tree
                               ;; is findable from any image on this host; one
                               ;; outside every tree was registered here alone,
                               ;; and the caller needs the load-asd line to
                               ;; reach any other image.
                               (if (eq registration :source-registry)
                                   (format nil
                                           "Registered with ASDF: ~S resolves on the source registry. ~
In an image that started before this scaffold: (asdf:load-asd ~S)"
                                           name abs-asd)
                                   (format nil
                                           "Registered in this image only: ~S sits outside every configured ~
ASDF source-registry tree. Elsewhere: (asdf:load-asd ~S)"
                                           name abs-asd))
                               (format nil
                                       "To load: run load-system with {\"system\": ~S}"
                                       name)
                               (format nil
                                       "To test: run run-tests with {\"system\": ~S}"
                                       (format nil "~A/tests" name))
                               (format nil
                                       "To edit: use lisp-edit-form with paths under ~A"
                                       (namestring target-dir)))))
            (result id
                    (make-ht "created" t
                             "path" (if (stringp relative) relative
                                        (namestring relative))
                             "absolute_path" (namestring target-dir)
                             "files" (coerce files 'vector)
                             "git_initialised" git-init-p
                             "gate_hook" (%gate-hook-object (getf res :gate-hook))
                             "disposition" (%disposition-object
                                            (getf res :disposition))
                             "next_steps" next-steps
                             "content"
                             (text-content
                              (format nil "Scaffolded ~A at ~A (~D files)~%Path: ~A~%~A~%~A~%~A~%~{~A~%~}"
                                      name relative (length files)
                                      (namestring target-dir)
                                      (if git-init-p
                                          "Initialized a git repository here."
                                          "No git repository was created here.")
                                      (%gate-hook-line (getf res :gate-hook))
                                      (%disposition-line (getf res :disposition))
                                      (coerce next-steps 'list))))))
        (invalid-argument-error (e)
          (result id
                  (make-ht "isError" t
                           "created" nil
                           "error_type" (let ((field (invalid-argument-field e))
                                              (reason (invalid-argument-reason e)))
                                          (if (string= field "destination")
                                              "sandbox-violation"
                                              "invalid-argument"))
                           "content" (text-content (princ-to-string e)))))
        ;; The question. Nothing has been written: the disposition is settled
        ;; before the project is.
        (project-disposition-required (condition)
          (disposition-question-result id condition "project-scaffold"))
        (project-disposition-conflict (condition)
          (disposition-refusal-result
           id "project-disposition-conflict" condition "project-scaffold"))
        (project-disposition-unreadable (condition)
          (disposition-refusal-result
           id "project-disposition-unreadable" condition "project-scaffold"))
        (project-disposition-not-recordable (condition)
          (disposition-refusal-result
           id "project-disposition-not-recordable" condition "project-scaffold"))))))
